#!/bin/bash
set -euo pipefail
# (#2631 follow-up) Refuse bats assertions that cannot fail.
#
# bats reports failure through an ERR trap. On bash 3.2 — what macOS ships
# at /bin/bash, frozen since 2007 because bash 4.0 relicensed to GPLv3 — a
# failing `[[ ]]` fires neither that trap nor `set -e`, so the test passes
# anyway. A bare `[[ ]]` therefore only fails a test when it happens to be
# the LAST command in the block. An assertion whose enforcement depends on
# its position is not an assertion.
#
# The invariant is ABSOLUTE: zero, everywhere, always. It shipped as a
# per-file baseline ratchet instead, to grandfather the 749 no-ops that
# existed when this was found — but all of them are now fixed, and a ratchet
# with nothing left to grandfather is worse than no ratchet: the baseline
# lived at a gitignored path, so it read as empty on every machine but the
# author's, which made the debt gate in scripts/test.sh inert exactly where
# it mattered (CI, fresh clones) while looking active. Zero needs no file.
#
# The scan reads the STAGED blob, not the worktree. Committing content that
# differs from what was scanned is the whole failure mode a pre-commit gate
# exists to prevent, and `pre-commit`'s stashing does not apply when the hook
# is installed directly into .git/hooks (as consumers do).
#
# Usage:
#   bats-assertion-gate.sh          # staged .bats files (pre-commit)
#   bats-assertion-gate.sh --all    # every .bats in .claude/tests
#
# Env:
#   BATS_ASSERTION_GATE_SKIP=1         bypass the gate for one invocation.
#   BATS_ASSERTION_GATE_SKIP_REASON=…  the rationale, recorded with it.
#
# A bypass appends a row to .claude/logs/pipeline-skip.jsonl (kind
# `bats-assertion-gate-skip`) carrying the reason, or "unstated" when none was
# given — so skipping is available but never invisible.
#
# Exit: 0 clean · 1 assertions found · 2 the gate could not run (bad
# argument, not a git repo, unreadable staged blob, git failure).
#
# The two are distinct because the remedies are: 1 means fix the assertions,
# 2 means the check did not happen and nothing was verified. This shipped
# collapsing both into 2, on the stated grounds that "every sibling hook in
# this directory exits 2" — which was asserted rather than checked, and is
# false: bats-gate.sh, check-ssot-drift.sh, compose-coderabbit-regen.sh,
# consumers-schema-check.sh, edit-corruption-guard.sh and others all use
# 0/1/2 exactly this way.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "bats-assertion-gate: not in a git repo" >&2
	exit 2
}
# shellcheck source=../_lib/bats-assertion-check.sh
. "$REPO_ROOT/_lib/bats-assertion-check.sh"

if [ "${BATS_ASSERTION_GATE_SKIP:-0}" = "1" ]; then
	echo "bats-assertion-gate: SKIPPED via BATS_ASSERTION_GATE_SKIP=1" >&2
	# The audit row is the ENTIRE justification for having a bypass. Written
	# with `|| true` it was optional: an unwritable .claude/logs let the skip
	# proceed unrecorded, which is the invisible skip this hook's own header
	# promises against. Fail closed instead — if the skip cannot be recorded,
	# it does not happen.
	_reason=${BATS_ASSERTION_GATE_SKIP_REASON:-unstated}
	# Minimal JSON escaping, so a reason containing a quote or a newline
	# cannot produce a malformed row that breaks every later reader of the
	# log. Backslash first, or it would double-escape the quotes it adds.
	_reason=${_reason//\\/\\\\}
	_reason=${_reason//\"/\\\"}
	_reason=${_reason//$'\n'/ }
	_reason=${_reason//$'\t'/ }
	_reason=${_reason//$'\r'/ }
	mkdir -p "$REPO_ROOT/.claude/logs" || {
		echo "bats-assertion-gate: cannot create .claude/logs to record the skip — refusing" >&2
		exit 2
	}
	printf '{"ts":"%s","kind":"bats-assertion-gate-skip","reason":"%s"}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_reason" \
		>>"$REPO_ROOT/.claude/logs/pipeline-skip.jsonl" || {
		echo "bats-assertion-gate: cannot append to pipeline-skip.jsonl — refusing" >&2
		exit 2
	}
	exit 0
fi

MODE="staged"
case "${1:-}" in
"") ;;
--all) MODE="all" ;;
*)
	# Refuse rather than silently ignore: an unrecognised argument in a
	# pre-commit hook most likely means a caller expected behaviour this
	# script does not have, and quietly running the default hides that.
	echo "bats-assertion-gate: unknown argument '$1' (expected nothing, or --all)" >&2
	exit 2
	;;
esac

tmp=$(mktemp) || exit 2
staged_list=$(mktemp) || exit 2
trap 'rm -f "$tmp" "$staged_list"' EXIT

violations=0
scanned=0

# rc 0 clean · 1 findings · 2 unreadable/unjudgeable. The third is NOT a pass:
# a detector that reports "clean" when it could not read the file is worse
# than no detector, because the commit proceeds with a green signal.
_scan_one() { # $1 = path to scan, $2 = display path
	local found rc=0
	found=$(bats_assertion_scan "$1") || rc=$?
	case "$rc" in
	0) return 0 ;;
	1) ;;
	*)
		# Exit 2 directly, not via the violations counter: "could not judge"
		# is the check failing to run, whose remedy is different from "fix
		# these assertions". Collapsing it into 1 would tell the caller to go
		# looking for assertions that were never found.
		echo "" >&2
		echo "bats-assertion-gate: could not judge $2 — refusing rather than passing it" >&2
		exit 2
		;;
	esac
	echo "" >&2
	echo "bats-assertion-gate: $2 — $(printf '%s\n' "$found" | grep -c .) assertion(s) that cannot fail" >&2
	echo "" >&2
	printf '%s\n' "$found" | sed 's/^/  line /' >&2
	violations=$((violations + 1))
}

if [ "$MODE" = "all" ]; then
	list=$(find "$REPO_ROOT/.claude/tests" -name '*.bats' -type f | sort) || {
		echo "bats-assertion-gate: cannot enumerate .claude/tests" >&2
		exit 2
	}
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		scanned=$((scanned + 1))
		_scan_one "$f" "${f#"$REPO_ROOT"/}"
	done <<<"$list"
else
	# A git failure must not read as "nothing staged" — that is a gate which
	# passes everything the moment git has a bad day. -z keeps a path git
	# would otherwise quote (non-ASCII, or containing a space) reaching the
	# scan; a silently skipped path is an ungated path. The list goes to a
	# FILE, not `$(...)`: command substitution strips NUL bytes, which would
	# splice every staged path into one unusable string.
	git -c core.quotePath=false diff --cached --name-only -z --diff-filter=ACMR -- '*.bats' >"$staged_list" || {
		echo "bats-assertion-gate: 'git diff --cached' failed — refusing" >&2
		exit 2
	}
	while IFS= read -r -d '' rel; do
		[ -n "$rel" ] || continue
		# The staged blob. A failure here is NOT "nothing to gate": git listed
		# this path as staged, so being unable to read it means a staged .bats
		# would go unscanned — silently, and with the commit proceeding.
		git show ":$rel" >"$tmp" 2>/dev/null || {
			echo "bats-assertion-gate: cannot read staged blob for '$rel' — refusing" >&2
			exit 2
		}
		scanned=$((scanned + 1))
		_scan_one "$tmp" "$rel"
	done <"$staged_list"
fi

if [ "$violations" -gt 0 ]; then
	cat >&2 <<-'EOF'

		  A bare `[[ ]]` does not fail a bats test on bash 3.2 unless it is the
		  block's LAST command. Use a form that fails wherever it sits:

		      [ "$status" -eq 0 ]                      single-bracket builtin
		      [[ $output == *x* ]] || return 1         the `||` supplies it
		      case "$output" in *x*) ;; *) return 1 ;; esac
		      assert_output_contains "x"               helper returning non-zero

		  Put the guard in COMMAND position, BEFORE any trailing comment:

		      [[ $o == *x* ]] || return 1   # why        guard runs
		      [[ $o == *x* ]]   # why || return 1        guard is a COMMENT

		  `&&` counts only for control flow (`&& return`, `&& break`). In
		  `[[ a ]] && [ b ]` the failing `[[ ]]` is a non-last AND-list member,
		  so it fires nothing on any bash — it reads as an assertion and is not.

		  See _lib/bats-assertion-check.sh for the one-line demonstration.
		  Bypass (audit-logged): BATS_ASSERTION_GATE_SKIP=1 git commit ...
	EOF
	# 1, not 2: the check RAN and found something. 2 is reserved for "the
	# check could not run", which needs a different remedy.
	exit 1
fi

if [ "$MODE" = "all" ]; then
	echo "bats-assertion-gate: $scanned file(s) clean"
fi
exit 0
