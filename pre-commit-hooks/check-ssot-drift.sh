#!/bin/bash
set -uo pipefail
# v4.4.D (#381): SSOT drift validator. Reads `.claude/ssot-checks.yml`
# for claims that should match an authoritative SSOT file. Fails the
# commit on mismatch.
#
# v4.28-W2 (#647): added `kind: list` checks alongside the original
# `kind: count`. List checks compare an inline enumeration in a file
# (e.g., a hard-coded `STACKS=(authelia swag ...)` array, or a prose
# bullet list) against the authoritative list in an SSOT file. Catches
# the drift class where someone restates an SSOT list inline and lets
# it diverge silently. `kind` defaults to `count` when omitted, so
# existing entries keep working without edit.
#
# The check config lives in `.claude/ssot-checks.yml` — adding a new drift
# guard means adding a new entry there, not editing this script.
#
# Opt-out per-commit: prepend `# ssot-drift: opt-out — <reason>` in a
# CLAUDE.md file's first 5 lines — intentional. Not supported for
# general files to keep the guard sharp.
#
# Bypass: NONE — SSOT drift validation is non-bypassable by design (the
# whole point is to catch silent inline-list drift). Test override only:
# set SSOT_CHECKS_CONFIG=/path/to/alt-config.yml to point the hook at a
# fixture instead of the real .claude/ssot-checks.yml.
#
# Strict mode: set -uo pipefail (NOT -e) — the script accumulates per-
# check failures into $errs and exits with binary 0/1 at the end. Adding
# -e would terminate on the first non-zero rc inside _check_count /
# _check_list before the accumulator runs. The `if ! cmd` pattern at
# call sites already neutralizes the missing -e for caller-error
# detection. cr-cli r2 (#647) flagged the line-2 placement; set -uo
# pipefail moved up; -e intentionally omitted per accumulator design.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[ -z "$REPO_ROOT" ] && exit 0
CONFIG="${SSOT_CHECKS_CONFIG:-$REPO_ROOT/.claude/ssot-checks.yml}"
[ -f "$CONFIG" ] || exit 0

command -v yq >/dev/null || {
	# v4.4 round-2 fix (CR): exit non-zero so missing yq fails the commit
	# loudly. Previously exit 0 silently masked drift in any environment
	# without yq (CI images, fresh clones).
	echo "check-ssot-drift: yq not installed — required for SSOT drift validation. brew install yq" >&2
	exit 1
}

# Early-exit if no checks configured (empty list).
#
# Phase 1 silent-failure-hunter (round 1, #647): the prior `2>/dev/null`
# masked yq parse errors — a corrupt ssot-checks.yml would silently
# disable ALL drift validation across every commit until someone noticed.
# Capture stderr explicitly + fail-loud on yq parse failure. Distinguishes
# "config valid but checks empty" (exit 0, no work) from "config broken"
# (exit 2, surface the yq error to operator).
YQ_STDERR=$(mktemp)
trap 'rm -f "$YQ_STDERR"' EXIT
if ! N=$(yq -r '.checks | length // 0' "$CONFIG" 2>"$YQ_STDERR"); then
	echo "check-ssot-drift: yq failed parsing $CONFIG — drift validation disabled until fixed:" >&2
	cat "$YQ_STDERR" >&2
	exit 2
fi
[ "${N:-0}" = "0" ] && exit 0

errs=0

# Resolve a path: absolute as-is, relative against REPO_ROOT. Lets test
# fixtures pass full absolute paths (tmpdir) without forcing every
# real-world entry to be repo-relative.
_abs_path() {
	case "$1" in
	/*) echo "$1" ;;
	*) echo "$REPO_ROOT/$1" ;;
	esac
}

# kind=count check (original v4.4.D behavior). Returns 0 on no-drift,
# 1 on drift detected, 2 on broken SSOT_EXPR.
#
# Phase 1 r2 silent-failure-hunter (#647): r1 only patched _check_list
# — _check_count still had grep + yq with 2>/dev/null swallowing tool
# stderr, conflating "regex didn't match" (legit) with "regex broken /
# yq parse error" (silent corruption). Apply the same per-tool stderr
# capture treatment for symmetry.
_check_count() {
	local name=$1 claim_file=$2 claim_regex=$3 ssot_file=$4 ssot_expr=$5 desc=$6
	local claimed actual claim_abs ssot_abs extract_err yq_err matched
	claim_abs=$(_abs_path "$claim_file")
	ssot_abs=$(_abs_path "$ssot_file")

	# extract_err captures stderr of BOTH extraction passes (grep + sed).
	extract_err=$(mktemp)
	yq_err=$(mktemp)

	# Two-step extraction (#2387): grep -m1 -o isolates the FULL first
	# regex match (self-limiting — no `| head` pipe that could SIGPIPE
	# grep under pipefail), then an ^anchored$ sed pulls capture group 1
	# out of that exact substring. The old single-pass
	# `s|.*${claim_regex}.*|\1|p` let the greedy `.*` prefix eat leading
	# digits of the capture (a claim of "10" extracted as "0" -> false
	# drift BLOCK on any multi-digit count). stderr non-empty = real
	# failure (bad regex); empty + rc=1 = "no match" (normal).
	# NB: the sed step uses `|` as its delimiter, so claim_regex must not
	# contain a literal `|` (same constraint _check_list documents for
	# its extraction below).
	matched=""
	if ! matched=$(grep -m1 -oE "${claim_regex}" "$claim_abs" 2>"$extract_err"); then
		if [ -s "$extract_err" ]; then
			echo "BLOCK: SSOT drift check '${name}' — regex match extraction failed:" >&2
			cat "$extract_err" >&2
			echo "  Bad regex in .claude/ssot-checks.yml? claim_regex=$claim_regex" >&2
			rm -f "$extract_err" "$yq_err"
			return 2
		fi
		# Empty result without stderr = no matches (normal).
		matched=""
	fi
	# grep -m1 stops at the first matching LINE but prints every match on
	# it; keep only the first (multi-match lines are first-match-wins).
	matched=${matched%%$'\n'*}
	claimed=""
	if [ -n "$matched" ]; then
		if ! claimed=$(printf '%s\n' "$matched" | sed -nE "s|^${claim_regex}\$|\1|p" 2>"$extract_err"); then
			if [ -s "$extract_err" ]; then
				echo "BLOCK: SSOT drift check '${name}' — sed capture extraction failed:" >&2
				cat "$extract_err" >&2
				echo "  Bad regex in .claude/ssot-checks.yml? claim_regex=$claim_regex" >&2
				rm -f "$extract_err" "$yq_err"
				return 2
			fi
			claimed=""
		fi
		# Fail-loud on extraction inconsistency: grep PROVED the claim
		# exists, so an empty second-pass capture means the two steps
		# disagree (regex dialect divergence between grep -E and sed -E,
		# or a zero-width capture) — NOT an absent claim. Returning 0
		# here would silently disable this check forever.
		if [ -z "$claimed" ]; then
			echo "BLOCK: SSOT drift check '${name}' — extraction inconsistency:" >&2
			echo "  grep matched '$matched' but the anchored sed capture came back empty." >&2
			echo "  Likely a grep-vs-sed ERE dialect divergence in claim_regex=$claim_regex" >&2
			echo "  Fix the regex in .claude/ssot-checks.yml to use portable ERE." >&2
			rm -f "$extract_err" "$yq_err"
			return 2
		fi
	fi
	rm -f "$extract_err"

	if ! actual=$(yq -r "$ssot_expr" "$ssot_abs" 2>"$yq_err"); then
		if [ -s "$yq_err" ]; then
			echo "BLOCK: SSOT drift check '${name}' — yq evaluation failed:" >&2
			cat "$yq_err" >&2
			echo "  Bad SSOT expression? ssot.count=$ssot_expr" >&2
			rm -f "$yq_err"
			return 2
		fi
		actual=""
	fi
	rm -f "$yq_err"

	if [ -z "$claimed" ]; then
		# Claim regex didn't match — maybe the file was refactored to not
		# make the numeric claim anymore. That's the SSOT-first goal;
		# don't fail, just note.
		return 0
	fi

	# v4.5.F: disambiguate "yq expression returned no value" from "legit
	# drift where SSOT says 0". If ACTUAL is literal "null" or empty,
	# the SSOT_EXPR is wrong — fail loud with a specific error pointing
	# at the bad config entry rather than reporting drift of "null vs N".
	if [ -z "$actual" ] || [ "$actual" = "null" ]; then
		echo "BLOCK: SSOT drift check '${name}' has a broken SSOT expression" >&2
		echo "  File:       $ssot_file" >&2
		echo "  Expression: $ssot_expr" >&2
		echo "  yq returned: '$actual' (empty or literal null = no match)" >&2
		echo "  Fix .claude/ssot-checks.yml to use a valid yq expression." >&2
		return 2
	fi

	if [ "$claimed" != "$actual" ]; then
		echo "BLOCK: SSOT drift — ${name}" >&2
		echo "  $claim_file says: $claimed" >&2
		echo "  $ssot_file says: $actual" >&2
		echo "  $desc" >&2
		echo "  Fix: update $claim_file to match, or rewrite to reference $ssot_file by path (no numeric claim)." >&2
		return 1
	fi
	return 0
}

# kind=list check (v4.28-W2 #647). claim.regex captures every inline
# enumeration entry — capture group 1 is the item value. The set of
# captured items must equal the set returned by ssot.list (a yq
# expression returning a list). Order is ignored (sets compared); empty
# claim = "no enumeration found, nothing to drift" (no-op, like count).
_check_list() {
	local name=$1 claim_file=$2 claim_regex=$3 ssot_file=$4 ssot_expr=$5 desc=$6
	local claimed_items actual_items only_in_claim only_in_ssot claim_abs ssot_abs
	claim_abs=$(_abs_path "$claim_file")
	ssot_abs=$(_abs_path "$ssot_file")

	# Phase 1 r1 silent-failure-hunter (#647): the prior `2>/dev/null + ||
	# true` swallowed sed regex-compile errors AND yq parse errors. A
	# malformed claim_regex from the config would silently produce empty
	# claimed_items; the "regex didn't match" branch then exited 0,
	# masking config corruption. Capture stderr explicitly so each tool's
	# error surfaces to the operator.
	#
	# Extract all items via the claim regex (group 1). Use sed instead of
	# grep because grep -oE doesn't isolate capture groups portably.
	# Sort + uniq so set-comparison is order-independent.
	local sed_err yq_err
	sed_err=$(mktemp)
	yq_err=$(mktemp)
	# Trap inside subshell scope is impractical; rely on caller cleanup +
	# manually rm the tempfiles before each return.
	# Phase 2 cr-cli r2 (#647): use `|` as sed delimiter so claim_regex
	# values containing `/` (e.g., file path patterns) don't break the
	# substitution. Caveat: claim_regex must not contain literal `|`;
	# document this constraint in ssot-checks.yml schema.
	if ! claimed_items=$(sed -nE "s|.*${claim_regex}.*|\1|p" "$claim_abs" 2>"$sed_err" | sort -u | grep -v '^$'); then
		# Pipe rc=1 from grep when no matches is normal; treat sed's
		# stderr as the canonical signal of breakage.
		if [ -s "$sed_err" ]; then
			echo "BLOCK: SSOT list-drift check '${name}' — sed regex extraction failed:" >&2
			cat "$sed_err" >&2
			echo "  Bad regex in .claude/ssot-checks.yml? claim_regex=$claim_regex" >&2
			rm -f "$sed_err" "$yq_err"
			return 2
		fi
		# Empty result without sed stderr = no matches, that's fine.
		claimed_items=""
	fi
	rm -f "$sed_err"

	# Pull the SSOT list — yq with `.[]` style expression yields one item
	# per line. Sort + uniq for the same reason. yq parse errors must
	# surface (the prior 2>/dev/null hid them, conflating "broken expr"
	# with "expr returned empty list").
	if ! actual_items=$(yq -r "$ssot_expr" "$ssot_abs" 2>"$yq_err" | sort -u | grep -v '^$'); then
		if [ -s "$yq_err" ]; then
			echo "BLOCK: SSOT list-drift check '${name}' — yq evaluation failed:" >&2
			cat "$yq_err" >&2
			echo "  Bad SSOT expression? ssot.list=$ssot_expr" >&2
			rm -f "$yq_err"
			return 2
		fi
		# Empty result without yq stderr = legit empty list — caught by
		# the empty-or-null broken-SSOT-expression branch below.
		actual_items=""
	fi
	rm -f "$yq_err"

	if [ -z "$claimed_items" ]; then
		# Claim regex matched nothing — file no longer carries an inline
		# enumeration of this list. SSOT-first goal, don't fail.
		return 0
	fi

	# Empty AND literal-null both mean "the SSOT expression returned no
	# list" — a broken config, not drift. Without the -z arm an empty
	# result fell through to the set-difference and reported every
	# claimed item as a misleading orphan-drift BLOCK.
	if [ -z "$actual_items" ] || [ "$actual_items" = "null" ]; then
		echo "BLOCK: SSOT list-drift check '${name}' has a broken SSOT expression" >&2
		echo "  File:       $ssot_file" >&2
		echo "  Expression: $ssot_expr" >&2
		echo "  yq returned no list (empty or null) — fix .claude/ssot-checks.yml." >&2
		return 2
	fi

	# Set-difference both ways: items in claim not in SSOT (orphans) +
	# items in SSOT not in claim (missing).
	# Phase 1 r1 silent-failure-hunter (#647): removed `|| true` —
	# under set -u (no set -e), cmd-sub failures don't terminate, so the
	# `|| true` was cosmetic. Worse, it would have masked process-
	# substitution failures (e.g. unsupported on the host shell).
	only_in_claim=$(comm -23 <(echo "$claimed_items") <(echo "$actual_items"))
	only_in_ssot=$(comm -13 <(echo "$claimed_items") <(echo "$actual_items"))

	if [ -n "$only_in_claim" ] || [ -n "$only_in_ssot" ]; then
		echo "BLOCK: SSOT list-drift — ${name}" >&2
		echo "  Claim file: $claim_file" >&2
		echo "  SSOT file:  $ssot_file" >&2
		if [ -n "$only_in_claim" ]; then
			echo "  Items in claim NOT in SSOT (orphans — drift candidates):" >&2
			while IFS= read -r _item; do
				printf '    - %s\n' "$_item" >&2
			done <<<"$only_in_claim"
		fi
		if [ -n "$only_in_ssot" ]; then
			echo "  Items in SSOT NOT in claim (missing from inline list):" >&2
			while IFS= read -r _item; do
				printf '    - %s\n' "$_item" >&2
			done <<<"$only_in_ssot"
		fi
		echo "  $desc" >&2
		echo "  Fix: update $claim_file to match SSOT, or rewrite to reference $ssot_file by path." >&2
		return 1
	fi
	return 0
}

# Compute staged paths for staging-aware filtering.
STAGED_PATHS=""
if git rev-parse --git-dir >/dev/null 2>&1; then
	STAGED_PATHS=$(git diff --name-only --cached 2>/dev/null || true)
fi

for i in $(seq 0 $((N - 1))); do
	NAME=$(I=$i yq -r '.checks[env(I)|tonumber].name' "$CONFIG")
	# kind defaults to "count" for v4.4.D backward compat.
	KIND=$(I=$i yq -r '.checks[env(I)|tonumber].kind // "count"' "$CONFIG")
	CLAIM_FILE=$(I=$i yq -r '.checks[env(I)|tonumber].claim.file' "$CONFIG")
	CLAIM_REGEX=$(I=$i yq -r '.checks[env(I)|tonumber].claim.regex' "$CONFIG")
	SSOT_FILE=$(I=$i yq -r '.checks[env(I)|tonumber].ssot.file' "$CONFIG")
	DESC=$(I=$i yq -r '.checks[env(I)|tonumber].description // ""' "$CONFIG")

	CLAIM_ABS=$(_abs_path "$CLAIM_FILE")
	SSOT_ABS=$(_abs_path "$SSOT_FILE")
	if [ ! -f "$CLAIM_ABS" ] || [ ! -f "$SSOT_ABS" ]; then
		echo "check-ssot-drift: ${NAME} — file missing, skipping" >&2
		continue
	fi

	# Staging-aware filtering: skip check if neither CLAIM_ABS nor SSOT_ABS is staged.
	if [ -n "$STAGED_PATHS" ]; then
		staged_match=""
		while IFS= read -r staged_path; do
			[ -z "$staged_path" ] && continue
			staged_abs=$(_abs_path "$staged_path")
			if [ "$staged_abs" = "$CLAIM_ABS" ] || [ "$staged_abs" = "$SSOT_ABS" ]; then
				staged_match="yes"
				break
			fi
		done <<<"$STAGED_PATHS"
		[ -z "$staged_match" ] && continue
	fi

	case "$KIND" in
	count)
		SSOT_EXPR=$(I=$i yq -r '.checks[env(I)|tonumber].ssot.count' "$CONFIG")
		if ! _check_count "$NAME" "$CLAIM_FILE" "$CLAIM_REGEX" "$SSOT_FILE" "$SSOT_EXPR" "$DESC"; then
			errs=$((errs + 1))
		fi
		;;
	list)
		SSOT_EXPR=$(I=$i yq -r '.checks[env(I)|tonumber].ssot.list' "$CONFIG")
		if ! _check_list "$NAME" "$CLAIM_FILE" "$CLAIM_REGEX" "$SSOT_FILE" "$SSOT_EXPR" "$DESC"; then
			errs=$((errs + 1))
		fi
		;;
	*)
		echo "BLOCK: SSOT check '${NAME}' has unknown kind '$KIND' — must be 'count' or 'list'." >&2
		errs=$((errs + 1))
		;;
	esac
done

# Phase 2 cr-cli (#647): bin to 0/1 — pre-commit gate contract is binary
# (0=pass, non-zero=fail). Exposing $errs raw allows codes >1 which
# downstream callers may misinterpret.
[ "$errs" -gt 0 ] && exit 1
exit 0
