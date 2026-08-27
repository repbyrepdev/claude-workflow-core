#!/usr/bin/env bats
# covers: hooks/pre-merge-cr-comments-gate.sh
#
# #2292: PreToolUse Bash gate that intercepts `gh pr merge` and refuses while
# the target PR has unresolved CodeRabbit findings (delegated to the
# _pr-cr-findings.sh helper). Non-merge commands pass through; the PR number is
# extracted from `gh pr merge <N>` / `--pr <N>` / current branch; missing PR or
# missing helper fail closed; PRE_MERGE_CR_GATE_SKIP=1 in the command preamble
# bypasses (audit-logged). bash-3.2 compatible (no mapfile).
#
# Isolation: symlink the real hook + real _lib helpers into a sandbox
# .claude/ tree so HOOK_DIR/../_lib and REPO_ROOT/.claude/hooks both resolve
# inside the sandbox; the CR-findings helper is a stub whose exit code we
# control; a no-op gh stub on PATH keeps the branch-fallback hermetic.

setup() {
	local hooks libs
	hooks=$(cd "${BATS_TEST_DIRNAME}/../../../hooks" && pwd)
	libs=$(cd "${BATS_TEST_DIRNAME}/../../../_lib" && pwd)
	REAL_SCRIPT="$hooks/pre-merge-cr-comments-gate.sh"
	[ -f "$REAL_SCRIPT" ]
	TEST_TMP=$(cd "$(mktemp -d -t pre-merge-cr-gate.XXXXXX)" && pwd -P) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		git config user.email t@t.t
		git config user.name t
		git commit -q --allow-empty -m seed
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
	mkdir -p "$TEST_TMP/.claude/hooks" "$TEST_TMP/.claude/_lib" "$TEST_TMP/bin"
	ln -s "$REAL_SCRIPT" "$TEST_TMP/.claude/hooks/guard.sh"
	ln -s "$libs/hook-deny.sh" "$TEST_TMP/.claude/_lib/hook-deny.sh"
	ln -s "$libs/hook-inline-sentinel.sh" "$TEST_TMP/.claude/_lib/hook-inline-sentinel.sh"
	ln -s "$libs/cmd-anchor.sh" "$TEST_TMP/.claude/_lib/cmd-anchor.sh"
	SCRIPT="$TEST_TMP/.claude/hooks/guard.sh"
	# No-op gh: the only gh call is the no-PR-number branch fallback; an empty
	# result drives the "could not extract PR number" path deterministically.
	printf '#!/bin/bash\n' >"$TEST_TMP/bin/gh"
	chmod +x "$TEST_TMP/bin/gh"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [[ $TEST_TMP == */pre-merge-cr-gate.* ]] && rm -rf "$TEST_TMP"
}

# Install the CR-findings stub helper. $1 = exit code (0 = clean, non-0 = findings).
_install_helper() {
	local h="$TEST_TMP/.claude/hooks/_pr-cr-findings.sh"
	cat >"$h" <<EOF
#!/bin/bash
echo "stub _pr-cr-findings: PR=\$1 findings-rc=${1:-0}" >&2
exit ${1:-0}
EOF
	chmod +x "$h"
}

# Run the gate with a Bash command. $1=command, $2..=env assignments. stderr merged.
_run_gate() {
	local cmd=$1
	shift
	local payload
	payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
	(cd "$TEST_TMP" && printf '%s' "$payload" |
		env PATH="$TEST_TMP/bin:$PATH" "$@" bash "$SCRIPT" 2>&1)
}

# Run the gate with RAW (already-built / malformed) stdin instead of a wrapped
# command — for the non-JSON fail-closed path.
_run_gate_raw() {
	(cd "$TEST_TMP" && printf '%s' "$1" |
		env PATH="$TEST_TMP/bin:$PATH" bash "$SCRIPT" 2>&1)
}

# Make the on-PATH gh stub echo a fixed PR number for the branch fallback.
_gh_returns() {
	printf '#!/bin/bash\necho "%s"\n' "$1" >"$TEST_TMP/bin/gh"
	chmod +x "$TEST_TMP/bin/gh"
}

@test "real hook script exists and is executable" {
	[ -x "$REAL_SCRIPT" ]
}

@test "non-merge command passes through (exit 0)" {
	_install_helper 1 # would deny IF it ran — proves it does not
	run _run_gate "gh pr view 42"
	[ "$status" -eq 0 ]
	[[ $output != *deny* ]]
}

@test "empty command passes through (exit 0)" {
	run _run_gate ""
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "gh pr merge <N> with a CLEAN PR → allowed (exit 0)" {
	_install_helper 0
	run _run_gate "gh pr merge 42 --squash"
	[ "$status" -eq 0 ]
	[[ $output != *deny* ]]
}

@test "gh pr merge <N> with UNRESOLVED findings → DENIED" {
	_install_helper 1
	run _run_gate "gh pr merge 42 --squash"
	# Real hook_deny: deny-JSON + exit 0. Assert the decision, the findings
	# reason, AND that the extracted PR number surfaced.
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]] || return 1
	# UNADDRESSED, not "unresolved" (#2548): a thread carrying an evidence
	# reply is `replied-awaiting-CR` and does NOT block, so the refusal has to
	# name the class it actually means.
	[[ $output == *"UNADDRESSED CodeRabbit findings"* ]] || return 1
	[[ $output == *"#42"* ]] || return 1
	# The three resolutions must be spelled out — a refusal that does not say
	# what to do next is how #2540 and #2635 stalled.
	[[ $output == *"thread-reply.sh"* ]] || return 1
	[[ $output == *"resolve-stranded.sh"* ]] || return 1
	# And the standing rule survives the rewrite.
	[[ $output == *"NEVER resolve a CR thread by hand"* ]]
}

@test "gh pr merge --pr <N> form → PR number extracted (DENIED on findings)" {
	_install_helper 1
	run _run_gate "gh pr merge --pr 42 --squash"
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]] || return 1
	[[ $output == *"#42"* ]]
}

@test "PRE_MERGE_CR_GATE_SKIP=1 preamble → bypass before the helper runs" {
	_install_helper 1 # would deny — the bypass must short-circuit first
	run _run_gate "PRE_MERGE_CR_GATE_SKIP=1 gh pr merge 42"
	[ "$status" -eq 0 ]
	[[ $output == *bypassing* ]] || return 1
	[[ $output != *deny* ]] || return 1
	# The "audit-logged" guarantee is real: the sentinel helper writes a JSONL
	# record (path derived from the prefix by hook-inline-sentinel.sh).
	[ -f "$TEST_TMP/.claude/logs/pre-merge-cr-gate-skip.jsonl" ]
}

@test "no extractable PR number → fail-closed deny" {
	_install_helper 0
	run _run_gate "gh pr merge --squash"
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]] || return 1
	[[ $output == *"could not extract PR number"* ]]
}

@test "CR-findings helper missing → fail-closed deny" {
	# No _install_helper: neither candidate path exists.
	run _run_gate "gh pr merge 42"
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]] || return 1
	[[ $output == *"helper not found"* ]]
}

# --- round-1 phase1 coverage gaps (pr-test-analyzer) ---

@test "gh pr merge after a && separator → fires (DENIED on findings)" {
	# The matcher anchors on shell separators too; a chained merge must still
	# be gated (not just a leading 'gh pr merge').
	_install_helper 1
	run _run_gate "echo prepping && gh pr merge 42 --squash"
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]] || return 1
	[[ $output == *"#42"* ]]
}

@test "unparseable (non-JSON) stdin → fail-closed deny" {
	# Every gate in this PR fails closed on a malformed payload; this one parses
	# the command via jq and denies when that fails.
	run _run_gate_raw 'this is not json {'
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]] || return 1
	[[ $output == *"failing closed"* ]]
}

@test "current-branch PR fallback resolves a number → DENIED on findings" {
	# No <N> and no --pr: the hook resolves the PR from the current branch via
	# gh. Stub gh to return one and assert the gate runs the helper against it.
	_install_helper 1
	_gh_returns 99
	run _run_gate "gh pr merge --squash"
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]] || return 1
	[[ $output == *"#99"* ]]
}

# --- #2393: command-position anchoring (no false-fire on quoted substring) ---

@test "gh pr merge inside a quoted commit message → pass-through (no false-fire)" {
	# #2393: a benign commit that merely mentions the phrase must NOT fire the
	# gate. _install_helper 1 would DENY if the gate fired — a pass-through proves
	# the phrase inside a quoted -m argument is not at a command position.
	_install_helper 1
	run _run_gate 'git commit -m "fix gh pr merge gate false-fire"'
	[ "$status" -eq 0 ]
	[[ $output != *deny* ]]
}

@test "gh pr merge inside a quoted echo argument → pass-through" {
	_install_helper 1
	run _run_gate 'echo "see the gh pr merge docs for details"'
	[ "$status" -eq 0 ]
	[[ $output != *deny* ]]
}

@test "env-preamble before a real merge still fires (APPROVE=1 gh pr merge)" {
	# The command-position parser must still strip a VAR=val preamble and detect
	# the real merge underneath it.
	_install_helper 1
	run _run_gate "APPROVE=1 gh pr merge 42"
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]] || return 1
	[[ $output == *"#42"* ]]
}

@test "a --flag=value on a real merge is not mistaken for an env preamble" {
	# `gh pr merge 42 --auto=true` contains `=` but NOT in the first token, so it
	# must still be detected as a merge (the SSOT ENV_PREFIX only peels a leading
	# preamble, and the anchor matches gh at command-start).
	_install_helper 1
	run _run_gate "gh pr merge 42 --auto=true"
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]] || return 1
	[[ $output == *"#42"* ]]
}

# --- SSOT-anchor robustness (was fail-open in the bespoke parser, fixed by
# --- routing through _lib/cmd-anchor.sh + the CR-hardened ENV_PREFIX) ---

@test 'quoted env-value preamble still fires (ENV_PREFIX handles X="a b")' {
	# The CR-hardened ENV_PREFIX matches single/double-quoted assignment values,
	# so a real merge behind `VAR=\"a b\"` is detected (a fail-open in the prior
	# bespoke parser, which split on the space inside the quotes).
	_install_helper 1
	run _run_gate 'GIT_AUTHOR_NAME="a b" gh pr merge 42'
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]] || return 1
	[[ $output == *"#42"* ]]
}

@test "bash -c single-quoted real merge fires (inner command checked)" {
	# The WRAPPED_CMD single-quote pass pulls the inner command out of the wrapper.
	_install_helper 1
	run _run_gate "bash -c 'gh pr merge 42'"
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]] || return 1
	[[ $output == *"#42"* ]]
}

@test "bash -c double-quoted real merge fires (per-quote extraction)" {
	# The double-quote pass handles `bash -c "..."`; a single ERE backreference
	# for "same quote" is non-portable on BSD sed (#2397), so extraction is two
	# passes — this asserts the double-quote pass detects the wrapped merge.
	_install_helper 1
	run _run_gate 'bash -c "gh pr merge 42"'
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]] || return 1
	[[ $output == *"#42"* ]]
}

@test "multi-space gh pr merge still fires (anchor uses [[:space:]]+)" {
	_install_helper 1
	run _run_gate "gh  pr  merge 42"
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]] || return 1
	[[ $output == *"#42"* ]]
}

@test "grouping/wrapper-prefixed merges fire (#2396: brace group, subshell, sudo, env)" {
	# Pre-#2396 all of these failed OPEN — the gate saw no command-position
	# `gh pr merge` behind the prefix and silently did not fire.
	_install_helper 1
	run _run_gate "{ gh pr merge 42; }"
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]] || return 1
	[[ $output == *"#42"* ]] || return 1
	run _run_gate "(gh pr merge 42)"
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]] || return 1
	run _run_gate "sudo -E gh pr merge 42"
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]] || return 1
	run _run_gate "env APPROVE=1 gh pr merge 42"
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]]
}

@test "quoted mid-string merge mention still passes after #2396 (no regression)" {
	_install_helper 1 # would deny if the gate (wrongly) fired
	run _run_gate 'git commit -m "docs: how { gh pr merge } is gated"'
	[ "$status" -eq 0 ]
	[[ $output != *deny* ]]
}

@test "mixed-version degradation: pre-#2396 lib (no CMD_HARDENED_PREFIX) still DENIES bare merges (r2)" {
	# The else-branch env-only fallback exists so a consumer mid-re-pin never
	# set -u-aborts (an aborting PreToolUse hook is NON-blocking = fail-open
	# merge). Stub the lib to the pre-#2396 export set and prove the gate
	# still fires on a bare merge with findings.
	rm "$TEST_TMP/.claude/_lib/cmd-anchor.sh"
	cat >"$TEST_TMP/.claude/_lib/cmd-anchor.sh" <<'EOF'
#!/bin/bash
CMD_SEGMENT_ANCHOR='(^|[;&|][[:space:]]*)'
CMD_SEGMENT_END='([[:space:]]|$)'
EOF
	_install_helper 1
	run _run_gate "gh pr merge 42 --squash"
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]] || return 1
	[[ $output == *"#42"* ]] || return 1
	# Env-prefixed form still covered by the fallback ENV_PREFIX too.
	run _run_gate "APPROVE=1 gh pr merge 42"
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]]
}
