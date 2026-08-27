#!/usr/bin/env bats
# covers: scripts/release.sh
#
# Regression tests for scripts/release.sh (#75). Covers arg parsing +
# precondition guards (not-a-git-repo, dirty tree, missing plugin.json,
# missing .version, version regression). Full --dry-run output structure
# coverage runs via the fixture-repo tests below.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/release.sh"
	# TEST_TMP — fresh tmpdir per test. Per repo standard `mktemp -d -t pfx.XXXXXX`.
	TEST_TMP=$(mktemp -d -t release-test.XXXXXX) || {
		echo "FATAL: mktemp -d failed" >&2
		return 1
	}
}

teardown() {
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */release-test.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# --- minimal fixture-repo helpers ------------------------------------

# Initializes $TEST_TMP as a git repo with a plugin.json at the given
# version + an initial commit. Returns with TEST_TMP as cwd.
_make_fixture_repo() {
	local version=${1:-0.1.0}
	cd "$TEST_TMP" || return 1
	git init -q
	git config user.email "test@test"
	git config user.name "test"
	mkdir -p .claude-plugin scripts .claude
	cat >.claude-plugin/plugin.json <<-EOF
		{
		  "name": "fixture",
		  "version": "$version",
		  "description": "fixture"
		}
	EOF
	# v0.18.1 #140: release.sh Step 2a requires hash-drift.sh + a fresh
	# .source-hashes.json. Stub hash-drift.sh so --generate writes a
	# stable empty-files manifest the diff check will accept.
	cat >scripts/hash-drift.sh <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "--generate" ] || exit 2
mkdir -p .claude
printf '{"schema_version":1,"algorithm":"sha256","producer_root":".","files":{}}\n' >.claude/.source-hashes.json
STUB
	chmod +x scripts/hash-drift.sh
	bash scripts/hash-drift.sh --generate
	git add . >/dev/null
	git commit -q -m "initial"
}

# --- arg parsing ------------------------------------------------------

@test "release.sh exists and is executable" {
	[ -x "$SCRIPT" ]
}

@test "--help shows usage including --notes flag" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"plugin.json"* ]] || return 1
	[[ $output == *"--notes"* ]] || return 1
	[[ $output == *"Exit codes"* ]] || return 1
	# Verify --help doesn't include code lines (DRY_RUN=0 etc.)
	[[ $output != *"DRY_RUN=0"* ]]
}

@test "unknown arg rejected with exit 2" {
	run "$SCRIPT" --bogus-flag
	[ "$status" -eq 2 ]
	[[ $output == *"unknown arg"* ]]
}

@test "--notes without value rejected with exit 2" {
	run "$SCRIPT" --notes
	[ "$status" -eq 2 ]
	[[ $output == *"requires a filename"* ]]
}

@test "--notes with non-existent file rejected at parse time (no silent fallback)" {
	run "$SCRIPT" --notes "$TEST_TMP/does-not-exist.md"
	[ "$status" -eq 2 ]
	[[ $output == *"not found"* ]]
}

# --- precondition guards (fixture-based) -----------------------------

@test "non-repo cwd refused with exit 2" {
	cd "$TEST_TMP" || return 1
	run "$SCRIPT" --dry-run
	[ "$status" -eq 2 ]
	[[ $output == *"not in a git repo"* ]]
}

@test "dirty working tree refused with exit 2 (real dirty-tree fixture)" {
	_make_fixture_repo 0.1.0
	# Introduce an unstaged modification
	echo "  // dirty" >>.claude-plugin/plugin.json
	run "$SCRIPT" --dry-run
	[ "$status" -eq 2 ]
	[[ $output == *"uncommitted or untracked"* ]]
}

@test "untracked file refused with exit 2 (no-untracked guard)" {
	_make_fixture_repo 0.1.0
	# Untracked file present
	touch "$TEST_TMP/untracked.txt"
	run "$SCRIPT" --dry-run
	[ "$status" -eq 2 ]
	[[ $output == *"uncommitted or untracked"* ]]
}

@test "missing plugin.json refused with exit 2" {
	cd "$TEST_TMP" || return 1
	git init -q
	git config user.email "test@test"
	git config user.name "test"
	echo "placeholder" >file.txt
	git add . >/dev/null
	git commit -q -m "initial"
	run "$SCRIPT" --dry-run
	[ "$status" -eq 2 ]
	[[ $output == *"plugin.json not found"* ]]
}

@test "plugin.json with missing .version refused with exit 2" {
	cd "$TEST_TMP" || return 1
	git init -q
	git config user.email "test@test"
	git config user.name "test"
	mkdir -p .claude-plugin
	echo '{"name": "fixture"}' >.claude-plugin/plugin.json
	git add . >/dev/null
	git commit -q -m "initial"
	run "$SCRIPT" --dry-run
	[ "$status" -eq 2 ]
	[[ $output == *".version missing"* ]]
}

@test "version regression refused with exit 2 (older than latest tag)" {
	_make_fixture_repo 0.0.1
	# Create a higher tag so plugin.json's 0.0.1 is regressing
	git tag v9.9.9
	run "$SCRIPT" --dry-run --no-github
	[ "$status" -eq 2 ]
	[[ $output == *"older than latest tag"* ]]
}

# --- --dry-run plan structure (positive path) ------------------------

@test "--dry-run prints the would-happen plan on a clean fixture repo" {
	_make_fixture_repo 0.1.0
	run "$SCRIPT" --dry-run --no-github
	[ "$status" -eq 0 ]
	[[ $output == *"target v0.1.0"* ]] || return 1
	[[ $output == *"[dry-run] would: git tag -a v0.1.0"* ]] || return 1
	[[ $output == *"[dry-run] would: git push origin v0.1.0"* ]] || return 1
	[[ $output == *"[dry-run] would: git clone"* ]] || return 1
	[[ $output == *"release complete"* ]]
}

@test "--dry-run + --no-github skips the gh release would: line" {
	_make_fixture_repo 0.1.0
	run "$SCRIPT" --dry-run --no-github
	[ "$status" -eq 0 ]
	[[ $output == *"--no-github"* ]] || return 1
	# Negative: must NOT contain the gh-release dry-run plan line.
	[[ $output != *"would: gh release create"* ]]
}

@test "idempotent re-run on existing tag at HEAD prints ✓ tag" {
	_make_fixture_repo 0.1.0
	git tag v0.1.0
	run "$SCRIPT" --dry-run --no-github
	[ "$status" -eq 0 ]
	[[ $output == *"tag v0.1.0 already exists"* ]]
}

@test "tag at different sha refused with exit 2" {
	_make_fixture_repo 0.1.0
	# Create tag, then advance HEAD so tag points elsewhere
	git tag v0.1.0
	echo "advance" >advance.txt
	git add . >/dev/null
	git commit -q -m "advance"
	run "$SCRIPT" --dry-run --no-github
	[ "$status" -eq 2 ]
	[[ $output == *"recreate the tag at HEAD"* ]]
}
