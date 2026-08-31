#!/usr/bin/env bats
# covers: pre-commit-hooks/bats-gate.sh
#
# (#2642) The gate that demands every touched shell file have a test had no
# test. It also could not have had one under its own rule: `pre-commit-hooks/`
# was outside the scope list it carried, so the gate never gated itself.
#
# That is the whole shape of this issue in one file — an enforcement that
# reported coverage it did not perform, and whose own instrument (the same
# path list, copied into scripts/test.sh --coverage) reported a percentage
# over the wrong denominator, so the gap never surfaced as a number.
#
# These tests run the gate against throwaway repos with a real index. They
# never touch the operator's tree.

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	GATE="$REPO_ROOT/pre-commit-hooks/bats-gate.sh"
	[ -x "$GATE" ] || [ -r "$GATE" ]
	WORK=$(mktemp -d -t bats-gate.XXXXXX) || return 1
	(
		set -e
		cd "$WORK"
		git init -q
		git config user.email t@t
		git config user.name t
		mkdir -p .claude/tests .claude/logs hooks scripts _lib pre-commit-hooks
		# The gate no-ops entirely without bats infra; give it the marker.
		: >.claude/tests/.keep
	) || return 1
	# The gate resolves its libs relative to its own path, so it always
	# reads the REAL _lib/. Only the repo it inspects is the fixture.
}

teardown() {
	cd "${TMPDIR:-/tmp}" 2>/dev/null || cd "$HOME" || return 0
	case "${WORK:-}" in
	*/bats-gate.*) rm -rf "$WORK" ;;
	esac
	return 0
}

_stage() { # $1 = path, $2 = content
	mkdir -p "$WORK/$(dirname "$1")"
	printf '%s\n' "$2" >"$WORK/$1"
	git -C "$WORK" add "$1"
}

_run_gate() {
	run bash -c "cd '$WORK' && BATS_GATE_AUTORUN=0 '$GATE'"
}

# ---- the scope regression ------------------------------------------------

@test "#2642: a touched hooks/*.sh is GATED (it was silently allowed)" {
	# The regression, stated as the gate's own behaviour. Before the scope
	# fix, `hooks/` was not in the list, so this committed with no test and
	# no complaint — for 91 files.
	_stage hooks/thing.sh '#!/bin/bash
echo hi'
	_run_gate
	[ "$status" -ne 0 ] || {
		echo "a touched hooks/*.sh with no covering test was ALLOWED: $output"
		return 1
	}
	[[ $output == *thing.sh* ]] || {
		echo "the refusal does not name the file: $output"
		return 1
	}
}

@test "#2642: _lib, pre-commit-hooks and skills are gated too" {
	local d
	for d in _lib pre-commit-hooks skills; do
		rm -rf "${WORK:?}/$d"
		git -C "$WORK" rm -r --cached "$d" -q 2>/dev/null || true
		_stage "$d/thing.sh" '#!/bin/bash
echo hi'
		_run_gate
		[ "$status" -ne 0 ] || {
			echo "$d/thing.sh was allowed with no covering test: $output"
			return 1
		}
		git -C "$WORK" rm -f --cached "$d/thing.sh" -q
		rm -f "$WORK/$d/thing.sh"
	done
}

@test "the gate would now gate ITSELF" {
	# It could not before: pre-commit-hooks/ was out of scope, so the file
	# enforcing the rule was exempt from it. This asserts the exemption is
	# gone, using the real path.
	run bash -c "set -uo pipefail
		. '$REPO_ROOT/_lib/bats-scope.sh'
		bats_in_scope 'pre-commit-hooks/bats-gate.sh'"
	[ "$status" -eq 0 ] || {
		echo "the bats gate is still outside its own scope"
		return 1
	}
}

# ---- the escapes, which must stay escapes --------------------------------

@test "a bats-required-0 header opts a file out" {
	# The one-line per-file escape that makes the widened scope livable.
	_stage hooks/thing.sh '#!/bin/bash
# bats-required: 0
echo hi'
	_run_gate
	[ "$status" -eq 0 ] || {
		echo "the documented opt-out did not opt out: $output"
		return 1
	}
}

@test "the opt-out is found below a long licence block" {
	# The header scan is full-file for exactly this reason; a `head -5`
	# scan used to miss it, which turns a documented escape into a lie.
	local body='#!/bin/bash'
	local i
	for i in $(seq 1 40); do body="$body
# licence line $i"; done
	body="$body
# bats-required: 0
echo hi"
	_stage hooks/thing.sh "$body"
	_run_gate
	[ "$status" -eq 0 ] || {
		echo "the opt-out was missed below a long header: $output"
		return 1
	}
}

@test "TEST_GATE_SKIP requires a REASON, and records it" {
	# A bypass with no recorded reason is an untracked hole. Refuse first.
	_stage hooks/thing.sh '#!/bin/bash
echo hi'
	run bash -c "cd '$WORK' && TEST_GATE_SKIP=1 '$GATE'"
	[ "$status" -eq 2 ] || {
		echo "a reasonless bypass was accepted (rc $status): $output"
		return 1
	}
	run bash -c "cd '$WORK' && TEST_GATE_SKIP=1 TEST_GATE_SKIP_REASON='because' '$GATE'"
	[ "$status" -eq 0 ] || {
		echo "a reasoned bypass was refused: $output"
		return 1
	}
	[ -s "$WORK/.claude/logs/test-gate-skip.jsonl" ] || {
		echo "the bypass was allowed but never logged — an untracked hole"
		return 1
	}
	grep -q 'because' "$WORK/.claude/logs/test-gate-skip.jsonl" || {
		echo "the recorded row does not carry the reason: $(cat "$WORK/.claude/logs/test-gate-skip.jsonl")"
		return 1
	}
}

# ---- out of scope stays out ----------------------------------------------

@test "a file outside the scope dirs is not gated" {
	# The widening must not become "gate everything" — a repo's own
	# unrelated shell has no covering-test obligation from this plugin.
	_stage vendor/thing.sh '#!/bin/bash
echo hi'
	_run_gate
	[ "$status" -eq 0 ] || {
		echo "an out-of-scope file was gated: $output"
		return 1
	}
}

@test "a non-shell file is not gated" {
	_stage hooks/notes.md 'just words'
	_run_gate
	[ "$status" -eq 0 ] || {
		echo "a markdown file was gated: $output"
		return 1
	}
}

@test "nothing staged is a clean no-op" {
	_run_gate
	[ "$status" -eq 0 ]
}

# ---- fail-closed ---------------------------------------------------------

@test "#2642: an unloadable scope library REFUSES rather than gating nothing" {
	# The dangerous default. Without the predicate, the old code path would
	# treat every file as out of scope and pass every commit — the gate
	# switching itself off while reporting success. It must refuse loudly.
	local fake="$WORK/fakegate"
	mkdir -p "$fake/pre-commit-hooks" "$fake/_lib"
	cp "$GATE" "$fake/pre-commit-hooks/bats-gate.sh"
	# Provide the other libs it sources, but NOT bats-scope.sh.
	local l
	for l in hook-ack.sh canonical-consumer-skip.sh; do
		[ -r "$REPO_ROOT/_lib/$l" ] && cp "$REPO_ROOT/_lib/$l" "$fake/_lib/$l"
	done
	_stage hooks/thing.sh '#!/bin/bash
echo hi'
	run bash -c "cd '$WORK' && BATS_GATE_AUTORUN=0 '$fake/pre-commit-hooks/bats-gate.sh'"
	[ "$status" -eq 2 ] || {
		echo "a missing scope library did not refuse (rc $status) — the gate may have passed everything: $output"
		return 1
	}
	[[ $output == *"bats-scope"* ]] || {
		echo "the refusal does not name the missing library: $output"
		return 1
	}
}
