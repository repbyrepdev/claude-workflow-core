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
#   - #2547, PLUGIN-SOURCE layout (hooks/*.sh) only, classified events
#     ($EVENT_FRONTMATTER_ENFORCEMENT_REQUIRED_EVENTS — currently PostToolUse):
#       (c) `# enforcement: enforce|inform — <reason>` (closed vocabulary;
#           consumer .claude/hooks/ exempt until migrated — epic #2566)
#
# Bypasses (each emits a SKIP message to stderr; no automatic audit-log):
#   EVENT_FRONTMATTER_SKIP=1              — whole gate (use sparingly)
#   EVENT_FRONTMATTER_ENFORCEMENT_SKIP=1  — rule (c) only
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
ENF_FAILED=()

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
	enforcement="${_parsed[3]:-}"

	# (a) explicit opt-out
	[ "$auto_register" = "false" ] && continue
	# (b) valid event
	if [ -n "$event" ] && event_frontmatter_event_valid "$event"; then
		# (c) #2547: classified events (SSOT list in the lib) must ALSO
		# declare enforce-vs-inform, fail-closed at commit time — the same
		# placement as the event requirement itself (phase1 r1: a
		# bats-only check fires long after an unclassified hook lands).
		# The raw value rides parse's 4th line; the CLOSED vocabulary is
		# judged by event_frontmatter_enforcement_valid ("advisory" is
		# unclassified, not a pass).
		#   enforce — the hook blocks on violation via a routed mechanism
		#   inform  — advisory by documented design (say why)
		# PLUGIN-SOURCE LAYOUT ONLY for now (phase1 r3 code-reviewer,
		# conf 8): the exported pre-commit id also fires on consumer
		# .claude/hooks/, where three consumer-authored PostToolUse hooks
		# would newly fail commits under a patch bump with no migration
		# note. Consumers migrate deliberately — widening tracked in epic
		# #2566.
		# EVENT_FRONTMATTER_ENFORCEMENT_SKIP=1 bypasses ONLY this rule
		# (family-prefixed name per the repo's gate/bypass convention;
		# the whole-gate EVENT_FRONTMATTER_SKIP also still works).
		if event_frontmatter_enforcement_required "$event" && [[ $rel == hooks/*.sh ]]; then
			if [ "${EVENT_FRONTMATTER_ENFORCEMENT_SKIP:-}" = "1" ]; then
				echo "event-frontmatter-check: SKIP enforcement classification via EVENT_FRONTMATTER_ENFORCEMENT_SKIP=1 for $f" >&2
			elif ! event_frontmatter_enforcement_valid "$enforcement"; then
				ENF_FAILED+=("$f")
			fi
		fi
		continue
	fi
	FAILED+=("$f")
done

# Report EVERY failure class before the single exit (phase1 r2, three
# reviewers independently: an early exit hid the second class until a
# follow-up commit attempt — a two-pass fix cycle; rc stays fail-closed).
rc=0
if [ "${#ENF_FAILED[@]}" -gt 0 ]; then
	echo "event-frontmatter-check: ${#ENF_FAILED[@]} PostToolUse hook(s) lack the #2547 enforce-vs-inform classification:" >&2
	for f in "${ENF_FAILED[@]}"; do
		echo "  $f" >&2
	done
	cat >&2 <<EOF

Add to the file's first $(event_frontmatter_scan_window) lines (after the matcher line):
  # enforcement: enforce — <how it blocks: hook-ack routing / decision:block>
  # enforcement: inform — <why advisory is the deliberate design>
(The vocabulary is closed: values other than enforce|inform are refused.)

An 'enforce' hook must actually route its failures (hook_ack_append, or a
decision:block JSON response) — .claude/tests/_lib/event-frontmatter-audit.bats pins
that; this gate pins that the classification EXISTS.
Bypass (this rule only): EVENT_FRONTMATTER_ENFORCEMENT_SKIP=1 git commit ...
EOF
	rc=1
fi

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
	rc=1
fi

exit "$rc"
