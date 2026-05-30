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
# Add a feature commit with a .sh change so `list-phase1-agents.sh main`
# yields a non-empty agent set (code paths, not skipped test/doc-only).
_make_diff() {
	(
		set -e
		cd "$TEST_TMP"
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

@test "round must be a positive integer → exit 2" {
	_init_repo
	_log phase1 0 code-reviewer 0 ok
	[ "$status" -eq 2 ]
	[[ $output == *"round must be a positive integer"* ]]
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
