#!/usr/bin/env bats
# covers: scripts/discover-orphan-hooks.sh

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." 2>&1 && pwd) || {
		echo "FATAL: cd failed: $REPO_ROOT" >&2
		return 1
	}
	SCRIPT="${REPO_ROOT}/scripts/discover-orphan-hooks.sh"
	TEST_TMP=$(mktemp -d -t orphans.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}

	(
		set -e
		HOOKS="$TEST_TMP/hooks"
		mkdir -p "$HOOKS" "$TEST_TMP/.claude"

		# Registered hook (in settings.json AND has auto-register: true).
		cat >"$HOOKS/registered.sh" <<'SH'
#!/bin/bash
# event: PreToolUse
# auto-register: true
# matcher: Bash
echo registered
SH

		# Orphan: auto-register true but NOT in settings.json.
		cat >"$HOOKS/orphan-a.sh" <<'SH'
#!/bin/bash
# event: SessionStart
# auto-register: true
echo orphan-a
SH

		cat >"$HOOKS/orphan-b.sh" <<'SH'
#!/bin/bash
# event: PreToolUse
# auto-register: true
# matcher: Edit|Write
echo orphan-b
SH

		# Helper (filename-_): always skip.
		cat >"$HOOKS/_helper.sh" <<'SH'
#!/bin/bash
# auto-register: true
echo i should be skipped because i'm _helper
SH

		# CLI tool: no auto-register directive → skip.
		cat >"$HOOKS/cli-tool.sh" <<'SH'
#!/bin/bash
# event: none
echo i'm a cli tool
SH

		# auto-register: false → explicit opt-out, skip.
		cat >"$HOOKS/opt-out.sh" <<'SH'
#!/bin/bash
# event: PreToolUse
# auto-register: false
echo opt-out by design
SH

		# Settings.json that registers only registered.sh.
		cat >"$TEST_TMP/.claude/settings.json" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "$HOOKS/registered.sh"}
        ]
      }
    ]
  }
}
JSON
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */orphans.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "--help emits usage" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"auto-register: true"* ]]
}

@test "--help does not leak loader frontmatter" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output != *"event: none"* ]] || return 1
	[[ $output != *"auto-register: false"* ]]
}

@test "text default reports 2 orphans (orphan-a, orphan-b); skips helper + cli-tool + opt-out + registered" {
	run "$SCRIPT" --hooks-dir "$TEST_TMP/hooks" --settings "$TEST_TMP/.claude/settings.json"
	[ "$status" -eq 0 ]
	[[ $output == *"(2)"* ]] || return 1
	[[ $output == *"orphan-a.sh"* ]] || return 1
	[[ $output == *"orphan-b.sh"* ]] || return 1
	# Should NOT mention these
	[[ $output != *"registered.sh"* ]] || return 1
	[[ $output != *"_helper.sh"* ]] || return 1
	[[ $output != *"cli-tool.sh"* ]] || return 1
	[[ $output != *"opt-out.sh"* ]]
}

@test "--json emits valid array of orphans with event + matcher fields" {
	run "$SCRIPT" --json --hooks-dir "$TEST_TMP/hooks" --settings "$TEST_TMP/.claude/settings.json"
	[ "$status" -eq 0 ]
	echo "$output" | jq -e 'type == "array" and length == 2'
	echo "$output" | jq -e '.[] | select(.name == "orphan-a.sh") | .event == "SessionStart"'
	echo "$output" | jq -e '.[] | select(.name == "orphan-b.sh") | .matcher == "Edit|Write"'
}

@test "--strict exits 1 when orphans exist" {
	run "$SCRIPT" --strict --hooks-dir "$TEST_TMP/hooks" --settings "$TEST_TMP/.claude/settings.json"
	[ "$status" -eq 1 ]
}

@test "--strict exits 0 when clean" {
	# Re-write settings.json to register both orphans.
	cat >"$TEST_TMP/.claude/settings.json" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {"matcher":"Bash","hooks":[{"type":"command","command":"$TEST_TMP/hooks/registered.sh"}]},
      {"matcher":"Edit|Write","hooks":[{"type":"command","command":"$TEST_TMP/hooks/orphan-b.sh"}]}
    ],
    "SessionStart": [
      {"hooks":[{"type":"command","command":"$TEST_TMP/hooks/orphan-a.sh"}]}
    ]
  }
}
JSON
	run "$SCRIPT" --strict --hooks-dir "$TEST_TMP/hooks" --settings "$TEST_TMP/.claude/settings.json"
	[ "$status" -eq 0 ]
}

@test "--register-missing writes stub YAML to DISCOVERY_OUT_DIR (no real-repo leak)" {
	DISCOVERY_OUT_DIR="$TEST_TMP/discovery" run "$SCRIPT" --register-missing \
		--hooks-dir "$TEST_TMP/hooks" --settings "$TEST_TMP/.claude/settings.json"
	[ "$status" -eq 0 ]
	[[ $output == *"Stub written"* ]] || return 1
	stub=$(find "$TEST_TMP/discovery" -name "orphans-*.yml" 2>/dev/null | head -1)
	[ -n "$stub" ]
	[ -f "$stub" ]
	# Verify @json-escaped YAML (quoted strings parseable as YAML).
	grep -q 'name: "orphan-a.sh"' "$stub"
	grep -q 'name: "orphan-b.sh"' "$stub"
}

@test "missing settings.json exits 2" {
	run "$SCRIPT" --hooks-dir "$TEST_TMP/hooks" --settings "$TEST_TMP/nonexistent.json"
	[ "$status" -eq 2 ]
	[[ $output == *"not found"* ]]
}

@test "missing hooks dir exits 2" {
	run "$SCRIPT" --hooks-dir "$TEST_TMP/nonexistent" --settings "$TEST_TMP/.claude/settings.json"
	[ "$status" -eq 2 ]
	[[ $output == *"not a directory"* ]]
}

@test "unknown arg exits 2" {
	run "$SCRIPT" --bogus
	[ "$status" -eq 2 ]
	[[ $output == *"unknown arg"* ]]
}

@test "auto-register: false is treated same as missing (opt-out)" {
	# Remove all auto-register: true hooks, keep only opt-out.
	rm "$TEST_TMP/hooks/orphan-a.sh" "$TEST_TMP/hooks/orphan-b.sh"
	run "$SCRIPT" --hooks-dir "$TEST_TMP/hooks" --settings "$TEST_TMP/.claude/settings.json"
	[ "$status" -eq 0 ]
	[[ $output == *"(0)"* ]] || [[ $output == *"clean"* ]]
}
