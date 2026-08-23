#!/usr/bin/env bats
# covers: scripts/ship-pr-cycle.sh
#
# #234 (Wave H): the phase2 round-cap. Before this, phase2 only advanced on
# findings==0 — but the local CR-CLI is non-deterministic on a large diff
# (findings oscillate 4→1→0→1→4), so a substantively-clean PR could loop
# forever chasing an LLM minor-tail. The cap mirrors phase1's scaler graduation
# (#792): after `_scaler_rounds` CR-CLI runs on a given sha, the cap engages.
# #238: the cap advances ONLY if every residual finding is ADDRESSED (the shared
# cr_phase2_clean_for_sha coverage check — the SAME one the pre-push gate uses);
# else it emits the address-residuals directive and stays, never riding past an
# unaddressed finding of any severity.
#
# Drives `ship-pr-cycle.sh next` against a tmp git repo (same harness as
# ship-pr-cycle-cr-conflict-check.bats). The findings>0 branch makes NO `gh`
# call — it only invokes the CR-CLI (stubbed), the scaler (stubbed), and counts
# this-BRANCH runs (git rev-list main..HEAD; #2354) from cr-local-review.jsonl
# (seeded). Outcomes covered: p2runs>=cap → push; p2runs<cap → directive+stay;
# cap honors the scaler value (dynamic, not a constant); missing log → p2runs=0
# (legit first run); rev-list/rev-parse/jq failure → fail-closed (rc 2).

# @bats test bodies run as subshells, so shellcheck flags the per-test
# STUB_ROUNDS export (SC2030/SC2031) as "lost in subshell" — false positive:
# each export feeds the PATH/consumer-resolved scaler stub child WITHIN the same
# test and is never read across tests. Same disable as cr-conflict-check.bats.
# shellcheck disable=SC2030,SC2031

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/ship-pr-cycle.sh"
	TEST_TMP=$(mktemp -d -t ship-p2cap.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# Tmp git repo so the script's REPO_ROOT (git rev-parse --show-toplevel)
	# resolves to it, making the consumer-first resolve-plugin-helper pick the
	# stubs below ($REPO_ROOT/.claude/$rel wins — resolve-plugin-helper.sh:39).
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		# #2354: the phase2 round-cap now counts CR-CLI runs PER-BRANCH
		# (git rev-list main..HEAD), so the fixture must model a real PR branch —
		# main + >=1 commit ahead. The commit is --allow-empty so git diff
		# main...HEAD stays empty (the content-hash cache key is unchanged) while
		# git rev-list main..HEAD is non-empty (the cap counts the branch commit).
		git branch -M main
		git checkout -q -b feat-2354-cap
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m work
		mkdir -p .claude/scripts/cr .claude/hooks .claude/logs
	) || {
		echo "FATAL: TEST_TMP fixture init failed (git/mkdir)" >&2
		return 1
	}
	# Canonical root + shas (macOS resolves mktemp /var → /private/var, so derive
	# via git, not $TEST_TMP). State files key on the FULL sha; the cap's run-log
	# counts on the SHORT sha (git rev-parse --short HEAD) — capture both.
	ROOT=$(cd "$TEST_TMP" && git rev-parse --show-toplevel)
	SHA=$(cd "$TEST_TMP" && git rev-parse HEAD)
	SHA_SHORT=$(cd "$TEST_TMP" && git rev-parse --short HEAD)
	STATE_DIR="$ROOT/.claude/.session-state/ship-cycle"
	mkdir -p "$STATE_DIR"

	# Stub CR-CLI: emit the canonical complete event with 2 findings + exit 1
	# (local-review.sh exits 1 — NOT 0 — when CR found things; a valid "ran
	# cleanly" code). _phase2_run_cr_cli parses .findings=2, driving the
	# findings>0 branch where the cap lives. Does NOT append to the run-log —
	# tests seed the count directly (below) so the cap boundary is deterministic;
	# the real local-review.sh appends its own entry (its own contract/tests).
	cat >"$ROOT/.claude/scripts/cr/local-review.sh" <<'STUB'
#!/usr/bin/env bash
# #284: drop a sentinel (relative to cwd = repo root) so the cache-HIT tests can
# assert this stub was NOT invoked — the skip-invocation / 10-hr-budget contract.
touch .claude/.local-review-ran 2>/dev/null || true
printf '%s\n' '{"type":"complete","findings":2}'
exit 1
STUB
	chmod +x "$ROOT/.claude/scripts/cr/local-review.sh"

	# Stub scaler → deterministic cap. _scaler_rounds runs it with --explain and
	# parses a `ROUNDS=N` line. Honors STUB_ROUNDS (default 3) so a test can vary
	# the cap and prove it's dynamic.
	cat >"$ROOT/.claude/hooks/phase1-scaler.sh" <<'STUB'
#!/usr/bin/env bash
printf 'ROUNDS=%s\n' "${STUB_ROUNDS:-3}"
exit 0
STUB
	chmod +x "$ROOT/.claude/hooks/phase1-scaler.sh"
}

teardown() {
	# shellcheck disable=SC2164 # best-effort; rm guarded below
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */ship-p2cap.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Pre-set the state file to phase2 on the current HEAD (full) sha.
_seed_stage() {
	printf '{"version":1,"stage":"%s","branch":"feat/v0.31.0/234-test","sha":"%s","history":[]}\n' \
		"$1" "$SHA" >"$STATE_DIR/$SHA.json"
}

_cur_stage() {
	jq -r '.stage' "$STATE_DIR/$SHA.json"
}

# Seed N prior CR-CLI run entries for the current SHORT sha into the run-log
# the cap counts (each genuine run appends one `{"sha":...}` line).
_seed_log() {
	local n="$1" i
	mkdir -p "$ROOT/.claude/logs"
	: >"$ROOT/.claude/logs/cr-local-review.jsonl"
	for ((i = 0; i < n; i++)); do
		printf '{"sha":"%s","findings":2}\n' "$SHA_SHORT" >>"$ROOT/.claude/logs/cr-local-review.jsonl"
	done
}

# #238: seed prove-yourself coverage so the shared cr_phase2_clean_for_sha sees
# the run's findings (2, from the stub) as ADDRESSED — a source=cr record scoped
# to the FULL sha (the lib matches covered_sha by short-sha prefix) covering N.
_seed_coverage() {
	mkdir -p "$ROOT/.claude/audit"
	printf '{"source":"cr","covered_sha":"%s","covers_count":%s}\n' "$SHA" "${1:-2}" \
		>"$ROOT/.claude/audit/prove-yourself.jsonl"
}

@test "#1848: resume STOPS at phase2 instead of walking into the CR-CLI" {
	# The phase2 PREREAD gate is emitted on ENTERING phase2. Before this fix
	# cmd_resume only stopped on phase1|merge-gate|merged, so an auto-walk that
	# reached phase2 (a graduated branch short-circuits phase0.5/phase1 inside a
	# single cmd_next) would run the CR-CLI on the NEXT iteration — spending the
	# 10/hr budget before the operator ever read the SKILL. phase2 is now a stop
	# stage: resume returns with the stage still phase2 and no CR-CLI invoked.
	_seed_stage phase2
	# Seed FEWER runs than the cap (1 < 3) so the round-cap path is NOT already
	# satisfied. With 3/3 the test would pass even if resume walked into phase2,
	# because the cap branch would advance it anyway — the assertions would hold
	# for the wrong reason (CR).
	_seed_log 1
	_seed_coverage 2
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run "$SCRIPT" resume
	[ "$status" -eq 0 ]
	# Stage untouched — resume did not advance past the preread gate...
	[ "$(_cur_stage)" = phase2 ]
	# ...and none of the phase2 advance output appears (no CR-CLI walk).
	[[ $output != *"advanced to push"* ]]
	[[ $output != *"round-cap reached"* ]]
	# Strongest assertion (CR): the stub drops .claude/.local-review-ran when it
	# executes, so its ABSENCE proves the CR-CLI was never invoked — the whole
	# point of stopping at the preread gate, and something output-matching alone
	# cannot establish.
	[ ! -e "$TEST_TMP/.claude/.local-review-ran" ]
	# NOT asserted here: that the preread ACK materializes. cmd_resume runs with
	# SHIP_PR_IN_RESUME=1 (emitter prints to stdout, writes no ack file), so the
	# stop branch re-emits with suppression off — but this fixture stubs only the
	# CR-CLI and the scaler, not _lib/ship-cycle-directives.sh + _lib/hook-ack.sh,
	# so no ack can be produced here regardless of the code being correct.
	# Asserting it would fail for a fixture reason, not a behavioural one.
	# Covering it needs a fixture extension — tracked in #1848's follow-up.
}

@test "phase2 at round-cap WITH all residuals addressed advances to push (#234/#238)" {
	# 3 runs logged, cap=3 → 3>=3 AND every finding addressed (prove-yourself
	# scoped to sha) → advance. #238: the cap now requires coverage to advance.
	_seed_stage phase2
	_seed_log 3
	_seed_coverage 2
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"round-cap reached (3/3)"* ]]
	[[ $output == *"addressed"* ]]
	[[ $output == *"advanced to push"* ]]
	[ "$(_cur_stage)" = push ]
}

@test "phase2 at round-cap but residuals NOT addressed → directive, stays (#238)" {
	# 3 runs logged, cap=3, but NO prove-yourself coverage → the cap must NOT
	# advance (never ride past unaddressed findings of any severity); emits the
	# address-residuals directive + stays at phase2.
	_seed_stage phase2
	_seed_log 3
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"round-cap reached (3/3) but"* ]]
	[[ $output == *"NOT all addressed"* ]]
	[[ $output == *"record-rejection"* ]]
	[ "$(_cur_stage)" = phase2 ]
}

@test "phase2 findings>0 under cap (p2runs<cap) emits directive + stays (#234)" {
	# 1 run logged, cap=3 → 1<3 → fix-directive, stage MUST NOT advance.
	_seed_stage phase2
	_seed_log 1
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"phase2 round 1/3"* ]]
	[[ $output == *"DIRECTIVE FOR OPERATOR"* ]]
	[ "$(_cur_stage)" = phase2 ]
}

@test "phase2 cap honors the scaler value, not a constant (#234/#238)" {
	# Prove cap = _scaler_rounds (dynamic). ROUNDS=2 + 2 logged runs + addressed
	# → 2>=2 advances; the same 2 runs under the default cap=3 would still emit a
	# directive (the under-cap test). The cap tracks the scaler.
	_seed_stage phase2
	_seed_log 2
	_seed_coverage 2
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=2
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"round-cap reached (2/2)"* ]]
	[[ $output == *"advanced to push"* ]]
	[ "$(_cur_stage)" = push ]
}

@test "phase2 missing CR-CLI log → p2runs=0 (legit first run), stays (#234)" {
	# CR phase2 r1 (CRITICAL fix): an absent log is a legitimate first run —
	# local-review.sh is the canonical appender, so missing means zero recorded
	# runs for this sha (p2runs=0), NOT a masked fallback to 1 that could
	# vacuously satisfy a cap of 1. With cap=3, 0<3 → directive, no advance.
	_seed_stage phase2
	rm -f "$ROOT/.claude/logs/cr-local-review.jsonl"
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"phase2 round 0/3"* ]]
	[ "$(_cur_stage)" = phase2 ]
}

@test "phase2 corrupt CR-CLI log → jq fails closed (rc 2), no advance (#234 CR r1)" {
	# The old `jq ... 2>/dev/null || echo 1` masked parse errors, silently
	# trusting a corrupt log to drive the cap. Now jq runs without 2>/dev/null
	# and a parse failure is fatal: rc 2, stage unchanged, diagnostic emitted.
	_seed_stage phase2
	mkdir -p "$ROOT/.claude/logs"
	printf 'not valid json at all {{{\n' >"$ROOT/.claude/logs/cr-local-review.jsonl"
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run "$SCRIPT" next
	[ "$status" -eq 2 ]
	[[ $output == *"phase2 round-cap — jq failed"* ]]
	[ "$(_cur_stage)" = phase2 ]
}

@test "phase2 cap — git rev-parse --short HEAD failure fails closed (#234 CR r1)" {
	# The sha is resolved before counting; a git failure must halt (rc 2), not
	# feed an empty --arg to jq and silently miscount. Selective git stub: fail
	# ONLY `rev-parse --short` (the cap's sole use — verified) and delegate
	# everything else (rev-parse --show-toplevel / --abbrev-ref) to real git.
	_seed_stage phase2
	_seed_log 1
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	local real_git
	real_git=$(command -v git)
	mkdir -p "$TEST_TMP/gitstub"
	{
		echo '#!/usr/bin/env bash'
		echo 'if [ "$1" = "rev-parse" ] && [ "$2" = "--short" ]; then'
		echo '  echo "stub git: forced rev-parse --short failure" >&2; exit 1'
		echo 'fi'
		printf 'exec %q "$@"\n' "$real_git"
	} >"$TEST_TMP/gitstub/git"
	chmod +x "$TEST_TMP/gitstub/git"
	PATH="$TEST_TMP/gitstub:$PATH"
	run "$SCRIPT" next
	[ "$status" -eq 2 ]
	[[ $output == *"git rev-parse --short HEAD failed"* ]]
	[ "$(_cur_stage)" = phase2 ]
}

@test "phase2 cap — git rev-list BASE..HEAD failure fails closed (#2354)" {
	# #2354 fail-LOUD: the per-branch commit list is resolved before counting;
	# a rev-list failure must halt (rc 2), not feed an empty --arg to jq and
	# silently count 0 runs (which would vacuously (mis)drive the cap). Selective
	# git stub: fail ONLY `rev-list` and delegate everything else to real git so
	# REPO_ROOT resolution + the head_sha rev-parse + the cache-key diff still run.
	_seed_stage phase2
	_seed_log 1
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	local real_git
	real_git=$(command -v git)
	mkdir -p "$TEST_TMP/gitstub"
	{
		echo '#!/usr/bin/env bash'
		echo 'if [ "$1" = "rev-list" ]; then'
		echo '  echo "stub git: forced rev-list failure" >&2; exit 1'
		echo 'fi'
		printf 'exec %q "$@"\n' "$real_git"
	} >"$TEST_TMP/gitstub/git"
	chmod +x "$TEST_TMP/gitstub/git"
	PATH="$TEST_TMP/gitstub:$PATH"
	run "$SCRIPT" next
	[ "$status" -eq 2 ]
	[[ $output == *"git rev-list"*"failed"* ]]
	[[ $output == *"cannot count this-branch CR-CLI runs"* ]]
	[ "$(_cur_stage)" = phase2 ]
}

@test "phase2 round-cap counts runs PER-BRANCH across fix-commits, not per-SHA (#2354)" {
	# The treadmill: per-SHA counting reset the cap each fix-commit, so the
	# ROUNDS cap never bounded cross-commit phase2 iteration. Seed CR-CLI runs
	# against TWO commits on the branch (a prior fix-commit + the new HEAD): the
	# cap must count BOTH (2/2 → advance), where per-SHA would see only the HEAD's
	# single run (1/2 → stay) and loop on the next nitpick.
	cd "$TEST_TMP" || return 1
	local sha1_short sha2 sha2_short
	sha1_short="$SHA_SHORT" # setup()'s branch commit = a prior fix-commit
	# A new HEAD on the same branch → branch now has 2 commits ahead of main.
	git -c user.email=t@t -c user.name=t commit --allow-empty -q -m fix
	sha2=$(git rev-parse HEAD)
	sha2_short=$(git rev-parse --short HEAD)
	printf '{"version":1,"stage":"phase2","branch":"feat-2354-cap","sha":"%s","history":[]}\n' \
		"$sha2" >"$STATE_DIR/$sha2.json"
	# One run-log entry per branch commit: per-SHA counts 1 (HEAD), per-branch 2.
	: >"$ROOT/.claude/logs/cr-local-review.jsonl"
	printf '{"sha":"%s","findings":2}\n' "$sha1_short" >>"$ROOT/.claude/logs/cr-local-review.jsonl"
	printf '{"sha":"%s","findings":2}\n' "$sha2_short" >>"$ROOT/.claude/logs/cr-local-review.jsonl"
	# Coverage scoped to the new HEAD so the cap can advance once REACHED.
	mkdir -p "$ROOT/.claude/audit"
	printf '{"source":"cr","covered_sha":"%s","covers_count":2}\n' \
		"$sha2" >"$ROOT/.claude/audit/prove-yourself.jsonl"
	export STUB_ROUNDS=2
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"round-cap reached (2/2)"* ]] # per-branch=2; per-SHA would be 1/2
	[[ $output == *"advanced to push"* ]]
	[ "$(jq -r '.stage' "$STATE_DIR/$sha2.json")" = push ]
}

@test "phase2 CR review timeout (local-review exit 4) → defers to server CR-in-CI, advances to push (#234)" {
	# A CR review timeout (local-review.sh exit 4 — client-side `timeout` kill
	# or CR's server-side recoverable:false timeout event) is not a code defect:
	# the local CR-CLI can't complete on a large diff. phase2 must advance to
	# push and defer to the AUTHORITATIVE server-side CR-in-CI, honoring CR's
	# unrecoverable signal (no retry). Distinct from rate-limit (rc 3 → wait)
	# and hard failure (rc 2 → halt).
	_seed_stage phase2
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	# Override the CR-CLI stub: emit a timeout event + exit 4 (the SSOT timeout
	# contract local-review.sh now produces).
	cat >"$ROOT/.claude/scripts/cr/local-review.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"type":"error","errorType":"timeout","recoverable":false}'
exit 4
STUB
	chmod +x "$ROOT/.claude/scripts/cr/local-review.sh"
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"timed out unrecoverably"* ]]
	[[ $output == *"advanced to push"* ]]
	[ "$(_cur_stage)" = push ]
}

# --- v0.32.11 (#249-grp / #282): content-hash review cache integration --------
# The cap tests above exercise the cache-MISS path: setup() now creates `main`
# (so the key computes), but seeds NO .review-cache entry → phase2_review_cache_key
# finds no cached result → cache inactive → the CR-CLI stub runs. These drive the
# cache-HIT path — the branch that was previously dead code in this file — by
# seeding phase2-results.jsonl with the key for THIS repo's review surface so the
# dispatch REUSES the count without invoking the CR-CLI, then asserting the
# advance-on-coverage decision.

# Seed the phase2 review-result cache. $1 = cached findings count. Deliberately
# force-renames the CURRENT branch (setup()'s feat-2354-cap) to main via
# `git branch -M main`, repointing main onto HEAD — NOT idempotent: it makes
# main==HEAD so the cache-key diff resolves. main...HEAD is then empty (the branch
# commits are --allow-empty, so no content change), yielding the stable empty-blob
# key computed here exactly as the lib does (empty stdin → git hash-object).
_seed_cache() {
	(cd "$ROOT" && git branch -M main) || return 1
	local key
	key=$(cd "$ROOT" && git diff main...HEAD 2>/dev/null | git hash-object --stdin)
	mkdir -p "$ROOT/.claude/.review-cache"
	printf '{"ts":"2026-01-01T00:00:00Z","content_hash":"%s","sha":"%s","findings":%s}\n' \
		"$key" "$SHA_SHORT" "$1" >"$ROOT/.claude/.review-cache/phase2-results.jsonl"
}

@test "phase2 content-hash cache HIT + 0 findings → advance to push, no CR-CLI (#282)" {
	# Cache says 0 findings for this surface → reuse + advance, never invoking
	# the CR-CLI stub (which would emit 2). findings==0 needs no coverage.
	_seed_stage phase2
	_seed_cache 0
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"cache HIT"* ]]
	[[ $output == *"reusing 0 finding"* ]]
	[[ $output == *"advanced to push"* ]]
	[ "$(_cur_stage)" = push ]
	[ ! -f "$ROOT/.claude/.local-review-ran" ] # cache HIT must NOT invoke local-review.sh
}

@test "phase2 content-hash cache HIT + residuals addressed → advance, no CR-CLI (#282)" {
	# Cache says 2 findings; the prior MISS-run logged them (cr-local-review) and
	# they're covered (prove-yourself) → the cache-HIT branch advances on
	# coverage WITHOUT re-invoking the non-deterministic CR-CLI (the treadmill fix).
	_seed_stage phase2
	_seed_cache 2
	_seed_log 1
	_seed_coverage 2
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"cache HIT"* ]]
	[[ $output == *"addressed"* ]]
	[[ $output == *"advanced to push"* ]]
	[ "$(_cur_stage)" = push ]
	[ ! -f "$ROOT/.claude/.local-review-ran" ] # cache HIT must NOT invoke local-review.sh
}

@test "phase2 content-hash cache HIT + residuals NOT addressed → directive, stays (#282)" {
	# Cache says 2 findings, logged but NOT covered → the cache-HIT branch must
	# emit the address-residuals directive + stay; it must NEVER falsely advance
	# on a hit (fail-closed via cr_phase2_clean_for_sha).
	_seed_stage phase2
	_seed_cache 2
	_seed_log 1
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"cache HIT"* ]]
	[[ $output == *"NOT all addressed"* ]]
	[ "$(_cur_stage)" = phase2 ]
	[ ! -f "$ROOT/.claude/.local-review-ran" ] # cache HIT must NOT invoke local-review.sh
}

# --- #2492/#2493: the cache carries finding DETAIL, not just a count -------
# The unaddressed-cache-HIT directive asks for --severity / --finding-id /
# --finding-text. Before this it supplied only N, so the operator had to either
# burn CR budget re-reviewing identical content or reject blind.

# Seed a cache record that ALSO carries findings_detail (what put() now writes).
_seed_cache_detail() {
	(cd "$ROOT" && git branch -M main) || return 1
	local key
	key=$(cd "$ROOT" && git diff main...HEAD 2>/dev/null | git hash-object --stdin)
	mkdir -p "$ROOT/.claude/.review-cache"
	printf '{"ts":"2026-01-01T00:00:00Z","content_hash":"%s","sha":"%s","findings":2,"findings_detail":[{"severity":"major","file":"hooks/foo.sh","summary":"rc capture aborts under set -e"},{"severity":"minor","file":"scripts/bar.sh","summary":"prefer mktemp over a PID-derived name"}]}\n' \
		"$key" "$SHA_SHORT" >"$ROOT/.claude/.review-cache/phase2-results.jsonl"
}

@test "#2493 cache HIT with unaddressed findings RENDERS the detail" {
	_seed_stage phase2
	_seed_cache_detail
	_seed_log 1
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"NOT all addressed"* ]]
	[[ $output == *"Findings from that review:"* ]]
	[[ $output == *"[major] hooks/foo.sh"* ]]
	[[ $output == *"rc capture aborts under set -e"* ]]
	[[ $output == *"[minor] scripts/bar.sh"* ]]
	[ ! -f "$ROOT/.claude/.local-review-ran" ] # still must not burn CR budget
}

@test "#2493 a LEGACY count-only record still yields the count-only directive" {
	# Records written before findings_detail existed must degrade cleanly —
	# detail is an operator convenience, never a correctness input.
	_seed_stage phase2
	_seed_cache 2 # no findings_detail field at all
	_seed_log 1
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"NOT all addressed"* ]]
	[[ $output != *"Findings from that review:"* ]]
	[ ! -f "$ROOT/.claude/.local-review-ran" ]
}

@test "#2493 a record with findings_detail:[] also degrades to count-only" {
	# Distinct from the missing-field case above: here the field EXISTS but is an
	# empty array (e.g. detail projection returned [] because the file was
	# pruned). Must render exactly like the legacy record, not a stray header.
	_seed_stage phase2
	(cd "$ROOT" && git branch -M main) || return 1
	local key
	key=$(cd "$ROOT" && git diff main...HEAD 2>/dev/null | git hash-object --stdin)
	mkdir -p "$ROOT/.claude/.review-cache"
	printf '{"ts":"2026-01-01T00:00:00Z","content_hash":"%s","sha":"%s","findings":2,"findings_detail":[]}\n' \
		"$key" "$SHA_SHORT" >"$ROOT/.claude/.review-cache/phase2-results.jsonl"
	_seed_log 1
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"NOT all addressed"* ]]
	[[ $output != *"Findings from that review:"* ]]
	[ ! -f "$ROOT/.claude/.local-review-ran" ]
}
