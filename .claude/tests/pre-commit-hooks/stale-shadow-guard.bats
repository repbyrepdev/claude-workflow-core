#!/usr/bin/env bats
# covers: pre-commit-hooks/stale-shadow-guard.sh
#
# CR #223: every pass-path test asserts BOTH channels — the gate is SILENT
# (no stdout/stderr) when it passes, so success cases pair `[ "$status" -eq 0 ]`
# with `[ -z "$output" ]`; failure cases assert the diagnostic naming the shadow.

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	HOOK="${REPO_ROOT}/pre-commit-hooks/stale-shadow-guard.sh"
	TEST_TMP=$(mktemp -d -t ssg.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# Synthetic consumer-shaped repo: a repo-root canonical at scripts/<x> plus
	# a shadow under .claude/scripts/<x>. The hook is co-located at
	# pre-commit-hooks/ so it resolves the repo root via git-toplevel.
	(
		set -e
		cd "$TEST_TMP"
		git init -q -b main
		git config user.email t@t
		git config user.name t
		mkdir -p pre-commit-hooks scripts/copilot _lib .claude/scripts/copilot .claude/_lib
		cp "$HOOK" pre-commit-hooks/stale-shadow-guard.sh
		chmod +x pre-commit-hooks/stale-shadow-guard.sh
		# Canonical helpers at the repo root.
		printf '#!/bin/bash\necho canonical-copilot\n' >scripts/copilot/try-free.sh
		printf '#!/bin/bash\necho canonical-lib\n' >_lib/helper.sh
		chmod +x scripts/copilot/try-free.sh _lib/helper.sh
		git add .
		git commit -q -m baseline
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */ssg.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "passes when no .claude/scripts|_lib file staged" {
	cd "$TEST_TMP" || return 1
	echo "readme" >README.md
	git add README.md
	run pre-commit-hooks/stale-shadow-guard.sh
	[ "$status" -eq 0 ]
	[ -z "$output" ] # no candidate staged → clean pass, silent
}

@test "FAILS when .claude/scripts shadow DIFFERS from canonical" {
	cd "$TEST_TMP" || return 1
	printf '#!/bin/bash\necho STALE-SHADOW\n' >.claude/scripts/copilot/try-free.sh
	git add .claude/scripts/copilot/try-free.sh
	run pre-commit-hooks/stale-shadow-guard.sh
	[ "$status" -eq 1 ]
	[[ $output == *".claude/scripts/copilot/try-free.sh"* ]] || return 1
	# Anchor on the hook's actual emitted format ("  - <shadow>  (canonical: <c>)")
	# — a bare "scripts/copilot/try-free.sh" substring is tautological (it's also a
	# substring of the SHADOW path), so it can't prove the canonical was named.
	[[ $output == *"canonical: scripts/copilot/try-free.sh"* ]] # names the canonical too || return 1
	[[ $output == *"#223"* ]]
}

@test "FAILS when .claude/_lib shadow DIFFERS from canonical" {
	cd "$TEST_TMP" || return 1
	printf '#!/bin/bash\necho STALE-LIB\n' >.claude/_lib/helper.sh
	git add .claude/_lib/helper.sh
	run pre-commit-hooks/stale-shadow-guard.sh
	[ "$status" -eq 1 ]
	[[ $output == *".claude/_lib/helper.sh"* ]] || return 1
	# Anchor on the emitted "(canonical: <c>)" format — bare "_lib/helper.sh" is a
	# substring of the shadow path too, so it's tautological (parity w/ scripts test).
	[[ $output == *"canonical: _lib/helper.sh"* ]] # names the canonical too || return 1
	[[ $output == *"#223"* ]]
}

@test "passes when shadow is IDENTICAL to canonical (non-drifting mirror)" {
	cd "$TEST_TMP" || return 1
	# Byte-for-byte copy of the canonical — harmless, must NOT fire.
	cp scripts/copilot/try-free.sh .claude/scripts/copilot/try-free.sh
	git add .claude/scripts/copilot/try-free.sh
	run pre-commit-hooks/stale-shadow-guard.sh
	[ "$status" -eq 0 ]
	[ -z "$output" ] # identical mirror → pass, no drift diagnostic
}

@test "passes when shadow has NO repo-root canonical (producer-local exemption)" {
	cd "$TEST_TMP" || return 1
	# A .claude/scripts file with NO sibling at the repo root — this is the
	# legitimately-local case (mirrors .claude/review-config.yml having no
	# top-level copy). Must NOT fire even though content is novel.
	printf '#!/bin/bash\necho local-only\n' >.claude/scripts/local-only.sh
	git add .claude/scripts/local-only.sh
	run pre-commit-hooks/stale-shadow-guard.sh
	[ "$status" -eq 0 ]
	[ -z "$output" ] # no canonical → producer-local exemption, silent pass
}

@test "compares the STAGED blob, not the worktree (add clean, then dirty worktree)" {
	cd "$TEST_TMP" || return 1
	# Stage an IDENTICAL copy (clean), THEN edit the worktree to drift. The
	# gate must validate the staged blob (clean) and PASS — proving it reads
	# the index, not the worktree.
	cp scripts/copilot/try-free.sh .claude/scripts/copilot/try-free.sh
	git add .claude/scripts/copilot/try-free.sh
	printf 'WORKTREE-ONLY-DRIFT\n' >>.claude/scripts/copilot/try-free.sh
	run pre-commit-hooks/stale-shadow-guard.sh
	[ "$status" -eq 0 ]
	[ -z "$output" ] # staged blob is clean → pass, silent (worktree drift ignored)
}

@test "staged-blob drift is caught even when worktree matches canonical" {
	cd "$TEST_TMP" || return 1
	# Inverse of the above: stage a DRIFTING blob, then restore the worktree to
	# match the canonical. The gate must still FAIL on the staged (drifting) blob.
	printf '#!/bin/bash\necho STAGED-DRIFT\n' >.claude/scripts/copilot/try-free.sh
	git add .claude/scripts/copilot/try-free.sh
	cp scripts/copilot/try-free.sh .claude/scripts/copilot/try-free.sh # worktree now clean
	run pre-commit-hooks/stale-shadow-guard.sh
	[ "$status" -eq 1 ]
	[[ $output == *".claude/scripts/copilot/try-free.sh"* ]] # names the drifting shadow
}

@test "bypass env STALE_SHADOW_GUARD_SKIP=1 lets a drifting shadow through" {
	cd "$TEST_TMP" || return 1
	printf '#!/bin/bash\necho STALE\n' >.claude/scripts/copilot/try-free.sh
	git add .claude/scripts/copilot/try-free.sh
	run env STALE_SHADOW_GUARD_SKIP=1 pre-commit-hooks/stale-shadow-guard.sh
	[ "$status" -eq 0 ]
	[[ $output == *"STALE_SHADOW_GUARD_SKIP"* ]]
}

@test "deleted shadow does not fire (deletion can't drift)" {
	cd "$TEST_TMP" || return 1
	# First commit a drifting shadow WITHOUT the gate, then stage its deletion.
	printf '#!/bin/bash\necho STALE\n' >.claude/scripts/copilot/try-free.sh
	git add .claude/scripts/copilot/try-free.sh
	git commit -q -m "add shadow (gate bypassed)" --no-verify
	git rm -q .claude/scripts/copilot/try-free.sh
	run pre-commit-hooks/stale-shadow-guard.sh
	[ "$status" -eq 0 ]
	[ -z "$output" ] # a staged deletion is not a candidate → silent pass
}

@test "precondition: not in a git repo → exit 2" {
	NOGIT=$(mktemp -d -t ssg-nogit.XXXXXX) || return 1
	cp "$HOOK" "$NOGIT/stale-shadow-guard.sh"
	chmod +x "$NOGIT/stale-shadow-guard.sh"
	cd "$NOGIT" || return 1
	# CR #478 p2: $TMPDIR can live inside a git worktree on some systems, so a
	# bare run could discover an ancestor repo and never hit the exit-2 branch.
	# GIT_CEILING_DIRECTORIES stops git's upward repo discovery at $NOGIT.
	run env GIT_CEILING_DIRECTORIES="$NOGIT" ./stale-shadow-guard.sh
	cd /tmp || true
	rm -rf "$NOGIT"
	[ "$status" -eq 2 ]
	[[ $output == *"git working tree"* ]]
}

@test "canonical staged but absent from worktree is still compared (r3 index check)" {
	cd "$TEST_TMP" || return 1
	# Stage a DRIFTING shadow, then delete the canonical from the WORKTREE while
	# its index/HEAD entry remains. The index-based existence check (git cat-file
	# -e :canonical) must still see the canonical and CATCH the drift — the old
	# worktree [ -f ] test would skip it and miss the drift.
	printf '#!/bin/bash\necho STAGED-SHADOW-DRIFT\n' >.claude/scripts/copilot/try-free.sh
	git add .claude/scripts/copilot/try-free.sh
	rm scripts/copilot/try-free.sh # gone from worktree, still in index + HEAD
	run pre-commit-hooks/stale-shadow-guard.sh
	[ "$status" -eq 1 ]
	[[ $output == *".claude/scripts/copilot/try-free.sh"* ]]
}
