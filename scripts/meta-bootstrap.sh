#!/bin/bash
set -euo pipefail
# meta-bootstrap.sh — single entry point for every setup target.
#
# Replaces the fragmented "I forgot step X" failure mode by routing
# every target through one verified pipeline.
#
# Targets:
#   machine         — new dev machine setup
#   repo            — new consumer repo setup
#   plugin          — plugin release / cache prep
#   feature-branch  — pre-work SSOT prereq check
#
# All four targets (machine, repo, plugin, feature-branch) implemented.
# Verify-only mode runs the per-target manifest at
# scripts/meta-bootstrap-manifest.yml (feature-branch keeps its inline
# git-state-dependent verifier).
#
# Exit codes (stable contract):
#   0   success
#   1   dispatcher-level failure (orchestrated step refused or its
#       post-condition verify disagreed — see log for which step)
#   2   argparse error (missing/invalid --target, unknown flag) OR
#       per-target required-positional missing / extra args
#   69  reserved for future unimplemented targets (matches sysexits
#       EX_UNAVAILABLE; distinct from the repo's rc=3 "refused due to
#       malformed precondition" used by register-hook.sh / etc.)
#   70  internal dispatch-table bug (should be unreachable; defense in
#       depth in case a future TARGET addition skips the case statement)
#
# Usage:
#   scripts/meta-bootstrap.sh --target <machine|repo|plugin|feature-branch> [args...]
#   scripts/meta-bootstrap.sh --target X --verify-only
#   scripts/meta-bootstrap.sh --help

TARGET=""
VERIFY_ONLY=0
EXTRA_ARGS=()

_log() { echo "[meta-bootstrap] $*" >&2; }

_usage() {
	cat <<USAGE
usage: scripts/meta-bootstrap.sh --target <TARGET> [--verify-only] [-- <args>]

Targets:
  machine         New dev machine setup
  repo            New consumer repo bootstrap
  plugin          Plugin release / cache packaging
  feature-branch  Pre-work SSOT prereq check

Flags:
  --target T     Required. One of {machine, repo, plugin, feature-branch}.
  --verify-only  Run verification rules only; no mutation.
  --help, -h     Show this help.

Anything after \`--\` is forwarded to the target's underlying script.
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
	--target)
		if [ $# -lt 2 ]; then
			echo "error: --target requires a value (machine|repo|plugin|feature-branch)" >&2
			exit 2
		fi
		TARGET="$2"
		shift 2
		;;
	--verify-only)
		VERIFY_ONLY=1
		shift
		;;
	-h | --help)
		_usage
		exit 0
		;;
	--)
		shift
		EXTRA_ARGS+=("$@")
		break
		;;
	-*)
		echo "error: unknown flag: $1" >&2
		_usage >&2
		exit 2
		;;
	*)
		EXTRA_ARGS+=("$1")
		shift
		;;
	esac
done

if [ -z "$TARGET" ]; then
	echo "error: --target is required" >&2
	_usage >&2
	exit 2
fi

case "$TARGET" in
machine | repo | plugin | feature-branch) ;;
*)
	echo "error: invalid --target: $TARGET (expected machine|repo|plugin|feature-branch)" >&2
	exit 2
	;;
esac

# Per-target dispatch table. All four targets implemented as of #110 +
# #111 + #112 + #113. The verify-only path consults the per-target
# manifest at scripts/meta-bootstrap-manifest.yml when rules are
# declared; feature-branch keeps its inline-bash verifier (rules are
# git-state-dependent, manifest can't express them cleanly).

# Manifest schema version this script understands. Bump in lockstep with
# scripts/meta-bootstrap-manifest.yml when removing/renaming a top-level
# section. Mismatch fails closed (silent partial reads would defeat the
# whole point of the version field).
META_BOOTSTRAP_SCHEMA_VERSION=1
# Known rule kinds. A target with NO known rule kinds AND no `inline: true`
# sentinel fails the verify — vacuous-pass is the exact silent-failure
# pattern the manifest exists to prevent.
META_BOOTSTRAP_RULE_KINDS=(brew_packages commands keychain_entries paths json_fields)

# Allow tests to point at a non-tracked manifest via env override so they
# never have to mutate the real scripts/meta-bootstrap-manifest.yml. Empty
# env var = use the tracked manifest (production behavior).
_resolve_manifest_path() {
	local script_dir=$1
	if [ -n "${META_BOOTSTRAP_MANIFEST:-}" ]; then
		echo "$META_BOOTSTRAP_MANIFEST"
	else
		echo "$script_dir/meta-bootstrap-manifest.yml"
	fi
}

# Manifest-rule runner — consumed by _dispatch_machine + _dispatch_plugin.
# Returns 0 if every declared rule passes; 1 with one log line per fail.
# A target with no recognized rules and no `inline: true` sentinel fails
# (refuses the vacuous-pass that would hide a missing-manifest-entry bug).
_verify_target_manifest() {
	local target=$1
	local script_dir=$2
	local manifest
	manifest=$(_resolve_manifest_path "$script_dir")
	if [ ! -f "$manifest" ]; then
		_log "ERROR: manifest not found: $manifest"
		return 1
	fi
	if ! command -v yq >/dev/null 2>&1; then
		_log "ERROR: yq required for manifest-driven verify (brew install yq)"
		return 1
	fi
	# Refuse non-mikefarah yq forks — the rule-walk relies on v4 semantics
	# (empty string on missing keys, [] no-op on null).
	if ! yq --version 2>&1 | grep -qi "mikefarah"; then
		_log "ERROR: yq must be mikefarah/yq v4+ (found: $(yq --version 2>&1))"
		return 1
	fi
	# Schema version guard — fail closed on mismatch so a future v2 manifest
	# can't silently partial-read against this v1 consumer.
	local sv
	sv=$(yq -r ".schema_version" "$manifest" 2>/dev/null)
	if [ "$sv" != "$META_BOOTSTRAP_SCHEMA_VERSION" ]; then
		_log "ERROR: manifest schema_version=$sv but this script supports $META_BOOTSTRAP_SCHEMA_VERSION (manifest: $manifest)"
		return 1
	fi
	local rc=0
	# Count declared rule kinds for this target. Zero rules + no inline:true
	# sentinel = vacuous-pass refusal.
	local rules_declared=0
	local kind
	for kind in "${META_BOOTSTRAP_RULE_KINDS[@]}"; do
		local has_key
		has_key=$(yq -r ".targets.${target} | has(\"${kind}\")" "$manifest" 2>/dev/null)
		[ "$has_key" = "true" ] && rules_declared=$((rules_declared + 1))
	done
	local inline_marker
	inline_marker=$(yq -r ".targets.${target}.inline // \"\"" "$manifest" 2>/dev/null)
	if [ "$rules_declared" -eq 0 ] && [ "$inline_marker" != "true" ]; then
		_log "ERROR: target '$target' has no manifest rules and no 'inline: true' sentinel — refusing to fake-pass"
		return 1
	fi
	# brew_packages
	local pkgs
	pkgs=$(yq -r ".targets.${target}.brew_packages[]" "$manifest" 2>/dev/null)
	if [ -n "$pkgs" ] && command -v brew >/dev/null 2>&1; then
		while IFS= read -r pkg; do
			[ -z "$pkg" ] && continue
			if ! brew list --formula --versions "$pkg" >/dev/null 2>&1; then
				_log "  ✗ brew package missing: $pkg (fix: brew install $pkg)"
				rc=1
			fi
		done <<<"$pkgs"
	elif [ -n "$pkgs" ]; then
		# Enumerate which packages are unverifiable when brew is absent so
		# the operator sees the full delta, not just "Homebrew missing".
		_log "  ✗ Homebrew not on PATH — $target manifest declares: $(echo "$pkgs" | tr '\n' ' ')"
		rc=1
	fi
	# commands (PATH-resolvable)
	local cmds
	cmds=$(yq -r ".targets.${target}.commands[]" "$manifest" 2>/dev/null)
	if [ -n "$cmds" ]; then
		while IFS= read -r cmd; do
			[ -z "$cmd" ] && continue
			if ! command -v "$cmd" >/dev/null 2>&1; then
				_log "  ✗ command not on PATH: $cmd"
				rc=1
			fi
		done <<<"$cmds"
	fi
	# keychain_entries (presence only — never reads the value)
	local entries
	entries=$(yq -r ".targets.${target}.keychain_entries[]" "$manifest" 2>/dev/null)
	if [ -n "$entries" ]; then
		if ! command -v security >/dev/null 2>&1; then
			_log "  ✗ security CLI not on PATH — cannot verify Keychain entries (macOS-only)"
			rc=1
		else
			while IFS= read -r entry; do
				[ -z "$entry" ] && continue
				if ! security find-generic-password -s "$entry" >/dev/null 2>&1; then
					_log "  ✗ Keychain entry missing: $entry"
					rc=1
				fi
			done <<<"$entries"
		fi
	fi
	# paths (only leading ~/ is expanded; other forms must be absolute or
	# resolved by the manifest author — documented in the schema header)
	local paths
	paths=$(yq -r ".targets.${target}.paths[]" "$manifest" 2>/dev/null)
	if [ -n "$paths" ]; then
		while IFS= read -r p; do
			[ -z "$p" ] && continue
			# Restrict expansion to leading `~/` — the bash pattern
			# `${p/#\~/$HOME}` would also rewrite `~user/...` to
			# `$HOME-user/...` (incorrect for other-user homes).
			# `${p:2}` strips the 2-char `~/` prefix; `${p#~/}` doesn't
			# work because bash tilde-expands the pattern position.
			# shellcheck disable=SC2088 # literal '~/' is what we match for, not expand
			local resolved=$p
			# shellcheck disable=SC2088
			if [[ $p == '~/'* ]]; then
				resolved="${HOME}/${p:2}"
			fi
			if [ ! -e "$resolved" ]; then
				_log "  ✗ required path missing: $p (resolved: $resolved)"
				rc=1
			fi
		done <<<"$paths"
	fi
	# json_fields — accepts `match` (preferred) or `min` (deprecated
	# alias kept for one schema_version cycle; the historic name was
	# misleading since it's always been a regex, not a numeric floor).
	local jcount
	jcount=$(yq -r ".targets.${target}.json_fields | length" "$manifest" 2>/dev/null)
	case "$jcount" in '' | null) jcount=0 ;; esac
	if [ "$jcount" != "0" ]; then
		local i=0
		while [ "$i" -lt "$jcount" ]; do
			local jfile jjq jregex jregex_legacy
			jfile=$(yq -r ".targets.${target}.json_fields[$i].file" "$manifest")
			jjq=$(yq -r ".targets.${target}.json_fields[$i].jq" "$manifest")
			jregex=$(yq -r ".targets.${target}.json_fields[$i].match // \"\"" "$manifest")
			jregex_legacy=$(yq -r ".targets.${target}.json_fields[$i].min // \"\"" "$manifest")
			if [ -z "$jregex" ] && [ -n "$jregex_legacy" ]; then
				jregex=$jregex_legacy
			fi
			if [ "$jfile" = "null" ] || [ "$jjq" = "null" ] || [ -z "$jregex" ]; then
				_log "  ✗ json_fields[$i]: schema error — missing file/jq/match (manifest: $manifest)"
				rc=1
			elif [ ! -f "$jfile" ]; then
				_log "  ✗ json_fields[$i]: file missing: $jfile"
				rc=1
			elif ! command -v jq >/dev/null 2>&1; then
				_log "  ✗ json_fields[$i]: jq required but not on PATH"
				rc=1
			else
				local val jq_err
				# Distinguish 'field absent' from 'jq syntax/parse error'.
				if ! val=$(jq -r "$jjq" "$jfile" 2>&1); then
					jq_err=$val
					_log "  ✗ json_fields[$i]: jq error on $jfile (query: $jjq): $jq_err"
					rc=1
				elif ! [[ $val =~ $jregex ]]; then
					_log "  ✗ json_fields[$i]: $jfile:$jjq value '$val' does not match /$jregex/"
					rc=1
				fi
			fi
			i=$((i + 1))
		done
	fi
	return "$rc"
}

_dispatch_machine() {
	# Machine bootstrap orchestrator. Delegates to bootstrap-machine.sh
	# (installs brew packages, registers plugin cache, prints Keychain-add
	# commands for missing entries) then runs manifest-driven verify.
	# bootstrap-machine.sh is itself idempotent — re-running fixes drift.
	#
	# --verify-only short-circuits the install step.
	if [ "$#" -gt 0 ]; then
		_log "ERROR: --target machine accepts no positional arguments (got $#)"
		return 2
	fi
	local script_dir
	script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	if [ "$VERIFY_ONLY" = "1" ]; then
		_log "running --verify-only against machine manifest (no mutation)"
		if ! _verify_target_manifest machine "$script_dir"; then
			_log "ERROR: --verify-only failed for machine — see ✗ lines above"
			return 1
		fi
		_log "✓ --target machine --verify-only complete: all manifest rules pass"
		return 0
	fi
	_log "running bootstrap-machine.sh..."
	# `cmd || rc=$?` captures the real exit code under `set -e` — using
	# `if ! cmd; then bm_rc=$?` would store the status of `! cmd` (always 0
	# on failure), not bootstrap-machine.sh's actual exit code.
	# See feedback_rc_capture_set_e: this is the project-blessed pattern.
	local bm_rc=0
	"$script_dir/bootstrap-machine.sh" || bm_rc=$?
	if [ "$bm_rc" -ne 0 ]; then
		_log "ERROR: bootstrap-machine.sh failed (rc=$bm_rc); aborting before verify"
		return 1
	fi
	_log "running --verify against machine manifest to confirm completeness..."
	if ! _verify_target_manifest machine "$script_dir"; then
		_log "ERROR: post-bootstrap verify failed — manifest rules not satisfied"
		return 1
	fi
	_log "✓ --target machine complete: bootstrapped + verified"
	return 0
}
_dispatch_repo() {
	# Repo bootstrap orchestrator. Delegates to bootstrap-repo.sh (writes
	# files + applies labels) then runs --verify --scope both to confirm
	# completeness across plugin-scope + consumer-scope manifest entries.
	# Optional --verify-only short-circuits the bootstrap step and just
	# runs the verify pass. Verify is a separate pass (not bundled into
	# bootstrap-repo.sh) so --verify-only can reuse the same code path
	# without mutation.
	if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
		_log "ERROR: --target repo requires a target directory"
		_log "    usage: meta-bootstrap.sh --target repo <target-dir>"
		return 2
	fi
	if [ "$#" -gt 1 ]; then
		# Reject extra positional args explicitly. Silent-drop would mask
		# typos like `repo /tmp/x --force` where the operator expects a
		# flag to forward but it gets dropped.
		_log "ERROR: --target repo accepts exactly one positional argument (got $#)"
		return 2
	fi
	local target_dir=$1
	local script_dir
	script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	if [ "$VERIFY_ONLY" = "1" ]; then
		_log "running --verify --scope both against $target_dir (no mutation)"
		if ! "$script_dir/bootstrap-repo.sh" "$target_dir" --verify --scope both; then
			_log "ERROR: --verify-only failed for $target_dir — manifest files missing or labels unapplied"
			return 1
		fi
		_log "✓ --target repo --verify-only complete: $target_dir verified"
		return 0
	fi
	_log "running bootstrap-repo.sh against $target_dir..."
	if ! "$script_dir/bootstrap-repo.sh" "$target_dir"; then
		_log "ERROR: bootstrap-repo.sh failed; aborting before verify"
		return 1
	fi
	_log "running --verify --scope both to confirm completeness..."
	if ! "$script_dir/bootstrap-repo.sh" "$target_dir" --verify --scope both; then
		_log "ERROR: post-bootstrap verify failed — files missing or labels not applied"
		return 1
	fi
	_log "✓ --target repo complete: $target_dir bootstrapped + verified"
	return 0
}
_dispatch_plugin() {
	# Plugin release-prep orchestrator. The mutating step is the version
	# bump itself (plugin-version-bump-gate.sh runs in pre-commit, not from
	# here). This dispatcher's job is to verify-on-demand: confirm the
	# plugin manifest version is set + the plugin's own files match the
	# scope=plugin manifest. Post-merge cache packaging is fired by a
	# git post-merge hook (hooks/post-merge-release-fire.sh), not on
	# operator invocation.
	#
	# --verify-only and the default path are equivalent for plugin since
	# there's no mutation step to short-circuit.
	if [ "$#" -gt 0 ]; then
		_log "ERROR: --target plugin accepts no positional arguments (got $#)"
		return 2
	fi
	local script_dir
	script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	local repo_root
	if ! repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
		_log "ERROR: --target plugin must run inside a git working tree (the plugin's own checkout)"
		return 1
	fi
	_log "verifying plugin manifest fields..."
	if ! (cd "$repo_root" && _verify_target_manifest plugin "$script_dir"); then
		_log "ERROR: plugin manifest verify failed — see ✗ lines above"
		return 1
	fi
	_log "verifying plugin files against bootstrap-manifest.yml (scope=plugin)..."
	if ! "$script_dir/bootstrap-repo.sh" "$repo_root" --verify --scope plugin; then
		_log "ERROR: plugin self-bootstrap verify failed"
		return 1
	fi
	if [ "$VERIFY_ONLY" = "1" ]; then
		_log "✓ --target plugin --verify-only complete: manifest + files verified"
	else
		_log "✓ --target plugin complete: manifest + files verified (cache packaging fires on merge via post-merge-release-fire.sh)"
	fi
	return 0
}
_dispatch_feature_branch() {
	# Pre-work SSOT prereq check. Each rule prints a remediation line on
	# failure so the operator can copy-paste a fix. All rules are read-
	# only; no mutation surface exists.
	#
	# Rules 2+3 (issue + labels) require gh on PATH; when gh is absent
	# they're skipped together AND the final verdict downgrades to
	# PARTIAL so a green light can't slip past silently.
	if [ "$#" -gt 0 ]; then
		_log "ERROR: --target feature-branch accepts no positional arguments (got $#)"
		return 2
	fi
	local rc=0 skipped=0
	# Resolve repo + current branch.
	local repo_root
	if ! repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
		_log "✗ not inside a git working tree — cd into a repo first"
		return 1
	fi
	local branch
	branch=$(git -C "$repo_root" branch --show-current 2>/dev/null || echo "")
	if [ -z "$branch" ]; then
		_log "✗ no current branch (detached HEAD?) — checkout a feature branch"
		return 1
	fi
	# Rule 1: branch named per Conventional Commits type prefix + SemVer + issue-slug.
	# Anchored both ends; slug restricted to lowercase kebab-case to match the
	# repo's existing branch hygiene rules (orphan-branch sweep, etc).
	local branch_re='^(feat|fix|chore|docs|refactor|perf|test|build|ci|revert)/v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?/[0-9]+-[a-z0-9][a-z0-9-]*$'
	local rule1_ok=1
	if [[ ! $branch =~ $branch_re ]]; then
		_log "✗ branch name not per convention: $branch"
		_log "    expected: <type>/vX.Y.Z/<issue-num>-<slug>"
		_log "    fix: git branch -m <type>/vX.Y.Z/<issue-num>-<slug>"
		rc=1
		rule1_ok=0
	fi
	# Rule 2 + Rule 3: only run when Rule 1 passed (so the issue-num
	# extraction is guaranteed to be a real issue reference, not garbage
	# from a malformed branch name).
	if [ "$rule1_ok" = "1" ]; then
		local issue_num
		issue_num=$(printf '%s' "$branch" | sed -E 's#^[^/]+/v[^/]+/([0-9]+)-.*#\1#')
		if ! command -v gh >/dev/null 2>&1; then
			_log "ℹ gh not on PATH — skipping Rules 2+3 (issue + labels)"
			skipped=$((skipped + 2))
		else
			local gh_err
			gh_err=$(mktemp -t feature-branch-gh.XXXXXX 2>/dev/null || echo "")
			if ! gh issue view "$issue_num" --json state >"${gh_err:-/dev/null}" 2>&1; then
				# Distinguish "issue not found" from "gh auth/network".
				if grep -q "not found\|Could not resolve" "${gh_err:-/dev/null}" 2>/dev/null; then
					_log "✗ branch references issue #$issue_num but issue not found on GitHub"
					_log "    fix: file the issue first via the github-issue-creation skill"
				else
					_log "✗ gh issue view failed for #$issue_num: $([ -n "$gh_err" ] && head -1 "$gh_err")"
					_log "    likely auth/network/rate-limit; retry after gh auth status"
				fi
				rc=1
			else
				local labels
				if ! labels=$(gh issue view "$issue_num" --json labels --jq '.labels[].name' 2>"${gh_err:-/dev/null}"); then
					_log "✗ gh issue view labels failed: $([ -n "$gh_err" ] && head -1 "$gh_err")"
					rc=1
				else
					# Require value after the prefix, not bare 'priority:' / 'area:'.
					if ! echo "$labels" | grep -qE "^priority:[a-z0-9]"; then
						_log "✗ issue #$issue_num missing a priority:* label"
						_log "    fix: gh issue edit $issue_num --add-label priority:p2"
						rc=1
					fi
					if ! echo "$labels" | grep -qE "^area:[a-z0-9]"; then
						_log "✗ issue #$issue_num missing an area:* label"
						_log "    fix: gh issue edit $issue_num --add-label area:infrastructure"
						rc=1
					fi
				fi
			fi
			[ -n "$gh_err" ] && rm -f "$gh_err"
		fi
	else
		# Rule 1 failed — skip Rules 2+3 (they'd query garbage).
		skipped=$((skipped + 2))
	fi
	# Rule 4: pre-commit hook installed in this working tree.
	if [ ! -f "$repo_root/.git/hooks/pre-commit" ]; then
		_log "✗ pre-commit hook not installed (.git/hooks/pre-commit missing)"
		_log "    fix: pre-commit install"
		rc=1
	fi
	# Rule 5 (advisory): tracking remote configured. Not gating.
	if ! git -C "$repo_root" config "branch.${branch}.remote" >/dev/null 2>&1; then
		_log "ℹ branch has no tracking remote yet — will be set on first push"
	fi
	if [ "$rc" -eq 0 ] && [ "$skipped" -eq 0 ]; then
		_log "✓ feature-branch prereqs satisfied: $branch"
	elif [ "$rc" -eq 0 ]; then
		_log "⚠ feature-branch PARTIAL: $skipped rule(s) skipped (install gh + re-run for full check)"
	else
		_log "✗ feature-branch verify FAILED — address each ✗ above before starting work"
	fi
	return "$rc"
}

# --verify-only honored for every target as of #110 + #111 + #112 + #113.
# feature-branch is intrinsically read-only; the other three short-circuit
# the mutation step and run their verify pass against the per-target
# manifest (scripts/meta-bootstrap-manifest.yml).

_log "running target: $TARGET"

# set -u-safe expansion: when EXTRA_ARGS is empty pass zero args, not
# one empty-string. Future dispatchers will rely on arg-count accuracy.
case "$TARGET" in
machine) _dispatch_machine ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ;;
repo) _dispatch_repo ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ;;
plugin) _dispatch_plugin ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ;;
feature-branch) _dispatch_feature_branch ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ;;
*)
	# Defense in depth — unreachable given the validator above, but
	# catches a future case-label drift that skipped the validator
	# update.
	_log "ERROR: dispatch table missing case for $TARGET (internal bug)"
	exit 70
	;;
esac
