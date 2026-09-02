#!/bin/bash
set -euo pipefail
# v4.28-W2 (#645): Prove Yourself audit skill.
# Mechanical enforcement of memory:feedback_dont_dismiss_cr_as_hallucination.md
# — refuses to record rejections without dogfood evidence, blocks commit on
# malformed rejection records.
#
# Usage: see print_help() (run `run.sh --help`) — kept SSOT to avoid drift.
#
# State at .claude/.session-state/prove-yourself/<finding-id>.json
#
# WHY mechanical: PR #639 r1-r5 NUL stripping + r17-r23 gpt-5-codex were
# both rejected via memory-citation / internal-variable inspection. The
# pattern: optional discipline. Make rejection-with-evidence not-optional.
#
# Bash 3.2 compatible — no associative arrays. Per-subcommand explicit
# argparse. macOS /bin/bash is 3.2; bash4-features-write-guard hook
# enforces.

export SKILL_WRAPPER=1
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE_DIR="$REPO_ROOT/.claude/.session-state/prove-yourself"
mkdir -p "$STATE_DIR"
# (#2652) Pre-fix baselines captured by record-baseline, consumed by
# record-fix. Session-state like $STATE_DIR: a baseline is scoped to the
# in-flight fix, not the durable audit trail (the consuming record stamps
# the evidence into itself).
BASELINE_DIR="$REPO_ROOT/.claude/.session-state/prove-yourself-baselines"
# v4.28-W4 (#710): tracked audit log persists across PRs (gitignored
# .session-state is per-session). One-line summary per record. Per-
# record full JSON stays in $STATE_DIR for transient detail.
AUDIT_DIR="$REPO_ROOT/.claude/audit"
AUDIT_FILE="$AUDIT_DIR/prove-yourself.jsonl"

# Phase 2 cr-cli r5 (#645): jq pre-flight. The skill writes JSON via
# `jq -n` (record-rejection / record-fix) and validates via `jq empty`
# (audit). Without a pre-flight check, missing-jq aborts with the
# unhelpful "jq: command not found" buried inside the cmd-sub.
if ! command -v jq >/dev/null 2>&1; then
	echo "prove-yourself-audit: ERROR: jq is required but not installed. Install via brew install jq (macOS) or apt install jq (Linux)." >&2
	exit 2
fi

# Anti-pattern strings refused as evidence (case-insensitive substring).
# Each represents a specific incident or class from the memory file.
#
# Phase 1 r1 code-reviewer (#645): the bare literal `${#var}` was over-
# broad — legitimate evidence citing bash docs (e.g. "Bash 3.5.3 says
# `${#var}` returns length") would falsely match. The dangerous pattern
# isn't the symbol itself; it's CONCLUDING from it (the PR #639 case).
# That's already covered by "length matched" semantically. Dropped the
# bare `${#var}` to eliminate the false-positive risk.
#
# Load from .claude/ssot-checks.yml as SINGLE SOURCE OF TRUTH when present.
# Fail-closed if SSOT file exists but cannot be loaded (CR review #656:
# silently falling back to a stale inline list when yq breaks would let
# operators believe the SSOT was authoritative when it wasn't).
_ANTIPATTERNS=()
_ssot_yml="$REPO_ROOT/.claude/ssot-checks.yml"
if [ -f "$_ssot_yml" ]; then
	if ! command -v yq >/dev/null 2>&1; then
		echo "prove-yourself-audit: ERROR: $_ssot_yml exists but yq is not installed." >&2
		echo "Install: brew install yq (macOS) or pip install yq." >&2
		exit 2
	fi
	_yq_err=$(mktemp)
	# Mike Farah's yq + Python yq both accept `.antipatterns[]?` — the `?`
	# makes index tolerant when the key is absent (returns empty, rc=0).
	# Don't use jq's `// empty` here: Mike Farah's yq parser rejects it.
	if ! _yq_out=$(yq -r '.antipatterns[]?' "$_ssot_yml" 2>"$_yq_err"); then
		echo "prove-yourself-audit: ERROR: yq failed to parse $_ssot_yml:" >&2
		cat "$_yq_err" >&2
		rm -f "$_yq_err"
		exit 2
	fi
	rm -f "$_yq_err"
	while IFS= read -r ap; do
		[ -n "$ap" ] && _ANTIPATTERNS+=("$ap")
	done <<<"$_yq_out"
fi
# Fall back to inline defaults only if SSOT file is absent (legitimate
# pre-#647 deployment) OR file present but `.antipatterns[]` empty.
if [ "${#_ANTIPATTERNS[@]}" -eq 0 ]; then
	_ANTIPATTERNS=(
		"memory says"
		"i remember"
		"i tested similar"
		"od shows"
		"length matched"
		"verified rejected"
		"i think it works"
	)
fi

# Reject anti-pattern strings in external-authority. The PR #639 case
# studies all had "external authority" that was actually a self-citation.
# Returns 0 if clean, 1 if anti-pattern hit.
#
# Phase 2 cr-cli (#645): accept the field name as $2 so the diagnostic
# correctly reports which flag (--external-authority vs --reason) hit
# the anti-pattern. Prior version always echoed --external-authority
# even when called with the --reason value.
_cited_files_json() {
	# v4.28-W3-C (#671): build a JSON array of {file, blob_sha} for the
	# space-separated file list passed in $1. Each path resolved via
	# git hash-object. Missing/non-files are silently skipped.
	# Output: JSON array (empty if list is empty or no files resolved).
	# r2 sfh #5: surface git hash-object failures rather than silently
	# dropping the file (parallels cache_blob_sha r2 fix). Missing-file
	# path stays silent (legit "file deleted between staging + record");
	# git-failure path now stderr-warns so corrupt-objdb / perms issues
	# don't silently truncate cited_files arrays.
	local list=$1
	[ -z "$list" ] && {
		echo "[]"
		return
	}
	local entries="[]"
	local hash_err
	hash_err=$(mktemp)
	# shellcheck disable=SC2086
	for f in $list; do
		[ -f "$REPO_ROOT/$f" ] || continue
		local sha rc=0
		sha=$(git -C "$REPO_ROOT" hash-object "$f" 2>"$hash_err") || rc=$?
		if [ "$rc" -ne 0 ]; then
			echo "_cited_files_json: WARN: git hash-object failed for $f (rc=$rc):" >&2
			cat "$hash_err" >&2
			continue
		fi
		[ -n "$sha" ] || continue
		entries=$(printf '%s' "$entries" |
			jq --arg f "$f" --arg s "$sha" '. + [{file: $f, blob_sha: $s}]')
	done
	rm -f "$hash_err"
	printf '%s\n' "$entries"
}

_record_cite_cache() {
	# v4.28-W3-C (#671): record a cache entry per cited file under the
	# given reviewer ID. Best-effort; failures don't abort the recording.
	# r1 comment-analyzer #3: prior comment falsely claimed an
	# audit_id-as-evidence_ref linkage but cache_record was called with
	# only 3 args. Removed the misleading claim — the canonical record
	# is the prove-yourself state JSON written by the calling
	# subcommand (cmd_record_rejection / cmd_record_fix) via jq;
	# this cache row is just a fast "did THIS reviewer mark THIS file
	# clean?" lookup keyed by current blob-sha.
	# r2 sfh #5: prior `2>/dev/null || true` triple-silenced cache_record
	# stderr (cannot resolve blob_sha, jq write failure). Operator records
	# a fix/rejection thinking the cache citation is filed, but failures
	# leave no trace. Now: capture stderr per call + surface tally on
	# failure (pattern from local-review.sh r1 fix).
	local reviewer=$1 list=$2
	local cache_lib="$REPO_ROOT/.claude/_lib/content-hash-cache.sh"
	[ -f "$cache_lib" ] || return 0
	[ -z "$list" ] && return 0
	# shellcheck source=/dev/null
	source "$cache_lib"
	local cite_diag cite_fail=0
	cite_diag=$(mktemp)
	# shellcheck disable=SC2086
	for f in $list; do
		[ -f "$REPO_ROOT/$f" ] || continue
		if ! cache_record "$reviewer" "$f" ok 2>>"$cite_diag"; then
			cite_fail=$((cite_fail + 1))
		fi
	done
	if [ "$cite_fail" -gt 0 ]; then
		echo "_record_cite_cache: WARN: $cite_fail cache_record write(s) failed (see $cite_diag)" >&2
	else
		rm -f "$cite_diag"
	fi
}

_jaccard_advise() {
	# v4.28-W3-C: emit stderr advisory when finding_text overlaps ≥ 60%
	# (Jaccard similarity on lowercased word-set) with an existing record.
	# Suggests a cluster-id; never auto-merges.
	local text="$1"
	[ -d "$STATE_DIR" ] || return 0
	# Lowercase + tokenize on non-alphanumeric.
	local words
	words=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '\n' | sort -u | grep -v '^$' || true)
	[ -z "$words" ] && return 0
	local word_count
	word_count=$(printf '%s\n' "$words" | wc -l | tr -d ' ')
	[ "$word_count" -lt 4 ] && return 0 # too short to dedupe usefully
	local best_overlap=0 best_record="" best_cluster=""
	while IFS= read -r -d '' f; do
		local existing_text existing_cluster existing_words shared union
		existing_text=$(jq -r '.finding_text // ""' "$f" 2>/dev/null || echo "")
		[ -z "$existing_text" ] && continue
		existing_cluster=$(jq -r '.cluster_id // ""' "$f" 2>/dev/null || echo "")
		[ -z "$existing_cluster" ] && continue
		existing_words=$(printf '%s' "$existing_text" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '\n' | sort -u | grep -v '^$' || true)
		[ -z "$existing_words" ] && continue
		shared=$(comm -12 <(printf '%s\n' "$words") <(printf '%s\n' "$existing_words") | wc -l | tr -d ' ')
		union=$(printf '%s\n%s\n' "$words" "$existing_words" | sort -u | wc -l | tr -d ' ')
		[ "$union" -eq 0 ] && continue
		local overlap_pct=$((shared * 100 / union))
		if [ "$overlap_pct" -gt "$best_overlap" ]; then
			best_overlap=$overlap_pct
			best_record=$(basename "$f")
			best_cluster=$existing_cluster
		fi
	done < <(find "$STATE_DIR" -name '*.json' -type f -print0 2>/dev/null)
	if [ "$best_overlap" -ge 60 ]; then
		echo "advisory: finding_text overlaps ${best_overlap}% with $best_record (cluster=$best_cluster)" >&2
		echo "  If same root cause, pass: --cluster-id $best_cluster" >&2
		echo "  If different root cause, pass a fresh: --cluster-id <new-slug>" >&2
	fi
}

# (#2629 p2r1) Word-bounded containment. A bare `*"$n"*` made every
# anti-pattern match inside longer words: "od shows" fired on "dogfood shows",
# and "i remember" would fire on "multi remembered". That is not a cosmetic
# false positive — this guard's remedy line is "APPLY the fix instead of
# rejecting", so a spurious hit pushes the reviewer toward making a change
# they had correctly judged wrong. Found exactly that way, blocking a
# rejection whose evidence was a docs quote.
#
# A match counts only when the characters flanking it are not word
# characters. Start/end of string count as boundaries (an unset var is not
# alnum), so a phrase alone in the field still hits.
_word_bounded_contains() { # $1 haystack, $2 needle — both already lowercased
	local rest=$1 n=$2 pre post before after
	[ -n "$n" ] || return 1
	while [[ $rest == *"$n"* ]]; do
		pre=${rest%%"$n"*}
		post=${rest#*"$n"}
		before=""
		[ -n "$pre" ] && before=${pre: -1}
		after=""
		[ -n "$post" ] && after=${post:0:1}
		if [[ ! $before =~ [[:alnum:]_] ]] && [[ ! $after =~ [[:alnum:]_] ]]; then
			return 0
		fi
		rest=$post
	done
	return 1
}

_check_antipatterns() {
	local text=$1 field=${2:---external-authority} lower
	# Lowercase for substring comparison.
	lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
	local ap ap_lower
	for ap in "${_ANTIPATTERNS[@]}"; do
		ap_lower=$(printf '%s' "$ap" | tr '[:upper:]' '[:lower:]')
		if _word_bounded_contains "$lower" "$ap_lower"; then
			echo "BLOCK: $field contains anti-pattern '$ap'." >&2
			echo "" >&2
			echo "Per memory:feedback_dont_dismiss_cr_as_hallucination.md, evidence" >&2
			echo "must be something an external observer can re-verify (registry API," >&2
			echo "docs, spec, --help output) — NOT self-reference (memory citation," >&2
			echo "internal-variable inspection, prior-round verdict)." >&2
			echo "" >&2
			echo "Default behavior: APPLY the fix and re-test instead of rejecting." >&2
			return 1
		fi
	done
	return 0
}

# Compute deterministic finding-id when caller didn't supply one.
_hash_finding() {
	local text=$1
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$text" | sha256sum | cut -c1-16
	elif command -v shasum >/dev/null 2>&1; then
		printf '%s' "$text" | shasum -a 256 | cut -c1-16
	else
		# Fallback: caller MUST supply finding-id when no hashing tool.
		echo ""
	fi
}

# Compose a collision-resistant state filename for a finding-id.
# CR review #656: bare slug truncated to 64 chars meant distinct ids that
# share a 64-char normalized prefix (or differ only in chars outside
# [alnum_-]) collapsed to the same path, silently overwriting prior
# evidence and letting `audit` read the wrong record. Combine slug (for
# human-readable filenames) with deterministic hash of the RAW finding-id.
_state_file_for_finding() {
	local fid=$1 slug hash
	slug=$(printf '%s' "$fid" | tr -c '[:alnum:]_-' '_' | head -c 48)
	hash=$(_hash_finding "$fid")
	[ -n "$hash" ] || {
		echo "error: cannot derive state filename hash for finding-id (no sha256sum/shasum)" >&2
		exit 2
	}
	printf '%s/%s-%s.json\n' "$STATE_DIR" "$slug" "$hash"
}

# ----- help -----

# CR review #656: previous --help dumped every `^#` line via grep+sed,
# leaking shebang + internal rationale comments and going stale (the
# header usage block still omitted `reset`). Replaced with a real
# usage function; subcommand parsers route --help to it explicitly so
# `record-rejection --help` no longer falls into the unknown-arg branch.
print_help() {
	cat <<'EOF'
Usage:
  run.sh record-rejection --finding-id X --finding-text "..." \
    --dogfood-cmd "..." --dogfood-output "..." --dogfood-rc N \
    --external-authority "..." --reason "..." \
    --source {phase0.5|phase1|cr}   # NOT issue — see below \
    [--confidence 1-10]      # required for source phase0.5/phase1
    [--severity ...]         # required for source=cr (CR vocab:
                             # critical|high|medium|minor|info).
                             # phase0.5/phase1 use --confidence, not severity.
                             # Other future sources (copilot/gemini/codex) will
                             # define their own; the validator is source-keyed.
    [--follow-up-issue N]    # required when (a) source=phase0.5|phase1 + confidence ≥ 7
                             # OR (b) source=cr + severity in {critical,high,medium}.
                             # Verified via gh issue view.
    [--cited-files "path1 path2 path3"] [--covers-count N] [--cluster-id ID]
    [--covered-sha SHA]      # ancestor of HEAD; re-file this evidence against
                             # an earlier commit (see record-fix below)
  run.sh record-fix --finding-id X --finding-text "..." \
    --fix-summary "..." --retest-cmd "..." --retest-rc N \
                             # #2562: --retest-cmd is RE-EXECUTED at record
                             # time; its actual rc must equal N or the record
                             # is refused (EVIDENCE MISMATCH). The command
                             # must be idempotent — it runs again right here.
                             # Timeout: PROVE_RETEST_TIMEOUT (default 120s).
                             # Cited cycle-critical files (hooks/, _lib/,
                             # pre-commit-hooks/, scripts/cr/local-review.sh)
                             # must appear IN the command text (real entry
                             # point, not only a bats fixture).
    --source {phase0.5|phase1|cr|issue} \
    [--confidence 1-10]      # required for source phase0.5/phase1;
                             # optional for source=cr (validated 1-10
                             # if provided)
    [--severity ...]         # required for source=cr (vocab:
                             # critical|high|medium|minor|info);
                             # not used by phase0.5/phase1
    [--cited-files "path1 path2"] [--covers-count N] [--cluster-id ID]
    [--symptom-cmd "..." --symptom-baseline-rc N --symptom-fixed-rc M]
                             # #2643 SYMPTOM DIFFERENTIAL. All three go
                             # together; N must differ from M. The command is
                             # RE-EXECUTED twice: once here, and once in a
                             # detached worktree at the baseline ref with this
                             # tree's .bats files copied in, so a new test can
                             # detect the old bug. Both observed rcs must match
                             # what you claim or the record is refused.
                             # REQUIRED when --source=issue, and when any cited
                             # file is cycle-critical. Optional elsewhere — but
                             # still verified if you supply it.
                             # Timeout: PROVE_BASELINE_TIMEOUT, else
                             # PROVE_RETEST_TIMEOUT, else 120s.
                             # It proves the rc DEPENDS on the diff. It cannot
                             # prove the command is relevant to the fix — no
                             # mechanism can. Choose a command that would fail
                             # for the reported reason.
    [--baseline-ref REF]     # which tree is "before". Default HEAD, because
                             # the cycle order is fix -> record-fix -> commit.
                             # Name the commit BEFORE the fix if it is already
                             # committed. A ref resolving to HEAD gets the same
                             # tautology check as the default.
    [--covered-sha SHA]      # which commit this evidence covers. Default is
                             # HEAD. Must be an ANCESTOR of HEAD: evidence can
                             # be re-filed onto a commit already on this branch
                             # (correcting a wrong --source, which is otherwise
                             # permanent because the sha is stamped at write
                             # time), never attached to unrelated work.
    [--allow-absence-baseline]
                             # accept a baseline rc of 127. A fix that ADDS a
                             # file makes the baseline exit "command not found",
                             # which looks like proof and is not; pass this only
                             # when 127 genuinely IS the reported symptom.
  run.sh record-baseline {--finding-id X | --finding-text "..."} \
    --retest-cmd "..." [--note "..."] [--allow-absence-baseline]
                             # (#2652) capture PRE-FIX evidence BEFORE applying
                             # the fix: the command is RE-EXECUTED now and must
                             # FAIL (nonzero rc) — a passing baseline shows no
                             # symptom and is refused; rc 126/127 are refused
                             # too (absence is not a symptom) unless
                             # --allow-absence-baseline claims it is. The key
                             # is --finding-id, or derived from --finding-text
                             # exactly like record-fix derives it. Evidence is
                             # stored keyed by that id AND corroborated by a
                             # tracked audit-ledger row; a later record-fix for
                             # the SAME id then requires the SAME command, a
                             # claimed --retest-rc 0, an ancestor-of-HEAD
                             # capture sha, and stamps both halves (+ the note)
                             # into the record, CONSUMING the baseline file —
                             # before/after proven from two live runs, no
                             # worktree needed. For a fix that is already
                             # committed (no pre-fix tree left to run in), use
                             # the #2643 symptom flags instead.
                             # Timeout: PROVE_RETEST_TIMEOUT (default 120s).
  run.sh audit
  run.sh check-commit
  run.sh reset
  run.sh cluster-list                # group records by cluster_id
  run.sh search [--text X] [--source Y] [--kind fix|rejection] [--limit N]
                                     # query the tracked audit log
                                     # (.claude/audit/prove-yourself.jsonl)
  run.sh --help
EOF
}

# ----- subcommands -----

cmd_record_rejection() {
	# v4.28-W4 #851 r1: ASYMMETRY DOCS — record-rejection vs record-fix
	# differ in required-flag set BY DESIGN. Documented inline to prevent
	# future "let's make them symmetric" refactors that would break the
	# defer-vs-close contract:
	#
	# RECORD-REJECTION REQUIRES (when confidence >= 7):
	#   --follow-up-issue <N>
	#
	# Why: rejection = DEFER. A defer-without-tracking is a leak — the
	# finding gets dropped from this PR's scope but never re-evaluated.
	# The follow-up issue is the durable ticket that lets the operator
	# (or a future audit) trace what was punted and why.
	#
	# Severity vs confidence: CR findings use {critical,high,medium,minor,
	# info}; phase0.5/phase1 findings use confidence 1-10. The validator
	# is source-keyed so a CR-critical CANNOT bulk-defer silently —
	# the --follow-up-issue requirement is enforced (verified via gh
	# issue view to exist), but a phase0.5 confidence=4 can bypass
	# the tracking requirement entirely (cf<7 = no follow-up needed).
	#
	# RECORD-FIX (compared, near cmd_record_fix below) does NOT require
	# --follow-up-issue. See that function's docstring for the rationale.
	#
	# Per-subcommand explicit argparse (bash 3.2 compatible — no -A arrays).
	local finding_id="" finding_text="" dogfood_cmd="" dogfood_output=""
	local dogfood_rc="" external_authority="" reason="" cited_files=""
	local covers_count="1" confidence="" follow_up_issue="" cluster_id=""
	local covered_sha_arg=""
	local src="" severity=""
	while [ $# -gt 0 ]; do
		case "$1" in
		-h | --help)
			print_help
			exit 0
			;;
		--finding-id)
			[ $# -lt 2 ] && {
				echo "error: missing value for --finding-id" >&2
				exit 2
			}
			finding_id=${2:-}
			shift 2
			;;
		--finding-text)
			[ $# -lt 2 ] && {
				echo "error: missing value for --finding-text" >&2
				exit 2
			}
			finding_text=${2:-}
			shift 2
			;;
		--dogfood-cmd)
			[ $# -lt 2 ] && {
				echo "error: missing value for --dogfood-cmd" >&2
				exit 2
			}
			dogfood_cmd=${2:-}
			shift 2
			;;
		--dogfood-output)
			[ $# -lt 2 ] && {
				echo "error: missing value for --dogfood-output" >&2
				exit 2
			}
			dogfood_output=${2:-}
			shift 2
			;;
		--dogfood-rc)
			[ $# -lt 2 ] && {
				echo "error: missing value for --dogfood-rc" >&2
				exit 2
			}
			dogfood_rc=${2:-}
			shift 2
			;;
		--external-authority)
			[ $# -lt 2 ] && {
				echo "error: missing value for --external-authority" >&2
				exit 2
			}
			external_authority=${2:-}
			shift 2
			;;
		--reason)
			[ $# -lt 2 ] && {
				echo "error: missing value for --reason" >&2
				exit 2
			}
			reason=${2:-}
			shift 2
			;;
		--cited-files)
			[ $# -lt 2 ] && {
				echo "error: missing value for --cited-files" >&2
				exit 2
			}
			cited_files=${2:-}
			shift 2
			;;
		--covers-count)
			[ $# -lt 2 ] && {
				echo "error: missing value for --covers-count" >&2
				exit 2
			}
			covers_count=${2:-}
			shift 2
			;;
		--confidence)
			# v4.28-W3-C: agent's self-rated confidence (1-10). REQUIRED
			# for --source=phase0.5|phase1 (cr uses --severity instead).
			# Gate enforces: confidence ≥ 7 (HIGH/MED) requires
			# --follow-up-issue with a verified GitHub issue.
			[ $# -lt 2 ] && {
				echo "error: missing value for --confidence" >&2
				exit 2
			}
			confidence=${2:-}
			shift 2
			;;
		--follow-up-issue)
			# v4.28-W3-C: GitHub issue number tracking this rejection
			# as Wave 2+ work. Verified via `gh issue view` to exist.
			# REQUIRED when confidence ≥ 7 (HIGH/MED can't bulk-defer).
			[ $# -lt 2 ] && {
				echo "error: missing value for --follow-up-issue" >&2
				exit 2
			}
			follow_up_issue=${2:-}
			shift 2
			;;
		--cluster-id)
			[ $# -lt 2 ] && {
				echo "error: missing value for --cluster-id" >&2
				exit 2
			}
			cluster_id=${2:-}
			shift 2
			;;
		--covered-sha)
			# (#2643) Same flag, same reason, same validation as record-fix:
			# a rejection filed under the wrong source is counted by nothing
			# and, without this, could never be corrected either — the same
			# dead end the fix side hit.
			[ $# -lt 2 ] && {
				echo "error: missing value for --covered-sha" >&2
				exit 2
			}
			covered_sha_arg=${2:-}
			shift 2
			;;
		--source)
			# v4.28-W3-C: source of the finding — phase0.5 (Copilot multi-CLI),
			# phase1 (Claude subagents), cr (CR-CLI/CR-in-CI). Drives the
			# threshold model: phase0.5/phase1 use --confidence (1-10),
			# cr uses --severity (critical|high|medium|minor|info).
			[ $# -lt 2 ] && {
				echo "error: missing value for --source" >&2
				exit 2
			}
			src=${2:-}
			shift 2
			;;
		--severity)
			# v4.28-W3-C: CR-source severity (critical|high|medium|minor|info).
			# Required when --source=cr; ignored otherwise.
			[ $# -lt 2 ] && {
				echo "error: missing value for --severity" >&2
				exit 2
			}
			severity=${2:-}
			shift 2
			;;
		*)
			echo "error: unknown arg: $1" >&2
			exit 2
			;;
		esac
	done

	if ! [[ $covers_count =~ ^[1-9][0-9]*$ ]]; then
		echo "error: --covers-count must be a positive integer (got: $covers_count)" >&2
		exit 2
	fi

	# v4.28-W3-C: source-aware threshold enforcement.
	# Required: --source ∈ {phase0.5, phase1, cr}.
	# - phase0.5 / phase1: --confidence required (1-10). HIGH/MED (≥7)
	#   requires --follow-up-issue. Bulk-defer ok at confidence ≤6.
	# - cr: --severity required. critical/high → never bulk-defer (must
	#   fix-this-PR or follow-up-issue). medium → follow-up-issue
	#   required for defer. minor/info → bulk-defer ok.
	[ -z "$src" ] && {
		echo "error: --source is REQUIRED (phase0.5|phase1|cr)" >&2
		exit 2
	}
	# (#2643) `issue` joins the vocabulary. Until now the only sources were
	# review stages, so ISSUE-DRIVEN BUG WORK never reached record-fix at
	# all — the one case where "did the reported symptom actually go away"
	# is the entire question had no way to be recorded. It is also the
	# source for which differential symptom evidence is REQUIRED.
	#
	# Confidence/severity stay optional for it: an issue is not a review
	# finding with a confidence score, it is a report someone filed.
	case "$src" in
	phase0.5 | phase1 | cr | issue) ;;
	*)
		echo "error: --source must be phase0.5|phase1|cr (got: $src) — 'issue' is accepted by record-fix only" >&2
		exit 2
		;;
	esac
	# r10 CR PR #755: validate --confidence format whenever provided
	# (cr-source allows optional --confidence too — without this guard,
	# non-numeric input on the rejection path reaches the jq template's
	# `.confidence | tonumber` and dies as a parse error instead of our
	# normal exit-2 contract). Mirrors the record-fix hoist from r1.
	if [ -n "$confidence" ] && ! [[ $confidence =~ ^([1-9]|10)$ ]]; then
		echo "error: --confidence must be 1-10 integer (got: $confidence)" >&2
		exit 2
	fi
	case "$src" in
	phase0.5 | phase1)
		[ -z "$confidence" ] && {
			echo "error: --source=$src requires --confidence (1-10)" >&2
			exit 2
		}
		if [ "$confidence" -ge 7 ] && [ -z "$follow_up_issue" ]; then
			echo "error: --confidence $confidence is HIGH/MED — REQUIRES --follow-up-issue <N>" >&2
			echo "  $src HIGH/MED findings cannot bulk-defer silently. Fix this PR or file tracking issue." >&2
			exit 2
		fi
		;;
	cr)
		[ -z "$severity" ] && {
			echo "error: --source=cr requires --severity (critical|high|medium|minor|info)" >&2
			exit 2
		}
		case "$severity" in
		critical | high | medium | minor | info) ;;
		*)
			echo "error: --severity must be critical|high|medium|minor|info (got: $severity)" >&2
			exit 2
			;;
		esac
		# CR critical/high/medium need follow-up-issue OR fix-this-PR.
		# CR critical/high cannot bulk-defer at all. medium needs follow-up.
		case "$severity" in
		critical | high)
			if [ -z "$follow_up_issue" ]; then
				echo "error: --source=cr --severity=$severity cannot bulk-defer — REQUIRES --follow-up-issue or fix-this-PR" >&2
				exit 2
			fi
			;;
		medium)
			if [ -z "$follow_up_issue" ]; then
				echo "error: --source=cr --severity=medium requires --follow-up-issue <N> for defer (or fix-this-PR)" >&2
				exit 2
			fi
			;;
		esac
		;;
	issue)
		# (#2643) record-fix accepts source=issue; record-REJECTION does
		# not. A rejection declines a review FINDING with evidence; an
		# issue is a report, and "I decline this bug report" is a decision
		# for the issue tracker, not for this ledger. Say so rather than
		# accepting a record whose semantics nobody defined.
		echo "error: --source=issue is for record-fix, not record-rejection — an issue is a report, not a review finding to decline. Close or comment on the issue instead (#2643)" >&2
		exit 2
		;;
	*)
		# UNREACHABLE by construction: the vocabulary case above already
		# rejected anything outside {phase0.5, phase1, cr, issue}, and this
		# case has an arm for each. Kept as a fail-closed default so a
		# future vocabulary addition cannot fall through silently — if this
		# ever prints, an arm is missing above.
		echo "error: internal: --source '$src' passed the vocabulary check but has no handler — refusing rather than recording an unvalidated source (#2643)" >&2
		exit 2
		;;
	esac
	if [ -n "$follow_up_issue" ]; then
		if ! [[ $follow_up_issue =~ ^[0-9]+$ ]]; then
			echo "error: --follow-up-issue must be a positive integer (got: $follow_up_issue)" >&2
			exit 2
		fi
		# r5 SFH #3+#4: fail-CLOSED on gh-missing or transient gh failure.
		# Earlier code printed `warn:` and accepted, defeating the
		# verification (operator on a CI box without gh, or stripped env,
		# could pass any integer). Distinguish: gh-missing exits 2; gh-
		# present + 404 → "does not exist"; gh-present + transient (auth/
		# network) → exit 2 with the gh stderr surfaced. Escape hatch:
		# PROVE_YOURSELF_VERIFY_OFFLINE=1 (audit-logged, operator-explicit).
		if [ "${PROVE_YOURSELF_VERIFY_OFFLINE:-0}" = "1" ]; then
			echo "warn: PROVE_YOURSELF_VERIFY_OFFLINE=1 — skipping --follow-up-issue #$follow_up_issue verification" >&2
		elif ! command -v gh >/dev/null 2>&1; then
			echo "error: --follow-up-issue verification requires gh CLI (not installed)" >&2
			echo "  Install: brew install gh && gh auth login" >&2
			echo "  Offline override (audit-logged): PROVE_YOURSELF_VERIFY_OFFLINE=1 ..." >&2
			exit 2
		else
			gh_stderr=$(mktemp -t gh-issue-view.XXXXXX)
			if gh issue view "$follow_up_issue" --json number >/dev/null 2>"$gh_stderr"; then
				rm -f "$gh_stderr"
			else
				gh_msg=$(cat "$gh_stderr" 2>/dev/null || true)
				rm -f "$gh_stderr"
				# v4.28-W4 #851 r1: distinguish 4 failure modes by stderr
				# pattern. All exit 2 (consistent contract — callers only
				# need pass/fail; the discriminator helps the operator).
				# Order matters: 404 first (most specific), then rate-limit,
				# auth, then generic transient/network catch-all.
				# v4.28-W4 #866 CR-CLI r1: removed `Could not resolve` from
				# the 404 branch — DNS / resolver / network errors share
				# that wording and would false-match as "issue missing".
				# Generic network errors now fall through to the catch-all.
				if echo "$gh_msg" | grep -qiE 'not found|HTTP 404|GraphQL: Could not resolve to an Issue'; then
					echo "error: --follow-up-issue #$follow_up_issue does not exist on the current repo's GitHub" >&2
				elif echo "$gh_msg" | grep -qiE 'rate.limit|API rate|secondary rate'; then
					echo "error: --follow-up-issue #$follow_up_issue verification hit gh API RATE LIMIT — retry after reset, or PROVE_YOURSELF_VERIFY_OFFLINE=1 (audit-logged)" >&2
					echo "  $gh_msg" >&2
				elif echo "$gh_msg" | grep -qiE 'authentication|not logged in|gh auth login|401|unauthorized|HTTP 403|Forbidden|Resource not accessible|Bad credentials|requires authentication'; then
					echo "error: --follow-up-issue #$follow_up_issue verification failed — gh AUTHENTICATION/AUTHORIZATION required. Run: gh auth login (or check repo scope)" >&2
					echo "  $gh_msg" >&2
				else
					echo "error: --follow-up-issue #$follow_up_issue verification FAILED (gh transient/network):" >&2
					echo "  $gh_msg" >&2
					echo "  Fix gh and re-run, or PROVE_YOURSELF_VERIFY_OFFLINE=1 (audit-logged)" >&2
				fi
				exit 2
			fi
		fi
	fi

	# Validate required fields.
	[ -z "$finding_text" ] && {
		echo "error: --finding-text is required" >&2
		exit 2
	}
	[ -z "$dogfood_cmd" ] && {
		echo "error: --dogfood-cmd is required" >&2
		exit 2
	}
	[ -z "$dogfood_output" ] && {
		echo "error: --dogfood-output is required" >&2
		exit 2
	}
	[ -z "$dogfood_rc" ] && {
		echo "error: --dogfood-rc is required" >&2
		exit 2
	}
	[ -z "$external_authority" ] && {
		echo "error: --external-authority is required" >&2
		exit 2
	}
	[ -z "$reason" ] && {
		echo "error: --reason is required" >&2
		exit 2
	}

	# finding-id: caller may pass explicitly, or derive from text.
	if [ -z "$finding_id" ]; then
		finding_id=$(_hash_finding "$finding_text")
		[ -z "$finding_id" ] && {
			echo "error: cannot derive finding-id (no sha256sum/shasum) — pass --finding-id explicitly" >&2
			exit 2
		}
	fi

	# Anti-pattern guard on both external-authority and reason.
	_check_antipatterns "$external_authority" "--external-authority" || exit 2
	_check_antipatterns "$reason" "--reason" || exit 2

	# Validate dogfood-rc is integer.
	if ! [[ $dogfood_rc =~ ^[0-9]+$ ]]; then
		echo "error: --dogfood-rc must be a non-negative integer (got: $dogfood_rc)" >&2
		exit 2
	fi

	# (#2643) BEFORE the state file is written. The first version
	# validated after the jq write, so an invalid sha left an orphan
	# rejection record on disk and only then errored. Resolve and VALIDATE --covered-sha: a real commit that is an
	# ANCESTOR of HEAD. Evidence may be re-filed onto a commit already on
	# this branch (correcting a label), never attached to unrelated work.
	local _rej_cov_sha=""
	if [ -n "$covered_sha_arg" ]; then
		_rej_cov_sha=$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${covered_sha_arg}^{commit}" 2>/dev/null) || _rej_cov_sha=""
		if [ -z "$_rej_cov_sha" ]; then
			echo "error: --covered-sha '$covered_sha_arg' does not resolve to a commit (#2643)" >&2
			exit 2
		fi
		if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$_rej_cov_sha" HEAD 2>/dev/null; then
			echo "error: --covered-sha '$covered_sha_arg' is not an ancestor of HEAD — evidence can be re-filed against a commit already on this branch, not attached to unrelated work (#2643)" >&2
			exit 2
		fi
		echo "record-rejection: covering ${_rej_cov_sha:0:7} (named via --covered-sha) rather than HEAD" >&2
	fi

	local ts state_file
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	state_file=$(_state_file_for_finding "$finding_id")

	# v4.28-W3-C (#671): build cited_files JSON before jq invocation so
	# the audit record carries blob-shas for cache_evidence_stale checks.
	local cited_json
	cited_json=$(_cited_files_json "$cited_files")

	# v0.30 #220: stamp the PR-cycle branch so the Phase-1 rejection blocks
	# (phase1-resume-message.sh + phase1-launcher.sh) scope to the current cycle.
	# `symbolic-ref --short` (NOT `rev-parse --abbrev-ref`) returns EMPTY on
	# detached HEAD / not-a-repo — never the literal "HEAD" — so empty → null
	# below and the readers' `$br == ""` arm cleanly means "undeterminable →
	# include all" with no "HEAD"-sentinel collision. `git -C "$REPO_ROOT"` keeps
	# the value identical to the readers regardless of cwd.
	local rej_branch
	rej_branch=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")

	# Write JSON via jq for safe escaping.
	# v4.28-W3-C: Jaccard text-overlap advisory. If finding_text shares
	# ≥ 60% word-set with an existing record AND the existing record has
	# a cluster_id but THIS record doesn't, suggest reusing that cluster.
	# Never auto-merges; just emits an advisory line to stderr.
	if [ -z "$cluster_id" ]; then
		_jaccard_advise "$finding_text"
	fi

	jq -n \
		--arg fid "$finding_id" \
		--arg ts "$ts" \
		--arg ftext "$finding_text" \
		--arg cmd "$dogfood_cmd" \
		--arg out "$dogfood_output" \
		--arg ext "$external_authority" \
		--arg reason "$reason" \
		--argjson rc "$dogfood_rc" \
		--argjson cited "$cited_json" \
		--argjson covers "$covers_count" \
		--arg conf "${confidence:-}" \
		--arg sev "${severity:-}" \
		--arg src "$src" \
		--arg followup "$follow_up_issue" \
		--arg cluster "$cluster_id" \
		--arg branch "$rej_branch" \
		'{finding_id: $fid, kind: "rejection", finding_text: $ftext, ts: $ts,
		  branch: (if $branch == "" then null else $branch end),
		  covers_count: $covers, source: $src,
		  confidence: (if $conf == "" then null else ($conf | tonumber) end),
		  severity: (if $sev == "" then null else $sev end),
		  follow_up_issue: (if $followup == "" then null else ($followup | tonumber) end),
		  cluster_id: (if $cluster == "" then null else $cluster end),
		  cited_files: $cited,
		  decision_data: {dogfood_cmd: $cmd, dogfood_output: $out,
		                  dogfood_rc: $rc, external_authority: $ext,
		                  reason: $reason}}' >"$state_file"

	# Record per-cited-file cache entries under reviewer "prove-yourself-rejection".
	_record_cite_cache "prove-yourself-rejection" "$cited_files"

	# v4.28-W4 (#710): append summary to tracked audit log.
	# CR-CI fix: propagate _append_tracked_audit failure. Helper returns
	# 1 on mkdir/jq error (r13 fail-closed); without rc check, caller
	# would print "✓ Recorded" after losing the persistent entry.
	if ! _append_tracked_audit "rejection" "$finding_id" "$src" "${severity:-}" "${confidence:-}" "$finding_text" "$state_file" "$cluster_id" "$covers_count" "$_rej_cov_sha"; then
		echo "ERROR: tracked audit append failed for $finding_id (state file at $state_file is intact, but audit log is missing this record)" >&2
		exit 1
	fi

	echo "✓ Recorded rejection: $finding_id"
	echo "  $state_file"
}

# ---------------------------------------------------------------------------
# (#2643) DIFFERENTIAL SYMPTOM EVIDENCE
#
# #2562 made the retest a RUN rather than a claim: it is re-executed, its rc
# must match, a deadline kill can never pass, and a cycle-critical citation
# must invoke the real entry point. That proves EXECUTION.
#
# It does not prove CONSEQUENCE. `--retest-cmd "bash hooks/x.sh"
# --retest-rc 0` is satisfied by a hook that was already green before the
# fix — the file admits the boundary itself: "the mechanical system cannot
# judge the semantic relevance of arbitrary commands."
#
# The symptom flags close that. The claim they encode is a DIFFERENCE:
#
#   --symptom-cmd "<command exhibiting the reported symptom>"
#   --symptom-baseline-rc N     what it does WITHOUT the fix
#   --symptom-fixed-rc M        what it does WITH the fix   (N != M required)
#   [--baseline-ref <sha>]      when the fix is already committed
#
# Both halves are RE-EXECUTED. The fixed half runs in the live tree through
# the existing machinery; the baseline runs in a detached worktree at HEAD.
#
# WHY HEAD IS THE BASELINE, FOR FREE. The cycle order is fix -> record-fix
# -> commit, so at record time the fix is still uncommitted and HEAD IS the
# pre-fix tree. No sabotage, no mutation of the working tree, nothing to
# restore. Worst case on a cleanup failure is a leaked temp dir and an
# orphan worktree stub — never a corrupted tree and never a lost fix.
#
# `git stash` is NOT used: it mutates the operator's working tree, and the
# whole point here is that the baseline costs nothing to obtain. (An earlier
# version of this comment claimed scripts/release.sh "documents the
# preference against it" — it does not; it says "commit or stash". The
# reason above stands on its own without the borrowed authority.)
#
# N != M is necessary, NOT sufficient, and the earlier wording here
# ("what makes this unfakeable") was simply false. A differential proves
# only that the command's exit code DEPENDS ON THE DIFF — not that it
# exercises the fix. Three shapes an adversarial review CONFIRMED against
# this code, kept here because a gate that hides its holes is worse than one
# that names them:
#   1. OBSERVE-THE-DIFF. Add a comment to a cited file, then
#      `--symptom-cmd "grep -q <that comment> <that file>"`. The rc differs
#      across the trees and the "fix" is a no-op. Mechanically
#      indistinguishable from grepping for new BEHAVIOUR.
#   2. LIVE-CWD ASYMMETRY. The fixed half runs in the working tree; the
#      baseline in a pristine checkout. Untracked junk exists in one and
#      never the other, so `test -f <any untracked file>` is a free
#      differential. Inherent to comparing a dirty tree against a commit —
#      running the fixed half somewhere clean would discard the uncommitted
#      fix, which is the thing under test.
#   3. MEASURE-THEN-REVERT. Nothing binds the record to the tree state it
#      was measured on, so the fix can be reverted afterwards.
# AND THE REQUIREMENT IS SELF-SELECTED: it fires from
# `--cited-files`, which is optional, so an agent that cites nothing (or
# picks `--source phase1` over `issue`) is never asked for a differential
# at all. That is a floor, not a fence. It raises the cost of a bare claim
# and makes the honest path the easy one; it does not stop a determined
# author from routing around it, and this comment says so rather than
# letting the next reader assume otherwise.
# Nothing mechanical
# can judge the semantic relevance of an arbitrary command, so this gate
# does not claim to: it raises the floor from "a suite passed" to "some
# observable changed, and I re-ran both sides myself to check". Claiming
# more than that is how a gate ends up reporting enforcement it does not
# perform (#2640). `--symptom-cmd true` with both rcs 0 is still refused.

# The worktree path currently in use. NOTE THE SCOPE, because the earlier
# comment here overstated it: `_prove_symptom_run_baseline` is invoked
# inside a command substitution to capture its rc, so it runs in a SUBSHELL
# and every assignment to this variable is confined there. The parent's copy
# stays empty, and there is no EXIT trap — so a SIGINT mid-baseline leaks the
# temp dir and an orphan worktree stub. That is the documented worst case
# (never a corrupted tree, never a lost fix), and `git worktree prune`
# clears the stub; the point of this note is that the cleanup is
# best-effort WITHIN the subshell, not a guarantee from the parent.
# (An earlier docblock here described a function
# `_prove_symptom_baseline_worktree <ref> <outvar>` that was never written —
# the worktree is created inline by _prove_symptom_run_baseline.)
_prove_symptom_wt=""
_prove_symptom_wt_cleanup() {
	# Remove -> rm -rf -> prune, the hardened sequence
	# scripts/backfill-tags.sh established. Each step is independently
	# best-effort: a half-removed worktree must not abort the caller, and
	# the prune is what stops an orphan .git/worktrees/ stub accumulating.
	[ -n "$_prove_symptom_wt" ] || return 0
	# Best-effort by design — a cleanup failure must never abort the caller
	# or lose the operator's fix — but NOT silent. An accumulating orphan
	# worktree is a real cost, and the first version discarded every signal
	# of one.
	git -C "$REPO_ROOT" worktree remove --force "$_prove_symptom_wt" 2>/dev/null ||
		echo "WARN: could not remove the baseline worktree at $_prove_symptom_wt — trying rm -rf" >&2
	rm -rf "$_prove_symptom_wt" 2>/dev/null ||
		echo "WARN: could not rm -rf $_prove_symptom_wt — it will need removing by hand" >&2
	git -C "$REPO_ROOT" worktree prune 2>/dev/null ||
		echo "WARN: 'git worktree prune' failed — an orphan stub may remain in .git/worktrees" >&2
	_prove_symptom_wt=""
}

# _prove_symptom_run_baseline <ref> <cmd> <timeout> [outfile]
#   Echoes the observed rc on LINE 1 and the elapsed seconds on LINE 2 —
#   the caller needs the elapsed time to tell OUR deadline kill from a
#   child's own fast inner timeout. rc 2 (of the function) on a setup
#   failure, which is NOT the same as the command failing.
_prove_symptom_run_baseline() {
	# No `cited` parameter: the single .bats list below comes from `git
	# diff --name-only`, which already includes any cited test file that
	# differs — and one that does NOT differ is identical at <ref> anyway.
	local ref="$1" cmd="$2" tmo="$3"
	local wt rc=0
	wt=$(mktemp -d -t prove-baseline.XXXXXX) || {
		echo "error: mktemp -d failed for the baseline worktree" >&2
		return 2
	}
	rm -rf "$wt"
	# git's own stderr is kept: "not a valid object name", "permission
	# denied" and "no space left" want completely different responses, and
	# the generic message could not tell them apart.
	local _wt_err _wt_detail=""
	_wt_err=$(mktemp) || _wt_err=""
	if ! git -C "$REPO_ROOT" worktree add --detach --quiet "$wt" "$ref" 2>"${_wt_err:-/dev/null}"; then
		[ -n "$_wt_err" ] && [ -s "$_wt_err" ] && _wt_detail=" — git said: $(head -c 200 "$_wt_err")"
		echo "error: could not create a detached worktree at '$ref'${_wt_detail}. The baseline half of the symptom evidence cannot be run." >&2
		[ -n "$_wt_err" ] && rm -f "$_wt_err"
		rm -rf "$wt" 2>/dev/null || true
		return 2
	fi
	[ -n "$_wt_err" ] && rm -f "$_wt_err"
	_prove_symptom_wt="$wt"

	# THE NEW TESTS COME ALONG; the production code does not.
	#
	# Without this the baseline is HEAD's tests against HEAD's code, which
	# answers a different question. What we want is: does the NEW test
	# detect the OLD bug? So changed .bats files are copied in while
	# everything else stays at <ref>.
	#
	# .claude/tests/**/*.bats are tests. Everything else is production —
	# stated here rather than guessed at each call site.
	#
	# A FAILED COPY IS FATAL. It was `cp ... || true`, which meant a
	# permissions or path error let the baseline run WITHOUT the very test
	# that is supposed to detect the bug — and the differential would then
	# "prove" the fix using a suite that never saw it. That is the silent
	# degradation this whole epic is about, in the one place least able to
	# afford it.
	#
	# ONE list, not two overlapping loops. `git diff --name-only <ref>`
	# already includes any cited .bats that differs, and a cited .bats that
	# does NOT differ is identical at <ref> anyway — so the second loop only
	# ever re-copied what the first had. Its own failure is fatal too: an
	# empty list from a broken ref would silently omit every new test.
	# p1-bypass (VERIFIED conf 9): `git diff --name-only` DOES NOT LIST
	# UNTRACKED FILES, and a brand-new test file is exactly what a fix for
	# a missing-coverage finding adds. The baseline therefore ran without
	# the new test, `bats <missing>.bats` exited 1 — not 127, so the
	# absence guard did not catch it either — and the fix got a free
	# differential for a file that was never copied. Untracked .bats files
	# are enumerated separately and appended.
	local _bats_list _bats_untracked _bats_rc=0
	# -c core.quotePath=false: with the default, a path containing a
	# non-ASCII byte is printed QUOTED and C-escaped ("tests/caf\303\251.bats").
	# That string does not exist on disk, so the loop below took its
	# not-found branch and skipped the file — the baseline then ran without
	# the very test meant to detect the bug, which is the fail-open the
	# fatal-copy rule exists to prevent. An earlier comment claimed the
	# not-a-regular-file refusal caught this; it does not, because the
	# does-not-exist check is evaluated first.
	# -z, THROUGH A TEMP FILE. `core.quotePath=false` alone fixes only
	# high-byte names; git still C-quotes CONTROL characters — a `.bats`
	# path containing a newline still arrives as a quoted string that does
	# not exist on disk, and the loop below skips it, which is the same
	# fail-open the fatal-copy rule forbids.
	#
	# The temp file is not stylistic: bash DROPS NUL BYTES inside `$( )`, so
	# reading -z output through a command substitution silently yields an
	# empty list. That is exactly how the bats-scope SSOT reported a zero
	# file set in #2642.
	local _bats_z
	_bats_z=$(mktemp -t prove-bats-z.XXXXXX) || {
		echo "error: mktemp failed while listing changed .bats files — refusing rather than running a baseline that silently omits the new tests" >&2
		_prove_symptom_wt_cleanup
		return 2
	}
	if ! git -C "$REPO_ROOT" diff -z --name-only "$ref" -- '*.bats' >"$_bats_z" 2>/dev/null; then
		echo "error: could not list changed .bats files against '$ref' — refusing rather than running a baseline that silently omits the new tests" >&2
		rm -f "$_bats_z"
		_prove_symptom_wt_cleanup
		return 2
	fi
	if ! git -C "$REPO_ROOT" ls-files -z --others --exclude-standard -- '*.bats' >>"$_bats_z" 2>/dev/null; then
		echo "error: could not list untracked .bats files — refusing rather than running a baseline that silently omits a brand-new test file" >&2
		rm -f "$_bats_z"
		_prove_symptom_wt_cleanup
		return 2
	fi
	local f
	while IFS= read -r -d '' f; do
		[ -n "$f" ] || continue
		# A path git listed that does not EXIST was deleted in this tree —
		# there is nothing to copy and nothing is lost, so skip it. But a
		# path that exists and is NOT a regular file (a directory, a broken
		# symlink) was silently skipped
		# by the old bare `[ -f ] || continue`, which is the same "run the
		# baseline without the test" outcome the fatal-copy rule below
		# exists to prevent — just reached by a different door.
		if [ ! -e "$REPO_ROOT/$f" ]; then
			continue
		fi
		if [ ! -f "$REPO_ROOT/$f" ]; then
			echo "error: $f is listed as a changed .bats but is not a regular file in this tree — refusing rather than running a baseline WITHOUT the test meant to detect the bug (#2643)" >&2
			_prove_symptom_wt_cleanup
			return 2
		fi
		if ! mkdir -p "$wt/$(dirname "$f")"; then
			echo "error: could not create $(dirname "$f") in the baseline worktree — refusing rather than running without $f" >&2
			_prove_symptom_wt_cleanup
			return 2
		fi
		if ! cp "$REPO_ROOT/$f" "$wt/$f"; then
			echo "error: could not copy $f into the baseline worktree — refusing rather than running a baseline WITHOUT the test meant to detect the bug" >&2
			_prove_symptom_wt_cleanup
			return 2
		fi
	done <"$_bats_z"
	rm -f "$_bats_z"

	# Output kept in a file the caller names, so a baseline mismatch can
	# show what happened rather than only that the number was wrong.
	#
	# p1-bypass (VERIFIED conf 10): ELAPSED TIME IS RECORDED because rc 124
	# from our own deadline is not evidence of anything. `--symptom-cmd
	# 'test -f marker || sleep 300' --symptom-baseline-rc 124` made the
	# wrapper's own kill play the part of "the bug", reproducing in the
	# symptom field exactly the hole #2562 closed for retest. The caller
	# compares against the deadline and refuses.
	# 4th POSITIONAL, not an exported global. The first version exported
	# PROVE_SYMPTOM_BASELINE_OUT, which meant the operator-supplied
	# --symptom-cmd was executed with the path to its own evidence-capture
	# file in its environment — and two functions in the same process were
	# talking through the environment for no reason.
	local outf="${4:-/dev/null}"
	# SECONDS, matching the retest path twelve lines up — not `date`. The
	# subprocess plus its "date failed, elapsed stays 0" fallback bought
	# nothing, and a silently-zero elapsed would have disabled the
	# deadline-kill discrimination that reads it.
	local _t0 _elapsed=0
	_t0=$SECONDS
	# Same split as the fixed half: the explicit opt-out may run unbounded,
	# a missing binary may not. `return 2` so the caller's existing
	# baseline-failure handling runs and the worktree is cleaned up.
	if [ "${PROVE_RETEST_NO_TIMEOUT:-0}" = "1" ]; then
		echo "record-fix: WARN: the baseline symptom run is UNBOUNDED by explicit PROVE_RETEST_NO_TIMEOUT=1 — a hang will not be killed (#2643)" >&2
		(cd "$wt" && bash -c "$cmd") >"$outf" 2>&1 || rc=$?
	elif command -v timeout >/dev/null 2>&1; then
		(cd "$wt" && timeout "$tmo" bash -c "$cmd") >"$outf" 2>&1 || rc=$?
	else
		echo "error: no timeout binary on PATH — refusing to run the baseline symptom evidence UNBOUNDED (install coreutils, or set PROVE_RETEST_NO_TIMEOUT=1 to explicitly accept an unenforced deadline) (#2643)" >&2
		_prove_symptom_wt_cleanup
		return 2
	fi
	_elapsed=$((SECONDS - _t0))
	_prove_symptom_wt_cleanup
	# rc on the first line, elapsed seconds on the second.
	printf '%s\n%s\n' "$rc" "$_elapsed"
	return 0
}

# (#2652 phase0.5) ONE re-execution engine for every live evidence run —
# the retest and the pre-fix baseline — so the #2562 deadline contract
# cannot drift between call sites (real run, real deadline, fail-closed
# without a timeout binary, a deadline kill is never evidence). The #2643
# symptom halves keep their own runners DELIBERATELY: their refusal
# strings ("fixed-tree symptom run hit the deadline", the #2643-tagged
# missing-binary message with rc 2) are contract text the symptom suite
# pins, and the baseline half additionally runs in a detached worktree —
# absorbing either here would change published messages to save ~30
# lines (phase1 simplifier, partially applied).
# _evidence_reexec <cmd> <announce-prefix> <noun>
#   Runs <cmd> at $REPO_ROOT under PROVE_RETEST_TIMEOUT. Sets _REEXEC_RC
#   (observed rc) + _REEXEC_TAIL (last 800 bytes of combined output).
#   Exits 1 on machinery failure (mktemp, no timeout binary without the
#   explicit seam, our own deadline kill).
_REEXEC_RC=0
_REEXEC_TAIL=""
_evidence_reexec() {
	local _cmd="$1" _announce="$2" _noun="$3"
	local _tmo="${PROVE_RETEST_TIMEOUT:-120}"
	if ! [[ $_tmo =~ ^[1-9][0-9]*$ ]]; then
		echo "WARN: PROVE_RETEST_TIMEOUT='$_tmo' is not a positive integer — using 120" >&2
		_tmo=120
	fi
	local _out _t0 _elapsed
	_REEXEC_RC=0
	_out=$(mktemp) || {
		echo "error: mktemp failed for $_noun output capture" >&2
		exit 1
	}
	echo "$_announce (timeout ${_tmo}s): $_cmd" >&2
	_t0=$SECONDS
	# Positive-first, env read once (phase1 simplifier): opt-out wins,
	# else a present timeout binary, else refuse — same truth table as
	# the negated compound this replaces, one read that cannot disagree.
	local _no_deadline="${PROVE_RETEST_NO_TIMEOUT:-0}"
	if [ "$_no_deadline" = "1" ]; then
		echo "WARN: PROVE_RETEST_NO_TIMEOUT=1 — the PROVE_RETEST_TIMEOUT deadline is UNENFORCED for this $_noun run (a hung command must be interrupted manually)" >&2
		(cd "$REPO_ROOT" && bash -c "$_cmd") >"$_out" 2>&1 || _REEXEC_RC=$?
	elif command -v timeout >/dev/null 2>&1; then
		(cd "$REPO_ROOT" && timeout "$_tmo" bash -c "$_cmd") >"$_out" 2>&1 || _REEXEC_RC=$?
	else
		echo "error: no timeout binary on PATH — refusing to run $_noun evidence UNBOUNDED (install coreutils, or set PROVE_RETEST_NO_TIMEOUT=1 to explicitly accept an unenforced deadline) (#2562)" >&2
		rm -f "$_out"
		exit 1
	fi
	_elapsed=$((SECONDS - _t0))
	if [ "$_REEXEC_RC" -eq 124 ] && [ "$_elapsed" -ge "$_tmo" ]; then
		echo "error: $_noun hit the PROVE_RETEST_TIMEOUT deadline (${_elapsed}s >= ${_tmo}s) — a deadline kill is never valid evidence, regardless of the claimed rc; raise PROVE_RETEST_TIMEOUT if the evidence genuinely needs longer (#2562)" >&2
		rm -f "$_out"
		exit 1
	fi
	_REEXEC_TAIL=$(tail -c 800 "$_out" 2>/dev/null || true)
	rm -f "$_out"
}

# (#2652) The ONE path rule for baseline files — used by the writer
# (record-baseline) AND the reader (record-fix), so the traversal guard
# cannot exist on only one side (phase1: `record-fix --finding-id ../../x`
# read an arbitrary JSON outside the store).
# Echoes the path; exits 2 on a path-shaped id.
_baseline_file_for_finding() {
	case "${1:-}" in
	'' | */* | *..*)
		echo "error: finding-id must be non-empty and contain no '/' or '..' (it names the baseline file)" >&2
		exit 2
		;;
	esac
	printf '%s\n' "$BASELINE_DIR/${1}.json"
}

# (#2652) PRE-FIX BASELINE — the missing half of #2562's "evidence is a
# run". record-fix re-executes the retest AFTER the fix, which proves the
# suite passes but not that the bug was ever present; the #2643 symptom
# differential reconstructs "before" from a worktree, which works only
# when a pre-fix commit exists to check out. This subcommand captures the
# "before" LIVE, at the moment the operator still has the broken tree:
# the command is re-executed under the same deadline machinery and must
# FAIL — a passing baseline demonstrates no symptom and is refused
# (a symptom whose failure mode is a WRONG rc-0 needs the symptom flags'
# explicit rc pair instead; this path encodes the common fails→passes
# contract). Evidence {cmd, rc, output tail, tree sha, note} is stored
# keyed by finding-id, AND a corroborating row is appended to the TRACKED
# audit ledger — the session-state file alone is forgeable with a text
# editor, and a forged tracked row shows up in the diff (phase1 security).
# The later record-fix for that finding-id must run the SAME command,
# claim rc 0, and stamps both halves into the record; the baseline file
# is consumed by that stamp.
cmd_record_baseline() {
	local finding_id="" finding_text="" retest_cmd="" note="" allow_absence=0
	while [ $# -gt 0 ]; do
		case "$1" in
		--finding-id)
			[ $# -lt 2 ] && {
				echo "error: missing value for --finding-id" >&2
				exit 2
			}
			finding_id=${2:-}
			shift 2
			;;
		--finding-text)
			[ $# -lt 2 ] && {
				echo "error: missing value for --finding-text" >&2
				exit 2
			}
			finding_text=${2:-}
			shift 2
			;;
		--retest-cmd)
			[ $# -lt 2 ] && {
				echo "error: missing value for --retest-cmd" >&2
				exit 2
			}
			retest_cmd=${2:-}
			shift 2
			;;
		--note)
			[ $# -lt 2 ] && {
				echo "error: missing value for --note" >&2
				exit 2
			}
			note=${2:-}
			shift 2
			;;
		--allow-absence-baseline)
			allow_absence=1
			shift
			;;
		*)
			echo "error: unknown arg: $1" >&2
			exit 2
			;;
		esac
	done
	[ -z "$retest_cmd" ] && {
		echo "error: --retest-cmd is required" >&2
		exit 2
	}
	# Same key derivation as record-fix (phase1: the two halves could not
	# agree on a key by construction — record-fix derives from
	# --finding-text when --finding-id is omitted, so the capture must
	# offer the identical derivation or default invocations never pair).
	if [ -z "$finding_id" ]; then
		if [ -z "$finding_text" ]; then
			echo "error: --finding-id or --finding-text is required (the later record-fix pairs on the same key)" >&2
			exit 2
		fi
		finding_id=$(_hash_finding "$finding_text")
		[ -z "$finding_id" ] && {
			echo "error: cannot derive finding-id (no sha256sum/shasum) — pass --finding-id explicitly" >&2
			exit 2
		}
	fi
	local _bl_file
	_bl_file=$(_baseline_file_for_finding "$finding_id")

	# The shared #2562 engine: real run, real deadline, fail-closed when
	# no timeout binary exists, a deadline kill is never evidence.
	_evidence_reexec "$retest_cmd" "record-baseline: re-executing pre-fix evidence" "baseline"
	local _bl_actual_rc="$_REEXEC_RC"
	if [ "$_bl_actual_rc" -eq 0 ]; then
		echo "error: baseline run PASSED (rc 0) — no symptom demonstrated, so there is nothing for the fix to flip; a baseline must show the bug (#2652)." >&2
		echo "  If the symptom is a WRONG success (the command should fail and does not), encode the expected rcs explicitly via record-fix's --symptom-cmd/--symptom-baseline-rc/--symptom-fixed-rc instead." >&2
		exit 1
	fi
	# rc 126/127 are absence, not symptom (phase1 silent-failure, mirror
	# of the #2643 worktree-baseline rule): a fix that ADDS the very file
	# the command runs makes the baseline exit "command not found", which
	# looks like proof and is not. --allow-absence-baseline is the
	# explicit claim that absence IS the reported symptom.
	if { [ "$_bl_actual_rc" -eq 126 ] || [ "$_bl_actual_rc" -eq 127 ]; } && [ "$allow_absence" -ne 1 ]; then
		echo "error: baseline exited rc $_bl_actual_rc (not executable / command not found) — that demonstrates ABSENCE, not the bug's symptom; a fix that adds the file would 'flip' this without fixing anything (#2652)." >&2
		echo "  Pass --allow-absence-baseline only when absence genuinely IS the reported symptom." >&2
		exit 1
	fi
	local _bl_tail _bl_sha _bl_ts
	_bl_tail="$_REEXEC_TAIL"
	# Loud refusal, not a silent "unknown" (phase1 silent-failure): the
	# sha is the field the record-fix ancestry check hangs on; capturing
	# without it would quietly undermine the pairing downstream.
	if ! _bl_sha=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null); then
		echo "error: cannot resolve HEAD for the baseline's tree sha — a baseline unmoored from a commit cannot be paired (#2652)" >&2
		exit 1
	fi
	_bl_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	mkdir -p "$BASELINE_DIR" || {
		echo "error: cannot create $BASELINE_DIR" >&2
		exit 1
	}
	if ! jq -n \
		--arg fid "$finding_id" \
		--arg ts "$_bl_ts" \
		--arg sha "$_bl_sha" \
		--arg cmd "$retest_cmd" \
		--argjson rc "$_bl_actual_rc" \
		--arg tail "$_bl_tail" \
		--arg note "$note" \
		'{finding_id: $fid, ts: $ts, sha: $sha, retest_cmd: $cmd,
		  baseline_rc: $rc, output_tail: $tail,
		  note: (if $note == "" then null else $note end)}' \
		>"$_bl_file"; then
		echo "error: failed writing baseline record for $finding_id" >&2
		exit 1
	fi
	# Corroborating TRACKED row (phase1 security): the gitignored file
	# above is forgeable with a text editor; record-fix refuses a
	# baseline the tracked ledger does not corroborate. The row's empty
	# source keeps it outside every coverage query (they filter on
	# .source). Unrecordable corroboration = no baseline (rm the file).
	if ! _append_tracked_audit "baseline" "$finding_id" "" "" "" \
		"baseline_rc=$_bl_actual_rc retest_cmd=$retest_cmd" "$_bl_file" "" 1 "$_bl_sha"; then
		rm -f "$_bl_file"
		echo "error: tracked-ledger corroboration append failed — refusing to keep an uncorroborated baseline (#2652)" >&2
		exit 1
	fi
	echo "✓ Captured pre-fix baseline for $finding_id: rc=$_bl_actual_rc (must be nonzero; record-fix will require the same command to exit 0)"
	echo "  $_bl_file"
}

cmd_record_fix() {
	# v4.28-W4 #851 r1: ASYMMETRY DOCS — record-fix INTENTIONALLY
	# differs from record-rejection in required flags:
	#
	# RECORD-FIX requires --retest-cmd + --retest-rc; does NOT require
	# --follow-up-issue.
	#
	# Why: fix = CLOSE, not defer. Evidence of close is "the retest
	# command exits cleanly at this exact SHA". No future tracking
	# needed because the finding is resolved in-PR. A follow-up issue
	# would be misleading — it would imply unfinished work that doesn't
	# exist.
	#
	# This is the dual of cmd_record_rejection's contract (see its
	# docstring above). When in doubt: rejection→follow-up-issue=tracking;
	# fix→retest-cmd=evidence. Symmetrizing them by adding
	# --follow-up-issue here would either (a) require fake/empty issue
	# numbers (gh validation breaks), or (b) signal "this fix is somehow
	# tentative" — both wrong.
	local finding_id="" finding_text="" fix_summary="" retest_cmd="" retest_rc="" cited_files=""
	local symptom_cmd="" symptom_baseline_rc="" symptom_fixed_rc="" baseline_ref=""
	local allow_absence_baseline=0
	local covers_count="1" confidence="" cluster_id="" src="" covered_sha_arg=""
	# v4.28-W4 #723: record-fix now accepts --severity (matches the
	# help text claim). cr-source records-of-fix use severity vocab
	# (critical|high|medium|minor|info) same as record-rejection.
	# phase0.5/phase1 sources still use --confidence.
	local severity=""
	while [ $# -gt 0 ]; do
		case "$1" in
		-h | --help)
			print_help
			exit 0
			;;
		--finding-id)
			[ $# -lt 2 ] && {
				echo "error: missing value for --finding-id" >&2
				exit 2
			}
			finding_id=${2:-}
			shift 2
			;;
		--finding-text)
			[ $# -lt 2 ] && {
				echo "error: missing value for --finding-text" >&2
				exit 2
			}
			finding_text=${2:-}
			shift 2
			;;
		--fix-summary)
			[ $# -lt 2 ] && {
				echo "error: missing value for --fix-summary" >&2
				exit 2
			}
			fix_summary=${2:-}
			shift 2
			;;
		--symptom-cmd)
			[ $# -lt 2 ] && {
				echo "error: missing value for --symptom-cmd" >&2
				exit 2
			}
			symptom_cmd=${2:-}
			shift 2
			;;
		--symptom-baseline-rc)
			[ $# -lt 2 ] && {
				echo "error: missing value for --symptom-baseline-rc" >&2
				exit 2
			}
			symptom_baseline_rc=${2:-}
			shift 2
			;;
		--symptom-fixed-rc)
			[ $# -lt 2 ] && {
				echo "error: missing value for --symptom-fixed-rc" >&2
				exit 2
			}
			symptom_fixed_rc=${2:-}
			shift 2
			;;
		--baseline-ref)
			[ $# -lt 2 ] && {
				echo "error: missing value for --baseline-ref" >&2
				exit 2
			}
			baseline_ref=${2:-}
			shift 2
			;;
		--allow-absence-baseline)
			# An absence-shaped baseline (rc 127) is refused by default —
			# see the guard below. This flag is the explicit claim that 127
			# IS the reported symptom, not an artefact of the fix adding a
			# file that did not exist at HEAD.
			allow_absence_baseline=1
			shift
			;;
		--retest-cmd)
			[ $# -lt 2 ] && {
				echo "error: missing value for --retest-cmd" >&2
				exit 2
			}
			retest_cmd=${2:-}
			shift 2
			;;
		--retest-rc)
			[ $# -lt 2 ] && {
				echo "error: missing value for --retest-rc" >&2
				exit 2
			}
			retest_rc=${2:-}
			shift 2
			;;
		--cited-files)
			[ $# -lt 2 ] && {
				echo "error: missing value for --cited-files" >&2
				exit 2
			}
			cited_files=${2:-}
			shift 2
			;;
		--covers-count)
			[ $# -lt 2 ] && {
				echo "error: missing value for --covers-count" >&2
				exit 2
			}
			covers_count=${2:-}
			shift 2
			;;
		--confidence)
			[ $# -lt 2 ] && {
				echo "error: missing value for --confidence" >&2
				exit 2
			}
			confidence=${2:-}
			shift 2
			;;
		--cluster-id)
			[ $# -lt 2 ] && {
				echo "error: missing value for --cluster-id" >&2
				exit 2
			}
			cluster_id=${2:-}
			shift 2
			;;
		--covered-sha)
			# (#2643) Name the sha this evidence covers instead of always
			# stamping HEAD. Without it a mislabeled record is PERMANENT —
			# the only exits are a bypass or re-running the review, which is
			# exactly the corner this feature's own author ended up in after
			# filing 42 phase0.5 findings under the wrong source. Validated
			# as an ANCESTOR of HEAD below, so it can correct a record and
			# never invent coverage for unrelated work.
			[ $# -lt 2 ] && {
				echo "error: missing value for --covered-sha" >&2
				exit 2
			}
			covered_sha_arg=${2:-}
			shift 2
			;;
		--source)
			# v4.28-W3-C: source of the underlying finding being fixed.
			# Same semantics as cmd_record_rejection's --source.
			[ $# -lt 2 ] && {
				echo "error: missing value for --source" >&2
				exit 2
			}
			src=${2:-}
			shift 2
			;;
		--severity)
			# v4.28-W4 #723: cr-source records use severity vocab
			# (critical|high|medium|minor|info). Mirrors the help-text
			# claim. phase0.5/phase1 use --confidence instead.
			[ $# -lt 2 ] && {
				echo "error: missing value for --severity" >&2
				exit 2
			}
			severity=${2:-}
			shift 2
			;;
		*)
			echo "error: unknown arg: $1" >&2
			exit 2
			;;
		esac
	done

	if ! [[ $covers_count =~ ^[1-9][0-9]*$ ]]; then
		echo "error: --covers-count must be a positive integer (got: $covers_count)" >&2
		exit 2
	fi
	# r2 code-reviewer #3: validate --source (mirror cmd_record_rejection).
	# Without this, a typo like `--source phse1` writes that exact string to
	# the audit record, then prove-yourself-gate's filter
	# `(.source // "phase1") == "phase1"` excludes it from coverage and the
	# operator's record is silently uncounted.
	[ -z "$src" ] && {
		echo "error: --source is REQUIRED (phase0.5|phase1|cr|issue)" >&2
		exit 2
	}
	# (#2643) `issue` is issue-driven bug work — the case where "did the
	# reported symptom go away" is the entire question, and which had no
	# way to be recorded because the vocabulary was review stages only.
	case "$src" in
	phase0.5 | phase1 | cr | issue) ;;
	*)
		echo "error: --source must be phase0.5|phase1|cr|issue (got: $src)" >&2
		exit 2
		;;
	esac

	# (#2643) Resolve and VALIDATE --covered-sha before anything reads it.
	# It must name a real commit that is an ANCESTOR of HEAD: evidence may be
	# re-filed against a commit already on this branch (correcting a label),
	# never attached to unrelated or future work.
	local _cov_sha=""
	if [ -n "$covered_sha_arg" ]; then
		_cov_sha=$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${covered_sha_arg}^{commit}" 2>/dev/null) || _cov_sha=""
		if [ -z "$_cov_sha" ]; then
			echo "error: --covered-sha '$covered_sha_arg' does not resolve to a commit (#2643)" >&2
			exit 2
		fi
		if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$_cov_sha" HEAD 2>/dev/null; then
			echo "error: --covered-sha '$covered_sha_arg' is not an ancestor of HEAD — evidence can be re-filed against a commit already on this branch, not attached to unrelated work (#2643)" >&2
			exit 2
		fi
		echo "record-fix: covering ${_cov_sha:0:7} (named via --covered-sha) rather than HEAD" >&2
	fi

	# ===== #2643 SOURCE-vs-STAGE RECONCILIATION ==========================
	# The vocabulary check above only proves the string is spellable. It
	# does NOT prove it names the stage that actually produced the findings
	# being covered — and that gap cost 42 findings across three shas,
	# recorded as `--source issue` when they were phase0.5 prefilter
	# results. The graduation gate counts only `source == "phase0.5"`, so it
	# reported 0/17, 0/13, 0/12 for work that was entirely done. The label
	# was wrong and, because `covered_sha` is stamped from HEAD, unfixable
	# afterwards.
	#
	# Two checks, because the failure had two independent halves:
	#   (1) the source disagrees with the stage log for THIS sha, and
	#   (2) there is no stage log at all, because the phases were run by
	#       hand and the state machine was never driven — which is the
	#       condition that makes (1) silent.
	# Both name PROVE_SOURCE_CHECK_SKIP so a deliberate exception is
	# audit-logged rather than invisible.
	# Resolve from the script's own location first (works in the consumer
	# .claude/ mirror too), then fall back to the repo root.
	local _SF_LIB _SF_SELF
	_SF_SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || _SF_SELF=""
	_SF_LIB="$_SF_SELF/../../_lib/stage-findings.sh"
	[ -r "$_SF_LIB" ] || _SF_LIB="$REPO_ROOT/_lib/stage-findings.sh"
	[ -r "$_SF_LIB" ] || _SF_LIB="$REPO_ROOT/.claude/_lib/stage-findings.sh"
	if [ "${PROVE_SOURCE_CHECK_SKIP:-0}" = "1" ]; then
		# ACTUALLY LOG IT. Both operator messages call this bypass
		# "audit-logged" and the first version only echoed to stderr —
		# every other bypass in this repo appends a row, so an auditor
		# reading the ledger could not tell a reconciled record from a
		# bypassed one. Claiming an audit trail that does not exist is the
		# same defect class this branch is fixing.
		echo "prove-yourself: PROVE_SOURCE_CHECK_SKIP=1 — source/stage reconciliation bypassed for --source $src (#2643)" >&2
		# A FAILURE TO LOG IS ANNOUNCED. Appending with `|| true` would
		# reproduce, one level down, the very defect this row exists to
		# fix: a bypass that calls itself audited when nothing recorded it.
		# Still non-fatal — refusing the record because a log write failed
		# would be worse — but never silent.
		if ! command -v jq >/dev/null 2>&1; then
			echo "prove-yourself: WARN: jq is not on PATH — this PROVE_SOURCE_CHECK_SKIP bypass is NOT audit-logged" >&2
		elif ! mkdir -p "$REPO_ROOT/.claude/logs" 2>/dev/null; then
			echo "prove-yourself: WARN: cannot create $REPO_ROOT/.claude/logs — this PROVE_SOURCE_CHECK_SKIP bypass is NOT audit-logged" >&2
		elif ! jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			--arg sha "$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")" \
			--arg src "$src" --arg fid "$finding_id" \
			'{ts:$ts, sha:$sha, label:"prove-source-check-skip", source:$src, finding_id:$fid}' \
			>>"$REPO_ROOT/.claude/logs/prove-source-check-skip.jsonl" 2>/dev/null; then
			echo "prove-yourself: WARN: could not append the bypass row to .claude/logs/prove-source-check-skip.jsonl — this bypass is stderr-only and the ledger will not show it" >&2
		fi
	elif [ ! -r "$_SF_LIB" ]; then
		# FAIL CLOSED AND SAY SO. Silently skipping meant "reconciled and
		# clean" and "never reconciled" were indistinguishable in both the
		# output and the written record.
		echo "error: cannot read _lib/stage-findings.sh — the source/stage reconciliation cannot run, and a check that silently does not run is the failure this gate exists to prevent (#2643)." >&2
		echo "  Looked for it next to this script and under the repo root. Deliberate exception (audit-logged): PROVE_SOURCE_CHECK_SKIP=1" >&2
		exit 2
	else
		# shellcheck source=/dev/null
		. "$_SF_LIB"
		# ALL THREE are load-bearing. A 127 from cycle_started or
		# cycle_in_use reads as "not started" / "not in use" and turns
		# check (2) off silently — the exact shape this guard exists to
		# stop, so a partial library must refuse rather than half-run.
		local _sf_fn
		for _sf_fn in _stage_findings_stages_at _stage_findings_cycle_started \
			_stage_findings_cycle_in_use; do
			if [ "$(type -t "$_sf_fn" 2>/dev/null)" != "function" ]; then
				echo "error: _lib/stage-findings.sh loaded but does not define $_sf_fn — refusing rather than skipping the reconciliation silently (#2643)" >&2
				exit 2
			fi
		done
		if true; then
			local _sf_sha _sf_stages _sf_started=0
			if [ -n "$_cov_sha" ]; then
				_sf_sha="$_cov_sha"
			else
				_sf_sha=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null) || _sf_sha=""
			fi
			if [ -n "$_sf_sha" ]; then
				_stage_findings_cycle_started "$REPO_ROOT" "$_sf_sha" && _sf_started=1
				local _sf_rc=0
				_sf_stages=$(_stage_findings_stages_at "$REPO_ROOT" "$_sf_sha") || _sf_rc=$?
				if [ "$_sf_rc" -ne 0 ]; then
					# A log that cannot be read is NOT an absence of
					# findings. Coercing it to zero shrinks the bar, which
					# is the exact coercion _phase05_findings_for_sha
					# refuses for the same reason.
					echo "error: could not determine which stage produced the findings at ${_sf_sha:0:7} — a stage log is unreadable, malformed, or jq is unavailable (#2643)." >&2
					echo "  Refusing rather than assuming there is nothing to reconcile: an unreadable log read as 'no findings' is how a mislabel gets written in the first place." >&2
					echo "  Deliberate exception (audit-logged): PROVE_SOURCE_CHECK_SKIP=1" >&2
					exit 2
				fi

				# (1) A stage logged findings here and --source names a
				#     different one. The record would not count toward the
				#     graduation this evidence is for.
				if [ -n "$_sf_stages" ]; then
					case "$_sf_stages" in
					*"$src"*) ;;
					*)
						echo "error: SOURCE/STAGE MISMATCH — ${_sf_sha:0:7} has findings logged by: $(printf '%s' "$_sf_stages" | tr '\n' ' ')but --source is '$src' (#2643)." >&2
						echo "  Graduation gates count ONLY records whose source matches the stage that found the issue, so this record would be written and then never counted — which is how 42 real fixes read as 0/17, 0/13, 0/12." >&2
						echo "  Use --source \"$(printf '%s' "$_sf_stages" | head -1)\", or split the record if it genuinely covers more than one stage." >&2
						echo "  If this is GENUINELY unrelated work on a sha that also had a review round — not coverage for the findings above — that is the case this check cannot tell apart, and the escape is the right answer: PROVE_SOURCE_CHECK_SKIP=1 (audit-logged)." >&2
						exit 2
						;;
					esac
				# (2) No stage log for this sha AND no cycle state. Phase
				#     evidence on a branch the machine never drove is
				#     unreconcilable: nothing will ever match it up.
				elif [ "$_sf_started" -eq 0 ] && [ "$src" != "issue" ] &&
					_stage_findings_cycle_in_use "$REPO_ROOT"; then
					echo "error: --source $src but the ship-cycle state machine has never run on ${_sf_sha:0:7} (#2643)." >&2
					echo "  A phase-sourced record with no stage log is unreconcilable — no gate can ever match it to the round it claims to cover. This is exactly the shape that let hand-run phases produce records nothing counted." >&2
					echo "  Run 'scripts/ship-pr-cycle.sh start' (then 'next') so the phase is logged, or record issue-driven work as --source issue." >&2
					echo "  Deliberate exception (audit-logged): PROVE_SOURCE_CHECK_SKIP=1" >&2
					exit 2
				fi
			fi
		fi
	fi
	# v4.28-W3-C: confidence/severity required source-keyed (record-fix
	# doesn't need follow-up since it's "did fix" not "deferred"; the
	# retest_cmd + retest_rc are the dogfood evidence).
	# v4.28-W4 #723: source-aware validation — cr uses --severity,
	# phase0.5/phase1 use --confidence.
	# r1 CR PR #755: validate --confidence format whenever provided
	# (cr-source allows optional --confidence too — without this guard,
	# non-numeric input reaches jq --argjson and fails as a parse error
	# instead of our normal exit-2 path).
	if [ -n "$confidence" ] && ! [[ $confidence =~ ^([1-9]|10)$ ]]; then
		echo "error: --confidence must be 1-10 integer (got: $confidence)" >&2
		exit 2
	fi
	case "$src" in
	issue)
		# Neither confidence nor severity applies: an issue is a report
		# somebody filed, not a finding an agent scored.
		;;
	phase0.5 | phase1)
		[ -z "$confidence" ] && {
			echo "error: --confidence (1-10) is REQUIRED for --source=$src" >&2
			exit 2
		}
		;;
	cr)
		[ -z "$severity" ] && {
			echo "error: --severity is REQUIRED for --source=cr (vocab: critical|high|medium|minor|info)" >&2
			exit 2
		}
		case "$severity" in
		critical | high | medium | minor | info) ;;
		*)
			echo "error: --severity must be critical|high|medium|minor|info (got: $severity)" >&2
			exit 2
			;;
		esac
		;;
	esac

	[ -z "$finding_text" ] && {
		echo "error: --finding-text is required" >&2
		exit 2
	}
	[ -z "$fix_summary" ] && {
		echo "error: --fix-summary is required" >&2
		exit 2
	}
	[ -z "$retest_cmd" ] && {
		echo "error: --retest-cmd is required" >&2
		exit 2
	}
	[ -z "$retest_rc" ] && {
		echo "error: --retest-rc is required" >&2
		exit 2
	}

	if ! [[ $retest_rc =~ ^[0-9]+$ ]]; then
		echo "error: --retest-rc must be a non-negative integer (got: $retest_rc)" >&2
		exit 2
	fi

	if [ -z "$finding_id" ]; then
		finding_id=$(_hash_finding "$finding_text")
		[ -z "$finding_id" ] && {
			echo "error: cannot derive finding-id (no sha256sum/shasum) — pass --finding-id explicitly" >&2
			exit 2
		}
	fi

	# ---- (#2652) PRE-FIX BASELINE PAIRING -----------------------------
	# A baseline captured by record-baseline for this finding-id upgrades
	# the retest from "passes now" to "failed before, passes now". When
	# one exists it is REQUIRED to match: same command (a different
	# command is two unrelated observations, not a differential) and a
	# claimed rc of 0 (the baseline already proved nonzero, so the pair
	# encodes fails→passes; nonzero-target evidence belongs to the
	# symptom flags). Absent a baseline, acceptance behavior is unchanged
	# (records additionally stamp baseline_verified:false) — the #2643
	# symptom differential remains the before/after path for
	# already-committed fixes and cycle-critical citations.
	local _bl_file
	_bl_file=$(_baseline_file_for_finding "$finding_id")
	local _bl_present=false _bl_cmd="" _bl_rc="" _bl_ts="" _bl_sha="" _bl_tail="" _bl_note=""
	if [ -f "$_bl_file" ]; then
		_bl_present=true
		# One guard over every field read (phase1 simplifier): the -er
		# reads sit first so a missing cmd/rc short-circuits, and a jq
		# failure on any provenance field is the same malformed refusal
		# — never a silently-empty stamp (phase0.5).
		if ! _bl_cmd=$(jq -er '.retest_cmd' "$_bl_file" 2>/dev/null) ||
			! _bl_rc=$(jq -er '.baseline_rc' "$_bl_file" 2>/dev/null) ||
			! _bl_ts=$(jq -r '.ts // ""' "$_bl_file" 2>/dev/null) ||
			! _bl_sha=$(jq -r '.sha // ""' "$_bl_file" 2>/dev/null) ||
			! _bl_tail=$(jq -r '.output_tail // ""' "$_bl_file" 2>/dev/null) ||
			! _bl_note=$(jq -r '.note // ""' "$_bl_file" 2>/dev/null); then
			echo "error: baseline record $_bl_file is malformed — re-capture with record-baseline or remove it (#2652)" >&2
			exit 2
		fi
		# File-sourced value headed for --argjson (phase1 silent-failure):
		# record-baseline only ever writes 1-255, so anything else is a
		# corrupt or hand-edited record — refuse as malformed rather than
		# let jq abort mid-write (truncating the state file) or stamp a
		# lying rc-0 "pair".
		if ! [[ $_bl_rc =~ ^[1-9][0-9]?[0-9]?$ ]] || [ "$_bl_rc" -gt 255 ]; then
			echo "error: baseline record $_bl_file is malformed (baseline_rc '$_bl_rc' is not a 1-255 integer) — re-capture with record-baseline or remove it (#2652)" >&2
			exit 2
		fi
		# The tracked ledger must corroborate (phase1 security): the
		# session-state file alone is forgeable with a text editor — a
		# hand-written JSON would earn baseline_verified with no run.
		# Forging the corroboration means editing a TRACKED file, which
		# the diff shows. grep prefilters; jq requires kind/id/rc match.
		if ! grep -F "\"finding_id\":\"$finding_id\"" "$AUDIT_FILE" 2>/dev/null |
			jq -e --arg fid "$finding_id" --arg rc "$_bl_rc" \
				'select(.kind == "baseline" and .finding_id == $fid) |
				 select(.finding_text | startswith("baseline_rc=" + $rc + " "))' \
				>/dev/null 2>&1; then
			echo "error: the tracked audit ledger has no corroborating baseline row for $finding_id (rc=$_bl_rc) — record-baseline appends one at capture; a session-state file without it is not evidence (#2652)" >&2
			exit 2
		fi
		# The baseline must have been captured on THIS branch's history
		# (phase1 lifecycle): a months-old baseline from another line of
		# development is not the "before" of this fix.
		if [ -z "$_bl_sha" ] ||
			! git -C "$REPO_ROOT" merge-base --is-ancestor "$_bl_sha" HEAD 2>/dev/null; then
			echo "error: baseline for $finding_id was captured at '${_bl_sha:-<missing sha>}', which is not an ancestor of HEAD — a baseline from another line of development cannot pair with this fix; re-capture (#2652)" >&2
			exit 2
		fi
		if [ "$_bl_cmd" != "$retest_cmd" ]; then
			echo "error: BASELINE MISMATCH — record-baseline for $finding_id captured:" >&2
			echo "    $_bl_cmd" >&2
			echo "  but --retest-cmd is:" >&2
			echo "    $retest_cmd" >&2
			echo "  The before/after pair must run the SAME command (#2652)." >&2
			exit 2
		fi
		if [ "$retest_rc" -ne 0 ]; then
			echo "error: a pre-fix baseline exists for $finding_id (baseline rc=$_bl_rc), so the post-fix retest must PASS — claim --retest-rc 0. Nonzero-target evidence uses --symptom-cmd/--symptom-baseline-rc/--symptom-fixed-rc instead (#2652)." >&2
			exit 2
		fi
	fi

	# #2562: EVIDENCE MUST BE A RUN, NOT A CLAIM. record-fix used to accept
	# --retest-cmd/--retest-rc as free text — `--retest-cmd "trust me"
	# --retest-rc 0` passed, so CLAIMING a fix was strictly easier than
	# REJECTING a finding (which demands dogfood evidence). That asymmetry
	# is backwards. Two mechanical requirements, both fail-closed:
	#
	# (1) Critical-path rule: when a cited file is cycle infrastructure
	#     (hooks/, _lib/, pre-commit-hooks/, scripts/cr/local-review.sh),
	#     the retest command must invoke the real entry point — the cited
	#     repo-relative path must appear in the command text. A bats run
	#     alone is a synthetic harness, not production-shaped evidence
	#     (#2544's three escaped defects all had green bats).
	# (#2643) Set when any cited file is cycle-critical, so the symptom
	# block below can require differential evidence for the same population
	# the critical-path retest rule already targets.
	local _crit_required=0
	local _crit_f _crit_norm
	# shellcheck disable=SC2086
	for _crit_f in $cited_files; do
		# p1r1: normalize the mirror prefix — the same files execute at
		# .claude/hooks/ + .claude/_lib/ in the consumer layout, and a
		# citation spelled that way must not slip past the rule (nor must
		# a legitimately-mirror-invoking retest command be refused).
		# p2-cap residual (CR major): also strip leading ./ and resolve
		# lexical .. segments — `./hooks/x.sh` or `hooks/../hooks/x.sh`
		# otherwise escaped the pattern match entirely (fail-OPEN for a
		# cycle-critical citation).
		# p2-ci-r3 (CR major): COMBINED prefixes (./.claude/hooks/x.sh)
		# survived a single-pass strip — loop until stable so no ordering
		# of ./ and .claude/ escapes classification.
		_crit_norm="$_crit_f"
		while :; do
			_crit_prev="$_crit_norm"
			_crit_norm="${_crit_norm#./}"
			_crit_norm="${_crit_norm#.claude/}"
			[ "$_crit_norm" = "$_crit_prev" ] && break
		done
		while [[ $_crit_norm == *"/../"* ]]; do
			_crit_norm=$(printf '%s' "$_crit_norm" | sed -E 's|[^/]+/\.\./||')
		done
		case "$_crit_norm" in
		hooks/*.sh | _lib/*.sh | pre-commit-hooks/*.sh | scripts/cr/local-review.sh)
			_crit_required=1
			# p2r1 (CR major): COMMAND-position, not substring — a command
			# that merely MENTIONS the path (`echo hooks/x.sh`) must not
			# satisfy the rule. Word-scan with a simple-command state
			# machine: the path counts only where a command can start
			# (string start, after ; & | && ||, or after interpreter/
			# launcher words + their flag/duration/K=V args). This is
			# still a textual proxy — the trust boundary remains the
			# re-execution + rc match below — but the mention-only shapes
			# are rejected, fail-closed (unknown shapes do not count).
			# p2-ci-r4 (backup-reviewer material): short-circuit operators
			# BEFORE the cited path skip its execution entirely — `true ||
			# bash hooks/x.sh` never runs the entry point yet reports rc 0
			# (mirror: `false && …` launders a claimed nonzero). The
			# trailing-swallow guard below only saw the AFTER half. Contract
			# now: a cycle-critical retest is a SINGLE PIPELINE — no `;`,
			# no `&`/`&&`, no `||`, no newlines ANYWHERE (a plain feed-pipe
			# is fine: every pipeline stage executes unconditionally).
			# `>&`/`<&` redirect digraphs are stripped before the scan.
			local _crit_whole="${retest_cmd//>&/}"
			_crit_whole="${_crit_whole//<&/}"
			case "$_crit_whole" in
			*';'* | *'&'* | *'||'* | *$'\n'*)
				echo "error: cited file $_crit_f is cycle-critical — the retest command must be a SINGLE PIPELINE (no ; & && || or newlines): short-circuit operators before the entry point can skip executing it entirely while reporting an unrelated rc (#2562 p2-ci-r4)" >&2
				exit 2
				;;
			esac
			local _crit_ok=0 _expect=1 _w _wq
			# shellcheck disable=SC2086
			for _w in $retest_cmd; do
				_wq="${_w%\'}" _wq="${_wq#\'}"
				_wq="${_wq%\"}" _wq="${_wq#\"}"
				if [ "$_expect" = 1 ]; then
					if [ "$_wq" = "$_crit_f" ] || [ "$_wq" = "$_crit_norm" ]; then
						_crit_ok=1
						break
					fi
					case "$_wq" in
					bash | sh | source | . | env | exec | nohup | sudo | timeout) ;; # launcher — next word may be the cmd
					[0-9]* | -* | *=*) ;;                                            # launcher args (duration, flags, K=V)
					*) _expect=0 ;;                                                  # a different command — its args don't count
					esac
				fi
				case "$_w" in
				';' | '&&' | '||' | '|' | '&' | *';' | *'|' | *'&') _expect=1 ;;
				esac
			done
			if [ "$_crit_ok" != 1 ]; then
				echo "error: cited file $_crit_f is cycle-critical — the retest command must INVOKE the real entry point (the cited path in command position, not merely mentioned; a bats fixture alone is not production-shaped evidence) (#2562)" >&2
				exit 2
			fi
			# p2-ci-r2 (backup-reviewer CHANGES_REQUESTED, material): the
			# overall shell rc is launderable — `hooks/x.sh || true` sits
			# in command position AND always reports 0, so a failing entry
			# point recorded as "verified" evidence. For cycle-critical
			# citations, refuse any rc-SWALLOWING operator after the cited
			# path: `;` (rc = last cmd), `|` (rc = pipe tail), `&`
			# (backgrounded, rc lost), and newlines. `>&`/`<&` redirect
			# digraphs are stripped first (2>&1 is not an operator); the
			# conservative cost is that `&&` after the path is refused too
			# — put the entry point LAST, or split into one record per
			# invocation. Operators feeding the path (`printf x | bash
			# hooks/y.sh`) stay legal: only what FOLLOWS the path can
			# swallow its exit status. Scope: this structural rule rides
			# the cycle-critical contract; for non-critical citations the
			# operator chooses what constitutes evidence and only the rc
			# match is enforced — the mechanical system cannot judge the
			# semantic relevance of arbitrary commands.
			local _crit_after _crit_after_scan
			case "$retest_cmd" in
			*"$_crit_f"*) _crit_after="${retest_cmd#*"$_crit_f"}" ;;
			*) _crit_after="${retest_cmd#*"$_crit_norm"}" ;;
			esac
			_crit_after_scan="${_crit_after//>&/}"
			_crit_after_scan="${_crit_after_scan//<&/}"
			case "$_crit_after_scan" in
			*';'* | *'|'* | *'&'* | *$'\n'*)
				echo "error: cited file $_crit_f is cycle-critical and the retest command carries an rc-swallowing operator (; | & or newline) AFTER the entry point — the overall exit status would not be the entry point's own (e.g. '|| true' launders a failure). Put the invocation last, or split into one record per entry point (#2562 p2-ci-r2)" >&2
				exit 2
				;;
			esac
			;;
		esac
	done

	# (2) Re-execution: run the recorded command HERE and require its actual
	#     rc to equal the claimed --retest-rc. The record then carries
	#     retest_verified:true + retest_actual_rc; cmd_audit refuses fix
	#     records without the stamp, so a hand-forged record cannot pass
	#     the commit gate. The retest command must therefore be idempotent
	#     (a test/check invocation — which is what retest evidence is).
	#     A claimed NONZERO rc is legitimate evidence ("the gate refuses
	#     with rc 1" proves enforcement) — the contract is match, not zero.
	# (#2652 phase0.5) The machinery lives in _evidence_reexec — ONE
	# implementation of the #2562 contract (timeout validation, the
	# explicit PROVE_RETEST_NO_TIMEOUT seam, fail-closed without a
	# timeout binary, the deadline-kill refusal) shared with
	# record-baseline. The retest anchors at $REPO_ROOT there (p1r1: a
	# repo-relative command — which the critical-path rule REQUIRES —
	# would fail rc=127 from a subdirectory and surface as a bogus
	# EVIDENCE MISMATCH).
	_evidence_reexec "$retest_cmd" "record-fix: re-executing retest evidence" "retest"
	local _retest_actual_rc="$_REEXEC_RC" _retest_tail="$_REEXEC_TAIL"
	if [ "$_retest_actual_rc" -ne "$retest_rc" ]; then
		echo "error: EVIDENCE MISMATCH — retest command exited rc=$_retest_actual_rc but --retest-rc claims $retest_rc; refusing the record (#2562)" >&2
		echo "  last output:" >&2
		printf '%s' "$_retest_tail" | tail -c 400 | sed 's/^/    /' >&2 || true
		exit 1
	fi

	# ---- (#2643) DIFFERENTIAL SYMPTOM EVIDENCE ------------------------
	#
	# Verified AFTER the retest, so the cheap check fails first and the
	# expensive worktree is only built for a record that is otherwise good.
	local _sym_supplied=0
	[ -n "$symptom_cmd$symptom_baseline_rc$symptom_fixed_rc$baseline_ref" ] && _sym_supplied=1

	# REQUIRED for the population whose cost operators already accept:
	# cycle-critical citations (the same set the critical-path retest rule
	# targets) and --source=issue, which is issue-driven bug work — the
	# case where "did the reported symptom go away" is the whole question.
	#
	# Deliberately NOT required everywhere. AGENTS.md records a phase-1
	# deadlock that "pressured the operator into fabricating review records
	# — the exact dishonesty the gate exists to prevent". A gate that fires
	# on every fix gets skipped on every fix, and a skipped gate proves
	# less than an optional one that is usually supplied.
	local _sym_required=0
	[ "$src" = "issue" ] && _sym_required=1
	if [ "$_crit_required" = "1" ]; then _sym_required=1; fi

	if [ "$_sym_required" = "1" ] && [ "$_sym_supplied" = "0" ]; then
		echo "error: --symptom-cmd/--symptom-baseline-rc/--symptom-fixed-rc are REQUIRED for source=issue and for cycle-critical citations (#2643)." >&2
		echo "  A retest proves the suite passes WITH the fix. It does not prove it would have FAILED without it, so it cannot distinguish a fix from a no-op." >&2
		echo "  Supply a command that exhibits the reported symptom, the rc it gives WITHOUT the fix, and the rc it gives WITH it. They must differ." >&2
		exit 2
	fi

	if [ "$_sym_supplied" = "1" ]; then
		[ -n "$symptom_cmd" ] || {
			echo "error: --symptom-baseline-rc/--symptom-fixed-rc/--baseline-ref given without --symptom-cmd (#2643)" >&2
			exit 2
		}
		case "$symptom_baseline_rc" in '' | *[!0-9]*)
			echo "error: --symptom-baseline-rc must be a non-negative integer (got '$symptom_baseline_rc') (#2643)" >&2
			exit 2
			;;
		esac
		case "$symptom_fixed_rc" in '' | *[!0-9]*)
			echo "error: --symptom-fixed-rc must be a non-negative integer (got '$symptom_fixed_rc') (#2643)" >&2
			exit 2
			;;
		esac
		# THE CLAIM IS A DIFFERENCE. Equal rcs describe a command whose
		# behaviour the fix did not change — `--symptom-cmd true` with both
		# 0 is the pre-#2562 "trust me" hole reopening in a new field.
		if [ "$symptom_baseline_rc" = "$symptom_fixed_rc" ]; then
			echo "error: --symptom-baseline-rc and --symptom-fixed-rc are BOTH $symptom_baseline_rc — that is not evidence of a fix, it is a command the fix did not affect (#2643)" >&2
			exit 2
		fi

		# Which tree is the baseline? Default HEAD, because the cycle order
		# is fix -> record-fix -> commit and the fix is still uncommitted.
		local _sym_ref="${baseline_ref:-HEAD}"
		# p1-bypass (VERIFIED conf 10): this guard used to run only when
		# `baseline_ref` was EMPTY — but the default it falls back to is
		# HEAD, so spelling `--baseline-ref HEAD` produced the identical
		# baseline while skipping the check. A record with no fix at all
		# was accepted on a clean tree. What matters is which COMMIT the
		# baseline resolves to, not whether the operator typed it, so ask
		# git: any ref that resolves to HEAD gets the guard.
		local _sym_ref_sha _head_sha _sym_same_as_head=0
		_sym_ref_sha=$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${_sym_ref}^{commit}" 2>/dev/null) || _sym_ref_sha=""
		_head_sha=$(git -C "$REPO_ROOT" rev-parse --verify --quiet "HEAD^{commit}" 2>/dev/null) || _head_sha=""
		if [ -z "$_sym_ref_sha" ]; then
			echo "error: --baseline-ref '$_sym_ref' does not resolve to a commit — refusing the record rather than accepting one-sided evidence from the fixed half alone (#2643)" >&2
			exit 2
		fi
		if [ -n "$_head_sha" ] && [ "$_sym_ref_sha" = "$_head_sha" ]; then
			_sym_same_as_head=1
		fi
		if [ "$_sym_same_as_head" -eq 1 ]; then
			# If nothing cited actually differs from HEAD, the fix is
			# already committed and HEAD is NOT the pre-fix tree — the
			# baseline would silently re-run the fixed code and the whole
			# experiment would be a tautology. Refuse WITH the remedy.
			# `git status --porcelain` answers "does this path differ from
			# HEAD in any way" directly — modified, staged, or untracked —
			# in ONE call. The first version reconstructed that from two
			# (`ls-files --error-unmatch` then `diff --quiet`), which is
			# re-deriving a classification git already publishes, and it
			# got the untracked case wrong on the first attempt precisely
			# because the reconstruction had a gap.
			local _sym_dirty=0 _cf _st _st_rc=0
			for _cf in $cited_files; do
				_st=$(git -C "$REPO_ROOT" status --porcelain -- "$_cf" 2>/dev/null) || _st_rc=$?
				if [ "$_st_rc" -ne 0 ]; then
					echo "error: could not ask git about '$_cf' (rc=$_st_rc) — refusing rather than guessing whether HEAD is the pre-fix tree" >&2
					exit 2
				fi
				if [ -n "$_st" ]; then
					_sym_dirty=1
					break
				fi
			done
			if [ "$_sym_dirty" = "0" ]; then
				if [ -z "$cited_files" ]; then
					# Nothing was cited at all, so "no cited file differs"
					# is vacuously true and the --baseline-ref remedy
					# misdiagnoses it. Say what is actually missing.
					echo "error: no --cited-files were given, so there is nothing to check against ${_sym_ref} and the baseline cannot be shown to be the pre-fix tree (#2643)." >&2
					echo '  Cite the files the fix changed: --cited-files "path1 path2"' >&2
					echo "  If the fix is already committed, also name the commit before it: --baseline-ref <sha>" >&2
					exit 2
				fi
				echo "error: no cited file differs from ${_sym_ref}, so ${_sym_ref} is not the pre-fix tree and the baseline would re-run the FIXED code — a tautology, not evidence (#2643)." >&2
				echo "  If the fix is already committed, name the commit before it: --baseline-ref <sha>" >&2
				exit 2
			fi
		fi

		# Name the variable the bad value ACTUALLY came from. This read the
		# raw env of whichever var won and then blamed PROVE_BASELINE_TIMEOUT
		# regardless, so a typo in PROVE_RETEST_TIMEOUT sent the operator to
		# check a variable they had not set (p1-docs, verified).
		local _sym_tmo _sym_tmo_var
		if [ -n "${PROVE_BASELINE_TIMEOUT:-}" ]; then
			_sym_tmo="$PROVE_BASELINE_TIMEOUT"
			_sym_tmo_var="PROVE_BASELINE_TIMEOUT"
		elif [ -n "${PROVE_RETEST_TIMEOUT:-}" ]; then
			_sym_tmo="$PROVE_RETEST_TIMEOUT"
			_sym_tmo_var="PROVE_RETEST_TIMEOUT"
		else
			_sym_tmo=120
			_sym_tmo_var="PROVE_BASELINE_TIMEOUT"
		fi
		# `00` and `000` passed the old `| 0)` arm and GNU `timeout 00` means
		# NO DEADLINE — so a two-character typo silently removed the only
		# backstop on a hanging baseline, and removed it right where the
		# rc-124 guard needs a real deadline to compare against. The retest
		# path already required ^[1-9][0-9]*$; match it (p1-correct, verified).
		case "$_sym_tmo" in
		'' | *[!0-9]*)
			echo "WARN: symptom timeout: $_sym_tmo_var='$_sym_tmo' is not a positive integer — using 120" >&2
			_sym_tmo=120
			;;
		*)
			# All-digits, but reject all-zero forms: 0, 00, 000.
			case "$_sym_tmo" in *[!0]*) ;; *)
				echo "WARN: symptom timeout: $_sym_tmo_var='$_sym_tmo' means NO DEADLINE to timeout(1), which would let a hang stand in for evidence — using 120" >&2
				_sym_tmo=120
				;;
			esac
			;;
		esac

		# --- the FIXED half, in the live tree -------------------------
		echo "record-fix: re-executing symptom evidence (fixed tree, timeout ${_sym_tmo}s): $symptom_cmd" >&2
		# OUTPUT IS CAPTURED. The retest path prints a `last output:` tail on
		# a mismatch and this one printed nothing — so the operator learned
		# the rc was wrong and had no way to see why, on the half that is
		# hardest to reason about.
		local _sym_fixed_actual=0 _sym_out _sym_ft0 _sym_fixed_elapsed=0
		_sym_out=$(mktemp) || {
			echo "error: mktemp failed for symptom output capture" >&2
			exit 1
		}
		_sym_ft0=$SECONDS
		# A MISSING `timeout` BINARY IS NOT A DECISION. The retest path
		# refuses it and lets only the explicit opt-out run unbounded; this
		# treated both the same and merely warned, so a machine without
		# coreutils quietly lost the deadline the rc-124 guard compares
		# against. Opt-out stays permitted, and says so.
		if [ "${PROVE_RETEST_NO_TIMEOUT:-0}" = "1" ]; then
			echo "record-fix: WARN: symptom runs are UNBOUNDED by explicit PROVE_RETEST_NO_TIMEOUT=1 — a hang will not be killed (#2643)" >&2
			(cd "$REPO_ROOT" && bash -c "$symptom_cmd") >"$_sym_out" 2>&1 || _sym_fixed_actual=$?
		elif command -v timeout >/dev/null 2>&1; then
			(cd "$REPO_ROOT" && timeout "$_sym_tmo" bash -c "$symptom_cmd") >"$_sym_out" 2>&1 || _sym_fixed_actual=$?
		else
			rm -f "$_sym_out"
			echo "error: no timeout binary on PATH — refusing to run symptom evidence UNBOUNDED (install coreutils, or set PROVE_RETEST_NO_TIMEOUT=1 to explicitly accept an unenforced deadline) (#2643)" >&2
			exit 2
		fi
		_sym_fixed_elapsed=$((SECONDS - _sym_ft0))
		# Same deadline-launder refusal as the baseline half below.
		if [ "$_sym_fixed_actual" -eq 124 ] && [ "$_sym_fixed_elapsed" -ge "$_sym_tmo" ]; then
			rm -f "$_sym_out"
			echo "error: the fixed-tree symptom run hit the deadline (${_sym_fixed_elapsed}s >= ${_sym_tmo}s) — a deadline kill is never valid evidence, regardless of the claimed rc (#2643)" >&2
			exit 1
		fi
		if [ "$_sym_fixed_actual" -ne "$symptom_fixed_rc" ]; then
			echo "error: SYMPTOM MISMATCH (fixed tree) — the command exited rc=$_sym_fixed_actual but --symptom-fixed-rc claims $symptom_fixed_rc (#2643)." >&2
			echo "  last output:" >&2
			tail -c 400 "$_sym_out" | sed 's/^/    /' >&2 || true
			rm -f "$_sym_out"
			echo "  If this is flaky rather than wrong, say so in the fix summary and re-run; a flake that changes the rc makes the evidence unreliable, not merely inconvenient." >&2
			exit 1
		fi
		rm -f "$_sym_out"

		# --- the BASELINE half, in a detached worktree ----------------
		echo "record-fix: re-executing symptom evidence (baseline worktree at ${_sym_ref}): $symptom_cmd" >&2
		local _sym_base_actual _sym_base_out
		# Fail the same way the sibling capture does. Falling back to
		# /dev/null meant a mismatch on the baseline half printed an empty
		# tail and looked like a command that produced no output — the one
		# case where the operator most needs to see what happened.
		_sym_base_out=$(mktemp) || {
			echo "error: mktemp failed for baseline symptom output capture" >&2
			exit 1
		}

		local _sym_base_pair _sym_base_elapsed
		_sym_base_pair=$(_prove_symptom_run_baseline "$_sym_ref" "$symptom_cmd" "$_sym_tmo" "$_sym_base_out") || {
			rm -f "$_sym_base_out"
			echo "error: could not run the baseline half — refusing the record rather than accepting one-sided evidence (#2643)" >&2
			exit 1
		}
		_sym_base_actual=$(printf '%s\n' "$_sym_base_pair" | sed -n '1p')
		_sym_base_elapsed=$(printf '%s\n' "$_sym_base_pair" | sed -n '2p')
		[ -n "$_sym_base_elapsed" ] || _sym_base_elapsed=0
		# p1-bypass (VERIFIED conf 10): our own deadline kill is not the
		# bug. `--symptom-cmd 'test -f marker || sleep 300'
		# --symptom-baseline-rc 124` let the wrapper's SIGTERM play the
		# part of "fails without the fix" — the same laundering #2562
		# closed on the retest side, reopened in a new field. Distinguish
		# our kill from a child's own fast inner timeout by elapsed time.
		if [ "$_sym_base_actual" -eq 124 ] && [ "$_sym_base_elapsed" -ge "$_sym_tmo" ]; then
			rm -f "$_sym_base_out"
			echo "error: the baseline hit the PROVE_BASELINE_TIMEOUT deadline (${_sym_base_elapsed}s >= ${_sym_tmo}s) — a deadline kill is never valid evidence, regardless of the claimed rc; raise PROVE_BASELINE_TIMEOUT if the evidence genuinely needs longer (#2643)" >&2
			exit 1
		fi
		if [ "$_sym_base_actual" -ne "$symptom_baseline_rc" ]; then
			echo "error: SYMPTOM MISMATCH (baseline at ${_sym_ref}) — the command exited rc=$_sym_base_actual but --symptom-baseline-rc claims $symptom_baseline_rc (#2643)." >&2
			echo "  The baseline runs ${_sym_ref}'s production code with THIS tree's .bats files (tracked AND untracked) copied in, so a new test can detect the old bug." >&2
			echo "  last output:" >&2
			tail -c 400 "$_sym_base_out" | sed 's/^/    /' >&2 || true
			echo "  If the numbers disagree because the command is flaky, that is a reason to distrust the evidence, not to retry until it agrees." >&2
			rm -f "$_sym_base_out"
			exit 1
		fi
		rm -f "$_sym_base_out"

		# ABSENCE-SHAPED FAILURE. If the fix ADDS a file, the baseline
		# exits 127 ("command not found") and looks exactly like "fails
		# without the fix" — while proving only that the file is new.
		if [ "$_sym_base_actual" -eq 127 ] && [ "$allow_absence_baseline" != "1" ]; then
			echo "error: the baseline exited 127 (command not found), which is what a fix that ADDS a file produces — it looks like proof and is not (#2643)." >&2
			echo "  If 127 genuinely IS the reported symptom, say so with --allow-absence-baseline. Otherwise choose a symptom command that exists at ${_sym_ref}." >&2
			exit 1
		fi
		echo "record-fix: symptom differential CONFIRMED — ${_sym_base_actual} without the fix, ${_sym_fixed_actual} with it" >&2
	fi

	local ts state_file
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	state_file=$(_state_file_for_finding "$finding_id")

	# v4.28-W3-C (#671): cited_files JSON for cache_evidence_stale.
	local cited_json
	cited_json=$(_cited_files_json "$cited_files")

	if [ -z "$cluster_id" ]; then
		_jaccard_advise "$finding_text"
	fi

	# v4.28-W4 #723: confidence may be empty when source=cr (uses
	# severity instead); the `${confidence:-null}` inline default
	# coerces to literal "null" for jq while keeping a numeric value
	# pass-through. The format-validator above guarantees non-empty
	# values are 1-10 integers, so jq --argjson always parses cleanly.
	jq -n \
		--arg fid "$finding_id" \
		--arg ts "$ts" \
		--arg ftext "$finding_text" \
		--arg summary "$fix_summary" \
		--arg symcmd "$symptom_cmd" \
		--argjson symbase "${symptom_baseline_rc:-null}" \
		--argjson symfixed "${symptom_fixed_rc:-null}" \
		--arg symref "${baseline_ref:-}" \
		--arg symrefeff "${_sym_ref:-}" \
		--argjson symabsence "$([ "$allow_absence_baseline" = "1" ] && echo true || echo false)" \
		--arg cmd "$retest_cmd" \
		--argjson rc "$retest_rc" \
		--argjson cited "$cited_json" \
		--argjson covers "$covers_count" \
		--argjson conf "${confidence:-null}" \
		--arg sev "${severity:-}" \
		--arg cluster "$cluster_id" \
		--arg src "${src:-}" \
		--argjson actual "$_retest_actual_rc" \
		--arg rtail "$_retest_tail" \
		--argjson blpresent "$_bl_present" \
		--argjson blrc "${_bl_rc:-null}" \
		--arg blts "$_bl_ts" \
		--arg blsha "$_bl_sha" \
		--arg bltail "$_bl_tail" \
		--arg blnote "$_bl_note" \
		'{finding_id: $fid, kind: "fix", finding_text: $ftext, ts: $ts,
		  covers_count: $covers, confidence: $conf,
		  severity: (if $sev == "" then null else $sev end),
		  source: (if $src == "" then null else $src end),
		  cluster_id: (if $cluster == "" then null else $cluster end),
		  cited_files: $cited,
		  decision_data: {fix_summary: $summary, retest_cmd: $cmd, retest_rc: $rc,
		                  retest_verified: true, retest_actual_rc: $actual,
		                  baseline_verified: $blpresent, baseline_rc: $blrc,
		                  baseline_ts: (if $blts == "" then null else $blts end),
		                  baseline_sha: (if $blsha == "" then null else $blsha end),
		                  baseline_output_tail: (if $bltail == "" then null else $bltail end),
		                  baseline_note: (if $blnote == "" then null else $blnote end),
		                  symptom_cmd: $symcmd, symptom_baseline_rc: $symbase,
		                  symptom_fixed_rc: $symfixed, symptom_baseline_ref: $symref,
		                  symptom_baseline_ref_effective: (if $symrefeff == "" then null else $symrefeff end),
		                  symptom_allow_absence_baseline: $symabsence,
		                  symptom_verified: ($symcmd != ""),
		                  retest_output_tail: $rtail}}' >"$state_file"

	if [ "$_bl_present" = true ]; then
		echo "record-fix: before/after pair CONFIRMED — baseline rc=$_bl_rc (captured $_bl_ts at ${_bl_sha:0:7}), post-fix rc=$_retest_actual_rc" >&2
		# Consume the baseline (phase1 lifecycle): its evidence now lives
		# in the durable record; leaving the file re-stamps stale proof
		# onto future records for a reused finding-id (or hard-refuses
		# them on BASELINE MISMATCH). Removal failure is loud but not
		# fatal — the record is already written and correct.
		rm -f "$_bl_file" ||
			echo "WARN: could not remove consumed baseline $_bl_file — a future record-fix for this finding-id will trip over it" >&2
	fi

	# Record per-cited-file cache entries under reviewer "prove-yourself-fix".
	_record_cite_cache "prove-yourself-fix" "$cited_files"

	# v4.28-W4 (#710): append summary to tracked audit log.
	# CR-CI fix: propagate failure (mirror record-rejection branch).
	# (#2643) Hand the validated ancestor sha to the ledger writer as an
	# argument — see the note on $10 there for why not an env var.
	if ! _append_tracked_audit "fix" "$finding_id" "${src:-}" "${severity:-}" "${confidence:-}" "$finding_text" "$state_file" "$cluster_id" "$covers_count" "$_cov_sha"; then
		echo "ERROR: tracked audit append failed for $finding_id (state file at $state_file is intact, but audit log is missing this record)" >&2
		exit 1
	fi

	echo "✓ Recorded fix: $finding_id"
	echo "  $state_file"
}

cmd_audit() {
	local rejections=0 fixes=0 malformed=0
	local errs=()

	# CR review #656: don't treat fs errors as "no records" — fail-opens
	# the check-commit gate when the state directory is unreadable. Validate
	# the directory exists+is readable, THEN check via safe glob.
	if [ ! -d "$STATE_DIR" ]; then
		echo "error: state directory $STATE_DIR not present" >&2
		return 2
	fi
	if [ ! -r "$STATE_DIR" ] || [ ! -x "$STATE_DIR" ]; then
		echo "error: state directory $STATE_DIR not readable" >&2
		return 2
	fi
	local _state_files=("$STATE_DIR"/*.json)
	if [ ! -e "${_state_files[0]}" ]; then
		echo "No prove-yourself records this session."
		return 0
	fi

	local f kind val field
	for f in "$STATE_DIR"/*.json; do
		[ -f "$f" ] || continue
		# Validate JSON parseability.
		if ! jq empty "$f" 2>/dev/null; then
			malformed=$((malformed + 1))
			errs+=("$f: malformed JSON")
			continue
		fi
		kind=$(jq -r '.kind // "unknown"' "$f")
		case "$kind" in
		rejection)
			rejections=$((rejections + 1))
			# Required fields for rejection records.
			for field in finding_id finding_text decision_data.dogfood_cmd \
				decision_data.dogfood_output decision_data.external_authority \
				decision_data.reason; do
				val=$(jq -r ".${field} // \"\"" "$f")
				if [ -z "$val" ]; then
					errs+=("$f: missing required field .${field}")
				fi
			done
			# RC field validation — must be present and numeric.
			val=$(jq -r '.decision_data.dogfood_rc // ""' "$f")
			if [ -z "$val" ]; then
				errs+=("$f: missing required field .decision_data.dogfood_rc")
			elif ! [[ $val =~ ^[0-9]+$ ]]; then
				errs+=("$f: .decision_data.dogfood_rc must be numeric integer (got: $val)")
			fi
			;;
		fix)
			fixes=$((fixes + 1))
			for field in finding_id finding_text decision_data.fix_summary \
				decision_data.retest_cmd; do
				val=$(jq -r ".${field} // \"\"" "$f")
				if [ -z "$val" ]; then
					errs+=("$f: missing required field .${field}")
				fi
			done
			# RC field validation — must be present and numeric.
			val=$(jq -r '.decision_data.retest_rc // ""' "$f")
			if [ -z "$val" ]; then
				errs+=("$f: missing required field .decision_data.retest_rc")
			elif ! [[ $val =~ ^[0-9]+$ ]]; then
				errs+=("$f: .decision_data.retest_rc must be numeric integer (got: $val)")
			fi
			# #2562: record-time re-execution stamp. A fix record without
			# retest_verified:true was hand-forged or written by a
			# pre-#2562 recorder; either way the evidence was never RUN
			# by the recorder — re-record via run.sh record-fix.
			val=$(jq -r '.decision_data.retest_verified // ""' "$f")
			if [ "$val" != "true" ]; then
				errs+=("$f: fix record lacks .decision_data.retest_verified:true — re-record via run.sh record-fix (the recorder re-executes the retest; #2562)")
			fi
			val=$(jq -r '.decision_data.retest_actual_rc // ""' "$f")
			if [ -z "$val" ]; then
				errs+=("$f: missing required field .decision_data.retest_actual_rc")
			elif ! [[ $val =~ ^[0-9]+$ ]]; then
				errs+=("$f: .decision_data.retest_actual_rc must be numeric integer (got: $val)")
			fi
			;;
		*)
			malformed=$((malformed + 1))
			errs+=("$f: unknown kind '$kind'")
			;;
		esac
	done

	# Fixes with no verified symptom differential. Counted from the same
	# record set the tallies above walk.
	# p1-bypass (VERIFIED conf 10): DO NOT TRUST `symptom_verified` ALONE.
	# It is a boolean this script writes, so a hand-written record carrying
	# `"symptom_verified": true` and no symptom fields at all read as proven
	# and drove the counter to 0. A self-declared flag is exactly the free
	# text this feature replaces, so the count is derived from the evidence
	# fields instead: the flag AND a command AND two rcs that actually
	# differ. Anything short of that is unproven, whatever the flag says.
	# ONE pass, and ONE jq per record. The first version walked the same
	# glob a second time and spent five more jq processes per file — on
	# every commit, since the pre-commit gate runs check-commit. The four
	# fields come back as one tab-separated line.
	local unproven=0 _af _fields _sv _scmd _sb _sf
	for _af in "$STATE_DIR"/*.json; do
		[ -f "$_af" ] || continue
		# NO EMPTY FIELDS and NO FREE TEXT. Tab is IFS whitespace, so
		# `IFS=<tab> read` collapses runs of tabs and drops leading and
		# trailing ones: five fields with an empty one in the middle
		# arrived as three. The old read still counted correctly only
		# because the shift was leftward — right by accident.
		#
		# So: every field is a scalar that can never be empty (missing
		# becomes "-"), and symptom_cmd is reduced to a BOOLEAN here since
		# only its presence matters. That also removes the one field that
		# could contain a tab or a newline of its own.
		# TYPES AND RANGES ARE CHECKED IN JQ, not just presence. An exit
		# code is a NON-NEGATIVE INTEGER: -1 and 0.5 are jq numbers, they
		# differ from 0, and they sailed through the presence-and-inequality
		# tests while describing something no process can return. A forged record with
		# `"symptom_verified": "true"` (a string), a symptom_cmd that is an
		# object, and rcs of "bad-a" / "bad-b" — which differ, so the
		# not-equal test passed — counted as PROVEN. Each field is
		# normalised to "-" unless it has the right type.
		_fields=$(jq -r '
			[ (.kind // "-"),
			  (if (.decision_data.symptom_verified) == true then "true" else "-" end),
			  (if (.decision_data.symptom_cmd | type) == "string"
			      and ((.decision_data.symptom_cmd | length) > 0) then "true" else "-" end),
			  (if (.decision_data.symptom_baseline_rc | type) == "number"
			      and (.decision_data.symptom_baseline_rc >= 0)
			      and (.decision_data.symptom_baseline_rc <= 255)
			      and ((.decision_data.symptom_baseline_rc | floor) == .decision_data.symptom_baseline_rc)
			      then (.decision_data.symptom_baseline_rc | tostring) else "-" end),
			  (if (.decision_data.symptom_fixed_rc | type) == "number"
			      and (.decision_data.symptom_fixed_rc >= 0)
			      and (.decision_data.symptom_fixed_rc <= 255)
			      and ((.decision_data.symptom_fixed_rc | floor) == .decision_data.symptom_fixed_rc)
			      then (.decision_data.symptom_fixed_rc | tostring) else "-" end)
			] | @tsv' "$_af" 2>/dev/null) || continue
		IFS=$(printf '\t') read -r _kind _sv _scmd _sb _sf <<EOF
$_fields
EOF
		[ "$_kind" = "fix" ] || continue
		if [ "$_sv" = "true" ] && [ "$_scmd" = "true" ] &&
			[ "$_sb" != "-" ] && [ "$_sf" != "-" ] && [ "$_sb" != "$_sf" ]; then
			continue
		fi
		unproven=$((unproven + 1))
	done
	echo "Prove-yourself audit:"
	echo "  Rejections recorded: $rejections"
	echo "  Fixes recorded:      $fixes"
	# (#2643) A VISIBLE NUMBER, not a block. Differential symptom evidence
	# is required for source=issue and cycle-critical citations; everywhere
	# else it is accepted and verified when present. Counting the fixes
	# that carry no such evidence makes the gap legible without turning
	# every fix into a gate — AGENTS.md records a phase-1 deadlock that
	# "pressured the operator into fabricating review records", and a gate
	# that fires on everything gets skipped on everything.
	echo "  ...unproven (no symptom differential): $unproven"
	echo "  Malformed records:   $malformed"
	if [ "${#errs[@]}" -gt 0 ]; then
		echo "" >&2
		echo "Errors:" >&2
		local e
		for e in "${errs[@]}"; do
			echo "  - $e" >&2
		done
		return 1
	fi
	return 0
}

# v4.28-W4 #851 r1: relocated from inside dispatch block to top-level
# function area for consistency with the other cmd_* functions. Pure
# structural move — no logic changes.
cmd_cluster_list() {
	# v4.28-W3-C: visualize records grouped by cluster_id. No mutations.
	[ -d "$STATE_DIR" ] || {
		echo "no records — state dir missing: $STATE_DIR" >&2
		return 0
	}
	# Group by cluster_id; print each cluster's records + uncategorized.
	# Surface jq parsing errors so operators know when a record is malformed
	# instead of silently emitting empty output.
	local jq_out jq_rc=0
	jq_out=$(find "$STATE_DIR" -name '*.json' -exec cat {} \; 2>/dev/null |
		jq -s '
			group_by(.cluster_id // "uncategorized") |
			map({
				cluster: (.[0].cluster_id // "uncategorized"),
				count: length,
				total_covers: (map(.covers_count // 1) | add),
				records: map({id: .finding_id, conf: .confidence, kind: .kind, text: (.finding_text // "" | .[0:80])})
			})
		' 2>&1) || jq_rc=$?
	if [ "$jq_rc" -ne 0 ]; then
		echo "cluster-list: jq failed (malformed record?): $jq_out" >&2
		return 1
	fi
	printf '%s\n' "$jq_out"
}

cmd_check_commit() {
	# Pre-commit gate. Same as audit but more verbose on failure.
	if cmd_audit; then
		return 0
	fi
	echo "" >&2
	echo "BLOCK: prove-yourself records have malformed/missing evidence." >&2
	echo "Fix the records or remove them under .claude/.session-state/prove-yourself/" >&2
	echo "Bypass: PROVE_YOURSELF_GATE_SKIP=1 git commit ... (audit-logged)" >&2
	return 1
}

# Reset state — useful for tests + post-merge cleanup.
cmd_reset() {
	# Guarded rm — STATE_DIR was set unconditionally above; here we double-
	# check to refuse if it's empty or root, so we cannot recurse from /
	# even if a future refactor breaks the upstream assignment. (Avoid
	# the literal "<rm -spaceFlag>rf /" wording in this comment — semgrep
	# pattern-matches on comments too, generating false positives on
	# every Edit to this file.)
	if [ -z "${STATE_DIR:-}" ] || [ "$STATE_DIR" = "/" ]; then
		echo "error: STATE_DIR not set or unsafe" >&2
		exit 2
	fi
	# CR review #656: rm failures must propagate. Swallowing them gave
	# tests + post-merge cleanup a false green while stale records persisted.
	local rc=0 f
	for f in "${STATE_DIR:?}"/*.json; do
		[ -e "$f" ] || continue
		rm -f -- "$f" || rc=1
	done
	# (#2652 phase1 lifecycle): un-consumed baselines are as stale as the
	# records after a merge — the sibling store resets with the main one.
	if [ -n "${BASELINE_DIR:-}" ] && [ "$BASELINE_DIR" != "/" ]; then
		for f in "${BASELINE_DIR:?}"/*.json; do
			[ -e "$f" ] || continue
			rm -f -- "$f" || rc=1
		done
	fi
	if [ "$rc" -ne 0 ]; then
		echo "error: failed to reset prove-yourself state" >&2
		exit 1
	fi
	echo "✓ Reset prove-yourself state"
}

# ----- dispatch -----

if [ $# -lt 1 ]; then
	print_help
	exit 0
fi

SUBCMD=$1
shift

# v4.28-W4 (#710): tracked audit-log helper + search subcommand.
# State-file (in $STATE_DIR) is gitignored per-session detail; audit
# log (in $AUDIT_DIR/prove-yourself.jsonl) is tracked + persists.
_append_tracked_audit() {
	# args: kind finding_id source severity confidence finding_text state_file [cluster_id] [covers_count]
	# v4.28-W5 #855 fix: 8th arg cluster_id (optional) — propagated to the
	# tracked audit log so phase0.5-dedupe-against-audit.sh can suppress
	# already-handled clusters by cluster_id (not just description-text
	# substring, which breaks when agents reword across rounds).
	local kind="$1" fid="$2" src="$3" sev="$4" conf="$5" ftext="$6" sfile="$7"
	# $10 (optional): an ALREADY-VALIDATED covered sha from record-fix's
	# --covered-sha. It arrives as a parameter, never through the ambient
	# environment: the first version exported PROVE_COVERED_SHA, and since
	# this writer read `${PROVE_COVERED_SHA:-}` verbatim, anything in the
	# caller's env stamped an arbitrary covered_sha on a fix OR a rejection
	# — opening the phase1, cr and ship-cycle coverage gates with a value
	# that had passed no ancestor check at all. Two phase-1 agents flagged
	# it independently. A parameter cannot be inherited.
	local covered_sha_in="${10:-}"
	local cluster="${8:-}"
	# v0.32.7 (#238): 9th arg covers_count MUST reach the tracked audit log —
	# the pre-push-gate's CR-coverage query (and ship-pr-cycle's phase2 cap, via
	# the shared _lib/cr-phase2-coverage.sh) sums `.covers_count` per record.
	# Without writing it here it was always null → the gate defaulted each
	# record to 1, so a `--covers-count N` (N>1) was silently dropped (one
	# record covered only 1 finding). Fail-safe to 1 on missing/non-numeric.
	local covers="${9:-1}"
	[[ $covers =~ ^[1-9][0-9]*$ ]] || covers=1
	# r2 fix: declare jq_err local so the tempfile path doesn't leak into
	# caller scope (cmd_record_rejection / cmd_record_fix). Without
	# `local`, a caller already using $jq_err would have its path
	# silently overwritten by mktemp here; after our `rm -f` fires, the
	# caller's later read of $jq_err would point at a deleted path.
	local ts ftext_hash jq_err sfile_rel
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	# CR r1 minor: store evidence_path relative to repo root rather than
	# absolute. Absolute paths leak the operator's username and break
	# portability across clones. Strip "$REPO_ROOT/" prefix; fall back
	# to the original (defensive) if sfile somehow doesn't start with it.
	case "$sfile" in
	"$REPO_ROOT"/*) sfile_rel="${sfile#"$REPO_ROOT"/}" ;;
	*) sfile_rel="$sfile" ;;
	esac
	# CR-CI fix: fail closed on mkdir failure. Prior `return 0` printed
	# "✓ Recorded" to caller despite losing the persistent audit entry —
	# defeats #710's whole point of cross-PR persistence. Caller should
	# see the failure and fix (chmod the dir, or override).
	mkdir_err=$(mktemp 2>/dev/null) || mkdir_err=/dev/null
	if ! mkdir -p "$AUDIT_DIR" 2>"$mkdir_err"; then
		if [ "$mkdir_err" != /dev/null ]; then
			echo "prove-yourself-audit: ERROR: cannot create $AUDIT_DIR: $(head -c 200 "$mkdir_err")" >&2
		else
			echo "prove-yourself-audit: ERROR: cannot create $AUDIT_DIR (mktemp also failed; stderr unavailable)" >&2
		fi
		[ "$mkdir_err" != /dev/null ] && rm -f "$mkdir_err"
		return 1
	fi
	[ "$mkdir_err" != /dev/null ] && rm -f "$mkdir_err"
	ftext_hash=$(printf '%s' "$ftext" | shasum -a 256 2>/dev/null | awk '{print $1}')
	[ -z "$ftext_hash" ] && ftext_hash=$(printf '%s' "$ftext" | sha256sum 2>/dev/null | awk '{print $1}')
	# r1 SFH #1 fix: WARN if both hashers failed — empty hash silently
	# breaks future search/dedup queries on finding_text_hash.
	[ -z "$ftext_hash" ] && echo "prove-yourself-audit: WARN: no shasum/sha256sum available — finding_text_hash will be empty in audit log" >&2
	# r1 SFH #2 fix: capture jq stderr in a tempfile so the WARN can
	# include actionable detail (jq parse error, disk full, perms).
	# CR r2 minor: mktemp fallback to /dev/null mirrors phase0.5 fix —
	# without it, an empty $jq_err yields `2>""` ambiguous-redirect that
	# aborts under set -e. Same scenario as phase0.5: TMPDIR-full +
	# audit-dir-unwriteable usually share a disk.
	# v0.8.1 (#54): always populate severity. When source uses confidence
	# (phase0.5/phase1), derive severity from confidence so the field is
	# never null in the tracked audit log. Mapping:
	#   conf >= 8 → high     (confidence floor for actionable findings)
	#   conf 4-7  → medium   (borderline / investigate)
	#   conf < 4  → low      (speculative / suppress)
	# This makes the audit log self-describing — downstream tools (CR-in-CI,
	# external auditors, traceability reports) can rely on severity without
	# needing to know the per-source field convention.
	#
	# evidence_path is intentionally a pointer into session-state (gitignored
	# transient storage) — the audit entry's finding_text + source + cluster
	# is the canonical record. We add evidence_persists=false so consumers
	# know the path is operational, not authoritative.
	# v0.8.3 (#33 CR fix): record covered_sha (current HEAD at write time)
	# so the pipeline-gate's CR-coverage query can scope by sha rather
	# than summing the whole audit history. Empty if not in a repo (e.g.
	# tests). Cannot use $REPO_ROOT here because some callers pre-set it
	# to a fixture dir; resolve from git directly for the current HEAD.
	local covered_sha
	if [ -n "$covered_sha_in" ]; then
		covered_sha="$covered_sha_in"
	else
		covered_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
	fi
	jq_err=$(mktemp 2>/dev/null) || jq_err=/dev/null
	if ! jq -nc \
		--arg ts "$ts" --arg kind "$kind" --arg fid "$fid" \
		--arg src "$src" --arg sev "$sev" --arg conf "$conf" \
		--arg ftext "$ftext" --arg ftext_hash "$ftext_hash" \
		--arg evidence "$sfile_rel" \
		--arg cluster "$cluster" \
		--arg csha "$covered_sha" \
		--argjson covers "$covers" \
		'{ts:$ts, kind:$kind, finding_id:$fid, source:$src,
		  severity: (if $sev != "" then $sev
		             elif $conf == "" then null
		             elif ($conf|tonumber) >= 8 then "high"
		             elif ($conf|tonumber) >= 4 then "medium"
		             else "low" end),
		  confidence: (if $conf == "" then null else ($conf|tonumber) end),
		  finding_text:$ftext, finding_text_hash:$ftext_hash,
		  cluster_id: (if $cluster == "" then null else $cluster end),
		  evidence_path:$evidence,
		  evidence_persists:false,
		  covers_count: $covers,
		  covered_sha: (if $csha == "" then null else $csha end)}' \
		>>"$AUDIT_FILE" 2>"$jq_err"; then
		# CR-CI fix: fail closed on append failure (was WARN+return 0).
		# Caller depends on the audit entry persisting; silent loss
		# breaks the cross-PR correlation #710 promises.
		if [ "$jq_err" != /dev/null ]; then
			echo "prove-yourself-audit: ERROR: failed to append to $AUDIT_FILE: $(head -c 200 "$jq_err")" >&2
		else
			echo "prove-yourself-audit: ERROR: failed to append to $AUDIT_FILE (mktemp also failed; stderr unavailable)" >&2
		fi
		[ "$jq_err" != /dev/null ] && rm -f "$jq_err"
		return 1
	fi
	[ "$jq_err" != /dev/null ] && rm -f "$jq_err"
}

cmd_search() {
	local text="" src="" kind="" limit=20
	local jq_err jq_rc=0
	# CR r1 minor: missing-arg guards for flags that consume $2.
	# Without these, `set -u` would emit a cryptic "unbound variable"
	# instead of a clear "missing value for --X" message. Same exit-2
	# semantics as the unknown-arg branch.
	while [ "$#" -gt 0 ]; do
		case "$1" in
		-h | --help)
			cat <<'HELP'
Usage: prove-yourself-audit search [OPTIONS]

Search the tracked audit log (.claude/audit/prove-yourself.jsonl).

Options:
  --text <substring>     Filter by case-insensitive substring of finding_text
  --source <name>        Filter by source (e.g. phase1, cr, phase0.5)
  --kind <fix|rejection> Filter by record kind
  --limit <N>            Cap result count (positive integer; default 20)
  -h, --help             Show this help and exit
HELP
			return 0
			;;
		--text)
			[ "$#" -lt 2 ] && {
				echo "search: missing value for --text" >&2
				exit 2
			}
			text="$2"
			shift 2
			;;
		--source)
			[ "$#" -lt 2 ] && {
				echo "search: missing value for --source" >&2
				exit 2
			}
			src="$2"
			shift 2
			;;
		--kind)
			[ "$#" -lt 2 ] && {
				echo "search: missing value for --kind" >&2
				exit 2
			}
			kind="$2"
			shift 2
			;;
		--limit)
			[ "$#" -lt 2 ] && {
				echo "search: missing value for --limit" >&2
				exit 2
			}
			limit="$2"
			# r2 SFH fix: validate --limit is numeric up front so a typo
			# (e.g. `--limit twenty`) gets a clear operator-facing error
			# instead of a confusing `tail: invalid number of lines`
			# message from a deep pipe stage.
			[[ $limit =~ ^[1-9][0-9]*$ ]] || {
				echo "search: --limit must be a positive integer; got '$limit'" >&2
				exit 2
			}
			shift 2
			;;
		*)
			echo "search: unknown arg: $1" >&2
			exit 2
			;;
		esac
	done
	if [ ! -f "$AUDIT_FILE" ]; then
		echo "search: no tracked audit log at $AUDIT_FILE — start fresh"
		return 0
	fi
	# r2 SFH fix: capture jq rc + stderr — the write side
	# (_append_tracked_audit) already does this; the read side must
	# too. Otherwise a malformed JSONL line (partial write from prior
	# crash, disk-full corruption) silently truncates results with no
	# operator-visible signal.
	# CR-CI fix: mktemp /dev/null fallback mirrors write side. Without
	# it, TMPDIR-full → empty $jq_err → `2>""` ambiguous-redirect →
	# set -e abort before the WARN can fire.
	jq_err=$(mktemp 2>/dev/null) || jq_err=/dev/null
	jq -r --arg t "$text" --arg s "$src" --arg k "$kind" '
		select(
			($t == "" or (.finding_text | ascii_downcase | contains($t | ascii_downcase))) and
			($s == "" or .source == $s) and
			($k == "" or .kind == $k)
		)
		| "\(.ts) [\(.kind) \(.source)\(if .severity then "/" + .severity else "" end)] \(.finding_id) — \(.finding_text[0:120])"
	' "$AUDIT_FILE" 2>"$jq_err" | tail -n "$limit" || jq_rc=$?
	# CR-CI fix: cmd_search is advisory — partial results are acceptable
	# (operator wants to find what records they have, not abort on
	# corruption). On jq failure, WARN to stderr but still return 0 so
	# the caller can act on whatever records DID parse. Callers needing
	# strict integrity should use `cmd_audit` (which fails closed).
	if [ "$jq_rc" -ne 0 ] || { [ "$jq_err" != /dev/null ] && [ -s "$jq_err" ]; }; then
		if [ "$jq_err" != /dev/null ]; then
			echo "prove-yourself-audit: WARN: search jq read failed (rc=$jq_rc) — results may be truncated: $(head -c 200 "$jq_err")" >&2
		else
			echo "prove-yourself-audit: WARN: search jq read failed (rc=$jq_rc; mktemp also failed; stderr unavailable)" >&2
		fi
	fi
	[ "$jq_err" != /dev/null ] && rm -f "$jq_err"
}

case "$SUBCMD" in
record-rejection) cmd_record_rejection "$@" ;;
record-fix) cmd_record_fix "$@" ;;
record-baseline) cmd_record_baseline "$@" ;;
audit) cmd_audit ;;
check-commit) cmd_check_commit ;;
reset) cmd_reset ;;
cluster-list) cmd_cluster_list ;;
search) cmd_search "$@" ;;
-h | --help)
	print_help
	exit 0
	;;
*)
	echo "error: unknown subcommand: $SUBCMD" >&2
	echo "Use one of: record-rejection, record-fix, record-baseline, audit, check-commit, reset, cluster-list, search" >&2
	exit 2
	;;
esac
