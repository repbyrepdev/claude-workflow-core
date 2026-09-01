#!/usr/bin/env bats
# covers: hooks/test-sh-scope-nudge.sh
#
# (#2640) This hook had NO tests, and it was advertising a flag that does
# not exist: its refusal text said "For full: scripts/test.sh --full", and
# its allow-arm passed `--full` through to a test.sh that answers "error:
# unknown flag '--full'". An operator who followed the instruction got a
# hard error and no full-suite run. That is the epic's exact shape — a
# gate whose message describes behaviour the system does not have.
#
# The load-bearing assertion here is the LAST one: the flags the refusal
# advertises are checked against the flags scripts/test.sh actually parses,
# so this class of drift fails a test instead of an operator.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
	HOOK="$REPO_ROOT/hooks/test-sh-scope-nudge.sh"
	[ -x "$HOOK" ] || skip "hook not executable at $HOOK"
}

# The hook is a PreToolUse hook: it reads a JSON payload on stdin and, when
# it blocks, emits deny-JSON on stdout (exit 0). It ALSO mirrors the same
# text to stderr for operator-grep, and bats' `run` merges the two streams —
# so stderr is dropped here, otherwise every `jq` below parses JSON with
# prose stapled to it.
#
# `env -u TEST_SH_FULL_OK` is load-bearing, not tidiness. The hook honours
# that variable from the ENVIRONMENT (line 49), and the full suite is itself
# launched as `TEST_SH_FULL_OK=1 scripts/test.sh` — so these tests inherited
# the very bypass they exist to check. Every blocking assertion passed alone
# and went green-on-nothing inside the suite, with the hook emitting no
# output at all. A test whose subject is a gate must own the gate's
# environment rather than inherit it.
_run_hook() {
	local cmd="$1"
	run env -u TEST_SH_FULL_OK bash -c "printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$cmd" | jq -Rs .)}}' | '$HOOK' 2>/dev/null"
}

_is_denied() {
	printf '%s' "$1" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1
}

# `! _is_denied` on its own is satisfied by ANY non-deny output — including
# the hook crashing and printing a stack trace, or printing nothing because
# it died. An "allowed through" claim therefore needs the exit status too:
# the hook must have RUN and SUCCEEDED, not merely failed to say deny.
_assert_allowed() {
	[ "$status" -eq 0 ] || {
		echo "the hook exited $status; 'allowed through' must mean it ran cleanly: $output"
		return 1
	}
	! _is_denied "$output" || {
		echo "expected the command to be allowed, but the hook denied it: $output"
		return 1
	}
}

@test "bare scripts/test.sh is refused" {
	_run_hook "scripts/test.sh"
	_is_denied "$output" || {
		echo "a bare full-suite run was NOT blocked — the hook's whole job: $output"
		return 1
	}
}

@test "a specific .bats path is allowed through" {
	_run_hook "scripts/test.sh .claude/tests/hooks/test-sh-scope-nudge.bats"
	_assert_allowed
}

@test "TEST_SH_FULL_OK=1 is allowed through (written in the command)" {
	_run_hook "TEST_SH_FULL_OK=1 scripts/test.sh"
	_assert_allowed
}

@test "TEST_SH_FULL_OK=1 is allowed through (inherited from the environment)" {
	# The hook honours this from the environment as well as from the command
	# text, and the two paths are separate code (line 49 vs the command-text
	# grep). Only the command-text one had a test, and the env one is what
	# the full suite actually uses — so the untested path was the one every
	# suite run depends on.
	run env TEST_SH_FULL_OK=1 bash -c "printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"scripts/test.sh\"}}' | '$HOOK' 2>/dev/null"
	_assert_allowed
	[ -z "$output" ] || {
		echo "expected the hook to stay silent when opted in; got: $output"
		return 1
	}
}

@test "#2640: --full is NOT advertised, because test.sh rejects it" {
	# The old text said "For full: scripts/test.sh --full". Following it
	# produced "error: unknown flag '--full'" and ran nothing.
	_run_hook "scripts/test.sh"
	local reason
	reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')
	[[ $reason != *"--full"* ]] || {
		echo "the refusal still advertises --full, which test.sh does not accept: $reason"
		return 1
	}
}

@test "#2640: the refusal names TEST_SH_FULL_OK as the full-suite route" {
	# Removing --full is only half the fix; the operator still needs to be
	# told what DOES work, or the message is merely less wrong.
	_run_hook "scripts/test.sh"
	local reason
	reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')
	[[ $reason == *"TEST_SH_FULL_OK=1 scripts/test.sh"* ]] || {
		echo "the refusal does not give a working full-suite command: $reason"
		return 1
	}
}

@test "#2640: every flag the refusal advertises is one test.sh parses" {
	# THE LOAD-BEARING TEST. Extract the long flags named in the refusal
	# text and confirm each has a real parser arm in scripts/test.sh. This
	# is what makes the fix durable rather than a one-time correction: the
	# next person to invent a flag in the help gets a red test.
	_run_hook "scripts/test.sh"
	local reason
	reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')

	local advertised
	advertised=$(printf '%s' "$reason" | grep -oE -- '--[a-z][a-z-]*' | sort -u)
	[ -n "$advertised" ] || {
		echo "no flags found in the refusal text — the extraction is broken, so this test would pass vacuously"
		return 1
	}

	local f missing=""
	for f in $advertised; do
		# A real arm looks like `	--coverage)` in the case statement.
		grep -qE "^[[:space:]]*(\*\|)?${f}\)" "$REPO_ROOT/scripts/test.sh" || missing="$missing $f"
	done
	[ -z "$missing" ] || {
		echo "the refusal advertises flags scripts/test.sh does not parse:$missing"
		echo "--- refusal text ---"
		echo "$reason"
		return 1
	}
}

@test "#2640: an unknown flag passes the gate and is refused by test.sh" {
	# DELIBERATE, pinned so nobody "fixes" it into a maintenance trap.
	#
	# The catch-all arm `"scripts/test.sh -"*` lets any dash-argument
	# through. `--full` therefore still reaches test.sh — which is fine,
	# and better than the alternative: a strict allow-list here would mean
	# every genuinely new flag added to test.sh is blocked by this hook
	# until someone remembers to update it, turning a nudge into an
	# obstacle.
	#
	# The gate's job is to stop a BARE full-suite run. `--full` is not a
	# run at all: test.sh rejects it immediately and executes no tests, so
	# nothing this hook exists to prevent can happen. The bug worth fixing
	# was the hook ADVERTISING the flag, which the tests above cover.
	_run_hook "scripts/test.sh --full"
	_assert_allowed
	# And the other half of the claim: test.sh really does refuse it, so
	# the operator gets a clear error rather than a silent no-op.
	run "$REPO_ROOT/scripts/test.sh" --full
	[ "$status" -ne 0 ] || {
		echo "test.sh accepted --full, so the reasoning above is now wrong: $output"
		return 1
	}
	[[ $output == *"unknown flag"* ]] || {
		echo "test.sh refused --full without saying why: $output"
		return 1
	}
}

@test "#2640: --full after a path is BLOCKED, unlike the real flags" {
	# This is where dropping `--full` from the named allow-arm actually
	# bites. The catch-all `scripts/test.sh -`* only matches a dash
	# IMMEDIATELY after the script, so `scripts/test.sh foo --full` misses
	# it and falls to the named list. While `--full` sat in that list it was
	# waved through as a deliberate opt-in; it is not one, because test.sh
	# cannot parse it.
	#
	# Without this test the allow-arm edit had no coverage at all: a
	# reviewer restored `--full` to the list and every other test stayed
	# green.
	_run_hook "scripts/test.sh somedir --full"
	_is_denied "$output" || {
		echo "--full after a path was treated as a valid opt-in: $output"
		return 1
	}
}

@test "#2640: the real flags ARE still honoured after a path" {
	# The control. The named arms exist precisely for flags that follow a
	# path, so blocking --full must not have broken --no-log or --baseline.
	local f
	for f in --no-log --baseline --coverage; do
		_run_hook "scripts/test.sh somedir $f"
		! _is_denied "$output" || {
			echo "$f after a path was blocked, but it is a flag test.sh really parses: $output"
			return 1
		}
	done
}
