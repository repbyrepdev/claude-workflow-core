#!/bin/bash
set -euo pipefail
# v4.27 (#632) item #16 — pre-commit hook: validate that memory `.md` files
# don't reference deleted/renamed hooks or scripts.
#
# WHY: Memory files (workflow_*.md, feedback_*.md, project_*.md) accumulate
# rules + script-path references over time. When a hook gets renamed or
# deleted (e.g. v4.26's lint-yaml.sh / lint-shell.sh / lint-actions.sh
# consolidated into lint-dispatch.sh), the memory file's pointer to the
# old path goes stale. Today this discipline is honor-only — operators
# remember to update memory when paths change. This hook makes it
# mechanical: refuse commit when any staged change leaves a memory file
# referencing a non-existent path.
#
# Scope: only checks PATHS that look like `.claude/...` or `scripts/...`
# referenced inside memory `.md` files. URL-style paths and prose
# mentions (e.g. "the lint-shell hook" without a path) are ignored.
#
# v0.30.J (#177): memory-path migration. A plugin restructure that renames
# old → new internal paths (e.g. v0.6.0 extracted consumer
# `.claude/skills/X/run.sh` into the plugin's top-level `skills/X/run.sh`)
# leaves memory files referencing the OLD path — and nothing migrated them,
# so this gate flagged 14+ memories as stale. The fix is a `.memory-aliases`
# map at repo root (`old -> new`, exact or trailing-slash prefix): a stale
# OLD reference is treated as live when its mapped NEW path resolves. This
# is the documented migration mechanism (vs the prior workaround of baking
# peer-repo defaults into MEMORY_DRIFT_EXTERNAL_ROOTS).
#
# Bypass: MEMORY_DRIFT_GATE_SKIP=1 (audit-logged).

# CR #634 round 2 finding 21: fail closed when repo root unresolvable.
# `exit 0` would silently disable the gate exactly when context is broken.
if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
	echo "memory-drift-check: unable to resolve repository root — refusing commit." >&2
	echo "  Override: MEMORY_DRIFT_GATE_SKIP=1 git commit ..." >&2
	exit 1
fi
# Derive MEMORY_DIR from env override or $HOME-based path (no hardcoded username).
# CR #634 round 3 finding 29: honor both CLAUDE_MEMORY_DIR (this hook's
# original contract) and MEMORY_DIR (used by session-start-report.sh) so
# operators have one consistent knob across hooks.
MEMORY_DIR="${CLAUDE_MEMORY_DIR:-${MEMORY_DIR:-$HOME/.claude/projects/${HOME//\//-}/memory}}"
[ -d "$MEMORY_DIR" ] || exit 0

if [ "${MEMORY_DRIFT_GATE_SKIP:-0}" = "1" ]; then
	echo "memory-drift-check: MEMORY_DRIFT_GATE_SKIP=1 — bypassing" >&2
	exit 0
fi

# Resolve the external-root list once (env override, else sensible peer-repo
# defaults under $HOME). v0.27.0 (#173 sibling): defaults make the hook useful
# out-of-box; memory files reference paths in consumer repos (media-server,
# pricing-team-toolkit) + the plugin cache.
_resolved_roots="${MEMORY_DRIFT_EXTERNAL_ROOTS:-}"
if [ -z "$_resolved_roots" ]; then
	_resolved_roots="$HOME/media-server:$HOME/pricing-team-toolkit"
fi

# _path_resolves <repo-relative-path> → 0 if the path points at a live file.
# Checks, in order: (1) staged index — CR #634 round 4 finding 73 validates
# against the index, not the worktree, so a local shadow file can't weaken the
# gate; (2) gitignored + worktree-present (logs/generated state never enter the
# index by design); (3) any external root (v0.6.2 #35 cross-repo awareness),
# with a `.claude/` prefix strip (v0.6.4 #35) since the plugin-cache layout has
# no `.claude/` prefix (`.claude/skills/X/run.sh` lives at `<cache>/skills/...`).
_path_resolves() {
	local p=$1 _root _alt
	if git -C "$REPO_ROOT" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
		return 0
	fi
	if git -C "$REPO_ROOT" check-ignore -q "$p" 2>/dev/null && [ -e "$REPO_ROOT/$p" ]; then
		return 0
	fi
	[ -n "$_resolved_roots" ] || return 1
	IFS=':' read -ra _ext_roots <<<"$_resolved_roots"
	for _root in "${_ext_roots[@]}"; do
		[ -n "$_root" ] || continue
		[ -e "$_root/$p" ] && return 0
		case "$p" in
		.claude/*)
			_alt="${p#.claude/}"
			[ -e "$_root/$_alt" ] && return 0
			;;
		esac
	done
	return 1
}

# _memory_alias_target <old-path> → echoes the migrated NEW path (and returns
# 0) if `.memory-aliases` maps the old path, else returns 1. Mappings are
# `old -> new`, one per line, `#` comments + blank lines ignored. A mapping
# whose `old` is a trailing-slash prefix (e.g. `.claude/skills/ -> skills/`)
# rewrites the prefix; an exact `old` rewrites the whole path. First match wins.
_memory_alias_target() {
	local p=$1 aliases="$REPO_ROOT/.memory-aliases" line old new
	[ -f "$aliases" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in '#'* | '') continue ;; esac
		# Require a literal "->" separator.
		case "$line" in *'->'*) ;; *) continue ;; esac
		old=${line%%->*}
		new=${line#*->}
		# Trim surrounding whitespace from both sides.
		old=$(printf '%s' "$old" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
		new=$(printf '%s' "$new" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
		[ -n "$old" ] || continue
		case "$p" in
		"$old")
			# Exact-path rename.
			printf '%s\n' "$new"
			return 0
			;;
		"$old"*)
			# Prefix rename (old typically ends in `/`): rewrite the prefix,
			# keep the remainder. Uses ${p#"$old"} so $old is matched literally.
			printf '%s\n' "${new}${p#"$old"}"
			return 0
			;;
		esac
	done <"$aliases"
	return 1
}

# Gather all memory .md files (small set; cheap to scan every commit).
# bash 3.2-portable form (no mapfile) — macOS /bin/bash is bash 3.2.
mem_files=()
while IFS= read -r f; do
	[ -n "$f" ] && mem_files+=("$f")
done < <(find "$MEMORY_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null)
[ "${#mem_files[@]}" -gt 0 ] || exit 0

drift_found=0
drift_lines=""
for mem in "${mem_files[@]}"; do
	# Extract probable script paths from the memory file. Match either
	# inline-code-fenced (`.claude/hooks/foo.sh`) or bare paths.
	# Filter to .sh / .yml / .json / .py / .bats endings to avoid false
	# positives on prose like "see .claude memory" without a real path.
	while IFS= read -r ref; do
		[ -z "$ref" ] && continue
		# Trim surrounding backticks / parens / commas / periods.
		path=$(echo "$ref" | sed -E 's/^[[:space:]]*[`(]*//; s/[`),.;:]*[[:space:]]*$//')
		[ -z "$path" ] && continue
		# Only check paths under .claude/ or scripts/.
		case "$path" in
		.claude/* | scripts/*) ;;
		*) continue ;;
		esac
		# Existence check: only the exact path counts. Prior version had a
		# `check_path="${path%/*}"` fallback that incorrectly accepted
		# "parent dir exists" as proof of file existence. Skip paths
		# containing glob chars (* ?) — those are pattern references in
		# prose (e.g. ".claude/scripts/**/*.sh"), not concrete paths.
		case "$path" in
		*'*'* | *'?'*) continue ;;
		esac
		if _path_resolves "$path"; then
			: # live (index / gitignored-worktree / external root) — pass
		else
			# v0.30.J (#177): the path is stale as-written. Before flagging
			# drift, consult the `.memory-aliases` migration map — if the old
			# path maps to a NEW path that resolves, the reference is honored
			# (the file moved during a plugin restructure; the memory just
			# predates the rename).
			alias_target=$(_memory_alias_target "$path" || true)
			if [ -n "$alias_target" ] && _path_resolves "$alias_target"; then
				: # resolved via migration alias — pass
			else
				drift_found=$((drift_found + 1))
				drift_lines="${drift_lines}  - ${path} (referenced in $(basename "$mem"))"$'\n'
			fi
		fi
		# CR #634 finding 68: anchor matches to start-of-line / whitespace /
		# backtick / paren so URL fragments like `https://github.com/.claude/...`
		# don't false-positive. Drop `head -50` truncation — memory files
		# rarely have >50 paths and missing one stale ref defeats the gate.
		# CR #634 round 3 finding 61: also accept `./scripts/...` and
		# `./.claude/...` prefixes (common in markdown). Strip the `./` after
		# extraction so existence check uses the canonical form.
	done < <(grep -oE '(^|[[:space:]`(])(\./)?(\.?claude|scripts)/[A-Za-z0-9_./*-]+\.(sh|yml|yaml|jsonl|json|py|bats|md)`?' "$mem" 2>/dev/null | sed -E 's/^[[:space:]`(]+//; s#^\./##')
done

if [ "$drift_found" -gt 0 ]; then
	echo "memory-drift-check: $drift_found stale path reference(s) in memory files:" >&2
	printf '%s' "$drift_lines" >&2
	echo "" >&2
	echo "  Update the memory file(s) to point to the current path, or remove the stale reference." >&2
	echo "  (Or add an old -> new mapping to .memory-aliases if the path was renamed by a plugin restructure.)" >&2
	echo "  Override: MEMORY_DRIFT_GATE_SKIP=1 git commit ..." >&2
	exit 1
fi

exit 0
