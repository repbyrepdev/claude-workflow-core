#!/usr/bin/env bats
# covers: hooks/issue-before-code.sh
#
# #2416 creation-time branch-convention + issue-lineage gate. PreToolUse Bash
# hook that refuses `git checkout -b` / `git switch -c` for malformed work-
# branch names (ALL types now, not just feat/) and for valid names whose issue
# doesn't exist or isn't assigned to the operator. The convention is sourced
# from the SSOT (_lib/branch-convention.sh) — these tests lock the decision
# matrix end-to-end:
#   malformed (chore/labels/2289-x; old dash vX.Y-Z form)  → deny
#   scratch (no <type>/ prefix) / non-branch command       → allow
#   inline ISSUE_BEFORE_CODE_SKIP sentinel                  → allow (bypass)
#   valid + issue missing on GitHub                         → deny (not found)
#   valid + issue exists + assigned @me                     → allow
#   valid + issue exists but NOT assigned                   → deny
#   transient gh failure                                    → allow (fail-open)
#
# Hermetic: a stub `gh` on PATH drives the existence/assignment/transient
# outcomes. The REAL hook runs so its `../_lib/*.sh` resolves the real SSOT +
# deny/sentinel libs (exercising the real permissionDecision:deny path).

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/issue-before-code.sh"
	[ -f "$HOOK" ]
	TEST_TMP=$(mktemp -d -t ibc.XXXXXX) || return 1
	mkdir -p "$TEST_TMP/bin"
	export PATH="$TEST_TMP/bin:$PATH"
	# Default gh poison: any gh call fails loudly so decisions made BEFORE gh
	# (malformed/scratch/bypass) can't silently depend on the network. gh-path
	# tests override via _stub_gh.
	cat >"$TEST_TMP/bin/gh" <<'POISON'
#!/bin/bash
echo "ibc-test: gh called unexpectedly: $*" >&2
exit 97
POISON
	chmod +x "$TEST_TMP/bin/gh"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */ibc.* ]] && rm -rf "$TEST_TMP"
	return 0
}

# Install a gh stub. $1 = mode: assigned|unassigned|notfound|transient
_stub_gh() {
	local mode="$1"
	cat >"$TEST_TMP/bin/gh" <<EOF
#!/bin/bash
if [ "\$1" = "api" ]; then echo "me"; exit 0; fi
if [ "\$1" = "issue" ] && [ "\$2" = "view" ]; then
	case "$mode" in
	assigned) printf '%s' '{"assignees":[{"login":"me"}]}'; exit 0 ;;
	unassigned) printf '%s' '{"assignees":[]}'; exit 0 ;;
	notfound) echo "GraphQL: Could not resolve to an issue or pull request with the number" >&2; exit 1 ;;
	transient) echo "error connecting to api.github.com" >&2; exit 1 ;;
	esac
fi
echo "ibc-stub: unexpected gh \$*" >&2
exit 1
EOF
	chmod +x "$TEST_TMP/bin/gh"
}

# Run the hook with a tool_input.command payload built safely via jq.
_run_hook() {
	local cmd="$1" payload
	payload=$(jq -nc --arg c "$cmd" '{tool_input: {command: $c}}')
	run bash -c 'printf "%s" "$1" | "$2" 2>&1' _ "$payload" "$HOOK"
}

# --- malformed work branch → deny ---

@test "REGRESSION #2289: chore/labels/2289-x denied at creation" {
	_run_hook "git checkout -b chore/labels/2289-area-infra-normalize"
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "old dash version form (feat/v0.34-W/...) denied (converged out)" {
	_run_hook "git checkout -b feat/v0.34-W/708-x"
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "git switch -c malformed work branch also denied" {
	_run_hook "git switch -c fix/badversion/5-x"
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

# --- scratch / non-branch → allow ---

@test "scratch name (no <type>/ prefix) allowed" {
	_run_hook "git checkout -b myquickfix"
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

@test "non-branch-creation command allowed (no false positive)" {
	_run_hook "ls -la"
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

# --- bypass sentinel → allow ---

@test "inline ISSUE_BEFORE_CODE_SKIP bypasses a malformed name" {
	_run_hook 'ISSUE_BEFORE_CODE_SKIP=1 ISSUE_BEFORE_CODE_SKIP_REASON="test" git checkout -b chore/labels/2289-x'
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

# --- valid branch → issue existence + assignment via stub gh ---

@test "valid branch + issue exists + assigned @me → allow" {
	_stub_gh assigned
	_run_hook "git checkout -b feat/v0.34.73/2416-branch-convention-ssot"
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

@test "valid branch + issue missing on GitHub → deny (and names the extracted issue)" {
	_stub_gh notfound
	_run_hook "git checkout -b feat/v0.34.73/12345-phantom"
	[[ $output == *'"permissionDecision":"deny"'* ]]
	# proves branch_convention_extract_issue fed the right number through
	[[ $output == *'12345'* ]]
}

@test "valid branch + issue exists but NOT assigned → deny" {
	_stub_gh unassigned
	_run_hook "git checkout -b feat/v0.34.73/2416-x"
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "valid branch + transient gh failure → allow (fail-open)" {
	_stub_gh transient
	_run_hook "git checkout -b feat/v0.34.73/2416-x"
	[[ $output != *'"permissionDecision":"deny"'* ]]
}
