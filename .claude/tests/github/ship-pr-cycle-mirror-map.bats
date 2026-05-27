#!/usr/bin/env bats
# covers: .github/ship-pr-cycle-mirror-map.yml
#
# Schema validation for the ship-pr-cycle mirror map. Mostly guards
# against drift between the YAML SSOT and the workflows it claims to
# mirror — every entry's `server_workflow` must point at a real
# .github/workflows/*.yml file (or be intentionally marked as
# alias-only in phase_aliases).

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	MAP="${REPO_ROOT}/.github/ship-pr-cycle-mirror-map.yml"
	WORKFLOWS_DIR="${REPO_ROOT}/.github/workflows"
}

@test "mirror-map file exists" {
	[ -f "$MAP" ]
}

@test "mirror-map declares schema_version: 1" {
	sv=$(yq -r '.schema_version' "$MAP")
	[ "$sv" = "1" ]
}

@test "mirror-map has at least one mirror entry" {
	count=$(yq -r '.mirrors | length' "$MAP")
	[ "$count" -ge 1 ]
}

@test "every mirror entry has all required fields" {
	count=$(yq -r '.mirrors | length' "$MAP")
	for i in $(seq 0 $((count - 1))); do
		for field in server_workflow phase local_command refuse_on_fail; do
			v=$(yq -r ".mirrors[$i].${field}" "$MAP")
			[ -n "$v" ] && [ "$v" != "null" ]
		done
	done
}

@test "every mirror's server_workflow points at a real .github/workflows/*.yml" {
	count=$(yq -r '.mirrors | length' "$MAP")
	for i in $(seq 0 $((count - 1))); do
		wf=$(yq -r ".mirrors[$i].server_workflow" "$MAP")
		[ -f "$WORKFLOWS_DIR/$wf" ]
	done
}

@test "every mirror's phase is from the canonical phase set" {
	count=$(yq -r '.mirrors | length' "$MAP")
	for i in $(seq 0 $((count - 1))); do
		phase=$(yq -r ".mirrors[$i].phase" "$MAP")
		case "$phase" in
		branch-ready | push | pr-create | cr-in-ci-wait) ;;
		*) false ;;
		esac
	done
}

@test "phase_aliases sections are subsets of declared mirror server_workflows" {
	declared_workflows=$(yq -r '.mirrors[].server_workflow' "$MAP" | sort -u)
	for phase in branch-ready push pr-create cr-in-ci-wait; do
		listed=$(yq -r ".phase_aliases.\"${phase}\"[]" "$MAP" 2>/dev/null || true)
		while IFS= read -r wf; do
			[ -z "$wf" ] && continue
			echo "$declared_workflows" | grep -qx "$wf"
		done <<<"$listed"
	done
}

@test "every server-side workflow has a mirror entry OR is intentionally unmirrored" {
	# This test catches the case where a new workflow lands but the
	# mirror map wasn't updated. Listed unmirrored workflows must be
	# documented here (intentional design decision: server-only check).
	UNMIRRORED=(
		# (none currently)
	)
	declared=$(yq -r '.mirrors[].server_workflow' "$MAP" | sort -u)
	for wf in "$WORKFLOWS_DIR"/*.yml; do
		basename=$(basename "$wf")
		if echo "$declared" | grep -qx "$basename"; then continue; fi
		found_in_unmirrored=0
		for u in "${UNMIRRORED[@]+"${UNMIRRORED[@]}"}"; do
			[ "$u" = "$basename" ] && found_in_unmirrored=1 && break
		done
		[ "$found_in_unmirrored" = "1" ]
	done
}
