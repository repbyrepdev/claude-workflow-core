#!/usr/bin/env bats
# covers: hooks/phase1-launcher.sh
#
# v0.30.F (#193): integration coverage for the launcher's SendMessage-resume
# wiring in its `*)` agent case. The launcher had NO direct bats before this.
#
# Fixture: an isolated temp repo with `main` + a `feat` branch carrying one
# .sh change (so `git diff main..HEAD` is non-empty + agent-relevant), and a
# stub `.claude/hooks/list-phase1-agents.sh` (resolve_plugin_helper checks
# $REPO_ROOT/.claude/hooks first) that returns exactly one resumable agent.
# We run the REAL launcher with cwd in the temp repo; $0 still points at the
# real hooks dir, so phase1-agent-id.sh + phase1-resume-message.sh resolve to
# the real helpers (which compute REPO_ROOT = the temp repo). The seeded
# agentId record therefore lives in the temp repo's .session-state.
#
# The two load-bearing assertions:
#   * FLAG OFF → fresh `Agent subagent_type=` line, NO [RESUME] (byte-identical
#     to pre-#193 — the whole safety contract).
#   * FLAG ON + eligible record → [RESUME] + a SendMessage body.

setup() {
	REPO="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
	LAUNCHER="$REPO/hooks/phase1-launcher.sh"
	[ -x "$LAUNCHER" ]

	TMP="$(mktemp -d -t p1lr.XXXXXX)"
	cd "$TMP" || return 1
	git init -q -b main 2>/dev/null || {
		git init -q
		git symbolic-ref HEAD refs/heads/main
	}
	git config user.email t@t.t
	git config user.name t
	git commit -q --allow-empty -m base
	BASE_SHA="$(git rev-parse HEAD)"
	git checkout -q -b feat
	printf '#!/bin/bash\necho hi\n' >foo.sh
	git add foo.sh
	git commit -q -m "feat: add foo.sh"

	# Stub the agent list — exactly one resumable (pr-review-toolkit) agent.
	mkdir -p "$TMP/.claude/hooks"
	cat >"$TMP/.claude/hooks/list-phase1-agents.sh" <<'STUB'
#!/bin/bash
echo code-reviewer
STUB
	chmod +x "$TMP/.claude/hooks/list-phase1-agents.sh"

	STORE="$TMP/.claude/.session-state/phase1-agent-ids"
	AGENTID="a872508899e04c95a"
}

teardown() {
	[ -n "${TMP:-}" ] && rm -rf "$TMP"
}

_seed_record() {
	# Seed an eligible record: last_sha = BASE (≠ HEAD) so round 2 has a delta.
	mkdir -p "$STORE"
	printf '{"agent":"code-reviewer","agentId":"%s","sha":"%s","last_sha":"%s","resume_count":0,"first_recorded":1}\n' \
		"$AGENTID" "$BASE_SHA" "$BASE_SHA" >"$STORE/code-reviewer.json"
}

@test "FLAG OFF round 2: fresh Agent line, NO [RESUME] (byte-identical fallback)" {
	_seed_record
	CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0 run bash "$LAUNCHER" 2
	[ "$status" -eq 0 ]
	[[ $output == *"Agent subagent_type=pr-review-toolkit:code-reviewer"* ]]
	[[ $output != *"[RESUME]"* ]]
	[[ $output != *"SendMessage to="* ]]
}

@test "FLAG ON round 2 + eligible record: emits [RESUME] + SendMessage body" {
	_seed_record
	CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 run bash "$LAUNCHER" 2
	[ "$status" -eq 0 ]
	[[ $output == *"[RESUME]"* ]]
	[[ $output == *"SendMessage to=$AGENTID"* ]]
	# the peer-review message body markers
	[[ $output == *"DELTA REVIEW"* ]]
	[[ $output == *"new_findings"* ]]
}

@test "FLAG ON round 2, NO record: falls back to fresh Agent (no resume directive)" {
	# no _seed_record — directive returns empty (no record) → fresh line.
	# Assert on `SendMessage to=` (the ACTUAL directive marker) rather than
	# the substring "[RESUME]", which also appears in the flag-gated footer
	# prose ("After a SUCCESSFUL [RESUME]…") and would false-positive.
	CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 run bash "$LAUNCHER" 2
	[ "$status" -eq 0 ]
	[[ $output == *"Agent subagent_type=pr-review-toolkit:code-reviewer"* ]]
	[[ $output != *"SendMessage to="* ]]
}

@test "FLAG ON round 1: always fresh (no resume directive) even with a record" {
	_seed_record
	CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 run bash "$LAUNCHER" 1
	[ "$status" -eq 0 ]
	[[ $output == *"Agent subagent_type=pr-review-toolkit:code-reviewer"* ]]
	[[ $output != *"SendMessage to="* ]]
}

@test "resume bookkeeping footer is flag-gated (present ON, absent OFF)" {
	_seed_record
	CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 run bash "$LAUNCHER" 2
	[[ $output == *"resume bookkeeping"* ]]
	CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0 run bash "$LAUNCHER" 2
	[[ $output != *"resume bookkeeping"* ]]
}

@test "FLAG OFF round 2: output is BYTE-IDENTICAL to the pre-#193 launcher (safety contract)" {
	# Phase 1 r1 (pr-test-analyzer HIGH): the whole #193 safety contract is
	# "flag off ⇒ byte-identical to pre-#193". Prove it by EQUALITY, not just
	# substring-absence: run the main-branch launcher and the HEAD launcher in
	# the SAME fixture with the flag off and diff. To make the comparison fair
	# both must resolve the same sibling hooks + _lib, so copy the whole HEAD
	# hooks/ + _lib into the fixture and drop the pre-#193 launcher beside them.
	_seed_record
	cp -R "$REPO/hooks" "$TMP/hooks-copy"
	cp -R "$REPO/_lib" "$TMP/_lib"
	# `_lib` must sit at <launcher-dir>/../_lib for both launchers' source line.
	mkdir -p "$TMP/run/hooks"
	cp -R "$TMP/_lib" "$TMP/run/_lib"
	cp "$TMP"/hooks-copy/*.sh "$TMP/run/hooks/" 2>/dev/null
	git -C "$REPO" show main:hooks/phase1-launcher.sh >"$TMP/run/hooks/main-launcher.sh" 2>/dev/null ||
		skip "#193 cannot read main:hooks/phase1-launcher.sh (shallow clone?)"
	chmod +x "$TMP/run/hooks/main-launcher.sh" "$TMP/run/hooks/phase1-launcher.sh"
	out_main=$(CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0 bash "$TMP/run/hooks/main-launcher.sh" 2 2>/dev/null)
	out_head=$(CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0 bash "$TMP/run/hooks/phase1-launcher.sh" 2 2>/dev/null)
	[ -n "$out_main" ]
	[ "$out_main" = "$out_head" ]
}
