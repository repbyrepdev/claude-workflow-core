#!/usr/bin/env bats
# covers: hooks/phase0.5-copilot-prefilter.sh
# shellcheck disable=SC2154  # $stderr/$output/$status are assigned by bats `run --separate-stderr`
#
# #2563: (1) an agent response wrapping its JSON array in prose is SALVAGED
# (first-[ .. last-] span) instead of discarded as non-array-output, with
# partial:true logged so the count is known-lossy; (2) findings missing
# their .agent field are stamped by the producer (the null agent used to
# crash phase1-dedup with jq's runtime rc=5 leaking through pipefail as an
# undocumented exit while [] read as "clean"); (3) every terminal path
# exits a documented code — a dedup/emit failure collapses to rc=1 with an
# errored-emit audit row, never a leaked jq rc.
#
# The fixture mirrors the repo layout (hooks/ + _lib/ siblings) with the
# REAL prefilter, dedup stages, and libs copied in; only the model helper
# (try-free.sh) and list-phase1-agents.sh are stubs, so the parse → stamp
# → dedup → emit chain under test is the production chain.

bats_require_minimum_version 1.5.0

setup() {
	REPO="${BATS_TEST_DIRNAME}/../../.."
	TEST_TMP=$(mktemp -d -t p05pf.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		git init -q -b main
		git config user.email t@t
		git config user.name t
		mkdir -p hooks _lib .claude/scripts/copilot .claude/logs
		# Real components under test + their real collaborators.
		cp "$REPO/hooks/phase0.5-copilot-prefilter.sh" hooks/
		cp "$REPO/hooks/phase1-dedup.sh" hooks/
		cp "$REPO/hooks/phase0.5-dedupe-against-audit.sh" hooks/
		cp "$REPO/_lib/resolve-plugin-helper.sh" _lib/
		cp "$REPO/_lib/phase05-dedupe.sh" _lib/
		cp "$REPO/_lib/phase05-auth-summary.sh" _lib/
		# Stub: agent selection (diff-aware scoping is not under test here).
		printf '#!/bin/bash\necho code-reviewer\n' >hooks/list-phase1-agents.sh
		# Stub: the Copilot CLI helper — emits whatever the test staged.
		cat >.claude/scripts/copilot/try-free.sh <<'EOF'
#!/bin/bash
cat "$(git rev-parse --show-toplevel)/copilot-out.txt"
exit "${STUB_COPILOT_RC:-0}"
EOF
		chmod +x hooks/*.sh .claude/scripts/copilot/try-free.sh
		cat >.claude/review-config.yml <<'EOF'
agents:
  code-reviewer:
    canonical_brief: "Review the diff for bugs. Files: {DIFF_FILES}"
EOF
		echo "base" >base.sh
		git add -A
		git commit -q -m base
		echo "change" >>base.sh
		git add -A
		git commit -q -m change
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
	BASE_SHA=$(cd "$TEST_TMP" && git rev-parse HEAD~1)
	LOG="$TEST_TMP/.claude/logs/phase0.5-run.jsonl"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}

_run_prefilter() {
	run --separate-stderr hooks/phase0.5-copilot-prefilter.sh --base "$BASE_SHA"
}

_last_agent_row() {
	jq -sc '[.[] | select(.agent == "code-reviewer")] | last' "$LOG"
}

@test "prose preamble before the array is salvaged, partial:true logged" {
	cd "$TEST_TMP" || return 1
	printf 'Here are my findings:\n[{"agent":"code-reviewer","file":"base.sh","line":1,"category":"c","severity":"low","description":"d","confidence":5}]\n' >copilot-out.txt
	_run_prefilter
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq 'length')" = "1" ]
	row=$(_last_agent_row)
	[ "$(jq -r '.status' <<<"$row")" = "ok" ]
	[ "$(jq -r '.findings' <<<"$row")" = "1" ]
	[ "$(jq -r '.partial' <<<"$row")" = "true" ]
}

@test "clean array parses with partial:false" {
	cd "$TEST_TMP" || return 1
	printf '[{"agent":"code-reviewer","file":"base.sh","line":1,"category":"c","severity":"low","description":"d","confidence":5}]\n' >copilot-out.txt
	_run_prefilter
	[ "$status" -eq 0 ]
	row=$(_last_agent_row)
	[ "$(jq -r '.status' <<<"$row")" = "ok" ]
	[ "$(jq -r '.partial' <<<"$row")" = "false" ]
}

@test "trailing prose after the array is salvaged too" {
	cd "$TEST_TMP" || return 1
	printf '[{"agent":"code-reviewer","file":"base.sh","line":1,"category":"c","severity":"low","description":"d","confidence":5}]\nHope this helps.\n' >copilot-out.txt
	_run_prefilter
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq 'length')" = "1" ]
	[ "$(jq -r '.partial' <<<"$(_last_agent_row)")" = "true" ]
}

@test "pure prose (no array) still records non-array-output with 0" {
	cd "$TEST_TMP" || return 1
	printf 'I cannot review this diff.\n' >copilot-out.txt
	_run_prefilter
	[ "$status" -eq 0 ]
	[ "$output" = "[]" ]
	row=$(_last_agent_row)
	[ "$(jq -r '.status' <<<"$row")" = "non-array-output" ]
	[ "$(jq -r '.findings' <<<"$row")" = "0" ]
}

@test "finding missing .agent is stamped by the producer and survives dedup" {
	cd "$TEST_TMP" || return 1
	printf '[{"file":"base.sh","line":1,"category":"c","severity":"low","description":"d","confidence":5}]\n' >copilot-out.txt
	_run_prefilter
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.[0].agent')" = "code-reviewer" ]
	[ "$(jq -r '.findings' <<<"$(_last_agent_row)")" = "1" ]
}

@test "non-object elements are dropped loudly, partial:true" {
	cd "$TEST_TMP" || return 1
	printf '["garbage",{"agent":"code-reviewer","file":"base.sh","line":1,"category":"c","severity":"low","description":"d","confidence":5}]\n' >copilot-out.txt
	_run_prefilter
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq 'length')" = "1" ]
	[[ $stderr == *"dropped 1 non-object element"* ]]
	[ "$(jq -r '.partial' <<<"$(_last_agent_row)")" = "true" ]
}

@test "dedup-stage failure exits documented rc=1 with an errored-emit row" {
	cd "$TEST_TMP" || return 1
	printf '[{"agent":"code-reviewer","file":"base.sh","line":1,"category":"c","severity":"low","description":"d","confidence":5}]\n' >copilot-out.txt
	printf '#!/bin/bash\nexit 7\n' >hooks/phase1-dedup.sh
	chmod +x hooks/phase1-dedup.sh
	_run_prefilter
	[ "$status" -eq 1 ]
	[[ $stderr == *"emit/dedup pipeline failed"* ]]
	row=$(jq -sc 'last' "$LOG")
	[ "$(jq -r '.status' <<<"$row")" = "errored-emit" ]
	[ "$(jq -r '.emit_rc' <<<"$row")" = "7" ]
}

@test "phase1-dedup unit: null-agent finding no longer crashes the batch" {
	cd "$TEST_TMP" || return 1
	run --separate-stderr bash -c 'printf %s "[{\"file\":\"f\",\"line\":1,\"category\":\"c\"}]" | hooks/phase1-dedup.sh'
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.[0].cluster_id // empty' | head -c 2)" = "c-" ]
}

@test "phase1-dedup unit: non-object element is dropped, objects survive" {
	cd "$TEST_TMP" || return 1
	run --separate-stderr bash -c 'printf %s "[42,{\"agent\":\"code-reviewer\",\"file\":\"f\",\"line\":1,\"category\":\"c\"}]" | hooks/phase1-dedup.sh'
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq 'length')" = "1" ]
}
