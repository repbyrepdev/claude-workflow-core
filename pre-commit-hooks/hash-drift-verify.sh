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
#   - Runs --verify. Exit 0 = clean / hashes match. Exit 1 = drift found
#     (consumer must update .claude/local-overrides.yml or sync to source).
#   - Operator-readable diagnostic emitted by hash-drift.sh itself; this
#     shim only forwards the rc.
#
# Bypass: HASH_DRIFT_VERIFY_SKIP=1 (audit-logged to stderr — emergency
# override; the hash-drift.sh tool runs in --verify-only mode here so
# bypassing is for build-system breakage only, not legitimate drift).

if [ "${HASH_DRIFT_VERIFY_SKIP:-0}" = "1" ]; then
	echo "hash-drift-verify: HASH_DRIFT_VERIFY_SKIP=1 — skipping (audit-logged)" >&2
	exit 0
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
HASH_DRIFT_SH="$SCRIPT_DIR/../scripts/hash-drift.sh"
if [ ! -x "$HASH_DRIFT_SH" ]; then
	echo "hash-drift-verify: sibling scripts/hash-drift.sh not found or non-executable at $HASH_DRIFT_SH" >&2
	echo "  Plugin layout drift? Reinstall the plugin via scripts/install-machine.sh." >&2
	exit 2
fi

exec "$HASH_DRIFT_SH" --verify
