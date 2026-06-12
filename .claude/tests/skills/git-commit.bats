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
	[[ $output == *"blocked by (failing hook lines)"* ]]
	[[ $output == *"fakehook"* ]]
	# No commit object was created (HEAD never advanced).
	run git -C "$SANDBOX" rev-parse --verify HEAD
	[ "$status" -ne 0 ]
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
	[[ $output == *staged.txt* ]]
	[[ $output != *unstaged.txt* ]]
}

@test "no message + --no-copilot → fail-closed (exit 2), nothing committed" {
	echo "x" >"$SANDBOX/file.txt"
	git -C "$SANDBOX" add file.txt
	run bash -c "cd '$SANDBOX' && COPILOT_DRAFT_OFF=1 '$WRAPPER' --no-copilot"
	[ "$status" -eq 2 ]
	[[ $output == *"no commit message provided"* ]]
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
	[[ $output == *"would commit"* ]]
	# Dry-run is side-effect-free: no commit object exists.
	run git -C "$SANDBOX" rev-parse --verify HEAD
	[ "$status" -ne 0 ]
}
