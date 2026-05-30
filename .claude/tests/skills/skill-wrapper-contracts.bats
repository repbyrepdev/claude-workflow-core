#!/usr/bin/env bats
# covers: skills/cr-plan/run.sh skills/cr-resolve-conflict/run.sh skills/github-epic-creation/run.sh skills/github-pr-creation/run.sh skills/prove-yourself-audit/run.sh
#
# v0.30.H (#196 slice 2): bats coverage for the 5 highest-risk untested skill
# wrappers (they invoke gh/git and write to disk). Two contracts are locked:
#   1. Each wrapper `export SKILL_WRAPPER=1` — the whole reason these run.sh
#      files exist (so their nested gh/git calls pass skill-bypass-guard). A
#      dropped export silently re-breaks every restricted call the skill makes.
#   2. Arg-validation fails CLOSED (exit 2) on missing/bad args — these paths
#      run BEFORE any gh/network call, so they're testable without mocking gh.
#
# Scope note: the wrappers' happy paths make live gh/git calls (PR/issue
# creation, CR polling) that need a real GitHub remote + auth, so they are out
# of scope for a unit test; the SKILL_WRAPPER contract + the fail-closed
# arg-validation are the high-value, hermetically-testable surface.

setup() {
	REPO="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
	[ -d "$REPO/skills" ]
}

_wrapper() { echo "$REPO/skills/$1/run.sh"; }

@test "all 5 high-risk skill wrappers export SKILL_WRAPPER=1 (bypass-guard contract)" {
	local s r
	for s in cr-plan cr-resolve-conflict github-epic-creation github-pr-creation prove-yourself-audit; do
		r=$(_wrapper "$s")
		[ -f "$r" ] || {
			echo "missing wrapper: $r" >&2
			return 1
		}
		grep -qE '^[[:space:]]*export SKILL_WRAPPER=1[[:space:]]*$' "$r" || {
			echo "$s/run.sh does not 'export SKILL_WRAPPER=1'" >&2
			return 1
		}
	done
}

@test "cr-plan: --help exits 0 with usage" {
	run bash "$(_wrapper cr-plan)" --help
	[ "$status" -eq 0 ]
	[[ $output == *"Usage"* ]] || [[ $output == *"usage"* ]]
}

@test "cr-plan: unknown subcommand exits 2" {
	run bash "$(_wrapper cr-plan)" definitely-not-a-real-subcommand
	[ "$status" -eq 2 ]
}

@test "cr-resolve-conflict: --pr with no value exits 2" {
	run bash -c "cd '$REPO' && bash '$(_wrapper cr-resolve-conflict)' --pr"
	[ "$status" -eq 2 ]
	[[ $output == *"--pr"* ]]
}

@test "github-pr-creation: --title with no value exits 2" {
	run bash -c "cd '$REPO' && bash '$(_wrapper github-pr-creation)' --title"
	[ "$status" -eq 2 ]
	[[ $output == *"--title"* ]]
}

@test "github-epic-creation: --title with no value exits 2" {
	run bash -c "cd '$REPO' && bash '$(_wrapper github-epic-creation)' --title"
	[ "$status" -eq 2 ]
}

@test "prove-yourself-audit: --help exits 0" {
	run bash "$(_wrapper prove-yourself-audit)" --help
	[ "$status" -eq 0 ]
}

@test "prove-yourself-audit: unknown action exits 2" {
	run bash "$(_wrapper prove-yourself-audit)" not-a-real-action
	[ "$status" -eq 2 ]
}
