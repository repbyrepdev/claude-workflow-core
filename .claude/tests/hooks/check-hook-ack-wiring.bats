#!/usr/bin/env bats
# covers: hooks/check-hook-ack-wiring.sh
#
# v0.31 #228: the SessionStart advisory must scan the REPO's SOURCE hooks dir
# (resolved via REPO_ROOT), not $(dirname "$0") — which, wired via the pinned
# plugin-cache path, is the FROZEN cache copy, blind to source-only hooks added
# after the pinned version. #228 r1 (silent-failure-hunter): plugin vs consumer
# is disambiguated by the PLUGIN MARKER (.claude-plugin/plugin.json), so a
# consumer with an unrelated top-level hooks/ scans .claude/hooks/, not hooks/.
#
# Each test runs the REAL hook with cwd inside a synthetic repo (so REPO_ROOT
# resolves there) + HOME pointed at a fixture settings.json, and asserts the
# advisory sees the synthetic repo's hooks via the DISCRIMINATING signal — the
# orphan's basename in the output (the generic "wiring incomplete" header is NOT
# discriminating, #228 r1 pr-test-analyzer, so it is not asserted on).

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/check-hook-ack-wiring.sh"
	[ -f "$HOOK" ]
	command -v jq >/dev/null
	command -v git >/dev/null
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

# $1=layout(plugin|consumer)  → sets TMP to a synthetic repo of that layout.
_mk_repo() {
	TMP=$(mktemp -d -t ackrepo.XXXXXX) || return 1
	(
		cd "$TMP" || exit 1
		git init -q
		git config user.email t@t.t
		git config user.name t
	)
	if [ "$1" = "plugin" ]; then
		mkdir -p "$TMP/.claude-plugin" "$TMP/hooks" # plugin marker + source hooks/
		printf '{"name":"x","version":"0.0.0"}\n' >"$TMP/.claude-plugin/plugin.json"
		HD="$TMP/hooks"
	else
		mkdir -p "$TMP/.claude/hooks" # consumer layout (no plugin.json, no top-level hooks/)
		HD="$TMP/.claude/hooks"
	fi
}

_seed_hook() {
	# $1=basename  $2=event  $3=auto_register(true|false)  [$4=dir, default $HD]
	local dir=${4:-$HD}
	cat >"$dir/$1" <<EOF
#!/bin/bash
# event: $2
# auto-register: $3
exit 0
EOF
}

_run() { run bash -c "cd '$TMP' && HOME='$FAKEHOME' ${1:-} bash '$HOOK' 2>&1"; }

@test "plugin layout: scans REPO_ROOT/hooks and flags an unregistered orphan (#228)" {
	_mk_repo plugin
	_seed_hook "zz-orphan-test.sh" "SessionStart" "true"
	# If the hook still scanned $(dirname "$0") (the real plugin hooks/) it could
	# not see this synthetic file, so detecting it proves the REPO_ROOT scan.
	_run
	[ "$status" -eq 0 ]
	[[ $output == *"zz-orphan-test.sh"* ]]
}

@test "consumer layout: scans REPO_ROOT/.claude/hooks (no plugin marker / top-level hooks) (#228 r1)" {
	_mk_repo consumer
	_seed_hook "zz-consumer-orphan.sh" "SessionStart" "true"
	_run
	[ "$status" -eq 0 ]
	[[ $output == *"zz-consumer-orphan.sh"* ]]
}

@test "opt-out + positive control: auto-register:false NOT flagged, true IS (same scan) (#228 r1)" {
	_mk_repo plugin
	_seed_hook "zz-orphan-true.sh" "SessionStart" "true"
	_seed_hook "zz-optout-false.sh" "SessionStart" "false"
	_run
	[ "$status" -eq 0 ]
	# Positive control proves the scan REACHED the dir (true orphan flagged)...
	[[ $output == *"zz-orphan-true.sh"* ]]
	# ...so the false one's absence is the opt-out skip, not an unscanned dir.
	[[ $output != *"zz-optout-false.sh"* ]]
}

@test "advisory is silenced by HOOK_ACK_WIRING_CHECK_SKIP=1 (#228)" {
	_mk_repo plugin
	_seed_hook "zz-orphan-test.sh" "SessionStart" "true"
	_run "HOOK_ACK_WIRING_CHECK_SKIP=1"
	[ "$status" -eq 0 ]
	[[ $output != *"zz-orphan-test.sh"* ]]
}
