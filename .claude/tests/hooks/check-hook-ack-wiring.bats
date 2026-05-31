#!/usr/bin/env bats
# covers: hooks/check-hook-ack-wiring.sh
#
# v0.31 #228: the SessionStart advisory must scan the REPO's SOURCE hooks dir
# (resolved via REPO_ROOT), not $(dirname "$0") — which, when the hook is wired
# via the pinned plugin-cache path, is the FROZEN cache copy and therefore blind
# to source-only hooks added after the pinned version (the orphan class this
# advisory exists to catch). These tests run the REAL hook with cwd inside a
# synthetic repo so REPO_ROOT resolves there, and HOME pointed at a fixture
# settings.json, then assert the advisory sees the synthetic repo's hooks/.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/check-hook-ack-wiring.sh"
	[ -f "$HOOK" ]
	command -v jq >/dev/null
	command -v git >/dev/null
	TMP=$(mktemp -d -t ackwire.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# Synthetic repo with a SOURCE hooks/ dir (plugin layout).
	(
		cd "$TMP" || exit 1
		git init -q
		git config user.email t@t.t
		git config user.name t
		mkdir -p hooks
	)
	# Fixture HOME with an EMPTY hooks map → any auto-register hook is an orphan.
	FAKEHOME=$(mktemp -d -t ackhome.XXXXXX)
	mkdir -p "$FAKEHOME/.claude"
	printf '{"hooks":{}}\n' >"$FAKEHOME/.claude/settings.json"
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || true
	for d in "${TMP:-}" "${FAKEHOME:-}"; do
		[ -n "$d" ] && [ -d "$d" ] && [[ $d == */ack*.* ]] && rm -rf "$d"
	done
	return 0
}

_seed_hook() {
	# $1=basename  $2=event  $3=auto_register(true|false)
	cat >"$TMP/hooks/$1" <<EOF
#!/bin/bash
# event: $2
# auto-register: $3
exit 0
EOF
}

@test "advisory scans REPO_ROOT/hooks (source) and flags an unregistered auto-register hook (#228)" {
	_seed_hook "zz-orphan-test.sh" "SessionStart" "true"
	# cwd = synthetic repo ⇒ REPO_ROOT=$TMP ⇒ HOOKS_DIR=$TMP/hooks. If the hook
	# still scanned $(dirname "$0") (the real plugin hooks/) it would NOT see this
	# source-only file, so detecting it proves the REPO_ROOT scan.
	run bash -c "cd '$TMP' && HOME='$FAKEHOME' bash '$HOOK' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"zz-orphan-test.sh"* ]]
	[[ $output == *"wiring incomplete"* ]]
}

@test "advisory does NOT flag an auto-register:false hook (#228)" {
	_seed_hook "zz-optout-test.sh" "SessionStart" "false"
	run bash -c "cd '$TMP' && HOME='$FAKEHOME' bash '$HOOK' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output != *"zz-optout-test.sh"* ]]
}

@test "advisory is silenced by HOOK_ACK_WIRING_CHECK_SKIP=1 (#228)" {
	_seed_hook "zz-orphan-test.sh" "SessionStart" "true"
	run bash -c "cd '$TMP' && HOME='$FAKEHOME' HOOK_ACK_WIRING_CHECK_SKIP=1 bash '$HOOK' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output != *"zz-orphan-test.sh"* ]]
}
