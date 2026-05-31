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

@test "no overlay → base emitted verbatim (comments preserved) (#234)" {
	run "$SCRIPT" --base "$BASE"
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

@test "empty/comment-only overlay → base verbatim + NOTE (#234)" {
	printf '# only a comment\n' >"$TMP/ovl.yaml"
	run "$SCRIPT" --base "$BASE" --overlay "$TMP/ovl.yaml"
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
