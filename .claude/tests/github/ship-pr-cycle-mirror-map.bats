#!/usr/bin/env bats
# covers: .github/ship-pr-cycle-mirror-map.yml
#
# Schema validation for the ship-pr-cycle mirror map. Guards against
# drift between (a) the YAML SSOT, (b) the workflows it claims to
# mirror, (c) the local_command paths it claims to invoke, (d) the
# orchestrator's actual state-machine stages.

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	MAP="${REPO_ROOT}/.github/ship-pr-cycle-mirror-map.yml"
	WORKFLOWS_DIR="${REPO_ROOT}/.github/workflows"
	ORCHESTRATOR="${REPO_ROOT}/scripts/ship-pr-cycle.sh"
	command -v yq >/dev/null 2>&1 || skip "yq required (mikefarah/yq v4+)"
	yq_ver=$(yq --version 2>&1)
	echo "$yq_ver" | grep -qi "mikefarah" || skip "yq must be mikefarah/yq (Go), found: $yq_ver"
	# Strict v4+ check — v3 uses incompatible subcommand syntax (`yq r ...`)
	# vs v4's jq-like expression form. Later tests use v4-only syntax, so
	# v3 produces noisy parse failures instead of clean skip without this.
	echo "$yq_ver" | grep -Eq 'version v?([4-9]|[1-9][0-9])(\.|$)' || skip "yq v4+ required, found: $yq_ver"
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

@test "every mirror entry has all required fields including non-empty local_command" {
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

@test "every mirror's local_command first token resolves to a real path or PATH binary" {
	count=$(yq -r '.mirrors | length' "$MAP")
	for i in $(seq 0 $((count - 1))); do
		cmd=$(yq -r ".mirrors[$i].local_command" "$MAP")
		first_token="${cmd%% *}"
		# Either a repo-relative path that exists + is executable,
		# OR a PATH-resolvable binary. This catches the class of
		# drift where the YAML references a script that doesn't exist.
		if [[ $first_token == */* ]]; then
			[ -x "$REPO_ROOT/$first_token" ]
		else
			command -v "$first_token" >/dev/null 2>&1
		fi
	done
}

@test "every mirror's phase is from the orchestrator's actual state-machine" {
	# SSOT: the stages declared in scripts/ship-pr-cycle.sh:30-39.
	# Grep the orchestrator for stages directly so this test refuses
	# to ratify a drift between the YAML's phase set + the script.
	canonical=$(grep -E "^#   (branch-ready|phase[0-9.]+|push|cr-in-ci-wait|auto-triage|merge-gate|merged)" "$ORCHESTRATOR" | awk '{print $2}' | sort -u)
	count=$(yq -r '.mirrors | length' "$MAP")
	for i in $(seq 0 $((count - 1))); do
		phase=$(yq -r ".mirrors[$i].phase" "$MAP")
		echo "$canonical" | grep -qx "$phase"
	done
}

@test "phase_aliases entries are subsets of declared mirror server_workflows" {
	declared_workflows=$(yq -r '.mirrors[].server_workflow' "$MAP" | sort -u)
	for phase in branch-ready push cr-in-ci-wait; do
		listed=$(yq -r ".phase_aliases.\"${phase}\"[]" "$MAP" 2>/dev/null || true)
		while IFS= read -r wf; do
			[ -z "$wf" ] && continue
			echo "$declared_workflows" | grep -qx "$wf"
		done <<<"$listed"
	done
}

@test "every server-side workflow has a mirror entry OR is in intentionally_unmirrored" {
	# Use nullglob so an empty workflows/ dir doesn't produce a literal
	# `*.yml` filename (silent-failure class — CR caught this).
	shopt -s nullglob
	workflows=("$WORKFLOWS_DIR"/*.yml)
	[ "${#workflows[@]}" -gt 0 ] || skip "no .github/workflows/*.yml in this repo"
	declared=$(yq -r '.mirrors[].server_workflow' "$MAP" | sort -u)
	unmirrored=$(yq -r '.intentionally_unmirrored[].workflow' "$MAP" 2>/dev/null | sort -u)
	for wf in "${workflows[@]}"; do
		basename=$(basename "$wf")
		echo "$declared" | grep -qx "$basename" && continue
		echo "$unmirrored" | grep -qx "$basename"
	done
}

@test "server_workflow values are unique across mirrors[]" {
	total=$(yq -r '.mirrors | length' "$MAP")
	unique=$(yq -r '.mirrors[].server_workflow' "$MAP" | sort -u | wc -l | tr -d ' ')
	[ "$total" -eq "$unique" ]
}
