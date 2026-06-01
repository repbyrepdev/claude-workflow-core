#!/usr/bin/env bats
# covers: hooks/log-retention-session.sh
#
# #250-wiring: the daily-throttled SessionStart runner for log-retention.sh.
# Runs a COPY of the hook inside a throwaway git repo with a STUBBED
# scripts/maintain/log-retention.sh, so REPO_ROOT resolves into the tmpdir and
# the real repo's logs are never pruned. The stub records that it ran (via
# RETENTION_RAN) + honors an injected rc (STUB_RC).

setup() {
	HOOK_SRC="${BATS_TEST_DIRNAME}/../../../hooks/log-retention-session.sh"
	[ -f "$HOOK_SRC" ]
	TMP=$(mktemp -d -t logret-sess.XXXXXX) || return 1
	git -C "$TMP" init -q # deterministic REPO_ROOT = $TMP
	mkdir -p "$TMP/hooks" "$TMP/scripts/maintain"
	cp "$HOOK_SRC" "$TMP/hooks/log-retention-session.sh"
	chmod +x "$TMP/hooks/log-retention-session.sh"
	HOOK="$TMP/hooks/log-retention-session.sh"
	RAN="$TMP/ran-sentinel"
	cat >"$TMP/scripts/maintain/log-retention.sh" <<'EOF'
#!/bin/bash
: >"${RETENTION_RAN:-/dev/null}"
exit "${STUB_RC:-0}"
EOF
	chmod +x "$TMP/scripts/maintain/log-retention.sh"
	MARKER="$TMP/.claude/logs/last-run/log-retention.ts"
}

teardown() {
	[ -n "${TMP:-}" ] && [ -d "$TMP" ] && [[ $TMP == */logret-sess.* ]] && rm -rf "$TMP"
	return 0
}

@test "first run (no marker) executes log-retention + stamps the marker" {
	run env RETENTION_RAN="$RAN" "$HOOK"
	[ "$status" -eq 0 ]
	[ -f "$RAN" ]
	[ -f "$MARKER" ]
}

@test "throttled: a fresh marker skips the run" {
	mkdir -p "$(dirname "$MARKER")"
	: >"$MARKER" # mtime = now ⇒ within the 24h window
	run env RETENTION_RAN="$RAN" "$HOOK"
	[ "$status" -eq 0 ]
	[ ! -f "$RAN" ]
}

@test "throttle expired (THROTTLE_S=0) runs even with a marker present" {
	mkdir -p "$(dirname "$MARKER")"
	: >"$MARKER"
	run env RETENTION_RAN="$RAN" LOG_RETENTION_THROTTLE_S=0 "$HOOK"
	[ "$status" -eq 0 ]
	[ -f "$RAN" ]
}

@test "missing retention script is a no-op (exit 0, nothing run)" {
	rm -f "$TMP/scripts/maintain/log-retention.sh"
	run env RETENTION_RAN="$RAN" "$HOOK"
	[ "$status" -eq 0 ]
	[ ! -f "$RAN" ]
}

@test "retention failure still exits 0 + warns + stamps marker (no re-fire storm)" {
	run env RETENTION_RAN="$RAN" STUB_RC=3 "$HOOK"
	[ "$status" -eq 0 ]
	[ -f "$RAN" ]
	[ -f "$MARKER" ]
	[[ $output == *"rc=3"* ]]
}

@test "LOG_RETENTION_SESSION_SKIP=1 is a no-op" {
	run env RETENTION_RAN="$RAN" LOG_RETENTION_SESSION_SKIP=1 "$HOOK"
	[ "$status" -eq 0 ]
	[ ! -f "$RAN" ]
}
