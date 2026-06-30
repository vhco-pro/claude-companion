# Feature Spec - Panel redesign (hybrid popover + tabbed dashboard window)

> Part of [Claude Companion](../claude-companion-spec.md). New (v0.6 candidate). Supersedes the
> single-scroll layout in [menubar-ui](menubar-ui.spec.md) (the status item + data sources are
> unchanged; only the *presentation* changes). Depends on [foundation](foundation.spec.md);
> renders data from [session-monitor](session-monitor.spec.md), [usage-limits](usage-limits.spec.md),
> [permission-engine](permission-engine.spec.md), [approval-ux](approval-ux.spec.md),
> [cost-breakdown](cost-breakdown.spec.md), [remote-ssh](remote-ssh.spec.md). Status: **spec**.

## Purpose

The dropdown panel grew one section at a time (usage, controls, blocklist, sessions,
needs-attention, remotes, cost, footer) until it is a single ~360-wide column that runs far past
a screen height with 12 active sessions + 127 decisions. A `MenuBarExtra(.window)` popover is
**fixed-width and non-resizable**, so there is no good way to make a long panel usable - the
[recent attempt](../../plans/) to wrap the whole thing in a `ScrollView` collapsed the popover to
a sliver (a `ScrollView` has no intrinsic height inside a popover).

Split the surface in two:

1. A **compact popover** for the at-a-glance state (the thing you click the menu bar for).
2. A **resizable, tabbed dashboard window** for everything that needs room (session lists, the
   audit log, remote management, settings).

Both observe the same in-process `@Observable @MainActor AppModel` - there is still **no daemon,
no IPC**; the window is just a second SwiftUI scene over the same live state.

## The compact popover (glance)

`MenuBarExtra(.window)`, ~300 wide, sized to content (a plain `VStack`, **not** wrapped in a
`ScrollView` - that is what collapsed it). Top to bottom:

- **Usage** - weekly + 5-hour bars with reset times, color-graded (unchanged from today).
- **Auto-accept** toggle + kill-switch hint.
- **One-line rollup** - `12 active · 3 need attention · 1 remote` (counts link nowhere; they are a
  summary). A red tint on "need attention" when >0.
- **Hook status** - installed / not-installed line (the install button moves to Settings).
- **`Open Dashboard ↗`** button - opens/raises the dashboard window.
- **Footer** - version · status · Quit.

The popover never needs to scroll: it is a fixed handful of rows regardless of how busy the
machine is. Everything that grows with activity lives in the window.

## The dashboard window (depth)

A real resizable window, **not** a popover. Square-ish default (~760×560), min ~640×440, user
can resize and the size persists. Tabs across the top (`TabView`): **Overview · Sessions ·
Decisions · Remotes · Settings**.

### Opening from an `LSUIElement` (agent) app

The app is `LSUIElement` (no Dock icon), so a window does **not** come forward on its own:

- Declare a `Window("Claude Companion", id: "dashboard")` scene (single instance, not a
  `WindowGroup` - we never want duplicates).
- The popover's button calls `openWindow(id: "dashboard")` **and**
  `NSApplication.shared.activate(ignoringOtherApps: true)` so it raises above the editor.
- Re-clicking the button when it is already open just re-activates/raises it (no second window).
- Closing the window is fine; the app keeps running in the menu bar (it always has).
- `.windowResizability(.contentMinSize)`, `.defaultSize(width: 760, height: 560)`, and persist
  the frame via `@SceneStorage` / autosave so it reopens where the user left it.

### Tabs

1. **Overview** - the dashboard's home. Usage bars (full size), auto-accept master toggle +
   kill-switch, hook status, and a small headline-numbers strip (active sessions, today's cost,
   decisions needing attention, remotes up/down). A glanceable summary that mirrors the popover
   but with room to breathe.
2. **Sessions** - the active-session cards (today's §Active sessions), each expandable to the
   per-tool breakdown + cwd + repo link (today's `sessionDetail`). Below: **Cost by project**
   (today's `costSection`), no longer truncated to 5. Host chip on remote sessions
   (already implemented). This is where session density lives, so it scrolls cleanly inside the
   resizable window (a `ScrollView` works here - the window gives it a real height).
3. **Decisions** - "Needs attention" (ask/deny/compromised, newest first) with the per-row
   expand → full command (in its own bounded scroll) + matched rule + allow/block actions
   (today's `decisionsSection` + `decisionActions`). Adds a **search/filter** box and a
   **decision-type filter** (all / deny / ask), and shows more than the current `prefix(8)` since
   there is room. The "last 7d · N total" summary stays.
4. **Remotes** - the remote-SSH hosts (today's `remotesSection`): per-host status dot, last-sync,
   re-sync, remove, and the add-from-`~/.ssh/config` / `user@host` controls. The reload reminder
   banner lives here (and, when fresh, also peeks in the popover rollup). Pairs with
   [remote-hook-autosync](remote-hook-autosync.spec.md).
5. **Settings** - the things you set once: hook **install/remove**, blocklist (searchable domain
   list + refresh + count), open-config-folder, open-rules-file, and any `config.yaml`-backed
   toggles. This is the new home for the blocklist (it was eating vertical space in the scroll).

### Shared state, no duplication

- One `AppModel` instance is created at app launch and injected into **both** scenes
  (`.environment(model)` on the `MenuBarExtra` content and the `Window` content). SwiftUI
  observation drives both; a toggle in either updates the other within a tick.
- The existing pollers/tailers (usage, JSONL tailer, audit ingest, remote sync timer) are
  untouched - they already feed `AppModel`, so the window is live for free.
- Section views are refactored out of `PanelView` into reusable views
  (`UsageSection`, `SessionsList`, `DecisionsList`, `RemotesPanel`, `SettingsPanel`) so the
  popover and the tabs compose the same building blocks - no copy-paste, no second source of
  truth.

## Behavior

- Renders directly from live in-process state (plain Swift observation, no IPC) - same as today.
- Mutations (toggle auto-accept, install hook, add/allow/block rules, add/remove remote) write
  the same files as today; the hot-reload watcher + hook pick them up. No behavior change to the
  gate, only to where the controls live.
- The popover stays instant and click-away-dismissable; the window persists until closed and is
  the place for anything that scrolls.

## Acceptance criteria

- [ ] The popover is a fixed, content-sized set of rows that never needs to scroll, regardless of
      session/decision count, and renders at full content (no collapsed sliver).
- [ ] `Open Dashboard` opens a **resizable** window that raises above other apps (works from the
      `LSUIElement` app) and re-uses the single instance on subsequent clicks.
- [ ] The window has the five tabs (Overview/Sessions/Decisions/Remotes/Settings); each renders
      its data live and updates within one tick of a change made elsewhere (popover or disk).
- [ ] Toggling auto-accept in the popover updates the window's Overview tab (and vice-versa)
      without a manual refresh.
- [ ] Decisions tab can filter by type and search command text; Sessions tab shows all projects
      (not capped at 5); both scroll cleanly within the resizable window.
- [ ] Window size/position persists across relaunches; closing it leaves the app running in the
      menu bar.
- [ ] No regression to the gate, data sources, or the existing audit/allow/block actions - this
      is presentation-only.

## Open questions / risks

- **Tab style:** SwiftUI `TabView` (top tabs) vs a leading sidebar (`NavigationSplitView`). Assume
  top `TabView` per the chosen design; sidebar is a fallback if five tabs feel cramped.
- **Window vs popover for the reload reminder:** show it in both (window Remotes tab always; popover
  rollup only while fresh) - confirm during build.
- **`@SceneStorage` frame persistence** for a single `Window` in an `LSUIElement` app - verify it
  restores correctly (NSWindow autosave is the fallback).
- Should the status-item **left-click** open the popover (today) and a **modifier-click** or a
  preference open the dashboard directly? Default: left-click = popover; dashboard via the button.
