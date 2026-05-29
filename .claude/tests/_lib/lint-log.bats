#!/usr/bin/env bats
# covers: _lib/lint-log.sh

# v0.30.G (#194): round-trip + field-name lock for the lint-run.jsonl helpers.
# The hash field is `content_hash` (sha256 of FILE CONTENT), renamed from the
# misleading `sha` so it isn't conflated with commit-sha logs. These tests
# assert the append/verdict round-trip works AND that the on-disk field is
# `content_hash`, not `sha`.

setup() {
	LIB="${BATS_TEST_DIRNAME}/../../../_lib/lint-log.sh"
	[ -f "$LIB" ]
	command -v jq >/dev/null
	# Need a sha256 tool for the round-trip; skip if neither present.
	command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || skip "no sha256 tool"
	TEST_TMP=$(mktemp -d -t lint-log.XXXXXX)
	# lint_log_append resolves repo root via git; init one so the log lands
	# under $TEST_TMP/.claude/logs/.
	(cd "$TEST_TMP" && git init -q && git config user.email t@t.t && git config user.name t)
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"
	return 0
}

@test "append then verdict returns pass for unchanged content" {
	# shellcheck source=/dev/null
	source "$LIB"
	(
		cd "$TEST_TMP" || exit 1
		echo 'echo hi' >f.sh
		lint_log_append f.sh shellcheck pass 0 "clean"
		v=$(lint_log_verdict f.sh shellcheck)
		[ "$v" = pass ]
	)
}

@test "on-disk field is content_hash, NOT sha (#194 rename lock)" {
	# shellcheck source=/dev/null
	source "$LIB"
	(
		cd "$TEST_TMP" || exit 1
		echo 'echo hi' >f.sh
		lint_log_append f.sh shellcheck pass 0 "clean"
		entry=$(tail -1 .claude/logs/lint-run.jsonl)
		# content_hash present + 64-char sha256; legacy `sha` key absent.
		ch=$(printf '%s' "$entry" | jq -r '.content_hash')
		[ "${#ch}" -eq 64 ]
		[ "$(printf '%s' "$entry" | jq -r 'has("sha")')" = false ]
	)
}

@test "verdict is unknown after content changes (hash mismatch)" {
	# shellcheck source=/dev/null
	source "$LIB"
	(
		cd "$TEST_TMP" || exit 1
		echo 'echo hi' >f.sh
		lint_log_append f.sh shellcheck pass 0 "clean"
		echo 'echo changed' >f.sh # content hash now differs
		run lint_log_verdict f.sh shellcheck
		[ "$output" = unknown ]
		[ "$status" -eq 2 ]
	)
}

@test "verdict is unknown for a file with no log entry" {
	# shellcheck source=/dev/null
	source "$LIB"
	(
		cd "$TEST_TMP" || exit 1
		echo 'x' >never-linted.sh
		run lint_log_verdict never-linted.sh shellcheck
		[ "$output" = unknown ]
		[ "$status" -eq 2 ]
	)
}

@test "mixed log: legacy sha-keyed entry ignored; new content_hash wins (#194 transition)" {
	# The exact transition scenario from the rename: a log with BOTH a legacy
	# `sha`-keyed entry AND a new `content_hash` entry. The legacy entry (even
	# at a matching hash value) must be IGNORED (verdict keys on content_hash),
	# so a stale legacy `fail` can never override a fresh `content_hash` pass.
	# Guards against a "backward-compat" refactor that re-matches `.sha`.
	# shellcheck source=/dev/null
	source "$LIB"
	(
		cd "$TEST_TMP" || exit 1
		echo 'echo hi' >f.sh
		h=$(lint_sha256_file f.sh)
		mkdir -p .claude/logs
		# Legacy entry: same hash value but under the OLD `sha` key, status fail.
		printf '{"ts":"2020-01-01T00:00:00Z","sha":"%s","file":"f.sh","linter":"shellcheck","status":"fail","issues":9,"detail":"legacy"}\n' "$h" >.claude/logs/lint-run.jsonl
		# Legacy-only → verdict must be unknown (NOT fail — the old key is ignored).
		run lint_log_verdict f.sh shellcheck
		[ "$output" = unknown ]
		[ "$status" -eq 2 ]
		# Now append a fresh content_hash PASS; mixed log → pass must win.
		lint_log_append f.sh shellcheck pass 0 "fresh"
		v=$(lint_log_verdict f.sh shellcheck)
		[ "$v" = pass ]
	)
}

@test "multi-linter: verdict selects the right linter (no cross-linter bleed)" {
	# file + content_hash match but a DIFFERENT linter must not satisfy the
	# query — guards the .linter clause in the verdict selector.
	# shellcheck source=/dev/null
	source "$LIB"
	(
		cd "$TEST_TMP" || exit 1
		echo 'echo hi' >f.sh
		lint_log_append f.sh shellcheck pass 0 "sc clean"
		lint_log_append f.sh shfmt fail 2 "shfmt diff"
		# assign-then-test (avoid inline $() under set -e) — shellcheck=pass.
		sc=$(lint_log_verdict f.sh shellcheck) || true
		[ "$sc" = pass ]
		# shfmt entry is fail → verdict fail/1 (different linter, not bled).
		sf=$(lint_log_verdict f.sh shfmt) || true
		[ "$sf" = fail ]
	)
}

@test "fail verdict round-trips with detail on stderr" {
	# shellcheck source=/dev/null
	source "$LIB"
	(
		cd "$TEST_TMP" || exit 1
		echo 'bad' >f.sh
		lint_log_append f.sh shellcheck fail 3 "SC1000 example"
		# --separate-stderr so $output is stdout (the 'fail' verdict) and
		# $stderr is the detail line. Keeps the explicit status/output
		# assertions AND additionally asserts the detail text round-trips
		# (CR #202: previously only 'fail' + rc were checked, so a dropped
		# detail would have passed silently).
		run --separate-stderr lint_log_verdict f.sh shellcheck
		[ "$status" -eq 1 ]
		[ "$output" = fail ]
		# shellcheck disable=SC2154  # $stderr is set by bats `run --separate-stderr`
		[[ $stderr == *"SC1000 example"* ]]
	)
}
