# Plan - Menu-bar UI

> Implements [menubar-ui.spec.md](../specs/features/menubar-ui.spec.md). Build order **6**.
> Depends on [foundation](1-foundation.plan.md); renders sessions/usage/permission/cost.
> **Revised 2026-06-15 - the UI *is* the app; in-process state, no daemon/IPC.**

## Phases

### P0 - Status item
- `NSStatusItem`/`MenuBarExtra` rendering `config.ui.status_format` (e.g. `◆ 23% · 5h 18%`).
- Color grading green <50 / orange 50-79 / red 80+; active-session dot/count; auto-accept
  icon variant (◆/◇); optional subtle recent-deny dot (no pending-approval badge - asks go to
  Claude Code's native prompt).
- *Test:* renders weekly + 5h with correct grading from live data; icon matches auto_accept.

### P1 - Dropdown scaffold
- `NSPopover` hosting a SwiftUI panel; section container layout.
- Renders from in-process observable state; shows per-source staleness/error indicators when a
  poll/read fails (no daemon to reconnect to).
- *Test:* panel opens, renders current state, shows staleness when a source is unavailable.

### P2 - Sections wired to data (in-process)
1. Usage (bars + countdowns, per-model when present).
2. Auto-accept (master toggle, kill-switch, link to rules, read-only recent-decisions list).
3. Active sessions (cards: project, model, msgs, context %, token rates, tool chain).
4. Activity (Swift Charts sparkline of tool/token rate).
5. Projects (collapsible per-project token + cost, today/week).
6. Footer (model, Anthropic status, last-updated, version).
- *Test:* each section reflects live in-app state; cards appear/disappear with sessions; the
  recent-decisions list reflects `audit.ndjson` ingestion.

### P3 - Mutations (write-to-disk, not IPC)
- Toggle auto-accept / edit rules → the app writes `rules.yaml`/`config.yaml`; the hot-reload
  watcher picks it up and the hook reads the new file on its next invocation.
- *Test:* toggling from the panel writes `rules.yaml` and takes effect on the hook's next decision.

### P4 - Resilience
- *Test:* UI renders correctly when a data source (usage/JSONL/Keychain) is unavailable and
  recovers when it returns; recent-decisions list matches `audit.ndjson`.

## Acceptance criteria (from spec)
- [ ] Status item grading correct from live data.
- [ ] Auto-accept icon updates within one tick of an external change.
- [ ] Session cards live (rates + tool chain); appear/disappear correctly.
- [ ] Panel toggle writes `rules.yaml` and affects the hook's next decision.
- [ ] Recent-decisions list reflects `audit.ndjson` (read-only; no pending queue).
- [ ] Renders with a data source unavailable; recovers when it returns.

## Risks
- NSPopover vs borderless window - validate the section layout fits in P1.
