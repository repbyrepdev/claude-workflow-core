#!/usr/bin/env bats
# covers: scripts/refresh-from-source.sh

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." 2>&1 && pwd) || {
		echo "FATAL: cd failed: $REPO_ROOT" >&2
		return 1
	}
	SCRIPT="${REPO_ROOT}/scripts/refresh-from-source.sh"
	TEST_TMP=$(mktemp -d -t rfs.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# Build a self-contained mini plugin-tree under TEST_TMP/plugin and a
	# consumer-tree under TEST_TMP/consumer so we can exercise the script
	# in isolation.
	(
		set -e
		PLUGIN="$TEST_TMP/plugin"
		mkdir -p "$PLUGIN/scripts" "$PLUGIN/.claude" "$PLUGIN/.github" \
			"$PLUGIN/.claude-plugin" "$PLUGIN/_lib"
		cp "$SCRIPT" "$PLUGIN/scripts/refresh-from-source.sh"
		chmod +x "$PLUGIN/scripts/refresh-from-source.sh"
		# Minimal plugin.json for version lookup
		cat >"$PLUGIN/.claude-plugin/plugin.json" <<'JSON'
{"name":"test","version":"9.9.9"}
JSON
		# Minimal consumers.yml
		cat >"$PLUGIN/.github/consumers.yml" <<YAML
schema_version: 1
consumers:
  - name: alpha
    repo: org/alpha
    local_path: $TEST_TMP/consumer
    pinned_version: "9.9.9"
    overrides_file: .claude/local-overrides.yml
    bootstrap_date: 2026-05-28
    contact: "@t"
    notes: "test fixture"
YAML
		# Two source files for the cascade test.
		echo "echo source-A" >"$PLUGIN/_lib/file-a.sh"
		echo "echo source-B" >"$PLUGIN/_lib/file-b.sh"
		# Compute hashes for .source-hashes.json
		hash_a=$(shasum -a 256 "$PLUGIN/_lib/file-a.sh" | awk '{print $1}')
		hash_b=$(shasum -a 256 "$PLUGIN/_lib/file-b.sh" | awk '{print $1}')
		cat >"$PLUGIN/.claude/.source-hashes.json" <<JSON
{
  "algorithm": "sha256",
  "files": {
    "_lib/file-a.sh": "$hash_a",
    "_lib/file-b.sh": "$hash_b"
  }
}
JSON
		# Consumer dir — no copies yet (all-missing initial state).
		mkdir -p "$TEST_TMP/consumer/.claude"
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */rfs.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "--help emits usage" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"Usage"* ]] || return 1
	[[ $output == *"--consumer"* ]] || return 1
	[[ $output == *"--all-consumers"* ]] || return 1
	[[ $output == *"--dry-run"* ]]
}

@test "fails when no target arg given" {
	run "$SCRIPT"
	[ "$status" -eq 2 ]
	[[ $output == *"must specify ONE of"* ]]
}

@test "fails when multiple target args given (mutually exclusive)" {
	run "$SCRIPT" --consumer alpha --all-consumers
	[ "$status" -eq 2 ]
	[[ $output == *"mutually exclusive"* ]]
}

@test "fails on unknown consumer name" {
	cd "$TEST_TMP/plugin" || return 1
	run scripts/refresh-from-source.sh --consumer nonexistent --dry-run
	[ "$status" -eq 2 ]
	[[ $output == *"not found"* ]]
}

@test "dry-run copies 2 missing files (DIFF + would-copy)" {
	cd "$TEST_TMP/plugin" || return 1
	run scripts/refresh-from-source.sh --consumer alpha --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"DIFF"* ]] || return 1
	[[ $output == *"file-a.sh"* ]] || return 1
	[[ $output == *"file-b.sh"* ]] || return 1
	[[ $output == *"replaced=2"* ]] || return 1
	# No files actually copied — dry-run.
	[ ! -f "$TEST_TMP/consumer/.claude/_lib/file-a.sh" ]
}

@test "real run copies 2 missing files atomically" {
	cd "$TEST_TMP/plugin" || return 1
	run scripts/refresh-from-source.sh --consumer alpha
	[ "$status" -eq 0 ]
	[[ $output == *"REPLACED"* ]] || return 1
	[ -f "$TEST_TMP/consumer/.claude/_lib/file-a.sh" ]
	[ -f "$TEST_TMP/consumer/.claude/_lib/file-b.sh" ]
	# Content matches source.
	[ "$(cat "$TEST_TMP/consumer/.claude/_lib/file-a.sh")" = "echo source-A" ]
}

@test "second run is idempotent (zero replacements)" {
	cd "$TEST_TMP/plugin" || return 1
	scripts/refresh-from-source.sh --consumer alpha >/dev/null 2>&1
	run scripts/refresh-from-source.sh --consumer alpha
	[ "$status" -eq 0 ]
	[[ $output == *"clean=2"* ]] || return 1
	[[ $output == *"replaced=0"* ]]
}

@test "honors local-overrides skip-list" {
	cd "$TEST_TMP/plugin" || return 1
	# Add an override skipping file-a.
	cat >"$TEST_TMP/consumer/.claude/local-overrides.yml" <<'YAML'
schema_version: 1
overrides:
  - path: .claude/_lib/file-a.sh
    category: domain-extension
    reason: "Test override; consumer keeps its own copy"
    added: "2026-05-28"
YAML
	run scripts/refresh-from-source.sh --consumer alpha --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"OVERRIDE"* ]] || return 1
	[[ $output == *"file-a.sh"* ]] || return 1
	[[ $output == *"overridden=1"* ]] || return 1
	# file-b not overridden — still appears in DIFF.
	[[ $output == *"DIFF"* ]] || return 1
	[[ $output == *"file-b.sh"* ]]
}

@test "--consumer-path bypasses consumers.yml lookup" {
	cd "$TEST_TMP/plugin" || return 1
	run scripts/refresh-from-source.sh --consumer-path "$TEST_TMP/consumer" --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"replaced=2"* ]]
}

@test "maps skills/ship-pr-cycle/run.sh under consumer .claude/skills, not repo-root (#2237)" {
	# #2237: the skills/* path-map arm must place the wrapper under the
	# consumer's .claude/skills/ (mirroring hooks/_lib), NOT verbatim at
	# repo-root skills/ where the consumer never loads it. A revert dropping
	# `skills/*` from the case would copy it to the wrong place + re-introduce
	# the phase1 deadlock with the suite still green.
	PLUGIN="$TEST_TMP/plugin"
	mkdir -p "$PLUGIN/skills/ship-pr-cycle"
	echo "echo wrapper" >"$PLUGIN/skills/ship-pr-cycle/run.sh"
	hash_a=$(shasum -a 256 "$PLUGIN/_lib/file-a.sh" | awk '{print $1}')
	hash_b=$(shasum -a 256 "$PLUGIN/_lib/file-b.sh" | awk '{print $1}')
	hash_w=$(shasum -a 256 "$PLUGIN/skills/ship-pr-cycle/run.sh" | awk '{print $1}')
	cat >"$PLUGIN/.claude/.source-hashes.json" <<JSON
{
  "algorithm": "sha256",
  "files": {
    "_lib/file-a.sh": "$hash_a",
    "_lib/file-b.sh": "$hash_b",
    "skills/ship-pr-cycle/run.sh": "$hash_w"
  }
}
JSON
	cd "$PLUGIN" || return 1
	run scripts/refresh-from-source.sh --consumer alpha
	[ "$status" -eq 0 ]
	[ -f "$TEST_TMP/consumer/.claude/skills/ship-pr-cycle/run.sh" ]
	[ ! -f "$TEST_TMP/consumer/skills/ship-pr-cycle/run.sh" ]
	[ "$(cat "$TEST_TMP/consumer/.claude/skills/ship-pr-cycle/run.sh")" = "echo wrapper" ]
}

@test "--files filters to subset" {
	cd "$TEST_TMP/plugin" || return 1
	run scripts/refresh-from-source.sh --consumer alpha --files _lib/file-a.sh --dry-run
	[ "$status" -eq 0 ]
	# file-a in subset → DIFF; file-b filtered out (no DIFF for it).
	[[ $output == *"file-a.sh"* ]] || return 1
	[[ $output == *"replaced=1"* ]]
}

@test "writes audit log on real run" {
	cd "$TEST_TMP/plugin" || return 1
	run scripts/refresh-from-source.sh --consumer alpha
	[ "$status" -eq 0 ]
	[ -f "$TEST_TMP/consumer/.claude/logs/refresh-from-source.jsonl" ]
	# Latest entry has the expected counts.
	last=$(tail -1 "$TEST_TMP/consumer/.claude/logs/refresh-from-source.jsonl")
	echo "$last" | jq -e '.files_replaced == 2'
	echo "$last" | jq -e '.plugin_version == "9.9.9"'
}

@test "preserves executable bit when source is executable" {
	cd "$TEST_TMP/plugin" || return 1
	chmod +x "$TEST_TMP/plugin/_lib/file-a.sh"
	# Re-hash after chmod (shasum is content-only; should match).
	hash_a=$(shasum -a 256 "$TEST_TMP/plugin/_lib/file-a.sh" | awk '{print $1}')
	hash_b=$(shasum -a 256 "$TEST_TMP/plugin/_lib/file-b.sh" | awk '{print $1}')
	cat >"$TEST_TMP/plugin/.claude/.source-hashes.json" <<JSON
{
  "algorithm": "sha256",
  "files": {
    "_lib/file-a.sh": "$hash_a",
    "_lib/file-b.sh": "$hash_b"
  }
}
JSON
	run scripts/refresh-from-source.sh --consumer alpha
	[ "$status" -eq 0 ]
	[ -x "$TEST_TMP/consumer/.claude/_lib/file-a.sh" ]
}

# #232 — .github byte-SSOT files map VERBATIM to the consumer repo root (the
# way hooks/_lib map under .claude/). Augment the fixture manifest with a
# .github entry and assert the propagation target.
_register_github_ssot() {
	mkdir -p "$TEST_TMP/plugin/.github"
	printf '## Summary\n' >"$TEST_TMP/plugin/.github/pull_request_template.md"
	local hp ha hb
	hp=$(shasum -a 256 "$TEST_TMP/plugin/.github/pull_request_template.md" | awk '{print $1}')
	ha=$(shasum -a 256 "$TEST_TMP/plugin/_lib/file-a.sh" | awk '{print $1}')
	hb=$(shasum -a 256 "$TEST_TMP/plugin/_lib/file-b.sh" | awk '{print $1}')
	cat >"$TEST_TMP/plugin/.claude/.source-hashes.json" <<JSON
{
  "algorithm": "sha256",
  "files": {
    "_lib/file-a.sh": "$ha",
    "_lib/file-b.sh": "$hb",
    ".github/pull_request_template.md": "$hp"
  }
}
JSON
}

@test "propagates .github SSOT file to consumer REPO ROOT, not under .claude/ (#232)" {
	cd "$TEST_TMP/plugin" || return 1
	_register_github_ssot
	run scripts/refresh-from-source.sh --consumer alpha
	[ "$status" -eq 0 ]
	# .github file landed at the consumer REPO ROOT.
	[ -f "$TEST_TMP/consumer/.github/pull_request_template.md" ]
	# NOT under .claude/ (the pre-#232 mis-mapping that would silently miss).
	[ ! -f "$TEST_TMP/consumer/.claude/.github/pull_request_template.md" ]
	[ "$(cat "$TEST_TMP/consumer/.github/pull_request_template.md")" = "## Summary" ]
	# hooks/_lib still map under .claude/.
	[ -f "$TEST_TMP/consumer/.claude/_lib/file-a.sh" ]
	# Idempotency (#232 r2 pr-test-analyzer): a second run sees the .github
	# file already in place → clean, zero replacements (the verbatim-repo-root
	# mapping + hash-compare are stable across runs).
	run scripts/refresh-from-source.sh --consumer alpha
	[ "$status" -eq 0 ]
	[[ $output == *"clean=3"* ]] || return 1
	[[ $output == *"replaced=0"* ]]
}

@test ".github override via bare relpath is honored (#232)" {
	cd "$TEST_TMP/plugin" || return 1
	_register_github_ssot
	cat >"$TEST_TMP/consumer/.claude/local-overrides.yml" <<'YAML'
schema_version: 1
overrides:
  - path: .github/pull_request_template.md
    category: domain-extension
    reason: "consumer keeps its own PR template"
    added: "2026-05-31"
YAML
	run scripts/refresh-from-source.sh --consumer alpha --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"OVERRIDE"* ]] || return 1
	[[ $output == *"pull_request_template.md"* ]] || return 1
	[[ $output == *"overridden=1"* ]] || return 1
	# file-a/file-b not overridden — still appear as DIFF.
	[[ $output == *"file-a.sh"* ]]
}
