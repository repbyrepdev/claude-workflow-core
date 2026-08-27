#!/usr/bin/env bats
# covers: scripts/cr/watch-until-done.sh
#
# #2332: the CR-in-CI watcher must treat a path-filtered PR (CodeRabbit posts
# no check) as TERMINAL (exit 3) instead of polling to the timeout — but ONLY
# when CR is definitely NOT a required check AND every other check is terminal.
# It must keep waiting (never prematurely exit 3) when CR IS required, when a
# non-CR check is still pending, while the CR row is present, or when the
# CR-required state is indeterminate (fail CLOSED).

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/cr/watch-until-done.sh"
	TEST_TMP=$(mktemp -d -t watchdone.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	mkdir -p "$TEST_TMP/fakebin"
}

teardown() {
	cd /tmp || return
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */watchdone.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Fake `gh` serving canned responses for the calls the script makes. The script
# invokes gh with its built-in `--jq` flag (e.g. `gh api … --jq '.protected'`),
# so gh applies the filter itself and emits a SCALAR ("main", "true"/"false") —
# NOT raw JSON. This stub therefore prints those post-`--jq` scalars directly;
# returning JSON objects would NOT match real gh and would break the script's
# `[ "$protected" = false ]` / scalar comparisons. Scenario is passed per-run
# via env (no `export` — that trips SC2030/2031 in bats):
#   FAKE_CHECKS         `gh pr checks` output, tab-separated (name<TAB>bucket)
#   FAKE_CHECKS_RC      exit code for `gh pr checks` (default 0; gh overloads it:
#                       0=all pass, 8=>=1 pending, 1=>=1 failed/none/error) (#2352)
#   FAKE_CR_REQUIRED    yes|no — is CodeRabbit in the base branch's required set
#   FAKE_PROTECTED      true|false — is the base branch protected (default true)
#   FAKE_BRANCH_READ_FAIL  1 — make the branch-object read fail (gh error sim)
_make_fake_gh() {
	cat >"$TEST_TMP/fakebin/gh" <<'EOF'
#!/bin/bash
# Route on "$1 $2". For `gh api <path> ...` the path is $2; distinguish the
# branch-PROTECTION read (CR-required) from the branch-OBJECT read (.protected)
# by the path suffix.
case "$1 $2" in
"pr checks") printf '%s\n' "$FAKE_CHECKS"; exit "${FAKE_CHECKS_RC:-0}" ;;
"pr view") echo "main" ;;
"repo view") echo "owner/repo" ;;
"api "*)
	case "$2" in
	*/protection)
		if [ "${FAKE_CR_REQUIRED:-no}" = yes ]; then echo true; else echo false; fi
		;;
	*)
		[ "${FAKE_BRANCH_READ_FAIL:-}" = 1 ] && exit 1
		echo "${FAKE_PROTECTED:-true}"
		;;
	esac
	;;
*)
	echo "fake-gh: unhandled: $*" >&2
	exit 1
	;;
esac
EOF
	chmod +x "$TEST_TMP/fakebin/gh"
}

# Timeout convention below: the exit-3 tests use --timeout 30 (well above the
# 3-consecutive-absent-poll threshold at --interval 1) so the watcher reaches
# exit 3 before timing out; the keep-waiting tests use --timeout 3 to hit the
# timeout fast (exit 2), proving they do NOT take the exit-3 path.
@test "path-filtered: CR absent + others terminal + not required → exit 3 (#2332)" {
	local checks=$'gitleaks\tpass\t2s\nlabel\tpass\t1s'
	_make_fake_gh
	run env FAKE_CHECKS="$checks" FAKE_CR_REQUIRED=no \
		PATH="$TEST_TMP/fakebin:$PATH" bash "$SCRIPT" 999 --interval 1 --timeout 30
	[ "$status" -eq 3 ]
	[[ $output == *"not applicable"* ]]
}

@test "unprotected base → CR not required → path-filtered exit 3 (plugin's own main) (#2332)" {
	# The plugin's main is unprotected: _cr_required_state must resolve 'no'
	# from the branch-object read alone (never reaching the protection read),
	# keeping the path-filtered PR exit-3 eligible.
	local checks=$'gitleaks\tpass\t2s\nlabel\tpass\t1s'
	_make_fake_gh
	run env FAKE_CHECKS="$checks" FAKE_PROTECTED=false \
		PATH="$TEST_TMP/fakebin:$PATH" bash "$SCRIPT" 999 --interval 1 --timeout 30
	[ "$status" -eq 3 ]
	[[ $output == *"not applicable"* ]]
}

@test "CR posts a passing check → exit 0" {
	local checks=$'CodeRabbit\tpass\t30s\ngitleaks\tpass\t2s'
	_make_fake_gh
	run env FAKE_CHECKS="$checks" FAKE_CR_REQUIRED=no \
		PATH="$TEST_TMP/fakebin:$PATH" bash "$SCRIPT" 999 --interval 1 --timeout 30
	[ "$status" -eq 0 ]
	[[ $output == *"CodeRabbit: pass"* ]]
}

@test "CR required + absent → keeps waiting (timeout exit 2), NOT premature exit 3 (#2332)" {
	# CR IS a required check, so even with CR absent + other checks terminal
	# the watcher must NOT exit 3 — it waits (and here times out → exit 2).
	local checks=$'gitleaks\tpass\t2s\nlabel\tpass\t1s'
	_make_fake_gh
	run env FAKE_CHECKS="$checks" FAKE_CR_REQUIRED=yes \
		PATH="$TEST_TMP/fakebin:$PATH" bash "$SCRIPT" 999 --interval 1 --timeout 3
	[ "$status" -eq 2 ]
	[[ $output == *"timeout reached"* ]]
}

@test "path-filtered but a NON-CR check still PENDING → keeps waiting (exit 2), not exit 3 (#2332)" {
	# CR absent + not required, BUT a non-CR check is still pending — the
	# watcher must NOT declare 'not applicable' (exit 3) while a real check is
	# mid-flight. It waits → times out → exit 2. This is the exact bug class
	# the _other_checks_terminal allowlist guards against.
	local checks=$'gitleaks\tpass\t2s\nlabel\tpending\t1s'
	_make_fake_gh
	run env FAKE_CHECKS="$checks" FAKE_CR_REQUIRED=no \
		PATH="$TEST_TMP/fakebin:$PATH" bash "$SCRIPT" 999 --interval 1 --timeout 3
	[ "$status" -eq 2 ]
	[[ $output == *"timeout reached"* ]]
}

@test "CR present-but-pending resets the absent counter → no premature exit 3 (#2332)" {
	# The CR row is present (pending), so ABSENT_WITH_OTHERS never reaches the
	# threshold — exit 3 can't fire even though CR is not required. Times out.
	local checks=$'CodeRabbit\tpending\t5s\ngitleaks\tpass\t2s'
	_make_fake_gh
	run env FAKE_CHECKS="$checks" FAKE_CR_REQUIRED=no \
		PATH="$TEST_TMP/fakebin:$PATH" bash "$SCRIPT" 999 --interval 1 --timeout 3
	[ "$status" -eq 2 ]
	[[ $output == *"timeout reached"* ]]
}

@test "indeterminate CR-required (gh branch read errors) → keeps waiting (exit 2), fail closed (#2332)" {
	# A transient gh/auth error resolving CR-required must NOT enable exit 3:
	# _cr_required_state returns 'unknown' → treated like 'yes' → keep waiting.
	local checks=$'gitleaks\tpass\t2s\nlabel\tpass\t1s'
	_make_fake_gh
	run env FAKE_CHECKS="$checks" FAKE_BRANCH_READ_FAIL=1 \
		PATH="$TEST_TMP/fakebin:$PATH" bash "$SCRIPT" 999 --interval 1 --timeout 3
	[ "$status" -eq 2 ]
	[[ $output == *"timeout reached"* ]]
}

@test "gh pr checks rc=8 (pending) tolerated — parses RAW, CR pass → exit 0 (#2352)" {
	# gh returns rc=8 when >=1 check is still pending (here a non-CR check) while
	# the CR row already passed. The old `if !` aborted on ANY non-zero rc; now
	# rc=8 falls through to the normal parse → CR pass → exit 0 (no scm_fail).
	local checks=$'CodeRabbit\tpass\t30s\nother\tpending\t1s'
	_make_fake_gh
	run env FAKE_CHECKS="$checks" FAKE_CHECKS_RC=8 FAKE_CR_REQUIRED=no \
		PATH="$TEST_TMP/fakebin:$PATH" bash "$SCRIPT" 999 --interval 1 --timeout 30
	[ "$status" -eq 0 ]
	[[ $output == *"CodeRabbit: pass"* ]] || return 1
	[[ $output != *"gh pr checks failed"* ]]
}

@test "gh pr checks rc=1 with a failed CR row → surfaces CR failure exit 1, not scm_fail (#2352)" {
	# rc=1 with a parseable table (CR row = fail) means gh RAN; the watcher must
	# surface the CR failure (exit 1), not the old generic invocation-error exit 2.
	local checks=$'CodeRabbit\tfail\t30s\ngitleaks\tpass\t2s'
	_make_fake_gh
	run env FAKE_CHECKS="$checks" FAKE_CHECKS_RC=1 FAKE_CR_REQUIRED=no \
		PATH="$TEST_TMP/fakebin:$PATH" bash "$SCRIPT" 999 --interval 1 --timeout 30
	[ "$status" -eq 1 ]
	[[ $output == *"CodeRabbit: fail"* ]] || return 1
	[[ $output != *"gh pr checks failed"* ]]
}

@test "gh pr checks rc=1 with EMPTY output → scm_fail exit 2, true invocation error (#2352)" {
	# rc=1 with no output at all is a genuine gh invocation error (auth/network)
	# — must still fail loud (exit 2), not silently poll through to the timeout.
	_make_fake_gh
	run env FAKE_CHECKS="" FAKE_CHECKS_RC=1 FAKE_CR_REQUIRED=no \
		PATH="$TEST_TMP/fakebin:$PATH" bash "$SCRIPT" 999 --interval 1 --timeout 30
	[ "$status" -eq 2 ]
	[[ $output == *"gh pr checks failed"* ]] || return 1
	[[ $output == *"no output"* ]]
}

@test "gh pr checks rc=1 with an ERROR message (no check rows) → scm_fail exit 2 (#2352)" {
	# A genuine invocation error (auth/network/unknown PR) prints a NON-empty
	# error line with no tab-separated check rows. The fragile empty-RAW proxy
	# would have let this fall through to the pending branch (silent failure,
	# polling to timeout — the phase0.5 prefilter caught it); the NF>=2 check-row
	# test fails loud instead, surfacing the real error.
	_make_fake_gh
	run env FAKE_CHECKS="error: could not resolve to a PullRequest with the number 999" \
		FAKE_CHECKS_RC=1 FAKE_CR_REQUIRED=no \
		PATH="$TEST_TMP/fakebin:$PATH" bash "$SCRIPT" 999 --interval 1 --timeout 30
	[ "$status" -eq 2 ]
	[[ $output == *"no parseable check rows"* ]]
}

@test "gh pr checks rc=1 with a failed NON-CR sibling → warns once, watch continues (#2352)" {
	# rc=1 from a failed non-CodeRabbit check (CR absent), CR required so no
	# exit-3: the watch must SURFACE the sibling failure (scm_warn) — not let the
	# eventual CR-timeout be the only signal — then keep polling (→ timeout exit 2).
	local checks=$'gitleaks\tfail\t2s\nlabel\tpass\t1s'
	_make_fake_gh
	run env FAKE_CHECKS="$checks" FAKE_CHECKS_RC=1 FAKE_CR_REQUIRED=yes \
		PATH="$TEST_TMP/fakebin:$PATH" bash "$SCRIPT" 999 --interval 1 --timeout 3
	[ "$status" -eq 2 ]
	[[ $output == *"timeout reached"* ]] || return 1
	# CR #2371: assert the warn fires EXACTLY once (the SIBLING_FAIL_WARNED
	# one-shot). Presence-only passed even when the warn was UNREACHABLE — the
	# count is the real contract. Kept LAST so bats enforces it.
	local warn_count
	warn_count=$(grep -c "non-CodeRabbit check has FAILED" <<<"$output" || true)
	[ "$warn_count" -eq 1 ]
}

@test "gh pr checks rc=2 (unexpected) → scm_fail exit 2 with rc in message (#2352)" {
	# Any rc outside {0,8,1} is a genuine invocation error → fail loud, surfacing
	# the actual rc. Guards the `*)` arm (distinct message from the rc=1 arm).
	_make_fake_gh
	run env FAKE_CHECKS="boom" FAKE_CHECKS_RC=2 FAKE_CR_REQUIRED=no \
		PATH="$TEST_TMP/fakebin:$PATH" bash "$SCRIPT" 999 --interval 1 --timeout 30
	[ "$status" -eq 2 ]
	[[ $output == *"(rc=2)"* ]]
}

@test "gh pr checks rc=8 with CR still pending → keeps polling to timeout, not abort (#2352)" {
	# rc=8 (pending) with the CR row itself pending must POLL — the keep-polling
	# half of the rc=8 contract the rc=8+CR-pass test does NOT exercise (that one
	# exits 0 on the first poll). Times out → exit 2, NOT scm_fail.
	local checks=$'CodeRabbit\tpending\t5s\nother\tpending\t1s'
	_make_fake_gh
	run env FAKE_CHECKS="$checks" FAKE_CHECKS_RC=8 FAKE_CR_REQUIRED=yes \
		PATH="$TEST_TMP/fakebin:$PATH" bash "$SCRIPT" 999 --interval 1 --timeout 3
	[ "$status" -eq 2 ]
	[[ $output == *"timeout reached"* ]] || return 1
	[[ $output != *"gh pr checks failed"* ]]
}
