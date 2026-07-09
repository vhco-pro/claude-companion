# Feature Spec - Timestamp per decision entry (Needs attention)

> Part of [Claude Companion](../claude-companion-spec.md). New (v0.6 candidate). Refines the
> Decisions surface of [panel-redesign](panel-redesign.spec.md) and
> [approval-ux](approval-ux.spec.md). Depends on [foundation](foundation.spec.md). Status: **spec**.

## Purpose

The **Needs attention** / Decisions list shows each surfaced tool-call decision (allow / ask / deny)
with its command and rule, but gives **no indication of *when* it happened**. Scanning the list, a
user can't tell whether an `ask` was surfaced two minutes ago or five days ago - the "last 7d"
header applies to the whole list, not the individual rows. When triaging what still needs a call,
recency matters: a decision from 10 seconds ago is a live prompt worth acting on; one from four days
ago is likely already moot.

This is a **presentation** fix. The data already exists - `AuditRecord.ts` is the ISO8601 instant
the hook recorded the decision (i.e. the moment it was surfaced). Nothing new is ingested, stored,
or computed on the hot path; we only parse and render a value we already persist.

## Design

### 1. Source of truth (no schema change)
- `AuditRecord.ts: String` already holds the surfaced-at instant in ISO8601 (`2026-07-09T01:33:46Z`),
  written by the hook and ingested verbatim. That IS "when it was surfaced" - no new column, no new
  ingest, no migration.

### 2. Pure, testable parsing in CompanionKit
- Add two static helpers next to the existing `AppModel.relative(_ date:)`:
  - `AppModel.relative(iso: String?) -> String?` - parse ISO8601 (with **and** without fractional
    seconds) then reuse the existing relative bucketing ("just now" / "3m ago" / "2h ago" / "5d ago").
  - `AppModel.absolute(iso: String?) -> String?` - parse then format a compact local wall-clock
    label, e.g. `Jul 9, 01:33`, for the expanded detail where a precise time is wanted.
  - Both return `nil` on an unparseable/absent string so the UI degrades gracefully (renders nothing
    rather than a bogus label).
- Parsing tolerates both the plain `…Z` form the hook writes today and the fractional-seconds form,
  matching the same two-formatter fallback `PanelFormat.resetLabel` already uses for usage resets.

### 3. UI (expanded detail only, via the shared `DecisionsList`)
- The timestamp lives **only in the expanded detail** (`decisionActions`), revealed when a row is
  tapped - the collapsed row stays a clean one-liner (icon · command · decision tag). Recency is a
  triage detail you reach for on a specific row, not something that has to crowd every row.
- The detail shows the **absolute** local time plus a **relative** hint on one line, e.g.
  `surfaced Jul 9, 01:33 · 2h ago`. Absent only if `ts` is unparseable.
- Applies to **both** the popover glance and the dashboard Decisions tab, since they compose the same
  `DecisionsList` (one source of truth).

## Behavior
- Live: the relative label reflects age at render time (recomputed from `ts` vs now on each redraw),
  so it ages naturally as the list is reopened; no timer/polling added.
- Timezone: relative labels are absolute-clock agnostic; the absolute label renders in the viewer's
  local timezone (the app is single-user, single-machine for the UI).
- No change to ingest, DB, the hook, or the audit format; sort order of the list is unchanged.

## Acceptance criteria
- [x] The collapsed decision row is unchanged (no timestamp); it appears only on expand.
- [x] Expanding a decision reveals when it was surfaced (absolute local time + relative hint),
      derived from `AuditRecord.ts`.
- [x] Both the popover and the dashboard Decisions tab show it (shared `DecisionsList` -
      build-verified it compiles and is the single composed view).
- [x] An unparseable/missing `ts` renders no timestamp (helpers return `nil`; the `if let` skips it).
- [x] `AppModel.relative(iso:)` / `absolute(iso:)` are covered by unit tests: plain `…Z` and
      fractional-seconds forms parse; relative buckets ("just now", "Nm ago", "Nh ago", "Nd ago");
      unparseable → nil. (`DecisionTimestampTests`, 3 tests, green.)
- [x] No change to ingest, DB, hook, or audit format.

## Open questions / risks
- **Relative vs absolute as the primary label:** relative wins for at-a-glance triage (the common
  case); absolute is available on expand. Revisit only if users ask for absolute-first.
- **Sub-minute freshness:** "just now" covers < 60s; a live prompt reads as "just now" which is the
  intent. No seconds-granularity label - it would churn every redraw for little value.
