# Rollback — claude-workflow-core

If a `claude-workflow-core` release breaks consumer repos, here's how to recover.

## Pinned versions (release log)

| Version | Tag | Consumer SHA references |
| --- | --- | --- |
| v0.1.0 | (tagged on first push) | media-server: TBD · pricing-team-toolkit: TBD |

## Roll back to a prior version (consumer side)

If you've installed the plugin and a release breaks workflow in your consumer repo:

```bash
# Option A: Pin the marketplace entry to a specific tag
# Edit ~/.claude/plugins/marketplaces/claude-workflow-core/marketplace.json
# Change "source": "./" to "source": "./", "ref": "v0.1.0"
# Or in your consumer's local-installed-plugins config

# Option B: Disable the plugin temporarily
/plugin disable claude-workflow-core@claude-workflow-core
```

## Restore deleted local skills (per-consumer rollback)

If a consumer repo's PR deleted the 8 local skill copies + later the plugin breaks, restore the local copies:

### media-server

```bash
cd ~/media-server
# Find the pre-deletion SHA from ROLLBACK.md in this repo (or git log --oneline | grep plugin-extraction)
git checkout <pre-deletion-sha> -- .claude/skills/{ack,brainstorm,creating-skills,deep-audit,memory-consolidate,retro,prove-yourself-audit,cr-plan}
git commit -m "revert: restore local copies of 8 skills after plugin regression"
```

### pricing-team-toolkit

```bash
cd ~/pricing-team-toolkit
git checkout <pre-deletion-sha> -- .claude/skills/{ack,brainstorm,creating-skills,deep-audit,memory-consolidate,retro,prove-yourself-audit,cr-plan}
git commit -m "revert: restore local copies of 8 skills after plugin regression"
```

The pre-deletion SHAs are listed in each consumer's `ROLLBACK.md`. Cross-referenced here too as releases roll out.

## Edit a plugin skill without a release

```bash
cd ~/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/0.1.0/skills/<name>/
# Edit SKILL.md directly — takes effect immediately for current session
# (will be overwritten next /plugin update — push the fix to the plugin repo too)
```

## Permanent rollback — remove plugin entirely

```bash
/plugin uninstall claude-workflow-core@claude-workflow-core
/plugin marketplace remove claude-workflow-core
# Then restore local copies per the consumer-side instructions above.
```

## Plugin update flow (for future reference)

```bash
# 1. In the plugin repo: edit a skill, bump version in .claude-plugin/plugin.json
# 2. Tag + push
git tag v0.1.1
git push origin v0.1.1 main

# 3. In each consumer: /plugin update claude-workflow-core
```
