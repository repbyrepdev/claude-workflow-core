#!/usr/bin/env bats
# covers: pre-commit-hooks/event-frontmatter-check.sh
#
# Tests for the event-frontmatter parity gate (#70). Verifies the gate
# fires on BOTH consumer-layout (`.claude/hooks/*.sh`) AND plugin-source-
# layout (`hooks/*.sh`) paths, skips opt-out forms, and accepts hooks
# with valid frontmatter.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../pre-commit-hooks/event-frontmatter-check.sh"
	# realpath-normalize so /var ≡ /private/var on macOS — the hook's
	# `git rev-parse --show-toplevel` returns the physical path, and
	# the test's `${f#"$repo_root/"}` strip only works if both sides
	# agree on physical-vs-symlink form.
	TEST_TMP=$(cd "$(mktemp -d -t event-fm.XXXXXX)" && pwd -P) || {
		echo "FATAL: mktemp -d failed" >&2
		return 1
	}
	# Init a real git repo so the hook's `git rev-parse --show-toplevel`
	# branch is exercisable when tests pass absolute paths (covered by
	# the absolute-path test below).
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		git config user.email "test@example.com"
		git config user.name "Test"
	)
}

# Helper: run the script with $TEST_TMP as cwd in a subshell. The cwd
# swap is fully local — bats's `run` doesn't propagate cwd across
# invocations but the explicit subshell makes that contract loud.
_run_from_tmp() {
	(cd "$TEST_TMP" && "$SCRIPT" "$@")
}

teardown() {
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */event-fm.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Helpers
_write_hook_no_frontmatter() {
	local path=$1
	mkdir -p "$(dirname "$TEST_TMP/$path")"
	cat >"$TEST_TMP/$path" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "no frontmatter"
EOF
	chmod +x "$TEST_TMP/$path"
}

_write_hook_with_frontmatter() {
	local path=$1
	local event=$2
	mkdir -p "$(dirname "$TEST_TMP/$path")"
	cat >"$TEST_TMP/$path" <<EOF
#!/bin/bash
set -euo pipefail
# event: $event
echo "valid hook"
EOF
	chmod +x "$TEST_TMP/$path"
}

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

# --- consumer layout: .claude/hooks/*.sh ----------------------------

@test "consumer-layout: missing frontmatter fails" {
	_write_hook_no_frontmatter ".claude/hooks/bad.sh"
	run _run_from_tmp .claude/hooks/bad.sh
	[ "$status" -eq 1 ]
	[[ $output == *"lack required frontmatter"* ]]
}

@test "consumer-layout: valid frontmatter passes" {
	_write_hook_with_frontmatter ".claude/hooks/good.sh" "PreToolUse"
	run _run_from_tmp .claude/hooks/good.sh
	[ "$status" -eq 0 ]
}

# --- plugin-source layout: hooks/*.sh (#70) -------------------------

@test "plugin-source-layout: missing frontmatter fails" {
	# #70 extension: the gate must cover the plugin's own source-tree
	# hooks/ dir, not just consumer .claude/hooks/.
	_write_hook_no_frontmatter "hooks/bad.sh"
	run _run_from_tmp hooks/bad.sh
	[ "$status" -eq 1 ]
	[[ $output == *"lack required frontmatter"* ]]
	[[ $output == *"hooks/bad.sh"* ]]
}

@test "plugin-source-layout: valid frontmatter passes" {
	_write_hook_with_frontmatter "hooks/good.sh" "PreToolUse"
	run _run_from_tmp hooks/good.sh
	[ "$status" -eq 0 ]
}

@test "plugin-source-layout: SessionStart event accepted" {
	_write_hook_with_frontmatter "hooks/session.sh" "SessionStart"
	run _run_from_tmp hooks/session.sh
	[ "$status" -eq 0 ]
}

# --- excluded paths ------------------------------------------------

@test "pre-commit-hooks/*.sh is NOT subject to the gate" {
	# Different lifecycle — pre-commit-hooks/ scripts are registered
	# via entry: in .pre-commit-hooks.yaml, not via # event: frontmatter.
	_write_hook_no_frontmatter "pre-commit-hooks/something.sh"
	run _run_from_tmp pre-commit-hooks/something.sh
	[ "$status" -eq 0 ]
}

@test "filename _*.sh helper opt-out (plugin-source layout)" {
	_write_hook_no_frontmatter "hooks/_helper.sh"
	run _run_from_tmp hooks/_helper.sh
	[ "$status" -eq 0 ]
}

@test "filename install-*.sh installer opt-out (plugin-source layout)" {
	_write_hook_no_frontmatter "hooks/install-something.sh"
	run _run_from_tmp hooks/install-something.sh
	[ "$status" -eq 0 ]
}

@test "explicit auto-register:false opt-out" {
	mkdir -p "$TEST_TMP/hooks"
	cat >"$TEST_TMP/hooks/opt-out.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# auto-register: false
echo "helper called by other hooks"
EOF
	chmod +x "$TEST_TMP/hooks/opt-out.sh"
	run _run_from_tmp hooks/opt-out.sh
	[ "$status" -eq 0 ]
}

# --- event-name validation (gate's second contract) --------------

@test "invalid event name (typo) fails — not just presence" {
	# pr-test-analyzer finding: gate's contract is two-part (frontmatter
	# present + event name in SSOT 6-event set). Tests only exercised
	# the first part. A typo'd event name must also fail.
	mkdir -p "$TEST_TMP/hooks"
	cat >"$TEST_TMP/hooks/typo.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# event: PreCommit
echo "typo'd event name (not in SSOT)"
EOF
	chmod +x "$TEST_TMP/hooks/typo.sh"
	run _run_from_tmp hooks/typo.sh
	[ "$status" -eq 1 ]
	[[ $output == *"lack required frontmatter"* ]]
}

# --- absolute-path normalization branch --------------------------

@test "absolute path inside repo resolves via git rev-parse + applies rules" {
	# pre-existing rev-parse branch (script lines ~55-76) wasn't exercised
	# by any other test — all the others pass relative paths. Locks the
	# absolute-path normalization contract: paths INSIDE the repo
	# resolve to relative form and get checked; paths OUTSIDE the
	# operator's cwd repo are silently skipped (correct — they're not
	# part of the staged set).
	_write_hook_no_frontmatter "hooks/abs.sh"
	# Run with cwd inside TEST_TMP so the script's `git rev-parse
	# --show-toplevel` resolves to TEST_TMP, making the absolute path a
	# valid in-repo file for normalization.
	run _run_from_tmp "$TEST_TMP/hooks/abs.sh"
	[ "$status" -eq 1 ]
	[[ $output == *"lack required frontmatter"* ]]
	[[ $output == *"hooks/abs.sh"* ]]
}

# --- nested paths (documented behavior) ---------------------------

@test "nested hooks/subdir/*.sh IS checked (bash case * matches slashes)" {
	# pr-test-analyzer finding: bash `case 'hooks/sub/x.sh' in hooks/*.sh)`
	# DOES match — case-statement glob `*` is not pathname expansion
	# and DOES traverse slashes (unlike shell pathname globbing).
	# Document the actual behavior: nested hooks ARE checked.
	_write_hook_no_frontmatter "hooks/nested/x.sh"
	run _run_from_tmp hooks/nested/x.sh
	[ "$status" -eq 1 ]
	[[ $output == *"lack required frontmatter"* ]]
}

# --- EVENT_FRONTMATTER_SKIP bypass --------------------------------

@test "EVENT_FRONTMATTER_SKIP=1 bypasses with stderr warning" {
	_write_hook_no_frontmatter "hooks/missing.sh"
	# Set via export because `env VAR=1 _run_from_tmp` would fail —
	# env exec's a real program, not a shell function.
	export EVENT_FRONTMATTER_SKIP=1
	run _run_from_tmp hooks/missing.sh
	unset EVENT_FRONTMATTER_SKIP
	[ "$status" -eq 0 ]
	[[ $output == *"SKIP via EVENT_FRONTMATTER_SKIP"* ]]
}

# --- #2547 enforcement classification (PostToolUse only) ----------------------
# Moved here from posttooluse-enforcement-contract.bats (phase1 r2
# code-reviewer: this suite is the pre-existing home for gate-rule tests —
# a maintainer changing the gate finds one suite, not two). The contract
# file keeps the live-tree audit.

_write_ptu_hook() {
	# $1=path  $2=extra frontmatter line (empty for none)
	mkdir -p "$(dirname "$TEST_TMP/$1")"
	{
		printf '#!/bin/bash\nset -u\n# event: PostToolUse\n# matcher: Bash\n'
		[ -n "$2" ] && printf '%s\n' "$2"
		printf 'exit 0\n'
	} >"$TEST_TMP/$1"
	chmod +x "$TEST_TMP/$1"
}

@test "#2547 PostToolUse hook with NO enforcement classification fails" {
	_write_ptu_hook "hooks/uncls.sh" ""
	run _run_from_tmp hooks/uncls.sh
	[ "$status" -eq 1 ]
	[[ $output == *"enforce-vs-inform"* ]]
}

@test "#2547 enforcement value OUTSIDE the vocabulary fails (enum, not presence)" {
	# Same property the event enum pins: loosening the accessor to accept
	# any value must turn this red (phase1 r2 pr-test-analyzer).
	_write_ptu_hook "hooks/advisory.sh" "# enforcement: advisory — not a real value"
	run _run_from_tmp hooks/advisory.sh
	[ "$status" -eq 1 ]
	[[ $output == *"enforce-vs-inform"* ]]
}

@test "#2547 enforce AND inform values both pass; non-PostToolUse needs none" {
	_write_ptu_hook "hooks/enf.sh" "# enforcement: enforce — fixture"
	_write_ptu_hook "hooks/inf.sh" "# enforcement: inform — fixture"
	_write_hook_with_frontmatter "hooks/pre.sh" "PreToolUse"
	run _run_from_tmp hooks/enf.sh hooks/inf.sh hooks/pre.sh
	[ "$status" -eq 0 ]
}

@test "#2547 MIXED batch reports BOTH failure classes in one pass" {
	# phase1 r2, three reviewers independently: the early exit hid the
	# frontmatter failure behind the classification failure, forcing a
	# two-pass fix cycle.
	_write_ptu_hook "hooks/uncls2.sh" ""
	_write_hook_no_frontmatter "hooks/bare.sh"
	run _run_from_tmp hooks/uncls2.sh hooks/bare.sh
	[ "$status" -eq 1 ]
	[[ $output == *"enforce-vs-inform"* ]] || {
		echo "classification failure not reported. output: $output"
		return 1
	}
	[[ $output == *"lack required frontmatter"* ]] || {
		echo "frontmatter failure hidden behind the classification exit — two-pass cycle is back. output: $output"
		return 1
	}
}

@test "#2547 ENFORCEMENT_FRONTMATTER_SKIP=1 bypasses ONLY the classification rule" {
	_write_ptu_hook "hooks/uncls3.sh" ""
	_write_hook_no_frontmatter "hooks/bare2.sh"
	run env ENFORCEMENT_FRONTMATTER_SKIP=1 bash -c "cd '$TEST_TMP' && '$SCRIPT' hooks/uncls3.sh hooks/bare2.sh"
	[ "$status" -eq 1 ] || {
		echo "narrow bypass disabled the event rule too (rc=$status). output: $output"
		return 1
	}
	[[ $output == *"lack required frontmatter"* ]]
	[[ $output != *"enforce-vs-inform"* ]] || {
		echo "classification still enforced under its own bypass. output: $output"
		return 1
	}
}
