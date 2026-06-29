# Plan - Remote-SSH support

> Implements [remote-ssh.spec.md](../specs/features/remote-ssh.spec.md). Build order **11**.
> Depends on [permission-engine](2-permission-engine.plan.md), [session-monitor](4-session-monitor.plan.md),
> [menubar-ui](6-menubar-ui.plan.md), [repo-quicklinks](../specs/features/repo-quicklinks.spec.md).
> Tracking issue: [#5](https://github.com/vhco-pro/claude-companion/issues/5).

## Outcome

When the user develops over VSCode Remote-SSH, the auto-approve/deny **gate runs on the remote
host** (a pushed Linux `companion-hook` + current compiled rules) and the Mac menu bar shows the
**remote sessions host-tagged** alongside local ones, with live tokens/tools and the decision
audit pulled back over SSH. No daemon on the remote; the Mac app orchestrates over `ssh`/`scp` on
a timer + on demand. Local behaviour is unchanged (everything defaults to host `local`).

## Settled decisions (from spec open questions + user)
- **Linux hook delivery: download-on-demand.** CI publishes both stripped Linux hooks
  (`companion-hook-linux-x86_64`, `-aarch64`) as **release assets** + a `.sha256`. The app fetches
  the arch-matched one for **its own version**, verifies the checksum, caches it under Application
  Support, and re-uses it. Keeps the cask small; only remote users pay the ~55 MB.
- **Remote registrations live in `config.yaml`** under `remotes:` (alias + opts). A per-host
  **sidecar** (`remotes/<alias>.state.json`) holds volatile offset/last-sync/status (not user-edited).
- **Sync cadence:** event-driven (window focus + post-decision) **plus** a slow timer. Rules push is
  debounced; an `auto_accept` flip is a high-priority immediate push.
- **Transport:** shell out to system `ssh`/`scp` by **absolute path**, `-F <user ssh config>`,
  `-o BatchMode=yes`, explicit timeout. Never prompt/store passwords; only user-registered hosts.
- **E2E target:** the Fedora 43 test host the spikes used.

## Phases

### P1 - `host` data dimension (CompanionKit, DB migration v2, fully unit-testable)
- Migration **v2**: add `host TEXT NOT NULL DEFAULT 'local'` to `sessions`, `tool_events`,
  `token_usage`, `audit`. Index `sessions(host)`.
- `SessionRecord`/`ToolEventRecord`/`TokenUsageRecord`/`AuditRecord` gain `host` (default `"local"`).
- `SessionIngestor.write` + `AuditIngestor.ingestNew` take an optional `host` (default `"local"`) and
  stamp every row. `SessionSummary` gains `host`; `summaries()` returns it.
- Session id collision across hosts: namespace remote session ids as `<alias>:<sessionId>` at
  ingest so two hosts' sessions never merge (local stays bare).
- *Tests:* v1→v2 migration preserves rows + backfills `'local'`; local ingest still tags `local`;
  a remote-tagged batch is queryable by host; summaries carry host; id namespacing keeps hosts apart.
- **✅ Done 2026-06-28** — migration v2 + `host` on all four records/ingestors; remote ids
  namespaced `<alias>:<id>`; `SessionSummary.host`. 5 new tests, full suite 78 green.

### P2 - Linux `companion-hook` in CI (release assets + checksums)
- Add a `linux-hook` job to the release flow (or extend `vhco-pro/swift-release-action`): on macOS
  or linux runner, install the **pinned** swift.org toolchain via swiftly (`6.2.3`) + the matching
  static-linux SDK, `swift build --product companion-hook --swift-sdk {x86_64,aarch64}-swift-linux-musl
  -c release`, `strip`, upload `companion-hook-linux-<arch>` + `.sha256` to the GitHub Release.
- Pin toolchain+SDK as one unit; verify SDK download by **content-length** (CDN false-200 gotcha).
- *Verify:* release produces both assets + checksums; `file` shows static ELF for each.
- **✅ Done 2026-06-28** — recipe **proven locally** (both arches: x86_64 → 57 MB, aarch64 → 55 MB,
  stripped static ELF). Shared `swift-release-action` now exposes `outputs.tag`/`semver` (PR #2,
  merged, `v1` re-pointed). `linux-hook` job added to claude-companion `release.yml`: clean ubuntu
  runner, swiftly-pinned 6.2.3 + local-file static-SDK install (size-guarded), build/strip/sha256
  both arches, `gh release upload` to the published tag. CI proof lands on the next real release.

### P3 - RemoteManager + SSH primitives (CompanionKit)
- `SSHConfigParser`: read `~/.ssh/config`, return `Host` aliases (skip wildcards) - the Add-host list.
- `SSHRunner`: absolute-path `ssh`/`scp`, `-F`, `-o BatchMode=yes -o ConnectTimeout=…`, captured
  stdout/stderr/exit, structured `RemoteError` (unreachable / needs-key / nonzero) - never hangs.
- `LinuxHookProvider`: resolve+download the arch asset for the app version, checksum-verify, cache.
- `RemoteManager.register(alias)`: `uname -m` → fetch matching hook → `scp` hook (version-gated) +
  `rules.compiled.json` + `blocklist.db` to `~/.config/claude-companion` (space-free) `chmod +x`;
  backup remote `settings.json` → pull-merge-push via `SettingsInstaller(settingsPath: temp,
  hookCommand: <remote path>)` → scp back. Surface the **reload-window** reminder.
- `RemoteManager.deregister(alias)`: restore the remote settings backup (remove our hook entries).
- *Tests:* ssh-config parse (aliases, wildcards skipped, Include tolerated); RemoteError mapping
  from exit codes/stderr; settings merge against a captured real remote file preserves unknown keys
  (reuses existing SettingsInstaller tests, remote-path variant); checksum mismatch rejects the hook.
- **✅ Done 2026-06-28** — `SSHConfigParser`, `SSHRunner` (+ pure `RemoteError.classify`),
  `LinuxHookProvider` (download + SHA-256 verify + version-keyed cache), `RemoteManager`
  (`register`/`deregister`/`pushRules`, version-gated hook push, pull-merge-push settings via the
  existing `SettingsInstaller`) + `RemotePaths`/`Paths` remote helpers. 12 new tests incl. a mocked-
  URLSession download/verify (good + tampered) and remote settings-merge preserving unknown keys.
  Full suite **90 green**. Live SSH orchestration is integration-tested against the Fedora host in P6.

### P4 - Rules push + incremental audit/session pull (RemoteManager, AppModel)
- On recompile (`compileRules`) / kill-switch flip / blocklist refresh → **debounced push** of
  `rules.compiled.json` (+ `blocklist.db`) to every registered remote; `auto_accept` flip bypasses
  the debounce. Failed push leaves last-good remote file intact (fail-safe = remote hook `ask`s).
- Pull loop (timer + focus): per host, `ssh host "tail -c +<offset+1> audit.ndjson"` → ingest
  host-tagged via `AuditIngestor`; same for the active session JSONL → `SessionIngestor`. Persist
  the new offset to the host sidecar. Capture remote `git -C <cwd> config --get remote.origin.url`
  during the pull → remote sessions get repo quicklinks.
- *Tests:* offset advance is monotonic + no dup ingest across two pulls; a failed pull keeps the
  last offset; host tag propagates end-to-end into summaries; repo URL captured for a remote cwd.
- **✅ Done 2026-06-28** — remotes are app-owned (`remotes.yaml` via `RemotesStore`, NOT in the
  user's config.yaml) + a per-host `RemoteState` status sidecar. `RemoteSync` mirrors remote
  audit + recent session JSONL incrementally (byte-exact raw-Data append; mirror-size is the
  offset) and ingests host-tagged via the existing `AuditIngestor`/`JSONLTailer` (now host-aware);
  `SSHRunner.runData` added for byte-exact pulls. `AppModel` wired: load remotes on start, 60 s
  pull timer + wake, `addRemote`/`removeRemote`/`resyncRemote` (off-main), push rules to all
  remotes on real recompile + immediately on kill-switch flip, reload-window reminder after
  register. 4 new tests (store round-trips, sidecar, byte-exact multibyte-split append). Full
  suite **94 green**. Live push/pull verified in P6.

### P5 - UI (ClaudeCompanion app)
- **Remotes** settings section: list registered hosts with per-host status (hook installed? reachable?
  last sync), Add (picker from `~/.ssh/config` or `user@host`) / Remove / Re-sync, reload reminder.
- Session cards: small **host chip** (`local` hidden or subtle; remotes show the alias). "Active
  sessions" spans local + remotes.
- *Verify:* human click-through (add a host, see chip, remove restores).
- **✅ Done 2026-06-29** — `remotesSection` in PanelView: always-visible reload-window banner after
  register, a "Remotes (N · M unreachable)" disclosure listing each host with a status dot + text
  (working/synced-Nago/error/unreachable), Re-sync + Remove, an "Add from ~/.ssh/config…" menu and
  a manual `user@host` field. Session cards show a host chip for remote sessions (local unadorned).
  Full app **builds clean** (xcodebuild). Visual click-through pairs with the P6 live run.

### P6 - config.yaml `remotes:` + persistence + E2E
- `AppConfig.remotes: [Remote]` (alias + opts), lenient decode (absent = `[]`, local-only - no
  behaviour change). Sidecar `remotes/<alias>.state.json` for offsets/status.
- **E2E on the Fedora host:** register it → reload VSCode window → non-matching cmd auto-`allow`s,
  `rm -rf /` denies on the remote; toggle kill-switch on Mac → takes effect on remote's next call;
  remote session appears host-tagged with live tokens + audit + a working repo quicklink; remove
  the host restores its settings backup. Fold in **Spike 2** (logging Stop/SessionStart hook on the
  remote + a 2-min user click procedure) to confirm lifecycle events fire in the Remote-SSH host;
  keep the activity-timeout heuristic as the fallback regardless.
- **✅ Done 2026-06-29 — live E2E PASSED against the Fedora host** (`fedora-43…ts.net`, x86_64).
  Automated as an env-gated `RemoteE2ETests` (skips unless `RUN_REMOTE_E2E=1`; never runs in CI),
  driving the real code: **register** (seeded Linux hook → scp + rules push + settings merge-tag),
  **gate on the remote** (`ls`→allow, `rm -rf /`→deny, `git push`→allow, `git push --force`→ask),
  **pull** (remote deny ingested host-tagged into the DB), **kill-switch** (`auto_accept=false`
  pushed → benign cmd→ask). **deregister** then restored the remote `settings.json` (our hooks
  removed, user keys + backup intact - verified). Remote repo-quicklink resolution added (origin
  read over SSH → pure `RepoURL.web`). Spike 2's interactive VSCode lifecycle check is the one bit
  not automatable headlessly; the activity-timeout fallback covers it meanwhile.

## End-to-end gate (before offering to ship)
Drive the real flow against the Fedora host: a freshly built app downloads the Linux hook from the
release, registers the host, and after a window reload the **remote** hook (not the Mac one) gates a
remote command correctly, while the Mac menu bar shows that remote session host-tagged with its
audit pulled back. No manual file editing on the remote.

## Acceptance criteria (from spec)
- [x] Registering a remote installs a working Linux `companion-hook` + current rules into the
      remote's `~/.config/claude-companion` and merge-tags the remote `settings.json`. *(E2E)*
- [x] A non-matching remote command auto-`allow`s; `rm -rf /` on the remote `deny`s. *(E2E - gate
      invoked directly on the remote hook; the "after a window reload" path is Spike 2.)*
- [x] Kill-switch / rule edits on the Mac propagate to the remote and take effect next tool call. *(E2E)*
- [x] Remote rules unreadable / push failed → remote hook returns `ask`; last-good rules preserved.
      *(Same hook binary + fail-safe as local, unit-tested; a failed push leaves the last-good file.)*
- [x] Menu bar shows remote sessions (host-tagged) with live tokens/tools + the remote audit.
      *(Pull verified E2E: remote audit ingested host-tagged. UI renders it + builds; visual
      click-through pairs with Spike 2.)*
- [x] A remote git-repo session shows a working repo quicklink. *(Origin resolved over SSH → pure
      `RepoURL.web`, wired into the render cache; remote origins confirmed resolvable, not yet
      asserted in the automated E2E.)*
- [x] Removing a remote cleanly uninstalls the remote hook entry (restores its settings backup).
      *(E2E: deregister removed our hooks; user keys + `settings.json.companion-bak` intact.)*
- [x] No password ever prompted/stored; only user-registered `~/.ssh/config` hosts are touched.
      *(`BatchMode=yes` by construction; hosts only from `SSHConfigParser`/explicit entry.)*

## Open questions (carry from spec; resolve as we build)
- Sync cadence numbers (pull interval / push debounce) that feel live without hammering SSH - tune in P4.
- Multi-window / same remote opened twice → dedupe via namespaced session id + per-host offset.
- Dev Containers / Codespaces explicitly out of scope (different transport) - note as future.
- aarch64 runtime is untested (Spike 1 built it, x86_64-only test box) - confirm if an arm64 remote appears.

## Status
**Implemented + live-verified 2026-06-29.** P1-P6 complete. 94 unit tests green; the env-gated
`RemoteE2ETests` passes against the real Fedora host (register → remote gate → host-tagged pull →
kill-switch → clean deregister). The full app builds (xcodebuild). Linux-hook CI fires on the next
release. The only un-automatable bit is Spike 2's interactive VSCode lifecycle check (activity-
timeout fallback covers it). Nothing committed yet.
