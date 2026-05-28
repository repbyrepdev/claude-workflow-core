{
  "_template": {
    "schema": "claude-workflow-core/settings.json.tpl",
    "version_placeholder": "<VERSION>",
    "renderer": "scripts/register-hook.sh --all-auto-register",
    "doc": "Canonical plugin-owned hooks section. Operator copies + renders <VERSION> to the installed plugin version; scripts/register-hook.sh --all-auto-register is the authoritative renderer that scans hooks/*.sh for '# auto-register: true' headers and writes entries with the current cache-dir path. This template documents the SHAPE for operator visibility; the canonical source is the per-hook '# event:' / '# matcher:' headers."
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "<from hook '# matcher:' header>",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/<VERSION>/hooks/<hookname>.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "<from hook '# matcher:' header>",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/<VERSION>/hooks/<hookname>.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/<VERSION>/hooks/<hookname>.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/<VERSION>/hooks/<hookname>.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/<VERSION>/hooks/<hookname>.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/<VERSION>/hooks/<hookname>.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
