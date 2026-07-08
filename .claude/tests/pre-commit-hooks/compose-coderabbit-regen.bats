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
}

@test "stale composed: overlay staged WITHOUT recompose fails (exit 1 + remediation)" {
	cd "$TEST_TMP" || return 1
	printf 'reviews:\n  request_changes_workflow: false\n' >.coderabbit.overlay.yaml
	git add .coderabbit.overlay.yaml
	run bash "$GATE"
	[ "$status" -eq 1 ]
	[[ $output == *"drifts from compose"* ]]
	[[ $output == *"Fix: scripts/compose-coderabbit.sh"* ]]
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

@test "base staged while composed absent from tree AND index fails (exit 1)" {
	cd "$TEST_TMP" || return 1
	git rm -q .coderabbit.yaml
	printf 'reviews:\n  profile: assertive\n' >.coderabbit.base.yaml
	git add .coderabbit.base.yaml
	run bash "$GATE"
	[ "$status" -eq 1 ]
	[[ $output == *"does not exist"* ]]
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
