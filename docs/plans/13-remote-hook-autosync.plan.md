# Plan - Remote hook auto-update on sync

> Implements [remote-hook-autosync.spec.md](../specs/features/remote-hook-autosync.spec.md).
> Build order **13**. Extends [remote-ssh](11-remote-ssh.plan.md). **Branch:**
> `feat/dashboard-redesign` (rides along with the UI work; backend-only, no visual review needed).

## Outcome

A registered remote's Linux `companion-hook` **self-heals to the current version on the normal
sync** instead of only at registration. After a Mac app upgrade, every reachable enabled remote
picks up the new hook within one sync cycle (≤60 s) and shows a "reload to activate" nudge - no
Remove/re-Add. Steady state stays cheap: one tiny `cat .hook-version` per host per cycle; the
~55 MB transfer happens only on an actual version change. Best-effort: a failed hook push never
blocks the audit/session pull, and the remote keeps gating with its previous hook.

## Settled decisions (from spec)
- Reuse the **existing version-gate** (already idempotent inside `register`); extract it so both
  `register` and the sync loop share one path.
- Hook push in sync is **best-effort** - pull must not depend on it (visibility > upgrade).
- When sync pushes a new hook, set the **reload reminder** once per detected version change per
  host (no per-cycle nagging) and record `RemoteState.hookVersion`.
- Rules/blocklist re-push stays where it is (`pushRulesToRemotes` on compile); out of scope here.

## Phases

### P1 - Extract `ensureHookCurrent(host:)` in `RemoteManager`
- Move the version-gate block out of `register(host:)` into
  `@discardableResult func ensureHookCurrent(host:) throws -> Bool` (returns whether it pushed):
  `cat .hook-version` → compare to `hookProvider.version` → on mismatch `hookProvider.ensure(arch:)`
  (download-on-demand, SHA-256 verified, cached) → `upload` → `chmod 755` → write marker.
- `register` calls `ensureHookCurrent` (behavior identical to today).
- *Tests:* push when marker differs / absent; no-push when marker matches; checksum mismatch
  rejects (reuses `LinuxHookProvider` path); marker written with the new version. Extend
  `RemoteManagerTests` (MockURLProtocol + a stub `SSHRunner`).

### P2 - Call it from the sync loop (best-effort)
- `RemoteSync.syncOnce(_:)` calls `manager.ensureHookCurrent(host:)` **before** the pull, wrapped
  so a thrown error is recorded as the host's `lastError` but the audit/session mirror still runs.
- The manual **Re-sync** button (`AppModel.resyncRemote`) goes through the same `syncOnce`.
- *Tests:* `syncOnce` with a stale remote marker triggers exactly one push then zero on the next
  call; a push failure still completes the pull (assert mirror written + `lastError` set).
  Extend `RemoteSyncTests`.

### P3 - Reload reminder + state, no nagging
- When `ensureHookCurrent` returns "pushed", `AppModel` sets `reloadReminderHost` for that host and
  updates `RemoteState.hookVersion`; track `lastRemindedHookVersion` in `RemoteState` so the nudge
  fires **once per version change** per host, not every cycle.
- Remotes UI shows `hook v0.5.x` / `updating…` / `reload to activate` from `RemoteState`.
- *Tests:* reminder set once on version change, not re-set on the following no-op cycle;
  `hookVersion` reflects the pushed version.

### P4 - Live verification (Fedora 43 host)
- Simulate an upgrade by writing a stale `.hook-version` on the remote, run a sync, confirm exactly
  one push + marker bump + reminder; run again, confirm no transfer. Confirm a real probe still
  gates correctly afterward. (Hook only DECIDES on probe input - safe, non-destructive.)
- *Verify:* matches P2/P3 behavior against the real host.

## Acceptance criteria
Mirror [remote-hook-autosync.spec.md](../specs/features/remote-hook-autosync.spec.md#acceptance-criteria):
`ensureHookCurrent` pushes iff version differs (checksum-verified, marker updated); one shared path
for register + sync; one push per version bump; pull survives a push failure; reload reminder +
`hookVersion` set on push; steady state transfers nothing.

## Test plan
| Area | Check | Type |
|---|---|---|
| P1 gate | push on marker-differs/absent; no-push on match | unit |
| P1 checksum | SHA-256 mismatch rejects the hook | unit |
| P2 sync push | stale marker → one push, then zero next cycle | unit |
| P2 resilience | hook-push failure still completes audit/session pull, sets `lastError` | unit |
| P3 reminder | reload reminder set once per version change, not per cycle | unit |
| P4 live | Fedora: stale marker → one push + bump + reminder; rerun → no transfer; gate OK | manual |

## Status
**Planned** - not started. Backend-only; implement after (or alongside) the UI phases on
`feat/dashboard-redesign`. Can land independently of the visual sign-off.
