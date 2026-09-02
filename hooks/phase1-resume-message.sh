#!/bin/bash
set -euo pipefail
# auto-register: false
# v0.30.F (#193) — build the SendMessage body for a resumed Phase 1 teammate.
#
# WHY: when phase1-agent-id.sh says agent X is resume-eligible on round N>1,
# the main loop resumes it with SendMessage instead of spawning fresh. The
# message must turn the teammate from a one-way finding-emitter into a peer
# reviewer. It carries three things:
#   1. DELTA SCOPE — review only `git diff <base>..<head>`, not the whole PR
#      (the teammate's prior file Reads + understanding are retained in its
#      resumed context, so re-reading unchanged code is wasted tokens).
#   2. DISMISSED FINDINGS + DOGFOOD EVIDENCE — every finding rejected this PR
#      cycle, WITH the dogfood command/output/reason used to reject it (from
#      prove-yourself records' decision_data). The teammate cross-references
#      against its own remembered findings — no server-side agent filtering
#      needed (its retained context IS the filter).
#   3. A TWO-WAY RESPONSE CONTRACT — the teammate replies with new_findings
#      (on the delta) + refutations (rejected findings it still believes,
#      WITH counter-evidence the rejection's dogfood missed) + accepted_
#      rejections (rejections whose evidence it now accepts → retire them).
#
# This is the agent-team peer-review layer on top of the resume mechanism.
# The refutation outcome is handled by the main loop per ship-pr-cycle
# SKILL.md: a refutation re-dogfooded and upheld → record-fix (reopen +
# fix in-PR); re-confirmed → record-rejection again with the counter-
# evidence addressed in decision_data. These EXISTING prove-yourself actions
# (record-fix / record-rejection) MUST still be run — no NEW action *type* is
# introduced; the refutation flow reuses them rather than adding a kind.
# (#2643) The action type is unchanged but the record-fix CONTRACT grew: a
# citation of a cycle-critical file now also requires --symptom-cmd plus the
# two rcs. The full set is hooks/, _lib/, pre-commit-hooks/ and
# scripts/cr/local-review.sh — naming only the first two here was already a
# drift of the very list this PR is trying to keep honest; run.sh --help is
# the machine-readable definition.
#
# Usage:
#   phase1-resume-message.sh build <agent> <round> <base_ref> <head_sha>
#
# Output: the message body (stdout). Exit codes:
#   0 — body emitted
#   2 — invalid arguments
#   3 — prove-yourself scan failed (non-corrupt) — fail loud, don't silently
#       drop the rejection context the refutation flow depends on.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
REJECTION_DIR="$REPO_ROOT/.claude/.session-state/prove-yourself"
# Cap on rejection records embedded (alpha-sorted for determinism, matching
# phase1-launcher.sh's rejection-list injection). Each field truncated below.
REJECTION_CAP="${PHASE1_RESUME_REJECTION_CAP:-20}"
# Phase 2 CR-CLI (same class as phase1-agent-id.sh's PHASE1_RESUME_CAP guard):
# validate the cap is an integer. A non-integer override makes the `[ "$count"
# -ge "$REJECTION_CAP" ]` test in _rejection_block error with "integer
# expression expected" inside the `&&`/`if`, where set -e does NOT abort — so
# `break` never fires, the cap is silently skipped, every rejection is embedded,
# and each iteration emits stderr noise. Fall back to 20 on garbage.
if ! [[ $REJECTION_CAP =~ ^[0-9]+$ ]]; then
	echo "phase1-resume-message: WARN: PHASE1_RESUME_REJECTION_CAP='$REJECTION_CAP' is not an integer — falling back to 20" >&2
	REJECTION_CAP=20
fi

_valid_agent() { [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; }
_valid_sha() { [[ $1 =~ ^[0-9a-f]{6,40}$ ]]; }

_usage() {
	echo "Usage: phase1-resume-message.sh build <agent> <round> <base_ref> <head_sha>" >&2
}

cmd_build() {
	local agent=${1:-} round=${2:-} base=${3:-} head=${4:-}
	_valid_agent "$agent" || {
		echo "phase1-resume-message: ERROR invalid agent '$agent'" >&2
		exit 2
	}
	[[ $round =~ ^[1-9][0-9]*$ ]] || {
		echo "phase1-resume-message: ERROR round must be a positive integer, got '$round'" >&2
		exit 2
	}
	[[ $base =~ ^[A-Za-z0-9_./-]{1,128}$ ]] || {
		echo "phase1-resume-message: ERROR invalid base ref '$base'" >&2
		exit 2
	}
	_valid_sha "$head" || {
		echo "phase1-resume-message: ERROR invalid head sha '$head'" >&2
		exit 2
	}

	# --- 1. Header + delta scope ------------------------------------------
	printf 'Phase 1 — Round %s DELTA REVIEW (you are being resumed; your prior review context is retained).\n\n' "$round"
	printf 'Scope: review ONLY what changed since your last pass. Run `git diff %s..%s`. Summary:\n' "$base" "$head"
	# --stat is advisory; the teammate runs the full diff itself. `|| true`
	# so a diff failure (detached base, etc.) never aborts the builder under
	# set -e — an empty stat just means "run the diff yourself".
	git diff --stat "${base}..${head}" 2>/dev/null | sed 's/^/  /' | head -30 || true
	printf '\n'

	# --- 2. Dismissed findings + dogfood evidence -------------------------
	local block
	block=$(_rejection_block)
	if [ -n "$block" ]; then
		cat <<'EOF'
Findings already DISMISSED this PR cycle, with the dogfood evidence used to reject them.
Some are your own prior findings. Do NOT silently re-raise any of these. If you still
believe one is real, REFUTE it (below) with NEW evidence — a concrete repro the rejection's
dogfood missed. Otherwise leave it dismissed.

EOF
		printf '%s\n\n' "$block"
	else
		printf 'No findings dismissed yet this PR cycle.\n\n'
	fi

	# --- 3. Two-way response contract -------------------------------------
	cat <<'EOF'
Respond with a SINGLE JSON object and nothing else:
{
  "new_findings": [ {"file":"","line":0,"category":"","severity":"","description":"","confidence":0} ],
  "refutations": [ {"finding_text":"","counter_evidence":"","why_still_valid":""} ],
  "accepted_rejections": [ "finding_text of a rejection you now accept" ]
}
- new_findings: real issues in the DELTA only — do NOT re-review unchanged code.
- refutations: dismissed findings you still believe. counter_evidence MUST be a concrete
  repro (command + expected failing output) that demonstrates the bug the rejection's
  dogfood missed. Hand-waving without a repro will be re-dismissed.
- accepted_rejections: dismissed findings whose dogfood evidence you now accept — list their
  finding_text so they are retired from future rounds.
- All three arrays may be empty. Empty new_findings AND empty refutations = a clean round.
EOF
}

# Emit the formatted rejection block (≤ REJECTION_CAP records). Mirrors
# phase1-launcher.sh's resilient scan: per-file jq failures that are corrupt
# input (rc 4/5) skip that file; any other non-zero rc fails loud (rc 3) so a
# real tooling regression can't silently drop the refutation context.
_rejection_block() {
	[ -d "$REJECTION_DIR" ] || return 0
	local find_err find_rc=0 files
	find_err=$(mktemp 2>/dev/null) || find_err=/dev/null
	# Deterministic alpha order (POSIX find does not guarantee order — APFS
	# vs ext4 differ); the cap then drops alphabetically-late records.
	files=$(find "$REJECTION_DIR" -name '*.json' -type f 2>"$find_err" | sort) || find_rc=$?
	if [ "$find_rc" -ne 0 ]; then
		echo "phase1-resume-message: ERROR find on $REJECTION_DIR failed (rc=$find_rc): $(head -c 200 "$find_err" 2>/dev/null)" >&2
		[ "$find_err" != /dev/null ] && rm -f "$find_err"
		exit 3
	fi
	[ "$find_err" != /dev/null ] && rm -f "$find_err"
	[ -n "$files" ] || return 0

	# v0.30 #220: scope rejections to the CURRENT PR cycle (branch). Records are
	# stamped with .branch at record time (prove-yourself-audit record-rejection);
	# filtering to this branch keeps a resumed teammate from seeing stale cross-PR
	# rejections from the global prove-yourself history. `symbolic-ref --short`
	# returns EMPTY on detached HEAD / not-a-repo (never the literal "HEAD"), so
	# the `$br == ""` arm below cleanly means "undeterminable → include all".
	# Identical resolution to the writer + launcher (git -C "$REPO_ROOT" → no drift).
	local cycle_branch
	cycle_branch=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")

	local jq_err count=0
	jq_err=$(mktemp 2>/dev/null) || jq_err=/dev/null
	local f jq_rc rec
	while IFS= read -r f; do
		[ -f "$f" ] || continue
		[ "$count" -ge "$REJECTION_CAP" ] && break
		jq_rc=0
		# One compact multi-line entry per rejection. Truncate each field so a
		# verbose dogfood_output can't balloon the message. `if`-chain (not
		# case) for the rc check is fine here — this jq is not inside a
		# pipeline-in-$( ), so the bash 3.2 case-parser bug does not apply,
		# but we keep rc discrimination identical to the launcher anyway.
		rec=$(jq -r --arg br "$cycle_branch" '
			select(.kind == "rejection" and (.finding_text // "") != ""
			       and ($br == "" or (.branch // "") == $br))
			| "  [\(.source // "?")\(if .confidence then "/c\(.confidence)" elif .severity then "/\(.severity)" else "" end)] \(.finding_text[0:200])"
			+ (if (.decision_data.reason // "") != "" then "\n     reason: \(.decision_data.reason[0:200])" else "" end)
			+ (if (.decision_data.dogfood_cmd // "") != "" then "\n     dogfood: \(.decision_data.dogfood_cmd[0:160]) -> \(.decision_data.dogfood_output[0:120] // "")(rc=\(.decision_data.dogfood_rc // "?"))" else "" end)
		' "$f" 2>>"$jq_err") || jq_rc=$?
		if [ "$jq_rc" -ne 0 ] && [ "$jq_rc" -ne 4 ] && [ "$jq_rc" -ne 5 ]; then
			echo "phase1-resume-message: ERROR jq failed for '$f' rc=$jq_rc (non-corrupt — fail loud)" >&2
			[ "$jq_err" != /dev/null ] && rm -f "$jq_err"
			exit 3
		fi
		if [ -n "$rec" ]; then
			printf '%s\n' "$rec"
			count=$((count + 1))
		fi
	done <<<"$files"
	if [ "$jq_err" != /dev/null ] && [ -s "$jq_err" ]; then
		echo "phase1-resume-message: WARN jq stderr while scanning rejections (corrupt record?): $(head -c 200 "$jq_err")" >&2
	fi
	[ "$jq_err" != /dev/null ] && rm -f "$jq_err"
	# v0.30 #220 (silent-failure-hunter): masked-zero telemetry. If rejection
	# records exist but the branch filter emitted none, say so — distinguishes
	# "no rejections this cycle" (healthy) from "all rejections are out-of-cycle"
	# (filtered) so an empty block isn't mistaken for a clean history.
	if [ "$count" -eq 0 ] && [ -n "$files" ]; then
		echo "phase1-resume-message: note — 0 rejections for branch '${cycle_branch:-<none>}' this cycle (records exist for other branches/cycles, scoped out)" >&2
	fi
}

sub=${1:-}
shift || true
case "$sub" in
build) cmd_build "$@" ;;
-h | --help | "")
	_usage
	exit 2
	;;
*)
	echo "phase1-resume-message: ERROR unknown subcommand '$sub'" >&2
	_usage
	exit 2
	;;
esac
