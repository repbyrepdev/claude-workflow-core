#!/usr/bin/env bats
# covers: pre-commit-hooks/bootstrap-heredoc-parity.sh
#
# #234 (Wave H) r1: this diff added .coderabbit.base.yaml to PARITY_PATHS, but
# the gate had no test. Prove it ACTIVELY drift-checks the byte-SSOT heredocs
# (a green-path test alone wouldn't catch a future refactor that silently
# de-listed an entry — only a drift test proves enforcement). Builds a faithful
# sandbox (real bootstrap-repo.sh + manifest + every PARITY_PATHS live file) so
# the baseline is clean, then mutates one file and asserts the gate fails.

setup() {
	PLUGIN=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	GATE="$PLUGIN/pre-commit-hooks/bootstrap-heredoc-parity.sh"
	[ -x "$GATE" ]
	command -v git >/dev/null
	TMP=$(mktemp -d -t heredocparity.XXXXXX) || return 1
	SANDBOX="$TMP/repo"
	mkdir -p "$SANDBOX/scripts"
	(cd "$SANDBOX" && git init -q)
	cp "$PLUGIN/scripts/bootstrap-repo.sh" "$SANDBOX/scripts/"
	cp "$PLUGIN/scripts/bootstrap-manifest.yml" "$SANDBOX/scripts/"
	# Copy every PARITY_PATHS live file faithfully so the baseline is clean.
	local p
	for p in \
		.github/ISSUE_TEMPLATE/bug.yml \
		.github/ISSUE_TEMPLATE/feature.yml \
		.github/ISSUE_TEMPLATE/task.yml \
		.github/ISSUE_TEMPLATE/epic.yml \
		.github/ISSUE_TEMPLATE/brainstorm.yml \
		.github/pull_request_template.md \
		.coderabbit.base.yaml; do
		mkdir -p "$SANDBOX/$(dirname "$p")"
		cp "$PLUGIN/$p" "$SANDBOX/$p"
	done
}

teardown() {
	[ -n "${TMP:-}" ] && [ -d "$TMP" ] && [[ $TMP == */heredocparity.* ]] && rm -rf "$TMP"
	return 0
}

@test ".coderabbit.base.yaml is in PARITY_PATHS (#234 r1)" {
	grep -qF '".coderabbit.base.yaml"' "$GATE"
}

@test "clean sandbox (all heredocs match live files) → gate passes (#234 r1)" {
	run bash -c "cd '$SANDBOX' && bash '$GATE'"
	[ "$status" -eq 0 ]
}

@test "drifting .coderabbit.base.yaml → gate fails with named drift (#234 r1)" {
	# Mutate ONLY the CR base; every other PARITY_PATHS file still matches, so
	# the failure must be isolated to .coderabbit.base.yaml — proving the gate
	# actively checks it (not just present in the array).
	printf '\n# drift injected by test\n' >>"$SANDBOX/.coderabbit.base.yaml"
	run bash -c "cd '$SANDBOX' && bash '$GATE'"
	[ "$status" -ne 0 ]
	[[ $output == *"drift in .coderabbit.base.yaml"* ]]
}

@test "missing .coderabbit.base.yaml live file → gate fails closed (#234 r1)" {
	rm -f "$SANDBOX/.coderabbit.base.yaml"
	run bash -c "cd '$SANDBOX' && bash '$GATE'"
	[ "$status" -ne 0 ]
	[[ $output == *"live file missing: .coderabbit.base.yaml"* ]]
}
