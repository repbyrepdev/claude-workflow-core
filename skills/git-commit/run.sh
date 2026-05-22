#!/bin/bash
set -euo pipefail
# v4.28-W3-CD (#675): git-commit skill wrapper — Copilot-draft DEFAULT.
#
# Wraps `git commit` to satisfy skill-bypass-guard (sets SKILL_WRAPPER=1)
# while validating the commit message against the .github/commit-template.yml
# SSOT and ensuring the Co-Authored-By trailer is present.
#
# **Default behavior change (v4.28-W3-CD):** when no --message or
# --message-file is supplied, the wrapper now auto-drafts via Copilot
# free-tier (gpt-4.1 / gpt-5-mini / gpt-4o, 0× premium multiplier on
# Enterprise seats). The prior behavior (refuse with "no commit message
# provided") was a UX gap — operators had to write the message inline
# AND invoke the wrapper. Now the wrapper does the writing.
#
# Opt-out:
#   --no-copilot               (per-invocation flag)
#   COPILOT_DRAFT_OFF=1        (env var, useful for trusted-edit flows)
#   --message / --message-file (explicit message takes precedence over draft)
#
# Backward compat: --copilot-draft remains a no-op flag (same as default).
#
# Usage:
#   .claude/skills/git-commit/run.sh                              # auto-draft
#   .claude/skills/git-commit/run.sh --message "<msg>" [--add <pathspec>]...
#   .claude/skills/git-commit/run.sh --message-file <path> [--add <pathspec>]...
#   .claude/skills/git-commit/run.sh --no-copilot --message "<msg>"
#
# Exit codes:
#   0 — commit succeeded
#   2 — arg / validation error
#   3 — Copilot-default attempted but unavailable + no fallback message
#       (use --message / --message-file or set COPILOT_DRAFT_OFF=1 + provide one)
#   4 — Copilot-drafted message failed schema preflight (full template
#       validation against .github/commit-template.yml SSOT). Operator-
#       supplied messages stay warn-only; only Copilot drafts are
#       fail-closed since the operator can't review the draft live.
#   non-zero from git — pre-commit hook failure (shown verbatim)

# CR-in-CI #743 r1 major: handle --help BEFORE repo discovery so `run.sh
# --help` outside a repo prints usage instead of erroring with rc=2.
for arg in "$@"; do
	case "$arg" in
	-h | --help)
		sed -n '4,34p' "$0"
		exit 0
		;;
	esac
done

# Resolve REPO_ROOT from current dir (not script location) so the wrapper
# operates on whatever repo the caller is in — required for tests that run
# inside a temporary repo.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "error: not in a git repo" >&2
	exit 2
}
cd "$REPO_ROOT"

MESSAGE=""
MESSAGE_FILE=""
# COPILOT_DRAFT: legacy opt-in flag; Copilot-draft is now DEFAULT
# (v4.28-W3-CD #675). Kept as a no-op flag for backward compat with
# existing callers (commit hooks, scripts, docs that still pass
# --copilot-draft). The variable is set by the arg parser but not
# read — shellcheck disable is intentional, not dead code.
# shellcheck disable=SC2034
COPILOT_DRAFT=0
NO_COPILOT=0
ADD_PATHS=()
DRY_RUN=0

while [ "$#" -gt 0 ]; do
	case "$1" in
	--message)
		[ "$#" -ge 2 ] || {
			echo "error: --message requires a value" >&2
			exit 2
		}
		MESSAGE="$2"
		shift 2
		;;
	--message-file)
		[ "$#" -ge 2 ] || {
			echo "error: --message-file requires a value" >&2
			exit 2
		}
		MESSAGE_FILE="$2"
		shift 2
		;;
	--copilot-draft)
		# Legacy flag — Copilot-draft is now the default. Kept as a
		# no-op for backward compat with existing callers/scripts.
		# shellcheck disable=SC2034 # intentional no-op assignment
		COPILOT_DRAFT=1
		shift
		;;
	--no-copilot)
		# Opt out of the v4.28-W3-CD Copilot-default. Caller must
		# supply --message or --message-file (or rely on env).
		NO_COPILOT=1
		shift
		;;
	--add)
		[ "$#" -ge 2 ] || {
			echo "error: --add requires a value" >&2
			exit 2
		}
		ADD_PATHS+=("$2")
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	-h | --help)
		# Already handled in pre-repo-discovery loop above; this case
		# is dead but kept for parser-symmetry. Should never fire in
		# practice (the pre-loop exits 0).
		sed -n '4,34p' "$0"
		exit 0
		;;
	*)
		echo "error: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

# v4.28-W3-CD (#675): also honor env-var opt-out for COPILOT_DRAFT_OFF=1.
if [ "${COPILOT_DRAFT_OFF:-0}" = "1" ]; then
	NO_COPILOT=1
fi

# v4.24 (#597): commit-template.yml is the SSOT for commit-message schema.
TEMPLATE_YAML="$REPO_ROOT/.github/commit-template.yml"
if [ ! -f "$TEMPLATE_YAML" ]; then
	echo "warn: $TEMPLATE_YAML missing — skipping schema validation" >&2
fi

# Stage requested paths first (run BEFORE message resolution so a Copilot
# draft can read the actual staged diff, not the working-tree).
if [ "${#ADD_PATHS[@]}" -gt 0 ]; then
	git add -- "${ADD_PATHS[@]}"
fi

# Message resolution (v4.28-W3-CD #675):
#   1. --message-file (explicit override)
#   2. --message (already in $MESSAGE from arg-parsing — explicit override)
#   3. Copilot-draft DEFAULT (when no message + not opted out)
#   4. Refuse with rc=3 when Copilot unavailable + no opt-out + no fallback
if [ -n "$MESSAGE_FILE" ]; then
	[ -f "$MESSAGE_FILE" ] || {
		echo "error: --message-file '$MESSAGE_FILE' not found" >&2
		exit 2
	}
	MESSAGE=$(cat "$MESSAGE_FILE")
elif [ -z "$MESSAGE" ] && [ "$NO_COPILOT" = "0" ]; then
	# Default path: try Copilot draft. Refuse on unavailability or
	# empty output — operators get a clear remediation hint.
	COPILOT_HELPER="$REPO_ROOT/.claude/scripts/copilot/try-free.sh"
	if [ ! -x "$COPILOT_HELPER" ]; then
		echo "error: Copilot-draft default unavailable — $COPILOT_HELPER missing/non-executable" >&2
		echo "  hint: pass --message / --message-file, or set COPILOT_DRAFT_OFF=1 + provide one" >&2
		exit 3
	fi
	if command -v yq >/dev/null 2>&1 && [ -f "$TEMPLATE_YAML" ]; then
		SCHEMA=$(yq -o=json '.' "$TEMPLATE_YAML")
	else
		SCHEMA="(commit-template.yml unavailable)"
	fi
	echo "drafting commit message via Copilot free-tier…" >&2
	# CR-in-CI #743 r1 major: capture helper exit code properly. The
	# prior `|| echo ""` swallowed rc and could land a partial-stdout
	# draft when the helper exited non-zero AFTER writing some output.
	# Fix: capture rc separately; refuse if non-zero OR empty.
	# CR-in-CI #743 r2 major: export SKILL_WRAPPER=1 so any nested
	# `gh`/`git` calls inside try-free.sh satisfy skill-bypass-guard.
	COPILOT_RC=0
	MESSAGE=$(SKILL_WRAPPER=1 git diff --cached |
		SKILL_WRAPPER=1 "$COPILOT_HELPER" "Draft a commit message for the staged diff. Schema: $SCHEMA. Output the message body only (no preamble, no trailing notes). End with 'Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>' on its own line." 2>/dev/null) || COPILOT_RC=$?
	if [ "$COPILOT_RC" -ne 0 ] || [ -z "$MESSAGE" ]; then
		echo "error: Copilot draft returned empty (rc=$COPILOT_RC) — Copilot CLI auth/network issue?" >&2
		echo "  hint: pass --message / --message-file, or set COPILOT_DRAFT_OFF=1 + provide one" >&2
		exit 3
	fi
	# CR-in-CI #743 r1 major (outside-diff): preflight schema validation
	# on the Copilot draft. Fail-closed so a malformed auto-draft can't
	# land in history. Operator-supplied messages keep the warning-only
	# behavior below — only Copilot drafts get strict-checked.
	MESSAGE_FROM_COPILOT=1
fi

if [ -z "$MESSAGE" ]; then
	# This branch reachable only when NO_COPILOT=1 + no --message/-file
	echo "error: no commit message provided + --no-copilot/COPILOT_DRAFT_OFF=1 set" >&2
	echo "  hint: pass --message or --message-file, or remove --no-copilot" >&2
	exit 2
fi

# CR-in-CI #743 r2 major: delegate to factored validator (.claude/scripts/
# commit/validate-message.sh) — full SSOT schema check, not just lightweight
# inline lint. Single SSOT for commit-message rules; same validator post-
# commit-template-lint.sh now uses. For Copilot drafts: rc != 0 → exit 4.
# For operator-supplied: warn-only (validator stderr → user, then proceed).
VALIDATOR="$REPO_ROOT/.claude/scripts/commit/validate-message.sh"
LINT_RC=0
if [ -x "$VALIDATOR" ]; then
	VALIDATOR_OUT=$(printf '%s' "$MESSAGE" | "$VALIDATOR" 2>&1 >/dev/null) || LINT_RC=$?
	if [ "$LINT_RC" -ne 0 ] && [ -n "$VALIDATOR_OUT" ]; then
		# Surface validator warnings to stderr regardless of source
		# (operator gets to see them and decide; Copilot path also
		# fails-closed below).
		printf '%s\n' "$VALIDATOR_OUT" >&2
	fi
	if [ "$LINT_RC" -ne 0 ] && [ "${MESSAGE_FROM_COPILOT:-0}" = "1" ]; then
		echo "error: Copilot-drafted message failed schema preflight — refusing to commit." >&2
		echo "  hint: re-run + Copilot will redraft, or pass --message / --message-file with a fixed message." >&2
		exit 4
	fi
else
	echo "warn: validator missing at $VALIDATOR — skipping schema preflight" >&2
fi

if [ "$DRY_RUN" = "1" ]; then
	echo "=== --dry-run: would commit with message ==="
	printf '%s\n' "$MESSAGE"
	echo "=== end ==="
	exit 0
fi

# Hand off to git commit. SKILL_WRAPPER=1 satisfies skill-bypass-guard.
# Use a tempfile to preserve multi-line message + special chars.
TMP_MSG=$(mktemp -t git-commit-msg.XXXXXX)
trap 'rm -f "$TMP_MSG"' EXIT
printf '%s\n' "$MESSAGE" >"$TMP_MSG"

# v4.28-W5 #780: post-condition verification + hook-ack on commit-didn't-land.
# Pre-commit auto-fix conflicts, memory-index-valid violations, bats-gate
# failures, etc. can abort the commit. Without this verify, the wrapper's
# rc gets clobbered by downstream pipes (`| tail -N`) — caller sees rc=0
# and thinks commit landed. Now: capture HEAD before/after, write to the
# hook-ack-pending sentinel when HEAD didn't advance so the operator's
# next Bash tool call is blocked until they Read the diagnostic.
HEAD_BEFORE=$(git rev-parse HEAD 2>/dev/null || echo "")
COMMIT_OUT=$(mktemp -t git-commit-out.XXXXXX)
trap 'rm -f "$TMP_MSG" "$COMMIT_OUT"' EXIT
# CR-in-CI #780 r2 CRITICAL: `set -euo pipefail` (line 2) exits on the
# first non-zero in the pipeline — bash never reaches the COMMIT_RC=...
# capture, so the entire failure-handling block below was dead code on
# the exact path it was meant to cover. Disable errexit around the
# pipeline only; restore immediately so the rest of the script keeps
# strict-mode semantics.
set +e
SKILL_WRAPPER=1 git commit --file="$TMP_MSG" 2>&1 | tee "$COMMIT_OUT"
COMMIT_RC=${PIPESTATUS[0]}
set -e
HEAD_AFTER=$(git rev-parse HEAD 2>/dev/null || echo "")

if [ "$HEAD_BEFORE" = "$HEAD_AFTER" ]; then
	# Commit did NOT land. Surface via hook-ack-pending so the next
	# Bash call is blocked until the operator Reads the diagnostic.
	# CR-in-CI #780 r2 trivial: use existing $REPO_ROOT (resolved at
	# line 54 + cd'd at line 58) instead of re-running git rev-parse.
	# CR-in-CI #780 r3 MAJOR: ack-file persistence is best-effort —
	# if mkdir/write fails (read-only fs, disk full, perms), don't let
	# `set -e` exit before the operator-facing stderr guidance lands.
	# shellcheck source=../../_lib/hook-ack.sh
	HOOK_ACK_LIB="$REPO_ROOT/.claude/_lib/hook-ack.sh"
	ACK_FILE=""
	if [ -f "$HOOK_ACK_LIB" ]; then
		# Write the failure diagnostic to a sentinel file the operator
		# Reads to ack. Filename includes timestamp so multiple commit
		# attempts in a session don't collide.
		ACK_DIR=".claude/.session-state/hook-ack/git-commit"
		ACK_FILE="$ACK_DIR/$(date -u +%Y%m%dT%H%M%SZ)-commit-aborted-$$.txt"
		ACK_FILE_ABS="$REPO_ROOT/$ACK_FILE"
		if mkdir -p "$ACK_DIR" >/dev/null 2>&1 && {
			echo "Commit attempt aborted — HEAD did not advance."
			echo ""
			echo "HEAD before: $HEAD_BEFORE"
			echo "HEAD after:  $HEAD_AFTER"
			echo "Wrapper rc:  $COMMIT_RC"
			echo ""
			echo "=== Common causes + fixes ==="
			echo "1. pre-commit auto-fix conflict (shfmt/shellcheck/semgrep rewrote a"
			echo "   staged file): re-stage the file (git add ...) and retry."
			echo "2. memory-index-valid: feedback memory missing **Why:** or **How to"
			echo "   apply:** sections. Fix the memory file content."
			echo "3. bats-gate assertion-weakening: tests removed/weakened assertions."
			echo "   Fix tests OR set TEST_GATE_WEAKEN_OK=1 with a recorded reason."
			echo "4. Commit-message validation drift: subject >70 chars, missing"
			echo "   Co-Authored-By, etc."
			echo ""
			echo "=== Last 80 lines of pre-commit output ==="
			tail -80 "$COMMIT_OUT" 2>/dev/null
		} >"$ACK_FILE_ABS" 2>/dev/null; then
			# shellcheck source=../../_lib/hook-ack.sh
			source "$HOOK_ACK_LIB" 2>/dev/null || true
			if command -v hook_ack_append >/dev/null 2>&1; then
				hook_ack_append "git-commit" "commit-aborted" "$ACK_FILE_ABS" 2>/dev/null || true
			fi
		else
			echo "git-commit: WARN: failed to persist hook-ack diagnostic at $ACK_FILE_ABS" >&2
			ACK_FILE=""
		fi
	fi
	# Operator-facing stderr always lands, even if ack persistence failed.
	echo "" >&2
	echo "git-commit: ERROR: commit did not land (HEAD unchanged)." >&2
	[ -n "$ACK_FILE" ] && echo "git-commit: diagnostic written to $ACK_FILE — Read it before retrying." >&2
	echo "" >&2
	exit 1
fi
exit "$COMMIT_RC"
