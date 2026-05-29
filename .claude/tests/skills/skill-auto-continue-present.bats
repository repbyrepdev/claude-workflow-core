#!/usr/bin/env bats
# covers: skills/ack/SKILL.md skills/cr-plan/SKILL.md skills/cr-resolve-conflict/SKILL.md skills/creating-skills/SKILL.md skills/github-epic-creation/SKILL.md skills/github-pr-merge/SKILL.md skills/memory-consolidate/SKILL.md skills/ship-pr-cycle/SKILL.md

# v0.30.C (#189): convention lock. Every skill SKILL.md must carry an
# `## Auto-continue` section so the decision-tree for "what happens after
# this skill runs" is explicit + reviewable. The 2026-05-29 audit found 8
# of 18 skills missing it; this test prevents regression + forces new
# skills to include one. (_lib/ is a helper dir, not a skill — no SKILL.md,
# naturally excluded by the glob.)

setup() {
	SKILLS_DIR="${BATS_TEST_DIRNAME}/../../../skills"
	[ -d "$SKILLS_DIR" ]
}

@test "every skill SKILL.md has an ## Auto-continue section" {
	missing=()
	for d in "$SKILLS_DIR"/*/; do
		md="$d/SKILL.md"
		[ -f "$md" ] || continue
		grep -qE '^##[[:space:]]+Auto-continue' "$md" || missing+=("$(basename "$d")")
	done
	if [ "${#missing[@]}" -gt 0 ]; then
		echo "Skills missing an '## Auto-continue' section:" >&2
		printf '  %s\n' "${missing[@]}" >&2
		echo "Add the section (see git-commit/SKILL.md for the format) — it documents what happens after the skill runs." >&2
		false
	fi
}

@test "the 8 skills fixed in #189 each have exactly one Auto-continue section" {
	# Guard against accidental double-append on re-runs of the fix.
	for s in ack cr-plan cr-resolve-conflict creating-skills \
		github-epic-creation github-pr-merge memory-consolidate ship-pr-cycle; do
		count=$(grep -cE '^##[[:space:]]+Auto-continue' "$SKILLS_DIR/$s/SKILL.md")
		[ "$count" -eq 1 ] || {
			echo "skill '$s' has $count Auto-continue sections (expected exactly 1)" >&2
			false
		}
	done
}
