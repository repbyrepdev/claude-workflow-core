#!/bin/bash
set -euo pipefail
# v4.27 (#632) item #18 — pre-commit hook: refuse commit when staged files
# match an `owns_files` glob in .claude/dogfood-registry.yml AND the
# matching dogfood target hasn't passed within the last 1h.
#
# Mirrors bats-gate.sh's pattern: hash-keyed JSONL log
# (.claude/logs/dogfood-runs.jsonl), content-stable cache lookups, 1h TTL.
# Survives compaction + new sessions because the log is on-disk.
#
# Bypass:
#   DOGFOOD_GATE_SKIP=1 (audit-logged + counted via session-start)
#   DOGFOOD_GATE_AUTORUN=0 (v4.30.C #798) — refuse on drift instead of
#     auto-running scripts/dogfood.sh inside the gate. Default (=1)
#     auto-runs all drifted targets + accepts when all pass.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
LOG="$REPO_ROOT/.claude/logs/dogfood-runs.jsonl"

# v4.28-W3-C r5 (#676 expansion): single-pane sentinel — every gate
# appends to .claude/.session-state/hook-output-pending.txt on FAIL.
LIB_HOOK_ACK="$(dirname "$0")/../_lib/hook-ack.sh"
# shellcheck source=../_lib/hook-ack.sh
[ -f "$LIB_HOOK_ACK" ] && source "$LIB_HOOK_ACK"
_dogfood_gate_ack() {
	# r7 Option E: per-ack diagnostic artifact instead of pinning to the
	# shared registry.yml (which collapsed per-target accountability —
	# r6 CR finding). Each drift target gets its own diagnostic file.
	local reason=${1:-drift}
	local target_name="${2:-unknown}"
	if command -v hook_ack_diagnostic_write >/dev/null 2>&1 &&
		command -v hook_ack_append >/dev/null 2>&1; then
		local diag
		diag=$(hook_ack_diagnostic_write "dogfood-gate" "$reason:$target_name" \
			"# dogfood-gate refused the commit.

Target:    $target_name
Reason:    $reason

# What this means
The dogfood target '$target_name' has staged content but no recent
(< 1h) PASS at that content's fingerprint. The registry is at:
  .claude/dogfood-registry.yml

# How to fix
Run the target manually + verify the wire really works:
  scripts/dogfood.sh --target $target_name

# Bypass (audit-logged)
DOGFOOD_GATE_SKIP=1 DOGFOOD_GATE_SKIP_REASON=\"<text>\" git commit ...
")
		[ -n "$diag" ] && hook_ack_append "dogfood-gate" "$reason:$target_name" "$diag"
	fi
}

# CR #634 round 4 finding 17: read registry from staged INDEX, not worktree.
# Worktree reads let an unstaged registry edit (removing a glob) bypass the
# gate at commit time. Use `git show :<path>` to read the indexed blob.
REGISTRY_PATH=".claude/dogfood-registry.yml"
REGISTRY=$(mktemp -t "dogfood-registry.XXXXXX")
trap 'rm -f "$REGISTRY"' EXIT INT TERM
# CR Phase-1 silent-failure-hunter #1: distinguish "no commits / not staged"
# from "staged but empty blob". The latter is an attack surface: an operator
# could `:>registry && git add registry` to silently disable enforcement.
# Strategy: try index first; if index path exists check for content; only
# fall back to worktree when the path simply isn't tracked yet (fresh repo).
if git -C "$REPO_ROOT" ls-files --error-unmatch -- "$REGISTRY_PATH" >/dev/null 2>&1; then
	# Path IS in index. Read the staged content.
	if ! git -C "$REPO_ROOT" show ":$REGISTRY_PATH" >"$REGISTRY" 2>/dev/null; then
		echo "dogfood-gate: failed to read staged registry — refusing commit" >&2
		exit 1
	fi
	# Empty staged blob = explicit attack signal. Fail closed.
	if [ ! -s "$REGISTRY" ]; then
		echo "dogfood-gate: staged registry is empty — refusing commit" >&2
		echo "  An empty registry would disable enforcement. Restore content or override:" >&2
		echo '  DOGFOOD_GATE_SKIP=1 DOGFOOD_GATE_SKIP_REASON="<text>" git commit ...' >&2
		exit 1
	fi
else
	# Not in index — true greenfield (no commits) OR file just doesn't exist.
	# Fall back to worktree only when no tracked file at all.
	if [ -f "$REPO_ROOT/$REGISTRY_PATH" ]; then
		cp "$REPO_ROOT/$REGISTRY_PATH" "$REGISTRY"
	else
		exit 0
	fi
fi

# CR #634 round 2 finding 41: check DOGFOOD_GATE_SKIP=1 BEFORE the deps
# check. Previously the missing-tool path exited 1 before the skip branch,
# so the documented escape hatch was unreachable in exactly the case it
# was needed (operator's tool got uninstalled, blocking ALL commits).
if [ "${DOGFOOD_GATE_SKIP:-0}" = "1" ]; then
	reason="${DOGFOOD_GATE_SKIP_REASON:-(no reason)}"
	echo "dogfood-gate: DOGFOOD_GATE_SKIP=1 reason=\"$reason\" — bypassing" >&2
	mkdir -p "$REPO_ROOT/.claude/logs"
	# jq may be missing here too — write directly without jq dep.
	if command -v jq >/dev/null 2>&1; then
		# v0.30.A (#187): capture jq output to var so a jq failure (rc!=0)
		# can't leave a partial line on disk. Shell `>>` opens fd with
		# O_APPEND; write(2) to an O_APPEND-opened regular file is atomic
		# for sizes ≤ PIPE_BUF (4096 bytes typical on Linux/macOS).
		_dgf_line=$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg r "$reason" \
			'{ts:$ts, action:"bypass", reason:$r}' 2>/dev/null) || _dgf_line=""
		if [ -n "$_dgf_line" ]; then
			printf '%s\n' "$_dgf_line" >>"$REPO_ROOT/.claude/logs/dogfood-skip.jsonl" 2>/dev/null || true
		fi
	else
		# CR #634 round 3 finding 34: JSON-escape $reason. Without escaping,
		# a reason containing `"`, `\`, or newlines corrupts the .jsonl log.
		# Portable escape: backslash → \\, quote → \", newline → \n, tab → \t.
		escaped=$(printf '%s' "$reason" |
			sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' |
			awk 'BEGIN{ORS=""} {if (NR>1) print "\\n"; print}' |
			tr '\t' ' ' | tr -d '\r')
		printf '{"ts":"%s","action":"bypass","reason":"%s","note":"jq-missing"}\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$escaped" \
			>>"$REPO_ROOT/.claude/logs/dogfood-skip.jsonl" 2>/dev/null || true
	fi
	exit 0
fi

# CR #634 finding 25: fail closed when yq/jq missing. Previously this hook
# exited 0 silently — meaning uninstalling either tool would trivially
# bypass enforcement. Honor the env override above.
if ! command -v yq >/dev/null 2>&1; then
	echo "dogfood-gate: yq not installed — required for registry parsing." >&2
	echo "  Install: brew install yq" >&2
	echo '  Override: DOGFOOD_GATE_SKIP=1 DOGFOOD_GATE_SKIP_REASON="<text>" git commit ...' >&2
	exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
	echo "dogfood-gate: jq not installed — required for log parsing." >&2
	echo "  Install: brew install jq" >&2
	echo '  Override: DOGFOOD_GATE_SKIP=1 DOGFOOD_GATE_SKIP_REASON="<text>" git commit ...' >&2
	exit 1
fi

# Get staged file list (relative to REPO_ROOT).
staged=()
while IFS= read -r line; do
	[ -n "$line" ] && staged+=("$line")
done < <(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)
[ "${#staged[@]}" -gt 0 ] || exit 0

# For each target in the registry, check if any staged file matches its
# owns_files globs. If yes, look up the log for a recent matching pass.
# CR #634 round 4 finding 87: fail closed on malformed registry. The
# previous `|| echo 0` silently disabled enforcement when yq parse failed.
if ! target_count=$(yq '.targets | length' "$REGISTRY" 2>&1); then
	echo "dogfood-gate: registry parse failed: $target_count" >&2
	echo "  Fix .claude/dogfood-registry.yml or override: DOGFOOD_GATE_SKIP=1 ..." >&2
	exit 1
fi
[[ $target_count =~ ^[0-9]+$ ]] || target_count=0
[ "$target_count" -gt 0 ] || exit 0

# CR Phase-1 silent-failure #2 / code-simplifier #1: hoist sha256 portable
# detection ABOVE the per-target loop so the function is defined once and
# the missing-tool exit fires before any target processes content.
# CR #634 round 4 finding 142: sha256sum is GNU-only. macOS ships
# `shasum -a 256` instead. Use either, fail-closed if neither.
if command -v sha256sum >/dev/null 2>&1; then
	_sha256_cmd() { sha256sum; }
elif command -v shasum >/dev/null 2>&1; then
	_sha256_cmd() { shasum -a 256; }
else
	echo "dogfood-gate: no sha256 tool (need sha256sum or shasum) — refusing commit" >&2
	echo "  Install: brew install coreutils  # provides gsha256sum/sha256sum" >&2
	exit 1
fi

# v4.28-W5 #867 CR-CLI r1: hoist source out of the per-target loop.
# The lib is idempotent (sourcing twice is harmless), but re-reading
# the file on every target iteration is wasted I/O. Source once here
# so `dogfood_per_file_hash` is available to all iterations.
# shellcheck source=../_lib/dogfood-fingerprint.sh
. "$(dirname "$0")/../_lib/dogfood-fingerprint.sh"

drift_targets=""
i=0
while [ "$i" -lt "$target_count" ]; do
	target_name=$(yq ".targets[$i].name" "$REGISTRY" 2>/dev/null)
	# shellcheck disable=SC2015  # intentional: precondition gate with explicit continue
	[ -n "$target_name" ] && [ "$target_name" != "null" ] || {
		i=$((i + 1))
		continue
	}

	# Read owns_files patterns for this target.
	patterns=()
	while IFS= read -r line; do
		[ -n "$line" ] && patterns+=("$line")
	done < <(yq ".targets[$i].owns_files[]" "$REGISTRY" 2>/dev/null | tr -d '"')

	# Check if any staged file matches any pattern.
	matched=0
	for pattern in "${patterns[@]}"; do
		[ -z "$pattern" ] && continue
		for sf in "${staged[@]}"; do
			# shellcheck disable=SC2053
			if [[ $sf == $pattern ]]; then
				matched=1
				break 2
			fi
		done
	done
	[ "$matched" = "0" ] && {
		i=$((i + 1))
		continue
	}

	# Target was triggered. Look for a recent pass in the log.
	if [ ! -f "$LOG" ]; then
		drift_targets="${drift_targets}  - ${target_name} (no run logged)"$'\n'
		i=$((i + 1))
		continue
	fi
	# CR #634 finding 92: bind recent-pass lookup to the staged content
	# fingerprint, not just a 1h time window. Otherwise a `dogfood.sh
	# --target X` from 30 minutes ago at content hash A unlocks a commit
	# at content hash B. Compute fingerprint over the matching staged
	# files (registry's owns_files patterns) and require log entry to
	# carry the same fingerprint.
	# CR #634 round 3 finding 124: fingerprint the STAGED snapshot via the
	# git index (`git ls-files -s` blob SHAs), not the worktree files.
	# Without this, unstaged edits after `git add` would change the
	# worktree-derived fingerprint even though the staged content didn't.
	# Also include the relative path so renames-with-identical-content don't
	# collide with the original.
	matched_paths=()
	for pattern in "${patterns[@]}"; do
		[ -z "$pattern" ] && continue
		for sf in "${staged[@]}"; do
			# shellcheck disable=SC2053
			if [[ $sf == $pattern ]]; then
				matched_paths+=("$sf")
			fi
		done
	done
	# Fingerprint = sha256 of sorted "<blob-sha> <relpath>" lines from the
	# git index. blob-sha already covers content; including relpath
	# disambiguates renamed-but-identical-content cases.
	# CR Phase-1 silent-failure #7: validate staged_fp shape post-pipeline
	# to detect silent failures (e.g. ls-files emitted nothing, sha256
	# computed empty input → all-zero hash colliding with legacy entries).
	#
	# ★ STAGED_FP DRIFT WARNING (mirror in scripts/dogfood.sh) ★
	# Both this reader and scripts/dogfood.sh writer source
	# `.claude/_lib/dogfood-fingerprint.sh` and call the SAME
	# `dogfood_per_file_hash` helper. Prior contract was "byte-for-byte
	# identical inline pipeline + edit both in the same commit + run
	# round-trip bats". v4.28-W5 #771/#840 replaced that with a shared
	# lib so drift is impossible. The per-file hash uses semantic-hash
	# (shfmt -mn normalization) for shell files so shfmt/semgrep auto-
	# fixes inherit a recent dogfood pass instead of triggering retry
	# loops; non-shell files keep the original `git show :path` +
	# sha256 byte-exact path.
	# v4.28-W5 #867 CR-CLI r1: lib hoisted out of this loop — sourced
	# once above at line ~167 so it doesn't re-read on every target
	# iteration. `dogfood_per_file_hash` is available here.
	staged_fp=$(printf '%s\n' "${matched_paths[@]}" | sort -u |
		while IFS= read -r p; do
			[ -z "$p" ] && continue
			dogfood_per_file_hash "$REPO_ROOT" "$p"
		done | _sha256_cmd | awk '{print $1}')
	if ! [[ $staged_fp =~ ^[0-9a-f]{64}$ ]]; then
		echo "dogfood-gate: staged_fp computation produced invalid hash — refusing commit" >&2
		echo "  This is a fingerprint pipeline bug. Override: DOGFOOD_GATE_SKIP=1 ..." >&2
		exit 1
	fi
	# CR #634 round 2 finding 128: previous `|| echo 0` fallback silently
	# disabled the 1h freshness check (cutoff=0 → jq's `>= 0` matches any
	# historical pass). Fail closed if neither BSD nor GNU date works.
	cutoff=$(date -u -v-1H +%s 2>/dev/null || date -u -d '1 hour ago' +%s 2>/dev/null || true)
	if ! [[ ${cutoff:-} =~ ^[0-9]+$ ]] || [ "$cutoff" -le 0 ]; then
		echo "dogfood-gate: cannot compute 1h cutoff on this platform; refusing commit." >&2
		echo '  Override: DOGFOOD_GATE_SKIP=1 DOGFOOD_GATE_SKIP_REASON="<text>" git commit ...' >&2
		exit 1
	fi
	# Require: target=match AND status=ok AND ts>=cutoff. Prefer entries
	# carrying .staged_fp matching the current staged content (CR #634
	# finding 92). Fall back to time-only match for legacy entries without
	# .staged_fp (e.g., logs written before the writer was updated).
	found_with_fp=$(jq -rs --arg t "$target_name" --argjson c "$cutoff" --arg fp "$staged_fp" \
		'[.[] | select(.target == $t and .status == "ok" and ((.ts | fromdateiso8601? // 0) >= $c) and (.staged_fp // "") == $fp)] | length' \
		"$LOG" 2>/dev/null || echo 0)
	if [ "$found_with_fp" != "0" ]; then
		i=$((i + 1))
		continue
	fi
	# CR #634 round 3 finding 148: legacy time-only fallback removed by
	# default — it reopens the stale-pass bypass for any log entry without
	# .staged_fp. Operators migrating from pre-fingerprint logs can opt
	# in via DOGFOOD_LEGACY_LOG_OK=1 (one-time migration flag).
	if [ "${DOGFOOD_LEGACY_LOG_OK:-0}" = "1" ]; then
		found_legacy=$(jq -rs --arg t "$target_name" --argjson c "$cutoff" \
			'[.[] | select(.target == $t and .status == "ok" and ((.ts | fromdateiso8601? // 0) >= $c) and (.staged_fp // "") == "")] | length' \
			"$LOG" 2>/dev/null || echo 0)
		if [ "$found_legacy" = "0" ]; then
			drift_targets="${drift_targets}  - ${target_name} (no recent pass at current staged content)"$'\n'
		fi
	else
		# Strict mode (default): no fingerprint match = no pass.
		drift_targets="${drift_targets}  - ${target_name} (no recent pass at current staged content)"$'\n'
	fi
	i=$((i + 1))
done

if [ -n "$drift_targets" ]; then
	# v4.30.C #798: auto-run drifted targets instead of refusing outright.
	# Operator was going to invoke scripts/dogfood.sh manually anyway;
	# the gate already knows which targets drifted. Run them; refuse
	# only if the run actually fails. Override: DOGFOOD_GATE_AUTORUN=0
	# keeps the old refuse-only path.
	if [ "${DOGFOOD_GATE_AUTORUN:-1}" = "1" ]; then
		echo "dogfood-gate: auto-running drifted targets:" >&2
		printf '%s' "$drift_targets" >&2
		echo "" >&2
		autorun_failed=0
		failed_targets=""
		while IFS= read -r line; do
			[ -z "$line" ] && continue
			target=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*-[[:space:]]+([^[:space:]]+).*/\1/')
			[ -z "$target" ] && continue
			if ! scripts/dogfood.sh --target "$target" >&2; then
				autorun_failed=$((autorun_failed + 1))
				failed_targets="${failed_targets}  - ${target}"$'\n'
			fi
		done <<<"$drift_targets"
		if [ "$autorun_failed" -eq 0 ]; then
			echo "dogfood-gate: auto-run cleared all drifted targets" >&2
			exit 0
		fi
		echo "" >&2
		echo "dogfood-gate: $autorun_failed target(s) FAILED auto-run:" >&2
		printf '%s' "$failed_targets" >&2
		echo "" >&2
		echo '  Override: DOGFOOD_GATE_SKIP=1 DOGFOOD_GATE_SKIP_REASON="<text>" git commit ...' >&2
		while IFS= read -r line; do
			[ -z "$line" ] && continue
			target=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*-[[:space:]]+([^[:space:]]+).*/\1/')
			_dogfood_gate_ack "autorun-failed" "$target"
		done <<<"$failed_targets"
		exit 1
	fi
	echo "dogfood-gate: $(printf '%s' "$drift_targets" | grep -c .) target(s) need dogfood verification:" >&2
	printf '%s' "$drift_targets" >&2
	echo "" >&2
	echo "  Run: scripts/dogfood.sh --target <name>" >&2
	echo '  Or override: DOGFOOD_GATE_SKIP=1 DOGFOOD_GATE_SKIP_REASON="<text>" git commit ...' >&2
	# Append each drift target to sentinel so single-pane sees them.
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		# Extract target name from "  - <name> (...)" prefix.
		target=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*-[[:space:]]+([^[:space:]]+).*/\1/')
		_dogfood_gate_ack "drift" "$target"
	done <<<"$drift_targets"
	exit 1
fi

exit 0
