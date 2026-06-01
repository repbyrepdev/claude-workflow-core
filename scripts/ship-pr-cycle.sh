#!/bin/bash
set -euo pipefail
# v4.28-W4 (#657): ship-pr-cycle orchestrator.
#
# Goal: operator interaction = ONE gate (approve-to-ship). Everything else
# autonomous. Drives Phase 0.5 → Phase 1 → Phase 2 → push → CR-in-CI →
# auto-triage → merge-gate as a single state machine.
#
# Relationship to cr-plan (#24): cr-plan is a PARALLEL workflow that runs
# BEFORE ship-pr-cycle, not nested. cr-plan handles issue → epic+subs
# planning; ship-pr-cycle handles branch → merge once an operator has
# picked a sub. No auto-fire from ship-pr-cycle into cr-plan — they are
# disjoint by design (see skills/cr-plan/SKILL.md "Relationship to
# ship-pr-cycle").
#
# State file: .claude/.session-state/ship-cycle/<sha>.json — keyed per-HEAD,
# preserved across amends via branch-pointer linkage at
# .claude/.session-state/ship-cycle/branch/<branch>.json
# (see _update_branch_pointer; #731).
#
# Usage:
#   ship-pr-cycle.sh start           # initialize state for current HEAD
#   ship-pr-cycle.sh status          # show state machine position
#   ship-pr-cycle.sh next            # advance one stage (idempotent)
#   ship-pr-cycle.sh resume          # auto-detect state + advance to terminal
#
# Env:
#   BASE_BRANCH    Comparison branch for "commits on branch" (default: main)
#
# Stages (state.stage):
#   branch-ready      → ≥1 commit ahead of BASE_BRANCH
#   phase0.5          → Copilot prefilter pending
#   phase1            → Claude Phase 1 rounds (cap from scaler tier)
#   phase2            → CR-CLI loop (cap from scaler tier)
#   push              → ready to push to origin
#   cr-in-ci-wait     → waiting for GitHub CR
#   auto-triage       → classify CR threads via scripts/cr/auto-triage.sh (#733)
#   cr-conflict-check → route DIRTY PR through CR resolver before gate (#190)
#   merge-gate        → OPERATOR APPROVES HERE (only interaction)
#   merged            → terminal
#
# Sub-issue scope: #657 (state machine + state-file MVP) + #728 (phase2/push/
# cr-in-ci-wait wiring) + #730 (skill wrapper) + #731 (branch-pointer linkage)
# are all implemented here. Open follow-ups: #732 (Claude-side directive
# hand-off for Phase 1 firing) and #733 (CR-in-CI auto-triage classifier).

# Refuse to run outside a git repo: silently falling back to $PWD makes the
# downstream `_common.sh` source error confusing ("file not found at <cwd>"
# with no hint that the script needed a repo root).
if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
	echo "ship-pr-cycle: ERROR: must be run inside a git repository (cwd=$PWD)" >&2
	exit 2
fi
STATE_DIR="$REPO_ROOT/.claude/.session-state/ship-cycle"
BASE_BRANCH="${BASE_BRANCH-main}"

# v0.7.0 (#19): plugin-cache fallback for shared helpers. Consumer copies
# under .claude/ win (legacy / overrides); plugin cache provides defaults
# so the orchestrator runs in any consumer regardless of whether they ship
# their own .claude/scripts/ or .claude/hooks/. Same alt-path pattern
# v0.6.5+ uses for phase hooks.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_LIB="$(cd "$SCRIPT_DIR/../_lib" 2>/dev/null && pwd || echo "")"
# v0.32.12 (#283): no-op fallback for the next-step directive emitter —
# overridden by _lib/ship-cycle-directives.sh when it sources below. Guarantees
# _emit_stage_directive always exists so its call sites never error (set -e)
# even if the lib is absent (consumer running an older cache, etc.).
_emit_stage_directive() { :; }
if [ -n "$PLUGIN_LIB" ] && [ -f "$PLUGIN_LIB/resolve-plugin-helper.sh" ]; then
	# shellcheck source=../_lib/resolve-plugin-helper.sh
	. "$PLUGIN_LIB/resolve-plugin-helper.sh"
	# v0.32.7 (#238): shared Phase 2 coverage SSOT (also sourced by the pre-push
	# gate) so the round-cap can gate its advance on the SAME "findings=0 OR all
	# addressed" check the gate uses — the cap never advances to a push the gate
	# refuses. Absent/unloadable → the cap use-site below fails CLOSED (clear
	# error + rc 2), never a silent or misleading "findings unaddressed" degrade
	# [#248 CR major: don't silently skip the declared coverage SSOT].
	if [ -r "$PLUGIN_LIB/cr-phase2-coverage.sh" ]; then
		# shellcheck source=../_lib/cr-phase2-coverage.sh
		. "$PLUGIN_LIB/cr-phase2-coverage.sh"
	fi
	# v0.32.11 (#249-grp): phase2 review-result cache (cap-reset treadmill
	# fix) — provides phase2_review_cache_{key,get,put}. Best-effort: if it is
	# absent/unloadable, phase2 simply always invokes the CR-CLI (the prior
	# behavior), so a missing lib degrades gracefully rather than failing
	# closed. REPO_ROOT is already resolved above (from `git rev-parse
	# --show-toplevel`) → the lib keys its ledger off the correct repo (incl.
	# consumers running from the plugin cache).
	if [ -r "$PLUGIN_LIB/content-hash-cache.sh" ]; then
		# shellcheck source=../_lib/content-hash-cache.sh
		# Guard the source: a lib that returns non-zero at source-time must NOT
		# abort the orchestrator under `set -e` (best-effort — if the fns end up
		# undefined the phase2 `command -v` guards fall back to always-review).
		. "$PLUGIN_LIB/content-hash-cache.sh" ||
			echo "ship-pr-cycle: WARN: content-hash-cache.sh source returned non-zero — phase2 cache disabled (always-review fallback)" >&2
	fi
	# v0.32.12 (#283): hook-ack + directive-emitter libs for ack-enforced
	# next-step directives. Source order matters: ship-cycle-directives.sh's
	# _emit_stage_directive overrides the no-op fallback defined above. Guarded
	# (|| warn) so a lib problem can't abort the orchestrator under set -e.
	if [ -r "$PLUGIN_LIB/hook-ack.sh" ]; then
		# shellcheck source=../_lib/hook-ack.sh
		. "$PLUGIN_LIB/hook-ack.sh" ||
			echo "ship-pr-cycle: WARN: hook-ack.sh source returned non-zero — #283 directives advisory-only" >&2
	fi
	if [ -r "$PLUGIN_LIB/ship-cycle-directives.sh" ]; then
		# shellcheck source=../_lib/ship-cycle-directives.sh
		. "$PLUGIN_LIB/ship-cycle-directives.sh" ||
			echo "ship-pr-cycle: WARN: ship-cycle-directives.sh source returned non-zero — #283 directives stdout-only" >&2
	fi
	_shipcycle_resolve() {
		# $1: rel path under .claude/ (e.g. "scripts/_common.sh"). Echoes
		# absolute path; falls back to REPO_ROOT/.claude/$1 when resolver
		# finds nothing (so caller's existence check still fires).
		resolve_plugin_helper "$1" 2>/dev/null || echo "$REPO_ROOT/.claude/$1"
	}
else
	_shipcycle_resolve() { echo "$REPO_ROOT/.claude/$1"; }
fi

# Source common helpers (scm_warn / scm_fail). v0.7.0: via resolver.
# shellcheck source=/dev/null
source "$(_shipcycle_resolve scripts/_common.sh)"

# Pre-flight: jq required for state-file manipulation.
if ! command -v jq >/dev/null 2>&1; then
	echo "ship-pr-cycle: ERROR: jq required (brew install jq / apt install jq)" >&2
	exit 2
fi

# ----- helpers -----

_current_sha() {
	# Surface git errors instead of swallowing into empty output —
	# downstream callers cannot distinguish "unborn HEAD" from "permission
	# denied" from "not a repo" without the underlying git stderr.
	local sha rc=0
	sha=$(git rev-parse HEAD 2>&1) || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "ship-pr-cycle: ERROR: git rev-parse HEAD failed (rc=$rc): $sha" >&2
		return "$rc"
	fi
	printf '%s\n' "$sha"
}

_state_file() {
	# `_current_sha` already errors out loudly on failure; under set -e
	# its non-zero rc aborts the caller before we ever reach an empty-sha
	# branch — so no redundant guard here (r3 dead-code cleanup).
	local sha
	sha=$(_current_sha)
	printf '%s/%s.json\n' "$STATE_DIR" "$sha"
}

_branch_pointer_file() {
	# Single source of truth for the branch pointer path. Both
	# `_init_state` (read) and `_update_branch_pointer` (write) go
	# through here so layout changes propagate atomically.
	# Caller must pre-validate that branch is a usable name (not "HEAD",
	# not containing newline / `..`).
	local branch=$1
	printf '%s/branch/%s.json\n' "$STATE_DIR" "$branch"
}

_phase1_directive_marker_file() {
	# v4.28-W4 (#732): marker file path for the phase1-directive
	# Claude-side hand-off. Sibling to the per-SHA state JSON; lives at
	# `<sha>.phase1-directive.txt` (sibling not subdir — keeps the
	# state-dir layout flat for easier `ls` inspection). Written by
	# cmd_next when state=phase1+streak<2; cleared by _set_stage on
	# transition away from phase1; read by phase1-directive-emit.sh
	# UserPromptSubmit hook to surface to Claude on next prompt.
	local sha=$1
	printf '%s/%s.phase1-directive.txt\n' "$STATE_DIR" "$sha"
}

_write_phase1_directive_marker() {
	# v4.28-W4 (#732): write phase1 directive text to marker so Claude
	# sees it on next UserPromptSubmit even if the orchestrator ran
	# detached.
	# v0.10.0 (#92): NONCE-WRAPPED. Generates a UUID nonce, writes
	# nonce on line 1 + directive text on line 2..N, and stores the
	# nonce in the per-SHA state JSON under .phase1_directive_nonce.
	# ship-cycle-guard.sh Agent path validates sentinel-content ==
	# state-JSON-nonce to defeat touch-bypass of the empty sentinel.
	local sha=$1
	local text=$2
	local marker
	marker=$(_phase1_directive_marker_file "$sha")
	mkdir -p "$STATE_DIR" || {
		scm_warn "phase1-directive marker dir create failed at $STATE_DIR — Claude may miss the hand-off; manual fire required"
		return 0
	}
	# Generate a UUID nonce. Prefer uuidgen (Linux/macOS), fall back
	# to /proc/sys/kernel/random/uuid (Linux), fall back to a
	# python3 oneliner if both missing.
	local nonce=""
	if command -v uuidgen >/dev/null 2>&1; then
		nonce=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')
	fi
	if [ -z "$nonce" ] && [ -r /proc/sys/kernel/random/uuid ]; then
		nonce=$(tr -d '\n' </proc/sys/kernel/random/uuid 2>/dev/null)
	fi
	if [ -z "$nonce" ] && command -v python3 >/dev/null 2>&1; then
		nonce=$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null)
	fi
	if [ -z "$nonce" ]; then
		# CR PR #99 MAJOR: fallback used to write a text-only marker
		# without a nonce, producing a sentinel the guard ALWAYS
		# rejects ('sentinel empty' or 'no nonce on line 1'). That's
		# silent degradation: the orchestrator returns 0 but every
		# subsequent Agent call fails with a misleading 'touch-bypass'
		# message. Fail loudly so operator knows to install a UUID
		# source (uuidgen / python3 / /proc/sys/kernel/random/uuid).
		scm_warn "phase1-directive: nonce generation failed (no uuidgen / /proc / python3) — emit aborted; install uuidgen via 'brew install util-linux' or 'apt install uuid-runtime'"
		return 0
	fi
	# v0.10.0 (#92 r2): write STATE JSON FIRST, sentinel SECOND.
	# Inverse order produced a window where guard saw new-sentinel-
	# nonce vs old-state-nonce → false-positive 'touch-bypass' deny.
	# With state-first ordering, between the two atomic renames the
	# sentinel either doesn't exist or has the OLD nonce — both safe.
	# Use mktemp (not $$) to avoid symlink-race with predictable
	# tmp names.
	local state_file="$STATE_DIR/$sha.json"
	if [ ! -f "$state_file" ]; then
		scm_warn "phase1-directive: state file $state_file missing — emit aborted (run 'ship-pr-cycle.sh start' to initialize)"
		return 0
	fi
	local tmp_state
	if ! tmp_state=$(mktemp "$state_file.XXXXXX" 2>/dev/null); then
		scm_warn "phase1-directive: state-nonce mktemp failed (state dir not writable?) — emit aborted"
		return 0
	fi
	if ! jq --arg n "$nonce" '. + {phase1_directive_nonce: $n}' "$state_file" >"$tmp_state" 2>/dev/null; then
		scm_warn "phase1-directive state-nonce jq merge failed for $state_file"
		rm -f "$tmp_state" 2>/dev/null || true
		return 0
	fi
	if ! mv "$tmp_state" "$state_file"; then
		scm_warn "phase1-directive state-nonce rename failed at $state_file"
		rm -f "$tmp_state" 2>/dev/null || true
		return 0
	fi
	# State JSON now has the new nonce. Write the sentinel.
	local tmp_marker
	if ! tmp_marker=$(mktemp "$marker.XXXXXX" 2>/dev/null); then
		scm_warn "phase1-directive: marker mktemp failed — sentinel not written, Agent calls will be denied until next emit"
		return 0
	fi
	if ! printf '%s\n%s\n' "$nonce" "$text" >"$tmp_marker"; then
		scm_warn "phase1-directive marker write failed at $tmp_marker"
		rm -f "$tmp_marker" 2>/dev/null || true
		return 0
	fi
	if ! mv "$tmp_marker" "$marker"; then
		scm_warn "phase1-directive marker rename failed at $marker"
		rm -f "$tmp_marker" 2>/dev/null || true
		return 0
	fi
}

_clear_phase1_directive_marker() {
	# v4.28-W4 (#732): clear marker when state advances past phase1 so
	# the hook stops emitting a stale directive. `rm -f` is a no-op
	# on missing files — no need for `[ -f ]` guard (CR-in-CI #733 r4
	# trivial: redundant guard removed).
	# CR-in-CI #732 r2 major: rm best-effort under set -e — even
	# `rm -f` can fail under unlikely conditions (read-only fs,
	# directory permissions). _set_stage transition's authoritative
	# `mv "$tmp" "$sf"` is the success criterion.
	# CR-in-CI r3 major: WARN on failure instead of silent swallow —
	# a stale marker can keep getting surfaced by phase1-directive-
	# emit.sh after the stage advanced; operator needs the signal to
	# clean it up manually.
	local sha=$1
	local marker
	marker=$(_phase1_directive_marker_file "$sha")
	rm -f "$marker" ||
		scm_warn "phase1-directive marker cleanup failed at $marker — stale directive may persist until removed manually"
	# CR PR #99 MAJOR (v0.10.1 r2): nonce deletion is now folded into
	# _set_stage's atomic jq transaction (single-write commit of stage
	# transition + nonce delete). Removed the prior second-write
	# best-effort cleanup here — it was a race window where process
	# death between stage-write and nonce-clear could carry a valid
	# nonce past Phase 1.
}

_branch_name_safe_for_pointer() {
	# Branch names from `git rev-parse --abbrev-ref HEAD` are constrained
	# by `git check-ref-format` (no `..`, no leading `-`, no most shell
	# metacharacters). Defense-in-depth: reject newline / CR / `..` / a
	# pure-`/` shape that would leave the pointer file at a directory
	# boundary. Caller treats reject as "skip pointer linkage" rather
	# than aborting init — pointer linkage is opportunistic optimization.
	local branch=$1
	case "$branch" in
	"" | HEAD) return 1 ;;
	*$'\n'* | *$'\r'* | *..* | /* | */) return 1 ;;
	esac
	return 0
}

_init_state() {
	# Initialize state for current HEAD if missing. Lazy mkdir keeps
	# non-state-mutating invocations (help, status-before-start, unknown
	# subcmd) from polluting disk.
	local sf
	sf=$(_state_file)
	if [ -f "$sf" ]; then
		# State file already exists — ensure branch pointer is also
		# written. Covers: (a) rollout — state file pre-dates branch-
		# pointer feature; (b) one-time pointer-write failure on prior
		# init — pointer never landed, next amend would have no
		# inheritance; (c) prior init occurred when branch was unsafe
		# (e.g. detached HEAD subsequently named).
		# Capture jq stderr to surface a corrupt existing-state file
		# (matches `_get_stage` discipline). Without this, a corrupt
		# state file's backfill silently no-ops — leaving the operator
		# with no audit signal that pointer linkage failed to land.
		local existing_payload existing_jq_err existing_jq_err_file existing_jq_rc=0
		existing_jq_err_file=$(mktemp -t ship-cycle-existing-jq.XXXXXX) ||
			scm_fail "mktemp for existing-state jq stderr capture failed"
		existing_payload=$(jq -r '[.branch // "", .sha // ""] | @tsv' "$sf" 2>"$existing_jq_err_file") || existing_jq_rc=$?
		[ -s "$existing_jq_err_file" ] && existing_jq_err=$(cat "$existing_jq_err_file")
		rm -f "$existing_jq_err_file"
		if [ "$existing_jq_rc" -ne 0 ]; then
			scm_warn "existing state file $sf is corrupt (jq rc=$existing_jq_rc): ${existing_jq_err:-<no stderr>} — backfill skipped, pointer linkage may be missing for this SHA. hint: rm '$sf' and re-run 'start'."
			return 0
		elif [ -n "${existing_jq_err:-}" ]; then
			# rc=0 + stderr → jq emitted a deprecation/advisory warning.
			# Mirrors the rc=0+stderr arm of branch_stderr handling
			# (the elif clause below `git rev-parse` capture).
			# Surface so the operator can act before it becomes a regression.
			scm_warn "existing state read jq emitted stderr on rc=0 (advisory): $existing_jq_err"
		fi
		local existing_branch existing_sha
		IFS=$'\t' read -r existing_branch existing_sha <<<"$existing_payload"
		if _branch_name_safe_for_pointer "$existing_branch" && [ -n "$existing_sha" ]; then
			local existing_pointer existing_ts
			existing_pointer=$(_branch_pointer_file "$existing_branch")
			if [ ! -f "$existing_pointer" ]; then
				existing_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
				_update_branch_pointer "$existing_branch" "$existing_sha" "$existing_ts"
			fi
		fi
		return 0
	fi
	mkdir -p "$STATE_DIR"
	local sha branch ts branch_err_file branch_stderr="" branch_rc=0
	sha=$(_current_sha)
	# Capture stderr to a separate file so a rc=0-with-stderr-noise
	# (safe.directory pseudo-warnings, corp git wrappers, gitlfs hooks)
	# does NOT pollute `.branch` in the state file with multi-line
	# warning text. The previous `2>&1` form coupled stderr into the
	# success-path variable.
	branch_err_file=$(mktemp -t ship-cycle-rev-parse-err.XXXXXX) ||
		scm_fail "mktemp for rev-parse stderr capture failed"
	branch=$(git rev-parse --abbrev-ref HEAD 2>"$branch_err_file") || branch_rc=$?
	[ -s "$branch_err_file" ] && branch_stderr=$(cat "$branch_err_file")
	rm -f "$branch_err_file"
	# Note: no trap-based cleanup — between mktemp (above) and rm here
	# there is no scm_fail / set -e exit path. Adding a RETURN trap
	# masks the function's rc under set -e in some bash versions.
	if [ "$branch_rc" -ne 0 ]; then
		scm_warn "git rev-parse --abbrev-ref HEAD failed (rc=$branch_rc): $branch_stderr — recording branch=HEAD"
		branch="HEAD"
	elif [ "$branch" = "HEAD" ]; then
		scm_warn "HEAD is detached; state file will record branch=HEAD"
	elif [ -n "$branch_stderr" ]; then
		scm_warn "git rev-parse --abbrev-ref HEAD emitted stderr on rc=0 (ignored from .branch): $branch_stderr"
	fi
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	# Branch-pointer linkage (#731): on a fresh HEAD for a known branch,
	# clone phase counters + history from the prior SHA's state so amends
	# don't orphan progress. Branch=HEAD (detached) skips this entirely.
	local prior_sha="" prior_state=""
	if _branch_name_safe_for_pointer "$branch"; then
		local pointer_file
		pointer_file=$(_branch_pointer_file "$branch")
		if [ -f "$pointer_file" ]; then
			# Capture jq stderr separately — corrupt pointer file must
			# surface as scm_warn (matches `_get_stage` + `_phase2_run_cr_cli`
			# discipline), not silently fall through to fresh-init which
			# would orphan all amend-inheritance progress without warning.
			local pointer_jq_err pointer_jq_err_file pointer_jq_rc=0
			pointer_jq_err_file=$(mktemp -t ship-cycle-pointer-jq.XXXXXX) ||
				scm_fail "mktemp for pointer jq stderr capture failed"
			prior_sha=$(jq -r '.sha // empty' "$pointer_file" 2>"$pointer_jq_err_file") || pointer_jq_rc=$?
			[ -s "$pointer_jq_err_file" ] && pointer_jq_err=$(cat "$pointer_jq_err_file")
			rm -f "$pointer_jq_err_file"
			if [ "$pointer_jq_rc" -ne 0 ]; then
				scm_warn "branch pointer $pointer_file is corrupt (jq rc=$pointer_jq_rc): ${pointer_jq_err:-<no stderr>} — initializing fresh, prior progress orphaned. hint: rm '$pointer_file' to clear stale pointer."
				prior_sha=""
			elif [ -n "${pointer_jq_err:-}" ]; then
				scm_warn "branch pointer read jq emitted stderr on rc=0 (advisory): $pointer_jq_err"
			fi
		fi
		# Clone state when a prior SHA exists, differs from current HEAD,
		# AND has a usable state file (otherwise initialize fresh — counters
		# reset to 0, history empty).
		if [ -n "$prior_sha" ] && [ "$prior_sha" != "$sha" ] &&
			[ -f "$STATE_DIR/$prior_sha.json" ]; then
			# Validate prior state file IS valid JSON before passing to
			# --argjson — corrupt prior state would otherwise blow up the
			# downstream jq invocation with a generic parse-error message
			# that doesn't point at the prior file as the culprit.
			# Capture stderr separately (matches discipline used for the
			# pointer + existing-state reads above) so a future jq that
			# emits a deprecation warning to stderr on rc=0 doesn't pollute
			# stdout with non-JSON noise that --argjson would then choke on.
			local prior_state_err prior_state_err_file prior_state_rc=0
			prior_state_err_file=$(mktemp -t ship-cycle-prior-state-jq.XXXXXX) ||
				scm_fail "mktemp for prior-state jq stderr capture failed"
			prior_state=$(jq -c . "$STATE_DIR/$prior_sha.json" 2>"$prior_state_err_file") || prior_state_rc=$?
			[ -s "$prior_state_err_file" ] && prior_state_err=$(cat "$prior_state_err_file")
			rm -f "$prior_state_err_file"
			if [ "$prior_state_rc" -ne 0 ]; then
				scm_warn "prior state file $STATE_DIR/$prior_sha.json is corrupt (jq rc=$prior_state_rc): ${prior_state_err:-<no stderr>} — history+counters orphaned, fresh init. hint: rm '$STATE_DIR/$prior_sha.json' or restore from backup."
				prior_state=""
			elif [ -n "${prior_state_err:-}" ]; then
				scm_warn "prior state read jq emitted stderr on rc=0 (advisory): $prior_state_err"
			fi
			# Empty file is a separate failure class from "corrupt JSON" —
			# rc=0 + empty stdout (interrupted write, NFS truncation, manual
			# `>file`, partial backup-restore). Without this guard the
			# `[ -n "$prior_state" ]` test below silently routes to fresh-
			# init with no audit signal. Mirror the corrupt-state warn so
			# operator sees the orphaning event.
			if [ "$prior_state_rc" -eq 0 ] && [ -z "$prior_state" ]; then
				scm_warn "prior state file $STATE_DIR/$prior_sha.json is empty (zero-byte) — history+counters orphaned, fresh init. hint: rm '$STATE_DIR/$prior_sha.json' or restore from backup."
			fi
		fi
	fi
	# Atomic write via tmp + mv (mirrors _set_stage). A crash mid-write
	# would otherwise leave $sf truncated.
	local init_tmp
	init_tmp=$(mktemp "$sf.XXXXXX") || scm_fail "cannot mktemp for init state $sf"
	if [ -n "$prior_state" ]; then
		# Inherit phase counters + history from prior SHA. Reset stage
		# back to branch-ready (new HEAD = fresh review cycle — tracking
		# per-HEAD scope under #674). Append a history entry recording
		# the amend so the chain is auditable.
		jq -n \
			--arg sha "$sha" \
			--arg branch "$branch" \
			--arg ts "$ts" \
			--arg prior "$prior_sha" \
			--argjson prev "$prior_state" \
			'{
				version: 1,
				sha: $sha,
				branch: $branch,
				stage: "branch-ready",
				started_at: $ts,
				phase1_rounds: ($prev.phase1_rounds // 0),
				phase2_rounds: ($prev.phase2_rounds // 0),
				history: (($prev.history // []) + [
					{from: ($prev.stage // "unknown"), to: "branch-ready",
					 ts: $ts, reason: "amend-inherit", prior_sha: $prior}
				])
			}' \
			>"$init_tmp" || {
			rm -f "$init_tmp"
			scm_fail "jq init state (clone path) failed"
		}
	else
		jq -n \
			--arg sha "$sha" \
			--arg branch "$branch" \
			--arg ts "$ts" \
			'{version: 1, sha: $sha, branch: $branch, stage: "branch-ready",
			  started_at: $ts, phase1_rounds: 0, phase2_rounds: 0, history: []}' \
			>"$init_tmp" || {
			rm -f "$init_tmp"
			scm_fail "jq init state failed"
		}
	fi
	# Write order: pointer FIRST, then state file. If the script crashes
	# between the two writes, the pointer references a non-existent state
	# file → next start fresh-inits that SHA without inheritance (graceful
	# degrade). The reverse order would leave a "live" SHA invisible to
	# amend-inheritance because the early-return at the top of _init_state
	# skips re-init when a state file exists, regardless of whether a
	# pointer was ever recorded.
	if _branch_name_safe_for_pointer "$branch"; then
		_update_branch_pointer "$branch" "$sha" "$ts"
	fi
	mv "$init_tmp" "$sf" || scm_fail "failed to atomically create state file $sf"
}

_update_branch_pointer() {
	# Write `.claude/.session-state/ship-cycle/branch/<branch>.json`
	# mapping branch → latest known SHA + timestamp. Atomic mktemp+mv.
	# Branch names can contain `/` (e.g. feat/x) — mkdir on the dirname
	# of the full pointer path so nested directories are created.
	#
	# Caller MUST pre-validate via `_branch_name_safe_for_pointer` —
	# writing branch/HEAD.json clobbers across unrelated detached states
	# (#731), and pathological names (`..`, newline) escape the pointer
	# directory layout.
	local branch=$1 sha=$2 ts=$3
	local pointer_file
	pointer_file=$(_branch_pointer_file "$branch")
	mkdir -p "$(dirname "$pointer_file")" ||
		scm_fail "cannot mkdir branch pointer parent dir for $pointer_file"
	local pointer_tmp
	pointer_tmp=$(mktemp "$pointer_file.XXXXXX") ||
		scm_fail "cannot mktemp for branch pointer $pointer_file"
	jq -n --arg sha "$sha" --arg branch "$branch" --arg ts "$ts" \
		'{branch: $branch, sha: $sha, updated_at: $ts}' \
		>"$pointer_tmp" || {
		rm -f "$pointer_tmp"
		scm_fail "jq branch pointer write failed"
	}
	mv "$pointer_tmp" "$pointer_file" || scm_fail "branch pointer mv failed"
}

_get_stage() {
	local sf
	sf=$(_state_file)
	[ -f "$sf" ] || {
		echo "branch-ready"
		return
	}
	# Capture jq stderr so a corrupt state file produces a clear error
	# (with rm-and-restart hint) instead of an opaque set -e abort.
	local stage rc=0
	stage=$(jq -r '.stage // empty' "$sf" 2>&1) || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "ship-pr-cycle: ERROR: state file $sf is corrupt (jq rc=$rc): $stage" >&2
		echo "  hint: rm '$sf' and re-run 'start' to reinitialize" >&2
		return 2
	fi
	if [ -z "$stage" ]; then
		echo "ship-pr-cycle: ERROR: state file $sf has no .stage field" >&2
		return 2
	fi
	printf '%s\n' "$stage"
}

_set_stage() {
	# Atomically transition stage. Records previous stage in history.
	# mktemp next to $sf guarantees same-filesystem rename(2) — without
	# this `mv` falls back to copy+unlink across volumes (e.g. macOS
	# $TMPDIR vs APFS subvolume), breaking atomicity.
	local new_stage="$1" sf
	sf=$(_state_file)
	[ -f "$sf" ] || _init_state
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local tmp
	tmp=$(mktemp "$sf.XXXXXX") || scm_fail "cannot mktemp next to state file $sf"
	local jq_err jq_rc=0
	# Order: `2>&1 >"$tmp"` puts stderr into $jq_err and stdout into
	# $tmp (the reverse `>"$tmp" 2>&1` would dump both into $tmp,
	# leaving $jq_err empty — shellcheck SC2327/SC2328).
	# CR PR #99 MAJOR: fold phase1_directive_nonce deletion into the
	# SAME jq transaction as the stage transition. Previous design
	# had nonce cleanup as a SECOND best-effort write after the
	# atomic-mv stage commit — if the process died between them, the
	# post-phase1 state could carry a valid nonce + sentinel, letting
	# ship-cycle-guard.sh continue to authorize pr-review-toolkit
	# Agent calls AFTER Phase 1 ended.
	jq_err=$(jq --arg new "$new_stage" --arg ts "$ts" \
		'.history += [{from: .stage, to: $new, ts: $ts}] | .stage = $new | del(.phase1_directive_nonce)' \
		"$sf" 2>&1 >"$tmp") || jq_rc=$?
	if [ "$jq_rc" -ne 0 ]; then
		rm -f "$tmp"
		scm_fail "jq state transition failed (rc=$jq_rc): $jq_err"
	fi
	# Sanity-check tmp before clobbering the real state file. Capture
	# jq's parse-error stderr so failures surface a useful diagnostic
	# (truncated, encoding, schema-drift) instead of a generic message.
	local empty_err empty_rc=0
	empty_err=$(jq empty "$tmp" 2>&1) || empty_rc=$?
	if [ "$empty_rc" -ne 0 ]; then
		rm -f "$tmp"
		scm_fail "jq produced invalid JSON (rc=$empty_rc): $empty_err; refusing to overwrite $sf"
	fi
	mv "$tmp" "$sf" || scm_fail "failed to atomically replace state file $sf"
	# v4.28-W4 (#732): on every stage transition, clear the phase1
	# directive marker (idempotent — no-op when marker missing). If
	# the transition is FROM phase1 to anywhere else, this prevents
	# the UserPromptSubmit hook from surfacing a stale directive.
	# If the transition is into/within other states, the no-op cost
	# is one stat call.
	local sha
	sha=$(_current_sha)
	_clear_phase1_directive_marker "$sha"
}

_get_state_field() {
	# v4.28-W5 (#774): read arbitrary string field from state file.
	# Returns empty string if field missing or state file absent.
	# Mirrors _get_stage's jq-stderr-capture + corrupt-state-halt
	# discipline (return 2 with diagnostic when jq fails — caller
	# sees rc=2 and halts, mirroring _get_stage's contract instead
	# of silently coercing corruption to "field missing").
	local field=$1 sf
	sf=$(_state_file)
	[ -f "$sf" ] || {
		printf ''
		return 0
	}
	local val rc=0
	val=$(jq -r --arg f "$field" '.[$f] // empty' "$sf" 2>&1) || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "ship-pr-cycle: ERROR: _get_state_field $field: jq failed (rc=$rc): $val" >&2
		echo "  hint: rm '$sf' and re-run 'start' to reinitialize" >&2
		return 2
	fi
	printf '%s\n' "$val"
}

_set_state_field() {
	# v4.28-W5 (#774): atomically set arbitrary string field on state
	# file. Mirrors _set_stage's atomic-write discipline (mktemp +
	# jq-validate + mv). Empty value sets the field to an empty
	# string "" (NOT JSON null — jq --arg always passes a string).
	# Used by cr-autofix stage to record entry-SHA so re-runs can
	# detect autofix-commits applied since.
	local field=$1 value=$2 sf
	sf=$(_state_file)
	[ -f "$sf" ] || _init_state
	local tmp
	tmp=$(mktemp "$sf.XXXXXX") || scm_fail "cannot mktemp next to state file $sf"
	local jq_err jq_rc=0
	jq_err=$(jq --arg f "$field" --arg v "$value" \
		'.[$f] = $v' \
		"$sf" 2>&1 >"$tmp") || jq_rc=$?
	if [ "$jq_rc" -ne 0 ]; then
		rm -f "$tmp"
		scm_fail "_set_state_field $field: jq failed (rc=$jq_rc): $jq_err"
	fi
	local empty_err empty_rc=0
	empty_err=$(jq empty "$tmp" 2>&1) || empty_rc=$?
	if [ "$empty_rc" -ne 0 ]; then
		rm -f "$tmp"
		scm_fail "_set_state_field $field: jq produced invalid JSON (rc=$empty_rc): $empty_err; refusing to overwrite $sf"
	fi
	mv "$tmp" "$sf" || scm_fail "_set_state_field $field: failed to atomically replace state file $sf"
}

_phase1_clean_streak() {
	# Count trailing clean rounds in review-log/<sha>.jsonl. A round is
	# clean when (a) total findings across all phase==1 entries == 0
	# AND (b) the round has all expected agents logged. Partial rounds
	# (subset of agents reporting 0 findings while others still in
	# flight) must NOT count as clean — sum=0 alone is indistinguishable
	# from "round done, all clean" without the agent-count check.
	#
	# CRITICAL: must filter to .phase==1 — the per-sha review-log also
	# accumulates phase2 + accept-with-reason entries, both of which can
	# poison the round-grouping (null .round buckets, missing .findings).
	# Surfaces jq errors via scm_warn instead of silently masking with 0,
	# so a malformed JSONL line doesn't quietly wedge convergence.
	local sha=$1
	local rlog="$REPO_ROOT/.claude/review-log/$sha.jsonl"
	[ -f "$rlog" ] || {
		printf '0\n'
		return
	}
	# Resolve expected agent count via list-phase1-agents.sh SSOT. Capture
	# stderr to a tmpfile (mirrors `_scaler_rounds` discipline) so a
	# script regression — schema drift, jq missing, registry-yaml broken —
	# surfaces a scm_warn instead of silently using the stale-default 7.
	# Fallback default 7 chosen to match the DIRECTIVE block enumeration
	# (5 parallel agents + security-review + semgrep) — keep in sync if
	# the directive's agent list changes.
	local expected_agents list_out list_err list_err_file list_rc=0
	list_err_file=$(mktemp -t ship-cycle-list-agents-err.XXXXXX) ||
		scm_fail "mktemp for list-phase1-agents stderr capture failed"
	list_out=$("$(_shipcycle_resolve hooks/list-phase1-agents.sh)" 2>"$list_err_file") || list_rc=$?
	[ -s "$list_err_file" ] && list_err=$(cat "$list_err_file")
	rm -f "$list_err_file"
	if [ "$list_rc" -ne 0 ]; then
		scm_warn "list-phase1-agents.sh exited rc=$list_rc; defaulting expected_agents=7. Stderr: ${list_err:-<no stderr>}"
		expected_agents=7
	else
		# rc=0 + stderr → SSOT script emitted a deprecation/advisory.
		# Surface so a degraded SSOT signal doesn't get masked behind the
		# downstream regex-fallback to 7.
		[ -n "${list_err:-}" ] &&
			scm_warn "list-phase1-agents.sh emitted stderr on rc=0 (advisory): $list_err"
		# `|| true` is required: under `set -e` (errexit, enabled on line 2
		# via `set -euo pipefail`), `grep -c .` returns rc=1 when the input
		# has zero matching lines and that propagates out of the command
		# substitution, aborting the function. The downstream regex
		# `^[1-9][0-9]*$` is the validation gate that catches the resulting
		# `0` and routes to scm_warn — DO NOT remove the regex thinking
		# `|| true` covers the no-output case.
		expected_agents=$(printf '%s\n' "$list_out" | grep -c . || true)
		if ! [[ $expected_agents =~ ^[1-9][0-9]*$ ]]; then
			scm_warn "list-phase1-agents.sh produced no parseable lines (got '$expected_agents'); defaulting to 7. Output: $list_out"
			expected_agents=7
		fi
	fi
	# Emit `<round>\t<sum>\t<distinct-agent-count>` per round, sorted
	# DESCENDING (newest first) so the trailing-clean-streak counter
	# below walks newest → oldest.
	local rounds_data jq_rc=0
	rounds_data=$(jq -s -r '
		map(select(.phase == 1 and .round != null and (.findings // null) != null))
		| group_by(.round)
		| sort_by(-.[0].round)
		| map([
			.[0].round,
			([.[].findings] | add),
			([.[].agent] | unique | length)
		])
		| .[] | @tsv
	' "$rlog" 2>&1) || jq_rc=$?
	if [ "$jq_rc" -ne 0 ]; then
		scm_warn "_phase1_clean_streak: jq pipeline failed walking $rlog (rc=$jq_rc): $rounds_data — defaulting streak=0"
		printf '0\n'
		return
	fi
	local streak=0
	while IFS=$'\t' read -r _round total agent_count; do
		[ -z "$total" ] && continue
		# Round only counts as clean when sum=0 AND all expected agents
		# logged — protects against partial-round false-positives.
		if [ "$total" = "0" ] && [ "$agent_count" -ge "$expected_agents" ]; then
			streak=$((streak + 1))
		else
			break
		fi
	done <<<"$rounds_data"
	printf '%s\n' "$streak"
}

_phase2_run_cr_cli() {
	# Invoke local CR-CLI. local-review.sh exits 1 (NOT 0) when CR found
	# things — both 0 and 1 are valid "ran cleanly" exit codes; only
	# rc>=2 means real invocation failure (auth, rate-limit, missing
	# binary). Print the findings count on stdout, return 0 on either
	# clean exit.
	#
	# Return code convention:
	#   0 = ran cleanly; stdout = integer findings count (caller advances
	#       to push at 0, prints fix-directive at >0)
	#   2 = invocation failure (auth, missing CLI, malformed stdout/jq
	#       parse error). Hard fail — caller surfaces + exits non-zero.
	#   3 = #760: CR rate_limit event detected. Caller treats as
	#       "deferred", stays at phase2, exits cleanly so post-commit-
	#       resume can retry once the local-CR-CLI budget refills.
	#       stdout is empty on rc=3 (no findings count to emit).
	#
	# Counting: prefer the canonical `{"type":"complete",...,"findings":N}`
	# event over grep'ing finding lines (a future stderr line containing
	# the substring `"type":"finding"` would inflate a grep count).
	local cr_script
	cr_script="$(_shipcycle_resolve scripts/cr/local-review.sh)"
	if [ ! -x "$cr_script" ]; then
		echo "ship-pr-cycle: ERROR: $cr_script missing/non-exec" >&2
		return 2
	fi
	# Capture stdout (the JSON-stream contract) separately from stderr
	# (diagnostic noise). Merging them via `2>&1` and parsing the blob
	# would let any stderr line containing JSON-like text confuse the
	# count parse — exactly the silent-failure pattern this PR is
	# meant to eliminate.
	local stdout_file stderr_file rc=0
	stdout_file=$(mktemp -t ship-cycle-cr-stdout.XXXXXX) ||
		scm_fail "mktemp for CR-CLI stdout capture failed"
	stderr_file=$(mktemp -t ship-cycle-cr-stderr.XXXXXX) || {
		rm -f "$stdout_file"
		scm_fail "mktemp for CR-CLI stderr capture failed"
	}
	"$cr_script" >"$stdout_file" 2>"$stderr_file" || rc=$?
	# Replay both streams to operator (stderr → operator stderr;
	# stdout → operator stderr too so CR-CLI's findings show up in the
	# usual Ctrl-C-able foreground stream).
	cat "$stderr_file" >&2
	cat "$stdout_file" >&2
	# v4.28-W5 #838: local-review.sh signals rate_limit via exit code 3
	# (centralized SSOT detection — see #830/#837). Short-circuit to the
	# defer path here rather than re-parsing CR's JSON output ourselves.
	# local-review attempted the rate-budget mark-exhausted write before
	# returning 3, but that write is best-effort (WARN-on-failure); if
	# it failed the rolling window may temporarily under-count, but the
	# defer path here must still fire — the failure mode is "slower budget
	# recovery", not "missed rate_limit".
	if [ "$rc" -eq 3 ]; then
		echo "ship-pr-cycle: phase 2 DEFERRED — CR rate limit exceeded (signaled by local-review.sh)" >&2
		# Audit log — best-effort, rate-budget tracker is canonical. Surface
		# failures so an operator chasing the JSONL isn't confused by silent
		# drops (rate-budget state is the truth, but the audit aids debug).
		local rl_log="$REPO_ROOT/.claude/logs/cr-rate-limit.jsonl"
		local rl_mkdir_err
		rl_mkdir_err=$(mktemp -t ship-cycle-rl-mkerr.XXXXXX 2>/dev/null) || rl_mkdir_err="/dev/null"
		if ! mkdir -p "$(dirname "$rl_log")" 2>"$rl_mkdir_err"; then
			if [ "$rl_mkdir_err" != "/dev/null" ] && [ -s "$rl_mkdir_err" ]; then
				echo "ship-pr-cycle: WARN: mkdir for cr-rate-limit.jsonl failed: $(head -c 200 "$rl_mkdir_err") — audit write skipped" >&2
			else
				echo "ship-pr-cycle: WARN: mkdir for cr-rate-limit.jsonl failed — audit write skipped" >&2
			fi
		else
			local rl_write_err
			rl_write_err=$(mktemp -t ship-cycle-rl-werr.XXXXXX 2>/dev/null) || rl_write_err="/dev/null"
			if ! jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
				'{ts:$ts, source:"ship-pr-cycle._phase2_run_cr_cli", signal:"local-review-rc-3"}' \
				>>"$rl_log" 2>"$rl_write_err"; then
				if [ "$rl_write_err" != "/dev/null" ] && [ -s "$rl_write_err" ]; then
					echo "ship-pr-cycle: WARN: cr-rate-limit.jsonl write failed: $(head -c 200 "$rl_write_err")" >&2
				else
					echo "ship-pr-cycle: WARN: cr-rate-limit.jsonl write failed" >&2
				fi
			fi
			[ "$rl_write_err" != "/dev/null" ] && rm -f "$rl_write_err"
		fi
		[ "$rl_mkdir_err" != "/dev/null" ] && rm -f "$rl_mkdir_err"
		rm -f "$stdout_file" "$stderr_file"
		return 3
	fi
	# v0.32.x (#234): exit 4 = local-review.sh signaled a CR review TIMEOUT
	# (client-side `timeout` kill or CR's server-side unrecoverable timeout
	# event). Distinct from rate_limit (3) and hard failures (auth/malformed):
	# the review couldn't complete, but that's a transient CR-backend limit on
	# a large diff, NOT a code problem. Surface as rc=4 so the caller defers to
	# the authoritative server-side CR-in-CI (mirrors the rc=3 defer contract).
	if [ "$rc" -eq 4 ]; then
		echo "ship-pr-cycle: phase 2 CR review TIMED OUT (local-review.sh exit 4) — deferring to server-side CR-in-CI" >&2
		rm -f "$stdout_file" "$stderr_file"
		return 4
	fi
	if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
		echo "ship-pr-cycle: ERROR: local-review.sh failed with rc=$rc (not a findings-exit)" >&2
		rm -f "$stdout_file" "$stderr_file"
		return "$rc"
	fi
	# #760: pre-filter stdout to JSON-shaped lines only — CR's error path
	# emits trailing non-JSON markers ("[error] stopping cli", "[warning] ...")
	# that previously crashed the `jq -rs` slurp. Each genuine CR-CLI event
	# is a single-line JSON object — anchor on the leading `{` only so the
	# filter is forward-compatible with optional trailing whitespace (jq -rs
	# already validates parseability downstream, so a looser anchor is safe).
	local json_lines_file
	json_lines_file=$(mktemp -t ship-cycle-cr-json.XXXXXX) || {
		rm -f "$stdout_file" "$stderr_file"
		scm_fail "mktemp for CR-CLI json-lines filter failed"
	}
	# grep exit conventions: 0 = match, 1 = no match (legit empty stream:
	# stderr-only output, or CR aborted before emitting any events),
	# 2+ = real error (read failure, invalid regex, binary file). Capture
	# rc and distinguish: rc==1 is acceptable (downstream `jq -rs` on
	# empty file returns `empty` cleanly), rc>1 is fail-loud. Without
	# this discrimination, `|| true` would mask a genuine grep failure.
	local grep_rc=0
	grep -E '^\{' "$stdout_file" >"$json_lines_file" || grep_rc=$?
	if [ "$grep_rc" -gt 1 ]; then
		rm -f "$stdout_file" "$stderr_file" "$json_lines_file"
		scm_fail "grep JSON-line pre-filter failed (rc=$grep_rc)"
	fi

	# v4.28-W5 #838: inline rate_limit JSON parsing removed. local-review.sh
	# is now the SSOT for rate_limit detection (#830) — it parses CR's
	# `{"type":"error","errorType":"rate_limit",...}` events itself + the
	# server-side "out of credits" text page, calls `rate-budget.sh
	# mark-exhausted`, and signals us via exit code 3. The rc=3 short-circuit
	# is at the top of this function (right after invoking local-review).
	# rate_limit *detection* + the canonical exhaustion sentinel both moved
	# out of this function. The rc=3 branch above still writes a minimal
	# `{ts, source, signal}` audit JSONL for operator visibility (separate
	# from the rate-budget tracker — that's the canonical state). waitTime
	# extraction is fully gone (mark-exhausted is no-arg).

	# Parse stdout ONLY for the canonical complete event. Stderr (e.g.
	# "evaluating rule" log lines) cannot leak into the count. Capture
	# jq stderr separately so a parse error surfaces (not silently
	# fall through to the grep fallback). Fail loudly when the complete
	# event is genuinely missing — that means CR was interrupted or
	# emitted malformed output, NOT that findings=0.
	local count count_err count_err_file count_rc=0
	count_err_file=$(mktemp -t ship-cycle-cr-jq-err.XXXXXX) || {
		rm -f "$stdout_file" "$stderr_file" "$json_lines_file"
		scm_fail "mktemp for CR-CLI jq stderr capture failed"
	}
	count=$(jq -rs '
		map(select(.type == "complete")) | if length > 0 then .[-1].findings else empty end
	' "$json_lines_file" 2>"$count_err_file") || count_rc=$?
	[ -s "$count_err_file" ] && count_err=$(cat "$count_err_file")
	rm -f "$count_err_file" "$json_lines_file"
	if [ "$count_rc" -ne 0 ]; then
		echo "ship-pr-cycle: ERROR: _phase2_run_cr_cli jq complete-event parse failed (rc=$count_rc): $count_err" >&2
		echo "  CR-CLI stdout dumped above; do NOT trust the count — re-run after diagnosing." >&2
		rm -f "$stdout_file" "$stderr_file"
		return 2
	fi
	if [ -z "$count" ]; then
		# jq succeeded but produced no output → no `complete` event found.
		# That's CR-CLI being interrupted / malformed stdout; don't advance.
		echo 'ship-pr-cycle: ERROR: CR-CLI emitted no {"type":"complete"} event — output incomplete' >&2
		echo "  hint: re-run; if persistent, diagnose with: $cr_script | jq -s 'map(.type) | unique'" >&2
		rm -f "$stdout_file" "$stderr_file"
		return 2
	fi
	if ! [[ $count =~ ^[0-9]+$ ]]; then
		echo "ship-pr-cycle: ERROR: CR-CLI complete event has non-numeric findings: $count" >&2
		rm -f "$stdout_file" "$stderr_file"
		return 2
	fi
	rm -f "$stdout_file" "$stderr_file"
	printf '%s\n' "$count"
}

# v4.28-W5 #775: extract the inline ~50-line block (PR node-id resolve +
# unresolved-thread count + numeric/error guards) from auto-triage into a
# helper. Auto-triage was the only call-site at extraction time; this PR
# adds a second call site in the pre-push gate's content-aware acceptance
# path (#784 PR-D), so the abstraction is no longer premature.
#
# Args:  $1 = PR number
# Stdout: integer count of unresolved CR threads on success
# Stderr: diagnostic on failure
# Returns: 0 on success, 2 on any failure (mirrors auto-triage stage semantics)
_count_unresolved_threads() {
	local pr_num="${1:-}"
	if [ -z "$pr_num" ] || ! [[ $pr_num =~ ^[0-9]+$ ]]; then
		echo "_count_unresolved_threads: invalid PR number '$pr_num'" >&2
		return 2
	fi
	local pr_node_id pr_id_err pr_id_err_file pr_id_rc=0
	pr_id_err_file=$(mktemp -t ship-cycle-prnodeid-err.XXXXXX) || {
		echo "_count_unresolved_threads: mktemp for pr_node_id stderr capture failed" >&2
		return 2
	}
	pr_node_id=$(gh pr view "$pr_num" --json id --jq .id 2>"$pr_id_err_file") || pr_id_rc=$?
	[ -s "$pr_id_err_file" ] && pr_id_err=$(cat "$pr_id_err_file")
	rm -f "$pr_id_err_file"
	if [ "$pr_id_rc" -ne 0 ] || [ -z "$pr_node_id" ]; then
		echo "_count_unresolved_threads: gh pr view --json id failed (rc=$pr_id_rc): ${pr_id_err:-<no stderr>}" >&2
		return 2
	fi
	local unresolved_count unresolved_err unresolved_err_file unresolved_rc=0
	unresolved_err_file=$(mktemp -t ship-cycle-unresolved-err.XXXXXX) || {
		echo "_count_unresolved_threads: mktemp for unresolved-count stderr capture failed" >&2
		return 2
	}
	# CR PR #790: fetch pageInfo + fail closed when hasNextPage=true.
	# `first:100` undercounts on PRs with >100 review threads, which would
	# route to merge-gate prematurely with unresolved findings. The
	# fail-closed shape mirrors auto-triage's "ship-pr-cycle: ERROR ... stage
	# stays at auto-triage" pattern — better to surface "needs pagination"
	# than silently miss critical CR findings. (Pagination cursor-loop is a
	# follow-up; this guard makes the silent-undercount path loud.)
	local paginated_response
	paginated_response=$(gh api graphql -F prid="$pr_node_id" -f query='
		query($prid:ID!){
		  node(id:$prid){
		    ... on PullRequest {
		      reviewThreads(first:100){
		        pageInfo { hasNextPage }
		        nodes{ isResolved }
		      }
		    }
		  }
		}' 2>"$unresolved_err_file") || unresolved_rc=$?
	[ -s "$unresolved_err_file" ] && unresolved_err=$(cat "$unresolved_err_file")
	rm -f "$unresolved_err_file"
	if [ "$unresolved_rc" -ne 0 ]; then
		echo "_count_unresolved_threads: gh api unresolved-count failed (rc=$unresolved_rc): ${unresolved_err:-<no stderr>}" >&2
		return 2
	fi
	# Pagination guard: refuse to undercount silently.
	# CR PR #790 r7 silent-failure-hunter: capture jq stderr at both
	# extraction points so a non-JSON response (rate-limit HTML, GitHub
	# 5xx, schema drift) surfaces the real cause instead of falling
	# through to the generic "non-numeric" sentinel.
	local has_next pageinfo_err pageinfo_err_file pageinfo_rc=0
	pageinfo_err_file=$(mktemp -t ship-cycle-pageinfo-err.XXXXXX) || {
		echo "_count_unresolved_threads: mktemp for pageinfo stderr capture failed" >&2
		return 2
	}
	has_next=$(printf '%s' "$paginated_response" | jq -r '.data.node.reviewThreads.pageInfo.hasNextPage // false' 2>"$pageinfo_err_file") || pageinfo_rc=$?
	[ -s "$pageinfo_err_file" ] && pageinfo_err=$(cat "$pageinfo_err_file")
	rm -f "$pageinfo_err_file"
	if [ "$pageinfo_rc" -ne 0 ]; then
		echo "_count_unresolved_threads: jq pageInfo parse failed (rc=$pageinfo_rc): ${pageinfo_err:-<no stderr>}; response snippet: $(printf '%s' "$paginated_response" | head -c 200)" >&2
		return 2
	fi
	# CR PR #790 r9 phase2: guard .data.node=null (PR deleted race, perms
	# denied, repo moved). Without this, a null node defaults to false
	# hasNextPage + empty nodes → routes to merge-gate with "0 unresolved".
	local node_exists
	node_exists=$(printf '%s' "$paginated_response" | jq -r '.data.node != null' 2>/dev/null)
	if [ "$node_exists" != "true" ]; then
		echo "_count_unresolved_threads: .data.node is null — PR may have been deleted or is inaccessible; response snippet: $(printf '%s' "$paginated_response" | head -c 200)" >&2
		return 2
	fi
	if [ "$has_next" = "true" ]; then
		echo "_count_unresolved_threads: reviewThreads has >100 entries (pageInfo.hasNextPage=true) — fail closed; pagination cursor-loop is a TODO" >&2
		return 2
	fi
	local count_err count_err_file count_rc=0
	count_err_file=$(mktemp -t ship-cycle-count-err.XXXXXX) || {
		echo "_count_unresolved_threads: mktemp for count stderr capture failed" >&2
		return 2
	}
	unresolved_count=$(printf '%s' "$paginated_response" | jq -r '[.data.node.reviewThreads.nodes[] | select(.isResolved == false)] | length' 2>"$count_err_file") || count_rc=$?
	[ -s "$count_err_file" ] && count_err=$(cat "$count_err_file")
	rm -f "$count_err_file"
	if [ "$count_rc" -ne 0 ]; then
		echo "_count_unresolved_threads: jq count parse failed (rc=$count_rc): ${count_err:-<no stderr>}; response snippet: $(printf '%s' "$paginated_response" | head -c 200)" >&2
		return 2
	fi
	if ! [[ $unresolved_count =~ ^[0-9]+$ ]]; then
		echo "_count_unresolved_threads: unresolved-count non-numeric: '$unresolved_count'" >&2
		return 2
	fi
	printf '%s\n' "$unresolved_count"
	return 0
}

_scaler_rounds() {
	# Resolve MAX_ROUNDS from phase1-scaler tier output. Honored as cap on
	# Phase 1 + Phase 2 convergence chasing. Surfaces scaler stderr on
	# both rc!=0 AND rc=0-but-no-ROUNDS-line — silent default would let a
	# scaler regression (output schema change, broken jq inside scaler)
	# silently cap at min, masking the real cap-from-fallback signal.
	local out rc=0 rounds=""
	out=$("$(_shipcycle_resolve hooks/phase1-scaler.sh)" --explain 2>&1) || rc=$?
	if [ "$rc" -ne 0 ]; then
		scm_warn "phase1-scaler.sh exited rc=$rc; defaulting cap to 2 rounds. Output: $out"
		printf '2\n'
		return
	fi
	# Bash regex loop avoids `set -o pipefail` aborting on grep no-match
	# (the previous `grep -E ... | head -1 | cut` chain returned 1 on
	# missing ROUNDS line, killing the script via set -e).
	while IFS= read -r line; do
		if [[ $line =~ ^ROUNDS=([1-9][0-9]*)$ ]]; then
			rounds="${BASH_REMATCH[1]}"
			break
		fi
	done <<<"$out"
	if [ -z "$rounds" ]; then
		scm_warn "phase1-scaler.sh exited 0 but emitted no parseable ROUNDS=N line; defaulting to 2. Output: $out"
		rounds=2
	fi
	printf '%s\n' "$rounds"
}

# ----- subcommands -----

cmd_start() {
	_init_state
	cmd_status
}

cmd_status() {
	local sf head_sha
	# `_current_sha` may fail (corrupt repo, unborn HEAD); render
	# "<unresolvable>" rather than a confusing empty `$()` substitution.
	if [ ! -f "$(_state_file 2>/dev/null || echo '/dev/null')" ]; then
		head_sha=$(_current_sha 2>/dev/null) || head_sha="<unresolvable>"
		echo "ship-pr-cycle: no state for HEAD $head_sha — run 'start' first"
		return 1
	fi
	sf=$(_state_file)
	echo "=== ship-pr-cycle state ==="
	# Capture jq render failure so a corrupted state file surfaces a
	# friendly hint, not the raw jq parse error from set -e abort.
	if ! jq -r '"  HEAD:        \(.sha)
  Branch:      \(.branch)
  Stage:       \(.stage)
  Started:     \(.started_at)
  Phase 1:     \(.phase1_rounds) round(s)
  Phase 2:     \(.phase2_rounds) round(s)
  History:     \(.history | length) transition(s)"' "$sf" 2>/dev/null; then
		echo "ship-pr-cycle: ERROR: state file $sf appears corrupt — rm and re-run 'start'" >&2
		return 2
	fi
}

cmd_next() {
	# Advance one stage. Caller-driven (one transition per invocation).
	local stage
	stage=$(_get_stage)
	echo "ship-pr-cycle: current stage = $stage"
	case "$stage" in
	branch-ready)
		# Need the base branch to compare against and ≥1 commit ahead.
		# Capture rev-parse stderr (`2>&1 >/dev/null`: stderr → $rev_err
		# via the captured original fd1, stdout → /dev/null) so every
		# git failure mode (whitespace in BASE_BRANCH, permission
		# errors, corrupt .git) surfaces with the underlying message
		# instead of collapsing to "branch does not exist".
		local rev_err rev_rc=0
		rev_err=$(git rev-parse --verify "$BASE_BRANCH" 2>&1 >/dev/null) || rev_rc=$?
		if [ "$rev_rc" -ne 0 ]; then
			echo "ship-pr-cycle: ERROR: cannot resolve base branch '$BASE_BRANCH' (rc=$rev_rc): $rev_err" >&2
			echo "  hint: set BASE_BRANCH=<ref> or check 'git branch -a'" >&2
			return 2
		fi
		local commits
		if ! commits=$(git rev-list --count "${BASE_BRANCH}..HEAD" 2>&1); then
			echo "ship-pr-cycle: ERROR: git rev-list --count failed: $commits" >&2
			return 2
		fi
		if ! [[ $commits =~ ^[0-9]+$ ]]; then
			echo "ship-pr-cycle: ERROR: git rev-list --count returned non-numeric: $commits" >&2
			return 2
		fi
		if [ "$commits" -eq 0 ]; then
			# Shallow clone can return 0 when the base is beyond the
			# fetch boundary even if the branch is "ahead" in reality.
			[ -f "$REPO_ROOT/.git/shallow" ] && scm_warn "rev-list returned 0 vs $BASE_BRANCH but repo is shallow — base may be beyond fetch depth"
			echo "ship-pr-cycle: no commits on branch (vs $BASE_BRANCH) — make a commit first"
			return 1
		fi
		_set_stage "phase0.5"
		echo "→ advanced to phase0.5"
		;;
	phase0.5)
		# v4.28-W5 #856 fix: honor phase-graduation marker across SHAs on
		# the same branch. Once a branch has graduated Phase 0.5/1 (one
		# clean Phase 1 round on any SHA), every subsequent commit on
		# that same branch SHOULD bypass Phase 0.5 entirely — re-running
		# the prefilter on every SHA generates the treadmill where slight
		# wording variations of already-rejected findings keep re-
		# surfacing. The graduation lib (.claude/_lib/phase-graduation.sh)
		# IS the contract; phase0.5-before-phase1.sh hook already honors
		# it for direct Phase 1 invocations. This stage handler is the
		# parallel honor-path for ship-pr-cycle's state machine.
		local _grad_branch _grad_lib _grad_branch_err _grad_rc=0
		# v4.28-W5 #863 CR-CLI fix: capture rc + stderr instead of `|| true`
		# swallow. A real git error (corrupt repo, perms revoked, HEAD
		# missing) silently dropping to per-SHA-log behavior would defeat
		# the whole #856 contract — the gate would fail-open. Now: branch
		# resolution error surfaces a WARN; we still fall through to the
		# per-SHA log path (safer fallback than refusing to advance, which
		# would deadlock the state machine).
		# v4.28-W5 #863 CR-CLI r2: mktemp may itself fail (TMPDIR full,
		# perms). Capture mktemp failure separately and WARN — falling
		# back to /dev/null then ALSO surfacing the git-rc-only WARN
		# would conflate two failure modes. Audit-trail demands the
		# discriminator.
		local _grad_mktemp_rc=0
		_grad_branch_err=$(mktemp -t shipcyc-grad-err.XXXXXX 2>/dev/null) || _grad_mktemp_rc=$?
		if [ "$_grad_mktemp_rc" -ne 0 ]; then
			echo "ship-pr-cycle: WARN: mktemp for graduation stderr-capture failed (rc=$_grad_mktemp_rc) — graduation WARN will be context-less" >&2
			_grad_branch_err="/dev/null"
		fi
		_grad_branch=$(git rev-parse --abbrev-ref HEAD 2>"$_grad_branch_err") || _grad_rc=$?
		if [ "$_grad_rc" -ne 0 ]; then
			if [ "$_grad_branch_err" != "/dev/null" ] && [ -s "$_grad_branch_err" ]; then
				echo "ship-pr-cycle: WARN: graduation branch resolution failed (rc=$_grad_rc): $(head -c 200 "$_grad_branch_err") — falling back to per-SHA phase0.5 log check" >&2
			else
				echo "ship-pr-cycle: WARN: graduation branch resolution failed (rc=$_grad_rc) — falling back to per-SHA phase0.5 log check" >&2
			fi
			_grad_branch=""
		fi
		[ "$_grad_branch_err" != "/dev/null" ] && rm -f "$_grad_branch_err"
		_grad_lib="$(_shipcycle_resolve _lib/phase-graduation.sh)"
		# v4.28-W5 #863 CR-CLI r2: wrap source + graduation_check in
		# `|| true` and a function-existence guard. Without it, a corrupt
		# library (syntax error in source) or a future schema change
		# that renames graduation_check would abort the whole script
		# under `set -e`. Safer: any failure → silently fall through to
		# the per-SHA log check (the gate still works, just slower).
		local _grad_src_rc=0 _grad_src_err
		if [ -n "$_grad_branch" ] && [ -r "$_grad_lib" ]; then
			# v4.28-W5 #863 CR-CLI r3: match the file-wide pattern (lines
			# 217/246/272 etc.) of capturing stderr to a tempfile so a
			# corrupt-library failure surfaces the actual parse error,
			# not just "rc=1". Same defensive pattern for graduation_check
			# itself — its rc=2 means "branch sanitized to empty" or
			# similar diagnostic; suppressing the stderr loses operator
			# actionability.
			# v4.28-W5 #863 CR-CLI r4: mktemp-rc capture matches lines
			# 981-986 pattern (rc=$? + WARN + /dev/null fallback) for
			# consistency. Silent fallback at this site only would
			# violate the file-wide invariant.
			local _grad_src_mktemp_rc=0
			_grad_src_err=$(mktemp -t shipcyc-src-err.XXXXXX 2>/dev/null) || _grad_src_mktemp_rc=$?
			if [ "$_grad_src_mktemp_rc" -ne 0 ]; then
				echo "ship-pr-cycle: WARN: mktemp for graduation-source stderr-capture failed (rc=$_grad_src_mktemp_rc) — graduation source/check WARN will be context-less" >&2
				_grad_src_err="/dev/null"
			fi
			# shellcheck source=/dev/null
			. "$_grad_lib" 2>"$_grad_src_err" || _grad_src_rc=$?
			if [ "$_grad_src_rc" -ne 0 ]; then
				if [ "$_grad_src_err" != "/dev/null" ] && [ -s "$_grad_src_err" ]; then
					echo "ship-pr-cycle: WARN: sourcing $_grad_lib failed (rc=$_grad_src_rc): $(head -c 200 "$_grad_src_err") — falling back to per-SHA phase0.5 log check" >&2
				else
					echo "ship-pr-cycle: WARN: sourcing $_grad_lib failed (rc=$_grad_src_rc) — falling back to per-SHA phase0.5 log check" >&2
				fi
			elif ! command -v graduation_check >/dev/null 2>&1; then
				echo "ship-pr-cycle: WARN: graduation_check function missing after sourcing $_grad_lib — library may be incomplete; falling back to per-SHA log check" >&2
			else
				# Capture graduation_check rc + stderr separately so a
				# non-zero rc (rc=2 = branch sanitized to empty, rc=1 =
				# no marker) surfaces actionable diagnostic on the
				# WARN path. r4 fix: prior code threw away stderr on
				# the implicit `elif graduation_check ...; then`
				# false-branch, losing the operator-actionability the
				# r3 docstring promised.
				local _grad_check_rc=0
				graduation_check "$_grad_branch" 2>"$_grad_src_err" || _grad_check_rc=$?
				if [ "$_grad_check_rc" -eq 0 ]; then
					_set_stage "phase1"
					echo "ship-pr-cycle: branch $_grad_branch already graduated past Phase 0.5/1 — skipping phase0.5 prefilter for this SHA"
					echo "→ advanced to phase1"
					_emit_stage_directive two-step-phase1
					[ "$_grad_src_err" != "/dev/null" ] && rm -f "$_grad_src_err"
					return 0
				fi
				# rc=1 = no graduation marker (common case, no WARN
				# needed). rc>1 = real diagnostic (e.g., shasum missing
				# inside the lib's _grad_safe_branch); surface stderr
				# so operator can address. Silent fall-through on rc=1
				# is the documented behavior.
				if [ "$_grad_check_rc" -gt 1 ]; then
					if [ "$_grad_src_err" != "/dev/null" ] && [ -s "$_grad_src_err" ]; then
						echo "ship-pr-cycle: WARN: graduation_check returned rc=$_grad_check_rc: $(head -c 200 "$_grad_src_err") — falling back to per-SHA phase0.5 log check" >&2
					else
						echo "ship-pr-cycle: WARN: graduation_check returned rc=$_grad_check_rc — falling back to per-SHA phase0.5 log check" >&2
					fi
				fi
			fi
			[ "$_grad_src_err" != "/dev/null" ] && rm -f "$_grad_src_err"
		fi
		echo "ship-pr-cycle: phase0.5 → run .claude/hooks/phase0.5-copilot-prefilter.sh"
		# Phase 0.5 auto-run is wired by .claude/hooks/phase0.5-post-commit-
		# rerun.sh (#728); this stage just verifies it's been logged for
		# current HEAD via a top-level
		# `.sha` exact match. `fromjson?` skips per-line parse errors so
		# a single corrupt write doesn't mask a valid record. The
		# previous substring grep would also match a nested `.sha` field
		# (e.g. inside a future schema's `.history[].sha` array).
		local sha jsonl
		sha=$(_current_sha)
		jsonl="$REPO_ROOT/.claude/logs/phase0.5-run.jsonl"
		if [ ! -f "$jsonl" ]; then
			echo "ship-pr-cycle: phase0.5 not yet logged for $sha"
			return 1
		fi
		if [ ! -r "$jsonl" ]; then
			echo "ship-pr-cycle: ERROR: $jsonl exists but is unreadable" >&2
			return 2
		fi
		# Capture jq stderr to distinguish parse errors (rc>=2) from a
		# legitimate "no record matched" (rc=1). Without this split a
		# truncated log + permission issue + actual no-match all collapse
		# to "phase0.5 not yet logged" — identical observable, divergent
		# remediation.
		local jq_err jq_rc=0
		jq_err=$(jq -e -R --arg sha "$sha" 'fromjson? | select(.sha == $sha)' "$jsonl" 2>&1 >/dev/null) || jq_rc=$?
		# jq -e exit codes: 0 = matched, 1 = matched value was null/false,
		# 4 = no result produced (the "no match" case for our filter), 2/5 =
		# real errors (parse / uncaught). 1+4 both route to "not yet logged".
		case "$jq_rc" in
		0)
			_set_stage "phase1"
			echo "→ phase0.5 logged for $sha; advanced to phase1"
			_emit_stage_directive two-step-phase1
			;;
		1 | 4)
			echo "ship-pr-cycle: phase0.5 not yet logged for $sha"
			return 1
			;;
		*)
			echo "ship-pr-cycle: ERROR: jq failed walking $jsonl (rc=$jq_rc): $jq_err" >&2
			return 2
			;;
		esac
		;;
	phase1)
		# Phase 1 firing itself is operator-driven (Claude invokes the
		# 5 parallel Agents + security-review separately — see
		# feedback_phase1_security_review_separate.md). The orchestrator
		# detects convergence (clean rounds >= cap from scaler in review-log)
		# and advances; otherwise prints the directive for Claude to read.
		#
		# v0.8.4 (#63 fix): if branch is already graduated (phase0.5 + phase1
		# converged once on a prior sha), short-circuit to phase2 without
		# requiring re-convergence on every new sha. This is THE fix for the
		# "every audit-record commit restarts phase1" loop — was costing 6+
		# extra cycles per PR. Per v4.29 design (#792): once Phase 0.5 + 1
		# pass on a branch, they're DONE for that branch.
		# CR r2 fix — graduation short-circuit MUST run before
		# _scaler_rounds + _phase1_clean_streak. Those calls are not pure
		# and can fail on a graduated branch (e.g., missing review-config.yml
		# in plugin source repo), causing phase1 to error before the
		# short-circuit fires. Eval order: graduation first, convergence
		# only if not graduated.
		local sha cap clean_streak
		sha=$(_current_sha)
		# Graduation short-circuit (v0.8.4 #63). Mirrors phase0.5's
		# error-handling discipline (lines ~1000-1085): capture stderr to
		# tmpfile, distinguish source-rc / function-missing / check-rc>1.
		# v0.8.4 CR r1 F2/F3 fix — the prior `2>/dev/null` pattern silenced
		# every lib failure mode and reproduced the very bug this stage's
		# fix was meant to prevent.
		local _grad_lib _grad_branch _grad_check_rc=99 _grad_err
		_grad_lib="$(_shipcycle_resolve _lib/phase-graduation.sh)"
		# N3 fix — mktemp stderr now leaks naturally (was 2>/dev/null
		# which left the WARN context-less and hid the actual cause).
		local _grad_branch_err _grad_branch_rc=0 _grad_branch_mk_rc=0
		_grad_branch_err=$(mktemp -t shipcyc-p1grad.XXXXXX) || _grad_branch_mk_rc=$?
		if [ "$_grad_branch_mk_rc" -ne 0 ]; then
			# F6 fix — was silently falling back to /dev/null which then
			# suppressed every downstream WARN; surface the mktemp failure.
			scm_warn "phase1 graduation: mktemp branch-stderr-capture failed (rc=$_grad_branch_mk_rc) — branch-failure WARN will be context-less"
			_grad_branch_err=/dev/null
		fi
		_grad_branch=$(git rev-parse --abbrev-ref HEAD 2>"$_grad_branch_err") || _grad_branch_rc=$?
		if [ "$_grad_branch_rc" -ne 0 ]; then
			# F7 fix — was branch="" silent fallthrough; now WARN flags
			# that graduation skip is unavailable so operator knows phase1
			# may over-iterate.
			if [ -s "$_grad_branch_err" ]; then
				scm_warn "phase1 graduation: branch resolution failed (rc=$_grad_branch_rc): $(head -c 200 "$_grad_branch_err") — graduation skip unavailable, phase1 may over-iterate"
			else
				scm_warn "phase1 graduation: branch resolution failed (rc=$_grad_branch_rc, no stderr) — graduation skip unavailable"
			fi
			_grad_branch=""
		fi
		[ "$_grad_branch_err" != /dev/null ] && rm -f "$_grad_branch_err"
		if [ -f "$_grad_lib" ] && [ -n "$_grad_branch" ] && [ "$_grad_branch" != "HEAD" ]; then
			# N3 fix — same as branch mktemp above.
			local _grad_check_mk_rc=0
			_grad_err=$(mktemp -t shipcyc-p1grad-check.XXXXXX) || _grad_check_mk_rc=$?
			if [ "$_grad_check_mk_rc" -ne 0 ]; then
				scm_warn "phase1 graduation: mktemp check-stderr-capture failed (rc=$_grad_check_mk_rc) — check-failure WARN will be context-less"
				_grad_err=/dev/null
			fi
			_grad_check_rc=0
			# shellcheck source=../_lib/phase-graduation.sh
			# Wrap source + check in subshell so a lib parse error or
			# missing function name doesn't abort the whole `case` walk.
			# F1 fix — removed inner `. lib 2>/dev/null` that was eating
			# source-time parse errors before outer capture saw them.
			(
				. "$_grad_lib"
				command -v graduation_check >/dev/null 2>&1 || exit 99
				graduation_check "$_grad_branch"
			) 2>"$_grad_err" || _grad_check_rc=$?
			# F5 fix — function-missing path was silent because $_grad_err
			# is empty (command -v -o-die emits nothing).
			if [ "$_grad_check_rc" -eq 99 ]; then
				scm_warn "phase1 graduation_check function missing after sourcing $_grad_lib (lib incomplete) — fail-open"
			elif [ "$_grad_check_rc" -gt 1 ]; then
				if [ -s "$_grad_err" ]; then
					scm_warn "phase1 graduation_check rc=$_grad_check_rc: $(head -c 200 "$_grad_err")"
				else
					scm_warn "phase1 graduation_check rc=$_grad_check_rc (no stderr captured)"
				fi
			fi
			[ "$_grad_err" != /dev/null ] && rm -f "$_grad_err"
		fi
		if [ "$_grad_check_rc" -eq 0 ]; then
			_set_stage "phase2"
			echo "→ phase1 skipped (branch graduated past Phase 0.5/1); advanced to phase2"
			return 0
		fi
		# Graduation didn't fire — now do the convergence eval. CR r2:
		# delayed until here so a graduated branch never pays the cost
		# of these calls (which can fail on missing review-config.yml).
		cap=$(_scaler_rounds)
		clean_streak=$(_phase1_clean_streak "$sha")
		# v0.8.4 (#63): criterion is `>= cap from scaler`, not hardcoded 2.
		# When scaler returns 1 (small/trivial diff), one clean round is
		# enough; demanding 2 was costing extra rounds on every pin bump.
		if [ "$clean_streak" -ge "$cap" ]; then
			_set_stage "phase2"
			echo "→ phase1 converged ($clean_streak-clean-streak ≥ $cap cap); advanced to phase2"
		else
			# v4.28-W4 (#732): write the directive ALSO to a marker file
			# so the phase1-directive-emit UserPromptSubmit hook can
			# surface it to Claude on next prompt — covers the case
			# where post-commit-ship-cycle fired `resume` detached and
			# the stdout heredoc landed in a log Claude doesn't read.
			# v0.7.2 (#26): emit per-agent prompt from canonical lib so the
			# READ-ONLY + treadmill-proof boilerplate is in EVERY agent
			# invocation, not just operator-memory. Per feedback memory
			# `phase1-agents-readonly`, agents have full Edit/Write tool
			# access — without explicit READ-ONLY directive they auto-
			# apply suggestions + get stuck 7-min in tool-rejection loops.
			local prompt_lib
			prompt_lib="$SCRIPT_DIR/../_lib/phase1-agent-prompt.sh"
			local directive_text
			directive_text="ship-pr-cycle: phase1 — cap from scaler = $cap rounds; current clean-streak = $clean_streak
  DIRECTIVE FOR OPERATOR (Claude):
    Per memory:feedback_phase1_security_review_separate.md — the security-
    review Skill MUST fire SEPARATELY from the parallel Agent block, else
    the pending-file gate kills it. Per memory:phase1-agents-readonly,
    every agent prompt MUST include the READ-ONLY directive (templated
    via _lib/phase1-agent-prompt.sh).

    Order:
    1. Block A: 5 parallel Agent calls — use the templated prompt for
       each (READ-ONLY + treadmill-proof + scope-bounded):
         $prompt_lib code-reviewer \"$REPO_ROOT\" \"$sha\" <round>
         $prompt_lib code-simplifier \"$REPO_ROOT\" \"$sha\" <round>
         $prompt_lib comment-analyzer \"$REPO_ROOT\" \"$sha\" <round>
         $prompt_lib pr-test-analyzer \"$REPO_ROOT\" \"$sha\" <round>
         $prompt_lib silent-failure-hunter \"$REPO_ROOT\" \"$sha\" <round>
    2. Barrier: log all 5 via review-log.sh phase1 N <agent> <count> ok
    3. Run semgrep, then review-log.sh phase1 N semgrep <count> ok
    4. Fire security-review via Agent subagent_type=general-purpose with
       the same templated prompt: $prompt_lib security-review ...
       (firing as Skill ends Claude's turn; Agent keeps it going)
    5. Log it: review-log.sh phase1 N security-review <count> ok
    6. Re-run 'ship-pr-cycle.sh next' (or rely on post-commit-ship-cycle
       firing \`resume\` on next commit — \`resume\` loops until it hits
       phase1, merge-gate, or terminal so it will advance from
       branch-ready → phase0.5 → phase1 in one call once the
       2-streak clean criterion is met)."
			_write_phase1_directive_marker "$sha" "$directive_text"
			printf '%s\n' "$directive_text"
			return 0
		fi
		;;
	phase2)
		# Wire local CR-CLI: invoke local-review.sh, parse findings count.
		# 0 findings → advance to push. >0 → print directive (operator
		# applies trivial fixes per memory rule, re-runs next).
		# rc=3 (#760) → CR rate limit hit; surface as deferred-with-wait,
		# do NOT advance, exit cleanly so post-commit-resume can retry
		# once the budget refills.
		# v0.32.11 (#249-grp) cap-reset treadmill fix: consult the content-hash
		# review-result cache BEFORE invoking the CR-CLI. If this exact review
		# surface (committed diff vs base) was already reviewed, reuse the count
		# — re-running CR's non-deterministic engine on identical content
		# oscillates false-positives + burns the 10/hr budget (PR #254 burned 3
		# reviews on one unchanged SHA). A new commit / main advancing → new
		# hash → miss → fresh review. Best-effort: no key / no lib → exactly the
		# prior always-review behavior.
		local findings rc=0 p2_from_cache=0 p2_ckey="" p2_cached=""
		if command -v phase2_review_cache_key >/dev/null 2>&1; then
			p2_ckey=$(phase2_review_cache_key "$BASE_BRANCH")
		fi
		if [ -n "$p2_ckey" ]; then
			p2_cached=$(phase2_review_cache_get "$p2_ckey")
			if [[ $p2_cached =~ ^[0-9]+$ ]]; then
				findings=$p2_cached
				p2_from_cache=1
				echo "→ phase2 content-hash cache HIT — review surface unchanged since the last CR-CLI pass; reusing $findings finding(s), skipping CR-CLI (saves 10/hr budget; deterministic)" >&2
			fi
		fi
		if [ "$p2_from_cache" -eq 0 ]; then
			findings=$(_phase2_run_cr_cli) || rc=$?
		fi
		if [ "$rc" -eq 3 ]; then
			echo "ship-pr-cycle: phase2 deferred — CR rate limit. Re-run after waitTime elapses." >&2
			# _phase2_run_cr_cli emits the "See <log> for event details"
			# hint conditionally (only when the JSONL was actually written).
			return 0
		fi
		if [ "$rc" -eq 4 ]; then
			# CR review timed out (local-review.sh exit 4) — the local CR-CLI
			# cannot complete on this diff within its review budget. This is a
			# transient CR-backend limit, NOT a code defect: advance to push and
			# defer to the AUTHORITATIVE server-side CR-in-CI (which re-reviews
			# the pushed branch). Mirrors the round-cap's defer philosophy; we
			# honor CR's own recoverable:false signal and do not retry locally.
			_set_stage "push"
			echo "→ phase2 CR review timed out unrecoverably; deferring the review to the authoritative server-side CR-in-CI; advanced to push"
			return 0
		fi
		if [ "$rc" -ne 0 ]; then
			echo "ship-pr-cycle: phase2 CR-CLI invocation failed (rc=$rc) — see output above" >&2
			return "$rc"
		fi
		# v0.32.11 (#249-grp): record a fresh review's result for the content-
		# hash treadmill cache (best-effort; never fails the review). A cache-hit
		# review (p2_from_cache=1) is already in the ledger — don't re-record.
		if [ "$p2_from_cache" -eq 0 ] && [ -n "$p2_ckey" ] &&
			command -v phase2_review_cache_put >/dev/null 2>&1; then
			phase2_review_cache_put "$p2_ckey" "$findings" \
				"$(git rev-parse --short HEAD 2>/dev/null || echo "")"
		fi
		if [ "$findings" -eq 0 ]; then
			_set_stage "push"
			echo "→ phase2 CR-CLI clean (0 findings); advanced to push"
		elif [ "$p2_from_cache" -eq 1 ]; then
			# Content-hash cache HIT with residual findings: this exact surface
			# was already reviewed. Re-reviewing identical content is wasteful +
			# non-deterministic (the treadmill). Advance gated SOLELY on coverage
			# — every residual addressed (real fix → new commit → new hash →
			# fresh review; or verified-FP → prove-yourself rejection) → advance;
			# else direct the operator to address them. No p2runs re-roll: the
			# cap existed to tolerate the oscillation this cache now eliminates.
			# #284 CR fix (deadlock): the cached review may have been recorded
			# under a DIFFERENT sha (content-identical rebase/amend), leaving THIS
			# sha with NO cr-local-review entry. cr_phase2_clean_for_sha is
			# sha-scoped, so findings would be unknown → fail-closed FOREVER (the
			# operator could never satisfy it — a true deadlock). The reconcile
			# below synthesizes this sha's run-log entry from the cached count so a
			# prove-yourself record CAN clear it, exactly as a real local-review
			# run would have logged. Guard/advance shape mirrors the round-cap
			# branch's; kept inline so each path's distinct directive stays legible.
			if ! command -v cr_phase2_clean_for_sha >/dev/null 2>&1; then
				echo "ship-pr-cycle: ERROR: coverage SSOT _lib/cr-phase2-coverage.sh did not load — cannot evaluate the phase2 cache-hit advance. (NOT advancing.)" >&2
				return 2
			fi
			local hs
			if ! hs=$(git rev-parse --short HEAD 2>/dev/null); then
				echo "ship-pr-cycle: ERROR: phase2 cache-hit advance — git rev-parse --short HEAD failed" >&2
				return 2
			fi
			local _crlog="$REPO_ROOT/.claude/logs/cr-local-review.jsonl" _have="false"
			if [ -f "$_crlog" ]; then
				_have=$(jq -rs --arg s "$hs" 'any(.sha == $s)' "$_crlog" 2>/dev/null || echo "false")
			fi
			if [ "$_have" != "true" ]; then
				mkdir -p "$(dirname "$_crlog")" 2>/dev/null || true
				jq -nc --arg s "$hs" --argjson f "$findings" \
					'{sha:$s, findings:$f, source:"phase2-cache-reconcile"}' >>"$_crlog" 2>/dev/null ||
					echo "ship-pr-cycle: WARN: cache-hit cr-local-review reconcile failed for $hs" >&2
			fi
			if cr_phase2_clean_for_sha "$hs"; then
				_set_stage "push"
				echo "→ phase2 content-hash cache HIT + all $findings residual finding(s) addressed (prove-yourself, scoped to sha); advanced to push"
				return 0
			fi
			cat <<EOF
ship-pr-cycle: phase2 content-hash cache HIT — the $findings finding(s) from the prior review of this IDENTICAL surface are NOT all addressed. Re-reviewing won't change them (same content). Address EACH, then re-run 'ship-pr-cycle.sh next':
  - real issue → fix in-PR (commit; the new SHA changes the content hash → fresh review)
  - verified FALSE-POSITIVE → record a rejection with evidence (covers this surface's findings, scoped to HEAD):
      skills/prove-yourself-audit/run.sh record-rejection --source cr --severity <critical|high|medium|minor|info> \\
        --covers-count $findings --follow-up-issue <N> --finding-id <id> --finding-text "..." \\
        --dogfood-cmd "..." --dogfood-output "..." --dogfood-rc 0 --external-authority "..." --reason "..."
EOF
			return 0
		else
			# Round-cap graduation (#234): phase2 CR-CLI findings on a large
			# diff are a non-deterministic LLM minor-tail that need not hit 0
			# even when the code is substantively clean. Mirror phase1's scaler
			# cap — after the round budget, advance to push: the residual is
			# diminishing-returns noise and the SERVER-SIDE CR-in-CI is the
			# authoritative merge gate. Count this-SHA CR-CLI runs from the log
			# (each _phase2_run_cr_cli appends one entry, incl. the current one).
			local cap p2runs cr_log head_sha
			cap=$(_scaler_rounds)
			# git/jq failures here must fail LOUD, not silently default the
			# count (CR phase2 r1 CRITICAL on this block): a masked failure could
			# wrongly advance — vacuously satisfying a small cap — or loop
			# forever. Resolve the sha first, then count, fail-closed on either.
			if ! head_sha=$(git rev-parse --short HEAD 2>/dev/null); then
				echo "ship-pr-cycle: ERROR: phase2 round-cap — git rev-parse --short HEAD failed; cannot count CR-CLI runs" >&2
				return 2
			fi
			cr_log="$REPO_ROOT/.claude/logs/cr-local-review.jsonl"
			if [ ! -f "$cr_log" ]; then
				# No run-log yet → legitimate first run: local-review.sh is the
				# canonical appender, so an absent file means zero recorded runs
				# for this sha (NOT a parse error to mask, NOT grounds to
				# vacuously advance a cap of 1).
				p2runs=0
			else
				local p2runs_err_file p2runs_rc=0
				p2runs_err_file=$(mktemp -t ship-cycle-p2runs-err.XXXXXX) ||
					scm_fail "mktemp for phase2 round-cap jq stderr failed"
				p2runs=$(jq -rs --arg s "$head_sha" '[.[] | select(.sha == $s)] | length' "$cr_log" 2>"$p2runs_err_file") || p2runs_rc=$?
				if [ "$p2runs_rc" -ne 0 ]; then
					echo "ship-pr-cycle: ERROR: phase2 round-cap — jq failed (rc=$p2runs_rc) counting CR-CLI runs in $cr_log: $(cat "$p2runs_err_file" 2>/dev/null)" >&2
					rm -f "$p2runs_err_file"
					return 2
				fi
				rm -f "$p2runs_err_file"
				if ! [[ $p2runs =~ ^[0-9]+$ ]]; then
					echo "ship-pr-cycle: ERROR: phase2 round-cap — non-numeric run count '$p2runs' from $cr_log" >&2
					return 2
				fi
			fi
			if [ "$p2runs" -ge "$cap" ]; then
				# #238: advance at the round budget ONLY if every residual finding
				# is ADDRESSED — the SAME shared coverage check the pre-push gate
				# uses (cr_phase2_clean_for_sha: findings=0 OR all covered by
				# prove-yourself records scoped to this sha). This keeps the cap
				# and the gate consistent (never advance to a push the gate
				# refuses) and — unlike the prior unconditional advance — never
				# rides past an UNADDRESSED finding of ANY severity. The cap thus
				# means "after N rounds you must ADDRESS the residuals (fix in-PR,
				# or verified-false-positive → reject with evidence), not re-roll
				# for a lucky 0". Fail-CLOSED if the shared lib didn't load.
				# #238 code-simplifier r1: reuse the already-resolved (fail-loud)
				# head_sha — cr_phase2_clean_for_sha reduces its arg to short form
				# internally, so a second `git rev-parse HEAD || echo ""` (a
				# soft-fail the fail-loud head_sha resolution above deliberately
				# rejects) would be redundant.
				# #248 (CR major): the declared coverage SSOT is REQUIRED to make
				# this cap decision. If it didn't load, fail CLOSED with a clear
				# error — never the misleading "findings unaddressed" directive
				# below, and never a silent advance. Scoped to the decision that
				# needs it, so other stages (branch-ready/phase1/push/merge) still
				# run (the pre-push gate independently fails-closed on the lib too).
				if ! command -v cr_phase2_clean_for_sha >/dev/null 2>&1; then
					echo "ship-pr-cycle: ERROR: coverage SSOT _lib/cr-phase2-coverage.sh did not load — cannot evaluate the Phase 2 round-cap. Fix the plugin install / PLUGIN_LIB resolution, then re-run. (NOT advancing.)" >&2
					return 2
				fi
				if cr_phase2_clean_for_sha "$head_sha"; then
					_set_stage "push"
					echo "→ phase2 round-cap reached ($p2runs/$cap) + all $findings residual finding(s) addressed (prove-yourself, scoped to sha); advanced to push"
					return 0
				fi
				cat <<EOF
ship-pr-cycle: phase2 round-cap reached ($p2runs/$cap) but the $findings residual finding(s) are NOT all addressed — NOT advancing (the cap will not ride past unaddressed findings of any severity).
  Address EACH residual, then re-run 'ship-pr-cycle.sh next':
    - real issue → fix in-PR (commit; the new SHA re-reviews)
    - verified FALSE-POSITIVE → record a rejection with evidence (covers this run's findings, scoped to HEAD):
        skills/prove-yourself-audit/run.sh record-rejection --source cr --severity <critical|high|medium|minor|info> \\
          --covers-count $findings --follow-up-issue <N> --finding-id <id> --finding-text "..." \\
          --dogfood-cmd "..." --dogfood-output "..." --dogfood-rc 0 --external-authority "..." --reason "..."
  (covered_sha auto = HEAD; --covers-count now reaches the audit log per #238.)
EOF
				return 0
			fi
			cat <<EOF
ship-pr-cycle: phase2 round $p2runs/$cap — CR-CLI returned $findings finding(s)
  DIRECTIVE FOR OPERATOR (Claude):
    Apply trivial fixes inline (regex tightening, mktemp /dev/null fallback,
    here-string idiom, comment fixes, log-msg updates, var renames).
    Commit the fixes — post-commit-ship-cycle fires \`resume\` which
    loops until phase1/merge-gate/terminal, so it will walk
    phase0.5 → phase1 automatically on the new HEAD; you only need to
    manually fire the 5 phase1 agents + log them.
    Non-trivial findings → present to operator with apply/defer/explain.
EOF
			return 0
		fi
		;;
	push)
		# Push the current branch if not already pushed (or if upstream
		# differs). Skip + advance if HEAD matches @{upstream}. Refuse
		# detached HEAD — pushing "HEAD" is not a meaningful operation.
		# Capture stderr to a separate tmpfile (mirror _init_state) so
		# git's rc=0-with-stderr noise (corp wrappers, safe.directory
		# pseudo-warnings) doesn't pollute $branch with multi-line text
		# that breaks the later `git push -u origin "$branch"` call.
		local branch branch_err_file branch_stderr="" branch_rc=0
		branch_err_file=$(mktemp -t ship-cycle-push-branch.XXXXXX) ||
			scm_fail "mktemp for branch stderr capture failed"
		branch=$(git rev-parse --abbrev-ref HEAD 2>"$branch_err_file") || branch_rc=$?
		[ -s "$branch_err_file" ] && branch_stderr=$(cat "$branch_err_file")
		rm -f "$branch_err_file"
		if [ "$branch_rc" -ne 0 ]; then
			echo "ship-pr-cycle: ERROR: cannot resolve current branch (rc=$branch_rc): $branch_stderr" >&2
			return 2
		fi
		if [ "$branch" = "HEAD" ]; then
			echo "ship-pr-cycle: ERROR: detached HEAD — cannot push without an explicit branch" >&2
			echo "  hint: git checkout -b <branch> first" >&2
			return 2
		fi
		local head_sha
		head_sha=$(_current_sha)
		# `@{upstream}` resolution: distinguish three rc cases —
		#   rc=0   : upstream set, value usable
		#   rc=128 + stderr "no upstream" : legitimate first-push (push -u)
		#   any other rc/stderr : real corruption — surface it loudly
		local upstream_sha="" upstream_err_file upstream_stderr="" upstream_rc=0
		upstream_err_file=$(mktemp -t ship-cycle-upstream-err.XXXXXX) ||
			scm_fail "mktemp for upstream stderr capture failed"
		upstream_sha=$(git rev-parse "@{upstream}" 2>"$upstream_err_file") || upstream_rc=$?
		[ -s "$upstream_err_file" ] && upstream_stderr=$(cat "$upstream_err_file")
		rm -f "$upstream_err_file"
		if [ "$upstream_rc" -ne 0 ]; then
			# rc=128 + "no upstream" = legitimate first-push (push -u
			# will set it). Anything else = real corruption — fail loud.
			if [[ $upstream_stderr == *"no upstream"* || $upstream_stderr == *"does not have an upstream"* ]]; then
				upstream_sha=""
			else
				echo "ship-pr-cycle: ERROR: git rev-parse @{upstream} failed unexpectedly (rc=$upstream_rc): $upstream_stderr" >&2
				echo "  hint: corrupt refs? — check 'git config --get branch.$branch.merge'" >&2
				return 2
			fi
		fi
		if [ -n "$upstream_sha" ] && [ "$upstream_sha" = "$head_sha" ]; then
			echo "ship-pr-cycle: push — already pushed (upstream matches HEAD)"
		else
			# Pre-flight: clear stale .git/index.lock if present + no live git
			# process holds it (#35). git push checks for index.lock before
			# its own ref-locks; a stale sentinel from a prior interrupted op
			# would fail this with "Unable to create '.git/index.lock'".
			local cycle_lock="$REPO_ROOT/.git/index.lock"
			if [ -e "$cycle_lock" ]; then
				local cycle_lock_held=0
				if command -v lsof >/dev/null 2>&1; then
					lsof -- "$cycle_lock" >/dev/null 2>&1 && cycle_lock_held=1
				fi
				if [ "$cycle_lock_held" -eq 0 ] && pgrep -af "git[ ].*${REPO_ROOT}" >/dev/null 2>&1; then
					cycle_lock_held=1
				fi
				if [ "$cycle_lock_held" -eq 0 ]; then
					local stale_log="$REPO_ROOT/.claude/logs/git-commit-stale-lock-clear.jsonl"
					mkdir -p "$(dirname "$stale_log")" 2>/dev/null || true
					local cycle_ts
					cycle_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
					echo "ship-pr-cycle: push — removing stale .git/index.lock (no live git holds it)" >&2
					printf '{"ts":"%s","repo":"%s","lock":"%s","action":"cleared","reason":"stale-sentinel-no-live-git","source":"ship-pr-cycle"}\n' \
						"$cycle_ts" "$REPO_ROOT" "$cycle_lock" >>"$stale_log" 2>/dev/null || true
					rm -f "$cycle_lock"
				else
					echo "ship-pr-cycle: push — .git/index.lock present + live git process detected — NOT removing" >&2
				fi
			fi
			echo "ship-pr-cycle: push — running 'git push -u origin $branch'"
			if ! git push -u origin "$branch"; then
				echo "ship-pr-cycle: ERROR: git push failed (see output above)" >&2
				return 2
			fi
		fi
		# v4.28-W5 (#770): ensure PR exists before advancing to
		# cr-in-ci-wait. Two outcomes: (a) PR exists → log + advance;
		# (b) PR missing → print directive + stay at push so operator
		# can run /github-pr-creation skill, then re-run next.
		# Honor SHIP_NO_PR=1 opt-out for cases where operator wants
		# manual PR control or is intentionally pushing without a PR.
		local pr_exists_json pr_exists_err_file pr_exists_stderr="" pr_exists_rc=0
		pr_exists_err_file=$(mktemp -t ship-cycle-prexists.XXXXXX) ||
			scm_fail "mktemp for pr_exists stderr capture failed"
		pr_exists_json=$(gh pr list --head "$branch" --state open --limit 1 --json number 2>"$pr_exists_err_file") || pr_exists_rc=$?
		[ -s "$pr_exists_err_file" ] && pr_exists_stderr=$(cat "$pr_exists_err_file")
		rm -f "$pr_exists_err_file"
		if [ "$pr_exists_rc" -ne 0 ]; then
			echo "ship-pr-cycle: ERROR: gh pr list failed during push-stage PR check (rc=$pr_exists_rc): $pr_exists_stderr" >&2
			echo "  hint: check 'gh auth status' and network connectivity" >&2
			return 2
		fi
		# Capture jq stderr (mirrors cr-in-ci-wait stage's discipline —
		# gh returning malformed JSON is rare but possible with proxy/
		# auth-redirect HTML; collapsing parse failure to "0 PRs" would
		# silently print the create-PR directive on a network glitch).
		local pr_exists_count pr_count_jq_err pr_count_jq_err_file pr_count_jq_rc=0
		pr_count_jq_err_file=$(mktemp -t ship-cycle-push-prcount-jq.XXXXXX) ||
			scm_fail "mktemp for push-stage pr_count jq stderr capture failed"
		pr_exists_count=$(jq 'length' <<<"$pr_exists_json" 2>"$pr_count_jq_err_file") || pr_count_jq_rc=$?
		[ -s "$pr_count_jq_err_file" ] && pr_count_jq_err=$(cat "$pr_count_jq_err_file")
		rm -f "$pr_count_jq_err_file"
		if [ "$pr_count_jq_rc" -ne 0 ]; then
			echo "ship-pr-cycle: ERROR: push — jq parse of gh pr list failed (rc=$pr_count_jq_rc): ${pr_count_jq_err:-<no stderr>}" >&2
			echo "  raw output: $pr_exists_json" >&2
			return 2
		elif [ -n "${pr_count_jq_err:-}" ]; then
			# v4.30 #786 (parent #781): advisory branch — jq rc=0 with
			# stderr is unexpected for a `length` query. Surface as warn
			# so operator notices upstream gh-output drift. Mirrors
			# _init_state existing_jq_err pattern at ~line 195.
			scm_warn "push-stage pr_count jq emitted stderr on rc=0 (advisory): $pr_count_jq_err"
		fi
		if [ "$pr_exists_count" = "0" ]; then
			# CR-in-CI #777 r2 MAJOR: SHIP_NO_PR=1 used to advance to
			# cr-in-ci-wait, which then dead-ended (cr-in-ci-wait refuses
			# without a PR). Now SHIP_NO_PR=1 means "manual PR control":
			# stay at push (silently — no directive spam) so operator can
			# manage PR creation outside the orchestrator. Operator unsets
			# SHIP_NO_PR + re-runs once a PR exists; falls through to the
			# discovered-PR branch below.
			if [ "${SHIP_NO_PR:-0}" = "1" ]; then
				echo "ship-pr-cycle: push — SHIP_NO_PR=1 (manual PR control); staying at push. Re-run with SHIP_NO_PR unset once a PR exists."
				return 0
			fi
			cat <<EOF
ship-pr-cycle: push — branch pushed, but no open PR exists for '$branch'.

Run the github-pr-creation skill to open one:

  /github-pr-creation

Then re-run 'ship-pr-cycle.sh next' from push to advance to cr-in-ci-wait.

Opt-out (manual PR control): SHIP_NO_PR=1 ship-pr-cycle.sh next
EOF
			return 0
		else
			local existing_pr_num existing_jq_err existing_jq_err_file existing_jq_rc=0
			existing_jq_err_file=$(mktemp -t ship-cycle-push-prnum-jq.XXXXXX) ||
				scm_fail "mktemp for push-stage pr_num jq stderr capture failed"
			existing_pr_num=$(jq -r '.[0].number' <<<"$pr_exists_json" 2>"$existing_jq_err_file") || existing_jq_rc=$?
			[ -s "$existing_jq_err_file" ] && existing_jq_err=$(cat "$existing_jq_err_file")
			rm -f "$existing_jq_err_file"
			if [ "$existing_jq_rc" -ne 0 ]; then
				echo "ship-pr-cycle: ERROR: push — jq parse of pr_num failed (rc=$existing_jq_rc): ${existing_jq_err:-<no stderr>}" >&2
				echo "  raw output: $pr_exists_json" >&2
				return 2
			elif [ -n "${existing_jq_err:-}" ]; then
				# v4.30 #786 (parent #781): advisory branch — jq rc=0 with
				# stderr is unexpected for a single-element extract.
				scm_warn "push-stage pr_num jq emitted stderr on rc=0 (advisory): $existing_jq_err"
			fi
			echo "ship-pr-cycle: push — PR #$existing_pr_num already exists for branch '$branch'"
		fi
		_set_stage "cr-in-ci-wait"
		echo "→ pushed; advanced to cr-in-ci-wait"
		;;
	cr-in-ci-wait)
		# Watch the PR's CodeRabbit status check until terminal. Advance
		# to auto-triage (or merge-gate if no findings — sub-issue work).
		# Use `gh pr list --head <branch>` instead of `gh pr view` —
		# the latter's stderr text is a moving target (gh CLI rewords
		# between versions, locale changes, etc.). `gh pr list` always
		# returns deterministic JSON (`length == 0` means no PR), so we
		# can distinguish "no PR" from "auth/network failure" by the
		# JSON output existing at all rather than by string-matching.
		# Same stderr-tmpfile pattern as `push` stage — keep stderr out
		# of `$cur_branch` so corp-wrapper warnings don't pollute the
		# subsequent `gh pr list --head "$cur_branch"` call.
		local cur_branch cur_branch_err_file cur_branch_stderr="" cur_branch_rc=0
		cur_branch_err_file=$(mktemp -t ship-cycle-cwait-branch.XXXXXX) ||
			scm_fail "mktemp for cur_branch stderr capture failed"
		cur_branch=$(git rev-parse --abbrev-ref HEAD 2>"$cur_branch_err_file") || cur_branch_rc=$?
		[ -s "$cur_branch_err_file" ] && cur_branch_stderr=$(cat "$cur_branch_err_file")
		rm -f "$cur_branch_err_file"
		if [ "$cur_branch_rc" -ne 0 ] || [ -z "$cur_branch" ]; then
			echo "ship-pr-cycle: ERROR: cannot resolve current branch (rc=$cur_branch_rc): $cur_branch_stderr" >&2
			return 2
		fi
		if [ "$cur_branch" = "HEAD" ]; then
			echo "ship-pr-cycle: ERROR: detached HEAD — cannot look up PR for branch=HEAD" >&2
			echo "  hint: git checkout <branch> first" >&2
			return 2
		fi
		# Single gh API call returning JSON; parse with jq locally for
		# both existence-check + pr_num. Stderr captured to tmpfile so
		# gh's rc=0-with-warnings (update-available, deprecation,
		# auth-warnings) doesn't pollute the JSON value.
		local pr_json pr_json_err_file pr_json_stderr="" pr_json_rc=0
		pr_json_err_file=$(mktemp -t ship-cycle-pr-err.XXXXXX) ||
			scm_fail "mktemp for gh pr list stderr capture failed"
		pr_json=$(gh pr list --head "$cur_branch" --state open --limit 1 --json number 2>"$pr_json_err_file") || pr_json_rc=$?
		[ -s "$pr_json_err_file" ] && pr_json_stderr=$(cat "$pr_json_err_file")
		rm -f "$pr_json_err_file"
		if [ "$pr_json_rc" -ne 0 ]; then
			echo "ship-pr-cycle: ERROR: gh pr list failed (rc=$pr_json_rc): $pr_json_stderr" >&2
			echo "  hint: check 'gh auth status' and network connectivity" >&2
			return 2
		fi
		# Capture jq stderr for both probes — if gh returned malformed JSON
		# (extremely rare but theoretically possible), the parse error
		# should surface, not collapse to "non-numeric count".
		local pr_count pr_count_jq_err pr_count_jq_err_file pr_count_jq_rc=0
		pr_count_jq_err_file=$(mktemp -t ship-cycle-prcount-jq.XXXXXX) ||
			scm_fail "mktemp for pr_count jq stderr capture failed"
		pr_count=$(jq 'length' <<<"$pr_json" 2>"$pr_count_jq_err_file") || pr_count_jq_rc=$?
		[ -s "$pr_count_jq_err_file" ] && pr_count_jq_err=$(cat "$pr_count_jq_err_file")
		rm -f "$pr_count_jq_err_file"
		if [ "$pr_count_jq_rc" -ne 0 ]; then
			echo "ship-pr-cycle: ERROR: gh pr list JSON parse failed (rc=$pr_count_jq_rc): $pr_count_jq_err" >&2
			echo "  raw output: $pr_json" >&2
			return 2
		fi
		if [ "$pr_count" = "0" ]; then
			echo "ship-pr-cycle: cr-in-ci-wait — no open PR for branch '$cur_branch' (run github-pr-creation skill first)" >&2
			return 1
		fi
		if ! [[ $pr_count =~ ^[1-9][0-9]*$ ]]; then
			echo "ship-pr-cycle: ERROR: gh pr list JSON has non-numeric count: $pr_count (raw: $pr_json)" >&2
			return 2
		fi
		local pr_num pr_num_jq_err pr_num_jq_err_file pr_num_jq_rc=0
		pr_num_jq_err_file=$(mktemp -t ship-cycle-prnum-jq.XXXXXX) ||
			scm_fail "mktemp for pr_num jq stderr capture failed"
		pr_num=$(jq -r '.[0].number' <<<"$pr_json" 2>"$pr_num_jq_err_file") || pr_num_jq_rc=$?
		[ -s "$pr_num_jq_err_file" ] && pr_num_jq_err=$(cat "$pr_num_jq_err_file")
		rm -f "$pr_num_jq_err_file"
		if [ "$pr_num_jq_rc" -ne 0 ]; then
			echo "ship-pr-cycle: ERROR: gh pr list JSON pr_num parse failed (rc=$pr_num_jq_rc): $pr_num_jq_err" >&2
			echo "  raw output: $pr_json" >&2
			return 2
		fi
		if ! [[ $pr_num =~ ^[0-9]+$ ]]; then
			echo "ship-pr-cycle: ERROR: gh pr list JSON has non-numeric pr_num: $pr_num (raw: $pr_json)" >&2
			return 2
		fi
		echo "ship-pr-cycle: cr-in-ci-wait — watching CodeRabbit on PR #$pr_num"
		local watch_rc=0
		"$(_shipcycle_resolve scripts/cr/watch-until-done.sh)" "$pr_num" || watch_rc=$?
		case "$watch_rc" in
		0)
			_set_stage "auto-triage"
			echo "→ CR-in-CI passed; advanced to auto-triage"
			;;
		1)
			_set_stage "auto-triage"
			echo "→ CR-in-CI completed with findings; advanced to auto-triage"
			;;
		2)
			echo "ship-pr-cycle: cr-in-ci-wait — watch-until-done.sh exited rc=2" >&2
			echo "  watch-until-done.sh stderr (above) indicates timeout vs invocation error." >&2
			echo "  Timeout: re-run 'ship-pr-cycle.sh next' once 'gh pr checks $pr_num' shows CodeRabbit terminal." >&2
			echo "  Invocation error (auth/network/args): fix root cause first, then re-run." >&2
			return 2
			;;
		*)
			echo "ship-pr-cycle: cr-in-ci-wait — watch-until-done.sh exited unexpected rc=$watch_rc" >&2
			return "$watch_rc"
			;;
		esac
		;;
	auto-triage)
		# v4.28-W4 (#733): invoke the classifier helper which fetches
		# unresolved CR threads + emits per-thread classification +
		# suggested action. Operator (Claude) reads the JSON output
		# and applies actions per the suggested_action field. The
		# script does NOT auto-apply edits or resolve threads —
		# operator-driven dispatch only.
		# CR-in-CI #733 r1 minor: capture gh stderr to surface real
		# diagnostics on failure (e.g., not authenticated, rate-limited)
		# instead of collapsing every failure mode to "not pushed?".
		local pr_num gh_err gh_err_file gh_rc=0
		gh_err_file=$(mktemp -t ship-cycle-pr-view-err.XXXXXX) ||
			scm_fail "mktemp for gh pr view stderr capture failed"
		pr_num=$(gh pr view --json number --jq .number 2>"$gh_err_file") || gh_rc=$?
		[ -s "$gh_err_file" ] && gh_err=$(cat "$gh_err_file")
		rm -f "$gh_err_file"
		if [ "$gh_rc" -ne 0 ]; then
			echo "ship-pr-cycle: auto-triage — cannot resolve PR (gh rc=$gh_rc): ${gh_err:-not pushed?}" >&2
			# CR-in-CI r3 major: hard failure → rc=2 (not 1, which is
			# "not ready" gate semantics). cmd_resume reads rc=1 as
			# "wait" but rc=2 as "stop and surface".
			return 2
		fi
		local triage_helper
		triage_helper="$(_shipcycle_resolve scripts/cr/auto-triage.sh)"
		if [ ! -x "$triage_helper" ]; then
			echo "ship-pr-cycle: auto-triage — helper missing at $triage_helper" >&2
			return 2
		fi
		echo "ship-pr-cycle: auto-triage — classifying CR threads on PR #$pr_num"
		# CR-in-CI #733 r1 major: capture rc BEFORE the `local` —
		# `local` itself returns 0, so `local rc=$?` always sees the
		# success rc of `local`, not the helper's. Capture into a
		# bare-name first, then declare local from it.
		local rc=0
		"$triage_helper" "$pr_num" --table || rc=$?
		if [ "$rc" -ne 0 ]; then
			echo "ship-pr-cycle: auto-triage helper exited rc=$rc" >&2
			return "$rc"
		fi
		echo ""
		echo "ship-pr-cycle: auto-triage — JSON output saved to .claude/logs/auto-triage.jsonl"
		# v4.28-W5 (#774, #775): route based on unresolved CR-thread count.
		# >0 → cr-autofix stage applies via skill (auto-apply all severities;
		# operator gates only at merge-gate per 4-gate autonomy model).
		# 0 → cr-conflict-check (#190); that stage advances to merge-gate when
		# mergeable, routes a DIRTY PR through CR's resolver, or holds if
		# mergeability is still computing (see its handler). Counting is
		# extracted to
		# _count_unresolved_threads (#775) since pre-push-pipeline-gate
		# shares the same code path for content-aware acceptance — helper
		# enforces numeric guard + stderr-labeled diagnostics on failure.
		local unresolved_count unresolved_rc=0
		unresolved_count=$(_count_unresolved_threads "$pr_num") || unresolved_rc=$?
		if [ "$unresolved_rc" -ne 0 ]; then
			echo "  Stage stays at auto-triage; re-run after diagnosing (helper stderr above)." >&2
			return 2
		fi
		if [ "$unresolved_count" = "0" ]; then
			_set_stage "cr-conflict-check"
			echo "→ no unresolved CR threads; advanced to cr-conflict-check"
			return 0
		fi
		echo "  $unresolved_count unresolved CR thread(s) — advancing to cr-autofix"
		_set_stage "cr-autofix"
		echo "→ advanced to cr-autofix"
		return 0
		;;
	cr-autofix)
		# v4.28-W5 (#774): apply CR autofixes via the coderabbit:autofix
		# skill (default, local Edit) or @coderabbitai autofix comment
		# (SHIP_CI_SIDE_AUTOFIX=1, server-side bot commit). Auto-applies
		# ALL severities — no per-finding operator gate (operator's gate
		# is at merge-gate per 4-gate autonomy model).
		#
		# State machine: first run records entry-SHA + prints directive.
		# Subsequent runs detect SHA change → autofix commits applied →
		# loop back to phase1 (delta-diff per #757).
		local cr_pr_num cr_gh_err cr_gh_err_file cr_gh_rc=0
		cr_gh_err_file=$(mktemp -t ship-cycle-crautofix-pr.XXXXXX) ||
			scm_fail "mktemp for cr-autofix gh pr view stderr capture failed"
		cr_pr_num=$(gh pr view --json number --jq .number 2>"$cr_gh_err_file") || cr_gh_rc=$?
		[ -s "$cr_gh_err_file" ] && cr_gh_err=$(cat "$cr_gh_err_file")
		rm -f "$cr_gh_err_file"
		if [ "$cr_gh_rc" -ne 0 ]; then
			echo "ship-pr-cycle: cr-autofix — cannot resolve PR (gh rc=$cr_gh_rc): ${cr_gh_err:-not pushed?}" >&2
			return 2
		fi
		# Capture _get_state_field rc explicitly — it now returns 2 on
		# corrupt state (mirroring _get_stage discipline). Don't let
		# `entry_sha=$(...)` swallow the rc; halt cr-autofix instead of
		# coercing corruption to "first run".
		local entry_sha entry_rc=0 current_sha
		entry_sha=$(_get_state_field "cr_autofix_entry_sha") || entry_rc=$?
		if [ "$entry_rc" -ne 0 ]; then
			echo "ship-pr-cycle: cr-autofix — _get_state_field cr_autofix_entry_sha failed (rc=$entry_rc); refusing to advance" >&2
			return "$entry_rc"
		fi
		current_sha=$(_current_sha)
		if [ -n "$entry_sha" ] && [ "$entry_sha" != "$current_sha" ]; then
			# Commits applied since entry — likely autofix landed.
			# Clear entry-SHA + dispatched flag (CR-in-CI #777 r2: the
			# dispatched-on-prior-sha is no longer relevant once HEAD
			# moves) + advance to phase1 for delta-diff re-review (#757).
			echo "ship-pr-cycle: cr-autofix — new commits since entry ($entry_sha → $current_sha)"
			_set_state_field "cr_autofix_entry_sha" ""
			_set_state_field "cr_autofix_dispatched" ""
			_set_stage "phase1"
			echo "→ autofix applied; looping back to phase1 (delta-diff)"
			return 0
		fi
		# CR-in-CI #777 r2 MAJOR (idempotency): track dispatch state for
		# SHIP_CI_SIDE_AUTOFIX path. autofix-cycle.sh writes a
		# `@coderabbitai autofix` PR comment; re-dispatching on every
		# rerun before the bot pushes its commit spams duplicate
		# requests. Use cr_autofix_dispatched flag — set after first
		# dispatch on a given entry_sha, cleared when sha changes.
		# First run on this sha: record entry + (if server-side) dispatch.
		# Already-dispatched run on unchanged sha: log "waiting" + return.
		local already_dispatched dispatched_rc=0
		already_dispatched=$(_get_state_field "cr_autofix_dispatched") || dispatched_rc=$?
		if [ "$dispatched_rc" -ne 0 ]; then
			echo "ship-pr-cycle: cr-autofix — _get_state_field cr_autofix_dispatched failed (rc=$dispatched_rc)" >&2
			return "$dispatched_rc"
		fi
		_set_state_field "cr_autofix_entry_sha" "$current_sha"
		if [ "${SHIP_CI_SIDE_AUTOFIX:-0}" = "1" ]; then
			if [ "$already_dispatched" = "1" ]; then
				echo "ship-pr-cycle: cr-autofix — already dispatched server-side autofix on $current_sha; waiting for bot commit (re-run after CR pushes)."
				return 0
			fi
			local cycle_helper
			cycle_helper="$(_shipcycle_resolve scripts/cr/autofix-cycle.sh)"
			if [ ! -x "$cycle_helper" ]; then
				echo "ship-pr-cycle: cr-autofix — server-side helper missing at $cycle_helper" >&2
				return 2
			fi
			echo "ship-pr-cycle: cr-autofix — dispatching @coderabbitai autofix (server-side, SHIP_CI_SIDE_AUTOFIX=1) on PR #$cr_pr_num"
			"$cycle_helper" --pr "$cr_pr_num" || {
				local crc=$?
				echo "ship-pr-cycle: cr-autofix — autofix-cycle.sh exited rc=$crc" >&2
				return "$crc"
			}
			# Mark dispatched so subsequent runs on this same sha don't
			# re-fire (idempotent until bot pushes + sha changes).
			_set_state_field "cr_autofix_dispatched" "1"
			# Server-side autofix may take time; rely on re-run to
			# detect new HEAD via entry-SHA comparison.
			return 0
		fi
		cat <<EOF
ship-pr-cycle: cr-autofix — auto-apply CR findings on PR #$cr_pr_num.

Run the coderabbit:autofix skill in batch mode (auto-apply all severities):

  /coderabbit:autofix $cr_pr_num

Per-finding operator confirmation is intentionally bypassed — the cumulative
diff is reviewed at merge-gate (4-gate autonomy model). If a CR finding is
genuinely off-base, record via prove-yourself rejection so phase1 doesn't
re-flag it (per #757 rec C).

After autofix commits, re-run 'ship-pr-cycle.sh next' to loop back to phase1
(delta-diff re-review).

Opt-in to server-side autofix (CR-bot pushes commit instead):
  SHIP_CI_SIDE_AUTOFIX=1 ship-pr-cycle.sh next
EOF
		return 0
		;;
	cr-conflict-check)
		# v0.30.D (#190): conflict gate between auto-triage and merge-gate.
		# CodeRabbit's resolve-merge-conflict feature (wrapped by
		# skills/cr-resolve-conflict) auto-resolves many conflicts; this stage
		# routes a DIRTY PR through it instead of letting a conflicted PR sit
		# unmergeable at the operator's approve-to-ship gate.
		#
		# ADDITIVE + STATELESS — re-evaluates mergeability every run. Outcomes:
		#   DIRTY        → emit the resolve directive + stay (return 0). When
		#                  the resolution lands LOCALLY (manual rebase moves
		#                  local HEAD), the machine starts a FRESH cycle on the
		#                  new SHA (#674 "new HEAD = fresh review cycle") so the
		#                  merged result is reviewed end-to-end. When CR
		#                  resolves SERVER-SIDE, only the REMOTE PR head moves;
		#                  the "mergeable but remote-ahead" guard below catches
		#                  that and forces a pull (→ new local HEAD → fresh
		#                  cycle) before merge-gate, so a CR-authored merge
		#                  commit can never reach the gate un-re-reviewed.
		#   UNKNOWN      → GitHub still computing mergeability (common right
		#                  after a push); stay (return 0), re-run shortly.
		#   empty/null   → schema drift / PR-state anomaly on an otherwise OK
		#                  gh call → fail loud (return 2), NOT treated as
		#                  "computing" (would stay forever). Mirrors the
		#                  cr-resolve-conflict skill's malformed-state guard.
		#   mergeable    → advance to merge-gate (only when local HEAD == PR
		#                  head; see remote-ahead guard).
		# One gh round-trip fetches number (for directives) + merge state +
		# mergeable + headRefOid (remote-ahead detection); `gh pr view` with no
		# positional arg resolves the current branch's PR.
		local cc_state cc_gh_err cc_gh_err_file cc_gh_rc=0
		cc_gh_err_file=$(mktemp -t ship-cycle-crconflict.XXXXXX) ||
			scm_fail "mktemp for cr-conflict-check gh pr view stderr capture failed"
		cc_state=$(gh pr view --json number,mergeStateStatus,mergeable,headRefOid 2>"$cc_gh_err_file") || cc_gh_rc=$?
		[ -s "$cc_gh_err_file" ] && cc_gh_err=$(cat "$cc_gh_err_file")
		rm -f "$cc_gh_err_file"
		if [ "$cc_gh_rc" -ne 0 ]; then
			echo "ship-pr-cycle: cr-conflict-check — cannot resolve PR (gh rc=$cc_gh_rc): ${cc_gh_err:-not pushed?}" >&2
			return 2
		fi
		# Validate JSON shape before extracting — a non-JSON body (proxy/5xx
		# HTML that still exits 0) would otherwise abort the run mid-extract
		# under set -e instead of returning the handler's own rc=2.
		if ! printf '%s' "$cc_state" | jq -e . >/dev/null 2>&1; then
			echo "ship-pr-cycle: cr-conflict-check — gh returned non-JSON PR state; refusing to advance" >&2
			return 2
		fi
		local cc_pr_num cc_merge cc_mergeable cc_remote_head
		cc_pr_num=$(printf '%s' "$cc_state" | jq -r '.number // ""')
		cc_merge=$(printf '%s' "$cc_state" | jq -r '.mergeStateStatus // ""')
		cc_mergeable=$(printf '%s' "$cc_state" | jq -r '.mergeable // ""')
		cc_remote_head=$(printf '%s' "$cc_state" | jq -r '.headRefOid // ""')
		# Genuine async UNKNOWN (GitHub still computing) is the ONLY "stay
		# because not-yet-known" case.
		if [ "$cc_mergeable" = "UNKNOWN" ]; then
			echo "ship-pr-cycle: cr-conflict-check — mergeability still computing (merge=$cc_merge); re-run 'next' shortly"
			return 0
		fi
		# Empty/null after a successful, valid-JSON gh call = schema drift or a
		# PR-state anomaly. Fail loud rather than silently staying forever
		# (silent-failure-hunter #190 r1; same posture as the skill's guard).
		# headRefOid is validated here too: an empty PR head would make the
		# remote-ahead guard below fail open (its comparison would no-op) and
		# advance an un-pulled state — so treat empty head as the same anomaly
		# (CR phase2 #190).
		if [ -z "$cc_merge" ] || [ -z "$cc_mergeable" ] || [ -z "$cc_remote_head" ]; then
			echo "ship-pr-cycle: cr-conflict-check — PR state has empty merge fields (merge='$cc_merge' mergeable='$cc_mergeable' head='$cc_remote_head'); refusing to advance" >&2
			return 2
		fi
		# Conflict trigger requires BOTH fields to agree (mirrors the skill's
		# strict gate) so a single transient field blip can't misfire.
		if [ "$cc_merge" = "DIRTY" ] && [ "$cc_mergeable" = "CONFLICTING" ]; then
			local cc_skill
			cc_skill=$(_shipcycle_resolve skills/cr-resolve-conflict/run.sh)
			cat <<EOF
ship-pr-cycle: cr-conflict-check — PR #$cc_pr_num has a merge conflict (merge=$cc_merge).

Resolve via CodeRabbit's resolver (posts '@coderabbitai resolve merge conflict', polls outcome):

  $cc_skill --pr $cc_pr_num

  rc 0 = CR resolved (or nothing to resolve) · rc 2 = CR declined/timed out
  → manual rebase: 'git fetch origin && git rebase origin/$BASE_BRANCH', resolve, push.
  Opt out of CR resolution entirely: CR_RESOLVE_CONFLICT_DISABLED=1.

Once the resolution commit lands, re-run 'ship-pr-cycle.sh next'. If CR resolved
it server-side, the next check directs you to pull first so the merged result is
re-reviewed on a fresh local cycle before merge-gate.
EOF
			return 0
		fi
		# Advance only when GitHub explicitly reports MERGEABLE. Any other
		# non-UNKNOWN value (e.g. CONFLICTING with merge != DIRTY — a transient
		# single-field mismatch the conflict guard above does not catch) must
		# hold here, never leak an unmergeable PR into merge-gate. (CR-in-CI
		# #203 major.)
		if [ "$cc_mergeable" != "MERGEABLE" ]; then
			echo "ship-pr-cycle: cr-conflict-check — mergeable='$cc_mergeable' (merge=$cc_merge) is not MERGEABLE; holding at cr-conflict-check, re-run 'next' once GitHub settles" >&2
			return 0
		fi
		# Mergeable — but a server-side resolution (CR's resolver pushes the
		# merge commit to the REMOTE PR branch) leaves local HEAD behind.
		# Advancing now would send an un-re-reviewed merge commit to
		# merge-gate, so only advance when local HEAD matches the PR head;
		# otherwise direct the operator to pull (→ new local HEAD → fresh
		# review cycle). (code-reviewer #190 r1.)
		local cc_local_head
		cc_local_head=$(_current_sha)
		# cc_remote_head is guaranteed non-empty (validated in the empty-fields
		# guard above), so a bare inequality is sufficient here.
		if [ "$cc_remote_head" != "$cc_local_head" ]; then
			cat <<EOF
ship-pr-cycle: cr-conflict-check — PR #$cc_pr_num is mergeable, but the PR head
($cc_remote_head) differs from local HEAD ($cc_local_head): a resolution was
likely pushed remotely. Pull it so the merged result is re-reviewed before
merge-gate:

  git fetch origin && git pull --ff-only

Then re-run 'ship-pr-cycle.sh next' — the new HEAD starts a fresh review cycle.
EOF
			return 0
		fi
		_set_stage "merge-gate"
		echo "→ no merge conflict (merge=$cc_merge mergeable=$cc_mergeable); advanced to merge-gate"
		return 0
		;;
	merge-gate)
		# v0.7.3 (#28): no-orphan-deferrals enforcement. Before showing the
		# operator-approval message, verify any epics this PR closes don't
		# have unaddressed prove-yourself rejections. Per-finding enforcement
		# happens at record-rejection time (prove-yourself-audit/run.sh
		# already requires --follow-up-issue when confidence ≥ 7); this
		# stage cross-checks at merge-gate time that those followup issues
		# still exist + are open. Bypass: NO_ORPHAN_DEFERRALS_SKIP=1.
		if [ "${NO_ORPHAN_DEFERRALS_SKIP:-0}" = "1" ]; then
			scm_warn "merge-gate: NO_ORPHAN_DEFERRALS_SKIP=1 — bypassing epic-completeness check"
		else
			local ec_lib="$SCRIPT_DIR/../_lib/epic-completeness-check.sh"
			if [ -f "$ec_lib" ]; then
				# shellcheck source=../_lib/epic-completeness-check.sh
				source "$ec_lib"
				local pr_num ec_rc=0
				pr_num=$(gh pr view --json number --jq .number 2>/dev/null)
				if [ -n "$pr_num" ]; then
					epic_completeness_check "$pr_num" || ec_rc=$?
					if [ "$ec_rc" -ne 0 ]; then
						scm_warn "merge-gate: epic-completeness check refused — fix orphan deferrals before approving"
						return "$ec_rc"
					fi
				fi
			fi
		fi
		echo "ship-pr-cycle: merge-gate — operator approves here"
		return 0
		;;
	merged)
		echo "ship-pr-cycle: terminal state (merged)"
		return 0
		;;
	*)
		echo "ship-pr-cycle: ERROR: unknown stage '$stage'" >&2
		return 2
		;;
	esac
}

cmd_resume() {
	# v0.32.12 (#283): suppress per-transition next-step directives during the
	# auto-walk. bash dynamic scope makes this local visible to cmd_next (called
	# in the loop below), so _emit_stage_directive skips the ack-pending for
	# intermediate stages — only the stage resume STOPS at surfaces a directive.
	# shellcheck disable=SC2034  # read by _lib/ship-cycle-directives.sh via dynamic scope (not referenced in this file)
	local SHIP_PR_IN_RESUME=1
	# Auto-detect state + advance until operator-input or terminal.
	# Stops on:
	#   - _get_stage non-zero rc (corrupt state file, missing .stage)
	#   - cmd_next non-zero rc (gate refused, error, or operator-input)
	#   - stage didn't change between iterations (idempotent stop —
	#     guards against infinite loop if a future stage forgets to
	#     advance)
	#   - operator-input stages (phase1, merge-gate) where the next
	#     transition needs human/Claude action
	#   - terminal stage (merged)
	# `iter` cap is belt-and-suspenders against pathological loops; the
	# state machine has 9 stages so 20 iterations covers any forward
	# walk plus generous slack.
	local iter=0 prev current state_rc=0
	while [ "$iter" -lt 20 ]; do
		# Capture _get_stage rc explicitly (SF-01/H2): plain
		# `prev=$(_get_stage)` masks rc=2 from a corrupt state file —
		# the case-statement falls through to cmd_next which then
		# fails with a confusing downstream error. Surface the
		# upstream rc with a clear diagnostic instead.
		prev=$(_get_stage) || state_rc=$?
		if [ "$state_rc" -ne 0 ]; then
			scm_warn "cmd_resume: _get_stage failed at iter $iter (rc=$state_rc) — see prior stderr for details"
			return "$state_rc"
		fi
		case "$prev" in
		phase1 | merge-gate | merged)
			# Operator-input or terminal — stop here so the operator
			# (or Claude session) can take over.
			return 0
			;;
		esac
		local rc=0
		cmd_next "$@" || rc=$?
		if [ "$rc" -ne 0 ]; then
			# Non-zero from cmd_next — gate refused, real error, or
			# stage emitted an operator directive. Stop and let the
			# caller see the message + decide.
			return "$rc"
		fi
		current=$(_get_stage) || state_rc=$?
		if [ "$state_rc" -ne 0 ]; then
			scm_warn "cmd_resume: _get_stage failed after cmd_next at iter $iter (rc=$state_rc)"
			return "$state_rc"
		fi
		if [ "$current" = "$prev" ]; then
			# No advance happened despite rc=0. Stop to avoid spinning.
			return 0
		fi
		iter=$((iter + 1))
	done
	scm_warn "cmd_resume: hit iteration cap (iter=$iter) without reaching operator-input or terminal — last prev=${prev:-<unset>} current=${current:-<unset>}. State: $(_state_file 2>/dev/null || echo unresolvable)"
	return 1
}

cmd_install_hook() {
	# Idempotently wire post-commit hook so every `git commit` fires
	# `.claude/hooks/post-commit-ship-cycle.sh` (which detaches a
	# `ship-pr-cycle.sh resume` to drive the cycle forward).
	#
	# Five cases (handled in this order):
	#   (1) hook is a SYMLINK (some clones link post-commit to
	#       .claude/pre-commit-hooks/fire-auto-close-parent.sh) →
	#       atomically replace with a wrapper file that calls BOTH the
	#       original target AND our wiring, leaving the tracked
	#       symlink-target file untouched. Found by #735 dogfood.
	#   (2) hook contains MULTIPLE `^exit 0$` lines → REFUSE with hint.
	#       Splicing before the last is unsafe — the earlier exit may
	#       already short-circuit (SF-03). Operator must merge manually.
	#   (3) hook is regular file already containing both our marker AND
	#       the post-commit-ship-cycle.sh invocation → no-op (SF-12 —
	#       checking marker alone could miss a partial wiring).
	#   (4) hook missing → create fresh.
	#   (5) hook is regular file → atomic append/splice via mktemp+rename.
	#
	# All file writes use mktemp+rename (atomic vs interrupt). Symlink
	# targets are validated for existence before installation. The
	# wrapper script we generate uses STATIC paths captured into a
	# temp file (no shell interpolation of untrusted symlink-target
	# strings into shell code, mitigating SF-02/H1).
	#
	# Hook dir is resolved via `git rev-parse --git-path hooks` so
	# worktrees + core.hooksPath users land in the right place (SF-11).
	local hooks_dir hook_path marker wiring_marker_re wiring_call_re
	# Capture stderr separately so a real git error (corrupt HEAD,
	# permission denied on .git, broken worktree gitlink, malformed
	# core.hooksPath) surfaces in the diagnostic instead of being
	# swallowed and replaced with a misleading "not a git repo?" guess.
	local hp_err hp_err_file hp_rc=0
	hp_err_file=$(mktemp -t ship-cycle-rev-parse-err.XXXXXX) ||
		scm_fail "mktemp for git rev-parse stderr capture failed"
	hooks_dir=$(git -C "$REPO_ROOT" rev-parse --git-path hooks 2>"$hp_err_file") || hp_rc=$?
	[ -s "$hp_err_file" ] && hp_err=$(cat "$hp_err_file")
	rm -f "$hp_err_file"
	if [ "$hp_rc" -ne 0 ]; then
		scm_fail "git rev-parse --git-path hooks failed (rc=$hp_rc): ${hp_err:-<no stderr>}"
	fi
	# rev-parse --git-path returns a path relative to cwd or absolute;
	# normalize relative-to-cwd by prefixing with REPO_ROOT when relative.
	[[ $hooks_dir == /* ]] || hooks_dir="$REPO_ROOT/$hooks_dir"
	mkdir -p "$hooks_dir" || scm_fail "cannot create hooks dir $hooks_dir"
	hook_path="$hooks_dir/post-commit"
	marker="# ship-pr-cycle: post-commit-ship-cycle.sh wiring (#735)"
	wiring_marker_re="ship-pr-cycle: post-commit-ship-cycle\.sh wiring"
	# Match the ACTUAL invocation, not any substring mention. A partially-
	# edited hook keeping the marker + `SHIP_CYCLE_HOOK=...` assignment
	# but missing the `"$SHIP_CYCLE_HOOK"` execution line should NOT be
	# considered "already wired" (CR-in-CI #736 r3). Single-quoted so
	# the literal `"$SHIP_CYCLE_HOOK"` (with quotes + dollar) survives
	# into the regex unexpanded — shellcheck SC2016 silenced because
	# we explicitly want no expansion here.
	# shellcheck disable=SC2016
	wiring_call_re='"\$SHIP_CYCLE_HOOK"'

	# (1) Symlink: validate target, replace atomically with wrapper.
	if [ -L "$hook_path" ]; then
		local link_target link_abs
		link_target=$(readlink "$hook_path") || scm_fail "readlink failed for $hook_path"
		[ -n "$link_target" ] || scm_fail "readlink returned empty target for $hook_path"
		# Reject suspicious targets (newline/CR/quote/backslash/$/` — could
		# pollute the wrapper script when interpolated into shell code).
		case "$link_target" in
		*$'\n'* | *$'\r'* | *\"* | *\$* | *\`* | *\\*)
			scm_fail "symlink target contains shell-special chars: $link_target — refusing to install. Replace symlink manually then re-run."
			;;
		esac
		# Resolve relative target.
		if [[ $link_target == /* ]]; then
			link_abs="$link_target"
		else
			link_abs="$hooks_dir/$link_target"
		fi
		[ -e "$link_abs" ] || scm_fail "symlink target $link_abs does not exist (dangling). Fix or remove the symlink before install-hook."
		[ -x "$link_abs" ] || scm_warn "symlink target $link_abs exists but is not executable — wrapper will skip it via [ -x ]. Fix permissions if you want the prior chain preserved."
		# Atomic replace: build wrapper in a tmpfile, then rename over
		# the symlink (rename(2) replaces atomically on POSIX).
		local wrap_tmp
		wrap_tmp=$(mktemp "$hook_path.XXXXXX") || scm_fail "mktemp failed for symlink replacement"
		# Use a quoted heredoc for the runtime block (no shell expansion
		# now); the prior-target absolute path is the ONLY runtime-known
		# value, written via `printf '%s\n'` which doesn't interpret it.
		{
			printf '%s\n' '#!/bin/bash'
			printf '# Auto-wrapper installed by ship-pr-cycle install-hook (#735) — preserves\n'
			printf '# the prior symlink target and adds the ship-cycle resume.\n'
			# Print the prior-target invocation. printf %q quotes the
			# path safely so it survives a shell re-eval.
			printf 'PRIOR_HOOK_TARGET=%q\n' "$link_abs"
			# Distinguish "missing" (not executable) from "ran but failed
			# rc=N" — both at the prior-target invocation and the ship-
			# cycle invocation. Naive `&& A || echo` conflates these
			# into a single misleading "failed or missing" message
			# (SFH r2 critical finding).
			# Capture rc IMMEDIATELY after the call, not via `if ! cmd`
			# — the latter sets $? to the rc of `! cmd` (always 0
			# inside the then-branch), making the diagnostic say
			# "rc=0" when the actual command failed. (CR-in-CI #736.)
			cat <<'WRAP'
if [ -x "$PRIOR_HOOK_TARGET" ]; then
    rc=0
    "$PRIOR_HOOK_TARGET" "$@" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "[ship-pr-cycle install-hook wrapper] prior target $PRIOR_HOOK_TARGET ran but exited rc=$rc at $(date -u +%FT%TZ)" >&2
    fi
else
    echo "[ship-pr-cycle install-hook wrapper] prior target $PRIOR_HOOK_TARGET missing or not executable at $(date -u +%FT%TZ)" >&2
fi
WRAP
			# Then our wiring (still quoted heredoc — no expansion).
			printf '%s\n' "$marker"
			cat <<'WIRING'
REPO_ROOT_FOR_SHIP_CYCLE=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "[ship-pr-cycle hook] git rev-parse --show-toplevel failed at $(date -u +%FT%TZ) — wiring skipped (worktree linkage broken? GIT_DIR? core.hooksPath?)" >&2
    exit 0
}
SHIP_CYCLE_HOOK="$REPO_ROOT_FOR_SHIP_CYCLE/.claude/hooks/post-commit-ship-cycle.sh"
if [ -x "$SHIP_CYCLE_HOOK" ]; then
    rc=0
    "$SHIP_CYCLE_HOOK" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "[ship-pr-cycle install-hook wrapper] post-commit-ship-cycle.sh ran but exited rc=$rc at $(date -u +%FT%TZ)" >&2
    fi
else
    echo "[ship-pr-cycle install-hook wrapper] post-commit-ship-cycle.sh missing or not executable at $(date -u +%FT%TZ)" >&2
fi
WIRING
		} >"$wrap_tmp" || {
			rm -f "$wrap_tmp"
			scm_fail "wrapper write failed at $wrap_tmp"
		}
		chmod +x "$wrap_tmp" || {
			rm -f "$wrap_tmp"
			scm_fail "chmod failed for $wrap_tmp"
		}
		mv "$wrap_tmp" "$hook_path" || {
			rm -f "$wrap_tmp"
			scm_fail "atomic rename failed: $wrap_tmp -> $hook_path"
		}
		echo "ship-pr-cycle install-hook: replaced symlink at $hook_path (preserved $link_target via wrapper)"
		return 0
	fi

	# (2) Multiple `^exit 0$` lines → refuse (SF-03).
	if [ -f "$hook_path" ]; then
		local exit0_count
		exit0_count=$(grep -cE '^[[:space:]]*exit 0[[:space:]]*$' "$hook_path" || true)
		if [ "$exit0_count" -gt 1 ]; then
			scm_fail "$hook_path has $exit0_count 'exit 0' lines — refusing to splice (earlier exit may short-circuit). Manually merge the wiring block from .claude/skills/ship-pr-cycle/SKILL.md."
		fi
	fi

	# (3) Already-wired check verifies BOTH marker AND the wiring call
	# (SF-12 — guards against partial removal that left a dangling marker).
	if [ -f "$hook_path" ] && grep -qE "$wiring_marker_re" "$hook_path" && grep -qE "$wiring_call_re" "$hook_path"; then
		echo "ship-pr-cycle install-hook: already wired at $hook_path"
		return 0
	fi

	# (4)+(5) Build the new content in a tmpfile (atomic via rename).
	local hook_tmp install_path
	hook_tmp=$(mktemp "$hook_path.XXXXXX") || scm_fail "mktemp failed for $hook_path"
	if [ ! -f "$hook_path" ]; then
		# (4) missing — fresh file with shebang
		install_path="fresh"
		printf '%s\n' '#!/bin/bash' >"$hook_tmp" || {
			rm -f "$hook_tmp"
			scm_fail "shebang write failed for $hook_tmp"
		}
	elif grep -qE '^[[:space:]]*exit 0[[:space:]]*$' "$hook_path"; then
		install_path="splice"
		# (5a) Splice BEFORE the single trailing `exit 0` so our block
		# isn't dead code. The exit0_count==1 guard above ensures
		# there's only one to find. Use awk reading the wiring block
		# from a tmpfile (avoids `awk -v` escape interpretation —
		# SF-02).
		local block_tmp
		block_tmp=$(mktemp "$hook_path.block.XXXXXX") || {
			rm -f "$hook_tmp"
			scm_fail "mktemp failed for splice block"
		}
		{
			printf '%s\n' "$marker"
			cat <<'WIRING'
REPO_ROOT_FOR_SHIP_CYCLE=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "[ship-pr-cycle hook] git rev-parse --show-toplevel failed at $(date -u +%FT%TZ) — wiring skipped (worktree linkage broken? GIT_DIR? core.hooksPath?)" >&2
    exit 0
}
SHIP_CYCLE_HOOK="$REPO_ROOT_FOR_SHIP_CYCLE/.claude/hooks/post-commit-ship-cycle.sh"
if [ -x "$SHIP_CYCLE_HOOK" ]; then
    rc=0
    "$SHIP_CYCLE_HOOK" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "[ship-pr-cycle wiring] post-commit-ship-cycle.sh ran but exited rc=$rc at $(date -u +%FT%TZ)" >&2
    fi
else
    echo "[ship-pr-cycle wiring] post-commit-ship-cycle.sh missing or not executable at $(date -u +%FT%TZ)" >&2
fi
WIRING
		} >"$block_tmp" || {
			rm -f "$hook_tmp" "$block_tmp"
			scm_fail "splice block write failed"
		}
		# Two-pass: read whole file into memory, find last `exit 0`
		# line, emit block before it. exit0_count==1 makes "last" ==
		# "only" — but the awk uses the same logic for safety.
		awk -v blockfile="$block_tmp" '
			BEGIN {
				while ((getline line < blockfile) > 0) block_lines[++block_n] = line
				close(blockfile)
				last_exit = -1
			}
			{ lines[NR] = $0; if ($0 ~ /^[[:space:]]*exit 0[[:space:]]*$/) last_exit = NR }
			END {
				for (i = 1; i <= NR; i++) {
					if (i == last_exit)
						for (j = 1; j <= block_n; j++) print block_lines[j]
					print lines[i]
				}
			}
		' "$hook_path" >"$hook_tmp" || {
			rm -f "$hook_tmp" "$block_tmp"
			scm_fail "awk splice failed for $hook_path"
		}
		# Validate the splice actually inserted the marker (SFH high
		# finding): if the bash regex on $hook_path matched but awk's
		# regex didn't (locale/awk-version disagreement), last_exit
		# stays -1 and the file is rewritten unchanged. Refuse loudly
		# instead of installing a hook with no wiring.
		if ! grep -qE "$wiring_marker_re" "$hook_tmp"; then
			rm -f "$hook_tmp" "$block_tmp"
			scm_fail "awk splice ran rc=0 but wiring marker not in output (regex-engine disagreement?). Refusing to install $hook_path."
		fi
		rm -f "$block_tmp"
	else
		# (5b) Plain append — copy original then append wiring.
		install_path="append"
		cat "$hook_path" >"$hook_tmp" || {
			rm -f "$hook_tmp"
			scm_fail "copy of $hook_path failed"
		}
	fi

	# Append wiring for fresh-file (4) and plain-append (5b) paths.
	if [ ! -f "$hook_path" ] || ! grep -qE '^[[:space:]]*exit 0[[:space:]]*$' "$hook_path"; then
		# Ensure trailing newline before appending — if the original
		# hook lacks one (rare but legal), the first appended line
		# would concatenate onto the last shell token (e.g. `fi#
		# ship-pr-cycle...`), creating syntactically broken bash.
		# (CR-in-CI #736 r3.)
		if [ -s "$hook_tmp" ] && [ "$(tail -c 1 "$hook_tmp" | xxd -p)" != "0a" ]; then
			printf '\n' >>"$hook_tmp"
		fi
		{
			printf '%s\n' "$marker"
			cat <<'WIRING'
REPO_ROOT_FOR_SHIP_CYCLE=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "[ship-pr-cycle hook] git rev-parse --show-toplevel failed at $(date -u +%FT%TZ) — wiring skipped (worktree linkage broken? GIT_DIR? core.hooksPath?)" >&2
    exit 0
}
SHIP_CYCLE_HOOK="$REPO_ROOT_FOR_SHIP_CYCLE/.claude/hooks/post-commit-ship-cycle.sh"
if [ -x "$SHIP_CYCLE_HOOK" ]; then
    rc=0
    "$SHIP_CYCLE_HOOK" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "[ship-pr-cycle wiring] post-commit-ship-cycle.sh ran but exited rc=$rc at $(date -u +%FT%TZ)" >&2
    fi
else
    echo "[ship-pr-cycle wiring] post-commit-ship-cycle.sh missing or not executable at $(date -u +%FT%TZ)" >&2
fi
WIRING
		} >>"$hook_tmp" || {
			rm -f "$hook_tmp"
			scm_fail "wiring append failed for $hook_tmp"
		}
	fi

	chmod +x "$hook_tmp" || {
		rm -f "$hook_tmp"
		scm_fail "chmod failed for $hook_tmp"
	}
	mv "$hook_tmp" "$hook_path" || {
		rm -f "$hook_tmp"
		scm_fail "atomic rename failed: $hook_tmp -> $hook_path"
	}
	# Differentiate install paths so post-hoc forensics can tell which
	# branch ran from the install log (SFH low finding).
	local install_kind
	if [ "$install_path" = "fresh" ]; then
		install_kind="installed fresh hook at"
	elif [ "$install_path" = "splice" ]; then
		install_kind="spliced wiring before exit 0 in"
	else
		install_kind="appended wiring to existing"
	fi
	echo "ship-pr-cycle install-hook: $install_kind $hook_path"
}

# ----- dispatch -----

_usage() {
	cat <<'EOF'
Usage: ship-pr-cycle.sh <subcommand>

Subcommands:
  start         Initialize state for current HEAD
  status        Show state machine position
  next          Advance one stage (idempotent)
  resume        Auto-detect + advance until operator-input or terminal
  install-hook  Wire .git/hooks/post-commit to fire resume after commit
  mirror-report Show mirror coverage telemetry summary (text or --json)
  epic          One-shot: cr-plan a brainstorm artifact → github-epic-creation
                (operator runs the brainstorm step separately — disjoint by design)

State file: .claude/.session-state/ship-cycle/<sha>.json
Env:        BASE_BRANCH (default: main)
EOF
}

if [ "$#" -lt 1 ]; then
	_usage
	exit 0
fi

SUBCMD=$1
shift

case "$SUBCMD" in
start) cmd_start "$@" ;;
status) cmd_status "$@" ;;
next) cmd_next "$@" ;;
resume) cmd_resume "$@" ;;
install-hook) cmd_install_hook "$@" ;;
mirror-report)
	# #131: per-mirror coverage summary. Delegates to the standalone
	# script so the helper can also be sourced by other consumers.
	_helper=$(_shipcycle_resolve scripts/cr/mirror-coverage.sh)
	if [ ! -x "$_helper" ]; then
		echo "ship-pr-cycle: mirror-coverage helper missing or non-exec: $_helper" >&2
		exit 2
	fi
	"$_helper" report "$@"
	;;
epic)
	# #125 Option C — thin dispatch to the cr-plan skill (one entrypoint
	# instead of operator memorizing which skill handles which step).
	# The brainstorm itself stays operator-driven (inherently interactive
	# A/B/C pick filed via brainstorm.yml issue template); this dispatch
	# just sequences the post-brainstorm chain:
	#
	#   ship-pr-cycle.sh epic trigger <brainstorm-issue-num>
	#     → cr-plan trigger: applies plan-me label + posts @coderabbitai
	#       plan comment so CR Issue Planner generates the plan.
	#
	#   ship-pr-cycle.sh epic parse <brainstorm-issue-num>
	#     → cr-plan parse: reads CR's plan comment, extracts Implementation
	#       Steps, invokes github-epic-creation to create parent epic +
	#       N sub-issues linked via addSubIssue GraphQL.
	#
	# Preserves "PARALLEL workflow, disjoint by design" doctrine — see the
	# file header section "Relationship to cr-plan" — no auto-fire into the
	# ship state machine. The --help/-h short-circuit below is the ONE
	# exception where this dispatch adds semantics (workflow-level help);
	# all other args pass through verbatim to cr-plan.
	_epic_usage() {
		cat <<'EOH'
Usage: ship-pr-cycle.sh epic <subcommand> <brainstorm-issue-num>

  trigger <num>   Apply plan-me label + post @coderabbitai plan comment.
                  CR posts the plan as a comment (~minutes).
                  (No APPROVE gate — idempotent.)
  parse <num>     Read CR plan comment, extract Implementation Steps,
                  invoke github-epic-creation to open parent + N subs.
                  Requires APPROVE=1 (non-interactive guard, mirrors
                  cr-plan's gate).

Workflow:
  1. Operator files brainstorm issue via brainstorm.yml template (manual,
     inherently interactive — operator picks the approach).
  2. ship-pr-cycle.sh epic trigger <num>  (this dispatch — kicks off CR plan)
  3. Wait for CR Issue Planner to post the plan as a comment.
  4. ship-pr-cycle.sh epic parse <num>    (this dispatch — creates epic+subs)
  5. Operator picks a sub to start; ship-pr-cycle takes over at branch-ready.

This is a thin dispatch — see skills/cr-plan/run.sh for the underlying
behavior.
EOH
	}
	# --help exits 0 (convention); empty args exits 2 (argparse error).
	# NOTE: top-level dispatch treats no-args as help (exit 0); subcommand
	# follows argparse-error convention (exit 2) since 'epic' alone is
	# meaningless. ${1:-} keeps set -u quiet on the help-flag comparison
	# even if the arity guard is ever reordered.
	if [ "$#" -lt 1 ]; then
		_epic_usage >&2
		exit 2
	fi
	if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
		_epic_usage
		exit 0
	fi
	_cr_plan=$(_shipcycle_resolve skills/cr-plan/run.sh)
	if [ ! -x "$_cr_plan" ]; then
		echo "ship-pr-cycle epic: cr-plan skill wrapper missing or non-exec: $_cr_plan" >&2
		exit 2
	fi
	# Pass through verbatim — cr-plan owns argument validation (trigger/parse
	# subcommands, issue-num arity, APPROVE=1 for parse). Wrapper layers on
	# documentation + single-entrypoint convenience, not new semantics.
	# `exec` makes the pass-through STRUCTURAL: kernel-enforced terminal call
	# (impossible to append code after) + frees the shell frame. Also pins
	# the contract — exit-code propagation is implicit instead of positional.
	exec "$_cr_plan" "$@"
	;;
-h | --help)
	_usage
	exit 0
	;;
*)
	echo "ship-pr-cycle: unknown subcommand: $SUBCMD" >&2
	echo "Use one of: start, status, next, resume, install-hook, mirror-report, epic" >&2
	exit 2
	;;
esac
