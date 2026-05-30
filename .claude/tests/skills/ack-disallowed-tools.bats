#!/usr/bin/env bats
# covers: skills/ack/SKILL.md
#
# v0.30.H (#196 slice 3): lock the ack skill's read-only constraint. ack only
# ever uses the Read tool (it reads the hook-ack sentinel), so its SKILL.md
# frontmatter declares `disallowed-tools` to remove the mutation/execution
# tools from the pool while it runs — a runtime-honored Claude Code SKILL.md
# frontmatter field (https://code.claude.com/docs/en/skills.md: "Tools removed
# from Claude's available pool while this skill is active"). This test pins the
# declaration so a future edit can't silently drop the read-only constraint.

setup() {
	SKILL="${BATS_TEST_DIRNAME}/../../../skills/ack/SKILL.md"
	[ -f "$SKILL" ]
}

# Print the YAML frontmatter (the lines between the first two `---` fences).
_frontmatter() {
	awk 'NR==1 && $0=="---"{f=1;next} f && $0=="---"{exit} f{print}' "$SKILL"
}

@test "ack SKILL.md declares a disallowed-tools frontmatter field" {
	run _frontmatter
	[ "$status" -eq 0 ]
	[[ $output == *"disallowed-tools:"* ]]
}

@test "ack disallowed-tools denies every mutation + execution tool" {
	local dt
	dt=$(_frontmatter | sed -nE 's/^disallowed-tools:[[:space:]]*//p')
	[ -n "$dt" ]
	# ack is Read-only — each mutation/execution tool must be denied so the
	# skill cannot Edit/Write/run commands while active.
	local tool
	for tool in Edit Write MultiEdit NotebookEdit Bash; do
		[[ $dt == *"$tool"* ]] || {
			echo "missing '$tool' in disallowed-tools: $dt" >&2
			return 1
		}
	done
}

@test "ack frontmatter does not re-grant a mutation tool via allowed-tools" {
	# Belt-and-suspenders: if ack ever gains an allowed-tools line, it must not
	# re-grant a mutation tool (which would contradict the read-only intent).
	# ack currently has no allowed-tools, so this passes vacuously.
	local fm
	fm=$(_frontmatter)
	if printf '%s\n' "$fm" | grep -q '^allowed-tools:'; then
		local at tool
		at=$(printf '%s\n' "$fm" | sed -nE 's/^allowed-tools:[[:space:]]*//p')
		for tool in Edit Write MultiEdit NotebookEdit Bash; do
			[[ $at != *"$tool"* ]] || {
				echo "allowed-tools re-grants mutation tool '$tool': $at" >&2
				return 1
			}
		done
	fi
}
