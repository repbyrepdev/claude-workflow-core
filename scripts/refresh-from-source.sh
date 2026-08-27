#!/bin/bash
set -euo pipefail
# v0.21.0 (#151) — producer→consumer cascade primitive.
#
# Copies plugin SSOT files (every path in .claude/.source-hashes.json)
# into a consumer directory, honoring the consumer's local-overrides.yml
# skip-list. Atomic per-file. Re-runnable. Writes an audit log.
#
# Usage:
#   scripts/refresh-from-source.sh --consumer <name>          # by consumers.yml name
#   scripts/refresh-from-source.sh --consumer-path <path>     # by absolute path
#   scripts/refresh-from-source.sh --all-consumers            # iterate consumers.yml
#   scripts/refresh-from-source.sh --dry-run                  # show what would change
#   scripts/refresh-from-source.sh --files file1,file2        # subset
#
# Exit codes:
#   0 — refresh succeeded (or dry-run completed)
#   2 — precondition error (missing yq/jq, consumer not found, bad args,
#       parse failure on consumers.yml / local-overrides.yml /
#       .source-hashes.json)
#   3 — partial failure (some file copies failed mid-cascade — audit log
#       lists which; consumer left in inconsistent state, manual recovery
#       required). Takes precedence over 4: an inconsistent filesystem is
#       reported even when a covering test also drifted.
#   4 — mirror-test drift gate blocked (#2525): a replaced mirror hook's
#       consumer bats still assert the OLD contract. Refresh those tests in
#       this cascade PR, or override with REFRESH_DRIFT_GATE_SKIP=1.
#
# Deferred behaviors (gated on other unshipped subs):
#   - settings.json re-render via templates/settings.json.tpl — Sub 12
#   - Post-cascade hash-drift.sh --verify validation — Sub 10
#   Both are TODO no-ops here; the cascade copy logic stands alone.

CONSUMER=""
CONSUMER_PATH=""
ALL_CONSUMERS=0
DRY_RUN=0
FILES_FILTER=""

while [ $# -gt 0 ]; do
	case "$1" in
	--consumer)
		[ $# -lt 2 ] && {
			echo "refresh-from-source: --consumer requires a name" >&2
			exit 2
		}
		CONSUMER=$2
		shift 2
		;;
	--consumer-path)
		[ $# -lt 2 ] && {
			echo "refresh-from-source: --consumer-path requires a path" >&2
			exit 2
		}
		CONSUMER_PATH=$2
		shift 2
		;;
	--all-consumers)
		ALL_CONSUMERS=1
		shift
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--files)
		[ $# -lt 2 ] && {
			echo "refresh-from-source: --files requires a comma-separated list" >&2
			exit 2
		}
		FILES_FILTER=$2
		shift 2
		;;
	-h | --help)
		# Emit the leading comment header as usage text. Same pattern as
		# scripts/list-consumers.sh --help.
		awk '
			NR == 1 { next }
			/^set / { next }
			/^# (event|auto-register):/ { next }
			/^#/ { in_header = 1; sub(/^# ?/, ""); print; next }
			NF == 0 && in_header { print; next }
			in_header { exit }
		' "$0"
		exit 0
		;;
	*)
		echo "refresh-from-source: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

# Mutual-exclusion validation: exactly ONE of --consumer / --consumer-path
# / --all-consumers must be set.
N_TARGETS=0
[ -n "$CONSUMER" ] && N_TARGETS=$((N_TARGETS + 1))
[ -n "$CONSUMER_PATH" ] && N_TARGETS=$((N_TARGETS + 1))
[ "$ALL_CONSUMERS" -eq 1 ] && N_TARGETS=$((N_TARGETS + 1))
if [ "$N_TARGETS" -eq 0 ]; then
	echo "refresh-from-source: must specify ONE of --consumer / --consumer-path / --all-consumers" >&2
	exit 2
fi
if [ "$N_TARGETS" -gt 1 ]; then
	echo "refresh-from-source: --consumer / --consumer-path / --all-consumers are mutually exclusive" >&2
	exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REGISTRY="$PLUGIN_ROOT/.github/consumers.yml"
HASHES="$PLUGIN_ROOT/.claude/.source-hashes.json"

[ -f "$REGISTRY" ] || {
	echo "refresh-from-source: $REGISTRY missing (Sub 3 must ship)" >&2
	exit 2
}
[ -f "$HASHES" ] || {
	echo "refresh-from-source: $HASHES missing (Sub 2 must ship)" >&2
	exit 2
}

for cmd in yq jq shasum; do
	command -v "$cmd" >/dev/null 2>&1 || {
		echo "refresh-from-source: $cmd required" >&2
		exit 2
	}
done

# r3 silent-failure-hunter MEDIUM: initialize _in_flight_new BEFORE
# mktemp + trap registration. If mktemp fails (exit 2 below), the EXIT
# trap fires; under bash 3.2 + set -u, ${#_in_flight_new[@]} would
# crash if the array were unbound. Declared first → safe.
_in_flight_new=()
yq_err=""

# r2 code-reviewer + silent-failure-hunter HIGH: promote .new tracking
# to script scope so the trap can actually clean up. Prior r1 declared
# this array `local` inside _refresh_one_consumer with _cleanup_new
# unwired — dead code on SIGINT mid-cascade.
# shellcheck disable=SC2329,SC2317
_cleanup() {
	[ -n "$yq_err" ] && rm -f "$yq_err"
	# Iterate via index — `"${_in_flight_new[@]:-}"` with `set -e` causes
	# the empty-default empty-string iteration to fire `[ -n "" ]` which
	# returns rc=1 and aborts the trap. Indexed iteration sidesteps that.
	local i n f
	n=${#_in_flight_new[@]}
	for ((i = 0; i < n; i++)); do
		f=${_in_flight_new[$i]}
		if [ -n "$f" ] && [ -f "$f" ]; then
			rm -f "$f"
		fi
	done
}
trap _cleanup EXIT INT TERM HUP

yq_err=$(mktemp -t rfs-yq.XXXXXX) || {
	echo "refresh-from-source: mktemp failed" >&2
	exit 2
}

_resolve_consumer_path() {
	# Resolve --consumer <name> against consumers.yml; expand ~/.
	local name=$1
	local consumers_json
	if ! consumers_json=$(yq -o=json '.consumers' "$REGISTRY" 2>"$yq_err"); then
		echo "refresh-from-source: yq failed parsing $REGISTRY:" >&2
		cat "$yq_err" >&2
		exit 2
	fi
	local found match_count
	if ! found=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .local_path' <<<"$consumers_json" 2>"$yq_err"); then
		echo "refresh-from-source: jq failed querying consumers.yml:" >&2
		cat "$yq_err" >&2
		exit 2
	fi
	if [ -z "$found" ] || [ "$found" = "null" ]; then
		echo "refresh-from-source: consumer '$name' not found in $REGISTRY" >&2
		exit 2
	fi
	# r1 silent-failure-hunter MEDIUM: defend against duplicate-name
	# scenarios. consumers-schema-check already blocks duplicates, but
	# this gate doesn't run on remote/fetched consumers.yml.
	match_count=$(echo "$found" | wc -l | tr -d ' ')
	if [ "$match_count" -gt 1 ]; then
		echo "refresh-from-source: consumer '$name' has $match_count entries in $REGISTRY — refusing to guess" >&2
		exit 2
	fi
	# Expand leading ~. shellcheck flags SC2088 (tilde doesn't expand
	# in quotes) but the intent here is to match a LITERAL '~/' prefix
	# in YAML-loaded text, then strip it manually. Disable applies to
	# the whole function.
	# shellcheck disable=SC2088
	case "$found" in
	"~/"*) found="$HOME/${found#"~/"}" ;;
	"~") found="$HOME" ;;
	esac
	printf '%s' "$found"
}

_list_all_consumer_paths() {
	# Emit one consumer-path per line (expanded). r1 code-reviewer +
	# silent-failure-hunter dup: capture jq output explicitly before
	# iterating, so a jq pipeline failure surfaces (not gets swallowed
	# by while-read's rc).
	local consumers_json paths
	if ! consumers_json=$(yq -o=json '.consumers' "$REGISTRY" 2>"$yq_err"); then
		echo "refresh-from-source: yq failed parsing $REGISTRY:" >&2
		cat "$yq_err" >&2
		exit 2
	fi
	if ! paths=$(jq -r '.[].local_path' <<<"$consumers_json" 2>"$yq_err"); then
		echo "refresh-from-source: jq failed enumerating consumers.yml:" >&2
		cat "$yq_err" >&2
		exit 2
	fi
	[ -n "$paths" ] || {
		echo "refresh-from-source: $REGISTRY .consumers is empty" >&2
		exit 2
	}
	# shellcheck disable=SC2088
	while IFS= read -r p; do
		case "$p" in
		"~/"*) p="$HOME/${p#"~/"}" ;;
		"~") p="$HOME" ;;
		esac
		printf '%s\n' "$p"
	done <<<"$paths"
}

_load_overrides_paths() {
	# Read consumer's .claude/local-overrides.yml; emit one skip-path per
	# line. Empty if the file doesn't exist.
	local cpath=$1
	local ov="$cpath/.claude/local-overrides.yml"
	[ -f "$ov" ] || return 0
	if ! yq -r '.overrides // [] | .[].path' "$ov" 2>"$yq_err"; then
		echo "refresh-from-source: yq failed parsing $ov:" >&2
		cat "$yq_err" >&2
		exit 2
	fi
}

# #2525 mirror-test drift gate. Given a consumer path + the list of replaced
# mirror shell files (consumer-relative, e.g. .claude/hooks/phase1-scaler.sh),
# find the consumer's bats whose `# covers:` header names each replaced hook
# and run them. A red covering test means the cascade updated the hook but its
# consumer-local test still asserts the OLD contract — fail loud (return 1) so
# the operator refreshes the tests in the SAME cascade PR.
#
# Best-effort, not airtight. Covering-test discovery is a `# covers:` grep, so
# a header written in a shape the pattern misses is treated as "no coverage"
# (return 0). A covering test whose cases all `skip` (e.g. a `command -v yq ||
# skip` guard in a lean env) exits 0 but verifies NOTHING — it is reported as
# UNVERIFIED (a loud warning), never scored as a silent pass ("bats skip =
# pass" trap). Returns 0 (with a note) when it genuinely cannot verify — bats
# absent, no test tree, or no covering test found — and only returns 1 on an
# actual red covering test. Escape hatch for a genuine unrelated pre-existing
# failure: REFRESH_DRIFT_GATE_SKIP=1.
_mirror_test_drift_gate() {
	local cpath=$1 pver=$2
	shift 2
	local replaced=("$@")

	if [ "${REFRESH_DRIFT_GATE_SKIP:-0}" = "1" ]; then
		echo "  [drift-gate] skipped via REFRESH_DRIFT_GATE_SKIP=1" >&2
		return 0
	fi
	if ! command -v bats >/dev/null 2>&1; then
		echo "  [drift-gate] WARN: bats not installed — cannot verify mirror-test drift (install bats to enforce)" >&2
		return 0
	fi
	local tests_dir="$cpath/.claude/tests"
	[ -d "$tests_dir" ] || {
		echo "  [drift-gate] consumer keeps no .claude/tests tree — nothing to verify" >&2
		return 0
	}

	# Collect the consumer *.bats whose `# covers:` header names a replaced
	# hook by its SSOT-relative path (the consumer-relative path with the
	# `.claude/` prefix stripped, e.g. `hooks/foo.sh` or `skills/foo/run.sh`).
	# Matching the PATH, not just the basename, is required because skill
	# wrappers all share the basename `run.sh` — a basename match would
	# collide across skills and pull in unrelated bats. The path is
	# boundary-anchored between non-alphanumerics so `hooks/foo.sh` does not
	# spuriously match `otherhooks/foo.sh`, and it matches a `# covers:`
	# header written either with or without the `.claude/` prefix (both the
	# consumer `.claude/hooks/foo.sh` and the SSOT `hooks/foo.sh` forms end
	# with the same suffix). Restricted to *.bats so a stray non-bats file
	# carrying a `# covers:` line is never fed to `bats`. A grep ERROR (rc>1:
	# unreadable dir / bad pattern) is surfaced loudly, NOT swallowed as a
	# clean no-match (rc=1). Dedup via `sort -u` (no associative arrays —
	# bash 3.2, the macOS system bash). `replaced` is non-empty (caller
	# guard), so the loop never expands an empty array under set -u.
	# The discovery loop below runs inside a process substitution, so nothing
	# it assigns survives — an earlier fix moved `find` out of a NESTED
	# subshell but the enclosing one still swallowed the status. Failures
	# therefore travel as a sentinel LINE in the stream, which is the only
	# channel that crosses the boundary. Without it an unreadable candidate
	# or a failed enumeration reached the "nothing to verify" success path
	# and certified a refreshed mirror whose coverage was never checked.
	local _UNVERIFIED_MARK="!!drift-gate-coverage-unverified!!"
	local bats_to_run=() covering _coverage_unverified=0
	while IFS= read -r covering; do
		if [ "$covering" = "$_UNVERIFIED_MARK" ]; then
			_coverage_unverified=1
			continue
		fi
		[ -n "$covering" ] && bats_to_run+=("$covering")
	done < <(
		for hook in "${replaced[@]}"; do
			relpath=${hook#.claude/}
			esc=${relpath//./\\.}
			grc=0
			# (#2572) `covers:` ONLY — deliberately not `audits:`. A
			# repo-wide meta-lint sweeps many files without behaviourally
			# exercising any of them, so accepting one here would report a
			# replaced mirror hook as "verified" on the strength of a policy
			# scan that never ran it. audits: routes in test-touched (the
			# audit re-runs when its subjects change); it grants no credit.
			# FIRST covers: line per file only (`grep -m1`), matching every
			# other consumer of the header — test-touched.sh routing,
			# test.sh --coverage, bats-gate.sh. `grep -rl` matched ANY line,
			# so a path on a second covers: line earned drift-gate credit
			# here while counting nowhere else.
			# find's status is captured in the PARENT: assigning grc inside a
			# process substitution sets it in a subshell that dies with the
			# construct, so a failed enumeration read as "no matches" and the
			# drift gate silently verified nothing.
			_bats_list=$(find "$tests_dir" -name '*.bats' -type f 2>/dev/null) || grc=$?
			if [ "$grc" -gt 0 ]; then
				echo "  [drift-gate] WARN: find failed (rc=$grc) scanning $tests_dir for $relpath" >&2
				printf '%s\n' "$_UNVERIFIED_MARK"
			fi
			while IFS= read -r _b; do
				[ -n "$_b" ] || continue
				# grep rc 1 is "no covers: header", which is normal. rc>1 is
				# an unreadable file — the header may well name this hook, so
				# treating it as "no coverage" would quietly drop a suite from
				# the verification set and let the gate report nothing to do.
				_hgrc=0
				_hdr=$(grep -m1 -E '^#[[:space:]]*covers:' "$_b" 2>/dev/null) || _hgrc=$?
				if [ "$_hgrc" -gt 1 ]; then
					echo "  [drift-gate] WARN: cannot read $_b (grep rc=$_hgrc) — coverage for $relpath is UNVERIFIED" >&2
					printf '%s\n' "$_UNVERIFIED_MARK"
					continue
				fi
				[ -n "$_hdr" ] || continue
				printf '%s\n' "$_hdr" |
					grep -qE "(^|[^[:alnum:]])${esc}(\$|[^[:alnum:]])" &&
					printf '%s\n' "$_b"
			done <<<"$_bats_list"
		done | sort -u
	)
	if [ "$_coverage_unverified" = "1" ]; then
		echo "  [drift-gate] REFUSING: coverage could not be determined for at least one replaced mirror hook — a refreshed mirror must not be certified on an unread header" >&2
		return 2
	fi
	[ "${#bats_to_run[@]}" -gt 0 ] || {
		echo "  [drift-gate] no consumer bats cover the ${#replaced[@]} replaced mirror hook(s) — nothing to verify" >&2
		return 0
	}

	echo "  [drift-gate] verifying ${#bats_to_run[@]} consumer bats covering the replaced v${pver} mirror hook(s)..."
	local failed=() unverified=()
	local b rel out
	for b in "${bats_to_run[@]}"; do
		rel=${b#"$cpath"/}
		# Capture stdout+stderr (not >/dev/null) so a red run can surface
		# WHICH assertion failed, and so an all-skipped run is detected.
		# Run the CONSUMER-RELATIVE path after cd so a relative --consumer-
		# path (e.g. ./consumer) doesn't double up into a non-existent path.
		if out=$(cd "$cpath" && bats "$rel" 2>&1); then
			if printf '%s\n' "$out" | grep -q '# skip'; then
				echo "    ⚠ $rel (contains skipped case(s) — drift NOT fully verified)"
				unverified+=("$rel")
			else
				echo "    ✓ $rel"
			fi
		else
			echo "    ✗ $rel (drifted from the refreshed hook contract)"
			printf '%s\n' "$out" | grep -E '^(not ok|# )' | sed 's/^/        /' >&2 || true
			failed+=("$rel")
		fi
	done

	if [ "${#failed[@]}" -gt 0 ]; then
		{
			echo ""
			echo "  [drift-gate] BLOCKED: ${#failed[@]} consumer test file(s) drifted from the refreshed v${pver} mirror hooks:"
			local f
			for f in "${failed[@]}"; do echo "    - $f"; done
			echo "  The cascade updated the mirror hooks but these consumer tests still assert"
			echo "  the OLD contract. Refresh them to the current contract in THIS cascade PR"
			echo "  (see repbyrepdev/claude-workflow-core#2525), then re-run refresh-from-source."
			echo "  Genuine unrelated pre-existing failure? Override with REFRESH_DRIFT_GATE_SKIP=1."
		} >&2
		return 1
	fi
	if [ "${#unverified[@]}" -gt 0 ]; then
		# Don't claim a clean "passed ✓" when some covering tests only
		# skipped — that would be the same false-verified signal the gate
		# exists to catch.
		echo "  [drift-gate] WARN: ${#unverified[@]} covering test(s) only skipped — drift NOT verified; check their skip guards" >&2
		echo "  [drift-gate] covering consumer tests ran, but ${#unverified[@]} were UNVERIFIED (skipped)"
		return 0
	fi
	echo "  [drift-gate] covering consumer tests passed against the refreshed hooks ✓"
	return 0
}

_refresh_one_consumer() {
	local cpath=$1
	if [ ! -d "$cpath" ]; then
		echo "refresh-from-source: consumer path $cpath does not exist" >&2
		return 2
	fi

	echo "==> Refresh: $cpath"

	# Build skip-list from consumer's overrides (one path per line).
	local overrides
	overrides=$(_load_overrides_paths "$cpath")

	# Materialize the SSOT path list (every file in .source-hashes.json).
	local ssot_paths
	if ! ssot_paths=$(jq -r '.files | keys[]' "$HASHES" 2>"$yq_err"); then
		echo "refresh-from-source: jq failed reading $HASHES:" >&2
		cat "$yq_err" >&2
		return 2
	fi
	# r1 silent-failure-hunter HIGH: empty .files would silent-pass.
	[ -n "$ssot_paths" ] || {
		echo "refresh-from-source: $HASHES has empty file list — refusing" >&2
		return 2
	}

	local n_clean=0 n_replaced=0 n_overridden=0 n_failed=0
	local now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	# r2 silent-failure-hunter MEDIUM: jq plugin_version had no error
	# handling. Match the explicit error-trapping pattern used everywhere
	# else in this script.
	local plugin_version
	if ! plugin_version=$(jq -r '.version' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>"$yq_err"); then
		echo "refresh-from-source: jq failed reading plugin.json:" >&2
		cat "$yq_err" >&2
		return 2
	fi
	if [ -z "$plugin_version" ] || [ "$plugin_version" = "null" ]; then
		echo "refresh-from-source: plugin.json .version missing or null" >&2
		return 2
	fi
	# r2 code-reviewer + silent-failure-hunter HIGH: reset the script-
	# scope _in_flight_new at the top of each consumer call so prior
	# consumer's tracked .new (already cleaned up via mv) doesn't pollute
	# this consumer's trap-cleanup behavior.
	_in_flight_new=()
	# #2525 mirror-test drift gate: collect the consumer-relative paths of
	# replaced mirror SHELL files (hooks/ + _lib/) so we can run their
	# covering consumer bats afterward and fail loud on drift.
	local _replaced_sh=()

	# Filter to --files subset if requested.
	local filter_arr=()
	if [ -n "$FILES_FILTER" ]; then
		IFS=',' read -ra filter_arr <<<"$FILES_FILTER"
	fi
	_is_in_filter() {
		local f=$1
		[ "${#filter_arr[@]}" -eq 0 ] && return 0
		local x
		for x in "${filter_arr[@]}"; do
			[ "$x" = "$f" ] && return 0
		done
		return 1
	}

	while IFS= read -r relpath; do
		[ -n "$relpath" ] || continue
		_is_in_filter "$relpath" || continue

		# Map producer-relative path → consumer location. hooks/ and _lib/
		# mirror under .claude/; .github/ files (and any other repo-root
		# path) map VERBATIM. Mirrors hash-drift.sh --verify (#232) so a
		# .github SSOT file lands at <consumer>/.github/..., not
		# <consumer>/.claude/.github/... The override-skip below checks BOTH
		# the mapped form and the bare relpath, so either may appear in
		# local-overrides.yml.
		local consumer_rel
		case "$relpath" in
		hooks/* | _lib/* | skills/*) consumer_rel=".claude/${relpath}" ;;
		*) consumer_rel="$relpath" ;;
		esac
		if echo "$overrides" | grep -Fxq "$consumer_rel" || echo "$overrides" | grep -Fxq "$relpath"; then
			n_overridden=$((n_overridden + 1))
			echo "  [OVERRIDE] $relpath"
			continue
		fi

		local src="$PLUGIN_ROOT/$relpath"
		local dst="$cpath/$consumer_rel"

		if [ ! -f "$src" ]; then
			echo "  [SKIP] $relpath (source missing in plugin)"
			continue
		fi

		# Existing consumer copy hash vs plugin source hash.
		# r1 silent-failure-hunter CRITICAL: validate hash-shape — a
		# missing/broken shasum returning empty string would compare
		# `"" = ""` as TRUE and silently report "clean" on every drift.
		local src_hash dst_hash
		src_hash=$(shasum -a 256 "$src" | awk '{print $1}')
		[[ $src_hash =~ ^[0-9a-f]{64}$ ]] || {
			echo "refresh-from-source: shasum produced malformed output for src $src ('$src_hash')" >&2
			n_failed=$((n_failed + 1))
			continue
		}
		if [ -f "$dst" ]; then
			dst_hash=$(shasum -a 256 "$dst" | awk '{print $1}')
			[[ $dst_hash =~ ^[0-9a-f]{64}$ ]] || {
				echo "refresh-from-source: shasum produced malformed output for dst $dst ('$dst_hash')" >&2
				n_failed=$((n_failed + 1))
				continue
			}
		else
			dst_hash="(missing)"
		fi

		if [ "$src_hash" = "$dst_hash" ]; then
			n_clean=$((n_clean + 1))
			continue
		fi

		# Differs — copy atomically (.new + mv).
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "  [DIFF] $relpath (would copy; src=${src_hash:0:8} dst=${dst_hash:0:8})"
			n_replaced=$((n_replaced + 1))
			continue
		fi

		mkdir -p "$(dirname "$dst")"
		_in_flight_new+=("$dst.new")
		if ! cp "$src" "$dst.new"; then
			echo "  [FAIL] $relpath (cp source → .new failed)" >&2
			# r1 code-reviewer Important: clean up partial .new before continue.
			rm -f "$dst.new"
			n_failed=$((n_failed + 1))
			continue
		fi
		if ! mv "$dst.new" "$dst"; then
			echo "  [FAIL] $relpath (atomic mv .new → live failed)" >&2
			rm -f "$dst.new"
			n_failed=$((n_failed + 1))
			continue
		fi
		# Preserve executable bit if source is executable.
		[ -x "$src" ] && chmod +x "$dst"
		echo "  [REPLACED] $relpath (dst=${dst_hash:0:8} → src=${src_hash:0:8})"
		n_replaced=$((n_replaced + 1))
		# #2525: track replaced mirror shell files for the drift gate.
		case "$consumer_rel" in
		# In `case` globs `*` spans `/`, so `.claude/skills/*.sh` already
		# covers a skill's run.sh at any nesting depth.
		.claude/hooks/*.sh | .claude/_lib/*.sh | .claude/skills/*.sh)
			_replaced_sh+=("$consumer_rel")
			;;
		esac
	done <<<"$ssot_paths"

	# Audit log to consumer.
	# r1 silent-failure-hunter MEDIUM: explicit jq failure check; if
	# audit-log construction fails, refuse to silently exit with
	# success — operator must know there's no record.
	if [ "$DRY_RUN" -eq 0 ]; then
		local audit_dir="$cpath/.claude/logs"
		mkdir -p "$audit_dir"
		local audit_file="$audit_dir/refresh-from-source.jsonl"
		local entry
		if ! entry=$(jq -cn --arg ts "$now" --arg pv "$plugin_version" \
			--argjson clean "$n_clean" \
			--argjson replaced "$n_replaced" \
			--argjson overridden "$n_overridden" \
			--argjson failed "$n_failed" \
			--arg cpath "$cpath" \
			'{ts: $ts, plugin_version: $pv, consumer_path: $cpath, files_clean: $clean, files_replaced: $replaced, files_overridden: $overridden, files_failed: $failed}' 2>"$yq_err"); then
			echo "refresh-from-source: jq audit-log entry construction failed:" >&2
			cat "$yq_err" >&2
			return 3
		fi
		if ! printf '%s\n' "$entry" >>"$audit_file"; then
			echo "refresh-from-source: failed to write audit log $audit_file" >&2
			return 3
		fi
	fi

	echo "  Summary: clean=$n_clean replaced=$n_replaced overridden=$n_overridden failed=$n_failed"

	# A partial-copy failure leaves the consumer in an inconsistent state
	# (rc=3) that outranks a mere test drift (rc=4) — report it FIRST so the
	# more-urgent "manual recovery required" signal is never masked by the
	# drift gate below.
	if [ "$n_failed" -gt 0 ]; then
		return 3
	fi

	# #2525 mirror-test drift gate. A cascade re-pin updates the consumer's
	# mirror HOOKS but the consumer's own bats copies of those hooks are not
	# in the sync set, so they drift from the hook contract and go red —
	# silently, since consumer bats is not a required CI check. Run the
	# covering consumer bats for every replaced mirror hook NOW and fail
	# loud, so drift is caught at refresh time (before a cascade PR opens)
	# instead of by accident mid-review. Real (non-dry) runs only. The
	# helper returns 1 on drift; map that to the caller's rc=4 contract.
	if [ "$DRY_RUN" -eq 0 ] && [ "${#_replaced_sh[@]}" -gt 0 ]; then
		_dg_rc=0
		_mirror_test_drift_gate "$cpath" "$plugin_version" "${_replaced_sh[@]}" || _dg_rc=$?
		# Distinguish the two failures. rc 2 is "coverage could not be
		# DETERMINED" (a candidate suite was unreadable) — a precondition
		# error, and the caller's documented meaning for 2. Collapsing it into
		# 4 would report test DRIFT, sending the operator to refresh tests
		# that were never the problem.
		case "$_dg_rc" in
		0) ;;
		2) return 2 ;;
		*) return 4 ;;
		esac
	fi

	# TODO (deferred to other unshipped subs):
	#   * Re-render consumer's settings.json from templates/settings.json.tpl
	#     (Sub 12) — preserves operator-only voice/marketplace sections.
	#   * Post-cascade `hash-drift.sh --verify` (Sub 10) to confirm zero
	#     drift on cascade-target paths.

	return 0
}

# Resolve target consumer paths.
target_paths=()
if [ -n "$CONSUMER" ]; then
	target_paths+=("$(_resolve_consumer_path "$CONSUMER")")
elif [ -n "$CONSUMER_PATH" ]; then
	target_paths+=("$CONSUMER_PATH")
elif [ "$ALL_CONSUMERS" -eq 1 ]; then
	while IFS= read -r p; do
		[ -n "$p" ] && target_paths+=("$p")
	done < <(_list_all_consumer_paths)
fi

# r1 silent-failure-hunter MEDIUM: refuse zero-target runs (e.g. empty
# consumers.yml under --all-consumers). Without this, the for-loop
# iterates zero times, overall_rc stays 0, script reports success.
if [ "${#target_paths[@]}" -eq 0 ]; then
	echo "refresh-from-source: no target consumers resolved — nothing to do" >&2
	exit 2
fi

# r1 code-reviewer Important: propagate WORST rc across consumers, not
# LAST. Prior code overwrote on every non-zero, so consumer-A=3 then
# consumer-B=2 would exit 2 (mis-classifying partial-failure as
# precondition-error).
overall_rc=0
for p in "${target_paths[@]}"; do
	rc=0
	_refresh_one_consumer "$p" || rc=$?
	if [ "$rc" -gt "$overall_rc" ]; then
		overall_rc=$rc
	fi
done

exit "$overall_rc"
