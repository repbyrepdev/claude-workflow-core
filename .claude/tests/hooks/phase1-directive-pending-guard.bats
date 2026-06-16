#!/usr/bin/env bats
# covers: hooks/phase1-directive-pending-guard.sh
# shellcheck disable=SC2030,SC2031  # _setup_pending_repo + `run`/$() subshells modify+read TDIR/sha across @test bodies; intentional + isolated per test
#
# Tests for v0.27.0 #173 Layer 1 self-heal.
# Full integration tests of the PreToolUse hook require the full plugin
# layout (_lib/ + dirname BASH_SOURCE resolution). Until a fixture
# harness exists for that, these tests assert the regression-guard
# patterns are present in the source.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/phase1-directive-pending-guard.sh"
	[ -f "$HOOK" ]
}

@test "Layer 1 origin/main reachability check present" {
	# v0.27.0 #173 Layer 1
	grep -q 'git merge-base --is-ancestor "\$sha" origin/main' "$HOOK"
}

@test "Layer 1 v0.28.0 #174 abandoned-commit check present" {
	# v0.28.0 #174 extension — for-each-ref --contains for any-local-ref
	grep -q 'git for-each-ref --contains "\$sha"' "$HOOK"
}

@test "Layer 1 v0.28.0 #174 hex-sha basename validation present" {
	# v0.28.x #174/#178 P1 r1 fix: validate basename is hex sha before
	# for-each-ref so editor swap files / .DS_Store don't trigger mass-rm
	grep -qF '$sha =~ ^[0-9a-f]{7,40}$' "$HOOK"
}

# --- v0.30.E (#191) behavioral harness: read-only allowlist ----------------
# Build a synthetic git repo with a pending phase1-directive marker, then pipe
# tool payloads to the REAL hook (cwd inside the synth repo so REPO_ROOT
# resolves there; the hook finds its _lib via its own BASH_SOURCE path). The
# marker's sha is a real local commit, unreachable from origin/main (no
# remote) so Layer 1 keeps it, reachable from HEAD so #174 keeps it.

_setup_pending_repo() {
	TDIR=$(mktemp -d -t p1dir-guard.XXXXXX)
	(
		cd "$TDIR" || exit 1
		git init -q
		git config user.email t@t.t
		git config user.name t
		git commit -q --allow-empty -m init
		sha=$(git rev-parse HEAD)
		mkdir -p .claude/.session-state/ship-cycle
		printf 'directive text\n' >".claude/.session-state/ship-cycle/${sha}.phase1-directive.txt"
	)
}

# Run the hook from inside the synth repo with a given payload; echo the
# decision. Modern PreToolUse hooks signal deny via a JSON
# `"permissionDecision":"deny"` on stdout + exit 0 (NOT exit code 2), so we
# parse the decision from stdout rather than the rc.
_run_guard() {
	local payload=$1 out
	out=$(cd "$TDIR" && printf '%s' "$payload" | "$HOOK" 2>/dev/null)
	if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
		echo deny
	else
		echo allow
	fi
}

# CR #223: assert the hook contract DIRECTLY (real exit status + raw stdout
# payload), not just the allow/deny reduction above. Modern PreToolUse hooks
# signal DENY via a JSON `permissionDecision:deny` on stdout AND exit 0 (the
# documented reliable blocking path — they do NOT exit non-zero), and signal
# ALLOW by exiting 0 with NO JSON. So the contract under test is: status is
# ALWAYS 0, and the stdout payload is what distinguishes deny from allow. This
# helper runs the REAL hook under bats' `run` so $status / $output bind to the
# hook process itself (a crash / malformed response would surface here, where
# the reduced _run_guard string could mask it).
_run_guard_raw() {
	run bash -c 'cd "$1" && printf "%s" "$2" | "$3" 2>/dev/null' _ "$TDIR" "$1" "$HOOK"
}

# Seed a phase1-directive marker for an ABANDONED (non-HEAD) but syntactically
# valid hex sha — genuine Layer 0 cruft (a squash-merge orphan / deleted topic
# branch), distinct from a live round on the current HEAD.
_seed_abandoned_marker() {
	ABANDONED_SHA="0123456789abcdef0123456789abcdef01234567"
	printf 'directive text\n' \
		>"$TDIR/.claude/.session-state/ship-cycle/${ABANDONED_SHA}.phase1-directive.txt"
}

teardown() {
	if [ -n "${TDIR:-}" ] && [ -d "$TDIR" ]; then
		rm -rf "$TDIR"
	fi
	return 0
}

@test "behavioral: pending marker blocks a mutating Bash command" {
	_setup_pending_repo
	rc=$(_run_guard '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}')
	[ "$rc" = deny ]
}

# --- v0.33.0 (#223) Layer 0 age-based self-heal -----------------------------
@test "Layer 0: ABANDONED (non-HEAD) marker older than 2 days is auto-removed and the call ALLOWED" {
	_setup_pending_repo
	# Replace the HEAD marker with an ABANDONED non-HEAD sha (genuine cruft) and
	# age it past the 2-day threshold (portable -t CCYYMMDDhhmm).
	rm -f "$TDIR"/.claude/.session-state/ship-cycle/*.phase1-directive.txt
	_seed_abandoned_marker
	find "$TDIR/.claude/.session-state/ship-cycle" -name '*.phase1-directive.txt' \
		-exec touch -t 202001010000 {} +
	# CR #223: assert the hook contract DIRECTLY — status is 0 (allow path) AND
	# the stdout payload carries NO deny decision (not just the reduced string).
	_run_guard_raw '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'
	[ "$status" -eq 0 ]
	[[ $output != *'"permissionDecision":"deny"'* ]]
	# Self-healed: the aged abandoned marker is gone (Layer 0 rm'd it).
	run ls "$TDIR"/.claude/.session-state/ship-cycle/
	[ "$status" -eq 0 ]
	[[ $output != *.phase1-directive.txt* ]]
}

@test "Layer 0: a fresh marker (sha == HEAD) is NOT age-removed and still DENIES" {
	_setup_pending_repo
	# CR-CLI r5: _setup_pending_repo seeds the marker at SHA == HEAD with a fresh
	# mtime (~now), so the retention asserted here is the COMBINED fresh + HEAD-
	# guard path (the AGED-but-HEAD case is the separate live-round test below). A
	# non-HEAD marker can't isolate "pure age": Layer 1 #174 reachability also
	# keeps a real ancestor, and a fake sha hits Layer 1's error path.
	# CR #223: assert the real hook contract — exit 0 (deny is JSON+exit0, NOT a
	# non-zero rc) AND the raw stdout carries the deny payload.
	_run_guard_raw '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
	# Boundary: Layer 0 must NOT nuke a fresh marker (mtime ~now).
	run ls "$TDIR"/.claude/.session-state/ship-cycle/*.phase1-directive.txt
	[ "$status" -eq 0 ]
	[[ $output == *.phase1-directive.txt* ]]
}

@test "Layer 0: an AGED marker whose sha == current HEAD is NOT age-pruned (live-round protection, #223)" {
	# CR #223 (major): age-ALONE would self-heal away a LIVE round paused over a
	# long weekend (>48h) whose marker sha IS the current HEAD, silently un-gating
	# Edit/Write/commit. The HEAD-guard must KEEP such a marker (Layers 1/2 then
	# correctly retain it — no origin/main ancestry, reachable from HEAD) so the
	# call still DENIES even though the marker is >2 days old.
	_setup_pending_repo # marker sha == HEAD
	find "$TDIR/.claude/.session-state/ship-cycle" -name '*.phase1-directive.txt' \
		-exec touch -t 202001010000 {} +
	_run_guard_raw '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
	# The HEAD marker must still be present — NOT age-pruned.
	run ls "$TDIR"/.claude/.session-state/ship-cycle/*.phase1-directive.txt
	[ "$status" -eq 0 ]
	[[ $output == *.phase1-directive.txt* ]]
	# And the KEPT marker is specifically the HEAD one (_setup_pending_repo
	# seeds sha == HEAD), proving the HEAD-guard — not some unrelated retention.
	head_sha=$(git -C "$TDIR" rev-parse HEAD)
	[[ $output == *"${head_sha}.phase1-directive.txt"* ]]
}

@test "behavioral: read-only git diff is ALLOWED while pending (#191)" {
	_setup_pending_repo
	rc=$(_run_guard '{"tool_name":"Bash","tool_input":{"command":"git diff main..HEAD"}}')
	[ "$rc" = allow ]
}

@test "behavioral: read-only cat/grep/find/ls allowed while pending (#191)" {
	_setup_pending_repo
	# NB: rg dropped from the allowlist in r2 (--pre exec); grep covers search.
	for c in "cat foo.txt" "grep -n pat file" "find . -name foo.sh" "ls -la" "git log --oneline -3" "head -5 x" "tail -20 y" "wc -l z" "semgrep scan --config=auto f.sh"; do
		rc=$(_run_guard "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}")
		[ "$rc" = allow ] || {
			echo "expected ALLOW for: $c (got rc=$rc)" >&2
			false
		}
	done
}

@test "behavioral: read-verb WITH file redirect is DENIED (not really read-only)" {
	_setup_pending_repo
	rc=$(_run_guard '{"tool_name":"Bash","tool_input":{"command":"cat foo > out.txt"}}')
	[ "$rc" = deny ]
	rc=$(_run_guard '{"tool_name":"Bash","tool_input":{"command":"grep x f >> log.txt"}}')
	[ "$rc" = deny ]
}

@test "behavioral: read-verb with harmless 2>/dev/null discard is ALLOWED" {
	_setup_pending_repo
	rc=$(_run_guard '{"tool_name":"Bash","tool_input":{"command":"git diff main..HEAD 2>/dev/null"}}')
	[ "$rc" = allow ]
}

@test "behavioral: mutating git verbs (push/add/reset) DENIED while pending" {
	_setup_pending_repo
	for c in "git push" "git add ." "git reset --hard" "rm -rf x" "mv a b"; do
		rc=$(_run_guard "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}")
		[ "$rc" = deny ] || {
			echo "expected DENY for: $c (got rc=$rc)" >&2
			false
		}
	done
}

@test "behavioral: Edit/Write always denied while pending (never read-only)" {
	_setup_pending_repo
	rc=$(_run_guard '{"tool_name":"Edit","tool_input":{"file_path":"x","old_string":"a","new_string":"b"}}')
	[ "$rc" = deny ]
	rc=$(_run_guard '{"tool_name":"Write","tool_input":{"file_path":"x","content":"c"}}')
	[ "$rc" = deny ]
}

@test "behavioral: Agent + Skill calls allowed (the firing path)" {
	_setup_pending_repo
	rc=$(_run_guard '{"tool_name":"Agent","tool_input":{"subagent_type":"pr-review-toolkit:code-reviewer"}}')
	[ "$rc" = allow ]
	rc=$(_run_guard '{"tool_name":"Skill","tool_input":{"command":"security-review"}}')
	[ "$rc" = allow ]
}

@test "behavioral: no marker → everything allowed (guard inactive)" {
	TDIR=$(mktemp -d -t p1dir-noguard.XXXXXX)
	(cd "$TDIR" && git init -q && git config user.email t@t.t && git config user.name t && git commit -q --allow-empty -m init)
	rc=$(_run_guard '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}')
	[ "$rc" = allow ]
}

# --- v0.30.E r2 (#191 Phase 1): compound-command bypass denials -------------
# R1 agents proved a read verb at the FRONT laundered a mutation behind it.
# Each of these MUST deny — a leading read verb does not make the whole
# command read-only.

@test "behavioral: read && mutate is DENIED (chaining)" {
	_setup_pending_repo
	for c in "git diff && git push" "cat f && rm x" "ls && git commit -m y" "git log || git push"; do
		d=$(_run_guard "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}")
		[ "$d" = deny ] || {
			echo "expected DENY for chain: $c (got $d)" >&2
			false
		}
	done
}

@test "behavioral: separator/pipe variants DENIED (; with space, | tee, | sh)" {
	_setup_pending_repo
	for c in "ls ; rm -rf x" "git diff | tee out.txt" "git log | sh" "ls | xargs rm"; do
		d=$(_run_guard "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}")
		[ "$d" = deny ] || {
			echo "expected DENY for sep/pipe: $c (got $d)" >&2
			false
		}
	done
}

@test "behavioral: command/process substitution DENIED" {
	_setup_pending_repo
	for c in 'cat $(rm -rf x)' 'git diff $(git push)' "cat <(rm f)"; do
		d=$(_run_guard "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}")
		[ "$d" = deny ] || {
			echo "expected DENY for subst: $c (got $d)" >&2
			false
		}
	done
}

@test "behavioral: git --output write flag DENIED (writes without redirect)" {
	_setup_pending_repo
	[ "$(_run_guard '{"tool_name":"Bash","tool_input":{"command":"git diff --output=stolen.txt"}}')" = deny ]
	[ "$(_run_guard '{"tool_name":"Bash","tool_input":{"command":"git log --output=x main..HEAD"}}')" = deny ]
}

@test "behavioral: find write/exec actions DENIED" {
	_setup_pending_repo
	for c in "find . -delete" "find . -name x -exec rm {} ;" "find . -fprintf /tmp/z %p"; do
		d=$(_run_guard "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}")
		[ "$d" = deny ] || {
			echo "expected DENY for find-write: $c (got $d)" >&2
			false
		}
	done
}

@test "behavioral: read-only find (no write action) still ALLOWED" {
	_setup_pending_repo
	d=$(_run_guard '{"tool_name":"Bash","tool_input":{"command":"find . -name foo.sh -print"}}')
	[ "$d" = allow ]
}

# --- v0.30.E r2 (#191 Phase 1): exec-flag bypass denials --------------------
# Adversarial re-verification found `rg --pre <cmd>` execs arbitrary code with
# NO shell metachar. rg is dropped from the allowlist + a standing --pre /
# --hostname-bin screen denies any future re-add.

@test "behavioral: rg --pre / --hostname-bin exec flags DENIED" {
	_setup_pending_repo
	for c in "rg --pre rm pat ." "rg --pre=rm pat ." "rg --hostname-bin /tmp/x pat ."; do
		d=$(_run_guard "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}")
		[ "$d" = deny ] || {
			echo "expected DENY for exec-flag: $c (got $d)" >&2
			false
		}
	done
}

@test "behavioral: bare rg is now DENIED (dropped from allowlist); grep covers search" {
	_setup_pending_repo
	[ "$(_run_guard '{"tool_name":"Bash","tool_input":{"command":"rg pattern src"}}')" = deny ]
	# grep remains the allowlisted Bash search verb (no exec flag).
	[ "$(_run_guard '{"tool_name":"Bash","tool_input":{"command":"grep -rn pattern src"}}')" = allow ]
}

@test "behavioral: git --output-indicator READ flag still ALLOWED (not --output)" {
	_setup_pending_repo
	d=$(_run_guard '{"tool_name":"Bash","tool_input":{"command":"git diff --output-indicator-new=+ main..HEAD"}}')
	[ "$d" = allow ]
}

@test "behavioral: git grep DENIED (--open-files-in-pager execs a pager)" {
	_setup_pending_repo
	# git grep dropped from the allowlist — its -O/--open-files-in-pager flag
	# execs a pager command. Plain grep (no such flag) remains allowed.
	[ "$(_run_guard '{"tool_name":"Bash","tool_input":{"command":"git grep --open-files-in-pager=rm pat"}}')" = deny ]
	[ "$(_run_guard '{"tool_name":"Bash","tool_input":{"command":"git grep pattern"}}')" = deny ]
}

# --- v0.30.E r3 (#191 Phase 1): exec/write-flag screens (final sweep) --------
# Final adversarial sweep found more write-via-flag vectors with NO shell
# metachar: find -rm (bfs alias for -delete), semgrep --autofix (in-place
# rewrite), semgrep --*-output= (writes a file). All MUST deny.

@test "behavioral: find -rm (bfs delete alias) DENIED" {
	_setup_pending_repo
	[ "$(_run_guard '{"tool_name":"Bash","tool_input":{"command":"find . -name f -rm"}}')" = deny ]
}

@test "behavioral: semgrep --autofix / --*-output / --allow-local-builds DENIED" {
	_setup_pending_repo
	for c in "semgrep scan --autofix --config=auto" "semgrep scan --json-output=x.json --config=auto" "semgrep scan --sarif-output=x --config=auto" "semgrep scan --allow-local-builds --config=auto"; do
		d=$(_run_guard "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}")
		[ "$d" = deny ] || {
			echo "expected DENY for semgrep-write: $c (got $d)" >&2
			false
		}
	done
}

@test "behavioral: plain semgrep scan (read-only analysis) still ALLOWED" {
	_setup_pending_repo
	[ "$(_run_guard '{"tool_name":"Bash","tool_input":{"command":"semgrep scan --config=auto --error f.sh"}}')" = allow ]
}

# --- v0.31 #225 (silent-failure-hunter #4): sanctioned test-runner carve-out ---
# A Phase-1 REVIEW subagent must be able to verify behaviorally (run the
# sanctioned test runners) WITHOUT PHASE1_DIRECTIVE_GUARD_SKIP. The runners are
# read-only w.r.t. source (they write only gitignored verification artifacts
# under .claude/ + temp dirs).

@test "behavioral: sanctioned test runners ALLOWED while pending (#225)" {
	_setup_pending_repo
	# Direct, with-arg, -touched, ./-prefixed, bash-prefixed, bash ./-prefixed,
	# and env-prefixed (BASE=main … is the documented scope-vs-main form).
	for c in "scripts/test.sh" "scripts/test.sh .claude/tests/hooks/x.bats" "scripts/test-touched.sh" "./scripts/test-touched.sh" "bash scripts/test.sh" "bash scripts/test-touched.sh" "bash ./scripts/test.sh" "BASE=main scripts/test-touched.sh"; do
		d=$(_run_guard "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}")
		[ "$d" = allow ] || {
			echo "expected ALLOW for test runner: $c (got $d)" >&2
			false
		}
	done
}

@test "behavioral: a test runner laundering a mutation is still DENIED (#225)" {
	_setup_pending_repo
	# The compound/redirect screen still applies — the carve-out is for the
	# single simple runner invocation only.
	for c in "scripts/test.sh; rm -rf x" "scripts/test-touched.sh && git push" "bash scripts/test.sh > out.txt"; do
		d=$(_run_guard "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}")
		[ "$d" = deny ] || {
			echo "expected DENY for laundered runner: $c (got $d)" >&2
			false
		}
	done
}

@test "behavioral: test-runner near-misses (prefix/suffix/interpreter) are DENIED (#225)" {
	_setup_pending_repo
	# Pin the CMD_SEGMENT_ANCHOR + CMD_SEGMENT_END boundaries the carve-out relies
	# on: a suffix past `.sh`, a non-separator prefix, a path-traversal prefix, and
	# a non-bash interpreter must all still DENY (else the allowlist over-matches).
	for c in "scripts/test.shX" "scripts/test.sh.bak" "xscripts/test.sh" "../scripts/test.sh" "sh scripts/test.sh"; do
		d=$(_run_guard "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}")
		[ "$d" = deny ] || {
			echo "expected DENY for near-miss: $c (got $d)" >&2
			false
		}
	done
}

# --- v0.34.81 (#2427) stamp-less self-heal ----------------------------------
# A marker whose state JSON EXISTS but lacks phase1_directive_protocol was
# written by a STALE driver (a frozen repo-root scripts/ship-pr-cycle.sh
# predating the #2237 stamp) — an unstamped directive ship-cycle-guard rejects,
# and every mechanical clear is itself directive-guard-blocked: the unrecoverable
# 2026-06-16 deadlock. The self-heal clears such a marker EVEN when it is the
# HEAD marker the other layers retain (Layer 0 skips HEAD; Layers 1/2 keep a
# reachable sha) — age-guarded >1 min on the marker mtime to skip the write-
# order race (driver writes the marker, then the state-JSON stamp ms later).

@test "self-heal: stamp-less state JSON + AGED marker is self-CLEARED and the call ALLOWED (#2427)" {
	_setup_pending_repo
	sha=$(git -C "$TDIR" rev-parse HEAD)
	# State JSON present but WITHOUT phase1_directive_protocol = stale-driver.
	printf '{"stage":"phase1"}\n' >"$TDIR/.claude/.session-state/ship-cycle/${sha}.json"
	# Age the marker past the 1-min write-order-race guard (portable -t CCYYMMDDhhmm).
	touch -t 202001010000 "$TDIR/.claude/.session-state/ship-cycle/${sha}.phase1-directive.txt"
	_run_guard_raw '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'
	[ "$status" -eq 0 ]
	[[ $output != *'"permissionDecision":"deny"'* ]]
	# Self-healed: the stamp-less marker (the HEAD marker the other layers keep) is gone.
	run ls "$TDIR"/.claude/.session-state/ship-cycle/
	[ "$status" -eq 0 ]
	[[ $output != *.phase1-directive.txt* ]]
}

@test "self-heal: STAMPED state JSON (protocol present) marker is KEPT and still DENIES (#2427)" {
	_setup_pending_repo
	sha=$(git -C "$TDIR" rev-parse HEAD)
	# Valid stamped directive (correct driver) — must NOT be self-healed even aged.
	printf '{"stage":"phase1","phase1_directive_protocol":1}\n' >"$TDIR/.claude/.session-state/ship-cycle/${sha}.json"
	touch -t 202001010000 "$TDIR/.claude/.session-state/ship-cycle/${sha}.phase1-directive.txt"
	_run_guard_raw '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
	run ls "$TDIR"/.claude/.session-state/ship-cycle/*.phase1-directive.txt
	[ "$status" -eq 0 ]
	[[ $output == *.phase1-directive.txt* ]]
}

@test "self-heal: stamp-less but FRESH marker (<1 min) is KEPT — write-order-race guard (#2427)" {
	_setup_pending_repo
	sha=$(git -C "$TDIR" rev-parse HEAD)
	printf '{"stage":"phase1"}\n' >"$TDIR/.claude/.session-state/ship-cycle/${sha}.json"
	# Marker mtime is ~now (fresh, set by _setup_pending_repo) — do NOT age it; a
	# sub-minute unstamped marker may be a correct driver mid-write.
	_run_guard_raw '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
	run ls "$TDIR"/.claude/.session-state/ship-cycle/*.phase1-directive.txt
	[ "$status" -eq 0 ]
	[[ $output == *.phase1-directive.txt* ]]
}

@test "self-heal: corrupt/unreadable state JSON + aged marker is KEPT (fail-closed) (#2427)" {
	_setup_pending_repo
	sha=$(git -C "$TDIR" rev-parse HEAD)
	# Invalid JSON → jq fails → _slh_proto != "absent" → KEEP (fail-closed; only a
	# READABLE JSON that genuinely lacks the field self-heals).
	printf 'not json {{{\n' >"$TDIR/.claude/.session-state/ship-cycle/${sha}.json"
	touch -t 202001010000 "$TDIR/.claude/.session-state/ship-cycle/${sha}.phase1-directive.txt"
	_run_guard_raw '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
	run ls "$TDIR"/.claude/.session-state/ship-cycle/*.phase1-directive.txt
	[ "$status" -eq 0 ]
	[[ $output == *.phase1-directive.txt* ]]
}
