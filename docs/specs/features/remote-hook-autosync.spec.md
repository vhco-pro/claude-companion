# Feature Spec - Remote hook auto-update on sync

> Part of [Claude Companion](../claude-companion-spec.md). New (v0.6 candidate). Extends
> [remote-ssh](remote-ssh.spec.md); depends on [foundation](foundation.spec.md) and the
> download-on-demand `LinuxHookProvider`. Status: **spec**.

## Purpose

A registered remote host gets the arch-matched Linux `companion-hook` pushed **once, at
registration** (`RemoteManager.register` → version-gated push, writing a `.hook-version` marker on
the remote). The periodic sync only *pulls* (audit + session JSONL); it never re-checks the hook.

So when the Mac app upgrades to a release with a **new hook** (e.g. the heredoc-sanitizer fix), the
remote keeps running the **old** hook until the user manually **Remove + re-Add** the host. That is
a silent staleness: the gate on the remote can lag the local gate by one or more releases, and a
fixed false-deny (or, worse, a fixed gap) never reaches the remote on its own.

Make the remote hook **self-heal on the normal sync**: each sync cycle does a cheap version check
and re-pushes the hook only when the local version moved.

## Design - fold a version-gate into the sync loop

The hook push is **already version-gated and idempotent** inside `RemoteManager.register`:

```
read remote ~/.config/claude-companion/.hook-version
if it != hookProvider.version:
    download arch-matched hook (checksum-verified, cached) → scp → chmod 755
    write .hook-version = hookProvider.version
```

Extract that block into a reusable `RemoteManager.ensureHookCurrent(host:)` and call it from the
sync path, not just registration.

### 1. Extract `ensureHookCurrent(host:)`
- Pure version-gate: `cat .hook-version` over SSH (a few bytes), compare to `hookProvider.version`.
- On mismatch: `hookProvider.ensure(arch:)` (download-on-demand, SHA-256 verified, version-keyed
  cache - existing code), `upload` to the space-free remote hook path, `chmod 755`, then write the
  new marker. Returns whether it pushed (so the caller can surface the reload reminder).
- On match: no-op, no transfer. The cost of the check is one tiny SSH command per host per cycle.
- `register` calls `ensureHookCurrent` (same behavior as today) so there is one code path.

### 2. Call it from the periodic sync
- `RemoteSync.syncOnce(_:)` (and the manual **Re-sync** button) call `ensureHookCurrent(host:)`
  **before** the pull, best-effort: a push failure records a per-host `lastError` but does **not**
  abort the pull (visibility must not depend on a successful hook upgrade), and the remote keeps
  gating with its previous hook (never silently degrades - same guarantee as `pushRules`).
- The 55 MB transfer only happens on an actual version change, so steady-state sync stays cheap
  (one `cat` per host).

### 3. Surface the reload reminder when the hook changes out-of-band
- The remote VSCode extension host **snapshots hooks at start**, so a hot-swapped hook only takes
  effect after the user reloads that window (the same caveat registration already surfaces).
- When `ensureHookCurrent` actually pushes a new hook during a background sync, set
  `AppModel.reloadReminderHost` for that host so the UI nudges the user to reload - otherwise the
  upgrade lands on disk but the running session keeps the old hook silently.
- Record the pushed version in the host's `RemoteState.hookVersion` so the Remotes tab can show
  `hook v0.5.7` / `updating…` / `reload to activate`.

### 4. Rules stay as-is
- `rules.compiled.json` + `blocklist.db` are small and already re-pushed on compile via
  `pushRulesToRemotes` (on rule edits / auto-accept toggle). No change needed; only the **binary**
  was missing an update path. (Optional: also re-push rules in `syncOnce` for hosts that were
  offline during the last compile - list it as an open question, not in scope.)

## Behavior

- After a Mac app upgrade, within one sync cycle (≤60 s) every reachable enabled remote pulls the
  new hook automatically and shows a "reload to activate" nudge - no Remove/re-Add needed.
- An unreachable remote is retried on the next cycle (and on wake/network-restore, like the pull).
- A remote already on the current version transfers nothing (just the version check).

## Acceptance criteria

- [ ] `ensureHookCurrent(host:)` re-pushes the hook **iff** the remote `.hook-version` differs from
      `hookProvider.version`, verifies the SHA-256 before install, and updates the marker.
- [ ] `register` and the sync path both call `ensureHookCurrent` (single code path; registration
      behavior unchanged).
- [ ] A simulated version bump (stale `.hook-version` on the remote) triggers exactly one push on
      the next `syncOnce`, and zero pushes on the cycle after that.
- [ ] A hook-push failure during sync records `lastError` but the audit/session **pull still
      succeeds**, and the remote keeps its previous hook.
- [ ] When sync pushes a new hook, `reloadReminderHost` is set for that host and `RemoteState`
      reflects the new `hookVersion`.
- [ ] Steady-state sync (no version change) performs no large transfer - only the version check.
- [ ] Covered by tests: `ensureHookCurrent` gating (push / no-push), sync-still-pulls-on-push-fail,
      and the reload-reminder side effect (extend `RemoteManagerTests` / `RemoteSyncTests`).

## Open questions / risks

- **Re-push rules in sync for hosts that missed a compile?** Out of scope here; revisit if stale
  rules on a previously-offline remote become a real problem.
- **Reload-reminder noise:** if the user ignores the nudge, do not re-nag every cycle - set it once
  per detected version change per host (track last-reminded version in `RemoteState`).
- **Concurrent sync + register** (user clicks Add while a timer sync runs): both funnel through the
  idempotent, version-gated `ensureHookCurrent`, so the worst case is a redundant no-op check.
