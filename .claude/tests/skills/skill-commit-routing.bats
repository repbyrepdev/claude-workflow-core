#!/usr/bin/env bats
# covers: skills/deep-audit/SKILL.md skills/github-pr-review/SKILL.md
#
# v0.30.H (#196 slice 1): deep-audit + github-pr-review are MODEL-DRIVEN skills
# that commit fixes. Their only skill-bypass-guard-blocked call is `git commit`
# (the guard blocks exactly: git commit, gh pr create, gh issue create,
# gh pr merge — see hooks/skill-bypass-guard.sh). The #196 "add a run.sh
# wrapper" framing was over-generalized: a thin per-skill run.sh cannot
# propagate SKILL_WRAPPER=1 to the model's own main-thread tool calls (the
# guard honors it only as the wrapper subprocess's env OR a command prefix).
# The genuinely-additive, runtime-correct fix is routing `git commit` through
# the EXISTING git-commit wrapper, which already exports SKILL_WRAPPER=1. This
# test locks that routing in both SKILL.md.

setup() {
	REPO="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
	[ -x "$REPO/skills/git-commit/run.sh" ]
}

@test "deep-audit SKILL.md routes commits through the git-commit wrapper" {
	grep -qF '.claude/skills/git-commit/run.sh' "$REPO/skills/deep-audit/SKILL.md"
}

@test "github-pr-review SKILL.md routes commits through the git-commit wrapper" {
	grep -qF '.claude/skills/git-commit/run.sh' "$REPO/skills/github-pr-review/SKILL.md"
}

@test "the git-commit wrapper they route to sets SKILL_WRAPPER=1 on its git commit" {
	# The routing is only functionally correct if the target wrapper sets the
	# bypass marker — otherwise the git commit would still be refused. git-commit
	# uses the per-command PREFIX form (`SKILL_WRAPPER=1 git commit`), which the
	# guard honors identically to an exported env var (hooks/skill-bypass-guard
	# matches both env and a leading prefix).
	grep -qE 'SKILL_WRAPPER=1[[:space:]]+git[[:space:]]+commit' "$REPO/skills/git-commit/run.sh"
}
