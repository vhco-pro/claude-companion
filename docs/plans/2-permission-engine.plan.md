# Plan - Permission Engine (headline)

> Implements [permission-engine.spec.md](../specs/features/permission-engine.spec.md).
> Build order **2**. Depends on [foundation](1-foundation.plan.md).
> **Revised 2026-06-15 - standalone hook (no daemon) + URL blocklist.**

## Outcome

The "type 1 to continue" killer: a standalone `companion-hook` that, on every `PreToolUse`,
reads `rules.yaml` + the cached blocklist, decides `allow`/`deny`/`ask` locally, prints, and
appends an `audit.ndjson` line - no daemon, no socket. `ask` → Claude Code's native prompt.
Plus the URL/domain blocklist, audit, kill switch. Coexists with the existing `rtk` Bash hook.

## Phases

### P0 - Hook contract (resolved by recon)
- ✅ 2.1.177: input + output schema, allow/deny proven, deny-wins across hooks, hooks see the
  original input, **GUI parity confirmed**. See
  [spec](../specs/features/permission-engine.spec.md#-confirmed-hook-contract-empirical-test-claude-code-2117-2026-06-15).
- Build the `HookDecisionSerializer` from the confirmed shape; install-time schema sanity-check
  vs the running CC version (it has drifted historically).
- *Test:* CLI allow/deny regression test green (GUI verified manually).

### P1 - `companion-hook` binary (standalone, GRDB-free)
- Subcommands: `pretooluse`, `posttooluse`, `sessionstart`, `stop`.
- `pretooluse`: read stdin payload → load `rules.yaml` + `blocklist.db` from disk → evaluate
  (P3) → print decision via the P0 serializer → append one `audit.ndjson` line → exit.
- Others: append a state line to `audit.ndjson` and exit (no decision).
- **Never blocks; no network; no socket.** Fail-safe: unreadable rules / malformed payload →
  print `ask` (never `allow`).
- *Test:* piped payload → valid decision JSON + one audit line; runs with the app **not**
  running; p95 latency < 100ms incl. cold start.

### P2 - Rule model + loader (`CompanionKit`)
- Parse `rules.yaml` (auto_accept, deny[], ask[], blocklist policy); precompile regex per load.
- Per-project `.claude-companion.yaml`: union with global, **tighten-only** (strictest wins;
  cannot remove/weaken global).
- App hot-reloads on edit; the hook simply reads fresh each invocation.
- *Test:* rules parse + recompile; project file can tighten, provably cannot loosen.

### P3 - Evaluator (`CompanionKit`)
- Pure function `(payload, rules, blocklist) -> allow|deny|ask`. Order: auto_accept off ⇒ ask;
  regex deny ⇒ deny; **URL on malicious feed ⇒ deny**; regex ask ⇒ ask; **URL on compromised
  feed ⇒ ask**; else allow. First match wins; deny>ask>allow.
- Match dimensions: tool name, `command_regex` (Bash), `path_glob` (Edit/Write/Read), optional
  `cwd_glob`. Evaluate against the **original** command (hooks run independently; we see what
  Claude proposed, not rtk's rewrite).
- *Test:* table-driven cases incl. the default blacklist + blocklist samples from the spec.

### P4 - URL / domain reputation blocklist
- **App side:** refresh threat feed(s) (e.g. URLhaus) on a timer → compile into a compact,
  read-only `blocklist.db` (sorted registrable-domain + class byte: malicious/compromised).
- **Hook side:** extract hosts from command/args + `WebFetch` input, normalize, memory-map +
  binary-search `blocklist.db` (no SQLite linked into the hook). `on_malicious: deny`,
  `on_compromised: ask` (with the "normally-trusted, currently compromised" reason),
  `allow_overrides` short-circuits to allow (URL check only, never the regex deny tier).
- *Test:* malicious domain ⇒ deny; compromised ⇒ ask w/ reason; override ⇒ allow; missing
  feed-class defaults to malicious.

### P5 - Audit log
- Hook appends one JSON line per decision to `audit.ndjson` (ts, session_id, prompt_id, tool,
  command, decision, rule_matched). The app tails → `audit` table (foundation P2). App-down ⇒
  lines queue on disk, ingested later.
- *Test:* each allow/deny/ask appends exactly one well-formed line; app ingests it once.

### P6 - Install / coexistence
- Merge our 4 hook entries (`PreToolUse`/`PostToolUse`/`SessionStart`/`Stop`, matcher `*`) into
  `~/.claude/settings.json`, **tagged**, using the embedded
  `…/ClaudeCompanion.app/Contents/Helpers/companion-hook` absolute path; preserve the `rtk`
  Bash hook. App **self-heals** the path on launch if the bundle moved.
- *Test:* install adds ours + keeps rtk; uninstall removes only ours; settings.json stays valid.

### P7 - Kill switch
- Menu-bar toggle + global hotkey flip `auto_accept` (app writes `rules.yaml`; effective on the
  hook's next read). `auto_accept: false` ⇒ every PreToolUse returns `ask`.
- *Test:* toggle + hotkey both flip state and take effect on the next decision.

## Acceptance criteria (from spec)
- [ ] Non-matching Bash ⇒ allow, no prompt, audited.
- [ ] `rm -rf /` ⇒ deny + audit; `git push` ⇒ ask → Claude Code's native prompt (hook instant).
- [ ] `curl <malicious>` ⇒ deny; `curl <compromised-good>` ⇒ ask w/ reason; override ⇒ allow.
- [ ] `auto_accept:false` ⇒ all ask. `rules.yaml` unreadable ⇒ hook ask (fail-safe).
- [ ] Decision p95 < 100ms incl. cold start; gate works with the app quit.
- [ ] Project file tightens, can't loosen; rtk hook survives install/uninstall.

## Risks
- Blocklist feed metadata must distinguish malicious vs compromised (URLhaus tags some) -
  default to malicious when unknown.
- Hook cold-start latency - keep it GRDB-free / dependency-light; benchmark in P1.
