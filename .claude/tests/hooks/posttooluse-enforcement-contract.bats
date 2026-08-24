#!/usr/bin/env bats
# covers: hooks/lint-dispatch.sh hooks/cr-pause-detector.sh hooks/hook-ack-clear.sh hooks/next-step-advisor.sh hooks/persist-session-state.sh hooks/phase0.5-post-commit-rerun.sh hooks/phase1-post-agent-nudge.sh hooks/phase1-post-commit-resume.sh hooks/post-commit-template-lint.sh hooks/post-tool-failure.sh hooks/pr-close-prune.sh hooks/pr-trigger.sh
#
# #2547: every PostToolUse hook must be CLASSIFIED enforce-vs-inform via a
# `# enforcement: ack|inform — <reason>` frontmatter line, and every
# `enforcement: ack` hook must actually route through hook_ack_append. The
# audit that produced the classification is a one-time act; this contract is
# what keeps it true — a NEW PostToolUse hook cannot land unclassified, and
# an enforcer cannot silently drop its routing (the exact regression #2547
# fears: "Fix now, same-turn" messages that scroll past).

setup() {
	HOOKS_DIR="${BATS_TEST_DIRNAME}/../../../hooks"
	[ -d "$HOOKS_DIR" ]
}

_posttooluse_hooks() {
	grep -l "^# event:.*PostToolUse" "$HOOKS_DIR"/*.sh
}

@test "#2547 every PostToolUse hook declares enforcement: ack or inform" {
	local f missing=""
	while IFS= read -r f; do
		grep -qE "^# enforcement: (ack|inform)( |$)" "$f" || missing="$missing ${f##*/}"
	done < <(_posttooluse_hooks)
	[ -z "$missing" ] || {
		echo "PostToolUse hook(s) with no enforce-vs-inform classification:$missing"
		echo "Add '# enforcement: ack — <why it blocks>' or '# enforcement: inform — <why advisory>' after the matcher line."
		return 1
	}
}

@test "#2547 every enforcement:ack hook routes through hook_ack_append" {
	local f unrouted="" found=0
	while IFS= read -r f; do
		grep -qE "^# enforcement: ack" "$f" || continue
		found=1
		grep -q "hook_ack_append" "$f" || unrouted="$unrouted ${f##*/}"
	done < <(_posttooluse_hooks)
	[ "$found" -eq 1 ] || {
		echo "no enforcement:ack hook found at all — lint-dispatch reclassified? That IS the regression."
		return 1
	}
	[ -z "$unrouted" ] || {
		echo "enforcement:ack hook(s) that never call hook_ack_append:$unrouted"
		return 1
	}
}

@test "#2547 lint-dispatch is pinned as the ack-routed enforcer" {
	# The one current enforcer, pinned by name: reclassifying it to inform
	# (or deleting the line) must turn this red — that decision belongs in
	# review, not in drift.
	grep -qE "^# enforcement: ack" "$HOOKS_DIR/lint-dispatch.sh" || {
		echo "lint-dispatch.sh is no longer declared enforcement:ack"
		return 1
	}
}
