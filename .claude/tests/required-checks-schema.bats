#!/usr/bin/env bats
# covers: .github/required-checks-list.yml scripts/bootstrap-repo.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
	CHECKS_YML="${REPO_ROOT}/.github/required-checks-list.yml"
	SCRIPT="${REPO_ROOT}/scripts/bootstrap-repo.sh"
	TEST_TMP=$(mktemp -d -t required-checks-schema.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */required-checks-schema.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Returns 0 iff $1 is a comma-separated list of KNOWN events with NO empty
# element — leading (",push"), interior ("a,,b"), or TRAILING ("push,"). Word
# splitting silently DROPS a trailing empty field, so the token loop alone never
# sees "push,"; the wrapped-comma guard catches it (CR-in-CI #2540). `null` is
# the caller's concern; this helper only sees a real value. Extracted so the
# malformed-list cases can assert it directly instead of only through the YAML.
_event_list_ok() {
	local ev=$1 _tok _ntok=0 _saved_ifs=$IFS
	# Empty element anywhere → reject. `,$ev,` wraps the ends so a leading or
	# trailing comma also produces the `,,` that this matches.
	case ",$ev," in
	*,,*) return 1 ;;
	esac
	IFS=','
	for _tok in $ev; do
		# strip surrounding whitespace from ", "-joined tokens
		_tok=${_tok#"${_tok%%[![:space:]]*}"}
		_tok=${_tok%"${_tok##*[![:space:]]}"}
		case "$_tok" in
		pull_request | push | schedule | workflow_dispatch) _ntok=$((_ntok + 1)) ;;
		*)
			IFS=$_saved_ifs
			return 1
			;;
		esac
	done
	IFS=$_saved_ifs
	# A whitespace-only value ("  ") splits into ZERO words, so the enum above
	# never runs and it would pass by default — fail closed on it too.
	[ "$_ntok" -gt 0 ]
}

# Validate every entry in a given section ($1 = "required" or "advisory")
_validate_section() {
	local section=$1
	count=$(yq -r ".$section | length" "$CHECKS_YML")
	[ "$count" -ge 0 ]
	[ "$count" -eq 0 ] && return 0
	for i in $(seq 0 $((count - 1))); do
		# check_name: non-empty, not null
		name=$(yq -r ".${section}[$i].check_name" "$CHECKS_YML")
		[ -n "$name" ]
		[ "$name" != "null" ]
		# workflow_file: non-empty string ending .yml OR literal "null"
		wf=$(yq -r ".${section}[$i].workflow_file" "$CHECKS_YML")
		if [ "$wf" != "null" ]; then
			[[ $wf =~ \.ya?ml$ ]] || return 1
		fi
		# event: enum {pull_request, push, schedule, workflow_dispatch}, OR a
		# comma-separated LIST of them, OR literal "null".
		#
		# The list form is required, not a laxity: a workflow legitimately fires
		# on more than one event (gitleaks.yml declares both `pull_request:` and
		# `push: branches:[main]`), so `event: pull_request, push` is the
		# TRUTHFUL description of it. The old single-token enum rejected that and
		# made this test red on main — the schema was narrower than the domain it
		# describes. Validate each token so the enum still catches real typos.
		ev=$(yq -r ".${section}[$i].event" "$CHECKS_YML")
		if [ "$ev" != "null" ]; then
			_event_list_ok "$ev" || return 1
		fi
		# paired contract: workflow_file null IFF event null
		[ "$wf" = "null" ] && [ "$ev" != "null" ] && return 1
		[ "$wf" != "null" ] && [ "$ev" = "null" ] && return 1
		# notes: non-empty
		notes=$(yq -r ".${section}[$i].notes" "$CHECKS_YML")
		[ -n "$notes" ]
		[ "$notes" != "null" ]
	done
}

@test "event-list validator rejects empty elements (leading, interior, trailing)" {
	# Trailing "push," is the one word-splitting drops — the exact case CR-in-CI
	# #2540 found accepted. Whitespace-only and unknown tokens must also fail.
	for bad in "" " " ",push" "pull_request,,push" "push," "push, ,pull_request" "bogus" "push,bogus"; do
		run _event_list_ok "$bad"
		if [ "$status" -eq 0 ]; then
			echo "validator wrongly ACCEPTED malformed event list: [$bad]" >&2
			# `return 1`, not `false`: bats has no set -e, so a bare `false` mid-loop
			# is masked by the loop's final iteration status. `return` aborts the
			# @test immediately on the FIRST wrongly-accepted input.
			return 1
		fi
		# the validator is rc-only — assert it emits NOTHING on stdout, so a stray
		# debug/error leak would be caught (CR-in-CI #2540: assert captured output).
		[ -z "$output" ] || return 1
	done
}

@test "event-list validator accepts valid single and multi-event lists" {
	for good in "push" "pull_request" "pull_request, push" "pull_request,push" "schedule, workflow_dispatch"; do
		run _event_list_ok "$good"
		if [ "$status" -ne 0 ]; then
			echo "validator wrongly REJECTED valid event list: [$good]" >&2
			return 1
		fi
		[ -z "$output" ] || return 1 # rc-only contract: no stray stdout
	done
}

@test "required-checks-list.yml is valid YAML" {
	run yq . "$CHECKS_YML"
	[ "$status" -eq 0 ]
}

@test "top-level keys are exactly {required, advisory}" {
	keys=$(yq -r 'keys | sort | join(",")' "$CHECKS_YML")
	[ "$keys" = "advisory,required" ]
}

@test "required[] is non-empty" {
	run yq -r '.required | length' "$CHECKS_YML"
	[ "$status" -eq 0 ]
	[ "$output" -gt 0 ]
}

@test "advisory[] section is declared (may be empty)" {
	run yq -r 'has("advisory")' "$CHECKS_YML"
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
}

@test "every required[] entry conforms to the schema (type + paired contract + enum)" {
	_validate_section required
}

@test "every advisory[] entry conforms to the schema (when non-empty)" {
	_validate_section advisory
}

@test "check_name values are unique within required[]" {
	total=$(yq -r '.required | length' "$CHECKS_YML")
	unique=$(yq -r '.required[].check_name' "$CHECKS_YML" | sort -u | wc -l | tr -d ' ')
	[ "$total" -eq "$unique" ]
}

@test "every required[] workflow_file references an existing workflow file" {
	count=$(yq -r '.required | length' "$CHECKS_YML")
	for i in $(seq 0 $((count - 1))); do
		wf=$(yq -r ".required[$i].workflow_file" "$CHECKS_YML")
		[ "$wf" = "null" ] && continue
		[ -f "${REPO_ROOT}/.github/workflows/${wf}" ]
	done
}

@test "required[] contains the minimum-required check set (CodeRabbit, gitleaks, pr-lint)" {
	names=$(yq -r '.required[].check_name' "$CHECKS_YML")
	for required in CodeRabbit gitleaks pr-lint; do
		echo "$names" | grep -qFx "$required"
	done
}

@test "bootstrap-repo.sh heredoc declares the same top-level keys as the live file" {
	# Extract the heredoc, render through yq, compare keys to live file.
	awk "/^_write \\.github\\/required-checks-list\\.yml 644 <<'EOF'$/,/^EOF$/" "$SCRIPT" |
		sed '1d;$d' >"$TEST_TMP/heredoc.yml"
	heredoc_keys=$(yq -r 'keys | sort | join(",")' "$TEST_TMP/heredoc.yml")
	live_keys=$(yq -r 'keys | sort | join(",")' "$CHECKS_YML")
	[ "$heredoc_keys" = "$live_keys" ]
}

@test "bootstrap-repo.sh heredoc required[] entries conform to the schema" {
	awk "/^_write \\.github\\/required-checks-list\\.yml 644 <<'EOF'$/,/^EOF$/" "$SCRIPT" |
		sed '1d;$d' >"$TEST_TMP/heredoc.yml"
	count=$(yq -r '.required | length' "$TEST_TMP/heredoc.yml")
	[ "$count" -gt 0 ]
	for i in $(seq 0 $((count - 1))); do
		name=$(yq -r ".required[$i].check_name" "$TEST_TMP/heredoc.yml")
		[ -n "$name" ]
		[ "$name" != "null" ]
		notes=$(yq -r ".required[$i].notes" "$TEST_TMP/heredoc.yml")
		[ -n "$notes" ]
		[ "$notes" != "null" ]
	done
}
