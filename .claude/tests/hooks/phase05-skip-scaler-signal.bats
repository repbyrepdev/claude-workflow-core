#!/usr/bin/env bats
# covers: hooks/phase0.5-copilot-prefilter.sh hooks/phase0.5-codex-prefilter.sh hooks/phase0.5-gemini-prefilter.sh hooks/phase1-scaler.sh
# #2259: (1) the phase0.5 graceful-skip 3-way contract (absent -> skip,
# present-but-broken -> hard-fail, oversized diff -> skip) was dogfood-proven
# but unit-untested; (2) phase1-scaler treated a skip as "ran clean" (a
# skipped-* entry yielded p05_count=0, lowering rounds as if the pre-filter
# vouched for the diff); (3) codex/gemini hard-failed on absent CLI while
# copilot skipped. The resolver roots itself at the tree containing _lib/,
# so a scratch copy of the plugin tree controls every path without mocking.

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	TEST_TMP=$(mktemp -d -t phase05-skip.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	TREE="$TEST_TMP/tree" # scratch plugin tree (hooks/ + _lib/)
	WORK="$TEST_TMP/work" # scratch consumer git repo
	BIN="$TEST_TMP/bin"   # controlled PATH (jq/yq present; codex/gemini absent)
	_mk_fixture || {
		echo "FATAL: fixture build failed" >&2
		return 1
	}
}

teardown() {
	cd /tmp || return 0
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */phase05-skip.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_mk_fixture() {
	mkdir -p "$TREE/hooks" "$TREE/_lib" "$WORK/.claude" "$BIN" || return 1
	# Real hook + lib copies — the resolver's plugin root becomes $TREE.
	cp "$REPO_ROOT/hooks/phase0.5-copilot-prefilter.sh" "$TREE/hooks/" || return 1
	cp "$REPO_ROOT/hooks/phase0.5-codex-prefilter.sh" "$TREE/hooks/" || return 1
	cp "$REPO_ROOT/hooks/phase0.5-gemini-prefilter.sh" "$TREE/hooks/" || return 1
	cp "$REPO_ROOT/_lib/resolve-plugin-helper.sh" "$TREE/_lib/" || return 1
	cp "$REPO_ROOT/_lib/phase05-dedupe.sh" "$TREE/_lib/" || return 1
	# Sourced at end-of-run by the gemini happy path (CR r4 --policy test).
	cp "$REPO_ROOT/_lib/phase05-auth-summary.sh" "$TREE/_lib/" || return 1
	# Sibling helpers the hooks preflight (stubs; never invoked on skip paths).
	printf '#!/bin/bash\ncat\n' >"$TREE/hooks/phase1-dedup.sh" || return 1
	printf '#!/bin/bash\ncat\n' >"$TREE/hooks/phase0.5-dedupe-against-audit.sh" || return 1
	chmod +x "$TREE/hooks/phase1-dedup.sh" "$TREE/hooks/phase0.5-dedupe-against-audit.sh" || return 1
	# Consumer repo: main + feature branch with a real diff. -b main pins
	# the branch name so the hooks' default --base main is host-independent
	# (init.defaultBranch varies).
	(cd "$WORK" &&
		git init -q -b main &&
		git config user.email t@t.t &&
		git config user.name t &&
		printf 'base\n' >f.txt &&
		git add -A && git commit -qm base &&
		git checkout -qb feat/test &&
		printf 'base\nchanged line for the diff\n' >f.txt &&
		git add -A && git commit -qm change) || return 1
	cp "$REPO_ROOT/.claude/review-config.yml" "$WORK/.claude/review-config.yml" || return 1
	# Controlled PATH: coreutils from /usr/bin:/bin, jq/yq symlinked in,
	# codex/gemini deliberately ABSENT regardless of host installs.
	ln -sf "$(command -v jq)" "$BIN/jq" || return 1
	ln -sf "$(command -v yq)" "$BIN/yq" || return 1
	ln -sf "$(command -v git)" "$BIN/git" || return 1
	# CR r6: /usr/bin:/bin stay on PATH for coreutils (shimming ~15 of
	# them is fragile), so the absent-CLI contract holds only while no
	# host ships codex/gemini THERE (brew -> /opt/homebrew, npm ->
	# /usr/local|~). Fail LOUD if an exotic host breaks that assumption
	# instead of letting absent-CLI tests silently test the wrong thing.
	for _cli in codex gemini; do
		if [ -x "/usr/bin/$_cli" ] || [ -x "/bin/$_cli" ]; then
			echo "FATAL: host has $_cli in /usr/bin or /bin - fixture PATH isolation broken" >&2
			return 1
		fi
	done
	return 0
}

_run_hook() { # $1 = hook basename, extra env via leading VAR=val words
	run bash -c "cd '$WORK' && PATH='$BIN:/usr/bin:/bin' $2 bash '$TREE/hooks/$1'"
}

# Assert a log entry with BOTH the status and the per-cli attribution
# on the same log line (CR r3: centralizes the repeated two-grep pattern;
# CR r5: status-neutral name - it asserts skipped-* AND ok entries).
_assert_status_logged() { # $1 = status string, $2 = cli name
	grep "\"$1\"" "$WORK/.claude/logs/phase0.5-run.jsonl" | grep -q "\"cli\":\"$2\""
}

@test "copilot: helper ABSENT from tree+repo -> graceful skip rc=0, [], logged" {
	_run_hook phase0.5-copilot-prefilter.sh ""
	[ "$status" -eq 0 ]
	[[ $output == *"[]"* ]]
	grep -q '"status":"skipped-no-copilot-helper"' "$WORK/.claude/logs/phase0.5-run.jsonl"
}

@test "copilot: helper present but NOT executable -> hard-fail rc=1" {
	mkdir -p "$WORK/.claude/scripts/copilot"
	printf '#!/bin/bash\nexit 0\n' >"$WORK/.claude/scripts/copilot/try-free.sh"
	# deliberately not chmod +x
	_run_hook phase0.5-copilot-prefilter.sh ""
	[ "$status" -eq 1 ]
	[[ $output == *"NOT executable"* ]]
}

@test "copilot: oversized diff -> skip rc=0 with skipped-diff-too-large logged" {
	mkdir -p "$WORK/.claude/scripts/copilot"
	printf '#!/bin/bash\necho "[]"\n' >"$WORK/.claude/scripts/copilot/try-free.sh"
	chmod +x "$WORK/.claude/scripts/copilot/try-free.sh"
	_run_hook phase0.5-copilot-prefilter.sh "PHASE05_DIFF_MAX_BYTES=10"
	[ "$status" -eq 0 ]
	[[ $output == *"[]"* ]]
	grep -q '"status":"skipped-diff-too-large"' "$WORK/.claude/logs/phase0.5-run.jsonl"
}

@test "codex: CLI absent -> graceful skip rc=0, [], logged with cli field (#2259 parity)" {
	_run_hook phase0.5-codex-prefilter.sh ""
	[ "$status" -eq 0 ]
	[[ $output == *"[]"* ]]
	grep -q '"status":"skipped-no-codex-cli"' "$WORK/.claude/logs/phase0.5-run.jsonl"
	# per-cli attribution: the skip entry carries cli:"codex" like every
	# other codex log line
	_assert_status_logged skipped-no-codex-cli codex
}

@test "gemini: CLI absent -> graceful skip rc=0, [], logged with cli field (#2259 parity)" {
	_run_hook phase0.5-gemini-prefilter.sh ""
	[ "$status" -eq 0 ]
	[[ $output == *"[]"* ]]
	grep -q '"status":"skipped-no-gemini-cli"' "$WORK/.claude/logs/phase0.5-run.jsonl"
	_assert_status_logged skipped-no-gemini-cli gemini
}

@test "codex: CLI present but repo config BROKEN -> hard-fail rc=1 (no silent skip)" {
	printf '#!/bin/sh\nexit 0\n' >"$BIN/codex"
	chmod +x "$BIN/codex"
	# no .codex/ dir in the work repo — present-but-broken must stay loud
	_run_hook phase0.5-codex-prefilter.sh ""
	[ "$status" -eq 1 ]
	[[ $output == *".codex"* ]]
}

@test "gemini: CLI present but policy.toml MISSING -> hard-fail rc=1 (#643 stays loud)" {
	printf '#!/bin/sh\nexit 0\n' >"$BIN/gemini"
	chmod +x "$BIN/gemini"
	_run_hook phase0.5-gemini-prefilter.sh ""
	[ "$status" -eq 1 ]
	[[ $output == *"policy.toml"* ]]
}

@test "gemini: happy path passes --policy <policy.toml> at invocation (#643 end-to-end)" {
	# CR r4: the deny-block flag was only preflight-checked ([ -f ] on the
	# file); an arg-capturing stub proves the CLI is actually INVOKED with
	# --policy. Stub records "$@" one-arg-per-line, then emits [].
	printf '#!/bin/sh\nprintf "%%s\\n" "$@" >"%s/gemini-args.txt"\necho "[]"\n' "$TEST_TMP" >"$BIN/gemini"
	chmod +x "$BIN/gemini"
	# macOS ships no `timeout`; shim drops the duration arg and execs the
	# command so the hook's wrapped invocation runs unmodified on any host.
	printf '#!/bin/sh\nshift\nexec "$@"\n' >"$BIN/timeout"
	chmod +x "$BIN/timeout"
	mkdir -p "$WORK/.gemini"
	printf '[deny]\n' >"$WORK/.gemini/policy.toml"
	# One gemini-callable agent so the per-agent loop actually invokes the CLI.
	printf '#!/bin/sh\necho code-reviewer\n' >"$TREE/hooks/list-phase1-agents.sh"
	chmod +x "$TREE/hooks/list-phase1-agents.sh"
	_run_hook phase0.5-gemini-prefilter.sh ""
	[ "$status" -eq 0 ]
	[[ $output == *"[]"* ]]
	[ -f "$TEST_TMP/gemini-args.txt" ]
	grep -qx -- "--policy" "$TEST_TMP/gemini-args.txt"
	grep -q "policy.toml" "$TEST_TMP/gemini-args.txt"
	_assert_status_logged ok gemini
}

@test "codex: oversized diff -> skip rc=0 with skipped-diff-too-large logged" {
	printf '#!/bin/sh\nexit 0\n' >"$BIN/codex"
	chmod +x "$BIN/codex"
	mkdir -p "$WORK/.codex"
	printf '# stub codex config\n' >"$WORK/.codex/config.toml"
	_run_hook phase0.5-codex-prefilter.sh "PHASE05_DIFF_MAX_BYTES=10"
	[ "$status" -eq 0 ]
	[[ $output == *"[]"* ]]
	_assert_status_logged skipped-diff-too-large codex
}

@test "gemini: oversized diff -> skip rc=0 with skipped-diff-too-large logged" {
	printf '#!/bin/sh\nexit 0\n' >"$BIN/gemini"
	chmod +x "$BIN/gemini"
	mkdir -p "$WORK/.gemini"
	printf '# stub deny policy\n' >"$WORK/.gemini/policy.toml"
	_run_hook phase0.5-gemini-prefilter.sh "PHASE05_DIFF_MAX_BYTES=10"
	[ "$status" -eq 0 ]
	[[ $output == *"[]"* ]]
	_assert_status_logged skipped-diff-too-large gemini
}

# ---- phase1-scaler signal tiers (#2259 item 2) ----

_scaler() {
	run bash -c "cd '$WORK' && bash '$REPO_ROOT/hooks/phase1-scaler.sh' --explain --base main"
}

# Shared log-fixture writers (CR r6): the mkdir + rev-parse + printf JSONL
# construction was repeated in every scaler case. Appends are safe - each
# test gets a fresh TEST_TMP from setup().
_log_p05() { # $1=git rev (HEAD/HEAD~1)  $2=agent  $3=findings (raw JSON)  $4=status
	local _sha
	_sha=$(cd "$WORK" && git rev-parse "$1") || return 1
	mkdir -p "$WORK/.claude/logs"
	printf '{"ts":"2026-07-08T00:00:00Z","sha":"%s","phase":"0.5","agent":"%s","findings":%s,"status":"%s"}\n' \
		"$_sha" "$2" "$3" "$4" >>"$WORK/.claude/logs/phase0.5-run.jsonl"
}
_log_cr() { # $1=findings count for the latest CR entry
	mkdir -p "$WORK/.claude/logs"
	printf '{"ts":"2026-07-08T00:00:00Z","findings":%s}\n' "$1" \
		>>"$WORK/.claude/logs/cr-local-review.jsonl"
}

@test "scaler: skipped-* entry is NO SIGNAL -> rounds=2, not all-clean" {
	_log_p05 HEAD "<all>" 0 skipped-no-copilot-helper
	_scaler
	[ "$status" -eq 0 ]
	[[ $output == *"ROUNDS=2"* ]]
	[[ $output == *"tier=no-prefilter-signal"* ]]
}

@test "scaler: ok entry with 0 findings IS a clean signal -> rounds=1 all-clean" {
	_log_p05 HEAD "<all>" 0 ok
	_scaler
	[ "$status" -eq 0 ]
	[[ $output == *"ROUNDS=1"* ]]
	[[ $output == *"tier=all-clean"* ]]
}

@test "scaler: no phase0.5 log at all -> no signal -> rounds=2" {
	_scaler
	[ "$status" -eq 0 ]
	[[ $output == *"ROUNDS=2"* ]]
	[[ $output == *"tier=no-prefilter-signal"* ]]
}

@test "scaler: multi-agent same-ts run SUMS findings (larger entry first)" {
	# One prefilter run logs one entry PER AGENT sharing a single ts. The
	# old single max_by returned the LAST tie's findings (0 here) ->
	# false all-clean; the summed aggregation must yield 4 -> moderate.
	# Larger entry FIRST so the old code provably fails this test.
	_log_p05 HEAD pr-test-analyzer 4 ok
	_log_p05 HEAD comment-analyzer 0 ok
	_scaler
	[ "$status" -eq 0 ]
	[[ $output == *"phase0.5=4"* ]]
	[[ $output == *"ROUNDS=3"* ]]
	[[ $output == *"tier=moderate"* ]]
}

@test "scaler: a skip entry alongside ok entries neither erases signal nor count" {
	_log_p05 HEAD code-reviewer 2 ok
	# cli-tagged skip line (unique shape: cli field + later ts) stays inline.
	sha=$(cd "$WORK" && git rev-parse HEAD)
	printf '{"ts":"2026-07-08T00:00:01Z","sha":"%s","phase":"0.5","cli":"codex","agent":"<all>","findings":0,"status":"skipped-no-codex-cli"}\n' "$sha" \
		>>"$WORK/.claude/logs/phase0.5-run.jsonl"
	_scaler
	[ "$status" -eq 0 ]
	[[ $output == *"phase0.5=2"* ]]
	[[ $output == *"p05_ran=1"* ]]
}

@test "scaler: entries for an OLDER sha do not vouch for HEAD (stale-sha)" {
	# ok entries exist ONLY for the parent commit; HEAD has no signal ->
	# must floor at no-prefilter-signal, not inherit the old all-clean.
	_log_p05 HEAD~1 "<all>" 0 ok
	_scaler
	[ "$status" -eq 0 ]
	[[ $output == *"ROUNDS=2"* ]]
	[[ $output == *"tier=no-prefilter-signal"* ]]
}

@test "scaler: prefilter skip + CR findings keep the normal high tier" {
	# A skip must not cap rounds while CR is screaming: total>0 keeps the
	# finding-count tiers (15 -> high/5), the no-signal floor only applies
	# at total==0.
	_log_p05 HEAD "<all>" 0 skipped-no-copilot-helper
	_log_cr 15
	_scaler
	[ "$status" -eq 0 ]
	[[ $output == *"ROUNDS=5"* ]]
	[[ $output == *"tier=high"* ]]
}

@test "scaler: ALL-malformed findings batch clears the vouch -> no-prefilter-signal" {
	# CR r8 Major (spec change from the earlier drop-and-vouch behavior):
	# an ok batch where EVERY findings value is non-numeric proves nothing
	# - a count built from zero readable values must clear the ran-signal
	# instead of landing in the 1-round all-clean tier.
	_log_p05 HEAD "<all>" null ok
	_scaler
	[ "$status" -eq 0 ]
	[[ $output == *"no numeric findings values"* ]]
	[[ $output == *"ROUNDS=2"* ]]
	[[ $output == *"tier=no-prefilter-signal"* ]]
}

@test "scaler: MIXED malformed batch still sums the readable values" {
	# The type filter stays defensive for partial corruption: one null +
	# one numeric 4 -> sum 4, signal intact -> moderate tier.
	_log_p05 HEAD comment-analyzer null ok
	_log_p05 HEAD pr-test-analyzer 4 ok
	_scaler
	[ "$status" -eq 0 ]
	[[ $output == *"phase0.5=4"* ]]
	[[ $output == *"ROUNDS=3"* ]]
	[[ $output == *"tier=moderate"* ]]
}
