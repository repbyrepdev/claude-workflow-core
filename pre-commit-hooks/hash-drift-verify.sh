#!/bin/bash
set -euo pipefail
# Pre-commit gate: verify consumer files match plugin SSOT via
# scripts/hash-drift.sh --verify.
#
# Catches drift at commit time so a consumer can't accidentally land
# a change to a plugin-tracked file (.github/labels.yml, ISSUE_TEMPLATE,
# workflows-source, etc.) without explicitly declaring the divergence
# in .claude/local-overrides.yml. v0.25.0 #148.
#
# Behavior:
#   - Locates scripts/hash-drift.sh relative to the script's own location
#     (works in plugin repo AND when shipped via the .pre-commit-hooks.yaml
#     manifest entry pinning consumers to vX.Y.Z).
#   - Runs --verify ONLY. Extra args rejected with exit 2 — contract is
#     locked-down (use scripts/hash-drift.sh directly for custom args).
#   - Exit 0 = clean / hashes match. Exit 1 = drift found. Exit 2 = shim
#     itself failed (sibling missing, layout drift, etc.).
#
# Bypass: HASH_DRIFT_VERIFY_SKIP=1 (audit-logged to JSONL at
# ~/.claude/logs/hash-drift-skip.jsonl per #148 spec AND stderr —
# pre-commit captures stderr only on failure, so a persistent file log
# is required for post-hoc audit). Bypass FAILS CLOSED if audit-logging
# is impossible (mkdir perm denied, jq missing) — exit 2 instead of 0,
# preventing an unaudited bypass.

# r2 silent-failure-hunter MEDIUM: reject extra args with clear message.
# Contract is locked-down: this shim hardcodes --verify. Future custom
# args should invoke scripts/hash-drift.sh directly.
if [ "$#" -gt 0 ]; then
	echo "hash-drift-verify: this shim hardcodes --verify; extra args rejected: $*" >&2
	echo "  Invoke scripts/hash-drift.sh directly to pass custom args." >&2
	exit 2
fi

if [ "${HASH_DRIFT_VERIFY_SKIP:-0}" = "1" ]; then
	# Bypass is gated on successful audit-logging — issue #148 explicitly
	# requires the override to be audit-logged. CR Phase 2 server-side
	# MAJOR: failing-closed when audit persistence fails prevents an
	# unaudited bypass slipping through.
	# Log path per #148 spec: ~/.claude/logs/hash-drift-skip.jsonl.
	_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
	_log_dir="${HOME}/.claude/logs"
	_log_file="$_log_dir/hash-drift-skip.jsonl"
	_audit_logged=0
	if mkdir -p "$_log_dir" 2>/dev/null; then
		if command -v jq >/dev/null 2>&1; then
			if jq -cn --arg ts "$_ts" --arg sha "$_sha" --arg actor "${USER:-unknown}" --arg pwd "$PWD" \
				'{ts:$ts,sha:$sha,actor:$actor,pwd:$pwd,event:"hash-drift-verify-skip"}' \
				>>"$_log_file" 2>/dev/null; then
				_audit_logged=1
			fi
		fi
	fi
	if [ "$_audit_logged" -eq 1 ]; then
		echo "hash-drift-verify: HASH_DRIFT_VERIFY_SKIP=1 — BYPASS (audit-logged to $_log_file)" >&2
		exit 0
	fi
	# Fail-closed: audit-logging is a precondition for bypass.
	echo "hash-drift-verify: HASH_DRIFT_VERIFY_SKIP=1 set but audit log write FAILED at $_log_file" >&2
	echo "  Cannot proceed: bypass requires audit-logging per #148. Check $_log_dir perms or jq availability." >&2
	exit 2
fi

# r2 silent-failure-hunter MEDIUM: use BASH_SOURCE[0] + `--` for cd to
# survive source-invocation + leading-dash filename injection. Wrap
# with explicit error handler so a cd failure produces an operator-
# scoped diagnostic instead of a generic shell error.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || {
	echo "hash-drift-verify: cannot resolve SCRIPT_DIR from ${BASH_SOURCE[0]} — broken symlink or perm change?" >&2
	echo "  Reinstall the plugin via scripts/install-machine.sh." >&2
	exit 2
}
HASH_DRIFT_SH="$SCRIPT_DIR/../scripts/hash-drift.sh"

# r2 silent-failure-hunter MEDIUM: split the missing/non-exec/wrong-type
# diagnostics so operators know whether to chmod / reinstall / inspect.
if [ ! -e "$HASH_DRIFT_SH" ]; then
	echo "hash-drift-verify: sibling scripts/hash-drift.sh MISSING at $HASH_DRIFT_SH" >&2
	echo "  Plugin layout drift? Reinstall the plugin via scripts/install-machine.sh." >&2
	exit 2
elif [ -d "$HASH_DRIFT_SH" ]; then
	echo "hash-drift-verify: sibling path is a directory, not a file: $HASH_DRIFT_SH" >&2
	echo "  Plugin layout corrupted? Reinstall the plugin via scripts/install-machine.sh." >&2
	exit 2
elif [ ! -f "$HASH_DRIFT_SH" ]; then
	echo "hash-drift-verify: sibling path is not a regular file (socket/fifo/device?): $HASH_DRIFT_SH" >&2
	exit 2
elif [ ! -x "$HASH_DRIFT_SH" ]; then
	echo "hash-drift-verify: sibling present but NOT EXECUTABLE: $HASH_DRIFT_SH" >&2
	echo "  Run: chmod +x $HASH_DRIFT_SH" >&2
	exit 2
fi

exec "$HASH_DRIFT_SH" --verify
