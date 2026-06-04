#!/bin/bash
set -euo pipefail
# v4.28 (#638) — pre-commit gate: every staged hook (consumer- or
# plugin-source layout) must have valid `# event:` frontmatter OR an
# explicit opt-out, so install-hooks.sh + register-hook.sh frontmatter
# scanners can pick it up. Without this, a new hook lands silently
# unwired — the exact paper-tiger pattern we built install-hooks.sh
# to eliminate.
#
# v0.9.5 (#70): plugin-source enforcement (hooks/*.sh) catches the
# SSOT files BEFORE they're copied into consumer .claude/hooks/.
# Without it, a plugin author lands an unwired hook in the source
# repo and only fails the gate in downstream consumer installs.
#
# Layouts covered (collectively `<hook-dir>` below):
#   - .claude/hooks/  (consumer layout — installed plugin path)
#   - hooks/          (plugin source layout — this repo's source-of-truth)
#
# Rules per staged file (apply to both layouts):
#   - <hook-dir>/_*.sh        → skip (helpers, by convention)
#   - <hook-dir>/install-*.sh → skip (installers)
#   - <hook-dir>/*.sh         → MUST contain ONE of:
#       (a) `# event: <PreToolUse|PostToolUse|SessionStart|PreCompact|Stop|UserPromptSubmit>`
#           in the first 30 lines
#       (b) `# auto-register: false` (explicit helper opt-out)
#
# Bypass: EVENT_FRONTMATTER_SKIP=1 (use sparingly — emits a SKIP message to
# stderr so the bypass shows up in pre-commit output, but no automatic
# audit-log file is written).
#
# Exit codes:
#   0 — all staged hooks pass
#   1 — one or more staged hooks lack required frontmatter
#   2 — usage error (no file arguments supplied — pre-commit always passes
#       staged paths, so this fires only on manual invocation)

if [ "${EVENT_FRONTMATTER_SKIP:-}" = "1" ]; then
	echo "event-frontmatter-check: SKIP via EVENT_FRONTMATTER_SKIP=1" >&2
	exit 0
fi

# Source the shared frontmatter library — same SSOT used by install-hooks.sh.
# Both gates parse + validate identically; renaming the helper convention or
# adding a 7th event is a one-file edit.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../_lib/event-frontmatter.sh disable=SC1091
. "$SCRIPT_DIR/../_lib/event-frontmatter.sh"
# v0.34.31 (#2235): consumer-aware canonical-skip — no-op in the plugin itself.
# shellcheck source=../_lib/canonical-consumer-skip.sh disable=SC1091
[ -f "$SCRIPT_DIR/../_lib/canonical-consumer-skip.sh" ] && . "$SCRIPT_DIR/../_lib/canonical-consumer-skip.sh"

# Manual-invocation advisory — pre-commit always supplies args, so empty `$@`
# means a developer ran this directly. Make the no-op visible.
if [ "$#" -eq 0 ]; then
	# Usage error — pre-commit always passes staged paths. exit 2 (not 0)
	# so manual invocation with no args is distinguishable from "all files
	# passed" in CI logs and exit-code-checking shell composition.
	echo "event-frontmatter-check: no files supplied — pre-commit normally passes staged paths. Pass file path(s) to validate manually." >&2
	exit 2
fi

FAILED=()

for f in "$@"; do
	# Normalize absolute → repo-relative so `case` glob works regardless of
	# how pre-commit (or a developer) supplies the path.
	rel="$f"
	case "$f" in
	/*)
		# Capture rc explicitly: a `|| echo ""` would make `repo_root=""` look
		# identical to a successful empty-string capture, leaving `rel`
		# absolute with no signal to the caller. Using `if cmd; then ...`
		# keeps the failure mode visible (rel stays absolute → downstream
		# path-prefix check fails loudly instead of silently passing).
		# Failure-branch warning makes the silent-skip mode (rev-parse failed
		# inside an absolute-path arg) actionable rather than mysteriously
		# omitting the file from the check.
		if repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
			rel="${f#"$repo_root/"}"
		else
			# Fail-closed: rev-parse failure means we can't determine if `f`
			# is under .claude/hooks/ — record as failed rather than silently
			# skipping. Silent skip would let an unchecked hook ship.
			echo "event-frontmatter-check: error: cannot normalize absolute path $f (git rev-parse failed) — treating as failure" >&2
			FAILED+=("$f")
			continue
		fi
		;;
	esac
	# Must be under .claude/hooks/ (consumer layout) OR hooks/ (plugin
	# source layout — #70). pre-commit-hooks/ is excluded; those use a
	# different lifecycle (entry: in .pre-commit-hooks.yaml).
	case "$rel" in
	.claude/hooks/*.sh | hooks/*.sh) ;;
	*) continue ;;
	esac

	# v0.34.31 (#2235): skip canonical hooks in a consumer (validated upstream).
	if command -v canonical_consumer_skip >/dev/null 2>&1 && canonical_consumer_skip "$rel"; then
		continue
	fi

	base=$(basename "$rel")
	if event_frontmatter_skip_basename "$base"; then
		continue
	fi

	[ -f "$f" ] || continue # deletion/rename — nothing to check

	# Use the shared parser. Empty event = no frontmatter found.
	# Capture stdout + rc explicitly: process-substitution `done < <(parse)`
	# would swallow event_frontmatter_parse's rc, so a parse error (missing/
	# unreadable file) reads as "no frontmatter" and silently passes.
	_parsed=()
	if ! _parse_out=$(event_frontmatter_parse "$f"); then
		echo "event-frontmatter-check: error: failed to parse frontmatter in $f" >&2
		FAILED+=("$f")
		continue
	fi
	while IFS= read -r _line; do _parsed+=("$_line"); done <<<"$_parse_out"
	event="${_parsed[0]:-}"
	auto_register="${_parsed[2]:-true}"

	# (a) explicit opt-out
	[ "$auto_register" = "false" ] && continue
	# (b) valid event
	if [ -n "$event" ] && event_frontmatter_event_valid "$event"; then
		continue
	fi
	FAILED+=("$f")
done

if [ "${#FAILED[@]}" -gt 0 ]; then
	echo "event-frontmatter-check: ${#FAILED[@]} staged hook(s) lack required frontmatter:" >&2
	for f in "${FAILED[@]}"; do
		echo "  $f" >&2
	done
	cat >&2 <<EOF

Add ONE of these to the file's first 30 lines:
  # event: <${EVENT_FRONTMATTER_VALID_EVENTS}>
  # event: PreToolUse
  # matcher: Bash       # (optional, for *ToolUse only)

OR if this is a helper script called by other hooks (not directly registered):
  # auto-register: false

Either fix the file(s) above or use an opt-out form:
  - rename with leading underscore (e.g. _helper.sh) — by-convention helpers
  - rename with install- prefix (e.g. install-something.sh) — installer scripts
  - add `# auto-register: false` to the first 30 lines — explicit opt-out
Bypass: EVENT_FRONTMATTER_SKIP=1 git commit ...
EOF
	exit 1
fi

exit 0
