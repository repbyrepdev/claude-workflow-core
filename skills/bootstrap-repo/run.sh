#!/bin/bash
set -euo pipefail
# bootstrap-repo skill wrapper (#223) — scaffold a NEW repo with the canonical
# claude-workflow-core SSOT wiring, pinned to the plugin's CURRENT version.
# Thin wrapper over scripts/bootstrap-repo.sh; sets SKILL_WRAPPER=1 so the
# skill-bypass-guard honors the `gh label` calls the scaffold makes.
#
# Usage:
#   .claude/skills/bootstrap-repo/run.sh <target-dir>             # scaffold
#   .claude/skills/bootstrap-repo/run.sh <target-dir> --dry-run   # preview only
#   .claude/skills/bootstrap-repo/run.sh <target-dir> --tag vX.Y.Z
#   .claude/skills/bootstrap-repo/run.sh --verify [--scope plugin|consumer|both]
#
# See SKILL.md for the post-scaffold checklist.
export SKILL_WRAPPER=1
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SELF_DIR/../.." && pwd)
exec bash "$REPO_ROOT/scripts/bootstrap-repo.sh" "$@"
