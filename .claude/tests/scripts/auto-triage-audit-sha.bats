#!/usr/bin/env bats
# covers: scripts/cr/auto-triage.sh

# v0.30.B (#188): regression guard for the audit-log sha join key added to
# auto-triage.sh. The full gh-driven path needs GraphQL mocking; this test
# isolates the audit-write jq transformation (the part #188 changed) and
# asserts the emitted entry carries the commit sha so auto-triage.jsonl can
# be joined with review-log/*.jsonl on the shared sha key.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/cr/auto-triage.sh"
	[ -f "$SCRIPT" ]
	command -v jq >/dev/null
}

# The exact jq filter auto-triage.sh uses for the audit-log write. Kept in
# sync with the source by the assertion below that greps the source for the
# same field list — if the source filter drifts, the drift-guard test fails.
_audit_jq() {
	jq -c --arg ts "$1" --arg pr "$2" --arg sha "$3" \
		'.[] | {ts: $ts, pr: $pr, sha: $sha, thread_id: .thread_id, path: .path, line: .line, class: .class, suggested_action: .suggested_action}'
}

@test "audit entry carries the sha join key" {
	classified='[{"thread_id":"PRRT_x","path":"a.sh","line":10,"class":"trivial","suggested_action":"edit-and-commit"}]'
	out=$(printf '%s' "$classified" | _audit_jq "2026-05-29T00:00:00Z" "192" "abc123def4567890abc123def4567890abc12345")
	# sha field present + full 40-char
	got_sha=$(printf '%s' "$out" | jq -r '.sha')
	[ "$got_sha" = "abc123def4567890abc123def4567890abc12345" ]
	[ "${#got_sha}" -eq 40 ]
	# other fields preserved
	[ "$(printf '%s' "$out" | jq -r '.pr')" = "192" ]
	[ "$(printf '%s' "$out" | jq -r '.class')" = "trivial" ]
	[ "$(printf '%s' "$out" | jq -r '.thread_id')" = "PRRT_x" ]
}

@test "empty sha tolerated (outside git repo)" {
	classified='[{"thread_id":"PRRT_y","path":"b.sh","line":1,"class":"real-but-in-scope","suggested_action":"review-then-apply"}]'
	out=$(printf '%s' "$classified" | _audit_jq "2026-05-29T00:00:00Z" "5" "")
	[ "$(printf '%s' "$out" | jq -r '.sha')" = "" ]
	# entry still valid JSON with all keys
	[ "$(printf '%s' "$out" | jq -r '.suggested_action')" = "review-then-apply" ]
}

@test "source still emits the sha field (drift guard)" {
	# If a future edit drops the sha field from the audit-write jq, this
	# fails — keeping the join-key contract locked to the source.
	grep -q 'sha: \$sha' "$SCRIPT"
}

@test "source audit-write field set matches the tested copy (full drift guard)" {
	# P1 R1 (pr-test-analyzer crit-3): the _audit_jq helper duplicates the
	# source jq filter. The single-token sha guard above only catches sha
	# removal; this asserts the FULL projected field set is still present in
	# source so a rename/drop of any other field (path/class/thread_id/...)
	# is caught too, keeping the copy honest.
	for field in 'ts: \$ts' 'pr: \$pr' 'sha: \$sha' 'thread_id: .thread_id' \
		'path: .path' 'line: .line' 'class: .class' 'suggested_action: .suggested_action'; do
		grep -q "$field" "$SCRIPT" || {
			echo "audit-write jq filter drifted: source missing '$field'" >&2
			echo "update _audit_jq in this test to match scripts/cr/auto-triage.sh" >&2
			false
		}
	done
}
