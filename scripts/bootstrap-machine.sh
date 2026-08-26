#!/bin/bash
set -euo pipefail
# v0.8.6 (#22): bootstrap-machine — one-command setup for a new dev
# machine consuming the claude-workflow-core plugin.
#
# Installs (via Homebrew on macOS):
#   - gh, jq, yq, pre-commit, shellcheck, shfmt, actionlint
#   - gitleaks, semgrep (via pip), age, sops
#   - coderabbit CLI (npm), copilot CLI (gh extension)
#   - openwiki CLI (npm, pinned via OPENWIKI_PIN)
#
# Wires:
#   - Plugin cache install at latest tagged version
#   - openwiki MCP server (`integrations install claude`) — the free
#     in-chat lane; loaded at SESSION START, so restart after a fresh wire
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
# Resolved once so sourced helpers (see _lib/openwiki-mcp-state.sh below) keep
# working regardless of the caller's cwd.
BM_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

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
		# NOT `grep '^#' "$0" | head -28`: this file has far more than 28
		# comment lines, so head closes the pipe, grep takes SIGPIPE, and
		# under `set -o pipefail` + `set -e` the help path aborts BEFORE its
		# own `exit 0` — making --help exit non-zero. awk stops on its own
		# instead of having the pipe closed under it.
		awk '/^#/ { print; if (++n >= 28) exit }' "$0"
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

# --- OpenWiki CLI + in-chat MCP lane (npm global) --------------------
#
# (#2629) The in-chat lane runs OpenWiki on the HOST agent's own session —
# no provider key, no Copilot credits — which makes it the right place for
# the expensive first generation. `integrations install claude` is native
# as of 0.4.0; earlier versions could not serve MCP at all, which forced a
# pnpm source build at ~/.openwiki-main. If this machine still carries that
# hack, the install below supersedes it — see skills/openwiki-lane/references/
# operations.md, and `skills/openwiki-lane/run.sh status` names it explicitly.
#
# Pinned so the machine CLI cannot drift out from under the repo-side
# .github/openwiki-toolchain pin. NOTE this pins only the TOP-LEVEL version:
# `npm install -g` does not honour a published package's lockfile, so the
# transitive tree (~29 deps, mostly caret ranges) resolves fresh and its
# lifecycle scripts run as this user. That is weaker than the CI lane, which
# uses `npm ci` against a committed lockfile with integrity hashes.
OPENWIKI_PIN="${OPENWIKI_PIN:-0.4.0}"
# A bare `command -v` presence check does not enforce a PIN — it enforces
# "some openwiki exists", which is the one thing pinning is meant to rule out.
# A machine that installed 0.3.x before this step existed would keep it
# forever while the repo-side toolchain pin moved, which is exactly the
# two-lanes-disagree failure the lockstep test exists to prevent. Compare, and
# reinstall on any answer that is not the pin.
#
# Version output is matched by extracting the first semver rather than by
# equality, because the CLI's format is not part of its contract ("0.4.0" and
# "openwiki/0.4.0" both occur in the wild). An UNREADABLE version counts as a
# mismatch: "cannot confirm the pin holds" must not report as "the pin holds".
_ow_installed_version() {
	openwiki --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}
# CI r1: `_run` under `set -e` makes every OpenWiki command load-bearing for
# the WHOLE bootstrap — a registry blip during `npm install -g openwiki` would
# abort before the plugin cache install, the Keychain report and the summary.
# OpenWiki is one optional step of a machine setup, and the section already
# warns-and-continues when npm is missing entirely; a FAILED install has to
# degrade the same way rather than taking the run down with it.
_ow_run_optional() { # never fails the bootstrap; records the skip instead
	if _run "$@"; then
		return 0
	fi
	_log "  ⚠ '$*' FAILED — continuing without it."
	OPENWIKI_WIRING_SKIPPED=1
	return 1
}
if ! command -v openwiki >/dev/null 2>&1; then
	if ! command -v npm >/dev/null 2>&1; then
		_log "  ⚠ npm not available — install Node.js first (brew install node)"
		_log "    then re-run, or: npm install -g openwiki@$OPENWIKI_PIN"
	else
		_log "installing openwiki@$OPENWIKI_PIN via npm..."
		_ow_run_optional npm install -g "openwiki@$OPENWIKI_PIN" || true
	fi
else
	OW_HAVE=$(_ow_installed_version) || OW_HAVE=""
	if [ "$OW_HAVE" = "$OPENWIKI_PIN" ]; then
		_log "  ✓ openwiki CLI already installed at the pin ($OPENWIKI_PIN)"
	elif ! command -v npm >/dev/null 2>&1; then
		_log "  ⚠ openwiki is ${OW_HAVE:-an unreadable version}, pin is $OPENWIKI_PIN,"
		_log "    and npm is not available to correct it. Install Node.js, then:"
		_log "    npm install -g openwiki@$OPENWIKI_PIN"
	else
		_log "openwiki is ${OW_HAVE:-an unreadable version}, pin is $OPENWIKI_PIN — reinstalling..."
		_ow_run_optional npm install -g "openwiki@$OPENWIKI_PIN" || true
	fi
fi

# Wire the MCP server. Idempotent: the installer rewrites its own entry, and
# re-running is how a source-build hack gets replaced by the published CLI.
# NOTE: Claude Code reads MCP servers at SESSION START — a fresh install is
# usable in the NEXT session, not the current one.
#
# DRY_RUN is in the condition on purpose: under --dry-run nothing was
# installed above, so a bare `command -v openwiki` would silently hide a step
# the real run WOULD perform — a preview that omits work is the same
# silent-skip class this repo refuses elsewhere.
#
# The state parse is SHARED with skills/openwiki-lane/run.sh via
# _lib/openwiki-mcp-state.sh — one question, one parser. Duplicating it once
# produced the identical fail-open bug in both copies, and fixing one is how
# the other was found (CI r1). This caller's POLICY is repair: every state
# that is not a healthy published-CLI entry routes to the installer, including
# the obsolete ~/.openwiki-main source build, which the installer supersedes.
#
# `no-jq` is the one state that is NOT repairable by re-running the installer,
# so it is called out rather than folded in silently.
# shellcheck source=../_lib/openwiki-mcp-state.sh
. "$BM_SCRIPT_DIR/../_lib/openwiki-mcp-state.sh"
if command -v openwiki >/dev/null 2>&1 || [ "$DRY_RUN" = "1" ]; then
	OW_MCP_STATE=$(openwiki_mcp_state "$HOME/.claude.json")
	if [ "$OW_MCP_STATE" = "no-jq" ]; then
		_log "  ⚠ cannot read ~/.claude.json — jq is not installed, so the openwiki"
		_log "    MCP entry could not be checked. Install jq and re-run."
		OPENWIKI_WIRING_SKIPPED=1
	elif [ "$OW_MCP_STATE" = "wired" ]; then
		_log "  ✓ openwiki MCP server already wired"
	else
		_log "wiring the openwiki MCP server (integrations install claude)..."
		if _ow_run_optional openwiki integrations install claude; then
			_log "    ↳ restart the Claude Code session for the MCP server to load"
		fi
	fi
else
	# Reachable on a REAL run: the npm-absent branch above warns and
	# continues, and the global bin dir may not be on PATH. Skipping the
	# whole section in silence would let automation read an openwiki-less
	# bootstrap as clean — the same silent-skip the DRY_RUN guard prevents.
	_log "  ⚠ openwiki CLI not on PATH — SKIPPED the MCP wiring (the free in-chat lane will not exist)."
	_log "    Fix: install Node/npm, ensure the npm global bin is on PATH, then re-run;"
	_log "    or run manually: npm i -g openwiki@$OPENWIKI_PIN && openwiki integrations install claude"
	OPENWIKI_WIRING_SKIPPED=1
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
	if [ -z "$owner_repo" ] || [[ ! $owner_repo =~ ^[^/]+/[^/]+$ ]]; then
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
		_log '    Or manually wire enabledPlugins."claude-workflow-core@<marketplace>": true'
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
if [ "${OPENWIKI_WIRING_SKIPPED:-0}" = "1" ]; then
	_log "  ⚠ openwiki MCP wiring was SKIPPED — see the warning above."
fi
_log "Next steps:"
_log "  1. If ~/.claude/settings.json wasn't wired, enable the plugin via Claude Code"
_log "  2. Add any missing Keychain entries listed above"
_log "  3. For a new consumer repo, run: /bootstrap-repo --name <repo> (skill #21)"
