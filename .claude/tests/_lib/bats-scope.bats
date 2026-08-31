#!/usr/bin/env bats
# covers: _lib/bats-scope.sh
#
# (#2642) The scope predicate, and the checks that keep it a single one.
#
# The answer to "does the bats discipline apply to this file" lived in three
# byte-identical copies and was wrong in all three: it listed CONSUMER paths
# (.claude/scripts, .claude/hooks, ...) which in this repo are untracked
# symlinks holding zero tracked files, so it matched `scripts/` alone —
# 50 of 229 production files. The commit gate allowed untested hooks/,
# the push gate hashed blobs it never looked at, and --coverage reported a
# percentage over the wrong denominator (~60% printed, 58.5% true across
# everything, which is precisely why nobody noticed).

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

# ---- the roots helper ----------------------------------------------------

@test "bats-scope: roots lists only directories that EXIST" {
	# find returns rc 1 on a missing starting path, and under pipefail that
	# aborts the caller — the exact bug v0.9.4 (#53) fixed in test.sh.
	# Filtering here is what keeps it fixed for every caller.
	run bash -c "set -uo pipefail
		cd '$REPO_ROOT'
		. '$LIB'
		bats_scope_roots"
	[ "$status" -eq 0 ]
	[ -n "$output" ] || {
		echo "no roots at all in the plugin repo — the list cannot be right"
		return 1
	}
	local r
	while IFS= read -r r; do
		[ -n "$r" ] || continue
		[ -d "$REPO_ROOT/$r" ] || {
			echo "roots listed a directory that does not exist: $r"
			return 1
		}
	done <<<"$output"
	# And it must actually include this repo's own production dirs, or the
	# coverage denominator is back where it started.
	[[ $output == *hooks* ]] || {
		echo "roots omits hooks/: $output"
		return 1
	}
}

@test "bats-scope: roots succeeds in a repo with none of the dirs" {
	# rc 0 with empty output, not rc 1 — callers use it under `set -e`.
	local tmp
	tmp=$(mktemp -d -t bats-scope.XXXXXX)
	run bash -c "set -euo pipefail
		cd '$tmp'
		. '$LIB'
		bats_scope_roots
		echo REACHED"
	rm -rf "$tmp"
	[ "$status" -eq 0 ] || {
		echo "roots failed in a bare directory (rc $status): $output"
		return 1
	}
	[[ $output == *REACHED* ]] || {
		echo "the caller did not survive an empty root set: $output"
		return 1
	}
}

# ---- the thing that keeps it ONE copy ------------------------------------

@test "#2642: no consumer sees a duplicate of the scope list" {
	# Three byte-identical copies are how this stayed wrong: fixing one
	# leaves the others lying, and nothing compared them. The predicate is
	# the only place the list may appear.
	local hits
	hits=$(cd "$REPO_ROOT" && grep -rn 'local-backups/\*' \
		--include='*.sh' hooks scripts pre-commit-hooks skills 2>/dev/null |
		grep -v '^_lib/bats-scope.sh:' || true)
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
		grep -qE 'command -v (bats_in_scope|bats_scope_roots|bats_scope_files)' "$REPO_ROOT/$f" ||
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
	hits=$(cd "$REPO_ROOT" && grep -rlE 'bats|scripts/test\.sh' .github/workflows/ 2>/dev/null || true)
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
	[[ $output == *"refusing"* ]] || {
		echo "the refusal does not say why: $output"
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
