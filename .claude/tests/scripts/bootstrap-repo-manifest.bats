#!/usr/bin/env bats
# covers: scripts/bootstrap-repo.sh scripts/bootstrap-manifest.yml

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

@test "manifest declares schema_version: 1" {
	run yq -r '.schema_version' "$MANIFEST"
	[ "$status" -eq 0 ]
	[ "$output" = "1" ]
}

@test "manifest has required top-level sections (all non-empty)" {
	for section in files labels workflows issue_templates; do
		run yq -r ".$section | length" "$MANIFEST"
		[ "$status" -eq 0 ]
		[ "$output" -gt 0 ]
	done
}

@test "manifest file count matches bootstrap-repo.sh _write count" {
	manifest_count=$(yq -r '.files | length' "$MANIFEST")
	heredoc_count=$(grep -cE '^_write ' "$SCRIPT")
	[ "$manifest_count" -gt 0 ]
	[ "$manifest_count" -eq "$heredoc_count" ]
}

@test "every manifest file path appears as a literal _write target (grep -F)" {
	paths=$(yq -r '.files[].path' "$MANIFEST")
	[ -n "$paths" ]
	while IFS= read -r path; do
		[ -z "$path" ] && continue
		run grep -F -- "_write $path " "$SCRIPT"
		[ "$status" -eq 0 ]
	done <<<"$paths"
}

@test "drift in OTHER direction: every _write path is in the manifest" {
	heredocs=$(grep -E '^_write ' "$SCRIPT" | awk '{print $2}')
	[ -n "$heredocs" ]
	manifest_paths=$(yq -r '.files[].path' "$MANIFEST")
	while IFS= read -r h; do
		[ -z "$h" ] && continue
		echo "$manifest_paths" | grep -qFx "$h"
	done <<<"$heredocs"
}

@test "every manifest workflow appears as a _write under .github/workflows/" {
	wfs=$(yq -r '.workflows[]' "$MANIFEST")
	[ -n "$wfs" ]
	while IFS= read -r wf; do
		[ -z "$wf" ] && continue
		run grep -F -- "_write .github/workflows/$wf " "$SCRIPT"
		[ "$status" -eq 0 ]
	done <<<"$wfs"
}

@test "every manifest issue_template appears as a _write under .github/ISSUE_TEMPLATE/" {
	tpls=$(yq -r '.issue_templates[]' "$MANIFEST")
	[ -n "$tpls" ]
	while IFS= read -r tpl; do
		[ -z "$tpl" ] && continue
		run grep -F -- "_write .github/ISSUE_TEMPLATE/$tpl " "$SCRIPT"
		[ "$status" -eq 0 ]
	done <<<"$tpls"
}

@test "every manifest label name appears in bootstrap labels.yml heredoc" {
	names=$(yq -r '.labels[].name' "$MANIFEST")
	[ -n "$names" ]
	while IFS= read -r n; do
		[ -z "$n" ] && continue
		# Heredoc has `- name: <n>` lines.
		run grep -F -- "- name: $n" "$SCRIPT"
		[ "$status" -eq 0 ]
	done <<<"$names"
}

@test "manifest label colors are 6-hex lowercase (no leading #)" {
	colors=$(yq -r '.labels[].color' "$MANIFEST")
	[ -n "$colors" ]
	while IFS= read -r c; do
		[ -z "$c" ] && continue
		[[ $c =~ ^[0-9a-f]{6}$ ]] || return 1
	done <<<"$colors"
}

@test "manifest mode values are octal-as-string (3 digits)" {
	modes=$(yq -r '.files[].mode' "$MANIFEST")
	[ -n "$modes" ]
	while IFS= read -r m; do
		[ -z "$m" ] && continue
		[[ $m =~ ^[0-7]{3,4}$ ]] || return 1
	done <<<"$modes"
}

@test "bootstrap-repo.sh --dry-run exits 0 and writes no files into target" {
	run bash -c "\"$SCRIPT\" \"$TEST_TMP/target-dry\" --dry-run 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"[dry-run] would write"* ]] || return 1
	# No actual writes inside target
	[ -z "$(find "$TEST_TMP/target-dry" -type f 2>/dev/null)" ]
}

@test "parity-check WARNs on manifest file-count drift" {
	cp "$MANIFEST" "$TEST_TMP/manifest-drifted.yml"
	yq -i '.files += [{"path": "fake.txt", "mode": "644"}]' "$TEST_TMP/manifest-drifted.yml"
	mkdir -p "$TEST_TMP/sandbox"
	cp "$SCRIPT" "$TEST_TMP/sandbox/bootstrap-repo.sh"
	cp "$TEST_TMP/manifest-drifted.yml" "$TEST_TMP/sandbox/bootstrap-manifest.yml"
	chmod +x "$TEST_TMP/sandbox/bootstrap-repo.sh"
	# ci-r3: these sandboxes are PARTIAL plugin roots by construction — the
	# script and a doctored manifest, with no refresh-from-source.sh beside
	# them. bootstrap-repo now fails closed (rc 2) when the declared SSOT
	# propagator is absent, in --dry-run too, because a preview that silently
	# omits the whole SSOT-sync section while printing "complete" is a false
	# success. Adding the real refresher does not restore rc 0 — it then
	# fails on the sandbox's missing .github/consumers.yml — so the honest
	# expectation here is 2. The SUBJECT of each test is the parity-check
	# text below, which is emitted long before that exit.
	run bash -c "\"$TEST_TMP/sandbox/bootstrap-repo.sh\" \"$TEST_TMP/target-drift\" --dry-run 2>&1"
	[ "$status" -eq 2 ]
	[[ $output == *"WARN: manifest drift"* ]]
}

@test "parity-check WARNs on missing manifest path (count matches, name renamed)" {
	cp "$MANIFEST" "$TEST_TMP/manifest-renamed.yml"
	# Replace first path with a non-existent name (count preserved, identity drifts)
	yq -i '.files[0].path = "bogus-rename-target.txt"' "$TEST_TMP/manifest-renamed.yml"
	mkdir -p "$TEST_TMP/sandbox"
	cp "$SCRIPT" "$TEST_TMP/sandbox/bootstrap-repo.sh"
	cp "$TEST_TMP/manifest-renamed.yml" "$TEST_TMP/sandbox/bootstrap-manifest.yml"
	chmod +x "$TEST_TMP/sandbox/bootstrap-repo.sh"
	run bash -c "\"$TEST_TMP/sandbox/bootstrap-repo.sh\" \"$TEST_TMP/target-rename\" --dry-run 2>&1"
	[ "$status" -eq 2 ]
	[[ $output == *"manifest path(s) not found"* ]]
}

@test "parity-check NOTEs (no WARN) when manifest is missing" {
	mkdir -p "$TEST_TMP/sandbox-no-manifest"
	cp "$SCRIPT" "$TEST_TMP/sandbox-no-manifest/bootstrap-repo.sh"
	chmod +x "$TEST_TMP/sandbox-no-manifest/bootstrap-repo.sh"
	run bash -c "\"$TEST_TMP/sandbox-no-manifest/bootstrap-repo.sh\" \"$TEST_TMP/target-nomanifest\" --dry-run 2>&1"
	[ "$status" -eq 2 ]
	[[ $output == *"NOTE: bootstrap-manifest.yml not found"* ]] || return 1
	[[ $output != *"WARN: manifest"* ]]
}

@test "parity-check WARNs on unparseable manifest" {
	mkdir -p "$TEST_TMP/sandbox-bad-manifest"
	cp "$SCRIPT" "$TEST_TMP/sandbox-bad-manifest/bootstrap-repo.sh"
	printf 'files:\n  - path: ok\n  bad-indent\n' >"$TEST_TMP/sandbox-bad-manifest/bootstrap-manifest.yml"
	chmod +x "$TEST_TMP/sandbox-bad-manifest/bootstrap-repo.sh"
	run bash -c "\"$TEST_TMP/sandbox-bad-manifest/bootstrap-repo.sh\" \"$TEST_TMP/target-bad\" --dry-run 2>&1"
	[ "$status" -eq 2 ]
	[[ $output == *"unparseable"* ]]
}

@test "parity-check NOTEs (skipped) when yq missing from PATH" {
	mkdir -p "$TEST_TMP/sandbox-no-yq"
	cp "$SCRIPT" "$TEST_TMP/sandbox-no-yq/bootstrap-repo.sh"
	cp "$MANIFEST" "$TEST_TMP/sandbox-no-yq/bootstrap-manifest.yml"
	chmod +x "$TEST_TMP/sandbox-no-yq/bootstrap-repo.sh"
	# Strip yq from PATH by running with a minimal PATH
	run env PATH="/usr/bin:/bin" bash -c "\"$TEST_TMP/sandbox-no-yq/bootstrap-repo.sh\" \"$TEST_TMP/target-no-yq\" --dry-run 2>&1"
	[ "$status" -eq 2 ]
	[[ $output == *"NOTE: yq not on PATH"* ]] || return 1
	[[ $output != *"WARN: manifest"* ]]
}

@test "parity-check stays silent (no WARN) on canonical manifest" {
	run bash -c "\"$SCRIPT\" \"$TEST_TMP/target-clean\" --dry-run 2>&1"
	[ "$status" -eq 0 ]
	[[ $output != *"WARN: manifest"* ]]
}

@test "manifest mode matches the mode passed to _write for each path" {
	while IFS= read -r path; do
		[ -z "$path" ] && continue
		expected=$(yq -r ".files[] | select(.path == \"$path\") | .mode" "$MANIFEST")
		# Extract second whitespace-token after _write <path> from bootstrap-repo.sh
		actual=$(grep -F -- "_write $path " "$SCRIPT" | head -1 | awk '{print $3}')
		[ "$expected" = "$actual" ]
	done < <(yq -r '.files[].path' "$MANIFEST")
}

@test "manifest files[].path entries are unique" {
	count_total=$(yq -r '.files | length' "$MANIFEST")
	count_unique=$(yq -r '.files[].path' "$MANIFEST" | sort -u | wc -l)
	[ "$count_total" -eq "$count_unique" ]
}

@test "workflows[] equals basenames of files[] under .github/workflows/" {
	declared=$(yq -r '.workflows[]' "$MANIFEST" | sort -u)
	derived=$(yq -r '.files[] | select(.path | test("^\\.github/workflows/")) | .path' "$MANIFEST" | xargs -n1 basename | sort -u)
	[ "$declared" = "$derived" ]
}

@test "issue_templates[] equals basenames of files[] under .github/ISSUE_TEMPLATE/" {
	declared=$(yq -r '.issue_templates[]' "$MANIFEST" | sort -u)
	derived=$(yq -r '.files[] | select(.path | test("^\\.github/ISSUE_TEMPLATE/")) | .path' "$MANIFEST" | xargs -n1 basename | sort -u)
	[ "$declared" = "$derived" ]
}

@test "label descriptions in manifest match labels.yml heredoc" {
	while IFS= read -r name; do
		[ -z "$name" ] && continue
		desc=$(yq -r ".labels[] | select(.name == \"$name\") | .description // \"\"" "$MANIFEST")
		[ -z "$desc" ] || [ "$desc" = "null" ] && continue
		run bash -c "grep -A2 -F -- '- name: $name' \"$SCRIPT\" | grep -F -- 'description: $desc'"
		[ "$status" -eq 0 ]
	done < <(yq -r '.labels[].name' "$MANIFEST")
}
