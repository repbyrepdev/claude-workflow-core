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
	case "$output" in
	*deny* | *REFUSED*) return 0 ;;
	esac
	echo "expected a denial; got: $output"
	return 1
}

_allowed() {
	case "$output" in
	*deny* | *REFUSED*)
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

@test "the Write/Edit tool shape is inspected, not just Bash" {
	# file_path, not command — the harness's own file tools can clobber the
	# same way.
	_guard_write ".claude/scripts/cr/thread-reply.sh"
	_denied
	_guard_write "scripts/cr/thread-reply.sh"
	_allowed
}

@test "the inline bypass works and is named in the denial" {
	_guard "SYMLINK_WRITE_GUARD_SKIP=1 cat > .claude/scripts/cr/x.sh"
	_allowed
	_guard "cat > .claude/scripts/cr/x.sh"
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
