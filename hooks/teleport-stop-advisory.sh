#!/bin/bash
set -uo pipefail
# event: Stop
# v4.27 (#632) item #19 — Stop hook: detect when user-scope ~/.claude/
# changed during this session and last teleport-push was >24h ago. Emits
# stderr advisory at session end suggesting `/claude-teleport:teleport-push`
# to sync changes across machines. Advisory only — never blocks.
#
# Auto-firing the actual push is intentionally NOT done — teleport-push
# uploads to a private hub (external write); user retains the gate.

# Per advisory contract, never block. Capture stderr-only failures + exit 0.
{
	# Find files in ~/.claude/ modified in last 24h (rough proxy for
	# "changed this session"). Excludes .session-state/ + logs that change
	# every tool call.
	last_push_marker="$HOME/.claude/.teleport-push-last"
	last_push=0
	if [ -f "$last_push_marker" ]; then
		last_push=$(cat "$last_push_marker" 2>/dev/null || echo 0)
	fi
	# CR #634 finding 23: sanitize the marker before arithmetic. A corrupted
	# marker (e.g. `abc`) would crash `(((now - last_push) / 3600))` under
	# set -u/-e — and we MUST stay non-blocking (advisory contract). Drop
	# any non-numeric value and treat as "never pushed".
	if ! [[ "$last_push" =~ ^[0-9]+$ ]]; then
		last_push=0
	fi
	now=$(date +%s)
	hours_since=$(((now - last_push) / 3600))

	if [ "$hours_since" -lt 24 ]; then
		# Pushed recently — silence.
		exit 0
	fi

	# Find any user-scope .claude/ change newer than $last_push, excluding
	# noise (session-state, logs, plugins/cache).
	if [ ! -d "$HOME/.claude" ]; then
		exit 0
	fi

	cutoff_ts=$last_push
	[ "$cutoff_ts" = "0" ] && cutoff_ts=$((now - 86400)) # 24h fallback

	# Use a temp reference file with the cutoff mtime for portable find -newer.
	temp_ref=$(mktemp -t teleport-ref.XXXXXX)
	touch -t "$(date -r "$cutoff_ts" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$cutoff_ts" +%Y%m%d%H%M.%S 2>/dev/null)" "$temp_ref" 2>/dev/null || {
		rm -f "$temp_ref"
		exit 0
	}

	changed=$(find "$HOME/.claude" -maxdepth 3 -type f -newer "$temp_ref" \
		-not -path "*/.session-state/*" \
		-not -path "*/logs/*" \
		-not -path "*/plugins/cache/*" \
		-not -path "*/projects/*/sessions/*" \
		-not -name '.teleport-push-last' \
		2>/dev/null | head -5)

	rm -f "$temp_ref"

	if [ -n "$changed" ]; then
		count=$(printf '%s\n' "$changed" | wc -l | tr -d ' ')
		echo "" >&2
		echo "ℹ teleport advisory: ~/.claude/ has $count changed file(s) since last teleport-push (${hours_since}h ago)." >&2
		echo "  Consider /claude-teleport:teleport-push to sync across machines." >&2
		echo "  (Advisory only — push remains user-gated per privacy.)" >&2
	fi
} >&2 || true

exit 0
