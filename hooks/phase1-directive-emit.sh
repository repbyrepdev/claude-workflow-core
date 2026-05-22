#!/bin/bash
# CR-in-CI #732 r2 major: relaxed `set -euo pipefail` → `set -u` only.
# This hook is documented as INTENTIONAL fail-open (UserPromptSubmit
# is optional context-injection); strict-mode would abort on any
# transient I/O hiccup and inadvertently block the user's prompt
# (`set -e` exits the hook non-zero, which Claude Code may interpret
# as a hook failure). Keeping `-u` catches typos at write-time;
# dropping `-e` + `-o pipefail` keeps the hook resilient under all
# observed I/O failure modes (corrupt .git, missing marker, race-
# rm during read). Per-call short-circuits below still surface
# meaningful errors via `|| exit 0` for fail-open behavior.
set -u
# auto-register: false
# v4.28-W4 (#732): UserPromptSubmit hook — surface the ship-pr-cycle
# phase1 directive to Claude when the orchestrator wrote a marker
# (i.e. state=phase1 + clean_streak<2 at last `cmd_next` invocation).
# Replaces the gap where post-commit-ship-cycle.sh fires `resume`
# detached: stdout lands in a log Claude doesn't read by default,
# so the directive was silent. Now: marker file → additionalContext.
#
# Marker is at .claude/.session-state/ship-cycle/<sha>.phase1-directive.txt
# (written by ship-pr-cycle.sh `_write_phase1_directive_marker`,
# cleared by `_clear_phase1_directive_marker` on stage transition).
#
# Hook reads stdin JSON (Claude Code UserPromptSubmit envelope) but
# doesn't need any field — the marker check is global per-repo.
# Output goes to stdout, which Claude Code injects as additionalContext.

# INTENTIONAL fail-open via `|| exit 0`: this is an OPTIONAL
# context-injection hook (UserPromptSubmit chain). When path
# resolution fails we silently no-op and let the user's prompt
# proceed unblocked — the hook's value is opportunistic surfacing
# of the phase1 directive marker, not a critical control. A failure
# here must NOT degrade the user's interactive experience.
# CR-in-CI r3 major: resolve REPO_ROOT via BASH_SOURCE (script
# location), NOT git rev-parse. The hook lives inside the target
# repo; if Claude invokes it from a different repo's CWD, git
# rev-parse points at the wrong tree and the marker lookup misses.
# Script-relative resolution binds the hook to its OWN repo
# regardless of caller CWD.
# `PHASE1_DIRECTIVE_REPO_OVERRIDE` env var is bats-fixture only —
# allows tests to point the hook at a tmp-dir state tree without
# needing to copy the script into the fixture. Production callers
# never set it.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 0
REPO_ROOT="${PHASE1_DIRECTIVE_REPO_OVERRIDE:-$(cd "$SCRIPT_DIR/../.." && pwd)}" || exit 0

SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null) || exit 0
[ -n "$SHA" ] || exit 0

MARKER="$REPO_ROOT/.claude/.session-state/ship-cycle/$SHA.phase1-directive.txt"
[ -f "$MARKER" ] || exit 0
[ -r "$MARKER" ] || exit 0

# Sanity-cap marker size so a runaway write can't exhaust Claude's
# context. The directive is ~600 bytes today; 8 KiB is generous and
# guards against future regressions.
if [ "$(wc -c <"$MARKER")" -gt 8192 ]; then
	echo "phase1-directive-emit: marker $MARKER exceeds 8 KiB — refusing to emit (file likely corrupt; rm and re-run ship-pr-cycle.sh next)" >&2
	exit 0
fi

# Drain stdin via jq so the JSON envelope is parsed (validates format
# per project guideline `.claude/hooks/*.sh: REQUIRE: JSON stdin
# parsed via jq, never grep/sed`). Fail-open on malformed JSON —
# the hook's advisory contract means we'd rather no-op silently
# than block the user's prompt with a parse error.
# (CR-in-CI r4 major: was raw `cat >/dev/null` which treated any
# malformed envelope as success.)
jq empty >/dev/null 2>&1 || exit 0

# CR-in-CI #733 r4 minor: avoid embedding $(cat "$MARKER") inside a
# heredoc — if the marker file ever contains a line equal to the
# heredoc terminator (`EOF`), the heredoc would truncate. Use printf
# + cat composition instead so any marker content is safe regardless
# of what tokens it contains.
printf '[ship-pr-cycle phase1-directive — auto-emitted from %s]\n\n' "$MARKER"
cat "$MARKER"
printf '\n[end directive — clear via '\''ship-pr-cycle.sh next'\'' once Phase 1 round logged]\n'
