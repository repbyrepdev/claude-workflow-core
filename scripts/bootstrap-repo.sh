#!/bin/bash
set -euo pipefail
# v0.8.7 (#21): bootstrap-repo — scaffold a new consumer repo with the
# canonical claude-workflow-core SSOT wiring.
#
# Scope: creates the MINIMAL set of files needed for a new repo to
# consume the plugin workflow. The operator still needs to:
#   - `gh repo create <owner>/<repo>` + push
#   - Enable GitHub Actions in repo Settings
#   - Set up branch protection on main (required checks per
#     .github/required-checks-list.yml)
#   - Install pre-commit hooks: `pre-commit install`
#
# Files written (SEED set — the full generic runtime is then synced, see below):
#   .pre-commit-config.yaml          — pinned plugin + minimal upstream hooks
#   .claude/skills/ship-pr-cycle/    — consumer wrapper for plugin orchestrator
#   .claude/hooks/review-log.sh      — shim that delegates to plugin
#   .github/pull_request_template.md — template stub
#   .github/commit-template.yml      — Conventional Commits SSOT
#   .github/labels.yml               — label catalog stub
#   .github/required-checks-list.yml — required-checks SSOT
#   .github/ISSUE_TEMPLATE/{bug,feature,task,epic,brainstorm}.yml
# The above are the per-repo-flavored + bootstrap-critical SEEDS only. The LARGE
# generic surface (~100 .claude/hooks/* runtime hooks, _lib/* helpers, and the
# hashed .gemini/.codex/.coderabbit/.github byte-SSOTs) is laid down right after
# by _sync_full_ssot() → refresh-from-source.sh; the authoritative file list is
# .claude/.source-hashes.json (NOT this comment — kept short to avoid drift).
#
# Idempotent: every file write checks for existing first; --force flag
# overrides. --dry-run shows what would be created without mutating.
#
# Usage:
#   scripts/bootstrap-repo.sh <target-dir>
#   scripts/bootstrap-repo.sh <target-dir> --tag v0.8.5    # pin to specific
#   scripts/bootstrap-repo.sh <target-dir> --dry-run       # preview
#   scripts/bootstrap-repo.sh <target-dir> --force         # overwrite existing
#   scripts/bootstrap-repo.sh <target-dir> --apply-labels  # OPT-IN: sync labels
#                                                          # to GitHub (remote
#                                                          # mutation; default OFF)
#
# Platform: macOS + Linux (no platform-specific calls).

# Resolve the plugin's OWN script dir up-front — BEFORE any `cd "$TARGET"` —
# so a relative invocation path can't break ${BASH_SOURCE[0]} resolution after
# the working dir changes. Used to locate sibling helpers (compose-coderabbit.sh)
# regardless of how bootstrap was invoked. (NOTE: the SCRIPT_DIR assignments
# further down live INSIDE embedded heredocs — they are the consumer run.sh's
# vars, not this script's.)
PLUGIN_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Set to 1 by _compose_coderabbit on a genuine compose failure so the
# end-of-run summary surfaces it (exit stays 0 — compose is best-effort, but
# exit-code-only automation would otherwise miss the absent .coderabbit.yaml).
COMPOSE_CR_FAILED=0

TARGET=""
# #283 (Wave J): default PIN_TAG to the plugin's CURRENT version (SSOT =
# .claude-plugin/plugin.json) so a fresh bootstrap pins to the current release
# instead of a hardcoded stale tag (the pin is version-agnostic — derived, not literal).
# --tag still overrides (parsed below). FAIL-CLOSED (CR #283): if plugin.json is
# missing/unparseable, PIN_TAG stays EMPTY here and a real bootstrap aborts after
# arg-parsing (guard below) — never a silent stale fallback.
_plugin_ver=$(jq -r '.version // empty' "$PLUGIN_SCRIPT_DIR/../.claude-plugin/plugin.json" 2>/dev/null || echo "")
PIN_TAG=""
[ -n "$_plugin_ver" ] && PIN_TAG="v${_plugin_ver}"
DRY_RUN=0
FORCE=0
VERIFY=0
VERIFY_SCOPE="both"
# --apply-labels is OPT-IN (default OFF). The repo contract requires every
# `gh label` REMOTE mutation to sit behind this explicit flag so a plain
# scaffold never silently writes to a GitHub repo's label set; sync is
# otherwise deferred to .github/workflows/label-sync.yml on first push.
APPLY_LABELS=0

while [ $# -gt 0 ]; do
	case "$1" in
	--tag)
		if [ $# -lt 2 ]; then
			echo "error: --tag requires a value (e.g. --tag v0.8.5)" >&2
			exit 2
		fi
		PIN_TAG="$2"
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--force)
		FORCE=1
		shift
		;;
	--apply-labels)
		APPLY_LABELS=1
		shift
		;;
	--verify)
		VERIFY=1
		shift
		;;
	--scope)
		if [ $# -lt 2 ]; then
			echo "error: --scope requires a value (plugin|consumer|both)" >&2
			exit 2
		fi
		case "$2" in
		plugin | consumer | both) VERIFY_SCOPE="$2" ;;
		*)
			echo "error: --scope must be one of: plugin, consumer, both (got: $2)" >&2
			exit 2
			;;
		esac
		shift 2
		;;
	-h | --help)
		grep '^#' "$0" | head -35
		exit 0
		;;
	-*)
		echo "unknown flag: $1" >&2
		exit 2
		;;
	*)
		if [ -z "$TARGET" ]; then
			TARGET="$1"
			shift
		else
			echo "error: multiple positional args — first arg is target dir, no other positionals" >&2
			exit 2
		fi
		;;
	esac
done

# FAIL-CLOSED (CR #283): a real bootstrap MUST have resolved a pin tag — from
# plugin.json (above) or --tag. Never silently pin to a stale hardcoded fallback.
# --dry-run/--verify don't write the pin, so they tolerate an empty PIN_TAG (and
# legitimately run without plugin.json present).
if [ -z "$PIN_TAG" ] && [ "$DRY_RUN" != "1" ] && [ "$VERIFY" != "1" ]; then
	echo "bootstrap-repo: ERROR: no pin tag resolved — .claude-plugin/plugin.json missing/unparseable AND no --tag vX.Y.Z given. Refusing a stale fallback pin; fix the manifest or pass --tag." >&2
	exit 2
fi

if [ -z "$TARGET" ]; then
	echo "error: missing target directory" >&2
	echo "usage: scripts/bootstrap-repo.sh <target-dir> [--tag vX.Y.Z] [--dry-run] [--force] [--apply-labels] [--verify] [--scope plugin|consumer|both]" >&2
	exit 2
fi

_log() { echo "[bootstrap-repo] $*" >&2; }

# Parity check: bootstrap-manifest.yml is the declarative SSOT for every
# file this script produces. Soft-warn on drift (count or path mismatch).
# Visible bypasses: yq missing OR manifest missing emits a NOTE so a quiet
# skip can't hide regressions.
MANIFEST_PATH="$(dirname "$0")/bootstrap-manifest.yml"
if [ ! -f "$MANIFEST_PATH" ]; then
	_log "NOTE: bootstrap-manifest.yml not found at $MANIFEST_PATH — parity check skipped"
elif ! command -v yq >/dev/null 2>&1; then
	_log "NOTE: yq not on PATH — manifest parity check skipped"
else
	# `|| echo` fallbacks preserve a parseable value when yq parse-errors or
	# grep matches zero — set -e would otherwise abort the whole script.
	# yq stderr captured to PARSE_ERR so failures land in a WARN line with
	# context instead of disappearing into /dev/null.
	PARSE_ERR=$(mktemp -t bootstrap-manifest-yq.XXXXXX 2>/dev/null || echo "")
	manifest_count=$(yq -r '.files | length' "$MANIFEST_PATH" 2>"${PARSE_ERR:-/dev/null}" || echo "")
	heredoc_count=$(grep -cE '^_write ' "$0" || echo 0)
	if [ "$heredoc_count" -eq 0 ]; then
		_log "WARN: bootstrap-repo.sh contains zero _write calls — script malformed?"
	elif [ -z "$manifest_count" ] || ! [ "$manifest_count" -eq "$manifest_count" ] 2>/dev/null; then
		_log "WARN: bootstrap-manifest.yml unparseable (yq -r '.files | length' failed) — parity check inconclusive"
		if [ -n "$PARSE_ERR" ] && [ -s "$PARSE_ERR" ]; then
			_log "      yq error: $(head -1 "$PARSE_ERR")"
		fi
	elif [ "$manifest_count" -ne "$heredoc_count" ]; then
		_log "WARN: manifest drift — bootstrap-manifest.yml lists $manifest_count files, this script has $heredoc_count _write calls"
		_log "      reconcile scripts/bootstrap-manifest.yml + heredocs in $0 before relying on output"
	else
		# Counts match — verify each manifest path appears as a literal _write
		# target. Materialize paths first so yq rc is checkable (process
		# substitution swallows rc). grep -F -- to avoid regex metachar
		# matching AND ugrep dash-prefix flag misinterpretation.
		if ! manifest_paths=$(yq -r '.files[] | select(.path != null) | .path' "$MANIFEST_PATH" 2>"${PARSE_ERR:-/dev/null}"); then
			_log "WARN: yq path enumeration failed — parity check inconclusive"
			[ -n "$PARSE_ERR" ] && [ -s "$PARSE_ERR" ] && _log "      yq error: $(head -1 "$PARSE_ERR")"
			manifest_paths=""
		fi
		drift_paths=()
		while IFS= read -r p; do
			[ -z "$p" ] && continue
			grep -F -- "_write $p " "$0" >/dev/null || drift_paths+=("$p")
		done <<<"$manifest_paths"
		if [ "${#drift_paths[@]}" -gt 0 ]; then
			_log "WARN: manifest path(s) not found in any _write call:"
			for p in "${drift_paths[@]}"; do
				_log "        - $p"
			done
		fi
	fi
	[ -n "$PARSE_ERR" ] && rm -f "$PARSE_ERR"
fi

# Short-circuit early when --verify so the manifest-parity NOTE/WARN
# lines above are the only setup noise verify mode emits. Anything
# below this point is bootstrap (write/apply) territory.

# --- --verify mode ---------------------------------------------------
# Reads bootstrap-manifest.yml + .github/labels.yml, asserts each file
# path exists in $TARGET and each label is present on the remote.
# Idempotent: invokable repeatedly. Exits 0 on clean, non-zero with a
# per-issue diff line on drift. Skips remote-label check when no gh or
# no GitHub remote (target may be pre-push).
_verify_target() {
	local rc=0 missing_files=0 wrong_mode=0 missing_labels=0 verified_count=0
	if [ ! -d "$TARGET" ]; then
		_log "ERROR: --verify target $TARGET is not a directory"
		return 2
	fi
	if [ ! -f "$MANIFEST_PATH" ]; then
		_log "ERROR: bootstrap-manifest.yml not found at $MANIFEST_PATH — cannot verify"
		return 2
	fi
	if ! command -v yq >/dev/null 2>&1; then
		_log "ERROR: yq not on PATH — cannot verify"
		return 2
	fi
	_log "verifying $TARGET against bootstrap-manifest.yml (scope=$VERIFY_SCOPE)..."
	# Files: every manifest path must exist; mode must match.
	# scope filter: entries without `scope:` default to "both" (visible in
	# all scopes). Entries marked scope: consumer skip when --scope=plugin.
	local count
	count=$(yq -r '.files | length' "$MANIFEST_PATH")
	local i=0
	while [ "$i" -lt "$count" ]; do
		local path mode actual_mode entry_scope
		path=$(yq -r ".files[$i].path" "$MANIFEST_PATH")
		mode=$(yq -r ".files[$i].mode" "$MANIFEST_PATH")
		entry_scope=$(yq -r ".files[$i].scope // \"both\"" "$MANIFEST_PATH")
		# Skip when current scope doesn't include this entry.
		if [ "$VERIFY_SCOPE" = "plugin" ] && [ "$entry_scope" = "consumer" ]; then
			i=$((i + 1))
			continue
		fi
		if [ "$VERIFY_SCOPE" = "consumer" ] && [ "$entry_scope" = "plugin" ]; then
			i=$((i + 1))
			continue
		fi
		if [ ! -f "$TARGET/$path" ]; then
			_log "  ✗ missing: $path"
			missing_files=$((missing_files + 1))
		else
			# stat: GNU `-c '%a'` first (returns octal mode), then BSD `-f '%Lp'`
			# fallback. Order matters: GNU stat's `-f` returns filesystem info
			# (not a format string), so trying BSD first on Linux yields garbage
			# instead of erroring.
			actual_mode=$(stat -c '%a' "$TARGET/$path" 2>/dev/null || stat -f '%Lp' "$TARGET/$path" 2>/dev/null || echo "")
			if [ -n "$actual_mode" ] && [ "$actual_mode" != "$mode" ]; then
				_log "  ⚠ mode mismatch: $path expected=$mode actual=$actual_mode"
				wrong_mode=$((wrong_mode + 1))
			fi
			verified_count=$((verified_count + 1))
		fi
		i=$((i + 1))
	done
	[ "$missing_files" -gt 0 ] && rc=1
	# Labels: compare manifest.labels[].name against gh label list when
	# remote available; otherwise verify labels.yml file is at least present.
	if [ ! -f "$TARGET/.github/labels.yml" ]; then
		_log "  ✗ missing: .github/labels.yml (labels SSOT)"
		rc=1
	elif command -v gh >/dev/null 2>&1 && git -C "$TARGET" remote get-url origin 2>/dev/null | grep -q github.com; then
		local expected actual gh_err
		expected=$(yq -r '.labels[].name' "$MANIFEST_PATH" | sort -u)
		# --limit 500 per project gh-query-limits guidance (default 30 truncates silently).
		# Capture stderr separately so auth/rate-limit/network errors are visible
		# instead of being swallowed and indistinguishable from "0 labels exist".
		gh_err=$(mktemp -t verify-gh-labels.XXXXXX 2>/dev/null || echo "")
		if ! actual=$( (cd "$TARGET" && gh label list --limit 500 --json name --jq '.[].name' 2>"${gh_err:-/dev/null}") | sort -u); then
			_log "  ✗ gh label list failed: $([ -n "$gh_err" ] && head -1 "$gh_err")"
			rc=1
		elif [ -z "$actual" ]; then
			# Empty result on a real remote = auth/rate-limit/permission failure.
			# Distinct from "remote unreachable" (the elif branch below).
			_log "  ✗ gh label list returned empty (auth? rate-limit? permission?) — failing closed"
			[ -n "$gh_err" ] && [ -s "$gh_err" ] && _log "      gh stderr: $(head -1 "$gh_err")"
			rc=1
		else
			while IFS= read -r want; do
				[ -z "$want" ] && continue
				echo "$actual" | grep -qFx "$want" || {
					_log "  ✗ label missing on remote: $want"
					missing_labels=$((missing_labels + 1))
				}
			done <<<"$expected"
		fi
		[ -n "$gh_err" ] && rm -f "$gh_err"
	else
		_log "  NOTE: gh / GitHub remote unavailable — skipping label-remote check (run after first push)"
	fi
	[ "$missing_labels" -gt 0 ] && rc=1
	if [ "$rc" -eq 0 ] && [ "$wrong_mode" -eq 0 ]; then
		_log "  ✓ verify clean: $verified_count file(s) verified, labels match manifest"
	elif [ "$rc" -eq 0 ]; then
		_log "  ⚠ verify completed with $wrong_mode mode mismatch(es) — non-blocking"
	else
		_log "  ✗ verify FAILED: $missing_files missing file(s), $missing_labels missing label(s)"
	fi
	return "$rc"
}

if [ "$VERIFY" = "1" ]; then
	_verify_target
	exit $?
fi

# Create target if missing (always create in dry-run too so subsequent
# cd + relative-path checks work; we tear down at end if empty).
TARGET_PREEXISTED=1
if [ ! -d "$TARGET" ]; then
	TARGET_PREEXISTED=0
	if [ "$DRY_RUN" = "1" ]; then
		_log "[dry-run] would mkdir -p $TARGET (creating temporarily for path resolution)"
	fi
	mkdir -p "$TARGET"
fi

cd "$TARGET" || {
	echo "error: cannot cd into $TARGET after mkdir (permissions? symlink loop?)" >&2
	exit 2
}
# Resolve to absolute after cd so dry-run cleanup (which does `cd /`)
# can still locate the target by absolute path even when $TARGET was
# originally given as a relative argument.
TARGET=$(pwd)

# Track skipped files so the end-of-run summary can warn loudly.
SKIPPED_FILES=()

# Helper: write file, idempotent + --force-respecting.
# Every step (mkdir/cat/chmod) checked explicitly so any failure
# names the path that broke instead of producing a bare set -e abort.
# args: <relative-path> [<mode>] (content on stdin)
_write() {
	local path=$1
	local mode=${2:-644}
	if [ -e "$path" ] && [ "$FORCE" != "1" ]; then
		_log "  • $path already exists — skipping (--force to overwrite)"
		# Drain stdin so caller's heredoc isn't left dangling.
		cat >/dev/null
		SKIPPED_FILES+=("$path")
		return 0
	fi
	if [ "$DRY_RUN" = "1" ]; then
		_log "[dry-run] would write $path (mode $mode)"
		cat >/dev/null
		return 0
	fi
	local parent
	parent=$(dirname "$path")
	if ! mkdir -p "$parent"; then
		echo "error: cannot create parent dir $parent for $path" >&2
		return 1
	fi
	if ! cat >"$path"; then
		echo "error: write to $path failed (disk full? permissions? read-only FS?)" >&2
		return 1
	fi
	if ! chmod "$mode" "$path"; then
		echo "error: chmod $mode $path failed" >&2
		return 1
	fi
	_log "  ✓ wrote $path"
}

# --- .pre-commit-config.yaml -----------------------------------------
_write .pre-commit-config.yaml 644 <<EOF
# Pre-commit config. Layered:
#   1. Upstream framework hooks (lint)
#   2. Plugin-provided hooks via \`claude-workflow-core\` (workflow gates)
# Install: pre-commit install
# Run all: pre-commit run --all-files

repos:
  # Upstream framework hooks
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.38.0
    hooks:
      - id: yamllint
  - repo: https://github.com/shellcheck-py/shellcheck-py
    rev: v0.10.0.1
    hooks:
      - id: shellcheck
  - repo: https://github.com/scop/pre-commit-shfmt
    rev: v3.10.0-2
    hooks:
      - id: shfmt
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.2
    hooks:
      - id: gitleaks

  # Plugin-provided workflow hooks — keep \`rev\` synchronized with
  # claude-workflow-core releases.
  - repo: https://github.com/repbyrepdev/claude-workflow-core
    rev: $PIN_TAG
    hooks:
      - id: bash-safety
      - id: bash4-features-check
      - id: commit-template-check
      - id: hash-drift-verify
      - id: lint-gate
      - id: memory-drift-check
      - id: memory-index-valid
      - id: prove-yourself-gate
EOF

# --- .claude/skills/ship-pr-cycle/run.sh -----------------------------
_write .claude/skills/ship-pr-cycle/run.sh 755 <<'EOF'
#!/bin/bash
set -euo pipefail
# Consumer wrapper for ship-pr-cycle orchestrator (lives in plugin).
# Resolves plugin pin from .pre-commit-config.yaml and exec's the
# orchestrator from the plugin cache.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
CONFIG="$REPO_ROOT/.pre-commit-config.yaml"

# Resolve plugin pin via plugin's own resolve-plugin-pin.sh (SSOT)
PLUGIN_CACHE="${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core}"
shopt -s nullglob
_resolve_candidates=("$PLUGIN_CACHE"/*/_lib/resolve-plugin-pin.sh)
shopt -u nullglob
# Pick the NEWEST cached version (version-sorted), not the lexicographically
# first — a bare ${arr[0]} sorts strings, so 0.34.x lands AFTER 0.6.x/0.8.x and
# the OLDEST cache wins. resolve-plugin-pin.sh is byte-identical across cached
# versions today, but pinning to an arbitrary stale version is fragile; sort -V
# picks the highest semver dir. sort -V is unsupported on older BSD/macOS sort,
# so fall back to the first candidate — the resolve-pin lib is byte-identical
# across cached versions, so any copy parses the pin identically (the version
# sort is a nicety, not a correctness requirement).
RESOLVE_LIB=""
if [ "${#_resolve_candidates[@]}" -gt 0 ]; then
	if command sort -V </dev/null >/dev/null 2>&1; then
		RESOLVE_LIB=$(printf '%s\n' "${_resolve_candidates[@]}" | sort -V | tail -1)
	else
		RESOLVE_LIB="${_resolve_candidates[0]}"
	fi
fi

if [ -z "$RESOLVE_LIB" ] || [ ! -f "$RESOLVE_LIB" ]; then
	echo "ship-pr-cycle consumer: ERROR: plugin cache empty at $PLUGIN_CACHE" >&2
	echo "  run scripts/bootstrap-machine.sh from the plugin repo first" >&2
	exit 2
fi
_src_err=$(mktemp 2>/dev/null) || _src_err=""
# shellcheck source=/dev/null
if ! source "$RESOLVE_LIB" 2>"${_src_err:-/dev/stderr}"; then
	echo "shim: cannot source plugin resolve-pin lib ($RESOLVE_LIB)${_src_err:+: $(cat "$_src_err" 2>/dev/null)}" >&2
	[ -n "$_src_err" ] && rm -f "$_src_err"
	exit 2
fi
[ -n "$_src_err" ] && rm -f "$_src_err"
if ! PIN=$(resolve_plugin_pin "$CONFIG"); then
	echo "error: could not resolve plugin pin from $CONFIG (key claude-workflow-core missing or malformed)" >&2
	exit 2
fi

ORCHESTRATOR="$PLUGIN_CACHE/$PIN/scripts/ship-pr-cycle.sh"
if [ ! -x "$ORCHESTRATOR" ]; then
	echo "ship-pr-cycle consumer: ERROR: orchestrator missing at $ORCHESTRATOR" >&2
	exit 2
fi
exec "$ORCHESTRATOR" "$@"
EOF

# --- .claude/skills/ship-pr-cycle/SKILL.md ---------------------------
_write .claude/skills/ship-pr-cycle/SKILL.md 644 <<'EOF'
---
name: ship-pr-cycle
description: Orchestrate the full PR lifecycle (Phase 0.5 → Phase 1 → Phase 2 → push → CR-in-CI → merge-gate). Invoked at branch-ready time to drive a PR through to mergeable.
---

# ship-pr-cycle (consumer wrapper)

Delegates to the orchestrator script in the plugin cache. See
`https://github.com/repbyrepdev/claude-workflow-core/blob/main/scripts/ship-pr-cycle.sh`
for full state machine + stage semantics.

## Usage

```bash
.claude/skills/ship-pr-cycle/run.sh start    # initialize for current HEAD
.claude/skills/ship-pr-cycle/run.sh status   # show state
.claude/skills/ship-pr-cycle/run.sh next     # advance one stage
.claude/skills/ship-pr-cycle/run.sh resume   # auto-detect + advance to terminal
```
EOF

# --- .claude/hooks/review-log.sh shim --------------------------------
_write .claude/hooks/review-log.sh 755 <<'EOF'
#!/bin/bash
set -euo pipefail
# Thin shim that forwards to the plugin's review-log.sh. Idempotency
# contract lives in the plugin — this shim just exists so the consumer
# repo has a stable path that doesn't change with pin bumps.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
CONFIG="$REPO_ROOT/.pre-commit-config.yaml"

PLUGIN_CACHE="${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core}"
shopt -s nullglob
_resolve_candidates=("$PLUGIN_CACHE"/*/_lib/resolve-plugin-pin.sh)
shopt -u nullglob
# Pick the NEWEST cached version (version-sorted), not lexicographically-first.
# sort -V is unsupported on older BSD/macOS sort, so fall back to the first
# candidate — the resolve-pin lib is byte-identical across cached versions, so
# any copy parses the pin identically (the version sort is a nicety, not a
# correctness requirement).
RESOLVE_LIB=""
if [ "${#_resolve_candidates[@]}" -gt 0 ]; then
	if command sort -V </dev/null >/dev/null 2>&1; then
		RESOLVE_LIB=$(printf '%s\n' "${_resolve_candidates[@]}" | sort -V | tail -1)
	else
		RESOLVE_LIB="${_resolve_candidates[0]}"
	fi
fi
if [ -z "$RESOLVE_LIB" ]; then
	echo "review-log.sh shim: plugin cache empty" >&2
	exit 2
fi
_src_err=$(mktemp 2>/dev/null) || _src_err=""
# shellcheck source=/dev/null
if ! source "$RESOLVE_LIB" 2>"${_src_err:-/dev/stderr}"; then
	echo "shim: cannot source plugin resolve-pin lib ($RESOLVE_LIB)${_src_err:+: $(cat "$_src_err" 2>/dev/null)}" >&2
	[ -n "$_src_err" ] && rm -f "$_src_err"
	exit 2
fi
[ -n "$_src_err" ] && rm -f "$_src_err"
if ! PIN=$(resolve_plugin_pin "$CONFIG"); then
	echo "error: could not resolve plugin pin from $CONFIG (key claude-workflow-core missing or malformed)" >&2
	exit 2
fi

TARGET_HOOK="$PLUGIN_CACHE/$PIN/hooks/review-log.sh"
if [ ! -x "$TARGET_HOOK" ]; then
	echo "review-log.sh shim: target hook missing or non-executable at $TARGET_HOOK" >&2
	echo "  ensure plugin cache for $PIN is installed (scripts/bootstrap-machine.sh)" >&2
	exit 2
fi
exec "$TARGET_HOOK" "$@"
EOF

# --- .claude/hooks/ ship-pr-cycle runtime shims (#223) ---------------
# ship-pr-cycle's phase0.5 + post-commit stages invoke these stable
# .claude/hooks/ paths. Same self-resolving shim pattern as review-log.sh
# above — each forwards to the plugin cache's same-named hook (+ its _lib
# deps) so a consumer's cycle works WITHOUT copying the full hook tree. ptt
# was bootstrapped before these existed, so its cycle broke at phase0.5.
_write .claude/hooks/phase0.5-copilot-prefilter.sh 755 <<'EOF'
#!/bin/bash
set -euo pipefail
# auto-register: false
# bats-required: 0
# (Thin self-resolving shim: the real hook + its bats live in the plugin cache
#  and are upstream-tested; this file only forwards. Not event-registered.)
# Self-naming shim → forwards to the plugin cache's hooks/<this-name> at the
# pinned version. The real hook + its _lib deps live in the plugin cache.
HOOK_NAME=$(basename "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
CONFIG="$REPO_ROOT/.pre-commit-config.yaml"
PLUGIN_CACHE="${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core}"
shopt -s nullglob
_resolve_candidates=("$PLUGIN_CACHE"/*/_lib/resolve-plugin-pin.sh)
shopt -u nullglob
# Pick the NEWEST cached version (version-sorted), not lexicographically-first.
# sort -V is unsupported on older BSD/macOS sort, so fall back to the first
# candidate — the resolve-pin lib is byte-identical across cached versions, so
# any copy parses the pin identically (the version sort is a nicety, not a
# correctness requirement).
RESOLVE_LIB=""
if [ "${#_resolve_candidates[@]}" -gt 0 ]; then
	if command sort -V </dev/null >/dev/null 2>&1; then
		RESOLVE_LIB=$(printf '%s\n' "${_resolve_candidates[@]}" | sort -V | tail -1)
	else
		RESOLVE_LIB="${_resolve_candidates[0]}"
	fi
fi
if [ -z "$RESOLVE_LIB" ]; then
	echo "$HOOK_NAME shim: plugin cache empty" >&2
	exit 2
fi
_src_err=$(mktemp 2>/dev/null) || _src_err=""
# shellcheck source=/dev/null
if ! source "$RESOLVE_LIB" 2>"${_src_err:-/dev/stderr}"; then
	echo "shim: cannot source plugin resolve-pin lib ($RESOLVE_LIB)${_src_err:+: $(cat "$_src_err" 2>/dev/null)}" >&2
	[ -n "$_src_err" ] && rm -f "$_src_err"
	exit 2
fi
[ -n "$_src_err" ] && rm -f "$_src_err"
if ! PIN=$(resolve_plugin_pin "$CONFIG"); then
	echo "$HOOK_NAME shim: could not resolve plugin pin from $CONFIG" >&2
	exit 2
fi
TARGET_HOOK="$PLUGIN_CACHE/$PIN/hooks/$HOOK_NAME"
if [ ! -x "$TARGET_HOOK" ]; then
	echo "$HOOK_NAME shim: target hook missing at $TARGET_HOOK (run scripts/bootstrap-machine.sh)" >&2
	exit 2
fi
exec "$TARGET_HOOK" "$@"
EOF

_write .claude/hooks/post-commit-ship-cycle.sh 755 <<'EOF'
#!/bin/bash
set -euo pipefail
# auto-register: false
# bats-required: 0
# (Thin self-resolving shim: the real hook + its bats live in the plugin cache
#  and are upstream-tested; this file only forwards. Not event-registered.)
# Self-naming shim → forwards to the plugin cache's hooks/<this-name> at the
# pinned version. The real hook + its _lib deps live in the plugin cache.
HOOK_NAME=$(basename "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
CONFIG="$REPO_ROOT/.pre-commit-config.yaml"
PLUGIN_CACHE="${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core}"
shopt -s nullglob
_resolve_candidates=("$PLUGIN_CACHE"/*/_lib/resolve-plugin-pin.sh)
shopt -u nullglob
# Pick the NEWEST cached version (version-sorted), not lexicographically-first.
# sort -V is unsupported on older BSD/macOS sort, so fall back to the first
# candidate — the resolve-pin lib is byte-identical across cached versions, so
# any copy parses the pin identically (the version sort is a nicety, not a
# correctness requirement).
RESOLVE_LIB=""
if [ "${#_resolve_candidates[@]}" -gt 0 ]; then
	if command sort -V </dev/null >/dev/null 2>&1; then
		RESOLVE_LIB=$(printf '%s\n' "${_resolve_candidates[@]}" | sort -V | tail -1)
	else
		RESOLVE_LIB="${_resolve_candidates[0]}"
	fi
fi
if [ -z "$RESOLVE_LIB" ]; then
	echo "$HOOK_NAME shim: plugin cache empty" >&2
	exit 2
fi
_src_err=$(mktemp 2>/dev/null) || _src_err=""
# shellcheck source=/dev/null
if ! source "$RESOLVE_LIB" 2>"${_src_err:-/dev/stderr}"; then
	echo "shim: cannot source plugin resolve-pin lib ($RESOLVE_LIB)${_src_err:+: $(cat "$_src_err" 2>/dev/null)}" >&2
	[ -n "$_src_err" ] && rm -f "$_src_err"
	exit 2
fi
[ -n "$_src_err" ] && rm -f "$_src_err"
if ! PIN=$(resolve_plugin_pin "$CONFIG"); then
	echo "$HOOK_NAME shim: could not resolve plugin pin from $CONFIG" >&2
	exit 2
fi
TARGET_HOOK="$PLUGIN_CACHE/$PIN/hooks/$HOOK_NAME"
if [ ! -x "$TARGET_HOOK" ]; then
	echo "$HOOK_NAME shim: target hook missing at $TARGET_HOOK (run scripts/bootstrap-machine.sh)" >&2
	exit 2
fi
exec "$TARGET_HOOK" "$@"
EOF

# --- .claude/local-overrides.yml (v0.20.1 #147) -----------------------
# Empty-stub by default; populate per-consumer after audit. Schema
# validated by pre-commit-hooks/local-overrides-schema-check.sh.
_write .claude/local-overrides.yml 644 <<'EOF'
# Operator-declared divergence ledger. Anything in here is INTENTIONAL
# drift from plugin SSOT — skipped from hash-drift checks.
#
# See templates/local-overrides.yml.tpl in the plugin source for the
# canonical schema + example entries.

schema_version: 1

overrides: []
EOF

# --- .github/pull_request_template.md --------------------------------
_write .github/pull_request_template.md 644 <<'EOF'
## Summary
<!-- What changed and why -->

## Changes
<!-- Files / modules modified -->

## Test plan
- [ ] Skill exercised against representative input
- [ ] Lint/tests clean for changed files
- [ ] No leaked tokens in diff

## Pre-merge
- [ ] CodeRabbit review clean (or all findings addressed)
- [ ] gitleaks server-side scan passes
- [ ] All required checks per `.github/required-checks-list.yml` green
- [ ] No unresolved review threads

## Rollback

<!-- How to revert if something breaks. -->

Closes #<!-- issue number -->
EOF

# --- .github/commit-template.yml -------------------------------------
_write .github/commit-template.yml 644 <<'EOF'
# Conventional Commits schema SSOT.
# Subject format: <type>(<optional_scope>): <summary>
# Max subject: 70 chars.

types:
  - feat
  - fix
  - refactor
  - perf
  - chore
  - test
  - docs
  - build
  - ci
  - revert

require_body_for: [feat, fix, refactor, perf]
require_footer: "Co-Authored-By:"
max_subject_length: 70
EOF

# --- .github/copilot-instructions.md ---------------------------------
# Byte-SSOT (manifest hashed: true; bootstrap-heredoc-parity gated). Repo-
# AGNOSTIC pointer that redirects GitHub Copilot to the repo-root AGENTS.md
# (the unified non-Claude-CLI reviewer contract). Identical in every repo.
_write .github/copilot-instructions.md 644 <<'EOF'
# GitHub Copilot Instructions

This repo uses a unified `AGENTS.md` at the repo root as the single source of truth for all non-Claude CLI agents (Copilot, Gemini, Codex).

**See: [`AGENTS.md`](../AGENTS.md)** — repo purpose, reviewer contract, conventions, per-CLI invocation context.

The "When invoked as Copilot (Phase 0.5)" section is specifically for you.
EOF

# --- .github/labels.yml ----------------------------------------------
_write .github/labels.yml 644 <<'EOF'
# Label catalog SSOT. Sync via `gh label create` or label-sync workflow.
- name: bug
  color: d73a4a
  description: Something broken
- name: enhancement
  color: a2eeef
  description: New capability
- name: epic
  color: 7057ff
  description: Parent of sub-issues
- name: priority:p1
  color: b60205
- name: priority:p2
  color: d93f0b
- name: priority:p3
  color: fbca04
- name: priority:needs-triage
  color: 5319e7
- name: area:infrastructure
  color: 0e8a16
- name: brainstorm
  color: c5def5
  description: Discussion-style ideation
EOF

# --- .github/required-checks-list.yml --------------------------------
_write .github/required-checks-list.yml 644 <<'EOF'
# SSOT for required status checks. Branch protection on main reads
# this list; pr-merge skill validates each is present + green before
# proceeding.
#
# Schema (per entry):
#   check_name, workflow_file (string|null), event (string|null), notes.
#   advisory[] uses the same schema for not-yet-required checks.
required:
  - check_name: CodeRabbit
    workflow_file: null
    event: null
    notes: Third-party SaaS review; runs server-side, not in Actions.
  - check_name: gitleaks
    workflow_file: gitleaks.yml
    event: pull_request
    notes: Secret scan with default rules
  - check_name: pr-lint
    workflow_file: pr-lint.yml
    event: pull_request
    notes: |
      Sequential checks enforcing area:* label, issue link, and PR
      template section headings — see pr-lint.yml for exact step list

advisory: []
EOF

# --- .github/ISSUE_TEMPLATE rich forms (bug/feature/task/epic/brainstorm) ---
_write .github/ISSUE_TEMPLATE/bug.yml 644 <<'EOF'
name: Bug / Issue
description: Something is broken or not working as expected
labels: ["bug"]
body:
  - type: input
    id: parent
    attributes:
      label: Parent epic
      description: "Issue number of the parent epic that tracks this work (e.g. `#42`). Sub-issues without a parent orphan in Backlog with no epic-progress correlation. If genuinely standalone, file an epic first."
      placeholder: "#NNN"
    validations:
      required: true
  - type: dropdown
    id: area
    attributes:
      label: Area
      description: Generic plugin areas. Consumer repos may extend via local-overrides (see plugin docs). AI triage applies the matching area:* label + board Area field.
      options:
        - Skills (.claude/skills/*)
        - Hooks (.claude/hooks/*, pre-commit-hooks/*)
        - Workflows (.github/workflows/*)
        - Plugin manifest (.claude-plugin/plugin.json, marketplace)
        - Docs (README.md, docs/)
        - Infrastructure (config, gates, _lib, scripts)
        - Other
    validations:
      required: true
  - type: textarea
    id: description
    attributes:
      label: What's happening?
      placeholder: Describe the bug — observed behavior, error messages, when it started.
    validations:
      required: true
  - type: textarea
    id: expected
    attributes:
      label: What should happen?
      placeholder: Expected behavior.
  - type: textarea
    id: repro
    attributes:
      label: Steps to reproduce
      placeholder: |
        1. Run `…`
        2. Observe `…`
        3. Expected `…`, got `…`
  - type: textarea
    id: context
    attributes:
      label: Context
      placeholder: Related issues / PRs / commits. Recent changes nearby. Environment specifics (OS, plugin version).
  - type: textarea
    id: logs
    attributes:
      label: Relevant logs / output
      placeholder: Paste any error output, hook stderr, or test failures here.
      render: shell
EOF

_write .github/ISSUE_TEMPLATE/feature.yml 644 <<'EOF'
name: Feature / Change
description: Request a new feature or configuration change
labels: ["enhancement"]
body:
  - type: input
    id: parent
    attributes:
      label: Parent epic
      description: "Issue number of the parent epic that tracks this work (e.g. `#42`). Sub-issues without a parent orphan in Backlog with no epic-progress correlation. If genuinely standalone, file an epic first."
      placeholder: "#NNN"
    validations:
      required: true
  - type: dropdown
    id: area
    attributes:
      label: Area
      description: Generic plugin areas. Consumer repos may extend via local-overrides (see plugin docs). AI triage applies the matching area:* label + board Area field.
      options:
        - Skills (.claude/skills/*)
        - Hooks (.claude/hooks/*, pre-commit-hooks/*)
        - Workflows (.github/workflows/*)
        - Plugin manifest (.claude-plugin/plugin.json, marketplace)
        - Docs (README.md, docs/)
        - Infrastructure (config, gates, _lib, scripts)
        - Other
    validations:
      required: true
  - type: textarea
    id: description
    attributes:
      label: What do you want?
      placeholder: Describe the change or feature.
    validations:
      required: true
  - type: textarea
    id: context
    attributes:
      label: Why?
      placeholder: What problem does this solve? What triggered it?
    validations:
      required: true
  - type: textarea
    id: acceptance
    attributes:
      label: Acceptance criteria
      placeholder: Testable statements that mark this feature as done.
    validations:
      required: true
EOF

_write .github/ISSUE_TEMPLATE/task.yml 644 <<'EOF'
name: Task / Maintenance
description: Infrastructure work, research, maintenance, or cleanup
labels: []
body:
  - type: input
    id: parent
    attributes:
      label: Parent epic
      description: "Issue number of the parent epic that tracks this work (e.g. `#42`). Sub-issues without a parent orphan in Backlog with no epic-progress correlation. If genuinely standalone, file an epic first."
      placeholder: "#NNN"
    validations:
      required: true
  - type: dropdown
    id: area
    attributes:
      label: Area
      description: Generic plugin areas. Consumer repos may extend via local-overrides (see plugin docs). AI triage applies the matching area:* label + board Area field.
      options:
        - Skills (.claude/skills/*)
        - Hooks (.claude/hooks/*, pre-commit-hooks/*)
        - Workflows (.github/workflows/*)
        - Plugin manifest (.claude-plugin/plugin.json, marketplace)
        - Docs (README.md, docs/)
        - Infrastructure (config, gates, _lib, scripts)
        - Other
    validations:
      required: true
  - type: textarea
    id: description
    attributes:
      label: What needs to be done?
      placeholder: Describe the task.
    validations:
      required: true
  - type: textarea
    id: context
    attributes:
      label: Context
      placeholder: Why is this needed? What triggered it? Related issues / PRs.
  - type: textarea
    id: acceptance
    attributes:
      label: Acceptance criteria
      placeholder: Testable statements that mark this task as done.
    validations:
      required: true
EOF

_write .github/ISSUE_TEMPLATE/epic.yml 644 <<'EOF'
name: Epic
description: Tracking issue for a multi-sub-issue effort (3+ sub-issues, multi-PR scope)
labels: ["epic", "enhancement"]
body:
  - type: dropdown
    id: area
    attributes:
      label: Area
      description: Primary plugin area this epic covers. Consumer repos may extend via local-overrides (see plugin docs). AI triage applies the matching area:* label + board Area field.
      options:
        - Skills (.claude/skills/*)
        - Hooks (.claude/hooks/*, pre-commit-hooks/*)
        - Workflows (.github/workflows/*)
        - Plugin manifest (.claude-plugin/plugin.json, marketplace)
        - Docs (README.md, docs/)
        - Infrastructure (config, gates, _lib, scripts)
        - Other
    validations:
      required: true
  - type: textarea
    id: goal
    attributes:
      label: Goal
      description: One sentence — what outcome does closing this epic produce?
    validations:
      required: true
  - type: textarea
    id: scope
    attributes:
      label: Scope
      placeholder: "In: ... Out: ..."
    validations:
      required: true
  - type: textarea
    id: sub_issues
    attributes:
      label: Sub-issues
      description: Checklist. Link each with `- [ ] #NNN` once filed. The `epic` label is applied automatically by this template's `labels:` field at issue open.
      value: |
        - [ ] #
        - [ ] #
        - [ ] #
    validations:
      required: true
  - type: textarea
    id: acceptance
    attributes:
      label: Acceptance criteria
      description: Testable statements only.
    validations:
      required: true
  - type: textarea
    id: rollout
    attributes:
      label: Rollout plan
      description: Order of PRs, gates between them, human checkpoints.
    validations:
      required: true
  - type: textarea
    id: rollback
    attributes:
      label: Rollback plan
      description: How to revert if something goes wrong mid-rollout.
    validations:
      required: true
EOF

_write .github/ISSUE_TEMPLATE/brainstorm.yml 644 <<'EOF'
name: Brainstorm / Discussion
description: Open-ended discussion, ideation, or architectural exploration — not ready to implement
labels: ["brainstorm"]
body:
  - type: dropdown
    id: area
    attributes:
      label: Area
      description: Primary plugin area this discussion covers. Consumer repos may extend via local-overrides (see plugin docs). AI triage applies the matching area:* label + board Area field.
      options:
        - Skills (.claude/skills/*)
        - Hooks (.claude/hooks/*, pre-commit-hooks/*)
        - Workflows (.github/workflows/*)
        - Plugin manifest (.claude-plugin/plugin.json, marketplace)
        - Docs (README.md, docs/)
        - Infrastructure (config, gates, _lib, scripts)
        - Other
    validations:
      required: true
  - type: textarea
    id: topic
    attributes:
      label: Topic
      placeholder: One-sentence framing of what we're thinking about.
    validations:
      required: true
  - type: textarea
    id: context
    attributes:
      label: Context
      placeholder: What triggered this? Constraints? Prior attempts? Related issues / PRs.
    validations:
      required: true
  - type: textarea
    id: ideas
    attributes:
      label: Ideas so far
      placeholder: |
        - Option A: ...
        - Option B: ...
        - Option C: ...
  - type: textarea
    id: tradeoffs
    attributes:
      label: Tradeoffs / open questions
      placeholder: What's unresolved? What do we need to decide before acting?
  - type: textarea
    id: decision
    attributes:
      label: Decision or next steps
      placeholder: |
        Once the brainstorm reaches a conclusion, fill this in. Then convert to a task/bug/feature issue
        (or close as "won't do" with rationale) and link the follow-up issue here.
EOF

# --- .github/labeler.yml ---------------------------------------------
_write .github/labeler.yml 644 <<'EOF'
---
# Path → label rules consumed by pr-labeler.yml workflow.
# See https://github.com/actions/labeler for syntax.
area:infrastructure:
  - changed-files:
      - any-glob-to-any-file:
          - scripts/**
          - .github/**
          - .claude/**
          - .pre-commit-config.yaml
EOF

# --- .github/workflows/ stubs ----------------------------------------
# Minimal workflow set: gitleaks, pr-lint, pr-labeler. Operator extends
# (lint-ci, project-automation, ai-triage) per repo needs.
_write .github/workflows/gitleaks.yml 644 <<'EOF'
name: Gitleaks Secret Scan
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  gitleaks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
EOF

_write .github/workflows/pr-lint.yml 644 <<'EOF'
name: PR Lint
on:
  pull_request:
    types: [opened, edited, synchronize, reopened]
permissions:
  pull-requests: read
jobs:
  pr-lint:
    runs-on: ubuntu-latest
    env:
      BODY: ${{ github.event.pull_request.body }}
    steps:
      - name: Require PR body
        if: always() && !cancelled()
        run: |
          if [ -z "$BODY" ] || [ "${#BODY}" -lt 50 ]; then
            echo "::error::PR body too short — fill out the template"
            exit 1
          fi
      - name: Require issue reference
        if: always() && !cancelled()
        run: |
          if echo "$BODY" | grep -qiE "(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+"; then
            echo "Issue link found"
          else
            echo "::error::PR body must reference an issue (e.g., 'Closes #N')"
            exit 1
          fi
EOF

_write .github/workflows/pr-labeler.yml 644 <<'EOF'
name: PR auto-label
on:
  pull_request_target:
    types: [opened, synchronize, reopened]
permissions:
  contents: read
  pull-requests: write
jobs:
  label:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/labeler@v5
        with:
          configuration-path: .github/labeler.yml
          sync-labels: true
EOF

_write .gemini/policy.toml 644 <<'EOF'
# v4.28-W4 (#643) — Gemini CLI policy.toml deny block.
# SCHEMA CORRECTED (#236): the prior schema was WRONG and the deny rules were
# no-ops. Per the official policy-engine reference
# (https://geminicli.com/docs/reference/policy-engine):
#   - field is `toolName` (NOT `tool`); an array of names is allowed
#   - `decision` = "allow" | "deny" | "ask_user"
#   - `denyMessage` (NOT `reason`)
#   - numeric `priority` 0-999 — HIGHEST priority wins (NOT declaration order)
#   - built-in tool names are e.g. read_file / read_many_files / list_directory
#     / glob / search_file_content / write_file / replace / run_shell_command /
#     web_fetch (NOT shell / execute_command / fetch_url / edit_file).
#
# Goal: Gemini CLI is a REVIEWER at Phase 0.5 — read-only inspection only; it
# must NEVER edit files, run shell commands, or fetch the network. Loaded via
# `gemini --policy .gemini/policy.toml -p "..."` from
# .claude/hooks/phase0.5-gemini-prefilter.sh. This is defense-in-depth on top of
# settings.json (approvalMode=plan + disableYoloMode), which is the primary
# read-only enforcement.

# ALLOW the read-only inspection tools the reviewer needs (highest priority).
# search_file_content + grep_search are both listed defensively — a name the
# registry does not have simply never matches, so listing both is harmless.
[[rule]]
toolName = ["read_file", "read_many_files", "list_directory", "glob", "search_file_content", "grep_search"]
decision = "allow"
priority = 100

# DENY everything else (deny-by-default, lowest priority) — no write_file /
# replace (edits), no run_shell_command (shell), no web_fetch / google_web_search
# (network), no memory writes. Fail-closed: an un-enumerated tool is denied, so
# the worst case is a degraded (over-restricted) review, never an escaped write.
[[rule]]
toolName = "*"
decision = "deny"
priority = 0
denyMessage = "Phase 0.5 Gemini reviewer is read-only — only read/list/search tools are permitted (no writes, edits, shell, or network)."
EOF

_write .gemini/settings.json 644 <<'EOF'
{
  "model": {
    "name": "gemini-2.5-flash"
  },
  "general": {
    "defaultApprovalMode": "plan",
    "checkpointing": {
      "enabled": true
    }
  },
  "telemetry": {
    "enabled": false
  },
  "context": {
    "fileName": ["AGENTS.md", "GEMINI.md"],
    "fileFiltering": {
      "respectGitIgnore": true,
      "respectGeminiIgnore": true
    }
  },
  "security": {
    "disableYoloMode": true
  },
  "tools": {
    "exclude": [
      "run_shell_command(rm)",
      "run_shell_command(sudo)",
      "run_shell_command(dd)",
      "run_shell_command(mkfs)",
      "run_shell_command(chown)",
      "run_shell_command(chmod)"
    ]
  },
  "_tools_note": "approvalMode='plan' (general.defaultApprovalMode) requires human approval before any tool runs. security.disableYoloMode=true forces every tool execution to require explicit confirmation, blocking the --approval-mode=yolo / --yolo override so plan-mode protections cannot be bypassed via the CLI flag. tools.exclude is a blocklist that uses simple PREFIX matching on the command; run_shell_command(rm) blocks any command whose run_shell_command argument starts with rm. NOTE: tools.exclude is DEPRECATED in favor of the Policy Engine (the 'deny' decision supersedes it) and string-based blocks are weaker than allowlisting — so the AUTHORITATIVE deny rules with priority + glob support live in .gemini/policy.toml [[rule]] deny blocks (#643); these exclude entries are a secondary, defense-in-depth layer.",
  "ui": {
    "hideTips": true,
    "showLineNumbers": true
  }
}
EOF

_write .codex/config.toml 644 <<'EOF'
# Codex CLI 0.125 — project-level config. NOT auto-discovered: 0.125 only loads
# `$CODEX_HOME/config.toml` (default ~/.codex). Phase 0.7 launcher must export
# CODEX_HOME=$REPO_ROOT/.codex before invoking `codex` to pick up these profiles.
# Both profiles share read-only sandbox + never approval — Codex is a reviewer here.
# Scoped for future Phase 0.7 of the local pre-push pipeline — not yet wired (see AGENTS.md).
# Repo conventions live in AGENTS.md at repo root (auto-loaded by Codex when CODEX_HOME points at this dir).

model = "gpt-5.3-codex"
sandbox_mode = "read-only"
approval_policy = "never"
hide_agent_reasoning = true
project_doc_max_bytes = 32768
file_opener = "vscode"

[history]
persistence = "save-all"

[profiles.review]
# Substantive PRs. Inherits global model (gpt-5.3-codex) + sandbox_mode +
# approval_policy; only effort/summary overrides here.
model_reasoning_effort = "high"
model_reasoning_summary = "detailed"

[profiles.fast-triage]
# Renovate / docs-only / single-file PRs — cheap pass on the smallest tier.
# Overrides global model (cheaper tier); other globals inherited.
model = "gpt-5.4-mini"
model_reasoning_effort = "low"
model_reasoning_summary = "concise"

[shell_environment_policy]
# Never expose secrets to shell tools the model invokes.
inherit = "core"
exclude = ["AWS_*", "AZURE_*", "GCP_*", "GCLOUD_*", "DOCKER_*", "VAULT_*", "*_TOKEN", "*_KEY", "*_SECRET", "*_PASSWORD", "*_CREDENTIALS", "*_CERT*", "GH_TOKEN", "GITHUB_TOKEN", "DATABASE_URL", "AGE_*", "SOPS_*", "OPENAI_API_KEY", "ANTHROPIC_API_KEY"]
EOF

_write .coderabbit.base.yaml 644 <<'EOF'
# CodeRabbit BASE config — canonical, repo-AGNOSTIC SSOT (#234, Wave H).
# Docs: https://docs.coderabbit.ai/reference/configuration
#
# This is the shared spine every repo's .coderabbit.yaml is built from. It is
# byte-SSOT (registered `hashed: true` in scripts/bootstrap-manifest.yml, so
# the Wave G #232 hash-drift engine propagates + drift-gates it). Update CR
# review behavior HERE, in one place.
#
# COMPOSE MODEL (bootstrap-repo.sh + refresh-from-source.sh):
#   .coderabbit.yaml = yq deep-merge( .coderabbit.base.yaml , .coderabbit.overlay.yaml )
#   using `*+` semantics: overlay SCALARS win, overlay ARRAYS append to base.
# A NEW repo with no overlay gets this file verbatim as its .coderabbit.yaml.
#
# OVERLAY (per-repo, consumer-owned `.coderabbit.overlay.yaml`) carries ONLY
# repo-specific bits — never duplicate base keys there:
#   - reviews.auto_review.path_filters       (repo source/asset paths)
#   - reviews.auto_review.ignore_title_keywords (repo bot-PR titles)
#   - reviews.labeling_instructions           (domain area:* PR labels)
#   - reviews.path_instructions               (repo file-path review rules)
#   - issue_enrichment.labeling.labeling_instructions (domain area:* issue labels)
#   - tone_instructions                       (repo domain one-liner; overlay overrides)
#   - knowledge_base.code_guidelines.filePatterns (repo-specific SSOT files; appended)
#   - code_generation                         (repo-specific, if any)
#
# CANONICAL LABELING SPLIT (do NOT collapse — they are different CR features):
#   reviews.labeling_instructions            → PR labels (by files changed)
#   issue_enrichment.labeling.labeling_instructions → ISSUE labels (type/priority/area)

language: en-US
tone_instructions: >-
  Direct and concise. Flag real correctness, security, and contract issues;
  skip prose nitpicks. Prefer fail-closed. Recurring classes: hardcoded paths,
  fail-open error suppression, SSOT duplication.
early_access: true
inheritance: false

reviews:
  profile: assertive
  # CR acts as an APPROVING reviewer: posts "Request changes" on findings,
  # auto-switches to "Approve" once all its comments are resolved + pre-merge
  # checks pass. Satisfies branch-protection "require N approving reviews" on
  # consumer repos (e.g. pricing-team-toolkit) so clean PRs merge via CR's
  # approval — no admin override. (#2261)
  request_changes_workflow: true
  high_level_summary: true
  high_level_summary_placeholder: "<!-- coderabbit:summary -->"
  review_status: true
  commit_status: true
  collapse_walkthrough: true
  sequence_diagrams: false
  poem: false
  assess_linked_issues: true
  related_issues: true
  related_prs: false
  suggested_labels: true
  suggested_reviewers: false
  enable_prompt_for_ai_agents: true

  auto_review:
    enabled: true
    drafts: false
    auto_incremental_review: true
    auto_pause_after_reviewed_commits: 5
    base_branches:
      - main
    # Generic bot/rollback titles. Repos append their own (e.g. "Update Docker
    # tag", "Update npm dependency") via overlay.
    ignore_title_keywords:
      - "rollback:"
    ignore_usernames:
      - "renovate[bot]"
    # Generic doc/asset skips. Re-includes FIRST (order matters): SKILL.md +
    # CLAUDE.md/AGENTS.md drive auto-invocation + operating rules, so they ARE
    # reviewed. Repos append repo-specific source paths via overlay.
    path_filters:
      - ".claude/skills/**/*.md"
      - "CLAUDE.md"
      - "AGENTS.md"
      - "GEMINI.md"
      - "!**/*.md"
      - "!LICENSE"
      - "!.gitignore"
      - "!.github/ISSUE_TEMPLATE/**"
      - "!.github/release.yml"
      - "!.claude/.session-state/**"
      - "!.claude/audit/**"
      # #2362: generated SHA-256 registry — integrity is enforced mechanically by
      # the source-hashes-regen gate + hash-drift (sha256sum), not by review. On a
      # mirrored-file change CR computes the BASE-version hash of that file (not
      # HEAD), so it flags .source-hashes.json (which records the HEAD hashes) as
      # "wrong" — a REAL base-version value, NOT a fabrication, but a guaranteed
      # false positive against the HEAD registry. Exclude it.
      - "!.claude/.source-hashes.json"
      - "!**/*.svg"
      - "!**/*.png"
      # v0.34.36 (#2249) canonical-review-exclusion CR-layer globs — NARROWED.
      # A consumer MIRRORS the plugin's _lib/ + the ship-pr-cycle skill into
      # .claude/, and hash-drift --verify enforces byte-identity to the pinned
      # cache, so those are already-reviewed-upstream mirrors; re-reviewing them
      # is the "verbatim treadmill" (media-server #950). CR-in-CI can't express
      # hash-equality, so we glob-exclude ONLY the dirs that are PURELY canonical
      # mirrors in EVERY consumer:
      #   _lib/                 — consumers never author _lib; all plugin mirror.
      #   skills/ship-pr-cycle/ — the cache-driver wrapper; one canonical set.
      # DELIBERATELY NOT excluded (v0.34.36 #2249 — the over-exclusion bug caught
      # by dogfooding media-server #952):
      #   pre-commit-hooks/ + scripts/ — consumers do NOT mirror these (#247: they
      #     exec the plugin's from the pinned cache), so .claude/pre-commit-hooks/
      #     + .claude/scripts/ are PURELY CONSUMER-AUTHORED (e.g. media-server's
      #     encryption / secret-leak guards, deploy scripts). Glob-excluding them
      #     blinds CR to consumer security/ops code for ZERO canonical benefit.
      #   hooks/ + agents/ — MIXED (plugin mirrors + consumer-authored). A coarse
      #     dir glob can't tell them apart. The hash-based LOCAL layers (phase1
      #     prompt-scope + phase2 finding-filter via canonical-review-exclude.sh)
      #     skip the byte-identical mirrors PRECISELY; CR-in-CI reviews those
      #     mirrors but they're upstream-clean (→ ~0 findings) and, crucially,
      #     consumer-authored files in those dirs stay reviewed.
      - "!.claude/_lib/**"
      - "!.claude/skills/ship-pr-cycle/**"

  # PR labels — by which files changed. Base ships ONLY the universal
  # area:infrastructure catch-all (present in every consumer's labels.yml).
  # Domain labels — area:hooks/skills/workflows, type:test/secrets, plus a
  # consumer's own area:streaming/area:coalesce/... — are repo-specific and
  # come via each repo's .coderabbit.overlay.yaml. A consumer whose
  # .github/labels.yml lacks a label must NOT be told to apply it (#2256:
  # media-server #956 flagged the 5 plugin labels as drift — absent in its
  # taxonomy). labels.yml is template-with-overrides, NOT byte-SSOT, so this
  # base must stay repo-agnostic.
  labeling_instructions:
    - label: "area:infrastructure"
      instructions: >-
        Apply when PR touches scripts/, config/gates, _lib, .github SSOT
        configs, or repo-bootstrap files (.pre-commit-config.yaml, .coderabbit*,
        .gitleaks.toml). Catch-all when no more-specific area matches.

  # Universal path review rules. Repos append file-path rules for their own
  # source trees (stacks/, coalesce/, *.sql, ...) via overlay.
  path_instructions:
    - path: ".claude/hooks/*.sh"
      instructions: >-
        Bash strict-mode hook. REQUIRE `set -euo pipefail` (or at minimum
        `set -u`) within the first 20 lines after the shebang — `# event:` /
        `# matcher:` frontmatter may sit between shebang and the strict-mode
        line. REQUIRE paths resolved via `dirname "${BASH_SOURCE[0]}"`, not
        caller CWD. REQUIRE JSON stdin parsed with `jq`, never grep/sed.
        REQUIRE fail-closed on `git rev-parse` and auxiliary commands — `|| true`
        / `2>/dev/null` silently swallow errors. FLAG hardcoded user paths,
        `*"FOO=1"*` globs that fire on arbitrary argv, and `$VAR` interpolated
        inside `jq -r "...$VAR..."` (require `--arg`). PAIRED REVIEW: IF a
        matching .claude/tests/hooks/<name>.bats EXISTS in this repo, inspect it
        for STALE assertions when the hook's event/matcher/exit-code contract
        changes. Do NOT request or flag a MISSING paired test — most
        .claude/hooks/*.sh are vendored byte-identical mirrors of an upstream
        plugin (claude-workflow-core) whose canonical tests live upstream and are
        drift-gate-enforced; a consumer having no local .bats is expected and
        correct, not a coverage gap.
    - path: ".claude/skills/*/run.sh"
      instructions: >-
        Skill wrapper. REQUIRE `set -euo pipefail`. REQUIRE `SKILL_WRAPPER=1`
        exported when invoking gh/git the skill-bypass-guard would otherwise
        refuse. REQUIRE `--help` prints usage + exits 0. REQUIRE idempotent on
        retry. FLAG missing argument bounds checks (`$2` under `set -u` with no
        `[[ $# -lt 2 ]]` guard).
    - path: ".github/workflows/*.yml"
      instructions: >-
        GitHub Actions workflow. REQUIRE top-level or per-job `permissions:`
        (least-privilege; `contents: read` baseline). REQUIRE third-party
        actions pinned to a full commit SHA, not a version tag. REQUIRE
        actionlint clean. REQUIRE secrets via `${{ secrets.X }}`, never inline.
    - path: ".gitleaks.toml"
      instructions: >-
        Secret-scan config shared by the local pre-commit hook and the gitleaks
        Action. Allowlist must be CONSERVATIVE — question any new broad `paths`
        entry, any `commits` entry, and any `stopwords` (stopwords risk false
        negatives; prefer path allowlists). Must cover *.enc files.
    - path: ".pre-commit-config.yaml"
      instructions: >-
        The `repo:` entry for github.com/repbyrepdev/claude-workflow-core pins a
        `rev:` tag in a PRIVATE repository the review sandbox cannot fetch. Do
        NOT flag that `rev:` as a non-existent or unverifiable tag — its
        existence is verified by `pre-commit` install and CI (CR-in-CI does not
        flag it; only the offline CLI sandbox does). Only flag a `rev:` that is
        obviously malformed — i.e. not a semver-style `vMAJOR.MINOR.PATCH` tag
        (optionally with a `-prerelease` and/or `+build` suffix) and not a
        40-char commit SHA.

  tools:
    shellcheck:
      enabled: true
    yamllint:
      enabled: true
    actionlint:
      enabled: true
    gitleaks:
      enabled: true
    osvScanner:
      enabled: true
    semgrep:
      enabled: true
    github-checks:
      # #2271/#2270: CI/CD pipeline log analysis — CR reads the GitHub Actions
      # check-run logs to surface pipeline failures in the review. In the base
      # SSOT so ALL consumers inherit it. timeout_ms = how long CR waits for the
      # checks to reach terminal before analyzing (CR default 90000; 120000 =
      # 2-min buffer for cold runners + the CodeRabbit check's own latency; max
      # 900000). Schema: docs.coderabbit.ai/tools/github-checks.
      enabled: true
      timeout_ms: 120000
    markdownlint:
      enabled: false # too noisy on CLAUDE.md/SKILL.md prose
    languagetool:
      enabled: false # ditto — silences "the the" on judgment-rule prose

chat:
  auto_reply: true

knowledge_base:
  opt_out: false
  web_search:
    enabled: true
  code_guidelines:
    # Universal SSOT files present in every repo. Repos append repo-specific
    # guideline files (.claude/review-config.yml, .claude/ssot-checks.yml, ...)
    # via overlay.
    filePatterns:
      - "CLAUDE.md"
      - "AGENTS.md"
      - ".github/commit-template.yml"
      - ".github/labels.yml"
      - ".github/required-checks-list.yml"
  learnings:
    scope: local
  issues:
    scope: local
  pull_requests:
    scope: local

# Issue labels (type/priority/area) — auto-applied on new/edited issues.
# This is the CANONICAL location for ISSUE labeling (distinct from
# reviews.labeling_instructions, which is PR labeling). Repos append domain
# area:* labels via overlay.
issue_enrichment:
  auto_enrich:
    enabled: true
  labeling:
    auto_apply_labels: true
    labeling_instructions:
      # Type — required, exactly one.
      - label: "bug"
        instructions: >-
          Apply when the issue describes broken/incorrect behavior or a
          regression. Keywords: "broken", "fails", "crashes", "regression",
          "not working", error messages quoted from logs.
      - label: "enhancement"
        instructions: >-
          Apply when the issue requests new functionality or extends existing
          features. Default for feature-style asks. Keywords: "add", "new",
          "support for", "feature".
      - label: "epic"
        instructions: >-
          Apply when the body has ≥3 occurrences of either `- [ ] #NNN`
          (sub-issue ref) OR `- [ ] vX.Y.Z:` (version-stamped task). Multi-
          phase work that decomposes into sub-issues.
      - label: "documentation"
        instructions: >-
          Apply when the issue is solely about CLAUDE.md / SKILL.md / docs
          updates with no code change.
      - label: "question"
        instructions: >-
          Apply when the issue is a clarification request, not actionable work.
      # Area — universal catch-all; repos add domain area:* via overlay.
      - label: "area:infrastructure"
        instructions: >-
          CI/CD, scripts, .claude/ tooling, .github SSOT, repo-bootstrap
          configs. Catch-all when no domain area matches.
      # Priority — required, exactly one. NEVER apply bare `priority:p0`.
      - label: "priority:p0-proposed"
        instructions: >-
          Production broken / active data loss / security-critical. NEVER apply
          bare `priority:p0` — always `p0-proposed` for operator confirmation.
      - label: "priority:p1"
        instructions: >-
          Blocking release, security-adjacent, or high-severity bug affecting
          users.
      - label: "priority:p2"
        instructions: >-
          Important, not blocking. Default for well-scoped features/tasks.
          Non-critical bugs and epics default to p2.
      - label: "priority:p3"
        instructions: "Polish work — nice to have, can wait weeks."
      - label: "priority:needs-triage"
        instructions: >-
          Apply when no area:* keyword matches the body — operator must
          manually classify before further action.
      # plan-me — triggers Issue Planner via auto_planning below.
      - label: "plan-me"
        instructions: >-
          Apply when the issue is `enhancement`, `epic`, or a generic
          well-scoped impl-ready task that benefits from structured phase
          decomposition. SKIP when the issue is `bug` (diagnostic),
          `documentation`, `question`, `brainstorm` (spec phase), already has
          `plan-me` (idempotent), `no-plan` (opt-out), or has any `auto:*`
          label (auto-generated — never plannable).
  planning:
    enabled: true
    auto_planning:
      enabled: true
      # Repos append their own `!auto:*` exclusions (trivy, restore-sanity, ...)
      # via overlay.
      labels:
        - "plan-me"
        - "!bug"
        - "!documentation"
        - "!question"
        - "!brainstorm"
        - "!no-plan"
        - "!auto:renovate"
EOF

# --- Apply labels via gh label create --------------------------------
# Writing .github/labels.yml does not create labels on GitHub — applying
# them is what THIS step does (gh label create per entry), OR a label-sync
# workflow you add to the target yourself. Bootstrap does NOT seed such a
# workflow, so there is no auto-sync-on-first-push.
# OPT-IN only (`--apply-labels`): the create is a REMOTE mutation, so the
# repo contract gates it behind an explicit flag — a plain scaffold never
# silently writes to a GitHub repo's label set. When the flag is given,
# running the create here means a freshly-bootstrapped repo doesn't ship
# with area:* label gates failing on the first PR. Idempotent: `gh label
# create --force` upserts.
#
# Skip-with-NOTE when: dry-run, gh missing, yq missing, no GitHub
# remote, or labels.yml absent. Per-label failures surface their gh
# stderr in the warn line so partial-apply isn't silent.
_apply_labels() {
	local count=0 failed=0 names color desc args err
	if [ "$DRY_RUN" = "1" ]; then
		_log "[dry-run] would apply labels from .github/labels.yml via gh label create"
		return 0
	fi
	if ! command -v gh >/dev/null 2>&1; then
		_log "NOTE: gh CLI not on PATH — skipping label apply (install gh, then re-run with --apply-labels, or add/run a label-sync workflow in the target)"
		return 0
	fi
	if ! command -v yq >/dev/null 2>&1; then
		_log "NOTE: yq not on PATH — skipping label apply (install yq, then re-run with --apply-labels, or add/run a label-sync workflow in the target)"
		return 0
	fi
	if [ ! -f "$TARGET/.github/labels.yml" ]; then
		_log "NOTE: target has no .github/labels.yml — skipping label apply"
		return 0
	fi
	if ! git -C "$TARGET" remote get-url origin 2>/dev/null | grep -q github.com; then
		_log "NOTE: target has no GitHub remote yet — skipping label apply"
		_log "      add a GitHub remote, then re-run with --apply-labels (bootstrap seeds no label-sync workflow), or add/run a label-sync workflow in the target"
		return 0
	fi
	_log "applying labels from .github/labels.yml via gh label create --force..."
	# Materialize names outside process subst so yq rc is checkable.
	if ! names=$(yq -r '.[].name' "$TARGET/.github/labels.yml" 2>&1); then
		_log "ERROR: yq failed to parse .github/labels.yml: $(head -1 <<<"$names")"
		return 2
	fi
	while IFS= read -r name; do
		[ -z "$name" ] && continue
		# --arg-style binding avoids shell-injection via label-name interpolation.
		color=$(yq -r --arg n "$name" '.[] | select(.name == $n) | .color' "$TARGET/.github/labels.yml")
		desc=$(yq -r --arg n "$name" '.[] | select(.name == $n) | .description // ""' "$TARGET/.github/labels.yml")
		args=(label create "$name" --color "$color" --force)
		[ -n "$desc" ] && [ "$desc" != "null" ] && args+=(--description "$desc")
		# Capture stderr so failure cause is visible (auth, rate-limit, color, etc).
		err=$(cd "$TARGET" && gh "${args[@]}" 2>&1 >/dev/null) && {
			count=$((count + 1))
			continue
		}
		_log "  ⚠ failed to create label: $name — $(head -1 <<<"$err")"
		failed=$((failed + 1))
	done <<<"$names"
	if [ "$failed" -gt 0 ]; then
		_log "  ✗ applied $count label(s), $failed FAILED — failing closed (a broken/mismatched labels.yml must not report success, #223)"
		return 2
	fi
	_log "  ✓ applied $count label(s)"
}

# OPT-IN gate (default OFF): only mutate the remote label set when the operator
# explicitly passed --apply-labels. Otherwise NOTE that label sync is SKIPPED, so
# a plain scaffold performs NO gh label remote write. Bootstrap does NOT seed a
# label-sync workflow, so there is no auto-sync-on-first-push — the NOTE gives
# accurate manual recovery instead. --dry-run still previews inside _apply_labels
# (its own guard).
# CR-CLI #1607: _apply_labels can `return 2` on a label-apply failure. A BARE
# call here under `set -euo pipefail` would ABORT the script BEFORE _sync_full_ssot
# + .coderabbit.yaml compose run → a partial bootstrap. Capture the rc instead
# (the only set-e-safe idiom) and DEFER the fail-closed `exit 2` until AFTER the
# end-of-run summary (mirrors the REFRESH_FAILED deferred-exit below), so the
# scaffold + summary still complete and the operator sees the full picture.
LABEL_RC=0
if [ "$APPLY_LABELS" = "1" ] || [ "$DRY_RUN" = "1" ]; then
	_apply_labels || LABEL_RC=$?
else
	_log "NOTE: label sync SKIPPED — no remote label mutation performed."
	_log "      To sync .github/labels.yml to GitHub: re-run scripts/bootstrap-repo.sh <target> --apply-labels,"
	_log "      or add/run a label-sync workflow in the target repo."
fi

# --- Compose .coderabbit.yaml from base [+ overlay] (#234) ------------
# CodeRabbit reads .coderabbit.yaml. We ship the byte-SSOT .coderabbit.base.yaml
# and compose the live config from it + an optional per-repo
# .coderabbit.overlay.yaml. A fresh repo (no overlay) gets the base verbatim;
# the base stays the single update point.
#
# Order matters (#234 r1): the DRY_RUN preview guard comes FIRST inside this
# function — a real run writes the base heredoc, then _sync_full_ssot refreshes
# it, THEN composes (the CALL is deferred to after _sync_full_ssot, see #223
# CR-CLI below), so on a fresh dir the dry-run must report "would compose"
# rather than tripping the (not-yet-written) base-absent NOTE.
# .coderabbit.yaml is a derived artifact but honors the same
# skip-pre-existing-unless-force contract as _write, so a re-run never clobbers
# a consumer's live config (edit the overlay + --force to regenerate). A true
# compose failure WARNs + sets COMPOSE_CR_FAILED so the summary surfaces it
# (exit-code-only automation would otherwise miss the absent .coderabbit.yaml).
_compose_coderabbit() {
	if [ "$DRY_RUN" = "1" ]; then
		_log "[dry-run] would compose .coderabbit.yaml from base + optional overlay"
		return 0
	fi
	local base="$TARGET/.coderabbit.base.yaml"
	local overlay="$TARGET/.coderabbit.overlay.yaml"
	local out="$TARGET/.coderabbit.yaml"
	[ -f "$base" ] || {
		_log "NOTE: .coderabbit.base.yaml absent in target — skipping .coderabbit.yaml compose"
		return 0
	}
	if [ -f "$out" ] && [ "$FORCE" != "1" ]; then
		_log "  • .coderabbit.yaml exists — skipping compose (edit .coderabbit.overlay.yaml + --force to regenerate)"
		SKIPPED_FILES+=(".coderabbit.yaml")
		return 0
	fi
	local composer="$PLUGIN_SCRIPT_DIR/compose-coderabbit.sh"
	if [ ! -x "$composer" ]; then
		_log "WARN: $composer not executable — .coderabbit.yaml NOT composed"
		COMPOSE_CR_FAILED=1
		return 0
	fi
	local args=(--base "$base" --out "$out")
	local suffix=""
	if [ -f "$overlay" ]; then
		args+=(--overlay "$overlay")
		suffix=" + overlay"
	fi
	local cerr
	if cerr=$("$composer" "${args[@]}" 2>&1); then
		_log "  ✓ composed .coderabbit.yaml from base${suffix}"
	else
		_log "WARN: compose-coderabbit.sh failed — .coderabbit.yaml NOT composed: $cerr"
		COMPOSE_CR_FAILED=1
	fi
}
# NB (#223 CR-CLI): _compose_coderabbit is DEFINED here but INVOKED AFTER
# _sync_full_ssot below. _sync_full_ssot (refresh-from-source) can REPLACE
# .coderabbit.base.yaml with the canonical SSOT bytes; composing before the
# sync would derive .coderabbit.yaml from a stale (pre-sync) base. Deferring
# the call until the base is refreshed keeps the composed config in lockstep
# with the synced base. (DRY_RUN preview is handled inside the function.)

# --- Full SSOT sync: copy the byte-identical generic runtime ----------
# The heredocs above seed only the per-repo-flavored + bootstrap-critical
# files. The LARGE generic surface — every .claude/hooks/* runtime hook, the
# _lib/* helpers they source, and the hashed .github/.coderabbit/.gemini/.codex
# byte-SSOTs — lives in .claude/.source-hashes.json and is propagated by
# refresh-from-source.sh (the same primitive that keeps existing consumers in
# sync). Inlining ~100 hooks as heredocs would fork them from their SSOT, so we
# CALL the propagator here instead: one `bootstrap-repo.sh <dir>` now lays the
# repo down with the IDENTICAL hook/skill/gate runtime every other repo has —
# no separate "now remember to run refresh-from-source" step. It also self-heals
# any seed heredoc that has drifted from its hashed live source (the heredoc
# writes first, then refresh overwrites with canonical bytes).
#
# Honors --dry-run (forwarded). NOT --force-gated: refresh is hash-diff driven
# (copies only changed/missing files) and honors the consumer's
# local-overrides.yml skip-list, so re-runs are safe + idempotent. FAIL-CLOSED on
# a REAL install: a refresh failure (or a missing refresher) leaves an INCOMPLETE
# repo, so it WARNs in the summary AND exits 2 (#223 CR-CLI r1) rather than
# reporting success on a partial hook/_lib runtime. --dry-run writes nothing
# (preview), so a hiccup there stays non-fatal (warn + continue).
REFRESH_FAILED=0
_sync_full_ssot() {
	local refresher="$PLUGIN_SCRIPT_DIR/refresh-from-source.sh"
	if [ ! -x "$refresher" ]; then
		# Dry-run is a preview that writes nothing, so it cannot produce an
		# incomplete repo — NOTE and continue. A REAL install with no refresher
		# IS a broken plugin → fail-closed (exit 2) rather than silently lay down
		# an INCOMPLETE repo (#223 CR-CLI r1).
		if [ "${DRY_RUN:-0}" = "1" ]; then
			_log "NOTE: refresh-from-source.sh not found at $refresher — dry-run previews seed files only (full SSOT sync not shown)"
			return 0
		fi
		# #223 CR-CLI: a REAL install with no refresher IS a broken plugin →
		# fail-closed. DEFER the exit (set the flag + return) so the end-of-run
		# summary's REFRESH_FAILED block still runs for real installs; the
		# deferred `exit 2` fires AFTER the summary (see _sync_full_ssot caller).
		_log "ERROR: refresh-from-source.sh missing/non-executable at $refresher — plugin install is broken; refusing to report success on an INCOMPLETE repo (#223)"
		REFRESH_FAILED=1
		return 0
	fi
	local args=(--consumer-path "$TARGET")
	[ "${DRY_RUN:-0}" = "1" ] && args+=(--dry-run)
	_log "syncing full generic SSOT (hooks/_lib + hashed configs) via refresh-from-source.sh..."
	local rerr
	if rerr=$("$refresher" "${args[@]}" 2>&1); then
		# Echo the propagator's per-file lines through our logger so dry-run
		# shows EVERY artifact it would lay down (completeness proof).
		while IFS= read -r line; do [ -n "$line" ] && _log "  $line"; done <<<"$rerr"
		_log "  ✓ full SSOT sync complete"
	else
		_log "WARN: refresh-from-source.sh exited non-zero — generic hook/_lib runtime may be incomplete:"
		while IFS= read -r line; do [ -n "$line" ] && _log "    $line"; done <<<"$rerr"
		REFRESH_FAILED=1
		# #223 r1 (silent-failure-hunter): a FAILED refresh on a REAL install
		# leaves the SAME incomplete-repo end-state as a MISSING refresher (which
		# also sets REFRESH_FAILED above) — so fail-closed here too, rather than
		# reporting exit 0 "success" on a partial hook/_lib runtime that exit-code-
		# driven automation would treat as a clean bootstrap. Dry-run writes
		# nothing (preview), so it stays non-fatal (warn + continue).
		# #223 CR-CLI: the actual `exit 2` is DEFERRED to AFTER the end-of-run
		# summary (see the _sync_full_ssot caller below) so the REFRESH_FAILED
		# summary block runs for REAL installs too, not just dry-runs — otherwise
		# an immediate exit here skipped the operator-facing remediation summary.
		if [ "${DRY_RUN:-0}" != "1" ]; then
			_log "ERROR: refusing to report success on an INCOMPLETE repo (#223). Fix the cause + re-run: scripts/refresh-from-source.sh --consumer-path $TARGET"
		fi
	fi
}
_sync_full_ssot

# --- Compose .coderabbit.yaml AFTER the SSOT sync (#223 CR-CLI) -------
# Now that _sync_full_ssot has refreshed .coderabbit.base.yaml to canonical
# SSOT bytes, derive .coderabbit.yaml from the FRESH base. _compose_coderabbit
# self-skips when DRY_RUN=1 (preview only). Gated on REFRESH_FAILED != 1: when
# the refresh failed we're about to `exit 2` on a REAL install (deferred
# fail-closed below), and the base may be partial/stale — composing then would
# bake a possibly-wrong config, so we skip and let the operator re-run after
# fixing the refresh. (COMPOSE_CR_FAILED set inside is still surfaced by the
# summary block below.)
if [ "$REFRESH_FAILED" != "1" ]; then
	_compose_coderabbit
fi

# --- Summary ---------------------------------------------------------
_log ""
if [ ${#SKIPPED_FILES[@]} -gt 0 ]; then
	_log "⚠ SKIPPED ${#SKIPPED_FILES[@]} pre-existing file(s) — content may be stale:"
	for f in "${SKIPPED_FILES[@]}"; do _log "    - $f"; done
	_log "    Re-run with --force to overwrite (e.g. after pin bump)."
	_log ""
fi
if [ "$COMPOSE_CR_FAILED" = "1" ]; then
	_log "⚠ .coderabbit.yaml was NOT composed — CodeRabbit will fall back to"
	_log "    defaults until you compose it (scripts/compose-coderabbit.sh"
	_log "    --base .coderabbit.base.yaml [--overlay .coderabbit.overlay.yaml]"
	_log "    --out .coderabbit.yaml). See the WARN above for the cause."
	_log ""
fi
if [ "$REFRESH_FAILED" = "1" ]; then
	_log "⚠ Full SSOT sync did NOT complete — the generic .claude/hooks/* +"
	_log "    _lib/* runtime may be partial. Re-run after fixing the cause:"
	_log "    scripts/refresh-from-source.sh --consumer-path $TARGET"
	_log "    See the WARN above for the underlying error."
	_log ""
	# #223 CR-CLI: DEFERRED fail-closed. A REAL install with a failed/missing
	# refresh is an INCOMPLETE repo — exit 2 so exit-code-driven automation never
	# treats it as a clean bootstrap. Deferred to HERE (after the summary above)
	# so the operator-facing remediation summary always prints first; previously
	# the in-function `exit 2` skipped this summary for real installs. Dry-runs
	# never set REFRESH_FAILED for a real failure (they only preview), so this
	# fires only on a genuine real-install failure — but guard on DRY_RUN anyway
	# so the dry-run "complete" path below is never pre-empted.
	if [ "$DRY_RUN" != "1" ]; then
		exit 2
	fi
fi
# CR-CLI #1607: DEFERRED fail-closed for a label-apply failure (LABEL_RC from the
# _apply_labels call site above). A failed `gh label` apply must not report a
# clean bootstrap, but it must ALSO not abort before _sync_full_ssot + the
# .coderabbit.yaml compose + this summary — so the exit is deferred to here, after
# the scaffold is otherwise complete. Ordered AFTER the REFRESH_FAILED block
# (refresh failure is the more fundamental incompleteness) and BEFORE the
# success message so "complete" never prints on a label failure. _apply_labels
# returns 0 in --dry-run, so this only fires on a real apply; guard DRY_RUN anyway.
if [ "$LABEL_RC" -ne 0 ] && [ "$DRY_RUN" != "1" ]; then
	_log "⚠ Label sync FAILED (rc=$LABEL_RC) — the scaffold completed but"
	_log "    .github/labels.yml was NOT fully applied to the remote. Re-run after"
	_log "    fixing the cause: scripts/bootstrap-repo.sh $TARGET --apply-labels"
	_log "    See the label-apply error above."
	_log ""
	exit 2
fi
if [ "$DRY_RUN" = "1" ]; then
	_log "bootstrap-repo dry-run complete. Re-run without --dry-run to apply."
	# Clean up the temp-created dir IF it was empty + we created it.
	# Resolve TARGET to absolute BEFORE cd / so a relative argument like
	# "new-repo" doesn't get re-resolved against root after cd.
	if [ "$TARGET_PREEXISTED" = "0" ]; then
		TARGET_ABS=$(cd "$TARGET" && pwd)
		cd /
		if [ -z "$(ls -A "$TARGET_ABS" 2>/dev/null)" ]; then
			rmdir "$TARGET_ABS"
		else
			_log "⚠ dry-run target dir $TARGET_ABS unexpectedly non-empty — leaving in place for inspection"
		fi
	fi
else
	_log "bootstrap-repo complete at $TARGET (plugin pin $PIN_TAG)."
fi
_log ""
_log "Next steps (manual):"
_log "  1. cd $TARGET"
_log "  2. git init && git add . && git commit -m 'initial: bootstrap from claude-workflow-core'"
_log "  3. gh repo create <owner>/<repo> --source=. --push"
_log "  4. Enable GitHub Actions in repo Settings → Actions → General"
_log "  5. Set up branch protection on main (require checks per .github/required-checks-list.yml)"
_log "  6. pre-commit install"
_log "  7. Run scripts/bootstrap-machine.sh from the plugin if you haven't bootstrapped your machine"
