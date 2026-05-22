#!/bin/bash
set -euo pipefail
# v4.28-W4 (#733): CR-in-CI auto-triage classifier. Reads unresolved CR
# threads on a PR, classifies each into 4 buckets, emits JSON for
# Claude to act on.
#
# Classifier output is read-only — it does NOT auto-apply fixes or
# resolve threads. Per-class actions are the operator's (Claude's) job
# based on the suggested_action field. The classifier's value is
# offloading the regex/heuristic decision so Claude can fast-skim
# trivial fixes vs needing-judgment ones.
#
# Buckets:
#   trivial          — matches known auto-fix patterns (regex tightening,
#                      mktemp /dev/null fallback, here-string idiom,
#                      comment fixes, log-msg updates, var renames).
#                      Suggested: apply via Edit + commit.
#   stale            — fix-content matches current code already.
#                      Suggested: resolve thread via GraphQL.
#   scope-creep      — describes behavior outside PR's stated scope.
#                      Suggested: file follow-up issue + post resolve-
#                      with-explanation comment on thread.
#   real-but-in-scope — substantive, in scope.
#                      Suggested: apply directly + commit.
#
# Heuristic risk: misclassification is possible. Defaults bias to
# `real-but-in-scope` when ambiguous, so operator sees the finding
# instead of the script silently dispatching it.
#
# Usage:
#   .claude/scripts/cr/auto-triage.sh <pr-number>
#   .claude/scripts/cr/auto-triage.sh <pr-number> --json    # JSON output (default)
#   .claude/scripts/cr/auto-triage.sh <pr-number> --table   # human-readable

# CR-in-CI #733 r2 major: resolve REPO_ROOT via git first (preserves
# bats test portability — bats fixtures `git init` in $TDIR + expect
# audit log path to follow), with script-relative fallback when git
# is unavailable. Matches the spirit of CR's suggestion (don't hard-
# require git) while keeping the bats contract.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
	REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
}
cd "$REPO_ROOT"

PR=""
FORMAT="json"

while [ "$#" -gt 0 ]; do
	case "$1" in
	--json)
		FORMAT="json"
		shift
		;;
	--table)
		FORMAT="table"
		shift
		;;
	--help | -h)
		sed -n '5,30p' "$0"
		exit 0
		;;
	[0-9]*)
		# CR-in-CI #733 r4 trivial: case pattern `[0-9]*` accepts
		# `123abc`; tighten to numeric-only via regex post-match.
		if ! [[ "$1" =~ ^[0-9]+$ ]]; then
			echo "auto-triage: ERROR: pr-number must be numeric, got '$1'" >&2
			exit 2
		fi
		PR=$1
		shift
		;;
	*)
		echo "auto-triage: ERROR: unknown arg '$1'" >&2
		exit 2
		;;
	esac
done

if [ -z "$PR" ]; then
	echo "auto-triage: ERROR: <pr-number> required" >&2
	echo "  hint: .claude/scripts/cr/auto-triage.sh <pr-number>" >&2
	exit 2
fi

# Resolve repo owner/name from the active remote so the GraphQL query
# below isn't hard-coded to a single repo (would break forks + bats
# fixtures). Resolution chain: (1) gh repo view (the standard path),
# (2) AUTO_TRIAGE_REPO_NWO env hint (for bats fixtures + forks
# without gh). If BOTH unset we exit 2 — there's no hardcoded
# repbyrepdev/plex_arr_media_stack fallback (CR-in-CI #733 r4 minor:
# prior comment incorrectly claimed there was; deliberate to keep
# the script fork-friendly without baked-in repo identity).
REPO_NWO=""
if REPO_NWO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) && [ -n "$REPO_NWO" ]; then
	:
elif [ -n "${AUTO_TRIAGE_REPO_NWO:-}" ]; then
	REPO_NWO="$AUTO_TRIAGE_REPO_NWO"
else
	echo "auto-triage: ERROR: cannot resolve repo nameWithOwner (gh unavailable + AUTO_TRIAGE_REPO_NWO unset)" >&2
	exit 2
fi
REPO_OWNER="${REPO_NWO%%/*}"
REPO_NAME="${REPO_NWO##*/}"

# Fetch unresolved CR threads via GraphQL. Pulls thread id, path, line,
# body, and isOutdated flag. isOutdated=true threads are still
# "unresolved" formally but anchored to lines that have changed —
# strong stale-class candidate.
# CR-in-CI #733 r2 major: pageInfo added so >100-thread PRs don't
# silently truncate. Full cursor-loop pagination would be cleaner but
# adds significant complexity (jq array merging across calls); the
# pragmatic fix is to surface hasNextPage as a WARN — operator knows
# the result is partial + can paginate manually if needed. Full loop
# tracked as follow-up if it ever becomes a real pain (only relevant
# on PRs with >100 unresolved CR threads — extreme outlier).
# shellcheck disable=SC2016 # GraphQL query body uses $pr/$owner/$name as
# GraphQL VARIABLES (resolved server-side via -F/-F/-F flags above), not
# bash variables. Single quotes are correct here.
THREADS_JSON=$(gh api graphql \
	-F pr="$PR" -F owner="$REPO_OWNER" -F name="$REPO_NAME" \
	-f query='
query($pr:Int!, $owner:String!, $name:String!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$pr) {
      reviewThreads(first:100) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated
          path line
          comments(first:1) {
            nodes { body author { login } }
          }
        }
      }
    }
  }
}' 2>&1) || {
	echo "auto-triage: ERROR: gh api graphql failed: $THREADS_JSON" >&2
	exit 2
}

# Warn if >100 threads exist (we only fetched first page).
HAS_NEXT_PAGE=$(printf '%s' "$THREADS_JSON" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false' 2>/dev/null || echo "false")
if [ "$HAS_NEXT_PAGE" = "true" ]; then
	echo "auto-triage: WARN: PR has >100 review threads — only first page classified. Manual pagination needed for full coverage." >&2
fi

# Filter to: unresolved + first comment by coderabbitai[bot].
UNRESOLVED=$(printf '%s' "$THREADS_JSON" | jq -c '
  .data.repository.pullRequest.reviewThreads.nodes
  | map(select(.isResolved == false))
  | map(select(.comments.nodes[0].author.login | test("coderabbit"; "i")))
  | map({
      thread_id: .id,
      path: .path,
      line: .line,
      is_outdated: .isOutdated,
      body: .comments.nodes[0].body
    })
') || {
	echo "auto-triage: ERROR: jq filter failed; threads_json=$THREADS_JSON" >&2
	exit 2
}

# Classifier: per-thread regex match against body. Order matters —
# stale check first (fastest reject for outdated), then trivial, then
# scope-creep, then default to real-but-in-scope.
# CR-in-CI #733 r3 trivial: compute classification ONCE, derive both
# class + suggested_action from the single value (DRY — was: regex
# logic duplicated across both fields, drift risk on rule edits).
CLASSIFIED=$(printf '%s' "$UNRESOLVED" | jq -c '
  map(. as $t |
    (
      if $t.is_outdated == true and ($t.body | test("(?i)still valid|verify against current|fix.*landed")) then "stale"
      elif ($t.body | test("(?i)\\*\\*nitpick\\*\\*|\\*\\*trivial\\*\\*|quick win")) and
           ($t.body | test("(?i)mktemp|2>/dev/null|here-string|var rename|comment fix|log msg|tighten|\\[ -z|--separate-stderr")) then "trivial"
      elif ($t.body | test("(?i)out of scope|scope creep|outside|orthogonal to this pr|separate pr|follow-up issue")) then "scope-creep"
      else "real-but-in-scope"
      end
    ) as $classification |
    {
      thread_id: $t.thread_id,
      path: $t.path,
      line: $t.line,
      class: $classification,
      suggested_action: (
        if $classification == "stale" then "resolve-via-graphql"
        elif $classification == "trivial" then "edit-and-commit"
        elif $classification == "scope-creep" then "file-followup-and-resolve"
        else "review-then-apply"
        end
      ),
      body_excerpt: ($t.body[0:200])
    }
  )
') || {
	echo "auto-triage: ERROR: classifier jq failed" >&2
	exit 2
}

# Output
case "$FORMAT" in
json)
	printf '%s\n' "$CLASSIFIED"
	;;
table)
	printf '%-20s | %-40s | %-26s | %s\n' "Class" "Path:Line" "Action" "Body excerpt"
	printf '%s\n' "--------------------+------------------------------------------+----------------------------+--------------"
	printf '%s' "$CLASSIFIED" | jq -r '.[] | [.class, (.path + ":" + (.line | tostring)), .suggested_action, (.body_excerpt | gsub("\n";" ")[0:60])] | @tsv' |
		awk -F'\t' '{ printf "%-20s | %-40s | %-26s | %s\n", $1, $2, $3, $4 }'
	;;
esac

# Audit log: every classification gets a JSONL line for retrospective
# accuracy review. Append-only; rotation handled separately.
# CR-in-CI #733 r1 minor: surface audit-log write failures via
# warning to stderr (was: 2>/dev/null || true silently dropped). The
# classifier's primary output (stdout JSON/table) is unaffected by an
# audit failure; we don't want a missing audit log to mask the
# classification result, but we DO want operators alerted when the
# log fails so the audit trail's gap is observable.
AUDIT_LOG="$REPO_ROOT/.claude/logs/auto-triage.jsonl"
# CR-in-CI #733 r2 major: mkdir best-effort under set -e — read-only
# /var, missing parent, etc. shouldn't kill the script after we
# already produced the classification (primary output is stdout; audit
# log is secondary).
mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || {
	echo "auto-triage: WARN: mkdir for audit log dir failed at $(dirname "$AUDIT_LOG") — audit write skipped this run" >&2
}
# CR-in-CI #733 r3 minor: surface mktemp failure as a warning instead
# of silently skipping the entire audit path. Two regimes: (a) mktemp
# OK → capture stderr to file, clean up after; (b) mktemp failed →
# emit warning, still attempt audit write but discard stderr (the
# audit log itself is the diagnostic — even a successful write under
# mktemp-failure tells the operator something's odd with /tmp).
audit_temp_created=true
audit_err_file=$(mktemp -t auto-triage-audit-err.XXXXXX) || {
	echo "auto-triage: WARN: mktemp for audit stderr capture failed — audit write proceeds without stderr capture" >&2
	audit_temp_created=false
	audit_err_file="/dev/null"
}
audit_rc=0
printf '%s' "$CLASSIFIED" | jq -c --arg ts "$(date -u +%FT%TZ)" --arg pr "$PR" \
	'.[] | {ts: $ts, pr: $pr, thread_id: .thread_id, path: .path, line: .line, class: .class, suggested_action: .suggested_action}' \
	>>"$AUDIT_LOG" 2>"$audit_err_file" || audit_rc=$?
if [ "$audit_rc" -ne 0 ]; then
	if [ "$audit_temp_created" = true ]; then
		audit_err=$(cat "$audit_err_file" 2>/dev/null || echo "<no stderr captured>")
	else
		audit_err="<stderr not captured: mktemp failed>"
	fi
	echo "auto-triage: WARN: audit log write failed (rc=$audit_rc) at $AUDIT_LOG: $audit_err" >&2
fi
[ "$audit_temp_created" = true ] && rm -f "$audit_err_file"
