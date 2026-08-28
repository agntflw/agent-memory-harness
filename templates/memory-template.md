---
name: example-memory-slug
description: One line stating the durable fact this memory carries.
metadata:
  type: reference
---

# example-memory-slug

To create a new memory, copy this file into the store as
`<slug>.md` (operator store root, or `lessons/<slug>.md` in the agent
store), where `<slug>` matches the frontmatter `name`. Before creating,
grep the store for the slug and its synonyms -- if a memory for this fact
already exists, extend or supersede it instead of adding a near-duplicate.
Then fill in the frontmatter:

- `name` -- the memory's sole, immutable identity. A kebab-case slug
  (`^[a-z0-9]+(-[a-z0-9]+)*$`), matching the filename, never containing
  dates or anything else mutable, and never changed afterwards. Wikilinks
  resolve against it; a wrong-but-shipped memory is superseded by a new
  one, not renamed.
- `description` -- exactly one single-line sentence saying what durable
  fact the memory carries. It is copied verbatim into the generated
  `MEMORY.md` index, so write it to be read out of context.
- `metadata.type` -- one of `feedback` (a lesson about how to work),
  `project` (a fact about this project's state or history), or
  `reference` (a stable external or technical fact). The index groups by
  this value; anything else is a hard health failure.

Replace this body with the memory's content. A useful shape: what
happened, what the durable lesson or fact is, what evidence backs it
(dates, identifiers, paths), and links to related memories as
`[[other-memory-slug]]` -- or `[[operator:some-slug]]` /
`[[agent:some-slug]]` for a memory in the other store. Dates belong here
in the body or frontmatter, never in the slug. Only the frontmatter block
is parsed by the tooling, and parsing is delimiter-bounded, so the body
may freely quote `name:` or `description:` lines (as this template does)
without confusing the index generator or the health gate.

Store layout note: an operator store is a flat directory of `<slug>.md`
memory files plus three tooling-owned names -- `MEMORY.md` (the generated
index; never hand-edited), `HEALTH.md` (the sweep's report), and optional
`tmp_*` scratch files that carry a 7-day fuse before the health gate
fails them. An agent store lives in the repo at
`.claude/agent-memory/agent/` and holds `MEMORY.md` (generated index),
`state.json` (tick checkpoint state), `events/<YYYY-MM-DD>.md` (one
append-only file per UTC day), and `lessons/<slug>.md` -- the durable
memories, which are the only files indexed and health-checked.
