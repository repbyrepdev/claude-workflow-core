#!/usr/bin/env bats
# covers: hooks/lint-dispatch.sh
#
# #2547: the dispatcher's header claimed "bats lint-dispatch.bats covers each
# branch" for 20+ versions while NO such file existed — comment rot hiding a
# real gap. These tests drive the REAL hook end-to-end (stdin payload, the
# real linters, tmp-repo cwd so lint-log + the ack sentinel land in the
# fixture) and pin the #2547 acceptance behavior empirically dogfooded on
# 2026-08-24: a shellcheck failure on an edited file must append to the
# universal hook-ack sentinel (HOOK_ACK_BATS_SKIP=0 forces the write under
# bats), which is what blocks the NEXT tool call at the point of violation
# instead of surfacing at commit time.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/lint-dispatch.sh"
	[ -f "$HOOK" ]
	command -v jq >/dev/null
	# Fail closed, not skip-as-pass: a skipped test counts as a bats pass,
	# which would silently neuter this routing contract on a box without
	# the linters (same rule as the prove-yourself covers_count test).
	command -v shellcheck >/dev/null || {
		echo "shellcheck required for the lint-dispatch routing contract" >&2
		return 1
	}
	command -v shfmt >/dev/null || {
		echo "shfmt required for the lint-dispatch routing contract" >&2
		return 1
	}
	TEST_TMP=$(mktemp -d -t lintdisp.XXXXXX) || return 1
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
	) || return 1
	ROOT=$(cd "$TEST_TMP" && git rev-parse --show-toplevel)
	SENTINEL="$ROOT/.claude/.session-state/hook-output-pending.txt"
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */lintdisp.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_payload() { printf '{"tool_input":{"file_path":"%s"}}' "$1"; }

@test "#2547 shellcheck failure appends to the hook-ack sentinel (blocks next call)" {
	# SC2164 (cd without || exit) is warning-level — survives -S warning.
	printf '#!/bin/bash\nset -u\ncd /tmp/nope\necho "$undefined_sc2154"\n' >"$ROOT/bad.sh"
	cd "$TEST_TMP" || return 1
	run bash -c "HOOK_ACK_BATS_SKIP=0 bash '$HOOK' <<<'$(_payload "$ROOT/bad.sh")'"
	[ "$status" -eq 1 ] || {
		echo "shellcheck failure did not exit 1 (got $status). output: $output"
		return 1
	}
	[ -s "$SENTINEL" ] || {
		echo "no sentinel entry — the failure would scroll past (the exact #2547 regression)"
		return 1
	}
	run grep -c "lint-dispatch.shellcheck" "$SENTINEL"
	[ "$output" = "1" ] || {
		echo "sentinel lacks the lint-dispatch.shellcheck entry. sentinel: $(cat "$SENTINEL")"
		return 1
	}
}

@test "#2547 clean shell file: exit 0, NO sentinel entry (informers must not block)" {
	printf '#!/bin/bash\nset -u\necho ok\n' >"$ROOT/good.sh"
	cd "$TEST_TMP" || return 1
	run bash -c "HOOK_ACK_BATS_SKIP=0 bash '$HOOK' <<<'$(_payload "$ROOT/good.sh")'"
	[ "$status" -eq 0 ] || {
		echo "clean file exited $status. output: $output"
		return 1
	}
	if [ -s "$SENTINEL" ]; then
		echo "a CLEAN file produced an ack entry — enforcement noise. sentinel: $(cat "$SENTINEL")"
		return 1
	fi
}

@test "#2547 shfmt drift: auto-fixed on disk + sentinel entry (file changed under operator)" {
	# Tab-indent expected by shfmt config? Use spaces-after-keyword drift
	# that shfmt -w normalizes regardless of style flags: '  echo' inside if.
	printf '#!/bin/bash\nset -u\nif true; then\n        echo hi\nfi\n' >"$ROOT/fmt.sh"
	cd "$TEST_TMP" || return 1
	run bash -c "HOOK_ACK_BATS_SKIP=0 bash '$HOOK' <<<'$(_payload "$ROOT/fmt.sh")'"
	# shfmt drift alone (shellcheck clean) auto-fixes and exits 0.
	[ "$status" -eq 0 ] || {
		echo "auto-fix path exited $status. output: $output"
		return 1
	}
	run grep -c "lint-dispatch.shfmt" "$SENTINEL"
	[ "$output" = "1" ] || {
		echo "auto-fix did not append the shfmt ack (file changed under the operator unnoticed). sentinel: $(cat "$SENTINEL" 2>/dev/null)"
		return 1
	}
}
