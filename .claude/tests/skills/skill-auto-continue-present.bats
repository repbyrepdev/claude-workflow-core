#!/usr/bin/env bats
# covers: skills/ack/SKILL.md skills/cr-plan/SKILL.md skills/cr-resolve-conflict/SKILL.md skills/creating-skills/SKILL.md skills/github-epic-creation/SKILL.md skills/github-pr-merge/SKILL.md skills/memory-consolidate/SKILL.md skills/ship-pr-cycle/SKILL.md

# v0.30.C (#189): convention lock. Every skill SKILL.md must carry an
# `## Auto-continue` section (exactly one, with content) so the decision-tree
# for "what happens after this skill runs" is explicit + reviewable. The
# 2026-05-29 audit found 8 of 18 skills missing it; this test prevents
# regression + forces new skills to include one. (_lib/ is a helper dir, not
# a skill — no SKILL.md, naturally excluded by the -f guard.)
#
# Phase 1 R1 hardening: (a) a `checked` counter fails the test loudly if the
# glob matches zero SKILL.md (silent-failure-hunter — a non-expanding glob
# would otherwise pass vacuously); (b) per-file exactly-one + has-content
# checks fold the prior hardcoded 8-skill list into the glob loop so the SSOT
# is the directory, not a drift-prone literal (pr-test-analyzer + simplifier).

setup() {
	SKILLS_DIR="${BATS_TEST_DIRNAME}/../../../skills"
	[ -d "$SKILLS_DIR" ] || {
		echo "SKILLS_DIR not found: $SKILLS_DIR" >&2
		false
	}
}

# Emit "<heading-count> <body-line-count>" for a SKILL.md, fence-aware.
# - Lines inside ``` fenced code blocks are ignored, so an `## Auto-continue`
#   shown as a documentation EXAMPLE (e.g. in creating-skills) is not counted.
# - The heading match has no end-anchor, so a heading with trailing text
#   (e.g. `## Auto-continue (decision tree)`) still counts as the section.
# - body = non-blank lines under the (first) section until the next `## `.
_auto_continue_stats() {
	awk '
		/^```/ { fence = !fence; next }
		fence { next }
		/^##[[:space:]]+Auto-continue/ { count++; in_sec=1; next }
		in_sec && /^##[[:space:]]/ { in_sec=0 }
		in_sec && /[^[:space:]]/ { body++ }
		END { print count + 0, body + 0 }
	' "$1"
}

@test "every skill SKILL.md has exactly one non-empty ## Auto-continue section" {
	missing=()
	dup=()
	empty=()
	checked=0
	for d in "$SKILLS_DIR"/*/; do
		md="${d}SKILL.md"
		[ -f "$md" ] || continue
		checked=$((checked + 1))
		read -r count body < <(_auto_continue_stats "$md")
		if [ "$count" -eq 0 ]; then
			missing+=("$(basename "$d")")
		elif [ "$count" -gt 1 ]; then
			dup+=("$(basename "$d") ($count)")
		elif [ "$body" -eq 0 ]; then
			empty+=("$(basename "$d")")
		fi
	done

	# Fail loud if the glob matched nothing — never pass vacuously.
	if [ "$checked" -eq 0 ]; then
		echo "No SKILL.md found under $SKILLS_DIR — test would pass vacuously; check the path/glob." >&2
		false
	fi

	local bad=0
	if [ "${#missing[@]}" -gt 0 ]; then
		echo "Skills missing an '## Auto-continue' section:" >&2
		printf '  %s\n' "${missing[@]}" >&2
		echo "Add the section (see git-commit/SKILL.md + creating-skills/SKILL.md for the format)." >&2
		bad=1
	fi
	if [ "${#dup[@]}" -gt 0 ]; then
		echo "Skills with MORE than one '## Auto-continue' section (double-append):" >&2
		printf '  %s\n' "${dup[@]}" >&2
		bad=1
	fi
	if [ "${#empty[@]}" -gt 0 ]; then
		echo "Skills with an EMPTY '## Auto-continue' section (heading but no content):" >&2
		printf '  %s\n' "${empty[@]}" >&2
		bad=1
	fi
	[ "$bad" -eq 0 ]
}
