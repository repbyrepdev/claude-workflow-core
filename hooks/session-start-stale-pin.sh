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
	# Forward drift: cache > settings. (#2536) AUTO-HEAL rather than advise.
	#
	# Why this became auto: a warning is worthless in the failure that actually
	# happens. When the cache advances and GC prunes the old version dir, EVERY
	# registered hook path 404s at once — and the advisory scrolls past in a
	# long session while the operator watches unexplained hook errors for hours
	# (observed 2026-08-22: 58 dead paths at v0.34.83 after the cache moved to
	# v0.34.108). The remediation was always mechanical, so do it.
	#
	# SAFETY — repoint only when the target can actually serve every reference:
	#   * every hook path referenced in settings.json must EXIST in $CACHE_VER
	#     (a partially-populated cache dir would trade 58 dead paths for 58
	#     different dead paths),
	#   * back up before writing, write atomically (tmp + mv),
	#   * re-validate JSON after rendering and refuse to install it otherwise.
	# Any failure leaves settings.json untouched and falls back to the warning.
	if [ "${SESSION_START_STALE_PIN_NO_HEAL:-0}" = "1" ]; then
		echo "session-start-stale-pin: ⚠ drift v$SETTINGS_VER → v$CACHE_VER; auto-heal disabled (SESSION_START_STALE_PIN_NO_HEAL=1)" >&2
		exit 0
	fi
	_heal_ok=1
	_missing_ct=0
	# Enumerate referenced hook basenames at the OLD version and require each
	# to exist under the new one.
	while IFS= read -r _rel; do
		[ -n "$_rel" ] || continue
		[ -e "$CACHE_DIR/$CACHE_VER/$_rel" ] || {
			_missing_ct=$((_missing_ct + 1))
			_heal_ok=0
		}
	done <<EOF
$(jq -r --arg v "$SETTINGS_VER" '[.. | strings | select(test("claude-workflow-core/claude-workflow-core/" + $v + "/"))] | map(sub(".*/claude-workflow-core/claude-workflow-core/" + $v + "/"; "")) | unique | .[]' "$SETTINGS" 2>/dev/null)
EOF
	if [ "$_heal_ok" -eq 1 ]; then
		_bak="${SETTINGS}.bak-stale-pin-${SETTINGS_VER}-to-${CACHE_VER}"
		_tmp="${SETTINGS}.stale-pin.$$"
		if cp "$SETTINGS" "$_bak" 2>/dev/null &&
			jq --arg old "claude-workflow-core/claude-workflow-core/$SETTINGS_VER/" \
				--arg new "claude-workflow-core/claude-workflow-core/$CACHE_VER/" \
				'walk(if type == "string" then gsub($old; $new) else . end)' \
				"$SETTINGS" >"$_tmp" 2>/dev/null &&
			jq empty "$_tmp" 2>/dev/null &&
			mv "$_tmp" "$SETTINGS" 2>/dev/null; then
			echo "session-start-stale-pin: ✓ AUTO-HEALED plugin-cache drift — repointed ~/.claude/settings.json hook paths v$SETTINGS_VER → v$CACHE_VER (backup: $_bak). Run /reload-plugins to apply in this session (#2536)." >&2
			exit 0
		fi
		rm -f "$_tmp" 2>/dev/null || true
		echo "session-start-stale-pin: ⚠ auto-heal FAILED writing $SETTINGS (backup at $_bak if it was created); settings left untouched" >&2
	else
		echo "session-start-stale-pin: ⚠ NOT auto-healing — $_missing_ct referenced hook(s) are absent from v$CACHE_VER (partial/incomplete cache); repointing would swap one set of dead paths for another" >&2
	fi
	cat >&2 <<EOF
session-start-stale-pin: ⚠ plugin-cache drift detected
  settings.json refs: v$SETTINGS_VER
  latest cache dir:   v$CACHE_VER
  Remediation: run \`scripts/migrate-settings.sh\` to update
  ~/.claude/settings.json plugin paths to v$CACHE_VER.
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
