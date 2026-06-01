#!/usr/bin/env bats
# covers: pre-commit-hooks/memory-index-valid.sh
#
# #253 test-cov for the #251 fix: memory-index-valid's frontmatter `type:`
# check must accept a key indented under a `metadata:` block (the harness
# normalizes memory frontmatter to `metadata:\n  type: <t>`), while still
# accepting a top-level `type:` AND still rejecting a file that has only
# `node_type:` (so `^[[:space:]]*type:` must NOT match `node_type:`).
#
# Driven entirely against a temp MEM_DIR (MEMORY_DIR override) with
# MEMORY_CHECK=1 to bypass the staged-files gate, so each fixture isolates
# the frontmatter check (indexed + under caps + non-feedback ⇒ every OTHER
# check passes, leaving the `type:` rule as the only variable).

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../pre-commit-hooks/memory-index-valid.sh"
	[ -f "$HOOK" ]
	MEM_TMP=$(mktemp -d -t mem-index.XXXXXX) || return 1
}

teardown() {
	[ -n "${MEM_TMP:-}" ] && [ -d "$MEM_TMP" ] && [[ $MEM_TMP == */mem-index.* ]] && rm -rf "$MEM_TMP"
	return 0
}

# Write MEMORY.md indexing the given basenames (satisfies orphan + dead-pointer checks).
_index() {
	{
		echo "# Memory index"
		for b in "$@"; do echo "- [x]($b) — hook"; done
	} >"$MEM_TMP/MEMORY.md"
}

@test "#251: frontmatter type: indented under metadata block is accepted (normalized memory)" {
	cat >"$MEM_TMP/proj_x.md" <<'EOF'
---
name: proj_x
description: a harness-normalized memory
metadata:
  node_type: memory
  type: project
---
body
EOF
	_index proj_x.md
	run env MEMORY_DIR="$MEM_TMP" MEMORY_CHECK=1 bash "$HOOK"
	[ "$status" -eq 0 ]
	[[ $output == *"memory index valid"* ]]
}

@test "top-level type: still accepted (backward compat)" {
	cat >"$MEM_TMP/proj_y.md" <<'EOF'
---
name: proj_y
description: a top-level-frontmatter memory
type: project
---
body
EOF
	_index proj_y.md
	run env MEMORY_DIR="$MEM_TMP" MEMORY_CHECK=1 bash "$HOOK"
	[ "$status" -eq 0 ]
}

@test "node_type: alone (no type:) is rejected — the regex must not match node_type" {
	cat >"$MEM_TMP/proj_z.md" <<'EOF'
---
name: proj_z
description: has node_type but no type key
metadata:
  node_type: memory
---
body
EOF
	_index proj_z.md
	run env MEMORY_DIR="$MEM_TMP" MEMORY_CHECK=1 bash "$HOOK"
	[ "$status" -eq 1 ]
	[[ $output == *"missing 'type:'"* ]]
}
