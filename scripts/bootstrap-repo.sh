#!/bin/bash
set -euo pipefail
# v0.8.7 (#21): bootstrap-repo — scaffold a new consumer repo with the
# canonical claude-workflow-core SSOT wiring.
#
# Scope: creates the MINIMAL set of files needed for a new repo to
# consume the plugin workflow. The operator still needs to:
#   - `gh repo create <owner>/<repo>` + push
#   - Enable GitHub Actions in repo Settings
#   - Set up branch protection on main (required checks per
#     .github/required-checks-list.yml)
#   - Install pre-commit hooks: `pre-commit install`
#
# Files written:
#   .pre-commit-config.yaml          — pinned plugin + minimal upstream hooks
#   .claude/skills/ship-pr-cycle/    — consumer wrapper for plugin orchestrator
#   .claude/hooks/review-log.sh      — shim that delegates to plugin
#   .github/pull_request_template.md — template stub
#   .github/commit-template.yml      — Conventional Commits SSOT
#   .github/labels.yml               — label catalog stub
#   .github/required-checks-list.yml — required-checks SSOT
#   .github/ISSUE_TEMPLATE/{bug,feature,task,epic,brainstorm}.yml
#
# Idempotent: every file write checks for existing first; --force flag
# overrides. --dry-run shows what would be created without mutating.
#
# Usage:
#   scripts/bootstrap-repo.sh <target-dir>
#   scripts/bootstrap-repo.sh <target-dir> --tag v0.8.5  # pin to specific
#   scripts/bootstrap-repo.sh <target-dir> --dry-run     # preview
#   scripts/bootstrap-repo.sh <target-dir> --force       # overwrite existing
#
# Platform: macOS + Linux (no platform-specific calls).

TARGET=""
PIN_TAG="v0.8.5"
DRY_RUN=0
FORCE=0

while [ $# -gt 0 ]; do
	case "$1" in
	--tag)
		if [ $# -lt 2 ]; then
			echo "error: --tag requires a value (e.g. --tag v0.8.5)" >&2
			exit 2
		fi
		PIN_TAG="$2"
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--force)
		FORCE=1
		shift
		;;
	-h | --help)
		grep '^#' "$0" | head -35
		exit 0
		;;
	-*)
		echo "unknown flag: $1" >&2
		exit 2
		;;
	*)
		if [ -z "$TARGET" ]; then
			TARGET="$1"
			shift
		else
			echo "error: multiple positional args — first arg is target dir, no other positionals" >&2
			exit 2
		fi
		;;
	esac
done

if [ -z "$TARGET" ]; then
	echo "error: missing target directory" >&2
	echo "usage: scripts/bootstrap-repo.sh <target-dir> [--tag vX.Y.Z] [--dry-run] [--force]" >&2
	exit 2
fi

_log() { echo "[bootstrap-repo] $*" >&2; }

# Parity check: bootstrap-manifest.yml is the declarative SSOT for every
# file this script produces. Soft-warn on drift (count or path mismatch).
# Visible bypasses: yq missing OR manifest missing emits a NOTE so a quiet
# skip can't hide regressions.
MANIFEST_PATH="$(dirname "$0")/bootstrap-manifest.yml"
if [ ! -f "$MANIFEST_PATH" ]; then
	_log "NOTE: bootstrap-manifest.yml not found at $MANIFEST_PATH — parity check skipped"
elif ! command -v yq >/dev/null 2>&1; then
	_log "NOTE: yq not on PATH — manifest parity check skipped"
else
	# `|| echo` fallbacks preserve a parseable value when yq parse-errors or
	# grep matches zero — set -e would otherwise abort the whole script.
	# yq stderr captured to PARSE_ERR so failures land in a WARN line with
	# context instead of disappearing into /dev/null.
	PARSE_ERR=$(mktemp -t bootstrap-manifest-yq.XXXXXX 2>/dev/null || echo "")
	manifest_count=$(yq -r '.files | length' "$MANIFEST_PATH" 2>"${PARSE_ERR:-/dev/null}" || echo "")
	heredoc_count=$(grep -cE '^_write ' "$0" || echo 0)
	if [ "$heredoc_count" -eq 0 ]; then
		_log "WARN: bootstrap-repo.sh contains zero _write calls — script malformed?"
	elif [ -z "$manifest_count" ] || ! [ "$manifest_count" -eq "$manifest_count" ] 2>/dev/null; then
		_log "WARN: bootstrap-manifest.yml unparseable (yq -r '.files | length' failed) — parity check inconclusive"
		if [ -n "$PARSE_ERR" ] && [ -s "$PARSE_ERR" ]; then
			_log "      yq error: $(head -1 "$PARSE_ERR")"
		fi
	elif [ "$manifest_count" -ne "$heredoc_count" ]; then
		_log "WARN: manifest drift — bootstrap-manifest.yml lists $manifest_count files, this script has $heredoc_count _write calls"
		_log "      reconcile scripts/bootstrap-manifest.yml + heredocs in $0 before relying on output"
	else
		# Counts match — verify each manifest path appears as a literal _write
		# target. Materialize paths first so yq rc is checkable (process
		# substitution swallows rc). grep -F -- to avoid regex metachar
		# matching AND ugrep dash-prefix flag misinterpretation.
		if ! manifest_paths=$(yq -r '.files[] | select(.path != null) | .path' "$MANIFEST_PATH" 2>"${PARSE_ERR:-/dev/null}"); then
			_log "WARN: yq path enumeration failed — parity check inconclusive"
			[ -n "$PARSE_ERR" ] && [ -s "$PARSE_ERR" ] && _log "      yq error: $(head -1 "$PARSE_ERR")"
			manifest_paths=""
		fi
		drift_paths=()
		while IFS= read -r p; do
			[ -z "$p" ] && continue
			grep -F -- "_write $p " "$0" >/dev/null || drift_paths+=("$p")
		done <<<"$manifest_paths"
		if [ "${#drift_paths[@]}" -gt 0 ]; then
			_log "WARN: manifest path(s) not found in any _write call:"
			for p in "${drift_paths[@]}"; do
				_log "        - $p"
			done
		fi
	fi
	[ -n "$PARSE_ERR" ] && rm -f "$PARSE_ERR"
fi

# Create target if missing (always create in dry-run too so subsequent
# cd + relative-path checks work; we tear down at end if empty).
TARGET_PREEXISTED=1
if [ ! -d "$TARGET" ]; then
	TARGET_PREEXISTED=0
	if [ "$DRY_RUN" = "1" ]; then
		_log "[dry-run] would mkdir -p $TARGET (creating temporarily for path resolution)"
	fi
	mkdir -p "$TARGET"
fi

cd "$TARGET" || {
	echo "error: cannot cd into $TARGET after mkdir (permissions? symlink loop?)" >&2
	exit 2
}
# Resolve to absolute after cd so dry-run cleanup (which does `cd /`)
# can still locate the target by absolute path even when $TARGET was
# originally given as a relative argument.
TARGET=$(pwd)

# Track skipped files so the end-of-run summary can warn loudly.
SKIPPED_FILES=()

# Helper: write file, idempotent + --force-respecting.
# Every step (mkdir/cat/chmod) checked explicitly so any failure
# names the path that broke instead of producing a bare set -e abort.
# args: <relative-path> [<mode>] (content on stdin)
_write() {
	local path=$1
	local mode=${2:-644}
	if [ -e "$path" ] && [ "$FORCE" != "1" ]; then
		_log "  • $path already exists — skipping (--force to overwrite)"
		# Drain stdin so caller's heredoc isn't left dangling.
		cat >/dev/null
		SKIPPED_FILES+=("$path")
		return 0
	fi
	if [ "$DRY_RUN" = "1" ]; then
		_log "[dry-run] would write $path (mode $mode)"
		cat >/dev/null
		return 0
	fi
	local parent
	parent=$(dirname "$path")
	if ! mkdir -p "$parent"; then
		echo "error: cannot create parent dir $parent for $path" >&2
		return 1
	fi
	if ! cat >"$path"; then
		echo "error: write to $path failed (disk full? permissions? read-only FS?)" >&2
		return 1
	fi
	if ! chmod "$mode" "$path"; then
		echo "error: chmod $mode $path failed" >&2
		return 1
	fi
	_log "  ✓ wrote $path"
}

# --- .pre-commit-config.yaml -----------------------------------------
_write .pre-commit-config.yaml 644 <<EOF
# Pre-commit config. Layered:
#   1. Upstream framework hooks (lint)
#   2. Plugin-provided hooks via \`claude-workflow-core\` (workflow gates)
# Install: pre-commit install
# Run all: pre-commit run --all-files

repos:
  # Upstream framework hooks
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.38.0
    hooks:
      - id: yamllint
  - repo: https://github.com/shellcheck-py/shellcheck-py
    rev: v0.10.0.1
    hooks:
      - id: shellcheck
  - repo: https://github.com/scop/pre-commit-shfmt
    rev: v3.10.0-2
    hooks:
      - id: shfmt
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.2
    hooks:
      - id: gitleaks

  # Plugin-provided workflow hooks — keep \`rev\` synchronized with
  # claude-workflow-core releases.
  - repo: https://github.com/repbyrepdev/claude-workflow-core
    rev: $PIN_TAG
    hooks:
      - id: bash-safety
      - id: bash4-features-check
      - id: commit-template-check
      - id: lint-gate
      - id: memory-drift-check
      - id: memory-index-valid
      - id: prove-yourself-gate
EOF

# --- .claude/skills/ship-pr-cycle/run.sh -----------------------------
_write .claude/skills/ship-pr-cycle/run.sh 755 <<'EOF'
#!/bin/bash
set -euo pipefail
# Consumer wrapper for ship-pr-cycle orchestrator (lives in plugin).
# Resolves plugin pin from .pre-commit-config.yaml and exec's the
# orchestrator from the plugin cache.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
CONFIG="$REPO_ROOT/.pre-commit-config.yaml"

# Resolve plugin pin via plugin's own resolve-plugin-pin.sh (SSOT)
PLUGIN_CACHE="$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core"
shopt -s nullglob
_resolve_candidates=("$PLUGIN_CACHE"/*/_lib/resolve-plugin-pin.sh)
shopt -u nullglob
RESOLVE_LIB="${_resolve_candidates[0]:-}"

if [ -z "$RESOLVE_LIB" ] || [ ! -f "$RESOLVE_LIB" ]; then
	echo "ship-pr-cycle consumer: ERROR: plugin cache empty at $PLUGIN_CACHE" >&2
	echo "  run scripts/bootstrap-machine.sh from the plugin repo first" >&2
	exit 2
fi
# shellcheck source=/dev/null
source "$RESOLVE_LIB"
if ! PIN=$(resolve_plugin_pin "$CONFIG"); then
	echo "error: could not resolve plugin pin from $CONFIG (key claude-workflow-core missing or malformed)" >&2
	exit 2
fi

ORCHESTRATOR="$PLUGIN_CACHE/$PIN/scripts/ship-pr-cycle.sh"
if [ ! -x "$ORCHESTRATOR" ]; then
	echo "ship-pr-cycle consumer: ERROR: orchestrator missing at $ORCHESTRATOR" >&2
	exit 2
fi
exec "$ORCHESTRATOR" "$@"
EOF

# --- .claude/skills/ship-pr-cycle/SKILL.md ---------------------------
_write .claude/skills/ship-pr-cycle/SKILL.md 644 <<'EOF'
---
name: ship-pr-cycle
description: Orchestrate the full PR lifecycle (Phase 0.5 → Phase 1 → Phase 2 → push → CR-in-CI → merge-gate). Invoked at branch-ready time to drive a PR through to mergeable.
---

# ship-pr-cycle (consumer wrapper)

Delegates to the orchestrator script in the plugin cache. See
`https://github.com/repbyrepdev/claude-workflow-core/blob/main/scripts/ship-pr-cycle.sh`
for full state machine + stage semantics.

## Usage

```bash
.claude/skills/ship-pr-cycle/run.sh start    # initialize for current HEAD
.claude/skills/ship-pr-cycle/run.sh status   # show state
.claude/skills/ship-pr-cycle/run.sh next     # advance one stage
.claude/skills/ship-pr-cycle/run.sh resume   # auto-detect + advance to terminal
```
EOF

# --- .claude/hooks/review-log.sh shim --------------------------------
_write .claude/hooks/review-log.sh 755 <<'EOF'
#!/bin/bash
set -euo pipefail
# Thin shim that forwards to the plugin's review-log.sh. Idempotency
# contract lives in the plugin — this shim just exists so the consumer
# repo has a stable path that doesn't change with pin bumps.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
CONFIG="$REPO_ROOT/.pre-commit-config.yaml"

PLUGIN_CACHE="$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core"
shopt -s nullglob
_resolve_candidates=("$PLUGIN_CACHE"/*/_lib/resolve-plugin-pin.sh)
shopt -u nullglob
RESOLVE_LIB="${_resolve_candidates[0]:-}"
if [ -z "$RESOLVE_LIB" ]; then
	echo "review-log.sh shim: plugin cache empty" >&2
	exit 2
fi
# shellcheck source=/dev/null
source "$RESOLVE_LIB"
if ! PIN=$(resolve_plugin_pin "$CONFIG"); then
	echo "error: could not resolve plugin pin from $CONFIG (key claude-workflow-core missing or malformed)" >&2
	exit 2
fi

TARGET_HOOK="$PLUGIN_CACHE/$PIN/hooks/review-log.sh"
if [ ! -x "$TARGET_HOOK" ]; then
	echo "review-log.sh shim: target hook missing or non-executable at $TARGET_HOOK" >&2
	echo "  ensure plugin cache for $PIN is installed (scripts/bootstrap-machine.sh)" >&2
	exit 2
fi
exec "$TARGET_HOOK" "$@"
EOF

# --- .github/pull_request_template.md --------------------------------
_write .github/pull_request_template.md 644 <<'EOF'
## Summary
<!-- What changed and why -->

## Changes
<!-- Files / modules modified -->

## Testing
- [ ] Skill exercised against representative input
- [ ] Lint/tests clean for changed files
- [ ] No leaked tokens in diff

## Pre-merge
- [ ] CodeRabbit review clean (or all findings addressed)
- [ ] gitleaks server-side scan passes
- [ ] All required checks per `.github/required-checks-list.yml` green
- [ ] No unresolved review threads

## Rollback

<!-- How to revert if something breaks. -->

Closes #<!-- issue number -->
EOF

# --- .github/commit-template.yml -------------------------------------
_write .github/commit-template.yml 644 <<'EOF'
# Conventional Commits schema SSOT.
# Subject format: <type>(<optional_scope>): <summary>
# Max subject: 70 chars.

types:
  - feat
  - fix
  - refactor
  - perf
  - chore
  - test
  - docs
  - build
  - ci
  - revert

require_body_for: [feat, fix, refactor, perf]
require_footer: "Co-Authored-By:"
max_subject_length: 70
EOF

# --- .github/labels.yml ----------------------------------------------
_write .github/labels.yml 644 <<'EOF'
# Label catalog SSOT. Sync via `gh label create` or label-sync workflow.
- name: bug
  color: d73a4a
  description: Something broken
- name: enhancement
  color: a2eeef
  description: New capability
- name: epic
  color: 7057ff
  description: Parent of sub-issues
- name: priority:p1
  color: b60205
- name: priority:p2
  color: d93f0b
- name: priority:p3
  color: fbca04
- name: priority:needs-triage
  color: 5319e7
- name: area:infrastructure
  color: 0e8a16
- name: brainstorm
  color: c5def5
  description: Discussion-style ideation
EOF

# --- .github/required-checks-list.yml --------------------------------
_write .github/required-checks-list.yml 644 <<'EOF'
# SSOT for required status checks. Branch protection on main reads
# this list; pr-merge skill validates each is present + green before
# proceeding.
#
# Schema (per entry):
#   check_name, workflow_file (string|null), event (string|null), notes.
#   advisory[] uses the same schema for not-yet-required checks.
required:
  - check_name: CodeRabbit
    workflow_file: null
    event: null
    notes: Third-party SaaS review; runs server-side, not in Actions.
  - check_name: gitleaks
    workflow_file: gitleaks.yml
    event: pull_request
    notes: Secret scan with default rules
  - check_name: pr-lint
    workflow_file: pr-lint.yml
    event: pull_request
    notes: |
      Sequential checks enforcing area:* label, issue link, and PR
      template section headings — see pr-lint.yml for exact step list

advisory: []
EOF

# --- .github/ISSUE_TEMPLATE stubs ------------------------------------
_write .github/ISSUE_TEMPLATE/bug.yml 644 <<'EOF'
name: Bug report
description: Something broken
labels: [bug]
body:
  - type: input
    id: area
    attributes:
      label: Area
    validations:
      required: true
  - type: textarea
    id: description
    attributes:
      label: What's happening?
    validations:
      required: true
EOF

_write .github/ISSUE_TEMPLATE/feature.yml 644 <<'EOF'
name: Feature request
description: New capability
labels: [enhancement]
body:
  - type: input
    id: area
    attributes:
      label: Area
    validations:
      required: true
  - type: textarea
    id: goal
    attributes:
      label: What's the goal?
    validations:
      required: true
EOF

_write .github/ISSUE_TEMPLATE/task.yml 644 <<'EOF'
name: Task
description: Sub-issue under an epic
labels: []
body:
  - type: input
    id: area
    attributes:
      label: Area
    validations:
      required: true
  - type: textarea
    id: description
    attributes:
      label: What needs to be done?
    validations:
      required: true
EOF

_write .github/ISSUE_TEMPLATE/epic.yml 644 <<'EOF'
name: Epic
description: Parent of sub-issues
labels: [epic, enhancement]
body:
  - type: input
    id: area
    attributes:
      label: Area
    validations:
      required: true
  - type: textarea
    id: goal
    attributes:
      label: Goal
    validations:
      required: true
  - type: textarea
    id: scope
    attributes:
      label: Scope
    validations:
      required: true
  - type: textarea
    id: sub_issues
    attributes:
      label: Sub-issues
    validations:
      required: true
  - type: textarea
    id: acceptance
    attributes:
      label: Acceptance criteria
    validations:
      required: true
  - type: textarea
    id: rollout
    attributes:
      label: Rollout plan
    validations:
      required: true
  - type: textarea
    id: rollback
    attributes:
      label: Rollback plan
    validations:
      required: true
EOF

_write .github/ISSUE_TEMPLATE/brainstorm.yml 644 <<'EOF'
name: Brainstorm
description: Discussion-style issue
labels: [brainstorm]
body:
  - type: input
    id: area
    attributes:
      label: Area
    validations:
      required: true
  - type: textarea
    id: topic
    attributes:
      label: Topic
    validations:
      required: true
EOF

# --- .github/labeler.yml ---------------------------------------------
_write .github/labeler.yml 644 <<'EOF'
---
# Path → label rules consumed by pr-labeler.yml workflow.
# See https://github.com/actions/labeler for syntax.
area:infrastructure:
  - changed-files:
      - any-glob-to-any-file:
          - scripts/**
          - .github/**
          - .claude/**
          - .pre-commit-config.yaml
EOF

# --- .github/workflows/ stubs ----------------------------------------
# Minimal workflow set: gitleaks, pr-lint, pr-labeler. Operator extends
# (lint-ci, project-automation, ai-triage) per repo needs.
_write .github/workflows/gitleaks.yml 644 <<'EOF'
name: Gitleaks Secret Scan
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  gitleaks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
EOF

_write .github/workflows/pr-lint.yml 644 <<'EOF'
name: PR Lint
on:
  pull_request:
    types: [opened, edited, synchronize, reopened]
permissions:
  pull-requests: read
jobs:
  pr-lint:
    runs-on: ubuntu-latest
    env:
      BODY: ${{ github.event.pull_request.body }}
    steps:
      - name: Require PR body
        if: always() && !cancelled()
        run: |
          if [ -z "$BODY" ] || [ "${#BODY}" -lt 50 ]; then
            echo "::error::PR body too short — fill out the template"
            exit 1
          fi
      - name: Require issue reference
        if: always() && !cancelled()
        run: |
          if echo "$BODY" | grep -qiE "(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+"; then
            echo "Issue link found"
          else
            echo "::error::PR body must reference an issue (e.g., 'Closes #N')"
            exit 1
          fi
EOF

_write .github/workflows/pr-labeler.yml 644 <<'EOF'
name: PR auto-label
on:
  pull_request_target:
    types: [opened, synchronize, reopened]
permissions:
  contents: read
  pull-requests: write
jobs:
  label:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/labeler@v5
        with:
          configuration-path: .github/labeler.yml
          sync-labels: true
EOF

# --- Summary ---------------------------------------------------------
_log ""
if [ ${#SKIPPED_FILES[@]} -gt 0 ]; then
	_log "⚠ SKIPPED ${#SKIPPED_FILES[@]} pre-existing file(s) — content may be stale:"
	for f in "${SKIPPED_FILES[@]}"; do _log "    - $f"; done
	_log "    Re-run with --force to overwrite (e.g. after pin bump)."
	_log ""
fi
if [ "$DRY_RUN" = "1" ]; then
	_log "bootstrap-repo dry-run complete. Re-run without --dry-run to apply."
	# Clean up the temp-created dir IF it was empty + we created it.
	# Resolve TARGET to absolute BEFORE cd / so a relative argument like
	# "new-repo" doesn't get re-resolved against root after cd.
	if [ "$TARGET_PREEXISTED" = "0" ]; then
		TARGET_ABS=$(cd "$TARGET" && pwd)
		cd /
		if [ -z "$(ls -A "$TARGET_ABS" 2>/dev/null)" ]; then
			rmdir "$TARGET_ABS"
		else
			_log "⚠ dry-run target dir $TARGET_ABS unexpectedly non-empty — leaving in place for inspection"
		fi
	fi
else
	_log "bootstrap-repo complete at $TARGET (plugin pin $PIN_TAG)."
fi
_log ""
_log "Next steps (manual):"
_log "  1. cd $TARGET"
_log "  2. git init && git add . && git commit -m 'initial: bootstrap from claude-workflow-core'"
_log "  3. gh repo create <owner>/<repo> --source=. --push"
_log "  4. Enable GitHub Actions in repo Settings → Actions → General"
_log "  5. Set up branch protection on main (require checks per .github/required-checks-list.yml)"
_log "  6. pre-commit install"
_log "  7. Run scripts/bootstrap-machine.sh from the plugin if you haven't bootstrapped your machine"
