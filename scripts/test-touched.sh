#!/bin/bash
# bats-required: 0  # Iteration-loop wrapper for bats — calls scripts/test.sh.
set -euo pipefail
# v4.24-O (#601) — scoped bats runner for the iteration loop.
#
# Problem this solves: `scripts/test.sh` (full suite) on every loop runs
# 668 tests when you only need the 10-20 that cover the file you touched.
# Before this helper I (Claude) was cycling through the whole suite ~4×
# per session — 2600+ redundant test executions per multi-commit PR.
#
# What this does:
#   1. Compute touched .sh + .bats via `git diff --name-only` against a
#      reference (default: HEAD vs main; configurable via BASE= env var or
#      --base <ref>).
#   2. For each touched .sh, find matching .bats via `# covers:` header
#      directive (same SSOT bats-gate + scripts/test.sh already consume).
#   3. Union with directly-touched .bats files.
#   4. Run only those files via `scripts/test.sh <file1> <file2> …`.
#   5. Nothing touched → no-op (exit 0 silently).
#
# Flags:
#   --base <ref>   diff against <ref> instead of main (also: BASE= env var)
#   --list         print the .bats files this change routes to, then stop.
#                  Makes the covers:/audits: routing rules observable, and
#                  therefore testable. Exits 0 with empty stdout when nothing
#                  routes — a list of nothing, not an error.
#   --help, -h     this header
#
# When to use this vs full `scripts/test.sh`:
#   - Iteration loop, between edits → test-touched.sh (fast)
#   - Before commit → bats-gate / lint-gate already re-validate as needed
#   - Before push → full `scripts/test.sh` at least once (weekly baseline
#     cron handles the stale-hash case automatically)
#
# Safety note: bats tests in this repo use mktemp -d isolation + setup/
# teardown — cross-test coupling is minimal. A theoretical regression via
# shared fixture gets caught at pre-push full-suite anyway.

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT" || exit 2

BASE="${BASE:-}"
# Initialised here, NOT read as `${LIST_ONLY:-0}` at the use site: an exported
# LIST_ONLY=1 anywhere upstream would otherwise turn this runner into a lister
# that prints paths and exits 0 having run nothing, while callers that treat
# exit 0 as "scoped tests passed" (scripts/cr/autofix-cycle.sh's post-pull
# re-test gate, hooks/phase1-launcher.sh) stayed satisfied. A flag is not
# ambient state. The suite covering this had to `env -u LIST_ONLY` around every
# invocation, which was the smell.
LIST_ONLY=0
PASS_ARGS=()
while [ "$#" -gt 0 ]; do
	case "$1" in
	--base)
		if [ -z "${2:-}" ] || [[ ${2:-} == -* ]]; then
			echo "test-touched: Missing value for --base" >&2
			exit 1
		fi
		BASE="$2"
		shift 2
		;;
	--list)
		# Print the files this change routes to, then stop. Makes the
		# covers:/audits: routing rules observable — and therefore testable.
		LIST_ONLY=1
		shift
		;;
	--help | -h)
		# The header block runs from just after `set -...` to the first
		# non-comment line. Derived, not a hardcoded `4,30p` range — that
		# range silently stopped covering the header the moment a flag was
		# documented in it, so `--list` shipped absent from its own help.
		# Anchored on `set -` rather than on line 1 because the shebang and
		# the `# bats-required:` directive precede it and are not help text.
		awk '/^set -/ { inhdr = 1; next }
		     inhdr { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
		exit 0
		;;
	*)
		PASS_ARGS+=("$1")
		shift
		;;
	esac
done

# Default base: main (branch-scoped diff). Fall back to HEAD~1 on
# detached-head / no-main repos.
if [ -z "$BASE" ]; then
	if git rev-parse --verify main >/dev/null 2>&1; then
		BASE="main"
	else
		BASE="HEAD~1"
	fi
fi

# Verify BASE is resolvable — previously the 3 stacked `|| true` calls
# conflated "nothing touched" with "git diff failed on bad base", silently
# reporting no-op when actually every query errored.
if ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
	echo "test-touched: base ref '$BASE' does not exist — fix or pass --base <ref>" >&2
	exit 2
fi

# Touched files = committed diff (BASE...HEAD, three-dot = diff from
# merge-base so main advancing on its own doesn't pollute the touched
# set) + working tree + staged.
# Let each git invocation fail-silent individually (e.g. no staged diff on
# clean tree is NOT an error); the BASE check above is the hard gate.
TOUCHED_RAW=$(
	{
		git diff --name-only "${BASE}...HEAD" 2>/dev/null || true
		git diff --name-only 2>/dev/null || true
		git diff --cached --name-only 2>/dev/null || true
	} | sort -u | grep -v '^$' || true
)

if [ -z "$TOUCHED_RAW" ]; then
	echo "test-touched: nothing changed vs $BASE — no-op" >&2
	exit 0
fi

TOUCHED_SH=$(printf '%s\n' "$TOUCHED_RAW" | grep -E '\.sh$' || true)
TOUCHED_BATS=$(printf '%s\n' "$TOUCHED_RAW" | grep -E '\.bats$' || true)

# For each touched .sh, find a .bats whose `# covers:` header lists it.
MATCHED_BATS=""
if [ -n "$TOUCHED_SH" ]; then
	while IFS= read -r sh; do
		[ -z "$sh" ] && continue
		# Scan all .bats headers for this path. grep -l gives files whose
		# first matching `covers:` line contains $sh — works because covers
		# paths are space-separated on one line.
		while IFS= read -r -d '' b; do
			hdr=$(grep -m1 -E '^#[[:space:]]*covers:' "$b" 2>/dev/null | sed -E 's/^#[[:space:]]*covers:[[:space:]]*//' || true)
			# (#2572) `# audits:` — a repo-wide meta-lint's SUBJECTS. It
			# routes exactly like covers: here (the audit must re-run when
			# something it polices changes) but grants NO behavioural
			# coverage credit, which is the whole point: an audit that
			# claims covers: on 40 hooks it never executes makes the
			# coverage report and the mirror-drift gate both lie.
			aud=$(grep -m1 -E '^#[[:space:]]*audits:' "$b" 2>/dev/null | sed -E 's/^#[[:space:]]*audits:[[:space:]]*//' || true)
			# `set -f` for the split: without it the shell PATHNAME-expands
			# the header before `case` ever sees a pattern, so `hooks/*.sh`
			# becomes 87 literal filenames — and a touched-but-DELETED subject
			# (still listed by `git diff --name-only`) matches none of them and
			# silently stops routing to its auditor. That silent drop is the
			# exact failure `audits:` was added to prevent.
			set -f
			matched=""
			# `covers:` is an exact path in every other consumer (test.sh
			# --coverage, bats-gate.sh, the drift gate). Glob-matching it only
			# here would let an entry route without earning coverage credit or
			# satisfying the commit gate — a partial behaviour nothing rejects.
			for p in $hdr; do
				if [ "$sh" = "$p" ]; then
					matched=1
					break
				fi
			done
			if [ -z "$matched" ]; then
				for p in $aud; do
					# shellcheck disable=SC2254 # $p is an intentional pattern
					case "$sh" in
					$p)
						matched=1
						break
						;;
					esac
				done
			fi
			set +f
			if [ -n "$matched" ]; then
				MATCHED_BATS="${MATCHED_BATS}${b}"$'\n'
			fi
		done < <(find .claude/tests -name '*.bats' -print0 2>/dev/null)
	done <<<"$TOUCHED_SH"
fi

# Union matched + directly touched, unique. Filter to existing files only —
# `git diff` includes deleted .bats files (status=D), but bats can't run a
# nonexistent path. Without this filter, a PR that deletes an orphan test
# (e.g. for a removed hook) fails test-touched on the deleted file.
# Uses `awk` (rc=0 on no-match) instead of `grep -v` (rc=1 on no-match)
# so the empty-pipeline case under set -euo pipefail doesn't spuriously
# abort. Real upstream errors (sort failure, etc.) still propagate.
TEST_TARGETS=$(
	printf '%s\n%s\n' "$MATCHED_BATS" "$TOUCHED_BATS" |
		sort -u |
		awk 'NF' |
		while IFS= read -r p; do if [ -f "$p" ]; then printf '%s\n' "$p"; fi; done
)

# (#2572) --list: print the routing decision and stop. Without it the only
# way to observe which files a change routes to is to RUN them, which makes
# the `covers:`/`audits:` routing rules untestable — and untestable routing
# is how an audit silently drops out of change-triggered runs.
#
# Ahead of the no-coverage branch below on purpose: `--list` asks what this
# change routes to, and "nothing" is a valid answer that must still come back
# as an empty list on stdout rather than as an advisory on stderr.
if [ "$LIST_ONLY" = "1" ]; then
	if [ -n "$TEST_TARGETS" ]; then
		printf '%s\n' "$TEST_TARGETS"
	fi
	exit 0
fi

if [ -z "$TEST_TARGETS" ]; then
	echo "test-touched: $(printf '%s\n' "$TOUCHED_RAW" | wc -l | tr -d ' ') file(s) touched but none have .bats coverage — no-op" >&2
	echo "  (consider: scripts/test.sh --coverage)" >&2
	exit 0
fi

count=$(printf '%s\n' "$TEST_TARGETS" | wc -l | tr -d ' ')

echo "test-touched: running $count bats file(s) covering touched files (vs $BASE)" >&2
# Pass each target to scripts/test.sh. scripts/test.sh takes ONE path per
# invocation, so loop. Accumulate failures.
fails=0
while IFS= read -r target; do
	[ -z "$target" ] && continue
	echo "" >&2
	echo "--- bats: $target ---" >&2
	if ! scripts/test.sh ${PASS_ARGS[@]+"${PASS_ARGS[@]}"} "$target"; then
		fails=$((fails + 1))
	fi
done <<<"$TEST_TARGETS"

if [ "$fails" -gt 0 ]; then
	echo "" >&2
	echo "test-touched: $fails target(s) FAILED" >&2
	exit 1
fi
echo "" >&2
echo "test-touched: all $count target(s) passed" >&2
exit 0
