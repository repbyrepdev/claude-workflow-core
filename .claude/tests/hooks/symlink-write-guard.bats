#!/usr/bin/env bats
# covers: hooks/symlink-write-guard.sh
#
# Two clobbers in one session, same shape both times — a write whose path
# resolved THROUGH A SYMLINK into something real, succeeding silently:
#
#   1. `printf '...' > "$dir/brew"` with $dir=/opt/homebrew/bin. The entry is
#      a symlink into the Cellar; the redirect followed it and replaced the
#      real brew binary with a 3-line stub. brew then just went quiet.
#   2. A bats test writing `.claude/scripts/cr/thread-reply.sh` to build a
#      fixture. `.claude/scripts` is a SYMLINK to the repo's scripts/ dir, so
#      it replaced a 292-line production helper — and the test then passed
#      against its own stub.
#
# Both are in here as literal regressions. The allow-cases matter just as
# much: a guard that refuses ordinary work gets bypassed, and then it guards
# nothing.

setup() {
	PLUGIN=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	GUARD="$PLUGIN/hooks/symlink-write-guard.sh"
	[ -x "$GUARD" ]
	command -v jq >/dev/null
	TEST_TMP=$(mktemp -d -t symguard.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	case "${TEST_TMP:-}" in
	*/symguard.*) rm -rf "$TEST_TMP" ;;
	esac
}

_guard() { # $1 = command string
	jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}' >"$TEST_TMP/p.json"
	run bash -c "cd '$PLUGIN' && bash '$GUARD' < '$TEST_TMP/p.json'"
}

_guard_write() { # $1 = file_path (Write/Edit tool shape)
	jq -nc --arg f "$1" '{tool_name:"Write", tool_input:{file_path:$f}}' >"$TEST_TMP/p.json"
	run bash -c "cd '$PLUGIN' && bash '$GUARD' < '$TEST_TMP/p.json'"
}

_denied() {
	# BOTH halves of the PreToolUse contract: `deny()` emits the decision
	# string AND exits 0. Asserting only the string let a hook that emitted a
	# correct deny and then exited nonzero — a broken hook Claude Code treats
	# as an error rather than a refusal — pass as a working guard.
	case "$output" in
	*'"permissionDecision":"deny"'*) ;;
	*)
		echo "expected a deny DECISION; got: $output"
		return 1
		;;
	esac
	[ "$status" -eq 0 ] || {
		echo "deny must exit 0 (the JSON is the signal, not the status); got $status: $output"
		return 1
	}
}

_allowed() {
	[ "$status" -eq 0 ] || {
		echo "guard exited $status — a crash is not permission: $output"
		return 1
	}
	case "$output" in
	*'"permissionDecision":"deny"'*)
		echo "expected this to be allowed; got: $output"
		return 1
		;;
	esac
	return 0
}

@test "REGRESSION: a relative write to .claude/scripts is refused" {
	# The exact command that replaced thread-reply.sh with a stub.
	_guard "cat > .claude/scripts/cr/thread-reply.sh"
	_denied
}

@test "REGRESSION: a write to /opt/homebrew/bin is refused" {
	# The exact shape that replaced brew.
	_guard "printf 'x' > /opt/homebrew/bin/brew"
	_denied
}

@test ".claude/hooks and .claude/_lib are refused too" {
	# All three are symlinks; guarding only the one that bit us would leave
	# the other two live.
	_guard "cat > .claude/hooks/some-hook.sh"
	_denied
	_guard "echo x > .claude/_lib/some-lib.sh"
	_denied
}

@test "a >> append through the symlink is refused, not just >" {
	# Appending to a production script is no less destructive than truncating.
	_guard "echo 'rm -rf /' >> .claude/scripts/cr/thread-reply.sh"
	_denied
}

@test "tee through the symlink is refused" {
	_guard "printf 'x' | tee .claude/scripts/foo.sh"
	_denied
	_guard "printf 'x' | tee -a .claude/hooks/foo.sh"
	_denied
}

@test "ALLOWED: a fixture under an absolute temp path" {
	# The correct form for a test stub. Refusing it would push authors to
	# bypass the guard, which is worse than not having one.
	_guard "cat > /var/folders/ab/T/t.99/.claude/scripts/cr/x.sh"
	_allowed
	_guard "cat > /tmp/fixture/.claude/hooks/x.sh"
	_allowed
}

@test "ALLOWED: editing the real script by its real path" {
	# Changing production ON PURPOSE, where the diff shows it.
	_guard "cat > scripts/cr/thread-reply.sh"
	_allowed
	_guard "cat > hooks/skill-bypass-guard.sh"
	_allowed
}

@test "ALLOWED: ordinary writes inside the repo and to logs" {
	_guard "echo x > .claude/logs/run.jsonl"
	_allowed
	_guard "jq . < a.json > b.json"
	_allowed
}

@test "ALLOWED: reading through the symlink is untouched" {
	# Only writes are the hazard; a read is how the mirrored paths are meant
	# to be used.
	_guard "cat .claude/scripts/cr/thread-reply.sh"
	_allowed
	_guard "bash .claude/hooks/review-log.sh phase1 1 x 0 ok"
	_allowed
}

@test "the Write/Edit shape is inspected — with the ABSOLUTE path it really sends" {
	# The first version of this test passed a RELATIVE file_path, a shape
	# Claude Code's Write/Edit tools never produce: they require absolute
	# paths. Rule A only matched relative ones, and Rule B then resolved the
	# symlink to a location inside the repo and ALLOWED it. So the guard did
	# not block incident #2 by the route incident #2 actually took, and the
	# test claiming to cover it exercised a shape that cannot occur.
	_guard_write "$PLUGIN/.claude/scripts/cr/thread-reply.sh"
	_denied
	# ...while editing the real path stays allowed — that is ordinary work.
	_guard_write "$PLUGIN/scripts/cr/thread-reply.sh"
	_allowed
}

@test "an absolute redirect through the symlink is refused too" {
	# Same hole, Bash shape: $PWD-built paths are how bats fixtures normally
	# construct targets.
	_guard "cat > $PLUGIN/.claude/hooks/some-hook.sh"
	_denied
}

@test "a SINGLE-quoted PATH target is refused, not just a bare one" {
	# The extractor stripped only a leading double quote, so a single-quoted
	# target kept its apostrophe, failed the absolute test, and skipped Rule B
	# entirely — incident #1 with different quoting.
	_guard "printf x > '/opt/homebrew/bin/brew'"
	_denied
}

@test "the bypass token must be a PREFIX, not text inside the payload" {
	# Unanchored, the token disabled the guard whenever it merely appeared
	# anywhere in the command — so writing that very text to a production file
	# was what let the write through.
	_guard "echo SYMLINK_WRITE_GUARD_SKIP=1 > .claude/scripts/cr/x.sh"
	_denied
}

@test "a bypass WRITES an audit row — the header promises it" {
	# The header and the deny text both said "audit-logged" while neither
	# bypass path recorded anything. A silent bypass of a guard that exists
	# because two silent overwrites went unnoticed is the same bug again.
	local log="$PLUGIN/.claude/logs/pipeline-skip.jsonl"
	local before=0
	[ -f "$log" ] && before=$(grep -c 'symlink-write-guard-skip' "$log" 2>/dev/null || echo 0)
	_guard "SYMLINK_WRITE_GUARD_SKIP=1 SYMLINK_WRITE_GUARD_SKIP_REASON=under-test cat > .claude/scripts/cr/x.sh"
	_allowed
	local after=0
	[ -f "$log" ] && after=$(grep -c 'symlink-write-guard-skip' "$log" 2>/dev/null || echo 0)
	[ "$after" -gt "$before" ] || {
		echo "the bypass wrote no audit row (before=$before after=$after)"
		return 1
	}
}

@test "an absolute write into a NOT-YET-EXISTING .claude subdir is refused" {
	# The parent-exists test came first, so a path whose directory had not
	# been created yet resolved to nothing and fell through to ALLOWED — and
	# the relative case arm never saw it, because a leading `/` matches the
	# absolute arm first. Creating a subdirectory is the ordinary way a
	# fixture gets built, so the hole sat on the most likely route.
	_guard_write "$PLUGIN/.claude/scripts/brand-new-dir/x.sh"
	_denied
}

@test "dd of= is inspected like a redirect" {
	# Same write, different verb. It was a documented gap purely because
	# nobody had written the two lines.
	_guard "dd if=/dev/zero of=.claude/scripts/cr/x.sh bs=1 count=1"
	_denied
}

@test "the inline bypass works and is named in the denial" {
	_guard "SYMLINK_WRITE_GUARD_SKIP=1 cat > .claude/scripts/cr/x.sh"
	_allowed
	_guard "cat > .claude/scripts/cr/x.sh"
	# _denied FIRST. These two tests inspect the denial TEXT; without
	# establishing that a denial happened at all, a guard that crashed with a
	# stack trace mentioning the bypass token would satisfy them.
	_denied
	case "$output" in
	*SYMLINK_WRITE_GUARD_SKIP*) ;;
	*)
		echo "the denial must name its own bypass; got: $output"
		return 1
		;;
	esac
}

@test "the denial explains the FIX, not just the refusal" {
	# A guard that only says no teaches nothing and gets bypassed.
	_guard "cat > .claude/scripts/cr/x.sh"
	_denied
	case "$output" in
	*TEST_TMP*) ;;
	*)
		echo "expected the fixture remedy; got: $output"
		return 1
		;;
	esac
	case "$output" in
	*"real path"* | *"production file"*) ;;
	*)
		echo "expected the edit-production remedy; got: $output"
		return 1
		;;
	esac
}
