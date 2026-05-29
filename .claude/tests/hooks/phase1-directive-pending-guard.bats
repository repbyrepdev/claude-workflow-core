#!/usr/bin/env bats
# covers: hooks/phase1-directive-pending-guard.sh
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

@test "behavioral: read-only git diff is ALLOWED while pending (#191)" {
	_setup_pending_repo
	rc=$(_run_guard '{"tool_name":"Bash","tool_input":{"command":"git diff main..HEAD"}}')
	[ "$rc" = allow ]
}

@test "behavioral: read-only cat/grep/rg/find/ls allowed while pending (#191)" {
	_setup_pending_repo
	for c in "cat foo.txt" "grep -n pat file" "rg pattern" "find . -name '*.sh'" "ls -la" "git log --oneline -3" "head -5 x" "tail -20 y" "wc -l z" "semgrep scan --config=auto f.sh"; do
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
