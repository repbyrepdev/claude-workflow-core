#!/usr/bin/env bats
# covers: scripts/cascade-to-consumers.sh

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." 2>&1 && pwd) || {
		echo "FATAL: cd failed: $REPO_ROOT" >&2
		return 1
	}
	SCRIPT="${REPO_ROOT}/scripts/cascade-to-consumers.sh"
	TEST_TMP=$(mktemp -d -t cascade.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}

	# Self-contained mini plugin tree.
	(
		set -e
		PLUGIN="$TEST_TMP/plugin"
		mkdir -p "$PLUGIN/scripts" "$PLUGIN/.github" "$PLUGIN/.claude-plugin" "$PLUGIN/.claude/logs"
		cp "$SCRIPT" "$PLUGIN/scripts/cascade-to-consumers.sh"
		chmod +x "$PLUGIN/scripts/cascade-to-consumers.sh"

		cat >"$PLUGIN/.claude-plugin/plugin.json" <<'JSON'
{"name":"test","version":"1.2.3"}
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
    notes: "first"
  - name: beta
    repo: org/beta
    local_path: /tmp/beta
    pinned_version: "1.2.3"
    overrides_file: .claude/local-overrides.yml
    bootstrap_date: 2026-02-20
    contact: "@dev"
    notes: "second"
YAML

		# Stub gh that records calls + returns scripted output.
		# `gh issue list ... --jq ...` returns empty (no existing issue).
		# `gh issue create ...` writes a URL to stdout + records the call.
		mkdir -p "$TEST_TMP/bin"
		cat >"$TEST_TMP/bin/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
LOG="${GH_STUB_LOG:-/tmp/gh-stub.log}"
echo "gh-stub: $*" >>"$LOG"
case "$1" in
  issue)
    case "$2" in
      list)
        # Honor GH_STUB_EXISTING_<repo>=<num> env to return a stub issue number.
        # repo arg is in $3 if --repo wasn't first; iterate args to find --repo.
        repo=""
        for ((i=3;i<=$#;i++)); do
          if [ "${!i}" = "--repo" ]; then
            j=$((i+1)); repo="${!j}"; break
          fi
        done
        env_name="GH_STUB_EXISTING_$(printf '%s' "$repo" | tr '/-' '__')"
        existing=$(printenv "$env_name" 2>/dev/null || echo "")
        if [ -n "$existing" ]; then
          printf '%s\n' "$existing"
        fi
        exit 0
        ;;
      create)
        # Extract --repo for URL synthesis.
        repo=""
        for ((i=3;i<=$#;i++)); do
          if [ "${!i}" = "--repo" ]; then
            j=$((i+1)); repo="${!j}"; break
          fi
        done
        # Fail if GH_STUB_FAIL_CREATE=1 set.
        if [ "${GH_STUB_FAIL_CREATE:-0}" = "1" ]; then
          echo "gh: stubbed create failure" >&2
          exit 1
        fi
        echo "https://github.com/$repo/issues/777"
        exit 0
        ;;
    esac
    ;;
esac
echo "gh-stub: unhandled args: $*" >&2
exit 0
GHSCRIPT
		chmod +x "$TEST_TMP/bin/gh"
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}

	export PATH="$TEST_TMP/bin:$PATH"
	export GH_STUB_LOG="$TEST_TMP/gh-stub.log"
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */cascade.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "--help emits usage" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"Usage"* ]]
	[[ $output == *"--dry-run"* ]]
}

@test "--help does not leak loader frontmatter directives" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output != *"event: post-release"* ]]
	[[ $output != *"auto-register: false"* ]]
}

@test "--consumer and --all-consumers are mutex" {
	run "$SCRIPT" --consumer foo --all-consumers
	[ "$status" -eq 2 ]
	[[ $output == *"mutually exclusive"* ]]
}

@test "--version requires X.Y.Z" {
	run "$SCRIPT" --version "v1.2.3"
	[ "$status" -eq 2 ]
	[[ $output == *"X.Y.Z"* ]]
}

@test "--consumer unknown name exits 2" {
	cd "$TEST_TMP/plugin" || return 1
	run scripts/cascade-to-consumers.sh --consumer nonexistent --dry-run
	[ "$status" -eq 2 ]
	[[ $output == *"not found"* ]]
}

@test "--dry-run --version 1.2.3 skips beta (current), would-create alpha" {
	cd "$TEST_TMP/plugin" || return 1
	run scripts/cascade-to-consumers.sh --dry-run --version 1.2.3
	[ "$status" -eq 0 ]
	[[ $output == *"[DRY-RUN] alpha"* ]]
	[[ $output == *"[CURRENT] beta"* ]]
	[[ $output == *"created:         0"* ]]
	[[ $output == *"skipped current: 1"* ]]
}

@test "real run creates issue + logs JSONL" {
	cd "$TEST_TMP/plugin" || return 1
	run scripts/cascade-to-consumers.sh --consumer alpha
	[ "$status" -eq 0 ]
	[[ $output == *"[CREATED] alpha"* ]]
	[[ $output == *"issue #777"* ]]
	# Audit log should contain a JSON record with action=created
	[ -f "$TEST_TMP/plugin/.claude/logs/cascade.jsonl" ]
	run jq -r '.action' "$TEST_TMP/plugin/.claude/logs/cascade.jsonl"
	[[ $output == *"created"* ]]
}

@test "idempotency: existing issue skips creation" {
	cd "$TEST_TMP/plugin" || return 1
	# Stub: org/alpha already has open cascade issue #555.
	GH_STUB_EXISTING_org_alpha=555 run scripts/cascade-to-consumers.sh --consumer alpha
	[ "$status" -eq 0 ]
	[[ $output == *"[EXISTS] alpha"* ]]
	[[ $output == *"#555"* ]]
}

@test "version override creates for both" {
	cd "$TEST_TMP/plugin" || return 1
	run scripts/cascade-to-consumers.sh --version 2.0.0
	[ "$status" -eq 0 ]
	[[ $output == *"[CREATED] alpha"* ]]
	[[ $output == *"[CREATED] beta"* ]]
	[[ $output == *"created:         2"* ]]
}

@test "gh create failure returns rc=3" {
	cd "$TEST_TMP/plugin" || return 1
	GH_STUB_FAIL_CREATE=1 run scripts/cascade-to-consumers.sh --consumer alpha
	[ "$status" -eq 3 ]
	[[ $output == *"[FAIL] alpha"* ]]
	[[ $output == *"failed:          1"* ]]
}

@test "missing plugin.json exits 2" {
	cd "$TEST_TMP/plugin" || return 1
	rm .claude-plugin/plugin.json
	run scripts/cascade-to-consumers.sh
	[ "$status" -eq 2 ]
	[[ $output == *"plugin.json missing"* ]]
}

@test "schema_version mismatch exits 2" {
	cd "$TEST_TMP/plugin" || return 1
	# Rewrite registry with bogus schema_version.
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
	run scripts/cascade-to-consumers.sh --dry-run
	[ "$status" -eq 2 ]
	[[ $output == *"schema_version=99"* ]]
}

@test "consumers null/empty exits 2" {
	cd "$TEST_TMP/plugin" || return 1
	cat >.github/consumers.yml <<'YAML'
schema_version: 1
consumers:
YAML
	run scripts/cascade-to-consumers.sh --dry-run
	[ "$status" -eq 2 ]
	[[ $output == *"null or empty"* ]]
}
