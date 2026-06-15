#!/usr/bin/env bats
# covers: hooks/issue-before-code.sh
#
# #2416 creation-time branch-convention + issue-lineage gate. PreToolUse Bash
# hook that refuses `git checkout -b|-B` / `git switch -c|-C|--create` for
# malformed work-branch names (ALL types now, not just feat/) and for valid
# names whose issue doesn't exist or isn't assigned to the operator. Convention
# is sourced from the SSOT (_lib/branch-convention.sh); the missing-vs-transient
# gh classification from _lib/gh-issue-classify.sh. These tests lock the
# decision matrix end-to-end:
#   malformed (chore/labels/2289-x; old dash form; force-create verbs)  → deny
#   scratch (no <type>/ prefix) / non-branch command                    → allow
#   inline ISSUE_BEFORE_CODE_SKIP sentinel                              → allow (bypass)
#   valid + issue missing on GitHub                                     → deny (not found)
#   valid + issue exists + assigned @me                                → allow
#   valid + issue exists but NOT assigned                              → deny
#   valid + transient gh failure (incl DNS-host) / gh absent / jq fail → allow (fail-open)
#
# Hermetic: a stub `gh` on PATH drives the gh-dependent outcomes. The REAL hook
# runs so its `../_lib/*.sh` resolves the real SSOTs + deny/sentinel libs
# (exercising the real permissionDecision:deny path). EVERY test asserts
# `$status -eq 0` (the hook always exits 0 — deny is signalled via JSON, not a
# non-zero rc), so a crash that merely fails to print the deny JSON, or one that
# crashes after printing it, can't pass spuriously (repo memory: the bats
# negative-assertion trap).

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

# Install a gh stub. $1 = mode controlling the `issue view` + `api user` arms.
# Both arms match BOTH argv positions (api user / issue view) to mirror the
# exact calls the hook makes and to catch an arg-shape regression in the stub.
_stub_gh() {
	local mode="$1"
	cat >"$TEST_TMP/bin/gh" <<EOF
#!/bin/bash
if [ "\$1" = "api" ] && [ "\$2" = "user" ]; then
	case "$mode" in
	apifail) echo "gh: HTTP 401 auth error" >&2; exit 1 ;;
	emptylogin) printf '' ; exit 0 ;;
	*) echo "me"; exit 0 ;;
	esac
fi
if [ "\$1" = "issue" ] && [ "\$2" = "view" ]; then
	case "$mode" in
	assigned) printf '%s' '{"assignees":[{"login":"me"}]}'; exit 0 ;;
	unassigned) printf '%s' '{"assignees":[]}'; exit 0 ;;
	notfound) echo "GraphQL: Could not resolve to an issue or pull request with the number" >&2; exit 1 ;;
	dnshost) echo "fatal: unable to access: Could not resolve host: api.github.com" >&2; exit 1 ;;
	transient) echo "error connecting to api.github.com port 443: Connection refused" >&2; exit 1 ;;
	badjson) printf '%s' 'NOT VALID JSON'; exit 0 ;;
	*) printf '%s' '{"assignees":[{"login":"me"}]}'; exit 0 ;;
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

# --- malformed work branch → deny (hook still exits 0; deny is via JSON) ---

@test "REGRESSION #2289: chore/labels/2289-x denied at creation" {
	_run_hook "git checkout -b chore/labels/2289-area-infra-normalize"
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "old dash version form (feat/v0.34-W/...) denied (converged out)" {
	_run_hook "git checkout -b feat/v0.34-W/708-x"
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "git switch -c malformed work branch also denied" {
	_run_hook "git switch -c fix/badversion/5-x"
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "git checkout -B (force-create) malformed denied" {
	_run_hook "git checkout -B chore/labels/2289-x"
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "git switch --create malformed denied" {
	_run_hook "git switch --create fix/badversion/5-x"
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "trailing-dash slug denied (kebab-case violation)" {
	_run_hook "git checkout -b feat/v1.2.3/5-foo-"
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

# --- scratch / non-branch → allow ---

@test "scratch name (no <type>/ prefix) allowed" {
	_run_hook "git checkout -b myquickfix"
	[ "$status" -eq 0 ]
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

@test "non-branch-creation command allowed (no false positive)" {
	_run_hook "ls -la"
	[ "$status" -eq 0 ]
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

# --- bypass sentinel → allow ---

@test "inline ISSUE_BEFORE_CODE_SKIP bypasses a malformed name" {
	_run_hook 'ISSUE_BEFORE_CODE_SKIP=1 ISSUE_BEFORE_CODE_SKIP_REASON="test" git checkout -b chore/labels/2289-x'
	[ "$status" -eq 0 ]
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

# --- valid branch → issue existence + assignment via stub gh ---

@test "valid branch + issue exists + assigned @me → allow" {
	_stub_gh assigned
	_run_hook "git checkout -b feat/v0.34.73/2416-branch-convention-ssot"
	[ "$status" -eq 0 ]
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

@test "valid branch + issue missing on GitHub → deny (and names the extracted issue)" {
	_stub_gh notfound
	_run_hook "git checkout -b feat/v0.34.73/12345-phantom"
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
	# proves branch_convention_extract_issue fed the right number through
	[[ $output == *'12345'* ]]
}

@test "valid branch + issue exists but NOT assigned → deny" {
	_stub_gh unassigned
	_run_hook "git checkout -b feat/v0.34.73/2416-x"
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

# --- fail-open paths (all must ALLOW, and exit 0) ---

@test "valid + transient gh failure → allow (fail-open)" {
	_stub_gh transient
	_run_hook "git checkout -b feat/v0.34.73/2416-x"
	[ "$status" -eq 0 ]
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

@test "REGRESSION: valid + DNS-host gh error → allow (NOT false not-found deny)" {
	# The pre-#2416-r2 classifier matched 'Could not resolve' and would deny a
	# DNS blip as 'issue not found'. The shared classifier must skip it.
	_stub_gh dnshost
	_run_hook "git checkout -b feat/v0.34.73/2416-x"
	[ "$status" -eq 0 ]
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

@test "valid + gh api user fails → allow (fail-open)" {
	_stub_gh apifail
	_run_hook "git checkout -b feat/v0.34.73/2416-x"
	[ "$status" -eq 0 ]
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

@test "valid + gh api user returns empty login → allow (fail-open)" {
	_stub_gh emptylogin
	_run_hook "git checkout -b feat/v0.34.73/2416-x"
	[ "$status" -eq 0 ]
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

@test "valid + malformed assignees JSON (jq fails) → allow (fail-open)" {
	_stub_gh badjson
	_run_hook "git checkout -b feat/v0.34.73/2416-x"
	[ "$status" -eq 0 ]
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

@test "valid + gh absent on PATH → allow (fail-open)" {
	# Isolated bin with the tools the hook needs EXCEPT gh, so `command -v gh`
	# fails and the gh-absent guard (not the transient path) is exercised.
	# This list mirrors the external commands hooks/issue-before-code.sh invokes
	# BEFORE the gh-absent exit (cat→PAYLOAD, jq→CMD, dirname→HOOK_DIR,
	# grep/sed/head→BRANCH extract; mktemp is only reached on the gh path). It
	# MUST be kept in sync if the hook starts using a new external tool before
	# that exit — otherwise this test would crash on a missing tool, not the
	# intended fail-open.
	local gobin="$TEST_TMP/nogh" t src
	mkdir -p "$gobin"
	for t in cat jq grep sed head mktemp dirname; do
		src=$(command -v "$t") && ln -sf "$src" "$gobin/$t"
	done
	local payload
	payload=$(jq -nc --arg c "git checkout -b feat/v0.34.73/2416-x" '{tool_input: {command: $c}}')
	# Invoke the hook directly (its #!/bin/bash shebang is absolute, so the
	# interpreter resolves regardless of PATH) with PATH scrubbed of gh; feed the
	# payload via herestring. A `bash -c` wrapper would itself need bash on PATH.
	run env PATH="$gobin" "$HOOK" <<<"$payload"
	[ "$status" -eq 0 ]
	[[ $output != *'"permissionDecision":"deny"'* ]]
}
