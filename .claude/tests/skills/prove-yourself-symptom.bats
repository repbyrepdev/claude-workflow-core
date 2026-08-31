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
	# A .bats file that exists only in the working tree; the baseline must
	# copy it in, which is what lets a NEW test detect the OLD bug.
	printf '#!/usr/bin/env bats\n@test "x" { true; }\n' >"$WORK/.claude/tests/new.bats"
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
	# scripts/release.sh documents the preference against it and it appears
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
