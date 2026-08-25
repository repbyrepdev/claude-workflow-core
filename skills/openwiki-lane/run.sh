#!/bin/bash
set -euo pipefail
# (#2629) openwiki-lane skill wrapper — makes the run-preconditions MECHANICAL.
#
# The expensive lessons behind this live in references/operations.md. Two are
# checkable, so they are checked here rather than trusted:
#   - gotcha 5: `openwiki --init` rewrites AGENTS.md/CLAUDE.md in the git
#     root, so an init against a dirty tree bundles unrelated files into the
#     next commit.
#   - install/MCP state: the MCP server is read at SESSION START, so a
#     just-installed server is not usable until the next session. Reporting
#     that plainly prevents the "why can't you see the tool" loop.
#
# SCOPE, stated honestly: this wrapper only PROBES and REFUSES. It does not
# wrap generation, so both real entry points (the MCP tool in-chat and
# `openwiki code --update` in CI) can bypass it entirely. `preflight` is a
# gate you choose to run, not one the system forces.
#
# Subcommands:
#   status     CLI version, MCP wiring, repo init state (never fails on state)
#   preflight  refuse-if-unsafe gate before an init/update (rc 1 = unsafe)
#   doctor     status + preflight + remediation hints (ALWAYS rc 0 —
#              diagnostic; do not switch on its exit code)
#
# Exit: 0 ok · 1 preflight refused (unsafe) · 2 usage/env error

# skill-wrapper contract: internal git calls must pass skill-bypass-guard.
export SKILL_WRAPPER=1

_usage() {
	cat <<'HELP'
Usage: skills/openwiki-lane/run.sh <status|preflight|doctor>

  status     Report CLI version, MCP wiring, and this repo's openwiki state.
  preflight  Refuse (rc 1) if it is unsafe to run openwiki here.
  doctor     status + preflight + what to do about each problem (always rc 0).

Read skills/openwiki-lane/references/operations.md before a first run.
HELP
}

case "${1:-}" in
-h | --help)
	_usage
	exit 0
	;;
status | preflight | doctor) CMD="$1" ;;
"")
	echo "openwiki-lane: subcommand required" >&2
	_usage >&2
	exit 2
	;;
*)
	echo "openwiki-lane: unknown subcommand: $1" >&2
	_usage >&2
	exit 2
	;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "openwiki-lane: not inside a git repo — openwiki operates on a repo tree" >&2
	exit 2
}

# ---- state probes (each prints ONE line; none exit non-zero on absence) ----

_cli_version() {
	command -v openwiki >/dev/null 2>&1 || {
		echo "absent"
		return
	}
	# Capture FIRST, then branch on emptiness. A piped `|| echo` fires on the
	# PIPELINE status, so under `set -o pipefail` it can print a fallback IN
	# ADDITION to real output — e.g. multi-line --version output makes head
	# close the pipe, SIGPIPE fails the pipeline, and the status table gets a
	# two-line field. stderr is folded in so a broken CLI explains itself.
	local v
	v=$(openwiki --version 2>&1 | head -1) || v=""
	if [ -n "$v" ]; then
		echo "$v"
	else
		echo "present (version unreadable)"
	fi
}

# The MCP entry lives in the user's ~/.claude.json. Absence is a STATE; a
# corrupt file or a missing jq are ERRORS, and reporting those as "not wired"
# would send the operator to re-run bootstrap-machine, which cannot fix them.
_mcp_state() {
	local cfg="$HOME/.claude.json"
	[ -r "$cfg" ] || {
		echo "no ~/.claude.json"
		return
	}
	command -v jq >/dev/null 2>&1 || {
		echo "unknown (jq missing — cannot read ~/.claude.json)"
		return
	}
	if ! jq -e . "$cfg" >/dev/null 2>&1; then
		echo "unknown (~/.claude.json is not valid JSON)"
		return
	fi
	if ! jq -e '.mcpServers.openwiki' "$cfg" >/dev/null 2>&1; then
		echo "not wired"
		return
	fi
	# Distinguish the published-CLI wiring from the obsolete source-build hack
	# (operations.md "Install"): the hack points at ~/.openwiki-main.
	local args
	args=$(jq -r '.mcpServers.openwiki | (.args // []) | join(" ")' "$cfg" 2>/dev/null) || args=""
	case "$args" in
	*openwiki-main*) echo "wired (SOURCE-BUILD HACK — supersede with the published CLI)" ;;
	*) echo "wired" ;;
	esac
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

# Returns 0 = dirty, 1 = clean, 2 = UNKNOWN (git failed). Callers must treat
# unknown as unsafe: testing only git's OUTPUT fails OPEN, because a corrupt
# index exits 128 with EMPTY stdout, which reads as "clean" over uncommitted
# work — in the wrapper's own primary refusal.
_TREE_ERR=""
_tree_state() {
	local out rc=0
	out=$(git -C "$REPO_ROOT" status --porcelain 2>&1) || rc=$?
	if [ "$rc" -ne 0 ]; then
		_TREE_ERR="$out"
		return 2
	fi
	[ -n "$out" ]
}

_print_status() {
	echo "openwiki-lane status — $REPO_ROOT"
	echo "  CLI:       $(_cli_version)"
	echo "  MCP:       $(_mcp_state)"
	echo "  This repo: $(_repo_state)"
	local ts=0
	_tree_state || ts=$?
	case "$ts" in
	0) echo "  Tree:      DIRTY" ;;
	1) echo "  Tree:      clean" ;;
	*) echo "  Tree:      UNKNOWN (git failed: ${_TREE_ERR:-no stderr})" ;;
	esac
}

# ---- preflight: the refusals ----------------------------------------------

_preflight() {
	local unsafe=0 ts=0
	_tree_state || ts=$?
	if [ "$ts" -eq 0 ]; then
		echo "openwiki-lane: REFUSING — working tree is dirty." >&2
		echo '  `openwiki --init` rewrites AGENTS.md/CLAUDE.md in the git root; on a' >&2
		echo "  dirty tree that bundles unrelated files into your next commit" >&2
		echo "  (operations.md gotcha 5)." >&2
		echo "  Fix: commit or stash, then re-run." >&2
		unsafe=1
	elif [ "$ts" -eq 2 ]; then
		echo "openwiki-lane: REFUSING — cannot determine tree state; git failed:" >&2
		echo "  ${_TREE_ERR:-no stderr}" >&2
		echo "  Unknown is treated as unsafe: a git error must never read as clean." >&2
		unsafe=1
	fi
	if ! command -v openwiki >/dev/null 2>&1; then
		echo "openwiki-lane: REFUSING — CLI not installed." >&2
		echo "  Fix: scripts/bootstrap-machine.sh (installs the pinned CLI + MCP wiring)." >&2
		unsafe=1
	fi
	[ "$unsafe" -eq 0 ] || return 1
	echo "openwiki-lane: preflight OK — safe to run."
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
	# Diagnostic by contract: doctor reports, it does not gate. Always rc 0.
	_preflight || true
	echo ""
	echo "Notes:"
	echo "  - The MCP server is read at SESSION START. A fresh install becomes"
	echo "    usable in the NEXT session, not the current one."
	echo "  - First generation belongs in the in-chat MCP lane (free, runs on the"
	echo "    host session). CI is for cheap weekly deltas and costs credits."
	echo "  - Corrections go in openwiki/INSTRUCTIONS.md — edits to generated"
	echo "    pages are reverted by the update loop (operations.md gotcha 6)."
	echo "  - preflight does NOT check MCP wiring, and nothing forces you to run"
	echo "    it before generating; it is a gate you choose."
	;;
esac
