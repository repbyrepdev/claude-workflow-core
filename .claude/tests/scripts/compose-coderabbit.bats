#!/usr/bin/env bats
# covers: scripts/compose-coderabbit.sh
#
# #234 (Wave H): compose .coderabbit.yaml = base [*+ overlay]. Merge semantics
# must be: overlay SCALARS win, overlay ARRAYS append to base, base-only keys
# preserved; no overlay ⇒ base verbatim (comments kept). Fail-closed on yq
# missing / base missing / base-not-a-map / overlay-unparseable.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/compose-coderabbit.sh"
	[ -x "$SCRIPT" ]
	command -v yq >/dev/null
	TMP=$(mktemp -d -t composecr.XXXXXX) || return 1
	BASE="$TMP/base.yaml"
	cat >"$BASE" <<'EOF'
# header comment
language: en-US
reviews:
  profile: assertive
  labeling_instructions:
    - label: area:hooks
    - label: area:infrastructure
  auto_review:
    base_branches:
      - main
EOF
}

teardown() {
	[ -n "${TMP:-}" ] && [ -d "$TMP" ] && [[ $TMP == */composecr.* ]] && rm -rf "$TMP"
	return 0
}

@test "no overlay (+ no hooks dir) → base emitted verbatim (comments preserved) (#234)" {
	# #2254: point the hook-exclusion enumerator at a nonexistent dir so the
	# CR-in-CI mirror-hook injection is skipped — isolating the base-verbatim
	# merge behavior this test covers. (Injection is covered separately below.)
	run env COMPOSE_CR_HOOKS_DIR="$TMP/no-such-hooks" "$SCRIPT" --base "$BASE"
	[ "$status" -eq 0 ]
	[[ $output == *"# header comment"* ]]
	# Byte-identical to base.
	printf '%s\n' "$output" >"$TMP/out.yaml"
	diff "$BASE" "$TMP/out.yaml"
}

@test "overlay scalar WINS over base (#234)" {
	cat >"$TMP/ovl.yaml" <<'EOF'
reviews:
  profile: chill
EOF
	run "$SCRIPT" --base "$BASE" --overlay "$TMP/ovl.yaml"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" >"$TMP/out.yaml"
	[ "$(yq -r '.reviews.profile' "$TMP/out.yaml")" = "chill" ]
}

@test "overlay arrays APPEND to base arrays (#234)" {
	cat >"$TMP/ovl.yaml" <<'EOF'
reviews:
  labeling_instructions:
    - label: area:coalesce
EOF
	run "$SCRIPT" --base "$BASE" --overlay "$TMP/ovl.yaml"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" >"$TMP/out.yaml"
	# base 2 + overlay 1 = 3, appended last.
	[ "$(yq -r '.reviews.labeling_instructions | length' "$TMP/out.yaml")" -eq 3 ]
	[ "$(yq -r '.reviews.labeling_instructions[-1].label' "$TMP/out.yaml")" = "area:coalesce" ]
}

@test "base-only keys preserved through merge (#234)" {
	cat >"$TMP/ovl.yaml" <<'EOF'
reviews:
  profile: chill
EOF
	run "$SCRIPT" --base "$BASE" --overlay "$TMP/ovl.yaml"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" >"$TMP/out.yaml"
	[ "$(yq -r '.language' "$TMP/out.yaml")" = "en-US" ]
	[ "$(yq -r '.reviews.auto_review.base_branches[0]' "$TMP/out.yaml")" = "main" ]
}

@test "--out writes the composed file atomically (#234)" {
	cat >"$TMP/ovl.yaml" <<'EOF'
reviews:
  profile: chill
EOF
	run "$SCRIPT" --base "$BASE" --overlay "$TMP/ovl.yaml" --out "$TMP/.coderabbit.yaml"
	[ "$status" -eq 0 ]
	[ -f "$TMP/.coderabbit.yaml" ]
	[ "$(yq -r '.reviews.profile' "$TMP/.coderabbit.yaml")" = "chill" ]
	# No leftover temp.
	run bash -c "ls $TMP/.coderabbit.yaml.* 2>/dev/null | wc -l | tr -d ' '"
	[ "$output" = "0" ]
}

@test "empty/comment-only overlay (+ no hooks dir) → base verbatim + NOTE (#234)" {
	printf '# only a comment\n' >"$TMP/ovl.yaml"
	# #2254: skip the hook-exclusion injection (see above) to isolate verbatim.
	run env COMPOSE_CR_HOOKS_DIR="$TMP/no-such-hooks" "$SCRIPT" --base "$BASE" --overlay "$TMP/ovl.yaml"
	[ "$status" -eq 0 ]
	[[ $output == *"# header comment"* ]]   # base verbatim
	[[ $output == *"no mapping content"* ]] # NOTE on stderr (captured by run)
}

@test "missing --base → exit 2 (#234)" {
	run "$SCRIPT" --overlay "$TMP/whatever.yaml"
	[ "$status" -eq 2 ]
	[[ $output == *"--base is required"* ]]
}

@test "nonexistent base path → exit 2 (#234)" {
	run "$SCRIPT" --base "$TMP/nope.yaml"
	[ "$status" -eq 2 ]
	[[ $output == *"base not found"* ]]
}

@test "base that is not a YAML mapping → exit 2 (#234)" {
	printf -- '- just\n- a\n- list\n' >"$TMP/notmap.yaml"
	run "$SCRIPT" --base "$TMP/notmap.yaml"
	[ "$status" -eq 2 ]
	[[ $output == *"not a valid YAML mapping"* ]]
}

@test "unknown arg → exit 2 (#234)" {
	run "$SCRIPT" --base "$BASE" --bogus
	[ "$status" -eq 2 ]
	[[ $output == *"unknown arg"* ]]
}

@test "fail-closed when overlay clobbers a base mapping-key with a scalar (#234 r1)" {
	# silent-failure-hunter r1: `reviews: "x"` would, under `*+`, let the scalar
	# win and silently gut the base reviews map. The type-clobber guard must
	# reject it (exit 2), naming the offending key.
	cat >"$TMP/ovl.yaml" <<'EOF'
reviews: "gut-the-map"
EOF
	run "$SCRIPT" --base "$BASE" --overlay "$TMP/ovl.yaml"
	[ "$status" -eq 2 ]
	[[ $output == *"non-mapping"* ]]
	[[ $output == *"reviews"* ]]
}

@test "fail-closed on a NESTED clobber (overlay sets reviews.auto_review scalar) (#234 r2)" {
	# CR r2 MAJOR: the guard must catch clobbers at ANY depth, not just the top
	# level. base has reviews.auto_review as a map; overlay scalars it.
	cat >"$TMP/ovl.yaml" <<'EOF'
reviews:
  auto_review: "boom"
EOF
	run "$SCRIPT" --base "$BASE" --overlay "$TMP/ovl.yaml"
	[ "$status" -eq 2 ]
	[[ $output == *"non-mapping"* ]]
	[[ $output == *"reviews.auto_review"* ]]
}

@test "overlay that only ADDS to a base map (no clobber) is allowed (#234 r1)" {
	# Guard must NOT false-positive: adding a key under reviews keeps it a map.
	cat >"$TMP/ovl.yaml" <<'EOF'
reviews:
  poem: true
EOF
	run "$SCRIPT" --base "$BASE" --overlay "$TMP/ovl.yaml"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" >"$TMP/out.yaml"
	[ "$(yq -r '.reviews.poem' "$TMP/out.yaml")" = "true" ]
	[ "$(yq -r '.reviews.profile' "$TMP/out.yaml")" = "assertive" ]
}

@test "fail-closed when yq is missing (#234 r1)" {
	# pr-test-analyzer r1: the `command -v yq || exit 2` branch is otherwise
	# untestable (setup requires yq). Run bash with an empty PATH so the yq
	# lookup fails at the first precondition check, before any external tool.
	run env PATH=/var/empty "$(command -v bash)" "$SCRIPT" --base "$BASE"
	[ "$status" -eq 2 ]
	[[ $output == *"yq required"* ]]
}

@test "#2254: canonical hooks → per-file !.claude/hooks exclusions appended" {
	# Fake canonical hooks/ set: 2 plugin hooks. A consumer-authored hook is NOT
	# in this set, so it must NOT be excluded (CR keeps reviewing it).
	mkdir -p "$TMP/hooks"
	printf '#!/bin/bash\n' >"$TMP/hooks/alpha.sh"
	printf '#!/bin/bash\n' >"$TMP/hooks/beta.sh"
	run env COMPOSE_CR_HOOKS_DIR="$TMP/hooks" "$SCRIPT" --base "$BASE" --out "$TMP/.coderabbit.yaml"
	[ "$status" -eq 0 ]
	[ "$(yq -r '.reviews.auto_review.path_filters[] | select(. == "!.claude/hooks/alpha.sh")' "$TMP/.coderabbit.yaml")" = "!.claude/hooks/alpha.sh" ]
	[ "$(yq -r '.reviews.auto_review.path_filters[] | select(. == "!.claude/hooks/beta.sh")' "$TMP/.coderabbit.yaml")" = "!.claude/hooks/beta.sh" ]
	# Exactly the canonical set is excluded — $BASE had no path_filters, so a
	# count of 2 proves no extra/leaked entries (a consumer-authored hook not in
	# COMPOSE_CR_HOOKS_DIR is never enumerated, hence never excluded).
	[ "$(yq -r '.reviews.auto_review.path_filters | length' "$TMP/.coderabbit.yaml")" -eq 2 ]
	# base content survives the injection.
	[ "$(yq -r '.reviews.auto_review.base_branches[0]' "$TMP/.coderabbit.yaml")" = "main" ]
}

@test "#2254: hook-exclusion injection is idempotent (recomposed from base)" {
	mkdir -p "$TMP/hooks"
	printf '#!/bin/bash\n' >"$TMP/hooks/alpha.sh"
	run env COMPOSE_CR_HOOKS_DIR="$TMP/hooks" "$SCRIPT" --base "$BASE" --out "$TMP/.coderabbit.yaml"
	[ "$status" -eq 0 ]
	n1=$(yq -r '[.reviews.auto_review.path_filters[] | select(. == "!.claude/hooks/alpha.sh")] | length' "$TMP/.coderabbit.yaml")
	run env COMPOSE_CR_HOOKS_DIR="$TMP/hooks" "$SCRIPT" --base "$BASE" --out "$TMP/.coderabbit.yaml"
	[ "$status" -eq 0 ]
	n2=$(yq -r '[.reviews.auto_review.path_filters[] | select(. == "!.claude/hooks/alpha.sh")] | length' "$TMP/.coderabbit.yaml")
	# Exactly one occurrence each run (not doubled) — result recomputed from base.
	[ "$n1" -eq 1 ]
	[ "$n2" -eq 1 ]
}

@test "#2254: hook exclusions APPEND to a base that already has path_filters" {
	# Production shape: a base WITH a pre-existing path_filters array. Proves the
	# `(existing // []) + new` merge preserves the base entries (a regression to
	# `= new` would silently wipe them and pass the empty-base tests).
	cat >"$TMP/pf-base.yaml" <<'EOF'
reviews:
  auto_review:
    path_filters:
      - "!**/*.md"
      - "!LICENSE"
EOF
	mkdir -p "$TMP/hooks"
	printf '#!/bin/bash\n' >"$TMP/hooks/alpha.sh"
	run env COMPOSE_CR_HOOKS_DIR="$TMP/hooks" "$SCRIPT" --base "$TMP/pf-base.yaml" --out "$TMP/.coderabbit.yaml"
	[ "$status" -eq 0 ]
	# Pre-existing filters SURVIVE (appended-to, not replaced).
	[ "$(yq -r '.reviews.auto_review.path_filters[] | select(. == "!**/*.md")' "$TMP/.coderabbit.yaml")" = "!**/*.md" ]
	[ "$(yq -r '.reviews.auto_review.path_filters[] | select(. == "!LICENSE")' "$TMP/.coderabbit.yaml")" = "!LICENSE" ]
	# New hook exclusion appended after them; total = 2 existing + 1 hook.
	[ "$(yq -r '.reviews.auto_review.path_filters[] | select(. == "!.claude/hooks/alpha.sh")' "$TMP/.coderabbit.yaml")" = "!.claude/hooks/alpha.sh" ]
	[ "$(yq -r '.reviews.auto_review.path_filters | length' "$TMP/.coderabbit.yaml")" -eq 3 ]
}

@test "#2254: existing-but-empty hooks dir → no exclusions appended" {
	mkdir -p "$TMP/emptyhooks"
	run env COMPOSE_CR_HOOKS_DIR="$TMP/emptyhooks" "$SCRIPT" --base "$BASE"
	[ "$status" -eq 0 ]
	# Dir exists but has no *.sh → injection is a no-op, no hook exclusions.
	[[ $output != *"!.claude/hooks/"* ]]
}
