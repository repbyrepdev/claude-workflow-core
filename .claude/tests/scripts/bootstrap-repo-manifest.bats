#!/usr/bin/env bats
# covers: scripts/bootstrap-repo.sh scripts/bootstrap-manifest.yml
#
# Tests for the bootstrap-manifest.yml SSOT + bootstrap-repo.sh parity
# check (#62). Manifest enumerates every file/label/workflow/template
# bootstrap-repo.sh writes; the script asserts count parity at start.

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/bootstrap-repo.sh"
	MANIFEST="${REPO_ROOT}/scripts/bootstrap-manifest.yml"
	TEST_TMP=$(mktemp -d -t bootstrap-manifest.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */bootstrap-manifest.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "manifest file exists and is valid YAML" {
	[ -f "$MANIFEST" ]
	run yq . "$MANIFEST"
	[ "$status" -eq 0 ]
}

@test "manifest has required top-level sections" {
	for section in files labels workflows issue_templates; do
		run yq -r ".$section | length" "$MANIFEST"
		[ "$status" -eq 0 ]
		[ "$output" -gt 0 ]
	done
}

@test "manifest file count matches bootstrap-repo.sh _write count" {
	manifest_count=$(yq -r '.files | length' "$MANIFEST")
	heredoc_count=$(grep -cE '^_write ' "$SCRIPT")
	[ "$manifest_count" -eq "$heredoc_count" ]
}

@test "every manifest file path appears in a _write call" {
	while IFS= read -r path; do
		run grep -E "^_write $path " "$SCRIPT"
		[ "$status" -eq 0 ]
	done < <(yq -r '.files[].path' "$MANIFEST")
}

@test "every manifest workflow appears as a _write in .github/workflows/" {
	while IFS= read -r wf; do
		run grep -E "^_write \\.github/workflows/$wf " "$SCRIPT"
		[ "$status" -eq 0 ]
	done < <(yq -r '.workflows[]' "$MANIFEST")
}

@test "every manifest issue_template appears as a _write in .github/ISSUE_TEMPLATE/" {
	while IFS= read -r tpl; do
		run grep -E "^_write \\.github/ISSUE_TEMPLATE/$tpl " "$SCRIPT"
		[ "$status" -eq 0 ]
	done < <(yq -r '.issue_templates[]' "$MANIFEST")
}

@test "bootstrap-repo.sh --dry-run exits 0 with manifest present" {
	run "$SCRIPT" "$TEST_TMP/target" --dry-run
	[ "$status" -eq 0 ]
}

@test "parity-check soft-warns when manifest file count drifts" {
	# Stage a temp copy with extra file entry, run dry-run, expect WARN line
	cp "$MANIFEST" "$TEST_TMP/manifest-drifted.yml"
	yq -i '.files += [{"path": "fake.txt", "mode": "644"}]' "$TEST_TMP/manifest-drifted.yml"
	# Build a sandbox where MANIFEST_PATH resolves to the drifted copy.
	mkdir -p "$TEST_TMP/sandbox"
	cp "$SCRIPT" "$TEST_TMP/sandbox/bootstrap-repo.sh"
	cp "$TEST_TMP/manifest-drifted.yml" "$TEST_TMP/sandbox/bootstrap-manifest.yml"
	chmod +x "$TEST_TMP/sandbox/bootstrap-repo.sh"
	run "$TEST_TMP/sandbox/bootstrap-repo.sh" "$TEST_TMP/target2" --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"WARN: manifest drift"* ]]
}
