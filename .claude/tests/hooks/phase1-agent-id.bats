#!/usr/bin/env bats
# covers: hooks/phase1-agent-id.sh hooks/phase1-resume-message.sh hooks/phase1-agent-ids-session-clear.sh
#
# v0.30.F (#193): the SendMessage-resume substrate — agentId registry
# (record/get/directive/resumed/clear/list), the peer-review message builder,
# and the SessionStart staleness-clear hook. Each test runs the real script in
# an ISOLATED temp git repo so REPO_ROOT (git rev-parse --show-toplevel) +
# the .session-state store resolve inside the tmpdir, never the plugin repo.

setup() {
	REPO="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
	AID="$REPO/hooks/phase1-agent-id.sh"
	MSG="$REPO/hooks/phase1-resume-message.sh"
	CLEAR="$REPO/hooks/phase1-agent-ids-session-clear.sh"
	[ -x "$AID" ] && [ -x "$MSG" ] && [ -x "$CLEAR" ]

	TMP="$(mktemp -d -t p1aid.XXXXXX)"
	cd "$TMP" || return 1
	git init -q
	git config user.email t@t.t
	git config user.name t
	git commit -q --allow-empty -m init
	HEAD_SHA="$(git rev-parse HEAD)"
	# A second, distinct 40-hex sha for delta tests (no second commit needed).
	OTHER_SHA="$(printf 'b%039d' 1 | tr ' ' 0)"
	STORE="$TMP/.claude/.session-state/phase1-agent-ids"
	# A valid-shaped agentId (matches the live probe format a<hex>).
	AGENTID="a872508899e04c95a"
	# Resume path requires the experimental flag; default it ON for these
	# tests, individual flag-off tests unset it explicitly.
	export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
}

teardown() {
	[ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# Write a record file directly for deterministic control of resume_count /
# last_sha (the `record` subcommand always starts at resume_count=0).
_mk_record() {
	local agent=$1 aid=$2 last_sha=$3 rc=${4:-0}
	mkdir -p "$STORE"
	printf '{"agent":"%s","agentId":"%s","sha":"%s","last_sha":"%s","resume_count":%s,"first_recorded":1}\n' \
		"$agent" "$aid" "$last_sha" "$last_sha" "$rc" >"$STORE/$agent.json"
}

# ---------------- phase1-agent-id.sh : record / get ----------------

@test "record creates a valid JSON record with resume_count 0" {
	run bash "$AID" record code-reviewer "$AGENTID" "$HEAD_SHA"
	[ "$status" -eq 0 ]
	[ -f "$STORE/code-reviewer.json" ]
	run jq -r '.agentId' "$STORE/code-reviewer.json"
	[ "$output" = "$AGENTID" ]
	run jq -r '.resume_count' "$STORE/code-reviewer.json"
	[ "$output" = "0" ]
}

@test "get echoes the recorded agentId" {
	bash "$AID" record code-reviewer "$AGENTID" "$HEAD_SHA"
	run bash "$AID" get code-reviewer
	[ "$status" -eq 0 ]
	[ "$output" = "$AGENTID" ]
}

@test "get on a missing agent is empty + rc 0" {
	run bash "$AID" get never-recorded
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "record rejects a path-traversal agent name (rc 2)" {
	run bash "$AID" record "../evil" "$AGENTID" "$HEAD_SHA"
	[ "$status" -eq 2 ]
	[ ! -e "$TMP/.claude/.session-state/evil.json" ]
}

@test "record rejects a non-conforming agentId (rc 2)" {
	run bash "$AID" record code-reviewer 'bad id;rm -rf' "$HEAD_SHA"
	[ "$status" -eq 2 ]
}

@test "record rejects a malformed sha (rc 2)" {
	run bash "$AID" record code-reviewer "$AGENTID" "not-a-sha"
	[ "$status" -eq 2 ]
}

# ---------------- phase1-agent-id.sh : directive (READ-ONLY) ----------------

@test "directive is EMPTY when the flag is off (byte-identical fallback)" {
	_mk_record code-reviewer "$AGENTID" "$OTHER_SHA" 0
	CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0 run bash "$AID" directive code-reviewer 2 main "$HEAD_SHA"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "directive is EMPTY on round 1 (baseline always fresh)" {
	_mk_record code-reviewer "$AGENTID" "$OTHER_SHA" 0
	run bash "$AID" directive code-reviewer 1 main "$HEAD_SHA"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "directive is EMPTY when no record exists" {
	run bash "$AID" directive code-reviewer 2 main "$HEAD_SHA"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "directive EMITS a SendMessage line when eligible (round>1, delta, under cap)" {
	_mk_record code-reviewer "$AGENTID" "$OTHER_SHA" 0
	run bash "$AID" directive code-reviewer 2 main "$HEAD_SHA"
	[ "$status" -eq 0 ]
	[[ $output == *"SendMessage to=$AGENTID"* ]]
	[[ $output == *"resume 1/3"* ]]
}

@test "directive is READ-ONLY — repeated calls do NOT bump resume_count" {
	_mk_record code-reviewer "$AGENTID" "$OTHER_SHA" 0
	bash "$AID" directive code-reviewer 2 main "$HEAD_SHA" >/dev/null
	bash "$AID" directive code-reviewer 2 main "$HEAD_SHA" >/dev/null
	run jq -r '.resume_count' "$STORE/code-reviewer.json"
	[ "$output" = "0" ]
}

@test "directive is EMPTY when last_sha == head (no new delta)" {
	_mk_record code-reviewer "$AGENTID" "$HEAD_SHA" 0
	run bash "$AID" directive code-reviewer 2 main "$HEAD_SHA"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "directive is EMPTY when the resume cap is reached (forces fresh)" {
	_mk_record code-reviewer "$AGENTID" "$OTHER_SHA" 3
	run bash "$AID" directive code-reviewer 5 main "$HEAD_SHA"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "PHASE1_RESUME_CAP override changes the cap boundary" {
	_mk_record code-reviewer "$AGENTID" "$OTHER_SHA" 1
	# cap=1 → resume_count 1 >= 1 → empty
	PHASE1_RESUME_CAP=1 run bash "$AID" directive code-reviewer 2 main "$HEAD_SHA"
	[ -z "$output" ]
	# cap=5 → 1 < 5 → emits, shows "resume 2/5"
	PHASE1_RESUME_CAP=5 run bash "$AID" directive code-reviewer 2 main "$HEAD_SHA"
	[[ $output == *"resume 2/5"* ]]
}

# ---------------- phase1-agent-id.sh : resumed (commits state) ----------------

@test "resumed bumps resume_count and advances last_sha" {
	_mk_record code-reviewer "$AGENTID" "$OTHER_SHA" 0
	run bash "$AID" resumed code-reviewer "$HEAD_SHA"
	[ "$status" -eq 0 ]
	run jq -r '.resume_count' "$STORE/code-reviewer.json"
	[ "$output" = "1" ]
	run jq -r '.last_sha' "$STORE/code-reviewer.json"
	[ "$output" = "$HEAD_SHA" ]
}

@test "resumed on a missing record warns + rc 0 (does not crash)" {
	run bash "$AID" resumed never-recorded "$HEAD_SHA"
	[ "$status" -eq 0 ]
	[[ $output == *"no record exists"* ]]
}

# ---------------- phase1-agent-id.sh : clear / list / dispatch ----------------

@test "clear <agent> removes that record only" {
	_mk_record code-reviewer "$AGENTID" "$OTHER_SHA" 0
	_mk_record comment-analyzer "$AGENTID" "$OTHER_SHA" 0
	run bash "$AID" clear code-reviewer
	[ "$status" -eq 0 ]
	[ ! -f "$STORE/code-reviewer.json" ]
	[ -f "$STORE/comment-analyzer.json" ]
}

@test "clear (no arg) removes the whole store dir" {
	_mk_record code-reviewer "$AGENTID" "$OTHER_SHA" 0
	run bash "$AID" clear
	[ "$status" -eq 0 ]
	[ ! -d "$STORE" ]
}

@test "clear rejects a bad agent name (rc 2)" {
	run bash "$AID" clear "../evil"
	[ "$status" -eq 2 ]
}

@test "list prints recorded agents + the actual (overridable) cap" {
	_mk_record code-reviewer "$AGENTID" "$OTHER_SHA" 1
	# Phase 2 CR-CLI fix: the cap must reflect PHASE1_RESUME_CAP (now passed via
	# jq --arg), not a hardcoded /3 — env.PHASE1_RESUME_CAP was null (unexported)
	# so list previously always showed /3 regardless of an override.
	PHASE1_RESUME_CAP=5 run bash "$AID" list
	[ "$status" -eq 0 ]
	[[ $output == *"code-reviewer"* ]]
	[[ $output == *"$AGENTID"* ]]
	[[ $output == *"resume=1/5"* ]]
}

@test "unknown subcommand exits 2" {
	run bash "$AID" frobnicate
	[ "$status" -eq 2 ]
}

# ---------------- phase1-resume-message.sh ----------------

_mk_rejection() {
	# $1 = filename stem, $2 = finding_text, $3 = reason
	local dir="$TMP/.claude/.session-state/prove-yourself"
	mkdir -p "$dir"
	jq -n --arg ft "$2" --arg r "$3" \
		'{kind:"rejection", source:"phase1", confidence:4, finding_text:$ft,
		  decision_data:{reason:$r, dogfood_cmd:"grep x y", dogfood_output:"rc=0 nothing", dogfood_rc:0}}' \
		>"$dir/$1.json"
}

@test "resume-message build emits delta scope + response schema" {
	run bash "$MSG" build code-reviewer 2 main "$HEAD_SHA"
	[ "$status" -eq 0 ]
	[[ $output == *"DELTA REVIEW"* ]]
	[[ $output == *"git diff main..$HEAD_SHA"* ]]
	[[ $output == *"new_findings"* ]]
	[[ $output == *"refutations"* ]]
	[[ $output == *"accepted_rejections"* ]]
}

@test "resume-message embeds dismissed findings WITH dogfood evidence" {
	_mk_rejection rej1 "code-reviewer HIGH: unchecked rc on foo" "diagnostic path only; rc captured downstream"
	run bash "$MSG" build code-reviewer 2 main "$HEAD_SHA"
	[ "$status" -eq 0 ]
	[[ $output == *"unchecked rc on foo"* ]]
	[[ $output == *"diagnostic path only"* ]]
	[[ $output == *"dogfood:"* ]]
}

@test "resume-message degrades cleanly with no prove-yourself dir" {
	run bash "$MSG" build code-reviewer 2 main "$HEAD_SHA"
	[ "$status" -eq 0 ]
	[[ $output == *"No findings dismissed yet"* ]]
	# schema still present
	[[ $output == *"new_findings"* ]]
}

@test "resume-message respects the rejection cap" {
	local i
	for i in $(seq 1 5); do _mk_rejection "rej$i" "finding number $i here" "reason $i"; done
	PHASE1_RESUME_REJECTION_CAP=2 run bash "$MSG" build code-reviewer 2 main "$HEAD_SHA"
	[ "$status" -eq 0 ]
	# Exactly 2 of the 5 finding lines should appear (alpha-sorted: rej1, rej2).
	count="$(printf '%s\n' "$output" | grep -c 'finding number')"
	[ "$count" -eq 2 ]
}

@test "resume-message rejects an invalid agent (rc 2)" {
	run bash "$MSG" build "../evil" 2 main "$HEAD_SHA"
	[ "$status" -eq 2 ]
}

# ---------------- phase1-agent-ids-session-clear.sh ----------------

@test "session-clear removes the phase1-agent-ids store" {
	_mk_record code-reviewer "$AGENTID" "$OTHER_SHA" 0
	[ -d "$STORE" ]
	run bash "$CLEAR"
	[ "$status" -eq 0 ]
	[ ! -d "$STORE" ]
}

@test "session-clear is idempotent (no store dir → rc 0)" {
	run bash "$CLEAR"
	[ "$status" -eq 0 ]
}

@test "session-clear leaves OTHER session-state dirs intact" {
	_mk_record code-reviewer "$AGENTID" "$OTHER_SHA" 0
	mkdir -p "$TMP/.claude/.session-state/prove-yourself"
	echo '{}' >"$TMP/.claude/.session-state/prove-yourself/keep.json"
	run bash "$CLEAR"
	[ "$status" -eq 0 ]
	[ ! -d "$STORE" ]
	[ -f "$TMP/.claude/.session-state/prove-yourself/keep.json" ]
}

# ---------------- Phase 1 r1 round-1 finding fixes + coverage gaps ----------------

_mk_corrupt() {
	mkdir -p "$STORE"
	printf 'not valid json {{{ ' >"$STORE/$1.json"
}

@test "PHASE1_RESUME_CAP non-integer falls back to 3 (cap NOT silently disabled)" {
	# resume_count 5 >= 3 → empty. Pre-fix, a garbage cap made the `-ge` test
	# error (rc 2) inside the `if`, skipping the cap and emitting regardless.
	_mk_record code-reviewer "$AGENTID" "$OTHER_SHA" 5
	PHASE1_RESUME_CAP=abc run bash "$AID" directive code-reviewer 2 main "$HEAD_SHA"
	[ "$status" -eq 0 ]
	[[ $output != *"SendMessage"* ]]
}

@test "directive with empty-string agentId falls through (no 'SendMessage to= ')" {
	mkdir -p "$STORE"
	printf '{"agent":"code-reviewer","agentId":"","sha":"%s","last_sha":"%s","resume_count":0}\n' "$OTHER_SHA" "$OTHER_SHA" >"$STORE/code-reviewer.json"
	run bash "$AID" directive code-reviewer 2 main "$HEAD_SHA"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "get with empty-string agentId warns + emits no id" {
	mkdir -p "$STORE"
	printf '{"agent":"code-reviewer","agentId":"","sha":"%s"}\n' "$OTHER_SHA" >"$STORE/code-reviewer.json"
	run bash "$AID" get code-reviewer
	[ "$status" -eq 0 ]
	[[ $output == *"missing/empty .agentId"* ]]
	# stdout (the id itself) must be empty
	run bash -c "bash '$AID' get code-reviewer 2>/dev/null"
	[ -z "$output" ]
}

@test "directive with non-numeric resume_count does NOT abort (resets to 0, emits)" {
	mkdir -p "$STORE"
	printf '{"agent":"code-reviewer","agentId":"%s","sha":"%s","last_sha":"%s","resume_count":"abc"}\n' "$AGENTID" "$OTHER_SHA" "$OTHER_SHA" >"$STORE/code-reviewer.json"
	run bash "$AID" directive code-reviewer 2 main "$HEAD_SHA"
	[ "$status" -eq 0 ]
	[[ $output == *"SendMessage to=$AGENTID"* ]]
	[[ $output == *"resume 1/3"* ]]
}

@test "directive rejects round=0 / bad base / bad head (rc 2)" {
	_mk_record code-reviewer "$AGENTID" "$OTHER_SHA" 0
	run bash "$AID" directive code-reviewer 0 main "$HEAD_SHA"
	[ "$status" -eq 2 ]
	run bash "$AID" directive code-reviewer 2 'bad;ref' "$HEAD_SHA"
	[ "$status" -eq 2 ]
	run bash "$AID" directive code-reviewer 2 main 'nothex'
	[ "$status" -eq 2 ]
}

@test "corrupt record: directive falls through (rc 0, empty) — does not abort" {
	_mk_corrupt code-reviewer
	run bash "$AID" directive code-reviewer 2 main "$HEAD_SHA"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "corrupt record: get warns + rc 0" {
	_mk_corrupt code-reviewer
	run bash "$AID" get code-reviewer
	[ "$status" -eq 0 ]
	[[ $output == *"corrupt"* ]]
}

@test "corrupt record: resumed exits 3 and does NOT clobber the file" {
	_mk_corrupt code-reviewer
	before="$(cat "$STORE/code-reviewer.json")"
	run bash "$AID" resumed code-reviewer "$HEAD_SHA"
	[ "$status" -eq 3 ]
	[ "$(cat "$STORE/code-reviewer.json")" = "$before" ]
}

@test "corrupt record: list prints a corrupt marker (rc 0)" {
	_mk_corrupt code-reviewer
	run bash "$AID" list
	[ "$status" -eq 0 ]
	[[ $output == *"corrupt record"* ]]
}

@test "end-to-end lifecycle: record → directive/resumed chain enforces the cap" {
	bash "$AID" record code-reviewer "$AGENTID" "$OTHER_SHA"
	h1="$(printf 'a%039d' 1 | tr ' ' 0)"
	h2="$(printf 'c%039d' 2 | tr ' ' 0)"
	h3="$(printf 'd%039d' 3 | tr ' ' 0)"
	h4="$(printf 'e%039d' 4 | tr ' ' 0)"
	run bash "$AID" directive code-reviewer 2 main "$h1"
	[[ $output == *"resume 1/3"* ]]
	bash "$AID" resumed code-reviewer "$h1"
	run bash "$AID" directive code-reviewer 3 main "$h2"
	[[ $output == *"resume 2/3"* ]]
	bash "$AID" resumed code-reviewer "$h2"
	run bash "$AID" directive code-reviewer 4 main "$h3"
	[[ $output == *"resume 3/3"* ]]
	bash "$AID" resumed code-reviewer "$h3"
	run bash "$AID" directive code-reviewer 5 main "$h4"
	[ -z "$output" ]
}

@test "resume-message: rejects bad head + unknown subcommand (rc 2)" {
	run bash "$MSG" build code-reviewer 2 main 'nothex'
	[ "$status" -eq 2 ]
	run bash "$MSG" frobnicate
	[ "$status" -eq 2 ]
}

@test "resume-message: one corrupt rejection record does NOT drop valid siblings" {
	_mk_rejection good1 "real finding alpha here" "reason alpha"
	mkdir -p "$TMP/.claude/.session-state/prove-yourself"
	printf 'not json {{{' >"$TMP/.claude/.session-state/prove-yourself/corrupt.json"
	run bash "$MSG" build code-reviewer 2 main "$HEAD_SHA"
	[ "$status" -eq 0 ]
	[[ $output == *"real finding alpha"* ]]
}

@test "resume-message: unreadable rejection dir fails loud (rc 3) [#193]" {
	if [ "$(id -u)" -eq 0 ]; then skip "#193 rc-3 path relies on DAC perms, which root (uid 0) bypasses"; fi
	mkdir -p "$TMP/.claude/.session-state/prove-yourself"
	printf '{}' >"$TMP/.claude/.session-state/prove-yourself/x.json"
	chmod 000 "$TMP/.claude/.session-state/prove-yourself"
	run bash "$MSG" build code-reviewer 2 main "$HEAD_SHA"
	chmod 755 "$TMP/.claude/.session-state/prove-yourself"
	[ "$status" -eq 3 ]
}

@test "resume-message: non-integer PHASE1_RESUME_REJECTION_CAP falls back to 20 (no cap-skip)" {
	# Phase 2 CR-CLI fix: a garbage cap must not error the -ge test + silently
	# skip the cap. Falls back to 20; all 3 (< 20) records still emit.
	local i
	for i in $(seq 1 3); do _mk_rejection "rej$i" "finding number $i here" "reason $i"; done
	PHASE1_RESUME_REJECTION_CAP=abc run bash "$MSG" build code-reviewer 2 main "$HEAD_SHA"
	[ "$status" -eq 0 ]
	[[ $output == *"falling back to 20"* ]]
	count="$(printf '%s\n' "$output" | grep -c 'finding number')"
	[ "$count" -eq 3 ]
}
