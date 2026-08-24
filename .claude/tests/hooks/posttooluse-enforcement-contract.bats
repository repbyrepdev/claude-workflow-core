#!/usr/bin/env bats
# covers: pre-commit-hooks/event-frontmatter-check.sh
#
# #2547: PostToolUse hooks must be CLASSIFIED enforce-vs-inform. The GATE is
# pre-commit-hooks/event-frontmatter-check.sh (fail-closed at commit time —
# phase1 r1 code-reviewer: a bats-only check fires long after an unclassified
# hook lands); this file is the gate's unit test PLUS the live-tree routing
# audit the gate deliberately does not do (it pins existence of the
# classification; routing truth needs content inspection).
#
# `covers:` names ONLY the gate script (phase1 r1 code-reviewer, conf 9):
# listing the twelve hooks here would grant them FALSE behavioral-coverage
# credit in test-touched routing and the mirror-drift gate — behavioral
# credit stays with behavioral suites (lint-dispatch.bats).
#
# Discovery drives off _lib/event-frontmatter.sh — the declared SSOT for
# frontmatter semantics (scan window, helper-basename skips, opt-out) — so
# the classified universe cannot diverge from the registered one.

setup() {
	REPO="${BATS_TEST_DIRNAME}/../../.."
	GATE="$REPO/pre-commit-hooks/event-frontmatter-check.sh"
	LIB="$REPO/_lib/event-frontmatter.sh"
	[ -x "$GATE" ]
	[ -f "$LIB" ]
	# shellcheck source=../../../_lib/event-frontmatter.sh disable=SC1091
	. "$LIB"
	HOOKS_DIR="$REPO/hooks"
	TEST_TMP=$(mktemp -d -t ptuenf.XXXXXX) || return 1
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		mkdir -p hooks
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
	) || return 1
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */ptuenf.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Live-tree PostToolUse hooks via the SSOT: skip helper basenames, honor the
# parser's scan window, filter to event == PostToolUse.
_posttooluse_hooks() {
	local f base event
	for f in "$HOOKS_DIR"/*.sh; do
		base=$(basename "$f")
		event_frontmatter_skip_basename "$base" && continue
		event=$(event_frontmatter_parse "$f" | head -1)
		[ "$event" = "PostToolUse" ] && printf '%s\n' "$f"
	done
	return 0
}

# A hook "routes" iff a NON-COMMENT line invokes an enumerated blocking
# mechanism: hook_ack_append (the universal sentinel) or a decision:block
# JSON response (phase1 r1 silent-failure-hunter + pr-test-analyzer: the
# bare string grep passed vacuously on a comment mention).
_hook_routes() {
	grep -qE '^[^#]*hook_ack_append' "$1" && return 0
	grep -qE '^[^#]*"decision"[[:space:]]*:[[:space:]]*"block"' "$1"
}

@test "#2547 GATE refuses a PostToolUse hook with no enforcement classification" {
	cat >"$TEST_TMP/hooks/newhook.sh" <<'EOF'
#!/bin/bash
set -u
# event: PostToolUse
# matcher: Bash
exit 0
EOF
	cd "$TEST_TMP" || return 1
	run bash "$GATE" hooks/newhook.sh
	[ "$status" -eq 1 ] || {
		echo "unclassified PostToolUse hook passed the gate (rc=$status). output: $output"
		return 1
	}
	[[ $output == *"enforce-vs-inform"* ]] || {
		echo "refusal does not name the missing classification. output: $output"
		return 1
	}
}

@test "#2547 GATE passes a classified PostToolUse hook; non-PostToolUse needs none" {
	cat >"$TEST_TMP/hooks/classified.sh" <<'EOF'
#!/bin/bash
set -u
# event: PostToolUse
# matcher: Bash
# enforcement: inform — fixture
exit 0
EOF
	cat >"$TEST_TMP/hooks/pretool.sh" <<'EOF'
#!/bin/bash
set -u
# event: PreToolUse
# matcher: Bash
exit 0
EOF
	cd "$TEST_TMP" || return 1
	run bash "$GATE" hooks/classified.sh hooks/pretool.sh
	[ "$status" -eq 0 ] || {
		echo "classified + non-PostToolUse fixtures failed the gate (rc=$status). output: $output"
		return 1
	}
}

@test "#2547 every live PostToolUse hook is classified enforce or inform" {
	local f missing="" n=0
	while IFS= read -r f; do
		n=$((n + 1))
		head -n "$(event_frontmatter_scan_window)" "$f" |
			grep -qE '^# enforcement: (enforce|inform)( |$)' || missing="$missing ${f##*/}"
	done < <(_posttooluse_hooks)
	[ "$n" -gt 0 ] || {
		echo "SSOT discovery found ZERO PostToolUse hooks — parser drift?"
		return 1
	}
	[ -z "$missing" ] || {
		echo "unclassified PostToolUse hook(s):$missing"
		return 1
	}
}

@test "#2547 every enforcement:enforce hook routes via a non-comment blocking call" {
	local f unrouted="" found=0
	while IFS= read -r f; do
		head -n "$(event_frontmatter_scan_window)" "$f" |
			grep -qE '^# enforcement: enforce' || continue
		found=1
		_hook_routes "$f" || unrouted="$unrouted ${f##*/}"
	done < <(_posttooluse_hooks)
	[ "$found" -eq 1 ] || {
		echo "no enforcement:enforce hook found at all — lint-dispatch reclassified? That IS the regression."
		return 1
	}
	[ -z "$unrouted" ] || {
		echo "enforce-classified hook(s) with no non-comment blocking call:$unrouted"
		return 1
	}
}

@test "#2547 lint-dispatch is pinned as the enforce-classified hook" {
	# The one current enforcer, pinned by name: reclassifying it to inform
	# (or deleting the line) must turn this red — that decision belongs in
	# review, not in drift.
	head -n "$(event_frontmatter_scan_window)" "$HOOKS_DIR/lint-dispatch.sh" |
		grep -qE '^# enforcement: enforce' || {
		echo "lint-dispatch.sh is no longer declared enforcement:enforce"
		return 1
	}
}
