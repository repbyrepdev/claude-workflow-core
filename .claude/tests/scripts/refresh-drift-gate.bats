#!/usr/bin/env bats
# covers: scripts/refresh-from-source.sh
#
# #2525 mirror-test drift gate: a cascade re-pin updates the consumer's
# mirror HOOKS but not the consumer's local bats copies of them, so the
# tests drift from the hook contract and go red — silently, since consumer
# bats is not a required CI check. The gate runs the covering consumer bats
# for every replaced mirror hook at REFRESH time and fails loud (rc=4) on
# drift, so it can never merge unseen.
#
# Each test builds a self-contained scratch PLUGIN tree (so PLUGIN_ROOT
# resolves to the scratch, not the real repo) + a scratch CONSUMER, then
# drives the REAL refresh-from-source.sh against them.

setup() {
	# Hard-fail (not `skip`) on a missing prerequisite: a skipped bats test
	# counts as passing, so skipping here would silently green the whole
	# drift-gate suite in a lean env — the exact "bats skip = pass" trap
	# this gate exists to catch. In CI these tools are always present, so
	# this only fires (loudly) on a genuinely-broken dev environment.
	local t
	for t in yq jq; do
		command -v "$t" >/dev/null || {
			echo "FATAL: required tool '$t' missing — cannot verify the drift gate" >&2
			return 1
		}
	done
	REAL_SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/refresh-from-source.sh"
	[ -f "$REAL_SCRIPT" ] || {
		echo "FATAL: refresh-from-source.sh not found at $REAL_SCRIPT" >&2
		return 1
	}
	TEST_TMP=$(mktemp -d -t rfs-drift.XXXXXX) || {
		echo "FATAL mktemp" >&2
		return 1
	}
	PLUGIN="$TEST_TMP/plugin"
	CONSUMER="$TEST_TMP/consumer"
	_build_plugin
	_build_consumer
}

teardown() {
	cd /tmp 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */rfs-drift.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Scratch plugin: the script derives PLUGIN_ROOT from its own dir, so the
# copy at $PLUGIN/scripts/ makes PLUGIN_ROOT=$PLUGIN. The SSOT list needs
# only correct KEYS (paths); hash VALUES are recomputed live, so dummies are
# fine. The mirror sources are the NEW contract. Includes a hook, a second
# hook, a skill run.sh, and a non-hook (.github) file to exercise tracking.
_build_plugin() {
	mkdir -p "$PLUGIN/scripts" "$PLUGIN/hooks" "$PLUGIN/_lib" "$PLUGIN/skills/myskill" \
		"$PLUGIN/.github" "$PLUGIN/.claude" "$PLUGIN/.claude-plugin"
	cp "$REAL_SCRIPT" "$PLUGIN/scripts/refresh-from-source.sh"
	chmod +x "$PLUGIN/scripts/refresh-from-source.sh"
	printf '#!/usr/bin/env bash\necho new\n' >"$PLUGIN/hooks/testhook.sh"
	printf '#!/usr/bin/env bash\necho other-new\n' >"$PLUGIN/hooks/other.sh"
	printf '#!/usr/bin/env bash\n: lib\n' >"$PLUGIN/_lib/broken.sh"
	printf '#!/usr/bin/env bash\necho skill-new\n' >"$PLUGIN/skills/myskill/run.sh"
	printf 'new-config\n' >"$PLUGIN/.github/thing.yml"
	chmod +x "$PLUGIN/hooks/testhook.sh" "$PLUGIN/hooks/other.sh" \
		"$PLUGIN/_lib/broken.sh" "$PLUGIN/skills/myskill/run.sh"
	local dummy='0000000000000000000000000000000000000000000000000000000000000000'
	jq -n --arg h "$dummy" '{files: {
		"hooks/testhook.sh": $h,
		"hooks/other.sh": $h,
		"_lib/broken.sh": $h,
		"skills/myskill/run.sh": $h,
		".github/thing.yml": $h
	}}' >"$PLUGIN/.claude/.source-hashes.json"
	printf '{"name":"t","version":"9.9.9"}\n' >"$PLUGIN/.claude-plugin/plugin.json"
	printf 'consumers: []\n' >"$PLUGIN/.github/consumers.yml"
}

# Scratch consumer: OLD mirror files (different hash → refresh REPLACES) +
# a covering bats for testhook (body written per-test). Only testhook +
# its test are seeded by default; other files are added per-test.
_build_consumer() {
	mkdir -p "$CONSUMER/.claude/hooks" "$CONSUMER/.claude/tests/hooks" "$CONSUMER/.github"
	printf '#!/usr/bin/env bash\necho old\n' >"$CONSUMER/.claude/hooks/testhook.sh"
	printf 'old-config\n' >"$CONSUMER/.github/thing.yml"
	chmod +x "$CONSUMER/.claude/hooks/testhook.sh"
}

# Write a covering bats for a hook asserting a given expected output.
# $1=hook basename (no .sh)  $2=expected output  [$3=extra body lines]
_write_test() {
	cat >"$CONSUMER/.claude/tests/hooks/$1.bats" <<EOF
#!/usr/bin/env bats
# covers: .claude/hooks/$1.sh
@test "$1 emits the expected contract" {
	${3:-}
	run bash "\$BATS_TEST_DIRNAME/../../hooks/$1.sh"
	[ "\$status" -eq 0 ]
	[ "\$output" = "$2" ]
}
EOF
}

_refresh() { run bash "$PLUGIN/scripts/refresh-from-source.sh" "$@"; }

@test "gate: covering test matching the NEW contract → rc=0, verified" {
	_write_test testhook new
	_refresh --consumer-path "$CONSUMER"
	[ "$status" -eq 0 ]
	[[ $output == *"[REPLACED] hooks/testhook.sh"* ]]
	[[ $output == *"covering consumer tests passed"* ]]
	[ "$(bash "$CONSUMER/.claude/hooks/testhook.sh")" = "new" ]
}

@test "gate: STALE covering test (OLD contract) → rc=4 BLOCKED, hook replaced + audited" {
	_write_test testhook old
	_refresh --consumer-path "$CONSUMER"
	[ "$status" -eq 4 ]
	[[ $output == *"BLOCKED"* ]]
	[[ $output == *"testhook.bats"* ]]
	# Replaced-but-blocked: the gate runs AFTER replacement + audit, so the
	# operator must recover from a live-but-flagged change.
	[ "$(bash "$CONSUMER/.claude/hooks/testhook.sh")" = "new" ]
	[ -f "$CONSUMER/.claude/logs/refresh-from-source.jsonl" ]
}

@test "gate: SKIPPED covering test → UNVERIFIED warning, NOT a silent pass (bats skip=pass trap)" {
	# The covering test skips (as a lean-env `command -v foo || skip` guard
	# would). bats exits 0, but it verified NOTHING — the gate must warn,
	# not report a green pass.
	_write_test testhook new 'skip "dependency absent"'
	_refresh --consumer-path "$CONSUMER"
	[ "$status" -eq 0 ]
	[[ $output == *"UNVERIFIED"* ]] || [[ $output == *"NOT verified"* ]]
	# Must NOT claim a clean pass when the covering test only skipped.
	[[ $output != *"covering consumer tests passed against the refreshed hooks ✓"* ]]
}

@test "gate: drifted SKILL run.sh is tracked and gated (#2525 skills coverage)" {
	# skills/*/run.sh is in the SSOT sync set; a contract change must be
	# gated like a hook. Seed the OLD skill mirror + a stale covering test.
	mkdir -p "$CONSUMER/.claude/skills/myskill" "$CONSUMER/.claude/tests/skills"
	printf '#!/usr/bin/env bash\necho skill-old\n' >"$CONSUMER/.claude/skills/myskill/run.sh"
	chmod +x "$CONSUMER/.claude/skills/myskill/run.sh"
	cat >"$CONSUMER/.claude/tests/skills/myskill.bats" <<'EOF'
#!/usr/bin/env bats
# covers: .claude/skills/myskill/run.sh
@test "skill run emits contract" {
	run bash "$BATS_TEST_DIRNAME/../../skills/myskill/run.sh"
	[ "$output" = "skill-old" ]
}
EOF
	# testhook has no covering bats (setup seeds only the hook), so only the
	# skill drifts here — the scenario stays focused on skill gating.
	_refresh --consumer-path "$CONSUMER"
	[ "$status" -eq 4 ]
	[[ $output == *"myskill.bats"* ]]
}

@test "gate: skill basename collision — matching keys on the full path, not the shared run.sh" {
	# Every skill wrapper shares the basename run.sh, so a basename match
	# would pull in a bats covering a DIFFERENT skill. Replacing myskill/
	# run.sh must NOT run a RED test that covers otherskill/run.sh.
	mkdir -p "$CONSUMER/.claude/skills/myskill" \
		"$CONSUMER/.claude/skills/otherskill" "$CONSUMER/.claude/tests/skills"
	printf '#!/usr/bin/env bash\necho skill-old\n' >"$CONSUMER/.claude/skills/myskill/run.sh"
	printf '#!/usr/bin/env bash\necho other\n' >"$CONSUMER/.claude/skills/otherskill/run.sh"
	# A RED covering test for the OTHER skill's run.sh — must be ignored,
	# since otherskill is not in the sync set and did not drift.
	cat >"$CONSUMER/.claude/tests/skills/otherskill.bats" <<'EOF'
#!/usr/bin/env bats
# covers: .claude/skills/otherskill/run.sh
@test "other" { false; }
EOF
	# myskill drifts but has no covering test; a basename match would
	# wrongly grab otherskill.bats and block with rc=4.
	rm -f "$CONSUMER/.claude/tests/hooks/testhook.bats"
	_refresh --consumer-path "$CONSUMER"
	[ "$status" -eq 0 ]
	[[ $output == *"no consumer bats cover"* ]]
}

@test "gate: --dry-run never invokes the gate even with a stale test → rc=0" {
	_write_test testhook old
	_refresh --dry-run --consumer-path "$CONSUMER"
	[ "$status" -eq 0 ]
	[[ $output != *"drift-gate"* ]]
	[[ $output != *"BLOCKED"* ]]
}

@test "gate: no covering test → no-op, rc=0" {
	rm -f "$CONSUMER/.claude/tests/hooks/testhook.bats"
	_refresh --consumer-path "$CONSUMER"
	[ "$status" -eq 0 ]
	[[ $output == *"no consumer bats cover"* ]]
}

@test "gate: no .claude/tests tree → no-op with a note, rc=0" {
	rm -rf "$CONSUMER/.claude/tests"
	_refresh --consumer-path "$CONSUMER"
	[ "$status" -eq 0 ]
	[[ $output == *"no .claude/tests tree"* ]]
}

@test "gate: replacing only a non-hook (.github) file does NOT invoke the gate" {
	# Only .github/thing.yml drifts (hook + skill already match). The
	# tracking case excludes non-shell/non-mirror paths, so no gate runs.
	printf '#!/usr/bin/env bash\necho new\n' >"$CONSUMER/.claude/hooks/testhook.sh"
	_write_test testhook new
	_refresh --consumer-path "$CONSUMER"
	[ "$status" -eq 0 ]
	[[ $output == *"[REPLACED] .github/thing.yml"* ]]
	[[ $output != *"drift-gate] verifying"* ]]
}

@test "gate: grep is basename-anchored — foo.sh must not match barfoo.sh" {
	# A test covering a DIFFERENT hook whose basename ends in the replaced
	# hook's basename must not be pulled in. Cover 'xtesthook.sh' (a
	# non-replaced name) and assert the gate finds no covering test for the
	# replaced 'testhook.sh'.
	rm -f "$CONSUMER/.claude/tests/hooks/testhook.bats"
	cat >"$CONSUMER/.claude/tests/hooks/decoy.bats" <<'EOF'
#!/usr/bin/env bats
# covers: .claude/hooks/xtesthook.sh
@test "decoy" { true; }
EOF
	_refresh --consumer-path "$CONSUMER"
	[ "$status" -eq 0 ]
	[[ $output == *"no consumer bats cover"* ]]
}

@test "gate: partial-copy failure (rc=3) takes precedence over drift (rc=4)" {
	# The consumer's .claude/_lib is a FILE, so copying the mirror
	# _lib/broken.sh into it fails ("Not a directory" → n_failed>0),
	# WHILE testhook drifts. rc=3 (inconsistent state) must win over rc=4
	# (drift) — the n_failed check runs before the gate. Using an
	# unwritable destination parent instead of chmod 000 on the source
	# keeps the failure privilege-independent (root can read 000 files, so
	# a chmod-based shasum failure silently regresses to rc=4 under root).
	printf 'not-a-dir\n' >"$CONSUMER/.claude/_lib"
	_write_test testhook old
	_refresh --consumer-path "$CONSUMER"
	[ "$status" -eq 3 ]
}

@test "gate: multi-consumer — a drifted consumer surfaces exit 4 overall" {
	# Two --consumer-path targets: one clean, one drifted. The worst-rc
	# aggregation must exit 4, and a clean consumer processed after the
	# drifted one must not reset it.
	_write_test testhook new
	local CONSUMER2="$TEST_TMP/consumer2"
	mkdir -p "$CONSUMER2/.claude/hooks" "$CONSUMER2/.claude/tests/hooks"
	printf '#!/usr/bin/env bash\necho old\n' >"$CONSUMER2/.claude/hooks/testhook.sh"
	chmod +x "$CONSUMER2/.claude/hooks/testhook.sh"
	cat >"$CONSUMER2/.claude/tests/hooks/testhook.bats" <<'EOF'
#!/usr/bin/env bats
# covers: .claude/hooks/testhook.sh
@test "t" { run bash "$BATS_TEST_DIRNAME/../../hooks/testhook.sh"; [ "$output" = "old" ]; }
EOF
	# Drifted consumer2 processed AFTER clean consumer.
	_refresh --consumer-path "$CONSUMER" --consumer-path "$CONSUMER2"
	[ "$status" -eq 4 ]
}

@test "gate: one bats covering two replaced hooks runs once (dedup)" {
	# other.sh also drifts; a single bats covers BOTH testhook + other.
	printf '#!/usr/bin/env bash\necho old\n' >"$CONSUMER/.claude/hooks/other.sh"
	chmod +x "$CONSUMER/.claude/hooks/other.sh"
	rm -f "$CONSUMER/.claude/tests/hooks/testhook.bats"
	cat >"$CONSUMER/.claude/tests/hooks/combo.bats" <<'EOF'
#!/usr/bin/env bats
# covers: .claude/hooks/testhook.sh .claude/hooks/other.sh
@test "both" {
	[ "$(bash "$BATS_TEST_DIRNAME/../../hooks/testhook.sh")" = "new" ]
	[ "$(bash "$BATS_TEST_DIRNAME/../../hooks/other.sh")" = "other-new" ]
}
EOF
	_refresh --consumer-path "$CONSUMER"
	[ "$status" -eq 0 ]
	# "verifying 1 consumer bats" — the shared file is deduped to a single run.
	[[ $output == *"verifying 1 consumer bats"* ]]
}

@test "gate: REFRESH_DRIFT_GATE_SKIP=1 overrides a drifted test → rc=0" {
	_write_test testhook old
	run env REFRESH_DRIFT_GATE_SKIP=1 bash "$PLUGIN/scripts/refresh-from-source.sh" --consumer-path "$CONSUMER"
	[ "$status" -eq 0 ]
	[[ $output == *"drift-gate] skipped"* ]]
}
