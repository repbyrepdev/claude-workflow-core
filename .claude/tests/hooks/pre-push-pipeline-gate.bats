#!/usr/bin/env bats
# covers: hooks/pre-push-pipeline-gate.sh
#
# v0.31 #228: the fail-soft hook-wiring drift advisory. Sourced via
# SOURCED_FOR_TEST so the function is exercised in isolation. Contract: WARN on
# orphans, NEVER block (always rc 0), respect the skip env + an absent detector.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/pre-push-pipeline-gate.sh"
	[ -f "$HOOK" ]
	# Source for its helpers — the gate returns early (before the main body)
	# under SOURCED_FOR_TEST, after defining the _ functions.
	# shellcheck disable=SC1090  # dynamic source path (the hook under test)
	SOURCED_FOR_TEST=1 source "$HOOK"
	TMP=$(mktemp -d -t prepush.XXXXXX) || return 1
	mkdir -p "$TMP/scripts"
}

teardown() {
	[ -n "${TMP:-}" ] && [ -d "$TMP" ] && [[ $TMP == */prepush.* ]] && rm -rf "$TMP"
	return 0
}

_stub_detector() {
	# $1 = exit code (1 = orphans found, 0 = clean)
	cat >"$TMP/scripts/discover-orphan-hooks.sh" <<EOF
#!/bin/bash
echo "STUB ORPHAN OUTPUT"
exit $1
EOF
	chmod +x "$TMP/scripts/discover-orphan-hooks.sh"
}

@test "_orphan_hook_advisory WARNS on orphans but returns 0 — fail-soft (#228)" {
	_stub_detector 1
	run _orphan_hook_advisory "$TMP"
	[ "$status" -eq 0 ] # never blocks the push
	[[ $output == *"hook-wiring drift"* ]]
	[[ $output == *"STUB ORPHAN OUTPUT"* ]]
	[[ $output == *"register-hook.sh --all-auto-register"* ]]
}

@test "_orphan_hook_advisory is silent + rc 0 when no orphans (#228)" {
	_stub_detector 0
	run _orphan_hook_advisory "$TMP"
	[ "$status" -eq 0 ]
	[[ $output != *"hook-wiring drift"* ]]
}

@test "_orphan_hook_advisory respects ORPHAN_HOOK_CHECK_SKIP=1 (#228)" {
	_stub_detector 1
	ORPHAN_HOOK_CHECK_SKIP=1 run _orphan_hook_advisory "$TMP"
	[ "$status" -eq 0 ]
	[[ $output != *"hook-wiring drift"* ]]
}

@test "_orphan_hook_advisory no-ops + rc 0 when the detector is absent (#228)" {
	# no _stub_detector → $TMP/scripts/discover-orphan-hooks.sh missing
	run _orphan_hook_advisory "$TMP"
	[ "$status" -eq 0 ]
	[[ $output != *"hook-wiring drift"* ]]
}

@test "_orphan_hook_advisory rc=2 (precondition) is NOT framed as drift (#228 r1)" {
	# silent-failure-hunter/pr-test r1: a detector tooling error (rc=2) must read
	# as "could not run", not "drift" with a register-hook hint that wouldn't fix it.
	_stub_detector 2
	run _orphan_hook_advisory "$TMP"
	[ "$status" -eq 0 ] # still never blocks
	[[ $output == *"could not run"* ]]
	[[ $output != *"hook-wiring drift"* ]]
	[[ $output != *"register-hook.sh"* ]]
}

@test "the gate body INVOKES the advisory before the ref loop — call-site guard (#228 r1 integration)" {
	# Guards the wiring (line ~366), not just the function: run the gate
	# NON-sourced with empty stdin (no refs ⇒ no pipeline checks) + a stub
	# detector reporting an orphan. The advisory must fire (proving the call-site
	# is reached) and the gate must still exit 0 (advisory never blocks).
	local repo
	repo=$(mktemp -d -t prepushint.XXXXXX)
	(cd "$repo" && git init -q && git config user.email t@t.t && git config user.name t && git commit -q --allow-empty -m init)
	mkdir -p "$repo/scripts"
	cat >"$repo/scripts/discover-orphan-hooks.sh" <<'STUB'
#!/bin/bash
echo "INTEGRATION STUB ORPHAN"
exit 1
STUB
	chmod +x "$repo/scripts/discover-orphan-hooks.sh"
	run bash -c "cd '$repo' && printf '' | bash '$HOOK' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"hook-wiring drift"* ]]
	[[ $output == *"INTEGRATION STUB ORPHAN"* ]]
	[ -d "$repo" ] && [[ $repo == */prepushint.* ]] && rm -rf "$repo"
}

@test "_cr_cli_clean_for_sha fails CLOSED when the coverage lib is unavailable (#238)" {
	# #238: _cr_cli_clean_for_sha delegates to the shared cr_phase2_clean_for_sha
	# (sourced from _lib/cr-phase2-coverage.sh). If that lib didn't source (the
	# function is undefined), the wrapper MUST fail closed — non-zero + an error —
	# never silently pass an unverified Phase 2. (The clean/covered/not-clean
	# LOGIC is unit-tested in _lib/cr-phase2-coverage.bats.)
	unset -f cr_phase2_clean_for_sha 2>/dev/null || true
	run _cr_cli_clean_for_sha 0123456789abcdef
	[ "$status" -ne 0 ]
	[[ $output == *"not sourced"* ]]
}

@test "gate resolves _lib through a .git/hooks SYMLINK — consumer install (#2252)" {
	# Regression: a consumer installs .git/hooks/pre-push as a SYMLINK to
	# .claude/hooks/pre-push-pipeline-gate.sh — a DIFFERENT directory depth than
	# the real hook. $0/BASH_SOURCE then point at the symlink, so the old
	# dirname/../_lib resolution looked in the symlink dir's (nonexistent)
	# ../_lib → cr-phase2-coverage.sh never sourced → fail-closed push. The
	# PPG_DIR symlink-resolving preamble must follow the link so _lib resolves
	# to the REAL hook's sibling. Source via the symlink + assert the coverage
	# fn became available (undefined ⇒ the bug is back).
	mkdir -p "$TMP/real/hooks" "$TMP/real/_lib" "$TMP/link/deeper"
	cp "$HOOK" "$TMP/real/hooks/pre-push-pipeline-gate.sh"
	cp "${BATS_TEST_DIRNAME}/../../../_lib/cr-phase2-coverage.sh" "$TMP/real/_lib/cr-phase2-coverage.sh"
	# Symlink dir ($TMP/link/deeper) has NO ../_lib; real dir ($TMP/real/hooks)
	# does — so success proves the link was resolved, not the symlink dir used.
	ln -s ../../real/hooks/pre-push-pipeline-gate.sh "$TMP/link/deeper/pre-push"
	unset -f cr_phase2_clean_for_sha 2>/dev/null || true
	# shellcheck disable=SC1090  # dynamic source path (the symlinked hook)
	SOURCED_FOR_TEST=1 source "$TMP/link/deeper/pre-push"
	[ "$PPG_DIR" -ef "$TMP/real/hooks" ] # PPG_DIR resolved to the REAL hook dir
	# Exercise the resolved gate END-TO-END, not just symbol presence (CR #2253):
	# a fixture review-log makes cr_phase2_clean_for_sha (sourced FROM the
	# resolved _lib) return CLEAN, so _cr_cli_clean_for_sha actually EXECUTES and
	# emits its accept verdict — proving the resolved _lib is functional.
	mkdir -p "$TMP/repo/.claude/logs"
	printf '{"sha":"abc1234","findings":0}\n' >"$TMP/repo/.claude/logs/cr-local-review.jsonl"
	REPO_ROOT="$TMP/repo" run _cr_cli_clean_for_sha abc1234def
	[ "$status" -eq 0 ]            # the resolved lib's fn ran and returned clean
	[[ $output == *"accepting"* ]] # ... emitting the gate's accept verdict
}

@test "gate resolves _lib through an ABSOLUTE-target .git/hooks symlink (#2252)" {
	# Most hook installers write an ABSOLUTE symlink target — exercises the
	# `case /*` branch (the test above covers the relative branch).
	mkdir -p "$TMP/real/hooks" "$TMP/real/_lib" "$TMP/link/deeper"
	cp "$HOOK" "$TMP/real/hooks/pre-push-pipeline-gate.sh"
	cp "${BATS_TEST_DIRNAME}/../../../_lib/cr-phase2-coverage.sh" "$TMP/real/_lib/cr-phase2-coverage.sh"
	ln -s "$TMP/real/hooks/pre-push-pipeline-gate.sh" "$TMP/link/deeper/pre-push"
	unset -f cr_phase2_clean_for_sha 2>/dev/null || true
	# shellcheck disable=SC1090  # dynamic source path (the symlinked hook)
	SOURCED_FOR_TEST=1 source "$TMP/link/deeper/pre-push"
	[ "$PPG_DIR" -ef "$TMP/real/hooks" ] # PPG_DIR resolved to the REAL hook dir
	# Exercise the resolved gate END-TO-END, not just symbol presence (CR #2253):
	# a fixture review-log makes cr_phase2_clean_for_sha (sourced FROM the
	# resolved _lib) return CLEAN, so _cr_cli_clean_for_sha actually EXECUTES and
	# emits its accept verdict — proving the resolved _lib is functional.
	mkdir -p "$TMP/repo/.claude/logs"
	printf '{"sha":"abc1234","findings":0}\n' >"$TMP/repo/.claude/logs/cr-local-review.jsonl"
	REPO_ROOT="$TMP/repo" run _cr_cli_clean_for_sha abc1234def
	[ "$status" -eq 0 ]            # the resolved lib's fn ran and returned clean
	[[ $output == *"accepting"* ]] # ... emitting the gate's accept verdict
}

@test "gate resolves _lib through a CHAINED multi-hop symlink (#2252)" {
	# Dotfile managers (stow/chezmoi/dotbot) install pre-push -> hop1 -> real
	# hook. Exercises the `while [ -L ]` loop at depth >=2 (the tests above are
	# single-hop); a loop that stops at hop 1 or mis-anchors the 2nd relative
	# re-resolution would FAIL here while passing the single-hop tests.
	mkdir -p "$TMP/real/hooks" "$TMP/real/_lib" "$TMP/a" "$TMP/b/deeper"
	cp "$HOOK" "$TMP/real/hooks/pre-push-pipeline-gate.sh"
	cp "${BATS_TEST_DIRNAME}/../../../_lib/cr-phase2-coverage.sh" "$TMP/real/_lib/cr-phase2-coverage.sh"
	ln -s ../real/hooks/pre-push-pipeline-gate.sh "$TMP/a/hop1" # hop1 -> real
	ln -s ../../a/hop1 "$TMP/b/deeper/pre-push"                 # pre-push -> hop1
	unset -f cr_phase2_clean_for_sha 2>/dev/null || true
	# shellcheck disable=SC1090  # dynamic source path (the symlinked hook)
	SOURCED_FOR_TEST=1 source "$TMP/b/deeper/pre-push"
	[ "$PPG_DIR" -ef "$TMP/real/hooks" ] # PPG_DIR resolved to the REAL hook dir
	# Exercise the resolved gate END-TO-END, not just symbol presence (CR #2253):
	# a fixture review-log makes cr_phase2_clean_for_sha (sourced FROM the
	# resolved _lib) return CLEAN, so _cr_cli_clean_for_sha actually EXECUTES and
	# emits its accept verdict — proving the resolved _lib is functional.
	mkdir -p "$TMP/repo/.claude/logs"
	printf '{"sha":"abc1234","findings":0}\n' >"$TMP/repo/.claude/logs/cr-local-review.jsonl"
	REPO_ROOT="$TMP/repo" run _cr_cli_clean_for_sha abc1234def
	[ "$status" -eq 0 ]            # the resolved lib's fn ran and returned clean
	[[ $output == *"accepting"* ]] # ... emitting the gate's accept verdict
}

@test "gate fails CLOSED when PPG_DIR resolves but _lib is absent (#2252 fail-safe)" {
	# Mirror-image negative of the success tests + the safety contract: resolve
	# through a symlink whose target dir has NO sibling _lib → cr-phase2-
	# coverage.sh silently not sourced → cr_phase2_clean_for_sha undefined →
	# _cr_cli_clean_for_sha fails CLOSED (never a silent pass).
	mkdir -p "$TMP/real/hooks" "$TMP/link" # NOTE: deliberately no $TMP/real/_lib
	cp "$HOOK" "$TMP/real/hooks/pre-push-pipeline-gate.sh"
	ln -s ../real/hooks/pre-push-pipeline-gate.sh "$TMP/link/pre-push"
	unset -f cr_phase2_clean_for_sha 2>/dev/null || true
	# shellcheck disable=SC1090  # dynamic source path (the symlinked hook)
	SOURCED_FOR_TEST=1 source "$TMP/link/pre-push"
	run _cr_cli_clean_for_sha 0123456789abcdef
	[ "$status" -ne 0 ]
	[[ $output == *"not sourced"* ]]
}

@test "gate does not HANG on a cyclic symlink install (#2252 termination)" {
	# Defense-in-depth: a misconfigured/cyclic .git/hooks/pre-push must fail-fast,
	# never hang the push. The OS's ELOOP (open of a self-referential link) and
	# the bounded-hop guard both guarantee termination. Sourcing through the
	# cycle must RETURN (so the test reaches its assertion); a spin would hang
	# the bats run → regression caught. No timeout(1) dep (absent on stock macOS).
	mkdir -p "$TMP/cyc"
	ln -s pre-push "$TMP/cyc/pre-push" # self-referential cycle (a -> a)
	run bash -c "SOURCED_FOR_TEST=1 source '$TMP/cyc/pre-push' 2>/dev/null; echo REACHED"
	[ "$status" -eq 0 ]          # bash -c returned (the cycle did NOT spin)
	[[ $output == *"REACHED"* ]] # ... and reached the sentinel past the source
}

@test "gate fails CLOSED (exit 1) when REPO_ROOT is unresolvable — non-git work tree (#2263)" {
	# v0.34.45 #2263: the empty-REPO_ROOT path changed from `exit 0` (fail-OPEN —
	# silently bypassing the WHOLE pipeline gate) to `exit 1` (fail-CLOSED). Run
	# the hook NON-sourced (so it does NOT return at the SOURCED_FOR_TEST guard
	# that precedes the check) with cwd in the non-git $TMP, so
	# `git rev-parse --show-toplevel` yields an empty REPO_ROOT. Without this lock
	# a refactor could silently revert the gate to fail-open and no test would see it.
	run bash -c "cd '$TMP' && printf '' | bash '$HOOK'"
	[ "$status" -eq 1 ]
	[[ $output == *"failing closed"* ]]
}
