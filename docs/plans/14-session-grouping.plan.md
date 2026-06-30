# Plan - Session grouping by project + tighter active filter

> Implements [session-grouping.spec.md](../specs/features/session-grouping.spec.md). Build order
> **14**. Refines [session-monitor](4-session-monitor.plan.md) + the Sessions surface of
> [panel-redesign](12-panel-redesign.plan.md). **Branch:** `feat/dashboard-redesign`.

## Outcome

Same-project active sessions collapse into **one group card** (name · `N sessions` badge · summed
tokens/tools/cost · model chips), expandable to the individual sessions. Empty/no-tool sessions stop
showing as active. The popover gains a compact **top-3 groups** glance. Pure, testable grouping in
CompanionKit; UI composes it in both surfaces. No DB/ingest/id changes.

## Phases

### P1 - `SessionGrouping` in CompanionKit (pure, unit-tested)
- `public struct ProjectSessionGroup: Identifiable, Sendable` - `id` = project path, `projectName`,
  `sessions: [SessionSummary]` (newest-first), aggregates (`toolCount`, `inputTokens`,
  `outputTokens`, `cacheTokens`, `costUSD`, `models: [String]`, `recentTools`, `host`, `lastSeen`),
  `sessionCount`.
- `public enum SessionGrouping { static func groupByProject([SessionSummary]) -> [ProjectSessionGroup] }`
  keyed by `projectPath ?? projectName`; sum aggregates; distinct non-nil models; `recentTools`/`host`
  from newest member; order groups by latest `lastSeen` desc.
- `AppModel.activeSessionGroups: [ProjectSessionGroup]` =
  `SessionGrouping.groupByProject(sessions.filter { $0.active && $0.toolCount > 0 })`.
- *Tests:* aggregation sums; distinct models; path-keyed separation (same leaf name, different path →
  two groups); newest-first ordering; 0-tool/no-model excluded; single-session group intact.

### P2 - Sessions tab uses group cards
- New `ProjectGroupCard` (in Sections): name + `N sessions` badge (hidden when 1) + summed
  tools/tokens/cost + model chips + newest tool chain + host chip. Tap → expand to member
  `SessionCard` + per-session detail (reuse existing views).
- `SessionsList` iterates `model.activeSessionGroups` instead of the flat `active` list.
- *Verify:* vega shows one card "3 sessions" with summed totals; expand lists the 3; the `?` card is
  gone; single-session projects look normal.

### P3 - Popover glance: top-3 groups + recent decisions
- Popover adds a compact **Active** block: top 3 `activeSessionGroups` as one-liners
  (`name · N sessions · $cost`) and a compact **Recent** block: the last ~3
  `recentDecisions` rows (reusing `DecisionRow`). Keeps the popover short but useful again (it had
  too much empty space after the slim-down).
- *Verify:* popover shows ≤3 group rows + ≤3 decision rows, still fixed-height and non-scrolling.

### P4 - Local visual sign-off
- Build + run; confirm grouping reads clearly, badges/aggregates correct, popover density feels right.
- *Verify (manual):* user reviews on the branch.

## Test plan
| Area | Check | Type |
|---|---|---|
| P1 aggregation | group sums tools/tokens/cost across members | unit |
| P1 path key | same leaf name + different path → separate groups | unit |
| P1 ordering | groups newest-active first; members newest-first | unit |
| P1 filter | 0-tool / no-model sessions excluded from groups | unit |
| P2 card | vega → one "3 sessions" card; expand → 3 members; `?` gone | manual |
| P3 popover | top-3 groups + last-3 decisions; popover stays fixed-height | manual |

## Status
**Planned** - implement on `feat/dashboard-redesign` after the panel-redesign cards exist (it reuses
them). Build + run locally for visual review; no merge until UI sign-off.
