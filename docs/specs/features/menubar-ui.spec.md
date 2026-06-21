# Feature Spec - Menu-bar UI

> Part of [Claude Companion](../claude-companion-spec.md). Build order **6** (M0-M3).
> Depends on [foundation](foundation.spec.md); renders data from session-monitor,
> usage-limits, permission-engine, approval-ux, cost-breakdown. Status: **shipped v0.1**.

## Purpose

The visible surface: an always-present `NSStatusItem` and a SwiftUI dropdown panel. The UI
**is** the app - it reads in-process state (sessions, usage, audit, cost) directly via Swift
observation and writes `rules.yaml`/`config.yaml` to disk. No daemon, no IPC.

## Status item (always visible)

- Compact string, e.g. `◆ 23% · 5h 18%` (weekly · 5h), format driven by
  `config.ui.status_format`.
- **Color grading:** green <50 / orange 50-79 / red 80+.
- **Active-session count** as a small dot or number.
- **Auto-accept state** via icon variant: filled `◆` = on, hollow `◇` = off.
- Optional **recent-deny indicator** (a subtle dot) when a deny happened recently - there is
  no pending-approval queue (asks go to Claude Code's native prompt; see approval-ux).

## Dropdown panel (SwiftUI), top to bottom

> **Implemented (v0.2, 2026-06-16):** the panel is the live SwiftUI `PanelView`. Done so far -
> Usage bars show the **reset day/time** ("resets Thu 22:00" weekly, "resets 20:00" 5h); the
> **blocklist** line expands to a searchable domain list + Refresh (B1); **session cards** tap to
> expand a detail row with a per-tool breakdown (B2). TODO: rules editing (B3), actionable
> denials (B4), activity sparkline.

1. **Usage** - 5h session bar + **reset time**; weekly bar + **reset day** (e.g. "resets Thu 22:00"); per-model when available.
   ([usage-limits](usage-limits.spec.md))
2. **Auto-accept** - master toggle (writes `rules.yaml`), kill-switch, link to rules file, and
   a **read-only recent-decisions list** (allow/deny/ask from `audit.ndjson`). No pending queue.
   ([permission-engine](permission-engine.spec.md), [approval-ux](approval-ux.spec.md))
3. **Active sessions** - one card per running session. ([session-monitor](session-monitor.spec.md))
4. **Activity** - multi-series sparkline of token/tool rate over time.
5. **Projects** - collapsible per-project token + cost totals (today / week).
   ([cost-breakdown](cost-breakdown.spec.md))
6. **Footer** - current model (+ signal-strength dots), Anthropic status indicator,
   last-updated ("Updated: 2 min ago"), version.

### Session-card layout (informed by a community reference, not set in stone)

A real-world "Claude Companion v0.6.8" screenshot (someone else's tool - note the **name is
taken**) shows a clean two-card layout we can borrow from. Per card, roughly top→bottom:
- **Title/summary** - the session's current task (derive from the session's latest prompt /
  `ai-title`), with the **cwd path** beneath (`~/Development/<project>`).
- **One-line status** - what it's doing now.
- **Context-fill bar + %** (e.g. `42.2%`), color-graded.
- **Counts** - `msgs` and active sub-agent count (`· 1 agent`).
- **Token totals** - `↓ in  ↑ out  ⊡ cache` (e.g. `↓9.3M ↑2.8M ⊡15.3M`).
- **Live rates** - per-second `↓ B/s ↑ B/s ⊡ KB/s ↺ /s` row.
- **Session cost** (e.g. `$0.0c`) and **memory** (e.g. `443 MB`).
- **Tool chain** - recent `Bash › Bash › Edit › Read …`.
- **Footer ids** - `pid` + short `session id`.

The **Usage strip** in that reference (Session 19% · 2h 36m green / Weekly 97% · 4d 18h red ·
`Max 20x`) maps to our §Usage section. Take the *information density* and grading as guidance;
final layout is ours to decide. v0.1 may ship a leaner card (title, model, msgs, context %,
token totals, tool chain) and add rates/memory/cost later.

## Behavior

- Renders directly from in-process state, updating live as the app's pollers/tailers refresh
  it (usage poll, JSONL tailer, `audit.ndjson` ingest) - plain Swift observation, no IPC.
- Mutations (toggle auto-accept) write `rules.yaml`/`config.yaml` to disk; the hot-reload
  watcher picks them up. The hook reads the new `rules.yaml` on its next invocation.
- Source-unavailable states are local: if the usage poll or Keychain read fails, show a
  staleness/error indicator (there's no daemon to be "down").

## Acceptance criteria

- [ ] Status item renders weekly + 5h with correct color grading from live data.
- [ ] Auto-accept icon variant matches `rules.yaml` state and updates within one tick of a
      change made elsewhere.
- [ ] Active-session cards appear/disappear as sessions start/stop and show live token
      rates + tool chain.
- [ ] Toggling auto-accept from the panel writes `rules.yaml` and takes effect on the hook's
      next decision.
- [ ] Recent-decisions list reflects `audit.ndjson` (read-only; no pending queue).
- [ ] UI shows a staleness indicator when a data source is unavailable and recovers when it returns.

## Open questions

- Panel as `NSPopover` vs a borderless window - popover is simplest; confirm it fits the
  sections cleanly.
- Sparkline: native Swift Charts vs hand-drawn - assume Swift Charts.
