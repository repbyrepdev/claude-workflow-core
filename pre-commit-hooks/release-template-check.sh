#!/bin/bash
# v4.24 (#597) — pre-commit drift guard for .github/release-template.yml
# and its sibling .github/release.yml.
#
# Ensures the Keep-a-Changelog schema + category mappings stay in sync across:
#   .github/release-template.yml   (local-mode auto-release.sh source)
#   .github/release.yml            (remote-mode --generate-notes fallback)
# Downstream code in auto-release.sh consumes both — drift between them
# means local and remote releases render different structure.

set -u

staged=$(git diff --cached --name-only 2>/dev/null || true)

# Fire if either template is staged.
touched_tmpl=0
touched_release=0
echo "$staged" | grep -qx ".github/release-template.yml" && touched_tmpl=1
echo "$staged" | grep -qx ".github/release.yml" && touched_release=1
[ "$touched_tmpl$touched_release" = "00" ] && exit 0

errs=0

# Read release-template.yml (staged if touched, otherwise from HEAD).
if [ "$touched_tmpl" = "1" ]; then
	if ! tmpl=$(git show ":.github/release-template.yml" 2>&1); then
		echo "ERROR: unable to read staged .github/release-template.yml: $tmpl" >&2
		exit 1
	fi
else
	# Not staged — read from HEAD for comparison.
	if ! tmpl=$(git show "HEAD:.github/release-template.yml" 2>&1); then
		# File may not exist in HEAD (first addition) — treat as empty.
		tmpl=""
	fi
fi

# Read release.yml (staged if touched, otherwise from HEAD).
if [ "$touched_release" = "1" ]; then
	if ! rel=$(git show ":.github/release.yml" 2>&1); then
		echo "ERROR: unable to read staged .github/release.yml: $rel" >&2
		exit 1
	fi
else
	# Not staged — read from HEAD for comparison.
	if ! rel=$(git show "HEAD:.github/release.yml" 2>&1); then
		# File may not exist in HEAD (first addition) — treat as empty.
		rel=""
	fi
fi

if [ "$touched_tmpl" = "1" ]; then
	# If yq is available, use YAML-node validation for higher precision.
	# Otherwise fall back to grep-based checks (original behavior).
	if command -v yq >/dev/null 2>&1 && [ -n "$tmpl" ]; then
		# Create temp file for yq parsing (yq expects file, not stdin variable).
		_tmpl_tmp=$(mktemp)
		printf '%s' "$tmpl" >"$_tmpl_tmp"

		# Required top-level sections.
		for required in "schema" "exemplars" "anti_patterns"; do
			if ! yq -e ".${required}" "$_tmpl_tmp" >/dev/null 2>&1; then
				echo "✗ release-template.yml missing top-level: $required" >&2
				errs=$((errs + 1))
			fi
		done

		# Required section names under schema.sections.
		for required in "Intro" "Highlights" "What's Changed" "Full Changelog"; do
			if ! yq -e ".schema.sections[] | select(.name == \"$required\")" "$_tmpl_tmp" >/dev/null 2>&1; then
				echo "✗ release-template.yml missing section name: $required" >&2
				errs=$((errs + 1))
			fi
		done

		# Required Keep-a-Changelog categories under "What's Changed" groups.
		for required in "### ✨ Added" "### 🐛 Fixed" "### 🔧 Changed" "### 📝 Docs" "### 🔒 Security" "### 🧪 Tests" "### 🔄 Reverted" "### 📦 Dependencies" "### ⚠ Breaking Changes" "### 🏷 Other"; do
			if ! yq -e ".schema.sections[] | select(.name == \"What's Changed\") | .groups[] | select(.category == \"$required\")" "$_tmpl_tmp" >/dev/null 2>&1; then
				echo "✗ release-template.yml missing category: $required" >&2
				errs=$((errs + 1))
			fi
		done

		# Required commit-prefix values across all groups.
		for required in "feat" "fix" "refactor" "docs" "test" "revert" "chore"; do
			if ! yq -e ".schema.sections[] | select(.name == \"What's Changed\") | .groups[].commit_prefixes[] | select(. == \"$required\")" "$_tmpl_tmp" >/dev/null 2>&1; then
				echo "✗ release-template.yml commit_prefixes must include: $required" >&2
				errs=$((errs + 1))
			fi
		done

		rm -f "$_tmpl_tmp"
	else
		# Fallback: grep-based checks with tighter anchoring.
		# Required top-level sections.
		for required in "^schema:" "^exemplars:" "^anti_patterns:"; do
			if ! printf '%s\n' "$tmpl" | grep -Eq "$required"; then
				echo "✗ release-template.yml missing: ${required#^}" >&2
				errs=$((errs + 1))
			fi
		done

		# Required schema subkeys — anchor to "- name:" or "- category:" lines.
		for required in "Intro" "Highlights" "What's Changed" "Full Changelog"; do
			if ! printf '%s\n' "$tmpl" | grep -E "^[[:space:]]+-[[:space:]]+name:[[:space:]]*[\"']?${required}[\"']?" >/dev/null; then
				echo "✗ release-template.yml missing section name: $required" >&2
				errs=$((errs + 1))
			fi
		done

		# Required Keep-a-Changelog category names — anchor to "- category:" lines.
		for required in "### ✨ Added" "### 🐛 Fixed" "### 🔧 Changed" "### 📝 Docs" "### 🔒 Security" "### 🧪 Tests" "### 🔄 Reverted" "### 📦 Dependencies" "### ⚠ Breaking Changes" "### 🏷 Other"; do
			if ! printf '%s\n' "$tmpl" | grep -E "^[[:space:]]+-[[:space:]]+category:[[:space:]]*[\"']?${required}[\"']?" >/dev/null; then
				echo "✗ release-template.yml missing category: $required" >&2
				errs=$((errs + 1))
			fi
		done

		# Required commit-prefix anchors. Match ONLY on `commit_prefixes:` lines
		# so exemplar bullets (`- feat(v4.23-A): ...`) can't false-positive pass
		# the drift guard. Support both inline arrays [feat, fix] and block-style YAML.
		for required in "feat" "fix" "refactor" "docs" "test" "revert" "chore"; do
			# Check inline array format first
			if printf '%s\n' "$tmpl" | grep -qE "^[[:space:]]+commit_prefixes:[[:space:]]*\[.*\<${required}\>.*\]"; then
				continue
			fi
			# Check block-style format: commit_prefixes: followed by indented - <required>
			if printf '%s\n' "$tmpl" | awk '/^[[:space:]]+commit_prefixes:[[:space:]]*$/{flag=1; next} flag && /^[[:space:]]+-[[:space:]]+'"$required"'([^[:alnum:]]|$)/{found=1; exit} flag && /^[[:space:]]+[^[:space:]-]/{flag=0} END{exit !found}'; then
				continue
			fi
			echo "✗ release-template.yml commit_prefixes must include: $required" >&2
			errs=$((errs + 1))
		done
	fi
fi

if [ "$touched_release" = "1" ]; then
	# Must have a changelog section with categories.
	if ! printf '%s\n' "$rel" | grep -qE "^changelog:"; then
		echo "✗ release.yml missing top-level: changelog:" >&2
		errs=$((errs + 1))
	fi
	if ! printf '%s\n' "$rel" | grep -qE "^[[:space:]]+categories:"; then
		echo "✗ release.yml missing: categories:" >&2
		errs=$((errs + 1))
	fi
	# Category titles here must match release-template.yml.
	# If both are staged, cross-check. Else only this side's presence check.
	for required in "✨ Added" "🐛 Fixed" "🔧 Changed" "🔒 Security" "📝 Docs" "🧪 Tests" "🔄 Reverted" "📦 Dependencies" "⚠ Breaking Changes" "🏷 Other"; do
		if ! printf '%s\n' "$rel" | grep -qF "$required"; then
			echo "✗ release.yml missing category title: $required" >&2
			errs=$((errs + 1))
		fi
	done
fi

if [ "$errs" -gt 0 ]; then
	echo "" >&2
	echo "$errs schema drift error(s) in release template files" >&2
	echo "Both .github/release-template.yml and .github/release.yml are SSOT — keep them aligned." >&2
	exit 1
fi

exit 0
