# Plan - Timestamp per decision entry (Needs attention)

> Implements [decision-timestamps.spec.md](../specs/features/decision-timestamps.spec.md). Build
> order **16**. Refines the Decisions surface of [panel-redesign](12-panel-redesign.plan.md) +
> [approval-ux](3-approval-ux.plan.md). **Branch:** `feat/decision-timestamps`.

## Outcome

Expanding a **Needs attention** row reveals *when* the decision was surfaced -
`surfaced Jul 9, 01:33 · 2h ago` - while the collapsed row stays a clean one-liner. Purely
presentational; the instant already lives in `AuditRecord.ts`, we parse and render it. No
DB/ingest/hook/audit-format change. Parsing is a pure, unit-tested helper in CompanionKit.

## Phases

### P1 - Parsing helpers in CompanionKit (pure, unit-tested)
- In `AppModel` (CompanionKit), next to the existing `static func relative(_ date:)`:
  - `public static func relative(iso: String?) -> String?` - `parseISO(iso)` → existing
    `relative(date)`; `nil` when absent/unparseable.
  - `public static func absolute(iso: String?) -> String?` - `parseISO(iso)` → `DateFormatter`
    `"MMM d, HH:mm"` local; `nil` when absent/unparseable.
  - `private static func parseISO(_ iso: String) -> Date?` - two-formatter fallback
    (`.withFractionalSeconds` then plain `ISO8601DateFormatter`), same pattern as
    `PanelFormat.resetLabel`.
- *Tests* (`DecisionTimestampTests`): plain `…Z` parses; fractional-seconds parses; `relative(iso:)`
  buckets ("just now" < 60s, "Nm ago", "Nh ago", "Nd ago") built from `Date().addingTimeInterval`;
  unparseable string → nil for both helpers; nil input → nil.

### P2 - Render in the expanded detail only (shared `DecisionsList`)
- `DecisionsList.decisionActions(_:)`: at the top of the detail stack, add a single line combining
  `AppModel.absolute(iso: d.ts)` + `AppModel.relative(iso: d.ts)`, e.g. `surfaced Jul 9, 01:33 · 2h ago`,
  tertiary `.caption2`. The collapsed `DecisionRow` is left unchanged.
- Both the popover (`PanelView`) and dashboard (`DashboardView`) compose this view unchanged, so the
  timestamp shows in both automatically.

### P3 - Verify
- `make test` (adds the new `DecisionTimestampTests`, existing suite stays green).
- `make run` - open the popover + dashboard Decisions tab, confirm each row shows a relative label
  and expanding shows the absolute time.

## Acceptance criteria
Mirrors [the spec](../specs/features/decision-timestamps.spec.md#acceptance-criteria).
