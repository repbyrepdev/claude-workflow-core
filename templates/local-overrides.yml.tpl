# Canonical template for `.claude/local-overrides.yml`. Copied by
# `scripts/bootstrap-repo.sh` into new consumer repos.
#
# Purpose: the operator-declared divergence ledger. Anything listed here
# is INTENTIONAL drift from plugin SSOT — skipped from `hash-drift.sh`
# checks, surfaced separately as "known overrides" instead of "violation".
#
# Schema validated by `pre-commit-hooks/local-overrides-schema-check.sh`.
#
# Categories:
#   domain-extension — file exists ONLY in consumer (e.g. homelab-only
#                      hook, FCP-only Coalesce script). Required fields:
#                      path, category, reason, added.
#   superset         — consumer file is plugin file + extensions
#                      (e.g. consumer labels.yml adds domain-specific
#                      labels on top of plugin's generic set). Required
#                      fields: path, category, reason, added,
#                      diff_allowed (controls what kind of additions
#                      the verifier permits).
#   temp-divergence  — deliberate temporary divergence. Required fields:
#                      path, category, reason, added, expires (YYYY-MM-DD).
#                      Schema-check refuses entries past their expires
#                      date — converts to "must reconcile" on next commit.
#   legacy           — drift predating SSOT discipline; tracked for future
#                      reconciliation. Required fields: path, category,
#                      reason, added. (No automatic age warning today —
#                      operator should periodically audit legacy entries
#                      for reconciliation opportunities.)

schema_version: 1

overrides: []
# Example entries — uncomment + customize per consumer:
#
# overrides:
#   - path: .claude/hooks/check-compose-envfile.sh
#     category: domain-extension
#     reason: "Homelab-specific docker compose validation; not portable to generic plugin"
#     added: "2026-04-21"
#
#   - path: .github/labels.yml
#     category: superset
#     reason: "Domain labels (area:monitoring, area:streaming) extend plugin's generic set"
#     added: "2026-04-21"
#     diff_allowed: domain_extensions_only
#
#   - path: .github/ISSUE_TEMPLATE/bug.yml
#     category: superset
#     reason: "Adds homelab-domain Area dropdown values to plugin baseline"
#     added: "2026-05-01"
#     diff_allowed: dropdown_options_only
#
#   - path: scripts/legacy-helper.sh
#     category: temp-divergence
#     reason: "Patching upstream bug; revert after plugin v0.21.0 ships fix"
#     added: "2026-05-15"
#     expires: "2026-07-01"
