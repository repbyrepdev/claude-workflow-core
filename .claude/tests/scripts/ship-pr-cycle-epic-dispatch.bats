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
	# `set -e` inside the subshell catches git/mkdir failures (silent-
	# failure-hunter #125 r2 HIGH: minimal CI containers without git, or
	# read-only TMPDIR, would silently produce a non-repo fixture and
	# downstream tests would fail with confusing "not in a git repo"
	# errors blamed on the dispatch). Capture subshell rc + abort setup.
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		mkdir -p .claude/skills/cr-plan
	) || {
		echo "FATAL: TEST_TMP fixture init failed (git/mkdir)" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164 # teardown best-effort; rm guarded below
	# silent-failure-hunter #125 r2: fall back to BATS_TEST_DIRNAME if
	# /tmp is unavailable (chroot/jail) so teardown still escapes TEST_TMP
	# before rm -rf fires.
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */ship-epic.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "epic with no args exits 2 + writes usage to stderr" {
	run "$SCRIPT" epic
	[ "$status" -eq 2 ]
	[[ $output == *"Usage: ship-pr-cycle.sh epic"* ]] || return 1
	[[ $output == *"trigger <num>"* ]] || return 1
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
	[[ $output == *"brainstorm.yml"* ]] || return 1
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
	[[ $output == *"epic"* ]] || return 1
	[[ $output == *"cr-plan a brainstorm artifact"* ]]
}

@test "unknown subcommand error message lists epic" {
	run "$SCRIPT" not-a-real-subcommand
	[ "$status" -eq 2 ]
	[[ $output == *"epic"* ]]
}

# Mechanism note: cwd-derived REPO_ROOT picks up TEST_TMP (initialized as a
# git repo in setup()), and the resolver's CONSUMER-FIRST lookup in
# _lib/resolve-plugin-helper.sh returns the stub at
# $REPO_ROOT/.claude/skills/cr-plan/run.sh BEFORE falling through to the
# plugin cache. No env-var flag is involved — the stub wins via path order.
# (Earlier drafts used PLUGIN_HELPER_NO_SEARCH=1 — that env var is not
# recognized anywhere in the codebase; removed as misleading dead code.)

@test "epic forwards args verbatim to cr-plan (pass-through contract)" {
	# Pin the verbatim-forwarding contract. Stub also echoes $0 so the test
	# asserts both 'args correct' AND 'invocation site was the local stub'
	# — guards against the resolver silently picking the plugin cache.
	cd "$TEST_TMP" || return 1
	cat >.claude/skills/cr-plan/run.sh <<'STUB'
#!/usr/bin/env bash
echo "STUB-CR-PLAN-AT:$0"
echo "STUB-CR-PLAN-ARGS:$*"
exit 0
STUB
	chmod +x .claude/skills/cr-plan/run.sh
	run "$SCRIPT" epic trigger 12345 extra-arg
	[ "$status" -eq 0 ]
	[[ $output == *"STUB-CR-PLAN-ARGS:trigger 12345 extra-arg"* ]] || return 1
	# The stub MUST have been the one invoked, not the live plugin's cr-plan.
	# Match on `.claude/skills/cr-plan/run.sh` suffix — the LIVE plugin lives
	# at `<plugin>/skills/cr-plan/run.sh` (no `.claude/` prefix), so this
	# substring uniquely identifies the consumer-shipped stub. Direct path
	# comparison would fail on macOS where mktemp returns `/var/...` but
	# `$0` resolves through the `/private/var/...` symlink.
	[[ $output == *".claude/skills/cr-plan/run.sh"* ]]
}

@test "epic propagates cr-plan exit code (failure visibility)" {
	# Pin exit-code propagation. A regression that wraps cr-plan with
	# `|| true` or a logging layer would silently mask non-zero returns.
	# Stub returns rc=7; dispatch must surface it.
	cd "$TEST_TMP" || return 1
	cat >.claude/skills/cr-plan/run.sh <<'STUB'
#!/usr/bin/env bash
exit 7
STUB
	chmod +x .claude/skills/cr-plan/run.sh
	run "$SCRIPT" epic parse 999
	[ "$status" -eq 7 ]
}

# helper non-exec guard: not pinned by a bats test. The resolver's plugin-
# cache fallback (see `_lib/resolve-plugin-helper.sh`) wins when the local
# $REPO_ROOT/.claude/skills/cr-plan/ has no run.sh, so an isolated tmp repo
# cannot simulate 'no cr-plan anywhere' without a stand-alone fixture that
# also shadows the plugin root.
#
# Manual verification recipe (NON-DESTRUCTIVE — uses a copied throwaway):
#
#   $ tmp=$(mktemp -d); cd $tmp; git init -q
#   $ cp -R /path/to/plugin/skills $tmp/.claude/  # local override copy
#   $ chmod -x $tmp/.claude/skills/cr-plan/run.sh # disable the LOCAL copy
#   $ /path/to/plugin/scripts/ship-pr-cycle.sh epic trigger 555
#   ship-pr-cycle epic: cr-plan skill wrapper missing or non-exec: …
#   exit=2 ✓
#
# (Earlier draft of this comment recommended `chmod -x` on the REAL plugin
# file — destructive; would break the operator's own cr-plan skill until
# restored. The non-destructive recipe above uses a local override copy.)
#
# Source of truth: grep for `cr-plan skill wrapper missing or non-exec`
# in scripts/ship-pr-cycle.sh — the `[ ! -x "$_cr_plan" ]` block in the
# `epic)` case-branch. Anchor pattern is line-shift-resistant.
