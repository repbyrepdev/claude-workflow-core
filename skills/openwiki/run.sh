#!/bin/bash
set -euo pipefail
# auto-register: false
# (#2629) openwiki skill wrapper — makes the run-preconditions MECHANICAL.
#
# The expensive lessons behind this live in references/operations.md. Two of
# them are checkable, so they are checked here rather than trusted:
#   - gotcha 5: `openwiki --init` rewrites AGENTS.md/CLAUDE.md in the git root;
#     against a dirty tree it bundles unrelated files into the next commit AND
#     (in this repo) trips the hash-drift + bootstrap-heredoc byte-SSOT gates.
#   - install/MCP state: the MCP server is read at SESSION START, so a
#     just-installed server is not usable until the next session. Reporting
#     that plainly prevents the "why can't you see the tool" loop.
#
# Subcommands:
#   status     CLI version, MCP wiring, repo init state (never fails on state)
#   preflight  refuse-if-unsafe gate before an init/update (rc 1 = unsafe)
#   doctor     status + preflight + remediation hints
#
# Exit: 0 ok · 1 preflight refused (unsafe to run openwiki) · 2 usage/env error

# skill-wrapper contract: internal git calls must pass skill-bypass-guard.
export SKILL_WRAPPER=1

_usage() {
	cat <<'HELP'
Usage: skills/openwiki/run.sh <status|preflight|doctor>

  status     Report CLI version, MCP wiring, and this repo's openwiki state.
  preflight  Refuse (rc 1) if it is unsafe to run openwiki here.
  doctor     status + preflight + what to do about each problem.

Read skills/openwiki/references/operations.md before a first run.
HELP
}

case "${1:-}" in
-h | --help)
	_usage
	exit 0
	;;
status | preflight | doctor) CMD="$1" ;;
"")
	echo "openwiki: subcommand required" >&2
	_usage >&2
	exit 2
	;;
*)
	echo "openwiki: unknown subcommand: $1" >&2
	_usage >&2
	exit 2
	;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "openwiki: not inside a git repo — openwiki operates on a repo tree" >&2
	exit 2
}

# ---- state probes (each prints one line; none exit non-zero on absence) ----

_cli_version() {
	command -v openwiki >/dev/null 2>&1 || {
		echo "absent"
		return
	}
	# Version is best-effort — a broken CLI must not stall the probe.
	openwiki --version 2>/dev/null | head -1 || echo "present (version unreadable)"
}

# The MCP entry lives in the user's ~/.claude.json. Absence is a state, not an
# error. jq is a hard dep of this repo's tooling, so no fallback parser.
_mcp_state() {
	local cfg="$HOME/.claude.json"
	[ -r "$cfg" ] || {
		echo "no ~/.claude.json"
		return
	}
	if jq -e '.mcpServers.openwiki' "$cfg" >/dev/null 2>&1; then
		# Distinguish the published-CLI wiring from the obsolete source-build
		# hack (operations.md "Install"): the hack points at ~/.openwiki-main.
		if jq -r '.mcpServers.openwiki | (.args // []) | join(" ")' "$cfg" 2>/dev/null | grep -q "openwiki-main"; then
			echo "wired (SOURCE-BUILD HACK — supersede with the published CLI)"
		else
			echo "wired"
		fi
	else
		echo "not wired"
	fi
}

_repo_state() {
	[ -d "$REPO_ROOT/openwiki" ] || {
		echo "no openwiki/ (never generated)"
		return
	}
	if [ -f "$REPO_ROOT/openwiki/INSTRUCTIONS.md" ]; then
		echo "generated (INSTRUCTIONS.md present — the steering channel)"
	else
		echo "generated (NO INSTRUCTIONS.md — corrections have nowhere durable to go)"
	fi
}

_tree_dirty() {
	# Porcelain is empty iff the tree is clean (tracked + untracked).
	[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]
}

_print_status() {
	echo "openwiki status — $REPO_ROOT"
	echo "  CLI:       $(_cli_version)"
	echo "  MCP:       $(_mcp_state)"
	echo "  This repo: $(_repo_state)"
	if _tree_dirty; then
		echo "  Tree:      DIRTY"
	else
		echo "  Tree:      clean"
	fi
}

# ---- preflight: the refusals ----------------------------------------------
# Returns 1 when running openwiki here is unsafe. Each refusal names the
# gotcha it enforces so the remedy is obvious without opening the reference.

_preflight() {
	local unsafe=0
	if _tree_dirty; then
		echo "openwiki: REFUSING — working tree is dirty." >&2
		echo '  `openwiki --init` rewrites AGENTS.md/CLAUDE.md in the git root; on a' >&2
		echo "  dirty tree that bundles unrelated files into your next commit and can" >&2
		echo "  trip this repo's byte-SSOT gates (operations.md gotcha 5)." >&2
		echo "  Fix: commit or stash, then re-run." >&2
		unsafe=1
	fi
	if ! command -v openwiki >/dev/null 2>&1; then
		echo "openwiki: REFUSING — CLI not installed." >&2
		echo "  Fix: scripts/bootstrap-machine.sh (installs the pinned CLI + MCP wiring)." >&2
		unsafe=1
	fi
	[ "$unsafe" -eq 0 ] || return 1
	echo "openwiki: preflight OK — safe to run."
}

case "$CMD" in
status)
	_print_status
	;;
preflight)
	_preflight
	;;
doctor)
	_print_status
	echo ""
	_preflight || true
	echo ""
	echo "Notes:"
	echo "  - The MCP server is read at SESSION START. A fresh install becomes"
	echo "    usable in the NEXT session, not the current one."
	echo "  - First generation belongs in the in-chat MCP lane (free, runs on the"
	echo "    host session). CI is for cheap weekly deltas and costs credits."
	echo "  - Corrections go in openwiki/INSTRUCTIONS.md — edits to generated"
	echo "    pages are reverted by the update loop (operations.md gotcha 6)."
	;;
esac
