#!/usr/bin/env bats
# covers: scripts/migrate-label.sh
#
# Tests the four-site label rename (#2288): .github/labels.yml name,
# .github/labeler.yml key, .coderabbit.overlay.yaml labeling_instructions
# label, and the `gh label edit` API call. Verifies dry-run safety,
# idempotency, partial-state completion, arg/precondition guards, and the
# gh-step skip/invoke logic via a hermetic gh stub.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/migrate-label.sh"
	TEST_TMP=$(mktemp -d -t migrate-label.XXXXXX) || {
		echo "FATAL: mktemp -d failed" >&2
		return 1
	}
	# Hermetic gh stub: `label list` cats $GH_LABELS (one name/line, default
	# empty); `label edit` logs args to $GH_LOG and exits 0. Keeps step 4
	# deterministic + offline.
	mkdir -p "$TEST_TMP/bin"
	cat >"$TEST_TMP/bin/gh" <<'EOF'
#!/bin/bash
if [ "$1" = "label" ] && [ "$2" = "list" ]; then
	cat "${GH_LABELS:-/dev/null}" 2>/dev/null
	exit 0
fi
if [ "$1" = "label" ] && [ "$2" = "edit" ]; then
	shift 2
	echo "edit $*" >>"${GH_LOG:-/dev/null}"
	exit 0
fi
exit 0
EOF
	chmod +x "$TEST_TMP/bin/gh"
	export PATH="$TEST_TMP/bin:$PATH"
	export GH_LOG="$TEST_TMP/gh.log"
	(
		set -e
		cd "$TEST_TMP"
		git init -q -b main
		git config user.email t@t
		git config user.name t
		mkdir -p .github
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
}

teardown() {
	unset GH_LABELS GH_LOG
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */migrate-label.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Write the three SSOT files with area:infra present in each.
_seed() {
	local old="area:infra"
	printf -- '- name: "%s"\n  color: "ededed"\n  description: d\n- name: "type:bug"\n  color: "d73a4a"\n  description: b\n' "$old" >"$TEST_TMP/.github/labels.yml"
	printf -- '%s:\n  - changed-files:\n      - any-glob-to-any-file: "scripts/**"\ntype:bug:\n  - changed-files:\n      - any-glob-to-any-file: "**"\n' "$old" >"$TEST_TMP/.github/labeler.yml"
	printf -- 'reviews:\n  labeling_instructions:\n    - label: "%s"\n      instructions: "use for %s"\n' "$old" "$old" >"$TEST_TMP/.coderabbit.overlay.yaml"
}

# --- arg / precondition guards ----------------------------------------

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

@test "--help shows usage and exit codes" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"Usage:"* ]]
	[[ $output == *"Exit codes:"* ]]
}

@test "missing --old/--new => exit 2" {
	cd "$TEST_TMP"
	run "$SCRIPT" --old area:infra
	[ "$status" -eq 2 ]
	[[ $output == *"both --old and --new are required"* ]]
}

@test "identical --old --new => exit 2" {
	cd "$TEST_TMP"
	run "$SCRIPT" --old x --new x
	[ "$status" -eq 2 ]
	[[ $output == *"identical"* ]]
}

@test "unknown arg => exit 2" {
	cd "$TEST_TMP"
	run "$SCRIPT" --old a --new b --bogus
	[ "$status" -eq 2 ]
	[[ $output == *"unknown arg"* ]]
}

@test "not a git working tree => exit 2" {
	NOGIT=$(mktemp -d -t migrate-label.XXXXXX)
	cd "$NOGIT"
	run "$SCRIPT" --old area:infra --new area:infrastructure
	rm -rf "$NOGIT"
	[ "$status" -eq 2 ]
	[[ $output == *"not in a git working tree"* ]]
}

# --- dry-run safety ---------------------------------------------------

@test "dry-run announces all sites and changes nothing" {
	cd "$TEST_TMP"
	_seed
	run "$SCRIPT" --old area:infra --new area:infrastructure --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"dry-run"* ]]
	[[ $output == *"labels.yml: rename name"* ]]
	[[ $output == *"labeler.yml: rename key"* ]]
	[[ $output == *"overlay: rename labeling_instructions"* ]]
	# Files untouched.
	[ "$(yq -r '.[0].name' .github/labels.yml)" = "area:infra" ]
	yq -e '.["area:infra"]' .github/labeler.yml >/dev/null
	[ "$(yq -r '.reviews.labeling_instructions[0].label' .coderabbit.overlay.yaml)" = "area:infra" ]
}

# --- apply: each site -------------------------------------------------

@test "apply renames labels.yml name field" {
	cd "$TEST_TMP"
	_seed
	run "$SCRIPT" --old area:infra --new area:infrastructure
	[ "$status" -eq 0 ]
	run yq -r '.[].name' .github/labels.yml
	[[ $output == *"area:infrastructure"* ]]
	# Key assertion last: area:infra must be fully gone (exact-match).
	run yq -e '.[] | select(.name == "area:infra")' .github/labels.yml
	[ "$status" -ne 0 ]
}

@test "apply renames labeler.yml key" {
	cd "$TEST_TMP"
	_seed
	run "$SCRIPT" --old area:infra --new area:infrastructure
	[ "$status" -eq 0 ]
	yq -e '.["area:infrastructure"]' .github/labeler.yml >/dev/null
	run yq -e '.["area:infra"]' .github/labeler.yml
	[ "$status" -ne 0 ]
}

@test "apply renames overlay labeling_instructions label" {
	cd "$TEST_TMP"
	_seed
	run "$SCRIPT" --old area:infra --new area:infrastructure
	[ "$status" -eq 0 ]
	run yq -r '.reviews.labeling_instructions[].label' .coderabbit.overlay.yaml
	[ "$output" = "area:infrastructure" ]
}

# --- idempotency + partial state --------------------------------------

@test "idempotent re-run skips all and exits 0" {
	cd "$TEST_TMP"
	_seed
	"$SCRIPT" --old area:infra --new area:infrastructure
	run "$SCRIPT" --old area:infra --new area:infrastructure
	[ "$status" -eq 0 ]
	[[ $output == *"labels.yml: area:infra absent — skip"* ]]
	[[ $output == *"labeler.yml: area:infra absent — skip"* ]]
	[[ $output == *"overlay: area:infra absent — skip"* ]]
}

@test "partial state (only labels.yml has old) completes that site, skips the rest" {
	cd "$TEST_TMP"
	# Only labels.yml carries the old name; labeler+overlay already migrated.
	printf -- '- name: "area:infra"\n  color: "ededed"\n  description: d\n' >.github/labels.yml
	printf -- 'area:infrastructure:\n  - changed-files:\n      - any-glob-to-any-file: "x"\n' >.github/labeler.yml
	printf -- 'reviews:\n  labeling_instructions:\n    - label: "area:infrastructure"\n      instructions: x\n' >.coderabbit.overlay.yaml
	run "$SCRIPT" --old area:infra --new area:infrastructure
	[ "$status" -eq 0 ]
	[[ $output == *"labels.yml: rename name"* ]]
	[[ $output == *"labeler.yml: area:infra absent — skip"* ]]
	[[ $output == *"overlay: area:infra absent — skip"* ]]
	run yq -e '.[] | select(.name == "area:infra")' .github/labels.yml
	[ "$status" -ne 0 ]
}

# --- gh label step ----------------------------------------------------

@test "gh label edit invoked when old exists and new absent" {
	cd "$TEST_TMP"
	_seed
	printf 'area:infra\ntype:bug\n' >"$TEST_TMP/labels.txt"
	GH_LABELS="$TEST_TMP/labels.txt" run "$SCRIPT" --old area:infra --new area:infrastructure
	[ "$status" -eq 0 ]
	[[ $output == *"gh label: edit area:infra --name area:infrastructure"* ]]
	grep -qx "edit area:infra --name area:infrastructure" "$GH_LOG"
}

@test "gh label skipped when new already exists" {
	cd "$TEST_TMP"
	_seed
	printf 'area:infra\narea:infrastructure\n' >"$TEST_TMP/labels.txt"
	GH_LABELS="$TEST_TMP/labels.txt" run "$SCRIPT" --old area:infra --new area:infrastructure
	[ "$status" -eq 0 ]
	[[ $output == *"area:infrastructure already exists"* ]]
	[ ! -s "$GH_LOG" ]
}

@test "gh label dry-run announces edit without invoking it" {
	cd "$TEST_TMP"
	_seed
	printf 'area:infra\n' >"$TEST_TMP/labels.txt"
	GH_LABELS="$TEST_TMP/labels.txt" run "$SCRIPT" --old area:infra --new area:infrastructure --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"would: gh label: edit area:infra"* ]]
	[ ! -s "$GH_LOG" ]
}
