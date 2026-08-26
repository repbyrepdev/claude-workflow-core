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
	[[ $output == *"clean"* ]] || return 1
	[[ $output == *"3 files match"* ]]
}

@test "--generate emits skills/ship-pr-cycle/run.sh + --verify maps it under .claude/skills (#2237)" {
	# #2237: the wrapper is the ONE skills/ file that is hashed (it resolves
	# the pinned-cache driver). --generate must emit it and --verify must map
	# skills/* under the consumer's .claude/skills/ (mirroring hooks/_lib).
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer "$PRODUCER"
	mkdir -p "$PRODUCER/skills/ship-pr-cycle"
	printf 'echo wrapper\n' >"$PRODUCER/skills/ship-pr-cycle/run.sh"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	# --generate emitted the wrapper key (the #2237 generate block).
	[ "$(jq -r '.files | has("skills/ship-pr-cycle/run.sh")' "$PRODUCER/.claude/.source-hashes.json")" = "true" ]
	_make_consumer "$CONSUMER" "$PRODUCER"
	mkdir -p "$CONSUMER/.claude/skills/ship-pr-cycle"
	cp "$PRODUCER/skills/ship-pr-cycle/run.sh" "$CONSUMER/.claude/skills/ship-pr-cycle/run.sh"
	run bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"clean"* ]] || return 1
	[[ $output == *"4 files match"* ]]
}

@test "--verify reports skills wrapper drift at .claude/skills path, NOT repo-root (#2237)" {
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer "$PRODUCER"
	mkdir -p "$PRODUCER/skills/ship-pr-cycle"
	printf 'echo wrapper\n' >"$PRODUCER/skills/ship-pr-cycle/run.sh"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	_make_consumer "$CONSUMER" "$PRODUCER"
	mkdir -p "$CONSUMER/.claude/skills/ship-pr-cycle"
	printf 'echo DRIFTED\n' >"$CONSUMER/.claude/skills/ship-pr-cycle/run.sh"
	run bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache' 2>&1"
	[ "$status" -eq 1 ]
	[[ $output == *".claude/skills/ship-pr-cycle/run.sh"* ]]
}

@test "--generate ABORTS when a plugin (plugin.json) is missing the coupled wrapper (#2238 CR)" {
	# In the real plugin the wrapper MUST exist; silently skipping it would drop
	# drift coverage. Refuse loud.
	PRODUCER="$TEST_TMP/producer-plugin"
	mkdir -p "$PRODUCER/.claude-plugin"
	_make_producer "$PRODUCER"
	echo '{"name":"x","version":"9.9.9"}' >"$PRODUCER/.claude-plugin/plugin.json"
	# Deliberately NO skills/ship-pr-cycle/run.sh.
	run bash -c "cd '$PRODUCER' && bash '$SCRIPT' --generate"
	[ "$status" -eq 2 ]
	[[ $output == *"refusing a coverage hole"* ]]
}

@test "--generate SKIPS the wrapper for a minimal producer (no plugin.json), no abort (#2238 CR)" {
	# Minimal/test producers legitimately lack the wrapper — must still generate
	# hooks/_lib without aborting (regression lock for the plugin-aware guard).
	PRODUCER="$TEST_TMP/producer-min"
	mkdir -p "$PRODUCER"
	_make_producer "$PRODUCER"
	run bash -c "cd '$PRODUCER' && bash '$SCRIPT' --generate"
	[ "$status" -eq 0 ]
	[ -f "$PRODUCER/.claude/.source-hashes.json" ]
	[ "$(jq -r '.files | has("skills/ship-pr-cycle/run.sh")' "$PRODUCER/.claude/.source-hashes.json")" = "false" ]
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
	[[ $output == *"drifted from plugin source"* ]] || return 1
	[[ $output == *".claude/hooks/foo.sh"* ]] || return 1
	[[ $output == *"local-overrides.yml"* ]]
}

@test "--verify override: drifted file in override list → silent + clean" {
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	_make_consumer "$CONSUMER" "$PRODUCER"
	# Consumer modifies + adds to override list. #2224: use the STRUCTURED
	# `overrides:` schema (the canonical shape the template + schema-check gate +
	# refresh-from-source all use). hash-drift.sh now parses it via yq, matching
	# those readers — the prior flat `path: reason` form is no longer the schema.
	printf 'echo LOCAL OVERRIDE\n' >"$CONSUMER/.claude/hooks/foo.sh"
	cat >"$CONSUMER/.claude/local-overrides.yml" <<'EOF'
# Local overrides — files we intentionally diverge from plugin source.
schema_version: 1
overrides:
  - path: .claude/hooks/foo.sh
    category: domain-extension
    reason: project-specific tweak
    added: "2026-06-01"
EOF
	run bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"clean"* ]] || return 1
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
	[[ $output == *"clean"* ]] || return 1
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
	[[ $output == *"drifted"* ]] || return 1
	[[ $output == *"foo.sh"* ]]
}

# ---------------------------------------------------------------------------
# #232 — .github byte-SSOT coverage (process templates declared `hashed: true`
# in scripts/bootstrap-manifest.yml). Producer-side: generation hashes them.
# Consumer-side: verify maps .github/* to the consumer REPO ROOT (not under
# .claude/, the way hooks/_lib map).
# ---------------------------------------------------------------------------

# Producer with hooks/_lib AND a bootstrap-manifest declaring 3 hashed .github
# process templates + 1 NON-hashed .github file (labels.yml, intentionally not
# created — proves the selector only touches `hashed: true` and the missing-
# file check is scoped to hashed entries).
_make_producer_gh() {
	local root=$1
	(
		cd "$root" || exit 1
		git init -q
		mkdir -p hooks _lib scripts .github/ISSUE_TEMPLATE
		printf 'echo hook1\n' >hooks/foo.sh
		printf 'echo lib1\n' >_lib/baz.sh
		printf '## Summary\n' >.github/pull_request_template.md
		printf 'schema:\n  subject:\n    max_length: 70\n' >.github/commit-template.yml
		printf 'name: Bug\n' >.github/ISSUE_TEMPLATE/bug.yml
		cat >scripts/bootstrap-manifest.yml <<'EOF'
schema_version: 1
files:
  - path: .github/pull_request_template.md
    mode: "644"
    hashed: true
  - path: .github/commit-template.yml
    mode: "644"
    hashed: true
  - path: .github/ISSUE_TEMPLATE/bug.yml
    mode: "644"
    hashed: true
  - path: .github/labels.yml
    mode: "644"
EOF
	)
}

# Consumer mirror: hooks/_lib under .claude/, but .github/* VERBATIM at the
# consumer root (the path-mapping under test).
_make_consumer_gh() {
	local consumer=$1 plugin=$2
	(
		cd "$consumer" || exit 1
		git init -q
		mkdir -p .claude/hooks .claude/_lib .github/ISSUE_TEMPLATE
		cp "$plugin/hooks/foo.sh" .claude/hooks/foo.sh
		cp "$plugin/_lib/baz.sh" .claude/_lib/baz.sh
		cp "$plugin/.github/pull_request_template.md" .github/pull_request_template.md
		cp "$plugin/.github/commit-template.yml" .github/commit-template.yml
		cp "$plugin/.github/ISSUE_TEMPLATE/bug.yml" .github/ISSUE_TEMPLATE/bug.yml
		mkdir -p plugin-cache/.claude
		cp "$plugin/.claude/.source-hashes.json" plugin-cache/.claude/.source-hashes.json
	)
}

@test "--generate hashes manifest hashed:true .github files, skips non-hashed (#232)" {
	PRODUCER="$TEST_TMP/producer"
	mkdir -p "$PRODUCER"
	_make_producer_gh "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	M="$PRODUCER/.claude/.source-hashes.json"
	# 2 (hooks/_lib) + 3 (hashed .github) = 5; labels.yml (not hashed) excluded.
	[ "$(jq '.files | length' "$M")" -eq 5 ]
	jq -e '.files[".github/pull_request_template.md"]' "$M"
	jq -e '.files[".github/commit-template.yml"]' "$M"
	jq -e '.files[".github/ISSUE_TEMPLATE/bug.yml"]' "$M"
	# labels.yml is in the manifest but NOT hashed:true → must be absent.
	run jq -e '.files[".github/labels.yml"]' "$M"
	[ "$status" -ne 0 ]
}

@test "--generate FAILS CLOSED when a hashed:true file is missing (#232)" {
	PRODUCER="$TEST_TMP/producer"
	mkdir -p "$PRODUCER"
	_make_producer_gh "$PRODUCER"
	# Remove a DECLARED hashed file → coverage hole must abort generation.
	rm "$PRODUCER/.github/commit-template.yml"
	run bash -c "cd '$PRODUCER' && bash '$SCRIPT' --generate 2>&1"
	[ "$status" -eq 2 ]
	[[ $output == *"coverage hole"* || $output == *"missing"* ]]
}

@test "--verify clean: .github files map to consumer REPO ROOT (#232)" {
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer_gh "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	_make_consumer_gh "$CONSUMER" "$PRODUCER"
	run bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"clean"* ]] || return 1
	[[ $output == *"5 files match"* ]]
}

@test "--verify .github drift → exit 1, reports repo-root path NOT .claude/.github (#232)" {
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer_gh "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	_make_consumer_gh "$CONSUMER" "$PRODUCER"
	# Drift the consumer's .github commit-template.
	printf 'schema:\n  subject:\n    max_length: 50\n' >"$CONSUMER/.github/commit-template.yml"
	run bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache' 2>&1"
	[ "$status" -eq 1 ]
	[[ $output == *"drifted from plugin source"* ]] || return 1
	[[ $output == *".github/commit-template.yml"* ]] || return 1
	# The pre-#232 bug signature: mapping .github under .claude/ would print
	# `.claude/.github/...` and silently never find the file. Must NOT appear.
	[[ $output != *".claude/.github"* ]]
}

@test "--verify .github file absent on consumer → not-installed, not drift (#232)" {
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer_gh "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	_make_consumer_gh "$CONSUMER" "$PRODUCER"
	# Consumer never installed the issue template.
	rm "$CONSUMER/.github/ISSUE_TEMPLATE/bug.yml"
	run bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"clean"* ]] || return 1
	[[ $output == *"1 not-installed"* ]]
}

@test "--verify MIXED drift: hooks AND .github both drift → exit 1, both reported (#232 r2)" {
	# pr-test-analyzer r1: single-category tests each flex only ONE arm of the
	# path-mapping case. A mixed run is the only test proving both branches
	# (.claude/ for hooks, verbatim for .github) fire correctly in ONE pass.
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer_gh "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	_make_consumer_gh "$CONSUMER" "$PRODUCER"
	# Drift BOTH a hooks file AND a .github file.
	printf 'echo DRIFTED\n' >"$CONSUMER/.claude/hooks/foo.sh"
	printf 'schema:\n  subject:\n    max_length: 50\n' >"$CONSUMER/.github/commit-template.yml"
	run bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache' 2>&1"
	[ "$status" -eq 1 ]
	[[ $output == *".claude/hooks/foo.sh"* ]] || return 1        # hooks arm → under .claude/
	[[ $output == *".github/commit-template.yml"* ]] || return 1 # .github arm → repo root
	[[ $output != *".claude/.github"* ]] || return 1             # never the mis-mapped form
	[[ $output == *"2 file(s) drifted"* ]]                       # both counted, mapping intact
}

@test "--generate FAILS CLOSED when yq missing but manifest present (#232 r2)" {
	# pr-test-analyzer r1: the `command -v yq || exit 2` branch (manifest
	# present, yq unavailable) must fail closed — never silently emit a
	# hooks/_lib-only manifest that drops .github coverage. Build a PATH shim
	# with every tool --generate needs EXCEPT yq so the branch fires.
	PRODUCER="$TEST_TMP/producer"
	mkdir -p "$PRODUCER"
	_make_producer_gh "$PRODUCER"
	SHIM="$TEST_TMP/shim"
	mkdir -p "$SHIM"
	for t in bash git jq find sort shasum sha256sum awk mktemp rm mkdir sed grep cat dirname env; do
		p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$SHIM/$t"
	done
	# Sanity: yq must NOT resolve under the shim PATH (else the test is moot).
	run env PATH="$SHIM" bash -c 'command -v yq'
	[ "$status" -ne 0 ]
	# --generate with the yq-less PATH; manifest present → must exit 2.
	run env PATH="$SHIM" bash -c "cd '$PRODUCER' && bash '$SCRIPT' --generate"
	[ "$status" -eq 2 ]
	[[ $output == *"yq required"* ]]
}

@test "--generate FAILS CLOSED on a non-boolean hashed: value (typo guard) (#232 r2)" {
	# silent-failure-hunter r1: a typo'd `hashed: ture` (or `yes`) is parsed as
	# a string, so yq's `== true` selector silently skips it → coverage hole
	# with no signal. The tag-validation guard must catch it and exit 2.
	PRODUCER="$TEST_TMP/producer"
	mkdir -p "$PRODUCER"
	_make_producer_gh "$PRODUCER"
	# Corrupt one hashed value to a typo.
	yq -i '(.files[] | select(.path == ".github/commit-template.yml") | .hashed) = "ture"' \
		"$PRODUCER/scripts/bootstrap-manifest.yml"
	run bash -c "cd '$PRODUCER' && bash '$SCRIPT' --generate"
	[ "$status" -eq 2 ]
	[[ $output == *"non-boolean hashed"* ]] || return 1
	[[ $output == *".github/commit-template.yml"* ]]
}

# ---------------------------------------------------------------------------
# v0.34.29 (#2224) — STRUCTURED `overrides:` parser (yq '.overrides[].path').
# The prior flat `grep|sed` parser extracted text-before-the-first-colon, which
# on the structured schema yields the metadata KEYS (schema_version, overrides,
# category, reason, added) as garbage "paths" instead of the real override
# paths. These tests regression-lock the new parser: a non-path key must NOT
# suppress a genuinely-drifted file, yq-absence must fail closed, and malformed
# or path-less entries must be handled safely.
# ---------------------------------------------------------------------------

@test "--verify NEGATIVE-LOCK: structured override suppresses foo, but drifted bar.sh (not overridden) IS reported (#2224)" {
	# The #2224 fix: `yq '.overrides[].path'` extracts ONLY the path values, not
	# the sibling metadata keys. The OLD grep|sed parser extracted
	# schema_version/category/reason/added as phantom override paths — none of
	# which match a real consumer path, so they were harmless noise — BUT the OLD
	# parser ALSO never extracted the real `path:` value (it sat after `- path:`,
	# not at line-start), so the legitimate override was NOT honored and the file
	# was reported as drift. Conversely a genuinely-drifted, NON-overridden file
	# (bar.sh) must STILL be reported. This test pins BOTH halves: foo.sh
	# overridden+suppressed, bar.sh drifted+reported. A revert to grep|sed FAILS
	# here (foo.sh would NOT be suppressed → drift_count=2, message lists foo.sh).
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	_make_consumer "$CONSUMER" "$PRODUCER"
	# Drift BOTH foo.sh (overridden) AND bar.sh (NOT overridden).
	printf 'echo FOO LOCAL OVERRIDE\n' >"$CONSUMER/.claude/hooks/foo.sh"
	printf 'echo BAR GENUINE DRIFT\n' >"$CONSUMER/.claude/hooks/bar.sh"
	# Override declares ONLY foo.sh — bar.sh is genuine, un-declared drift.
	cat >"$CONSUMER/.claude/local-overrides.yml" <<'EOF'
schema_version: 1
overrides:
  - path: .claude/hooks/foo.sh
    category: domain-extension
    reason: project-specific tweak
    added: "2026-06-01"
EOF
	run bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache' 2>&1"
	# bar.sh drift → exit 1.
	[ "$status" -eq 1 ]
	# bar.sh IS reported as drift (the un-overridden, genuinely-drifted file).
	[[ $output == *".claude/hooks/bar.sh"* ]] || return 1
	# Exactly ONE file drifted — foo.sh is suppressed by the override, so a
	# phantom-key extraction (grep|sed) that failed to honor foo.sh would make
	# this "2 file(s) drifted" + list foo.sh → revert tripwire.
	[[ $output == *"1 file(s) drifted"* ]] || return 1
	# Drift-branch summary phrasing is `overridden: N` (clean-branch is `N overridden`).
	[[ $output == *"overridden: 1"* ]] || return 1
	# foo.sh must NOT appear in the drift report (it is overridden).
	[[ $output != *".claude/hooks/foo.sh"* ]]
}

@test "--verify FAILS CLOSED when overrides file present but yq missing (#2224)" {
	# pr-test-analyzer: the consumer-side `command -v yq || exit 2` branch — an
	# overrides file present with yq unavailable must fail closed (never fall
	# back to a parser that silently mishandles the structured schema). PATH-shim
	# pattern mirroring the producer-side yq-missing test above.
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	_make_consumer "$CONSUMER" "$PRODUCER"
	# An overrides file must be PRESENT for the yq guard to fire.
	cat >"$CONSUMER/.claude/local-overrides.yml" <<'EOF'
schema_version: 1
overrides:
  - path: .claude/hooks/foo.sh
    category: domain-extension
    reason: x
    added: "2026-06-01"
EOF
	SHIM="$TEST_TMP/shim"
	mkdir -p "$SHIM"
	# Every tool consumer-verify needs EXCEPT yq (jq IS present; mktemp/cat for
	# the override-parse error path).
	for t in bash git jq find sort shasum sha256sum awk mktemp rm mkdir sed grep cat dirname env; do
		p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$SHIM/$t"
	done
	# Sanity: yq must NOT resolve under the shim PATH (else the test is moot).
	run env PATH="$SHIM" bash -c 'command -v yq'
	[ "$status" -ne 0 ]
	run env PATH="$SHIM" bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache'"
	[ "$status" -eq 2 ]
	[[ $output == *"yq required"* ]]
}

@test "--verify FAILS CLOSED on malformed overrides YAML (yq parse failure → exit 2 + stderr) (#2224)" {
	# pr-test-analyzer: syntactically-broken overrides YAML must surface yq's
	# parse failure (exit 2 + stderr passthrough), not silently treat the file as
	# having no overrides (which would mis-report a legit override as drift).
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	_make_consumer "$CONSUMER" "$PRODUCER"
	# Broken YAML: unbalanced flow-mapping bracket → yq parse error.
	printf 'overrides: [ { path: .claude/hooks/foo.sh, \n' >"$CONSUMER/.claude/local-overrides.yml"
	run bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache' 2>&1"
	[ "$status" -eq 2 ]
	[[ $output == *"yq failed parsing"* ]]
}

@test "--verify path-less override entry parses cleanly + doesn't suppress real drift; sibling honored (#2224)" {
	# pr-test-analyzer + CR phase2 r1: a structured entry MISSING its `path:`
	# field makes `.overrides[].path` emit the literal "null", which the
	# `!= "null"` guard drops. The guard is DEFENSIVE DEPTH and its drop is not
	# separately observable here (a tracked file cannot have the literal path
	# "null", so the count is `overridden: 1` with or without the guard). This
	# test therefore asserts the OBSERVABLE behavior: the path-less entry parses
	# without error, does NOT suppress a genuine drift (bar.sh still reported),
	# and the VALID sibling override (foo.sh) is still honored.
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	_make_consumer "$CONSUMER" "$PRODUCER"
	# Drift foo.sh (declared via a valid entry) AND bar.sh (NOT overridden — the
	# path-less entry must NOT accidentally cover it).
	printf 'echo FOO OVERRIDE\n' >"$CONSUMER/.claude/hooks/foo.sh"
	printf 'echo BAR DRIFT\n' >"$CONSUMER/.claude/hooks/bar.sh"
	cat >"$CONSUMER/.claude/local-overrides.yml" <<'EOF'
schema_version: 1
overrides:
  - path: .claude/hooks/foo.sh
    category: domain-extension
    reason: valid sibling override
    added: "2026-06-01"
  - category: legacy
    reason: this entry has NO path field — yields literal "null"
    added: "2026-06-01"
EOF
	run bash -c "cd '$CONSUMER' && bash '$SCRIPT' --verify --plugin-cache '$CONSUMER/plugin-cache' 2>&1"
	# bar.sh still drifts (path-less entry did NOT suppress it) → exit 1.
	[ "$status" -eq 1 ]
	[[ $output == *".claude/hooks/bar.sh"* ]] || return 1
	# foo.sh honored by the valid sibling → not in the drift report, counted overridden.
	[[ $output != *".claude/hooks/foo.sh"* ]] || return 1
	[[ $output == *"1 file(s) drifted"* ]] || return 1
	# Drift-branch summary phrasing is `overridden: N`.
	[[ $output == *"overridden: 1"* ]]
}

# ---------------------------------------------------------------------------
# #2331 — pin-aware cache resolution. When --plugin-cache is NOT supplied,
# --verify resolves the cache from the version the consumer PINS
# (.pre-commit-config.yaml `rev:` for the claude-workflow-core repo), NOT the
# highest-semver cache. Comparing mirrors against a different version than the
# one pinned reports false "drift" (version skew). Falls back to highest-semver
# (with a NOTE) only when the pinned version is not installed. These exercise
# the auto-discovery branch (no --plugin-cache), unlike the tests above.
# ---------------------------------------------------------------------------

@test "--verify pin-aware: picks the PINNED cache version, not the highest (#2331)" {
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	# Consumer mirrors == this (the PINNED 0.34.50) version.
	_make_consumer "$CONSUMER" "$PRODUCER"
	BASE="$TEST_TMP/cachebase"
	mkdir -p "$BASE/0.34.50/.claude" "$BASE/0.34.52/.claude"
	cp "$PRODUCER/.claude/.source-hashes.json" "$BASE/0.34.50/.claude/.source-hashes.json"
	# Build a HIGHER 0.34.52 cache with DIFFERENT hashes (edit a producer file +
	# regen) — the consumer would falsely "drift" against it if it were picked.
	printf 'echo HIGHER-VERSION\n' >"$PRODUCER/hooks/foo.sh"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	cp "$PRODUCER/.claude/.source-hashes.json" "$BASE/0.34.52/.claude/.source-hashes.json"
	# Consumer pins v0.34.50 (NOT the highest installed, 0.34.52).
	cat >"$CONSUMER/.pre-commit-config.yaml" <<'EOF'
repos:
  - repo: https://github.com/repbyrepdev/claude-workflow-core
    rev: v0.34.50
    hooks:
      - id: hash-drift-verify
EOF
	# No --plugin-cache → exercises the auto-discovery (pin-aware) block.
	run bash -c "cd '$CONSUMER' && HASH_DRIFT_PLUGIN_CACHE_BASE='$BASE' bash '$SCRIPT' --verify 2>&1"
	# Pinned 0.34.50 matches the consumer mirrors → clean. The OLD highest-semver
	# behavior would pick 0.34.52 → foo.sh drift → exit 1 (regression tripwire).
	[ "$status" -eq 0 ]
	[[ $output == *"clean"* ]]
}

@test "--verify skew fallback: pinned version absent from cache → highest-semver + NOTE (#2331)" {
	PRODUCER="$TEST_TMP/producer"
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$PRODUCER" "$CONSUMER"
	_make_producer "$PRODUCER"
	(cd "$PRODUCER" && bash "$SCRIPT" --generate)
	_make_consumer "$CONSUMER" "$PRODUCER"
	BASE="$TEST_TMP/cachebase"
	mkdir -p "$BASE/0.34.52/.claude"
	cp "$PRODUCER/.claude/.source-hashes.json" "$BASE/0.34.52/.claude/.source-hashes.json"
	# Consumer pins a version that has NO installed cache.
	cat >"$CONSUMER/.pre-commit-config.yaml" <<'EOF'
repos:
  - repo: https://github.com/repbyrepdev/claude-workflow-core
    rev: v0.99.0
    hooks:
      - id: hash-drift-verify
EOF
	run bash -c "cd '$CONSUMER' && HASH_DRIFT_PLUGIN_CACHE_BASE='$BASE' bash '$SCRIPT' --verify 2>&1"
	# Fallback cache 0.34.52 == the consumer mirrors → clean exit 0 (CR r1 major).
	[ "$status" -eq 0 ]
	# Falls back to the only installed cache (0.34.52) and emits the skew NOTE so
	# the operator isn't misled into thinking it verified against the pinned ver.
	[[ $output == *"NOTE pinned plugin v0.99.0 has no installed cache"* ]] || return 1
	[[ $output == *"comparing against installed v0.34.52"* ]]
}

@test "#2237 coupled-wrapper coverage-hole refusal is a positive contract (#2552, p1r1: moved here from the regen-gate suite for covers: routing)" {
	# Until #2552 this refusal was only ever OBSERVED accidentally — as the
	# mystery rc=2 that broke the regen-gate suite. Pin it deliberately: a
	# plugin (plugin.json present) whose skills/ship-pr-cycle/run.sh is
	# missing must refuse generation rather than emit a hash set with a
	# coverage hole for the coupled wrapper.
	mkdir -p "$TEST_TMP/plug"
	(
		set -e
		cd "$TEST_TMP/plug"
		git init -q
		mkdir -p .claude-plugin hooks _lib scripts
		echo '{"version":"0.0.0"}' >.claude-plugin/plugin.json
		printf '#!/bin/bash\necho v1\n' >hooks/h.sh
		cp "$SCRIPT" scripts/hash-drift.sh
		chmod +x scripts/hash-drift.sh hooks/h.sh
		# deliberately NO skills/ship-pr-cycle/run.sh
	)
	cd "$TEST_TMP/plug" || return 1
	run scripts/hash-drift.sh --generate
	[ "$status" -eq 2 ]
	[[ $output == *"refusing a coverage hole for the coupled wrapper"* ]]
}
