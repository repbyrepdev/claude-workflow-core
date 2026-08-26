#!/usr/bin/env bats
# covers: pre-commit-hooks/compose-coderabbit-regen.sh
#
# #2402: the composed .coderabbit.yaml is per-repo (NOT hashed, NOT in
# bootstrap-manifest.yml) and had NO gate — a base/overlay edit committed
# without re-running compose-coderabbit.sh silently shipped a stale config.
# These drive the REAL gate + the REAL compose script inside a sandbox git
# repo (empty canonical hooks/_lib fixture dirs sit next to the symlinked
# compose script so the #2254 exclusion pass composes deterministically and
# never ingests the plugin's live hook tree).

setup() {
	GATE="${BATS_TEST_DIRNAME}/../../../pre-commit-hooks/compose-coderabbit-regen.sh"
	COMPOSE_REAL="${BATS_TEST_DIRNAME}/../../../scripts/compose-coderabbit.sh"
	[ -x "$GATE" ]
	[ -x "$COMPOSE_REAL" ]
	command -v yq >/dev/null
	TEST_TMP=$(mktemp -d -t crregen.XXXXXX) || return 1
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		mkdir -p scripts hooks _lib
		ln -s "$COMPOSE_REAL" scripts/compose-coderabbit.sh
		printf 'reviews:\n  profile: chill\n' >.coderabbit.base.yaml
		printf 'reviews:\n  request_changes_workflow: true\n' >.coderabbit.overlay.yaml
		bash scripts/compose-coderabbit.sh --base .coderabbit.base.yaml \
			--overlay .coderabbit.overlay.yaml --out .coderabbit.yaml >/dev/null 2>&1
		git add .coderabbit.base.yaml .coderabbit.overlay.yaml .coderabbit.yaml
		git -c user.email=t@t -c user.name=t commit -q -m "seed trio"
	) || {
		echo "FATAL: sandbox init failed" >&2
		return 1
	}
	unset COMPOSE_CR_REGEN_SKIP
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */crregen.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "trio untouched: unrelated staged file passes (exit 0, silent)" {
	cd "$TEST_TMP" || return 1
	echo x >unrelated.txt
	git add unrelated.txt
	run bash "$GATE"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "consistent stage: overlay edit + recomposed .coderabbit.yaml passes (exit 0)" {
	cd "$TEST_TMP" || return 1
	printf 'reviews:\n  request_changes_workflow: false\n' >.coderabbit.overlay.yaml
	bash scripts/compose-coderabbit.sh --base .coderabbit.base.yaml \
		--overlay .coderabbit.overlay.yaml --out .coderabbit.yaml >/dev/null 2>&1
	git add .coderabbit.overlay.yaml .coderabbit.yaml
	run bash "$GATE"
	[ "$status" -eq 0 ]
	# A clean pass is SILENT — drift/warn text with exit 0 would be a
	# report-without-refusal regression.
	[ -z "$output" ]
}

@test "stale composed: overlay staged WITHOUT recompose fails (exit 1 + remediation)" {
	cd "$TEST_TMP" || return 1
	printf 'reviews:\n  request_changes_workflow: false\n' >.coderabbit.overlay.yaml
	git add .coderabbit.overlay.yaml
	run bash "$GATE"
	[ "$status" -eq 1 ]
	[[ $output == *"drifts from compose"* ]] || return 1
	[[ $output == *"Fix: scripts/compose-coderabbit.sh"* ]] || return 1
	[[ $output == *"COMPOSE_CR_REGEN_SKIP=1"* ]]
}

@test "hand-edited composed staged alone fails (exit 1)" {
	cd "$TEST_TMP" || return 1
	printf '# sneaky hand edit\nreviews:\n  profile: assertive\n' >.coderabbit.yaml
	git add .coderabbit.yaml
	run bash "$GATE"
	[ "$status" -eq 1 ]
	[[ $output == *"drifts from compose"* ]]
}

@test "base staged while composed absent from index fails (exit 1)" {
	cd "$TEST_TMP" || return 1
	git rm -q .coderabbit.yaml
	printf 'reviews:\n  profile: assertive\n' >.coderabbit.base.yaml
	git add .coderabbit.base.yaml
	run bash "$GATE"
	[ "$status" -eq 1 ]
	[[ $output == *"not in the index"* ]]
}

@test "COMPOSE_CR_REGEN_SKIP=1 bypasses with audit line (exit 0)" {
	cd "$TEST_TMP" || return 1
	printf 'reviews:\n  request_changes_workflow: false\n' >.coderabbit.overlay.yaml
	git add .coderabbit.overlay.yaml
	COMPOSE_CR_REGEN_SKIP=1 run bash "$GATE"
	[ "$status" -eq 0 ]
	[[ $output == *"bypassing"* ]]
}

@test "compose script missing everywhere refuses (exit 2, fail-closed)" {
	cd "$TEST_TMP" || return 1
	rm scripts/compose-coderabbit.sh
	# Run a sandbox-local COPY of the gate: invoked from its real plugin path,
	# the hook-sibling fallback (_hook_self_dir/../scripts) resolves the REAL
	# compose script — correct for cache consumers, but this test needs BOTH
	# lookups to miss. From .claude/pre-commit-hooks/ neither repo-local
	# scripts/ nor ../scripts/ exists.
	mkdir -p .claude/pre-commit-hooks
	cp "$GATE" .claude/pre-commit-hooks/compose-coderabbit-regen.sh
	printf 'reviews:\n  request_changes_workflow: false\n' >.coderabbit.overlay.yaml
	git add .coderabbit.overlay.yaml
	run bash .claude/pre-commit-hooks/compose-coderabbit-regen.sh
	[ "$status" -eq 2 ]
	[[ $output == *"not found"* ]]
}

@test "unparseable staged base refuses via recompose failure (exit 2, stderr surfaced)" {
	cd "$TEST_TMP" || return 1
	printf 'not: [valid: yaml: {' >.coderabbit.base.yaml
	git add .coderabbit.base.yaml
	run bash "$GATE"
	[ "$status" -eq 2 ]
	[[ $output == *"recompose FAILED"* ]]
}

@test "base-only repo (no overlay) passes — bash-3.2 empty-array path (r2 code-reviewer)" {
	# "${OVERLAY_ARGS[@]}" with a zero-element array under set -u aborts on
	# bash 3.2 (macOS /bin/bash; fixed in 4.4) — the \${arr[@]+...} guard must
	# keep the no-overlay recompose working.
	cd "$TEST_TMP" || return 1
	git rm -q .coderabbit.overlay.yaml
	bash scripts/compose-coderabbit.sh --base .coderabbit.base.yaml \
		--out .coderabbit.yaml >/dev/null 2>&1
	git add .coderabbit.yaml
	run bash "$GATE"
	[ "$status" -eq 0 ]
	# Positive success shape (silent clean pass), not just crash-absence.
	[ -z "$output" ]
}

@test "untracked-but-present composed refuses — commit ships without it (r2 comment-analyzer)" {
	# Fresh composed in the WORKTREE only: the old `|| cat` fallback compared
	# equal and passed while the commit shipped base/overlay WITHOUT the
	# composed artifact. Index-only comparison must refuse.
	cd "$TEST_TMP" || return 1
	git rm -q --cached .coderabbit.yaml
	printf 'reviews:\n  request_changes_workflow: false\n' >.coderabbit.overlay.yaml
	bash scripts/compose-coderabbit.sh --base .coderabbit.base.yaml \
		--overlay .coderabbit.overlay.yaml --out .coderabbit.yaml >/dev/null 2>&1
	git add .coderabbit.overlay.yaml # composed intentionally NOT re-added
	run bash "$GATE"
	[ "$status" -eq 1 ]
	[[ $output == *"not in the index"* ]]
}

@test "staged overlay DELETION recomposes base-only from the index (r2 silent-failure)" {
	# The commit's post-state has NO overlay; the gate must judge the index
	# (base-only recompose), never fall back to the worktree file being
	# removed. Pass when composed matches the base-only recompose.
	cd "$TEST_TMP" || return 1
	git rm -q .coderabbit.overlay.yaml
	bash scripts/compose-coderabbit.sh --base .coderabbit.base.yaml \
		--out .coderabbit.yaml >/dev/null 2>&1
	git add .coderabbit.yaml
	run bash "$GATE"
	[ "$status" -eq 0 ]
	[ -z "$output" ] # clean pass is silent
	# ...and FAIL (drift) when composed still carries the deleted overlay.
	git checkout -q HEAD -- .coderabbit.yaml # restore overlay-bearing composed
	git rm -q --cached .coderabbit.overlay.yaml 2>/dev/null || true
	git add .coderabbit.yaml
	run bash "$GATE"
	[ "$status" -eq 1 ]
	[[ $output == *"drifts from compose"* ]]
}

@test "staged base DELETION refuses (exit 1) — composed retained without its input" {
	cd "$TEST_TMP" || return 1
	git rm -q .coderabbit.base.yaml
	run bash "$GATE"
	[ "$status" -eq 1 ]
	[[ $output == *"not in the index"* ]] || [[ $output == *"staged for deletion"* ]]
}

@test "trailing-newline hand-edit to composed is caught — byte-exact cmp (r2 silent-failure)" {
	# $(...) captures strip trailing newlines on BOTH sides, so an appended
	# blank line passed the old string compare. cmp is byte-exact.
	cd "$TEST_TMP" || return 1
	printf '\n\n' >>.coderabbit.yaml
	git add .coderabbit.yaml
	run bash "$GATE"
	[ "$status" -eq 1 ]
	[[ $output == *"drifts from compose"* ]]
}

@test "exclusion-parity: byte-identical consumer mirror composes + passes (r2 pr-test-analyzer)" {
	# Exercises the COMPOSE_CR_CONSUMER_{HOOKS,LIB}_DIR pins WITH content: a
	# canonical hook with a byte-identical consumer mirror lands a per-file
	# exclusion in the composed output, and the gate's recompute (same pins)
	# must agree byte-for-byte.
	cd "$TEST_TMP" || return 1
	printf '#!/bin/bash\necho x\n' >hooks/x.sh
	mkdir -p .claude/hooks .claude/_lib
	cp hooks/x.sh .claude/hooks/x.sh
	COMPOSE_CR_CONSUMER_HOOKS_DIR="$TEST_TMP/.claude/hooks" \
		COMPOSE_CR_CONSUMER_LIB_DIR="$TEST_TMP/.claude/_lib" \
		bash scripts/compose-coderabbit.sh --base .coderabbit.base.yaml \
		--overlay .coderabbit.overlay.yaml --out .coderabbit.yaml >/dev/null 2>&1
	grep -q '!.claude/hooks/x.sh' .coderabbit.yaml
	git add .coderabbit.yaml
	run bash "$GATE"
	[ "$status" -eq 0 ]
	[ -z "$output" ] # clean pass is silent
}

@test "hook-sibling compose fallback POSITIVE path works (r2 pr-test-analyzer)" {
	# Every consumer repo runs the gate from the plugin cache and resolves the
	# compose script via _hook_self_dir/../scripts — prove that path composes,
	# not just that its absence exits 2.
	cd "$TEST_TMP" || return 1
	rm scripts/compose-coderabbit.sh
	# Canonical dirs resolve relative to the symlinked compose script's dir
	# (.claude/scripts/../hooks + ../_lib) — create them empty so the
	# exclusion pass composes deterministically (same as the top-level layout).
	mkdir -p .claude/pre-commit-hooks .claude/scripts .claude/hooks .claude/_lib
	cp "$GATE" .claude/pre-commit-hooks/compose-coderabbit-regen.sh
	ln -s "$COMPOSE_REAL" .claude/scripts/compose-coderabbit.sh
	printf 'reviews:\n  request_changes_workflow: false\n' >.coderabbit.overlay.yaml
	bash .claude/scripts/compose-coderabbit.sh --base .coderabbit.base.yaml \
		--overlay .coderabbit.overlay.yaml --out .coderabbit.yaml >/dev/null 2>&1
	git add .coderabbit.overlay.yaml .coderabbit.yaml
	run bash .claude/pre-commit-hooks/compose-coderabbit-regen.sh
	[ "$status" -eq 0 ]
	[ -z "$output" ] # clean pass is silent
}
