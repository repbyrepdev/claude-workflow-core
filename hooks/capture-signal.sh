#!/bin/bash
set -euo pipefail
# event: UserPromptSubmit
# bats-required: 0  # meta-learning capture (no behavior to assert beyond grep gate)
# UserPromptSubmit hook — capture correction + positive + frustration signals
# from user messages to .claude/session-log.jsonl for later /retro analysis.
#
# Two-pass approach: fast grep gate here (keep this hook <50ms), semantic
# classification happens later in the /retro skill via Claude-as-classifier.
# Err on the side of over-capturing — filter at retro-time, not capture-time.
#
# Part of v3.19 meta-learning infrastructure (#231).
#
# Word boundaries: bash's `[[ =~ ]]` uses POSIX ERE and does NOT support \b.
# Use `grep -w` with ERE patterns instead.

# Telemetry: log hook run at exit (from _lib.sh)
_HOOK_START=$(date +%s)
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh" 2>/dev/null || true
trap 'hook_log_run "$0" "$?" "$_HOOK_START" 2>/dev/null || true' EXIT

# Resolve LOG_DIR from script location, NOT caller CWD. Auto-registered hooks
# can fire from any subdirectory the user happens to be in; relative `.claude`
# would write `<cwd>/.claude/session-log.jsonl` and fragment capture history
# across multiple working dirs (Class A cwd-recovery; v4.28-W1 #638).
_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LOG_DIR="$(cd -- "$_SCRIPT_DIR/../.." && pwd)/.claude"
LOG_FILE="$LOG_DIR/session-log.jsonl"
ARCHIVE_DIR="$LOG_DIR/session-log-archive"
MAX_AGE_HOURS=24

input=$(cat 2>/dev/null || true)
msg=$(echo "$input" | jq -r '.prompt // .user_prompt // .message // empty' 2>/dev/null || true)
[ -z "$msg" ] && exit 0

# Normalize: DELETE apostrophes (so "don't" → "dont", not "don t"), then
# convert remaining punctuation to spaces, then lowercase.
lower=$(echo "$msg" | tr -d "'" | tr "[:punct:]" " " | tr "[:upper:]" "[:lower:]")

# v3.21 #270: pre-filter common conversational false-positives BEFORE regex match.
# "no problem" / "no worries" / "no issue" are ACKs, not corrections. Drop them
# to reduce /retro proposal noise. Over-capture philosophy preserved for novel
# patterns; explicit known-acks pruned here.
#
# CR #301 edge-case fix: only skip if the ACK is the ENTIRE message (not buried
# in a longer real correction like "no worries, but wait that's wrong" — which
# IS a real correction despite leading with an ACK). Bound by word count.
word_count=$(printf '%s\n' "$lower" | wc -w | tr -d ' ')
[ -n "$word_count" ] || word_count=0
if [ "$word_count" -le 4 ] && echo "$lower" | grep -Eq "^(no problem|no worries|no issue|no big deal|no thanks|no doubt|no biggie)( proceed| go| ok| thanks)?[[:space:]]*$"; then
	exit 0
fi

match_class() {
	# $1 = class name, $2 = ERE alternation
	# uses: $lower (global, defined earlier in this script)
	# Need to distinguish three grep outcomes: match (rc=0) → print + return 0;
	# no-match (rc=1) → return 0 silently; exec error (rc>1) → fail closed.
	# Two patterns considered + rejected:
	#   * Bare `match=$(grep); rc=$?` — aborts under set -e on grep failure
	#     before the rc-capture line runs (verified empirically).
	#   * `if match=$(grep); then ...; fi; rc=$?` — exempt from set -e but
	#     after `fi` $? is 0 on the false-condition path per bash(1), so rc
	#     captures 0 not grep's actual rc. Dogfood-verified r18 against
	#     `[invalid` and `xyz` patterns: both reported rc=0 under this form,
	#     hiding the rc=2 grep error.
	# Correct form: `cmd || rc=$?`. The `||` short-circuit is exempt from
	# set -e and runs only on grep failure — capturing grep's real rc.
	local class_name="$1" pattern="$2" match rc=0
	match=$(printf '%s\n' "$lower" | grep -Eom1 "$pattern") || rc=$?
	if [ "$rc" -eq 0 ]; then
		printf '%s\t%s' "$class_name" "$match"
		return 0
	fi
	[ "$rc" -eq 1 ] && return 0
	return "$rc"
}

# Priority: correction > positive > frustration.
# - Correction wins first (most actionable signal)
# - Positive before frustration (less likely to false-positive on ambiguous words)
# - Frustration uses PHRASE patterns (multi-word) to avoid over-triggering on
#   common words like "keep" or "why"
# match_class now returns 0 on both no-match AND match (with empty/non-empty
# output respectively) — only real grep errors propagate. So `|| true`
# wrapping is unnecessary and would mask legitimate failures.
sig=$(match_class correction '\b(no|nope|dont|stop|wait|actually|revert|redo|undo|wrong|missing|circles|slow down|think harder|take a step back|focus|not quite|back out)\b')
[ -z "$sig" ] && sig=$(match_class positive '\b(yes|yep|yeah|exactly|perfect|great|correct|nice|works|ship it|go go go|keep doing|good call)\b')
[ -z "$sig" ] && sig=$(match_class frustration '\b(ugh|wtf|you keep|why are you|please just|stop doing|we already tried|going in circles)\b')

[ -z "$sig" ] && exit 0

signal_type=$(echo "$sig" | cut -f1)
matched=$(echo "$sig" | cut -f2)

mkdir -p "$LOG_DIR" "$ARCHIVE_DIR"
if [ -f "$LOG_FILE" ]; then
	file_mtime=$(stat -f %m "$LOG_FILE" 2>/dev/null || stat -c %Y "$LOG_FILE" 2>/dev/null || date +%s)
	age_min=$((($(date +%s) - file_mtime) / 60))
	if [ "$age_min" -gt $((MAX_AGE_HOURS * 60)) ]; then
		mv "$LOG_FILE" "$ARCHIVE_DIR/$(date -u +%Y-%m-%dT%H%M%S).jsonl"
	fi
fi

# Redact obvious secrets (conservative)
excerpt=$(echo "$msg" | head -c 300 | tr '\n' ' ' | sed -E 's/(sk-|ghp_|gho_|github_pat_)[A-Za-z0-9_]{20,}/<REDACTED>/g; s/AKIA[0-9A-Z]{16}/<REDACTED>/g')

jq -nc \
	--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg sig "$signal_type" \
	--arg matched "$matched" \
	--arg excerpt "$excerpt" \
	--arg sid "${CLAUDE_SESSION_ID:-$$}" \
	'{timestamp: $ts, signal_type: $sig, matched_phrase: $matched, excerpt: $excerpt, session: $sid}' >>"$LOG_FILE"

exit 0
