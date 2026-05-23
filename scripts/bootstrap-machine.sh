#!/bin/bash
set -euo pipefail
# v0.8.0 (#22): bootstrap a new dev machine for the gold-standard workflow.
#
# Idempotent. Safe to re-run on an already-set-up machine — only fills gaps.
#
# Steps:
#   1. Verify macOS (BSD utils baseline assumed) — script also runs on Linux
#      with GNU coreutils caveat noted.
#   2. Install Homebrew tooling: gh, jq, yq, pre-commit, shellcheck, shfmt,
#      actionlint, gitleaks, semgrep, bats-core
#   3. Install Claude Code CLI dependencies: coderabbit (CR CLI), gh
#      copilot extension, gh GraphQL features
#   4. gh auth verify (interactive prompt if not authed)
#   5. Install/update claude-workflow-core plugin cache to latest tagged version
#   6. Bootstrap user-scope ~/.claude/settings.json with PreToolUse/PostToolUse
#      hooks pointing at the plugin cache (BACKS UP existing settings.json
#      to ~/.claude/settings.json.bak-<ts> before any write)
#   7. Print MEMORY_DRIFT_EXTERNAL_ROOTS shell-rc instructions
#   8. Print Keychain token setup instructions (interactive — operator runs
#      `security add-generic-password ...` themselves for secrets)
#
# Usage:
#   bootstrap-machine.sh                     # interactive
#   bootstrap-machine.sh --plugin-rev v0.7.3 # pin a specific version
#   bootstrap-machine.sh --dry-run           # show what would happen
#   bootstrap-machine.sh --skip-brew         # already have tools installed
#
# Exit codes:
#   0 — bootstrap completed (or already-set-up)
#   1 — partial: some steps need manual followup (e.g. token entries)
#   2 — fatal: prerequisite missing (no brew on macOS, no apt on Linux, etc.)

DRY_RUN=0
SKIP_BREW=0
PLUGIN_REV=""

while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--skip-brew)
		SKIP_BREW=1
		shift
		;;
	--plugin-rev)
		[ "$#" -ge 2 ] || {
			echo "bootstrap: --plugin-rev requires value" >&2
			exit 2
		}
		PLUGIN_REV="$2"
		shift 2
		;;
	--help | -h)
		head -30 "$0" | sed -n 's/^# \?//p'
		exit 0
		;;
	*)
		echo "bootstrap: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

_run() {
	if [ "$DRY_RUN" = "1" ]; then
		echo "  [dry-run] $*"
	else
		echo "  $ $*"
		"$@"
	fi
}

_log() {
	echo ""
	echo "═══ $* ═══"
}

# Step 1: platform detection
_log "1/8 Platform check"
case "$(uname -s)" in
Darwin)
	PLATFORM="macos"
	echo "  macOS detected"
	;;
Linux)
	PLATFORM="linux"
	echo "  Linux detected (GNU coreutils assumed)"
	;;
*)
	echo "bootstrap: unsupported platform $(uname -s) — only macOS + Linux" >&2
	exit 2
	;;
esac

# Step 2: tooling
_log "2/8 Tooling install"
if [ "$SKIP_BREW" = "1" ]; then
	echo "  --skip-brew: assuming tools already installed"
else
	if [ "$PLATFORM" = "macos" ]; then
		if ! command -v brew >/dev/null 2>&1; then
			echo "bootstrap: Homebrew not found — install from https://brew.sh" >&2
			exit 2
		fi
		for pkg in gh jq yq pre-commit shellcheck shfmt actionlint gitleaks semgrep bats-core; do
			if brew list "$pkg" >/dev/null 2>&1; then
				echo "  ✓ $pkg (already installed)"
			else
				_run brew install "$pkg"
			fi
		done
	else
		echo "  Linux: install gh, jq, yq, pre-commit, shellcheck, shfmt, actionlint, gitleaks, semgrep, bats-core via your package manager"
		echo "  Skipping automatic install on Linux — verify each tool exists:"
		for pkg in gh jq yq pre-commit shellcheck shfmt actionlint gitleaks semgrep bats; do
			command -v "$pkg" >/dev/null 2>&1 && echo "  ✓ $pkg" || echo "  ✗ $pkg — install manually"
		done
	fi
fi

# Step 3: CR CLI + Copilot extension
_log "3/8 CodeRabbit + Copilot CLIs"
if command -v coderabbit >/dev/null 2>&1; then
	echo "  ✓ coderabbit ($(coderabbit --version 2>&1 | head -1))"
else
	echo "  Install CR CLI: https://docs.coderabbit.ai/cli/installation"
fi
if gh extension list 2>/dev/null | grep -q copilot; then
	echo "  ✓ gh copilot extension"
else
	_run gh extension install github/gh-copilot
fi

# Step 4: gh auth
_log "4/8 gh authentication"
if gh auth status >/dev/null 2>&1; then
	echo "  ✓ gh authed"
else
	echo "  Run: gh auth login"
	echo "  (Skipping; re-run bootstrap after auth)"
fi

# Step 5: plugin cache install
_log "5/8 claude-workflow-core plugin cache"
PLUGIN_DIR="$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core"
if [ -z "$PLUGIN_REV" ]; then
	# Resolve latest tag from GitHub
	PLUGIN_REV=$(gh release view --repo repbyrepdev/claude-workflow-core --json tagName --jq .tagName 2>/dev/null || echo "")
	if [ -z "$PLUGIN_REV" ]; then
		PLUGIN_REV="v0.7.3" # known-good fallback
		echo "  ⚠ Could not query latest release; falling back to $PLUGIN_REV"
	else
		echo "  Latest release: $PLUGIN_REV"
	fi
fi
PLUGIN_CACHE_VER="${PLUGIN_REV#v}"
if [ -d "$PLUGIN_DIR/$PLUGIN_CACHE_VER" ]; then
	echo "  ✓ Plugin cache present at $PLUGIN_DIR/$PLUGIN_CACHE_VER"
else
	mkdir -p "$PLUGIN_DIR"
	_run git clone --branch "$PLUGIN_REV" --depth 1 \
		https://github.com/repbyrepdev/claude-workflow-core.git \
		"$PLUGIN_DIR/$PLUGIN_CACHE_VER"
fi

# Step 6: user-scope settings.json
_log "6/8 ~/.claude/settings.json wiring"
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
	ts=$(date -u +%Y%m%dT%H%M%SZ)
	echo "  Backing up existing settings to $SETTINGS.bak-$ts"
	_run cp "$SETTINGS" "$SETTINGS.bak-$ts"
fi
echo "  Settings template would wire ~40 hooks pointing at $PLUGIN_DIR/$PLUGIN_CACHE_VER/hooks/*.sh"
echo "  (Templated write deferred to v0.8.1 — operator currently copies from another machine)"

# Step 7: shell-rc instructions
_log "7/8 Shell-rc setup"
cat <<EOF
  Add to ~/.zshrc (or ~/.bashrc):

    export MEMORY_DRIFT_EXTERNAL_ROOTS="\$HOME/media-server:\$HOME/pricing-team-toolkit:\$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/$PLUGIN_CACHE_VER"

  This lets memory-drift-check resolve paths across both consumer repos +
  the plugin cache.
EOF

# Step 8: Keychain tokens (manual)
_log "8/8 Keychain tokens (manual)"
cat <<EOF
  Operator action required — add these to macOS Keychain:

    security add-generic-password -a "\$USER" -s sops-age-key -w "<age-key>"
    security add-generic-password -a "\$USER" -s coalesce-access-token -w "<token>"
    security add-generic-password -a "\$USER" -s coalesce-catalog-token -w "<token>"
    security add-generic-password -a "\$USER" -s firecrawl-api-key -w "<key>"
    security add-generic-password -a "\$USER" -s brave-api-key -w "<key>"

  (Linux: use your secret-service of choice; the workflow scripts read
   via \`security find-generic-password\` on macOS only today.)
EOF

_log "Bootstrap complete"
echo "  Plugin pinned at: $PLUGIN_REV"
echo "  Cache at:         $PLUGIN_DIR/$PLUGIN_CACHE_VER"
echo "  Next: cd into your consumer repo + run \`pre-commit install --install-hooks\`"
