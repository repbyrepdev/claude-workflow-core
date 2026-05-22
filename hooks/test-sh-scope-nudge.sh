#!/bin/bash
set -u
# event: PreToolUse
# matcher: Bash
# v4.24-R (#605) / v4.28-W3-C (#665) — PreToolUse Bash gate. Filename
# retains "scope-nudge" basename from the v4.24-R advisory era (now
# upgraded to BLOCKING per #665) for log/audit-trail stability.
# Functionally a hard block, name preserved by intent.
#
# Label conventions (intentionally split per audience):
#   - JSONL log label: `test-sh-scope-block` (machine-grep'd; reflects
#     the BLOCKING semantics)
#   - Stderr label:    `test-sh-scope-nudge:` (human-grep stability;
#     long history of pre-#665 logs use this prefix)
# bats expects the JSONL `test-sh-scope-block` label;
# operator-grep continues to find `test-sh-scope-nudge:` on stderr.
#
# What it gates: bare `scripts/test.sh` (full suite, ~700 tests) blocks
# unless the caller explicitly opted into full-suite via --baseline /
# --coverage / --full / --no-log or a specific path argument.
# v4.28-W3-C upgrades from advisory to BLOCKING per #665 — repeated
# observation that the advisory got ignored, full suite ran in
# iteration loops, burned 10-50× the per-iteration time.
#
# Policy:
#  - `scripts/test.sh --baseline` / `--coverage` / `--full` / `--no-log` /
#    a specific path argument → allowed (valid full-suite or scoped uses)
#  - `scripts/test.sh` BARE → REFUSED, redirected to test-touched.sh.
#    Bypass: TEST_SH_FULL_OK=1 (operator-explicit; no automatic setter
#    in-tree today — full-suite is operator-driven for pre-push
#    validation or weekly baseline runs).
#
# Registered via ~/.claude/settings.json hooks.PreToolUse matcher=Bash.

PAYLOAD=$(cat 2>/dev/null || echo "{}")
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -z "$CMD" ] && exit 0

# v4.28-W3-C (#665): allow legit full-suite contexts via env.
# Set by an operator running `TEST_SH_FULL_OK=1 scripts/test.sh ...`
# for a deliberate full run (pre-push validation, weekly baseline,
# CI/cron contexts that need the full suite). No automatic setter
# in-tree today — operator-explicit only.
if [ "${TEST_SH_FULL_OK:-0}" = "1" ]; then
	exit 0
fi
# Inline-prefix variant (PreToolUse env-var visibility quirk).
# r3 fix (pr-test-analyzer C2): anchor on command-start or shell
# separator so `echo TEST_SH_FULL_OK=1 && scripts/test.sh` doesn't
# spoof the bypass. Pattern requires the env-var to START a segment
# (i.e. preceded by command-start or `&&`/`||`/`;`/`|`/`&` + optional
# whitespace), not just any whitespace.
# v4.28-W4 (#677): use shared CMD_SEGMENT_ANCHOR via _lib/cmd-anchor.sh
# instead of a local regex variant.
# shellcheck source=../_lib/cmd-anchor.sh
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/cmd-anchor.sh"
if printf '%s' "$CMD" | grep -qE "${CMD_SEGMENT_ANCHOR}TEST_SH_FULL_OK=1[[:space:]]+"; then
	exit 0
fi

# r3 fix (#659+#665+r3 multi-vector): the r2 substring-allowlist had
# critical bypasses caught by silent-failure-hunter + pr-test-analyzer
# round 3:
#   - `cat scripts/test.sh && scripts/test.sh` — left half matched the
#     `*"cat "*"scripts/test.sh"*` allowlist, exited 0 before the runner
#     in the right segment was detected.
#   - `scripts/test.sh && echo --baseline` — right half matched the
#     `*"scripts/test.sh "*"--baseline"*` allowlist, bypassed the block.
#   - `echo TEST_SH_FULL_OK=1 && scripts/test.sh` — `TEST_SH_FULL_OK=1`
#     substring spoofed the bypass without actually setting any env.
# Root cause: substring matching on a multi-segment command line. Fix:
# tokenize $CMD on shell separators (;, &&, ||, |, &), then apply
# runner-detection + allowlist PER-SEGMENT. A bare runner segment in
# ANY split position trips. Bypass env-var must START a segment.
_seg_should_block() {
	# $1 = single command segment (no shell separators).
	local seg=$1
	# Strip leading whitespace + env-var assignments + known wrappers.
	while :; do
		case "$seg" in
		[[:space:]]*) seg=${seg#[[:space:]]} ;;
		[A-Za-z_]*=*)
			# Strip a `VAR=value` env-prefix. If no space follows the
			# assignment (bare `FOO=bar` segment, no command), drop the
			# entire segment — otherwise `${seg#* }` is a no-op and the
			# while-loop spins forever (CR #683 r1 critical).
			case "$seg" in
			*" "*) seg=${seg#* } ;;
			*) seg="" ;;
			esac
			;;
		"sudo "* | "time "* | "nice "* | "env "* | "xargs "*) seg=${seg#* } ;;
		"bash "* | "/bin/bash "* | "sh "* | "/bin/sh "* | "zsh "* | "/bin/zsh "*) seg=${seg#* } ;;
		"./scripts/test.sh"*) seg="scripts/test.sh${seg#./scripts/test.sh}" ;;
		*) break ;;
		esac
	done
	case "$seg" in
	"scripts/test.sh") return 0 ;;
	"scripts/test.sh "*"--baseline"* | "scripts/test.sh "*"--coverage"* | \
		"scripts/test.sh "*"--full"* | "scripts/test.sh "*"--no-log"* | \
		"scripts/test.sh -"*) return 1 ;;
	"scripts/test.sh "*".bats"* | "scripts/test.sh "*".claude/tests"*) return 1 ;;
	"scripts/test.sh "*) return 0 ;;
	*) return 1 ;;
	esac
}

# Tokenize: replace `&&`/`||`/`|`/`&` with `;` so a single IFS-split
# handles them all.
_NORMALIZED=$(printf '%s' "$CMD" | sed -E 's/&&/;/g; s/\|\|/;/g; s/[|&]/;/g')
_SEGMENTS_BLOCK=0
IFS=';' read -r -a _SEGS <<<"$_NORMALIZED"
for _seg in "${_SEGS[@]+"${_SEGS[@]}"}"; do
	if _seg_should_block "$_seg"; then
		_SEGMENTS_BLOCK=1
		break
	fi
done

if [ "$_SEGMENTS_BLOCK" = "0" ]; then
	exit 0
fi

case "$CMD" in
*"scripts/test.sh"*)
	REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
	if [ -n "$REPO_ROOT" ] && command -v jq >/dev/null 2>&1; then
		mkdir -p "$REPO_ROOT/.claude/logs" 2>/dev/null || true
		jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			--arg cmd "${CMD:0:200}" \
			'{ts:$ts, label:"test-sh-scope-block", cmd_preview:$cmd}' \
			>>"$REPO_ROOT/.claude/logs/test-sh-scope-skip.jsonl" 2>/dev/null || true
	fi
	# v4.28-W3-C #665: emit deny-JSON + exit 0 (PreToolUse blocking
	# contract per v4.17.R). Same pattern as skill-bypass-guard's deny().
	REASON="BLOCKED: bare \`scripts/test.sh\` runs all ~700 tests, defeating the iteration loop.

For iteration: scripts/test-touched.sh (scoped via # covers: headers, 10-50× faster).
For one file:  scripts/test.sh path/to/file.bats
For full:      scripts/test.sh --full   (or --baseline / --coverage / --no-log)
Bypass (operator-explicit, used for pre-push / baseline runs): TEST_SH_FULL_OK=1 scripts/test.sh"
	if command -v jq >/dev/null 2>&1; then
		jq -nc --arg r "$REASON" \
			'{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
	else
		echo "$REASON" >&2
		exit 2
	fi
	echo "test-sh-scope-nudge: $REASON" >&2
	exit 0
	;;
esac

exit 0
