---
name: creating-skills
description: Guide for creating Claude Code skills following Anthropic's official best practices. Use when user wants to create a new skill, build a skill, write SKILL.md, update an existing skill, or needs skill creation guidelines. Provides structure, frontmatter fields, naming conventions, and new features like dynamic context injection and subagent execution.
---

# Creating skills

Guide for creating Claude Code skills following Anthropic's official best practices.

## Quick start

```bash
# 1. Create skill directory
mkdir -p ~/.claude/skills/<skill-name>

# 2. Create SKILL.md with frontmatter
cat > ~/.claude/skills/<skill-name>/SKILL.md << 'EOF'
---
name: <skill-name>
description: <What it does>. Use when <trigger phrases>. <Key capabilities>.
---

# <Skill title>

<Instructions for the skill workflow>
EOF

# 3. Add optional resources as needed
mkdir -p ~/.claude/skills/<skill-name>/{scripts,references,assets}
```

## SKILL.md structure

### Frontmatter (YAML between `---` markers)

| Field | Required | Description |
|-------|----------|-------------|
| `name` | No | Display name. Defaults to directory name. Lowercase, hyphens, max 64 chars. |
| `description` | Recommended | What + when + capabilities. Max 1024 chars. Determines when Claude activates the skill. |
| `allowed-tools` | No | Tools Claude can use without asking permission when skill is active. |
| `argument-hint` | No | Autocomplete hint for arguments. Example: `[issue-number]` |
| `disable-model-invocation` | No | `true` to prevent auto-invocation (manual `/name` only). |
| `user-invocable` | No | `false` to hide from `/` menu (background knowledge only). |
| `model` | No | Model override when skill is active. |
| `context` | No | `fork` to run in isolated subagent context. |
| `agent` | No | Subagent type when `context: fork`. Built-in: `Explore`, `Plan`, `general-purpose`. |
| `hooks` | No | Lifecycle hooks scoped to this skill. |

### Invocation control matrix

| Configuration | User can invoke | Claude can invoke |
|---------------|-----------------|-------------------|
| (defaults) | Yes | Yes |
| `disable-model-invocation: true` | Yes | No |
| `user-invocable: false` | No | Yes |

### Description formula

```
<What it does>. Use when <trigger phrases>. <Key capabilities>.
```

Include action verbs ("create", "handle"), user intent ("wants to", "needs to"), and domain keywords users would say.

## Directory structure

```
skill-name/
├── SKILL.md              # Required: instructions (keep under 500 lines)
├── scripts/              # Optional: executable code (deterministic, token-efficient)
├── references/           # Optional: docs loaded into context on demand
└── assets/               # Optional: files used in output, NOT loaded into context
                          #   (templates, images, fonts, boilerplate)
```

### Progressive disclosure (3-level loading)

1. **Metadata** (name + description) - always in context (~100 tokens per skill)
2. **SKILL.md body** - loaded when skill triggers (keep under 5k words)
3. **Bundled resources** - loaded as needed by Claude

Reference supporting files from SKILL.md so Claude knows they exist. Keep references one level deep. For files over 100 lines, include a table of contents.

### Scripts vs references vs assets

| Type | Purpose | Loaded into context? |
|------|---------|---------------------|
| `scripts/` | Deterministic operations, complex processing | No (executed via bash) |
| `references/` | Documentation Claude reads while working | Yes, on demand |
| `assets/` | Templates, images, fonts for output | No (copied/used in output) |

Only create scripts when they add value: complex multi-step processing, repeated code generation, deterministic reliability. Not for single-command wrappers.

## Dynamic features

### Context injection

Inject shell command output into skill content before loading:

```markdown
## Recent commits
!`git log --oneline -5 2>/dev/null`
```

The output replaces the directive when the skill loads.

### String substitutions

Pass arguments to skills invoked via `/skill-name arg1 arg2`:

| Variable | Value |
|----------|-------|
| `$ARGUMENTS` | Full argument string |
| `$ARGUMENTS[0]`, `$ARGUMENTS[1]` | Individual arguments |
| `$1`, `$2` | Shorthand for `$ARGUMENTS[N]` |

### Subagent execution

Run a skill in isolated context with `context: fork`:

```yaml
---
name: deep-research
description: Research a topic thoroughly.
context: fork
agent: Explore
---
```

## Degrees of freedom

Match specificity to the task's fragility:

| Level | When to use | Example |
|-------|-------------|---------|
| **High** (text instructions) | Multiple valid approaches, context-dependent | "Analyze the code and suggest improvements" |
| **Medium** (pseudocode/scripts with params) | Preferred pattern exists, some variation OK | Script with configurable parameters |
| **Low** (specific scripts, few params) | Fragile operations, consistency critical | Exact sequence of API calls |

## Naming conventions

- Lowercase, hyphens between words, max 64 chars
- Styles: gerund (`processing-pdfs`), noun phrase (`github-pr-creation`), prefixed group (`github-pr-*`)

## Required: `## Auto-continue` section (#189)

Every SKILL.md **must** end with an `## Auto-continue` section — a decision
tree for what happens after the skill runs, so the next action is explicit and
reviewable rather than ad-hoc. This is enforced by
`.claude/tests/skills/skill-auto-continue-present.bats` (exactly one non-empty
section per skill); a new skill without it fails CI.

Format (see `git-commit/SKILL.md` for the canonical exemplar): bulleted
outcomes, each `**<state>** → <next action>`. Cover the success path, the
common failure paths, and any operator gate. Example:

```markdown
## Auto-continue

- **Succeeded, more work coming** → stay on branch, keep editing
- **Succeeded, ready for review** → run review → push → invoke github-pr-creation (GATE at PR create)
- **Blocked** → diagnose the specific error and fix; do not retry verbatim
```

## Important rules

- **ALWAYS** write descriptions that include WHAT + WHEN triggers + capabilities
- **ALWAYS** keep SKILL.md under 500 lines, split to references when approaching
- **ALWAYS** reference bundled files from SKILL.md so Claude discovers them
- **ALWAYS** end with an `## Auto-continue` section (enforced by bats — see above)
- **NEVER** duplicate info between SKILL.md and reference files
- **NEVER** create wrapper scripts for single commands
- **NEVER** include extraneous files (README.md, CHANGELOG.md, INSTALLATION_GUIDE.md, QUICK_REFERENCE.md)
- **NEVER** explain things Claude already knows (standard libraries, common tools, basic patterns)

## Skill-tool loader compatibility (#670)

The runtime that loads SKILL.md content via the Skill tool surface has been observed to fail with `(eval):17: unmatched '` style errors. The pre-commit hook `skill-md-loader-safety.sh` lint-locks the patterns below (originally for the multi-line `jq`/heredoc/oversize classes from #670, extended in #739 to cover document-level `!`-prefix directives with nested single quotes). Bypass via `SKILL_MD_LOADER_SKIP=1` is audit-logged.

### Inside fenced ` ```bash ` blocks — AVOID

- **Multi-line `jq -r --arg ...` filters** — quoting interplay across newlines breaks the loader's eval. Move the filter into the wrapper script and reference it from SKILL.md as prose ("the wrapper resolves X via `jq` filter — see `run.sh`'s `helper_name()`").
- **Heredocs with `\$()` substitutions** in unquoted-tag bodies (`<<EOF` ... `$(cmd)` ... `EOF`) — quote the tag (`<<'EOF'`) or move to wrapper.
- **Single fenced code blocks longer than 75 lines** — each is a parse-failure surface. Split or replace with prose.

### At document level (`!`-prefix context-injection) — AVOID (#739)

```markdown
## Recent commits
!`git log --oneline -5 2>/dev/null`
```

This feature is great for surfacing live state. But the runtime evaluates the backtick command via shell-eval — and a **single quote inside the command** terminates the eval-wrapper early.

**Broken** (regression from github-pr-merge / pr-review pre-#739):

```markdown
!`gh pr view -q '"PR #\(.number): \(.title)"' 2>/dev/null`
```

**Safe alternatives**:

1. Move to a fenced ```` ```bash ```` block (no eval, Claude runs on demand):
   ````markdown
   ## Current PR
   ```bash
   gh pr view --json number,title,state
   ```
   ````
2. Keep the `!`-prefix directive but use double quotes only — no nested single quotes anywhere in the command.

Note: switching from `-q '...'` to `--template '...'` does NOT fix the issue — the single quotes around the template body still trip the loader. Only options 1 and 2 are loader-safe.

Pattern: SKILL.md describes WHAT and WHEN. The wrapper script implements HOW. Don't duplicate. When you find yourself writing 30+ lines of bash inside a SKILL.md fence, extract a helper into `run.sh` and reference it.

### Skill tool runtime cache (#739, observation)

After modifying a SKILL.md, the Skill tool surface may continue serving the **pre-modification** content for the rest of the session — disk content is correct but the loader caches per-session. Reload (or restart Claude Code) to pick up the new SKILL.md. This is a runtime behavior of the Skill tool itself, not a repo-side issue, but worth knowing when verifying SKILL.md fixes.

## References

- `references/official_best_practices.md` - Principles, anti-patterns, quality checklist, testing
- `references/skill_examples.md` - Concrete skill examples with new features

## Auto-continue

- **New skill authored** → add `.claude/tests/skills/<name>.bats` + run it before committing (untested skills fail the structure audit).
- **SKILL.md modified mid-session** → reload / restart to clear the Skill-tool per-session loader cache before verifying the change (#739).
- **30+ lines of bash inside a SKILL.md fence** → extract a `run.sh` wrapper and reference it; don't grow the fence.
