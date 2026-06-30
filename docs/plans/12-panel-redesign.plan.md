# Plan - Panel redesign (hybrid popover + tabbed dashboard window)

> Implements [panel-redesign.spec.md](../specs/features/panel-redesign.spec.md). Build order **12**.
> Supersedes the single-scroll layout of [menubar-ui](6-menubar-ui.plan.md). Depends on
> [foundation](1-foundation.plan.md); renders the same in-process `AppModel` state as today.
> **Branch:** `feat/dashboard-redesign` (UI must be reviewed running locally before any merge).

## Outcome

The menu-bar surface is split in two over **one shared `@Observable @MainActor AppModel`** (no
daemon, no IPC): a **compact, content-sized popover** that never scrolls, and a **resizable,
tabbed dashboard window** (Overview / Sessions / Decisions / Remotes / Settings) for everything
that grows with activity. The gate, data sources, and allow/block actions are unchanged - this is
presentation-only. UX stays close to today's; the win is that 12 sessions + 127 decisions no
longer make a mile-long popover.

## Settled decisions (from spec + user)
- **Hybrid** presentation: compact popover + a real `Window` (not a popover) for depth.
- **Five top tabs:** Overview / Sessions / Decisions / Remotes / Settings (`TabView`).
- **One `AppModel`** injected into both scenes via `.environment`; section views are extracted so
  popover and tabs share the exact same building blocks (no second source of truth).
- **Reviewed locally before merge** - each phase must build + run; the user signs off on visuals.
- UX parity is a hard constraint: existing interactions (tap-to-expand session/decision,
  allow/block, install hook, add/remove remote, kill-switch) keep working identically.

## Phases

### P1 - Extract reusable section views (refactor, zero behavior change)
- Pull the body of `PanelView` into standalone views in `ClaudeCompanion/App/Sections/`:
  `UsageSection`, `ControlsSection` (auto-accept/kill-switch/hook), `BlocklistSection`,
  `SessionsList` (+ `SessionCard`, `sessionDetail`), `DecisionsList` (+ `DecisionRow`,
  `decisionActions`), `RemotesPanel` (+ rows/add), `CostSection`, `FooterBar`. Each takes
  `@Bindable var model: AppModel` (or reads it from the environment).
- `PanelView` recomposes from these - rendering is **byte-for-byte the same** as v0.5.7.
- *Verify:* build + run; the popover looks and behaves exactly as today (the safety net before any
  visual change). No new tests (pure view extraction); existing suite stays green.

### P2 - Dashboard `Window` scene + open-from-popover (the `LSUIElement` raise)
- Add a single `Window("Claude Companion", id: "dashboard")` scene in the App; inject the shared
  `AppModel`. `.defaultSize(760×560)`, `.windowResizability(.contentMinSize)`, min ~640×440.
- Popover gains an `Open Dashboard ↗` button → `openWindow(id:"dashboard")` +
  `NSApplication.shared.activate(ignoringOtherApps: true)` so it raises above the editor. Re-click
  re-raises the same instance (no duplicates). Closing it leaves the app running in the menu bar.
- For P2 the window can host the existing full `PanelView` content (temporary) so we can prove the
  window mechanics before tabs land.
- *Verify:* button opens a resizable window that comes to the front from the no-Dock app; second
  click raises the same window; resize works; close → app still alive.

### P3 - Tabs in the window (compose the P1 views)
- Replace the window's temporary content with a `TabView`: **Overview** (UsageSection full +
  ControlsSection + a headline-numbers strip), **Sessions** (`SessionsList` + `CostSection`,
  uncapped, in a `ScrollView` - the window gives it real height), **Decisions** (`DecisionsList`,
  uncapped), **Remotes** (`RemotesPanel` + reload banner), **Settings** (hook install/remove +
  `BlocklistSection` + open-config/rules).
- *Verify:* all five tabs render live data; a change in one place (e.g. auto-accept) reflects in
  the others within a tick; tabs scroll cleanly.

### P4 - Slim the popover to the glance
- Reduce `PanelView` to: UsageSection (compact) · auto-accept toggle + kill-switch hint · a
  one-line rollup `N active · M need attention · K remotes` (red tint when M>0) · hook status line
  · `Open Dashboard ↗` · footer (version · status · Quit). Width ~300, plain `VStack`, no scroll.
- The blocklist, session list, decision list, remote management, cost move OUT of the popover (now
  in the window). Install-hook moves to Settings; the kill-switch hotkey is unchanged.
- *Verify:* popover is a short fixed set of rows at any session/decision count; never a sliver,
  never scrolls.

### P5 - Depth features the window unlocks
- **Decisions tab:** a search box (matches command text) + a type filter (all / deny / ask);
  show well beyond the old `prefix(8)`.
- **Sessions tab:** show all projects in Cost-by-project (drop the `prefix(5)`); keep cards capped
  to active but scrollable.
- **Window frame persistence:** `@SceneStorage`/NSWindow autosave so size+position restore on
  relaunch.
- *Verify:* filter/search work; lists no longer artificially truncated; reopen restores frame.

### P6 - Polish + local visual sign-off
- Spacing/typography pass for the window (it has room now); ensure dark-mode + accent-tint look
  right; make sure remote host chips, repo links, and decision colors carry over.
- Build a Release-config local app, run it, walk every tab + the popover; capture before/after.
- *Verify (E2E, manual):* user reviews the running app on the branch and confirms visuals + UX
  parity before any merge is considered.

## Acceptance criteria
Mirror [panel-redesign.spec.md](../specs/features/panel-redesign.spec.md#acceptance-criteria):
popover never scrolls/collapses; dashboard opens + raises from the `LSUIElement` app and reuses one
instance; five live tabs; cross-scene updates within a tick; decisions filter/search + uncapped
lists; frame persists; no gate/data/action regressions.

## Test plan
| Area | Check | Type |
|---|---|---|
| P1 view extraction | popover renders identically to v0.5.7 (visual) | manual |
| P1 | existing CompanionKit suite stays green | unit |
| P2 window raise | `Open Dashboard` brings a resizable window to front from no-Dock app | manual |
| P2 single instance | re-click raises same window, no duplicate | manual |
| P3 tabs live | auto-accept toggle in popover updates Overview tab within a tick | manual |
| P3 | each tab renders its data source live | manual |
| P5 filter | Decisions search + type filter narrow the list correctly | manual |
| P5 persistence | window size/position restored after relaunch | manual |
| Regression | install/remove hook, allow/block decision, add/remove remote all still work | manual |

## Status
**Implemented (P1-P6) on `feat/dashboard-redesign`** — extracted section views; hybrid compact
popover + single resizable tabbed `Window` (Overview/Sessions/Decisions/Remotes/Settings) raised
from the `LSUIElement` app; popover top-3 sessions/decisions are interactive (expand + allow/block);
Decisions search + type filter; cost uncapped; Overview section headers (P6). Built + run locally
across several review rounds. **Awaiting final UI sign-off before merge** (per the branch rule).
