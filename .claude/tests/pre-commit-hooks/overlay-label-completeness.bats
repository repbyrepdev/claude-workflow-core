#!/usr/bin/env bats
# covers: pre-commit-hooks/overlay-label-completeness.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	HOOK="${REPO_ROOT}/pre-commit-hooks/overlay-label-completeness.sh"
	TEST_TMP=$(mktemp -d -t overlay-lbl.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		git init -q -b main
		git config user.email t@t
		git config user.name t
		mkdir -p .github
		git commit --allow-empty -q -m init
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */overlay-lbl.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# _write_labels <name...> — write .github/labels.yml as a top-level seq and
# STAGE it (the gate reads the staged blob via `git show :path`).
_write_labels() {
	: >"$TEST_TMP/.github/labels.yml"
	local n
	for n in "$@"; do
		printf -- '- name: "%s"\n  color: "ededed"\n  description: d\n' "$n" >>"$TEST_TMP/.github/labels.yml"
	done
	git -C "$TEST_TMP" add .github/labels.yml
}

# _write_overlay <label...> — write .coderabbit.overlay.yaml with the given
# reviews.labeling_instructions labels and STAGE it.
_write_overlay() {
	{
		echo "reviews:"
		echo "  labeling_instructions:"
		local l
		for l in "$@"; do
			printf -- '    - label: "%s"\n      instructions: "use for %s"\n' "$l" "$l"
		done
	} >"$TEST_TMP/.coderabbit.overlay.yaml"
	git -C "$TEST_TMP" add .coderabbit.overlay.yaml
}

@test "plugin-source skip (name-pinned): announced + exit 0 even if drifted" {
	cd "$TEST_TMP"
	mkdir -p .claude-plugin
	echo '{"name":"claude-workflow-core","version":"0.0.0"}' >.claude-plugin/plugin.json
	_write_labels "area:docs" "area:plugin-manifest"
	_write_overlay # empty labeling_instructions — would fail if not skipped
	run "$HOOK"
	[ "$status" -eq 0 ]
	[[ $output == *"plugin source"* ]]
}

@test "complete: overlay domain set == labels.yml domain set => exit 0" {
	cd "$TEST_TMP"
	_write_labels "area:infrastructure" "area:hooks" "type:test" "bug"
	_write_overlay "area:hooks" "type:test"
	run "$HOOK"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "universal area:infrastructure is excluded (not required in overlay)" {
	cd "$TEST_TMP"
	_write_labels "area:infrastructure" "area:hooks"
	_write_overlay "area:hooks"
	run "$HOOK"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "incomplete: domain label in labels.yml missing from overlay => exit 1" {
	cd "$TEST_TMP"
	_write_labels "area:hooks" "area:coalesce" "type:test"
	_write_overlay "area:hooks" "type:test"
	run "$HOOK"
	[ "$status" -eq 1 ]
	[[ $output == *"MISSING from overlay"* ]] || return 1
	[[ $output == *"area:coalesce"* ]]
}

@test "extra: overlay declares a label absent from labels.yml => exit 1" {
	cd "$TEST_TMP"
	_write_labels "area:hooks"
	_write_overlay "area:hooks" "area:ghost"
	run "$HOOK"
	[ "$status" -eq 1 ]
	[[ $output == *"EXTRA in overlay"* ]] || return 1
	[[ $output == *"area:ghost"* ]]
}

@test "overlay not staged => exit 0 (out of scope)" {
	cd "$TEST_TMP"
	_write_labels "area:hooks"
	run "$HOOK"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "labels.yml not staged => exit 0 (out of scope)" {
	cd "$TEST_TMP"
	_write_overlay "area:hooks"
	run "$HOOK"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "bypass env => exit 0 and no drift error emitted" {
	cd "$TEST_TMP"
	_write_labels "area:hooks" "area:coalesce"
	_write_overlay "area:hooks"
	OVERLAY_LABEL_COMPLETENESS_SKIP=1 run "$HOOK"
	[ "$status" -eq 0 ]
	[[ $output != *"drifted"* ]]
}

@test "wrong-shape labels.yml (top-level mapping, not seq) => exit 2 precondition" {
	cd "$TEST_TMP"
	# A mapping of label-objects: yq '.[].name' emits "null" rc=0 and would
	# silently collapse to an empty domain set — the shape-assert catches it.
	printf 'area:foo:\n  color: ededed\n' >"$TEST_TMP/.github/labels.yml"
	git -C "$TEST_TMP" add .github/labels.yml
	_write_overlay "area:hooks"
	run "$HOOK"
	[ "$status" -eq 2 ]
	[[ $output == *"not a top-level sequence"* ]]
}

@test "overlay with reviews: but no labeling_instructions => missing labels, exit 1" {
	cd "$TEST_TMP"
	_write_labels "area:hooks" "area:coalesce"
	printf 'reviews:\n  profile: assertive\n' >"$TEST_TMP/.coderabbit.overlay.yaml"
	git -C "$TEST_TMP" add .coderabbit.overlay.yaml
	run "$HOOK"
	[ "$status" -eq 1 ]
	[[ $output == *"MISSING from overlay"* ]] || return 1
	[[ $output == *"area:hooks"* ]]
}

@test "plugin.json with non-canonical name is NOT skipped (consumer-plugin enforced)" {
	cd "$TEST_TMP"
	mkdir -p .claude-plugin
	echo '{"name":"some-consumer-plugin","version":"1.0.0"}' >.claude-plugin/plugin.json
	_write_labels "area:hooks" "area:coalesce"
	_write_overlay "area:hooks"
	run "$HOOK"
	[ "$status" -eq 1 ]
	[[ $output == *"MISSING from overlay"* ]]
}

@test "staged content (not working-tree) is what is validated" {
	cd "$TEST_TMP"
	# Stage a COMPLETE overlay, then dirty the working tree to be incomplete.
	# The gate reads the staged blob, so it must PASS (working-tree WIP ignored).
	_write_labels "area:hooks"
	_write_overlay "area:hooks"
	printf 'reviews:\n  labeling_instructions: []\n' >"$TEST_TMP/.coderabbit.overlay.yaml"
	run "$HOOK"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}
