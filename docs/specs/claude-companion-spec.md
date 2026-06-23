# Claude Companion - Master Spec (v0.2)

A macOS menu-bar widget that monitors all running Claude Code sessions, tracks
usage limits, surfaces tool-call activity, and **auto-approves tool calls except
those on a blacklist** - killing the endless "type 1 to continue" loop.

Working name: *Claude Companion* (rename if you want - Zplane and Bender are taken).

> **This is the overview/architecture doc.** Detailed, buildable specs live one-per-feature
> under [`docs/specs/features/`](features/). See the [feature-spec index](#9-feature-spec-index).

---

## 0. Decisions locked (2026-06-15)

| Topic | Decision |
|---|---|
| **Stack** | All Swift - single codebase for both daemon and UI (the "visual one"). |
| **Permission tiers** | **Two-tier blacklist:** hard-`deny` for catastrophic commands, `ask` for merely-risky ones. Everything not on the blacklist auto-`allow`s, never prompts. (User: "if the command is not on the blacklist it should never ask… I am using sandbox anyway.") |
| **Approval delivery** | ~~Configurable banner + badge~~ → **superseded by recon.** An `ask`-tier match returns `permissionDecision:"ask"` and Claude Code shows its **own native prompt**. Companion adds only a passive deny-notification + a read-only recent-decisions list. (Hold-open banners are unsafe - see recon.) |
| **Storage** | **SQLite** - one store for sessions, cost, and audit log. |
| **Replace terminal prompt?** | No. The app never replaces Claude Code's own prompt; it only short-circuits permission decisions via the `PreToolUse` hook. |
| **Process model** | **No daemon.** A standalone `companion-hook` reads `rules.yaml` and decides locally; an always-on menu-bar app (login item) does monitoring/UI in-process. They share files, not a socket. (Earlier daemon+IPC design dropped - over-engineering.) |
| **URL blocklist** | Threat-feed domain check: **malicious domain → deny**, **compromised-but-reputable domain → ask** (with a clear reason), well-known/clean → allow, user `allow_overrides`. Content-based prompt-injection detection = separate future spec. |

---

## 0.5 Recon findings (empirical, 2026-06-15 - Claude Code 2.1.177)

All external unknowns were resolved by inspecting the live machine and a headless test.

| Contract | Result |
|---|---|
| **Hook output schema** | `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow\|deny\|ask"}}` - proven to allow/deny on 2.1.177. |
| **Hook input schema** | `cwd, tool_name, tool_input.{command,description/file_path}, permission_mode, session_id, tool_use_id, transcript_path, hook_event_name, effort`. |
| **Multiple hooks / `rtk`** | All matching PreToolUse hooks run; **deny wins** (deny>ask>allow). Our `*` hook coexists with the existing `rtk` Bash hook; install merges tagged. |
| **Hook block-timeout** | A blocking hook that times out **runs the tool** (not a prompt). ⇒ **never block**; `ask` defers to the native prompt. |
| **Usage endpoint** | `GET https://api.anthropic.com/api/oauth/usage` + `Authorization: Bearer <oauth>` + `anthropic-beta: oauth-2025-04-20` → `{five_hour, seven_day, seven_day_<model>, extra_usage}`. HTTP 200. |
| **Credentials** | macOS Keychain `service="Claude Code-credentials"`; JSON `claudeAiOauth.accessToken` (`sk-ant-oat01…`). No creds file. |
| **JSONL** | `.cwd`, `.sessionId`, `.message.model`, `.message.usage.{input,output,cache_creation,cache_read}_tokens`, `.message.content[].tool_use`. `stats-cache.json` = stale historical token/cost. |
| **GUI parity** | ✅ **Confirmed in the VSCode extension (2026-06-15):** hook `deny` auto-blocks with no prompt; hook `allow` runs the tool with no prompt. Headline feature works in the GUI. |

---

## 1. Goals

1. One glanceable menu-bar item showing 5h + weekly usage and active-session count.
2. A dropdown / detail panel with live multi-session monitoring (the screenshot view).
3. Per-project token + cost breakdown.
4. Live tool-call activity, including bash command chains.
5. **Auto-accept gate**: approve every tool call automatically *unless* it matches a
   blacklist rule (hard-`deny`) or an `ask` rule (→ Claude Code's own native prompt), plus a
   URL/domain reputation check (malicious → deny, compromised → ask).

## 2. Non-goals (v0.1)

- No remote/cloud sync, no mobile app, no multi-machine.
- No editing of Claude Code config from the UI (read-only on settings).
- No Windows/Linux (macOS only; uses menu-bar + Keychain).

---

## 3. Architecture - lean, daemon-free (revised 2026-06-15)

**No daemon, no socket, no IPC.** Two artifacts share state through files. The earlier
`companiond`+socket design was dropped once we learned the hook must never block and the
menu-bar app is always running - see [foundation §Why no daemon](features/foundation.spec.md#why-no-daemon-design-correction).

```
┌─────────────────────────────────────────────────────────────┐
│  Claude Code session(s) - VSCode extension                    │
│    │ writes JSONL          │ runs hooks         │ stores OAuth │
│    ▼                        ▼                    ▼             │
│  ~/.claude/projects/*.jsonl  PreToolUse/etc.    Keychain       │
└──────────┬───────────────────────┬──────────────────┬────────┘
           │                        │                  │
           │              spawns per tool call          │
           │                        ▼                   │
           │        ┌────────────────────────────┐      │
           │        │ companion-hook (tiny exec)  │      │
           │        │  reads rules.yaml+blocklist │      │
           │        │  → allow/deny/ask (instant) │      │
           │        │  → appends audit.ndjson     │      │
           │        └─────────────┬──────────────┘      │
           │                      │ files               │
           ▼                      ▼                      ▼
    ┌──────────────────────────────────────────────────────┐
    │  ClaudeCompanion.app  (menu-bar, always-on login item) │
    │   • JSONL tailer + usage poller + blocklist refresh     │
    │   • SQLite (sessions/cost/audit) ; writes rules.yaml    │
    │   • tails audit.ndjson → SQLite ; NSStatusItem + panel  │
    └──────────────────────────────────────────────────────┘
       shared files: ~/.config/claude-companion/{rules.yaml, blocklist.db,
                     config.yaml, audit.ndjson, companion.db}
```

The hook is **standalone** - the gate works even if the app is quit. The app is the only
long-lived process and does everything else in-process.

**Stack:** all Swift, one `CompanionKit` SwiftPM package (lib + `companion-hook` exec) + a
thin XcodeGen-generated menu-bar app shell. Go-like self-contained packaging mirrors
[`vhco-pro/ssm-connect`](https://github.com/vhco-pro/ssm-connect) (see foundation spec).

---

## 4. Data sources

### 4.1 JSONL log parsing (sessions, tokens, tools, cost)

- Watch `~/.claude/projects/<encoded-path>/<session-uuid>.jsonl` and
  `~/.claude/history.jsonl` with `fsevents` (Go: `fsnotify`; Swift: `FSEventStream`),
  debounced ~500ms.
- Each line is a JSON event. Parse for:
  - session id, project path, model (`claude-opus-4-8`, `claude-fable-5`, etc.)
  - message counts, input/output/cache tokens
  - tool_use events → name (Bash, Edit, Read, Write, Agent…) and, for Bash, the command
- Derive per-project + per-session token totals and estimated cost (per-model pricing
  table, kept in a config file so you can update it without recompiling).
- Read-only. Never write to these files.

### 4.2 Hooks (live events + the permission gate)

Register in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "*", "hooks": [
        { "type": "command",
          "command": "/usr/local/bin/companion-hook pretooluse" }
      ]}
    ],
    "PostToolUse": [
      { "matcher": "*", "hooks": [
        { "type": "command",
          "command": "/usr/local/bin/companion-hook posttooluse" }
      ]}
    ],
    "SessionStart": [ /* … */ ],
    "Stop":         [ /* … */ ]
  }
}
```

- `companion-hook` is a tiny **standalone** binary (the command above is the embedded
  bundle path `…/ClaudeCompanion.app/Contents/Helpers/companion-hook`, not `/usr/local/bin`).
  It reads the payload on stdin, **reads `rules.yaml` + the cached blocklist from disk,
  decides locally, prints the decision, and appends one `audit.ndjson` line** - no daemon,
  no socket, no network.
- For `PreToolUse` it returns `allow`/`deny`/`ask` (see §5). Other hooks just append a state
  line to `audit.ndjson`, which the always-on app tails into SQLite for the UI.

> The exact decision schema is **confirmed** on Claude Code 2.1.177 (see §0.5); the install
> step still sanity-checks it against the running version since it has drifted historically.

### 4.3 OAuth usage endpoint (5h + weekly limits)

- Reuse the token Claude Code already stores (macOS Keychain, or
  `~/.claude/.credentials.json`). No separate API key, no scraping.
- Poll the same usage endpoint that backs `claude.ai/settings/usage`.
- Surface: current 5h session %, weekly all-models %, and per-model weekly
  (Opus / Sonnet / Fable) where the plan exposes it, plus reset countdowns.
- Poll interval ~2 min, backoff on rate-limit.

---

## 5. The auto-accept permission engine (the headline feature)

**Default behavior: allow.** Every `PreToolUse` returns `allow` *unless* a blacklist
rule matches, in which case it returns `ask` (prompt you) or `deny` (hard block).

### 5.1 Decision flow

```
PreToolUse event
   │
   ▼
Is global auto-accept ON?  ──no──►  return "ask"  (normal Claude Code behavior)
   │yes
   ▼
Does tool/command match a DENY rule? ──yes──►  return "deny"  (+ notify)
   │no
   ▼
Does it match an ASK rule?           ──yes──►  return "ask"   (native prompt)
   │no
   ▼
return "allow"
```

### 5.2 Rule model

Rules live in `~/.config/claude-companion/rules.yaml`, hot-reloaded on change.

```yaml
auto_accept: true          # master switch (also toggleable from menu bar)

deny:                       # never run, always block
  - tool: Bash
    command_regex: 'rm\s+-rf\s+(/|~|\$HOME)'
  - tool: Bash
    command_regex: 'git\s+push\s+.*--force'
  - tool: Bash
    command_regex: ':\(\)\s*\{\s*:\|:&\s*\}'      # fork bomb
  - tool: Bash
    command_regex: 'mkfs|dd\s+if=.*of=/dev/'

ask:                        # pause and prompt me before running
  - tool: Bash
    command_regex: 'curl\s+.*\|\s*(sh|bash)'       # pipe-to-shell
  - tool: Bash
    command_regex: 'sudo\b'
  - tool: Bash
    command_regex: 'git\s+push\b'
  - tool: Bash
    command_regex: '(npm|pnpm|yarn)\s+publish'
  - tool: Bash
    command_regex: 'kubectl\s+delete|terraform\s+(destroy|apply)'
  - tool: Bash
    command_regex: 'aws\s+.*(delete|terminate|rm)'
  - tool: Write
    path_glob: '**/.env*'                          # writing secrets files
  - tool: Bash
    command_regex: '>\s*/etc/|/usr/|/System/'      # writes outside project

# Everything else → allow automatically
```

Matching covers: tool name, bash command (regex), file path (glob for
Edit/Write/Read), and optionally working directory. First matching rule wins;
deny beats ask beats allow.

### 5.3 Prompting for `ask` rules

When a rule resolves to `ask`, the hook returns `permissionDecision:"ask"` and **Claude Code
shows its own native prompt** - the hook returns instantly and never holds the call open (a
block-timeout would *run* the tool). No custom banner/queue. See
[approval-ux.spec.md](features/approval-ux.spec.md). The app adds only a passive deny
notification + a read-only recent-decisions list.

### 5.5 URL / domain reputation blocklist

Beyond the regex tiers, the hook checks URLs (Bash `curl`/`wget` args, `WebFetch`) against a
cached threat feed: **malicious domain → deny**, **compromised-but-reputable → ask** (with a
clear reason), clean → allow, plus user `allow_overrides`. See
[permission-engine.spec.md](features/permission-engine.spec.md#url--domain-reputation-blocklist).

### 5.4 Safety notes (be honest with yourself here)

- Auto-accept is genuinely risky: Claude can mutate your filesystem, push to remote,
  hit cloud APIs, and exfiltrate via `curl` without you in the loop. The blacklist is
  your only guardrail, so the **deny/ask defaults ship locked-down** and you opt into
  loosening them.
- Per-project override: allow a `.claude-companion.yaml` in a repo to *tighten* (never
  loosen) rules, so a sensitive repo can force `ask` on everything.
- Audit log: every decision (allow/ask/deny, rule matched, command, timestamp,
  session, prompt id) written to `~/.config/claude-companion/audit.log`. This is also
  your "what did Claude just do at 2am" trail.
- Kill switch: a menu-bar toggle that flips `auto_accept: false` instantly, and a
  global hotkey to do the same.

---

## 6. UI spec (menu bar)

### 6.1 Status item (always visible)

Compact, e.g.:  `◆ 23% · 5h 18%`  with color grading
(green <50 / orange 50-79 / red 80+). A small dot or count shows active sessions.
Auto-accept state shown via icon variant (e.g. filled ◆ = auto-accept on,
hollow ◇ = off). A subtle dot may flag a recent deny - there's no pending-approval queue
(asks go to Claude Code's native prompt).

### 6.2 Dropdown panel

Sections, top to bottom:

1. **Usage** - 5h session bar + reset countdown; weekly bar (+ per-model if available).
2. **Auto-accept** - master toggle, kill switch, read-only recent-decisions list, link to rules.
3. **Active sessions** - one card per running session: project name, model, msg count,
   context-fill %, token rates (↓in ↑out cache), memory, and the recent tool chain
   (Bash › Edit › Read …). Mirrors the screenshot's two-card layout.
4. **Activity** - a small sparkline/graph of tool or token rate over time.
5. **Projects** - collapsible per-project token + cost totals (today / week).
6. **Footer** - current model, Anthropic status indicator, last-updated, version.

---

## 7. Milestones

- **M0 - Skeleton:** menu-bar app (login item) + `companion-hook` binary + file-based state;
  JSONL tailer reads sessions and shows active-session count. No hooks yet.
- **M1 - Usage:** OAuth usage poller; 5h + weekly bars with reset countdowns and color
  grading in the status item and dropdown.
- **M2 - Auto-accept (the reason you're building this):** standalone `companion-hook`, rule
  engine + URL blocklist, default blacklist, `audit.ndjson`, kill switch. `ask` → native prompt.
- **M3 - Session detail:** per-session cards (tokens, context %, tool chains, memory),
  activity sparkline.
- **M4 - Cost:** per-model pricing table + per-project token/cost breakdown.
- **M5 - Polish:** per-project rule overrides, "always allow" exceptions,
  notifications config, settings window.

---

## 8. Resolved questions

All v0.1 open questions are now resolved - see [§0 Decisions locked](#0-decisions-locked-2026-06-15).

- **Daemon language** → All Swift (one codebase, the visual one).
- **How `ask` reaches you** → Claude Code's own native prompt (the hook returns `ask`); no
  custom banner/queue. The app adds only a passive deny notification + recent-decisions list.
- **Audit log storage** → SQLite, as the single store for sessions + cost + audit.
- **Replace the terminal prompt?** → No. The app provides a shared blacklist; anything not on
  it auto-allows and never prompts. Blacklist = `rm -rf` and similar. Sandbox covers the rest.

---

## 9. Feature-spec index

Each feature has its own buildable spec under [`features/`](features/), and will get its own
implementation plan. Build order follows the headline-first preference (permission engine early),
on top of the minimal foundation.

| Order | Spec | Maps to milestone | Status |
|---|---|---|---|
| 1 | [`foundation.spec.md`](features/foundation.spec.md) - menu-bar app + standalone hook, file-based state, SQLite, packaging | M0 | shipped v0.1 |
| 2 | [`permission-engine.spec.md`](features/permission-engine.spec.md) - hooks, rule engine, audit, kill switch *(headline)* | M2 | shipped v0.1 |
| 3 | [`approval-ux.spec.md`](features/approval-ux.spec.md) - `ask` → native prompt + passive deny notification | M2 | shipped v0.1 |
| 4 | [`session-monitor.spec.md`](features/session-monitor.spec.md) - JSONL ingestion → sessions/tokens/tools | M0/M3 | shipped v0.1 |
| 5 | [`usage-limits.spec.md`](features/usage-limits.spec.md) - OAuth reuse + usage poller | M1 | shipped v0.1 |
| 6 | [`menubar-ui.spec.md`](features/menubar-ui.spec.md) - status item + dropdown panel | M0-M3 | shipped v0.1 |
| 7 | [`cost-breakdown.spec.md`](features/cost-breakdown.spec.md) - pricing table + per-project cost | M4 | shipped v0.1 |
| 8 | [`repo-quicklinks.spec.md`](features/repo-quicklinks.spec.md) - click a session → open its GitHub/GitLab/Azure DevOps repo | v0.1 | shipped v0.1 (local sessions) |
| 9 | [`dependency-modernization.spec.md`](features/dependency-modernization.spec.md) - GRDB 7, Yams 6, CI on macos-26 | maint | shipped v0.1 |
| 10 | [`swift6-language-mode.spec.md`](features/swift6-language-mode.spec.md) - Swift 6 strict concurrency | maint | shipped v0.1 |
| - | [`prompt-injection-detection.spec.md`](features/prompt-injection-detection.spec.md) - content-based injection flagging | post-v0.1 | spec (future) |
| - | [`remote-ssh.spec.md`](features/remote-ssh.spec.md) - gate + full visibility on VSCode Remote-SSH hosts | next | spec (spiked, not built) |
| - | [`allow-tier.spec.md`](features/allow-tier.spec.md) - "always allow this" / actionable denials (allow override tier + `rules.local.yaml`) | next | spec (deferred, not built) |
| - | [`default-blacklist.reference.md`](features/default-blacklist.reference.md) - shipped `rules.yaml` deny/ask defaults (cited) | - | reference |

> **v0.1 shipped and released** (rows 1-10 implemented + verified live, 54 tests, Homebrew cask
> `brew install --cask vhco-pro/tap/claude-companion`). **Next up:** [`remote-ssh`](features/remote-ssh.spec.md)
> - gate + full visibility on VSCode Remote-SSH hosts (SSH push/pull, not cloud sync; revisits the
> v0.1 "no remote" non-goal). repo-quicklinks then extends to remote sessions. **Also unbuilt:** the
> [`allow-tier`](features/allow-tier.spec.md) "always allow this" override (engine `allow` tier +
> app-owned `rules.local.yaml`), and the v0.2 items still spec (accurate session lifecycle,
> notifications + sparkline) - see [`claude-companion-v0.2.spec.md`](claude-companion-v0.2.spec.md).
