#!/usr/bin/env bats
# covers: _lib/hook-ack.sh
#
# (#2641) This library had NO covering test file, despite being the mechanism
# every enforcement hook in the repo relies on to make its output impossible
# to scroll past. It is the thing that turns "a hook printed something" into
# "the next tool call is denied until you read it".
#
# The immediate reason for writing it: the filename suffix intended to stop
# rapid calls clobbering each other had never once worked in production. All
# 511 diagnostics on disk carried the `$$` fallback and not one a random
# suffix — because `head -c 6` SIGPIPEs `tr`, and under the `set -o pipefail`
# that EVERY caller sets, the pipeline reports failure. A shell test run by
# hand, without pipefail, returns a random string and shows nothing wrong.
# That is why the bug survived: it is invisible except under the callers' own
# shell options.

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	LIB="$REPO_ROOT/_lib/hook-ack.sh"
	[ -r "$LIB" ]
	TEST_TMP=$(mktemp -d -t hook-ack.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# A scratch repo: hook_ack_diagnostic_write resolves its directory from
	# the git toplevel, so this keeps every diagnostic out of the real tree.
	# Writing them into the operator's own hook-ack dir would block their
	# next tool call for a test fixture.
	WORK="$TEST_TMP/work"
	mkdir -p "$WORK"
	(cd "$WORK" && git init -q -b main) || {
		echo "FATAL: fixture repo init failed" >&2
		return 1
	}
	SENTINEL="$WORK/.claude/.session-state/hook-output-pending.txt"
	DIAG_ROOT="$WORK/.claude/.session-state/hook-ack"
}

teardown() {
	cd "${TMPDIR:-/tmp}" 2>/dev/null || cd "$HOME" || return 0
	case "${TEST_TMP:-}" in
	*/hook-ack.*) rm -rf "$TEST_TMP" ;;
	esac
	return 0
}

# Runs a snippet with the library sourced, in the fixture repo, under the
# SAME shell options every real caller uses. `HOOK_ACK_BATS_SKIP=0` forces
# the real append path (it short-circuits under bats by default).
_in_lib() { # $1 = shell snippet
	run bash -c "set -uo pipefail
		cd '$WORK'
		export HOOK_ACK_BATS_SKIP=0
		. '$LIB'
		$1"
}

# ---- the suffix bug ------------------------------------------------------

@test "hook-ack: the filename suffix is not the pid" {
	# The regression itself. `$$` is stable across subshells within one
	# process, so a pid suffix is not a disambiguator at all — two calls in
	# the same second from one process produced the same path.
	_in_lib 'hook_ack_diagnostic_write h reason "body"'
	[ "$status" -eq 0 ] || {
		echo "diagnostic write failed: $output"
		return 1
	}
	local base suffix
	base=$(basename "$output")
	suffix=$(printf '%s' "$base" | sed -E 's/.*-([A-Za-z0-9]+)\.txt$/\1/')
	[ -n "$suffix" ] || {
		echo "could not extract a suffix from: $base"
		return 1
	}
	# ASSERTS ONLY WHAT IT CAN. The suffix must be exactly 6 characters —
	# the pid fallback was 5-6 decimal digits, so length alone does not
	# discriminate. An earlier draft had a `case` arm pretending to reject
	# pid-shaped values while doing nothing; a later one asserted lowercase
	# hex, which was true only of the hand-rolled draw that mktemp then
	# replaced. The real invariant is distinctness, asserted next. This pins
	# the shape so dropping the suffix, or emitting a bare pid, is caught.
	[ ${#suffix} -eq 6 ] || {
		echo "suffix is ${#suffix} chars, expected 6: $suffix"
		return 1
	}
	case "$suffix" in
	*[!0-9A-Za-z]*)
		echo "suffix is not alphanumeric: $suffix"
		return 1
		;;
	esac
}

@test "hook-ack: a diagnostic write into an UNWRITABLE dir fails loudly" {
	# mktemp is now the uniqueness authority, so its failure is the write's
	# failure. It must return non-zero and say where — a silent empty return
	# would hand the caller an empty path, and every caller in this repo
	# refuses to register a sentinel with an empty file_path precisely
	# because such a row cannot be cleared by Read.
	# The per-hook dir must EXIST and be read-only, so `mkdir -p` succeeds
	# and mktemp is the step that fails. Making the parent read-only instead
	# fails one step earlier at mkdir, which is also correct behaviour but
	# is not the path under test.
	_in_lib 'mkdir -p .claude/.session-state/hook-ack/h
		chmod 500 .claude/.session-state/hook-ack/h
		hook_ack_diagnostic_write h r "body"'
	# Restore before asserting so teardown can clean up regardless.
	chmod -R u+w "$WORK/.claude/.session-state" 2>/dev/null || true
	[ "$status" -ne 0 ] || {
		echo "an unwritable ack dir returned success: $output"
		return 1
	}
	case "$output" in
	*mktemp*) ;;
	*)
		echo "the failure does not name its cause: $output"
		return 1
		;;
	esac
}

@test "hook-ack: an unwritable state dir is not reported as a stuck lock" {
	# It waited the full 2s and then blamed "another hook may be stuck",
	# for a directory nothing could write to and no lock existed in. The
	# wrong diagnosis sends the reader looking for a process; the right one
	# is a chmod. Also 2s of latency on a path that cannot succeed.
	_in_lib 'p=$(hook_ack_diagnostic_write h r "first"); hook_ack_append h r "$p"'
	[ "$status" -eq 0 ]
	chmod 500 "$(dirname "$SENTINEL")"
	_in_lib 'hook_ack_append h r "/tmp/x"'
	chmod -R u+w "$WORK/.claude/.session-state" 2>/dev/null || true
	[ "$status" -ne 0 ] || {
		echo "an unwritable state dir reported success: $output"
		return 1
	}
	case "$output" in
	*"not writable"*) ;;
	*)
		echo "an unwritable dir is still diagnosed as a held lock: $output"
		return 1
		;;
	esac
	case "$output" in
	*"stuck holding"*)
		echo "still blaming a concurrent hook that does not exist: $output"
		return 1
		;;
	esac
}

@test "hook-ack: a failing RENAME after mktemp fails loudly and leaves no stem" {
	# mktemp creates the file; the rename onto .txt is a second syscall with
	# its own failure. If it were allowed to fall through, the caller would
	# get an empty path AND an orphan extensionless file in the ack dir that
	# hook-ack-clear.sh (which globs *.txt) can never clear — a directory
	# that grows files nothing will ever remove.
	#
	# Forced by shadowing `mv` with a failing stub earlier in PATH, since
	# after a successful mktemp the real mv has no reason to fail.
	mkdir -p "$TEST_TMP/bin"
	cat >"$TEST_TMP/bin/mv" <<'STUB'
#!/bin/bash
echo "mv: stubbed failure" >&2
exit 1
STUB
	chmod +x "$TEST_TMP/bin/mv"
	# PATH is built HERE, not inside the snippet: a quoted "$PATH" written
	# into the inner shell does not expand, and the resulting PATH of just
	# the stub dir makes every command fail — which looks like the rename
	# failing and would have passed a laxer assertion.
	run env PATH="$TEST_TMP/bin:$PATH" bash -c "set -uo pipefail
		cd '$WORK'
		export HOOK_ACK_BATS_SKIP=0
		. '$LIB'
		hook_ack_diagnostic_write h r 'body'"
	[ "$status" -ne 0 ] || {
		echo "a failed rename reported success: $output"
		return 1
	}
	case "$output" in
	*"cannot name"*) ;;
	*)
		echo "the failure does not say the rename is what broke: $output"
		return 1
		;;
	esac
	# The stem must be cleaned up — not left behind unreachable.
	local leftovers
	leftovers=$(find "$DIAG_ROOT" -type f ! -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')
	[ "$leftovers" -eq 0 ] || {
		echo "a failed rename left $leftovers orphan stem(s) nothing can clear:"
		find "$DIAG_ROOT" -type f 2>/dev/null
		return 1
	}
}

@test "hook-ack: a FAILED dedup rewrite refuses and does not append" {
	# The if/else rewrite distinguishes an awk failure from an mv failure.
	# Neither may leave a half-deduped sentinel or fall through to the
	# append — a sentinel that lost rows is worse than one with a stale row,
	# because the lost rows were blocks somebody was owed.
	#
	# Forced by shadowing `mv` with a failing stub. The first version of
	# this test chmod 500'd the state directory instead, which never
	# reached the dedup at all — mkdir of the lockdir failed two guards
	# earlier and the function returned on lock acquisition. It passed
	# anyway, because "non-zero" and "sentinel unchanged" are true of that
	# failure too. Only asserting WHICH branch ran exposed it.
	_in_lib 'p=$(hook_ack_diagnostic_write h r "first"); hook_ack_append h r "$p"'
	[ "$status" -eq 0 ]
	local before
	before=$(cat "$SENTINEL")
	mkdir -p "$TEST_TMP/bin2"
	cat >"$TEST_TMP/bin2/mv" <<'STUB'
#!/bin/bash
echo "mv: stubbed failure" >&2
exit 1
STUB
	chmod +x "$TEST_TMP/bin2/mv"
	run env PATH="$TEST_TMP/bin2:$PATH" bash -c "set -uo pipefail
		cd '$WORK'
		export HOOK_ACK_BATS_SKIP=0
		. '$LIB'
		hook_ack_append h r '$WORK/second.txt'"
	[ "$status" -ne 0 ] || {
		echo "a failed dedup rewrite reported success: $output"
		return 1
	}
	# WHICH branch. The two dedup failures have different causes and fixes,
	# and a shared message let this test claim one while exercising neither.
	case "$output" in
	*"mv could not replace"*) ;;
	*)
		echo "expected the rename branch, got: $output"
		return 1
		;;
	esac
	# The original row must survive — nothing silently dropped.
	[ "$(cat "$SENTINEL")" = "$before" ] || {
		echo "the sentinel was mutated by a failed rewrite: $(cat "$SENTINEL")"
		return 1
	}
}

@test "hook-ack: two calls in ONE process get DISTINCT paths" {
	# The actual invariant, and the one the pid fallback broke. Same
	# process, same second, two diagnostics — they must not collide.
	_in_lib 'a=$(hook_ack_diagnostic_write h reason "body one")
		b=$(hook_ack_diagnostic_write h reason "body two")
		printf "%s\n%s\n" "$a" "$b"'
	[ "$status" -eq 0 ] || {
		echo "writes failed: $output"
		return 1
	}
	local first second
	first=$(printf '%s\n' "$output" | sed -n '1p')
	second=$(printf '%s\n' "$output" | sed -n '2p')
	[ "$first" != "$second" ] || {
		echo "two calls in one process produced the SAME path: $first"
		return 1
	}
	# And BOTH files must survive — a collision would leave one body only.
	[ -f "$first" ] && [ -f "$second" ] || {
		echo "a diagnostic was clobbered: first=$first second=$second"
		return 1
	}
	grep -q 'body one' "$first" || {
		echo "first diagnostic lost its body"
		return 1
	}
	grep -q 'body two' "$second" || {
		echo "second diagnostic lost its body"
		return 1
	}
}

@test "hook-ack: the suffix works under the callers' OWN shell options" {
	# The reason the bug was invisible: without `pipefail` the old pipeline
	# returned a random string and looked fine. Every real caller sets
	# `set -uo pipefail`, and _in_lib does too — so this test would have
	# failed before the fix and passes after it. Pinned explicitly because
	# "works when I try it in a shell" was the false signal.
	_in_lib 'set -o | grep -q "pipefail.*on" || { echo "FIXTURE-NO-PIPEFAIL"; exit 1; }
		hook_ack_diagnostic_write h reason "body"'
	[ "$status" -eq 0 ]
	case "$output" in
	*FIXTURE-NO-PIPEFAIL*)
		echo "the fixture did not actually enable pipefail — this test proves nothing"
		return 1
		;;
	esac
}

# ---- the core contract ---------------------------------------------------

@test "hook-ack: a written diagnostic contains hook, reason and body" {
	_in_lib 'p=$(hook_ack_diagnostic_write myhook myreason "the explanation")
		cat "$p"'
	[ "$status" -eq 0 ]
	case "$output" in
	*myhook*) ;;
	*)
		echo "the diagnostic does not name its hook: $output"
		return 1
		;;
	esac
	case "$output" in
	*myreason*) ;;
	*)
		echo "the diagnostic does not name its reason: $output"
		return 1
		;;
	esac
	case "$output" in
	*"the explanation"*) ;;
	*)
		echo "the diagnostic lost its body: $output"
		return 1
		;;
	esac
}

@test "hook-ack: append registers a row that names the diagnostic" {
	_in_lib 'p=$(hook_ack_diagnostic_write h r "body")
		hook_ack_append h r "$p"'
	[ "$status" -eq 0 ] || {
		echo "append failed: $output"
		return 1
	}
	[ -s "$SENTINEL" ] || {
		echo "no sentinel row was written"
		return 1
	}
	# Field 4 is the path, and it must exist — a row pointing at nothing
	# cannot be cleared by Read and hard-blocks every later tool call.
	local fp
	fp=$(awk -F'\t' 'NR==1{print $4}' "$SENTINEL")
	[ -n "$fp" ] || {
		echo "the row has an EMPTY file_path — unclearable"
		return 1
	}
	[ -f "$fp" ] || {
		echo "the row points at a file that does not exist: $fp"
		return 1
	}
}

@test "hook-ack: append DEDUPES by (hook, reason), keeping one row" {
	# The documented behaviour, and the reason a repeated directive still
	# blocks: the row collapses but is re-pointed at a brand-new file that
	# has never been Read.
	_in_lib 'for i in 1 2 3; do
			p=$(hook_ack_diagnostic_write h r "body $i")
			hook_ack_append h r "$p"
		done'
	[ "$status" -eq 0 ]
	local rows
	rows=$(grep -c . "$SENTINEL")
	[ "$rows" = "1" ] || {
		echo "expected 1 deduped row, got $rows: $(cat "$SENTINEL")"
		return 1
	}
	# And it points at the LAST one written.
	local fp
	fp=$(awk -F'\t' 'NR==1{print $4}' "$SENTINEL")
	grep -q 'body 3' "$fp" || {
		echo "the surviving row does not point at the newest diagnostic"
		return 1
	}
}

@test "hook-ack: a DIFFERENT reason gets its own row" {
	# Dedup is on the pair, not on the hook. Two concerns from one hook must
	# both block.
	_in_lib 'p=$(hook_ack_diagnostic_write h reason-a "a"); hook_ack_append h reason-a "$p"
		q=$(hook_ack_diagnostic_write h reason-b "b"); hook_ack_append h reason-b "$q"'
	[ "$status" -eq 0 ]
	local rows
	rows=$(grep -c . "$SENTINEL")
	[ "$rows" = "2" ] || {
		echo "expected 2 rows for 2 reasons, got $rows: $(cat "$SENTINEL")"
		return 1
	}
}

@test "hook-ack: a path-traversing hook name cannot escape the ack dir" {
	# The hook name becomes a directory component. `basename` + a character
	# filter run on it for exactly this reason.
	_in_lib 'hook_ack_diagnostic_write "../../../etc/evil" r "body"' || true
	# Either it refuses, or it writes INSIDE the ack root — never outside.
	[ ! -e "$WORK/.claude/.session-state/etc" ] || {
		echo "a traversing hook name created a directory outside the ack root"
		return 1
	}
	[ ! -e "$TEST_TMP/etc" ] || {
		echo "a traversing hook name escaped the fixture repo entirely"
		return 1
	}
	if [ "$status" -eq 0 ] && [ -n "$output" ]; then
		# RESOLVED on both sides. macOS $TMPDIR is /var/folders/... while the
		# library resolves through git, which reports /private/var/... — two
		# spellings of one directory. Comparing them raw fails on a path that
		# is actually contained, which is a false alarm about a security
		# property and the third time this exact mismatch has bitten today.
		local _root_real _out_real
		_root_real=$(cd "$DIAG_ROOT" 2>/dev/null && pwd -P) || _root_real="$DIAG_ROOT"
		_out_real=$(cd "$(dirname "$output")" 2>/dev/null && pwd -P) || _out_real=$(dirname "$output")
		case "$_out_real/" in
		"$_root_real"/*) ;;
		*)
			echo "wrote outside the ack root: $_out_real (root: $_root_real)"
			return 1
			;;
		esac
	fi
}

@test "hook-ack: a body with tabs and newlines cannot forge a sentinel row" {
	# The sentinel is tab-delimited, one row per line. Body text is
	# attacker-influenced in several callers (commit subjects, task items),
	# and it must not be able to inject a second row or shift the columns.
	_in_lib 'p=$(hook_ack_diagnostic_write h r "$(printf "evil\tcol\nsecond\trow")")
		hook_ack_append h r "$p"'
	[ "$status" -eq 0 ]
	local rows
	rows=$(grep -c . "$SENTINEL")
	[ "$rows" = "1" ] || {
		echo "body text forged extra sentinel rows ($rows): $(cat "$SENTINEL")"
		return 1
	}
	local fp
	fp=$(awk -F'\t' 'NR==1{print $4}' "$SENTINEL")
	[ -f "$fp" ] || {
		echo "body text corrupted the path column: [$fp]"
		return 1
	}
}
