#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Edit|Write|MultiEdit
# PreToolUse hook: when editing a known-library config file, remind Claude to
# look up docs via context7 MCP first. CLAUDE.md says "NEVER guess field names"
# but without this nudge I fall back on training-data memory which may be stale.
#
# Silent unless the edit target matches a known pattern.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat) || {
	echo "context7-reminder: stdin read failed — skipping" >&2
	exit 0
}
[ -z "$INPUT" ] && INPUT="{}"
# Malformed INPUT JSON makes jq exit 2; under set -euo pipefail pipefail
# propagates and aborts the hook before the context7 reminder fires.
# Diagnostic to stderr keeps the failure visible (advisory exit-0 contract).
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || {
	echo "context7-reminder: jq parse failed (malformed JSON?) — skipping" >&2
	FILE=""
}
[ -z "$FILE" ] && exit 0

# Extract just the filename + immediate parent for pattern matching
BASENAME=$(basename "$FILE")
PARENT=$(basename "$(dirname "$FILE")")

MATCH=""
LIB=""
case "$BASENAME" in
renovate.json | renovate.json5)
	MATCH=1
	LIB="Renovate (packageRules, recreateWhen, platformAutomerge, etc.)"
	;;
.coderabbit.yaml | .coderabbit.yml)
	MATCH=1
	LIB="CodeRabbit (reviews, path_filters, ignore_title_keywords, etc.)"
	;;
.gitleaks.toml)
	MATCH=1
	LIB="Gitleaks (rules, allowlists, regex patterns)"
	;;
.pre-commit-config.yaml)
	MATCH=1
	LIB="pre-commit framework (hooks, repos, local hook syntax)"
	;;
prometheus.yml)
	MATCH=1
	LIB="Prometheus (scrape_configs, rule_files, alerting)"
	;;
alertmanager.yml)
	MATCH=1
	LIB="Alertmanager (route, receivers, inhibit_rules)"
	;;
configuration.yml)
	# Authelia by path, Homepage by path — check parent dir
	if [ "$PARENT" = "authelia" ]; then
		MATCH=1
		LIB="Authelia (identity_validation, access_control, session, totp)"
	fi
	;;
compose.yaml | compose.yml | docker-compose.yaml | docker-compose.yml)
	MATCH=1
	LIB="Docker Compose (service spec: healthcheck, depends_on, networks, volumes)"
	;;
esac

# Also match by path fragment (catches nested stack configs)
case "$FILE" in
*/stacks/*/compose.yaml | */stacks/*/compose.yml)
	MATCH=1
	LIB="${LIB:-Docker Compose + the specific service image}"
	;;
*/grafana/provisioning/dashboards/*.json)
	MATCH=1
	LIB="Grafana dashboard schema (panels, targets, timeseries, stat)"
	;;
*/.github/workflows/*.yml | */.github/workflows/*.yaml)
	MATCH=1
	LIB="GitHub Actions (workflow_dispatch, permissions, jobs, steps syntax)"
	;;
*.toml)
	# Generic .toml — don't override a more-specific name match above.
	# Common in config files (pyproject, Cargo, gitleaks, various config libraries).
	if [ -z "$MATCH" ]; then
		MATCH=1
		LIB="the TOML-based tool (pyproject/Cargo/gitleaks/etc.) — look up the exact schema"
	fi
	;;
*.conf | *.ini | *.cfg)
	# Generic config files — nginx.conf, redis.conf, prowlarr config.xml, etc.
	if [ -z "$MATCH" ]; then
		MATCH=1
		LIB="the specific tool (redis / nginx / etc.) — look up the exact config schema"
	fi
	;;
*.xml)
	if [ -z "$MATCH" ]; then
		MATCH=1
		LIB="the XML-consuming tool (prowlarr / radarr / etc.) — schema varies per app"
	fi
	;;
esac

if [ -n "$MATCH" ]; then
	# v3.22.1 #294: shortened from ~210-token preamble to ~50 tokens. Batch
	# edits were paying the full message on every file. CLAUDE.md covers
	# the "why" — hook only needs to name the lib + point at context7.
	cat <<EOF | jq -Rs '{additionalContext: .}'
→ context7: resolve-library-id → query-docs for $LIB before editing $BASENAME (don't guess schema).
EOF
fi

exit 0
