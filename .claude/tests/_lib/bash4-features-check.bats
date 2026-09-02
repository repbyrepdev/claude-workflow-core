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
	[ "$status" -eq 0 ]
}

@test "#!/bin/bash with clean 3.2 code passes" {
	run _chk $'#!/bin/bash\nset -u\nfor f in a b; do echo "$f"; done'
	[ "$status" -eq 0 ]
}

@test "mapfile -d flags (bash 4.4)" {
	run _chk $'#!/bin/bash\nmapfile -d "" arr < x'
	[ "$status" -eq 1 ]
	[[ $output == *"mapfile -d"* ]]
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
	[ "$status" -ne 0 ]
}
