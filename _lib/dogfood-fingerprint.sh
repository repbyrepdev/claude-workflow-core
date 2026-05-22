#!/bin/bash
# auto-register: false
set -u
# v4.28-W5 #771 #840 — shared per-file fingerprint for dogfood
# gate + writer.
#
# Why a shared lib: dogfood-gate.sh (pre-commit reader) and
# scripts/dogfood.sh (run-time writer) MUST compute byte-for-byte
# identical staged_fp values, or the gate refuses every entry the
# writer just produced (paper-tiger). Prior contract was "edit both
# files in the same commit + run the round-trip bats test". A shared
# lib makes drift impossible.
#
# v4.28-W5 #771 fix: per-file semantic hash for shell files (so
# shfmt/semgrep auto-fix produces the same fingerprint and inherits
# a recent dogfood pass). Byte-exact fallback for non-shell files.
# Mirrors the bats-gate pattern (.claude/pre-commit-hooks/bats-gate.sh
# lines 111-128) so both gates evolve in lockstep.
#
# Public API:
#   dogfood_per_file_hash <repo_root> <path>
#     Emits "<hash> <path>" on stdout. Returns non-zero IFF no hash
#     could be computed (no sha256 tool + no git access).

# Source semantic-hash.sh once at load time. If the lib is missing,
# fall through to byte-exact on every call (degraded but functional).
_DOGFOOD_FP_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -r "$_DOGFOOD_FP_LIB_DIR/semantic-hash.sh" ]; then
	# shellcheck source=semantic-hash.sh
	. "$_DOGFOOD_FP_LIB_DIR/semantic-hash.sh"
fi

# Internal: pick a sha256 tool. Defined here as a fallback when the
# caller hasn't already defined _sha256_cmd.
if ! command -v _sha256_cmd >/dev/null 2>&1; then
	_dogfood_fp_sha256() {
		if command -v sha256sum >/dev/null 2>&1; then
			sha256sum
		elif command -v shasum >/dev/null 2>&1; then
			shasum -a 256
		else
			return 1
		fi
	}
else
	_dogfood_fp_sha256() { _sha256_cmd; }
fi

# Compute "hash path" for a single staged file. For shell scripts
# (.sh, .bash, or shebang `#!/.../bash`-recognized by semantic-hash.sh),
# use compute_semantic_hash_staged so formatting-only edits produce
# identical hashes. For everything else, fall back to byte-exact
# (sha256 of the git-staged blob).
dogfood_per_file_hash() {
	local repo_root="$1" path="$2"
	[ -n "$repo_root" ] || return 1
	[ -n "$path" ] || return 1

	local hash="" sem_rc=0
	# Shell-file semantic hash. Mirrors bats-gate pattern: capture rc
	# explicitly so a non-zero return falls through to byte-exact
	# rather than aborting the script under `set -e`.
	#
	# v4.28-W5 #867 CR-CLI r1: case block matches `.sh` / `.bash`
	# extensions ONLY. Shebang-based detection (e.g., extension-less
	# `gradlew`, `pre-commit` with `#!/usr/bin/env bash`) is handled
	# INSIDE `compute_semantic_hash_staged` (.claude/_lib/semantic-
	# hash.sh) — that lib detects shell content via shfmt + content
	# probe, not just by filename. To opt in shebang-detected files
	# here, we'd need to call the semantic-hash function unconditionally
	# and rely on its own rc — but that doubles the cost on non-shell
	# files. The case-block fast-path is the design choice: trust the
	# extension; let the byte-exact fallback handle extension-less
	# files (the dogfood-gate flow is fine with byte-exact on those
	# because shebang-only scripts are typically NOT auto-formatted by
	# shfmt/semgrep in pre-commit anyway).
	case "$path" in
	*.sh | *.bash)
		if command -v compute_semantic_hash_staged >/dev/null 2>&1; then
			hash=$(compute_semantic_hash_staged "$path" 2>/dev/null) || sem_rc=$?
			[ "$sem_rc" -eq 0 ] || hash=""
		fi
		;;
	esac

	# Byte-exact fallback for non-shell files OR shell files where
	# semantic hash failed (shfmt missing, file corrupt, etc.). Same
	# `git show :path` as before #840 — no behavior change for the
	# fallback path, only added the shell-file fast-path above it.
	if [ -z "$hash" ]; then
		hash=$(git -C "$repo_root" show ":$path" 2>/dev/null | _dogfood_fp_sha256 | awk '{print $1}')
	fi

	[ -n "$hash" ] || return 1
	printf '%s %s\n' "$hash" "$path"
}
