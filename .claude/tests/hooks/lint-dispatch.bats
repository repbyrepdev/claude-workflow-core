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
# Pinned ack-routing sites (5 of 6): shellcheck fail, shfmt auto-fixed,
# shfmt auto-fix-failed, yamllint fail, actionlint fail. The shellcheck-
# CRASH arm needs an input that crashes the linter itself and is exercised
# only in production (phase1 r1 pr-test-analyzer + comment-analyzer: say
# exactly what is pinned, or restart the rot cycle).

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/lint-dispatch.sh"
	[ -f "$HOOK" ]
	command -v jq >/dev/null
	# Fail closed, not skip-as-pass: a skipped test counts as a bats pass,
	# which would silently neuter this routing contract on a box without
	# the linters (same rule as the prove-yourself covers_count test).
	local t
	for t in shellcheck shfmt yamllint actionlint; do
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

# Sentinel line format is <ts>\t<hook>\t<reason>\t<file> — assert the hook
# AND the specific reason so a wrong-reason append cannot pass.
_sentinel_has() { grep -qE "	lint-dispatch\.$1	$2	" "$SENTINEL"; }

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
	_sentinel_has shellcheck "fail-2-issues" || {
		echo "sentinel lacks lint-dispatch.shellcheck fail-2-issues. sentinel: $(cat "$SENTINEL")"
		return 1
	}
}

@test "#2547 clean shell file: exit 0, NO sentinel entry (informers must not block)" {
	printf '#!/bin/bash\nset -u\necho ok\n' >"$ROOT/good.sh"
	run env HOOK_ACK_BATS_SKIP=0 bash "$HOOK" <<<"$(_payload "$ROOT/good.sh")"
	[ "$status" -eq 0 ] || {
		echo "clean file exited $status. output: $output"
		return 1
	}
	if [ -s "$SENTINEL" ]; then
		echo "a CLEAN file produced an ack entry — enforcement noise. sentinel: $(cat "$SENTINEL")"
		return 1
	fi
}

@test "#2547 shfmt drift: auto-fixed ON DISK + auto-fixed sentinel reason" {
	printf '#!/bin/bash\nset -u\nif true; then\n        echo hi\nfi\n' >"$ROOT/fmt.sh"
	run env HOOK_ACK_BATS_SKIP=0 bash "$HOOK" <<<"$(_payload "$ROOT/fmt.sh")"
	[ "$status" -eq 0 ] || {
		echo "auto-fix path exited $status. output: $output"
		return 1
	}
	# Disk state, not just exit code (phase1 r1 pr-test-analyzer: a silent
	# shfmt -w no-op with the sentinel intact would otherwise pass).
	run shfmt -d "$ROOT/fmt.sh"
	[ -z "$output" ] || {
		echo "file still has shfmt drift after the auto-fix path: $output"
		return 1
	}
	_sentinel_has shfmt "auto-fixed" || {
		echo "sentinel lacks the auto-fixed reason specifically. sentinel: $(cat "$SENTINEL" 2>/dev/null)"
		return 1
	}
}

@test "#2547 shfmt -w failure falls back to auto-fix-failed + exit 1" {
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
	_sentinel_has shfmt "auto-fix-failed" || {
		echo "sentinel lacks the auto-fix-failed reason. sentinel: $(cat "$SENTINEL" 2>/dev/null)"
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
	grep -qE "	lint-dispatch\.yamllint	fail-[0-9]+-issues	" "$SENTINEL" || {
		echo "sentinel lacks the yamllint fail entry. sentinel: $(cat "$SENTINEL" 2>/dev/null)"
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
	grep -qE "	lint-dispatch\.actionlint	fail-[0-9]+-issues	" "$SENTINEL" || {
		echo "sentinel lacks the actionlint fail entry. sentinel: $(cat "$SENTINEL" 2>/dev/null)"
		return 1
	}
}
