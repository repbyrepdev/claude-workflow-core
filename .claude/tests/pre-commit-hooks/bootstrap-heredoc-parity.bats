#!/usr/bin/env bats
# covers: pre-commit-hooks/bootstrap-heredoc-parity.sh
#
# #234 (Wave H) r1: this diff added .coderabbit.base.yaml to PARITY_PATHS, but
# the gate had no test. Prove it ACTIVELY drift-checks the byte-SSOT heredocs
# (a green-path test alone wouldn't catch a future refactor that silently
# de-listed an entry — only a drift test proves enforcement). Builds a faithful
# sandbox (real bootstrap-repo.sh + manifest + every PARITY_PATHS live file) so
# the baseline is clean, then mutates one file and asserts the gate fails.

# Robustly extract the gate's PARITY_PATHS entries (CR r3): grep ALL quoted
# tokens (handles inline arrays / multiple per line), skip comment + blank
# lines, strip quotes. One path per line. Used by setup AND the membership
# test so both mirror the gate's real array, not a raw file grep.
_gate_parity_paths() {
	awk '/^PARITY_PATHS=\(/{f=1; next} /^\)/{f=0} f && !/^[[:space:]]*#/' "$GATE" |
		grep -oE '"[^"]+"' | tr -d '"'
}

setup() {
	PLUGIN=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	GATE="$PLUGIN/pre-commit-hooks/bootstrap-heredoc-parity.sh"
	[ -x "$GATE" ]
	command -v git >/dev/null
	# yq guard (CR r4): the gate itself SKIPS (exit 0) when yq is absent
	# (bootstrap-heredoc-parity.sh:27). Without this, the "clean sandbox →
	# gate passes" test would pass VACUOUSLY on a yq-less machine (the gate
	# skipped, verified nothing). Require yq so the tests exercise real logic.
	command -v yq >/dev/null
	TMP=$(mktemp -d -t heredocparity.XXXXXX) || return 1
	SANDBOX="$TMP/repo"
	mkdir -p "$SANDBOX/scripts"
	(cd "$SANDBOX" && git init -q)
	cp "$PLUGIN/scripts/bootstrap-repo.sh" "$SANDBOX/scripts/"
	cp "$PLUGIN/scripts/bootstrap-manifest.yml" "$SANDBOX/scripts/"
	# Copy every PARITY_PATHS live file faithfully so the baseline is clean.
	# Read the list FROM the gate (no SSOT duplication — CR r2): extract the
	# quoted entries between `PARITY_PATHS=(` and the closing `)`. If the gate's
	# whitelist changes, this test mirrors it automatically.
	local p
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		mkdir -p "$SANDBOX/$(dirname "$p")"
		cp "$PLUGIN/$p" "$SANDBOX/$p"
	done < <(_gate_parity_paths)
}

teardown() {
	[ -n "${TMP:-}" ] && [ -d "$TMP" ] && [[ $TMP == */heredocparity.* ]] && rm -rf "$TMP"
	return 0
}

@test ".coderabbit.base.yaml is in the gate's PARITY_PATHS array (#234 r1)" {
	# Behavioral (CR r3): parse the actual PARITY_PATHS array — a raw file grep
	# would be satisfied by a mere comment mention. Exact-line membership.
	_gate_parity_paths | grep -Fxq '.coderabbit.base.yaml'
}

@test "clean sandbox (all heredocs match live files) → gate passes (#234 r1)" {
	run bash -c "cd '$SANDBOX' && bash '$GATE'"
	[ "$status" -eq 0 ]
	# Not just exit 0 (CR r3): assert no drift/missing markers leaked to output.
	[[ $output != *"drift in"* ]]
	[[ $output != *"live file missing"* ]]
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
