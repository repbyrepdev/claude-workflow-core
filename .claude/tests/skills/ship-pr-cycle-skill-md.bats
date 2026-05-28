#!/usr/bin/env bats
# covers: skills/ship-pr-cycle/SKILL.md

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." 2>&1 && pwd) || {
		echo "FATAL: cd failed: $REPO_ROOT" >&2
		return 1
	}
	SKILL_MD="${REPO_ROOT}/skills/ship-pr-cycle/SKILL.md"
}

@test "SKILL.md exists at canonical plugin path" {
	[ -f "$SKILL_MD" ]
}

@test "SKILL.md has valid YAML frontmatter (name + description)" {
	# First line must be `---`, second line `name: ship-pr-cycle`,
	# next include `description:`, and frontmatter closes with `---`.
	[ "$(head -1 "$SKILL_MD")" = "---" ]
	grep -qE '^name:[[:space:]]+ship-pr-cycle[[:space:]]*$' "$SKILL_MD"
	grep -qE '^description:' "$SKILL_MD"
	# Closing `---` must appear in first ~15 lines.
	head -15 "$SKILL_MD" | grep -cE '^---$' | grep -qFx 2
}

@test "SKILL.md frontmatter description mentions trigger phrases" {
	# Trigger phrases drive Skill-tool auto-routing. If these are
	# stripped or paraphrased, NL detection breaks silently.
	grep -q "ship" "$SKILL_MD"
	grep -q "Phase 0.5" "$SKILL_MD"
	grep -q "Phase 1" "$SKILL_MD"
	grep -q "Phase 2" "$SKILL_MD"
	grep -q "CR-in-CI" "$SKILL_MD"
	grep -q "merge-gate" "$SKILL_MD"
}

@test "SKILL.md contains state machine diagram" {
	grep -q "branch-ready" "$SKILL_MD"
	grep -q "phase0.5" "$SKILL_MD"
	grep -q "phase1" "$SKILL_MD"
	grep -q "phase2" "$SKILL_MD"
	grep -q "cr-in-ci-wait" "$SKILL_MD"
	grep -q "merge-gate" "$SKILL_MD"
	grep -q "merged" "$SKILL_MD"
}

@test "SKILL.md references the wrapper script at run.sh" {
	grep -qE '\.claude/skills/ship-pr-cycle/run\.sh' "$SKILL_MD"
}

@test "SKILL.md cross-references related plugin skills" {
	grep -qE 'cr-plan' "$SKILL_MD"
	grep -qE 'git-commit' "$SKILL_MD"
	grep -qE 'github-pr-creation' "$SKILL_MD"
	grep -qE 'github-pr-merge' "$SKILL_MD"
	grep -qE 'coderabbit' "$SKILL_MD"
}

@test "SKILL.md mentions domain-extension pattern for consumers" {
	# Consumers (homelab post-merge deploy, FCP auto-triage deferral)
	# overlay via domain-extension.md per the SSOT design.
	grep -q "domain-extension" "$SKILL_MD"
}

@test "SKILL.md is >= 80 lines (full doc, not a stub)" {
	# Stub files would skip critical sections like state machine +
	# Phase 1 firing protocol. Lock the minimum.
	[ "$(wc -l <"$SKILL_MD")" -ge 80 ]
}
