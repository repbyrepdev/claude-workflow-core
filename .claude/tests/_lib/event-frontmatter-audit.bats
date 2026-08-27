#!/usr/bin/env bats
# covers: _lib/event-frontmatter.sh
# audits: hooks/*.sh
#
# (#2572) FIRST USER of the `# audits:` header. `covers:` names what this file
# BEHAVIOURALLY exercises — the lib's accessors, which it calls directly.
# `audits:` names what it SWEEPS: every hook in hooks/, checked against the
# classification policy without any of them being executed.
#
# The split matters because three consumers read these headers. test-touched
# routes on BOTH (an audit must re-run when a hook it polices changes), while
# the coverage report and the refresh-from-source drift gate count `covers:`
# ONLY. Before the split, this file's single covers: line either under-routed
# (hook edits did not re-run the audit) or, had it listed the hooks, would
# have told the drift gate that 40-odd mirror hooks were verified by a policy
# scan that never ran one of them.
#
# #2547 LIVE-TREE AUDIT + accessor unit tests. The commit-time GATE lives in
# event-frontmatter-check.sh (its unit tests in .claude/tests/pre-commit-
# hooks/event-frontmatter-check.bats — phase1 r2). This file audits the REPO
# against the classification policy through the lib's own accessors, and
# unit-tests the accessors' contracts (routing predicate, registered-universe
# emitter, de-registration pins). Located beside the other lib suites
# (phase1 r3 code-reviewer: it was the one hooks/-dir suite covering a lib,
# so a scoped `bats .claude/tests/_lib/` run missed it).

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

# Registered PostToolUse hooks of $1 as `path<TAB>enforcement(raw)` lines,
# straight off the emitter's records — no per-hook re-parse (phase1 r4,
# three reviewers: the re-parse guard was DEAD — a pipeline swallowed the
# parser's rc, the exact silent shrink the emitter's contract forbids).
# LOUD rc 1 propagates from the emitter on a parse failure.
_classification_required_hooks() {
	local list f event enf
	list=$(event_frontmatter_registered_hooks "$1") || return 1
	# No [ -n ] guard needed (phase1 r8, verified): an empty list feeds one
	# all-empty record, skipped explicitly below (phase2 r1: the r9 domain
	# guard made the required-predicate LOUD on non-events, so the empty
	# record must not reach it); the trailing return 0 normalizes the rc.
	while IFS=$'\t' read -r f event enf; do
		[ -z "$f" ] && continue # empty universe feeds one all-empty record
		event_frontmatter_enforcement_required "$event" && printf '%s\t%s\n' "$f" "$enf"
	done <<<"$list"
	return 0
}

# Discover + guard + filter in one call (phase1 r8 code-simplifier: the
# pipeline was spelled out five times with interchangeable messages).
# $1 = hooks dir, $2 = enforcement value to keep (enforce|inform — the
# closed vocabulary; r9 dropped an unexercised any mode).
# Emits matching paths one per line; rc 1 (already-loud) on discovery
# failure.
_hooks_with_enforcement() {
	local list f enf
	list=$(_classification_required_hooks "$1") || return 1
	while IFS=$'\t' read -r f enf; do
		[ -z "$f" ] && continue
		[ "$enf" = "$2" ] && printf '%s\n' "$f"
	done <<<"$list"
	return 0
}

@test "#2547 every registered live PostToolUse hook is classified enforce or inform" {
	local list f enf missing=""
	list=$(_classification_required_hooks "$HOOKS_DIR") || {
		echo "discovery failed — see parse failure above"
		return 1
	}
	[ -n "$list" ] || {
		echo "SSOT discovery found ZERO registered PostToolUse hooks — parser drift?"
		return 1
	}
	while IFS=$'\t' read -r f enf; do
		event_frontmatter_enforcement_valid "$enf" || missing="$missing ${f##*/}"
	done <<<"$list"
	[ -z "$missing" ] || {
		echo "unclassified (or out-of-vocabulary) PostToolUse hook(s):$missing"
		return 1
	}
}

@test "#2547 every enforce-classified hook routes via a non-comment blocking call" {
	local list f unrouted=""
	list=$(_hooks_with_enforcement "$HOOKS_DIR" enforce) || return 1
	while IFS= read -r f; do
		[ -z "$f" ] && continue
		event_frontmatter_hook_routes "$f" || unrouted="$unrouted ${f##*/}"
	done <<<"$list"
	[ -z "$unrouted" ] || {
		echo "enforce-classified hook(s) with no non-comment blocking call:$unrouted"
		return 1
	}
}

@test "#2547 INVERSE: inform-classified hooks contain NO blocking call (labels cannot lie)" {
	# phase1 r4 pr-test-analyzer (major): the honesty contract was
	# one-directional — a hook_ack_append landing in an inform hook without
	# reclassification would start blocking tool calls while its header
	# still claims advisory, and every test stayed green.
	local list f lying=""
	list=$(_hooks_with_enforcement "$HOOKS_DIR" inform) || return 1
	while IFS= read -r f; do
		[ -z "$f" ] && continue
		if event_frontmatter_hook_routes "$f"; then
			lying="$lying ${f##*/}"
		fi
	done <<<"$list"
	[ -z "$lying" ] || {
		echo "inform-classified hook(s) with a real blocking call — the label lies:$lying"
		return 1
	}
}

@test "#2547 lint-dispatch is pinned as the enforce-classified hook AND stays in the universe" {
	# The one current enforcer, pinned by name: reclassifying it to inform
	# (or deleting the line) must turn this red — that decision belongs in
	# review, not in drift.
	[ "$(event_frontmatter_enforcement "$HOOKS_DIR/lint-dispatch.sh")" = "enforce" ] || {
		echo "lint-dispatch.sh is no longer declared enforcement:enforce"
		return 1
	}
	# MEMBERSHIP too (phase1 r6 pr-test-analyzer, verified empirically): an
	# auto-register:false on lint-dispatch kept this pin green while the
	# routing + inverse audits iterated ZERO enforce subjects — vacuously
	# green. Via the CLASSIFICATION helper, not the raw emitter (phase1 r7
	# code-simplifier: the raw path passed for membership under ANY event,
	# so flipping the event to PreToolUse re-opened the same vacuity).
	local list
	list=$(_classification_required_hooks "$HOOKS_DIR") || {
		echo "universe discovery failed"
		return 1
	}
	[[ $list == *"lint-dispatch.sh"* ]] || {
		echo "lint-dispatch.sh left the classification-required universe — the enforce audits now run on nothing"
		return 1
	}
}

@test "#2547 the de-registered phase1 panel hooks stay opted out (installer must not re-wire)" {
	# phase1 r3 pr-test-analyzer: the #2564 de-registrations were pinned by
	# no test — deleting an auto-register:false line silently re-wires a
	# hook documented as deadlock-broken. By-name pins, same rationale as
	# the lint-dispatch pin above.
	local h _p auto
	for h in phase1-log-pending-gate phase1-post-agent-nudge phase1-launch-completeness-gate phase1-directive-pending-guard; do
		# Capture parse rc BEFORE slicing (phase1 r5, four reviewers: the
		# piped form's guard was dead — sed's rc masked the parser's — so a
		# parse failure misreported as a lost opt-out).
		_p=$(event_frontmatter_parse "$HOOKS_DIR/$h.sh") || {
			echo "parse failed for $h.sh"
			return 1
		}
		{
			read -r _
			read -r _
			read -r auto
		} <<<"$_p"
		[ "$auto" = "false" ] || {
			echo "$h.sh lost its auto-register:false — the installer WILL re-wire the deadlocking panel (see #2564)"
			return 1
		}
	done
}

@test "#2547 event_frontmatter_hook_routes: comment-only mention does NOT count; real calls do" {
	# phase1 r3 pr-test-analyzer (conf 9): the predicate had no negative
	# fixture — losing the non-comment anchor would leave the routing audit
	# vacuously green forever (lint-dispatch's own header mentions
	# hook_ack_append in prose).
	mkdir -p "$TEST_TMP/hooks"
	printf '#!/bin/bash\nset -u\n# this hook mentions hook_ack_append only in prose\nexit 0\n' >"$TEST_TMP/hooks/prose.sh"
	run event_frontmatter_hook_routes "$TEST_TMP/hooks/prose.sh"
	[ "$status" -ne 0 ] || {
		echo "a comment-only mention counted as routing — the vacuous pass is back"
		return 1
	}
	# INDENTED comments too (phase2 r2, dogfooded rc 1 before pinning): a
	# leading tab/space before the # must not defeat the anchor.
	printf '#!/bin/bash\nset -u\n\t# indented hook_ack_append mention\n    # spaced "decision": "block" mention\nexit 0\n' >"$TEST_TMP/hooks/indent.sh"
	run event_frontmatter_hook_routes "$TEST_TMP/hooks/indent.sh"
	[ "$status" -ne 0 ] || {
		echo "an INDENTED comment mention counted as routing"
		return 1
	}
	printf '#!/bin/bash\nset -u\nhook_ack_append "x" "y" "z"\nexit 0\n' >"$TEST_TMP/hooks/real.sh"
	run event_frontmatter_hook_routes "$TEST_TMP/hooks/real.sh"
	[ "$status" -eq 0 ] || {
		echo "a real hook_ack_append call did not count as routing"
		return 1
	}
	cat >"$TEST_TMP/hooks/dec.sh" <<'FIXEOF'
#!/bin/bash
set -u
printf '%s' '{"decision": "block"}'
exit 0
FIXEOF
	run event_frontmatter_hook_routes "$TEST_TMP/hooks/dec.sh"
	[ "$status" -eq 0 ] || {
		echo "a decision:block response did not count as routing"
		return 1
	}
}

@test "#2547 audit honors auto-register:false (registered universe, not file universe)" {
	mkdir -p "$TEST_TMP/hooks"
	printf '#!/bin/bash\nset -u\n# event: PostToolUse\n# auto-register: false\nexit 0\n' >"$TEST_TMP/hooks/optout.sh"
	printf '#!/bin/bash\nset -u\n# event: PostToolUse\n# enforcement: inform — fixture\nexit 0\n' >"$TEST_TMP/hooks/reg.sh"
	local list
	list=$(_classification_required_hooks "$TEST_TMP/hooks") || {
		echo "fixture discovery failed"
		return 1
	}
	[[ $list == *"reg.sh"* ]] || {
		echo "registered fixture missing from the universe: $list"
		return 1
	}
	[[ $list != *"optout.sh"* ]] || {
		echo "auto-register:false hook counted as registered — the universes diverge again"
		return 1
	}
}

@test "#2547 an unreadable hook fails the audit LOUDLY, never a vacuous pass" {
	if [ "$(id -u)" -eq 0 ]; then
		skip "relies on DAC perms, which root (uid 0) bypasses"
	fi
	mkdir -p "$TEST_TMP/hooks"
	printf '#!/bin/bash\nset -u\n# event: PostToolUse\nexit 0\n' >"$TEST_TMP/hooks/dark.sh"
	chmod 000 "$TEST_TMP/hooks/dark.sh"
	run event_frontmatter_registered_hooks "$TEST_TMP/hooks"
	[ "$status" -ne 0 ] || {
		echo "unreadable hook silently dropped from the audited universe (rc=0)"
		return 1
	}
	[[ $output == *"PARSE FAILURE"* ]] || {
		echo "no loud parse-failure diagnostic. output: $output"
		return 1
	}
}

@test "#2547 parse emits the raw enforcement value as line 4 (empty when absent)" {
	mkdir -p "$TEST_TMP/hooks"
	printf '#!/bin/bash\nset -u\n# event: PostToolUse\n# enforcement: advisory — bogus but raw\nexit 0\n' >"$TEST_TMP/hooks/raw.sh"
	local _p line4
	_p=$(event_frontmatter_parse "$TEST_TMP/hooks/raw.sh") || {
		echo "parse failed for raw.sh"
		return 1
	}
	line4=$(sed -n 4p <<<"$_p")
	[ "$line4" = "advisory" ] || {
		echo "raw out-of-vocabulary value not surfaced on parse line 4 (got '$line4')"
		return 1
	}
	run event_frontmatter_enforcement_valid "advisory"
	[ "$status" -ne 0 ]
	run event_frontmatter_enforcement_valid "enforce"
	[ "$status" -eq 0 ]
	printf '#!/bin/bash\nset -u\n# event: PostToolUse\nexit 0\n' >"$TEST_TMP/hooks/none.sh"
	_p=$(event_frontmatter_parse "$TEST_TMP/hooks/none.sh") || {
		echo "parse failed for none.sh"
		return 1
	}
	[ -z "$(sed -n 4p <<<"$_p")" ] || {
		echo "absent directive did not yield an empty line 4"
		return 1
	}
	# The one-call accessor's FAILURE contract (phase1 r5 pr-test-analyzer:
	# only the positive path was pinned — deleting its validity check left
	# every test green while it emitted raw invalid values).
	# EXACT rc 1 (phase1 r9 pr-test-analyzer: -ne 0 let a policy verdict
	# drift onto the rc-2 I/O path with the suite green — the 2566
	# consumers branch on the split).
	run event_frontmatter_enforcement "$TEST_TMP/hooks/raw.sh"
	[ "$status" -eq 1 ] || {
		echo "out-of-vocabulary was not the rc-1 POLICY verdict (got $status): '$output'"
		return 1
	}
	run event_frontmatter_enforcement "$TEST_TMP/hooks/none.sh"
	[ "$status" -eq 1 ] || {
		echo "absent directive was not the rc-1 POLICY verdict (got $status): '$output'"
		return 1
	}
}

@test "#2547 emitter refuses a NONEXISTENT directory loudly (no empty-universe pass)" {
	run event_frontmatter_registered_hooks "$TEST_TMP/definitely/not/here"
	[ "$status" -ne 0 ] || {
		echo "a missing directory read as an empty clean universe (rc=0)"
		return 1
	}
	[[ $output == *"NOT A READABLE DIRECTORY"* ]] || {
		echo "no loud diagnostic for the missing directory. output: $output"
		return 1
	}
}

@test "#2547 emitter refuses an UNREADABLE (perm-denied) directory loudly" {
	if [ "$(id -u)" -eq 0 ]; then
		skip "relies on DAC perms, which root (uid 0) bypasses"
	fi
	# phase1 r7 silent-failure-hunter (verified): chmod-000 on an EXISTING
	# dir still glob-failed straight to rc 0 — the r6 guard caught only the
	# missing-dir half.
	mkdir -p "$TEST_TMP/deniedroot/hooks"
	printf '#!/bin/bash\nset -u\n# event: PostToolUse\nexit 0\n' >"$TEST_TMP/deniedroot/hooks/h.sh"
	chmod 000 "$TEST_TMP/deniedroot/hooks"
	run event_frontmatter_registered_hooks "$TEST_TMP/deniedroot/hooks"
	chmod 755 "$TEST_TMP/deniedroot/hooks"
	[ "$status" -ne 0 ] || {
		echo "a permission-denied directory read as an empty clean universe (rc=0)"
		return 1
	}
	[[ $output == *"NOT A READABLE DIRECTORY"* ]] || {
		echo "no loud diagnostic for the unreadable directory. output: $output"
		return 1
	}
}

@test "#2547 emitter refuses a READ-ONLY (no-search, mode 444) directory loudly" {
	# phase1 r8, code-reviewer + silent-failure-hunter independently
	# (verified): readable-but-unsearchable passed the r7 guard, the glob
	# expanded to real names, every stat failed, and the loop fell through
	# to a clean empty universe. The structural closure is the loud
	# CANNOT-STAT branch; the -x preflight gives the earlier message.
	if [ "$(id -u)" -eq 0 ]; then
		skip "relies on DAC perms, which root (uid 0) bypasses"
	fi
	mkdir -p "$TEST_TMP/rodir/hooks"
	printf '#!/bin/bash\nset -u\n# event: PostToolUse\nexit 0\n' >"$TEST_TMP/rodir/hooks/h.sh"
	chmod 444 "$TEST_TMP/rodir/hooks"
	run event_frontmatter_registered_hooks "$TEST_TMP/rodir/hooks"
	chmod 755 "$TEST_TMP/rodir/hooks"
	[ "$status" -ne 0 ] || {
		echo "a read-only (no-search) directory read as a clean empty universe (rc=0)"
		return 1
	}
	[[ $output == *"NOT A READABLE DIRECTORY"* || $output == *"CANNOT STAT"* ]] || {
		echo "no loud diagnostic for the unsearchable directory. output: $output"
		return 1
	}
}

@test "#2547 a DANGLING *.sh symlink refuses loudly (no silent per-file drop)" {
	# phase1 r8 silent-failure-hunter (verified): a hook deployed as a
	# symlink whose target vanished disappeared from the honesty audits
	# with everything green — the '[ -e ] || continue' sentinel conflated
	# empty-dir with cannot-stat.
	mkdir -p "$TEST_TMP/symdir"
	printf '#!/bin/bash\nset -u\n# event: PostToolUse\n# enforcement: inform — fixture\nexit 0\n' >"$TEST_TMP/symdir/real.sh"
	ln -s "$TEST_TMP/symdir/vanished-target" "$TEST_TMP/symdir/ghost.sh"
	run event_frontmatter_registered_hooks "$TEST_TMP/symdir"
	[ "$status" -ne 0 ] || {
		echo "a dangling symlink was silently dropped from the universe (rc=0). output: $output"
		return 1
	}
	[[ $output == *"CANNOT STAT"* ]] || {
		echo "no loud diagnostic for the dangling symlink. output: $output"
		return 1
	}
}

@test "#2547 accessor parse failure: rc 2 + loud PARSE FAILURE (not a policy verdict)" {
	# phase1 r8, code-reviewer + pr-test-analyzer: the r7 stderr add went
	# unpinned, and rc 1 conflated I/O failure with the two policy
	# verdicts — the repo's lib convention splits them 1-vs-2.
	if [ "$(id -u)" -eq 0 ]; then
		skip "relies on DAC perms, which root (uid 0) bypasses"
	fi
	mkdir -p "$TEST_TMP/hooks"
	printf '#!/bin/bash\nset -u\n# event: PostToolUse\n# enforcement: enforce — x\nexit 0\n' >"$TEST_TMP/hooks/sealed.sh"
	chmod 000 "$TEST_TMP/hooks/sealed.sh"
	run event_frontmatter_enforcement "$TEST_TMP/hooks/sealed.sh"
	[ "$status" -eq 2 ] || {
		echo "parse/I-O failure did not return rc 2 (got $status) — laundered into a policy verdict"
		return 1
	}
	[[ $output == *"PARSE FAILURE"* ]] || {
		echo "no loud diagnostic on the accessor's I/O path. output: $output"
		return 1
	}
}

@test "#2547 an EMPTY readable directory is a benign rc-0 empty universe" {
	# phase1 r9 pr-test-analyzer: only the loud half of the r8 split was
	# pinned — deleting the literal-glob carve-out would make every fresh
	# consumer install (empty hooks dir) refuse loudly with CANNOT STAT
	# while the suite stayed green.
	mkdir -p "$TEST_TMP/emptydir"
	run event_frontmatter_registered_hooks "$TEST_TMP/emptydir"
	[ "$status" -eq 0 ] || {
		echo "an empty readable dir refused (rc=$status) — fresh installs would break. output: $output"
		return 1
	}
	[ -z "$output" ] || {
		echo "an empty dir emitted records: $output"
		return 1
	}
}
