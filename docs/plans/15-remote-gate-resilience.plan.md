# Plan - Remote gate resilience (settings self-heal + last_seen accuracy)

> Bug-fix follow-up to [remote-hook-autosync](../specs/features/remote-hook-autosync.spec.md) and
> [session-grouping](../specs/features/session-grouping.spec.md) / session-monitor.
> **Branch:** `fix/remote-gate-resilience`. Two independent defects found live on the Fedora host.

## Defects (root-caused)

1. **Remote gate silently un-wires → "press yes a lot".** The sync self-heals the hook *binary*
   (`ensureHookCurrent`) but never re-asserts the *settings.json wiring*. When Claude Code rewrites
   the remote `~/.claude/settings.json` (e.g. on a `/config` change) it drops our `hooks` block, so
   the gate stops being invoked and every tool call falls back to Claude Code's native prompt. Found:
   fedora `settings.json` had `effortLevel/enabledPlugins/permissions` but **no `hooks`**.

2. **Dead sessions show as active.** [JSONLTailer.swift:80](../../CompanionKit/Sources/CompanionKit/JSONLTailer.swift)
   stamps `event.timestamp.flatMap(parse) ?? Date()`. A trailing timestamp-less entry (e.g. a
   `pr-link` line) gets stamped *now* the first time a historical JSONL is mirrored, so `last_seen`
   jumps to sync-time and the session looks active forever. Found: fedora session `110bd93f` real
   last activity 18:51 but `last_seen` 21:29 → phantom 2nd "stackweaver" card.

## Phases

### P1 - last_seen accuracy (fix 2)
- JSONLTailer carries the **last valid timestamp forward** within a batch: a line with no parseable
  timestamp uses the previous real timestamp, not `Date()`. (Only a batch with *zero* real
  timestamps falls back to `Date()`.) Fixes both local and remote.
- *Test:* a batch ending in a timestamp-less line → the session's `last_seen` is the last real
  timestamp, not now (so it ages out of "active" correctly).

### P2 - settings self-heal (fix 1)
- `RemoteManager.ensureSettingsWired(host:paths:) -> Bool`: cheap `grep` for our `companion-hook`
  marker in the remote `settings.json`; if absent, run the idempotent pull-merge-push
  `installSettings` (preserves the user's other keys) and return true.
- `RemoteSync.syncOnce` calls it after `ensureHookCurrent`, best-effort (a failure records the error
  but never blocks the pull).
- When it re-wires, flag `RemoteState.needsReload` so `AppModel.checkReloadReminders` nudges the user
  to reload that VSCode window (the extension host snapshots hooks at start).
- *Tests:* re-wires only when the marker is missing (no-op when present); a re-wire sets needsReload.

### P3 - live verify on Fedora + ship
- Build, run; deliberately strip the remote `hooks`, run a sync, confirm it re-wires + flags reload;
  confirm the phantom session drops once last_seen reflects real activity.
- *Verify:* fedora gate stays wired across a settings rewrite; only the genuinely-active stackweaver
  session shows.

## Test plan
| Area | Check | Type |
|---|---|---|
| P1 | timestamp-less trailing line → last_seen = last real ts, not now | unit |
| P2 | ensureSettingsWired: no-op when wired, re-wires when marker absent | unit |
| P2 | re-wire flags needsReload → reminder fires once | unit |
| P3 | strip remote hooks → next sync re-wires; phantom session gone | manual (Fedora) |

## Status
**Planned** - implement on `fix/remote-gate-resilience`; immediate fedora re-wire already applied by
hand for instant relief. Ship via the normal release cycle after local + Fedora verification.
