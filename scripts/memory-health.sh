#!/usr/bin/env bash
# scripts/memory-health.sh
# Read-only health checker for an agent-memory store. Never mutates anything.
#
# Exit contract: 0 clean/info, 1 warnings present, 2 any hard failure.
# CI gates on >= 2; local and scheduled runs report 1 without blocking.
#
# Checks (H = hard failure, W = warning, I = informational):
#   H  index drift          MEMORY.md differs from memory-index.sh regeneration
#   H  dangling index ptr   index entry whose file does not exist
#   H  frontmatter keys     name/description/type missing or duplicated
#   H  non-slug name        name is not kebab-case (the name is the link
#                           identity; prose titles rot into dangling links)
#   H  empty name           'name:' present with an empty value (nameless
#                           memories index as broken links)
#   H  name-identity split  normalized basename differs from normalized
#                           frontmatter name (a diverged name forks the dedup
#                           lineage; pre-rule divergences are grandfathered)
#   H  type fragmentation   type value outside feedback|project|reference
#   H  byte duplicates      two files with identical content
#   H  near-miss wikilink   [[target]] that resolves after slug normalization
#                           (strip type prefix, underscores to dashes): a typo,
#                           not an aspiration - fix the link at the link site
#   H  expired tmp scratch  tmp_* older than 7 days (operator profile)
#   H  checkpoint behind    state.json last_tick_iso < newest event stamp
#                           (agent profile, only when events/ present)
#   W  aspirational link    [[target]] with no normalized match; escalates to H
#                           when 2+ distinct files reference the same target
#   W  tmp scratch present  any tmp_* file (operator profile)
#   W  index line budget    generated index > 190 lines (agent 200-line
#                           prompt-load budget)
#   W  date-bearing slug    filename embeds a date - mutable data in an
#                           immutable identity (grandfathered slugs allowlisted)
#   W  cross-store link     [[operator:x]] / [[agent:x]] unresolvable when
#                           --also-resolve given; info when resolver absent
#                           (CI cannot see the operator home directory)
#   I  counts, type histogram, staleness listing (oldest dated stamps)
#
# Identity rule this checker encodes: the frontmatter `name:` is the sole
# identity of a memory; wikilinks resolve against names union filenames sans
# extension; files are never renamed - links are fixed at the link site.
#
# Toolchain: bash 3.2 + ripgrep + POSIX line-set algebra only, by decision.
# Flip trigger to a real parser: the day frontmatter needs nesting beyond
# single-line scalars, or a health run exceeds 5s, or a store crosses 2000
# files.
#
# Usage:
#   scripts/memory-health.sh --profile operator|agent <store-root>
#                            [--also-resolve <other-store-root>]

set -uo pipefail
IFS=$'\n\t'

# Pin collation: sort order and line-set algebra must not vary with the
# invoking locale (interactive macOS shell vs launchd vs CI runner).
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
die() { printf 'memory-health: FATAL: %s\n' "$*" >&2; exit 2; }

# launchd and CI runners start with a bare PATH that misses Homebrew/local
# bins. ripgrep is a hard dependency: without rg the wikilink and checkpoint
# checks would yield empty result sets and a sick store would report healthy.
# Fail closed instead of reporting partial results. Note: ubuntu CI runners
# do not ship ripgrep - install it explicitly in the workflow.
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v rg > /dev/null 2>&1 || die "ripgrep (rg) not found on PATH - the wikilink and checkpoint checks depend on it, and partial results must not report a store as healthy"

PROFILE="" STORE="" OTHER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --also-resolve) OTHER="${2:-}"; shift 2 ;;
    -*) die "unknown option: $1" ;;
    *) STORE="$1"; shift ;;
  esac
done
[ -n "$PROFILE" ] && [ -n "$STORE" ] || die "usage: memory-health.sh --profile operator|agent <store-root> [--also-resolve <path>]"
[ -d "$STORE" ] || die "store root not found: $STORE"

# Grandfathered date-bearing slugs: files created before the immutable-slug
# rule may be allowlisted here, one slug per line (basename without .md), so
# the date-bearing-slug warning skips them. Ships empty on purpose: a fresh
# adoption has no pre-rule history to grandfather. Do not add entries for new
# files - fix the name instead.
GRANDFATHER=''

# Grandfathered name-identity divergences: files whose frontmatter name grew
# away from the filename before the name-identity rule existed may be
# allowlisted here, one slug per line, kept per never-rename. Ships empty on
# purpose. Do not add entries for new files - a divergence is repaired by
# superseding the memory, never by renaming it.
GRANDFATHER_DIVERGED=''

case "$PROFILE" in
  operator)
    FILES=$( (cd "$STORE" && ls -- *.md 2>/dev/null) | grep -v -e '^MEMORY\.md$' -e '^HEALTH\.md$' -e '^tmp_' | sort || true)
    SUBDIR=""
    ;;
  agent)
    FILES=$( (cd "$STORE" && ls -- lessons/*.md 2>/dev/null) | sort || true)
    SUBDIR="lessons/"
    ;;
  *) die "unknown profile: $PROFILE" ;;
esac
[ -n "$FILES" ] || die "no memory files found under $STORE (profile $PROFILE)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
HARD=0 WARN=0

hard() { HARD=$((HARD + 1)); printf 'FAIL  %s\n' "$*"; }
warn() { WARN=$((WARN + 1)); printf 'WARN  %s\n' "$*"; }
info() { printf 'info  %s\n' "$*"; }

abs() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$(pwd)" "$1" ;; esac; }
STORE_ABS=$(abs "$STORE")

# Slug normalization: strip type prefix, underscores to dashes.
normalize() { sed -E 's/^(feedback|project|reference|tmp)[-_]//; s/_/-/g'; }

# Frontmatter block only: the lines between the leading '---' delimiters.
# A file not starting with '---' yields empty output, so the key-count check
# below still fails hard. Bounding here keeps a memory free to quote its own
# template (a fenced 'name:' line in the body) without confusing the checker.
fm() { awk 'NR==1{if($0!="---")exit; next} /^---$/{exit} {print}' "$1"; }

printf '== memory-health: profile=%s store=%s ==\n' "$PROFILE" "$STORE"

# --- resolution sets -------------------------------------------------------
: > "$WORK/slugs"; : > "$WORK/names"
while IFS= read -r f; do
  basename "$f" .md >> "$WORK/slugs"
  fm "$STORE/$f" | sed -n 's/^name: *//p' | head -1 >> "$WORK/names"
done <<EOF
$FILES
EOF
sort -u "$WORK/slugs" "$WORK/names" | grep -v '^$' > "$WORK/resolve"
sort -u "$WORK/resolve" | normalize | sort -u > "$WORK/resolve_norm"

# --- frontmatter keys and type values --------------------------------------
while IFS= read -r f; do
  p="$STORE/$f"
  for key in name description; do
    c=$(fm "$p" | grep -c "^$key: " || true)
    [ "$c" -eq 1 ] || hard "frontmatter: $f has $c '$key:' lines (want exactly 1)"
  done
  n=$(fm "$p" | sed -n 's/^name: *//p' | head -1 | sed -E 's/^"(.*)"$/\1/')
  if [ -z "$n" ] && fm "$p" | grep -q '^name:'; then
    hard "frontmatter: $f has 'name:' with an empty value - nameless memories index as broken links"
  fi
  if [ -n "$n" ] && ! printf '%s' "$n" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'; then
    hard "name is not a kebab slug: $f has name '$n' - the name is the link identity, it must be a stable slug"
  fi
  if [ -n "$n" ]; then
    slug=$(basename "$f" .md)
    if ! printf '%s\n' "$GRANDFATHER_DIVERGED" | grep -qx "$slug"; then
      slug_norm=$(printf '%s\n' "$slug" | normalize)
      name_norm=$(printf '%s\n' "$n" | normalize)
      if [ "$slug_norm" != "$name_norm" ]; then
        hard "name-identity divergence: $f has name '$n' - a diverged name forks the dedup lineage: slug-grep misses the name and vice versa; repair by superseding, never by renaming"
      fi
    fi
  fi
  t=$(fm "$p" | sed -n 's/^[[:space:]]*type: *//p' | head -1)
  case "$t" in
    feedback|project|reference) : ;;
    "") hard "frontmatter: $f has no type" ;;
    *) hard "type fragmentation: $f has type '$t' (want feedback|project|reference)" ;;
  esac
done <<EOF
$FILES
EOF

# --- index drift + dangling pointers ---------------------------------------
if [ -f "$STORE/MEMORY.md" ]; then
  "$SCRIPT_DIR/memory-index.sh" --profile "$PROFILE" "$STORE" > "$WORK/generated" 2>/dev/null \
    || hard "index generator failed for $STORE"
  if [ -s "$WORK/generated" ] && ! diff -q "$WORK/generated" "$STORE/MEMORY.md" > /dev/null 2>&1; then
    hard "index drift: MEMORY.md differs from regeneration (run: memory-index.sh --profile $PROFILE $STORE > $STORE/MEMORY.md)"
    diff "$WORK/generated" "$STORE/MEMORY.md" | sed -n '1,12p' | sed 's/^/      /'
  fi
  rg -o '\]\(([^)]+\.md)\)' -r '$1' "$STORE/MEMORY.md" 2>/dev/null | sort -u > "$WORK/indexed" || true
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -f "$STORE/$rel" ] || hard "dangling index pointer: $rel"
  done < "$WORK/indexed"
  lines=$(wc -l < "$STORE/MEMORY.md" | tr -d ' ')
  [ "$lines" -le 190 ] || warn "index line budget: MEMORY.md has $lines lines (budget 190 of the 200-line prompt load)"
else
  hard "no MEMORY.md index in $STORE"
fi

# --- byte duplicates -------------------------------------------------------
( cd "$STORE" && shasum $FILES 2>/dev/null ) | sort | awk '{print $1}' | uniq -d > "$WORK/dupes" || true
if [ -s "$WORK/dupes" ]; then
  while IFS= read -r h; do
    hard "byte-duplicate files: $( (cd "$STORE" && shasum $FILES) | awk -v H="$h" '$1==H{print $2}' | tr '\n' ' ')"
  done < "$WORK/dupes"
fi

# --- wikilinks -------------------------------------------------------------
( cd "$STORE" && rg -o '\[\[([^]|]+)\]\]' -r '$1' --no-filename $FILES 2>/dev/null ) | sort -u > "$WORK/links" || true
while IFS= read -r target; do
  [ -n "$target" ] || continue
  case "$target" in
    operator:*|agent:*)
      bare=${target#*:}
      if [ -n "$OTHER" ] && [ -d "$OTHER" ]; then
        if [ ! -f "$WORK/other_resolve" ]; then
          for of in "$OTHER"/*.md "$OTHER"/lessons/*.md; do
            [ -f "$of" ] || continue
            basename "$of" .md >> "$WORK/other_resolve"
            fm "$of" | sed -n 's/^name: *//p' | head -1 | sed -E 's/^"(.*)"$/\1/' >> "$WORK/other_resolve"
          done
          : >> "$WORK/other_resolve"
        fi
        grep -qx "$bare" "$WORK/other_resolve" || warn "cross-store link unresolvable: [[${target}]]"
      else
        info "cross-store link (no resolver given): [[${target}]]"
      fi
      continue ;;
  esac
  grep -qx "$target" "$WORK/resolve" && continue
  tn=$(printf '%s\n' "$target" | normalize)
  if grep -qx "$tn" "$WORK/resolve_norm"; then
    suggestion=$(while IFS= read -r r; do [ "$(printf '%s\n' "$r" | normalize)" = "$tn" ] && printf '%s ' "$r"; done < "$WORK/resolve")
    referrers=$( (cd "$STORE" && rg -lF "[[${target}]]" $FILES 2>/dev/null) | tr '\n' ' ')
    hard "near-miss wikilink: [[${target}]] in ${referrers}- did you mean: ${suggestion}"
  else
    refcount=$( (cd "$STORE" && rg -lF "[[${target}]]" $FILES 2>/dev/null) | wc -l | tr -d ' ')
    if [ "$refcount" -ge 2 ]; then
      hard "aspirational wikilink in $refcount files: [[${target}]] - two files rely on a memory that does not exist; write it or fix the links"
    else
      warn "aspirational wikilink: [[${target}]] (allowed while single-referenced)"
    fi
  fi
done < "$WORK/links"

# --- slug lint: dates in filenames -----------------------------------------
while IFS= read -r f; do
  slug=$(basename "$f" .md)
  printf '%s\n' "$GRANDFATHER" | grep -qx "$slug" && continue
  if printf '%s\n' "$slug" | rg -q '20[0-9]{2}[-_][0-9]{2}[-_][0-9]{2}|20[0-9]{2}$'; then
    warn "date-bearing slug: $f (mutable data in an immutable identity; frontmatter holds dates)"
  fi
done <<EOF
$FILES
EOF

# --- tmp scratch lifecycle (operator profile) ------------------------------
if [ "$PROFILE" = "operator" ]; then
  expired=$(find "$STORE_ABS" -maxdepth 1 -name 'tmp_*' -mtime +7 2>/dev/null || true)
  if [ -n "$expired" ]; then
    while IFS= read -r f; do hard "expired tmp scratch (>7 days): $(basename "$f") - promote to a memory or delete"; done <<EOF
$expired
EOF
  fi
  fresh=$(find "$STORE_ABS" -maxdepth 1 -name 'tmp_*' -mtime -8 2>/dev/null || true)
  if [ -n "$fresh" ]; then
    while IFS= read -r f; do warn "tmp scratch present: $(basename "$f") (7-day fuse; staging belongs in the session scratchpad)"; done <<EOF
$fresh
EOF
  fi
fi

# --- agent checkpoint reconciliation ---------------------------------------
if [ "$PROFILE" = "agent" ] && [ -d "$STORE/events" ] && [ -f "$STORE/state.json" ]; then
  ckpt=$(rg -o '"last_tick_iso" *: *"([^"]+)"' -r '$1' "$STORE/state.json" | head -1)
  newest=$(rg -o '20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z' --no-filename "$STORE"/events/*.md 2>/dev/null | sort | tail -1)
  if [ -n "$ckpt" ] && [ -n "$newest" ]; then
    if [ "$(printf '%s\n%s\n' "$ckpt" "$newest" | sort | tail -1)" != "$ckpt" ]; then
      hard "checkpoint behind log: state.json last_tick_iso=$ckpt < newest event stamp $newest"
    else
      info "checkpoint ok: last_tick_iso=$ckpt >= newest event stamp"
    fi
  fi
fi

# --- informational ---------------------------------------------------------
total=$(printf '%s\n' "$FILES" | grep -c . || true)
info "files: $total  wikilinks: $(wc -l < "$WORK/links" | tr -d ' ') distinct targets"
for t in feedback project reference; do
  c=0
  while IFS= read -r f; do
    [ "$(fm "$STORE/$f" | sed -n 's/^[[:space:]]*type: *//p' | head -1)" = "$t" ] && c=$((c + 1))
  done <<EOF
$FILES
EOF
  info "type $t: $c"
done
cutoff=$(date -v-180d +%F 2>/dev/null || date -d '-180 days' +%F 2>/dev/null || echo 1970-01-01)
stale=0
while IFS= read -r f; do
  newest_stamp=$(rg -o '20[0-9]{2}-[0-9]{2}-[0-9]{2}' --no-filename "$STORE/$f" 2>/dev/null | sort | tail -1)
  [ -n "$newest_stamp" ] && [ "$newest_stamp" \< "$cutoff" ] && stale=$((stale + 1))
done <<EOF
$FILES
EOF
info "staleness: $stale files whose newest date stamp predates $cutoff (informational; supersede or revalidate when touched)"

printf '== result: %d hard failure(s), %d warning(s) ==\n' "$HARD" "$WARN"
[ "$HARD" -gt 0 ] && exit 2
[ "$WARN" -gt 0 ] && exit 1
exit 0
