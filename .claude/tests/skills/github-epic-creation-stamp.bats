#!/usr/bin/env bats
# covers: skills/github-epic-creation/run.sh
#
# 2026-08-25 upstream trim: --ensure-label is --label PLUS create-before-
# use — the value flows to the epic AND every sub through the normal
# LABELS path (p1r1 correction: subs inherit every caller --label; only
# the wrapper-injected epic/enhancement pair is parent-only). cr-plan
# passes auto:cr-plan so ai-triage's existing "skip any auto:* label"
# rule mechanically excludes scaffolding from plan-me labeling. Drives
# the REAL skill with a PATH-stubbed gh that logs every call.
# shellcheck disable=SC2030,SC2031

setup() {
	PLUGIN=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	SKILL="$PLUGIN/skills/github-epic-creation/run.sh"
	[ -x "$SKILL" ]
	TEST_TMP=$(mktemp -d -t epic-stamp.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		mkdir -p bin
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
	GH_LOG="$TEST_TMP/gh.log"
	_write_gh_stub 0
	# Epic body satisfying the template preflight (7 required sections).
	cat >"$TEST_TMP/epic-body.md" <<'EOF'
Epic fixture.

## Area

area:infrastructure

## Goal

Test the stamp.

## Scope

In-scope: stamping.

## Sub-issues

(two)

## Acceptance criteria

- stamped

## Rollout plan

One PR.

## Rollback plan

Revert.
EOF
	cat >"$TEST_TMP/sub-body.md" <<'EOF'
Sub fixture.

## Area

area:infrastructure

## Description

Stamped sub.
EOF
}

# gh stub. $1 = exit code for `gh label create` (0, or nonzero to model
# the COMMON repeat-run path: gh 422s on an existing label). Logs "$*"
# for every call BEFORE acting, so ordering + failure paths are visible.
_write_gh_stub() {
	local label_rc="$1"
	cat >"$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"\$GH_LOG"
if [ "\$1" = "label" ] && [ "\$2" = "create" ]; then
	echo "STUB-LABEL-CREATE:\$3" >&2
	exit $label_rc
fi
if [ "\$1" = "issue" ] && [ "\$2" = "create" ]; then
	echo "STUB-ISSUE-CREATE" >&2
	n=\$(cat "\$GH_COUNT" 2>/dev/null || echo 100)
	n=\$((n + 1))
	echo "\$n" >"\$GH_COUNT"
	echo "https://github.com/stub/stub/issues/\$n"
	exit 0
fi
if [ "\$1" = "repo" ] && [ "\$2" = "view" ]; then
	echo "stub/stub"
	exit 0
fi
if [ "\$1" = "api" ] && [ "\$2" = "graphql" ]; then
	case "\$*" in
	*addSubIssue*) echo '{"data":{"addSubIssue":{"issue":{"number":101}}}}' ;;
	*totalCount*) echo "2" ;;
	*) echo "NODEID_stub" ;;
	esac
	exit 0
fi
exit 0
EOF
	chmod +x "$TEST_TMP/bin/gh"
}

teardown() {
	cd /tmp 2>/dev/null || true
	[ -n "${TEST_TMP:-}" ] && [[ $TEST_TMP == */epic-stamp.* ]] && rm -rf "$TEST_TMP"
}

_run_skill() { # extra args appended
	run env PATH="$TEST_TMP/bin:$PATH" GH_LOG="$GH_LOG" GH_COUNT="$TEST_TMP/count" \
		"$SKILL" --title "EPIC: stamp test (#9)" --body-file "$TEST_TMP/epic-body.md" \
		--sub-title "sub one" --sub-body-file "$TEST_TMP/sub-body.md" \
		--sub-title "sub two" --sub-body-file "$TEST_TMP/sub-body.md" \
		--yes "$@"
}

@test "--ensure-label creates the label BEFORE any issue create, and EVERY sub is stamped" {
	cd "$TEST_TMP"
	_run_skill --ensure-label "auto:cr-plan"
	[ "$status" -eq 0 ]
	# ORDER: the ensure-create precedes the first issue create — a
	# first-ever run would otherwise fail on a nonexistent label
	# (p1r1 test-analyzer: presence greps were order-blind).
	lc=$(grep -n "label create auto:cr-plan" "$GH_LOG" | head -1 | cut -d: -f1)
	ic=$(grep -n "issue create" "$GH_LOG" | head -1 | cut -d: -f1)
	[ -n "$lc" ] && [ -n "$ic" ] && [ "$lc" -lt "$ic" ]
	# Parent carries the label.
	run grep -qE "issue create --title EPIC: stamp test.*--label auto:cr-plan" "$GH_LOG"
	[ "$status" -eq 0 ]
	# BOTH subs carry it — the runaway recursion came through subs, and a
	# single-sub fixture could not distinguish per-iteration stamping
	# from first-sub-only (p1r1 test-analyzer).
	run grep -qE "issue create --title sub one.*--label auto:cr-plan" "$GH_LOG"
	[ "$status" -eq 0 ]
	run grep -qE "issue create --title sub two.*--label auto:cr-plan" "$GH_LOG"
	[ "$status" -eq 0 ]
}

@test "ensure-create uses --force (idempotent on existing) and a REAL failure fails CLOSED" {
	# p2r1 CR major: --force makes repeat runs idempotent WITHOUT || true,
	# so auth/network/validation failures propagate — the run must abort
	# BEFORE creating any issues (no orphan epic on a broken label step).
	cd "$TEST_TMP"
	_run_skill --ensure-label "auto:cr-plan"
	[ "$status" -eq 0 ]
	[[ $output == *"STUB-LABEL-CREATE:auto:cr-plan"* ]]
	[[ $output == *"STUB-ISSUE-CREATE"* ]]
	run grep -qE "label create auto:cr-plan --force" "$GH_LOG"
	[ "$status" -eq 0 ]
	# Now a genuinely failing create (auth/network): fail closed, zero
	# issue creates.
	: >"$GH_LOG"
	_write_gh_stub 1
	_run_skill --ensure-label "auto:cr-plan"
	[ "$status" -ne 0 ]
	run grep -q "issue create" "$GH_LOG"
	[ "$status" -ne 0 ]
}

@test "combined --label + --ensure-label: subs receive BOTH (the REAL inheritance contract)" {
	# Pins what line ~570 actually does — every caller label reaches every
	# sub — so nobody "fixes" the code toward the debunked
	# subs-don't-inherit premise (p1r1: 3 agents converged on this).
	cd "$TEST_TMP"
	_run_skill --label "area:infrastructure" --ensure-label "auto:cr-plan"
	[ "$status" -eq 0 ]
	run grep -qE "issue create --title sub one.*--label area:infrastructure.*--label auto:cr-plan|issue create --title sub one.*--label auto:cr-plan.*--label area:infrastructure" "$GH_LOG"
	[ "$status" -eq 0 ]
	# And ONLY the ensure-label got a create — plain --label is assumed to exist.
	run grep -q "label create area:infrastructure" "$GH_LOG"
	[ "$status" -ne 0 ]
}

@test "without --ensure-label nothing changes: no label create, no stamp (not over-broad)" {
	cd "$TEST_TMP"
	_run_skill
	[ "$status" -eq 0 ]
	run grep -q "label create" "$GH_LOG"
	[ "$status" -ne 0 ]
	run grep -q -- "--label auto:cr-plan" "$GH_LOG"
	[ "$status" -ne 0 ]
}
