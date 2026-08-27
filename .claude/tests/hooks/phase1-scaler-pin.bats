#!/usr/bin/env bats
# covers: hooks/phase1-scaler.sh
#
# (#2544) The round cap chased its own tail. The tier tables in phase1-scaler
# are a pure function of the CURRENT finding count, recomputed on every call,
# so the number bounding how many review rounds a branch may spend GREW as
# those rounds found things:
#
#   cap 3 (cr=10, moderate) -> the round that hit 3/3 returned 13 findings
#   -> the next call read cr=13 -> high -> cap 5, and 3/3-ENFORCED became 4/5
#
# Observed live on fix/v0.34.184/2548-cr-thread-reply. It only ever rose,
# cr_count being floored by ancestor rows, so it was a ratchet. Both phases
# read this one number, so it was never phase-2-specific.
#
# Split out of phase05-skip-scaler-signal.bats: that file is scoped to the
# phase0.5 skip-signal contract, and per-branch pin state is a different
# subject.
#
# These drive the REAL script against a scratch consumer repo, with PIN_DIR
# pointed at the per-test tmpdir via PHASE1_SCALER_PIN_DIR, so nothing here
# can read or write the operator's own pin.

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	TEST_TMP=$(mktemp -d -t phase05-skip.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	TREE="$TEST_TMP/tree" # scratch plugin tree (hooks/ + _lib/)
	WORK="$TEST_TMP/work" # scratch consumer git repo
	BIN="$TEST_TMP/bin"   # controlled PATH (jq/yq present; codex/gemini absent)
	_mk_fixture || {
		echo "FATAL: fixture build failed" >&2
		return 1
	}
}

teardown() {
	cd /tmp || return 0
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */phase05-skip.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_mk_fixture() {
	mkdir -p "$TREE/hooks" "$TREE/_lib" "$WORK/.claude" "$BIN" || return 1
	# Real hook + lib copies — the resolver's plugin root becomes $TREE.
	cp "$REPO_ROOT/hooks/phase0.5-copilot-prefilter.sh" "$TREE/hooks/" || return 1
	cp "$REPO_ROOT/hooks/phase0.5-codex-prefilter.sh" "$TREE/hooks/" || return 1
	cp "$REPO_ROOT/hooks/phase0.5-gemini-prefilter.sh" "$TREE/hooks/" || return 1
	cp "$REPO_ROOT/_lib/resolve-plugin-helper.sh" "$TREE/_lib/" || return 1
	cp "$REPO_ROOT/_lib/phase05-dedupe.sh" "$TREE/_lib/" || return 1
	# Sourced at end-of-run by the gemini happy path (CR r4 --policy test).
	cp "$REPO_ROOT/_lib/phase05-auth-summary.sh" "$TREE/_lib/" || return 1
	# Sibling helpers the hooks preflight (stubs; never invoked on skip paths).
	printf '#!/bin/bash\ncat\n' >"$TREE/hooks/phase1-dedup.sh" || return 1
	printf '#!/bin/bash\ncat\n' >"$TREE/hooks/phase0.5-dedupe-against-audit.sh" || return 1
	chmod +x "$TREE/hooks/phase1-dedup.sh" "$TREE/hooks/phase0.5-dedupe-against-audit.sh" || return 1
	# Consumer repo: main + feature branch with a real diff. -b main pins
	# the branch name so the hooks' default --base main is host-independent
	# (init.defaultBranch varies).
	(cd "$WORK" &&
		git init -q -b main &&
		git config user.email t@t.t &&
		git config user.name t &&
		printf 'base\n' >f.txt &&
		git add -A && git commit -qm base &&
		git checkout -qb feat/test &&
		printf 'base\nchanged line for the diff\n' >f.txt &&
		git add -A && git commit -qm change) || return 1
	cp "$REPO_ROOT/.claude/review-config.yml" "$WORK/.claude/review-config.yml" || return 1
	# Controlled PATH: coreutils from /usr/bin:/bin, jq/yq symlinked in,
	# codex/gemini deliberately ABSENT regardless of host installs.
	ln -sf "$(command -v jq)" "$BIN/jq" || return 1
	ln -sf "$(command -v yq)" "$BIN/yq" || return 1
	ln -sf "$(command -v git)" "$BIN/git" || return 1
	# CR r6: /usr/bin:/bin stay on PATH for coreutils (shimming ~15 of
	# them is fragile), so the absent-CLI contract holds only while no
	# host ships codex/gemini THERE (brew -> /opt/homebrew, npm ->
	# /usr/local|~). Fail LOUD if an exotic host breaks that assumption
	# instead of letting absent-CLI tests silently test the wrong thing.
	for _cli in codex gemini; do
		if [ -x "/usr/bin/$_cli" ] || [ -x "/bin/$_cli" ]; then
			echo "FATAL: host has $_cli in /usr/bin or /bin - fixture PATH isolation broken" >&2
			return 1
		fi
	done
	return 0
}

# Feeds the CR-findings signal the tier tables read. Appends are safe: each
# test gets a fresh TEST_TMP from setup().
_log_cr() { # $1 = findings count for the latest CR entry
	mkdir -p "$WORK/.claude/logs"
	printf '{"ts":"2026-07-08T00:00:00Z","findings":%s}\n' "$1" \
		>>"$WORK/.claude/logs/cr-local-review.jsonl"
}

_scaler_pin() { # $1 = extra env words
	run bash -c "cd '$WORK' && PHASE1_SCALER_PIN_DIR='$TEST_TMP/pins' ${1:-} bash '$REPO_ROOT/hooks/phase1-scaler.sh' --explain --base main"
}

@test "scaler pin: a later finding count does NOT raise the cap" {
	# THE regression. First resolve at 10 findings -> moderate/3. Then cross
	# the 11+ boundary, which previously produced high/5 on the very next call.
	_log_cr 10
	_scaler_pin
	[ "$status" -eq 0 ]
	[[ $output == *"ROUNDS=3"* ]] || {
		echo "first resolve was not moderate/3: $output"
		return 1
	}
	[[ $output == *"pinned=0"* ]] || {
		echo "the first resolve should not report as pinned: $output"
		return 1
	}
	_log_cr 13
	_scaler_pin
	[ "$status" -eq 0 ]
	[[ $output == *"ROUNDS=3"* ]] || {
		echo "the cap grew with the finding count — the treadmill is back: $output"
		return 1
	}
	[[ $output == *"pinned=1"* ]] || {
		echo "held the number but did not report it as pinned: $output"
		return 1
	}
}

@test "scaler pin: a fix commit on the SAME branch does not re-resolve" {
	# Per-branch, not per-SHA. Re-resolving on each new HEAD would reintroduce
	# the treadmill one fix commit at a time.
	_log_cr 10
	_scaler_pin
	[[ $output == *"ROUNDS=3"* ]] || return 1
	(cd "$WORK" && printf 'more\n' >>f.txt && git add -A &&
		git -c user.email=t@t.t -c user.name=t commit -qm fix) || return 1
	_log_cr 13
	_scaler_pin
	[ "$status" -eq 0 ]
	[[ $output == *"ROUNDS=3"* ]] || {
		echo "a new HEAD re-resolved the tier: $output"
		return 1
	}
	[[ $output == *"pinned=1"* ]]
}

@test "scaler pin: a DIFFERENT branch resolves fresh" {
	# The pin bounds one branch's budget; it must not leak to the next.
	_log_cr 10
	_scaler_pin
	[[ $output == *"ROUNDS=3"* ]] || return 1
	(cd "$WORK" && git checkout -qb feat/other) || return 1
	_log_cr 13
	_scaler_pin
	[ "$status" -eq 0 ]
	[[ $output == *"pinned=0"* ]] || {
		echo "a different branch inherited the pin: $output"
		return 1
	}
	[[ $output == *"ROUNDS=5"* ]] || {
		echo "the fresh branch did not resolve from its own signals: $output"
		return 1
	}
}

@test "scaler pin: PHASE1_MIN_ROUNDS still raises a pinned-low cap" {
	# Floors apply UPWARD over a pin. The pin bounds growth; it does not grant
	# permission to review less than a floor demands.
	_log_cr 1
	_scaler_pin
	[[ $output == *"ROUNDS=2"* ]] || return 1
	_scaler_pin "PHASE1_MIN_ROUNDS=4"
	[ "$status" -eq 0 ]
	[[ $output == *"ROUNDS=4"* ]] || {
		echo "a pin held the count under an explicit floor: $output"
		return 1
	}
	[[ $output == *"pinned=1"* ]]
}

@test "scaler pin: PHASE1_ROUNDS override still wins outright" {
	_log_cr 10
	_scaler_pin
	[[ $output == *"ROUNDS=3"* ]] || return 1
	_scaler_pin "PHASE1_ROUNDS=9"
	[ "$status" -eq 0 ]
	[[ $output == *"ROUNDS=9"* ]] || {
		echo "the explicit override did not beat the pin: $output"
		return 1
	}
	[[ $output == *"PHASE1_ROUNDS env override"* ]]
}

@test "scaler pin: --repin re-resolves deliberately" {
	_log_cr 10
	_scaler_pin
	[[ $output == *"ROUNDS=3"* ]] || return 1
	_log_cr 13
	run bash -c "cd '$WORK' && PHASE1_SCALER_PIN_DIR='$TEST_TMP/pins' bash '$REPO_ROOT/hooks/phase1-scaler.sh' --explain --base main --repin"
	[ "$status" -eq 0 ]
	[[ $output == *"ROUNDS=5"* ]] || {
		echo "--repin did not re-resolve: $output"
		return 1
	}
	[[ $output == *"repinned"* ]]
}

@test "scaler pin: a CORRUPT pin re-resolves loudly, never aborts" {
	# A hook that dies on a truncated state file is worse than one that
	# recomputes — and a silently discarded pin looks exactly like a first run.
	_log_cr 10
	_scaler_pin
	[[ $output == *"ROUNDS=3"* ]] || return 1
	local pin
	pin=$(find "$TEST_TMP/pins" -name '*.json' 2>/dev/null | head -1)
	[ -n "$pin" ] || {
		echo "no pin file was written"
		return 1
	}
	printf 'not json at all\n' >"$pin"
	_scaler_pin
	[ "$status" -eq 0 ] || {
		echo "a corrupt pin aborted the scaler: $output"
		return 1
	}
	[[ $output == *"unreadable or has no valid rounds"* ]] || {
		echo "the corrupt pin was discarded silently: $output"
		return 1
	}
	[[ $output == *"pinned=0"* ]]
}

@test "scaler pin: corruption recovery WRITES a fresh pin, not just a warning" {
	# The recovery path is only half-done if it re-resolves and then leaves the
	# branch unpinned: the next call re-resolves too, which is the treadmill
	# with an extra warning printed.
	_log_cr 10
	_scaler_pin
	[[ $output == *"ROUNDS=3"* ]] || return 1
	local pin
	pin=$(find "$TEST_TMP/pins" -name '*.json' 2>/dev/null | head -1)
	[ -n "$pin" ] || {
		echo "no pin file was written"
		return 1
	}
	printf 'not json\n' >"$pin"
	_scaler_pin
	[[ $output == *"pinned=0"* ]] || return 1
	# The recovered pin must now hold on the NEXT call, at the recovered value.
	_log_cr 13
	_scaler_pin
	[ "$status" -eq 0 ]
	[[ $output == *"pinned=1"* ]] || {
		echo "corruption recovery re-resolved but never re-pinned: $output"
		return 1
	}
	[[ $output == *"ROUNDS=3"* ]] || {
		echo "the recovered pin did not hold its value: $output"
		return 1
	}
}

@test "scaler pin: a detached HEAD WARNS instead of silently unpinning" {
	# Empty branch slug skips both pin blocks, restoring the pre-#2544
	# treadmill. Silent is the one thing this feature cannot be.
	_log_cr 10
	(cd "$WORK" && git checkout -q --detach HEAD) || return 1
	_scaler_pin
	[ "$status" -eq 0 ]
	[[ $output == *"detached HEAD"* ]] || {
		echo "a detached HEAD disabled pinning with no warning: $output"
		return 1
	}
	[[ $output == *"pinned=0"* ]]
}

@test "scaler pin: a missing jq WARNS instead of silently unpinning" {
	# The pin is JSON. Without jq it can be neither read nor written, so the
	# cap silently reverts to per-call resolution — the tier tables above
	# degrade quietly by design, but this must not.
	_log_cr 10
	# PATH must contain everything the script calls EXCEPT jq. Dropping
	# /usr/bin wholesale is not enough on its own — this host ships
	# /usr/bin/jq — and keeping /usr/bin keeps jq. So the exact command set is
	# symlinked in and nothing else is on PATH. The list comes from the
	# script itself; if it grows a dependency this test fails loudly at the
	# symlink step rather than silently testing the wrong thing.
	local nojq="$TEST_TMP/nojq" _c
	mkdir -p "$nojq"
	for _c in awk cut date find git mkdir mv rm sed tail tr; do
		ln -sf "$(command -v "$_c")" "$nojq/$_c" || {
			echo "fixture: could not shim $_c"
			return 1
		}
	done
	# The interpreter is named ABSOLUTELY: with PATH stripped to the shim dir,
	# a bare `bash` is itself unresolvable, and the run failed on that instead
	# of on the thing under test.
	local _bash
	_bash=$(command -v bash)
	run bash -c "cd '$WORK' && PATH='$nojq' PHASE1_SCALER_PIN_DIR='$TEST_TMP/pins' '$_bash' '$REPO_ROOT/hooks/phase1-scaler.sh' --explain --base main"
	[ "$status" -eq 0 ]
	[[ $output == *"jq not found"* ]] || {
		echo "a missing jq disabled pinning with no warning: $output"
		return 1
	}
}

@test "scaler pin: the sensitive-path floor still applies OVER a pin" {
	# The other floor. PHASE1_MIN_ROUNDS was covered; the sensitive-path floor
	# runs through the same post-pin path and was not.
	_log_cr 0
	(cd "$WORK" && mkdir -p authelia && printf 'x\n' >authelia/config.yml &&
		git add -A && git -c user.email=t@t.t -c user.name=t commit -qm sensitive) || return 1
	_scaler_pin
	[ "$status" -eq 0 ]
	[[ $output == *"sensitive=1"* ]] || {
		echo "the sensitive-path signal was not detected: $output"
		return 1
	}
	# all-clean would be 1 round; the floor lifts it to 2 even though the pin
	# was written from the same resolve.
	[[ $output != *"ROUNDS=1"* ]] || {
		echo "a pin held the count under the sensitive-path floor: $output"
		return 1
	}
}

@test "scaler pin: --repin does not persist the marker into the tier" {
	# `tier="${tier}+repinned"` wrote the marker into the new pin file, so
	# every later read reported `moderate+repinned` forever — a one-off event
	# conflated with the tier field, permanently.
	_log_cr 10
	_scaler_pin
	[[ $output == *"ROUNDS=3"* ]] || return 1
	run bash -c "cd '$WORK' && PHASE1_SCALER_PIN_DIR='$TEST_TMP/pins' bash '$REPO_ROOT/hooks/phase1-scaler.sh' --explain --base main --repin"
	[ "$status" -eq 0 ]
	[[ $output == *"repinned=1"* ]] || {
		echo "--repin was not reported: $output"
		return 1
	}
	# The NEXT call reads the pin written by the repin. Its tier must be clean.
	_scaler_pin
	[ "$status" -eq 0 ]
	[[ $output == *"pinned=1"* ]] || return 1
	[[ $output != *"+repinned"* ]] || {
		echo "the repin marker was persisted into the tier field: $output"
		return 1
	}
	[[ $output != *"repinned=1"* ]] || {
		echo "a later call still reports itself as a repin: $output"
		return 1
	}
}

@test "scaler pin: --help still prints Usage after the header grew" {
	# The defect this PR narrates: --help printed the header by hardcoded LINE
	# NUMBER, so adding a paragraph pushed Usage out of range and the flag
	# silently stopped showing how to invoke the script. Without this test the
	# same edit breaks it again with no signal.
	run bash "$REPO_ROOT/hooks/phase1-scaler.sh" --help
	[ "$status" -eq 0 ]
	[[ $output == *"Usage:"* ]] || {
		echo "--help no longer prints Usage: $output"
		return 1
	}
	[[ $output == *"--explain"* ]] || {
		echo "--help does not show the flags: $output"
		return 1
	}
	[[ $output == *"--repin"* ]]
}

@test "scaler pin: an UNWRITABLE pin dir warns and keeps recomputing" {
	# Not fatal — the tier just resolves per call, which is the old behaviour.
	# But the operator has to know the cap is not actually being held.
	_log_cr 10
	local ro="$TEST_TMP/readonly"
	mkdir -p "$ro"
	chmod 500 "$ro"
	run bash -c "cd '$WORK' && PHASE1_SCALER_PIN_DIR='$ro/pins' bash '$REPO_ROOT/hooks/phase1-scaler.sh' --explain --base main"
	chmod 700 "$ro"
	[ "$status" -eq 0 ]
	[[ $output == *"could not write the tier pin"* ]] || {
		echo "an unwritable pin dir was silent: $output"
		return 1
	}
	[[ $output == *"pinned=0"* ]] || return 1
	# "keeps recomputing" is the name of this test, so it is asserted rather
	# than assumed: a second call with a finding count across a tier boundary
	# must now MOVE, because nothing was pinned to hold it.
	_log_cr 13
	chmod 500 "$ro"
	run bash -c "cd '$WORK' && PHASE1_SCALER_PIN_DIR='$ro/pins' bash '$REPO_ROOT/hooks/phase1-scaler.sh' --explain --base main"
	chmod 700 "$ro"
	[ "$status" -eq 0 ]
	[[ $output == *"ROUNDS=5"* ]] || {
		echo "an unpinned run did not recompute from the new count: $output"
		return 1
	}
	[[ $output == *"pinned=0"* ]]
}

@test "scaler pin: a STALE pin is REMOVED when the write fails" {
	# The `[ -f "$PIN_FILE" ]` success test was WRONG with a pin already
	# present: a failed replace left the old file, the test passed, nothing
	# warned, and the script served a value it had just failed to update.
	#
	# Setup: a valid pin exists, then it is corrupted so the next call
	# re-resolves, and the directory is made read-only so the replacing write
	# fails with the stale file still sitting there.
	_log_cr 1
	_scaler_pin
	[[ $output == *"ROUNDS=2"* ]] || return 1
	local pin
	pin=$(find "$TEST_TMP/pins" -name '*.json' | head -1)
	[ -n "$pin" ] || {
		echo "no pin file was written"
		return 1
	}
	printf 'not json\n' >"$pin"
	chmod 500 "$TEST_TMP/pins"
	_scaler_pin
	chmod 700 "$TEST_TMP/pins"
	[ "$status" -eq 0 ]
	[[ $output == *"could not write the tier pin"* ]] || {
		echo "the failed write did not warn: $output"
		return 1
	}
	# In THIS scenario the directory itself is read-only, so the removal
	# cannot succeed either — and the script says so rather than implying the
	# stale pin is gone. Asserting the removal here would be asserting
	# something the filesystem forbids.
	[[ $output == *"STALE pin remains"* ]] || {
		echo "the un-removable stale pin was not reported: $output"
		return 1
	}
}

@test "scaler pin: a stale pin IS removed when the directory allows it" {
	# The other half, and the one the fix is actually for: the write fails
	# (bad content already there, re-resolve, then the tmp write is blocked)
	# while the directory still permits removal. The stale pin must be gone so
	# the next call cannot read a number this run already rejected.
	_log_cr 1
	_scaler_pin
	local pin
	pin=$(find "$TEST_TMP/pins" -name '*.json' | head -1)
	[ -n "$pin" ] || return 1
	printf 'not json\n' >"$pin"
	# Block only the TMP write, by making the target name a directory the
	# printf cannot open — the pins dir itself stays writable.
	mkdir -p "$pin.$$" 2>/dev/null || true
	_scaler_pin
	rmdir "$TEST_TMP/pins/"*.\$\$ 2>/dev/null || true
	[ "$status" -eq 0 ]
	# Either it wrote cleanly (pin present and valid) or it failed and removed
	# the stale one. What must NEVER be true is a corrupt pin left in place.
	if [ -f "$pin" ]; then
		jq -e '.rounds' "$pin" >/dev/null 2>&1 || {
			echo "a corrupt pin was left in place: $(cat "$pin")"
			return 1
		}
	fi
}

@test "scaler pin: stale pins are PRUNED on write" {
	_log_cr 10
	_scaler_pin
	[[ $output == *"ROUNDS=3"* ]] || return 1
	local old="$TEST_TMP/pins/a_long_dead_branch.json"
	printf '{"rounds":5,"tier":"high"}\n' >"$old"
	# 40 days back — past the 30-day window.
	touch -t "$(date -u -v-40d +%Y%m%d0000 2>/dev/null || date -u -d '40 days ago' +%Y%m%d0000)" "$old"
	(cd "$WORK" && git checkout -qb feat/prune-trigger) || return 1
	_scaler_pin
	[ "$status" -eq 0 ]
	[ ! -f "$old" ] || {
		echo "a 40-day-old pin survived the prune"
		return 1
	}
}

@test "scaler pin: --repin on an unpinnable branch does not crash" {
	# Detached HEAD leaves branch_slug empty, so the repin block is skipped
	# entirely. It must warn and exit cleanly, not fall through to a rm/printf
	# against an empty path.
	_log_cr 10
	(cd "$WORK" && git checkout -q --detach HEAD) || return 1
	run bash -c "cd '$WORK' && PHASE1_SCALER_PIN_DIR='$TEST_TMP/pins' bash '$REPO_ROOT/hooks/phase1-scaler.sh' --explain --base main --repin"
	[ "$status" -eq 0 ]
	[[ $output == *"detached HEAD"* ]] || {
		echo "--repin on a detached HEAD did not warn: $output"
		return 1
	}
	[[ $output == *"ROUNDS="* ]]
}

@test "scaler pin: --repin WRITES an audit row with branch, reason and rounds" {
	# The whole claim of `--repin` is that a deliberate cap change is tracked.
	# Asserting only the stdout text leaves the audit trail — the part that
	# outlives the terminal — unverified.
	_log_cr 10
	_scaler_pin
	[[ $output == *"ROUNDS=3"* ]] || return 1
	_log_cr 13
	run bash -c "cd '$WORK' && PHASE1_SCALER_PIN_DIR='$TEST_TMP/pins' PHASE1_REPIN_REASON='widened for the auth rewrite' bash '$REPO_ROOT/hooks/phase1-scaler.sh' --explain --base main --repin"
	[ "$status" -eq 0 ]
	local log="$WORK/.claude/logs/pipeline-skip.jsonl"
	[ -f "$log" ] || {
		echo "no audit log was written at all"
		return 1
	}
	local row
	row=$(grep 'phase1-scaler-repin' "$log" | tail -1)
	[ -n "$row" ] || {
		echo "no phase1-scaler-repin row in $log"
		return 1
	}
	# The reason is the operator wording — the field exists so a later reader
	# knows WHY the cap moved, not merely that it did.
	[ "$(printf '%s' "$row" | jq -r '.reason')" = "widened for the auth rewrite" ] || {
		echo "PHASE1_REPIN_REASON did not reach the audit row: $row"
		return 1
	}
	[ "$(printf '%s' "$row" | jq -r '.new_rounds')" = "5" ] || {
		echo "the audit row did not record the re-resolved value: $row"
		return 1
	}
	[ "$(printf '%s' "$row" | jq -r '.branch')" = "feat_test" ] || {
		echo "the audit row did not record the branch: $row"
		return 1
	}
}

@test "scaler pin: an unstated repin reason is recorded as such" {
	# The default has to be a value a reader can recognise, not an empty
	# string that looks like the field was dropped.
	_log_cr 10
	_scaler_pin
	run bash -c "cd '$WORK' && PHASE1_SCALER_PIN_DIR='$TEST_TMP/pins' bash '$REPO_ROOT/hooks/phase1-scaler.sh' --explain --base main --repin"
	[ "$status" -eq 0 ]
	local row
	row=$(grep 'phase1-scaler-repin' "$WORK/.claude/logs/pipeline-skip.jsonl" | tail -1)
	[ "$(printf '%s' "$row" | jq -r '.reason')" = "unstated" ] || {
		echo "the default reason is not recognisable: $row"
		return 1
	}
}

@test "scaler pin: a FAILED repin audit write warns instead of proceeding quietly" {
	# --repin is sold as audit-logged. A silent write failure makes that
	# sentence false at exactly the moment someone is changing a cap on
	# purpose, which is when the trail matters most.
	_log_cr 10
	_scaler_pin
	mkdir -p "$WORK/.claude/logs"
	chmod 500 "$WORK/.claude/logs"
	run bash -c "cd '$WORK' && PHASE1_SCALER_PIN_DIR='$TEST_TMP/pins' bash '$REPO_ROOT/hooks/phase1-scaler.sh' --explain --base main --repin"
	chmod 700 "$WORK/.claude/logs"
	[ "$status" -eq 0 ]
	[[ $output == *"audit row could NOT be written"* ]] || {
		echo "a failed audit write was silent: $output"
		return 1
	}
	# It still re-pins — refusing would strand the operator — but says so.
	[[ $output == *"repinned=1"* ]]
}

@test "scaler pin: a pin with no tier surfaces the sentinel, not a fake tier" {
	# rounds is what gates; tier is what the operator reads. A pin missing its
	# tier must say so distinguishably rather than print a word that could be
	# mistaken for one the table produces.
	_log_cr 10
	_scaler_pin
	[[ $output == *"ROUNDS=3"* ]] || return 1
	local pin
	pin=$(find "$TEST_TMP/pins" -name '*.json' | head -1)
	[ -n "$pin" ] || return 1
	printf '{"rounds":3,"pinned_at":"2026-01-01T00:00:00Z"}\n' >"$pin"
	_scaler_pin
	[ "$status" -eq 0 ]
	[[ $output == *"ROUNDS=3"* ]] || {
		echo "a tier-less pin lost its rounds value: $output"
		return 1
	}
	[[ $output == *"pin-tier-missing"* ]] || {
		echo "a tier-less pin did not surface the sentinel: $output"
		return 1
	}
	[[ $output == *"pinned=1"* ]]
}

@test "scaler pin: a prune failure WARNS like every sibling path" {
	# The prune ended in `|| true` while every other failure in the block
	# warns. A prune that silently stops working just grows the directory
	# forever, which is the failure nobody notices until it is large.
	_log_cr 10
	_scaler_pin
	[[ $output == *"ROUNDS=3"* ]] || return 1
	# An OLD pin in a read-only directory: find matches it, cannot delete it,
	# prints the reason to stderr — and exits 0 anyway. That exit status is
	# why the first version of this warning could never fire, and why the
	# check reads stderr instead.
	local old="$TEST_TMP/pins/an_old_branch.json"
	printf '{"rounds":5,"tier":"high"}\n' >"$old"
	touch -t "$(date -u -v-40d +%Y%m%d0000 2>/dev/null || date -u -d '40 days ago' +%Y%m%d0000)" "$old"
	chmod 500 "$TEST_TMP/pins"
	(cd "$WORK" && git checkout -qb feat/prune-warn) || return 1
	_scaler_pin
	chmod 700 "$TEST_TMP/pins"
	[ "$status" -eq 0 ]
	[[ $output == *"could not prune stale pins"* ]] || {
		echo "a prune failure was silent: $output"
		return 1
	}
	# And it names what went wrong, not merely that something did.
	[[ $output == *"Permission denied"* || $output == *"denied"* ]] || {
		echo "the prune warning did not carry the underlying error: $output"
		return 1
	}
}
