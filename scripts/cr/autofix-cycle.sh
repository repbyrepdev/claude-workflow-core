#!/bin/bash
set -euo pipefail
# bats-required: 0
# (Orchestration wrapper over gh + CodeRabbit + git — fires @coderabbitai
#  autofix, polls the gh API, pulls autofix commits, restores exec bits, waits
#  for CR re-review. Exercised LIVE in the ship-pr-cycle cr-autofix stage; not
#  unit-testable without full gh/CR/network mocking. #223 CR-CLI r7.)
# v4.24-R (#605) — automated CR autofix cycle.
# v4.27 (#632) — extended:
#   - wait-for-CR-rereview on autofix HEAD (item #8)
#   - budget-aware adaptive routing via rate-budget.sh (item #9)
#   - exec-bit re-commit (git update-index + auto-commit) (item #10)
#
# Fires `@coderabbitai autofix` on a PR, polls gh API for the status
# comment, pulls the autofix commit when applied, restores exec bits
# (recurring autofix quirk), waits for CR's fresh review on the autofix
# HEAD, loops up to 3 times until "skipped — nothing to fix" OR max
# iterations reached. Budget-aware: when CR rate budget is low, falls
# back to Phase 0.5 free-tier prefilter to make progress without
# burning the prepaid 10/hr Pro Plus bucket (refill 6min/token).
#
# Replaces the manual `gh pr comment ... @coderabbitai autofix` + Monitor
# polling + `git pull` cycle we ran by hand 4× per PR in v4.24-O.
#
# Usage:
#   .claude/scripts/cr/autofix-cycle.sh <pr-number> [--max-cycles N] [--poll N] [--timeout N]
# Defaults: --max-cycles 3, --poll 30s, --timeout 600s per cycle.

PR=""
MAX_CYCLES=3
POLL_INTERVAL=30
CYCLE_TIMEOUT=600

while [ "$#" -gt 0 ]; do
	case "$1" in
	--pr)
		# shellcheck disable=SC2015 # A&&B||{exit} is an intentional arg-guard (C runs whenever the require fails)
		[ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || {
			echo "autofix-cycle: --pr requires a value" >&2
			exit 2
		}
		PR="$2"
		shift 2
		;;
	--max-cycles)
		# shellcheck disable=SC2015 # A&&B||{exit} is an intentional arg-guard (C runs whenever the require fails)
		[ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || {
			echo "autofix-cycle: --max-cycles requires a value" >&2
			exit 2
		}
		MAX_CYCLES="$2"
		shift 2
		;;
	--poll)
		# shellcheck disable=SC2015 # A&&B||{exit} is an intentional arg-guard (C runs whenever the require fails)
		[ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || {
			echo "autofix-cycle: --poll requires a value" >&2
			exit 2
		}
		POLL_INTERVAL="$2"
		shift 2
		;;
	--timeout)
		# shellcheck disable=SC2015 # A&&B||{exit} is an intentional arg-guard (C runs whenever the require fails)
		[ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || {
			echo "autofix-cycle: --timeout requires a value" >&2
			exit 2
		}
		CYCLE_TIMEOUT="$2"
		shift 2
		;;
	-h | --help)
		# Print the user-facing description + Usage block (lines 14-27);
		# skip the internal orchestration note + bats-required + changelog
		# at lines 3-13 (#223 phase2 — the prior 4,16p truncated mid-sentence
		# and showed internal notes instead of Usage).
		sed -n '14,27p' "$0"
		exit 0
		;;
	[0-9]*)
		PR="$1"
		shift
		;;
	*)
		echo "autofix-cycle: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

[ -n "$PR" ] || {
	echo "autofix-cycle: <pr-number> required" >&2
	exit 2
}

REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd; })

# CR-CLI #1607: load the plugin-cache helper resolver so _phase05_fallback can
# resolve review-config.yml the SAME way hooks/phase0.5-copilot-prefilter.sh
# does (consumer .claude/ copy → plugin cache), instead of only checking
# $REPO_ROOT/.claude/. This script lives at scripts/cr/ (plugin) or
# .claude/scripts/cr/ (consumer), so the plugin _lib sibling is ../../_lib.
# Guarded + best-effort (mirrors scripts/ship-pr-cycle.sh): if the lib is
# absent (older consumer cache), _phase05_fallback falls back to the direct
# $REPO_ROOT/.claude path.
_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_LIB="$(cd "$_SCRIPT_DIR/../../_lib" 2>/dev/null && pwd || echo "")"
if [ -n "$PLUGIN_LIB" ] && [ -f "$PLUGIN_LIB/resolve-plugin-helper.sh" ]; then
	# shellcheck source=../../_lib/resolve-plugin-helper.sh
	. "$PLUGIN_LIB/resolve-plugin-helper.sh"
fi

_exec_bit_restore_local() {
	# v4.28-W3-C (#672): restore exec bits + commit LOCALLY ONLY. Push
	# is split out so the cycle can wait for CR's autofix-only re-review
	# BEFORE the exec-bit commit lands on remote (otherwise CR re-reviews
	# the combined head and the wait_for_rereview poll on the autofix
	# SHA never matches).
	#
	# Output (to stdout): the local commit SHA if a commit was created,
	# empty string if no exec-bit changes were needed. Caller passes
	# this to _exec_bit_push to actually publish.
	local dir f
	local restored_files=()
	for dir in \
		"$REPO_ROOT/.claude/hooks" \
		"$REPO_ROOT/.claude/scripts" \
		"$REPO_ROOT/.claude/pre-commit-hooks" \
		"$REPO_ROOT/.claude/local-backups" \
		"$REPO_ROOT/.claude/_lib" \
		"$REPO_ROOT/scripts"; do
		[ -d "$dir" ] || continue
		while IFS= read -r -d '' f; do
			if [ ! -x "$f" ]; then
				chmod +x "$f" 2>/dev/null || true
				restored_files+=("$f")
			fi
		done < <(find "$dir" -maxdepth 3 -name '*.sh' -type f -print0 2>/dev/null)
	done

	if [ "${#restored_files[@]}" -eq 0 ]; then
		return 0 # nothing to restore
	fi

	local rel index_dirty=0 update_failed=0
	for f in "${restored_files[@]}"; do
		rel="${f#"$REPO_ROOT/"}"
		if git -C "$REPO_ROOT" ls-files -s "$rel" 2>/dev/null | awk '{print $1}' | grep -qx 100644; then
			# stderr NOT suppressed (CR-CLI): a failing update-index (e.g. path not
			# in index) must be visible, not swallowed. CR #1607: fail-closed — a
			# stripped exec bit that can't be re-staged is the exact breakage this
			# helper exists to prevent, so record the failure and abort the cycle
			# (return 1) rather than silently pushing a partial exec-bit restore.
			if git -C "$REPO_ROOT" update-index --chmod=+x "$rel"; then
				index_dirty=1
			else
				echo "autofix-cycle: 'git update-index --chmod=+x $rel' failed — cannot re-stage exec bit" >&2
				update_failed=1
			fi
		fi
	done
	[ "$update_failed" = "0" ] || return 1
	[ "$index_dirty" = "1" ] || return 0

	echo "autofix-cycle: committing exec-bit restorations (LOCAL ONLY — push deferred until after re-review)" >&2
	local commit_paths=()
	for f in "${restored_files[@]}"; do
		rel="${f#"$REPO_ROOT/"}"
		if git -C "$REPO_ROOT" diff --cached --raw -- "$rel" 2>/dev/null |
			awk '$1 ~ /^:100644$/ && $2 ~ /^100755$/' | grep -q .; then
			commit_paths+=("$rel")
		fi
	done
	[ "${#commit_paths[@]}" -gt 0 ] || return 0

	if SKILL_WRAPPER=1 \
		DOGFOOD_GATE_SKIP=1 \
		DOGFOOD_GATE_SKIP_REASON="autofix-cycle exec-bit recovery (mode-only)" \
		git -C "$REPO_ROOT" commit -m "fix: restore exec bits stripped by CR autofix [no-issue: automated exec-bit recovery]" -- "${commit_paths[@]}" 2>&1 | tail -3 >&2; then
		# Echo the commit SHA so caller knows there's something to push.
		git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null
		return 0
	fi
	echo "autofix-cycle: exec-bit commit failed" >&2
	return 1
}

_exec_bit_push() {
	# v4.28-W3-C (#672): push the local exec-bit recovery commit. Called
	# AFTER _wait_for_rereview confirms CR finished its autofix-only review.
	#
	# Args: $1 = local commit SHA from _exec_bit_restore_local (empty
	#       string if no commit was made — in which case this is a no-op).
	local local_sha=${1:-}
	[ -z "$local_sha" ] && return 0
	local current_branch
	current_branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null) || {
		echo "autofix-cycle: cannot resolve current branch — aborting exec-bit push" >&2
		return 1
	}
	if [ -z "$current_branch" ] || [ "$current_branch" = "HEAD" ]; then
		echo "autofix-cycle: detached HEAD — aborting exec-bit push (commit is local-only)" >&2
		return 1
	fi
	if ! git -C "$REPO_ROOT" push origin "$current_branch" 2>&1 | tail -3 >&2; then
		echo "autofix-cycle: push of exec-bit recovery commit failed — manual recovery may be needed" >&2
		return 1
	fi
}

_retest_after_pull() {
	# v4.28-W3-C (#672): "re-test, confirm nothing broke" step from the
	# user's spec. Runs touched-bats against the autofix delta. If any
	# bats fail, abort the push so a broken autofix doesn't propagate.
	# r3 CR fix #4: missing/non-executable test-touched.sh → return 1
	# (was return 0 = silent skip). The whole point of post-pull re-test
	# is "confirm nothing broke" — disabling it when the checkout is
	# misconfigured defeats the gate.
	local touched="$REPO_ROOT/scripts/test-touched.sh"
	[ -x "$touched" ] || {
		echo "autofix-cycle: scripts/test-touched.sh missing or not executable — aborting post-pull re-test (gate cannot run)" >&2
		return 1
	}
	echo "autofix-cycle: running touched bats on autofix delta" >&2
	# r5 SFH #5: surface bats output when it fails — silencing it forced
	# operators to re-run touched-bats manually to find the failure. Pipe
	# to stderr so the failure recap is in the same stream as the abort
	# message and visible in the autofix-cycle log.
	if ! "$touched" >&2; then
		echo "autofix-cycle: touched bats FAILED on autofix output — aborting push to prevent broken push" >&2
		return 1
	fi
	echo "autofix-cycle: touched bats clean on autofix delta" >&2
	return 0
}

_wait_for_rereview() {
	# v4.27 (#632) item #8: after autofix commit lands + we pull, wait for
	# CR's fresh review on the new HEAD before declaring cycle "done".
	# Prior behavior matched only on autofix-status comments — could exit
	# while CR was still preparing its re-review of the autofix-applied
	# state. Polls reviews API, filters by commit_id == new HEAD.
	#
	# v4.28-W3-C #672: callers pass the pulled-autofix HEAD as $3. The
	# rationale is now even more important than CR #634 r2 #143's: in the
	# new ordering this wait runs BEFORE _exec_bit_restore_local creates
	# any local commit, so head_sha=pulled_head is exactly what's on
	# remote. (Earlier rationale referenced _exec_bit_restore which is
	# now split into _local + _push — see #672 reorder.)
	local pr="$1" deadline="$2" head_sha="${3:-}"
	if [ -z "$head_sha" ]; then
		head_sha=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null) || return 0
	fi
	local started_at
	started_at=$(date -u +%s)
	while true; do
		local now elapsed
		now=$(date -u +%s)
		elapsed=$((now - started_at))
		if [ "$elapsed" -ge "$deadline" ]; then
			echo "autofix-cycle: re-review wait timed out after ${deadline}s — proceeding without confirmation" >&2
			return 0
		fi
		# Look for any CR review on this exact commit.
		# CR #634 finding 166: gh api does NOT support --arg/--argjson;
		# those are jq-only flags. Pipe the JSON to jq --arg explicitly so
		# the variable is bound (previously the filter saw $sha as undefined).
		local found
		found=$(gh api "repos/$REPO/pulls/$pr/reviews" --paginate 2>/dev/null |
			jq -rs --arg sha "$head_sha" '[.[][] | select(.user.login | test("coderabbit"; "i")) | select(.commit_id == $sha)] | length' 2>/dev/null || echo 0)
		if [ "$found" -gt 0 ]; then
			echo "autofix-cycle: CR re-reviewed HEAD ${head_sha:0:8} ($found review(s)) — proceeding" >&2
			return 0
		fi
		sleep "$POLL_INTERVAL"
	done
}

_budget_remaining() {
	# v4.27 (#632) item #9: returns CR rate budget remaining (integer 0+),
	# or empty string if rate-budget.sh is unavailable. Used to branch on
	# adaptive routing before each cycle.
	# Sibling-first (#2519 class): rate-budget.sh lives next to THIS
	# script — resolves in the plugin repo, the plugin cache, and any
	# consumer mirror alike. The consumer-tree path silently disabled
	# budget-aware routing in repos without the mirror. Consumer copy
	# still wins when present (override semantics).
	local budget_script="$REPO_ROOT/.claude/scripts/cr/rate-budget.sh"
	[ -x "$budget_script" ] || budget_script="$_SCRIPT_DIR/rate-budget.sh"
	if [ ! -x "$budget_script" ]; then
		echo ""
		return
	fi
	local out
	out=$("$budget_script" --json 2>/dev/null) || {
		echo ""
		return
	}
	echo "$out" | jq -r '.remaining // empty' 2>/dev/null || echo ""
}

_phase05_fallback() {
	# v4.27 (#632) item #9: when CR budget is tight, run free-tier
	# Copilot prefilter to catch findings without burning a CR slot.
	# Returns 0 if Phase 0.5 ran successfully, non-zero otherwise.
	local prefilter="$REPO_ROOT/.claude/hooks/phase0.5-copilot-prefilter.sh"
	if [ ! -x "$prefilter" ]; then
		echo "autofix-cycle: phase0.5-copilot-prefilter.sh not available — skipping fallback" >&2
		return 1
	fi
	echo "autofix-cycle: running Phase 0.5 fallback (free-tier Copilot, 0 CR slots)" >&2
	local exit_code=0
	# #223 CR-CLI: derive the prefilter base ref from review-config.yml's
	# base_ref SSOT (matching phase0.5-post-commit-rerun.sh) instead of
	# hardcoding `main`, so a repo whose mainline isn't `main` prefilters
	# against the right base.
	#
	# CR #1607 fail-closed: distinguish ABSENT config from PARSE ERROR. When
	# review-config.yml is genuinely absent we default to "main" (prior
	# behavior, a sane convention). But when the file EXISTS yet can't be read
	# (yq missing, malformed YAML, unreadable) we must NOT silently prefilter
	# against the wrong base — error to stderr + skip the prefilter (return
	# non-zero) so a misconfigured SSOT can't quietly diff against main.
	# CR-CLI #1607: resolve review-config.yml through resolve_plugin_helper (the
	# SAME resolver phase0.5-copilot-prefilter.sh uses) so a consumer that pulls
	# review-config.yml from the plugin cache (no local .claude/ copy) reads its
	# base_ref instead of being treated as "absent" → wrong "main" default. Falls
	# back to the direct $REPO_ROOT/.claude path when the resolver isn't loaded.
	local review_config=""
	if command -v resolve_plugin_helper >/dev/null 2>&1; then
		review_config="$(resolve_plugin_helper "review-config.yml" 2>/dev/null || echo "")"
	fi
	[ -n "$review_config" ] || review_config="$REPO_ROOT/.claude/review-config.yml"
	local base_ref="main"
	if [ -f "$review_config" ]; then
		if ! command -v yq >/dev/null 2>&1; then
			echo "autofix-cycle: yq required to read $review_config — skipping Phase 0.5 prefilter (fail-closed)" >&2
			return 2
		fi
		local cfg_base
		if ! cfg_base=$(yq -r '.base_ref // empty' "$review_config"); then
			echo "autofix-cycle: failed parsing base_ref from $review_config — skipping Phase 0.5 prefilter (fail-closed)" >&2
			return 2
		fi
		# An explicit empty/absent base_ref key in a parseable file keeps the
		# "main" default (the file is readable, the key is just unset).
		[ -n "$cfg_base" ] && [ "$cfg_base" != "null" ] && base_ref="$cfg_base"
	fi
	# stdin </dev/null: the prefilter calls try-free.sh, whose `[ ! -t 0 ] && cat`
	# blocks on an unbounded read when stdin is a non-tty pipe with no data (here
	# stdin would be inherited from autofix-cycle's caller). The prefilter pipes no
	# context, so closing stdin avoids the COPILOT_TIMEOUT_SEC hang (#223 CR-CLI).
	"$prefilter" --base "$base_ref" </dev/null 2>&1 | tail -5 >&2 || exit_code=$?
	return $exit_code
}

cycle=1
budget_zero_retries=0
MAX_BUDGET_ZERO_RETRIES=5
while [ "$cycle" -le "$MAX_CYCLES" ]; do
	echo "autofix-cycle: firing cycle $cycle/$MAX_CYCLES on PR #$PR" >&2
	start_ts=$(date -u +%s)

	# v4.27 (#632) item #9: budget-aware adaptive routing.
	# Each autofix cycle consumes ~2 CR slots (1 to fire autofix, 1 for
	# the re-review). Check budget before committing to a cycle.
	remaining=$(_budget_remaining)
	if [ -n "$remaining" ] && [[ $remaining =~ ^[0-9]+$ ]]; then
		case "$remaining" in
		0)
			# Out of budget: fall back to Phase 0.5 free-tier and wait.
			# Don't fire autofix this cycle — it'd consume slots we don't
			# have. Phase 0.5 catches what it can for $0; budget recovers
			# as the rolling 60-min window ages out earlier calls.
			# Bounded retry to prevent infinite loop.
			budget_zero_retries=$((budget_zero_retries + 1))
			if [ "$budget_zero_retries" -gt "$MAX_BUDGET_ZERO_RETRIES" ]; then
				echo "autofix-cycle: CR budget=0 after $MAX_BUDGET_ZERO_RETRIES retries — exiting to prevent infinite loop" >&2
				# CR #634 round 3 finding 240: exit non-zero so callers can
				# detect "no autofix cycle ran" instead of treating it as
				# converged-success.
				exit 3
			fi
			echo "autofix-cycle: CR budget=0 EXHAUSTED (retry $budget_zero_retries/$MAX_BUDGET_ZERO_RETRIES) — running Phase 0.5 fallback while window ages out" >&2
			# CR #634 round 4 finding 262: don't swallow phase05 failures.
			# If the prefilter is missing or fails, surface it (exit 4)
			# rather than silently logging "ran fallback" with zero output.
			if ! _phase05_fallback; then
				echo "autofix-cycle: Phase 0.5 fallback failed at budget=0 — exiting" >&2
				exit 4
			fi
			# Wait one full poll interval before re-checking budget. The
			# rolling window means at least one slot frees within ~hour.
			sleep "$POLL_INTERVAL"
			# Don't increment cycle counter — retry budget check.
			continue
			;;
		1)
			# Reset counter when budget is non-zero.
			budget_zero_retries=0
			# Tight budget: skip the autofix call (would leave 0 slots
			# for the re-review). Run Phase 0.5 to address what we can
			# locally, then break out — the user/operator can manually
			# fire @coderabbitai autofix later if Phase 0.5 didn't cover.
			echo "autofix-cycle: CR budget=1 — autofix would leave 0 slots for re-review. Running Phase 0.5 + exiting; manual @autofix when budget recovers." >&2
			# CR #634 round 4 finding 262: same fail-loud posture.
			if ! _phase05_fallback; then
				echo "autofix-cycle: Phase 0.5 fallback failed at budget=1 — exiting non-zero" >&2
				exit 4
			fi
			exit 0
			;;
		*)
			# Normal path (>=2 slots): reset retry counter and proceed.
			budget_zero_retries=0
			;;
		esac
	fi

	# Fire the autofix trigger.
	if ! gh pr comment "$PR" --body "@coderabbitai autofix" >/dev/null 2>&1; then
		echo "autofix-cycle: gh pr comment failed — aborting" >&2
		exit 2
	fi

	# Poll for the status comment timestamped AFTER start_ts.
	waited=0
	status_body=""
	while [ "$waited" -lt "$CYCLE_TIMEOUT" ]; do
		sleep "$POLL_INTERVAL"
		waited=$((waited + POLL_INTERVAL))
		# Pass start_ts via jq --argjson to avoid shell interpolation into
		# the jq filter (CR flag — prevents any template-injection hazard
		# if $start_ts ever contained non-numeric content).
		# Match terminal phrases directly (Fixes Applied Successfully | Autofix skipped)
		# and use >= for timestamp comparison.
		status_body=$(gh api "repos/$REPO/issues/$PR/comments" 2>/dev/null |
			jq --argjson ts "$start_ts" -r \
				'[.[] | select(.user.login | test("coderabbit"; "i")) | select(.body | test("Fixes Applied Successfully|Autofix skipped"; "i")) | select((.created_at | fromdateiso8601) >= $ts)] | sort_by(.created_at) | last // empty | .body' 2>/dev/null || echo "")
		[ -n "$status_body" ] && break
	done

	if [ -z "$status_body" ]; then
		echo "autofix-cycle: cycle $cycle timed out after ${CYCLE_TIMEOUT}s — no autofix status comment found" >&2
		exit 1
	fi

	case "$status_body" in
	*"Fixes Applied Successfully"*)
		# v4.28-W3-C (#672): correct order per user directive —
		# autofix lands → pull → WAIT for CR re-review on autofix-only
		# → exec-bit restore (local) → re-test → push.
		# Prior order pushed exec-bit BEFORE waiting, so CR re-reviewed
		# the combined head and the wait poll on pulled_head never matched.
		echo "autofix-cycle: cycle $cycle applied fixes — pulling autofix" >&2
		if ! git pull --ff-only >/dev/null 2>&1; then
			echo "autofix-cycle: git pull failed — likely diverged. Resolve manually." >&2
			exit 2
		fi
		pulled_head=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")
		# Step 1: WAIT for CR's re-review on the autofix-only HEAD.
		# (Run BEFORE exec-bit restore so CR sees the autofix delta alone.)
		_wait_for_rereview "$PR" "$CYCLE_TIMEOUT" "$pulled_head"
		# Step 2: exec-bit restore LOCALLY (don't push yet).
		# r4 CR fix: exec-bit recovery is the WHOLE POINT of this helper.
		# Letting the cycle continue when restore fails leaves the remote
		# in the broken state this script exists to prevent. Abort hard.
		exec_bit_local_sha=$(_exec_bit_restore_local) || {
			echo "autofix-cycle: exec-bit local restore failed — aborting to avoid leaving remote with stripped exec bits" >&2
			exit 6
		}
		# Step 3: re-test (touched bats on autofix delta).
		if ! _retest_after_pull; then
			echo "autofix-cycle: post-pull re-test failed — refusing to push exec-bit recovery" >&2
			exit 5
		fi
		# Step 4: push exec-bit recovery commit (only if there was one).
		# r5 SFH #6: log-and-continue lets cycle++ proceed with an unpushed
		# local commit, so subsequent autofix cycles operate on a stale-
		# remote vs local-divergent state. Abort the cycle on push failure
		# (operator can re-run after fixing remote state).
		if ! _exec_bit_push "$exec_bit_local_sha"; then
			echo "autofix-cycle: exec-bit push FAILED — local has commit $exec_bit_local_sha not on remote" >&2
			echo "  Push manually then re-run autofix-cycle, or investigate remote-state issue." >&2
			exit 6
		fi
		cycle=$((cycle + 1))
		continue
		;;
	*"Autofix skipped"*)
		echo "autofix-cycle: cycle $cycle skipped (no unresolved findings) — converged" >&2
		exit 0
		;;
	*)
		echo "autofix-cycle: cycle $cycle unknown status: $(printf '%s' "$status_body" | head -c 200)" >&2
		exit 1
		;;
	esac
done

echo "autofix-cycle: hit max-cycles ($MAX_CYCLES) without Skipped — stopping" >&2
# Exit 1: caller should know we stopped without full convergence so the
# decision to push/merge isn't taken on incomplete autofix state.
exit 1
