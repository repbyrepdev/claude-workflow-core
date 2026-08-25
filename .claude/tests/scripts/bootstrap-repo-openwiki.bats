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

	# The hub ping degrades to a notice instead of a red build when the
	# secret is absent — otherwise every docs push in a fresh repo fails.
	run grep -q 'HUB_DISPATCH_TOKEN unset' "$target/.github/workflows/notify-wiki-hub.yml"
	[ "$status" -eq 0 ]

	# The toolchain pin travels, and its lockfile (the supply-chain gate for
	# `npm ci`) is GENERATED rather than heredoc'd.
	[ -f "$target/.github/openwiki-toolchain/package.json" ]
	[ -f "$target/.github/openwiki-toolchain/package-lock.json" ]
	run jq -e '.packages["node_modules/openwiki"].version' "$target/.github/openwiki-toolchain/package-lock.json"
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
	# bootstrap-repo.sh (what consumers receive). The cascade pin covers the
	# first two; the heredoc was an UNPINNED third copy until it joined
	# PARITY_PATHS. Unpinned, someone could arm a cron for every bootstrapped
	# repo while this repo's own copy stayed innocently inert.
	run bash "$REPO_ROOT/pre-commit-hooks/bootstrap-heredoc-parity.sh"
	[ "$status" -eq 0 ] || {
		echo "heredoc/live parity broken — see output above"
		return 1
	}
	# And the whitelist genuinely covers them (a silent removal would make
	# the check above vacuous for these files).
	run grep -q '".github/workflows/openwiki-update.yml"' "$REPO_ROOT/pre-commit-hooks/bootstrap-heredoc-parity.sh"
	[ "$status" -eq 0 ]
	run grep -q '".github/workflows/notify-wiki-hub.yml"' "$REPO_ROOT/pre-commit-hooks/bootstrap-heredoc-parity.sh"
	[ "$status" -eq 0 ]
}
