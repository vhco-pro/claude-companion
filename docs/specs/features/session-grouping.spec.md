# Feature Spec - Session grouping by project + tighter active filter

> Part of [Claude Companion](../claude-companion-spec.md). New (v0.6 candidate). Refines
> [session-monitor](session-monitor.spec.md) and the Sessions surface of
> [panel-redesign](panel-redesign.spec.md). Depends on [foundation](foundation.spec.md). Status: **spec**.

## Purpose

A power user runs **many concurrent Claude Code sessions in the same project folder** (e.g. 11 under
`one-b2c/platform/vega`, 12 under `one-b2c`). The session list renders one card per session, so the
same project name repeats several times - it *reads* like a duplication bug even though every card is
a distinct session (different id, tokens, cost). Two concrete problems:

1. **Repeated project names** with no aggregation - hard to scan, looks broken.
2. **Empty/stale sessions leak into "active"** - a 0-tool, no-model session shows as a live `?` card
   because `active` is purely a recency test (`lastSeen` within 30 min) with no activity floor.

This is a **presentation** fix (the rows are real data); group same-project sessions into one card and
tighten what counts as active.

## Design

### 1. Group active sessions by project (chosen: *group by project*)
- A pure `SessionGrouping.groupByProject([SessionSummary]) -> [ProjectSessionGroup]` in CompanionKit
  (dependency-free, unit-testable). Group key = `projectPath` (fall back to `projectName`), so two
  different folders that share a leaf name never merge.
- `ProjectSessionGroup` carries the member sessions (newest-first) + **aggregates**: summed
  `toolCount` / `inputTokens` / `outputTokens` / `cacheTokens` / `costUSD` (sum of priced members),
  distinct `models`, `recentTools` from the newest member, `host`, and the group's latest `lastSeen`.
- Groups are ordered by latest `lastSeen` (most-recently-active project first).

### 1a. Title by the *working subfolder*, not the launch cwd
- Claude Code records only the **launch directory** as a session's cwd, so many sessions started at
  a monorepo root all read as the root (`one-b2c`) even though each works in a different subfolder.
- Derive the real working folder from the files the session **actually edits/reads**
  (`tool_events.target_path`): the **deepest common ancestor directory** of the in-project file
  paths. `SessionGrouping.workingDirectory(projectPath:targetPaths:)` (pure, tested) returns it, or
  nil when there's no signal deeper than the root (then fall back to the cwd leaf).
- `SessionSummary.workingPath` carries it; the card **title** = leaf of `workingPath ?? projectPath`,
  and grouping is **keyed by `workingPath`** - so a monorepo-root launch splits into the subfolders
  each session works on (e.g. `vega`, `satellites/foo`). The cwd is still kept for the detail row.

### 2. Tighter active filter (chosen: *recent + has activity*)
- The grouping input is `sessions.filter { $0.active && $0.toolCount > 0 }` - a session must be both
  recent (existing `active` window) **and** have ≥1 tool call. This drops the empty `?` cards.
- `active`'s existing meaning (recency) is unchanged elsewhere; the activity floor lives in the
  grouping layer so nothing else regresses.

### 3. UI (both surfaces, via the shared views)
- **Sessions tab (dashboard):** one **group card** per project: name + a `N sessions` badge +
  aggregated tools/tokens/cost + distinct model chips + the newest session's tool chain. Tap to
  expand → the individual member sessions (today's `SessionCard` + per-session detail), so nothing
  is lost. Host chip carries through for remote groups.
- **Popover (glance):** the **top 3 groups** as compact one-liners (`vega · 3 sessions · $1027`) so
  you see what's busy without opening the dashboard - pairs with the popover's recent-decisions
  glance (see [panel-redesign](panel-redesign.spec.md)).
- Cost-by-project (Sessions tab) is unchanged - it already aggregates by project.

## Behavior
- Live: regroups as sessions start/stop/advance, driven by the existing JSONL tailer (no new polling).
- A single-session project shows a `1 session` card (or no badge) - same info as today, just via the
  group card.
- Grouping is view-state only; the DB, ingest, and session ids are untouched.

## Acceptance criteria
- [ ] Same-project active sessions render as **one card** with a session-count badge and correct
      summed tokens/tools/cost; expanding shows each member session.
- [ ] Two different folders sharing a leaf name stay **separate** groups (keyed by path).
- [ ] 0-tool / no-model sessions never appear as active (the `?` card is gone).
- [ ] Popover shows the top 3 active groups as compact rows.
- [ ] `groupByProject` is covered by unit tests: aggregation sums, distinct models, path-keyed
      separation, newest-first ordering, empty/no-tool exclusion.
- [ ] No change to ingest, DB, or session ids; cost-by-project unchanged.

## Open questions / risks
- **Aggregate cost when some members are unpriced:** sum the priced ones, show the total (matches
  cost-by-project). Acceptable; note it's a lower bound if a model is unpriced.
- **Group ordering** by latest activity vs by cost - default latest activity; revisit if cost-sort is
  more useful.
- **Expanded group + many members:** the dashboard window scrolls, so a 11-session expand is fine;
  the popover only ever shows the 3 collapsed group rows (never expands there).
