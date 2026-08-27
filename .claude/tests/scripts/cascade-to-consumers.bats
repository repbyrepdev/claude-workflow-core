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
		mkdir -p "$PLUGIN/scripts" "$PLUGIN/.github" "$PLUGIN/.claude-plugin" "$PLUGIN/.claude/logs" "$PLUGIN/_lib"
		cp "$SCRIPT" "$PLUGIN/scripts/cascade-to-consumers.sh"
		chmod +x "$PLUGIN/scripts/cascade-to-consumers.sh"
		# cascade now sources the plugin-identity lib (#2310); provide it in the
		# fixture so require_plugin_identity passes (the manifest below also gains
		# a .repository field for the same reason).
		cp "$REPO_ROOT/_lib/resolve-plugin-identity.sh" "$PLUGIN/_lib/resolve-plugin-identity.sh"

		cat >"$PLUGIN/.claude-plugin/plugin.json" <<'JSON'
{"name":"test","version":"1.2.3","repository":"https://github.com/test-org/test"}
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
		# `gh issue list ... --json number,title` returns JSON; the
		# downstream `| jq ...` extracts the number. GH_STUB_EXISTING_<repo>
		# (with title) lets a test mark an issue as already existing.
		# `gh label create ...` always succeeds (idempotency-friendly).
		# `gh issue create ...` writes a URL to stdout.
		mkdir -p "$TEST_TMP/bin"
		cat >"$TEST_TMP/bin/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
LOG="${GH_STUB_LOG:-/tmp/gh-stub.log}"
echo "gh-stub: $*" >>"$LOG"
case "$1" in
  label)
    # gh label create --force is idempotent in the real CLI; stub is no-op.
    if [ "${GH_STUB_FAIL_LABEL:-0}" = "1" ]; then
      echo "gh: stubbed label-create failure" >&2
      exit 1
    fi
    exit 0
    ;;
  issue)
    case "$2" in
      list)
        # Locate --repo for env lookup.
        repo=""
        for ((i=3;i<=$#;i++)); do
          if [ "${!i}" = "--repo" ]; then
            j=$((i+1)); repo="${!j}"; break
          fi
        done
        env_repo=$(printf '%s' "$repo" | tr '/-' '__')
        env_name="GH_STUB_EXISTING_$env_repo"
        existing_num=$(printenv "$env_name" 2>/dev/null || echo "")
        # Title-aware env: GH_STUB_EXISTING_TITLE_<repo>=<full title>
        title_env="GH_STUB_EXISTING_TITLE_$env_repo"
        existing_title=$(printenv "$title_env" 2>/dev/null || echo "")
        # v0.26.0 #169: GH_STUB_PRIOR_<repo>="num1,num2,..." lists OPEN
        # cascade issues that supersede-dedup should close. Returned IN
        # ADDITION to the title-exact existing_num (if set).
        prior_env="GH_STUB_PRIOR_$env_repo"
        prior_list=$(printenv "$prior_env" 2>/dev/null || echo "")
        # Build the JSON array. Title for prior entries is intentionally
        # different from the to-be-created title so the title-exact
        # idempotency check doesn't false-match them.
        entries=""
        if [ -n "$existing_num" ]; then
          entries="{\"number\":$existing_num,\"title\":\"${existing_title:-feat: refresh from plugin v1.2.3 (was v1.0.0)}\"}"
        fi
        if [ -n "$prior_list" ]; then
          IFS=, read -ra arr <<<"$prior_list"
          for p in "${arr[@]}"; do
            [ -z "$p" ] && continue
            [ -n "$entries" ] && entries="$entries,"
            entries="$entries{\"number\":$p,\"title\":\"feat: refresh from plugin (PRIOR $p)\"}"
          done
        fi
        printf '[%s]\n' "$entries"
        exit 0
        ;;
      create)
        repo=""
        for ((i=3;i<=$#;i++)); do
          if [ "${!i}" = "--repo" ]; then
            j=$((i+1)); repo="${!j}"; break
          fi
        done
        # Capture the issue body (cascade pipes it via --body-file -) so tests
        # can assert the rendered identity (#2310). Always consume stdin so the
        # producer pipe closes; default to /dev/null when unobserved. No silent
        # mask: a write failure to a real BODY_LOG surfaces (/dev/null cannot fail).
        cat >"${GH_STUB_BODY_LOG:-/dev/null}"
        if [ "${GH_STUB_FAIL_CREATE:-0}" = "1" ]; then
          echo "gh: stubbed create failure" >&2
          exit 1
        fi
        echo "https://github.com/$repo/issues/777"
        exit 0
        ;;
      close)
        # v0.26.0 #169: cascade-dedup supersede calls gh issue close <num>
        # --repo <r> --comment "...". Stub records the close to a log so
        # tests can assert which numbers got closed. Parent-dir mkdir
        # guard prevents silent log loss if a future test uses a nested
        # GH_STUB_CLOSE_LOG path (r2 silent-failure-hunter MEDIUM).
        close_num="$3"
        close_log="${GH_STUB_CLOSE_LOG:-/tmp/gh-stub-close.log}"
        if ! mkdir -p "$(dirname "$close_log")" 2>/dev/null; then
          echo "stub: cannot create close_log parent dir" >&2
          exit 99
        fi
        if ! echo "$close_num" >>"$close_log"; then
          echo "stub: append to $close_log failed" >&2
          exit 99
        fi
        if [ "${GH_STUB_FAIL_CLOSE:-0}" = "1" ]; then
          echo "gh: stubbed close failure" >&2
          exit 1
        fi
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
	export GH_STUB_CLOSE_LOG="$TEST_TMP/gh-stub-close.log"
	export GH_STUB_BODY_LOG="$TEST_TMP/gh-issue-body.txt"
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
	[[ $output == *"Usage"* ]] || return 1
	[[ $output == *"--dry-run"* ]]
}

@test "--help does not leak loader frontmatter directives" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output != *"event: post-release"* ]] || return 1
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
	[[ $output == *"[DRY-RUN] alpha"* ]] || return 1
	[[ $output == *"[CURRENT] beta"* ]] || return 1
	[[ $output == *"created:         0"* ]] || return 1
	[[ $output == *"skipped current: 1"* ]]
}

@test "real run creates issue + logs JSONL" {
	cd "$TEST_TMP/plugin" || return 1
	run scripts/cascade-to-consumers.sh --consumer alpha
	[ "$status" -eq 0 ]
	[[ $output == *"[CREATED] alpha"* ]] || return 1
	[[ $output == *"issue #777"* ]] || return 1
	# Audit log should contain a JSON record with action=created
	[ -f "$TEST_TMP/plugin/.claude/logs/cascade.jsonl" ]
	run jq -r '.action' "$TEST_TMP/plugin/.claude/logs/cascade.jsonl"
	[[ $output == *"created"* ]]
}

@test "idempotency: existing issue skips creation" {
	cd "$TEST_TMP/plugin" || return 1
	# Stub: org/alpha already has open cascade issue #555 with matching title.
	GH_STUB_EXISTING_org_alpha=555 \
		GH_STUB_EXISTING_TITLE_org_alpha="feat: refresh from plugin v1.2.3 (was v1.0.0)" \
		run scripts/cascade-to-consumers.sh --consumer alpha
	[ "$status" -eq 0 ]
	[[ $output == *"[EXISTS] alpha"* ]] || return 1
	[[ $output == *"#555"* ]]
}

@test "label-create failure halts cascade for that consumer (rc=3)" {
	cd "$TEST_TMP/plugin" || return 1
	GH_STUB_FAIL_LABEL=1 run scripts/cascade-to-consumers.sh --consumer alpha
	[ "$status" -eq 3 ]
	[[ $output == *"failed to ensure"* ]] || return 1
	[[ $output == *"failed:          1"* ]] || return 1
	# r3 code-reviewer LOW: also verify the JSONL audit log carries the
	# fail-label-create action (whole-point-of-the-audit-log).
	[ -f "$TEST_TMP/plugin/.claude/logs/cascade.jsonl" ]
	run jq -s 'map(select(.action == "fail-label-create")) | length' "$TEST_TMP/plugin/.claude/logs/cascade.jsonl"
	[ "$output" -ge 1 ]
}

@test "malformed consumer entry (missing fields) rc=3 + audit logs fail-malformed-entry" {
	cd "$TEST_TMP/plugin" || return 1
	# Replace consumers.yml with one missing the `repo` field.
	cat >.github/consumers.yml <<'YAML'
schema_version: 1
consumers:
  - name: bogus
    local_path: /tmp/bogus
    pinned_version: "0.1.0"
    overrides_file: .claude/local-overrides.yml
    bootstrap_date: 2026-01-15
    contact: "@dev"
    notes: "missing repo"
YAML
	run scripts/cascade-to-consumers.sh
	[ "$status" -eq 3 ]
	[[ $output == *"missing required field"* ]]
}

@test "version override creates for both" {
	cd "$TEST_TMP/plugin" || return 1
	run scripts/cascade-to-consumers.sh --version 2.0.0
	[ "$status" -eq 0 ]
	[[ $output == *"[CREATED] alpha"* ]] || return 1
	[[ $output == *"[CREATED] beta"* ]] || return 1
	[[ $output == *"created:         2"* ]]
}

@test "gh create failure returns rc=3" {
	cd "$TEST_TMP/plugin" || return 1
	GH_STUB_FAIL_CREATE=1 run scripts/cascade-to-consumers.sh --consumer alpha
	[ "$status" -eq 3 ]
	[[ $output == *"[FAIL] alpha"* ]] || return 1
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

# --- v0.26.0 #169 cascade-dedup tests ---

@test "dedup: one prior open cascade is superseded after new create" {
	cd "$TEST_TMP/plugin" || return 1
	# Stub: org/alpha has prior open cascade #555 (different version)
	GH_STUB_PRIOR_org_alpha="555" run scripts/cascade-to-consumers.sh --consumer alpha
	[ "$status" -eq 0 ]
	[[ $output == *"[CREATED] alpha"* ]] || return 1
	[[ $output == *"[SUPERSEDED] alpha"* ]] || return 1
	[[ $output == *"#555"* ]] || return 1
	# Verify the close call landed
	[ -f "$TEST_TMP/gh-stub-close.log" ]
	grep -Fxq "555" "$TEST_TMP/gh-stub-close.log"
}

@test "dedup: multiple priors all get superseded" {
	cd "$TEST_TMP/plugin" || return 1
	GH_STUB_PRIOR_org_alpha="100,200,300" run scripts/cascade-to-consumers.sh --consumer alpha
	[ "$status" -eq 0 ]
	[[ $output == *"[CREATED] alpha"* ]] || return 1
	# All 3 priors closed
	[ -f "$TEST_TMP/gh-stub-close.log" ]
	grep -Fxq "100" "$TEST_TMP/gh-stub-close.log"
	grep -Fxq "200" "$TEST_TMP/gh-stub-close.log"
	grep -Fxq "300" "$TEST_TMP/gh-stub-close.log"
}

@test "dedup: zero priors → no supersede calls" {
	cd "$TEST_TMP/plugin" || return 1
	# Default state: no GH_STUB_PRIOR set
	run scripts/cascade-to-consumers.sh --consumer alpha
	[ "$status" -eq 0 ]
	[[ $output == *"[CREATED] alpha"* ]] || return 1
	[[ $output != *"[SUPERSEDED]"* ]] || return 1
	[ ! -f "$TEST_TMP/gh-stub-close.log" ] || [ ! -s "$TEST_TMP/gh-stub-close.log" ]
}

@test "dedup: --dry-run previews supersede without closing" {
	cd "$TEST_TMP/plugin" || return 1
	GH_STUB_PRIOR_org_alpha="500" run scripts/cascade-to-consumers.sh --consumer alpha --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"[DRY-RUN] alpha"* ]] || return 1
	[[ $output == *"[DRY-RUN-supersede] alpha"* ]] || return 1
	[[ $output == *"#500"* ]] || return 1
	# No close calls actually fired
	[ ! -f "$TEST_TMP/gh-stub-close.log" ] || [ ! -s "$TEST_TMP/gh-stub-close.log" ]
}

@test "dedup: existing-issue [EXISTS] path does NOT supersede priors" {
	cd "$TEST_TMP/plugin" || return 1
	# EXISTS path: title-match returns the existing issue. Dedup loop
	# should NOT fire (we're already on the latest).
	GH_STUB_EXISTING_org_alpha=555 \
		GH_STUB_EXISTING_TITLE_org_alpha="feat: refresh from plugin v1.2.3 (was v1.0.0)" \
		GH_STUB_PRIOR_org_alpha="100" \
		run scripts/cascade-to-consumers.sh --consumer alpha
	[ "$status" -eq 0 ]
	[[ $output == *"[EXISTS] alpha"* ]] || return 1
	# Should NOT have closed #100 (we hit EXISTS, not CREATED)
	[ ! -f "$TEST_TMP/gh-stub-close.log" ] || ! grep -Fxq "100" "$TEST_TMP/gh-stub-close.log"
}

@test "dedup: close-fail is best-effort (rc stays 0; failure audit-logged WITH detail)" {
	cd "$TEST_TMP/plugin" || return 1
	GH_STUB_PRIOR_org_alpha="999" GH_STUB_FAIL_CLOSE=1 run scripts/cascade-to-consumers.sh --consumer alpha
	# Primary cascade succeeded → exit 0 even with supersede failures
	[ "$status" -eq 0 ]
	[[ $output == *"[CREATED] alpha"* ]] || return 1
	[[ $output == *"[supersede-fail] alpha"* ]] || return 1
	# r2 code-reviewer CRITICAL: fail-supersede-close audit MUST capture
	# BOTH the prior issue number AND the gh-close stderr (was dropping
	# detail when issue_num was set under the old mutually-exclusive _log).
	[ -f "$TEST_TMP/plugin/.claude/logs/cascade.jsonl" ]
	grep -q '"action":"fail-supersede-close"' "$TEST_TMP/plugin/.claude/logs/cascade.jsonl"
	grep -q '"issue":999' "$TEST_TMP/plugin/.claude/logs/cascade.jsonl"
	grep -q '"detail":' "$TEST_TMP/plugin/.claude/logs/cascade.jsonl"
	# r2 silent-failure-hunter HIGH: supersede failure shows in summary.
	[[ $output == *"supersede fails: 1"* ]]
}

@test "dedup: summary surfaces superseded counter on success" {
	cd "$TEST_TMP/plugin" || return 1
	GH_STUB_PRIOR_org_alpha="100,200,300" run scripts/cascade-to-consumers.sh --consumer alpha
	[ "$status" -eq 0 ]
	# r2 silent-failure-hunter HIGH: feature must be visible in summary
	# (was: superseded counter only in audit log; operator at-a-glance
	# couldn't see whether dedup actually fired).
	[[ $output == *"superseded:      3"* ]] || return 1
	[[ $output == *"supersede fails: 0"* ]]
}

@test "dedup: zero priors emits supersede-none audit entry" {
	cd "$TEST_TMP/plugin" || return 1
	# No GH_STUB_PRIOR → empty prior list
	run scripts/cascade-to-consumers.sh --consumer alpha
	[ "$status" -eq 0 ]
	# r2 silent-failure-hunter MEDIUM: audit log must positively record
	# "no priors found" rather than silence on this path.
	[ -f "$TEST_TMP/plugin/.claude/logs/cascade.jsonl" ]
	grep -q '"action":"supersede-none"' "$TEST_TMP/plugin/.claude/logs/cascade.jsonl"
}

@test "issue body interpolates the DERIVED plugin identity (#2310)" {
	cd "$TEST_TMP/plugin" || return 1
	run scripts/cascade-to-consumers.sh --consumer alpha
	[ "$status" -eq 0 ]
	# The body (captured from gh stdin) must carry the identity DERIVED from the
	# fixture manifest (name=test, repository=https://github.com/test-org/test),
	# proving $PLUGIN_NAME / $PLUGIN_REPO_URL interpolation — not a hardcode.
	[ -f "$TEST_TMP/gh-issue-body.txt" ]
	run cat "$TEST_TMP/gh-issue-body.txt"
	[[ $output == *"test has released"* ]] || return 1
	[[ $output == *"~/test/scripts/refresh-from-source.sh"* ]] || return 1
	# Key assertion LAST: the release-notes link is built from $PLUGIN_REPO_URL.
	[[ $output == *"https://github.com/test-org/test/releases/tag/v"* ]]
}

@test "cascade fails closed (rc 2) when manifest identity is incomplete (#2310)" {
	cd "$TEST_TMP/plugin" || return 1
	# Empty .repository → lib derives an empty URL (jq -er succeeds on "", so no
	# set-e abort at source) → require_plugin_identity at load aborts the cascade
	# (rc 2) BEFORE any consumer work.
	cat >"$TEST_TMP/plugin/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "test",
  "version": "1.2.3",
  "repository": ""
}
EOF
	run scripts/cascade-to-consumers.sh --consumer alpha
	[ "$status" -eq 2 ]
	[[ $output == *"incomplete"* ]]
}
