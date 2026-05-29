#!/bin/bash
set -u
# v4.24-O (#601) — shared helpers for lint-run.jsonl log append + walk.
# Mirrors the bats-run.jsonl contract (.claude/logs/bats-run.jsonl) so the
# lint family and bats family share one pattern.
#
# Schema per entry:
#   {ts: "...", content_hash: "<sha256 of file content>", file: "<path>",
#    linter: "shellcheck|shfmt|yamllint|actionlint",
#    issues: <int>, status: "pass|fail", detail: "<short summary>"}
#
# v0.30.G (#194): the hash field is `content_hash`, NOT `sha`. It is a
# sha256 of FILE CONTENT, not a git commit sha — naming it `sha` conflated
# it with the commit-sha keys in review-log/*.jsonl + auto-triage.jsonl and
# invited a meaningless cross-log join. Renaming makes the distinction
# explicit. (One-time effect: pre-rename entries keyed on `sha` read as
# `unknown` → those files re-lint once on next commit. Harmless; rotation
# ages the old entries out.)
#
# Consumers:
#   - .claude/hooks/lint-shell.sh + lint-yaml.sh + lint-actions.sh (writers)
#   - .claude/pre-commit-hooks/lint-gate.sh (reader — blocks commit)
#   - .claude/hooks/lint-gate-bash.sh (reader — PreToolUse Bash gate)
#
# Nothing here is lint-specific beyond the `linter` field; adding new
# linters is just another write-site + another matcher in the gate.

# sha256 helper — GNU sha256sum or BSD shasum. Uses stdin.
_lint_sha256_stdin() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | awk '{print $1}'
	else
		echo "lint-log: missing sha256sum/shasum; gate will re-lint everything" >&2
		echo "no-hash-tool"
	fi
}

# sha256 of a file. Prints hash or empty.
lint_sha256_file() {
	local path=$1
	[ -f "$path" ] || {
		echo ""
		return 1
	}
	_lint_sha256_stdin <"$path"
}

# Append one {ts, sha, file, linter, issues, status, detail} entry.
# Args: $1=path $2=linter $3=lint_status (pass|fail) $4=issues_count $5=detail
# (zsh reserves `status` as a read-only $? mirror — avoid that local name.)
lint_log_append() {
	local lpath=$1 llinter=$2 lstatus=$3 lissues=$4 ldetail=$5
	local repo_root log hash ts
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
	log="$repo_root/.claude/logs/lint-run.jsonl"
	mkdir -p "$repo_root/.claude/logs" 2>/dev/null || true
	hash=$(lint_sha256_file "$lpath")
	[ -n "$hash" ] || hash="unknown"
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	# Use jq for safe JSON encoding (handles quotes/newlines in $ldetail).
	# Visible stderr on failure (disk full, permissions, jq crash): the
	# gate walks this log and falls back to "unknown" if the entry is
	# missing, triggering _lint_run_on_miss to re-run forever. A silent
	# append failure looks like a slow gate rather than a broken log.
	# NOTE: no `2>/dev/null` on jq — if it fails, jq's own error message
	# ends up on stderr alongside our diagnostic, surfacing useful detail.
	if ! jq -nc \
		--arg ts "$ts" --arg content_hash "$hash" --arg file "$lpath" \
		--arg linter "$llinter" --arg status "$lstatus" \
		--argjson issues "${lissues:-0}" \
		--arg detail "$ldetail" \
		'{ts:$ts, content_hash:$content_hash, file:$file, linter:$linter, status:$status, issues:$issues, detail:$detail}' \
		>>"$log"; then
		echo "lint-log: append failed for $lpath ($llinter) — check disk/permissions on $log" >&2
		return 1
	fi
}

# Walk the log for the LATEST entry matching (file, current-content-hash,
# linter). Returns:
#   0 + echoes "pass" if most recent matching entry is pass
#   1 + echoes "fail" if most recent matching entry is fail (also echoes detail on stderr)
#   2 + echoes "unknown" if no entry for that (file, hash, linter) tuple
# Args: $1=file $2=linter
lint_log_verdict() {
	local lpath=$1 llinter=$2
	local repo_root log hash
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
	log="$repo_root/.claude/logs/lint-run.jsonl"
	if [ ! -f "$log" ]; then
		echo "unknown"
		return 2
	fi
	hash=$(lint_sha256_file "$lpath")
	if [ -z "$hash" ] || [ "$hash" = "no-hash-tool" ]; then
		echo "unknown"
		return 2
	fi
	local last
	last=$(jq -c --arg f "$lpath" --arg h "$hash" --arg l "$llinter" \
		'select(.file==$f and .content_hash==$h and .linter==$l)' "$log" 2>/dev/null | tail -1)
	if [ -z "$last" ]; then
		echo "unknown"
		return 2
	fi
	local lstatus ldetail
	lstatus=$(printf '%s' "$last" | jq -r '.status')
	ldetail=$(printf '%s' "$last" | jq -r '.detail')
	if [ "$lstatus" = "pass" ]; then
		echo "pass"
		return 0
	fi
	echo "fail"
	[ -n "$ldetail" ] && echo "  $llinter: $ldetail" >&2
	return 1
}
