#!/usr/bin/env bats
# covers: skills/prove-yourself-audit/run.sh
#
# (#2643) Differential symptom evidence.
#
# #2562 made the retest a RUN rather than a claim. That proves EXECUTION,
# not CONSEQUENCE: `--retest-cmd "bash hooks/x.sh" --retest-rc 0` is
# satisfied by a hook that was already green before the fix, and the file
# admits the boundary itself — "the mechanical system cannot judge the
# semantic relevance of arbitrary commands."
#
# The symptom flags encode a DIFFERENCE instead, and both halves are
# re-executed: the fixed half in the live tree, the baseline in a detached
# worktree at HEAD. The cycle order is fix -> record-fix -> commit, so at
# record time HEAD IS the pre-fix tree and the baseline costs nothing to
# obtain — no sabotage, no mutation, nothing to restore.

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	RUN="$REPO_ROOT/skills/prove-yourself-audit/run.sh"
	[ -x "$RUN" ] || [ -r "$RUN" ]
	WORK=$(mktemp -d -t prove-symptom.XXXXXX) || return 1
	(
		set -e
		cd "$WORK"
		git init -q
		git config user.email t@t
		git config user.name t
		mkdir -p scripts hooks .claude/tests
		printf '#!/bin/bash\nexit 1\n' >scripts/thing.sh
		chmod +x scripts/thing.sh
		git add -A
		git commit -qm init
	) || return 1
	export PROVE_RETEST_TIMEOUT=60 PROVE_BASELINE_TIMEOUT=60
}

teardown() {
	cd "${TMPDIR:-/tmp}" 2>/dev/null || cd "$HOME" || return 0
	# Prune any worktree the run may have left registered in the fixture.
	# `if`, not `A && B || C` — the chained form runs the handler both when
	# B fails AND when A fails, which reads as if-then-else and is not one.
	if [ -d "${WORK:-}/.git" ]; then
		git -C "$WORK" worktree prune 2>/dev/null || true
	fi
	case "${WORK:-}" in
	*/prove-symptom.*) rm -rf "$WORK" ;;
	esac
	return 0
}

# Run record-fix inside the fixture repo.
_rec() { run bash -c "cd '$WORK' && '$RUN' record-fix $1"; }

# The standard shape: a tracked file whose behaviour the "fix" changes.
_make_fix() {
	printf '#!/bin/bash\nexit 0\n' >"$WORK/scripts/thing.sh"
}

_base_args() {
	printf '%s' "--source issue --finding-id t --finding-text t --fix-summary t \
--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0"
}

# ---- the claim is a DIFFERENCE -------------------------------------------

@test "#2643: a genuine differential is CONFIRMED and recorded" {
	# The whole point, end to end: rc 1 without the fix, rc 0 with it, both
	# observed rather than claimed.
	_make_fix
	_rec "$(_base_args) --symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -eq 0 ] || {
		echo "a real differential was refused: $output"
		return 1
	}
	[[ $output == *"differential CONFIRMED"* ]] || {
		echo "the differential was not announced: $output"
		return 1
	}
	[[ $output == *"1 without the fix, 0 with it"* ]] || {
		echo "the confirmation does not name the two observed rcs: $output"
		return 1
	}
}

@test "#2643: EQUAL rcs are refused — that is the 'trust me' hole reopening" {
	# `--symptom-cmd true` with both rcs 0 describes a command the fix did
	# not affect. Accepting it would reintroduce, in a new field, exactly
	# the free-text claim #2562 removed from --retest-cmd.
	_make_fix
	_rec "$(_base_args) --symptom-cmd true --symptom-baseline-rc 0 --symptom-fixed-rc 0"
	[ "$status" -eq 2 ] || {
		echo "equal rcs returned $status, expected 2: $output"
		return 1
	}
	[[ $output == *"BOTH 0"* ]] || {
		echo "the refusal does not say why: $output"
		return 1
	}
}

@test "#2643: a WRONG claimed rc is refused on either half" {
	_make_fix
	# fixed half wrong
	_rec "$(_base_args) --symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 7"
	[ "$status" -ne 0 ]
	[[ $output == *"SYMPTOM MISMATCH (fixed tree)"* ]] || {
		echo "a wrong fixed-rc was not caught: $output"
		return 1
	}
	# baseline half wrong
	_rec "$(_base_args) --symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 5 --symptom-fixed-rc 0"
	[ "$status" -ne 0 ]
	[[ $output == *"SYMPTOM MISMATCH (baseline"* ]] || {
		echo "a wrong baseline-rc was not caught: $output"
		return 1
	}
}

# ---- who has to supply it ------------------------------------------------

@test "#2643: source=issue REQUIRES the differential" {
	# Issue-driven bug work is the case where "did the reported symptom go
	# away" is the entire question — and until this change it could not be
	# recorded at all, because the source vocabulary was review stages only.
	_make_fix
	_rec "$(_base_args)"
	[ "$status" -eq 2 ] || {
		echo "source=issue without symptom flags returned $status, expected 2: $output"
		return 1
	}
	[[ $output == *REQUIRED* ]] || {
		echo "the refusal does not say it is required: $output"
		return 1
	}
	[[ $output == *"does not prove it would have FAILED without it"* ]] || {
		echo "the message does not explain WHY a retest is insufficient: $output"
		return 1
	}
}

@test "#2643: a cycle-critical citation REQUIRES it too" {
	# The same population the critical-path retest rule already targets,
	# whose cost operators have already accepted.
	printf '#!/bin/bash\nexit 0\n' >"$WORK/hooks/h.sh"
	chmod +x "$WORK/hooks/h.sh"
	run bash -c "cd '$WORK' && '$RUN' record-fix --source phase1 --confidence 8 \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files hooks/h.sh --retest-cmd 'bash hooks/h.sh' --retest-rc 0"
	[ "$status" -eq 2 ] || {
		echo "a cycle-critical fix without the differential returned $status: $output"
		return 1
	}
	[[ $output == *"cycle-critical"* ]] || {
		echo "the refusal does not name the population: $output"
		return 1
	}
}

@test "#2643: an ORDINARY fix does not require it — the gate must stay usable" {
	# AGENTS.md records a phase-1 deadlock that "pressured the operator
	# into fabricating review records — the exact dishonesty the gate
	# exists to prevent". A gate that fires on every fix is skipped on
	# every fix, and a skipped gate proves less than an optional one.
	_make_fix
	run bash -c "cd '$WORK' && '$RUN' record-fix --source phase1 --confidence 5 \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0"
	[ "$status" -eq 0 ] || {
		echo "an ordinary fix was blocked on symptom evidence: $output"
		return 1
	}
}

# ---- the four holes ------------------------------------------------------

@test "#2643: an ABSENCE-shaped baseline (127) is refused by default" {
	# If the fix ADDS a file, the baseline exits "command not found" and
	# looks exactly like "fails without the fix" — while proving only that
	# the file is new.
	printf '#!/bin/bash\nexit 0\n' >"$WORK/scripts/new.sh"
	chmod +x "$WORK/scripts/new.sh"
	run bash -c "cd '$WORK' && '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/new.sh --retest-cmd 'bash scripts/new.sh' --retest-rc 0 \
		--symptom-cmd 'bash scripts/new.sh' --symptom-baseline-rc 127 --symptom-fixed-rc 0"
	[ "$status" -ne 0 ] || {
		echo "an absence-shaped baseline was accepted as proof: $output"
		return 1
	}
	[[ $output == *"looks like proof and is not"* ]] || {
		echo "the refusal does not explain the shape: $output"
		return 1
	}
	[[ $output == *"--allow-absence-baseline"* ]] || {
		echo "the refusal does not offer the explicit claim: $output"
		return 1
	}
}

@test "#2643: --allow-absence-baseline is the explicit claim, and works" {
	printf '#!/bin/bash\nexit 0\n' >"$WORK/scripts/new.sh"
	chmod +x "$WORK/scripts/new.sh"
	run bash -c "cd '$WORK' && '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/new.sh --retest-cmd 'bash scripts/new.sh' --retest-rc 0 \
		--symptom-cmd 'bash scripts/new.sh' --symptom-baseline-rc 127 --symptom-fixed-rc 0 \
		--allow-absence-baseline"
	[ "$status" -eq 0 ] || {
		echo "the explicit absence claim was still refused: $output"
		return 1
	}
}

@test "#2643: an UNTRACKED cited file counts as differing from HEAD" {
	# `git diff HEAD -- <path>` reports nothing for a file git has never
	# seen, so a fix that ADDS a file looked exactly like a fix already
	# committed — and the remedy the message offered (--baseline-ref) was
	# wrong advice for it. Caught by the first live run of this feature.
	printf '#!/bin/bash\nexit 0\n' >"$WORK/scripts/new.sh"
	chmod +x "$WORK/scripts/new.sh"
	run bash -c "cd '$WORK' && '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/new.sh --retest-cmd 'bash scripts/new.sh' --retest-rc 0 \
		--symptom-cmd 'bash scripts/new.sh' --symptom-baseline-rc 127 --symptom-fixed-rc 0 \
		--allow-absence-baseline"
	[[ $output != *"no cited file differs from HEAD"* ]] || {
		echo "an untracked new file was mistaken for an already-committed fix: $output"
		return 1
	}
}

@test "#2643: an ALREADY-COMMITTED fix is refused WITH the remedy" {
	# If nothing cited differs from HEAD, the baseline would re-run the
	# FIXED code — a tautology. The message must name --baseline-ref, not
	# just report a mismatch.
	# The retest has to PASS here, or it fails first and we never reach the
	# already-committed check this test is about. scripts/thing.sh exits 1
	# at HEAD, so `true` is the retest and the symptom command is separate.
	run bash -c "cd '$WORK' && '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd true --retest-rc 0 \
		--symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -eq 2 ] || {
		echo "an unchanged tree was accepted (rc $status): $output"
		return 1
	}
	[[ $output == *tautology* ]] || {
		echo "the refusal does not name the problem: $output"
		return 1
	}
	[[ $output == *"--baseline-ref"* ]] || {
		echo "the refusal does not offer the remedy: $output"
		return 1
	}
}

# ---- the baseline mechanics ----------------------------------------------

@test "#2643: the baseline runs HEAD's code with THIS tree's tests" {
	# Without copying the new .bats in, the baseline is HEAD's tests
	# against HEAD's code — which answers a different question. What we
	# want is whether the NEW test detects the OLD bug.
	# The symptom command must EXIST at HEAD, or the baseline exits 127 and
	# the absence guard fires instead — a different test. So it is an
	# INLINE command over a tracked file, not a script the fix adds.
	printf 'marker-absent\n' >"$WORK/scripts/thing.sh"
	run bash -c "cd '$WORK' && '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh \
		--retest-cmd 'grep -q marker-absent scripts/thing.sh' --retest-rc 0 \
		--symptom-cmd 'grep -q marker-absent scripts/thing.sh' \
		--symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -eq 0 ] || {
		echo "the baseline did not observe HEAD's code: $output"
		return 1
	}
	[[ $output == *"1 without the fix, 0 with it"* ]] || {
		echo "the differential was not as expected: $output"
		return 1
	}
}

@test "#2643: an UNTRACKED .bats really reaches the baseline worktree" {
	# THE TEST THAT SHOULD HAVE EXISTED. The version of this that shipped
	# wrote a .bats file into the working tree and then never referred to
	# it — so with the copy loop entirely dead the test still passed, and
	# a real bug hid behind it: `git diff --name-only` does not list
	# untracked files, and a BRAND-NEW test file is the normal case for
	# "does the new test detect the old bug?".
	#
	# Asserting on the copy is awkward, because a file that is present in
	# both trees produces equal rcs and equal rcs are refused. So this
	# claims a deliberately WRONG baseline rc and reads the actual one out
	# of the mismatch: rc 0 means grep found the sentinel and the file was
	# copied; rc 2 is grep's "no such file" and means it was not.
	_make_fix
	printf '#!/usr/bin/env bats\n# sentinel-in-new-bats\n@test "x" { true; }\n' \
		>"$WORK/.claude/tests/brand-new.bats"
	# Untracked on purpose — committing it would test the other path.
	run bash -c "cd '$WORK' && git status --porcelain .claude/tests/brand-new.bats"
	[[ $output == '??'* ]] || {
		echo "fixture is not untracked, so this test would prove the wrong thing: $output"
		return 1
	}

	_rec "$(_base_args) --symptom-cmd 'grep -q sentinel-in-new-bats .claude/tests/brand-new.bats' \
		--symptom-baseline-rc 5 --symptom-fixed-rc 0"
	[ "$status" -ne 0 ] || {
		echo "expected a mismatch refusal (5 is deliberately wrong): $output"
		return 1
	}
	[[ $output == *"exited rc=0"* ]] || {
		echo "the untracked .bats did not reach the baseline worktree — grep could not read it there. Output: $output"
		return 1
	}
}

@test "#2643: a TRACKED-MODIFIED .bats also reaches the baseline worktree" {
	# The control for the test above: the path that always worked, so a
	# regression in the tracked half cannot hide behind the untracked fix.
	_make_fix
	printf '#!/usr/bin/env bats\n@test "x" { true; }\n' \
		>"$WORK/.claude/tests/tracked.bats"
	run bash -c "cd '$WORK' && git add .claude/tests/tracked.bats && git -c user.email=t@t -c user.name=t commit -qm tracked"
	[ "$status" -eq 0 ] || {
		echo "could not commit the control fixture: $output"
		return 1
	}
	# Now modify it in the working tree only.
	printf '#!/usr/bin/env bats\n# sentinel-tracked-mod\n@test "x" { true; }\n' \
		>"$WORK/.claude/tests/tracked.bats"

	_rec "$(_base_args) --symptom-cmd 'grep -q sentinel-tracked-mod .claude/tests/tracked.bats' \
		--symptom-baseline-rc 5 --symptom-fixed-rc 0"
	[ "$status" -ne 0 ] || {
		echo "expected a mismatch refusal (5 is deliberately wrong): $output"
		return 1
	}
	[[ $output == *"exited rc=0"* ]] || {
		echo "the working-tree version of a tracked .bats did not reach the baseline: $output"
		return 1
	}
}

@test "#2643: the baseline worktree is CLEANED UP" {
	# Worst case on failure is a leaked temp dir and an orphan
	# .git/worktrees stub. Neither should be the normal case.
	_make_fix
	_rec "$(_base_args) --symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -eq 0 ]
	local left
	left=$(git -C "$WORK" worktree list 2>/dev/null | grep -c 'prove-baseline' || true)
	[ "${left:-0}" -eq 0 ] || {
		echo "a baseline worktree is still registered:"
		git -C "$WORK" worktree list 2>&1
		return 1
	}
}

@test "#2643: the working tree is NOT modified by the baseline run" {
	# No sabotage, no stash. The fix must still be there afterwards — this
	# is the property that makes running the baseline safe at all.
	_make_fix
	local before
	before=$(cksum <"$WORK/scripts/thing.sh")
	_rec "$(_base_args) --symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -eq 0 ]
	local after
	after=$(cksum <"$WORK/scripts/thing.sh")
	[ "$before" = "$after" ] || {
		echo "the working tree changed during the baseline run (before=$before after=$after)"
		return 1
	}
}

@test "#2643: git stash is not used anywhere in the recorder" {
	# a stash would put the operator's uncommitted fix at risk and it appears
	# nowhere in this repo. A baseline built on stash would put the
	# operator's uncommitted fix at risk to prove the fix works.
	# CODE only. The file explains at length WHY stash is not used, so a
	# bare grep matches its own rationale — the first version of this test
	# failed on the comment it was written to accompany.
	run bash -c "grep -n 'git stash' '$RUN' | grep -vE '^[0-9]+:[[:space:]]*#'"
	[ "$status" -ne 0 ] || {
		echo "the recorder uses git stash in CODE: $output"
		return 1
	}
}

# ---- vocabulary ----------------------------------------------------------

@test "#2643: record-REJECTION refuses source=issue, and says why" {
	# A rejection declines a review FINDING with evidence. An issue is a
	# report, and "I decline this bug report" belongs in the tracker.
	run bash -c "cd '$WORK' && '$RUN' record-rejection --source issue --severity minor \
		--finding-id t --finding-text t --dogfood-cmd true --dogfood-output o \
		--dogfood-rc 0 --external-authority a --reason r"
	[ "$status" -eq 2 ] || {
		echo "record-rejection accepted source=issue (rc $status): $output"
		return 1
	}
	[[ $output == *"not record-rejection"* ]] || {
		echo "the refusal does not explain the asymmetry: $output"
		return 1
	}
}

@test "#2643: the audit prints an UNPROVEN-fix count" {
	# A visible number, not a block: it makes the gap legible without
	# turning every fix into a gate.
	_make_fix
	_rec "$(_base_args) --symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -eq 0 ]
	run bash -c "cd '$WORK' && '$RUN' audit"
	[[ $output == *"unproven (no symptom differential)"* ]] || {
		echo "the audit does not report the unproven count: $output"
		return 1
	}
	# The one just recorded carries a differential, so it must NOT be
	# counted — otherwise the number means nothing.
	[[ $output == *"unproven (no symptom differential): 0"* ]] || {
		echo "a fix WITH a verified differential was counted as unproven: $output"
		return 1
	}
}

@test "#2643: --baseline-ref is a working REMEDY, not just a suggestion" {
	# The refusal path was tested and the remedy it names was not — so the
	# message could have offered a flag that did not work, which is worse
	# than no advice. An already-committed fix names the commit BEFORE it.
	printf '#!/bin/bash\nexit 0\n' >"$WORK/scripts/thing.sh"
	git -C "$WORK" add -A >/dev/null 2>&1
	git -C "$WORK" commit -qm "the fix, now committed" >/dev/null 2>&1
	local before
	before=$(git -C "$WORK" rev-parse HEAD~1)
	run bash -c "cd '$WORK' && '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0 \
		--symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0 \
		--baseline-ref $before"
	[ "$status" -eq 0 ] || {
		echo "--baseline-ref did not work as the refusal advertises: $output"
		return 1
	}
	[[ $output == *"1 without the fix, 0 with it"* ]] || {
		echo "the differential against the named ref was not confirmed: $output"
		return 1
	}
}

@test "#2643: a BAD --baseline-ref refuses rather than skipping the baseline" {
	# One-sided evidence is not evidence. If the worktree cannot be built,
	# the record must be refused — never written with the fixed half alone.
	_make_fix
	run bash -c "cd '$WORK' && '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0 \
		--symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0 \
		--baseline-ref deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
	[ "$status" -ne 0 ] || {
		echo "an unusable baseline ref was accepted: $output"
		return 1
	}
	[[ $output == *"one-sided evidence"* ]] || {
		echo "the refusal does not explain what it protects: $output"
		return 1
	}
}

@test "#2643: partial symptom flags are refused" {
	# Rcs without a command describe a claim with nothing to run — the
	# free-text shape this whole feature replaces.
	_make_fix
	_rec "$(_base_args) --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -eq 2 ] || {
		echo "rcs without a command returned $status, expected 2: $output"
		return 1
	}
	[[ $output == *"without --symptom-cmd"* ]] || {
		echo "the refusal does not name what is missing: $output"
		return 1
	}
}

@test "#2643: a NON-NUMERIC symptom rc is refused" {
	# The same validation the retest rc gets. Without it the equality check
	# is a string compare that silently accepts nonsense.
	_make_fix
	_rec "$(_base_args) --symptom-cmd true --symptom-baseline-rc one --symptom-fixed-rc 0"
	[ "$status" -eq 2 ] || {
		echo "a non-numeric baseline rc returned $status, expected 2: $output"
		return 1
	}
	[[ $output == *"non-negative integer"* ]] || {
		echo "the refusal does not name the constraint: $output"
		return 1
	}
}

@test "#2643: a failed .bats copy REFUSES rather than running without the test" {
	# The high-severity one. `cp ... || true` let the baseline run WITHOUT
	# the new test that is supposed to detect the bug — and the
	# differential would then "prove" the fix using a suite that never saw
	# it. Forced by making the source file unreadable.
	# NOT chmod 000: root ignores it, so the negative test was vacuous for
	# anyone running as root and had to be skipped there — a skip that
	# reports success. Replacing the source with a DIRECTORY makes the
	# plain `cp` fail for every user, root included, so the refusal is
	# actually exercised everywhere.
	#
	# Commit the TEST first, then make the fix — otherwise committing both
	# leaves nothing differing from HEAD and the tautology check fires
	# before the copy is ever attempted.
	mkdir -p "$WORK/.claude/tests/deep"
	printf '#!/usr/bin/env bats\n@test "x" { true; }\n' >"$WORK/.claude/tests/deep/new.bats"
	git -C "$WORK" add .claude >/dev/null 2>&1
	git -C "$WORK" commit -qm "add a test" >/dev/null 2>&1
	_make_fix
	# Now change the test so it is a CHANGED .bats the baseline must copy,
	# and make that copy fail.
	printf '#!/usr/bin/env bats\n@test "y" { true; }\n' >"$WORK/.claude/tests/deep/new.bats"
	rm -f "$WORK/.claude/tests/deep/new.bats"
	mkdir -p "$WORK/.claude/tests/deep/new.bats"
	run bash -c "cd '$WORK' && '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0 \
		--symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	rm -rf "$WORK/.claude/tests/deep/new.bats"
	[ "$status" -ne 0 ] || {
		echo "an unreadable test file was silently skipped: $output"
		return 1
	}
	[[ $output == *"WITHOUT the test"* ]] || {
		echo "the refusal does not explain the consequence: $output"
		return 1
	}
}

@test "#2643: a changed .bats that is DELETED in this tree is skipped, not refused" {
	# The other side of the not-a-regular-file rule. A path git lists that
	# no longer exists was deleted here — there is nothing to copy and
	# nothing is lost, so it must not refuse. Without this the rule above
	# would break every branch that removes a test file.
	mkdir -p "$WORK/.claude/tests/deep"
	printf '#!/usr/bin/env bats\n@test "x" { true; }\n' >"$WORK/.claude/tests/deep/gone.bats"
	git -C "$WORK" add .claude >/dev/null 2>&1
	git -C "$WORK" commit -qm "add a test" >/dev/null 2>&1
	_make_fix
	rm -f "$WORK/.claude/tests/deep/gone.bats"
	run bash -c "cd '$WORK' && '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0 \
		--symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -eq 0 ] || {
		echo "deleting a test file broke the baseline copy: $output"
		return 1
	}
}

@test "#2643: a symptom MISMATCH shows what the command actually printed" {
	# The retest path prints a `last output:` tail on a mismatch and this
	# one printed nothing — so the operator learned the rc was wrong with
	# no way to see why, on the half that is hardest to reason about.
	_make_fix
	_rec "$(_base_args) --symptom-cmd 'echo the-actual-output; exit 4' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -ne 0 ]
	[[ $output == *"last output:"* ]] || {
		echo "the mismatch showed no output tail: $output"
		return 1
	}
	[[ $output == *the-actual-output* ]] || {
		echo "the tail does not carry what the command printed: $output"
		return 1
	}
}

@test "#2643: --symptom-fixed-rc gets the same validation as its sibling" {
	# Only the baseline rc had a test. An identical branch with no coverage
	# is a coin-flip on whether it works.
	_make_fix
	_rec "$(_base_args) --symptom-cmd true --symptom-baseline-rc 0 --symptom-fixed-rc zero"
	[ "$status" -eq 2 ] || {
		echo "a non-numeric fixed rc returned $status, expected 2: $output"
		return 1
	}
	[[ $output == *"non-negative integer"* ]] || {
		echo "the refusal does not name the constraint: $output"
		return 1
	}
}

@test "#2643: a bad PROVE_BASELINE_TIMEOUT warns and falls back" {
	# The fallback exists so a typo'd timeout cannot silently mean "no
	# deadline". Untested, it is a guess.
	_make_fix
	run bash -c "cd '$WORK' && PROVE_BASELINE_TIMEOUT=notanumber '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0 \
		--symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -eq 0 ] || {
		echo "a bad timeout broke the run instead of falling back: $output"
		return 1
	}
	[[ $output == *"PROVE_BASELINE_TIMEOUT"* ]] || {
		echo "the fallback was silent: $output"
		return 1
	}
}

@test "#2643: record-rejection's own docs do not advertise source=issue" {
	# The usage block and the error text both listed `issue` as valid while
	# the code refused it at runtime. Advertising a value that cannot work
	# is worse than omitting it, because the operator trusts the help.
	#
	# `record-rejection` with NO ARGS was the original probe here, and it
	# never reached print_help at all — it stopped at "--source is REQUIRED"
	# and the assertion passed on a string that could not have contained the
	# advertisement either way. Editing print_help back to the wrong text
	# left it green. `--help` is the route that actually renders the block.
	run bash -c "'$RUN' record-rejection --help 2>&1"
	[ "$status" -eq 0 ] || {
		echo "record-rejection --help did not render usage (status $status): $output"
		return 1
	}
	# Guard against the probe silently ceasing to reach the usage block
	# again: if this anchor is gone, the assertion below proves nothing.
	[[ $output == *"run.sh record-rejection"* ]] || {
		echo "output is not the usage block, so the check below would be vacuous: $output"
		return 1
	}
	# Scope to the REJECTION section. record-fix legitimately advertises
	# `issue`, so asserting over the whole help would fail on correct text —
	# the two subcommands genuinely have different vocabularies, which is
	# the entire point of the fix under test.
	local rej_block
	rej_block=$(printf '%s\n' "$output" | awk '/run\.sh record-rejection/{f=1} /run\.sh record-fix/{f=0} f')
	[ -n "$rej_block" ] || {
		echo "could not isolate the record-rejection block; the check below would be vacuous: $output"
		return 1
	}
	# Match the VOCABULARY, not the word. The block is allowed — encouraged —
	# to mention `issue` in prose explaining that it is NOT valid here; what
	# it must never do is list it as a selectable value.
	[[ $rej_block != *"|issue}"* ]] || {
		echo "the rejection usage block still lists issue as a valid --source: $rej_block"
		return 1
	}
	# And the prose that replaced it is still there, so a future edit that
	# drops the vocabulary AND the explanation does not pass silently.
	[[ $rej_block == *"NOT issue"* ]] || {
		echo "the rejection block no longer explains that issue is invalid here: $rej_block"
		return 1
	}
	# And the error text, which was the other half of the same drift.
	run bash -c "'$RUN' record-rejection --finding-id x --finding-text t --source issue 2>&1 || true"
	[[ $output != *"phase0.5|phase1|cr|issue"* ]] || {
		echo "the rejection error text still advertises source=issue: $output"
		return 1
	}
}

@test "#2643: the unproven counter COUNTS UP, not just down to zero" {
	# It was only ever asserted at 0 — the all-verified case. A counter
	# that never increments in any test is a counter nobody has seen work,
	# and it is the whole visible-number half of this feature.
	_make_fix
	# One WITH a differential.
	_rec "$(_base_args) --symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -eq 0 ]
	# One WITHOUT — an ordinary non-critical fix, which is allowed.
	run bash -c "cd '$WORK' && '$RUN' record-fix --source phase1 --confidence 5 \
		--finding-id plain --finding-text t --fix-summary t \
		--cited-files README.md --retest-cmd true --retest-rc 0"
	[ "$status" -eq 0 ] || {
		echo "the plain fix was refused: $output"
		return 1
	}
	run bash -c "cd '$WORK' && '$RUN' audit"
	[[ $output == *"unproven (no symptom differential): 1"* ]] || {
		echo "the counter did not count the unproven fix: $output"
		return 1
	}
	[[ $output == *"Fixes recorded:      2"* ]] || {
		echo "both fixes were not recorded: $output"
		return 1
	}
}

@test "#2643: optional symptom evidence is VERIFIED when volunteered" {
	# Optional does not mean unchecked. A non-required source that supplies
	# the flags must still have them re-executed — otherwise "optional"
	# quietly means "free text", which is the thing this replaces.
	_make_fix
	run bash -c "cd '$WORK' && '$RUN' record-fix --source phase1 --confidence 5 \
		--finding-id vol --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd true --retest-rc 0 \
		--symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 9 --symptom-fixed-rc 0"
	[ "$status" -ne 0 ] || {
		echo "a volunteered but WRONG differential was accepted unchecked: $output"
		return 1
	}
	[[ $output == *"SYMPTOM MISMATCH"* ]] || {
		echo "the volunteered evidence was not re-executed: $output"
		return 1
	}
}

@test "#2643: --baseline-ref HEAD gets the tautology check too" {
	# VERIFIED BYPASS (phase 1, conf 10). The guard ran only when
	# --baseline-ref was EMPTY — but the value it defaults to IS HEAD, so
	# spelling it out produced the identical baseline while skipping the
	# check. A record with no fix at all was accepted on a clean tree.
	# What matters is the commit the ref resolves to, not whether the
	# operator typed it.
	_make_fix
	# Commit the fix so nothing differs from HEAD: that is the tautology.
	run bash -c "cd '$WORK' && git add -A && git -c user.email=t@t -c user.name=t commit -qm fix"
	[ "$status" -eq 0 ]

	run bash -c "cd '$WORK' && '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0 \
		--baseline-ref HEAD \
		--symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -ne 0 ] || {
		echo "an explicit --baseline-ref HEAD walked around the tautology guard: $output"
		return 1
	}
	[[ $output == *"tautology"* ]] || {
		echo "refused, but not for the tautology reason: $output"
		return 1
	}
}

@test "#2643: our own deadline kill is not the symptom (FIXED half)" {
	# VERIFIED BYPASS (phase 1, conf 10). Claiming rc 124 and supplying a
	# command that hangs let the wrapper's own SIGTERM play the part of the
	# evidence — the laundering #2562 closed on the retest side, reopened in
	# a new field. Here the FIXED half hangs, so its guard is the one that
	# must fire.
	_make_fix
	run bash -c "cd '$WORK' && PROVE_BASELINE_TIMEOUT=2 '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0 \
		--symptom-cmd 'test -f never-exists-marker || sleep 30' \
		--symptom-baseline-rc 1 --symptom-fixed-rc 124"
	[ "$status" -ne 0 ] || {
		echo "a deadline kill was accepted as evidence: $output"
		return 1
	}
	[[ $output == *"fixed-tree symptom run hit the deadline"* ]] || {
		echo "refused, but not by the fixed-half deadline guard: $output"
		return 1
	}
}

@test "#2643: our own deadline kill is not the symptom (BASELINE half)" {
	# The baseline guard is SEPARATE code from the fixed-half one above, and
	# the first version of this test never reached it: both trees hung, so
	# the fixed half refused first and the baseline guard could be deleted
	# outright with every test still green. Mutation-checked.
	#
	# The command must therefore be FAST in the fixed tree and HANG in the
	# baseline. A marker file the "fix" adds does exactly that: present now,
	# absent at HEAD.
	_make_fix
	printf 'x\n' >"$WORK/marker"
	run bash -c "cd '$WORK' && PROVE_BASELINE_TIMEOUT=2 '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0 \
		--symptom-cmd 'test -f marker || sleep 30' \
		--symptom-baseline-rc 124 --symptom-fixed-rc 0"
	[ "$status" -ne 0 ] || {
		echo "a baseline deadline kill was accepted as evidence: $output"
		return 1
	}
	[[ $output == *"baseline hit the PROVE_BASELINE_TIMEOUT deadline"* ]] || {
		echo "refused, but not by the baseline deadline guard: $output"
		return 1
	}
}

@test "#2643: the audit counter does not trust a self-declared flag" {
	# VERIFIED BYPASS (phase 1, conf 10). `unproven` was computed from the
	# boolean `symptom_verified` alone, so a hand-written record carrying
	# `"symptom_verified": true` and no symptom fields read as proven and
	# drove the count to 0. A self-declared flag is precisely the free text
	# this feature replaces.
	_make_fix
	local sd="$WORK/.claude/.session-state/prove-yourself"
	mkdir -p "$sd"
	# WELL-FORMED on every other axis, so the only thing under test is the
	# forged flag. An incomplete record would be caught by the schema check
	# instead and prove nothing about the counter.
	cat >"$sd/forged-abc123.json" <<'JSON'
{"finding_id":"forged","kind":"fix","finding_text":"t","ts":"2026-01-01T00:00:00Z",
 "covers_count":1,"cited_files":[],
 "decision_data":{"fix_summary":"t","retest_cmd":"true","retest_rc":0,
                  "retest_verified":true,"retest_actual_rc":0,
                  "symptom_verified":true}}
JSON
	run bash -c "cd '$WORK' && '$RUN' audit"
	[ "$status" -eq 0 ] || {
		echo "audit failed: $output"
		return 1
	}
	[[ $output == *"unproven (no symptom differential): 1"* ]] || {
		echo "a forged symptom_verified flag counted as proven: $output"
		return 1
	}
}

@test "#2643: the rejection --source ERROR text does not advertise issue either" {
	# The same defect existed TWICE in cmd_record_rejection and the earlier
	# fix caught only the second copy. The test that shipped with it ran
	# record-rejection with no args, which stops at "--source is REQUIRED"
	# and reaches neither line — so the miss survived its own regression
	# test. This drives the path that actually prints it: a source that is
	# present but invalid, with the other required fields supplied.
	run bash -c "'$RUN' record-rejection --source bogus \
		--finding-id x --finding-text t --dogfood-cmd t --dogfood-output t \
		--dogfood-rc 0 --external-authority t --reason t 2>&1 || true"
	[[ $output == *"--source must be"* ]] || {
		echo "did not reach the invalid-source error at all, so this test would be vacuous: $output"
		return 1
	}
	[[ $output != *"|issue"* ]] || {
		echo "the rejection error text still advertises issue as valid: $output"
		return 1
	}
}

@test "#2643: an all-zero timeout is refused, not silently unbounded" {
	# `timeout 00` means NO DEADLINE to GNU timeout, and the old validation
	# only rejected a single `0`. A two-character typo therefore removed the
	# one backstop on a hanging baseline — precisely where the rc-124 guard
	# needs a real deadline to compare against.
	_make_fix
	run bash -c "cd '$WORK' && PROVE_BASELINE_TIMEOUT=00 '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0 \
		--symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -eq 0 ] || {
		echo "the fallback should let the record proceed, not break it: $output"
		return 1
	}
	[[ $output == *"NO DEADLINE"* ]] || {
		echo "an all-zero timeout was accepted silently: $output"
		return 1
	}
}

@test "#2643: a bad timeout names the variable it actually came from" {
	# The WARN read whichever variable won and then blamed
	# PROVE_BASELINE_TIMEOUT regardless, sending the operator to check a
	# variable they had never set.
	_make_fix
	run bash -c "cd '$WORK' && PROVE_RETEST_TIMEOUT=notanumber '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0 \
		--symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[[ $output == *"PROVE_RETEST_TIMEOUT='notanumber'"* ]] || {
		echo "the WARN blames the wrong variable: $output"
		return 1
	}
}

@test "#2643: citing NOTHING is diagnosed as citing nothing" {
	# With no --cited-files the tautology refusal fired vacuously ("no cited
	# file differs") and offered --baseline-ref, which is the remedy for a
	# different problem entirely.
	_make_fix
	run bash -c "cd '$WORK' && '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--retest-cmd 'bash scripts/thing.sh' --retest-rc 0 \
		--symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -ne 0 ] || {
		echo "a record with no citations was accepted: $output"
		return 1
	}
	[[ $output == *"no --cited-files were given"* ]] || {
		echo "the refusal misdiagnoses the missing citation: $output"
		return 1
	}
}

@test "#2643: the unproven counter counts FIXES, not rejections" {
	# Mutation-verified gap: deleting the `kind == fix` filter left all 54
	# tests green, because every audit test used a fix-only state dir. A
	# rejection is not an unproven fix.
	_make_fix
	_rec "$(_base_args) --symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -eq 0 ]
	local sd="$WORK/.claude/.session-state/prove-yourself"
	cat >"$sd/rej-zzz999.json" <<'JSON'
{"finding_id":"rej","kind":"rejection","finding_text":"t","ts":"2026-01-01T00:00:00Z",
 "covers_count":1,"cited_files":[],
 "decision_data":{"reason":"t","dogfood_cmd":"true","dogfood_output":"o","dogfood_rc":0,
                  "external_authority":"a"}}
JSON
	run bash -c "cd '$WORK' && '$RUN' audit"
	[[ $output == *"unproven (no symptom differential): 0"* ]] || {
		echo "a rejection was counted as an unproven fix: $output"
		return 1
	}
	[[ $output == *"Rejections recorded: 1"* ]] || {
		echo "the rejection fixture was not picked up at all, so this test is vacuous: $output"
		return 1
	}
}
# ---- #2643 source/stage reconciliation ------------------------------------
# The guard for the failure that cost three review rounds' worth of
# bookkeeping: phase0.5 findings recorded as --source issue, counted by
# nothing, and uncorrectable because covered_sha was stamped from HEAD.

@test "#2643: recording a phase0.5 sha under the WRONG source is refused" {
	# THE ONE THAT WOULD HAVE CAUGHT IT. The vocabulary check passes
	# `issue` happily; only comparing it against the stage log for this sha
	# reveals that the record would be written and then never counted.
	_make_fix
	mkdir -p "$WORK/.claude/logs"
	local sha
	sha=$(git -C "$WORK" rev-parse HEAD)
	# REAL schema: the terminal aggregate {agent:"<all>", status:"emitted"}
	# is the authority (_lib/phase05-dedupe.sh). An earlier version of this
	# fixture invented {sha, findings} and so pinned a reader that was dead
	# against every real log in the repo.
	printf '{"sha":"%s","agent":"<all>","findings":12,"status":"emitted"}\n' \
		"$sha" >"$WORK/.claude/logs/phase0.5-run.jsonl"

	run bash -c "cd '$WORK' && '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0 \
		--symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -ne 0 ] || {
		echo "a phase0.5 sha was recorded as --source issue, the exact mislabel: $output"
		return 1
	}
	[[ $output == *"SOURCE/STAGE MISMATCH"* ]] || {
		echo "refused, but not for the mislabel: $output"
		return 1
	}
	[[ $output == *phase0.5* ]] || {
		echo "the refusal does not name the source that WOULD count: $output"
		return 1
	}
}

@test "#2643: the MATCHING source is accepted at the same sha" {
	# The control. A guard that refused everything would be useless, and
	# would be turned off within a day.
	_make_fix
	mkdir -p "$WORK/.claude/logs"
	local sha
	sha=$(git -C "$WORK" rev-parse HEAD)
	# REAL schema: the terminal aggregate {agent:"<all>", status:"emitted"}
	# is the authority (_lib/phase05-dedupe.sh). An earlier version of this
	# fixture invented {sha, findings} and so pinned a reader that was dead
	# against every real log in the repo.
	printf '{"sha":"%s","agent":"<all>","findings":12,"status":"emitted"}\n' \
		"$sha" >"$WORK/.claude/logs/phase0.5-run.jsonl"

	run bash -c "cd '$WORK' && '$RUN' record-fix --source phase0.5 --confidence 8 \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0"
	[ "$status" -eq 0 ] || {
		echo "the correct source was refused: $output"
		return 1
	}
}

@test "#2643: a sha with no findings logged does not trip the guard" {
	# Ordinary recording must stay unaffected, or the guard becomes noise.
	_make_fix
	run bash -c "cd '$WORK' && '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0 \
		--symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -eq 0 ] || {
		echo "a clean sha was blocked by the reconciliation guard: $output"
		return 1
	}
}

@test "#2643: --covered-sha re-files evidence onto an ancestor commit" {
	# The recovery path, and the reason a bypass was not needed. Without
	# this, a mislabeled record is permanent: covered_sha is stamped from
	# HEAD, so the only exits are a skip or re-running the review.
	_make_fix
	local old_sha
	old_sha=$(git -C "$WORK" rev-parse HEAD)
	run bash -c "cd '$WORK' && git add -A && git -c user.email=t@t -c user.name=t commit -qm second"
	[ "$status" -eq 0 ]

	printf 'more\n' >>"$WORK/scripts/thing.sh"
	run bash -c "cd '$WORK' && '$RUN' record-fix --source phase1 --confidence 7 \
		--covered-sha '$old_sha' \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd true --retest-rc 0"
	[ "$status" -eq 0 ] || {
		echo "re-filing onto an ancestor was refused: $output"
		return 1
	}
	[[ $output == *"covered-sha"* ]] || {
		echo "the run does not say it covered a different sha: $output"
		return 1
	}
	local logged
	logged=$(jq -rs --arg s "$old_sha" '[ .[] | select(.covered_sha == $s) ] | length' \
		"$WORK/.claude/audit/prove-yourself.jsonl" 2>/dev/null)
	[ "${logged:-0}" -ge 1 ] || {
		echo "the ledger row was not filed against the named sha"
		return 1
	}
}

@test "#2643: --covered-sha REFUSES a sha that is not an ancestor" {
	# Otherwise the recovery flag becomes a coverage-fabrication flag:
	# attach evidence to any commit anywhere.
	_make_fix
	run bash -c "cd '$WORK' && '$RUN' record-fix --source phase1 --confidence 7 \
		--covered-sha deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd true --retest-rc 0"
	[ "$status" -ne 0 ] || {
		echo "an unresolvable sha was accepted: $output"
		return 1
	}
	[[ $output == *"does not resolve to a commit"* ]] || {
		echo "refused, but not for the reason claimed: $output"
		return 1
	}
}
# ---- #2643 phase-1 round 1: gaps the mutation testing found -------------

@test "#2643: --covered-sha refuses a REAL commit that is not an ancestor" {
	# MUTATION-VERIFIED GAP. The existing test passed `deadbeef...`, which
	# fails `rev-parse` first and never reaches the ancestor check — so
	# deleting the `merge-base --is-ancestor` guard entirely left the suite
	# green. That guard is the whole anti-fabrication property of the flag:
	# without it, evidence can be attached to any commit anywhere. It needs
	# a sha that RESOLVES but is not an ancestor.
	_make_fix
	run bash -c "cd '$WORK' && git add -A && git -c user.email=t@t -c user.name=t commit -qm main-line"
	[ "$status" -eq 0 ]
	# A commit on a side branch: real, resolvable, NOT an ancestor of HEAD.
	local side
	side=$(cd "$WORK" && git rev-parse HEAD)
	run bash -c "cd '$WORK' && git checkout -q -b sidebranch '$side' && printf 'side\n' > scripts/side.sh && git add -A && git -c user.email=t@t -c user.name=t commit -qm side && git rev-parse HEAD"
	[ "$status" -eq 0 ]
	local side_sha="${lines[${#lines[@]} - 1]}"
	run bash -c "cd '$WORK' && git checkout -q - 2>/dev/null || git checkout -q master 2>/dev/null || git checkout -q main"
	# Sanity: the fixture really does have a non-ancestor commit, or this
	# test would prove nothing.
	run bash -c "cd '$WORK' && git merge-base --is-ancestor '$side_sha' HEAD"
	[ "$status" -ne 0 ] || {
		echo "fixture setup failed: $side_sha IS an ancestor, so the refusal below would be untested"
		return 1
	}

	printf 'more\n' >>"$WORK/scripts/thing.sh"
	run bash -c "cd '$WORK' && '$RUN' record-fix --source phase1 --confidence 7 \
		--covered-sha '$side_sha' \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd true --retest-rc 0"
	[ "$status" -ne 0 ] || {
		echo "evidence was filed against a commit that is NOT on this branch: $output"
		return 1
	}
	[[ $output == *"not an ancestor"* ]] || {
		echo "refused, but not by the ancestor guard: $output"
		return 1
	}
}

@test "#2643: a phase source with NO cycle state is refused where the machine runs" {
	# MUTATION-VERIFIED GAP: replacing this branch with `elif false` left
	# every test green. It is the half of the reconciliation that catches a
	# phase run BY HAND around the state machine — the actual shape of the
	# failure this feature exists for — and nothing exercised it.
	_make_fix
	# The machine is in use in this repo, but never drove THIS sha.
	mkdir -p "$WORK/.claude/.session-state/ship-cycle"
	printf '{}\n' >"$WORK/.claude/.session-state/ship-cycle/some-other-sha.json"

	run bash -c "cd '$WORK' && '$RUN' record-fix --source phase1 --confidence 7 \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd true --retest-rc 0"
	[ "$status" -ne 0 ] || {
		echo "a hand-run phase record was accepted with no cycle state: $output"
		return 1
	}
	[[ $output == *"never run on"* ]] || {
		echo "refused, but not by the cycle-state check: $output"
		return 1
	}
}

@test "#2643: the same record is ACCEPTED once the machine has driven the sha" {
	# The control for the test above. Without it, the check could refuse
	# unconditionally and still look correct.
	_make_fix
	local sha
	sha=$(git -C "$WORK" rev-parse HEAD)
	mkdir -p "$WORK/.claude/.session-state/ship-cycle"
	printf '{}\n' >"$WORK/.claude/.session-state/ship-cycle/$sha.json"

	run bash -c "cd '$WORK' && '$RUN' record-fix --source phase1 --confidence 7 \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd true --retest-rc 0"
	[ "$status" -eq 0 ] || {
		echo "a properly-driven sha was still refused: $output"
		return 1
	}
}

@test "#2643: PROVE_SOURCE_CHECK_SKIP actually lets a record through" {
	# An escape hatch named in a blocking error but never exercised is how
	# operators end up deadlocked with no verified way out. Both new
	# refusals advertise this one.
	_make_fix
	mkdir -p "$WORK/.claude/.session-state/ship-cycle"
	printf '{}\n' >"$WORK/.claude/.session-state/ship-cycle/other.json"

	run bash -c "cd '$WORK' && PROVE_SOURCE_CHECK_SKIP=1 '$RUN' record-fix --source phase1 --confidence 7 \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd true --retest-rc 0"
	[ "$status" -eq 0 ] || {
		echo "the advertised escape hatch does not work: $output"
		return 1
	}
	[[ $output == *"PROVE_SOURCE_CHECK_SKIP=1"* ]] || {
		echo "the bypass was silent: $output"
		return 1
	}
	# And it must leave an audit row, because both messages call it
	# "audit-logged" — a claim that was false in the first version.
	[ -s "$WORK/.claude/logs/prove-source-check-skip.jsonl" ] || {
		echo "the bypass claims to be audit-logged but wrote no row"
		return 1
	}
}

@test "#2643: the symptom timeout WARN is distinct from the retest one" {
	# MUTATION-VERIFIED VACUOUS: the two warnings were byte-identical, so
	# the test asserting the variable name was satisfied by the retest
	# path's warning and stayed green when the symptom path hardcoded the
	# wrong variable.
	_make_fix
	# PROVE_BASELINE_TIMEOUT must be UNSET, or the symptom path uses it and
	# never reaches the PROVE_RETEST_TIMEOUT fallback this test is about.
	# setup() exports a valid one, so drop it explicitly.
	run bash -c "cd '$WORK' && env -u PROVE_BASELINE_TIMEOUT PROVE_RETEST_TIMEOUT=notanumber '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0 \
		--symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[[ $output == *"symptom timeout: PROVE_RETEST_TIMEOUT='notanumber'"* ]] || {
		echo "the SYMPTOM warning does not name the variable the value came from: $output"
		return 1
	}
}

@test "#2643: a baseline MISMATCH shows what the baseline actually printed" {
	# MUTATION-VERIFIED GAP: reverting the baseline capture to /dev/null
	# left the suite green, because the only tail-content test exercises the
	# FIXED half. The baseline half is the one an operator can least easily
	# reason about, which is why it captures output at all.
	_make_fix
	_rec "$(_base_args) --symptom-cmd 'echo baseline-said-this; bash scripts/thing.sh' \
		--symptom-baseline-rc 9 --symptom-fixed-rc 0"
	[ "$status" -ne 0 ] || {
		echo "expected a baseline mismatch (9 is wrong): $output"
		return 1
	}
	[[ $output == *"SYMPTOM MISMATCH (baseline"* ]] || {
		echo "did not reach the baseline mismatch: $output"
		return 1
	}
	[[ $output == *baseline-said-this* ]] || {
		echo "the baseline tail does not carry what the command printed: $output"
		return 1
	}
}

@test "#2643: a child's own FAST rc-124 is still valid symptom evidence" {
	# The accept side of the deadline guard. MUTATION-VERIFIED GAP:
	# collapsing both guards to a blanket `rc == 124 -> refuse` left every
	# test green, so the elapsed-time discrimination — the only thing
	# separating a laundered kill from a legitimate inner timeout — was
	# unpinned. The retest path has this test; the symptom path did not.
	_make_fix
	# Exits 124 immediately, nowhere near the 60s deadline.
	run bash -c "cd '$WORK' && '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0 \
		--symptom-cmd 'if [ -f scripts/thing.sh ] && grep -q \"exit 0\" scripts/thing.sh; then exit 0; else exit 124; fi' \
		--symptom-baseline-rc 124 --symptom-fixed-rc 0"
	[ "$status" -eq 0 ] || {
		echo "a fast, genuine rc-124 was rejected as a deadline kill: $output"
		return 1
	}
	[[ $output == *"differential CONFIRMED"* ]] || {
		echo "the differential was not confirmed: $output"
		return 1
	}
}
@test "#2643: record-rejection gets --covered-sha too, ancestor-validated" {
	# code-reviewer r1: cmd_record_rejection writes through the SAME ledger
	# writer, stamps the same covered_sha and is summed by the same gates —
	# so a mislabeled rejection was exactly as uncounted, and exactly as
	# uncorrectable, as the mislabeled fix this PR exists to fix. The flag
	# was added to record-fix only.
	_make_fix
	local old_sha
	old_sha=$(git -C "$WORK" rev-parse HEAD)
	run bash -c "cd '$WORK' && git add -A && git -c user.email=t@t -c user.name=t commit -qm second"
	[ "$status" -eq 0 ]

	run bash -c "cd '$WORK' && '$RUN' record-rejection --source phase1 --confidence 3 \
		--covered-sha '$old_sha' \
		--finding-id r --finding-text t --dogfood-cmd 'bash scripts/thing.sh' \
		--dogfood-output 'o' --dogfood-rc 0 \
		--external-authority 'https://example.invalid/spec#section' --reason 'r'"
	[ "$status" -eq 0 ] || {
		echo "a rejection could not be re-filed onto an ancestor: $output"
		return 1
	}
	local logged
	logged=$(jq -rs --arg s "$old_sha" '[ .[] | select(.covered_sha == $s and .kind == "rejection") ] | length' \
		"$WORK/.claude/audit/prove-yourself.jsonl" 2>/dev/null)
	[ "${logged:-0}" -ge 1 ] || {
		echo "the rejection row was not filed against the named sha"
		return 1
	}
}

@test "#2643: record-rejection --covered-sha refuses a non-ancestor" {
	# The anti-fabrication half, on the rejection side.
	_make_fix
	run bash -c "cd '$WORK' && git add -A && git -c user.email=t@t -c user.name=t commit -qm base && git rev-parse HEAD"
	[ "$status" -eq 0 ]
	local base="${lines[${#lines[@]} - 1]}"
	run bash -c "cd '$WORK' && git checkout -q -b side '$base' && printf 'x\n' > scripts/side.sh && git add -A && git -c user.email=t@t -c user.name=t commit -qm side && git rev-parse HEAD"
	[ "$status" -eq 0 ]
	local side_sha="${lines[${#lines[@]} - 1]}"
	run bash -c "cd '$WORK' && git checkout -q '$base'"
	run bash -c "cd '$WORK' && git merge-base --is-ancestor '$side_sha' HEAD"
	[ "$status" -ne 0 ] || {
		echo "fixture setup failed: the side sha IS an ancestor, so the refusal below is untested"
		return 1
	}

	run bash -c "cd '$WORK' && '$RUN' record-rejection --source phase1 --confidence 3 \
		--covered-sha '$side_sha' \
		--finding-id r --finding-text t --dogfood-cmd 'true' \
		--dogfood-output 'o' --dogfood-rc 0 \
		--external-authority 'https://example.invalid/spec#section' --reason 'r'"
	[ "$status" -ne 0 ] || {
		echo "a rejection was filed against a commit not on this branch: $output"
		return 1
	}
	[[ $output == *"not an ancestor"* ]] || {
		echo "refused, but not by the ancestor guard: $output"
		return 1
	}
}

@test "#2643: the symptom path WARNS when it runs with no deadline" {
	# pr-test-analyzer r1: the no-timeout branch and its UNBOUNDED warning
	# had no test, though the analogous retest branch does. An unbounded
	# run that says nothing is indistinguishable from a bounded one.
	_make_fix
	run bash -c "cd '$WORK' && PROVE_RETEST_NO_TIMEOUT=1 '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0 \
		--symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	[ "$status" -eq 0 ] || {
		echo "disabling the deadline broke the record: $output"
		return 1
	}
	[[ $output == *"UNBOUNDED"* ]] || {
		echo "the symptom run went unbounded silently: $output"
		return 1
	}
}

@test "#2643: a MISSING timeout binary refuses the record outright" {
	# CR p2r2/p2r3: a missing binary is not an operator decision. The
	# retest path already refused it while both symptom halves merely
	# warned — so a machine without coreutils quietly lost the deadline
	# that the rc-124 laundering guard compares elapsed time against.
	_make_fix
	# A PATH with no `timeout`, built HERE and passed via env. Building it
	# inside a `bash -c` string is how an earlier attempt in this branch
	# turned the stub dir into the ENTIRE path and lost `uname`.
	local stub="$WORK/nostub"
	mkdir -p "$stub"
	local p="$stub:/usr/bin:/bin:/usr/sbin:/sbin"

	run env PATH="$p" bash -c "cd '$WORK' && '$RUN' record-fix --source issue \
		--finding-id t --finding-text t --fix-summary t \
		--cited-files scripts/thing.sh --retest-cmd 'bash scripts/thing.sh' --retest-rc 0 \
		--symptom-cmd 'bash scripts/thing.sh' --symptom-baseline-rc 1 --symptom-fixed-rc 0"
	# Guard the guard: if `timeout` is still reachable the refusal below
	# would never fire and this test would pass having proved nothing.
	if env PATH="$p" command -v timeout >/dev/null 2>&1; then
		skip "pending #2643 — timeout resolves outside the stubbed PATH on this machine (e.g. /usr/bin), so the negative case cannot be produced here"
	fi
	[ "$status" -ne 0 ] || {
		echo "a missing timeout binary ran the evidence unbounded: $output"
		return 1
	}
	# The RETEST gate catches it first — it runs before the symptom block
	# and already refused a missing binary (#2562). That is the reachable
	# guarantee, and it is what this asserts. The matching refusals now in
	# both symptom halves are defence in depth for a caller that reaches
	# them directly; asserting on their wording here would have been
	# vacuous, since the retest message is what actually appears.
	[[ $output == *"no timeout binary on PATH"* ]] || {
		echo "refused, but not for the missing binary: $output"
		return 1
	}
	[[ $output != *"differential CONFIRMED"* ]] || {
		echo "evidence was confirmed despite there being no enforceable deadline: $output"
		return 1
	}
}
