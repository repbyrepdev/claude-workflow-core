#!/usr/bin/env bats
# covers: scripts/ship-pr-cycle.sh
#
# v0.30.D (#190): the cr-conflict-check stage. Drives `ship-pr-cycle.sh next`
# against a tmp git repo with a PATH-stubbed `gh` so the stage's mergeability
# branching is exercised end-to-end (no network). Also pins the auto-triage
# 0-unresolved-threads reroute: it now lands on cr-conflict-check, NOT
# merge-gate directly.

# @bats test bodies run as subshells, so shellcheck flags the per-test STUB_*
# exports (SC2030/SC2031) as "lost in subshell" — false positive here: each
# export feeds the PATH-stubbed `gh` child process WITHIN the same test and is
# never read across tests. Same disable as ship-cycle-guard.bats.
# shellcheck disable=SC2030,SC2031

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/ship-pr-cycle.sh"
	TEST_TMP=$(mktemp -d -t ship-crconflict.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# Tmp git repo so REPO_ROOT-derived STATE_DIR + helpers resolve locally.
	# set -e in the subshell aborts setup on git/mkdir failure (mirrors the
	# epic-dispatch suite's silent-failure guard).
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		mkdir -p .claude/scripts/cr bin
	) || {
		echo "FATAL: TEST_TMP fixture init failed (git/mkdir)" >&2
		return 1
	}
	# Canonical root + HEAD sha — match what the script computes (macOS
	# resolves mktemp /var → /private/var, so derive via git, not $TEST_TMP).
	ROOT=$(cd "$TEST_TMP" && git rev-parse --show-toplevel)
	SHA=$(cd "$TEST_TMP" && git rev-parse HEAD)
	STATE_DIR="$ROOT/.claude/.session-state/ship-cycle"
	mkdir -p "$STATE_DIR"

	# Unified `gh` stub: routes by argv shape.
	#   api graphql ...                       → 0 unresolved threads, no next page
	#   ... --json mergeStateStatus,mergeable → {STUB_MERGE, STUB_MERGEABLE}
	#   ... --json id --jq .id                → a node id
	#   ... --json number --jq .number        → STUB_PR (default 123)
	cat >"$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "api" ]; then
	printf '%s\n' '{"data":{"node":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}'
	exit 0
fi
for a in "$@"; do
	case "$a" in
	*mergeStateStatus*)
		printf '%s\n' "{\"mergeStateStatus\":\"${STUB_MERGE:-CLEAN}\",\"mergeable\":\"${STUB_MERGEABLE:-MERGEABLE}\"}"
		exit 0
		;;
	esac
done
for a in "$@"; do
	if [ "$a" = "id" ]; then
		printf '%s\n' "PR_kwTESTID"
		exit 0
	fi
done
printf '%s\n' "${STUB_PR:-123}"
exit 0
STUB
	chmod +x "$TEST_TMP/bin/gh"
	export PATH="$TEST_TMP/bin:$PATH"
}

teardown() {
	# shellcheck disable=SC2164 # best-effort; rm guarded below
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */ship-crconflict.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Pre-set the state file to a given stage on the current HEAD sha.
_seed_stage() {
	printf '{"version":1,"stage":"%s","branch":"feat/v0.30.0/190-test","sha":"%s","history":[]}\n' \
		"$1" "$SHA" >"$STATE_DIR/$SHA.json"
}

_cur_stage() {
	jq -r '.stage' "$STATE_DIR/$SHA.json"
}

@test "cr-conflict-check + CLEAN/MERGEABLE advances to merge-gate" {
	_seed_stage cr-conflict-check
	cd "$TEST_TMP" || return 1
	export STUB_MERGE=CLEAN STUB_MERGEABLE=MERGEABLE
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"advanced to merge-gate"* ]]
	[ "$(_cur_stage)" = merge-gate ]
}

@test "cr-conflict-check + DIRTY/CONFLICTING stays + emits resolve directive" {
	_seed_stage cr-conflict-check
	cd "$TEST_TMP" || return 1
	export STUB_MERGE=DIRTY STUB_MERGEABLE=CONFLICTING
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	# Directive names the cr-resolve-conflict skill wrapper + the PR number.
	[[ $output == *"cr-resolve-conflict/run.sh --pr 123"* ]]
	[[ $output == *"merge conflict"* ]]
	# Stage MUST NOT advance — operator resolves, then HEAD moves.
	[ "$(_cur_stage)" = cr-conflict-check ]
}

@test "cr-conflict-check + UNKNOWN mergeable stays (computing) without advancing" {
	_seed_stage cr-conflict-check
	cd "$TEST_TMP" || return 1
	export STUB_MERGE=UNKNOWN STUB_MERGEABLE=UNKNOWN
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"still computing"* ]]
	[ "$(_cur_stage)" = cr-conflict-check ]
}

@test "cr-conflict-check requires BOTH fields to agree — DIRTY+MERGEABLE is not a conflict" {
	# Single-field disagreement (transient blip) must NOT misfire the
	# resolver — mirrors the skill's strict gate. Routes to merge-gate.
	_seed_stage cr-conflict-check
	cd "$TEST_TMP" || return 1
	export STUB_MERGE=DIRTY STUB_MERGEABLE=MERGEABLE
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"advanced to merge-gate"* ]]
	[ "$(_cur_stage)" = merge-gate ]
}

@test "auto-triage with 0 unresolved threads reroutes to cr-conflict-check (#190)" {
	# The behavior change at the heart of #190: the 0-threads path no longer
	# jumps straight to merge-gate; it goes through cr-conflict-check.
	_seed_stage auto-triage
	cd "$TEST_TMP" || return 1
	# Local auto-triage helper stub (consumer-first resolver picks it up).
	cat >.claude/scripts/cr/auto-triage.sh <<'AT'
#!/usr/bin/env bash
exit 0
AT
	chmod +x .claude/scripts/cr/auto-triage.sh
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"advanced to cr-conflict-check"* ]]
	[ "$(_cur_stage)" = cr-conflict-check ]
}
