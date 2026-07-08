#!/usr/bin/env bats
# covers: scripts/bootstrap-repo.sh scripts/compose-coderabbit.sh
#
# #234 (Wave H) r1: the _compose_coderabbit step. meta-bootstrap-repo.bats
# covers the no-overlay case (composed == base); this file covers the paths
# phase-1 review flagged as untested: WITH-overlay compose, --dry-run preview
# fidelity, idempotency (skip-pre-existing-unless-force), and fail-soft
# (compose failure WARNs + sets the summary reminder, bootstrap still exits 0).
#
# #2400: plus fixture-driven unit tests for compose-coderabbit.sh's
# #2254/#2257 canonical-mirror exclusion branches, driven DIRECTLY via the
# COMPOSE_CR_{HOOKS,LIB}_DIR + COMPOSE_CR_CONSUMER_{HOOKS,LIB}_DIR overrides
# (meta-bootstrap-repo.bats proves the pass fires COMPLETELY at integration
# level; the per-branch logic lives here).

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
	# Guard the dynamic count (#2270 phase1 silent-failure-hunter): a null/empty
	# base labeling_instructions makes base_n empty->0 and the append->1 pass
	# spuriously; an unchecked yq error masks the cause. Require a positive
	# integer so a regressed/empty base fails LOUD here, not as a count mismatch.
	[[ $base_n =~ ^[0-9]+$ ]] && [ "$base_n" -ge 1 ]
	[ "$(yq -r '.reviews.labeling_instructions | length' "$TMP/target/.coderabbit.yaml")" -eq "$((base_n + 1))" ]
	[ "$(yq -r '.reviews.labeling_instructions[-1].label' "$TMP/target/.coderabbit.yaml")" = "area:coalesce" ]
}

@test "github-checks tool is pinned in the composed config (#2270/#2271)" {
	# Value-pin github-checks (pr-test-analyzer): without this, a future base.yaml
	# edit that drops the tool (or changes the timeout) passes every byte/hash
	# gate (they just re-record) — only this asserts the tool + value land in the
	# composed config consumers inherit.
	mkdir -p "$TMP/gc"
	run bash "$SCRIPT" "$TMP/gc"
	[ "$status" -eq 0 ]
	[ "$(yq -r '.reviews.tools."github-checks".enabled' "$TMP/gc/.coderabbit.yaml")" = "true" ]
	[ "$(yq -r '.reviews.tools."github-checks".timeout_ms' "$TMP/gc/.coderabbit.yaml")" -eq 120000 ]
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

# ---- #2400: canonical-mirror exclusion branches (compose driven directly) ----

# Fixture: canonical dir with two hooks; empty _lib fixture dirs so the real
# plugin _lib never leaks into the composed output under test.
_mk_excl_fixture() {
	COMPOSE="${BATS_TEST_DIRNAME}/../../../scripts/compose-coderabbit.sh"
	BASEF="${BATS_TEST_DIRNAME}/../../../.coderabbit.base.yaml"
	[ -x "$COMPOSE" ]
	[ -f "$BASEF" ]
	mkdir -p "$TMP/canon" "$TMP/consumer" "$TMP/libcanon" "$TMP/libconsumer"
	printf '#!/bin/bash\necho a\n' >"$TMP/canon/alpha.sh"
	printf '#!/bin/bash\necho b\n' >"$TMP/canon/beta.sh"
}

_run_compose_fixture() {
	COMPOSE_CR_HOOKS_DIR="$TMP/canon" \
		COMPOSE_CR_CONSUMER_HOOKS_DIR="$TMP/consumer" \
		COMPOSE_CR_LIB_DIR="$TMP/libcanon" \
		COMPOSE_CR_CONSUMER_LIB_DIR="$TMP/libconsumer" \
		run bash "$COMPOSE" --base "$BASEF" --out "$TMP/composed.yaml"
}

@test "exclusion: byte-identical consumer mirror IS excluded (#2400 case 1)" {
	_mk_excl_fixture
	cp "$TMP/canon/alpha.sh" "$TMP/consumer/alpha.sh"
	cp "$TMP/canon/beta.sh" "$TMP/consumer/beta.sh"
	_run_compose_fixture
	[ "$status" -eq 0 ]
	run yq -r '.reviews.auto_review.path_filters[]' "$TMP/composed.yaml"
	[[ $output == *'!.claude/hooks/alpha.sh'* ]]
	[[ $output == *'!.claude/hooks/beta.sh'* ]]
}

@test "exclusion: consumer-OVERRIDDEN copy stays REVIEWED (#2400 case 2)" {
	_mk_excl_fixture
	cp "$TMP/canon/alpha.sh" "$TMP/consumer/alpha.sh"
	printf '#!/bin/bash\necho DIFFERENT\n' >"$TMP/consumer/beta.sh"
	_run_compose_fixture
	[ "$status" -eq 0 ]
	run yq -r '.reviews.auto_review.path_filters[]' "$TMP/composed.yaml"
	[[ $output == *'!.claude/hooks/alpha.sh'* ]]
	[[ $output != *'!.claude/hooks/beta.sh'* ]]
}

@test "exclusion: ABSENT consumer file IS excluded — mirror assumed (#2400 case 3)" {
	_mk_excl_fixture
	# consumer dir exists but has neither hook
	_run_compose_fixture
	[ "$status" -eq 0 ]
	run yq -r '.reviews.auto_review.path_filters[]' "$TMP/composed.yaml"
	[[ $output == *'!.claude/hooks/alpha.sh'* ]]
	[[ $output == *'!.claude/hooks/beta.sh'* ]]
}

@test "exclusion: cmp ERROR keeps the file REVIEWED + emits diagnostic (#2400 case 4)" {
	_mk_excl_fixture
	cp "$TMP/canon/alpha.sh" "$TMP/consumer/alpha.sh"
	cp "$TMP/canon/beta.sh" "$TMP/consumer/beta.sh"
	chmod 000 "$TMP/consumer/beta.sh"
	# Root ignores mode bits — the unreadable-file fixture can't produce a cmp
	# error there, so the branch is untestable; skip rather than false-pass.
	if [ "$(id -u)" -eq 0 ]; then
		chmod 644 "$TMP/consumer/beta.sh"
		skip "#2400: environmental — as root chmod 000 cannot make the fixture unreadable"
	fi
	_run_compose_fixture
	[ "$status" -eq 0 ]
	[[ $output == *"WARNING: cmp failed"* ]]
	[[ $output == *"beta.sh"* ]]
	chmod 644 "$TMP/consumer/beta.sh"
	run yq -r '.reviews.auto_review.path_filters[]' "$TMP/composed.yaml"
	[[ $output == *'!.claude/hooks/alpha.sh'* ]]
	[[ $output != *'!.claude/hooks/beta.sh'* ]]
}

@test "exclusion: #2254/#2257 head_comment injected on path_filters (#2400 case 5)" {
	_mk_excl_fixture
	_run_compose_fixture
	[ "$status" -eq 0 ]
	run grep -c "canonical-mirror exclusions auto-appended by compose-coderabbit.sh" "$TMP/composed.yaml"
	[ "$output" -ge 1 ]
}
