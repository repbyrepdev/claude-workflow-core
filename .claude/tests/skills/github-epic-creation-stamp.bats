#!/usr/bin/env bats
# covers: skills/github-epic-creation/run.sh
#
# 2026-08-25 upstream trim: --stamp-label applies one label to the EPIC
# AND every sub-issue (unlike --label, which subs deliberately do not
# inherit), creating the label first if missing. cr-plan passes
# auto:cr-plan so ai-triage's existing "skip any auto:* label" rule
# mechanically excludes scaffolding from plan-me labeling. Drives the
# REAL skill with a PATH-stubbed gh that logs every call.
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
	# gh stub: logs "$*" for every call; per-command canned replies keep
	# the real skill's whole flow (create → link → verify) running.
	cat >"$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
	n=$(cat "$GH_COUNT" 2>/dev/null || echo 100)
	n=$((n + 1))
	echo "$n" >"$GH_COUNT"
	echo "https://github.com/stub/stub/issues/$n"
	exit 0
fi
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
	echo "stub/stub"
	exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
	case "$*" in
	*addSubIssue*) echo '{"data":{"addSubIssue":{"issue":{"number":101}}}}' ;;
	*totalCount*) echo "1" ;;
	*) echo "NODEID_stub" ;;
	esac
	exit 0
fi
exit 0
EOF
	chmod +x "$TEST_TMP/bin/gh"
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

(one)

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

teardown() {
	cd /tmp 2>/dev/null || true
	[ -n "${TEST_TMP:-}" ] && [[ $TEST_TMP == */epic-stamp.* ]] && rm -rf "$TEST_TMP"
}

@test "--stamp-label creates the label, stamps the EPIC and EVERY sub (upstream trim)" {
	cd "$TEST_TMP"
	run env PATH="$TEST_TMP/bin:$PATH" GH_LOG="$GH_LOG" GH_COUNT="$TEST_TMP/count" \
		"$SKILL" --title "EPIC: stamp test (#9)" --body-file "$TEST_TMP/epic-body.md" \
		--sub-title "one sub" --sub-body-file "$TEST_TMP/sub-body.md" \
		--stamp-label "auto:cr-plan" --yes
	[ "$status" -eq 0 ]
	# The label is ensured BEFORE first use.
	run grep -q "label create auto:cr-plan" "$GH_LOG"
	[ "$status" -eq 0 ]
	# Parent create carries the stamp (alongside epic+enhancement).
	run grep -qE "issue create --title EPIC: stamp test.*--label auto:cr-plan" "$GH_LOG"
	[ "$status" -eq 0 ]
	# The SUB create carries the stamp too — the recursion came through subs.
	run grep -qE "issue create --title one sub.*--label auto:cr-plan" "$GH_LOG"
	[ "$status" -eq 0 ]
}

@test "without --stamp-label nothing changes: no label create, no stamp (not over-broad)" {
	cd "$TEST_TMP"
	run env PATH="$TEST_TMP/bin:$PATH" GH_LOG="$GH_LOG" GH_COUNT="$TEST_TMP/count" \
		"$SKILL" --title "EPIC: plain (#9)" --body-file "$TEST_TMP/epic-body.md" \
		--sub-title "one sub" --sub-body-file "$TEST_TMP/sub-body.md" --yes
	[ "$status" -eq 0 ]
	run grep -q "label create" "$GH_LOG"
	[ "$status" -ne 0 ]
	run grep -q -- "--label auto:cr-plan" "$GH_LOG"
	[ "$status" -ne 0 ]
}
