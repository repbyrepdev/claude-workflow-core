#!/usr/bin/env bats
# covers: skills/cr-plan/run.sh
#
# (#2556) Every sub-issue carried its phase TITLE and nothing else. #2556 was
# titled "Registration, operator toggle, tests, and docs" — four deliverables,
# a body that described none of them, and a pointer to a different issue's
# comment thread as the only way to learn what the work was. A tracker entry
# you cannot work from, review for completeness, or judge done against.
#
# These drive the REAL skill with a PATH-stubbed `gh` and a stub EPIC_SKILL
# that captures the --sub-body-file arguments, so what is asserted is the body
# the skill actually hands to github-epic-creation. The first cut of this
# extraction invented three phantom phases by matching BOTH heading forms at
# once, and nothing caught it until it ran against the real #2551 plan — so
# the phantom-phase case below is the point of the file, not a footnote.
# shellcheck disable=SC2030,SC2031

setup() {
	PLUGIN=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	SKILL="$PLUGIN/skills/cr-plan/run.sh"
	[ -x "$SKILL" ]
	command -v jq >/dev/null
	TEST_TMP=$(mktemp -d -t cr-plan-bodies.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	CAPTURE="$TEST_TMP/capture"
	mkdir -p "$CAPTURE" "$TEST_TMP/bin"
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
	# gh stub: the comments fetch returns $GH_PLAN_BODY, every other view
	# returns a minimal OPEN issue that clears the parse guards.
	cat >"$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
	case "$*" in
	*"--json comments"*)
		printf "%s" "${GH_PLAN_BODY:-}"
		exit 0
		;;
	esac
	printf '%s' '{"number":999,"state":"OPEN","title":"feat: the thing","labels":[{"name":"plan-me"}],"body":"an ordinary issue body"}'
	exit 0
fi
exit 0
EOF
	chmod +x "$TEST_TMP/bin/gh"
	# EPIC_SKILL stub: copies each --sub-body-file into $CAPTURE in the order
	# the skill emitted them, so ORDER is assertable and not just content.
	cat >"$TEST_TMP/bin/epic-stub" <<'EOF'
#!/usr/bin/env bash
n=0
while [ "$#" -gt 0 ]; do
	if [ "$1" = "--sub-body-file" ]; then
		n=$((n + 1))
		cp "$2" "$CAPTURE/$(printf '%02d' "$n").md"
		shift 2
		continue
	fi
	shift
done
printf 'sub-bodies captured: %s\n' "$n"
exit 0
EOF
	chmod +x "$TEST_TMP/bin/epic-stub"
}

teardown() {
	cd /tmp 2>/dev/null || true
	case "${TEST_TMP:-}" in
	*/cr-plan-bodies.*) rm -rf "$TEST_TMP" ;;
	esac
	return 0
}

_run_parse() { # $1 = plan comment body
	run env PATH="$TEST_TMP/bin:$PATH" APPROVE=1 \
		CAPTURE="$CAPTURE" EPIC_SKILL="$TEST_TMP/bin/epic-stub" \
		GH_PLAN_BODY="$1" "$SKILL" parse 999
}

_captured() { # count of captured sub-bodies
	find "$CAPTURE" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' '
}

_body() { # $1 = 1-based index
	cat "$CAPTURE/$(printf '%02d' "$1").md" 2>/dev/null
}

# A plan in the `### Phase N:` form whose task lists CONTAIN NUMBERED STEPS.
# This is the shape of the real #2551 plan, and the shape that broke the first
# implementation.
_plan_heading() {
	cat <<'EOF'
Here is the plan.

## Implementation Steps

### Phase 1: The library

1. Write the parser in `_lib/task-queue.sh`.
2. Give it a three-state classifier.
3. Cover it with tests.

### Phase 2: The hooks

1. Add the PostToolUse tracker.
2. Add the Stop nudge.

### Phase 3: Docs

1. Update the README.

## Risks

Nothing here should be treated as a phase.
EOF
}

_plan_numbered() {
	cat <<'EOF'
## Phases

1. Build the parser library
   - handle the absent case
   - handle the empty case
2. Wire up the hooks
   - tracker, stop nudge, reconcile
3. Document the toggle

## Notes

Not a phase.
EOF
}

@test "phase bodies: each sub-issue carries ITS OWN phase's tasks (#2556)" {
	cd "$TEST_TMP"
	_run_parse "$(_plan_heading)"
	[ "$status" -eq 0 ] || {
		echo "parse failed: $output"
		return 1
	}
	[ "$(_captured)" = "3" ] || {
		echo "expected 3 sub-bodies, got $(_captured)"
		return 1
	}
	local b1 b2 b3
	b1=$(_body 1)
	b2=$(_body 2)
	b3=$(_body 3)
	# Phase 1's own tasks are present...
	[[ $b1 == *"Write the parser"* ]] || {
		echo "phase 1 body lost its tasks: $b1"
		return 1
	}
	# ...and phase 2's are NOT. An off-by-one in the index would still show
	# "tasks present" while showing the WRONG phase's, which is worse than
	# the empty body #2556 complained about.
	[[ $b1 != *"Add the PostToolUse tracker"* ]] || {
		echo "phase 1 body leaked phase 2's tasks: $b1"
		return 1
	}
	[[ $b2 == *"Add the PostToolUse tracker"* ]] || {
		echo "phase 2 body lost its tasks: $b2"
		return 1
	}
	[[ $b2 != *"Write the parser"* ]] || {
		echo "phase 2 body leaked phase 1's tasks: $b2"
		return 1
	}
	[[ $b3 == *"Update the README"* ]] || {
		echo "phase 3 body lost its tasks: $b3"
		return 1
	}
}

@test "phase bodies: numbered steps inside a body do NOT become phantom phases" {
	# The first cut matched both heading forms unconditionally, so every
	# "1." inside a phase's task list started a new phase. Three real phases
	# became six, each of the phantoms carrying a fragment of a task list as
	# its title. Caught only by running against the real #2551 plan.
	cd "$TEST_TMP"
	_run_parse "$(_plan_heading)"
	[ "$status" -eq 0 ]
	[ "$(_captured)" = "3" ] || {
		echo "phantom phases: expected 3, got $(_captured)"
		find "$CAPTURE" -name '*.md' -exec head -3 {} \;
		return 1
	}
	# And the reported count agrees with what was handed over.
	[[ $output == *"parsed 3 phase(s)"* ]] || {
		echo "the skill reported a different count than it emitted: $output"
		return 1
	}
}

@test "phase bodies: the NUMBERED fallback form also carries tasks" {
	cd "$TEST_TMP"
	_run_parse "$(_plan_numbered)"
	[ "$status" -eq 0 ] || {
		echo "parse failed: $output"
		return 1
	}
	[ "$(_captured)" = "3" ] || {
		echo "expected 3 sub-bodies, got $(_captured)"
		return 1
	}
	local b1
	b1=$(_body 1)
	[[ $b1 == *"handle the absent case"* ]] || {
		echo "numbered-form phase 1 lost its sub-bullets: $b1"
		return 1
	}
	[[ $b1 != *"tracker, stop nudge"* ]] || {
		echo "numbered-form phase 1 leaked phase 2's bullets: $b1"
		return 1
	}
}

@test "phase bodies: an unextractable body says so EXPLICITLY" {
	# A phase whose heading is immediately followed by the next heading has
	# no body. The sub-issue must say the list could not be extracted rather
	# than silently look like a phase with no tasks — the reader cannot tell
	# those apart, and one of them is a bug in this skill.
	cd "$TEST_TMP"
	_run_parse "$(printf '## Phases\n\n### Phase 1: Empty one\n### Phase 2: Has tasks\n\n- do the thing\n')"
	[ "$status" -eq 0 ]
	[ "$(_captured)" = "2" ]
	local b1 b2
	b1=$(_body 1)
	b2=$(_body 2)
	[[ $b1 == *"could not be extracted"* ]] || {
		echo "an empty phase body was silent about it: $b1"
		return 1
	}
	[[ $b2 == *"do the thing"* ]] || {
		echo "the phase that HAS a body lost it: $b2"
		return 1
	}
	# The citation survives in both branches — the copy supplements the CR
	# comment, it does not replace it as the authority.
	[[ $b1 == *"gh issue view 999 --comments"* ]] || return 1
	[[ $b2 == *"gh issue view 999 --comments"* ]] || return 1
}

@test "phase bodies: the copy is LABELLED as a copy, not passed off as the source" {
	cd "$TEST_TMP"
	_run_parse "$(_plan_heading)"
	[ "$status" -eq 0 ]
	local b1
	b1=$(_body 1)
	[[ $b1 == *"Tasks (copied from the CR plan)"* ]] || {
		echo "the copied task list is not labelled as a copy: $b1"
		return 1
	}
	[[ $b1 == *"remains the authority"* ]] || {
		echo "the body does not name the CR comment as authority: $b1"
		return 1
	}
}

@test "phase bodies: an UNTITLED phase does not desync titles from bodies" {
	# The awk heading test accepted a bare `### Phase 2`; the title grep
	# requires trailing title text and skipped it. So the awk index advanced
	# where the title list did not, and every later body landed under the
	# WRONG title — phase 2's tasks filed as the sub-issue named "Docs".
	# Worse than the empty body #2556 complained about: confidently wrong
	# rather than visibly missing.
	cd "$TEST_TMP"
	_run_parse "$(printf '## Phases\n\n### Phase 1: Library\n\n- build the library\n\n### Phase 2\n\n- orphan work that has no title\n\n### Phase 3: Docs\n\n- write the docs\n')"
	[ "$status" -eq 0 ]
	# Two TITLES were extracted (the untitled one is skipped), so two bodies.
	[ "$(_captured)" = "2" ] || {
		echo "expected 2 sub-bodies for 2 titles, got $(_captured)"
		return 1
	}
	local b1 b2
	b1=$(_body 1)
	b2=$(_body 2)
	[[ $b1 == *"build the library"* ]] || {
		echo "phase 1 body is wrong: $b1"
		return 1
	}
	# The body filed under "Docs" must be the DOCS body.
	[[ $b2 == *"write the docs"* ]] || {
		echo "the Docs sub-issue did not get the docs tasks: $b2"
		return 1
	}
	[[ $b2 != *"orphan work"* ]] || {
		echo "the Docs sub-issue got the untitled phase's tasks: $b2"
		return 1
	}
	# ...and it did not flow BACKWARDS into phase 1 either. A rejected Phase
	# marker still ends the phase above it; leaving the output file unchanged
	# appended the stray heading and its whole task list to the previous
	# sub-issue, which is the same misattribution in the other direction.
	[[ $b1 != *"orphan work"* ]] || {
		echo "the untitled phase's tasks flowed into phase 1: $b1"
		return 1
	}
	[[ $b1 != *"Phase 2"* ]] || {
		echo "a rejected Phase heading was copied into phase 1's body: $b1"
		return 1
	}
}

@test "phase bodies: bold and whitespace-only headings keep titles and bodies aligned" {
	# The two patterns that must agree are written in two languages (ERE in
	# grep, ERE in awk) against the same lines, so the interesting cases are
	# the ones where they could disagree WITHOUT either looking wrong:
	#   `### Phase 1: **Library**` — grep's `[^*#]+` stops at the asterisk,
	#     awk's `[^*#[:space:]]` refuses it. Both skip. Agreement by luck is
	#     still agreement, but only a test keeps it that way.
	#   `### Phase 2 ` — trailing whitespace and no title. grep's `[^*#]+`
	#     matches the SPACE, so the title survives grep and is then emptied
	#     by the trailing-space sed and dropped by the `[ -z ]` guard without
	#     advancing idx. awk refuses it outright.
	# If either side ever stops skipping one of these, the indices desync and
	# the last phase gets someone elses body — silently.
	cd "$TEST_TMP"
	_run_parse "$(printf '## Phases\n\n### Phase 1: **Library**\n\n- bold heading work\n\n### Phase 2 \n\n- whitespace heading work\n\n### Phase 3: Docs\n\n- write the docs\n')"
	[ "$status" -eq 0 ] || {
		echo "parse failed: $output"
		return 1
	}
	# Only "Docs" is a usable title, so exactly one sub-issue.
	[ "$(_captured)" = "1" ] || {
		echo "expected 1 usable title, got $(_captured) sub-bodies"
		return 1
	}
	local b1
	b1=$(_body 1)
	[[ $b1 == *"write the docs"* ]] || {
		echo "the Docs sub-issue did not receive the Docs tasks: $b1"
		return 1
	}
	[[ $b1 != *"bold heading work"* ]] || {
		echo "the Docs sub-issue received the bold phase's tasks: $b1"
		return 1
	}
}

@test "phase bodies: an @mention in plan text does not notify from the new issue" {
	# CR writes the plan, but it writes it FROM the source issue's text —
	# so an @mention typed by whoever filed that issue rides along and would
	# be replayed once per sub-issue created here, notifying someone about
	# an issue they never opened.
	cd "$TEST_TMP"
	_run_parse "$(printf '## Phases\n\n### Phase 1: Thing\n\n- ask @octocat and email a@b.com about it\n')"
	[ "$status" -eq 0 ]
	local b1
	b1=$(_body 1)
	[[ $b1 == *'`@octocat`'* ]] || {
		echo "the @mention was not neutralised: $b1"
		return 1
	}
	# An email address is not a mention and must not be mangled into one.
	[[ $b1 == *"a@b.com"* ]] || {
		echo "an email address was rewritten: $b1"
		return 1
	}
}

@test "phase bodies: plan text is never EXECUTED as shell" {
	# The body is interpolated into a heredoc via \$(cat "\$_pb"). The heredoc
	# delimiter is unquoted (it has to be — \$ptitle and the \$( ) block must
	# expand), so anything the FILE contains had better reach the sub-issue as
	# literal text. Command substitution inside the file's own content is not
	# re-evaluated by cat, and this pins that.
	cd "$TEST_TMP"
	_run_parse "$(printf '## Phases\n\n### Phase 1: Injection\n\n- run `$(touch %s/PWNED)` and ${HOME} and `whoami`\n' "$TEST_TMP")"
	[ "$status" -eq 0 ]
	[ ! -e "$TEST_TMP/PWNED" ] || {
		echo "plan text executed a command substitution"
		return 1
	}
	local b1
	b1=$(_body 1)
	[[ $b1 == *'$(touch'* ]] || {
		echo "the substitution was evaluated away instead of copied literally: $b1"
		return 1
	}
	[[ $b1 == *'${HOME}'* ]] || {
		echo "a parameter expansion in plan text was expanded: $b1"
		return 1
	}
}

@test "phase bodies: PHASE_MAX truncation drops bodies with the titles, not out of step" {
	# Truncating titles to PHASE_MAX while the body dir still holds every
	# phase would be harmless; the reverse — more titles than bodies — hands
	# out empty bodies. Pin that the two stay in step at the boundary.
	cd "$TEST_TMP"
	local plan="## Phases
"
	local i=1
	while [ "$i" -le 4 ]; do
		plan="$plan
### Phase $i: Thing $i

- task for phase $i
"
		i=$((i + 1))
	done
	run env PATH="$TEST_TMP/bin:$PATH" APPROVE=1 PHASE_MAX=2 \
		CAPTURE="$CAPTURE" EPIC_SKILL="$TEST_TMP/bin/epic-stub" \
		GH_PLAN_BODY="$plan" "$SKILL" parse 999
	[ "$status" -eq 0 ] || {
		echo "parse failed: $output"
		return 1
	}
	[ "$(_captured)" = "2" ] || {
		echo "PHASE_MAX=2 emitted $(_captured) sub-bodies"
		return 1
	}
	[[ $(_body 1) == *"task for phase 1"* ]] || return 1
	[[ $(_body 2) == *"task for phase 2"* ]] || {
		echo "the second body is not phase 2's: $(_body 2)"
		return 1
	}
	[[ $output == *"truncated to first 2"* ]] || {
		echo "truncation was silent: $output"
		return 1
	}
}
