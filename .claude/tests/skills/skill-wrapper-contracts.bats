#!/usr/bin/env bats
# covers: skills/cr-plan/run.sh skills/cr-resolve-conflict/run.sh skills/github-epic-creation/run.sh skills/github-pr-creation/run.sh skills/prove-yourself-audit/run.sh skills/bootstrap-repo/run.sh
#
# v0.30.H (#196 slice 2): bats coverage for the 6 highest-risk untested skill
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

@test "all 6 high-risk skill wrappers export SKILL_WRAPPER=1 (bypass-guard contract)" {
	local s r
	for s in cr-plan cr-resolve-conflict github-epic-creation github-pr-creation prove-yourself-audit bootstrap-repo; do
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

@test "cr-plan: invalid/missing issue arg exits 2 with usage" {
	# A single non-flag token leaves issue="${2:-}" empty, so the missing-args
	# guard (run.sh ~L74) fires the Usage exit-2 path. (The unknown-subcommand
	# *) branch needs a valid issue number, which pulls in gh — not hermetically
	# testable, so this locks the missing/invalid-issue-arg guard it actually
	# reaches, pinned by the Usage message.)
	run bash "$(_wrapper cr-plan)" definitely-not-a-real-subcommand
	[ "$status" -eq 2 ]
	[[ $output == *"Usage"* ]] || [[ $output == *"usage"* ]]
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
	# Pin the --title arg-guard specifically (a downstream empty-TITLE check
	# also exits 2, so without this the test would pass even if the guard went).
	[[ $output == *"--title"* ]]
}

@test "prove-yourself-audit: --help exits 0" {
	run bash "$(_wrapper prove-yourself-audit)" --help
	[ "$status" -eq 0 ]
}

@test "prove-yourself-audit: unknown action exits 2" {
	run bash -c "cd '$REPO' && bash '$(_wrapper prove-yourself-audit)' not-a-real-action"
	[ "$status" -eq 2 ]
	# Pin the unknown-action *) branch (distinct from the missing-jq exit 2).
	[[ $output == *"unknown subcommand"* ]]
}

@test "prove-yourself-audit: record-fix --covers-count N writes covers_count:N to the audit log (#238)" {
	# #238 (pr-test-analyzer r1, crit-8): _append_tracked_audit must PERSIST
	# covers_count so the pre-push-gate's CR-coverage sum honors `--covers-count N`
	# (was always null → defaulted to 1, silently dropping multi-finding coverage).
	# Functional WRITER test — proves the producer (run.sh) writes the field the
	# consumer (cr_phase2_clean_for_sha) reads; would FAIL if the run.sh fix were
	# reverted (the prior bats hand-wrote the audit, so the writer was untested).
	# Fail CLOSED, not skip-as-pass: a skipped test counts as a bats "pass", so
	# skipping on missing jq would silently neuter this writer-coverage contract.
	# [#238 phase2 r1, CR major]
	command -v jq >/dev/null 2>&1 || {
		echo "jq required for the prove-yourself-audit covers_count contract test" >&2
		return 1
	}
	local repo audit
	repo=$(mktemp -d -t pycovers.XXXXXX)
	(cd "$repo" && git init -q && git config user.email t@t.t && git config user.name t && git commit -q --allow-empty -m init)
	run bash -c "cd '$repo' && bash '$(_wrapper prove-yourself-audit)' record-fix --source cr --severity minor --covers-count 3 --finding-id t238 --finding-text x --fix-summary y --retest-cmd true --retest-rc 0"
	[ "$status" -eq 0 ]
	# CLI success-message contract — not just exit status + audit side-effect
	# (#238 phase2 r2/3, CR minor). Asserted on this first `run` before the jq
	# `run` below overwrites $output.
	[[ $output == *"Recorded fix"* ]]
	audit="$repo/.claude/audit/prove-yourself.jsonl"
	[ -f "$audit" ]
	run jq -rs '[.[] | select(.finding_id=="t238")] | last | .covers_count' "$audit"
	[ "$status" -eq 0 ]
	[ "$output" = "3" ]
	[ -d "$repo" ] && [[ $repo == */pycovers.* ]] && rm -rf "$repo"
}
