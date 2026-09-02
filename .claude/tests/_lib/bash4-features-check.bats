#!/usr/bin/env bats
# covers: _lib/bash4-features-check.sh
#
# #2645 — first behavioral coverage for the bash-3.2 portability SSOT (it was
# pattern-matched, never executed, and had zero tests). Locks three contracts:
#   1. every detector fires on CODE using its feature (old six + new six);
#   2. comment-only mentions do NOT flag (the false-positive that hit three
#      shipped files: scripts/test.sh, skills/_lib/skill-common.sh,
#      hooks/phase1-launcher.sh);
#   3. delimiter negatives — legal 3.2 constructs that LOOK like features
#      (`cmd; &`, `2>&1`, `${1:-x}`, `local -i n=5`) stay clean.
# Plus one honest execution proof: on a machine whose /bin/bash IS 3.2, `;&`
# is a hard parse error — the exact failure class the gate exists to stop.

setup() {
	LIB="${BATS_TEST_DIRNAME}/../../../_lib/bash4-features-check.sh"
	[ -f "$LIB" ]
	# shellcheck source=../../../_lib/bash4-features-check.sh
	. "$LIB"
}

# _chk <content> — run the SSOT entrypoint with a fixed display name.
_chk() {
	bash4_features_check_content "fixture.sh" "$1"
}

@test "safe shebang (#!/usr/bin/env bash) exempts even declare -A" {
	run _chk $'#!/usr/bin/env bash\ndeclare -A m=()'
	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ]
}

@test "#!/bin/bash with clean 3.2 code passes" {
	run _chk $'#!/bin/bash\nset -u\nfor f in a b; do echo "$f"; done'
	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ]
}

@test "mapfile -d flags (bash 4.4)" {
	run _chk $'#!/bin/bash\nmapfile -d "" arr < x'
	[ "$status" -eq 1 ]
	[[ $output == *"mapfile -d"* ]]
}

@test "mapfile -t -d with split flag clusters flags (#2649)" {
	run _chk $'#!/bin/bash\nmapfile -t -d "" arr < x'
	[ "$status" -eq 1 ]
	[[ $output == *"mapfile -d"* ]]
}

@test "whitespace shebang variants are still unsafe; safe interpreters never match (#2649)" {
	run _chk $'#! /bin/bash\ndeclare -A m'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"declare -A"* ]] || return 1
	run _chk $'#!/bin/bash \t\ndeclare -A m'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"declare -A"* ]] || return 1
	run bash4_features_unsafe_shebang '#!/opt/homebrew/bin/bash'
	[ "$status" -eq 1 ] || return 1
	[ -z "$output" ] || return 1
	run bash4_features_unsafe_shebang '#!/usr/bin/env bash'
	[ "$status" -eq 1 ] || return 1
	[ -z "$output" ]
}

@test "builtin/command/time prefixes flag; bare mapfile has a rule (#2649 r3)" {
	run _chk $'#!/bin/bash\nbuiltin declare -A values'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"declare -A"* ]] || return 1
	run _chk $'#!/bin/bash\ncommand readarray values'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"readarray (bash 4.0)"* ]] || return 1
	run _chk $'#!/bin/bash\ntime mapfile values < input'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"mapfile / readarray (bash 4.0)"* ]]
}

@test "prefixes with options flag: command -p readarray and time -p mapfile (#2649 r4)" {
	run _chk $'#!/bin/bash\ncommand -p readarray values'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"readarray (bash 4.0)"* ]] || return 1
	run _chk $'#!/bin/bash\ntime -p mapfile values < input'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"mapfile / readarray (bash 4.0)"* ]]
}

@test "assignment and redirection prefixes flag (#2649 r5)" {
	run _chk $'#!/bin/bash\nB4_TEST=1 mapfile values < input'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"mapfile / readarray (bash 4.0)"* ]] || return 1
	run _chk $'#!/bin/bash\nLC_ALL=C declare -A values'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"declare -A"* ]] || return 1
	run _chk $'#!/bin/bash\na[0]=v declare -A m'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"declare -A"* ]] || return 1
	run _chk $'#!/bin/bash\n< input mapfile values'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"mapfile / readarray (bash 4.0)"* ]] || return 1
	run _chk $'#!/bin/bash\n2>log readarray values'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"readarray (bash 4.0)"* ]]
}

@test "backtick substitution is a command boundary: legacy backtick-wrapped features flag (#2649 backup review)" {
	run _chk $'#!/bin/bash\nn=`declare -A seen; echo "${#seen[@]}"`'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"declare -A"* ]] || return 1
	run _chk $'#!/bin/bash\narr=`mapfile -t a < f; echo done`'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"mapfile / readarray (bash 4.0)"* ]]
}

@test "CRLF shebang does not disable the gate (#2649 backup review)" {
	run _chk $'#!/bin/bash\r\ndeclare -A m'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"declare -A"* ]]
}

@test "negated commands flag: if ! mapfile ... and bare ! declare (#2649 r2)" {
	run _chk $'#!/bin/bash\nif ! mapfile -d "" items < input; then :; fi'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"mapfile -d"* ]] || return 1
	run _chk $'#!/bin/bash\n! declare -A m'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"declare -A"* ]]
}

@test "declare -A flags (bash 4.0)" {
	run _chk $'#!/bin/bash\ndeclare -A map'
	[ "$status" -eq 1 ]
	[[ $output == *"declare -A"* ]]
}

@test "bare readarray flags (bash 4.0)" {
	run _chk $'#!/bin/bash\nreadarray -t arr < input.txt'
	[ "$status" -eq 1 ]
	[[ $output == *"readarray (bash 4.0)"* ]]
}

@test "case transform in CODE flags" {
	run _chk $'#!/bin/bash\necho "${name^^}"'
	[ "$status" -eq 1 ]
	[[ $output == *"case transforms"* ]]
}

@test "case transform in a COMMENT only does NOT flag (#2645 fix)" {
	run _chk $'#!/bin/bash\n# Lowercase via tr for 3.2 compat - ${var,,} is bash 4+.\nlower=$(printf %s "$v" | tr A-Z a-z)'
	[ "$status" -eq 0 ]
}

@test "globstar mention in a COMMENT only does NOT flag (#2645 fix)" {
	run _chk $'#!/bin/bash\n# avoid shopt -s globstar here; find(1) instead\nfind . -name "*.sh"'
	[ "$status" -eq 0 ]
}

@test "&>> in CODE flags" {
	run _chk $'#!/bin/bash\ncmd &>>log.txt'
	[ "$status" -eq 1 ]
	[[ $output == *"&>>"* ]]
}

@test ";& case fall-through flags as a PARSE error class (#2645 new)" {
	run _chk $'#!/bin/bash\ncase $x in\na) echo a ;&\nb) echo b ;;\nesac'
	[ "$status" -eq 1 ]
	[[ $output == *"PARSE error"* ]]
}

@test ";;& case terminator flags (#2645 new)" {
	run _chk $'#!/bin/bash\ncase $x in\na) echo a ;;&\nb) echo b ;;\nesac'
	[ "$status" -eq 1 ]
	[[ $output == *";;&"* ]]
}

@test "legal 3.2 lookalikes do not flag: spaced semicolon-ampersand and 2>&1" {
	run _chk $'#!/bin/bash\n(sleep 1; echo x) & wait\ncmd 2>&1 | tee log'
	[ "$status" -eq 0 ]
}

@test "coproc flags (#2645 new)" {
	run _chk $'#!/bin/bash\ncoproc mycop { cat; }'
	[ "$status" -eq 1 ]
	[[ $output == *"coproc"* ]]
}

@test "declare -g flags (#2645 new, bash 4.2)" {
	run _chk $'#!/bin/bash\nf() { declare -g shared=1; }'
	[ "$status" -eq 1 ]
	[[ $output == *"declare -g"* ]]
}

@test "local -n nameref flags while local -i n=5 stays clean (#2645 new)" {
	run _chk $'#!/bin/bash\nf() { local -n ref=$1; }'
	[ "$status" -eq 1 ]
	[[ $output == *"nameref"* ]] || return 1
	run _chk $'#!/bin/bash\nf() { local -i n=5; echo "$n"; }'
	[ "$status" -eq 0 ]
}

@test "negative subscript arr[-1] flags while positional-default stays clean (#2645 new)" {
	run _chk $'#!/bin/bash\nlast=${arr[-1]}'
	[ "$status" -eq 1 ]
	[[ $output == *"negative array subscripts"* ]] || return 1
	run _chk $'#!/bin/bash\narg=${1:-default}\nn=${#arr[@]}'
	[ "$status" -eq 0 ]
}

@test "var-at-Q parameter transform flags (#2645 new)" {
	run _chk $'#!/bin/bash\nprintf %s "${v@Q}"'
	[ "$status" -eq 1 ]
	[[ $output == *"parameter transforms"* ]]
}

@test "inline function body is not a blind spot for declare -A (#2645)" {
	run _chk $'#!/bin/bash\nf() { declare -A m; }'
	[ "$status" -eq 1 ]
	[[ $output == *"declare -A"* ]]
}

@test "valid waiver with reason suppresses exactly that detector (#2645)" {
	run _chk $'#!/bin/bash\n# bash4-waiver: globstar — guarded with || true, degradation documented\nshopt -s globstar 2>/dev/null || true'
	[ "$status" -eq 0 ]
}

@test "waiver does not leak to other detectors" {
	run _chk $'#!/bin/bash\n# bash4-waiver: globstar — guarded here\nshopt -s globstar 2>/dev/null || true\ndeclare -A m'
	[ "$status" -eq 1 ]
	[[ $output == *"declare -A"* ]] || return 1
	[[ $output != *"globstar (bash 4.0)"* ]]
}

@test "reasonless waiver does NOT suppress and is itself reported (#2645)" {
	run _chk $'#!/bin/bash\n# bash4-waiver: globstar\nshopt -s globstar || true'
	[ "$status" -eq 1 ]
	[[ $output == *"shopt -s globstar"* ]] || return 1
	[[ $output == *"NO reason"* ]]
}

@test "unknown waiver key is reported as malformed (#2645)" {
	run _chk $'#!/bin/bash\n# bash4-waiver: globbstar — typo key\necho ok'
	[ "$status" -eq 1 ]
	[[ $output == *"unknown bash4-waiver key"* ]]
}

@test "keyword-prefixed one-liners flag: do/then forms are not a blind spot (#2645 r1)" {
	# Probed fail-open hole: do/then sat between the delimiter and the
	# builtin, so `for ...; do readarray ...` sailed through both gates —
	# the anchor regression class in its most common compact shape.
	run _chk $'#!/bin/bash\nfor f in a b; do readarray -t x <"$f"; done'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"readarray"* ]] || return 1
	run _chk $'#!/bin/bash\nwhile :; do mapfile -d "" x; done'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"mapfile -d"* ]] || return 1
	run _chk $'#!/bin/bash\nif declare -A m; then :; fi'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"declare -A"* ]]
}

@test "grep tool error is a BLOCK, not a clean bill (#2645 r1 fail-closed)" {
	# A grep that errors (rc 2) must not read as "no features found". The
	# override is visible to run's subshell; every detector then errors and
	# the accumulated _B4_TOOL_ERR turns into a BLOCK.
	# shellcheck disable=SC2317,SC2329  # invoked indirectly inside run subshell
	grep() { return 2; }
	run _chk $'#!/bin/bash\necho ok'
	unset -f grep
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"detector errored; failing closed"* ]]
}

@test "sed comment-strip failure is a BLOCK (#2645 r1 fail-closed)" {
	# sed failing would disable ALL detectors at once — the widest silent
	# blast radius; must fail closed.
	# shellcheck disable=SC2317,SC2329  # invoked indirectly inside run subshell
	sed() { return 1; }
	run _chk $'#!/bin/bash\necho ok'
	unset -f sed
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"comment-strip failed"* ]]
}

@test "exempt_path is exactly one file wide: the detector lib in any layout (#2645 r1)" {
	run bash4_features_exempt_path "_lib/bash4-features-check.sh"
	[ "$status" -eq 0 ]
	run bash4_features_exempt_path ".claude/_lib/bash4-features-check.sh"
	[ "$status" -eq 0 ]
	run bash4_features_exempt_path "pre-commit-hooks/bash4-features-check.sh"
	[ "$status" -eq 1 ]
	run bash4_features_exempt_path "skills/_lib/skill-common.sh"
	[ "$status" -eq 1 ]
}

@test "execution proof: ;& is a hard parse error under a real bash 3.2" {
	/bin/bash --version 2>/dev/null | head -1 | grep -q ' 3\.' ||
		skip "pending #2642 — /bin/bash here is not 3.x; the dual-version execution gate rides that issue"
	run /bin/bash -n -c $'case x in\nx) echo a ;&\nesac'
	[ "$status" -ne 0 ] || return 1
	[[ $output == *"syntax error"* ]]
}

@test "compact terminators flag: echo x;& and :;& without leading space (#2645 r2)" {
	run _chk $'#!/bin/bash\ncase $x in\na) echo x;&\nb) echo b ;;\nesac'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"PARSE error"* ]] || return 1
	run _chk $'#!/bin/bash\ncase $y in\na) :;&\nb) : ;;\nesac'
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"PARSE error"* ]]
}

# #2652 dogfood: run the check under the COMMIT GATE's shell contract —
# pre-commit-hooks/bash4-features-check.sh sets `set -euo pipefail`, and
# the SIGPIPE class this pins only exists under pipefail (the write-guard
# runs `set -u` only and never surfaced it; the bats harness does not set
# pipefail either, which is exactly how the bug hid from a plain _chk
# call). Content travels via a temp FILE, not argv — Linux caps a single
# exec argument at MAX_ARG_STRLEN (~128KB), so a ~350KB argv would E2BIG
# on any Linux runner (phase1 test-analysis).
_chk_pipefail() {
	printf '%s' "$1" >"$BATS_TEST_TMPDIR/pf-content" || return 1
	run bash -c 'set -euo pipefail; . "$1"; bash4_features_check_content chk.sh "$(cat "$2")"' _ \
		"${BATS_TEST_DIRNAME}/../../../_lib/bash4-features-check.sh" \
		"$BATS_TEST_TMPDIR/pf-content"
}

# _big_body <shebang> [early-line] [tail-line] — ~350KB of content with a
# feature optionally placed before or after the buffer-pressure filler.
# One home for the 10000-line constant (phase1 simplifier).
_big_body() {
	awk -v sb="$1" -v early="${2:-}" -v tl="${3:-}" \
		'BEGIN{print sb; if (early != "") print early; for (i = 0; i < 10000; i++) print "echo filler line for buffer pressure"; if (tl != "") print tl}'
}

@test "large content does not SIGPIPE shebang extraction into a spurious BLOCK" {
	# `printf | head -1` under the commit gate's pipefail broke on blobs
	# past the pipe buffer; a ~350KB safe-shebang file must pass.
	local big
	big=$(_big_body '#!/usr/bin/env bash')
	_chk_pipefail "$big"
	[ "$status" -eq 0 ] || return 1
	[[ $output != *'cannot extract shebang'* ]]
}

@test "large bin-bash content still detects its bash-4 feature at the tail" {
	local big
	big=$(_big_body '#!/bin/bash' '' 'declare -A m=()')
	_chk_pipefail "$big"
	[ "$status" -eq 1 ] || return 1
	[[ $output == *'declare -A'* ]]
}

@test "feature EARLY in large content is a finding, not a detector error" {
	# The same SIGPIPE class one function over (#2652 phase1,
	# live-probed): grep -Eq exits on its first match, so an EARLY match
	# SIGPIPE'd _b4_hit's printf and the rc-141 fail-closed turned a
	# real finding into 'detector errored'. The tail-placement test
	# above cannot catch this — grep reaches EOF there.
	local big
	big=$(_big_body '#!/bin/bash' 'declare -A m=()')
	_chk_pipefail "$big"
	[ "$status" -eq 1 ] || return 1
	[[ $output == *'declare -A'* ]] || return 1
	[[ $output != *'detector errored'* ]]
}
