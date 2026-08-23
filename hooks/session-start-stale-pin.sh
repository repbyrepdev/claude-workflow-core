#!/bin/bash
set -euo pipefail
# event: SessionStart
# auto-register: true
# Introduced in #89 — SessionStart hook detecting stale plugin-cache
# refs in ~/.claude/settings.json.
#
# Why: hooks/{...}.sh paths in settings.json embed a hard-coded plugin
# version (e.g. claude-workflow-core/0.8.5/hooks/...). When the plugin
# is updated, new cache dirs get created but settings.json still
# points at the old version — every hook keeps running its STALE copy.
# Multi-month drift is the norm without operator awareness.
#
# Behavior: pure ADVISORY (no deny / no block). Emits a single warning
# line to stderr if drift detected. Reads ~/.claude/settings.json,
# extracts the highest-semver plugin-version path-segment among
# .claude/plugins/cache/claude-workflow-core/claude-workflow-core/<X.Y.Z>/
# refs, compares to the highest cache dir on disk. Warns on BOTH
# directions of asymmetric drift (cache > settings → "update settings",
# settings > cache → "cache may be corrupt").
#
# Env vars:
#   SESSION_START_STALE_PIN_SKIP=1     — bypass entirely
#   SESSION_START_STALE_PIN_SETTINGS   — override settings.json path (test use)
#   SESSION_START_STALE_PIN_CACHE_DIR  — override plugin cache dir (test use)
#
# Limitations (DOCUMENTED, not bugs):
#   - Regex matches X.Y.Z only — pre-release suffixes (X.Y.Z-rc1)
#     are NOT extracted, by design. Pre-release versions aren't part
#     of the plugin's release flow today (#89 spec).
#   - Compares max(settings refs) to max(cache subdirs). A mixed-state
#     settings.json (multiple version refs) is silent if its max
#     equals cache max. See #89-followup for min-vs-max semantics.
#
# Exit codes:
#   0 — always (advisory hook; never block session start)

if [ "${SESSION_START_STALE_PIN_SKIP:-0}" = "1" ]; then
	exit 0
fi

SETTINGS="${SESSION_START_STALE_PIN_SETTINGS:-$HOME/.claude/settings.json}"
CACHE_DIR="${SESSION_START_STALE_PIN_CACHE_DIR:-$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core}"

# No settings.json → not a Claude Code install we can inspect.
[ -f "$SETTINGS" ] || exit 0
# No cache dir → plugin not installed via cache (e.g., dev-from-source).
[ -d "$CACHE_DIR" ] || exit 0

if ! command -v jq >/dev/null 2>&1; then
	# jq missing — silently pass; other hooks nudge install.
	exit 0
fi

# Pre-validate settings.json. Distinguish 'corrupt JSON' (warn before
# silent pass) from 'no plugin-cache refs' (silent).
if ! jq empty "$SETTINGS" 2>/dev/null; then
	echo "session-start-stale-pin: ⚠ $SETTINGS is not valid JSON — skipping drift check (run a JSON linter to fix)" >&2
	exit 0
fi

# Extract the highest semver path-segment from settings.json refs.
# Paths follow: .../claude-workflow-core/claude-workflow-core/<X.Y.Z>/hooks/...
SETTINGS_VER=$(jq -r '
  [.. | strings | select(test("claude-workflow-core/claude-workflow-core/[0-9]+\\.[0-9]+\\.[0-9]+/"))]
  | map(capture("claude-workflow-core/claude-workflow-core/(?<v>[0-9]+\\.[0-9]+\\.[0-9]+)/").v)
  | unique
  | .[]
' "$SETTINGS" 2>/dev/null | sort -V | tail -1 || printf '')

if [ -z "$SETTINGS_VER" ]; then
	# No plugin-cache refs — not pinned, nothing to drift-check.
	exit 0
fi

# Find the highest version on-disk. Use nullglob so empty CACHE_DIR
# doesn't yield literal "$CACHE_DIR/*" that the regex masks as 'no
# semver subdirs'. Use ${entry##*/} instead of basename — bash-builtin,
# immune to PATH shims.
shopt -s nullglob
entries=("$CACHE_DIR"/*)
shopt -u nullglob
CACHE_VER=""
# `"${entries[@]:-}"` form needed because set -u + empty array =
# "unbound variable" on bash 3.2 (the leading-empty-token is harmless
# — it fails the regex on the next line and `continue`s).
for entry in "${entries[@]:-}"; do
	name=${entry##*/}
	[[ $name =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
	if [ -z "$CACHE_VER" ]; then
		CACHE_VER=$name
	else
		higher_cv=$(printf '%s\n%s\n' "$CACHE_VER" "$name" | sort -V | tail -1)
		CACHE_VER=$higher_cv
	fi
done

if [ -z "$CACHE_VER" ]; then
	# Cache dir exists but no semver subdirs — corrupt-cache signal.
	# Don't silent-pass: this is the kind of state operators want
	# surfaced (partial install, wrong path, stripped cache).
	if [ ${#entries[@]} -eq 0 ]; then
		echo "session-start-stale-pin: ⚠ $CACHE_DIR exists but is empty — plugin cache may be corrupt or partially installed" >&2
	else
		echo "session-start-stale-pin: ⚠ $CACHE_DIR has no semver subdirs — plugin cache layout unexpected" >&2
	fi
	exit 0
fi

if [ "$SETTINGS_VER" = "$CACHE_VER" ]; then
	# Up to date — silent pass.
	exit 0
fi

# Determine drift direction. sort -V handles 0.10.0 > 0.9.5 correctly
# (lex sort would invert).
higher=$(printf '%s\n%s\n' "$SETTINGS_VER" "$CACHE_VER" | sort -V | tail -1)
if [ "$higher" = "$CACHE_VER" ]; then
	# Forward drift: cache > settings.
	#
	# (#2536 r1 code-simplifier) The remediation here USED to be
	# `scripts/migrate-settings.sh`, which rewrites
	# `/claude-workflow-core/<from>/` → `/claude-workflow-core/<to>/` — i.e. it
	# RE-PINS to a concrete version. That is the exact opposite of what #2536
	# established: following that advice recreates the version-pinned state whose
	# GC left 58 registrations 404'ing, and it fired on EVERY SessionStart that
	# detected drift, so the advice actively undid the fix on a loop.
	# install-hook-launchers.sh UN-pins onto version-agnostic launchers instead,
	# and is also the only writer here with a lock, a backup, post-write
	# revalidation and mode preservation.
	# Emit an ABSOLUTE, runnable path. At SessionStart the cwd is the CONSUMER
	# repo, which does not ship install-hook-launchers.sh — a cwd-relative
	# `scripts/…` gives `No such file or directory` and the warning repeats every
	# session (CR-in-CI #2540). The script lives in the newest cache version we
	# just resolved.
	ihl="$CACHE_DIR/$CACHE_VER/scripts/install-hook-launchers.sh"
	cat >&2 <<EOF
session-start-stale-pin: ⚠ plugin-cache drift detected
  settings.json refs: v$SETTINGS_VER
  latest cache dir:   v$CACHE_VER
  Remediation: run \`$ihl --generate --migrate\`
  to UN-PIN these refs onto version-agnostic launchers, after which cache
  bumps stop causing drift entirely. Verify with \`$ihl --verify\`.
  (Do NOT use migrate-settings.sh for this — it re-pins to v$CACHE_VER, which
  reintroduces the dangling-ref failure once that version is GC'd.)
EOF
else
	# Inverse drift: settings > cache → hooks reference paths that
	# don't exist. Likely a partial install or post-migrate race.
	cat >&2 <<EOF
session-start-stale-pin: ⚠ inverse plugin-cache drift detected
  settings.json refs: v$SETTINGS_VER
  latest cache dir:   v$CACHE_VER
  Hook script paths are likely broken (settings references newer cache
  than is installed). Remediation: reinstall the plugin via Claude Code
  plugin manager (\`/plugin reload claude-workflow-core\`) to repopulate
  the cache.
EOF
fi
exit 0
