#!/usr/bin/env bash
set -u
# NB: sourced lib → `set -u` (nounset) ONLY, intentionally NOT `set -euo
# pipefail`. -e/-o pipefail would mutate the CALLERS' errexit (this is sourced
# into ship-pr-cycle.sh + the pre-push gate, both already -euo pipefail), and
# the functions here are explicitly fail-closed (every fallback is
# `|| echo <sentinel>` that the guards reject, plus explicit `return 0/1`).
# [#248 CR declined `set -euo pipefail` — sourced-lib convention.]
# v0.32.7 (#238): SSOT for "is this sha's Phase 2 CR-CLI review clean — or are
# all its findings ADDRESSED?". Sourced by BOTH:
#   - hooks/pre-push-pipeline-gate.sh  (the push gate)
#   - scripts/ship-pr-cycle.sh         (the Phase 2 round-cap advance decision)
# so the round-cap never advances to a push the gate will refuse, and the two
# never drift. Extracted verbatim from the gate's former `_cr_cli_clean_for_sha`
# (which was "local to this script") + made silent (callers emit their own
# messages) so it composes.
#
# cr_phase2_clean_for_sha <sha>
#   rc 0 = clean: latest CR-CLI run for the sha has findings=0, OR every finding
#                 is covered by source=cr prove-yourself records scoped to the
#                 sha (sum of .covers_count >= latest findings).
#   rc 1 = not clean / cannot determine.
# Fail-CLOSED: missing run-log, missing jq, non-numeric/absent findings, or
# missing audit log → rc 1 (never whitewash). REPO_ROOT honored if exported
# (tests pre-set it); else derived from git.

_cr_phase2_branch_graduation() {
	# #2545 (operator-flagged design bug): a fix commit necessarily orphans
	# its review's sha — the row lives under the REVIEWED commit, the fixes
	# land under a NEW one. With strictly sha-scoped evidence, a rejection
	# covered findings in place but a FIX could never satisfy the gate
	# without spending another review, so the enforced round cap turned the
	# normal terminal state (final in-budget round found trivia → you fixed
	# it) into a routine emergency override. GRADUATION closes that: HEAD
	# with NO row of its own is clean when the NEWEST branch review row
	# (BASE_BRANCH..HEAD — the same per-branch scope the round cap counts,
	# #2354) ITSELF satisfies the completeness rules AND its findings are
	# covered by branch-scoped prove-yourself records. Deliberately no
	# search backward for an older completed row (phase2 r3 pinned the
	# wording): a NEWER killed/partial run blocks graduation — the newest
	# evidence wins, incomplete newest evidence is refusal.
	# Positive evidence is still the rule: no branch row, a killed/partial
	# row, or an uncovered count all refuse exactly as before, and the
	# unreviewed fix-delta defers to the authoritative server-side CR-in-CI
	# (the same philosophy as ship-pr-cycle's timeout rc=4 defer).
	#
	# $1 = cr_log path, $2 = repo_root. All git calls anchor to $2 — the
	# caller's cwd is not trusted (bats fixtures run from the live repo).
	# Silent when it cannot graduate for structural reasons (no git, no
	# branch rows — the caller's refusal already narrates); loud on the one
	# actionable gap (candidate found, coverage short) and on success (an
	# ancestor-graduated push is a trust signal the operator should see).
	local cr_log="$1" repo_root="$2"
	local base="${BASE_BRANCH:-main}"
	local branch_shas
	branch_shas=$(git -C "$repo_root" rev-list "$base..HEAD" 2>/dev/null) || return 1
	[ -n "$branch_shas" ] || return 1
	local row
	row=$(jq -rs --arg shas "$branch_shas" '
		($shas | split("\n") | map(select(length > 0))) as $bs
		| [.[] | select((.sha // "") as $s | ($s | length > 0) and ($bs | any(startswith($s))))]
		| if length == 0 then empty else
		    (last as $l
		     | if ($l.complete // false) != true then empty
		       elif (($l | has("partial")) and ($l.partial != false))
		         or (($l | has("timeout")) and ($l.timeout != false)) then empty
		       elif ($l.findings | type) != "number" then empty
		       elif $l.findings < 0 then empty
		       else "\($l.sha)\t\($l.findings)" end)
		  end' "$cr_log" 2>/dev/null) || return 1
	[ -n "$row" ] || return 1
	local anc_sha="${row%%$'\t'*}" anc_findings="${row##*$'\t'}"
	case "$anc_findings" in
	'' | *[!0-9]*) return 1 ;;
	esac
	if [ "$anc_findings" = "0" ]; then
		echo "cr_phase2_clean_for_sha: HEAD has no review row — GRADUATED via branch ancestor $anc_sha (0 findings, complete); the fix-delta defers to CR-in-CI." >&2
		return 0
	fi
	local audit_log="$repo_root/.claude/audit/prove-yourself.jsonl"
	[ -f "$audit_log" ] || return 1
	local covered
	covered=$(jq -rs --arg shas "$branch_shas" '
		($shas | split("\n") | map(select(length > 0))) as $bs
		| [.[] | select(.source == "cr")
		       | select((.covered_sha // "") as $c | ($c | length > 0) and ($bs | any(startswith($c))))]
		| map(.covers_count // 1) | add // 0' "$audit_log" 2>/dev/null || echo 0)
	case "$covered" in
	'' | *[!0-9]*) return 1 ;;
	esac
	if [ "$covered" -ge "$anc_findings" ]; then
		echo "cr_phase2_clean_for_sha: HEAD has no review row — GRADUATED via branch ancestor $anc_sha ($anc_findings finding(s), covered $covered by branch-scoped prove-yourself records); the fix-delta defers to CR-in-CI." >&2
		return 0
	fi
	echo "cr_phase2_clean_for_sha: graduation candidate $anc_sha has $anc_findings finding(s) but branch-scoped coverage is only $covered — record the missing fix/rejection records, then re-run." >&2
	return 1
}

cr_phase2_clean_for_sha() {
	local sha=$1
	# #248 CR: fail CLOSED on an unresolvable repo root — do NOT fall back to
	# pwd (which could point at an unrelated repo whose .claude/logs happen to
	# exist, yielding a wrong clean/not-clean verdict).
	local repo_root="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
	[ -n "$repo_root" ] || return 1
	local cr_log="$repo_root/.claude/logs/cr-local-review.jsonl"
	[ -f "$cr_log" ] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	local short_sha
	short_sha=$(printf '%s' "$sha" | cut -c1-7)
	local latest_findings jq_err
	# `-t <template>` not bare `mktemp`: the bare form is a GNU coreutils
	# convenience and BSD/macOS mktemp wants a template. The bats suite for this
	# very file already uses the portable form; this lib did not, so a consumer
	# on stock macOS without coreutils would have had every push refused.
	# Guard emptiness too — an mktemp exiting 0 with no output would make
	# `2>"$jq_err"` an ambiguous redirect and land on the failure branch with
	# the real cause (a broken tmpdir) nowhere in the message.
	# Explicit if, not `A && B || C` — that form runs C when A succeeds but B
	# fails, which is exactly the empty-output case, and shellcheck SC2015
	# flags it. `|| jq_err=""` collapses a non-zero rc into the same empty
	# check (this lib is `set -u` only, so the assignment does not abort).
	jq_err=$(mktemp -t crp2cov.XXXXXX) || jq_err=""
	if [ -z "$jq_err" ]; then
		echo "cr_phase2_clean_for_sha: mktemp failed (TMPDIR=${TMPDIR:-/tmp} full or unwritable?) — cannot verify Phase 2, refusing" >&2
		return 1
	fi
	# A PARTIAL / TIMED-OUT run is NOT evidence of a clean review (#2544).
	#
	# THE LAUNDERING THIS CLOSES: when the CR-CLI is killed before emitting a
	# single finding, local-review.sh logs `{"findings":0,"timeout":true,
	# "partial":true}` — truthfully reporting "0 findings were SEEN", not "0
	# findings EXIST". This predicate read only `.findings`, so `0` meant CLEAN,
	# and the pre-push gate then accepted a SHA whose local review never ran.
	# Observed live: PR #2540's f21b3d1 pushed on exactly such an entry, and the
	# operator was told the signal was clean.
	#
	# THE RULE: `complete:true` is REQUIRED. Everything else is defence in depth.
	#
	# The first attempt at this fix enumerated the ways a review can fail —
	# `partial`, `timeout` — and rejected those. That approach is unfixable in
	# principle: you cannot enumerate every way a review fails to happen, and
	# any path you miss writes an unflagged `findings:0` that reads as CLEAN.
	# Phase 1 proved it empirically — ONLY rc 124/137 and CR's own timeout event
	# reach the flagged writer; auth failure, rate limit, network error, bad
	# config and CLI crash all fall through to the plain logger with
	# `rc:1, findings:0` and no flags at all. The blocklist was already leaking
	# on the day it was written.
	#
	# So the test is inverted: absence of positive evidence is refusal. A writer
	# that forgets the field, an older writer that predates it, a truncated
	# line, a schema change — every one of them fails CLOSED. That is the whole
	# point, and it is why `// false` (not `// true`) is the default here.
	#
	# The remaining arms are belt-and-braces for a writer that sets
	# `complete:true` wrongly:
	#   - partial/timeout still reject, so a salvaged-then-flagged run cannot be
	#     coverage-cleared. `has()` + `!= false` rather than `// false != false`:
	#     the `//` form collapses ABSENT and explicit NULL into the same value,
	#     but they mean different things. Absent is an old writer that predates
	#     the field — compatible, allow. An explicit `null` is a writer that
	#     TRIED to state completion and produced nothing, which is the same
	#     inference error as reading findings:0 off a killed run. Reject it.
	#     `!= false` (not `== true`) still catches a string "true" or a 1.
	#   - `.findings` must be a real JSON *number*. A string "0" would otherwise
	#     print bare `0`, pass the shell digit test below, and read CLEAN.
	#   - negative findings reject, so the -1 sentinel can never be compared
	#     `-ge` against a coverage sum and pass.
	#
	# Prove-yourself coverage cannot clear an incomplete run at any findings
	# count: covering the handful of findings CR emitted before it died says
	# nothing about the rest of the diff it never read. Only a subsequent
	# COMPLETE run for the same SHA clears it (see the non-sticky note below).
	latest_findings=$(jq -rs --arg s "$short_sha" \
		'[.[] | select(.sha==$s)]
		 | if length > 0 then
		     (last as $l
		      | if ($l.complete // false) != true then "-1 the newest ledger entry is missing complete:true — the review was killed, crashed, hit auth/rate-limit, or never ran"
		        elif (($l | has("partial")) and ($l.partial != false))
		          or (($l | has("timeout")) and ($l.timeout != false))
		        then "-1 the newest ledger entry is flagged partial/timeout — an incomplete run cannot be coverage-cleared"
		        elif ($l.findings | type) != "number" then "-1 .findings is not a JSON number — writer bug or schema drift"
		        elif $l.findings < 0 then "-1 .findings is negative — the unparseable-count sentinel, not a real count"
		        else ($l.findings | tostring) end)
		   else "-1 no ledger entry exists for this SHA — no review has ever run" end' \
		"$cr_log" 2>"$jq_err") || {
		# A jq failure here is NOT a verdict — it means the ledger is
		# unreadable (malformed JSONL from a torn concurrent write, a schema
		# change, jq itself broken). The old `2>/dev/null || echo -1` form
		# returned the same silent rc 1 as a legitimate "not clean", so an
		# operator staring at a refused push had no way to tell a real finding
		# from a corrupt log file. Fail closed AND say why.
		#
		# This is the documented exception to the silent contract: normal
		# clean/not-clean verdicts stay silent (callers narrate those), but a
		# broken input is not a verdict and must be loud.
		echo "cr_phase2_clean_for_sha: jq failed reading $cr_log — refusing (not a clean verdict): $(head -c 200 "$jq_err" 2>/dev/null)" >&2
		rm -f "$jq_err"
		return 1
	}
	rm -f "$jq_err"
	# NON-STICKY, deliberately: `last` keys on the newest entry for the SHA
	# only. A partial run followed by a complete one reads CLEAN off the
	# complete entry. Making the rejection sticky would strand a branch whose
	# re-run genuinely succeeded, with no way to clear it short of a new
	# commit — the gate would stop being a signal and start being a wall.
	# Reject non-numeric / missing / negative BEFORE the coverage path. A
	# "-1 <reason>" string means "no completed CR-CLI run for this SHA" —
	# fail-closed, never whitewashed by old audit. The reason rides out of the
	# jq because one fused message for five distinct causes points the
	# operator at the wrong field (a SHA with no entry at all has no "newest
	# entry" to be missing complete:true — the gate would refuse correctly
	# and explain wrongly).
	# #2544 — SAY WHY. A correct-but-mute gate is not actually correct: the
	# caller's generic "Phase 2 not clean — address findings" sends the operator
	# to a ledger showing findings:0, which reads as a broken gate, and the
	# documented escape (PIPELINE_GATE_SKIP=1) is one line further down. A
	# mystery-red trains the bypass. Refusing loudly is what makes the refusal
	# survive contact with a tired operator at 2am.
	case "$latest_findings" in
	-1*)
		local refusal_reason="${latest_findings#-1 }"
		# #2545 graduation: ONLY the no-row-for-this-SHA reason may
		# graduate via a covered branch-ancestor review. A row that EXISTS
		# and was rejected on its own terms (killed run, partial flag, bad
		# count) is evidence something ran and died for THIS sha —
		# graduating around it would be the #2544 laundering again.
		case "$refusal_reason" in
		"no ledger entry exists for this SHA"*)
			if _cr_phase2_branch_graduation "$cr_log" "$repo_root"; then
				return 0
			fi
			;;
		esac
		echo "cr_phase2_clean_for_sha: no COMPLETED CR review on record for $short_sha." >&2
		echo "  Reason: ${refusal_reason}." >&2
		echo "  findings:0 there means '0 were SEEN', not '0 exist'. Re-run: coderabbit review --agent -t committed --base main" >&2
		return 1
		;;
	esac
	case "$latest_findings" in
	'' | *[!0-9]*) return 1 ;;
	esac
	if [ "$latest_findings" = "0" ]; then
		return 0
	fi
	# findings>0 → clean IFF every finding has a prove-yourself record scoped to
	# THIS sha (by .covered_sha prefix). Sum .covers_count (default 1 — #238
	# made the writer persist the real count so `--covers-count N` is honored).
	local audit_log="$repo_root/.claude/audit/prove-yourself.jsonl"
	[ -f "$audit_log" ] || return 1
	local cr_covered
	cr_covered=$(jq -rs --arg s "$short_sha" '
		[.[] | select(.source == "cr") | select((.covered_sha // "") | startswith($s))] |
		map(.covers_count // 1) | add // 0
	' "$audit_log" 2>/dev/null || echo 0)
	[ "${cr_covered:-0}" -ge "${latest_findings:-0}" ] && return 0
	return 1
}
