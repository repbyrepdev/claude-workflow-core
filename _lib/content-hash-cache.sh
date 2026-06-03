#!/bin/bash
set -euo pipefail
# auto-register: false
# v4.28-W3-C (#671): unified per-file content-hash cache primitives.
#
# All review-style operations (Phase 1 agents, bats-gate, CR-CLI,
# prove-yourself dogfood audit) source this library + record/lookup
# against ONE ledger keyed by `(reviewer × file × git-blob-sha)`.
#
# Why blob-sha not commit-sha:
#   - Invariant under rebase / commit metadata churn
#   - Changes ONLY when file content actually changes
#   - `git hash-object <file>` is O(1) per file
#   - Bats-gate already uses this model (correctly); this lib generalizes it
#
# Ledger location: .claude/.review-cache/ledger.jsonl (gitignored).
# Format: {"ts":<iso8601>, "reviewer":<id>, "file":<path>, "blob_sha":<sha>,
#          "status":<ok|fail|errored>, "evidence_ref":<optional path>}
# Currently only `ok` is recorded by all 5 callers (phase1, bats, cr-cli,
# prove-yourself-fix, prove-yourself-rejection); fail/errored are reserved
# for future caller use.
#
# Reviewer IDs:
#   - phase1-<agent-name>  (e.g. phase1-code-reviewer)
#   - bats
#   - cr-cli
#   - prove-yourself-fix
#   - prove-yourself-rejection
#
# This file is sourced, not executed. Functions:
#   cache_blob_sha <file>                 — emit git hash-object of file
#   cache_lookup <reviewer> <file>        — emit "ok"/"fail"/"" based on
#                                           current blob-sha vs ledger
#   cache_record <reviewer> <file> <status> [evidence_ref]
#                                          — append entry to ledger
#   cache_evidence_stale <prove_yourself_id>
#                                          — return 0 if cited file blob-sha
#                                            differs from record-time
#   cache_prune                           — drop entries older than 30d
#
# Caller idempotency: the lookup is purely a function of (reviewer, file,
# current-blob-sha). Re-recording with the same triple is a no-op duplicate
# entry; the lookup uses the LATEST entry.

# r1 code-reviewer #1: only set REPO_ROOT if caller hasn't (composes
# cleanly with consumers that compute their own repo root, e.g.
# local-review.sh + prove-yourself-audit do `git rev-parse` first).
# v0.34.29 (#2224, CR critical): the dirname-relative fallback is
# LAYOUT-DEPENDENT and mis-resolved in consumers. This lib lives at
# <repo>/_lib/ in the PLUGIN (so dirname/.. = repo) but at
# <repo>/.claude/_lib/ in CONSUMERS (so dirname/.. = <repo>/.claude, one
# level too shallow). Prefer `git rev-parse --show-toplevel`, which returns
# the true repo root in BOTH layouts; fall back to dirname-relative only when
# not in a git work tree (e.g. a standalone tarball sourcing). Every
# production caller still pre-sets REPO_ROOT, so the `:-` default is the
# defensive path; making it layout-agnostic removes a latent consumer bug.
REPO_ROOT="${REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd))}"
CACHE_DIR="$REPO_ROOT/.claude/.review-cache"
CACHE_LEDGER="$CACHE_DIR/ledger.jsonl"

_cache_init() {
	mkdir -p "$CACHE_DIR"
	[ -f "$CACHE_LEDGER" ] || : >"$CACHE_LEDGER"
}

# Compute git blob-sha for a file. Empty/missing file → empty output.
# Uses git hash-object so the SHA matches what git would record on commit.
# r2 sfh #6: surface git failures rather than swallow. A degraded git
# object DB returning empty here would silently degrade the cache to
# always-miss for every reviewer, with zero operator signal. Now: capture
# stderr to a temp + emit it on non-zero rc so the failure is visible.
cache_blob_sha() {
	local file=$1
	[ -f "$file" ] || return 0
	local err sha rc=0
	err=$(mktemp)
	sha=$(git -C "$REPO_ROOT" hash-object "$file" 2>"$err") || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "cache_blob_sha: git hash-object failed for $file (rc=$rc):" >&2
		cat "$err" >&2
		rm -f "$err"
		return "$rc"
	fi
	rm -f "$err"
	printf '%s\n' "$sha"
}

# Look up the latest cache entry for (reviewer, file). Emits status if the
# entry's blob_sha matches the file's CURRENT blob-sha; empty otherwise.
# Empty output = cache miss (caller must re-run the reviewer).
cache_lookup() {
	local reviewer=$1 file=$2
	_cache_init
	local current_sha
	current_sha=$(cache_blob_sha "$file")
	[ -z "$current_sha" ] && return 0
	# Latest matching entry where blob_sha equals current. Filter the
	# slurped ledger array by (reviewer, file, blob_sha), return .[-1]
	# (last appended = most recent timestamp).
	jq -rs --arg r "$reviewer" --arg f "$file" --arg s "$current_sha" '
		map(select(.reviewer==$r and .file==$f and .blob_sha==$s))
		| if length == 0 then "" else .[-1].status end
	' "$CACHE_LEDGER" 2>/dev/null
}

# Record a cache entry. Appends — never updates in place.
# Args: reviewer file status [evidence_ref]
cache_record() {
	local reviewer=$1 file=$2 status=$3 evidence_ref=${4:-}
	_cache_init
	local blob_sha ts
	blob_sha=$(cache_blob_sha "$file")
	[ -z "$blob_sha" ] && {
		echo "cache_record: cannot resolve blob_sha for $file" >&2
		return 1
	}
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	jq -nc --arg ts "$ts" --arg r "$reviewer" --arg f "$file" \
		--arg b "$blob_sha" --arg s "$status" --arg e "$evidence_ref" '
		{ts:$ts, reviewer:$r, file:$f, blob_sha:$b, status:$s}
		+ (if $e == "" then {} else {evidence_ref:$e} end)
	' >>"$CACHE_LEDGER"
}

# Determine if a prove-yourself audit record's cited evidence is stale.
# Returns 0 (true, stale) if any cited file's CURRENT blob-sha differs from
# the blob-sha at record-time. Returns 1 (false, fresh) if all cited files
# match. r1 comment-analyzer #1+#2: callers pass the audit-id which IS
# the basename of the JSON state file (the prove-yourself state writer
# slugs the finding into a deterministic basename — see
# `_state_file_for_finding` in prove-yourself-audit/run.sh). Cited files
# come from the --cited-files arg of record-fix/record-rejection, NOT
# from --dogfood-cmd output (corrected from earlier comment drift).
cache_evidence_stale() {
	local audit_id=$1
	local audit_file="$REPO_ROOT/.claude/.session-state/prove-yourself/${audit_id}.json"
	[ -f "$audit_file" ] || {
		echo "cache_evidence_stale: audit record $audit_id not found" >&2
		return 1
	}
	# Each cited file: compare current blob-sha to record-time blob-sha.
	# If ANY mismatch → stale (return 0).
	local cited stale=0
	cited=$(jq -r '.cited_files[]? | "\(.file)|\(.blob_sha)"' "$audit_file" 2>/dev/null)
	[ -z "$cited" ] && return 1 # no cited files → not stale
	while IFS='|' read -r file recorded_sha; do
		[ -z "$file" ] && continue
		local current_sha
		current_sha=$(cache_blob_sha "$file")
		if [ "$current_sha" != "$recorded_sha" ]; then
			stale=1
			echo "cache_evidence_stale: $file changed since record (was $recorded_sha, now $current_sha)" >&2
			break
		fi
	done <<<"$cited"
	[ "$stale" -eq 1 ] && return 0
	return 1
}

# Prune entries older than RETENTION_DAYS (default 30). Idempotent.
# Defined for future maintenance-hook integration; current pruning of the
# ledger routes through scripts/maintain/log-retention.sh's `jsonl` entry
# in .claude/log-retention.yml. Comment kept narrow to avoid claiming a
# wiring that doesn't exist yet.
# r2 sfh #1: same fail-loud pattern as log-retention.sh _prune_jsonl —
# prior `jq ... && mv` silently no-op'd on jq parse failure, leaving the
# cache backing every reviewer (Phase 1, bats, CR, prove-yourself) with
# no operator signal. Now: capture jq stderr + rc-check + refuse to mv
# on failure.
cache_prune() {
	local retention=${1:-30}
	_cache_init
	local cutoff
	cutoff=$(date -u -v-"${retention}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		date -u -d "${retention} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || {
		echo "cache_prune: cannot compute cutoff (date tool variant?)" >&2
		return 1
	}
	# v0.32.11 (#249-grp): prune BOTH ledgers — the per-file ledger AND the
	# phase2 review-result ledger (PHASE2_RESULT_LEDGER was previously never
	# pruned, so it grew unbounded; latest-wins kept reads correct but the file
	# still bloated). Per-ledger failures are isolated (continue + rc=1) so one
	# bad file never skips the other.
	local ledger rc=0
	for ledger in "$CACHE_LEDGER" "$PHASE2_RESULT_LEDGER"; do
		[ -s "$ledger" ] || continue
		local tmp jq_err jq_rc=0
		tmp=$(mktemp) || {
			echo "cache_prune: mktemp failed for tmp ($ledger)" >&2
			rc=1
			continue
		}
		jq_err=$(mktemp) || {
			echo "cache_prune: mktemp failed for jq_err ($ledger) — fail closed" >&2
			rm -f "$tmp"
			rc=1
			continue
		}
		jq -c --arg cutoff "$cutoff" 'select(.ts >= $cutoff)' \
			"$ledger" >"$tmp" 2>"$jq_err" || jq_rc=$?
		if [ "$jq_rc" -ne 0 ]; then
			echo "cache_prune: jq prune failed for $ledger (rc=$jq_rc):" >&2
			cat "$jq_err" >&2
			rm -f "$tmp" "$jq_err"
			rc=1
			continue
		fi
		# Checked rename: an unchecked mv could leave the ledger unpruned while
		# the function reports success — fail closed for this ledger instead.
		if ! mv "$tmp" "$ledger"; then
			echo "cache_prune: mv failed for $ledger — left unpruned, fail closed" >&2
			rm -f "$tmp" "$jq_err"
			rc=1
			continue
		fi
		rm -f "$jq_err"
	done
	return "$rc"
}

# --- Phase 2 review-result cache (v0.32.11 #249-grp: cap-reset treadmill fix) -
# The per-file ledger above answers "is THIS file clean?". This separate,
# coarser cache answers "what did the CR-CLI find for the WHOLE review
# surface?" — the committed diff CR reviews under `-t committed --base <base>`
# (= <base>...HEAD). ship-pr-cycle's phase2 consults it BEFORE invoking the
# CR-CLI: an unchanged review surface reuses the prior findings count instead
# of re-running CR's non-deterministic engine, which on identical content
# oscillates false-positives + burns the 10/hr Pro Plus budget (the treadmill
# that hit PR #254 across 3 re-reviews of one unchanged SHA). A new commit or
# main advancing changes the hash → miss → fresh review (correct). Keyed on the
# diff CONTENT, not the commit SHA, so a no-op amend/rebase that preserves
# content still hits.
PHASE2_RESULT_LEDGER="$CACHE_DIR/phase2-results.jsonl"

# Emit the content hash of the phase2 review surface (committed diff vs base).
# Empty output on ANY git failure → caller treats it as "no key" and always
# reviews (fail-safe: a key we cannot compute is never a false hit).
# The key is the diff CONTENT only — deliberately NOT salted with the CR engine
# / ruleset version: content-identity IS the dedup goal, and the server-side
# CR-in-CI stays the authoritative merge gate. To force a re-review after a CR
# engine/ruleset change, change the diff or clear PHASE2_RESULT_LEDGER.
phase2_review_cache_key() {
	local base=${1:-main}
	local diff d_err d_rc=0
	# 3-dot: changes on this branch since it diverged from base — mirrors CR's
	# committed-review surface. hash-object gives a stable content digest.
	# v0.34.29 (CR-in-CI #2226): mirror the hash-object hardening below — a git
	# diff failure (bad base ref / degraded object DB) was a silent fail-open
	# (the exact pattern this PR kills); capture stderr + emit a breadcrumb on
	# non-zero rc, still returning empty (fail-safe: caller does a fresh review,
	# never a false cache hit).
	# v0.34.30 (#2230): EXCLUDE the prove-yourself audit ledger + session-state
	# from the review-surface diff. The tracked .claude/audit/prove-yourself.jsonl
	# (and .claude/.session-state/ audit records) live IN CR's committed-review
	# surface, so committing audit records busts this content-hash key + needlessly
	# re-triggers the CR-CLI — an "audit-commit treadmill". These paths are
	# bookkeeping, never part of the code under review, so excluding them keeps the
	# key stable across pure audit-record commits. Pathspec excludes append after a
	# `--` and compose with the 3-dot range (verified under the real git engine).
	d_err=$(mktemp 2>/dev/null) || d_err=""
	diff=$(git -C "$REPO_ROOT" diff "${base}...HEAD" -- \
		':(exclude).claude/audit/prove-yourself.jsonl' \
		':(exclude).claude/.session-state/' 2>"${d_err:-/dev/null}") || d_rc=$?
	if [ "$d_rc" -ne 0 ]; then
		if [ -n "$d_err" ] && [ -s "$d_err" ]; then
			echo "phase2_review_cache_key: git diff failed — no cache key (forces a fresh review): $(head -c 160 "$d_err")" >&2
		else
			echo "phase2_review_cache_key: git diff failed — no cache key (forces a fresh review)" >&2
		fi
		[ -n "$d_err" ] && rm -f "$d_err"
		return 0
	fi
	[ -n "$d_err" ] && rm -f "$d_err"
	# v0.34.29 (#2224, ptt #102): a bare `|| true` swallowed hash-object
	# failure silently — an empty key → caller always reviews (fail-safe) but
	# with ZERO operator signal that key computation is broken (e.g. a degraded
	# object DB). Mirror phase2_review_cache_get's hardening: capture stderr +
	# emit a breadcrumb on non-zero rc, still returning empty (no false hit).
	local key h_err h_rc=0
	h_err=$(mktemp 2>/dev/null) || h_err=""
	key=$(printf '%s' "$diff" | git -C "$REPO_ROOT" hash-object --stdin 2>"${h_err:-/dev/null}") || h_rc=$?
	if [ "$h_rc" -ne 0 ]; then
		if [ -n "$h_err" ] && [ -s "$h_err" ]; then
			echo "phase2_review_cache_key: git hash-object failed — no cache key (forces a fresh review): $(head -c 160 "$h_err")" >&2
		else
			echo "phase2_review_cache_key: git hash-object failed — no cache key (forces a fresh review)" >&2
		fi
		[ -n "$h_err" ] && rm -f "$h_err"
		return 0
	fi
	[ -n "$h_err" ] && rm -f "$h_err"
	printf '%s' "$key"
}

# Emit the cached findings count for a content-hash key (latest entry wins);
# empty on miss. Always returns 0 — a miss is normal, not an error.
phase2_review_cache_get() {
	local key=$1
	[ -n "$key" ] || return 0
	[ -f "$PHASE2_RESULT_LEDGER" ] || return 0
	local out jq_err jq_rc=0
	jq_err=$(mktemp 2>/dev/null) || jq_err=""
	out=$(jq -rs --arg k "$key" '
		map(select(.content_hash == $k)) | if length == 0 then "" else (.[-1].findings | tostring) end
	' "$PHASE2_RESULT_LEDGER" 2>"${jq_err:-/dev/null}") || jq_rc=$?
	if [ "$jq_rc" -ne 0 ]; then
		# Corrupt ledger → treat as a MISS (fail-safe: forces a real review,
		# never a false hit) BUT surface a breadcrumb so a persistently-corrupt
		# ledger is visible instead of silently eating a review every cycle
		# (matches this file's r2-sfh hardening; silent-failure-hunter conf4).
		if [ -n "$jq_err" ] && [ -s "$jq_err" ]; then
			echo "phase2_review_cache_get: jq read failed on $PHASE2_RESULT_LEDGER — treating as miss (fresh review): $(head -c 160 "$jq_err")" >&2
		else
			echo "phase2_review_cache_get: jq read failed on $PHASE2_RESULT_LEDGER — treating as miss (fresh review)" >&2
		fi
		[ -n "$jq_err" ] && rm -f "$jq_err"
		return 0
	fi
	[ -n "$jq_err" ] && rm -f "$jq_err"
	printf '%s' "$out"
}

# Record a phase2 review result. Best-effort — a write failure must never fail
# the review (worst case is a future miss → one extra review, not data loss).
phase2_review_cache_put() {
	local key=$1 findings=$2 sha=${3:-}
	[ -n "$key" ] || return 0
	[[ $findings =~ ^[0-9]+$ ]] || return 0
	_cache_init || return 0
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || ts=""
	# v0.34.30 (#2230): mirror the _get/cache-key stderr hardening — a silent
	# `2>/dev/null || return 0` swallowed jq-append failures (e.g. a read-only
	# CACHE_DIR or a degraded jq), leaving the result cache silently never-written
	# with ZERO operator signal. Capture stderr + emit a concise breadcrumb on
	# failure, then still return 0 (best-effort: a write miss costs one extra
	# review, never a failed cycle).
	local jq_err jq_rc=0
	jq_err=$(mktemp 2>/dev/null) || jq_err=""
	jq -nc --arg k "$key" --argjson f "$findings" --arg s "$sha" --arg ts "$ts" \
		'{ts:$ts, content_hash:$k, sha:$s, findings:$f}' >>"$PHASE2_RESULT_LEDGER" 2>"${jq_err:-/dev/null}" || jq_rc=$?
	if [ "$jq_rc" -ne 0 ]; then
		if [ -n "$jq_err" ] && [ -s "$jq_err" ]; then
			echo "phase2 cache write failed: $(head -c 160 "$jq_err")" >&2
		else
			echo "phase2 cache write failed" >&2
		fi
		[ -n "$jq_err" ] && rm -f "$jq_err"
		return 0
	fi
	[ -n "$jq_err" ] && rm -f "$jq_err"
}
