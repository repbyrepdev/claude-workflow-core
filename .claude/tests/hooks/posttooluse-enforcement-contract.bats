#!/usr/bin/env bats
# covers: _lib/event-frontmatter.sh
#
# #2547 LIVE-TREE AUDIT: every registered PostToolUse hook is classified
# enforce-vs-inform, and every enforcer really routes. The commit-time GATE
# (unclassified hooks cannot land) lives in event-frontmatter-check.sh and
# is unit-tested in .claude/tests/pre-commit-hooks/event-frontmatter-check
# .bats — its pre-existing home (phase1 r2 code-reviewer). This file audits
# the REPO against the policy, driving the same SSOT accessors the gate
# uses (`covers:` therefore names the lib: editing the accessor re-runs
# this audit; behavioral hook credit stays with lint-dispatch.bats).
#
# Discovery matches the REGISTERED universe exactly (phase1 r2: honoring
# the auto-register:false opt-out install-hooks.sh honors — a deliberately
# de-registered hook is not required to classify), and a per-file parse
# failure fails the audit LOUDLY instead of silently shrinking the
# universe (phase1 r2 silent-failure-hunter, reproduced with an unreadable
# hook).

setup() {
	REPO="${BATS_TEST_DIRNAME}/../../.."
	LIB="$REPO/_lib/event-frontmatter.sh"
	[ -f "$LIB" ]
	# shellcheck source=../../../_lib/event-frontmatter.sh disable=SC1091
	. "$LIB"
	HOOKS_DIR="$REPO/hooks"
	TEST_TMP=$(mktemp -d -t ptuenf.XXXXXX) || return 1
}

teardown() {
	cd /tmp 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */ptuenf.* ]]; then
		chmod -R u+rwx "$TEST_TMP" 2>/dev/null || true
		rm -rf "$TEST_TMP"
	fi
}

# Emit the REGISTERED PostToolUse hooks of $1 (a hooks dir): skip helper
# basenames and auto-register:false opt-outs via the SSOT; a parse failure
# is FATAL (rc 1 + the file named on stderr) so the audit can never pass
# vacuously on a shrunken universe.
_posttooluse_hooks() {
	local dir="$1" f base _parse_out event auto
	for f in "$dir"/*.sh; do
		base=$(basename "$f")
		event_frontmatter_skip_basename "$base" && continue
		if ! _parse_out=$(event_frontmatter_parse "$f"); then
			echo "AUDIT PARSE FAILURE: $f (unreadable?) — refusing a vacuous pass" >&2
			return 1
		fi
		event=$(printf '%s\n' "$_parse_out" | sed -n 1p)
		auto=$(printf '%s\n' "$_parse_out" | sed -n 3p)
		[ "$auto" = "false" ] && continue
		[ "$event" = "PostToolUse" ] && printf '%s\n' "$f"
	done
	return 0
}

# A hook "routes" iff a NON-COMMENT line invokes an enumerated blocking
# mechanism: hook_ack_append (the universal sentinel) or a decision:block
# JSON response. Known limitation, deliberate: the call must be visible in
# the hook file itself — hoisting an ack wrapper into _lib later turns
# this RED loudly (fail-closed), at which point the contract gets taught
# the new shape in the same PR (phase1 r2 code-reviewer).
_hook_routes() {
	grep -qE '^[^#]*hook_ack_append' "$1" && return 0
	grep -qE '^[^#]*"decision"[[:space:]]*:[[:space:]]*"block"' "$1"
}

_discover_or_fail() {
	# $1 = dir; sets DISCOVERED (newline list) or returns 1 loudly.
	DISCOVERED=$(_posttooluse_hooks "$1") || return 1
	return 0
}

@test "#2547 every registered live PostToolUse hook is classified enforce or inform" {
	_discover_or_fail "$HOOKS_DIR" || {
		echo "discovery failed — see parse failure above"
		return 1
	}
	[ -n "$DISCOVERED" ] || {
		echo "SSOT discovery found ZERO registered PostToolUse hooks — parser drift?"
		return 1
	}
	local f missing=""
	while IFS= read -r f; do
		event_frontmatter_enforcement "$f" >/dev/null || missing="$missing ${f##*/}"
	done <<<"$DISCOVERED"
	[ -z "$missing" ] || {
		echo "unclassified (or out-of-vocabulary) PostToolUse hook(s):$missing"
		return 1
	}
}

@test "#2547 every enforce-classified hook routes via a non-comment blocking call" {
	_discover_or_fail "$HOOKS_DIR" || {
		echo "discovery failed — see parse failure above"
		return 1
	}
	local f unrouted=""
	while IFS= read -r f; do
		[ "$(event_frontmatter_enforcement "$f" 2>/dev/null)" = "enforce" ] || continue
		_hook_routes "$f" || unrouted="$unrouted ${f##*/}"
	done <<<"$DISCOVERED"
	[ -z "$unrouted" ] || {
		echo "enforce-classified hook(s) with no non-comment blocking call:$unrouted"
		return 1
	}
}

@test "#2547 lint-dispatch is pinned as the enforce-classified hook" {
	# The one current enforcer, pinned by name: reclassifying it to inform
	# (or deleting the line) must turn this red — that decision belongs in
	# review, not in drift. Also the existence guard for the routing test
	# above (if no enforcer exists at all, THIS is what goes red).
	[ "$(event_frontmatter_enforcement "$HOOKS_DIR/lint-dispatch.sh")" = "enforce" ] || {
		echo "lint-dispatch.sh is no longer declared enforcement:enforce"
		return 1
	}
}

@test "#2547 audit honors auto-register:false (registered universe, not file universe)" {
	mkdir -p "$TEST_TMP/hooks"
	printf '#!/bin/bash\nset -u\n# event: PostToolUse\n# auto-register: false\nexit 0\n' >"$TEST_TMP/hooks/optout.sh"
	printf '#!/bin/bash\nset -u\n# event: PostToolUse\n# enforcement: inform — fixture\nexit 0\n' >"$TEST_TMP/hooks/reg.sh"
	_discover_or_fail "$TEST_TMP/hooks" || {
		echo "fixture discovery failed"
		return 1
	}
	[[ $DISCOVERED == *"reg.sh"* ]] || {
		echo "registered fixture missing from the universe: $DISCOVERED"
		return 1
	}
	[[ $DISCOVERED != *"optout.sh"* ]] || {
		echo "auto-register:false hook counted as registered — the universes diverge again"
		return 1
	}
}

@test "#2547 an unreadable hook fails the audit LOUDLY, never a vacuous pass" {
	mkdir -p "$TEST_TMP/hooks"
	printf '#!/bin/bash\nset -u\n# event: PostToolUse\nexit 0\n' >"$TEST_TMP/hooks/dark.sh"
	chmod 000 "$TEST_TMP/hooks/dark.sh"
	run _posttooluse_hooks "$TEST_TMP/hooks"
	[ "$status" -ne 0 ] || {
		echo "unreadable hook silently dropped from the audited universe (rc=0)"
		return 1
	}
	[[ $output == *"AUDIT PARSE FAILURE"* ]] || {
		echo "no loud parse-failure diagnostic. output: $output"
		return 1
	}
}
