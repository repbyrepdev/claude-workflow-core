#!/usr/bin/env bats
# covers: hooks/lint-dispatch.sh
#
# #2547: the dispatcher's header claimed "bats lint-dispatch.bats covers each
# branch" for 20+ versions (since v0.5.0) while NO such file existed —
# comment rot hiding a real gap. These tests drive the REAL hook end-to-end
# (stdin payload, the real linters, tmp-repo cwd so lint-log + the ack
# sentinel land in the fixture) and pin the #2547 acceptance behavior
# empirically dogfooded on 2026-08-24: a lint failure on a just-edited file
# must append to the universal hook-ack sentinel (HOOK_ACK_BATS_SKIP=0
# forces the write under bats), which is what blocks the NEXT tool call at
# the point of violation instead of surfacing at commit time.
#
# Pinned ack-routing sites (6 of 6, #2574): shellcheck fail, shellcheck
# CRASH (stubbed linter — a real crasher input is linter-version-dependent,
# so the stub emitting the Haskell-exception shape is the stable fixture),
# shfmt auto-fixed, shfmt auto-fix-failed, yamllint fail, actionlint fail.
# (phase1 r1 pr-test-analyzer + comment-analyzer: say exactly what is
# pinned, or restart the rot cycle.)

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/lint-dispatch.sh"
	[ -f "$HOOK" ]
	# Fail closed, not skip-as-pass: a skipped test counts as a bats pass,
	# which would silently neuter this routing contract on a box without
	# the linters (same rule as the prove-yourself covers_count test).
	local t
	for t in jq shellcheck shfmt yamllint actionlint; do
		command -v "$t" >/dev/null || {
			echo "$t required for the lint-dispatch routing contract" >&2
			return 1
		}
	done
	TEST_TMP=$(mktemp -d -t lintdisp.XXXXXX) || return 1
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
	) || return 1
	ROOT=$(cd "$TEST_TMP" && git rev-parse --show-toplevel)
	SENTINEL="$ROOT/.claude/.session-state/hook-output-pending.txt"
	cd "$TEST_TMP" || return 1
}

teardown() {
	cd /tmp 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */lintdisp.* ]]; then
		chmod -R u+w "$TEST_TMP" 2>/dev/null || true
		rm -rf "$TEST_TMP"
	fi
}

_payload() { printf '{"tool_input":{"file_path":"%s"}}' "$1"; }

# Sentinel line format is <ts>\t<hook>\t<reason>\t<file> — assert hook,
# reason AND the file path: hook-ack-clear.sh clears by matching that 4th
# field against the Read file, so a garbage path means an uncleanable stuck
# sentinel (phase1 r3 pr-test-analyzer). $3 = expected file path.
_sentinel_has() { grep -qE "	lint-dispatch\.$1	$2	$3$" "$SENTINEL"; }

# Clean-path passthrough contract (phase1 r8 code-simplifier: five tests
# carried byte-identical bodies): run the hook on payload $1, expect exit 0
# and an EMPTY sentinel. $2 names the scenario in failure output. Each
# caller keeps its own @test name, so branches stay independently reported.
_expect_clean_passthrough() {
	run env HOOK_ACK_BATS_SKIP=0 bash "$HOOK" <<<"$1"
	[ "$status" -eq 0 ] || {
		echo "$2 exited $status. output: $output"
		return 1
	}
	if [ -s "$SENTINEL" ]; then
		echo "$2 produced an ack entry. sentinel: $(cat "$SENTINEL")"
		return 1
	fi
	# CR-in-CI on #2576: content too — a clean path emitting diagnostics is
	# noise the operator reads as a problem.
	[ -z "$output" ] || {
		echo "$2 emitted output on a clean path: $output"
		return 1
	}
}

@test "#2547 shellcheck failure appends to the hook-ack sentinel (blocks next call)" {
	# SC2164 (cd without || exit) is warning-level — survives -S warning.
	printf '#!/bin/bash\nset -u\ncd /tmp/nope\necho "$undefined_sc2154"\n' >"$ROOT/bad.sh"
	run env HOOK_ACK_BATS_SKIP=0 bash "$HOOK" <<<"$(_payload "$ROOT/bad.sh")"
	[ "$status" -eq 1 ] || {
		echo "shellcheck failure did not exit 1 (got $status). output: $output"
		return 1
	}
	[ -s "$SENTINEL" ] || {
		echo "no sentinel entry — the failure would scroll past (the exact #2547 regression)"
		return 1
	}
	_sentinel_has shellcheck "fail-[0-9]+-issues" "$ROOT/bad.sh" || {
		echo "sentinel lacks the lint-dispatch.shellcheck fail entry. sentinel: $(cat "$SENTINEL")"
		return 1
	}
	# CR-in-CI on #2576: assert the operator-facing CONTENT — suppressed
	# diagnostics previously passed.
	[[ $output == *"ShellCheck:"* ]] || {
		echo "shellcheck diagnostics missing from output: $output"
		return 1
	}
	[[ $output == *"Fix now, same-turn"* ]] || {
		echo "the advisory context line is missing: $output"
		return 1
	}
}

@test "#2547 clean shell file: exit 0, NO sentinel entry (informers must not block)" {
	printf '#!/bin/bash\nset -u\necho ok\n' >"$ROOT/good.sh"
	_expect_clean_passthrough "$(_payload "$ROOT/good.sh")" "clean shell file"
}

@test "#2547 shfmt drift: auto-fixed ON DISK + auto-fixed sentinel reason" {
	printf '#!/bin/bash\nset -u\nif true; then\n        echo hi\nfi\n' >"$ROOT/fmt.sh"
	run env HOOK_ACK_BATS_SKIP=0 bash "$HOOK" <<<"$(_payload "$ROOT/fmt.sh")"
	[ "$status" -eq 0 ] || {
		echo "auto-fix path exited $status. output: $output"
		return 1
	}
	# Content BEFORE the disk-state run below clobbers $output (CR-in-CI
	# on #2576 + the first draft of this assertion placed after it read an
	# empty, already-clobbered $output).
	[[ $output == *"auto-fixed formatting"* ]] || {
		echo "the auto-fix announcement is missing: $output"
		return 1
	}
	# Disk state, not just exit code (phase1 r1 pr-test-analyzer: a silent
	# shfmt -w no-op with the sentinel intact would otherwise pass).
	run shfmt -d "$ROOT/fmt.sh"
	[ -z "$output" ] || {
		echo "file still has shfmt drift after the auto-fix path: $output"
		return 1
	}
	_sentinel_has shfmt "auto-fixed" "$ROOT/fmt.sh" || {
		echo "sentinel lacks the auto-fixed reason specifically. sentinel: $(cat "$SENTINEL" 2>/dev/null)"
		return 1
	}
}

@test "#2547 shfmt -w failure falls back to auto-fix-failed + exit 1" {
	if [ "$(id -u)" -eq 0 ]; then
		skip "relies on DAC perms, which root (uid 0) bypasses"
	fi
	# shfmt -w replaces via rename, so blocking the DIRECTORY (not the
	# file) is what makes -w fail while -d still reads the drift.
	mkdir -p "$ROOT/rodir"
	printf '#!/bin/bash\nset -u\nif true; then\n        echo hi\nfi\n' >"$ROOT/rodir/ro.sh"
	chmod 555 "$ROOT/rodir"
	run env HOOK_ACK_BATS_SKIP=0 bash "$HOOK" <<<"$(_payload "$ROOT/rodir/ro.sh")"
	[ "$status" -eq 1 ] || {
		echo "auto-fix-failed path did not exit 1 (got $status). output: $output"
		return 1
	}
	_sentinel_has shfmt "auto-fix-failed" "$ROOT/rodir/ro.sh" || {
		echo "sentinel lacks the auto-fix-failed reason. sentinel: $(cat "$SENTINEL" 2>/dev/null)"
		return 1
	}
	[[ $output == *"auto-fix failed"* ]] || {
		echo "the auto-fix-failed diagnostic is missing: $output"
		return 1
	}
}

@test "#2547 yamllint failure appends to the sentinel + propagates the lint exit" {
	printf 'key: [unclosed\n' >"$ROOT/bad.yml"
	run env HOOK_ACK_BATS_SKIP=0 bash "$HOOK" <<<"$(_payload "$ROOT/bad.yml")"
	[ "$status" -ne 0 ] || {
		echo "yamllint failure exited 0. output: $output"
		return 1
	}
	_sentinel_has yamllint 'fail-[0-9]+-issues' "$ROOT/bad.yml" || {
		echo "sentinel lacks the yamllint fail entry. sentinel: $(cat "$SENTINEL" 2>/dev/null)"
		return 1
	}
	[[ $output == *"syntax"* || $output == *"error"* ]] || {
		echo "yamllint diagnostics missing from output: $output"
		return 1
	}
}

@test "#2547 actionlint failure appends to the sentinel + exit 1" {
	mkdir -p "$ROOT/.github/workflows"
	printf 'on: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n        with:\n          nope: ${{ github.event.bogus\n' >"$ROOT/.github/workflows/bad.yml"
	run env HOOK_ACK_BATS_SKIP=0 bash "$HOOK" <<<"$(_payload "$ROOT/.github/workflows/bad.yml")"
	[ "$status" -eq 1 ] || {
		echo "actionlint failure did not exit 1 (got $status). output: $output"
		return 1
	}
	_sentinel_has actionlint 'fail-[0-9]+-issues' "$ROOT/.github/workflows/bad.yml" || {
		echo "sentinel lacks the actionlint fail entry. sentinel: $(cat "$SENTINEL" 2>/dev/null)"
		return 1
	}
	[[ $output == *"bad.yml:"* ]] || {
		echo "actionlint diagnostics missing from output: $output"
		return 1
	}
}

@test "#2547 clean yaml file: exit 0, NO sentinel entry" {
	# phase1 r5 pr-test-analyzer: the enforcement-noise inverse was pinned
	# only for the *.sh branch — a stray append or exit-1 landing in the
	# yamllint PASS arm would block the operator's next call with every
	# test green.
	printf 'key: value\n' >"$ROOT/good.yml"
	_expect_clean_passthrough "$(_payload "$ROOT/good.yml")" "clean yaml"
}

@test "#2547 clean workflow file: exit 0, NO sentinel entry" {
	mkdir -p "$ROOT/.github/workflows"
	printf 'on: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n' >"$ROOT/.github/workflows/good.yml"
	_expect_clean_passthrough "$(_payload "$ROOT/.github/workflows/good.yml")" "clean workflow"
}

@test "#2547 non-lintable extension passes through: exit 0, NO sentinel" {
	# phase1 r6 pr-test-analyzer: the dispatcher's highest-frequency
	# production path (a .md/.json/.py edit falling through the case) had
	# no inverse — a hoisted exit 1 or broken fall-through would block
	# every non-lintable Edit/Write with the suite green.
	printf 'notes\n' >"$ROOT/notes.md"
	_expect_clean_passthrough "$(_payload "$ROOT/notes.md")" "non-lintable file"
}

@test "#2547 payload without file_path passes through: exit 0, NO sentinel" {
	_expect_clean_passthrough '{}' "empty payload"
}

@test "#2574 shellcheck CRASH routes crashed-upstream-bug: skip-not-fail + sentinel" {
	# The 6th and last ack-routing site. A real crasher input is
	# linter-version-dependent (Haskell exception in checkCmd), so
	# the linter is STUBBED to emit the crash shape — explicitly allowed
	# by the issue. Stub lives in a prepended PATH dir; shfmt/jq stay real.
	mkdir -p "$TEST_TMP/stub"
	printf '#!/bin/bash\necho "shellcheck: Non-exhaustive patterns in checkCmd"\nexit 2\n' >"$TEST_TMP/stub/shellcheck"
	chmod +x "$TEST_TMP/stub/shellcheck"
	printf '#!/bin/bash\nset -u\necho ok\n' >"$ROOT/crash.sh"
	run env HOOK_ACK_BATS_SKIP=0 PATH="$TEST_TMP/stub:$PATH" bash "$HOOK" <<<"$(_payload "$ROOT/crash.sh")"
	# Crash = LINTER broken, not code broken: must NOT block the commit...
	[ "$status" -eq 0 ] || {
		echo "crash arm blocked (rc=$status). output: $output"
		return 1
	}
	# ...but must be VISIBLE: breadcrumb naming the actual exception...
	[[ $output == *"CRASHED"* ]] || {
		echo "no crash breadcrumb. output: $output"
		return 1
	}
	[[ $output == *"Non-exhaustive patterns"* ]] || {
		echo "breadcrumb lacks the exception text. output: $output"
		return 1
	}
	# ...the sentinel reason names the not-fixable-in-code cause...
	_sentinel_has shellcheck "crashed-upstream-bug" "$ROOT/crash.sh" || {
		echo "sentinel: $(cat "$SENTINEL" 2>/dev/null)"
		return 1
	}
	# ...and the lint log records skip (linter broken), never fail.
	grep -q '"linter":"shellcheck","status":"skip"' "$ROOT/.claude/logs/lint-run.jsonl" || {
		echo "log: $(cat "$ROOT/.claude/logs/lint-run.jsonl" 2>/dev/null)"
		return 1
	}
}
