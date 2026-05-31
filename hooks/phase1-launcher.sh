#!/bin/bash
# auto-register: false
# v4.15.E #493 — Phase 1 launcher helper.
#
# Prints a ready-to-use agent launch checklist for the current diff.
# The caller (Claude) then issues the expected Agent tool calls in a single
# parallel message per round. This helper doesn't invoke agents itself
# (the Agent tool lives in the conversation layer, not shell) but it
# removes the ambiguity about which agents should run + what scope.
#
# Usage:
#   .claude/hooks/phase1-launcher.sh [round]
#
# Output format: one line per agent, followed by the git diff --stat
# summary + the base ref the agents should review against.
#
# WHY: observed workflow skip 2026-04-20 — Claude runs a subset of agents
# in a round and proceeds. A one-shot "here's what round N needs" print
# closes the "which 7 again?" loophole. Claude copy-pastes the list
# into a single Agent-parallel message rather than deciding ad-hoc.

set -euo pipefail

ROUND="${1:-next}"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
cd "$REPO_ROOT" || exit 2

SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
if [ -z "$SHA" ]; then
	echo "ERROR: no HEAD commit — can't launch Phase 1 without a commit to review" >&2
	exit 2
fi

# v0.6.5 (#39): plugin-cache fallback so consumer repos without a local
# .claude/hooks/list-phase1-agents.sh can still launch Phase 1.
PLUGIN_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" && pwd)"
# shellcheck source=../_lib/resolve-plugin-helper.sh
. "$PLUGIN_LIB/resolve-plugin-helper.sh"

LIST_SCRIPT="$(resolve_plugin_helper "hooks/list-phase1-agents.sh" 2>/dev/null || echo "")"
if [ -z "$LIST_SCRIPT" ] || [ ! -x "$LIST_SCRIPT" ]; then
	echo "ERROR: list-phase1-agents.sh missing (checked $REPO_ROOT/.claude/hooks/ + plugin cache)" >&2
	exit 2
fi

# v4.15.GG: don't swallow SSOT stderr — matches phase1-dashboard.sh pattern.
if ! EXPECTED=$("$LIST_SCRIPT" main | sort -u); then
	echo "ERROR: list-phase1-agents.sh failed — failing closed" >&2
	exit 2
fi
if [ -z "$EXPECTED" ]; then
	echo "ERROR: list-phase1-agents.sh returned no agents" >&2
	exit 2
fi
EXPECTED_COUNT=$(printf '%s\n' "$EXPECTED" | wc -l | tr -d ' ')

# Figure out round-next if user passed "next"
LOG=".claude/review-log/${SHA}.jsonl"
if [ "$ROUND" = "next" ]; then
	if [ -f "$LOG" ]; then
		LAST=$(jq -r 'select(.phase==1 and .round!=null) | .round' "$LOG" 2>/dev/null | sort -un | tail -1)
		ROUND=$((${LAST:-0} + 1))
	else
		ROUND=1
	fi
fi

# v4.23-C (#549): incremental agent scoping. Round 1 reviews the full
# main..HEAD diff (establishes the baseline). Rounds 2+ use the last
# all-agents-clean round's SHA as the base — agents review only what
# changed since the diff was last fully clean. Catches regressions in
# deltas without re-reading stable code. 40-60% per-round token drop
# after round 1.
#
# Determining "last clean SHA" — walk all branch SHAs' review-logs, find
# the most recent round where every expected agent returned findings=0
# + status=ok + round-clean. Only rounds matching the *current* expected
# agent set count as "clean" (no partial-agent-set fabrication).
#
# If no prior clean round exists (round 1, or every prior round had
# findings), base stays main. If the clean SHA equals HEAD (we just
# committed on top of a clean round), base is that SHA's predecessor
# minus one — practically identical to clean-SHA.
BASE_REF="main"
SCOPE_NOTE="full diff (round 1 baseline OR no prior clean round)"
if [ "$ROUND" -gt 1 ]; then
	COLLECT=".claude/hooks/_phase1-collect-logs.sh"
	if [ -x "$COLLECT" ]; then
		COMBINED=$("$COLLECT" main 2>/dev/null || echo "")
		if [ -n "$COMBINED" ]; then
			# Note: EXPECTED_COUNT computed from full agent list.
			# When detecting clean rounds, we need to account for the fact that
			# some historical rounds may have had skipped/cached agents.
			# We'll extract per-round agent lists from the logs and compare
			# to the expected count at that time.
			EXPECTED_COUNT_SORTED=$(printf '%s\n' "$EXPECTED" | wc -l | tr -d ' ')
			# Tuples of (sha, round) that had ALL expected agents return clean.
			# jq aggregates the round; bash filters to tuples where all agents clean.
			# Modified to be more lenient: a round is clean if all agents that
			# ran returned findings=0 + status=ok, even if count < EXPECTED_COUNT
			# (due to skipped/cached agents in that round).
			# v4.28-W4 PR #755 r5 (CR symmetry): treat status=not-installed as
			# clean too — the launcher itself prints the "log as not-installed"
			# instruction when a skill isn't installed; phase1-before-cr.sh
			# accepts the same status. Without this, the launcher's clean-
			# streak detector silently disagrees with the gate it feeds.
			# v4.30 #772: also accept `not-applicable` (auto-logged for
			# file-type-filtered agents). SSOT symmetry with phase1-before-cr
			# + pre-push-pipeline-gate + phase-log-carry-forward.
			CLEAN_TUPLES=$(printf '%s\n' "$COMBINED" | jq -r '
				select(.phase==1 and .round!=null and (.findings // 0) == 0 and (.status=="ok" or .status=="not-installed" or .status=="not-applicable"))
				| "\(.sha)|\(.round)|\(.agent)"
			' 2>/dev/null | awk -F'|' -v expected_count="$EXPECTED_COUNT_SORTED" '
				{ key=$1"|"$2; agent=$3; sk=key"|"agent; if(!seen[sk]){ count[key]++; seen[sk]=1 }; round_has_agent[key]=1 }
				END { for (k in round_has_agent) if (count[k] == expected_count) print k }
			')
			# Prefer clean SHA that is an ancestor of HEAD (ignore other branches).
			# Walk newest-to-oldest via git log.
			CLEAN_SHA=""
			if [ -n "$CLEAN_TUPLES" ]; then
				for branch_sha in $(git log --pretty=%H main..HEAD 2>/dev/null); do
					if printf '%s\n' "$CLEAN_TUPLES" | grep -q "^${branch_sha}|"; then
						CLEAN_SHA="$branch_sha"
						break
					fi
				done
			fi
			# v4.28-W5 (#757): treadmill anti-pattern. When NO round was clean
			# (PR-E pattern: 28 rounds, never all-clean), the prior fallback was
			# `main..HEAD` — re-litigating already-reviewed code each round.
			# New fallback: last REVIEWED sha (any round, any findings count).
			# Round 2+ then sees only the delta since the prior round, never
			# the whole branch. Agents stop re-finding nits in stable code.
			REVIEWED_SHA=""
			if [ -z "$CLEAN_SHA" ]; then
				# Any phase-1 entry counts — find newest reviewed sha that's
				# an ancestor of HEAD.
				# v4.28-W5 (#767) telemetry: capture jq stderr so a
				# malformed COMBINED stream surfaces instead of silently
				# treadmill-falling-back to main.
				rev_jq_err=$(mktemp)
				rev_jq_rc=0
				REVIEWED_TUPLES=$(printf '%s\n' "$COMBINED" |
					jq -r 'select(.phase==1 and .round!=null) | .sha' 2>"$rev_jq_err" |
					sort -u) || rev_jq_rc=$?
				if [ "$rev_jq_rc" -ne 0 ] || [ -s "$rev_jq_err" ]; then
					echo "phase1-launcher: WARN: REVIEWED_TUPLES jq emitted stderr (rc=$rev_jq_rc): $(head -c 200 "$rev_jq_err")" >&2
				fi
				rm -f "$rev_jq_err"
				if [ -n "$REVIEWED_TUPLES" ]; then
					# v4.28-W5 (#767) telemetry: capture git-log stderr so
					# 'main missing' or 'refs broken' surfaces instead of
					# silent ancestry walk failure.
					gl_err=$(mktemp)
					gl_rc=0
					git_log_out=$(git log --pretty=%H main..HEAD 2>"$gl_err") || gl_rc=$?
					if [ "$gl_rc" -ne 0 ] || [ -s "$gl_err" ]; then
						echo "phase1-launcher: WARN: git log main..HEAD emitted stderr (rc=$gl_rc): $(head -c 200 "$gl_err")" >&2
					fi
					rm -f "$gl_err"
					for branch_sha in $git_log_out; do
						if printf '%s\n' "$REVIEWED_TUPLES" | grep -q "^${branch_sha}$"; then
							REVIEWED_SHA="$branch_sha"
							break
						fi
					done
					# v4.28-W5 (#767) telemetry: surface "no ancestor sha
					# matched" case so rebase/squash orphans are visible
					# distinct from "no reviewed sha" or "broken ref".
					if [ -z "$REVIEWED_SHA" ]; then
						echo "phase1-launcher: NOTE: REVIEWED_TUPLES non-empty but no entry is an ancestor of HEAD (likely rebase/squash orphan)" >&2
					fi
				fi
			fi
			if [ -n "$CLEAN_SHA" ] && [ "$CLEAN_SHA" != "$SHA" ]; then
				BASE_REF="$CLEAN_SHA"
				SCOPE_NOTE="incremental (since last all-clean round at ${CLEAN_SHA:0:8})"
			elif [ -n "$CLEAN_SHA" ] && [ "$CLEAN_SHA" = "$SHA" ]; then
				# Already clean at HEAD — agents should re-confirm against main
				# only if HEAD has moved since. Practically this means a streak
				# round — full diff is still right (the log-walk in pre-push will
				# count it correctly).
				SCOPE_NOTE="full diff (last clean round IS HEAD — likely streak confirmation)"
			elif [ -n "$REVIEWED_SHA" ] && [ "$REVIEWED_SHA" != "$SHA" ]; then
				BASE_REF="$REVIEWED_SHA"
				SCOPE_NOTE="incremental delta (since last reviewed round at ${REVIEWED_SHA:0:8}, no clean round yet — anti-treadmill #757)"
			fi
		fi
	fi
fi

# v4.28-W5 (#788 follow-up) — content-aware short-circuit. When the
# diff BASE_REF..HEAD contains no agent-relevant files (only audit
# logs, memory, .enc re-encrypts, etc.), the most-recent clean round
# at BASE_REF can be carried forward to HEAD. The streak walker in
# pre-push-pipeline-gate dedupes on (sha, round) tuple, so a carried
# entry with .sha=HEAD counts as a fresh clean round. This breaks
# the "every irrelevant commit restarts the streak" loop that drove
# PR #782 to 25 phase-1 rounds across 20 commits.
ARF="$(dirname "$0")/agent-relevant-files.sh"
CARRY="$(dirname "$0")/phase-log-carry-forward.sh"
# Phase 1 r1 code-reviewer MED: BASE_REF != "main" is a structural-not-string
# property — gate carry-forward when we have a prior reviewed SHA on the
# branch (which is what BASE_REF=CLEAN_SHA or REVIEWED_SHA indicates).
# Equivalent to "round > 1 with prior history", branch-name-agnostic.
if [ "$BASE_REF" != "main" ] && [ -x "$ARF" ] && [ -x "$CARRY" ]; then
	# Phase 1 r1 silent-failure-hunter HIGH (conf 9): rc=2 (tooling broken
	# — yq missing, config corrupt) used to fall through to the full
	# launcher path identically to rc=0 (relevant files present). Operator
	# never learned the content-aware gate was silently disabled. Now we
	# capture stderr + surface a WARN on rc=2 so a config regression doesn't
	# silently restore the 25-round loop this PR exists to fix.
	# set -e + bare-command pattern aborts when ARF exits non-zero (which is
	# exactly the carry-forward case rc=1). Use ||-rc-capture instead, per
	# feedback_rc_capture_set_e.md memory.
	arf_err=$(mktemp 2>/dev/null) || arf_err=/dev/null
	arf_rc=0
	"$ARF" "$BASE_REF" "$SHA" >/dev/null 2>"$arf_err" || arf_rc=$?
	if [ "$arf_rc" -eq 2 ]; then
		stderr_snippet=""
		[ "$arf_err" != /dev/null ] && [ -s "$arf_err" ] && stderr_snippet=$(head -c 400 "$arf_err")
		echo "phase1-launcher: WARN: CONTENT-AWARE GATE BROKEN — agent-relevant-files.sh rc=2: ${stderr_snippet:-<no stderr>}" >&2
		echo "  Content-aware short-circuit DISABLED for this round; falling through to full launcher output." >&2
	fi
	[ "$arf_err" != /dev/null ] && rm -f "$arf_err"
	if [ "$arf_rc" -eq 1 ]; then
		# No agent-relevant files between BASE_REF..HEAD. Attempt
		# carry-forward. Phase 1 r1 silent-failure-hunter HIGH (conf 9):
		# distinguish rc=0 (success — skip the round), rc=1 (nothing to
		# carry — expected, fall through quietly), rc=2 (jq missing /
		# write failed — print loud diagnostic + fall through). The
		# old `if "$CARRY" ...; then` form collapsed rc=1 and rc=2 into
		# identical fall-through, masking real breakage.
		carry_err=$(mktemp 2>/dev/null) || carry_err=/dev/null
		carry_rc=0
		"$CARRY" "$BASE_REF" "$SHA" 2>"$carry_err" || carry_rc=$?
		if [ "$carry_rc" -eq 0 ]; then
			# Replay any stderr the helper produced (the "carried N
			# entries" success message goes to stderr by convention).
			[ "$carry_err" != /dev/null ] && [ -s "$carry_err" ] && cat "$carry_err" >&2
			[ "$carry_err" != /dev/null ] && rm -f "$carry_err"
			cat <<EOF
=== Phase 1 Round $ROUND — CARRIED FORWARD ===

No agent-relevant files changed between ${BASE_REF:0:8}..${SHA:0:8}
(only audit-logs / memory / .enc re-encrypts / docs were touched).

Carried clean entries from ${BASE_REF:0:8} → ${SHA:0:8}.
Streak counter advances WITHOUT re-running agents.

Action: skip to the next pipeline step (Phase 2 / push / merge-gate).
Use 'ship-pr-cycle.sh status' to confirm the streak count.
EOF
			exit 0
		elif [ "$carry_rc" -eq 2 ]; then
			cstderr_snippet=""
			[ "$carry_err" != /dev/null ] && [ -s "$carry_err" ] && cstderr_snippet=$(head -c 400 "$carry_err")
			echo "phase1-launcher: WARN: CARRY-FORWARD BROKEN — phase-log-carry-forward.sh rc=2: ${cstderr_snippet:-<no stderr>}" >&2
			echo "  Falling through to full launcher output; investigate jq/log-write failure above." >&2
		fi
		# rc=1 is expected ("nothing to carry") — fall through silently.
		[ "$carry_err" != /dev/null ] && rm -f "$carry_err"
	fi
fi

# v4.23-S (#565): agent subset by diff file type. Some agents are dead
# weight on certain file kinds. Token savings compound with v4.23-A's
# round-count scaling.
#
#  .bats only           → skip security-review, semgrep, silent-failure-hunter
#  *.md / docs/** only  → keep only code-reviewer + comment-analyzer
#  config-only          → skip pr-test-analyzer (no testable code paths)
#  *.yml workflow-only  → keep all + actionlint focus note
#  (mixed diff)         → keep all (no filtering)
#
# Detection uses the same classifiers pre-push-pipeline-gate.sh uses —
# _diff_files already computed by this launcher's scope logic.
SKIP_AGENTS=""
DIFF_ALL_FILES=$(git diff --name-only "${BASE_REF}..HEAD" 2>/dev/null)
if [ -n "$DIFF_ALL_FILES" ]; then
	# Helper: is every line in DIFF_ALL_FILES matching the glob(s)?
	# Enables globstar so patterns like `docs/**` match recursively. Saves
	# + restores the prior shopt so we don't leak state back to the caller.
	_all_match() {
		local pat1=$1 pat2=${2:-} f
		local _prev_globstar
		# globstar is bash 4.0+. macOS /bin/bash is 3.2 — `shopt -s globstar`
		# errors there. Capture current state + enable defensively; on bash-3
		# the `shopt -s globstar` silently fails and the `$pat1` match degrades
		# to literal matching (no recursive **). Acceptable because the patterns
		# used here (*.bats, *.md, docs/**, *.yml) don't actually need recursive
		# ** for the shallow file sets this repo produces.
		_prev_globstar=$(shopt -p globstar 2>/dev/null || echo "")
		shopt -s globstar 2>/dev/null || true
		while IFS= read -r f; do
			[ -z "$f" ] && continue
			# shellcheck disable=SC2053
			[[ $f == $pat1 ]] && continue
			if [ -n "$pat2" ]; then
				# shellcheck disable=SC2053
				[[ $f == $pat2 ]] && continue
			fi
			[ -n "$_prev_globstar" ] && eval "$_prev_globstar"
			return 1
		done <<<"$DIFF_ALL_FILES"
		[ -n "$_prev_globstar" ] && eval "$_prev_globstar"
		return 0
	}
	if _all_match '*.bats'; then
		SKIP_AGENTS="security-review semgrep silent-failure-hunter"
		SCOPE_NOTE="$SCOPE_NOTE; agent-subset=bats-only (skip security/semgrep/silent-failure)"
	elif _all_match '*.md' 'docs/**'; then
		SKIP_AGENTS="security-review semgrep silent-failure-hunter pr-test-analyzer code-simplifier"
		SCOPE_NOTE="$SCOPE_NOTE; agent-subset=docs-only (code-reviewer+comment-analyzer only)"
	elif _all_match '*.yml' '*.yaml'; then
		# Non-workflow YAML: skip test-analyzer
		if ! echo "$DIFF_ALL_FILES" | grep -q '\.github/workflows/'; then
			SKIP_AGENTS="pr-test-analyzer"
			SCOPE_NOTE="$SCOPE_NOTE; agent-subset=config-yaml (skip pr-test-analyzer)"
		fi
	fi
fi

# v4.28-W3-C (#671): per-(agent × file × blob-sha) cache lookup. Replaces
# the v4.23-G whole-diff sha256 hash model — that key invalidated EVERY
# agent's prior clean review whenever ANY file in the diff changed, even
# files outside that agent's scope. Per-file blob-sha matches the bats-
# gate model and only invalidates agents whose scoped files actually
# changed.
#
# An agent is cached-clean when ALL its scoped files (per
# list-agent-files.sh) have a status=ok cache entry at their CURRENT
# blob-sha. Zero scoped files means nothing to verify → not cached
# (treat as miss; agent runs to confirm there's nothing to do).
CACHE_LIB="$(dirname "$0")/../_lib/content-hash-cache.sh"
LIST_FILES_SCRIPT="$(dirname "$0")/list-agent-files.sh"
CACHED_AGENTS=""
if [ -f "$CACHE_LIB" ] && [ -x "$LIST_FILES_SCRIPT" ]; then
	# shellcheck source=/dev/null
	source "$CACHE_LIB"
	for agent in $EXPECTED; do
		# Skip agents already in SKIP_AGENTS — no need to cache-check.
		skip=0
		for s in $SKIP_AGENTS; do
			[ "$agent" = "$s" ] && skip=1 && break
		done
		[ "$skip" = "1" ] && continue
		# Per-agent scoped files (using main as base for stable cache keying).
		# r2 sfh #3: surface list-agent-files.sh failures rather than
		# treating every error mode (yq missing, agent unknown, base ref
		# missing, config corrupt) as "empty scope → skip cache check".
		# That silenced the very tooling/config breakage operators most
		# need to see.
		lf_err=$(mktemp)
		lf_rc=0
		agent_files=$("$LIST_FILES_SCRIPT" "$agent" main 2>"$lf_err") || lf_rc=$?
		if [ "$lf_rc" -ne 0 ]; then
			echo "phase1-launcher: WARN: list-agent-files.sh failed for $agent (rc=$lf_rc):" >&2
			cat "$lf_err" >&2
			agent_files=""
		fi
		rm -f "$lf_err"
		[ -z "$agent_files" ] && continue
		# Cached iff EVERY scoped file has status=ok at current blob-sha.
		all_ok=1
		while IFS= read -r f; do
			[ -z "$f" ] && continue
			status=$(cache_lookup "phase1-$agent" "$f" 2>/dev/null || echo "")
			if [ "$status" != "ok" ]; then
				all_ok=0
				break
			fi
		done <<<"$agent_files"
		if [ "$all_ok" = "1" ]; then
			CACHED_AGENTS="${CACHED_AGENTS:+$CACHED_AGENTS }$agent"
		fi
	done
	if [ -n "$CACHED_AGENTS" ]; then
		SCOPE_NOTE="$SCOPE_NOTE; cache-hits=[$CACHED_AGENTS]"
	fi
fi

# Build the effective agent list (EXPECTED minus SKIP_AGENTS minus CACHED).
EFFECTIVE_AGENTS=""
for agent in $EXPECTED; do
	skip=0
	for skipped in $SKIP_AGENTS $CACHED_AGENTS; do
		[ "$agent" = "$skipped" ] && skip=1 && break
	done
	[ "$skip" -eq 0 ] && EFFECTIVE_AGENTS="$EFFECTIVE_AGENTS$agent
"
done
# `grep -c .` outputs "0" AND exits 1 on no-match — `|| echo 0` then adds
# a SECOND "0", producing "0\n0" which breaks `[ -eq 0 ]` numeric tests.
# awk avoids the issue: always exits 0, prints a single integer.
EFFECTIVE_COUNT=$(printf '%s' "$EFFECTIVE_AGENTS" | awk 'NF { c++ } END { print c+0 }')

# v4.30 #772: auto-log file-type-filtered agents as `not-applicable`
# so the gate (phase1-before-cr.sh) accepts the round as clean even when
# not all 7 agents physically fired. Without this, operators had to
# manually log skipped agents with status `not-installed` to satisfy
# the gate (semantically wrong — they ARE installed, just not applicable).
# Cached agents stay out of the auto-log (their prior pass IS the signal).
#
# v4.30 #772 Phase 2 r1/r2/r5 CR-CLI major: auto-log skipped agents with
# status=not-applicable; FAIL-CLOSED on both mktemp failure (r2) and
# review-log.sh failure (r5). The launcher exits non-zero on any auto-log
# error rather than continuing — this surfaces the underlying cause at its
# source instead of leaking through as a downstream "gate refused
# convergence" error the operator has to root-cause backwards. Pairs with
# the gate's missing-agent rejection (gate is canonical safety net; this
# is the source-level signal).
if [[ $ROUND =~ ^[0-9]+$ ]]; then
	for skipped_agent in $SKIP_AGENTS; do
		# v4.30 #772 Phase 2 r2 CR-CLI major: fail-closed on mktemp.
		# Environments where mktemp fails are pathological (full /tmp,
		# permissions); the launcher should refuse rather than continue
		# with degraded auto-log capture. review-log.sh failures still
		# WARN-then-continue (gate enforcement is the canonical safety net).
		_autolog_err=$(mktemp -t phase1-autolog-err.XXXXXX) || {
			echo "phase1-launcher: ERROR: mktemp failed for skipped-agent auto-log stderr capture (disk full? /tmp permissions?)" >&2
			exit 2
		}
		# v4.30 #772 Phase 2 r5 CR-CLI major: fail-closed on review-log.sh
		# failure too. Without this, the round is missing the auto-log entry
		# and the gate refuses — but the operator only sees the gate refusal,
		# not the underlying cause. Failing the launcher with rc=2 surfaces
		# the failure at its source.
		_autolog_rc=0
		"$(dirname "$0")/review-log.sh" phase1 "$ROUND" "$skipped_agent" 0 not-applicable >/dev/null 2>"$_autolog_err" || _autolog_rc=$?
		if [ "$_autolog_rc" -ne 0 ]; then
			echo "phase1-launcher: ERROR: auto-log for skipped agent '$skipped_agent' (round=$ROUND, status=not-applicable) failed rc=$_autolog_rc" >&2
			[ -s "$_autolog_err" ] && head -c 200 "$_autolog_err" >&2 && echo "" >&2
			echo "  Manual log: .claude/hooks/review-log.sh phase1 $ROUND $skipped_agent 0 not-applicable" >&2
			rm -f "$_autolog_err"
			exit "$_autolog_rc"
		fi
		rm -f "$_autolog_err"
	done
fi

# v4.23-W: cache/filter can make EFFECTIVE_COUNT zero, breaking
# streak-confirmation. Fallback: always run at least one agent.
if [ "$EFFECTIVE_COUNT" -eq 0 ] && [ -n "$EXPECTED" ]; then
	# Pick the first agent from EXPECTED as the fallback.
	EFFECTIVE_AGENTS=$(printf '%s\n' "$EXPECTED" | head -1)
	EFFECTIVE_COUNT=1
	SCOPE_NOTE="$SCOPE_NOTE; fallback-agent (cache+filter yielded 0)"
fi

# v4.27 (#632): write a sidecar manifest of EFFECTIVE_AGENTS for this
# round so phase1-launch-completeness-gate.sh can verify round N-1 was
# fully logged before round N is launched. Snapshot is essential — by
# round N, diff state may have changed (fix commit between rounds), so
# re-computing the effective set later would give a different answer
# than what was actually launched.
if [[ $ROUND =~ ^[0-9]+$ ]]; then
	REVIEW_LOG_DIR="$REPO_ROOT/.claude/review-log"
	if ! mkdir -p "$REVIEW_LOG_DIR"; then
		echo "phase1-launcher: FAIL — mkdir $REVIEW_LOG_DIR failed" >&2
		exit 1
	fi
	SIDECAR="$REVIEW_LOG_DIR/${SHA}-round-${ROUND}-effective.txt"
	if ! printf '%s' "$EFFECTIVE_AGENTS" >"$SIDECAR"; then
		echo "phase1-launcher: FAIL — write to $SIDECAR failed" >&2
		exit 1
	fi
fi

cat <<EOF
=== Phase 1 Launcher — Round $ROUND ===
HEAD: ${SHA:0:12}
Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)
Base: $BASE_REF (review-scope: git diff ${BASE_REF}..HEAD — $SCOPE_NOTE)

Files in diff:
$(git diff --stat "${BASE_REF}..HEAD" 2>/dev/null | sed 's/^/  /' | head -20)

Launch $EFFECTIVE_COUNT of $EXPECTED_COUNT agents in a SINGLE parallel Agent block this round:
${SKIP_AGENTS:+
  (skipped per v4.23-S file-type filter: $SKIP_AGENTS)
}
EOF

# v4.24-O (#601): canonical briefs from SSOT. If review-config.yml defines
# a `canonical_brief` for the agent, emit it (placeholders resolved); else
# fall back to the pre-v4.24-O generic brief line.
# v0.6.5 (#39): try REPO_ROOT first, then plugin-cache fallback.
CONFIG="$(resolve_plugin_helper "review-config.yml" 2>/dev/null || echo "")"
HAS_CONFIG=0
if [ -n "$CONFIG" ] && [ -f "$CONFIG" ] && command -v yq >/dev/null 2>&1; then
	HAS_CONFIG=1
fi

_canonical_brief() {
	# Args: $1=agent name. Echoes the resolved brief or nothing on miss.
	local agent=$1 brief
	[ "$HAS_CONFIG" = "1" ] || return 1
	brief=$(yq -r ".agents.\"$agent\".canonical_brief // \"\"" "$CONFIG" 2>/dev/null)
	[ -n "$brief" ] || return 1
	# Brace-delimited placeholder substitution via bash parameter expansion.
	# Portable to macOS bash 3.2 (no `mapfile -d`). Space-joined, matches
	# the space-joined doc in review-config.yml's {DIFF_FILES} definition.
	# Filenames containing newlines are extremely rare in this repo and a
	# known limitation; if one appears, the brief will just have an extra
	# space — non-fatal for the advisory prompt use case.
	local diff_files_joined
	diff_files_joined=$(git diff --name-only "${BASE_REF}..HEAD" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
	brief=${brief//\{BASE_REF\}/$BASE_REF}
	brief=${brief//\{HEAD_SHA\}/${SHA:0:12}}
	brief=${brief//\{ROUND\}/$ROUND}
	brief=${brief//\{DIFF_FILES\}/$diff_files_joined}
	printf '%s' "$brief"
}

# v4.28-W5 (#757): inject rejection-list into agent prompts so they don't
# re-litigate already-rejected findings. Reads prove-yourself rejection
# records from .claude/.session-state/prove-yourself/*.json. Emitted as a
# single block after the per-agent brief on round 2+. Up to 20 distinct
# rejection finding-texts (each truncated to 200 chars). NOTE: ordering is
# alphabetical (sort -u dedup), NOT mtime/recency — the cap removes
# alphabetically-late entries when the corpus exceeds 20.
REJECTION_DIR=".claude/.session-state/prove-yourself"
REJECTION_BLOCK=""
if [ -d "$REJECTION_DIR" ] && [ "$ROUND" -gt 1 ]; then
	# Phase 1 r5 fix (conf 9-10): null-defense + dedup. The jq selector
	# now skips records with missing/null/empty finding_text — without
	# this, a schema-drift record produced "- " literal noise lines.
	# Emptiness guard: skip the jq invocation block when no .json files
	# exist so the telemetry branch "0 records (no .json files in
	# $REJECTION_DIR)" fires instead of "0 records (round N)" — the two
	# values let an operator distinguish "no rejections this round
	# (mechanism healthy)" from "no rejections (mechanism broken)".
	# v4.28-W5 (#767) telemetry: capture find stderr (e.g. unreadable dir,
	# perms) so silent breakage on rejection-list pipeline surfaces.
	find_err=$(mktemp)
	find_rc=0
	# v4.28-W5 #832 Phase 1 r1 fix: pipe through `sort` to lock
	# deterministic alpha iteration order. POSIX find does NOT guarantee
	# order; readdir(3) order varies by filesystem (APFS ≈ lexical, ext4
	# dir_index = hash order). Tests like `corrupt-MIDDLE` need stable
	# ordering to actually exercise the position they claim. The sort
	# itself adds negligible cost (typical rejection-dir = <50 files).
	rejection_files=$(find "$REJECTION_DIR" -name "*.json" -type f 2>"$find_err" | sort) || find_rc=$?
	# CR PR #835: fail-loud when discovery itself breaks (broken sort,
	# unreadable dir, traversal error) — that's a tooling failure, not
	# corrupt input, and dropping every rejection record silently would
	# defeat #832's anti-treadmill protection just as the bug it fixed.
	# Non-empty stderr alone is still WARN-only (find emits to stderr for
	# benign cases like a permissions-denied subdir while still returning
	# rc=0 + a usable list).
	if [ "$find_rc" -ne 0 ]; then
		err_snip=$(head -c 200 "$find_err")
		rm -f "$find_err"
		echo "phase1-launcher: ERROR: find on $REJECTION_DIR failed (rc=$find_rc): $err_snip" >&2
		exit 2
	elif [ -s "$find_err" ]; then
		echo "phase1-launcher: WARN: find on $REJECTION_DIR emitted stderr (rc=$find_rc): $(head -c 200 "$find_err")" >&2
	fi
	rm -f "$find_err"
	if [ -n "$rejection_files" ]; then
		# v4.28-W5 (#767) telemetry: capture per-file jq stderr; aggregate
		# count of records produced so operator distinguishes "no rejections
		# this round" (mechanism healthy) from "no rejections (jq missing /
		# schema drift / corrupt JSON)".
		jq_err=$(mktemp)
		# v4.28-W5 #832: per-file jq failures are non-fatal for corrupt
		# input (rc=4/5) but fail-loud for non-corrupt failures (binary
		# missing, OOM, signal). Prior: any corrupt rejection record
		# (regardless of iteration order) caused jq to return rc=5,
		# which under launcher's `set -euo pipefail` propagated through
		# command substitution and aborted the launcher with rc=5 —
		# losing ALL rejection records. (The `| sort` above is unrelated
		# to this bug; it locks deterministic test fixture iteration.) The corrupt
		# file's stderr still captures via `2>>$jq_err` so the WARN
		# emitted when `[ -s "$jq_err" ]` below still fires. Empty
		# stdout from a failed jq is the documented degraded behavior
		# the rejection-block contract is built around ("one corrupt
		# file does not drop ALL rejections" — locked by tests 10-13
		# in phase1-launcher-anti-treadmill-coverage.bats: 10=corrupt-
		# MIDDLE, 11=all-corrupt clean degradation, 12=fail-loud rc=2
		# contract for non-corrupt jq failures, 13=rc=4 silent-continue
		# branch independent from rc=5). The jq-rc discrimination is at
		# the loop body.
		#
		# v0.30 #220: scope to the CURRENT PR cycle (branch) — the SAME predicate
		# as phase1-resume-message.sh's _rejection_block (kept consistent, no
		# drift; differs only in line-wrapping). Records carry .branch (stamped by
		# prove-yourself-audit record-rejection); legacy / other-branch records
		# are excluded so a round isn't shown stale cross-PR rejections.
		# `symbolic-ref --short` returns EMPTY on detached HEAD / not-a-repo (never
		# the literal "HEAD"), so the `$br == ""` arm means "undeterminable →
		# include all". git -C "$REPO_ROOT" → identical value to the other sites.
		_rej_branch=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
		REJECTION_BLOCK=$(
			printf '%s\n' "$rejection_files" |
				while IFS= read -r f; do
					[ -f "$f" ] || continue
					# v4.28-W5 #832 CR-CLI r2: discriminate jq exit codes.
					# rc=4/5 are jq's "malformed input"/"parse error" codes —
					# expected for corrupt rejection records, silent continue
					# (per-file resilience contract). Other non-zero rc
					# (binary missing, OOM, signal) is a non-corrupt failure
					# that should fail-loud so a regression in jq itself or
					# the invocation isn't silently masked.
					# Note: `if` not `case` — bash 3.2 (macOS default) has a
					# parser bug where `case` inside a pipeline inside `$(…)`
					# fails with "syntax error near unexpected token ;;" even
					# when the syntax is well-formed. The if-chain avoids it.
					jq_rc=0
					jq -r --arg br "$_rej_branch" 'select(.kind == "rejection" and (.finding_text // "") != "" and ($br == "" or (.branch // "") == $br)) | "- \(.finding_text[0:200])"' "$f" 2>>"$jq_err" || jq_rc=$?
					if [ "$jq_rc" -ne 0 ] && [ "$jq_rc" -ne 4 ] && [ "$jq_rc" -ne 5 ]; then
						echo "phase1-launcher: ERROR: jq failed for '$f' with rc=$jq_rc (non-corrupt failure — fail-loud)" >&2
						exit 2
					fi
				done |
				sort -u | head -20
		)
		if [ -s "$jq_err" ]; then
			echo "phase1-launcher: WARN: rejection-list jq emitted stderr (corrupt record?): $(head -c 200 "$jq_err")" >&2
		fi
		rm -f "$jq_err"
		# Count emitted rejection rows (positive-confirmation telemetry).
		# v0.30 #220 (silent-failure-hunter): when files exist but 0 survive the
		# branch filter, say so — masked-zero (all out-of-cycle / corrupt) reads
		# differently from a healthy "no rejections this round".
		rej_count=$(printf '%s\n' "$REJECTION_BLOCK" | awk 'NF { c++ } END { print c+0 }')
		if [ "$rej_count" -eq 0 ]; then
			echo "phase1-launcher: rejection-list: 0 in-cycle records for branch '${_rej_branch:-<none>}' (round $ROUND; rejection files present but scoped out by branch / corrupt)" >&2
		else
			echo "phase1-launcher: rejection-list: $rej_count records (round $ROUND)" >&2
		fi
	else
		echo "phase1-launcher: rejection-list: 0 records (no .json files in $REJECTION_DIR)" >&2
	fi
fi

i=1
for agent in $EFFECTIVE_AGENTS; do
	# v0.30.F (#193): per-agent flag — set to 1 only when this agent is
	# emitted as a SendMessage RESUME (round N>1, eligible). Resumed agents
	# carry their brief + the two-way rejection list inside the resume message
	# body, so the post-case canonical-brief + one-way DO-NOT-RE-FLAG block
	# are suppressed for them to avoid duplicate / conflicting instructions.
	AGENT_RESUMED=0
	case "$agent" in
	security-review)
		# v4.28-W3-L (#739): /security-review lives in
		# anthropics/claude-code-security-review (separate repo from the
		# claude-plugins-official marketplace), distributed as a slash
		# command file. If `.claude/commands/security-review.md` is
		# present, emit the standard invocation brief; otherwise tell
		# the operator to log it as a stub instead of pretending it ran.
		if [ -f "$REPO_ROOT/.claude/commands/security-review.md" ]; then
			echo "  $i. Skill invocation — /security-review — review git diff ${BASE_REF}..HEAD"
		else
			echo "  $i. /security-review NOT INSTALLED — log as 'security-review 0 not-installed' via review-log.sh."
			echo "     To install: copy from anthropics/claude-code-security-review (.claude/commands/security-review.md)."
		fi
		;;
	semgrep)
		# v4.15.W: MCP semgrep_scan errors with "output too large" on whole-repo
		# scans. CLI with scoped paths is reliable.
		# v4.23-C: scope to files changed since BASE_REF (not main) on round N>1.
		# v4.23-R (#564): incremental scan via --baseline-ref on round N>1 —
		# semgrep diffs against the baseline and only reports findings on
		# lines NEW since that baseline. 50-80% reduction on rebase-clean PRs
		# where most files are unchanged.
		# v4.28-W5 (#788 follow-up): `|| true` on the grep keeps pipefail
		# from aborting the launcher when no code files are in the diff.
		# Surfaced by content-aware carry-forward tests where round 2+
		# diffs may contain only audit/log files (no .sh/.yml/.py/etc.) —
		# previously the launcher crashed with set -e +o pipefail before
		# emitting the "no code files in diff" branch below.
		DIFF_FILES=$(git diff --name-only "${BASE_REF}..HEAD" 2>/dev/null | { grep -E '\.(sh|yml|yaml|py|js|ts|go)$' || true; } | tr '\n' ' ' | sed 's/ $//')
		SEMGREP_ARGS="--config=auto --error"
		if [ "$ROUND" -gt 1 ] && [ "$BASE_REF" != "main" ]; then
			# BASE_REF is the last-clean-sha on round N>1 — use it as baseline.
			SEMGREP_ARGS="$SEMGREP_ARGS --baseline-ref $BASE_REF"
		fi
		if [ -n "$DIFF_FILES" ]; then
			echo "  $i. semgrep scan $SEMGREP_ARGS $DIFF_FILES"
		else
			echo "  $i. semgrep scan $SEMGREP_ARGS (no code files in diff — may skip)"
		fi
		;;
	*)
		# v0.30.F (#193): SendMessage resume on round N>1. `directive` is
		# READ-ONLY + idempotent — empty output means fall through to the
		# fresh-Agent line (flag off / round 1 / no record / cap reached /
		# no new delta). Byte-identical to pre-#193 whenever it's empty, so
		# the experimental path never changes behaviour for non-flag users.
		_resume_line=""
		_aid_helper="$(dirname "$0")/phase1-agent-id.sh"
		if [ -x "$_aid_helper" ]; then
			# Phase 1 r1 (silent-failure-hunter): capture directive's rc instead
			# of `|| echo ""`. rc 2 = the launcher passed bad args to its own
			# helper (a real contract bug, e.g. a malformed BASE_REF from the
			# clean-SHA walk) — distinct from the intended empty-output no-op
			# (rc 0: flag off / round 1 / cap / no delta). Surface rc 2; don't
			# let it masquerade as a silent fall-through to fresh.
			_dir_err=$(mktemp 2>/dev/null) || _dir_err=/dev/null
			_dir_rc=0
			_resume_line=$("$_aid_helper" directive "$agent" "$ROUND" "$BASE_REF" "$SHA" 2>"$_dir_err") || _dir_rc=$?
			if [ "$_dir_rc" -eq 2 ]; then
				echo "phase1-launcher: WARN: phase1-agent-id directive rc=2 for $agent (bad args/contract?): $(head -c 200 "$_dir_err" 2>/dev/null)" >&2
				_resume_line=""
			fi
			[ "$_dir_err" != /dev/null ] && rm -f "$_dir_err"
		fi
		_fresh_line="  $i. Agent subagent_type=pr-review-toolkit:$agent — brief with git diff ${BASE_REF}..HEAD"
		if [ -z "$_resume_line" ]; then
			echo "$_fresh_line"
		else
			# Phase 1 r1 (silent-failure-hunter, HIGH): build the peer-review
			# body UP FRONT + capture its rc before committing to a resume. The
			# builder is fail-loud (rc 3) when its rejection scan breaks; the old
			# `... 2>/dev/null | sed | … || true` discarded that rc AND the
			# partial stdout still reached the operator — so a broken build
			# silently dropped the dismissed-findings+dogfood-evidence block and
			# the teammate re-litigated rejected findings, defeating the whole
			# peer-review layer. On any build failure, downgrade to a FRESH spawn
			# rather than emit a partial/empty resume body.
			_msg_helper="$(dirname "$0")/phase1-resume-message.sh"
			_body=""
			_body_rc=0
			if [ -x "$_msg_helper" ]; then
				_body=$("$_msg_helper" build "$agent" "$ROUND" "$BASE_REF" "$SHA" 2>/dev/null) || _body_rc=$?
			else
				_body_rc=127
			fi
			if [ "$_body_rc" -ne 0 ] || [ -z "$_body" ]; then
				echo "phase1-launcher: WARN: resume-message build failed (rc=$_body_rc) for $agent — using a fresh Agent instead of a partial resume body" >&2
				echo "$_fresh_line (resume downgraded: message build failed)"
			else
				AGENT_RESUMED=1
				echo "  $i. [RESUME] $_resume_line"
				# Send the body VERBATIM as the SendMessage `message`. After a
				# SUCCESSFUL resume, commit it: phase1-agent-id.sh resumed $agent $SHA (footer).
				echo "       ↓ send VERBATIM as the SendMessage message body ↓"
				printf '%s\n' "$_body" | sed 's/^/       /'
			fi
		fi
		;;
	esac
	# v4.24-O: emit the canonical brief body as an indented block so Claude
	# can copy it verbatim into the Agent tool invocation. Suppresses when
	# the SSOT doesn't define one for this agent (keeps free-form fallback).
	# v0.30.F (#193): also suppressed for RESUMED agents — they hold their
	# brief in retained context, and the resume message scopes them to the
	# delta, so a full-diff canonical brief would send a conflicting signal.
	if [ "$AGENT_RESUMED" -eq 0 ] && resolved=$(_canonical_brief "$agent"); then
		printf '%s\n' "$resolved" | sed 's/^/       /'
	fi
	# Anti-treadmill rejection-list injection (#757). One block per agent
	# (cheap — same content for all). Suppressed on round 1 + when no
	# rejections recorded. v0.30.F (#193): also suppressed for RESUMED agents
	# — the resume message already embeds these rejections in two-way (refute
	# / accept) form, so the one-way DO-NOT-RE-FLAG block would duplicate it.
	if [ -n "$REJECTION_BLOCK" ] && [ "$AGENT_RESUMED" -eq 0 ]; then
		printf '\n       DO NOT RE-FLAG (already rejected this PR cycle):\n'
		printf '%s\n' "$REJECTION_BLOCK" | sed 's/^/       /'
	fi
	i=$((i + 1))
done

cat <<EOF

After each agent returns:
  .claude/hooks/review-log.sh phase1 $ROUND <agent> <findings-count> ok

Round passes when every agent returns findings=0 with status in {ok, not-installed, not-applicable}.
Convergence = ${PHASE1_MIN_CLEAN_STREAK:-2} consecutive clean rounds (and ≥${PHASE1_MIN_ROUNDS:-5} total rounds).
After a fix, re-run ALL agents on the WHOLE diff — increment round, don't append to this round.

v4.28-W3-T (#658): while agents run, fire SCOPED bats in parallel
(test-touched scopes via \`# covers:\` headers; full \`scripts/test.sh\`
is reserved for pre-push + weekly baseline). Iteration loop = scoped.
  scripts/test-touched.sh --git-base main > /tmp/bats-r${ROUND}.log 2>&1 &
  (check \$? after agents converge; any bats failure = fix-same-round)

EOF

# v0.30.F (#193): agent-team resume bookkeeping. Flag-gated so output is
# byte-identical to pre-#193 when the experimental flag is off.
if [ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-0}" = "1" ]; then
	cat <<EOF
v0.30.F (#193) — SendMessage resume bookkeeping (this round may RESUME agents above):
  • After a FRESH Agent spawn, capture its agentId from the return JSON + record it:
      .claude/hooks/phase1-agent-id.sh record <agent> <agentId> $SHA
  • After a SUCCESSFUL [RESUME], commit the resume event (bumps cap counter):
      .claude/hooks/phase1-agent-id.sh resumed <agent> $SHA
  • If a [RESUME] FAILS (teammate not resumable), fall back to a fresh Agent, then:
      .claude/hooks/phase1-agent-id.sh clear <agent>
  • Resumed teammates reply with JSON {new_findings, refutations, accepted_rejections}.
    review-log findings-count = len(new_findings). Handle refutations per
    skills/ship-pr-cycle/SKILL.md (re-dogfood → reopen-as-fix OR re-confirm-rejection).

EOF
fi

# v4.23-F (#552): CR-budget-aware Phase 2 skip directive. If the prepaid
# CR bucket has <2 slots free when Phase 1 converges, skip local
# Phase 2 CR CLI and go straight to push — CR-in-CI will fire anyway
# and consumes the same slot, so running local Phase 2 doubles cost.
# Cap is 10/hr on CR Pro Plus (refill 6min/token); rate-budget.sh's
# default LIMIT was bumped to 10 in 2026-05-04 (post-PR #683 merge).
# v0.6.5 (#39): plugin-cache fallback.
BUDGET_SCRIPT="$(resolve_plugin_helper "scripts/cr/rate-budget.sh" 2>/dev/null || echo "")"
if [ -n "$BUDGET_SCRIPT" ] && [ -x "$BUDGET_SCRIPT" ]; then
	cat <<EOF
v4.23-F (#552): before invoking Phase 2 CR CLI after convergence, run:
  scripts/cr/rate-budget.sh --check
If it reports <2 slots free, SKIP Phase 2 locally + push — CR-in-CI
will fire as required status check + consume the same slot.

EOF
fi

# v4.28-W5 (#788 follow-up): explicit exit 0 so the trailing if-block's
# false-condition rc doesn't propagate to the launcher's exit code under
# `set -e` on bash 3.2 (macOS default). Without this, an empty body
# tail on `if [ -x $BUDGET_SCRIPT ]; then ...; fi` was being seen as
# rc=1 by the bats `run` harness on certain bash builds.
exit 0
