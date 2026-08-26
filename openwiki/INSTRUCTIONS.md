# OpenWiki standing instructions

The generator reads this file on EVERY run. It is the only sanctioned way to
steer output: edits to generated pages under `openwiki/` are reverted by the
update loop, so a correction only survives if it is written here as a rule.

Phrase entries as durable rules ("never describe X by value"), not as one-off
patches ("fix the typo on line 12").

## Rules

- Treat source code and tests as authoritative. When a doc claim and the code
  disagree, the code wins and the doc is the bug.
- Never reproduce secret VALUES. Describe what a secret is for and where it
  is configured, never its contents — this includes anything under an
  encrypted store (SOPS/age) and any CI secret.
- Diagrams: decompose, never truncate. If a view has more nodes than fit,
  split it into multiple complete views rather than capping the node count —
  a truncated diagram silently misrepresents the system.
- Prefer the narrowest accurate statement. Unknowns are verification gaps to
  name, not requirements to invent.

## Repo-specific rules

(Add rules here as corrections come up. Each one you add is a correction that
will not need making twice.)
