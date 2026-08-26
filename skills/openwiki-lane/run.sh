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

# Keep git's stderr: "not a repo" and "git is broken/absent" are different
# problems with different fixes, and discarding the message makes the second
# one wear the first one's label — the same tri-state lesson as the tree probe
# below, at the door instead of inside it.
_RR_ERR=""
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	_RR_ERR=$(git rev-parse --show-toplevel 2>&1 >/dev/null) || true
	echo "openwiki-lane: cannot resolve a git repo root — openwiki operates on a repo tree" >&2
	[ -n "$_RR_ERR" ] && echo "  git said: $_RR_ERR" >&2
	echo "  (If git itself is broken or missing, that is the problem, not the cwd.)" >&2
	exit 2
}

# The MCP state PARSER is shared with scripts/bootstrap-machine.sh — see the
# header of the lib for why. This skill ships inside the plugin, so the path
# is fixed relative to this file.
_OW_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib/openwiki-mcp-state.sh"
if [ ! -r "$_OW_LIB" ]; then
	echo "openwiki-lane: missing shared probe $_OW_LIB — the plugin checkout is incomplete" >&2
	exit 2
fi
# shellcheck source=../../_lib/openwiki-mcp-state.sh
. "$_OW_LIB"

# ---- state probes (each prints ONE line; none exit non-zero on absence) ----

# Shared with bootstrap-machine's pin check — see the lib header. This used to
# ask `openwiki --version`, which is not a supported flag (the real binary
# answers "Unknown option: --version"), so a healthy machine reported the
# version as unreadable forever and the pin check reinstalled on every run.
#
# Each token gets its OWN sentence. The previous message named one cause
# ("not under $(npm root -g)") for an emptiness that had four possible
# causes — asserting as fact something the probe never established.
_cli_version() {
	local st
	st=$(openwiki_installed_version)
	case "$st" in
	no-cli) echo "absent" ;;
	no-jq) echo "present (version unknown — jq missing, cannot read its package.json)" ;;
	unresolvable) echo "present (version unknown — the openwiki on PATH does not resolve to a real file)" ;;
	not-found) echo "present (version unknown — no openwiki package.json above the resolved binary)" ;;
	bad-version) echo "present (version unknown — its package.json .version is missing or not a semver)" ;;
	*) echo "$st" ;;
	esac
}

# The MCP entry lives in the user's ~/.claude.json. Absence is a STATE; a
# corrupt file or a missing jq are ERRORS, and reporting those as "not wired"
# would send the operator to re-run bootstrap-machine, which cannot fix them.
#
# The PARSE is shared with scripts/bootstrap-machine.sh via
# _lib/openwiki-mcp-state.sh (CI r1: one question answered by two copies grew
# the same fail-open bug in both). Only the POLICY is local — this caller
# REPORTS, so every state gets its own sentence, where the machine bootstrap
# collapses everything repairable into "run the installer".
_mcp_state() {
	local st
	st=$(openwiki_mcp_state "$HOME/.claude.json")
	case "$st" in
	no-config) echo "no ~/.claude.json" ;;
	no-jq) echo "unknown (jq missing — cannot read ~/.claude.json)" ;;
	bad-json) echo "unknown (~/.claude.json is not valid JSON)" ;;
	unreadable) echo "unknown (~/.claude.json: cannot read .mcpServers.openwiki)" ;;
	not-wired) echo "not wired" ;;
	bad-entry:*) echo "unknown (~/.claude.json .mcpServers.openwiki is a ${st#bad-entry:}, not an object)" ;;
	bad-args:*) echo "unknown (~/.claude.json .mcpServers.openwiki .args is ${st#bad-args:}, not an array)" ;;
	# The obsolete source build (operations.md "Install") points at
	# ~/.openwiki-main; it IS wired, just at the wrong thing.
	source-hack) echo "wired (SOURCE-BUILD HACK — supersede with the published CLI)" ;;
	wired) echo "wired" ;;
	# An unrecognised token means parser/consumer drift, not a healthy
	# server. Say that rather than defaulting into either answer.
	*) echo "unknown (unrecognised probe state '$st' — parser/consumer drift)" ;;
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
_TREE_WARN=""
_tree_state() {
	local out rc=0 errf
	# CI r1: folding stderr into $out made an rc-0 WARNING read as porcelain
	# output, so a clean tree came back DIRTY and the operator was told to
	# "commit or stash" while `git status` showed nothing to commit — with the
	# warning itself never printed. git writes advice, CRLF notices and
	# unreadable-config warnings to stderr and still exits 0. Capture the two
	# streams separately: stdout decides dirty/clean, stderr is reported.
	errf=$(mktemp -t openwiki-lane-tree.XXXXXX) || {
		_TREE_ERR="could not create a temp file for git's stderr"
		return 2
	}
	out=$(git -C "$REPO_ROOT" status --porcelain 2>"$errf") || rc=$?
	if [ "$rc" -ne 0 ]; then
		_TREE_ERR=$(cat "$errf" 2>/dev/null)
		rm -f "$errf"
		return 2
	fi
	# rc 0 with stderr text is a WARNING, not a failure — surfaced alongside
	# the verdict rather than folded into it.
	_TREE_WARN=$(cat "$errf" 2>/dev/null)
	rm -f "$errf"
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
	# A warning that did not change the verdict still has to be visible —
	# silently discarding it is how "clean tree, reported dirty" became
	# unexplainable in the first place.
	[ -n "$_TREE_WARN" ] && echo "  Tree warn: $_TREE_WARN"
	return 0
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
		[ -n "$_TREE_WARN" ] && echo "  (git also warned: $_TREE_WARN)" >&2
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
	# Diagnostic by contract: doctor REPORTS, preflight GATES. doctor is
	# documented as always rc 0 and callers are told not to switch on it, so
	# an unsafe result must not become doctor's exit code.
	#
	# But `|| true` swallowed EVERY status, including ones _preflight never
	# returns — a crash, a 127, a `set -e` abort mid-probe all read exactly
	# like the ordinary "unsafe" it is supposed to absorb. Keep rc 0; say the
	# undocumented ones out loud instead.
	_PF_RC=0
	_preflight || _PF_RC=$?
	if [ "$_PF_RC" -ne 0 ] && [ "$_PF_RC" -ne 1 ]; then
		echo "openwiki-lane: WARNING — preflight itself failed with rc $_PF_RC." >&2
		echo "  That is not one of its documented outcomes (0 safe / 1 unsafe)," >&2
		echo "  so this report is INCOMPLETE — run 'preflight' directly." >&2
	fi
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
