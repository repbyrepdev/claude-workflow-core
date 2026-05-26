#!/bin/bash
set -euo pipefail
# v0.9.5 (#72) — print the exact ~/.claude/settings.json permissions.allow
# entries that authorize register-hook.sh to write to settings.json.
#
# WHY this script exists:
# The auto-mode classifier hard-blocks ANY programmatic edit to
# ~/.claude/settings.json as "Self-Modification" — even when the operator
# has authorized the action in-session. This is correct default policy
# (a buggy agent shouldn't be able to rewrite its own permissions). The
# classifier exception is operator-set Bash permissions: if the operator
# adds `scripts/register-hook.sh` to permissions.allow, classifier honors
# the rule and the script can write settings.json autonomously.
#
# This installer DOES NOT modify settings.json itself (it CAN'T —
# classifier-blocked). It detects whether the needed permissions are
# present and, if not, prints the exact JSON snippet to paste.
#
# Usage:
#   install-register-hook-permissions.sh           # print status + remediation
#   install-register-hook-permissions.sh --json    # emit just the snippet
#   install-register-hook-permissions.sh --check   # exit 0 if installed, 1 if missing
#
# Exit codes:
#   0 — permissions already present
#   1 — permissions missing (remediation printed; --check returns 1)
#   2 — usage / precondition error
#   3 — settings.json malformed

MODE="status"
while [ "$#" -gt 0 ]; do
	case "$1" in
	--json)
		MODE="json"
		shift
		;;
	--check)
		MODE="check"
		shift
		;;
	-h | --help)
		awk '
			NR == 1 { next }
			/^set / { next }
			/^#/ { in_header = 1; sub(/^# ?/, ""); print; next }
			NF == 0 && in_header { print; next }
			in_header { exit }
		' "$0"
		exit 0
		;;
	-*)
		echo "install-register-hook-permissions.sh: unknown flag '$1'" >&2
		exit 2
		;;
	*)
		echo "install-register-hook-permissions.sh: unexpected positional '$1'" >&2
		exit 2
		;;
	esac
done

if ! command -v jq >/dev/null 2>&1; then
	echo "install-register-hook-permissions.sh: jq required but not installed" >&2
	exit 2
fi

SETTINGS="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"

# Pattern entries to add. These authorize register-hook.sh + its sister
# script install-register-hook-permissions.sh to run without classifier
# prompts. The leading "Bash(" prefix matches Claude Code's permissions
# schema for shell tool invocations.
#
# Security: each pattern ends with an EXACT argument set, NOT a trailing
# wildcard. A trailing `*` in fnmatch matches shell metacharacters
# including ` && `, ` ; `, ` | `, ` $(...) `, so `Bash(.../register-hook.sh*)`
# would let `.../register-hook.sh && rm -rf ~` slip past the classifier.
# By naming each safe argument form explicitly, command-chained variants
# don't satisfy any pattern and re-trigger the classifier prompt.
#
# Path anchoring: each pattern requires `/claude-workflow-core/` as a
# literal path segment. This raises the bar over a bare `*/scripts/...`
# pattern — an attacker dropping a file at `/tmp/x/scripts/register-hook.sh`
# no longer satisfies the pattern. The remaining `*` between
# `claude-workflow-core/` and `scripts/` accommodates BOTH the
# source-repo layout (`<home>/claude-workflow-core/scripts/...`, where
# `*` matches nothing) AND the plugin-cache layout
# (`<home>/.claude/plugins/cache/claude-workflow-core/<version>/scripts/...`,
# where `*` matches the version segment).
#
# Residual risk: an attacker who can create `/tmp/x/claude-workflow-core/`
# (a top-level directory literally named after this project) can still
# satisfy the pattern. Full mitigation requires anchoring to the
# operator's home tree (e.g. `/Users/<name>/...`) which varies per OS +
# user, OR a different non-pattern-based authentication mechanism.
# Deferred — file a follow-up sub-issue under #57 once Anthropic
# publishes a path-realpath-resolution option for Bash() patterns.
#
# Adding new patterns expands the classifier-exemption surface — only
# add scripts whose entire purpose is settings.json maintenance and
# that have been reviewed for self-modification risk.
REQUIRED_PATTERNS=(
	# register-hook.sh — bounded forms for autonomous use.
	"Bash(*/claude-workflow-core/*scripts/register-hook.sh --check)"
	"Bash(*/claude-workflow-core/*scripts/register-hook.sh --check-permissions)"
	"Bash(*/claude-workflow-core/*scripts/register-hook.sh --all-auto-register)"
	"Bash(*/claude-workflow-core/*scripts/register-hook.sh --dry-run --all-auto-register)"
	# install-register-hook-permissions.sh — read-only probe modes.
	"Bash(*/claude-workflow-core/*scripts/install-register-hook-permissions.sh)"
	"Bash(*/claude-workflow-core/*scripts/install-register-hook-permissions.sh --check)"
	"Bash(*/claude-workflow-core/*scripts/install-register-hook-permissions.sh --json)"
)

# --json short-circuits before settings.json access — the snippet shape
# is constant and doesn't depend on current state. Operators on fresh
# machines need this output BEFORE settings.json exists.
if [ "$MODE" = "json" ]; then
	jq -n --argjson reqs "$(printf '%s\n' "${REQUIRED_PATTERNS[@]}" | jq -R . | jq -s .)" '
		{permissions: {allow: $reqs}}
	'
	exit 0
fi

if [ ! -f "$SETTINGS" ]; then
	echo "install-register-hook-permissions.sh: $SETTINGS does not exist" >&2
	echo "  Claude Code not yet installed on this machine, or CLAUDE_SETTINGS_FILE points at the wrong path." >&2
	exit 2
fi
# Surface jq's parse-error detail (line/char position) — settings.json
# is hand-edited per this script's own remediation, so corruption is
# the failure mode that most needs diagnostic context.
if ! jq_err=$(jq empty "$SETTINGS" 2>&1 >/dev/null); then
	echo "install-register-hook-permissions.sh: $SETTINGS is malformed JSON" >&2
	[ -n "$jq_err" ] && echo "  jq: $jq_err" >&2
	exit 3
fi

# Discover which patterns are missing
missing=()
for pat in "${REQUIRED_PATTERNS[@]}"; do
	if ! jq -e --arg p "$pat" '.permissions.allow // [] | any(. == $p)' "$SETTINGS" >/dev/null; then
		missing+=("$pat")
	fi
done

if [ "${#missing[@]}" -eq 0 ]; then
	echo "✓ register-hook.sh permissions are present in $SETTINGS"
	echo "   All ${#REQUIRED_PATTERNS[@]} required patterns allowlisted."
	exit 0
fi

# --check mode just reports presence/absence via exit code
if [ "$MODE" = "check" ]; then
	echo "install-register-hook-permissions.sh: ${#missing[@]} pattern(s) missing from $SETTINGS" >&2
	for p in "${missing[@]}"; do
		echo "  - $p" >&2
	done
	exit 1
fi

# Default mode: status + remediation guidance
cat <<EOF
✗ register-hook.sh permissions are NOT installed in $SETTINGS

Missing patterns:
EOF
for p in "${missing[@]}"; do
	echo "  - $p"
done
cat <<EOF

WHY this matters:
  Claude Code's auto-mode classifier hard-blocks programmatic edits to
  ~/.claude/settings.json as "Self-Modification". With the patterns above
  added to .permissions.allow, the classifier honors the allowlist and
  register-hook.sh can write to settings.json autonomously (plugin
  install/upgrade can then auto-register new hooks without manual edits).

HOW to install:
  1. Open $SETTINGS in an editor.
  2. Find (or create) the "permissions" object.
  3. Inside it, find (or create) the "allow" array.
  4. Append the patterns listed above.
  5. Save the file.

Or run \`scripts/install-register-hook-permissions.sh --json\` to get the
exact JSON snippet to merge.

Once installed, re-run this script to verify: it should print the "✓ present" line.

After verification, register-hook.sh can be invoked autonomously by the
agent + plugin install/upgrade scripts. The classifier still hard-blocks
any OTHER programmatic edit to settings.json — only the allowlisted
patterns are exempt.
EOF
exit 1
