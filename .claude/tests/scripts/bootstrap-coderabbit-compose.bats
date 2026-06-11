#!/usr/bin/env bats
# covers: scripts/bootstrap-repo.sh
#
# #234 (Wave H) r1: the _compose_coderabbit step. meta-bootstrap-repo.bats
# covers the no-overlay case (composed == base); this file covers the paths
# phase-1 review flagged as untested: WITH-overlay compose, --dry-run preview
# fidelity, idempotency (skip-pre-existing-unless-force), and fail-soft
# (compose failure WARNs + sets the summary reminder, bootstrap still exits 0).

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/bootstrap-repo.sh"
	[ -x "$SCRIPT" ]
	command -v yq >/dev/null
	TMP=$(mktemp -d -t bootcrcompose.XXXXXX) || return 1
}

teardown() {
	[ -n "${TMP:-}" ] && [ -d "$TMP" ] && [[ $TMP == */bootcrcompose.* ]] && rm -rf "$TMP"
	return 0
}

@test "WITH overlay: bootstrap composes base + pre-planted overlay (#234 r1)" {
	mkdir -p "$TMP/target"
	# Plant a domain overlay BEFORE bootstrap (consumer-authored). It adds a
	# PR label under reviews.labeling_instructions (array → appends to base).
	cat >"$TMP/target/.coderabbit.overlay.yaml" <<'EOF'
reviews:
  labeling_instructions:
    - label: "area:coalesce"
      instructions: "Coalesce .sql changes."
EOF
	run bash "$SCRIPT" "$TMP/target"
	[ "$status" -eq 0 ]
	[ -f "$TMP/target/.coderabbit.base.yaml" ]
	[ -f "$TMP/target/.coderabbit.yaml" ]
	# Composed != base (overlay merged in). `run` + status (bats: bare `!`
	# does not fail a test — SC2314).
	run diff -q "$TMP/target/.coderabbit.base.yaml" "$TMP/target/.coderabbit.yaml"
	[ "$status" -ne 0 ]
	# Overlay appends 1 label to whatever the base ships (array-append). Assert
	# the append DYNAMICALLY (base count + 1) so the test does not go stale when
	# the base SSOT's label set changes (was 6 at #234, now 1 — pre-existing
	# stale hardcode caught during #2270).
	base_n=$(yq -r '.reviews.labeling_instructions | length' "$TMP/target/.coderabbit.base.yaml")
	[ "$(yq -r '.reviews.labeling_instructions | length' "$TMP/target/.coderabbit.yaml")" -eq "$((base_n + 1))" ]
	[ "$(yq -r '.reviews.labeling_instructions[-1].label' "$TMP/target/.coderabbit.yaml")" = "area:coalesce" ]
}

@test "--dry-run previews 'would compose' and writes NOTHING (#234 r1)" {
	mkdir -p "$TMP/target"
	run bash "$SCRIPT" "$TMP/target" --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"would compose .coderabbit.yaml"* ]]
	# Regression guard for the pre-r1 ordering bug (base-check before dry-run
	# guard) that emitted "absent — skipping" on a fresh dry-run.
	[[ $output != *"absent in target — skipping"* ]]
	# Dry-run mutates nothing.
	[ ! -f "$TMP/target/.coderabbit.base.yaml" ]
	[ ! -f "$TMP/target/.coderabbit.yaml" ]
}

@test "idempotency: second run skips compose, does not clobber .coderabbit.yaml (#234 r1)" {
	mkdir -p "$TMP/target"
	bash "$SCRIPT" "$TMP/target" >/dev/null 2>&1
	[ -f "$TMP/target/.coderabbit.yaml" ]
	before=$(shasum -a 256 "$TMP/target/.coderabbit.yaml" | awk '{print $1}')
	run bash "$SCRIPT" "$TMP/target"
	[ "$status" -eq 0 ]
	[[ $output == *".coderabbit.yaml exists — skipping compose"* ]]
	after=$(shasum -a 256 "$TMP/target/.coderabbit.yaml" | awk '{print $1}')
	[ "$before" = "$after" ]
}

@test "fail-soft: a clobbering overlay fails compose but bootstrap still exits 0 + surfaces it (#234 r1)" {
	mkdir -p "$TMP/target"
	# Overlay that sets a base mapping-key to a scalar → compose-coderabbit.sh
	# exits 2 (type-clobber guard) → _compose_coderabbit WARNs + sets the
	# summary reminder, but bootstrap must NOT abort (compose is best-effort).
	cat >"$TMP/target/.coderabbit.overlay.yaml" <<'EOF'
reviews: "gut-the-map"
EOF
	run bash "$SCRIPT" "$TMP/target"
	[ "$status" -eq 0 ]
	[[ $output == *"NOT composed"* ]]
	[[ $output == *"fall back to"* ]] # the summary reminder fired
	# base still written; .coderabbit.yaml not produced (compose failed).
	[ -f "$TMP/target/.coderabbit.base.yaml" ]
	[ ! -f "$TMP/target/.coderabbit.yaml" ]
}
