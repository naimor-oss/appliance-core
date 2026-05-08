# Claude Code Notes

This file is kept because Claude Code reads `CLAUDE.md` by convention.

The shared, vendor-neutral agent instructions live in:

- [`AGENTS.md`](AGENTS.md) — appliance-specific agent brief
- [`../dev-commons/AGENTS.md`](../dev-commons/AGENTS.md) — sibling-family agent brief
- [`../dev-commons/CONTEXT.md`](../dev-commons/CONTEXT.md) — read first

Claude-specific interpretation:

- Treat `AGENTS.md` as the authoritative project brief.
- Keep `.claude/` local and private.
- Do not put general project knowledge only in `.claude/`; promote useful
  knowledge into tracked docs (in this repo) or into `../dev-commons/`
  (cross-cutting).
