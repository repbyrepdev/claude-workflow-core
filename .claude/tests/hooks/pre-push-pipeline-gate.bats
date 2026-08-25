#!/usr/bin/env bats
# covers: hooks/pre-push-pipeline-gate.sh
# shellcheck disable=SC2317,SC2329  # stub fns (e.g. graduation_invalidate) run
# indirectly via the sourced hook, so the reachability/invocation checks
# misfire here (SC2317 + SC2329 differ only by shellcheck version).
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
	printf '{"sha":"abc1234","findings":0,"complete":true}\n' >"$TMP/repo/.claude/logs/cr-local-review.jsonl"
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
	printf '{"sha":"abc1234","findings":0,"complete":true}\n' >"$TMP/repo/.claude/logs/cr-local-review.jsonl"
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
	printf '{"sha":"abc1234","findings":0,"complete":true}\n' >"$TMP/repo/.claude/logs/cr-local-review.jsonl"
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
	# #2263: the empty-REPO_ROOT path changed from `exit 0` (fail-OPEN —
	# silently bypassing the WHOLE pipeline gate) to `exit 1` (fail-CLOSED). Run
	# the hook NON-sourced (so it does NOT return at the SOURCED_FOR_TEST guard
	# that precedes the check) with cwd in the non-git $TMP, so
	# `git rev-parse --show-toplevel` yields an empty REPO_ROOT. Without this lock
	# a refactor could silently revert the gate to fail-open and no test would see it.
	run bash -c "cd '$TMP' && printf '' | bash '$HOOK'"
	[ "$status" -eq 1 ]
	[[ $output == *"failing closed"* ]]
}

# ---- #2295: force-push detection → graduation invalidation -----------------
# Builds c1 → c2 (linear) plus c2alt diverging from c1 in $TMP; echoes "c1 c2 c2alt".
_make_grad_fixture() {
	(
		set -e # fail-fast: a failed git step must not yield partial output (CR #2482)
		cd "$TMP" || exit 1
		git init -q
		git config user.email t@t
		git config user.name t
		echo a >f
		git add f
		git commit -qm c1
		c1=$(git rev-parse HEAD)
		echo b >>f
		git add f
		git commit -qm c2
		c2=$(git rev-parse HEAD)
		git checkout -q -b alt "$c1"
		echo z >>f
		git add f
		git commit -qm c2alt
		c2alt=$(git rev-parse HEAD)
		echo "$c1 $c2 $c2alt"
	)
}

ZERO40="0000000000000000000000000000000000000000"

# Builds main(cb) → feat/x(c2) with the test LEFT ON feat/x; echoes "cb c2".
# Used by the #2483 ancestry-check tests, which amend/extend feat/x afterwards.
_make_stale_fixture() {
	(
		set -e
		cd "$TMP" || exit 1
		git init -q
		git config user.email t@t
		git config user.name t
		git checkout -qb main
		echo base >f
		git add f
		git commit -qm base
		cb=$(git rev-parse HEAD)
		git checkout -qb feat/x
		echo work >g
		git add g
		git commit -qm work
		echo "$cb $(git rev-parse HEAD)"
	)
}

_GRAD_LIB="${BATS_TEST_DIRNAME}/../../../_lib/phase-graduation.sh"

@test "STALE marker on a CREATE-push (graduate then amend then first push) runs the full gate (#2483)" {
	# The event detectors cannot see this shape: an all-zeros remote is never a
	# force-push, so pre-#2483 the stale marker short-circuited Phase 1 for
	# amended, never-re-reviewed code. rc is 1 both pre- and post-fix (pre-fix
	# it fails later at the Phase 2 check INSIDE the short-circuit), so the
	# discriminating assertions are the MESSAGES.
	read -r _cb c2 < <(_make_stale_fixture)
	cd "$TMP"
	# shellcheck disable=SC1090
	source "$_GRAD_LIB"
	graduation_mark "feat/x" "$c2" 1
	marker=$(graduation_marker_path "feat/x")
	[ -f "$marker" ]
	git commit -q --amend -m "work amended" # no post-commit hook installed → marker survives
	c2p=$(git rev-parse HEAD)
	run bash -c "cd '$TMP' && printf 'refs/heads/feat/x %s refs/heads/feat/x %s\n' '$c2p' '$ZERO40' | PHASE1_MIN_ROUNDS= bash '$HOOK'"
	[ "$status" -eq 1 ]
	[[ $output == *"is STALE"* ]]                   # ancestry check fired
	[[ $output != *"graduated past Phase 0.5/1"* ]] # short-circuit NOT honored
	[[ $output == *"no review log for"* ]]          # full log walk ran
	[ ! -f "$marker" ]                              # stale marker invalidated
}

@test "STALE marker on a FAST-FORWARD push (amend of a never-pushed tip) runs the full gate (#2483)" {
	# remote=cb is an ancestor of the amended tip, so the force-push probe
	# returns 1 (fast-forward) — only the ancestry check catches this shape.
	read -r cb c2 < <(_make_stale_fixture)
	cd "$TMP"
	# shellcheck disable=SC1090
	source "$_GRAD_LIB"
	graduation_mark "feat/x" "$c2" 1
	git commit -q --amend -m "work amended"
	c2p=$(git rev-parse HEAD)
	run bash -c "cd '$TMP' && printf 'refs/heads/feat/x %s refs/heads/feat/x %s\n' '$c2p' '$cb' | PHASE1_MIN_ROUNDS= bash '$HOOK'"
	[ "$status" -eq 1 ]
	[[ $output != *"force-push detected"* ]] # took the fast-forward path
	[[ $output == *"is STALE"* ]]            # ...and ancestry still caught it
	[[ $output != *"graduated past Phase 0.5/1"* ]]
	[[ $output == *"no review log for"* ]]
}

@test "POSITIVE control: graduated branch with a normal child commit keeps the short-circuit (#2483)" {
	# Locks the ancestry check against over-tightening (an inverted merge-base
	# or fail-closed parse quirk would silently revert #792 graduation and put
	# every branch back on the Phase 1 treadmill).
	read -r _cb c2 < <(_make_stale_fixture)
	cd "$TMP"
	# shellcheck disable=SC1090
	source "$_GRAD_LIB"
	graduation_mark "feat/x" "$c2" 1
	echo more >h
	git add h
	git commit -qm more # NORMAL child commit — c2 stays an ancestor
	c3=$(git rev-parse HEAD)
	mkdir -p .claude/logs
	# cr_phase2_clean_for_sha matches .sha against the 7-char short sha exactly.
	printf '{"sha":"%s","findings":0,"complete":true}\n' "${c3:0:7}" >.claude/logs/cr-local-review.jsonl # Phase 2 clean seed
	run bash -c "cd '$TMP' && printf 'refs/heads/feat/x %s refs/heads/feat/x %s\n' '$c3' '$ZERO40' | PHASE1_MIN_ROUNDS= bash '$HOOK'"
	[ "$status" -eq 0 ]
	[[ $output == *"graduated past Phase 0.5/1"* ]] # short-circuit survived the ancestry check
	[[ $output != *"is STALE"* ]]
	[[ $output == *"accepting"* ]] # Phase 2 clean verdict honored
}

@test "force-push with a STUCK marker (rm fails) still runs the full gate via _grad_forced (#2483)" {
	# Locks the operational claim in the WARN text: enforcement does not depend
	# on the marker actually being removed. Marker graduated at c1 (an ancestor
	# of the pushed c2alt), so the ancestry check alone would NOT trip — only
	# _grad_forced blocks the short-circuit here.
	read -r c1 c2 c2alt < <(_make_grad_fixture)
	cd "$TMP"
	# shellcheck disable=SC1090
	source "$_GRAD_LIB"
	graduation_mark "feat/x" "$c1" 1
	marker=$(graduation_marker_path "feat/x")
	mdir=$(dirname "$marker")
	chmod 555 "$mdir" # unlink now fails → graduation_invalidate returns 1
	run bash -c "cd '$TMP' && printf 'refs/heads/feat/x %s refs/heads/feat/x %s\n' '$c2alt' '$c2' | PHASE1_MIN_ROUNDS= bash '$HOOK'"
	chmod 755 "$mdir" # restore so teardown's rm -rf succeeds
	[ "$status" -eq 1 ]
	[[ $output == *"force-push detected"* ]]
	[[ $output == *"WARN"* ]]
	[[ $output == *"graduation_invalidate failed"* ]]
	[[ $output != *"graduated past Phase 0.5/1"* ]] # _grad_forced bypassed the short-circuit
	[[ $output == *"no review log for"* ]]          # full walk ran
	[ -f "$marker" ]                                # the stuck marker indeed survived
}

@test "_grad_marker_stale: MISSING marker is fail-closed STALE (rc 0) (#2483 CR)" {
	# TOCTOU guard: the caller checks graduation_check first, but a marker
	# invalidated between the two checks must NOT be honored — and the helper
	# must stay self-contained fail-closed for any future caller.
	read -r _cb c2 < <(_make_stale_fixture)
	cd "$TMP"
	# shellcheck disable=SC1090
	source "$_GRAD_LIB" # provides graduation_marker_path (no marker written)
	run _grad_marker_stale "feat/x" "$c2"
	[ "$status" -eq 0 ]
}

@test "_grad_invalidate_on_force_push: WARNs (still rc 0) when marker removal fails (#2483)" {
	# #2483: a failed graduation_invalidate must be VISIBLE — a persisting
	# marker would wrongly re-graduate the NEXT fast-forward push. rc stays 0:
	# enforcement for THIS push is the caller's _grad_forced flag.
	read -r _c1 c2 c2alt < <(_make_grad_fixture)
	cd "$TMP"
	graduation_invalidate() { return 1; }
	run _grad_invalidate_on_force_push "feat/x" "$c2" "$c2alt" "$ZERO40"
	[ "$status" -eq 0 ]
	[[ $output == *"force-push detected"* ]]
	[[ $output == *"WARN"* ]]
	[[ $output == *"graduation_invalidate failed"* ]]
}

@test "_grad_invalidate_on_force_push: divergent (rewrite) invalidates + rc 0 (#2295)" {
	read -r _c1 c2 c2alt < <(_make_grad_fixture)
	cd "$TMP"
	graduation_invalidate() { echo "INVAL:$1"; }
	# remote=c2, local=c2alt (diverged from c1) ⇒ c2 is NOT an ancestor of c2alt.
	run _grad_invalidate_on_force_push "feat/x" "$c2" "$c2alt" "$ZERO40"
	[ "$status" -eq 0 ]
	[[ $output == *"force-push detected for feat/x"* ]]
	[[ $output == *"INVAL:feat/x"* ]]
}

@test "_grad_invalidate_on_force_push: fast-forward is not a force-push → rc 1 (#2295)" {
	read -r c1 c2 _c2alt < <(_make_grad_fixture)
	cd "$TMP"
	graduation_invalidate() { echo "INVAL:$1"; }
	# remote=c1, local=c2 ⇒ c1 IS an ancestor of c2 (history extended, not rewritten).
	run _grad_invalidate_on_force_push "feat/x" "$c1" "$c2" "$ZERO40"
	[ "$status" -eq 1 ]
	[[ $output != *"INVAL"* ]]
	[[ $output != *"force-push"* ]]
}

@test "_grad_invalidate_on_force_push: all-zeros remote (new branch) → rc 1 (#2295)" {
	read -r _c1 c2 _c2alt < <(_make_grad_fixture)
	cd "$TMP"
	graduation_invalidate() { echo "INVAL:$1"; }
	run _grad_invalidate_on_force_push "feat/x" "$ZERO40" "$c2" "$ZERO40"
	[ "$status" -eq 1 ]
	[[ $output != *"INVAL"* ]]
}

@test "_grad_invalidate_on_force_push: empty branch name → rc 1, no-op (#2295)" {
	graduation_invalidate() { echo "INVAL:$1"; }
	run _grad_invalidate_on_force_push "" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "cafebabecafebabecafebabecafebabecafebabe" "$ZERO40"
	[ "$status" -eq 1 ]
	[[ $output != *"INVAL"* ]]
}

# ---- #2567-r2 hardening: NO AUDIT ROW → NO BYPASS ---------------------------

@test "PIPELINE_GATE_SKIP=1 bypass succeeds AND writes the audit row" {
	(cd "$TMP" && git init -q && git config user.email t@t.t && git config user.name t && git commit -q --allow-empty -m init)
	run bash -c "cd '$TMP' && printf '' | PIPELINE_GATE_SKIP=1 SKIP_LOG='$TMP/skip.jsonl' bash '$HOOK'"
	[ "$status" -eq 0 ]
	[[ $output == *"bypassing gate"* ]]
	[ -f "$TMP/skip.jsonl" ]
	[ "$(jq -r '.gate' "$TMP/skip.jsonl")" = "pre-push" ]
}

@test "bypass REFUSES when the audit append fails — no unlogged skip" {
	(cd "$TMP" && git init -q && git config user.email t@t.t && git config user.name t && git commit -q --allow-empty -m init)
	mkdir -p "$TMP/ro"
	chmod 555 "$TMP/ro"
	run bash -c "cd '$TMP' && printf '' | PIPELINE_GATE_SKIP=1 SKIP_LOG='$TMP/ro/deeper/skip.jsonl' bash '$HOOK'"
	chmod 755 "$TMP/ro"
	[ "$status" -eq 1 ]
	[[ $output == *"refusing an UNLOGGED bypass"* ]]
}

@test "bypass REFUSES when the audit writer lib is absent entirely" {
	# Copy the hook to a dir with NO sibling _lib → pipeline_skip_log never
	# defined → the bypass must fail closed, not proceed with a warning.
	(cd "$TMP" && git init -q && git config user.email t@t.t && git config user.name t && git commit -q --allow-empty -m init)
	mkdir -p "$TMP/hooks"
	cp "$HOOK" "$TMP/hooks/pre-push-pipeline-gate.sh"
	run bash -c "cd '$TMP' && printf '' | PIPELINE_GATE_SKIP=1 bash '$TMP/hooks/pre-push-pipeline-gate.sh'"
	[ "$status" -eq 1 ]
	[[ $output == *"refusing an UNLOGGED bypass"* ]]
	[[ $output == *"pipeline-skip.sh unavailable"* ]]
}

@test "real hook on a fast-forward ref does NOT abort at the force-push probe (#2295 set -e regression)" {
	# pr-test-analyzer #2295 r1: the unit tests above call the fn via `run` (a
	# subshell — it swallows set -e), so they cannot see that a BARE call at the
	# real call site would abort the whole gate under `set -euo pipefail` when
	# the fn returns 1 on a fast-forward. Run the REAL hook NON-sourced with a
	# fast-forward ref line on stdin: local=c2 (descendant), remote=c1 (its
	# ancestor). Pre-fix the gate died at the probe (~line 512) before the log
	# walk; post-fix it proceeds and — with no review-log for c2 — reaches the
	# "no review log" gate, so asserting that message proves it cleared the
	# probe. PHASE1_MIN_ROUNDS=1 makes the post-probe path deterministic (skips
	# CR-CLI delegation) while still exercising the probe (which runs regardless).
	read -r c1 c2 _c2alt < <(_make_grad_fixture)
	cd "$TMP"
	run bash -c "printf 'refs/heads/feat/x %s refs/heads/feat/x %s\n' '$c2' '$c1' | PHASE1_MIN_ROUNDS=1 bash '$HOOK'"
	[ "$status" -eq 1 ]                      # blocks the push: no review log for c2 ⇒ FAILED=1
	[[ $output == *"no review log for"* ]]   # reached the log walk ⇒ survived the probe
	[[ $output != *"force-push detected"* ]] # fast-forward is NOT a force-push
}
