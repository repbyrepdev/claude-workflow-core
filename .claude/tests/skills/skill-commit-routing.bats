#!/usr/bin/env bats
# covers: skills/deep-audit/SKILL.md skills/github-pr-review/SKILL.md skills/git-commit/run.sh
#
# v0.30.H (#196 slice 1): deep-audit + github-pr-review are MODEL-DRIVEN skills
# that commit fixes. Their only relevant skill-bypass-guard-blocked call is
# `git commit` (the guard blocks several high-risk verbs — `git commit` among
# them; see hooks/skill-bypass-guard.sh for the full set). The #196 "add a
# run.sh wrapper" framing was over-generalized: a thin per-skill run.sh cannot
# propagate SKILL_WRAPPER=1 to the model's own main-thread tool calls (the
# guard honors it only as the wrapper subprocess's env OR a command prefix).
# The genuinely-additive, runtime-correct fix is routing `git commit` through
# the EXISTING git-commit wrapper, which already sets SKILL_WRAPPER=1 as a
# command prefix on its git commit. This test locks that routing in both
# SKILL.md.
#
# Path convention (CR #217): this is the plugin SOURCE repo, where the wrapper
# lives at skills/git-commit/run.sh. The SKILL.md files reference it by its
# CONSUMER mount path, .claude/skills/git-commit/run.sh — the SAME file once the
# plugin is installed into a downstream repo. So the assertions deliberately use
# two path forms: grep the consumer path INSIDE the SKILL.md (it is literally
# what a consumer reads), but file-access the source path. setup() derives the
# source path FROM the consumer path (strip the `.claude/` mount prefix) so the
# two are provably the same file — not a silent mismatch, and a future edit to
# the documented route fails the file-access check instead of going stale.

setup() {
	REPO="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
	# DOC_PATH = exactly the route string the SKILL.md files contain (consumer
	# mount). SRC_PATH = the same file in THIS source repo (drop .claude/ mount).
	DOC_PATH='.claude/skills/git-commit/run.sh'
	SRC_PATH="${DOC_PATH#.claude/}"
	[ -x "$REPO/$SRC_PATH" ]
}

@test "deep-audit SKILL.md routes commits through the git-commit wrapper" {
	grep -qF "$DOC_PATH" "$REPO/skills/deep-audit/SKILL.md"
}

@test "github-pr-review SKILL.md routes commits through the git-commit wrapper" {
	grep -qF "$DOC_PATH" "$REPO/skills/github-pr-review/SKILL.md"
}

@test "the git-commit wrapper they route to sets SKILL_WRAPPER=1 on its git commit" {
	# The routing is only functionally correct if the target wrapper sets the
	# bypass marker — otherwise the git commit would still be refused. git-commit
	# uses the per-command PREFIX form (`SKILL_WRAPPER=1 git commit`), which the
	# guard honors identically to an exported env var (hooks/skill-bypass-guard
	# matches both env and a leading prefix). SRC_PATH is the SKILL.md route's
	# file in this source repo (see setup() — DOC_PATH minus the .claude/ mount).
	grep -qE 'SKILL_WRAPPER=1[[:space:]]+git[[:space:]]+commit' "$REPO/$SRC_PATH"
}
