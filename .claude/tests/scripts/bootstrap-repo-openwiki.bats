#!/usr/bin/env bats
# covers: scripts/bootstrap-repo.sh scripts/bootstrap-manifest.yml
#
# (#2629) The OpenWiki docs lane is seeded into EVERY bootstrapped repo
# rather than hidden behind a flag, which is only safe because both
# workflows are inert until deliberately armed. These tests pin that
# safety property — it is the entire justification for unconditional
# seeding, and a well-meaning "let's schedule it" edit would silently make
# every bootstrapped repo start spending AI credits.
#
# The full-bootstrap test runs the real script once (it generates a ~5.5k
# line lockfile via npm), so it asserts everything about the seeded output
# in one pass; the cheap cross-file invariants run without bootstrapping.
# shellcheck disable=SC2030,SC2031

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	SCRIPT="$REPO_ROOT/scripts/bootstrap-repo.sh"
	[ -x "$SCRIPT" ]
	TEST_TMP=$(mktemp -d -t br-openwiki.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	cd /tmp 2>/dev/null || true
	[ -n "${TEST_TMP:-}" ] && [[ $TEST_TMP == */br-openwiki.* ]] && rm -rf "$TEST_TMP"
}

@test "bootstrap seeds the OpenWiki lane INERT: no cron, guarded ping, real lockfile" {
	local target="$TEST_TMP/consumer"
	mkdir -p "$target"
	(cd "$target" && git init -q)
	run bash "$SCRIPT" "$target"
	[ "$status" -eq 0 ]

	# Both workflows land...
	[ -f "$target/.github/workflows/openwiki-update.yml" ]
	[ -f "$target/.github/workflows/notify-wiki-hub.yml" ]

	# ...and the update workflow carries NO schedule trigger. This is the
	# load-bearing assertion: a bootstrapped repo must never start spending
	# AI credits on its own. Arming the cron is a deliberate per-repo commit.
	run grep -E '^[[:space:]]*schedule:' "$target/.github/workflows/openwiki-update.yml"
	[ "$status" -ne 0 ]
	# It IS dispatchable, so the lane is usable on demand.
	run grep -q 'workflow_dispatch:' "$target/.github/workflows/openwiki-update.yml"
	[ "$status" -eq 0 ]

	# The hub lane costs NOTHING until opted in: the JOB is gated on
	# vars.WIKI_HUB_REPO, so an un-opted-in repo never starts a runner at all
	# (an in-step skip still burns billed Actions minutes on every docs push).
	run grep -qE "^[[:space:]]*if: vars.WIKI_HUB_REPO != ''" "$target/.github/workflows/notify-wiki-hub.yml"
	[ "$status" -eq 0 ]
	# ...and it carries no cross-org default hub, which would send a
	# consumer's token to a repo they do not own.
	run grep -q "repbyrepdev/repbyrep-wiki" "$target/.github/workflows/notify-wiki-hub.yml"
	[ "$status" -ne 0 ]

	# The toolchain pin travels, and its lockfile (the supply-chain gate for
	# `npm ci`) is COPIED from the plugin's reviewed one.
	[ -f "$target/.github/openwiki-toolchain/package.json" ]
	[ -f "$target/.github/openwiki-toolchain/package-lock.json" ]
	run jq -e '.packages["node_modules/openwiki"].version' "$target/.github/openwiki-toolchain/package-lock.json"
	[ "$status" -eq 0 ]

	# Auto-merge must be opt-in: arming the cron and auto-merging LLM edits to
	# AGENTS.md/CLAUDE.md are different risk decisions.
	run grep -q "vars.OPENWIKI_AUTO_MERGE == 'true'" "$target/.github/workflows/openwiki-update.yml"
	[ "$status" -eq 0 ]
}

@test "the seeded toolchain pin matches OPENWIKI_PIN in bootstrap-machine.sh (lockstep)" {
	# Two pins exist by design — the machine CLI (in-chat lane) and the repo
	# toolchain (CI lane). If they drift, the same repo gets documented by two
	# different generator versions depending on which lane ran.
	local machine_pin toolchain_pin
	machine_pin=$(grep -oE 'OPENWIKI_PIN="\$\{OPENWIKI_PIN:-[0-9.]+\}"' "$REPO_ROOT/scripts/bootstrap-machine.sh" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
	toolchain_pin=$(jq -r '.dependencies.openwiki' "$REPO_ROOT/.github/openwiki-toolchain/package.json")
	[ -n "$machine_pin" ] || {
		echo "could not parse OPENWIKI_PIN from bootstrap-machine.sh"
		return 1
	}
	[ "$machine_pin" = "$toolchain_pin" ] || {
		echo "pin drift: bootstrap-machine=$machine_pin toolchain=$toolchain_pin"
		return 1
	}
}

@test "manifest declares every OpenWiki file bootstrap writes (SSOT, not hashed)" {
	# The heredoc/manifest counts are drift-checked by the script itself; this
	# pins the specific paths AND that they are NOT byte-SSOT — workflows are
	# template-with-overrides, so a `hashed: true` here would wrongly gate
	# every consumer's copy against this repo's.
	local m="$REPO_ROOT/scripts/bootstrap-manifest.yml"
	# This repo's yq is the Go build: env vars via strenv(), not jq's --arg.
	for p in .github/workflows/openwiki-update.yml .github/workflows/notify-wiki-hub.yml .github/openwiki-toolchain/package.json; do
		run env P="$p" yq -r '.files[] | select(.path == strenv(P)) | .path' "$m"
		[ "$status" -eq 0 ]
		[ -n "$output" ] || {
			echo "manifest missing $p"
			return 1
		}
		run env P="$p" yq -r '.files[] | select(.path == strenv(P)) | .hashed // "absent"' "$m"
		[ "$output" = "absent" ] || {
			echo "$p must NOT be hashed (workflows vary per repo); got: $output"
			return 1
		}
	done
}

@test "the plugin's own live workflow equals its workflows-source copy (cascade pin)" {
	# Both are cascade entries; the source-pin hook enforces this repo-wide,
	# but a targeted assertion names the OpenWiki pair specifically.
	for w in openwiki-update.yml notify-wiki-hub.yml; do
		run diff -u "$REPO_ROOT/.github/workflows-source/$w" "$REPO_ROOT/.github/workflows/$w"
		[ "$status" -eq 0 ] || {
			echo "$w drifted between workflows-source/ and workflows/"
			return 1
		}
	done
	run grep -q "openwiki-update.yml" "$REPO_ROOT/.github/workflows-cascade.yml"
	[ "$status" -eq 0 ]
	run grep -q "notify-wiki-hub.yml" "$REPO_ROOT/.github/workflows-cascade.yml"
	[ "$status" -eq 0 ]
}

@test "all THREE copies stay locked: workflows-source == live == bootstrap heredoc" {
	# There are three copies of each OpenWiki workflow — workflows-source/
	# (SSOT), workflows/ (what Actions reads), and the heredoc inside
	# bootstrap-repo.sh (what consumers receive).
	#
	# p1r1: this test used to just run bootstrap-heredoc-parity.sh and assert
	# rc 0. That hook has at least four exit-0-WITHOUT-CHECKING paths (cwd
	# outside the repo, an unrelated staged set, yq missing, the SKIP env), so
	# the assertion could pass while comparing nothing. Diff directly instead.
	local boot="$REPO_ROOT/scripts/bootstrap-repo.sh"
	for w in openwiki-update.yml notify-wiki-hub.yml; do
		run diff -u "$REPO_ROOT/.github/workflows-source/$w" "$REPO_ROOT/.github/workflows/$w"
		[ "$status" -eq 0 ] || {
			echo "$w drifted between workflows-source/ and workflows/"
			return 1
		}
		# Extract the heredoc body for this path and compare byte-for-byte.
		awk -v t=".github/workflows/$w" \
			'BEGIN{pat="^_write " t " 644 <<'"'"'EOF'"'"'$"} $0 ~ pat,/^EOF$/' "$boot" |
			sed '1d;$d' >"$TEST_TMP/heredoc-$w"
		[ -s "$TEST_TMP/heredoc-$w" ] || {
			echo "could not extract the $w heredoc from bootstrap-repo.sh"
			return 1
		}
		run diff -u "$REPO_ROOT/.github/workflows/$w" "$TEST_TMP/heredoc-$w"
		[ "$status" -eq 0 ] || {
			echo "$w heredoc drifted from the live workflow"
			return 1
		}
	done
	# The whitelist must still cover them, or the pre-commit gate goes vacuous.
	for pth in ".github/workflows/openwiki-update.yml" ".github/workflows/notify-wiki-hub.yml" ".github/openwiki-toolchain/package.json"; do
		run grep -qF "\"$pth\"" "$REPO_ROOT/pre-commit-hooks/bootstrap-heredoc-parity.sh"
		[ "$status" -eq 0 ] || {
			echo "$pth missing from PARITY_PATHS"
			return 1
		}
	done
	run grep -q "openwiki-update.yml" "$REPO_ROOT/.github/workflows-cascade.yml"
	[ "$status" -eq 0 ]
	run grep -q "notify-wiki-hub.yml" "$REPO_ROOT/.github/workflows-cascade.yml"
	[ "$status" -eq 0 ]
}

@test "the PLUGIN's own workflow is inert too, asserted directly (p1r1)" {
	# The seeded copy was asserted; this repo's own copy — the one that would
	# spend THESE credits — was only covered transitively through a chain that
	# included the vacuous hook call above.
	for f in "$REPO_ROOT/.github/workflows/openwiki-update.yml" "$REPO_ROOT/.github/workflows-source/openwiki-update.yml"; do
		run grep -E '^[[:space:]]*schedule:' "$f"
		[ "$status" -ne 0 ] || {
			echo "$f has a schedule trigger — it would spend credits on a timer"
			return 1
		}
		# An uncommented cron: line is the same hazard written differently.
		run grep -E '^[[:space:]]*-[[:space:]]*cron:' "$f"
		[ "$status" -ne 0 ] || {
			echo "$f has an uncommented cron entry"
			return 1
		}
	done
}

@test "hub ping BEHAVIOUR: unset token exits 0 without calling curl (p1r1)" {
	# Previously pinned by grepping the notice TEXT, so deleting the `exit 0`
	# (letting control fall into curl, which 401s) left the test green.
	# Extract the step body and run it with a curl stub that must never fire.
	local wf="$REPO_ROOT/.github/workflows/notify-wiki-hub.yml"
	mkdir -p "$TEST_TMP/hubbin"
	printf '#!/usr/bin/env bash\necho CURL-WAS-CALLED >&2\nexit 7\n' >"$TEST_TMP/hubbin/curl"
	chmod +x "$TEST_TMP/hubbin/curl"
	# The step body is the file's final `run: |` scalar.
	sed -n '/run: |/,$p' "$wf" | sed '1d;s/^          //' >"$TEST_TMP/hub-step.sh"
	[ -s "$TEST_TMP/hub-step.sh" ]
	run env PATH="$TEST_TMP/hubbin:/usr/bin:/bin" HUB_DISPATCH_TOKEN="" \
		HUB_REPO="owner/hub" REPO="owner/repo" bash "$TEST_TMP/hub-step.sh"
	[ "$status" -eq 0 ]
	[[ $output != *"CURL-WAS-CALLED"* ]]
}

@test "the seeded lockfile carries no machine-absolute paths (p1r1)" {
	local target="$TEST_TMP/lockrepo"
	mkdir -p "$target"
	(cd "$target" && git init -q)
	run bash "$SCRIPT" "$target"
	[ "$status" -eq 0 ]
	local lock="$target/.github/openwiki-toolchain/package-lock.json"
	[ -f "$lock" ]
	# `npm --prefix <abs>` from another cwd bakes /private/var/... into the
	# package keys; the reviewed copy must contain no such paths.
	run grep -nE '/Users/|/private/var|/tmp/|"file:' "$lock"
	[ "$status" -ne 0 ] || {
		echo "seeded lockfile contains machine-absolute paths"
		return 1
	}
	# ...and it must be the REVIEWED copy, byte-identical to the plugin's.
	run diff -q "$REPO_ROOT/.github/openwiki-toolchain/package-lock.json" "$lock"
	[ "$status" -eq 0 ]
}

@test "bootstrap seeds the INSTRUCTIONS.md steering channel (p1r1)" {
	# gotcha 6 makes this the ONLY place a correction survives; five reviewers
	# caught SKILL.md promising it while nothing created it.
	local target="$TEST_TMP/instrrepo"
	mkdir -p "$target"
	(cd "$target" && git init -q)
	run bash "$SCRIPT" "$target"
	[ "$status" -eq 0 ]
	[ -f "$target/openwiki/INSTRUCTIONS.md" ]
	run grep -q "durable rules" "$target/openwiki/INSTRUCTIONS.md"
	[ "$status" -eq 0 ]
	# The skill's own probe must now report the healthy state.
	run env HOME="$TEST_TMP" bash -c "cd '$target' && '$REPO_ROOT/skills/openwiki-lane/run.sh' status"
	[[ $output == *"the steering channel"* ]]
}
