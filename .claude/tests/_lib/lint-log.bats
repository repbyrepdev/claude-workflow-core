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

@test "fail verdict round-trips with detail on stderr" {
	# shellcheck source=/dev/null
	source "$LIB"
	(
		cd "$TEST_TMP" || exit 1
		echo 'bad' >f.sh
		lint_log_append f.sh shellcheck fail 3 "SC1000 example"
		run lint_log_verdict f.sh shellcheck
		[ "$output" = fail ] || [[ $output == *fail* ]]
		[ "$status" -eq 1 ]
	)
}
