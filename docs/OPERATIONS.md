# Operations

Install runbook, environment reference, the mirror-backup flow, the
falsification test recipe for the health gate, and troubleshooting.

Throughout, `$REPO` is the repo that holds `scripts/` and the agent store,
and `$OPERATOR_STORE` is the operator store directory outside any repo.

## Install runbook

### Prerequisites (both platforms)

- bash 3.2 or newer (macOS system bash is enough by design).
- ripgrep (`rg`) on PATH. The health checker fails closed without it.
  macOS: `brew install ripgrep`. Debian/Ubuntu: `apt-get install ripgrep`.
- The three scripts under `$REPO/scripts/`, executable
  (`chmod +x scripts/memory-*.sh`).
- Both stores initialized and indexed (see the README quickstart), and a
  clean baseline run: `memory-health.sh` exits 0 or 1 on each store.

### macOS (launchd)

1. Copy `templates/launchd.plist.template` and replace every
   `__PLACEHOLDER__` token:

   - `__LABEL__` -- reverse-DNS job label, e.g. `com.example.memory-health`.
     Must match the installed plist filename sans `.plist`.
   - `__REPO_ROOT__` -- absolute path to `$REPO`.
   - `__OPERATOR_STORE__` -- absolute path to the operator store; the sweep
     refuses to run without `MEMORY_SWEEP_OPERATOR_STORE`.
   - `__LOG_PATH__` -- absolute path to a writable log file, e.g. the
     expansion of `~/Library/Logs/memory-health-sweep.log`.

2. Install and load:

       cp filled-in.plist ~/Library/LaunchAgents/__LABEL__.plist
       launchctl load ~/Library/LaunchAgents/__LABEL__.plist

3. Verify: `launchctl list | grep __LABEL__` shows the job. The template
   sets `StartInterval` 172800 (every 2 days) and `RunAtLoad` false, so
   loading does not fire an immediate sweep -- run
   `scripts/memory-health-sweep.sh` by hand once to confirm the wiring and
   seed the first `HEALTH.md` in each store.

### Linux (systemd user units)

1. Copy both templates and replace `__REPO_ROOT__` and
   `__OPERATOR_STORE__`:

       cp templates/systemd-user.service.template \
          ~/.config/systemd/user/memory-health-sweep.service
       cp templates/systemd-user.timer.template \
          ~/.config/systemd/user/memory-health-sweep.timer

2. Enable:

       systemctl --user daemon-reload
       systemctl --user enable --now memory-health-sweep.timer

3. Verify: `systemctl --user list-timers` shows the timer;
   `journalctl --user -u memory-health-sweep.service` shows run output.
   The timer fires 15 minutes after boot, then every 2 days;
   `Persistent=true` fires a missed run at the next login instead of
   silently skipping it.

On either platform, prefer pointing the scheduler at a dedicated stable
clone rather than your working clone -- see the dead-man section of
`docs/DESIGN.md` for why.

## Environment variable reference

All variables are read by `scripts/memory-health-sweep.sh`.

| Variable                      | Required | Default                                | Meaning                                                        |
| ----------------------------- | -------- | -------------------------------------- | -------------------------------------------------------------- |
| `MEMORY_SWEEP_OPERATOR_STORE` | yes      | none                                   | Path to the operator store. It lives outside the repo, in the operator's home, so there is no portable default; the sweep exits 2 when unset. |
| `MEMORY_SWEEP_REPO`           | no       | the script's parent directory          | Repo root holding `scripts/` and the agent store.               |
| `MEMORY_SWEEP_AGENT_STORE`    | no       | `$REPO/.claude/agent-memory/agent`     | Path to the agent store.                                        |
| `MEMORY_SWEEP_GIT_NAME`       | no       | store's own git config                 | Author name for the snapshot commit. Used only when the email is also set. |
| `MEMORY_SWEEP_GIT_EMAIL`      | no       | store's own git config                 | Author email for the snapshot commit. Used only when the name is also set. |

`memory-health.sh` and `memory-index.sh` take no environment configuration;
everything is flags (`--profile`, the store root, and for the health
checker the optional `--also-resolve <other-store-root>`).

## Mirror-backup flow

The operator store lives outside any project repo, so nothing backs it up
unless you make it a repo of its own.

1. Create an empty private repository on your git host (no README, no
   initial commit -- the store's history starts locally).

2. Initialize the store as a repo on branch `main` (the sweep pushes
   `origin main` specifically) and connect it:

       cd "$OPERATOR_STORE"
       git init -b main
       git add -A
       git commit -m "Initial memory snapshot"
       git remote add origin <private-repo-url>
       git push -u origin main

3. From then on, every sweep run: stages everything (`git add -A`), commits
   only when the staged diff is non-empty, with the message
   `Scheduled memory snapshot (YYYY-MM-DD)`, and pushes to `origin main`
   when an `origin` remote exists. Commit identity comes from
   `MEMORY_SWEEP_GIT_NAME`/`MEMORY_SWEEP_GIT_EMAIL` when both are set,
   otherwise from the store's own git config.

Lost-remote behavior:

- No `origin` configured: the push is skipped quietly. Snapshots still
  accumulate as local commits, so wiring a remote later pushes the full
  accumulated history in one go.
- `origin` configured but unreachable or deleted: the push fails, the
  sweep appends `backup push failed` to its notification lines and keeps
  going. Nothing is lost -- history is local-first. Repair the remote (or
  create a fresh private repo and repoint `origin`), then either wait for
  the next sweep or push by hand.

## Falsification test recipe

Never trust a gate you have not watched fire. This recipe seeds one defect
per hard check into a disposable fixture store and states the expected
`FAIL` line and exit code for each. Run it once at adoption, and again
after any change to `memory-health.sh`.

Ground rules:

- Work only on the fixture, never on a real store.
- After each mutation: run the checker, confirm the expected line appears
  and `echo $?` prints the expected code, then restore the fixture (the
  simplest restore is to rebuild it from step 1).
- A seeded frontmatter defect usually also trips `index drift`, because
  the index derives from frontmatter. That collateral finding is correct
  behavior; assert the target line is present, not that it is alone.

### Fixture setup (operator profile)

    STORE=$(mktemp -d)
    cat > "$STORE/first-lesson.md" <<'EOF'
    ---
    name: first-lesson
    description: First fixture memory for the falsification run.
    metadata:
      type: reference
    ---
    Fixture body. Related: [[second-lesson]].
    EOF
    cat > "$STORE/second-lesson.md" <<'EOF'
    ---
    name: second-lesson
    description: Second fixture memory for the falsification run.
    metadata:
      type: project
    ---
    Fixture body.
    EOF
    scripts/memory-index.sh --profile operator "$STORE" > "$STORE/MEMORY.md"
    scripts/memory-health.sh --profile operator "$STORE"

Baseline expectation: `== result: 0 hard failure(s), 0 warning(s) ==`,
exit 0. Do not proceed until the baseline is clean.

### Mutation matrix (hard checks, expected exit 2)

Missing index. Seed: `rm "$STORE/MEMORY.md"`. Expect:
`FAIL  no MEMORY.md index in $STORE`.
Restore: regenerate the index.

Index drift. Seed: `echo extra >> "$STORE/MEMORY.md"`. Expect:
`FAIL  index drift: MEMORY.md differs from regeneration (run: ...)`
followed by an indented diff excerpt.
Restore: regenerate the index.

Dangling index pointer. Seed: append a fake entry,
`echo '- [ghost](ghost.md) — gone' >> "$STORE/MEMORY.md"`. Expect:
`FAIL  dangling index pointer: ghost.md` (plus index drift).
Restore: regenerate the index.

Index generator failure. Seed: `chmod -x scripts/memory-index.sh`.
Expect: `FAIL  index generator failed for $STORE`.
Restore: `chmod +x scripts/memory-index.sh`.

Missing frontmatter key. Seed: delete the `description:` line from
`first-lesson.md`. Expect:
`FAIL  frontmatter: first-lesson.md has 0 'description:' lines (want exactly 1)`.
The same check reports 2 lines if you duplicate the key instead.
Restore fixture.

Empty name. Seed: change the name line to `name:` (no value). Expect:
`FAIL  frontmatter: first-lesson.md has 'name:' with an empty value - nameless memories index as broken links`
(plus a collateral key-count failure: a bare `name:` no longer matches
the `name: ` key pattern, so the exactly-one check reports 0 lines).
Restore fixture.

Non-slug name. Seed: set `name: First Lesson Prose Title`. Expect:
`FAIL  name is not a kebab slug: first-lesson.md has name 'First Lesson Prose Title' - ...`.
Restore fixture.

Name-identity divergence. Seed: set `name: totally-different-slug` in
`first-lesson.md` (a valid slug that is not the filename's). Expect:
`FAIL  name-identity divergence: first-lesson.md has name 'totally-different-slug' - a diverged name forks the dedup lineage: ...`.
Restore fixture.

Missing type. Seed: delete the `type:` line. Expect:
`FAIL  frontmatter: first-lesson.md has no type`.
Restore fixture.

Type fragmentation. Seed: set `type: lesson`. Expect:
`FAIL  type fragmentation: first-lesson.md has type 'lesson' (want feedback|project|reference)`.
Restore fixture.

Byte duplicates. Seed:
`cp "$STORE/first-lesson.md" "$STORE/copied-lesson.md"`. Expect:
`FAIL  byte-duplicate files: copied-lesson.md first-lesson.md` (order per
sort; collateral name-identity and index-drift findings also fire, since
the copy carries the original's name).
Restore: `rm "$STORE/copied-lesson.md"`; regenerate the index.

Near-miss wikilink. Seed: append `See [[first_lesson]].` to the body of
`second-lesson.md` (underscore where the slug has a dash). Expect:
`FAIL  near-miss wikilink: [[first_lesson]] in second-lesson.md - did you mean: first-lesson`.
Restore fixture.

Aspirational wikilink, escalated. Seed: append `[[missing-target]]` to the
body of both fixture files. Expect:
`FAIL  aspirational wikilink in 2 files: [[missing-target]] - two files rely on a memory that does not exist; write it or fix the links`.
With the link in only one file, expect instead
`WARN  aspirational wikilink: [[missing-target]] (allowed while single-referenced)`
and exit 1.
Restore fixture.

Expired tmp scratch (operator profile only). Seed:

    touch "$STORE/tmp_probe.md"
    # macOS:
    touch -mt "$(date -v-8d +%Y%m%d%H%M)" "$STORE/tmp_probe.md"
    # Linux:
    touch -d '8 days ago' "$STORE/tmp_probe.md"

Expect: `FAIL  expired tmp scratch (>7 days): tmp_probe.md - promote to a memory or delete`.
With a fresh mtime instead, expect
`WARN  tmp scratch present: tmp_probe.md (7-day fuse; ...)` and exit 1.
Restore: `rm "$STORE/tmp_probe.md"`.

Checkpoint behind log (agent profile only). Seed a minimal agent fixture:

    ASTORE=$(mktemp -d)
    mkdir -p "$ASTORE/lessons" "$ASTORE/events"
    cp "$STORE/second-lesson.md" "$ASTORE/lessons/second-lesson.md"
    scripts/memory-index.sh --profile agent "$ASTORE" > "$ASTORE/MEMORY.md"
    echo 'tick at 2024-01-02T10:00:00Z' > "$ASTORE/events/2024-01-02.md"
    echo '{"last_tick_iso": "2024-01-01T00:00:00Z"}' > "$ASTORE/state.json"
    scripts/memory-health.sh --profile agent "$ASTORE"

Expect:
`FAIL  checkpoint behind log: state.json last_tick_iso=2024-01-01T00:00:00Z < newest event stamp 2024-01-02T10:00:00Z`.
Setting `last_tick_iso` to `2024-01-02T10:00:00Z` or later flips it to
`info  checkpoint ok: ...` and exit 0.

Fail-closed preflight. Seed: make `rg` genuinely unfindable. Note that a
stripped `PATH` is not enough -- the script prepends `/opt/homebrew/bin`
and `/usr/local/bin` itself, so if ripgrep lives under one of those
prefixes, temporarily rename the binary
(`mv "$(command -v rg)" "$(command -v rg).hidden"`, restore afterwards),
or run the check in a container or CI runner that has no ripgrep
installed. Expect on stderr:
`memory-health: FATAL: ripgrep (rg) not found on PATH - ...`,
exit 2, and no check output at all -- proving a missing tool cannot
produce a clean-looking report.

### Warning tier spot-checks (expected exit 1)

- Date-bearing slug: create `note-2024-01-01.md` with valid frontmatter
  whose name is also `note-2024-01-01` (digits and dashes are legal in a
  kebab slug, and matching the filename avoids a collateral divergence
  failure), regenerate the index, and expect
  `WARN  date-bearing slug: note-2024-01-01.md (mutable data in an immutable identity; frontmatter holds dates)`.
- Index line budget: only reachable on large stores; expect
  `WARN  index line budget: MEMORY.md has N lines (budget 190 of the 200-line prompt load)`
  once the generated index exceeds 190 lines.
- Cross-store link: add `[[operator:first-lesson]]` to an agent-store
  lesson and run without `--also-resolve` -- expect an `info` line; run
  with `--also-resolve` pointing at a store that lacks the target --
  expect `WARN  cross-store link unresolvable: [[operator:first-lesson]]`.

### CI gate self-test

Open a throwaway PR that seeds any one hard defect into the agent store
(index drift is the cheapest: edit one character of the committed
`MEMORY.md`). The `memory-health` workflow must trigger (the path filter
covers `.claude/agent-memory/**`) and the job must fail with
`memory-health reported hard failures (exit 2)`. Close the PR without
merging. If the workflow did not trigger at all, the path filter does not
match your store location -- fix the filter, not the store.

## Troubleshooting

**`memory-health: FATAL: ripgrep (rg) not found on PATH`.**
This is the fail-closed preflight, not a bug: the wikilink and checkpoint
checks depend on `rg`, and partial results must not report a store as
healthy. Install ripgrep. In scheduler contexts note that launchd and CI
runners start with a bare PATH; the scripts prepend `/opt/homebrew/bin`
and `/usr/local/bin` themselves, so if your `rg` lives elsewhere, extend
`PATH` in the scheduler unit or workflow. The shipped CI workflow installs
ripgrep explicitly because ubuntu runners do not ship it.

**Index drift failures that only reproduce on one machine or in CI.**
Classic locale-drift symptom: the diff excerpt shows the same entries in a
different order, none added or removed. The shipped scripts pin
`export LC_ALL=C`, so a committed index generated by them cannot drift
this way -- the stale side is a `MEMORY.md` that was generated by an older
unpinned script or sorted by hand. Regenerate with the shipped generator
and commit the result. If drift persists, diff the two environments'
`sort` behavior directly with slug-shaped input --
`printf 'a_b\na-b\nab\n' | sort` -- dashes and underscores are exactly
where UTF-8 collations disagree with C, and memory slugs are full of
both. Both environments must give the C order.

**Sweeps stopped happening / HEALTH.md is stale.**
Check the generation stamp on the first line of each store's `HEALTH.md`;
older than two sweep intervals means the scheduler is not firing or the
sweep is dying early. Usual cause: the scheduler points at a moved or
deleted path -- the repo was relocated, or the checked-out branch no
longer contains `scripts/`. Diagnose on macOS via the `__LOG_PATH__` log
file and `launchctl list __LABEL__` (a non-zero last-exit status), on
Linux via `journalctl --user -u memory-health-sweep.service`. Fix the
path in the plist or unit (reload it afterwards), or better, point the
scheduler at a dedicated stable clone as recommended in `docs/DESIGN.md`.
Remember the sweep also exits 2 immediately when
`MEMORY_SWEEP_OPERATOR_STORE` is unset -- an edited unit that dropped the
environment block produces exactly this symptom.

**`backup push failed` in the sweep notification.**
The snapshot commit succeeded locally; only the push to `origin main`
failed. Check `git -C "$OPERATOR_STORE" remote -v` and push by hand to see
the real error (auth expired, repo deleted, offline). Nothing is lost --
see the lost-remote behavior above.
