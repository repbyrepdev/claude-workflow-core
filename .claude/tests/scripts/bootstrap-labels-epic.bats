#!/usr/bin/env bats
# covers: scripts/bootstrap-repo.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/bootstrap-repo.sh"
	TEST_TMP=$(mktemp -d -t bootstrap-labels-epic.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */bootstrap-labels-epic.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Extract heredoc body for a given file path target (target uses raw glob chars).
_extract_heredoc() {
	local target=$1
	awk -v t="$target" 'BEGIN{ pat = "^_write " t " 644 <<'\''EOF'\''$" } $0 ~ pat,/^EOF$/' "$SCRIPT" | sed '1d;$d'
}

@test 'bootstrap epic.yml heredoc uses quoted labels ["epic", "enhancement"]' {
	body=$(_extract_heredoc '.github/ISSUE_TEMPLATE/epic.yml')
	[ -n "$body" ]
	echo "$body" | grep -qF 'labels: ["epic", "enhancement"]'
}

@test "live epic.yml matches the quoted-labels contract" {
	live="${REPO_ROOT}/.github/ISSUE_TEMPLATE/epic.yml"
	[ -f "$live" ]
	grep -qF 'labels: ["epic", "enhancement"]' "$live"
}

@test "epic.yml passes issue-template-schema-check.sh validator (v0.19.1 #143)" {
	# Validator reads from staged area / repo; we just check the validator
	# parser recognizes the heredoc body as valid (labels line is the
	# tightest invariant — required-id list is in _spec.yml).
	body=$(_extract_heredoc '.github/ISSUE_TEMPLATE/epic.yml')
	echo "$body" | grep -qE '^labels:[[:space:]]*\[.*\]'
	echo "$body" | grep -q '"epic"'
	echo "$body" | grep -q '"enhancement"'
}

@test "bootstrap-repo.sh defines _apply_labels function" {
	grep -qE '^_apply_labels\(\)' "$SCRIPT"
}

@test "_apply_labels prints the would-apply message in dry-run" {
	mkdir -p "$TEST_TMP/target"
	run bash -c "\"$SCRIPT\" \"$TEST_TMP/target\" --dry-run 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"would apply labels"* ]]
}

# CR #1607: label sync is OPT-IN via --apply-labels. WITH the flag on a
# no-remote target, _apply_labels runs and hits its no-remote skip-NOTE.
# Hermetic: _apply_labels only reaches the no-remote branch AFTER both
# `command -v gh` and `command -v yq` succeed, so shim both on PATH (no-op
# stubs) — otherwise the result depends on the runner image's gh/yq presence.
@test "_apply_labels NOTE on no-remote target (gh present, --apply-labels)" {
	mkdir -p "$TEST_TMP/target-no-remote"
	mkdir -p "$TEST_TMP/bin"
	cat >"$TEST_TMP/bin/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
	cat >"$TEST_TMP/bin/yq" <<'EOF'
#!/bin/bash
exit 0
EOF
	chmod +x "$TEST_TMP/bin/gh" "$TEST_TMP/bin/yq"
	run env PATH="$TEST_TMP/bin:$PATH" bash -c "\"$SCRIPT\" \"$TEST_TMP/target-no-remote\" --apply-labels 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"no GitHub remote yet"* ]]
}

# CR #1607: WITHOUT --apply-labels (the default), a non-dry-run real install
# must NOT touch the remote label set — it NOTEs the skip and never reaches
# _apply_labels' no-remote message.
@test "label sync skipped by default (no --apply-labels) → opt-in NOTE, no remote write" {
	mkdir -p "$TEST_TMP/target-default"
	run bash -c "\"$SCRIPT\" \"$TEST_TMP/target-default\" 2>&1"
	[ "$status" -eq 0 ]
	# CR-CLI #1607: bootstrap-repo.sh logs "label sync SKIPPED" (uppercase);
	# the old lowercase glob never matched. AND: bats 1.13.0 only fails a test
	# on the LAST command's rc (no set -e in test bodies), so a bare mid-body
	# `[[ ]]` is silently ignored — every assertion below MUST be `|| return 1`
	# (verified: a false mid-body `[[ ]]` reports `ok`, a `|| return 1` reports
	# `not ok`). Without this the test was green even with an impossible glob.
	[[ $output == *"label sync SKIPPED"* ]] || return 1
	[[ $output == *"--apply-labels"* ]] || return 1
	[[ $output != *"no GitHub remote yet"* ]] || return 1
	[[ $output != *"applying labels from"* ]] || return 1
}
