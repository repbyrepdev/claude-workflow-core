#!/usr/bin/env bats
# covers: skills/prove-yourself-audit/run.sh
# shellcheck disable=SC2030,SC2031  # each bats test runs in its own subshell — env exports (PROVE_RETEST_TIMEOUT) are deliberately per-test
#
# #2562: record-fix re-executes its retest evidence. These tests pin the
# three mechanical guarantees: (1) the recorded command is RUN and its
# actual rc must match the claimed --retest-rc (EVIDENCE MISMATCH refusal
# otherwise); (2) the written record carries the retest_verified stamp and
# audit refuses fix records without it (hand-forged / pre-#2562 records
# cannot pass the commit gate); (3) cited cycle-critical files demand the
# real entry point inside the retest command text.
#
# The suite runs the REAL skill inside a throwaway git repo so REPO_ROOT
# (and therefore STATE_DIR + the tracked audit log) resolve to the sandbox,
# never to this repo's live session state.

setup() {
	SKILL="${BATS_TEST_DIRNAME}/../../../skills/prove-yourself-audit/run.sh"
	[ -f "$SKILL" ]
	TEST_TMP=$(mktemp -d -t prove-yourself-audit.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		git config user.email t@t.t
		git config user.name t
		git commit -q --allow-empty -m seed
		# A cycle-critical file for the entry-point rule tests. Exits 0 so
		# it can double as the (truthful) retest command itself.
		mkdir -p hooks
		printf '#!/bin/bash\nexit 0\n' >hooks/x.sh
		chmod +x hooks/x.sh
		# A non-critical citable file.
		echo "doc" >README.md
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}

# p2r1: guarantee a `timeout` on PATH — real one if present, else a stub
# that sleeps out the duration and returns 124 (the deadline shape) so
# the refusal branches execute on every host instead of skipping.
_ensure_timeout_on_path() {
	command -v timeout >/dev/null 2>&1 && return 0
	mkdir -p "$TEST_TMP/tbin"
	printf '#!/bin/bash\nd="$1"; shift\n"$@" &\np=$!\nfor _ in $(seq 1 "$d"); do sleep 1; kill -0 "$p" 2>/dev/null || { wait "$p"; exit $?; }\ndone\nkill "$p" 2>/dev/null\nexit 124\n' >"$TEST_TMP/tbin/timeout"
	chmod +x "$TEST_TMP/tbin/timeout"
	export PATH="$TEST_TMP/tbin:$PATH"
}

# Shorthand: record a fix with overridable retest cmd/rc + cited files.
_record_fix() {
	local cmd="$1" rc="$2" cited="${3:-}"
	# (#2643) Differential symptom evidence is REQUIRED for cycle-critical
	# citations, and most of this file's fixtures cite hooks/x.sh. These
	# tests are about the critical-path RETEST rule, not about symptom
	# evidence, so the helper supplies the smallest TRUTHFUL differential
	# the fixture affords and each test gets on with its own subject.
	#
	# Truthful, not a stub: hooks/x.sh is written into the working tree and
	# never committed, so at HEAD it genuinely does not exist and the
	# baseline genuinely exits 127. --allow-absence-baseline is the explicit
	# claim that absence IS the baseline here — precisely the case that flag
	# exists for, rather than a way around the check.
	local sym=()
	case "$cited" in
	# One pattern: `*hooks/*.sh` already covers pre-commit-hooks/, and `*`
	# matches `/`, so the extra arms were the same pattern written three
	# times. Every fixture in this file that cites a cycle-critical path
	# cites hooks/x.sh.
	*hooks/*.sh | *_lib/*.sh)
		sym=(--symptom-cmd "bash hooks/x.sh" --symptom-baseline-rc 127
			--symptom-fixed-rc 0 --allow-absence-baseline)
		;;
	esac
	run "$SKILL" record-fix \
		--finding-id t1 \
		--finding-text "sample finding" \
		--fix-summary "sample fix" \
		--retest-cmd "$cmd" \
		--retest-rc "$rc" \
		--source phase1 --confidence 5 \
		${cited:+--cited-files "$cited"} \
		"${sym[@]+"${sym[@]}"}"
}

@test "truthful rc-0 evidence records and stamps retest_verified" {
	cd "$TEST_TMP" || return 1
	_record_fix "true" 0
	[ "$status" -eq 0 ]
	[[ $output == *"Recorded fix"* ]] || return 1
	local f
	f=$(ls .claude/.session-state/prove-yourself/*.json)
	[ "$(jq -r '.decision_data.retest_verified' "$f")" = "true" ]
	[ "$(jq -r '.decision_data.retest_actual_rc' "$f")" = "0" ]
}

@test "false rc claim is refused as EVIDENCE MISMATCH, no record written" {
	cd "$TEST_TMP" || return 1
	_record_fix "false" 0
	[ "$status" -eq 1 ]
	[[ $output == *"EVIDENCE MISMATCH"* ]] || return 1
	[[ $output == *"rc=1"* ]] || return 1
	# No state file may exist — a refused record must leave nothing behind.
	local n
	n=$(find .claude/.session-state/prove-yourself -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
	[ "$n" = "0" ]
}

@test "claimed NONZERO rc is legitimate evidence when it matches" {
	cd "$TEST_TMP" || return 1
	_record_fix "bash -c 'exit 3'" 3
	[ "$status" -eq 0 ]
	[[ $output == *"Recorded fix"* ]]
}

@test "retest timeout refuses with the PROVE_RETEST_TIMEOUT hint" {
	# p2r1 CR: no skip — hosts without a real timeout binary get a stub
	# emulating the deadline shape so the refusal branch always executes.
	cd "$TEST_TMP" || return 1
	_ensure_timeout_on_path
	export PROVE_RETEST_TIMEOUT=1
	_record_fix "sleep 5" 0
	unset PROVE_RETEST_TIMEOUT
	[ "$status" -eq 1 ]
	[[ $output == *"deadline"* ]] || return 1
	[[ $output == *"PROVE_RETEST_TIMEOUT"* ]]
}

@test "claimed rc 124 cannot launder a deadline kill (p2r1)" {
	# The CR major: claim 124, supply a hanging command — the wrapper's
	# own kill used to produce a matching 124 that proved nothing. A
	# deadline-elapsed 124 now refuses regardless of the claim.
	cd "$TEST_TMP" || return 1
	_ensure_timeout_on_path
	export PROVE_RETEST_TIMEOUT=1
	_record_fix "sleep 5" 124
	unset PROVE_RETEST_TIMEOUT
	[ "$status" -eq 1 ]
	[[ $output == *"never valid evidence"* ]]
}

@test "a child's own FAST inner timeout (rc 124 before the deadline) is still valid evidence (p2r1)" {
	cd "$TEST_TMP" || return 1
	# rc 124 returned instantly — far below the 120s default deadline, so
	# it is the CHILD's own semantics, not our wrapper kill.
	_record_fix "bash -c 'exit 124'" 124
	[ "$status" -eq 0 ]
	[[ $output == *"Recorded fix"* ]]
}

@test "MENTIONING a critical path without invoking it is refused (p2r1)" {
	cd "$TEST_TMP" || return 1
	_record_fix "echo hooks/x.sh" 0 "hooks/x.sh"
	[ "$status" -eq 2 ]
	[[ $output == *"command position"* ]]
}

@test "a launcher chain (env bash <path>) satisfies command position (p2r1)" {
	cd "$TEST_TMP" || return 1
	_record_fix "env bash hooks/x.sh" 0 "hooks/x.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"Recorded fix"* ]]
}

@test "cycle-critical cited file demands its path inside the retest command" {
	cd "$TEST_TMP" || return 1
	_record_fix "true" 0 "hooks/x.sh"
	[ "$status" -eq 2 ]
	[[ $output == *"cycle-critical"* ]] || return 1
	[[ $output == *"hooks/x.sh"* ]]
}

@test "cycle-critical citation passes when the command invokes the entry point" {
	cd "$TEST_TMP" || return 1
	_record_fix "bash hooks/x.sh" 0 "hooks/x.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"Recorded fix"* ]]
}

@test "non-critical cited file is exempt from the entry-point rule" {
	cd "$TEST_TMP" || return 1
	_record_fix "true" 0 "README.md"
	[ "$status" -eq 0 ]
}

@test "audit refuses a fix record lacking the retest_verified stamp" {
	cd "$TEST_TMP" || return 1
	mkdir -p .claude/.session-state/prove-yourself
	jq -n '{finding_id: "forged", kind: "fix", finding_text: "x", ts: "2020-01-01T00:00:00Z",
	        covers_count: 1, confidence: 5, source: "phase1", cited_files: [],
	        decision_data: {fix_summary: "s", retest_cmd: "true", retest_rc: 0}}' \
		>.claude/.session-state/prove-yourself/forged.json
	run "$SKILL" audit
	[ "$status" -eq 1 ]
	[[ $output == *"retest_verified"* ]]
}

@test "audit passes a record written by the current recorder" {
	cd "$TEST_TMP" || return 1
	_record_fix "true" 0
	[ "$status" -eq 0 ]
	run "$SKILL" audit
	[ "$status" -eq 0 ]
	[[ $output == *"Fixes recorded:      1"* ]]
}

@test "retest output tail is captured into the record" {
	cd "$TEST_TMP" || return 1
	_record_fix "echo tail-marker-xyz" 0
	[ "$status" -eq 0 ]
	local f
	f=$(ls .claude/.session-state/prove-yourself/*.json)
	[[ $(jq -r '.decision_data.retest_output_tail' "$f") == *"tail-marker-xyz"* ]]
}

@test "no-timeout-binary fallback still verifies match AND mismatch (p1r1, p2-ci-r1 deterministic)" {
	# p2-ci-r1 CR major: PATH surgery was host-dependent — on GNU hosts
	# timeout lives in /usr/bin, the hide failed, and the guard converted
	# that into a silent skip on exactly the hosts CI runs. The
	# PROVE_RETEST_NO_TIMEOUT seam forces the unbounded branch
	# deterministically on every host; the WARN proves WHICH branch ran.
	cd "$TEST_TMP" || return 1
	export PROVE_RETEST_NO_TIMEOUT=1
	_record_fix "true" 0
	[ "$status" -eq 0 ]
	[[ $output == *"deadline is UNENFORCED"* ]] || return 1
	[[ $output == *"Recorded fix"* ]] || return 1
	run "$SKILL" record-fix --finding-id tf2 --finding-text x2 --fix-summary y \
		--retest-cmd false --retest-rc 0 --source phase1 --confidence 5
	unset PROVE_RETEST_NO_TIMEOUT
	[ "$status" -eq 1 ]
	[[ $output == *"EVIDENCE MISMATCH"* ]]
}

@test "retest runs anchored at REPO_ROOT even when invoked from a subdir (p1r1)" {
	cd "$TEST_TMP" || return 1
	mkdir -p sub/deeper
	cd sub/deeper || return 1
	run "$SKILL" record-fix --finding-id cwd1 --finding-text x --fix-summary y \
		--retest-cmd "bash hooks/x.sh" --retest-rc 0 --cited-files "hooks/x.sh" \
		--source phase1 --confidence 5 \
		--symptom-cmd "bash hooks/x.sh" --symptom-baseline-rc 127 --symptom-fixed-rc 0 --allow-absence-baseline
	[ "$status" -eq 0 ]
	[[ $output == *"Recorded fix"* ]]
}

@test "a .claude/-prefixed citation still triggers the cycle-critical rule (p1r1)" {
	cd "$TEST_TMP" || return 1
	mkdir -p .claude/hooks
	printf '#!/bin/bash\nexit 0\n' >.claude/hooks/m.sh
	chmod +x .claude/hooks/m.sh
	run "$SKILL" record-fix --finding-id mir1 --finding-text x --fix-summary y \
		--retest-cmd "true" --retest-rc 0 --cited-files ".claude/hooks/m.sh" \
		--source phase1 --confidence 5
	[ "$status" -eq 2 ]
	[[ $output == *"cycle-critical"* ]] || return 1
	# And the SSOT-relative spelling of the entry point satisfies it.
	run "$SKILL" record-fix --finding-id mir2 --finding-text x2 --fix-summary y \
		--retest-cmd "bash .claude/hooks/m.sh" --retest-rc 0 --cited-files ".claude/hooks/m.sh" \
		--source phase1 --confidence 5 \
		--symptom-cmd "bash .claude/hooks/m.sh" --symptom-baseline-rc 127 --symptom-fixed-rc 0 --allow-absence-baseline
	[ "$status" -eq 0 ]
}

@test "non-integer PROVE_RETEST_TIMEOUT warns and falls back to 120 (p1r1)" {
	cd "$TEST_TMP" || return 1
	export PROVE_RETEST_TIMEOUT=abc
	_record_fix "true" 0
	unset PROVE_RETEST_TIMEOUT
	[ "$status" -eq 0 ]
	[[ $output == *"not a positive integer"* ]] || return 1
	[[ $output == *"Recorded fix"* ]]
}

@test "rc-swallowing operator after the entry point is refused (p2-ci-r2/r4)" {
	# The backup reviewer's laundering, round 1: hooks/x.sh || true always
	# reports 0 regardless of the entry point's real exit status. The `;`
	# and `||` shapes now refuse at the single-pipeline rule; the trailing
	# single-pipe shape refuses at the after-path check. Each refusal
	# asserts its SPECIFIC message.
	cd "$TEST_TMP" || return 1
	_record_fix "bash hooks/x.sh || true" 0 "hooks/x.sh"
	[ "$status" -eq 2 ]
	[[ $output == *"SINGLE PIPELINE"* ]] || return 1
	_record_fix "bash hooks/x.sh; true" 0 "hooks/x.sh"
	[ "$status" -eq 2 ]
	[[ $output == *"SINGLE PIPELINE"* ]] || return 1
	_record_fix "bash hooks/x.sh | cat" 0 "hooks/x.sh"
	[ "$status" -eq 2 ]
	[[ $output == *"rc-swallowing"* ]]
}

@test "short-circuit BEFORE the entry point cannot skip its execution (p2-ci-r4)" {
	# The backup reviewer's round 2: `true || bash hooks/x.sh` NEVER runs
	# the entry point (shell short-circuit) yet reports true's rc 0 —
	# verified evidence for a hook that never executed. Mirror: `false &&`
	# launders a claimed nonzero.
	cd "$TEST_TMP" || return 1
	_record_fix "true || bash hooks/x.sh" 0 "hooks/x.sh"
	[ "$status" -eq 2 ]
	[[ $output == *"SINGLE PIPELINE"* ]] || return 1
	_record_fix "false && bash hooks/x.sh" 1 "hooks/x.sh"
	[ "$status" -eq 2 ]
	[[ $output == *"SINGLE PIPELINE"* ]]
}

@test "operators FEEDING the entry point stay legal; redirect digraphs are not operators (p2-ci-r2)" {
	cd "$TEST_TMP" || return 1
	_record_fix "printf x | bash hooks/x.sh" 0 "hooks/x.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"Recorded fix"* ]] || return 1
	run "$SKILL" record-fix --finding-id rd1 --finding-text xr --fix-summary y \
		--retest-cmd "bash hooks/x.sh >/dev/null 2>&1" --retest-rc 0 \
		--cited-files "hooks/x.sh" --source phase1 --confidence 5 \
		--symptom-cmd "bash hooks/x.sh" --symptom-baseline-rc 127 --symptom-fixed-rc 0 --allow-absence-baseline
	[ "$status" -eq 0 ]
	[[ $output == *"Recorded fix"* ]]
}

@test "a ./-prefixed citation still triggers the cycle-critical rule (p2-cap)" {
	cd "$TEST_TMP" || return 1
	_record_fix "true" 0 "./hooks/x.sh"
	[ "$status" -eq 2 ]
	[[ $output == *"cycle-critical"* ]] || return 1
	_record_fix "bash ./hooks/x.sh" 0 "./hooks/x.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"Recorded fix"* ]]
}

@test "COMBINED ./.claude/ prefixes still trigger the rule (p2-ci-r3)" {
	cd "$TEST_TMP" || return 1
	mkdir -p .claude/hooks
	printf '#!/bin/bash\nexit 0\n' >.claude/hooks/c.sh
	chmod +x .claude/hooks/c.sh
	_record_fix "true" 0 "./.claude/hooks/c.sh"
	[ "$status" -eq 2 ]
	[[ $output == *"cycle-critical"* ]]
}

@test "a lexical ..-segment citation still triggers the rule (p2-cap)" {
	cd "$TEST_TMP" || return 1
	_record_fix "true" 0 "hooks/../hooks/x.sh"
	[ "$status" -eq 2 ]
	[[ $output == *"cycle-critical"* ]]
}

@test "no timeout binary WITHOUT the explicit seam refuses fail-closed (p2-cap, p2-ci-r3 deterministic)" {
	# p2-ci-r3 CR: nb-ONLY PATH — /usr/bin:/bin exposed GNU timeout and
	# the old skip guard neutered the only fail-closed coverage there.
	# Every tool the skill needs is symlinked in, timeout deliberately
	# NOT, so the refusal branch runs on every host. No skip.
	cd "$TEST_TMP" || return 1
	mkdir -p nb
	for t in jq git bash sh grep sed tail head date mktemp shasum ls find mkdir rm cat sort tr uniq cut dirname basename wc env; do
		p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "nb/$t"
	done
	run env PATH="$TEST_TMP/nb" bash -c "cd '$TEST_TMP' && '$SKILL' record-fix --finding-id nt1 --finding-text x --fix-summary y --retest-cmd true --retest-rc 0 --source phase1 --confidence 5"
	[ "$status" -eq 1 ]
	[[ $output == *"refusing to run retest evidence UNBOUNDED"* ]] || return 1
	[[ $output == *"PROVE_RETEST_NO_TIMEOUT"* ]]
}

# $1 = --reason text. Everything else is a valid minimal rejection.
_record_rejection_reason() {
	run env HOME="$TEST_TMP" bash -c "cd '$TEST_TMP' && '$SKILL' record-rejection \
		--finding-id ap1 --finding-text 'sample finding' \
		--dogfood-cmd 'true' --dogfood-output 'ok' --dogfood-rc 0 \
		--external-authority 'GNU coreutils manual, timeout(1)' \
		--reason \"\$1\" --source cr --severity minor" _ "$1"
}

@test "anti-pattern match is WORD-BOUNDED, not bare substring (p2r1)" {
	# The guard's remedy line is "APPLY the fix instead of rejecting", so a
	# false positive actively pushes the reviewer toward making a change they
	# had correctly judged wrong. Found live: "od shows" fired inside
	# "dogfood shows", blocking a rejection whose evidence was a docs quote.
	cd "$TEST_TMP" || return 1
	_record_rejection_reason "The dogfood shows zero matches, so the suggestion would loosen the config."
	[ "$status" -eq 0 ] || {
		echo "word-bounded guard still blocked a legitimate reason: $output"
		return 1
	}
	[[ $output != *"anti-pattern"* ]]
}

@test "the real self-citation anti-patterns still BLOCK (not over-corrected) (p2r1)" {
	cd "$TEST_TMP" || return 1
	# Standalone, mid-sentence, and sentence-initial — every position a
	# boundary check has to get right.
	# The last two END at the field boundary: with text after every case, a
	# regression that rejected a match on an EMPTY `$after` would go unseen.
	for r in "od shows the bytes are fine" \
		"I checked and od shows nothing" \
		"memory says this was already settled" \
		"i remember rejecting this one before" \
		"od shows" \
		"I already checked and od shows"; do
		_record_rejection_reason "$r"
		# rc 2 is this skill's validation-refusal status (not 1).
		[ "$status" -eq 2 ] || {
			echo "anti-pattern NOT blocked (rc $status): $r"
			return 1
		}
		[[ $output == *"anti-pattern"* ]] || return 1
	done
}
