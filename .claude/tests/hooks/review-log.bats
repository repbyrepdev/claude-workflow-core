#!/usr/bin/env bats
# covers: hooks/review-log.sh
#
# v0.30.0 (#180 PR3): regression locks for the v4.3.D (#360) Phase 1/2 review
# logger. Covers the high-priority #180 gaps for this layer:
#   - T12: round-complete clears the per-SHA phase1-directive marker (without
#     this the marker leaks every round → phase1-directive-pending-guard locks
#     every tool call; 2026-05-28 dogfood: 34 markers accumulated).
#   - T13: round-complete with findings>0 emits the NEXT-STEPS directive and
#     does NOT graduate; a clean round graduates. (deferred-vs-clean state.)
#   - the v4.23-U (#589) strict 5-arg validation cr-fix (no fake-clean round
#     from a defaulted findings=0/status=ok) + the v4.15.B fabrication guard
#     (unknown agent rejected) + CR-SFH #14 fail-loud REPO_ROOT.
#
# Round-complete needs the real list-phase1-agents.sh SSOT, so those tests
# copy .claude/review-config.yml into the fixture and build a main↔feature
# diff, then log exactly the agents `list-phase1-agents.sh main` reports.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/review-log.sh"
	[ -f "$HOOK" ]
	command -v jq >/dev/null
	HOOKS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../../hooks" && pwd)"
	REAL_CONFIG="${BATS_TEST_DIRNAME}/../../review-config.yml"
	TEST_TMP=$(mktemp -d -t review-log.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */review-log.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# A minimal git repo with one commit on `main`.
_init_repo() {
	(
		set -e
		cd "$TEST_TMP"
		git init -q -b main 2>/dev/null || { git init -q && git branch -M main; }
		git config user.email t@t.t
		git config user.name t
		git commit --allow-empty -q -m init
	)
}
# Enable the agent-list SSOT inside the fixture (round-complete needs it).
_enable_agents() {
	[ -f "$REAL_CONFIG" ] || skip "review-config.yml not found at $REAL_CONFIG"
	command -v yq >/dev/null || skip "yq not installed — round-complete needs the agent SSOT"
	mkdir -p "$TEST_TMP/.claude"
	cp "$REAL_CONFIG" "$TEST_TMP/.claude/review-config.yml"
}
# Add a feature commit with a .sh change ON A FEATURE BRANCH so the base
# `main` is preserved as a real diff base — otherwise `main..HEAD` is empty,
# `list-phase1-agents.sh main` returns nothing, and the round-complete tests
# silently skip (pr-test-analyzer #180-PR3 r1: the headline tests were inert).
_make_diff() {
	(
		set -e
		cd "$TEST_TMP"
		git checkout -q -b feat
		mkdir -p scripts
		printf '#!/bin/bash\necho hi\n' >scripts/dummy.sh
		git add scripts/dummy.sh
		git commit -q -m "feat: dummy"
	)
}
_marker_path() {
	local sha
	sha=$(git -C "$TEST_TMP" rev-parse HEAD)
	echo "$TEST_TMP/.claude/.session-state/ship-cycle/${sha}.phase1-directive.txt"
}
_log() { run bash -c "cd '$TEST_TMP' && bash '$HOOK' $*"; }

@test "REPO_ROOT unresolvable (not a git work tree) → exit 2, fail-loud (CR-SFH #14)" {
	# A non-git dir must refuse rather than write to an ambiguous location.
	run bash -c "cd '$TEST_TMP' && bash '$HOOK' phase1 1 code-reviewer 0 ok"
	[ "$status" -eq 2 ]
	[[ $output == *"cannot resolve REPO_ROOT"* ]]
}

@test "strict 5-arg validation: missing findings+status → exit 2 (no fake-clean, v4.23-U)" {
	_init_repo
	_log phase1 1 code-reviewer
	[ "$status" -eq 2 ]
	[[ $output == *"Missing: findings status"* ]]
}

@test "findings_count must be a non-negative integer → exit 2" {
	_init_repo
	_log phase1 1 code-reviewer abc ok
	[ "$status" -eq 2 ]
	[[ $output == *"findings_count must be a non-negative integer"* ]]
}

@test "negative findings_count is rejected (the ^[0-9]+$ guard excludes the sign)" {
	# The regex is non-negative-only; a leading '-' must be refused, not parsed
	# as a count or a flag. Locks the 'non-negative' half of the contract that
	# the abc-case (non-numeric) does not exercise.
	_init_repo
	_log phase1 1 code-reviewer -1 ok
	[ "$status" -eq 2 ]
	[[ $output == *"non-negative integer"* ]]
}

@test "round must be a positive integer → exit 2" {
	_init_repo
	_log phase1 0 code-reviewer 0 ok
	[ "$status" -eq 2 ]
	[[ $output == *"round must be a positive integer"* ]]
}

@test "extra positional args beyond the 5 are ignored, not an error" {
	# The hook reads $2..$5 positionally; a stray 6th arg must be ignored, not
	# misparsed into a failure. Locks the positional-arg contract.
	_init_repo
	_enable_agents
	_log phase1 1 code-reviewer 0 ok ignored-sixth-arg
	[ "$status" -eq 0 ]
}

@test "review-log path occupied by a file → fail-loud (mkdir -p refuses)" {
	# If .claude/review-log is a FILE (not a dir), `mkdir -p "$LOG_DIR"` (line
	# 37) fails under set -euo pipefail → the hook aborts non-zero rather than
	# silently logging nowhere. Locks fail-loud on a broken log path.
	_init_repo
	mkdir -p "$TEST_TMP/.claude"
	: >"$TEST_TMP/.claude/review-log"
	_log phase1 1 code-reviewer 0 ok
	[ "$status" -ne 0 ]
}

@test "unknown agent name is rejected (fabrication guard, v4.15.B)" {
	_init_repo
	_enable_agents
	_log phase1 1 totally-not-an-agent 0 ok
	[ "$status" -eq 2 ]
	[[ $output == *"unknown Phase 1 agent"* ]]
}

@test "valid phase1 log appends one jsonl line for the HEAD sha" {
	_init_repo
	_enable_agents
	local sha
	sha=$(git -C "$TEST_TMP" rev-parse HEAD)
	_log phase1 1 code-reviewer 2 ok
	[ "$status" -eq 0 ]
	local logf="$TEST_TMP/.claude/review-log/${sha}.jsonl"
	[ -f "$logf" ]
	# the line records phase/round/agent/findings.
	run jq -e 'select(.phase==1 and .round==1 and .agent=="code-reviewer" and .findings==2)' "$logf"
	[ "$status" -eq 0 ]
}

@test "logging an agent clears ALL its pending sentinels, leaves other agents' (T14)" {
	# hook lines 168-183 (+ #778-followup): once an agent is logged, every
	# ${AGENT}-*.txt pending sentinel is cleared regardless of sha (one agent =
	# one in-flight review), so phase1-log-pending-gate stops blocking — but a
	# DIFFERENT agent's sentinel must survive.
	_init_repo
	_enable_agents
	local sha pdir
	sha=$(git -C "$TEST_TMP" rev-parse HEAD)
	pdir="$TEST_TMP/.claude/.session-state/phase1-log-pending"
	mkdir -p "$pdir"
	: >"$pdir/code-reviewer-${sha}.txt"
	: >"$pdir/code-reviewer-deadbeefdeadbeef.txt"
	: >"$pdir/comment-analyzer-${sha}.txt"
	_log phase1 1 code-reviewer 0 ok
	[ "$status" -eq 0 ]
	# both code-reviewer sentinels cleared (current-sha AND stale-sha)…
	[ ! -f "$pdir/code-reviewer-${sha}.txt" ]
	[ ! -f "$pdir/code-reviewer-deadbeefdeadbeef.txt" ]
	# …a different agent's sentinel is untouched.
	[ -f "$pdir/comment-analyzer-${sha}.txt" ]
}

@test "unwritable review-log dir → fail-loud, not silent (T15 write-failure proxy)" {
	# T15: an audit-log write that can't land (disk-full / perms) must surface a
	# non-zero exit, never silently "succeed" with no recorded line. The jsonl
	# append (line 153) runs under set -euo pipefail with no `|| true`, so a
	# failed `>>"$LOG"` aborts loudly. Simulated here via a read-only log dir.
	if [ "$(id -u)" -eq 0 ]; then
		skip "#180 write-failure relies on DAC perms, which root bypasses"
	fi
	_init_repo
	_enable_agents
	local logdir="$TEST_TMP/.claude/review-log"
	mkdir -p "$logdir"
	chmod 555 "$logdir"
	_log phase1 1 code-reviewer 0 ok
	chmod u+w "$logdir"
	# the append could not write → non-zero exit (not a silent 0).
	[ "$status" -ne 0 ]
}

@test "round-complete (all agents clean) clears the directive marker + GRADUATES (T12)" {
	_init_repo
	_enable_agents
	_make_diff
	# expected filtered agent set for THIS diff (same SSOT the hook uses).
	local expected
	expected=$(cd "$TEST_TMP" && "$HOOKS_DIR/list-phase1-agents.sh" main 2>/dev/null | sort -u)
	[ -n "$expected" ] || skip "list-phase1-agents.sh returned no agents for the fixture diff"
	# seed the per-SHA directive marker the round-complete path must clear.
	local marker
	marker=$(_marker_path)
	mkdir -p "$(dirname "$marker")"
	: >"$marker"
	[ -f "$marker" ]
	# log every expected agent clean (findings=0); the last one completes round 1.
	local ag
	while IFS= read -r ag; do
		[ -n "$ag" ] || continue
		_log phase1 1 "$ag" 0 ok
		[ "$status" -eq 0 ]
	done <<<"$expected"
	# T12: the round-complete path removed the directive marker.
	[ ! -f "$marker" ]
	# clean round → graduation directive emitted.
	[[ $output == *"GRADUATED"* ]]
	# state-transition is persisted, not just printed: the per-sha review-log
	# actually recorded this round's agent entries (phase1/round1).
	local logf
	logf="$TEST_TMP/.claude/review-log/$(git -C "$TEST_TMP" rev-parse HEAD).jsonl"
	[ -f "$logf" ]
	run jq -e 'select(.phase==1 and .round==1 and .findings==0)' "$logf"
	[ "$status" -eq 0 ]
}

@test "round-complete with findings>0 clears marker but emits NEXT STEPS, no graduation (T13)" {
	_init_repo
	_enable_agents
	_make_diff
	local expected
	expected=$(cd "$TEST_TMP" && "$HOOKS_DIR/list-phase1-agents.sh" main 2>/dev/null | sort -u)
	[ -n "$expected" ] || skip "list-phase1-agents.sh returned no agents for the fixture diff"
	local marker
	marker=$(_marker_path)
	mkdir -p "$(dirname "$marker")"
	: >"$marker"
	# log all expected agents; give the FIRST one a non-zero finding so the
	# round is complete-but-dirty.
	local ag first=1
	while IFS= read -r ag; do
		[ -n "$ag" ] || continue
		if [ "$first" -eq 1 ]; then
			_log phase1 1 "$ag" 3 ok
			first=0
		else
			_log phase1 1 "$ag" 0 ok
		fi
		[ "$status" -eq 0 ]
	done <<<"$expected"
	# round-complete still clears the marker (it fires regardless of findings)…
	[ ! -f "$marker" ]
	# …but a dirty round emits NEXT STEPS and does NOT graduate.
	[[ $output == *"NEXT STEPS"* ]]
	[[ $output != *"GRADUATED"* ]]
}

@test "round IN PROGRESS (not all agents logged yet) leaves the directive marker INTACT (#473 guard window)" {
	# #473 / #2230 Part B: the directive-clear (hook lines 242-253) must fire ONLY
	# when the round COMPLETES (all expected agents logged) — NOT after a partial
	# round. This pins the OTHER edge of the marker lifecycle that T12/T13 (which
	# both log the FULL set) leave uncovered: while agents are still in-flight the
	# marker MUST survive, so the phase1-directive-pending-guard keeps nudging the
	# loop to finish firing the round (its intended [directive-emit → agents-logged]
	# blocking window). A regression that cleared the marker on the FIRST agent
	# would silently un-gate the loop mid-round; this assertion breaches first.
	_init_repo
	_enable_agents
	_make_diff
	local expected
	expected=$(cd "$TEST_TMP" && "$HOOKS_DIR/list-phase1-agents.sh" main 2>/dev/null | sort -u)
	[ -n "$expected" ] || skip "list-phase1-agents.sh returned no agents for the fixture diff"
	local n_expected
	n_expected=$(printf '%s\n' "$expected" | grep -c .)
	# Need ≥2 agents to have a genuine "in progress" state (log some, omit ≥1).
	[ "$n_expected" -ge 2 ] || skip "fixture filtered to <2 agents — no partial-round state to exercise"
	# Seed the per-SHA directive marker (as ship-pr-cycle would on directive-emit).
	local marker
	marker=$(_marker_path)
	mkdir -p "$(dirname "$marker")"
	: >"$marker"
	[ -f "$marker" ]
	# Log all EXCEPT the last expected agent → round is incomplete (MISSING != "").
	local last ag
	last=$(printf '%s\n' "$expected" | tail -n1)
	while IFS= read -r ag; do
		[ -n "$ag" ] || continue
		[ "$ag" = "$last" ] && continue # omit the last → round stays in progress
		_log phase1 1 "$ag" 0 ok
		[ "$status" -eq 0 ]
	done <<<"$expected"
	# The round-complete branch was NOT entered → marker MUST survive.
	[ -f "$marker" ]
	# Sanity: no round-complete directive was emitted (the round isn't done).
	[[ $output != *"COMPLETE — all expected agents logged"* ]]
	# Now log the final agent → round completes → marker IS cleared (the positive
	# edge, mirroring T12 but proving the transition happens on the LAST agent).
	_log phase1 1 "$last" 0 ok
	[ "$status" -eq 0 ]
	[ ! -f "$marker" ]
}

@test "round-complete with an 'errored' agent blocks graduation even at 0 findings (ANY_ERR)" {
	# hook lines 255/269: round-complete counts status=='errored' agents
	# (ANY_ERR). A round where every agent reports 0 findings but one is
	# 'errored' is NOT clean → NEXT STEPS, no graduation. Locks that an errored
	# agent (crash/timeout/unparseable) is never mistaken for a clean pass.
	_init_repo
	_enable_agents
	_make_diff
	local expected
	expected=$(cd "$TEST_TMP" && "$HOOKS_DIR/list-phase1-agents.sh" main 2>/dev/null | sort -u)
	[ -n "$expected" ] || skip "list-phase1-agents.sh returned no agents for the fixture diff"
	local ag first=1
	while IFS= read -r ag; do
		[ -n "$ag" ] || continue
		if [ "$first" -eq 1 ]; then
			_log phase1 1 "$ag" 0 errored
			first=0
		else
			_log phase1 1 "$ag" 0 ok
		fi
		[ "$status" -eq 0 ]
	done <<<"$expected"
	# 0 findings everywhere but one errored → not clean.
	[[ $output == *"NEXT STEPS"* ]]
	[[ $output != *"GRADUATED"* ]]
}

@test "phase2 happy path appends a {phase:2} record (the pre-push-gate contract)" {
	# `review-log.sh phase2 <findings> <status>` is fired by local-review.sh and
	# the resulting phase==2 record is consumed by pre-push-pipeline-gate.sh to
	# authorize push. Lock the append shape so a renamed/dropped phase/findings/
	# status field can't silently break push gating.
	_init_repo
	local sha
	sha=$(git -C "$TEST_TMP" rev-parse HEAD)
	_log phase2 0 clean
	[ "$status" -eq 0 ]
	local logf="$TEST_TMP/.claude/review-log/${sha}.jsonl"
	[ -f "$logf" ]
	run jq -e 'select(.phase==2 and .findings==0 and .status=="clean")' "$logf"
	[ "$status" -eq 0 ]
}

@test "phase2 with a non-numeric findings count fails loud (no silent skip)" {
	# Unlike phase1, phase2 does NO numeric guard — $2 goes straight to jq
	# --argjson. A non-numeric count makes jq abort under set -e, so the run
	# fails non-zero rather than silently appending a malformed/absent line.
	_init_repo
	_log phase2 abc clean
	[ "$status" -ne 0 ]
}

@test "accept-with-reason writes a kind=accept-with-reason record; empty reason → exit 2" {
	_init_repo
	local sha
	sha=$(git -C "$TEST_TMP" rev-parse HEAD)
	# Pass the multi-word reason as a single single-quoted arg (the _log helper
	# word-splits $*, which would break a spaced reason).
	run bash -c "cd '$TEST_TMP' && bash '$HOOK' accept-with-reason 'simplifier vs comment-analyzer disagreed - explanatory preferred'"
	[ "$status" -eq 0 ]
	local logf="$TEST_TMP/.claude/review-log/${sha}.jsonl"
	run jq -e 'select(.kind=="accept-with-reason" and .phase==1)' "$logf"
	[ "$status" -eq 0 ]
	# an empty reason is refused — no silent no-reason override.
	_log accept-with-reason
	[ "$status" -eq 2 ]
}

@test "unknown action → exit 2 (a typo'd action is not silently ignored)" {
	_init_repo
	_log phase3 1 code-reviewer 0 ok
	[ "$status" -eq 2 ]
	[[ $output == *"Unknown action"* ]]
}
