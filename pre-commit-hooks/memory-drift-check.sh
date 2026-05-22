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
MEMORY_DIR="${CLAUDE_MEMORY_DIR:-${MEMORY_DIR:-$HOME/.claude/projects/$(echo "$HOME" | sed 's|/|-|g')/memory}}"
[ -d "$MEMORY_DIR" ] || exit 0

if [ "${MEMORY_DRIFT_GATE_SKIP:-0}" = "1" ]; then
	echo "memory-drift-check: MEMORY_DRIFT_GATE_SKIP=1 — bypassing" >&2
	exit 0
fi

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
		# CR #634 round 4 finding 73: validate against staged index, not
		# the working tree. `-e` on checkout passes when a file is absent
		# from the staged commit but a local shadow file exists — weakens
		# the gate's "blocked-when-bypassed" guarantee.
		# Exception: gitignored paths (logs, generated state) won't be in
		# the index by design; accept worktree existence for those.
		if git -C "$REPO_ROOT" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
			: # in index — pass
		elif git -C "$REPO_ROOT" check-ignore -q "$path" 2>/dev/null && [ -e "$REPO_ROOT/$path" ]; then
			: # gitignored but worktree-present (logs/generated files) — pass
		else
			# v0.6.2 (#35): cross-repo awareness. Memory files reference paths
			# in multiple consumer repos + the plugin. From any one repo's
			# cwd, paths in the OTHER repos look "stale". Honor
			# MEMORY_DRIFT_EXTERNAL_ROOTS (colon-separated list of absolute
			# paths) — if the path resolves under any external root, treat
			# as live (no drift).
			external_hit=0
			if [ -n "${MEMORY_DRIFT_EXTERNAL_ROOTS:-}" ]; then
				IFS=':' read -ra _ext_roots <<<"$MEMORY_DRIFT_EXTERNAL_ROOTS"
				for _root in "${_ext_roots[@]}"; do
					[ -n "$_root" ] || continue
					if [ -e "$_root/$path" ]; then
						external_hit=1
						break
					fi
					# v0.6.4 (#35): plugin-cache layout has NO `.claude/` prefix.
					# Memory says `.claude/skills/X/run.sh` but plugin has it
					# at `<cache>/skills/X/run.sh`. Strip prefix + retry so
					# plugin paths resolve from external roots.
					case "$path" in
					.claude/*)
						alt_path="${path#.claude/}"
						if [ -e "$_root/$alt_path" ]; then
							external_hit=1
							break
						fi
						;;
					esac
				done
			fi
			if [ "$external_hit" = "0" ]; then
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
	echo "  Override: MEMORY_DRIFT_GATE_SKIP=1 git commit ..." >&2
	exit 1
fi

exit 0
