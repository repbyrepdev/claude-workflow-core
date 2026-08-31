#!/usr/bin/env bats
# covers: skills/git-commit/run.sh
#
# #253 test-cov for the #251 fix: when a commit is BLOCKED (a pre-commit hook
# exits non-zero so HEAD doesn't advance), the wrapper must EXTRACT + SURFACE
# the failing hook line(s) ("blocked by (failing hook lines)") rather than
# only reporting "commit did not land". Runs in a throwaway git repo — the
# wrapper resolves REPO_ROOT from cwd, and since $sandbox/.claude/_lib/
# hook-ack.sh does not exist there, the real session sentinel is NOT touched.

setup() {
	WRAPPER="${BATS_TEST_DIRNAME}/../../../skills/git-commit/run.sh"
	[ -f "$WRAPPER" ]
	TEMPLATE_SRC="${BATS_TEST_DIRNAME}/../../../.github/commit-template.yml"
	SANDBOX=$(mktemp -d -t git-commit-fh.XXXXXX) || return 1
	git -C "$SANDBOX" init -q
	git -C "$SANDBOX" config user.email t@example.com
	git -C "$SANDBOX" config user.name tester
	git -C "$SANDBOX" config commit.gpgsign false
	# Give the sandbox the commit-template SSOT so the wrapper's message
	# preflight has its schema (operator --message-file is warn-only anyway,
	# but this keeps the run faithful to a real repo).
	mkdir -p "$SANDBOX/.github"
	[ -f "$TEMPLATE_SRC" ] && cp "$TEMPLATE_SRC" "$SANDBOX/.github/commit-template.yml"
}

teardown() {
	[ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && [[ $SANDBOX == */git-commit-fh.* ]] && rm -rf "$SANDBOX"
	return 0
}

@test "#251: a blocked commit surfaces the failing hook line(s)" {
	# A failing pre-commit hook that prints a recognizable '- hook id:' + 'Failed'.
	cat >"$SANDBOX/.git/hooks/pre-commit" <<'EOF'
#!/bin/bash
echo "- hook id: fakehook"
echo "  some detail line"
echo "Failed"
exit 1
EOF
	chmod +x "$SANDBOX/.git/hooks/pre-commit"
	echo "content" >"$SANDBOX/file.txt"
	git -C "$SANDBOX" add file.txt
	cat >"$SANDBOX/msg.txt" <<'EOF'
test: trigger pre-commit hook failure

Exercises the #251 FAILED_HOOKS surfacing path in the git-commit wrapper.

Co-Authored-By: Tester <t@example.com>
EOF
	run bash -c "cd '$SANDBOX' && COPILOT_DRAFT_OFF=1 '$WRAPPER' --no-copilot --message-file msg.txt"
	[ "$status" -ne 0 ]
	[[ $output == *"blocked by (failing hook lines)"* ]] || return 1
	[[ $output == *"fakehook"* ]] || return 1
	# No commit object was created (HEAD never advanced).
	run git -C "$SANDBOX" rev-parse --verify HEAD
	[ "$status" -ne 0 ]
}

@test "#2641: the abort diagnostic is written by the library, and is readable" {
	# The whole point of the ack file is that the operator is BLOCKED until
	# they Read it, so a diagnostic that is empty, unnamed, or written under
	# a path the wrapper then misreports is worse than none — the block
	# stands and the evidence does not.
	#
	# Every other test in this file runs in a sandbox with no
	# .claude/_lib/hook-ack.sh, which is deliberate (it keeps the real
	# session sentinel untouched) but means the entire ack branch — 60
	# lines, the part that fires on every blocked commit — had NO coverage.
	# This test gives the sandbox the real library. hook_ack_append still
	# short-circuits under bats via its own BATS_TEST_NAME guard, so the
	# operator's live queue is still not touched; hook_ack_diagnostic_write
	# fires for real, into the SANDBOX repo root, which is what we assert on.
	local lib_src="${BATS_TEST_DIRNAME}/../../../_lib/hook-ack.sh"
	[ -f "$lib_src" ]
	mkdir -p "$SANDBOX/.claude/_lib"
	cp "$lib_src" "$SANDBOX/.claude/_lib/hook-ack.sh"

	cat >"$SANDBOX/.git/hooks/pre-commit" <<'EOF'
#!/bin/bash
echo "- hook id: fakehook"
echo "Failed"
exit 1
EOF
	chmod +x "$SANDBOX/.git/hooks/pre-commit"
	echo "content" >"$SANDBOX/file.txt"
	git -C "$SANDBOX" add file.txt
	cat >"$SANDBOX/msg.txt" <<'EOF'
test: exercise the abort-diagnostic path

Covers the hook-ack branch of the git-commit wrapper.

Co-Authored-By: Tester <t@example.com>
EOF
	run bash -c "cd '$SANDBOX' && COPILOT_DRAFT_OFF=1 '$WRAPPER' --no-copilot --message-file msg.txt"
	[ "$status" -ne 0 ]

	# The wrapper must NAME the file it wrote.
	[[ $output == *"diagnostic written to"* ]] || {
		echo "the wrapper did not report a diagnostic path: $output"
		return 1
	}
	# Extract the reported path and check it is real, relative, and non-empty.
	local rel
	rel=$(printf '%s\n' "$output" | sed -n 's/.*diagnostic written to \(.*\) — Read it.*/\1/p' | tail -1)
	[ -n "$rel" ] || {
		echo "could not parse the reported path out of: $output"
		return 1
	}
	case "$rel" in
	/*)
		echo "the reported path is absolute; the wrapper reports repo-relative: $rel"
		return 1
		;;
	esac
	[ -s "$SANDBOX/$rel" ] || {
		echo "the reported diagnostic does not exist or is empty: $rel"
		ls -la "$SANDBOX/.claude/.session-state/hook-ack/git-commit" 2>&1
		return 1
	}
	# It must carry the evidence, not just exist. The failing hook line is
	# the reason the operator is being made to read it.
	grep -q 'HEAD did not advance' "$SANDBOX/$rel" || {
		echo "diagnostic lacks the abort statement: $(cat "$SANDBOX/$rel")"
		return 1
	}
	grep -q 'fakehook' "$SANDBOX/$rel" || {
		echo "diagnostic lacks the failing hook: $(cat "$SANDBOX/$rel")"
		return 1
	}
	# Written through the library, so it carries the library's header.
	grep -q '^Hook:  *git-commit' "$SANDBOX/$rel" || {
		echo "diagnostic is not in the library's format — hand-rolled again? $(head -3 "$SANDBOX/$rel")"
		return 1
	}
}

@test "#2641: a library that cannot write the diagnostic WARNS, and claims nothing" {
	# The branch that runs when hook_ack_diagnostic_write is missing or
	# fails. Two ways to get this wrong, both silent: claim a diagnostic
	# that was never written (the operator goes looking for a file that is
	# not there), or say nothing at all (the operator never learns the
	# mandatory-read block is not in place). It must do neither.
	#
	# Forced with a library present but incomplete — the shape a partial
	# sync or a half-finished edit actually produces, which is why
	# `[ -f "$HOOK_ACK_LIB" ]` alone is not enough of a guard.
	mkdir -p "$SANDBOX/.claude/_lib"
	cat >"$SANDBOX/.claude/_lib/hook-ack.sh" <<'EOF'
#!/bin/bash
# Incomplete on purpose: hook_ack_diagnostic_write is absent.
hook_ack_append() { return 0; }
EOF
	cat >"$SANDBOX/.git/hooks/pre-commit" <<'EOF'
#!/bin/bash
echo "- hook id: fakehook"
echo "Failed"
exit 1
EOF
	chmod +x "$SANDBOX/.git/hooks/pre-commit"
	echo "content" >"$SANDBOX/file.txt"
	git -C "$SANDBOX" add file.txt
	cat >"$SANDBOX/msg.txt" <<'EOF'
test: exercise the diagnostic fallback path

Covers the branch where the hook-ack library cannot write a diagnostic.

Co-Authored-By: Tester <t@example.com>
EOF
	run bash -c "cd '$SANDBOX' && COPILOT_DRAFT_OFF=1 '$WRAPPER' --no-copilot --message-file msg.txt"
	[ "$status" -ne 0 ]

	# It must say the persistence failed.
	[[ $output == *"failed to persist hook-ack diagnostic"* ]] || {
		echo "the fallback is silent about the missing diagnostic: $output"
		return 1
	}
	# It must NOT claim a file it did not write.
	[[ $output != *"diagnostic written to"* ]] || {
		echo "the wrapper reported a diagnostic it never wrote: $output"
		return 1
	}
	# The real reason for the commit failing still has to reach the operator
	# — losing the diagnostic must not also lose the hook name.
	[[ $output == *"fakehook"* ]] || {
		echo "the failing hook was lost along with the diagnostic: $output"
		return 1
	}
	# And nothing was left behind pretending to be one.
	local n
	n=$(find "$SANDBOX/.claude/.session-state/hook-ack" -type f 2>/dev/null | wc -l | tr -d ' ')
	[ "$n" -eq 0 ] || {
		echo "the failed path still left $n file(s) behind"
		return 1
	}
}

@test "#2641: a diagnostic that cannot be REGISTERED says so — it is not a block" {
	# The subtle failure: the file is written, the operator is told to read
	# it, and nothing actually blocks, because the sentinel row that does
	# the blocking never landed. Silent, and indistinguishable from working
	# — the diagnostic is right there on disk. This is the shape the whole
	# epic is about, so its two variants each get a test.
	mkdir -p "$SANDBOX/.claude/_lib"
	# A library that writes fine but whose append FAILS.
	{
		sed 's/^hook_ack_append()/hook_ack_append_real()/' "${BATS_TEST_DIRNAME}/../../../_lib/hook-ack.sh"
		echo 'hook_ack_append() { echo "sentinel is unwritable" >&2; return 1; }'
	} >"$SANDBOX/.claude/_lib/hook-ack.sh"
	cat >"$SANDBOX/.git/hooks/pre-commit" <<'EOF'
#!/bin/bash
echo "- hook id: fakehook"
echo "Failed"
exit 1
EOF
	chmod +x "$SANDBOX/.git/hooks/pre-commit"
	echo "content" >"$SANDBOX/file.txt"
	git -C "$SANDBOX" add file.txt
	cat >"$SANDBOX/msg.txt" <<'EOF'
test: exercise the unregistered-diagnostic path

Covers the WARN when the sentinel append fails.

Co-Authored-By: Tester <t@example.com>
EOF
	run bash -c "cd '$SANDBOX' && COPILOT_DRAFT_OFF=1 '$WRAPPER' --no-copilot --message-file msg.txt"
	[ "$status" -ne 0 ]
	[[ $output == *"could NOT be registered for mandatory read"* ]] || {
		echo "a diagnostic that blocks nothing was reported as normal: $output"
		return 1
	}
	# The library's own reason must be carried through, not replaced by a
	# generic message — that is the difference between a fixable report and
	# knowing only that something went wrong.
	[[ $output == *"sentinel is unwritable"* ]] || {
		echo "the append's own error was discarded: $output"
		return 1
	}
	# The file still exists and is still NAMED, since reading it manually is
	# the remaining remedy — and that is what gets asserted.
	#
	# `$output == *"Read"*` could not fail: the assertion above already
	# matched "could NOT be registered for mandatory read", and the wrapper
	# emits that text as "... nothing will block on it. Read $ACK_FILE_ABS
	# yourself." — so the substring is guaranteed present the moment the
	# earlier assertion passes. It claimed the file exists and is named, and
	# proved neither.
	local named
	named=$(printf '%s\n' "$output" | sed -n 's/.*Read \(.*\) yourself\..*/\1/p' | tail -1)
	[ -n "$named" ] || {
		echo "the warning does not name a file to read: $output"
		return 1
	}
	[ -s "$named" ] || {
		echo "the named diagnostic does not exist or is empty: $named"
		return 1
	}
	grep -q 'fakehook' "$named" || {
		echo "the named diagnostic does not carry the failing hook: $(cat "$named")"
		return 1
	}
}

@test "#2641: an append that is MISSING entirely also warns" {
	# The other variant: a library that loaded but is missing the function.
	# `command -v` guards it, and the else branch that guard needs had no
	# test — a guard whose fallback is unproven is half a guard.
	# A MINIMAL library, written from scratch rather than filtered from the
	# real one. The first attempt deleted the `hook_ack_append()` header
	# with grep and left its body behind, which is a syntax error — the
	# source then failed outright and the test appeared to prove the
	# missing-append warning while actually proving the missing-WRITE one.
	mkdir -p "$SANDBOX/.claude/_lib"
	cat >"$SANDBOX/.claude/_lib/hook-ack.sh" <<'EOF'
#!/bin/bash
# Defines the writer and deliberately NOT hook_ack_append.
hook_ack_diagnostic_write() {
	local d="$PWD/.claude/.session-state/hook-ack/git-commit"
	mkdir -p "$d" || return 1
	local f
	f=$(mktemp "$d/stub-XXXXXX") || return 1
	mv -f "$f" "$f.txt" || return 1
	printf 'Hook:      %s\nReason:    %s\n\n%s\n' "$1" "$2" "$3" >"$f.txt" || return 1
	printf '%s\n' "$f.txt"
}
EOF
	cat >"$SANDBOX/.git/hooks/pre-commit" <<'EOF'
#!/bin/bash
echo "- hook id: fakehook"
echo "Failed"
exit 1
EOF
	chmod +x "$SANDBOX/.git/hooks/pre-commit"
	echo "content" >"$SANDBOX/file.txt"
	git -C "$SANDBOX" add file.txt
	cat >"$SANDBOX/msg.txt" <<'EOF'
test: exercise the missing-append path

Covers the WARN when hook_ack_append is absent from the library.

Co-Authored-By: Tester <t@example.com>
EOF
	run bash -c "cd '$SANDBOX' && COPILOT_DRAFT_OFF=1 '$WRAPPER' --no-copilot --message-file msg.txt"
	[ "$status" -ne 0 ]
	[[ $output == *"hook_ack_append missing"* ]] || {
		echo "a library missing the append function was accepted silently: $output"
		return 1
	}
}

@test "#2641: back-to-back aborts do not overwrite each other's diagnostic" {
	# The library's uniqueness suffix is the thing under test. Two aborted
	# commits must leave two readable diagnostics: an operator who is
	# blocked twice needs both, and the second silently replacing the first
	# is how the ORIGINAL library bug lost evidence.
	local lib_src="${BATS_TEST_DIRNAME}/../../../_lib/hook-ack.sh"
	mkdir -p "$SANDBOX/.claude/_lib"
	cp "$lib_src" "$SANDBOX/.claude/_lib/hook-ack.sh"
	cat >"$SANDBOX/.git/hooks/pre-commit" <<'EOF'
#!/bin/bash
echo "- hook id: fakehook"
echo "Failed"
exit 1
EOF
	chmod +x "$SANDBOX/.git/hooks/pre-commit"
	echo "content" >"$SANDBOX/file.txt"
	git -C "$SANDBOX" add file.txt
	cat >"$SANDBOX/msg.txt" <<'EOF'
test: exercise the abort-diagnostic path twice

Covers diagnostic uniqueness across repeated blocked commits.

Co-Authored-By: Tester <t@example.com>
EOF
	# Back-to-back, usually inside one second — but NOT guaranteed: each
	# invocation runs a full commit plus pre-commit hooks and can straddle a
	# second boundary, at which point the %H%M%S stem alone separates them
	# and the suffix stops being exercised. The timestamp prefixes are
	# therefore compared below, so a straddle is visible rather than silent.
	bash -c "cd '$SANDBOX' && COPILOT_DRAFT_OFF=1 '$WRAPPER' --no-copilot --message-file msg.txt" >/dev/null 2>&1 || true
	bash -c "cd '$SANDBOX' && COPILOT_DRAFT_OFF=1 '$WRAPPER' --no-copilot --message-file msg.txt" >/dev/null 2>&1 || true

	local n
	n=$(find "$SANDBOX/.claude/.session-state/hook-ack/git-commit" -name '*.txt' -type f 2>/dev/null | wc -l | tr -d ' ')
	[ "$n" -eq 2 ] || {
		echo "expected 2 distinct diagnostics after 2 aborts, found $n"
		ls -la "$SANDBOX/.claude/.session-state/hook-ack/git-commit" 2>&1
		return 1
	}
	# The suffix is only under test when the TIMESTAMPS collide — otherwise
	# the %H%M%S stem alone separates the two names and this proves nothing
	# about uniqueness. Two invocations each run a full commit, so a second
	# boundary can fall between them; when it does, say so rather than
	# reporting a pass the run did not earn.
	# NO early return. An earlier version bailed with `return 0` when the
	# two runs straddled a second boundary, which meant the count and
	# non-empty assertions below were skipped on exactly the runs where
	# something might have gone wrong — a test that opts out of itself.
	# The names must differ either way; the straddle only changes WHICH
	# component distinguishes them, and that is reported, not excused.
	# (The same-second case, where only the suffix can separate them, is
	# covered directly against the library in hook-ack.bats.)
	local stems
	stems=$(find "$SANDBOX/.claude/.session-state/hook-ack/git-commit" -name '*.txt' -type f 2>/dev/null |
		sed 's#.*/##; s/-commit-aborted-.*//' | sort -u | wc -l | tr -d ' ')
	if [ "$stems" -ne 1 ]; then
		echo "note: the two aborts straddled a second boundary, so the timestamp stems differ; the suffix was not the distinguishing component this run"
	fi
	local names
	names=$(find "$SANDBOX/.claude/.session-state/hook-ack/git-commit" -name '*.txt' -type f 2>/dev/null |
		sed 's#.*/##' | sort -u | wc -l | tr -d ' ')
	[ "$names" -eq 2 ] || {
		echo "the two aborts did not produce two distinct names (got $names distinct)"
		return 1
	}
	# Both must be non-empty — two names pointing at one truncated file
	# would satisfy a count-only assertion.
	local f
	while IFS= read -r f; do
		[ -s "$f" ] || {
			echo "diagnostic is empty: $f"
			return 1
		}
	done < <(find "$SANDBOX/.claude/.session-state/hook-ack/git-commit" -name '*.txt' -type f)
}

# --- #2293 edge-case expansion: happy path, partial stage, fail-closed,
# --- dry-run. (Operator --message-file schema checks are warn-only by design,
# --- so these target the behaviors that actually change commit state.) ---

@test "happy path: a valid message commits and advances HEAD" {
	echo "content" >"$SANDBOX/file.txt"
	git -C "$SANDBOX" add file.txt
	cat >"$SANDBOX/msg.txt" <<'EOF'
test: add a file in the happy-path sandbox

Exercises the successful commit path of the git-commit wrapper.

Co-Authored-By: Tester <t@example.com>
EOF
	run bash -c "cd '$SANDBOX' && COPILOT_DRAFT_OFF=1 '$WRAPPER' --no-copilot --message-file msg.txt"
	[ "$status" -eq 0 ]
	# Key assertions last: a commit object now exists AND carries our subject.
	run git -C "$SANDBOX" log -1 --pretty=%s
	[ "$status" -eq 0 ]
	[[ $output == *"add a file in the happy-path sandbox"* ]]
}

@test "partial stage: only the staged file is committed" {
	echo "staged" >"$SANDBOX/staged.txt"
	echo "loose" >"$SANDBOX/unstaged.txt" # left untracked on purpose
	git -C "$SANDBOX" add staged.txt
	cat >"$SANDBOX/msg.txt" <<'EOF'
test: commit only the staged file

Co-Authored-By: Tester <t@example.com>
EOF
	run bash -c "cd '$SANDBOX' && COPILOT_DRAFT_OFF=1 '$WRAPPER' --no-copilot --message-file msg.txt"
	[ "$status" -eq 0 ]
	# The committed tree contains staged.txt but NOT the untracked file.
	run git -C "$SANDBOX" ls-tree --name-only HEAD
	[[ $output == *staged.txt* ]] || return 1
	[[ $output != *unstaged.txt* ]]
}

@test "no message + --no-copilot → fail-closed (exit 2), nothing committed" {
	echo "x" >"$SANDBOX/file.txt"
	git -C "$SANDBOX" add file.txt
	run bash -c "cd '$SANDBOX' && COPILOT_DRAFT_OFF=1 '$WRAPPER' --no-copilot"
	[ "$status" -eq 2 ]
	[[ $output == *"no commit message provided"* ]] || return 1
	# HEAD never came into existence.
	run git -C "$SANDBOX" rev-parse --verify HEAD
	[ "$status" -ne 0 ]
}

@test "--dry-run prints the message without creating a commit" {
	echo "x" >"$SANDBOX/file.txt"
	git -C "$SANDBOX" add file.txt
	cat >"$SANDBOX/msg.txt" <<'EOF'
test: dry-run must not create a commit

Co-Authored-By: Tester <t@example.com>
EOF
	run bash -c "cd '$SANDBOX' && COPILOT_DRAFT_OFF=1 '$WRAPPER' --no-copilot --message-file msg.txt --dry-run"
	[ "$status" -eq 0 ]
	[[ $output == *"would commit"* ]] || return 1
	# Dry-run is side-effect-free: no commit object exists.
	run git -C "$SANDBOX" rev-parse --verify HEAD
	[ "$status" -ne 0 ]
}
