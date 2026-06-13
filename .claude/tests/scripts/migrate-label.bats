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
	if [ "${GH_FAIL:-0}" = "1" ]; then
		echo "gh: api error (stub)" >&2
		exit 4
	fi
	cat "${GH_LABELS:-/dev/null}" 2>/dev/null
	exit 0
fi
if [ "$1" = "label" ] && [ "$2" = "edit" ]; then
	shift 2
	echo "edit $*" >>"${GH_LOG:-/dev/null}"
	exit 0
fi
echo "migrate-label stub: unexpected gh invocation: $*" >&2
exit 1
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
	unset GH_LABELS GH_LOG GH_FAIL
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/tmp}" 2>/dev/null || true
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

@test "script is executable and runs (--help exits 0 with usage)" {
	[ -x "$SCRIPT" ]
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"Usage:"* ]]
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
	[[ $output == *"type:bug"* ]] # sibling entry untouched
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
	yq -e '.["type:bug"]' .github/labeler.yml >/dev/null # sibling key untouched
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

@test "gh label skipped when OLD is not a GitHub label" {
	cd "$TEST_TMP"
	_seed
	printf 'type:bug\nsomething-else\n' >"$TEST_TMP/labels.txt" # no area:infra
	GH_LABELS="$TEST_TMP/labels.txt" run "$SCRIPT" --old area:infra --new area:infrastructure
	[ "$status" -eq 0 ]
	[[ $output == *"area:infra not a GitHub label — skip"* ]]
	[ ! -s "$GH_LOG" ]
}

@test "gh label list failure exits 2 (no silent success)" {
	cd "$TEST_TMP"
	_seed
	GH_FAIL=1 run "$SCRIPT" --old area:infra --new area:infrastructure
	[ "$status" -eq 2 ]
	[[ $output == *"gh label list failed"* ]]
	[ ! -s "$GH_LOG" ]
}

@test "renames a label containing dot/glob-special chars" {
	cd "$TEST_TMP"
	printf -- '- name: "dep:foo.bar"\n  color: "ededed"\n  description: d\n' >.github/labels.yml
	printf -- 'dep:foo.bar:\n  - changed-files:\n      - any-glob-to-any-file: "x"\n' >.github/labeler.yml
	printf -- 'reviews:\n  labeling_instructions:\n    - label: "dep:foo.bar"\n      instructions: x\n' >.coderabbit.overlay.yaml
	run "$SCRIPT" --old "dep:foo.bar" --new "dep:foobar"
	[ "$status" -eq 0 ]
	yq -e '.[] | select(.name == "dep:foobar")' .github/labels.yml >/dev/null
	yq -e '.["dep:foobar"]' .github/labeler.yml >/dev/null
	[ "$(yq -r '.reviews.labeling_instructions[].label' .coderabbit.overlay.yaml)" = "dep:foobar" ]
	# Key assertion last: dotted old key fully gone (indexed access, not a path).
	run yq -e '.["dep:foo.bar"]' .github/labeler.yml
	[ "$status" -ne 0 ]
}

@test "overlay rename touches only the matching labeling_instructions entry" {
	cd "$TEST_TMP"
	printf -- '- name: "area:infra"\n  color: "ededed"\n  description: d\n' >.github/labels.yml
	printf -- 'area:infra:\n  - changed-files:\n      - any-glob-to-any-file: "x"\n' >.github/labeler.yml
	printf -- 'reviews:\n  labeling_instructions:\n    - label: "area:infra"\n      instructions: a\n    - label: "type:bug"\n      instructions: b\n' >.coderabbit.overlay.yaml
	run "$SCRIPT" --old area:infra --new area:infrastructure
	[ "$status" -eq 0 ]
	run yq -r '.reviews.labeling_instructions[].label' .coderabbit.overlay.yaml
	[[ $output == *"area:infrastructure"* ]]
	[[ $output == *"type:bug"* ]] # non-matching entry untouched
	# Key assertion last: the matched label is renamed, no stale area:infra left.
	run yq -e '.reviews.labeling_instructions[] | select(.label == "area:infra")' .coderabbit.overlay.yaml
	[ "$status" -ne 0 ]
}

@test "absent required SSOT file => exit 2 (no silent no-op)" {
	cd "$TEST_TMP"
	# labels.yml + overlay present, labeler.yml absent → precondition error.
	printf -- '- name: "area:infra"\n  color: "ededed"\n  description: d\n' >.github/labels.yml
	printf -- 'reviews:\n  labeling_instructions:\n    - label: "area:infra"\n      instructions: a\n' >.coderabbit.overlay.yaml
	run "$SCRIPT" --old area:infra --new area:infrastructure
	[ "$status" -eq 2 ]
	[[ $output == *"required SSOT .github/labeler.yml is absent"* ]]
}

@test "gh not installed => file edits apply, API rename skipped, exit 0" {
	cd "$TEST_TMP"
	_seed
	# Build a PATH carrying the script's real tool deps but NO gh, so the
	# `command -v gh` fallback branch is exercised (the gh stub is otherwise
	# always on PATH). PATH override (not env -i) keeps HOME/git config intact.
	mkdir -p "$TEST_TMP/nogh"
	local t p
	for t in bash yq git grep sed awk cat; do
		p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$TEST_TMP/nogh/$t"
	done
	run env PATH="$TEST_TMP/nogh" "$SCRIPT" --old area:infra --new area:infrastructure
	[ "$status" -eq 0 ]
	[[ $output == *"gh not installed — skip API rename"* ]]
	# File edits still applied despite no gh.
	yq -e '.[] | select(.name == "area:infrastructure")' .github/labels.yml >/dev/null
}
