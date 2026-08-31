#!/usr/bin/env bats
# covers: _lib/bats-scope.sh
#
# (#2642) The scope predicate, and the checks that keep it a single one.
#
# The answer to "does the bats discipline apply to this file" lived in three
# places — the same directory SET, though not byte-identical: two case-globs
# and one word list. It listed CONSUMER paths (.claude/scripts,
# .claude/hooks, ...), of which three exist here as symlinks and three do
# not exist at all, and the whole .claude tree is gitignored — so it matched
# `scripts/` alone: 50 of 229 production files. The commit gate allowed
# untested hooks/, the push gate hashed blobs it never looked at, and
# --coverage reported over the wrong denominator: exactly 60% printed
# (30/50) against 58.95% true across all 229, which is precisely why
# nobody noticed.

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	LIB="$REPO_ROOT/_lib/bats-scope.sh"
	[ -r "$LIB" ]
}

# Run a snippet with the library sourced, under the callers' own options.
_scope() { # $1 = snippet
	run bash -c "set -uo pipefail
		. '$LIB'
		$1"
}

# ---- the predicate -------------------------------------------------------

@test "bats-scope: the plugin's OWN production dirs are in scope" {
	# The regression. Every one of these returned 'out of scope' before,
	# which is what let a touched hook commit and push with no test.
	local d
	for d in hooks _lib pre-commit-hooks skills scripts; do
		_scope "bats_in_scope '$d/thing.sh'"
		[ "$status" -eq 0 ] || {
			echo "$d/thing.sh is out of scope — this is the 22% bug"
			return 1
		}
	done
}

@test "bats-scope: the CONSUMER install paths stay in scope" {
	# One library serves both layouts; widening must not drop the paths
	# the original list did cover, or consumers silently lose the gate.
	local d
	for d in .claude/scripts .claude/hooks .claude/skills .claude/local-backups; do
		_scope "bats_in_scope '$d/thing.sh'"
		[ "$status" -eq 0 ] || {
			echo "$d/thing.sh lost its scope in the widening"
			return 1
		}
	done
}

@test "bats-scope: non-shell files are never in scope" {
	local f
	for f in scripts/notes.md hooks/config.yml _lib/data.json scripts/thing; do
		_scope "bats_in_scope '$f'"
		[ "$status" -ne 0 ] || {
			echo "$f was treated as a shell file"
			return 1
		}
	done
}

@test "bats-scope: tests, .git and vendored trees are excluded" {
	# .claude/tests is Layer 2's business — gating a test file on having
	# its own test is a loop. .git/ holds hooks git generates.
	local f
	for f in .claude/tests/_lib/thing.bats .claude/tests/helper.sh .git/hooks/pre-commit.sh node_modules/x/y.sh; do
		_scope "bats_in_scope '$f'"
		[ "$status" -ne 0 ] || {
			echo "$f should not be gated: $f"
			return 1
		}
	done
}

@test "bats-scope: a path that merely CONTAINS a scope dir is not in scope" {
	# Prefix matching must be anchored. `vendor/scripts/x.sh` is not this
	# repo's scripts/, and `scriptsfoo/x.sh` is not scripts/ either.
	local f
	for f in vendor/scripts/x.sh third_party/hooks/y.sh scriptsfoo/z.sh hooksy/a.sh; do
		_scope "bats_in_scope '$f'"
		[ "$status" -ne 0 ] || {
			echo "unanchored match: $f was treated as in scope"
			return 1
		}
	done
}

@test "bats-scope: an empty path is out of scope, not a crash" {
	_scope "bats_in_scope ''"
	[ "$status" -ne 0 ]
	_scope "bats_in_scope"
	[ "$status" -ne 0 ]
}

@test "bats-scope: BATS_SCOPE_DIRS overrides the default set" {
	# The documented consumer escape. Without it, a repo with unrelated
	# root hooks/ has no way back to the narrow rule short of editing the
	# plugin.
	run bash -c "set -uo pipefail
		export BATS_SCOPE_DIRS='onlyhere'
		. '$LIB'
		bats_in_scope 'onlyhere/x.sh' && echo IN
		bats_in_scope 'scripts/x.sh' || echo OUT"
	[ "$status" -eq 0 ]
	[[ $output == *IN* ]] || {
		echo "the override did not take: $output"
		return 1
	}
	[[ $output == *OUT* ]] || {
		echo "the default set still applied under an override: $output"
		return 1
	}
}

# (bats_scope_roots was removed with its tests: once every consumer moved
# to bats_scope_files, nothing called it. Dead code carrying its own
# dedicated coverage is worse than no code — the tests keep passing and
# read as evidence that something is exercised.)

# ---- the thing that keeps it ONE copy ------------------------------------

@test "#2642: no consumer sees a duplicate of the scope list" {
	# Three byte-identical copies are how this stayed wrong: fixing one
	# leaves the others lying, and nothing compared them. The predicate is
	# the only place the list may appear.
	local hits
	# _lib IS searched — it was omitted, which made the self-exclusion on
	# the next line dead code and left the most likely home for a fourth
	# copy (a _lib helper, now that _lib is in scope) invisible. Two agents
	# pointed at the dead filter before anyone noticed why it was dead.
	#
	# grep's rc is CAPTURED: rc 1 is "no matches", the passing case; rc >1
	# is a real failure (a missing root after a rename) and must not read
	# as clean, which `|| true` made it.
	local grc=0
	hits=$(cd "$REPO_ROOT" && grep -rn 'local-backups/\*' \
		--include='*.sh' hooks scripts pre-commit-hooks skills _lib |
		grep -v '^_lib/bats-scope.sh:') || grc=$?
	[ "$grc" -le 1 ] || {
		echo "the duplication search itself failed (rc $grc) — this test checked nothing"
		return 1
	}
	[ -z "$hits" ] || {
		echo "the scope list is duplicated outside _lib/bats-scope.sh:"
		printf '%s\n' "$hits"
		echo "Call bats_in_scope instead."
		return 1
	}
}

@test "#2642: every consumer of the scope FAILS CLOSED without the library" {
	# An unloadable predicate must never read as "nothing is in scope" —
	# that is the gate switching itself off while reporting success, which
	# is the exact class this epic exists to remove. Each consumer must
	# name the library and refuse.
	local f missing=""
	for f in pre-commit-hooks/bats-gate.sh hooks/pre-push-pipeline-gate.sh scripts/test.sh; do
		grep -q 'bats-scope\.sh' "$REPO_ROOT/$f" || missing="$missing $f(no-source)"
		# It must react to the ABSENCE, not merely source it.
		# `type -t ... = function`, NOT `command -v`. command -v also finds
		# EXECUTABLES on PATH, so a stray file named bats_in_scope anywhere
		# on $PATH would satisfy a consumer's guard and then BE the scope
		# predicate — an external program deciding what the gate enforces.
		# Requiring a shell function means only the sourced library can
		# satisfy it, and this test requires the consumers to require that.
		#
		# (bats_scope_roots is not an accepted alternative: it was deleted,
		# and leaving it in the alternation let a consumer satisfy the guard
		# by naming a function that no longer exists.)
		grep -qE 'type -t (bats_in_scope|bats_scope_files).*function' "$REPO_ROOT/$f" ||
			missing="$missing $f(no-guard)"
	done
	[ -z "$missing" ] || {
		echo "consumer(s) not wired to fail closed:$missing"
		return 1
	}
}

@test "#2642: bats stays OUT of CI — the enforcement is local" {
	# Operator decision, 2026-08-30: a 15-18 minute serial suite does not
	# belong on billed Actions minutes. The commit and push gates already
	# enforce it locally and for free; this asserts nobody quietly adds a
	# workflow later.
	local hits
	# grep rc captured, as in the duplication guard above: rc 1 is "no
	# matches" (the passing case), rc >1 is a real failure — a missing
	# workflows directory after a restructure — and `|| true` made a search
	# that never ran indistinguishable from a search that found nothing.
	local grc=0
	hits=$(cd "$REPO_ROOT" && grep -rlE 'bats|scripts/test\.sh' .github/workflows/) || grc=$?
	[ "$grc" -le 1 ] || {
		echo "the CI-policy search itself failed (rc $grc) — this test checked nothing"
		return 1
	}
	[ -z "$hits" ] || {
		echo "a CI workflow now references bats/test.sh — the enforcement is deliberately LOCAL:"
		printf '%s\n' "$hits"
		return 1
	}
}

# ---- the file list, from git ---------------------------------------------

@test "bats-scope: files come from GIT, not a filesystem walk" {
	# The authoritative source. `find` over directories answers a different
	# question: .claude/hooks here is a SYMLINK to ../hooks, which find does
	# not follow — so the two agree by accident today and would double-count
	# on a consumer where that path is a real directory. find also counts
	# UNTRACKED files, none of which can carry a covering test.
	local tmp
	tmp=$(mktemp -d -t bats-scope-git.XXXXXX)
	(
		cd "$tmp"
		git init -q
		mkdir -p hooks
		printf '#!/bin/bash\n' >hooks/tracked.sh
		printf '#!/bin/bash\n' >hooks/untracked.sh
		git add hooks/tracked.sh
		git -c user.email=t@t -c user.name=t commit -qm init
	)
	run bash -c "set -uo pipefail
		cd '$tmp'
		. '$LIB'
		bats_scope_files"
	rm -rf "$tmp"
	[ "$status" -eq 0 ] || {
		echo "bats_scope_files failed: $output"
		return 1
	}
	[[ $output == *hooks/tracked.sh* ]] || {
		echo "the tracked file is missing from the list: $output"
		return 1
	}
	[[ $output != *untracked* ]] || {
		echo "an UNTRACKED file was counted — it cannot carry a covering test: $output"
		return 1
	}
}

@test "bats-scope: the file list is not silently emptied by NUL handling" {
	# The trap this hit on its first run. `out=\$(git ls-files -z ...)` drops
	# every NUL, because bash cannot hold them in a variable — the listing
	# collapses to one string, `read -d ''` finds no delimiter, and the
	# function returns NOTHING. Which reads as "no shell files in scope":
	# a denominator of zero and a gate with nothing to gate.
	#
	# This repo has 200+ in-scope files, so a near-empty answer is proof of
	# that bug and nothing else.
	run bash -c "set -uo pipefail
		cd '$REPO_ROOT'
		. '$LIB'
		bats_scope_files | grep -c ."
	[ "$status" -eq 0 ]
	[ "$output" -gt 100 ] || {
		echo "only $output in-scope files — the listing collapsed (NUL handling?)"
		return 1
	}
}

@test "bats-scope: files REFUSES rather than reporting an empty set on git failure" {
	# An empty list is indistinguishable from "this repo has no shell
	# files", and reads downstream as full coverage of nothing. Outside a
	# git repo the answer is not zero, it is unknown.
	local tmp
	tmp=$(mktemp -d -t bats-scope-nogit.XXXXXX)
	run bash -c "set -uo pipefail
		cd '$tmp'
		. '$LIB'
		bats_scope_files"
	rm -rf "$tmp"
	[ "$status" -eq 2 ] || {
		echo "outside a git repo, bats_scope_files returned $status (expected 2): $output"
		return 1
	}
	[[ $output == *"efusing"* ]] || {
		echo "the refusal does not say what it is refusing to do: $output"
		return 1
	}
	# GIT'S OWN WORDS must survive. "not a git repository" and "index file
	# corrupt" want completely different responses, and an rc alone cannot
	# tell them apart — the first version sent git's stderr to /dev/null and
	# reported a bare rc=128.
	[[ $output == *"not a git repository"* ]] || {
		echo "git's own diagnosis was discarded; only an rc survived: $output"
		return 1
	}
}

# ---- BATS_SCOPE_DIRS edge cases ------------------------------------------

@test "bats-scope: a trailing slash in BATS_SCOPE_DIRS still matches" {
	# The variable is operator-facing, so 'hooks/' is a spelling somebody
	# will use. It must not silently match nothing.
	run bash -c "set -uo pipefail
		export BATS_SCOPE_DIRS='hooks/'
		. '$LIB'
		bats_in_scope 'hooks/x.sh'"
	[ "$status" -eq 0 ] || {
		echo "a trailing slash silently disabled the entry"
		return 1
	}
}

@test "bats-scope: the directory itself, with no file under it, is not in scope" {
	# `hooks` is not a shell file; only things beneath it are candidates.
	_scope "bats_in_scope 'hooks'"
	[ "$status" -ne 0 ]
	_scope "bats_in_scope 'hooks.sh'"
	[ "$status" -ne 0 ] || {
		echo "a file merely PREFIXED by a scope dir name was matched"
		return 1
	}
}

@test "bats-scope: an empty BATS_SCOPE_DIRS puts nothing in scope, quietly" {
	# Deliberate: it is the documented way to turn the discipline off for a
	# repo. It must not error — but the CONSUMERS must still fail closed on
	# a missing library, which is a different condition and tested there.
	run bash -c "set -uo pipefail
		export BATS_SCOPE_DIRS=''
		. '$LIB'
		bats_in_scope 'hooks/x.sh' && echo IN || echo OUT"
	[ "$status" -eq 0 ]
	[[ $output == *OUT* ]] || {
		echo "an empty scope list still matched: $output"
		return 1
	}
}

# ---- the consumers' fail-closed paths, exercised ------------------------

# NOT TESTED BEHAVIOURALLY, and saying so rather than pretending.
#
# Phase 0.5 (conf 8) asked for a behavioural test of the push gate's
# fail-closed path, matching the one the commit gate has. It is not
# reachable at proportionate cost: pre-push-pipeline-gate.sh exits at an
# earlier check (cr_phase2_clean_for_sha, which wants a completed CR review
# on record for the pushed sha) long before it reaches the scope block, so
# a fixture would have to fake the whole CR ledger to get there.
#
# What IS enforced is structural, in "every consumer of the scope FAILS
# CLOSED without the library" above: that test greps each of the three
# consumers for both the source and a `command -v` guard reacting to its
# absence, so a consumer that stopped refusing would fail it. That is
# weaker than executing the branch and is recorded as such — an
# almost-behavioural test that quietly exercised an earlier exit would be
# worse than an honest structural one.

@test "#2642: the CONSUMER layout (.claude/_lib) is a real fallback" {
	# Second entry in every consumer's probe, and untested. A plugin
	# installed under .claude/ resolves there; if that arm were broken the
	# library would be 'missing' for every consumer repo while working
	# perfectly in this one, which is the hardest kind of bug to see from
	# here.
	local fake="$BATS_TEST_TMPDIR/consumer"
	mkdir -p "$fake/scripts" "$fake/.claude/_lib"
	cp "$LIB" "$fake/.claude/_lib/bats-scope.sh"
	[ ! -e "$fake/_lib/bats-scope.sh" ] || return 1
	# Resolve exactly as the consumers do, from the script's own dir.
	run bash -c "set -uo pipefail
		_scope_self=\$(cd '$fake/scripts/..' && pwd)
		for c in \"\$_scope_self/_lib/bats-scope.sh\" \"\$_scope_self/.claude/_lib/bats-scope.sh\"; do
			[ -r \"\$c\" ] && { . \"\$c\"; break; }
		done
		command -v bats_in_scope >/dev/null && echo RESOLVED"
	[ "$status" -eq 0 ] || {
		echo "the consumer-layout probe failed: $output"
		return 1
	}
	[[ $output == *RESOLVED* ]] || {
		echo "the .claude/_lib fallback did not resolve the library: $output"
		return 1
	}
}

@test "bats-scope: the SCOPE FILTER applies to the git listing too" {
	# bats_scope_files asks git for every *.sh and then filters. If the
	# filter were skipped there, the denominator would include test helpers
	# and vendored shell — files that cannot carry a covering test and would
	# push measured coverage down for no reason anyone could act on.
	local tmp
	tmp=$(mktemp -d -t bats-scope-filter.XXXXXX)
	(
		cd "$tmp"
		git init -q
		mkdir -p hooks .claude/tests vendor
		printf '#!/bin/bash\n' >hooks/in.sh
		printf '#!/bin/bash\n' >.claude/tests/helper.sh
		printf '#!/bin/bash\n' >vendor/out.sh
		git add -A
		git -c user.email=t@t -c user.name=t commit -qm init
	)
	run bash -c "set -uo pipefail
		cd '$tmp'
		. '$LIB'
		bats_scope_files"
	rm -rf "$tmp"
	[ "$status" -eq 0 ]
	[[ $output == *hooks/in.sh* ]] || {
		echo "an in-scope tracked file is missing: $output"
		return 1
	}
	[[ $output != *helper.sh* ]] || {
		echo "a test helper was counted — Layer 2 owns those, and gating a test on having its own test is a loop: $output"
		return 1
	}
	[[ $output != *vendor/out.sh* ]] || {
		echo "vendored shell was counted: $output"
		return 1
	}
}
