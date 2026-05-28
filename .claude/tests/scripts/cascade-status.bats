#!/usr/bin/env bats
# covers: scripts/cascade-status.sh

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." 2>&1 && pwd) || {
		echo "FATAL: cd failed: $REPO_ROOT" >&2
		return 1
	}
	SCRIPT="${REPO_ROOT}/scripts/cascade-status.sh"
	TEST_TMP=$(mktemp -d -t cstatus.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}

	(
		set -e
		PLUGIN="$TEST_TMP/plugin"
		mkdir -p "$PLUGIN/scripts" "$PLUGIN/.github" "$PLUGIN/.claude-plugin"
		cp "$SCRIPT" "$PLUGIN/scripts/cascade-status.sh"
		chmod +x "$PLUGIN/scripts/cascade-status.sh"

		cat >"$PLUGIN/.claude-plugin/plugin.json" <<'JSON'
{"name":"test","version":"2.0.0"}
JSON
		cat >"$PLUGIN/.github/consumers.yml" <<'YAML'
schema_version: 1
consumers:
  - name: alpha
    repo: org/alpha
    local_path: /tmp/alpha
    pinned_version: "1.0.0"
    overrides_file: .claude/local-overrides.yml
    bootstrap_date: 2026-01-15
    contact: "@dev"
    notes: "behind"
  - name: beta
    repo: org/beta
    local_path: /tmp/beta
    pinned_version: "2.0.0"
    overrides_file: .claude/local-overrides.yml
    bootstrap_date: 2026-02-20
    contact: "@dev"
    notes: "current"
YAML
		# Stub gh — emit empty JSON array for issue list calls so the
		# downstream `| jq -r '.[0].number // empty'` parses cleanly.
		mkdir -p "$TEST_TMP/bin"
		cat >"$TEST_TMP/bin/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
case "$1" in
  issue)
    case "$2" in
      list) printf '[]\n'; exit 0 ;;
    esac
    ;;
esac
exit 0
GHSCRIPT
		chmod +x "$TEST_TMP/bin/gh"
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
	export PATH="$TEST_TMP/bin:$PATH"
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */cstatus.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "--help emits usage" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"cascade-status snapshot"* ]]
}

@test "--help does not leak loader frontmatter" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output != *"event: none"* ]]
	[[ $output != *"auto-register: false"* ]]
}

@test "--quiet --json mutex exits 2" {
	cd "$TEST_TMP/plugin" || return 1
	run scripts/cascade-status.sh --quiet --json
	[ "$status" -eq 2 ]
	[[ $output == *"mutually exclusive"* ]]
}

@test "text default lists both consumers + counts behind" {
	cd "$TEST_TMP/plugin" || return 1
	run scripts/cascade-status.sh
	[ "$status" -eq 0 ]
	[[ $output == *"alpha"* ]]
	[[ $output == *"beta"* ]]
	[[ $output == *"1 consumer(s) behind"* ]]
}

@test "--json emits valid array with is_behind flags" {
	cd "$TEST_TMP/plugin" || return 1
	run scripts/cascade-status.sh --json
	[ "$status" -eq 0 ]
	echo "$output" | jq -e 'type == "array"'
	echo "$output" | jq -e 'length == 2'
	echo "$output" | jq -e '.[] | select(.name == "alpha") | .is_behind == true'
	echo "$output" | jq -e '.[] | select(.name == "beta") | .is_behind == false'
}

@test "--quiet exits 1 when consumers behind + emits stderr summary" {
	cd "$TEST_TMP/plugin" || return 1
	run scripts/cascade-status.sh --quiet
	[ "$status" -eq 1 ]
	[[ $output == *"behind plugin v2.0.0"* ]]
}

@test "--quiet exits 0 + silent when all current" {
	cd "$TEST_TMP/plugin" || return 1
	cat >.github/consumers.yml <<'YAML'
schema_version: 1
consumers:
  - name: alpha
    repo: org/alpha
    local_path: /tmp/alpha
    pinned_version: "2.0.0"
    overrides_file: .claude/local-overrides.yml
    bootstrap_date: 2026-01-15
    contact: "@dev"
    notes: "current"
YAML
	run scripts/cascade-status.sh --quiet
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "missing plugin.json exits 2" {
	cd "$TEST_TMP/plugin" || return 1
	rm .claude-plugin/plugin.json
	run scripts/cascade-status.sh
	[ "$status" -eq 2 ]
	[[ $output == *"plugin.json missing"* ]]
}

@test "schema_version mismatch exits 2" {
	cd "$TEST_TMP/plugin" || return 1
	cat >.github/consumers.yml <<'YAML'
schema_version: 99
consumers:
  - name: alpha
    repo: org/alpha
    local_path: /tmp/alpha
    pinned_version: "1.0.0"
    overrides_file: .claude/local-overrides.yml
    bootstrap_date: 2026-01-15
    contact: "@dev"
    notes: "first"
YAML
	run scripts/cascade-status.sh
	[ "$status" -eq 2 ]
	[[ $output == *"schema_version=99"* ]]
}

@test "zero consumers yields clean empty snapshot, not exit 2" {
	cd "$TEST_TMP/plugin" || return 1
	cat >.github/consumers.yml <<'YAML'
schema_version: 1
consumers:
YAML
	# r2 silent-failure-hunter LOW: empty registry is operationally valid.
	run scripts/cascade-status.sh
	[ "$status" -eq 0 ]
	[[ $output == *"no consumers registered"* ]]

	run scripts/cascade-status.sh --json
	[ "$status" -eq 0 ]
	echo "$output" | jq -e 'type == "array" and length == 0'

	run scripts/cascade-status.sh --quiet
	[ "$status" -eq 0 ]
}
