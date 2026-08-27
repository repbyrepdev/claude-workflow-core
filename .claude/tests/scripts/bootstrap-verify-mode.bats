#!/usr/bin/env bats
# covers: scripts/bootstrap-repo.sh pre-commit-hooks/bootstrap-heredoc-parity.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/bootstrap-repo.sh"
	PARITY="${REPO_ROOT}/pre-commit-hooks/bootstrap-heredoc-parity.sh"
	TEST_TMP=$(mktemp -d -t bootstrap-verify.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */bootstrap-verify.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "--verify --scope plugin returns 0 on plugin's own repo" {
	run bash -c "\"$SCRIPT\" \"$REPO_ROOT\" --verify --scope plugin 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"verify clean"* ]]
}

@test "--verify --scope both finds consumer-only files missing in plugin repo" {
	run bash -c "\"$SCRIPT\" \"$REPO_ROOT\" --verify --scope both 2>&1"
	[ "$status" -eq 1 ]
	[[ $output == *"missing: .claude/skills/ship-pr-cycle/run.sh"* ]]
}

@test "--verify on empty dir returns non-zero with FAILED summary" {
	mkdir -p "$TEST_TMP/empty"
	run bash -c "\"$SCRIPT\" \"$TEST_TMP/empty\" --verify --scope plugin 2>&1"
	[ "$status" -eq 1 ]
	[[ $output == *"verify FAILED"* ]]
}

@test "--verify --scope=bogus rejects with error" {
	run bash -c "\"$SCRIPT\" \"$REPO_ROOT\" --verify --scope bogus 2>&1"
	[ "$status" -eq 2 ]
	[[ $output == *"must be one of"* ]]
}

@test "--verify on non-existent dir returns 2 with ERROR" {
	run bash -c "\"$SCRIPT\" \"$TEST_TMP/does-not-exist\" --verify 2>&1"
	[ "$status" -eq 2 ]
	[[ $output == *"ERROR"* ]]
}

@test "parity gate exits 0 on plugin's own clean tree" {
	run "$PARITY"
	[ "$status" -eq 0 ]
}

@test "manifest schema accepts scope field defaulting to both" {
	count=$(yq -r '.files | length' "${REPO_ROOT}/scripts/bootstrap-manifest.yml")
	[ "$count" -gt 0 ]
	for i in $(seq 0 $((count - 1))); do
		s=$(yq -r ".files[$i].scope // \"both\"" "${REPO_ROOT}/scripts/bootstrap-manifest.yml")
		case "$s" in
		plugin | consumer | both) ;;
		*) return 1 ;;
		esac
	done
}

@test "plugin-self-bootstrap-verify workflow exists + is valid YAML" {
	wf="${REPO_ROOT}/.github/workflows/plugin-self-bootstrap-verify.yml"
	[ -f "$wf" ]
	run yq . "$wf"
	[ "$status" -eq 0 ]
	grep -qF "scripts/bootstrap-repo.sh . --verify --scope plugin" "$wf"
}

@test "parity gate detects drift when heredoc body diverges from live" {
	# Sandbox: copy live epic.yml + bootstrap script, mutate the live file
	# so it no longer matches the script's heredoc, run the gate, expect rc=1.
	mkdir -p "$TEST_TMP/sandbox/.github/ISSUE_TEMPLATE" "$TEST_TMP/sandbox/scripts" "$TEST_TMP/sandbox/pre-commit-hooks"
	cp "$REPO_ROOT/scripts/bootstrap-repo.sh" "$TEST_TMP/sandbox/scripts/"
	cp "$REPO_ROOT/scripts/bootstrap-manifest.yml" "$TEST_TMP/sandbox/scripts/"
	cp "$REPO_ROOT/pre-commit-hooks/bootstrap-heredoc-parity.sh" "$TEST_TMP/sandbox/pre-commit-hooks/"
	chmod +x "$TEST_TMP/sandbox/pre-commit-hooks/bootstrap-heredoc-parity.sh"
	# Drift the live epic.yml so the gate must flag it.
	printf 'name: Epic\ndescription: DRIFT\nlabels: ["epic"]\nbody: []\n' >"$TEST_TMP/sandbox/.github/ISSUE_TEMPLATE/epic.yml"
	# Also need the other PARITY_PATHS to either exist or skip; populate from live.
	for tpl in bug feature task brainstorm; do
		[ -f "$REPO_ROOT/.github/ISSUE_TEMPLATE/${tpl}.yml" ] && cp "$REPO_ROOT/.github/ISSUE_TEMPLATE/${tpl}.yml" "$TEST_TMP/sandbox/.github/ISSUE_TEMPLATE/"
	done
	[ -f "$REPO_ROOT/.github/pull_request_template.md" ] && cp "$REPO_ROOT/.github/pull_request_template.md" "$TEST_TMP/sandbox/.github/"
	# Make it a git repo so should_run gate doesn't short-circuit.
	(cd "$TEST_TMP/sandbox" && git init -q && git add -A)
	run bash -c "cd \"$TEST_TMP/sandbox\" && ./pre-commit-hooks/bootstrap-heredoc-parity.sh 2>&1"
	[ "$status" -eq 1 ]
	[[ $output == *"drift in .github/ISSUE_TEMPLATE/epic.yml"* ]]
}

@test "--verify reports mode mismatch as non-blocking warn" {
	# Sandbox: materialize every manifest file with intentionally wrong mode
	# for a 755-expected entry, run --verify --scope plugin, assert mode-
	# mismatch warn fires but verify still exits 0 (mode is non-blocking).
	mkdir -p "$TEST_TMP/target"
	count=$(yq -r '.files | length' "${REPO_ROOT}/scripts/bootstrap-manifest.yml")
	for i in $(seq 0 $((count - 1))); do
		path=$(yq -r ".files[$i].path" "${REPO_ROOT}/scripts/bootstrap-manifest.yml")
		scope=$(yq -r ".files[$i].scope // \"both\"" "${REPO_ROOT}/scripts/bootstrap-manifest.yml")
		[ "$scope" = "consumer" ] && continue
		mkdir -p "$(dirname "$TEST_TMP/target/$path")"
		echo "stub" >"$TEST_TMP/target/$path"
		# Force mode 600 on all (will mismatch 644 and 755 entries).
		chmod 600 "$TEST_TMP/target/$path"
	done
	run bash -c "\"$SCRIPT\" \"$TEST_TMP/target\" --verify --scope plugin 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"mode mismatch"* ]] || return 1
	[[ $output == *"non-blocking"* ]]
}

@test "every PARITY_PATHS entry exists in bootstrap-manifest.yml" {
	# Drift guard: PARITY_PATHS and manifest.files[] are two SSOTs.
	# Assert every PARITY_PATHS entry has a corresponding manifest entry.
	hook="${REPO_ROOT}/pre-commit-hooks/bootstrap-heredoc-parity.sh"
	manifest_paths=$(yq -r '.files[].path' "${REPO_ROOT}/scripts/bootstrap-manifest.yml")
	[ -n "$manifest_paths" ]
	# Extract PARITY_PATHS entries from the hook (quoted ".github/..." lines).
	while IFS= read -r entry; do
		[ -z "$entry" ] && continue
		# Strip quotes + leading whitespace.
		path=$(echo "$entry" | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
		echo "$manifest_paths" | grep -qFx "$path"
	done < <(awk '/^PARITY_PATHS=\(/,/^\)$/{ if ($0 ~ /^\s*"\.github\//) print }' "$hook")
}
