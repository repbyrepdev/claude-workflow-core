#!/bin/bash
set -u
# v4.30.B #802: semantic content hash for bats-gate + dogfood-gate.
#
# Normalize shell scripts via `shfmt -mn` (minify mode — strips comments
# + collapses whitespace, preserves AST) before hashing. Comment-only +
# whitespace-only edits produce identical normalized output → identical
# hash → recent-pass log entry still matches → re-run skipped. Behavior-
# changing edits produce different normalized output → different hash →
# re-run required (safe).
#
# Fallbacks: if shfmt is unavailable OR rejects the input (e.g. yaml,
# non-shell file), fall back to byte-exact hash so the gate degrades to
# pre-v4.30.B behavior rather than skipping the check entirely.

# Compute the semantic hash of stdin. Outputs the 64-char sha256 on
# stdout. Caller pipes content in. Internal-fail returns 1.
_compute_hash_from_stdin() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | awk '{print $1}'
	else
		echo "_compute_hash_from_stdin: no sha256sum or shasum available" >&2
		return 1
	fi
}

# Compute the semantic hash of a file's CONTENT. For shell scripts
# (.sh/.bash extension OR identifiable shebang), pipe through `shfmt -mn`
# first; fall back to byte-exact otherwise.
compute_semantic_hash() {
	local path=${1:-}
	if [ -z "$path" ]; then
		_compute_hash_from_stdin
		return $?
	fi
	if [ ! -r "$path" ]; then
		echo "compute_semantic_hash: cannot read $path" >&2
		return 1
	fi
	local is_shell=0
	case "$path" in
	*.sh | *.bash) is_shell=1 ;;
	esac
	if [ "$is_shell" = "0" ]; then
		case "$(head -n 1 "$path" 2>/dev/null)" in
		'#!/bin/bash' | '#!/bin/sh' | '#!/usr/bin/env bash' | '#!/usr/bin/env sh') is_shell=1 ;;
		esac
	fi
	if [ "$is_shell" = "1" ] && command -v shfmt >/dev/null 2>&1; then
		local normalized
		# CR PR #803 r2 MINOR: empty normalized output is still a valid
		# semantic hash (whitespace-only file → minified empty → hash of
		# empty string). Don't fall through to byte-exact in that case.
		if normalized=$(shfmt -mn <"$path" 2>/dev/null); then
			printf '%s' "$normalized" | _compute_hash_from_stdin
			return $?
		fi
	fi
	_compute_hash_from_stdin <"$path"
}

# Variant: hash from a git-staged blob (not the worktree).
compute_semantic_hash_staged() {
	local path=${1:-}
	[ -n "$path" ] || {
		echo "compute_semantic_hash_staged: path required" >&2
		return 1
	}
	local tmp
	tmp=$(mktemp -t sem-hash.XXXXXX) || {
		echo "compute_semantic_hash_staged: mktemp failed" >&2
		return 1
	}
	if ! git show ":$path" 2>/dev/null >"$tmp"; then
		rm -f "$tmp"
		echo "compute_semantic_hash_staged: git show :$path failed" >&2
		return 1
	fi
	# Inherit the path extension so .sh detection works.
	local tmp_with_ext
	tmp_with_ext="$tmp.$(basename "$path")"
	mv "$tmp" "$tmp_with_ext"
	local rc=0
	compute_semantic_hash "$tmp_with_ext" || rc=$?
	rm -f "$tmp_with_ext"
	return "$rc"
}
