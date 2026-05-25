#!/bin/bash
set -euo pipefail
# v0.8.6 (#22): bootstrap-machine — one-command setup for a new dev
# machine consuming the claude-workflow-core plugin.
#
# Installs (via Homebrew on macOS):
#   - gh, jq, yq, pre-commit, shellcheck, shfmt, actionlint
#   - gitleaks, semgrep (via pip), age, sops
#   - coderabbit CLI (npm), copilot CLI (gh extension)
#
# Wires:
#   - Plugin cache install at latest tagged version
#   - ~/.claude/settings.json: reference check only (no auto-edit —
#     operator enables via `/plugin enable` to avoid magic mutation)
#   - Keychain entries: presence check only, prints add commands
#     for missing entries (operator runs `security add-generic-password`)
#
# Idempotent: every step checks current state first; safe to re-run.
#
# Usage:
#   scripts/bootstrap-machine.sh
#   scripts/bootstrap-machine.sh --dry-run    # show what would happen
#   scripts/bootstrap-machine.sh --tag v0.8.5 # pin a specific plugin tag
#
# Platform: macOS only (uses Homebrew + Keychain). Linux support is a
# follow-up — see linux-specific package managers + secret-tool dance.

DRY_RUN=0
PIN_TAG=""

while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--tag)
		if [ $# -lt 2 ]; then
			echo "error: --tag requires a value (e.g. --tag v0.8.5)" >&2
			exit 2
		fi
		PIN_TAG="$2"
		shift 2
		;;
	-h | --help)
		grep '^#' "$0" | head -25
		exit 0
		;;
	*)
		echo "unknown arg: $1" >&2
		exit 2
		;;
	esac
done

_run() {
	echo "→ $*" >&2
	if [ "$DRY_RUN" = "1" ]; then return 0; fi
	"$@"
}

_log() { echo "[bootstrap-machine] $*" >&2; }

# --- Platform check --------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
	echo "error: bootstrap-machine.sh currently supports macOS only" >&2
	echo "  See follow-up issue for Linux support (apt/dnf + secret-tool)." >&2
	exit 2
fi

# --- Homebrew --------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
	_log "Homebrew not found — install from https://brew.sh first, then re-run"
	exit 2
fi

# --- Required CLI tools (via Homebrew) -------------------------------
brew_packages=(
	gh
	jq
	yq
	pre-commit
	shellcheck
	shfmt
	actionlint
	gitleaks
	age
	sops
)

_log "checking Homebrew packages..."
for pkg in "${brew_packages[@]}"; do
	if brew list --formula --versions "$pkg" >/dev/null 2>&1; then
		_log "  ✓ $pkg already installed"
	else
		_run brew install "$pkg"
	fi
done

# --- Python-installed tools (semgrep) --------------------------------
if ! command -v semgrep >/dev/null 2>&1; then
	if ! command -v pip3 >/dev/null 2>&1; then
		_log "  ⚠ pip3 not available — install Python3 first (brew install python@3.12)"
		_log "    then re-run, or: pip3 install --user semgrep"
		exit 2
	fi
	_log "installing semgrep via pip3..."
	_run pip3 install --user semgrep
else
	_log "  ✓ semgrep already installed ($(semgrep --version 2>&1 | head -1))"
fi

# --- CodeRabbit CLI (npm global) -------------------------------------
if ! command -v coderabbit >/dev/null 2>&1; then
	if ! command -v npm >/dev/null 2>&1; then
		_log "  ⚠ npm not available — install Node.js first (brew install node)"
		_log "    then re-run, or: npm install -g @coderabbit/cli"
		exit 2
	fi
	_log "installing @coderabbit/cli via npm..."
	_run npm install -g @coderabbit/cli
else
	_log "  ✓ coderabbit CLI already installed"
fi

# --- Copilot CLI (gh extension) --------------------------------------
if gh extension list 2>/dev/null | grep -q "github/gh-copilot"; then
	_log "  ✓ gh-copilot extension already installed"
else
	_log "installing gh-copilot extension..."
	_run gh extension install github/gh-copilot
fi

# --- Plugin cache install -------------------------------------------
PLUGIN_REPO_URL="${PLUGIN_REPO_URL:-https://github.com/repbyrepdev/claude-workflow-core}"
PLUGIN_CACHE="$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core"

if [ -z "$PIN_TAG" ]; then
	# Latest tag — derive owner/repo from PLUGIN_REPO_URL so overrides work.
	_log "resolving latest plugin tag from $PLUGIN_REPO_URL..."
	# Strip protocol + .git suffix → owner/repo. Supports both https + ssh.
	owner_repo=$(echo "$PLUGIN_REPO_URL" | sed -E 's|^https?://github\.com/||; s|^git@github\.com:||; s|\.git$||')
	if [ -z "$owner_repo" ] || [[ ! "$owner_repo" =~ ^[^/]+/[^/]+$ ]]; then
		_log "  ⚠ cannot parse owner/repo from PLUGIN_REPO_URL='$PLUGIN_REPO_URL'"
		_log "    expected format: https://github.com/<owner>/<repo>"
		exit 2
	fi
	PIN_TAG=$(gh api "repos/$owner_repo/releases/latest" --jq '.tag_name' 2>/dev/null || echo "")
	if [ -z "$PIN_TAG" ]; then
		_log "  ⚠ failed to resolve latest tag from $owner_repo — re-run with --tag <vX.Y.Z>"
		exit 2
	fi
fi

# Strip leading 'v' for plugin cache dir name (matches existing layout)
PIN_VER="${PIN_TAG#v}"
TARGET_DIR="$PLUGIN_CACHE/$PIN_VER"

if [ -d "$TARGET_DIR" ]; then
	_log "  ✓ plugin cache $PIN_VER already installed at $TARGET_DIR"
else
	_log "cloning plugin $PIN_TAG into $TARGET_DIR..."
	_run mkdir -p "$PLUGIN_CACHE"
	_run git clone --branch "$PIN_TAG" --single-branch --depth 1 "$PLUGIN_REPO_URL" "$TARGET_DIR"
fi

# --- User-scope settings.json hook registration ----------------------
#
# The user is expected to invoke `/plugin enable claude-workflow-core@...`
# via Claude Code itself OR drop the appropriate stanza in settings.json.
# This script doesn't auto-edit settings.json (too magic) — instead it
# prints the lines to add.
SETTINGS_FILE="$HOME/.claude/settings.json"
if [ ! -f "$SETTINGS_FILE" ]; then
	_log "  ⚠ $SETTINGS_FILE not found — Claude Code may not be installed yet"
else
	if grep -q "claude-workflow-core" "$SETTINGS_FILE" 2>/dev/null; then
		_log "  ✓ ~/.claude/settings.json already references claude-workflow-core"
	else
		_log "  ⚠ ~/.claude/settings.json does not reference claude-workflow-core."
		_log "    Add the plugin via: /plugin enable claude-workflow-core@<marketplace>"
		_log "    Or manually wire enabledPlugins.\"claude-workflow-core@<marketplace>\": true"
	fi
fi

# --- Keychain entries (informational) --------------------------------
#
# Each consumer needs its own tokens. Print which entries the workflow
# expects; operator creates them via `security add-generic-password`.
expected_keychain_items=(
	"sops-age-key — age secret key (~/.config/sops/age/keys.txt)"
	"coalesce-access-token — Coalesce API token (FCP consumers only)"
	"coalesce-catalog-token — Coalesce Catalog token (FCP consumers only)"
	"firecrawl-api-key — Firecrawl API key (optional)"
	"brave-api-key — Brave Search API key (optional)"
)

_log "checking expected Keychain entries (informational — manual setup)..."
for item in "${expected_keychain_items[@]}"; do
	name="${item%% —*}"
	if security find-generic-password -a "$USER" -s "$name" >/dev/null 2>&1; then
		_log "  ✓ $name present"
	else
		_log "  • $name missing — add via:"
		_log "      security add-generic-password -a \"\$USER\" -s $name -w \"<value>\""
	fi
done

# --- Summary ---------------------------------------------------------
_log ""
_log "bootstrap-machine complete (DRY_RUN=$DRY_RUN, plugin pin=$PIN_TAG)."
_log "Next steps:"
_log "  1. If ~/.claude/settings.json wasn't wired, enable the plugin via Claude Code"
_log "  2. Add any missing Keychain entries listed above"
_log "  3. For a new consumer repo, run: /bootstrap-repo --name <repo> (skill #21)"
