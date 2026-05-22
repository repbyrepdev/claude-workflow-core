#!/bin/bash
set -euo pipefail
# v4.28-W3-K (#670) + v4.28-W3-L (#739): refuse SKILL.md changes that
# re-introduce loader-incompatibility patterns documented in
# .claude/skills/creating-skills/SKILL.md "Skill-tool loader
# compatibility (#670)" section.
#
# Triggers on staged .claude/skills/*/SKILL.md files. Scans:
#
# Inside ```bash fenced code blocks:
#   - multi-line `jq -r --arg ...` filters (parse-eval breaks here)
#   - heredocs with $() substitutions inside escape-laden contexts
#   - any single fenced code block longer than 75 lines
#
# At document level (outside any fenced block, #739):
#   - `!`<cmd>`` context-injection directives whose <cmd> contains a
#     single quote — the loader eval terminates on the embedded quote
#     and prints "unmatched '" style errors.
#
# Bypass (audit-logged): SKILL_MD_LOADER_SKIP=1

if [ "${SKILL_MD_LOADER_SKIP:-0}" = "1" ]; then
	echo "skill-md-loader-safety: SKILL_MD_LOADER_SKIP=1 — bypassing"
	exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$REPO_ROOT"

# Get staged SKILL.md files via NUL-delimited iteration. Filenames with
# whitespace/newlines (rare in practice for tracked source paths but
# possible) would otherwise break the naive `for f in $STAGED` split.
# Pathspec filter delegates the SKILL.md match to git (no grep -z
# portability concern on macOS BSD grep). (CR-in-CI #737 r2.)
violations=0
while IFS= read -r -d '' f; do
	[ -z "$f" ] && continue
	# Scan STAGED blob (`:$f`), not the working tree file. Partial-staging
	# (a partially-staged SKILL.md) would otherwise let the hook pass on
	# the wrong content. (CR-in-CI #737.)
	staged_content=$(git show ":$f" 2>/dev/null) || {
		echo "$f: ERROR: cannot read staged blob — abort hook to be safe" >&2
		violations=$((violations + 1))
		continue
	}
	# Scan fenced bash blocks for the dangerous patterns.
	# shellcheck disable=SC1078,SC1079,SC2026 # awk regex w/ bash-escaped single quotes
	printf '%s\n' "$staged_content" | awk -v file="$f" '
		BEGIN { in_bash = 0; in_fence = 0; block_start = 0; block_lines = 0; in_heredoc = 0; heredoc_tag = ""; heredoc_allow_tabs = 0 }
		# v4.28-W3-L (#739): document-level !`<cmd>` context-injection
		# directives whose <cmd> contains a single quote (\047) trip the
		# Skill-tool loader eval (unmatched-quote error). Affects
		# patterns like !`gh pr view ... -q \047"..."\047`. Only fires
		# OUTSIDE any fenced code block — backtick lines inside ANY
		# fence (bash, markdown, text, yaml) are literal samples, not
		# directives. in_fence covers all fence languages; in_bash is
		# kept for the existing oversize/jq/heredoc checks that only
		# apply to ```bash content.
		!in_fence && /^!`/ {
			if (index($0, "\047") > 0) {
				printf "%s:%d: ERROR: `!`-prefix context-injection directive contains a single quote (trips Skill-tool loader eval). Move to a fenced ```bash code block, or use double quotes only — see creating-skills/SKILL.md for safe alternatives.\n", file, NR
				exit_code = 1
			}
		}
		# CR-in-CI #739 r2 major: fence parser accepts indented (0-3
		# leading spaces, CommonMark spec) and 4+ backtick fences. The
		# repo has 28 indented fences across 5 SKILL.md files; the
		# prior column-0 + 3-tick-only matcher missed all of them. Open
		# rules guard on !in_fence so backtick lines INSIDE an outer
		# fence (e.g. ```` wrapping ```bash) are treated as content.
		!in_fence && /^[ ]{0,3}`{3,}bash[[:space:]]*$/ { in_bash = 1; in_fence = 1; block_start = NR; block_lines = 0; in_heredoc = 0; heredoc_tag = ""; heredoc_allow_tabs = 0; next }
		!in_fence && /^[ ]{0,3}`{3,}[a-zA-Z]/ { in_fence = 1; next }
		# Bare fence line (no language tag) — could open OR close a
		# fence. Toggle in_fence (labeled-language fences set it via
		# the rules above; this rule handles unlabeled blocks AND
		# closes any open fence).
		/^[ ]{0,3}`{3,}[[:space:]]*$/ {
			if (in_fence) {
				# closing
				if (in_bash && block_lines > 75) {
					printf "%s:%d: WARN: bash code block is %d lines (>75) — likely too dense for Skill-tool loader. Move to wrapper script.\n", file, block_start, block_lines
					exit_code = 1
				}
				in_bash = 0
				in_fence = 0
				in_heredoc = 0
				heredoc_tag = ""
				heredoc_allow_tabs = 0
			} else {
				# opening bare fence (no language tag)
				in_fence = 1
			}
			next
		}
		in_bash {
			block_lines++
			# Track heredoc CLOSE first so the same line that ends a
			# heredoc body cant retrigger detection. CR-in-CI #737 r1:
			# without this reset, every $(...) AFTER the heredoc
			# closes was getting false-flagged.
			# CR-in-CI #737 r4: bash heredoc-close rules are STRICT.
			# `<<TAG` requires the delimiter on a line by itself (no
			# leading or trailing whitespace); `<<-TAG` allows ONLY
			# leading tabs (no spaces, no trailing whitespace). The
			# previous `^[[:space:]]*TAG[[:space:]]*$` was too
			# permissive — a body line `  TAG  ` would falsely close
			# the heredoc + miss subsequent $().
			if (in_heredoc && heredoc_tag != "") {
				if (heredoc_allow_tabs) {
					close_re = "^\t*" heredoc_tag "$"
				} else {
					close_re = "^" heredoc_tag "$"
				}
				if ($0 ~ close_re) {
					in_heredoc = 0
					heredoc_tag = ""
					heredoc_allow_tabs = 0
					next
				}
			}
			# Multi-line jq with --arg crosses parse-eval lines.
			if (/jq -r/ && /--arg/ && /'\''[^'\'']*$/) {
				printf "%s:%d: ERROR: multi-line `jq -r --arg ...` filter — breaks Skill-tool loader. Move to wrapper.\n", file, NR
				exit_code = 1
			}
			# Detect heredoc start. Capture the tag so we can match the
			# closing terminator. NOTE: we only flag UNQUOTED tags —
			# `<<TAG` (expansion), NOT `<<\047TAG\047` (no expansion,
			# parse-safe). (\047 = single quote, used for awk-portable
			# matching.) The match[] arr is awk-gawk compatible.
			if (match($0, /<<-?[A-Za-z_][A-Za-z0-9_]*/)) {
				# Capture the matched substring to detect `<<-` (allow
				# leading tabs on close) vs `<<` (no leading whitespace).
				matched = substr($0, RSTART, RLENGTH)
				allow_tabs = (substr(matched, 1, 3) == "<<-") ? 1 : 0
				# Strip the leading `<<` or `<<-` to get the tag.
				tag = matched
				sub(/^<<-?/, "", tag)
				# Skip if the tag was followed by a closing single-quote
				# in the original line — that indicates `<<\047TAG\047`
				# (quoted, parse-safe). We check the char immediately
				# after the matched tag.
				next_char_idx = RSTART + RLENGTH
				if (substr($0, next_char_idx, 1) != "\047") {
					in_heredoc = 1
					heredoc_tag = tag
					heredoc_allow_tabs = allow_tabs
				}
			}
			# Inside an unquoted heredoc, flag $(...) substitutions —
			# their parsing varies across loaders.
			if (in_heredoc && /\$\(/) {
				printf "%s:%d: ERROR: heredoc body contains `$(...)` — quote the heredoc tag (`<<\"EOF\"`) or move to wrapper.\n", file, NR
				exit_code = 1
			}
		}
		END { exit (exit_code ? 1 : 0) }
	' || violations=$((violations + 1))
done < <(git diff --cached --name-only -z --diff-filter=ACMR -- ':(top).claude/skills/*/SKILL.md' 2>/dev/null || true)

if [ "$violations" -gt 0 ]; then
	echo ""
	echo "skill-md-loader-safety: $violations SKILL.md file(s) have loader-incompatibility patterns."
	echo "  See .claude/skills/creating-skills/SKILL.md#skill-tool-loader-compatibility-670"
	echo "  Bypass: SKILL_MD_LOADER_SKIP=1 git commit ..."
	exit 1
fi
exit 0
