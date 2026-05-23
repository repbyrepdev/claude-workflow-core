#!/bin/bash
set -euo pipefail
# v0.8.0 (#21): bootstrap-repo skill wrapper.
#
# Scaffolds a new consumer repo with full gold-standard SSOT wiring. See
# SKILL.md for full contract.
#
# Sets SKILL_WRAPPER=1 so internal gh calls bypass skill-bypass-guard.

REPO_NAME=""
IN_DIR=""
PLUGIN_REV=""
CREATE_REMOTE=0
WITH_BOARD=0
DRY_RUN=0

while [ $# -gt 0 ]; do
	case "$1" in
	--name)
		[ "$#" -ge 2 ] || {
			echo "bootstrap-repo: --name requires value" >&2
			exit 2
		}
		REPO_NAME="$2"
		shift 2
		;;
	--in)
		[ "$#" -ge 2 ] || {
			echo "bootstrap-repo: --in requires value" >&2
			exit 2
		}
		IN_DIR="$2"
		shift 2
		;;
	--plugin-rev)
		[ "$#" -ge 2 ] || {
			echo "bootstrap-repo: --plugin-rev requires value" >&2
			exit 2
		}
		PLUGIN_REV="$2"
		shift 2
		;;
	--create-remote)
		CREATE_REMOTE=1
		shift
		;;
	--with-board)
		WITH_BOARD=1
		shift
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--help | -h)
		head -25 "$0" | sed -n 's/^# \?//p'
		exit 0
		;;
	*)
		echo "bootstrap-repo: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

if [ -z "$REPO_NAME" ]; then
	echo "bootstrap-repo: --name <repo> is required" >&2
	exit 2
fi
[ -n "$IN_DIR" ] || IN_DIR="./$REPO_NAME"

# Resolve plugin rev — latest if not specified
if [ -z "$PLUGIN_REV" ]; then
	PLUGIN_REV=$(gh release view --repo repbyrepdev/claude-workflow-core --json tagName --jq .tagName 2>/dev/null || echo "v0.7.3")
fi
PLUGIN_VER="${PLUGIN_REV#v}"
PLUGIN_CACHE="$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/$PLUGIN_VER"

if [ ! -d "$PLUGIN_CACHE" ]; then
	echo "bootstrap-repo: ERROR: plugin cache not present at $PLUGIN_CACHE" >&2
	echo "  Run: scripts/bootstrap-machine.sh --plugin-rev $PLUGIN_REV" >&2
	exit 2
fi

_run() {
	if [ "$DRY_RUN" = "1" ]; then
		echo "  [dry-run] $*"
	else
		echo "  $ $*"
		"$@"
	fi
}

export SKILL_WRAPPER=1

echo "═══ bootstrap-repo: $REPO_NAME ═══"
echo "  Target dir:    $IN_DIR"
echo "  Plugin pin:    $PLUGIN_REV"
echo "  Create remote: $CREATE_REMOTE"
echo "  With board:    $WITH_BOARD"
echo ""

# Step 1: target dir
if [ -d "$IN_DIR" ] && [ -n "$(ls -A "$IN_DIR" 2>/dev/null)" ]; then
	if [ "$DRY_RUN" = "0" ]; then
		echo "bootstrap-repo: ERROR: $IN_DIR is non-empty — refuse to overwrite" >&2
		exit 2
	fi
fi
_run mkdir -p "$IN_DIR"
cd "$IN_DIR" || exit 2
_run git init -b main

# Step 2: .pre-commit-config.yaml
echo ""
echo "═══ 2/12 .pre-commit-config.yaml ═══"
if [ "$DRY_RUN" = "0" ]; then
	cat >.pre-commit-config.yaml <<EOF
# Pre-commit config bootstrapped by claude-workflow-core $PLUGIN_REV
# See: https://github.com/repbyrepdev/claude-workflow-core
repos:
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.38.0
    hooks:
      - id: yamllint
  - repo: https://github.com/shellcheck-py/shellcheck-py
    rev: v0.11.0.1
    hooks:
      - id: shellcheck
        args: [-S, warning]
  - repo: https://github.com/scop/pre-commit-shfmt
    rev: v3.13.1-1
    hooks:
      - id: shfmt
        args: [-d]
  - repo: https://github.com/rhysd/actionlint
    rev: v1.7.12
    hooks:
      - id: actionlint
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks
        args: [--config, .gitleaks.toml]
  # Plugin-provided hooks (claude-workflow-core $PLUGIN_REV)
  - repo: https://github.com/repbyrepdev/claude-workflow-core
    rev: $PLUGIN_REV
    hooks:
      - id: actions-permissions
      - id: bash-safety
      - id: bash4-features-check
      - id: check-review-accept-reason
      - id: check-ssot-drift
      - id: commit-scope-to-issue
      - id: commit-template-check
      - id: edit-corruption-guard
      - id: epic-structure
      - id: event-frontmatter-check
      - id: label-sync-on-labels-change
      - id: lint-gate
      - id: memory-drift-check
      - id: memory-index-valid
      - id: prove-yourself-gate
      - id: release-template-check
      - id: review-config-check
      - id: skill-md-loader-safety
EOF
fi
echo "  Wrote .pre-commit-config.yaml"

# Step 3: .claude/skills/ship-pr-cycle/ shim
echo ""
echo "═══ 3/12 .claude/ skills + hooks ═══"
_run mkdir -p .claude/skills/ship-pr-cycle .claude/hooks
if [ "$DRY_RUN" = "0" ]; then
	# Copy the wrapper from the plugin cache (they're consumer-shipped wrappers
	# that resolve to plugin cache via glob-locate)
	# For bootstrap purposes, we'll write a minimal version pointing at PLUGIN_REV
	cat >.claude/skills/ship-pr-cycle/SKILL.md <<EOF
---
name: ship-pr-cycle
description: Drive the local PR review pipeline (Phase 0.5 → Phase 1 → Phase 2 → push → CR → merge-gate) as a state machine. Use when user says "ship", "advance the cycle", "ship this PR".
---

See $PLUGIN_CACHE/scripts/ship-pr-cycle.sh for the full state-machine docs.
EOF
	cat >.claude/skills/ship-pr-cycle/run.sh <<'WRAPPER'
#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
PLUGIN_CACHE="$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core"
shopt -s nullglob
_candidates=("$PLUGIN_CACHE"/*/scripts/ship-pr-cycle.sh)
shopt -u nullglob
ORCHESTRATOR="${_candidates[0]:-}"
if [ -z "$ORCHESTRATOR" ] || [ ! -x "$ORCHESTRATOR" ]; then
	echo "ship-pr-cycle skill: ERROR: plugin orchestrator not found in $PLUGIN_CACHE" >&2
	exit 2
fi
export SKILL_WRAPPER=1
exec "$ORCHESTRATOR" "$@"
WRAPPER
	chmod +x .claude/skills/ship-pr-cycle/run.sh

	# review-log.sh shim
	cat >.claude/hooks/review-log.sh <<'SHIM'
#!/bin/bash
# auto-register: false
set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "review-log shim: must be in a git repo" >&2; exit 2; }
PLUGIN_CACHE="$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core"
shopt -s nullglob
_candidates=("$PLUGIN_CACHE"/*/hooks/review-log.sh)
shopt -u nullglob
TARGET="${_candidates[0]:-}"
[ -n "$TARGET" ] && [ -x "$TARGET" ] || { echo "review-log shim: plugin not installed" >&2; exit 2; }
exec "$TARGET" "$@"
SHIM
	chmod +x .claude/hooks/review-log.sh
fi
echo "  Wrote .claude/skills/ship-pr-cycle/{SKILL.md,run.sh} + .claude/hooks/review-log.sh"

# Steps 4-12 (templates) — abbreviated for brevity; copy from plugin's
# bootstrap-templates/ directory once that lands. For now, instruct the
# operator to copy from a sibling consumer repo.
echo ""
echo "═══ 4-12/12 Templates (deferred — operator action) ═══"
cat <<EOF
  The following must be copied from a sibling consumer repo (homelab or FCP)
  until v0.8.1 ships the bootstrap-templates/ directory in the plugin:

    cp -r <sibling>/.github ./
    cp <sibling>/.coderabbit.yaml ./   # edit labeling for your domain
    cp -r <sibling>/.gemini ./
    cp -r <sibling>/.codex ./
    cp <sibling>/.gitleaks.toml ./
    # Write CLAUDE.md fresh for THIS repo's judgment rules

  Then:
    pre-commit install --install-hooks

  Operator UI actions (cannot be scripted):
    - Enable workflows in Actions tab (workflows ship disabled-by-default)
    - Configure branch protection on main: require CR + 1 reviewer
    - Add secrets: CR_API_KEY (if Pro+), GEMINI_API_KEY, repo-specific
EOF

if [ "$CREATE_REMOTE" = "1" ]; then
	echo ""
	echo "═══ Remote creation ═══"
	_run gh repo create "$REPO_NAME" --private --source=. --remote=origin --push
fi

if [ "$WITH_BOARD" = "1" ]; then
	echo ""
	echo "═══ Project board ═══"
	echo "  (Deferred to v0.8.1 — board GraphQL setup is non-trivial)"
fi

echo ""
echo "═══ Bootstrap initial commit ═══"
_run git add .
_run git commit -m "chore: bootstrap repo via claude-workflow-core $PLUGIN_REV"

echo ""
echo "═══ Done — $REPO_NAME bootstrapped at $IN_DIR ═══"
