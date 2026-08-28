# agent-memory-harness

A two-store memory harness for coding agents.

Agents that persist lessons across sessions accumulate a corpus of small
markdown files. Left alone, that corpus rots: indexes drift from reality,
links dangle, names fork, duplicates pile up, and nothing tells you when it
happened. This harness treats the corpus as data with invariants and gives
you the machinery to keep those invariants true:

- Two stores. An **operator store** that lives outside any repo (personal,
  cross-project, backed up to a private mirror) and an **agent store** that
  lives inside the repo at `.claude/agent-memory/agent` (project-scoped,
  reviewed through PRs, gated by CI).
- A **generated index** (`MEMORY.md`), produced deterministically from file
  frontmatter by `scripts/memory-index.sh`. The index is a projection of the
  store, never a hand-maintained document.
- A **falsification-tested health gate** (`scripts/memory-health.sh`), a
  read-only checker with a strict exit-code contract and a documented
  mutation matrix (see `docs/OPERATIONS.md`) so you can prove every check
  fires before you trust it.
- A **scheduled sweep** (`scripts/memory-health-sweep.sh`), the one
  sanctioned recurring writer: it refreshes a `HEALTH.md` report per store,
  snapshots the operator store to its backup repo, and raises a desktop
  notification only when findings change.
- A **private mirror backup** for the operator store: the store is itself a
  git repo with a private remote; the sweep commits and pushes snapshots.

## Layout

    scripts/
      memory-index.sh          deterministic MEMORY.md generator
      memory-health.sh         read-only health checker (the gate)
      memory-health-sweep.sh   recurring sweep: reports, snapshot, notify
    .github/workflows/
      memory-health.yml        path-filtered CI gate for the agent store
    templates/
      memory-template.md       canonical memory file shape
      launchd.plist.template   macOS scheduler for the sweep
      systemd-user.service.template   Linux scheduler (service half)
      systemd-user.timer.template     Linux scheduler (timer half)
    docs/
      DESIGN.md                every design decision, with rationale
      OPERATIONS.md            install runbook, env vars, falsification
                               recipe, troubleshooting
      harness-diagram.html     browsable overview, two figures
      kit.html                 browsable single-page kit

## Browsable pages

The kit ships two self-contained HTML pages, deployed with GitHub Pages:

- [harness diagram](https://agntflw.github.io/agent-memory-harness/harness-diagram.html)
  -- two figures showing how the harness works end to end, including the
  mirror push.
- [kit on one page](https://agntflw.github.io/agent-memory-harness/kit.html)
  -- the core files embedded with a per-file copy button.

The sources live at `docs/harness-diagram.html` and `docs/kit.html`; both
are self-contained and also open directly in a browser from a clone, no
server needed.

## Quickstart

1. Copy `scripts/` into your repo and mark the scripts executable:

       cp -R agent-memory-harness/scripts your-repo/scripts
       chmod +x your-repo/scripts/memory-*.sh

2. Initialize a store. For the operator store, pick a directory outside any
   repo (for example `~/agent-memory/`) and write your first memory from
   `templates/memory-template.md`. For the agent store, create
   `.claude/agent-memory/agent/lessons/` in the repo and put lesson files
   there. One file per memory; frontmatter carries `name`, `description`,
   and `type` (one of `feedback`, `project`, `reference`).

3. Generate the index (idempotent; rerun after every memory change):

       scripts/memory-index.sh --profile operator ~/agent-memory \
         > ~/agent-memory/MEMORY.md
       scripts/memory-index.sh --profile agent .claude/agent-memory/agent \
         > .claude/agent-memory/agent/MEMORY.md

4. Run the health check:

       scripts/memory-health.sh --profile operator ~/agent-memory
       scripts/memory-health.sh --profile agent .claude/agent-memory/agent

   Add `--also-resolve <other-store-root>` to resolve cross-store
   `[[operator:...]]` / `[[agent:...]]` wikilinks against the other store.

5. Wire CI. Copy `.github/workflows/memory-health.yml` into your repo. It is
   path-filtered to the agent store and the harness tooling, installs
   ripgrep explicitly (ubuntu runners do not ship it), and fails the job
   only on hard failures (exit 2).

6. Install the scheduler template for the recurring sweep. macOS: fill in
   the placeholders in `templates/launchd.plist.template` and load it with
   `launchctl`. Linux: install the systemd user service and timer pair.
   Step-by-step instructions live in `docs/OPERATIONS.md`.

7. Set the environment variables the sweep needs. Only one is required:
   `MEMORY_SWEEP_OPERATOR_STORE` (the operator store lives outside the repo,
   so there is no portable default). The full reference is in
   `docs/OPERATIONS.md`.

8. Add a private mirror remote for the operator store:

       cd ~/agent-memory
       git init -b main && git add -A && git commit -m "Initial memory snapshot"
       git remote add origin <private-repo-url>
       git push -u origin main

   From then on the sweep commits and pushes snapshots automatically; an
   empty diff produces no commit, and a missing remote is skipped quietly.

## Exit-code contract

Both `memory-health.sh` and the sweep honour the same contract:

- `0` clean; informational lines only.
- `1` warnings present. Local and scheduled runs report warnings without
  blocking; CI does not gate on them.
- `2` any hard failure -- including a broken precondition such as ripgrep
  missing, an unreadable store, or bad usage. CI gates on `>= 2`.

The sweep exits with the worst code across both stores.
`memory-index.sh` exits `2` on fatal errors and `0` otherwise.

## License

MIT with the Commons Clause License Condition v1.0 attached; the Licensor
is AGENTFLOW S.R.L. The full text is in [LICENSE](LICENSE), and the license
text governs -- this summary only states the intent:

- You may use, copy, modify, and embed the harness in your own projects,
  open-source or commercial, at no charge.
- Businesses may build and sell products and services with it and monetize
  work that uses it -- the restriction below is only about the harness
  itself.
- You may not Sell the Software: offering the harness itself -- or hosting,
  consulting, or support whose value derives entirely or substantially from
  it -- to third parties for a fee is not licensed.
- Redistribution must keep the copyright notice, the MIT permission notice,
  and the Commons Clause condition notice together.

Note: with the Commons Clause attached this is source-available software,
not open source under the OSI definition; projects with a strict
OSI-only licensing policy should evaluate accordingly.

## FAQ

**Why a generated index instead of maintaining MEMORY.md by hand?**
A hand-maintained index is a dual-write: every memory change requires a
matching index edit, and the failure mode is silent -- entries orphan, drift
accumulates, and nothing detects it. A derived index cannot drift: it is a
pure function of the corpus, regeneration is idempotent, and the health
check verifies the committed index byte-equals regeneration. The full
argument is in `docs/DESIGN.md`.

**Why does the health check fail closed when ripgrep is missing?**
Because a missing tool must never make a sick store look healthy. Without
`rg`, the wikilink and checkpoint checks would return empty result sets --
zero findings, exit 0 -- on a store full of broken links. Partial results
that cannot be distinguished from clean results are worse than no results,
so the checker dies with exit 2 instead. CI installs ripgrep explicitly for
the same reason: ubuntu runners do not ship it.

**Why `export LC_ALL=C` in every script?**
Sort order is locale-dependent. The same store, indexed from an interactive
macOS shell, a launchd job, and a CI runner, produced differently ordered
output until the collation was pinned -- and index drift between
environments looks exactly like a hygiene failure. Pinning `LC_ALL=C` makes
sort order and line-set algebra byte-identical everywhere.

**Why is a memory never renamed?**
The frontmatter `name` is the sole link identity: wikilinks resolve against
it, and greps for the slug are the dedup check before creating a new memory.
Renaming breaks both -- every inbound link dangles and the lineage forks.
A memory that has become wrong is superseded by a new memory that says so;
the old name keeps resolving forever. Legacy files that diverged before the
rule existed are handled by an empty-by-default grandfather allowlist, not
by renaming (see `docs/DESIGN.md`).
