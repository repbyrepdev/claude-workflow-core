#!/bin/bash
set -u
# event: PreToolUse
# matcher: Bash
# v4.24-L (#577) — PreToolUse Bash: refuses `git checkout -b feat/*` (or
# `git switch -c feat/*`) branch creation unless the branch name embeds a
# linked issue number AND that issue is assigned to the current user.
#
# Pattern enforced (in priority order — comment-analyzer r2 #5/#6):
#   1. explicit `#NNN` reference inside the branch name → direct NNN
#   2. `feat/vX.Y-Z/NNN-slug` path-segment NNN (v4.28-W4 #708) → NNN
#   3. `feat/vX.Y-Z/...` (no NNN segment) → resolve via gh issue search
# `gh issue view NNN` must show @me as an assignee. Prevents the
# "coding without a tracking issue" class of slip-ups flagged in #201 +
# memory feedback_batch_related_subissues.
#
# Emergency bypass: inline `ISSUE_BEFORE_CODE_SKIP=1 git checkout -b …`
# sentinel in the command string (PreToolUse hooks don't see the env).
# Logged to .claude/logs/issue-before-code-skip.jsonl for audit.
#
# Registered via ~/.claude/settings.json hooks.PreToolUse matcher=Bash.

PAYLOAD=$(cat 2>/dev/null || echo "{}")
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -z "$CMD" ] && exit 0

# Detect branch-creation commands targeting `feat/` (convention). Let
# chore/fix/docs/etc branches through — they're usually one-off and
# don't need issue-lineage enforcement at this layer.
# Anchored match: command must START with (possibly `env VAR=val`-
# prefixed) `git checkout -b feat/` or `git switch -c feat/`. Substring
# match would false-positive on commit messages that MENTION the
# command pattern inside a heredoc.
if [[ ! $CMD =~ ^([[:space:]]*[A-Za-z_][A-Za-z_0-9]*=[^[:space:]]*[[:space:]]+)*git[[:space:]]+(checkout[[:space:]]+-b|switch[[:space:]]+-c)[[:space:]]+feat/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)* ]]; then
	exit 0
fi

# v4.24-Q (#604) — shared sentinel + deny libs.
# Resolve via the hook's own install dir (not `git rev-parse`) so the
# hook works when invoked from an unrelated cwd (test harness tmpdir,
# arbitrary git repo checked out under the user's session, etc.).
HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
LIB_DENY="${HOOK_DIR}/../_lib/hook-deny.sh"
LIB_SENTINEL="${HOOK_DIR}/../_lib/hook-inline-sentinel.sh"
if [ -f "$LIB_DENY" ]; then
	# shellcheck source=../_lib/hook-deny.sh
	source "$LIB_DENY"
else
	hook_deny() {
		echo "$1: $2" >&2
		exit 2
	}
fi
if [ -f "$LIB_SENTINEL" ]; then
	# shellcheck source=../_lib/hook-inline-sentinel.sh
	source "$LIB_SENTINEL"
else
	hook_inline_sentinel_check() { return 1; }
fi

# Inline-sentinel bypass.
if hook_inline_sentinel_check "ISSUE_BEFORE_CODE_SKIP" "$CMD" "issue-before-code"; then
	exit 0
fi

# Extract branch name — everything after `-b feat/` or `-c feat/` up to
# whitespace/semicolon/ampersand/end-of-command.
BRANCH=$(printf '%s' "$CMD" | grep -oE '(checkout -b|switch -c)[[:space:]]+feat/[^[:space:];&|]+' | head -1 | sed -E 's/^(checkout -b|switch -c)[[:space:]]+//')
if [ -z "$BRANCH" ]; then
	# Pattern matched case but regex failed to extract — fail-open for
	# weird spacing rather than block legit commands.
	exit 0
fi

# Extract issue number from branch name (vX.Y-Z/NNN, vX.Y-Z, or #NNN).
# Matches in order:
#   1. feat/#NNN-description → direct NNN.
#   2. feat/vX.Y-Z/NNN-slug → NNN as path-segment digit cluster after
#      the version prefix. Disambiguates when multiple sub-issues share
#      the same vX.Y-Z prefix (the version-prefix search would pick the
#      first match alphabetically and silently route to the wrong issue).
#      v4.28-W4 (#708): added because feat/v4.28-W4/708-... resolved to
#      #710 — the first of seven v4.28-W4 siblings — even though the
#      branch was clearly tagged with 708.
#   3. feat/vX.Y-Z/... with no NNN segment → lookup via gh issue search.
#
# code-reviewer r1 #2: branch-pattern regex is now SSOT'd here so the
# path-NNN extractor + version-prefix extractor stay in lockstep if
# the `feat/vX.Y-Z` convention ever changes.
VER_PREFIX_RE='^feat/v[0-9]+\.[0-9]+-[A-Za-z0-9]+'
ISSUE_NUM=""
if echo "$BRANCH" | grep -qE '#[0-9]+'; then
	ISSUE_NUM=$(echo "$BRANCH" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
fi

if [ -z "$ISSUE_NUM" ]; then
	ISSUE_NUM=$(echo "$BRANCH" | grep -oE "${VER_PREFIX_RE}/[0-9]+" | head -1 | grep -oE '/[0-9]+$' | tr -d '/')
fi

# Fall back to version-prefix resolution (feat/v4.24-L/... → lookup the
# sub-issue titled "v4.24-L:" under the v4.24 epic). Slower but handles
# the `vX.Y-Z/...` convention this repo uses when no NNN segment exists.
#
# silent-failure-hunter r2 #1 (CRITICAL): prior `2>/dev/null || echo ""`
# masked transient gh API errors (5xx, network, rate-limit) and let them
# fall through to the L108 "no resolvable issue link" deny — operator
# saw "File the issue first" guidance when the real cause was a
# transient backend error. This is a BLOCKING hook; misleading deny =
# wasted user time + bypass via ISSUE_BEFORE_CODE_SKIP. Same r1 #2
# pattern: capture rc separately + advisory exit on API failure (not
# deny — issue resolution can't proceed without the API).
if [ -z "$ISSUE_NUM" ]; then
	VER_PREFIX=$(echo "$BRANCH" | grep -oE "$VER_PREFIX_RE" | head -1 | sed 's,^feat/,,')
	if [ -n "$VER_PREFIX" ] && command -v gh >/dev/null 2>&1; then
		# CR Phase 2 minor: pass VER_PREFIX via jq --arg instead of shell-
		# interpolating into the gh --jq filter. Direct interpolation
		# would let a hostile branch-name VER_PREFIX inject jq syntax.
		# gh's `--jq` flag only takes a string filter (no --arg), so we
		# split: gh emits raw JSON, jq applies the filter with --arg.
		# Capture gh output to a var BEFORE piping to jq — this hook has
		# `set -u` only (no pipefail), so a failing gh in a pipe would
		# silently propagate jq's rc instead of gh's. Two-step gives us
		# correct rc-capture for the existing gh_rc-branch advisory.
		gh_err=$(mktemp)
		gh_rc=0
		gh_out=$(gh issue list --state all --search "$VER_PREFIX:" --json number,title 2>"$gh_err") || gh_rc=$?
		if [ "$gh_rc" -eq 0 ]; then
			# CR Phase 2 r4 trivial: guard jq failure same as the assignee
			# block below so ISSUE_NUM stays empty (falls through to deny)
			# rather than tripping `set -u`.
			jq_err=$(mktemp)
			ISSUE_NUM=$(printf '%s' "$gh_out" | jq -r --arg ver "$VER_PREFIX:" '[.[] | select(.title | startswith($ver))] | .[0].number // empty' 2>"$jq_err") || ISSUE_NUM=""
			rm -f "$jq_err"
		fi
		if [ "$gh_rc" -ne 0 ]; then
			echo "issue-before-code: gh issue list for $VER_PREFIX failed (rc=$gh_rc) — skipping ($(head -c 200 "$gh_err"))" >&2
			rm -f "$gh_err"
			exit 0
		fi
		rm -f "$gh_err"
	fi
fi

if [ -z "$ISSUE_NUM" ]; then
	hook_deny "issue-before-code" \
		"branch '$BRANCH' has no resolvable issue link (expected #NNN or vX.Y-Z prefix matching an open issue title). File the issue first or bypass: ISSUE_BEFORE_CODE_SKIP=1 ISSUE_BEFORE_CODE_SKIP_REASON=\"...\" <cmd>"
fi

# Verify the issue is assigned to current user.
if ! command -v gh >/dev/null 2>&1; then
	# gh missing = can't verify; fail-open.
	exit 0
fi

# silent-failure-hunter r1 #1 + r3 #1: prior `2>/dev/null` discarded
# stderr entirely; operator saw "gh auth failed" advisory whether the
# real cause was auth, network, rate-limit, or 5xx. Now: rc-branch +
# tempfile-stderr so the advisory carries the actual failure context.
gh_err=$(mktemp)
gh_rc=0
ME=$(gh api user --jq .login 2>"$gh_err") || gh_rc=$?
if [ "$gh_rc" -ne 0 ]; then
	echo "issue-before-code: gh api user failed (rc=$gh_rc) — skipping assignee verification ($(head -c 200 "$gh_err"))" >&2
	rm -f "$gh_err"
	exit 0
fi
rm -f "$gh_err"
if [ -z "$ME" ]; then
	echo "issue-before-code: gh api user returned empty login — skipping assignee verification" >&2
	exit 0
fi

# silent-failure-hunter r1 #2: prior `gh issue view ... 2>/dev/null ||
# echo "false"` made API failure (network, 5xx, rate-limit) indistin-
# guishable from a genuinely-unassigned issue — operator saw the
# "NOT assigned to" deny, blamed assignment, but the real cause was a
# transient gh API error. Capture rc separately so we can branch on it.
# CR Phase 2 minor: same jq-injection-safe pattern as the version-prefix
# fallback above — capture gh output to a var first (this hook has set -u
# only, no pipefail; a piped gh would propagate jq's rc instead of gh's),
# then pipe through jq with --arg.
gh_err=$(mktemp)
gh_rc=0
gh_out=$(gh issue view "$ISSUE_NUM" --json assignees 2>"$gh_err") || gh_rc=$?
if [ "$gh_rc" -ne 0 ]; then
	# API failed — different message + advisory exit. Don't deny on a
	# transient backend error.
	echo "issue-before-code: gh issue view #$ISSUE_NUM failed (rc=$gh_rc) — skipping assignee verification ($(head -c 200 "$gh_err"))" >&2
	rm -f "$gh_err"
	exit 0
fi
rm -f "$gh_err"

# CR Phase 2 r4 trivial #2: jq could fail on malformed JSON (rare but
# possible if gh schema changes or returns truncated content). Without
# this guard, ASSIGNED stays unset → next `[ "$ASSIGNED" != "true" ]`
# aborts under `set -u`. Capture jq stderr + default to advisory-exit.
jq_err=$(mktemp)
jq_rc=0
ASSIGNED=$(printf '%s' "$gh_out" | jq -r --arg me "$ME" '[.assignees[].login] | any(. == $me)' 2>"$jq_err") || jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
	echo "issue-before-code: jq failed parsing assignees (rc=$jq_rc) — skipping verification ($(head -c 200 "$jq_err"))" >&2
	rm -f "$jq_err"
	exit 0
fi
rm -f "$jq_err"

if [ "$ASSIGNED" != "true" ]; then
	hook_deny "issue-before-code" \
		"#$ISSUE_NUM (resolved from '$BRANCH') is NOT assigned to $ME. Run .claude/scripts/board/assign-self.sh $ISSUE_NUM first OR bypass: ISSUE_BEFORE_CODE_SKIP=1 ISSUE_BEFORE_CODE_SKIP_REASON=\"...\" <cmd>"
fi

exit 0
