#!/usr/bin/env bats
# covers: scripts/cr/mirror-coverage.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/cr/mirror-coverage.sh"
	TEST_TMP=$(mktemp -d -t mirror-coverage.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# Override log + manifest paths so tests don't touch the live ones.
	# The script reads $REPO_ROOT (computed at invocation), so pretend the
	# test tmp dir is a repo by initializing git there + linking artifacts.
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		mkdir -p .claude/logs .github
		# Minimal manifest so the report can list 'declared but never fired'.
		cat >.github/ship-pr-cycle-mirror-map.yml <<'YAML'
schema_version: 1
mirrors:
  - server_workflow: pr-lint.yml
    phase: push
    local_command: hooks/pr-lint-check.sh
    refuse_on_fail: true
  - server_workflow: gitleaks.yml
    phase: branch-ready
    local_command: pre-commit run gitleaks --all-files
    refuse_on_fail: true
YAML
	)
}

teardown() {
	# shellcheck disable=SC2164 # teardown best-effort; rm guarded below
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */mirror-coverage.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "log appends one JSONL row per call" {
	cd "$TEST_TMP" || return 1
	run "$SCRIPT" log --mirror pr-lint.yml --phase push --rc 0
	[ "$status" -eq 0 ]
	[ -f .claude/logs/ship-pr-mirror-coverage.jsonl ]
	[ "$(wc -l <.claude/logs/ship-pr-mirror-coverage.jsonl | tr -d ' ')" -eq 1 ]
	run "$SCRIPT" log --mirror gitleaks.yml --phase branch-ready --rc 0
	[ "$status" -eq 0 ]
	[ "$(wc -l <.claude/logs/ship-pr-mirror-coverage.jsonl | tr -d ' ')" -eq 2 ]
}

@test "log entries are valid JSON with required fields" {
	cd "$TEST_TMP" || return 1
	"$SCRIPT" log --mirror pr-lint.yml --phase push --rc 1 --refuse-on-fail true >/dev/null
	row=$(cat .claude/logs/ship-pr-mirror-coverage.jsonl)
	echo "$row" | jq -e '.mirror == "pr-lint.yml"' >/dev/null
	echo "$row" | jq -e '.phase == "push"' >/dev/null
	echo "$row" | jq -e '.local_rc == 1' >/dev/null
	echo "$row" | jq -e '.local_fired == true' >/dev/null
	echo "$row" | jq -e '.refuse_on_fail == true' >/dev/null
}

@test "report on empty log emits 'no coverage events' notice" {
	cd "$TEST_TMP" || return 1
	# Remove any pre-existing log (setup didn't create one).
	rm -f .claude/logs/ship-pr-mirror-coverage.jsonl
	run "$SCRIPT" report
	[ "$status" -eq 0 ]
	[[ $output == *"no coverage events logged"* ]]
}

@test "report aggregates fires + fails per mirror" {
	cd "$TEST_TMP" || return 1
	"$SCRIPT" log --mirror pr-lint.yml --phase push --rc 0 >/dev/null
	"$SCRIPT" log --mirror pr-lint.yml --phase push --rc 1 >/dev/null
	"$SCRIPT" log --mirror pr-lint.yml --phase push --rc 0 >/dev/null
	"$SCRIPT" log --mirror gitleaks.yml --phase branch-ready --rc 0 >/dev/null
	run "$SCRIPT" report
	[ "$status" -eq 0 ]
	# pr-lint: 3 fires, 1 fail
	[[ $output == *"pr-lint.yml"* ]]
	[[ $output == *"gitleaks.yml"* ]]
	# Spot-check the per-mirror line shape
	[[ $output =~ pr-lint.yml[[:space:]]+3[[:space:]]+1 ]]
}

@test "report --json emits valid JSON array" {
	cd "$TEST_TMP" || return 1
	"$SCRIPT" log --mirror pr-lint.yml --phase push --rc 0 >/dev/null
	run "$SCRIPT" report --json
	[ "$status" -eq 0 ]
	echo "$output" | jq -e 'type == "array"' >/dev/null
	echo "$output" | jq -e 'length == 1' >/dev/null
	echo "$output" | jq -e '.[0].mirror == "pr-lint.yml"' >/dev/null
	echo "$output" | jq -e '.[0].fires == 1' >/dev/null
}

@test "report flags mirrors declared in manifest but never observed firing" {
	cd "$TEST_TMP" || return 1
	# Only fire pr-lint; gitleaks is in the manifest but unfired.
	"$SCRIPT" log --mirror pr-lint.yml --phase push --rc 0 >/dev/null
	run "$SCRIPT" report
	[ "$status" -eq 0 ]
	[[ $output == *"Declared but never fired"* ]]
	[[ $output == *"gitleaks.yml"* ]]
}

@test "log without --mirror skips silently (best-effort, doesn't block orchestrator)" {
	cd "$TEST_TMP" || return 1
	rm -f .claude/logs/ship-pr-mirror-coverage.jsonl
	run "$SCRIPT" log --phase push --rc 0
	[ "$status" -eq 0 ]
	[[ $output == *"requires"* ]]
	# No entry should be written
	[ ! -f .claude/logs/ship-pr-mirror-coverage.jsonl ]
}

@test "log with --mirror but no value remains fail-soft under set -u" {
	cd "$TEST_TMP" || return 1
	rm -f .claude/logs/ship-pr-mirror-coverage.jsonl
	run "$SCRIPT" log --mirror
	[ "$status" -eq 0 ]
	[[ $output == *"--mirror requires a value"* ]]
	[ ! -f .claude/logs/ship-pr-mirror-coverage.jsonl ]
}

@test "log with --rc but no value remains fail-soft under set -u" {
	cd "$TEST_TMP" || return 1
	rm -f .claude/logs/ship-pr-mirror-coverage.jsonl
	run "$SCRIPT" log --mirror pr-lint.yml --phase push --rc
	[ "$status" -eq 0 ]
	[[ $output == *"--rc requires a value"* ]]
	[ ! -f .claude/logs/ship-pr-mirror-coverage.jsonl ]
}

@test "report skips malformed JSONL lines + counts only valid rows" {
	cd "$TEST_TMP" || return 1
	# Inject 2 valid + 1 truncated row directly so jq fromjson? must skip the bad one.
	cat >.claude/logs/ship-pr-mirror-coverage.jsonl <<'JSONL'
{"ts":"2026-01-01T00:00:00Z","sha":"1","mirror":"pr-lint.yml","phase":"push","local_fired":true,"local_rc":0,"refuse_on_fail":null}
{"mirror":"BROKEN
{"ts":"2026-01-01T00:00:01Z","sha":"2","mirror":"pr-lint.yml","phase":"push","local_fired":true,"local_rc":1,"refuse_on_fail":null}
JSONL
	run "$SCRIPT" report
	[ "$status" -eq 0 ]
	[[ $output == *"malformed JSONL row(s)"* ]]
	# Should count 2 fires for pr-lint (1 fail) — the broken line MUST NOT abort jq mid-file.
	[[ $output =~ pr-lint.yml[[:space:]]+2[[:space:]]+1 ]]
}
