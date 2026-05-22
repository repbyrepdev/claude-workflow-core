#!/bin/bash
# Pre-commit: require a `permissions:` block in every staged .github/workflows/*.yml.
# GitHub's default GITHUB_TOKEN scope is write-all; explicit least-privilege
# blocks prevent accidental privilege escalation. actionlint doesn't warn on
# missing permissions.
#
# Opt-out: add `# permissions: opt-out — <reason>` comment in the file.
#
# Part of v3.21 #264.

set -u

# --diff-filter=A only — new workflows. Existing ones are grandfathered.
STAGED=$(git diff --cached --name-only --diff-filter=A | grep -E '^\.github/workflows/.*\.ya?ml$' || true)
[ -z "$STAGED" ] && exit 0

errs=0
for f in $STAGED; do
	[ -f "$f" ] || continue

	# Opt-out comment anywhere in file
	if grep -q "^# permissions: opt-out" "$f"; then continue; fi

	# Require a top-level `permissions:` key. Matches `^permissions:` at column 0.
	if ! grep -q "^permissions:" "$f"; then
		echo "BLOCK: $f — missing \`permissions:\` block at top level" >&2
		echo "  → Add \`permissions: { contents: read }\` (or narrower) to prevent default write-all scope." >&2
		echo "  → OR opt-out: \`# permissions: opt-out — <reason>\` comment." >&2
		errs=$((errs + 1))
	fi
done

exit "$errs"
