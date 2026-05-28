#!/usr/bin/env bats
# covers: scripts/hash-drift.sh
#
# Tests for the producer-consumer hash-drift gate (#90).

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/hash-drift.sh"
	TEST_TMP=$(mktemp -d -t hash-drift.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */hash-drift.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Helper: build a producer-side repo with hooks/ + _lib/ files.
_make_producer() {
	local root=$1
	(
		cd "$root" || exit 1
		git init -q
		mkdir -p hooks _lib
		printf 'echo hook1\n' >hooks/foo.sh
		printf 'echo hook2\n' >hooks/bar.sh
		printf 'echo lib1\n' >_lib/baz.sh
	)
}

# Helper: build a consumer-side repo with .claude/{hooks,_lib} + plugin cache.
_make_consumer() {
	local consumer=$1 plugin=$2
	(
		cd "$consumer" || exit 1
		git init -q
		mkdir -p .claude/hooks .claude/_lib
		# Mirror plugin files into consumer's .claude/ tree.
		cp "$plugin/hooks/foo.sh" .claude/hooks/foo.sh
		cp "$plugin/hooks/bar.sh" .claude/hooks/bar.sh
		cp "$plugin/_lib/baz.sh" .claude/_lib/baz.sh
		# Mirror plugin's .source-hashes.json into the plugin-cache location.
		mkdir -p plugin-cache/.claude
		cp "$plugin/.claude/.source-hashes.json" plugin-cache/.claude/.source-hashes.json
	)
}

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

@test "--generate writes valid JSON with hook + _lib entries (schema_version:1)" {
	PRODUCER="$TEST_TMP/producer"
	mkdir -p "$PRODUCER"
	_make_producer "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	[ -f "$PRODUCER/.claude/.source-hashes.json" ]
	jq empty "$PRODUCER/.claude/.source-hashes.json"
	# v0.18.1 (#140): schema-wrapped manifest with metadata + .files entries.
	[ "$(jq -r '.schema_version' "$PRODUCER/.claude/.source-hashes.json")" = "1" ]
	[ "$(jq -r '.algorithm' "$PRODUCER/.claude/.source-hashes.json")" = "sha256" ]
	# 3 file entries: hooks/foo.sh, hooks/bar.sh, _lib/baz.sh.
	[ "$(jq '.files | length' "$PRODUCER/.claude/.source-hashes.json")" -eq 3 ]
	# Each value is a 64-char hex hash.
	jq -r '.files[] | length' "$PRODUCER/.claude/.source-hashes.json" | sort -u | grep -q '^64$'
}

@test "--verify clean: identical files → exit 0 + clean message" {
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	_make_consumer "$CONSUMER" "$PRODUCER"
	run bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"clean"* ]]
	[[ $output == *"3 files match"* ]]
}

@test "--verify drift: consumer-edited file → exit 1 with drift report" {
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	_make_consumer "$CONSUMER" "$PRODUCER"
	# Consumer modifies one hook.
	printf 'echo DRIFTED\n' >"$CONSUMER/.claude/hooks/foo.sh"
	run bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache' 2>&1"
	[ "$status" -eq 1 ]
	[[ $output == *"drifted from plugin source"* ]]
	[[ $output == *".claude/hooks/foo.sh"* ]]
	[[ $output == *"local-overrides.yml"* ]]
}

@test "--verify override: drifted file in override list → silent + clean" {
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	_make_consumer "$CONSUMER" "$PRODUCER"
	# Consumer modifies + adds to override list.
	printf 'echo LOCAL OVERRIDE\n' >"$CONSUMER/.claude/hooks/foo.sh"
	cat >"$CONSUMER/.claude/local-overrides.yml" <<'EOF'
# Local overrides — files we intentionally diverge from plugin source.
.claude/hooks/foo.sh: project-specific tweak
EOF
	run bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"clean"* ]]
	[[ $output == *"1 overridden"* ]]
}

@test "--verify with .source-hashes.json missing → silent no-op (exit 0)" {
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$CONSUMER/plugin-cache/.claude"
	(cd "$CONSUMER" && git init -q)
	run bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"predates #90"* ]]
}

@test "--verify with malformed .source-hashes.json → exit 2" {
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$CONSUMER/plugin-cache/.claude"
	echo "{ broken" >"$CONSUMER/plugin-cache/.claude/.source-hashes.json"
	(cd "$CONSUMER" && git init -q)
	run bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache' 2>&1"
	[ "$status" -eq 2 ]
	[[ $output == *"malformed"* ]]
}

@test "--verify consumer missing a producer file → not drift (counts as missing)" {
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	_make_consumer "$CONSUMER" "$PRODUCER"
	# Consumer deletes one hook (not installed locally).
	rm "$CONSUMER/.claude/hooks/foo.sh"
	run bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"clean"* ]]
	[[ $output == *"1 not-installed"* ]]
}

@test "--generate is idempotent (same content → same hashes)" {
	PRODUCER="$TEST_TMP/producer"
	mkdir -p "$PRODUCER"
	_make_producer "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	first=$(jq -S . "$PRODUCER/.claude/.source-hashes.json")
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	second=$(jq -S . "$PRODUCER/.claude/.source-hashes.json")
	[ "$first" = "$second" ]
}

@test "--verify both directions (producer-newer vs consumer-edited)" {
	# Producer ships v1, consumer installs v1 cleanly → clean.
	# Producer edits → ships v2 hashes. Consumer still has v1 → drift.
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	_make_consumer "$CONSUMER" "$PRODUCER"

	# Producer edits hook + regenerates hashes.
	printf 'echo PRODUCER-NEW\n' >"$PRODUCER/hooks/foo.sh"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	# Re-sync the hashes.json into consumer's plugin-cache (release.sh
	# would do this).
	cp "$PRODUCER/.claude/.source-hashes.json" "$CONSUMER/plugin-cache/.claude/.source-hashes.json"

	# Consumer's local .claude/hooks/foo.sh is still old.
	run bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache' 2>&1"
	[ "$status" -eq 1 ]
	[[ $output == *"drifted"* ]]
	[[ $output == *"foo.sh"* ]]
}
