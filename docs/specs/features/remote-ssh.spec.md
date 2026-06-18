# Feature Spec - Remote-SSH support (gate + visibility on remote dev hosts)

> Part of [Claude Companion](../claude-companion-spec.md). New (v0.3 candidate). Depends on
> [permission-engine](permission-engine.spec.md), [session-monitor](session-monitor.spec.md),
> [foundation](foundation.spec.md). Status: **spec - top risks are spikes (see §Spikes).**

## Purpose

Make Claude Companion work when the user develops over **VSCode Remote - SSH**: the
auto-approve/deny **gate must run on the remote host**, and the Mac menu bar must show the
**remote sessions** (full visibility), not just local ones.

> User's request: *"if in VSCode I am on a remote server, the hook thing should also work"* +
> (chosen scope) **gate + full visibility**.

## The core problem (why local install doesn't just work)

With Remote-SSH, the Claude Code **extension host runs on the remote machine**. So:

- Claude Code reads the **remote's** `~/.claude/settings.json` and runs the `PreToolUse` hook on
  the **remote filesystem** - our Mac-installed hook is never invoked.
- The hook needs `rules.compiled.json` + `blocklist.db` **on the remote** to decide; ours live in
  the Mac's `~/.config/claude-companion`, which the remote can't see.
- Session JSONL transcripts + `audit.ndjson` are written on the **remote**; the Mac app's tailer
  watches local paths, so it sees nothing.
- The hook binary is a **macOS Mach-O**; the remote is almost always **Linux** → we need a
  **Linux build of `companion-hook`** (see Spike 1 - the #1 unknown).

So "remote support" = get a working hook + current rules onto the remote, and stream the remote's
audit/sessions back to the Mac. The transport we already have is **SSH** (the user is connected
via Remote-SSH, so an `ssh <host>` reachable from the Mac almost always exists).

## Design - SSH push/pull, no remote daemon

Keep the project's **no-daemon, file-based** philosophy. The remote gets only a **static hook
binary + compiled rule files**; the Mac app orchestrates over SSH on a timer + on demand. Nothing
long-running runs on the remote except Claude Code itself invoking the hook per tool call.

### 1. Remote registration (one action per host)
- User picks "Add remote host…" and chooses an entry from their **`~/.ssh/config`** (parse it for
  `Host` aliases - same list VSCode Remote-SSH uses) or types `user@host`.
- The app, over SSH:
  1. Detect remote arch (`uname -m`) and `scp` the **matching Linux `companion-hook`** (x86_64 or
     aarch64, stripped ~55 MB) to the remote `~/.config/claude-companion/companion-hook`
     (space-free path - same root-cause rule as local; `chmod +x`). Re-push only on version change.
  2. `scp` the current `rules.compiled.json` + `blocklist.db` to the same dir.
  3. Merge-tag the four hooks into the **remote** `~/.claude/settings.json` via **pull-merge-push**
     (verified): scp it down → run `SettingsInstaller` locally against the temp file with the
     remote hook path → scp it back. Structure-preserving (keeps `permissions`/`enabledPlugins`/…)
     and coexists with any remote `rtk`/other hooks - same merge code as local.
  4. Back up the remote settings (`settings.json.companion-bak`) before step 3, exactly as locally.
- **Activation caveat carries over:** the remote extension host snapshots hooks at start - the
  user must **reload the VSCode window** after install (already documented for local; restate in
  the remote install UI).

### 2. Rules sync (Mac → remote, push)
- The gate on the remote reads `rules.compiled.json` fresh each call (same as local), so a push of
  the recompiled file takes effect on the next tool call.
- Whenever the Mac recompiles rules (`rules.yaml` edit, kill-switch toggle, blocklist refresh),
  **push the new `rules.compiled.json` / `blocklist.db` to every registered remote** (debounced).
  The kill-switch must propagate fast - treat `auto_accept` flips as high-priority pushes.
- **Fail-safe matches local:** if the remote can't read its compiled rules, `companion-hook`
  returns `ask` (never silent-allow). A failed push leaves the last-good remote file intact.

### 3. Audit + sessions sync (remote → Mac, pull)
- On a timer (and on window focus), the Mac app pulls the remote's:
  - `~/.config/claude-companion/audit.ndjson` (decision trail), and
  - the relevant **Claude Code session JSONL** under the remote `~/.claude/projects/…`.
- Use **incremental pull** (track per-host byte offsets like the local `audit.offset`; `rsync` or
  `ssh host "tail -c +<offset> <file>"`) so we move only new bytes, not whole files each tick.
- Ingest into the **same SQLite store**, tagging every row with a **host** (`local` or the SSH
  alias). Sessions, tools, tokens, cost, and audit all gain a `host` dimension.
- For [repo-quicklinks](repo-quicklinks.spec.md): capture `git -C <cwd> config --get
  remote.origin.url` **on the remote** during the pull and carry it back per session, so remote
  sessions get clickable repo links too.

### 4. Usage / limits - no remote work needed
- Usage is **per Anthropic account**, not per machine. If the remote uses the **same account**,
  the Mac's existing usage poll already reflects remote consumption - nothing to sync. Document
  this; only revisit if a user runs a *different* account on the remote (then: optional per-host
  usage read from the remote's `~/.claude/.credentials.json`, out of scope for v1).

### 5. UI
- Sessions list **groups/tags by host** (e.g. a small `host` chip on each card; "Active sessions"
  spans local + remotes). A per-host connection indicator (last-synced / unreachable).
- Settings: a **Remotes** section - list registered hosts, per-host status (hook installed?
  reachable? last sync), Add / Remove / Re-sync, and "Reload reminder" after install.

## Security / trust

- We only ever SSH to hosts the **user explicitly registers** (sourced from their own
  `~/.ssh/config`); no scanning, no implicit hosts.
- Use the user's existing SSH auth (agent/keys/config) - **never** prompt for or store passwords;
  shell out to the system `ssh`/`scp`/`rsync` so `~/.ssh/config`, `ControlMaster`, jump hosts, and
  agent forwarding all "just work" like they do for VSCode.
- The remote only receives a hook binary + rule files it would run anyway; we never read remote
  source beyond the session JSONL + audit the user opted into syncing.

## Spikes

### Spike 1 - Linux `companion-hook` build ✅ **VERIFIED (2026-06-18, on Fedora 43 x86_64)**

The highest risk is **resolved**. The dependency-light hook (`companion-hook → CompanionCore →
Foundation` only - no GRDB/Yams/macOS frameworks) **cross-compiles cleanly with the Swift Static
Linux SDK and runs on a stock remote with no Swift runtime.** Empirical results:

- **Builds + links** to a `x86_64-swift-linux-musl` target. `file` →
  *"ELF 64-bit … statically linked"*, `ldd` → *"not a dynamic executable"*.
- **Runs on stock Fedora 43** (no Swift installed). Fed the **real** `rules.compiled.json` +
  three payloads: `ls -la → allow`, `rm -rf / → deny` (correct rule captured), `git push → ask`.
  All correct, and the hook wrote `audit.ndjson` on the remote.
- **Latency: ~11 ms/call** cold start (50 invocations in 0.549 s), **~15 MB RSS** - inside the
  spec's `< 20 ms` target. (Process spawn + read rules + evaluate + append audit.)
- **Size: 141 MB unstripped → 55 MB after `strip`** (static Swift stdlib + Foundation). Strip in
  the build; push to a remote only **once per version change** (offset-tracked, debounced).

**⚠️ Gotchas discovered (bake into the installer/build):**
1. **Toolchain ↔ SDK versions must match EXACTLY.** `swift build` errored *"module compiled with
   Swift 6.2.3 cannot be imported by the Swift 6.3.2 compiler"* when mismatched.
2. **Xcode's Swift cannot be used.** Xcode 26 ships Swift **6.3.2**, which has **no published
   static Linux SDK** (swift.org publishes SDKs for its own release line: 6.2.3 / 6.2.1 / 6.2 /
   6.1.2 / 6.1 exist; 6.2.4 and 6.3.x do **not**). Build the Linux hook with a **swift.org
   toolchain** via [swiftly], pinned to a version that *has* a matching static SDK.
3. **`swiftly install 6.2` resolves to the latest patch (6.2.4) - which is *ahead* of the latest
   static SDK (6.2.3).** Pin explicitly: `swiftly install 6.2.3` + the 6.2.3 SDK.
4. **PATH alone isn't enough** - even with `~/.swiftly/bin` first, SwiftPM picked Xcode's 6.3.2.
   Build via **`swiftly run swift build …`** (or `swiftly use 6.2.3` first) to force the toolchain.
5. **CDN false-200:** `download.swift.org` returns HTTP 200 + a 173-byte XML `<Error>` body for a
   missing artifact - verify by **content-length**, not status code, when scripting SDK fetches.

**Verified build recipe (x86_64):**
```sh
swiftly install 6.2.3 && swiftly use 6.2.3                  # toolchain matching the SDK
swift sdk install <swift-6.2.3-RELEASE_static-linux…tar.gz> # matching static Linux SDK
swiftly run swift build --product companion-hook \
  --swift-sdk x86_64-swift-linux-musl -c release
strip .build/x86_64-swift-linux-musl/release/companion-hook # 141MB → 55MB
```
> **Build-time pin:** the CI that produces the Linux hook must pin the swift.org toolchain +
> static-SDK version together (they drift independently of Xcode). Treat the pair as one unit.

**aarch64 ✅ builds (2026-06-18):** the **same** static-linux SDK bundle produces a valid
`aarch64-swift-linux-musl` static ELF (`swift build --swift-sdk aarch64-swift-linux-musl`, 3.9s,
`file` → "ELF 64-bit … ARM aarch64 … statically linked"). Detect remote arch via `uname -m` and
ship the matching binary. *(Runtime-untested - Fedora box is x86_64 - but same toolchain/code, so
arm64 runtime is expected identical. Confirm on a real arm64 remote when one's available.)*

[swiftly]: https://www.swift.org/install/macos/swiftly/

### Spike 3 - Incremental pull ✅ **VERIFIED (2026-06-18)**
Offset-based pull is correct and cheap. Stored a byte offset, the remote appended 2 lines, then
`ssh <host> "tail -c +<offset+1> audit.ndjson"` pulled **only the 12-byte delta** (not the 30-byte
whole file) and appended locally → 5 distinct lines, **no dupes**. Needs only `ssh` + `tail`
(present everywhere); `rsync --append-verify` also works as an alternative. **Decision: use
`tail -c +N` with a per-host stored offset** (mirrors the local `audit.offset` design) - no rsync
dependency. Same mechanism pulls new session-JSONL bytes.

### Spike 4 - Reaching the remote from a background GUI app - partially de-risked
- **Big finding:** the test host uses **Tailscale SSH** (tailnet `100.x` IPs), and the connection
  worked with an **empty ssh-agent** (`ssh-add -l` → no identities). Tailscale auth is via the
  `tailscaled` daemon, **not** `SSH_AUTH_SOCK` - so a login-item GUI app (which doesn't inherit the
  shell's agent socket) can still reach Tailscale hosts. **Tailscale hosts are the easy case.**
- **Still to confirm:** for **plain key-based** SSH hosts, a launchd-spawned app has a minimal env
  (no `SSH_AUTH_SOCK`, trimmed `PATH`). Mitigations to bake in: invoke ssh by **absolute path**,
  pass **`-F <user ~/.ssh/config>`** + **`-o BatchMode=yes`** explicitly, and surface a clear
  "host unreachable / needs key" status rather than hanging. Verify with the actual login-item app.

### Spike 2 - `Stop`/`SessionStart` firing in the remote extension host - **needs interactive test**
Can't be settled headlessly: it requires a real Claude Code session **in the VSCode Remote-SSH
extension** (the concern is that notification-style hooks sometimes don't fire there). The remote
*does* run Claude Code (`~/.local/bin/claude`, populated `~/.claude/projects/*`), so the harness is
easy: register a logging `SessionStart`/`Stop` hook on the remote that appends `{event, ts}` to a
file, then the user starts+stops one session in VSCode and we inspect it. **Action: stage that
harness + a 2-min user procedure.** Keep the activity-timeout heuristic as the fallback regardless
(same as local Theme A).

## Remote recon - ✅ confirmed on the test host (Fedora 43, 2026-06-18)

Facts the design depends on, verified on a real Remote-SSH target:
- **Claude Code genuinely runs on the remote** - `~/.claude/` is populated: `settings.json`
  (3957 bytes → install must **merge**, never create), `projects/<encoded-cwd>/*.jsonl` session
  transcripts in the **same `-home-m-code-…` path-encoding as macOS** (so the existing JSONL
  ingestor should parse remote files unchanged), `.credentials.json`, `sessions/`, `history.jsonl`.
- **Sync/merge tooling all present:** `rsync`, `jq`, `tail`, `dd`, `sha256sum`. **Decision:
  pull-merge-push the settings.json** (cleaner than `jq` on the remote, reuses our tested Swift):
  scp the remote `settings.json` to a temp → `SettingsInstaller(settingsPath: temp, hookCommand:
  <remote hook path>).install()` → scp back. **No refactor needed** - `SettingsInstaller` is
  already parameterized on `settingsPath` + `hookCommand`, and it merges via `JSONSerialization`
  dict manipulation (touches only `json["hooks"]`), so it **provably preserves unknown top-level
  keys**. Verified against the real remote file, which has `effortLevel` / `enabledPlugins` /
  `permissions` and **no `hooks` key** - the installer adds `hooks` and leaves the rest intact.
- **Usage:** the remote has its **own `.credentials.json`**. If it's the **same** Anthropic account,
  the Mac's existing usage poll already covers it (no work). Only a *different* remote account would
  need a per-host usage read - out of scope for v1 (documented).

## Acceptance criteria

- [ ] Registering a remote installs a working Linux `companion-hook` + current rules into the
      remote's `~/.config/claude-companion` and merge-tags the remote `~/.claude/settings.json`.
- [ ] After reload, a non-matching command on the remote auto-`allow`s (no "type 1"); `rm -rf /`
      on the remote is `deny`'d - i.e. the gate works on the remote.
- [ ] Toggling the kill-switch / editing rules on the Mac propagates to the remote and takes
      effect on the remote's next tool call.
- [ ] Remote rules unreadable / push failed → remote hook returns `ask` (fail-safe), last-good
      rules preserved.
- [ ] The Mac menu bar shows remote sessions (host-tagged) alongside local ones, with live
      tokens/tools and the decision audit pulled from the remote.
- [ ] A remote git-repo session shows a working [repo quicklink](repo-quicklinks.spec.md).
- [ ] Removing a remote cleanly uninstalls the remote hook entry (restores its settings backup).
- [ ] No password is ever prompted/stored; only user-registered `~/.ssh/config` hosts are touched.

## Open questions

- **Sync cadence vs freshness** - audit/session pull interval (and push debounce) that feels live
  without hammering SSH. Event-driven triggers (window focus, post-decision) + a slow timer?
- **Multi-window / multiple remotes at once** - dedupe sessions if the same remote is open in two
  windows; per-host offset bookkeeping.
- **Dev Containers / Codespaces** (explicitly out of scope now - user uses Remote-SSH) would each
  need a different transport (`docker exec`, Codespaces CLI). Note as future, don't build.
- **Where to store remote registrations** - `config.yaml` (`remotes: [{alias, …}]`) vs a separate
  file; per-host last-offset + status sidecar.
