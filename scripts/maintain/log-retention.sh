#!/bin/bash
set -euo pipefail
# v4.28-W3-C: centralized log/state retention pruner.
#
# Reads .claude/log-retention.yml as SSOT for which paths to prune at
# what retention. Replaces the prior ad-hoc situation where each log
# grew unbounded (only cache_prune at 30d existed).
#
# Pruning is fail-soft: missing files or jq parse errors on a single
# line don't abort the whole run. Each path's outcome is reported.
#
# Usage:
#   .claude/scripts/maintain/log-retention.sh           # apply all
#   .claude/scripts/maintain/log-retention.sh --dry-run # report-only
#
# Cron: fire daily via launchd / cron.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
SSOT="$REPO_ROOT/.claude/log-retention.yml"
DRY_RUN=0

while [ "$#" -gt 0 ]; do
	case "$1" in
	--dry-run)
		DRY_RUN=1
		shift
		;;
	-h | --help)
		sed -n '4,15p' "${BASH_SOURCE[0]}"
		exit 0
		;;
	*)
		echo "log-retention: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

[ -f "$SSOT" ] || {
	echo "log-retention: SSOT $SSOT missing" >&2
	exit 2
}
command -v yq >/dev/null 2>&1 || {
	echo "log-retention: yq required" >&2
	exit 2
}
# r5 CR fix #1: jq is required by _prune_jsonl + _prune_json_dir. Without
# this guard, _prune_json_dir's `jq -r '.ts // ""' ... 2>/dev/null` silently
# returns empty for every file and the SKIP-on-missing-ts branch fires for
# all of them — making the missing-jq dependency look like "every file
# legitimately lacks a ts" rather than "tooling broken".
command -v jq >/dev/null 2>&1 || {
	echo "log-retention: jq required" >&2
	exit 2
}

# Iterate retention entries via yq + per-entry case dispatch.
ENTRY_COUNT=$(yq -r '.retention | length' "$SSOT")
[ "$ENTRY_COUNT" = "0" ] && {
	echo "log-retention: no entries in $SSOT — nothing to prune" >&2
	exit 0
}

_prune_jsonl() {
	# $1 = file path, $2 = retention_days
	local file=$1 days=$2
	[ -f "$file" ] || return 0
	local cutoff
	cutoff=$(date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		date -u -d "${days} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || {
		echo "  log-retention: ERROR: cannot compute cutoff for $file (date tool variant?)" >&2
		return 1
	}
	local before after tmp jq_err jq_rc
	before=$(wc -l <"$file" | tr -d ' ')
	if [ "$DRY_RUN" = "1" ]; then
		# r5 CR fix #2: mirror apply-mode's guarded jq pattern. Was
		# `2>/dev/null | wc -l` — jq parse failure on bad JSON went
		# silent and `after` reported "0 pruned" indistinguishable
		# from a clean ledger. Now: rc-check jq + surface stderr.
		jq_err=$(mktemp)
		jq_rc=0
		after=$(jq -c --arg cutoff "$cutoff" 'select(.ts >= $cutoff)' "$file" 2>"$jq_err" | wc -l | tr -d ' ') || jq_rc=$?
		if [ "$jq_rc" -ne 0 ]; then
			echo "  log-retention: WARN: dry-run jq prune failed for $file (rc=$jq_rc):" >&2
			cat "$jq_err" >&2
			rm -f "$jq_err"
			return 1
		fi
		rm -f "$jq_err"
		echo "  [dry-run] $file: $before → $after ($((before - after)) pruned)"
		return 0
	fi
	# r1 follow-up SFH CRITICAL: prior `jq ... && mv` silently no-op'd on
	# any jq parse failure — function reported "0 pruned" indistinguishable
	# from clean state. Now rc-check + surface jq stderr; refuse to mv on
	# failure rather than mask it.
	tmp=$(mktemp) || {
		echo "  log-retention: ERROR: mktemp failed for $file" >&2
		return 1
	}
	jq_err=$(mktemp)
	jq_rc=0
	jq -c --arg cutoff "$cutoff" 'select(.ts >= $cutoff)' "$file" >"$tmp" 2>"$jq_err" || jq_rc=$?
	if [ "$jq_rc" -ne 0 ]; then
		echo "  log-retention: WARN: jq prune failed for $file (rc=$jq_rc):" >&2
		cat "$jq_err" >&2
		rm -f "$tmp" "$jq_err"
		return 1
	fi
	# mv failure path: log + return 1. The fail-soft contract is enforced
	# at the CALLER level — the main loop wraps each invocation with
	# `|| entry_rc=$?` and accumulates into `loop_rc` (see end of file).
	# So this function returning 1 does NOT abort the script; the loop
	# continues to the next entry and the script exits with loop_rc.
	if ! mv "$tmp" "$file"; then
		echo "  log-retention: ERROR: mv $tmp -> $file failed" >&2
		rm -f "$tmp" "$jq_err"
		return 1
	fi
	rm -f "$jq_err"
	after=$(wc -l <"$file" | tr -d ' ')
	echo "  $file: $before → $after ($((before - after)) pruned)"
}

_prune_json_dir() {
	# $1 = dir, $2 = retention_days. Each .json file has a top-level `ts`.
	local dir=$1 days=$2
	[ -d "$dir" ] || return 0
	local cutoff
	# r2 sfh #10: align with _prune_jsonl's fail-loud cutoff handling
	# (was silent `return 0` on date-tool failure, indistinguishable
	# from "no work done"). Now: emit ERROR + return 1 so cron logs
	# show the actual cause.
	cutoff=$(date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		date -u -d "${days} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || {
		echo "  log-retention: ERROR: cannot compute cutoff for $dir (date tool variant?)" >&2
		return 1
	}
	local pruned=0 kept=0 skipped=0
	# v4.28-W4 (#681 F10): capture find stderr to a temp + WARN if
	# traversal hit an error (perm denied on subdir, broken symlink,
	# etc). Was `2>/dev/null` swallow → operator saw clean kept/pruned
	# counts, trusted them, but some paths grew unbounded.
	local find_err
	find_err=$(mktemp)
	while IFS= read -r -d '' f; do
		local ts
		ts=$(jq -r '.ts // ""' "$f" 2>/dev/null || echo "")
		# r1 fix: missing/unparseable ts → SKIP + warn (don't auto-delete).
		# Prior fail-closed behavior surprise-pruned files dropped into the
		# tracked dir without `ts`. Now: only prune when ts is valid AND
		# older than cutoff.
		if [ -z "$ts" ]; then
			echo "  log-retention: skip $f (missing/unparseable ts)" >&2
			skipped=$((skipped + 1))
			continue
		fi
		if [[ "$ts" < "$cutoff" ]]; then
			if [ "$DRY_RUN" = "1" ]; then
				pruned=$((pruned + 1))
			else
				rm -f "$f" && pruned=$((pruned + 1))
			fi
		else
			kept=$((kept + 1))
		fi
	done < <(find "$dir" -name '*.json' -type f -print0 2>"$find_err")
	if [ -s "$find_err" ]; then
		echo "  log-retention: WARN: find traversal in $dir surfaced errors:" >&2
		cat "$find_err" >&2
	fi
	rm -f "$find_err"
	# r5 CR fix #3: `${DRY_RUN:+...}` expands when DRY_RUN is non-empty,
	# but DRY_RUN defaults to "0" (also non-empty). So live runs were
	# falsely labeled "(dry-run)" — operator-confusion bug corrupting
	# audit logs. Use explicit string compare instead.
	local dry_run_suffix=""
	[ "$DRY_RUN" = "1" ] && dry_run_suffix=" (dry-run)"
	echo "  $dir: $kept kept, $pruned pruned, $skipped skipped (no-ts)${dry_run_suffix}"
}

_prune_dir() {
	# $1 = path (must be a directory), $2 = retention_days,
	# $3 = scope_to_branch ("true"/"false")
	# r5 CSimp #2: was `_prune_file_or_dir(path, days, format, scope)`
	# but the body only handled format=dir; the `file` branch silently
	# no-op'd. SSOT YAML only ever lists jsonl/json/dir. Dropped the
	# unused `format` parameter + renamed.
	local path=$1 days=$2 scope=$3
	[ -d "$path" ] || return 0
	local cutoff_secs now
	now=$(date -u +%s)
	cutoff_secs=$((now - days * 86400))
	# Build set of branch-scoped SHAs when scope_to_branch=true.
	# r3 CR fix #6: capture git stderr so missing main / weird repo state
	# doesn't silently look the same as "no branch SHAs". On failure: warn
	# and continue with empty branch_shas (age-only scope).
	local branch_shas=""
	if [ "$scope" = "true" ]; then
		local git_err shas_out
		git_err=$(mktemp)
		shas_out=$(git -C "$REPO_ROOT" log --pretty=%H main..HEAD 2>"$git_err") || {
			# r4 CR fix: `_prune_dir` parameter is $path, not $dir
			# (the latter is local to `_prune_json_dir`). Under set -u
			# the prior $dir reference would abort on first invocation
			# with scope_to_branch=true when git fails.
			echo "  log-retention: WARN: git log main..HEAD failed for $path (continuing without branch-scope filter):" >&2
			cat "$git_err" >&2
			shas_out=""
		}
		rm -f "$git_err"
		branch_shas=$(printf '%s' "$shas_out" | tr '\n' ' ')
	fi
	local pruned=0 kept=0 skipped=0
	# v4.28-W4 (#681 F10): capture find stderr (mirrors _prune_json_dir).
	local find_err
	find_err=$(mktemp)
	while IFS= read -r -d '' f; do
		local fmtime fbase keep=0
		# r1 follow-up: align with _prune_json_dir's missing-data policy:
		# stat failure → SKIP+warn (don't auto-delete) instead of treating
		# as old. Symmetric semantics: "I don't know the timestamp" never
		# auto-prunes. Removing surprise-delete risk on transient stat
		# failures (perms, fs glitch, NFS hiccup).
		fmtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "")
		if [ -z "$fmtime" ]; then
			echo "  log-retention: skip $f (stat failed — keeping)" >&2
			skipped=$((skipped + 1))
			continue
		fi
		fbase=$(basename "$f")
		# Branch-scope: keep if filename starts with a branch SHA.
		if [ -n "$branch_shas" ]; then
			for s in $branch_shas; do
				case "$fbase" in "$s"*)
					keep=1
					break
					;;
				esac
			done
		fi
		# Age-scope: keep if mtime ≥ cutoff.
		if [ "$keep" = "0" ] && [ "$fmtime" -ge "$cutoff_secs" ]; then
			keep=1
		fi
		if [ "$keep" = "1" ]; then
			kept=$((kept + 1))
		else
			if [ "$DRY_RUN" = "1" ]; then
				pruned=$((pruned + 1))
			else
				rm -f "$f" && pruned=$((pruned + 1))
			fi
		fi
	done < <(find "$path" -type f -print0 2>"$find_err")
	if [ -s "$find_err" ]; then
		echo "  log-retention: WARN: find traversal in $path surfaced errors:" >&2
		cat "$find_err" >&2
	fi
	rm -f "$find_err"
	# r5 CR fix #3: same ${DRY_RUN:+...} bug as _prune_json_dir above.
	local dry_run_suffix=""
	[ "$DRY_RUN" = "1" ] && dry_run_suffix=" (dry-run)"
	echo "  $path: $kept kept, $pruned pruned, $skipped skipped (no-mtime)${dry_run_suffix}"
}

echo "=== log-retention: applying retention from $SSOT (dry-run=$DRY_RUN) ==="
i=0
# r3 CR fix #7: accumulate rc across the loop instead of letting set -e
# abort on the first prune-function `return 1`. Per script header lines 9-10
# ("Pruning is fail-soft: missing files or jq parse errors on a single line
# don't abort the whole run"), each entry's outcome must be reported and
# the loop must continue. Functions emit ERROR to stderr; we OR the rc into
# a final exit code so the operator still gets a non-zero signal at the end
# if any entry failed.
loop_rc=0
while [ "$i" -lt "$ENTRY_COUNT" ]; do
	path=$(I=$i yq -r ".retention[strenv(I) | tonumber].path" "$SSOT")
	format=$(I=$i yq -r ".retention[strenv(I) | tonumber].format" "$SSOT")
	days=$(I=$i yq -r ".retention[strenv(I) | tonumber].retention_days" "$SSOT")
	scope=$(I=$i yq -r ".retention[strenv(I) | tonumber].scope_to_branch // false" "$SSOT")
	# v4.28-W4 (#681 F18): yq returns the literal string "null" when a
	# field is missing (no `// default` fallback). Validate path/format
	# explicitly so a malformed entry surfaces loudly instead of silently
	# skipping (path missing → abs_path="$REPO_ROOT/null" → function
	# return 0 because not-a-dir; format missing → "unknown format
	# 'null'" → user-visible warn but loop continues with rc=0).
	# Validating loud here lets the operator find the broken SSOT entry.
	if [ -z "$path" ] || [ "$path" = "null" ]; then
		echo "  log-retention: ERROR: entry $i has missing/null path field — skipping" >&2
		loop_rc=2
		i=$((i + 1))
		continue
	fi
	if [ -z "$format" ] || [ "$format" = "null" ]; then
		echo "  log-retention: ERROR: entry $i ($path) has missing/null format field — skipping" >&2
		loop_rc=2
		i=$((i + 1))
		continue
	fi
	if [ -z "$days" ] || [ "$days" = "null" ]; then
		echo "  log-retention: ERROR: entry $i ($path) has missing/null retention_days field — skipping" >&2
		loop_rc=2
		i=$((i + 1))
		continue
	fi
	abs_path="$REPO_ROOT/$path"
	entry_rc=0
	case "$format" in
	jsonl) _prune_jsonl "$abs_path" "$days" || entry_rc=$? ;;
	json) _prune_json_dir "$abs_path" "$days" || entry_rc=$? ;;
	dir) _prune_dir "$abs_path" "$days" "$scope" || entry_rc=$? ;;
	*) echo "  $path: unknown format '$format' — skipping" >&2 ;;
	esac
	if [ "$entry_rc" -ne 0 ]; then
		loop_rc=$entry_rc
	fi
	i=$((i + 1))
done
echo "=== log-retention: done (rc=$loop_rc) ==="
exit "$loop_rc"
