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
