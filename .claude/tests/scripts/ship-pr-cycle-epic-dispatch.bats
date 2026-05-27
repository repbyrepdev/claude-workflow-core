#!/usr/bin/env bats
# covers: scripts/ship-pr-cycle.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/ship-pr-cycle.sh"
	TEST_TMP=$(mktemp -d -t ship-epic.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# Stub-isolation infra: initialize a tmp git repo + .claude/ tree so
	# the dispatch's REPO_ROOT-aware helpers find local stubs instead of
	# the real plugin cache. Tests that need this `cd "$TEST_TMP"` first.
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		mkdir -p .claude/skills/cr-plan
	)
}

teardown() {
	# shellcheck disable=SC2164 # teardown best-effort; rm guarded below
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */ship-epic.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "epic with no args exits 2 + writes usage to stderr" {
	run "$SCRIPT" epic
	[ "$status" -eq 2 ]
	[[ $output == *"Usage: ship-pr-cycle.sh epic"* ]]
	[[ $output == *"trigger <num>"* ]]
	[[ $output == *"parse <num>"* ]]
}

@test "epic --help exits 0 (convention) + writes usage to stdout" {
	run "$SCRIPT" epic --help
	[ "$status" -eq 0 ]
	[[ $output == *"Usage: ship-pr-cycle.sh epic"* ]]
}

@test "epic -h exits 0 (alias for --help)" {
	run "$SCRIPT" epic -h
	[ "$status" -eq 0 ]
	[[ $output == *"Usage: ship-pr-cycle.sh epic"* ]]
}

@test "epic help mentions PARALLEL workflow doctrine + APPROVE=1 gate" {
	run "$SCRIPT" epic --help
	[ "$status" -eq 0 ]
	# Workflow rooted in operator-driven brainstorm (not auto-fired into ship cycle)
	[[ $output == *"brainstorm.yml"* ]]
	# Gate matches cr-plan's APPROVE=1 requirement (parse step)
	[[ $output == *"APPROVE=1"* ]]
}

@test "epic dispatch references cr-plan as the underlying skill" {
	run "$SCRIPT" epic --help
	[ "$status" -eq 0 ]
	[[ $output == *"skills/cr-plan/run.sh"* ]]
}

@test "epic appears in top-level _usage subcommand listing" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"epic"* ]]
	[[ $output == *"cr-plan a brainstorm artifact"* ]]
}

@test "unknown subcommand error message lists epic" {
	run "$SCRIPT" not-a-real-subcommand
	[ "$status" -eq 2 ]
	[[ $output == *"epic"* ]]
}

@test "epic forwards args verbatim to cr-plan (pass-through contract)" {
	# pr-test-analyzer #125 r1: pin the verbatim-forwarding contract.
	# Stub skills/cr-plan/run.sh inside an isolated repo, echoes args.
	cd "$TEST_TMP" || return 1
	cat >.claude/skills/cr-plan/run.sh <<'STUB'
#!/usr/bin/env bash
echo "STUB-CR-PLAN-ARGS:$*"
exit 0
STUB
	chmod +x .claude/skills/cr-plan/run.sh
	# PLUGIN_HELPER_NO_SEARCH disables plugin-helper search so the resolver
	# falls back to $REPO_ROOT/.claude/$path. REPO_ROOT auto-derives from
	# cwd's git rev-parse, which is TEST_TMP (initialized as a repo in setup).
	PLUGIN_HELPER_NO_SEARCH=1 run "$SCRIPT" epic trigger 12345 extra-arg
	[ "$status" -eq 0 ]
	[[ $output == *"STUB-CR-PLAN-ARGS:trigger 12345 extra-arg"* ]]
}

@test "epic propagates cr-plan exit code (failure visibility)" {
	# pr-test-analyzer #125 r1: pin exit-code propagation. A regression
	# that wraps cr-plan with `|| true` or a logging layer would silently
	# mask non-zero returns. Stub returns rc=7; dispatch must surface it.
	cd "$TEST_TMP" || return 1
	cat >.claude/skills/cr-plan/run.sh <<'STUB'
#!/usr/bin/env bash
exit 7
STUB
	chmod +x .claude/skills/cr-plan/run.sh
	PLUGIN_HELPER_NO_SEARCH=1 run "$SCRIPT" epic parse 999
	[ "$status" -eq 7 ]
}

# pr-test-analyzer #125 r1 finding 1 (helper non-exec guard): not pinned by a
# bats test. The `_shipcycle_resolve` resolver falls back to the plugin's own
# root when REPO_ROOT/.claude/<path> is empty, so an isolated tmp repo cannot
# simulate "no cr-plan anywhere" without copying the whole script + deps to a
# stand-alone fixture. Verified manually instead:
#
#   $ TEST_TMP=$(mktemp -d); cd $TEST_TMP; git init -q
#   $ chmod -x /path/to/plugin/skills/cr-plan/run.sh
#   $ ship-pr-cycle.sh epic trigger 555
#   ship-pr-cycle epic: cr-plan skill wrapper missing or non-exec: …
#   exit=2 ✓
#
# Mechanical pin lives in the dispatch's `if [ ! -x "$_cr_plan" ]` block — a
# direct read of scripts/ship-pr-cycle.sh:2324-2327 is the source of truth for
# this branch until a fixture-isolated REPO_ROOT pattern lands (deferred).
