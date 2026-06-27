# Feature Spec - Permission Engine (the headline)

> Part of [Claude Companion](../claude-companion-spec.md). Build order **2** (M2).
> Depends on [foundation](foundation.spec.md). Status: **shipped v0.1**.

## Purpose

Kill the "type 1 to continue" loop. Provide one shared blacklist that applies to every
Claude Code session. Anything **not** on the blacklist is auto-allowed and never prompts.
Blacklisted commands are split into two tiers: hard-`deny` (catastrophic) and `ask`
(pause and confirm). The app never replaces Claude Code's own prompt - it only answers
the `PreToolUse` hook.

## Scope

In: the `PreToolUse`/`PostToolUse`/`SessionStart`/`Stop` hook registration, the
`companion-hook` client binary, the rule model + evaluator, the audit log, the global
kill switch + hotkey, and per-project tighten-only overrides.

Out: how an `ask` is surfaced to the user and resolved → [approval-ux](approval-ux.spec.md).

## How it wires in (standalone hook - no daemon)

1. App adds hook entries to `~/.claude/settings.json` for `PreToolUse`, `PostToolUse`,
   `SessionStart`, `Stop` (matcher `*`), pointing at the embedded
   `…/ClaudeCompanion.app/Contents/Helpers/companion-hook` (merge-tagged; coexists with rtk).
2. On each tool call, Claude Code runs `companion-hook pretooluse`. The hook reads the payload
   on stdin, **reads `rules.yaml` + the cached blocklist from disk, evaluates locally, prints
   the decision, and appends one line to `audit.ndjson`** - then exits. No socket, no daemon,
   no network. Self-contained and fast (see Latency & failure).
3. `PostToolUse`/`SessionStart`/`Stop` just append a state line to `audit.ndjson` (which the
   app tails) and exit immediately - no decision.

> The menu-bar app is **not** in the decision path. It only *produces* `rules.yaml`/blocklist
> and *consumes* `audit.ndjson`. So the gate works even when the app is quit. See
> [foundation shared-state model](foundation.spec.md#shared-state-model-replaces-ipc).

> **⚠️ Hook path MUST be space-free (root-cause bug, 2026-06-16).** Claude Code invokes the hook
> command **unquoted** - a path with a space (e.g. the dev bundle under `.../public projects/...`)
> silently fails to execute (it runs `.../public`), yielding NO output and NO audit, so Claude Code
> falls back to **prompting**. The hook *looked* installed and correct but never fired. **Fix: the
> installer stages the hook binary to a space-free path** (`~/.config/claude-companion/companion-hook`)
> and registers THAT. Confirmed matcher `"*"` fires fine - the space, not the matcher, was the bug.
> The installer also wires rtk's own hook (Option A) for reproducibility; the two hooks coexist.

> **⚠️ Activation after install (confirmed 2026-06-16).** Claude Code snapshots its hooks when
> the session / VSCode **extension host** starts. After clicking Install, an **already-running**
> session - including a *new chat in the same VSCode window* (it reuses the existing host) - will
> NOT have the hook and keeps prompting. The user must **reload the window**
> (`Developer: Reload Window`) or start a fresh one. The Install action should surface this
> ("Reload your editor to activate"). The hook itself was verified correct (returns `allow`); only
> activation timing is the gotcha.

### ✅ Confirmed hook contract (empirical test, Claude Code 2.1.177, 2026-06-15)

**Input** - Claude Code sends this JSON on stdin to a `PreToolUse` hook:
```json
{
  "hook_event_name": "PreToolUse",
  "session_id": "…", "tool_use_id": "…", "transcript_path": "…",
  "cwd": "/path/to/project", "permission_mode": "default", "effort": "…",
  "tool_name": "Bash",
  "tool_input": { "command": "echo hi", "description": "…" }
}
```
(For Edit/Write/Read, `tool_input` carries `file_path` etc. instead of `command`.)

**Output** - to decide, the hook prints to stdout (exit 0):
```json
{ "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow" | "deny" | "ask",
    "permissionDecisionReason": "…" } }
```
Printing nothing (exit 0) = defer to the normal permission flow.

**Verified behavior on 2.1.177:** `permissionDecision: "allow"` runs a tool that otherwise
could not (no prompt); `"deny"` blocks it (Claude is told it was denied). Both proven via a
headless harness. The output schema is no longer a guess - but the install step should still
sanity-check it against the running CC version, since it has drifted historically.

> **GUI parity - ✅ confirmed (VSCode extension, 2026-06-15).** Manually verified in the
> extension the user actually runs: a hook `deny` auto-blocks the Bash call with no prompt,
> and a hook `allow` runs an otherwise-prompting command (`touch`) with no prompt. The
> headline auto-approve feature works in the GUI, not just the CLI.

### ✅ Confirmed coexistence with `rtk` (2.1.177)
Machine already has `PreToolUse` `matcher: "Bash"` → `rtk hook claude` (rewrites Bash
commands). Confirmed: **all matching PreToolUse hooks run; any `deny` wins** (deny > ask >
allow across hooks). So our `*`-matcher hook coexists with rtk and our `deny` is always
honored. Each hook receives the **original** `tool_input` (hooks run independently), so we
evaluate the command Claude proposed - fine for safety. Install MUST **merge tagged** into
the existing array, never clobber rtk.

## Decision flow

```
PreToolUse → is auto_accept ON? ──no──► return "ask"  (normal Claude Code behavior)
                  │yes
            match DENY rule (regex)?           ──yes──► "deny"   (+ reason guides the model:
                  │no                                            "do not work around; ask the user")
            URL in cmd/args on MALICIOUS feed? ──yes──► "deny"   (+ reason: known-malicious)
                  │no
            match ALLOW exception (regex)?     ──yes──► "allow"  (user override; see allow-tier)
                  │no
            match ASK rule (regex)?            ──yes──► "ask"
                  │no
            URL on COMPROMISED feed?           ──yes──► "ask"    (+ reason: normally-trusted,
                  │no                                            currently flagged compromised)
            return "allow"
```
First matching rule wins; **deny beats malicious beats allow-exception beats ask**. The `allow`
tier (added 2026-06-28, [allow-tier](allow-tier.spec.md)) sits *after* deny+malicious so a user
exception can clear an `ask`/compromised match but **never** a hard deny. The hook **always returns
a decision immediately and never blocks** - `ask` defers to Claude Code's native prompt rather than
holding the call open (see Latency & failure). On a `deny`, the `permissionDecisionReason` is written
to tell the model not to silently work around the block. See [approval-ux](approval-ux.spec.md).

## Rule model - `~/.config/claude-companion/rules.yaml` (hot-reloaded)

Schema (representative - the **full shipped default lives in
[`default-blacklist.reference.md`](default-blacklist.reference.md)**: 40+ curated rules across
filesystem/disk/fork-bomb/privesc/RCE/secrets-exfil/cloud/VCS/persistence/DB, with per-rule
rationale, false-positive analysis, macOS notes, and cited sources):

```yaml
auto_accept: true     # master switch; also toggled from the menu bar / hotkey

deny:                 # catastrophic - never run (samples; see reference for the full set)
  - { tool: Bash, command_regex: '\brm\s+...(?:/|~|\$HOME|/\*|--no-preserve-root)' }  # rm -rf of root/home
  - { tool: Bash, command_regex: '\bdd\b[^|;&]*\bof=\s*/dev/(?:r?disk\d|sd[a-z])' }   # overwrite raw disk
  - { tool: Bash, command_regex: '\b(?:curl|wget)\b[^|]*\|\s*(?:sudo\s+)?(?:ba|z)?sh\b' } # pipe-to-shell
  - { tool: Write, path_glob: '{/,~/}Library/Launch{Agents,Daemons}/**' }            # persistence

ask:                  # risky / outward-facing - defer to Claude Code's native prompt
  - { tool: Bash, command_regex: '^\s*(?:sudo|doas)\b' }
  - { tool: Bash, command_regex: '\bgit\s+push\b' }
  - { tool: Bash, command_regex: '\bterraform\s+(?:destroy|apply)\b' }
  - { tool: Bash, command_regex: '(?:\.ssh/.*_rsa|\.aws/credentials|\.env)\b' }      # secrets read
```
Match dimensions: `tool` name, `command_regex` (Bash), `path_glob` (Edit/Write/Read),
optional `cwd_glob`. Ships **locked-down**: user opts into loosening, never the reverse.
Regexes are precompiled once per `rules.yaml` load. **Caveat (stated in the reference):**
regex blocking is accident-prevention, not a security boundary - it pairs with the OS sandbox.

> The block above is an **abridged illustration**. The full shipped default - ~30 deny + ~35
> ask rules with per-rule rationale, false-positive analysis, macOS specifics, and cited
> sources - is the canonical [default-blacklist reference](default-blacklist.reference.md).
> Two rules to validate against a real command corpus before shipping (flagged there): the
> fork-bomb pattern and the DB one-liner (`psql … -c`). Remember: this is accident-prevention,
> **not** a security boundary - the OS sandbox is the real guardrail.

### Per-project override - `.claude-companion.yaml` (tighten-only)
A repo may add `deny`/`ask` rules or force `auto_accept: false`, but **cannot remove or
weaken** global rules. Evaluator unions project rules with global and takes the strictest
outcome.

## URL / domain reputation blocklist

The thing Claude Code itself doesn't do: when a tool call references a URL (Bash `curl`/`wget`
args, `WebFetch` domain), check the host against a **cached threat feed** and gate by feed
classification. The mental model the user wants: *"if the domain is bad, it's bad - done; if a
normally-good domain got hacked, ask me and say so."*

```yaml
blocklist:
  enabled: true
  # Aggregate as many reputable free feeds as possible; the app merges + dedupes them into
  # one compact blocklist.db. `class` is the default bucket for a feed; URLhaus carries
  # per-entry tags that override it (so a URLhaus "compromised" entry → ask, not deny).
  feeds:
    - { name: urlhaus,        url: "https://urlhaus.abuse.ch/downloads/text/",            class: from-feed }  # malware URLs; tags compromised vs malicious
    - { name: threatfox,      url: "https://threatfox.abuse.ch/export/csv/domains/recent/", class: malicious } # abuse.ch IOC domains
    - { name: openphish,      url: "https://openphish.com/feed.txt",                       class: malicious }  # phishing
    - { name: phishing-army,  url: "https://phishing.army/download/phishing_army_blocklist_extended.txt", class: malicious }
    - { name: stevenblack,    url: "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/malware/hosts", class: malicious } # malware-only variant
    - { name: feodo-c2,       url: "https://feodotracker.abuse.ch/downloads/ipblocklist.txt", class: malicious } # botnet C2 IPs/hosts
  refresh_minutes: 360
  on_malicious: deny              # dedicated-malicious domain → hard block, no prompt
  on_compromised: ask             # normally-reputable but flagged compromised → native prompt
  unknown_class: malicious        # if a feed gives no class signal, treat as malicious (safer)
  allow_overrides:                # crystal-clear, user-owned exceptions (loosen on purpose)
    - "raw.githubusercontent.com"
    - "registry.npmjs.org"
    - "github.com"
    - "pypi.org"
```
> Feed list is illustrative defaults - confirm each feed's current URL, format, and licence
> (some require attribution; PhishTank now needs a registered API key, so it's omitted). The
> decoder is per-feed (text/CSV/hosts-file) behind one normalizer; adding/removing a feed is a
> config + small parser change. **Only URLhaus reliably distinguishes compromised vs malicious**
> - most feeds are flat "malicious", which is why `on_compromised` will mostly trigger from
> URLhaus-tagged entries.

- **Classification (the key design point):** entries are bucketed **malicious** vs
  **compromised** using the feed's own metadata where it exists - e.g. URLhaus tags some
  entries as `compromised` (a hacked legit site) vs a dedicated abuse domain. `on_malicious`
  → `deny`; `on_compromised` → `ask` with a reason string that literally says "normally-trusted
  but currently flagged as compromised." When a feed gives no class signal, treat as
  `malicious` (safer) unless the host is in `allow_overrides`.
- **Matching:** extract hosts from the command/args (and `WebFetch` input), normalize
  (strip scheme/port/path, lowercase, registrable domain), exact + parent-domain match. The
  blacklist regex tiers still run first; URL checks slot in as shown in the decision flow.
- **Overrides win for allow only:** an `allow_overrides` host short-circuits the URL check
  (never the regex `deny` tier - you can't override a fork bomb by whitelisting a domain).
- **Hook reads it cheaply:** the app compiles feeds into a sorted, dependency-free
  `blocklist.db` (one `host<TAB>class` line per entry). The hook loads it **only when the
  command actually references a host** (so the common no-URL case does zero blocklist IO), and
  the hook never does network or links GRDB. *(v0.1 loads the file into a dict on demand; a
  memory-mapped binary-search format is a later optimization if the file grows large.)*
- **Freshness - dynamic, must not go stale silently.** Threat feeds change constantly, so the
  app keeps the list live:
  - **Periodic refresh** on a timer (`refresh_minutes`, default 360 = 6h) re-fetches every feed
    and recompiles `blocklist.db`; an immediate refresh runs at launch.
  - **Event-driven refresh** on **wake-from-sleep** (`NSWorkspace.didWakeNotification`) and on
    **network-reachability return** (`NWPathMonitor`) - a closed laptop never sits on a stale
    list for a whole interval.
  - **The hook reads the file fresh every invocation**, so a recompile takes effect on the very
    next tool call (no stale in-memory cache).
  - **Keep-last-good on failure:** if a fetch fails the old `blocklist.db` is left intact (never
    lose protection), but staleness is **surfaced, not hidden** - the menu shows
    "updated 2h ago" and flags **⚠️ stale** when the last successful refresh is older than 2× the
    interval (derived from `blocklist.db`'s mtime). Per-feed errors are shown too.
  - **Feed-fetch gotcha (resolved):** abuse.ch served a `Content-Encoding: gzip` response whose
    auto-decompression under `URLSession` stripped line endings → 0 parsed hosts. Fix: request
    `Accept-Encoding: identity` + a real `User-Agent`, and parse on **any** newline (`\n`/`\r`/
    `\r\n`). Confirmed live: 552 domains compiled.
- **Out of scope here - content-based prompt injection.** A domain list cannot catch an
  injection payload on a clean host. Detecting that needs scanning fetched *content*
  (`WebFetch`/`Read` output) and is tracked as a separate **future/experimental** spec, not v0.1.

## Audit log

Every decision → the hook appends one JSON line to `audit.ndjson` (`ts, session_id,
prompt_id, tool, command, decision, rule_matched`). The app tails that file and ingests rows
into the `audit` table for the UI activity view - the "what did Claude do at 2am" trail. If
the app is down, lines queue on disk and are ingested later (the gate is unaffected). Not
truncated automatically in v0.1; the app may compact after ingest.

## Kill switch

- Menu-bar toggle flips `auto_accept` instantly (writes `rules.yaml`, takes effect on the
  very next decision).
- Global hotkey does the same - default **⌃⌥⌘A** (control-option-command-A, "auto-accept"),
  rebindable via `config.yaml` (`hotkeys.toggle_auto_accept`). Chosen to avoid common app
  shortcuts; registered via a global event monitor (no extra dependency).
- With `auto_accept: false`, **every** `PreToolUse` returns `ask` → normal Claude Code
  behavior, i.e. the app gets out of the way entirely.

## Latency & failure behavior

- **Never block the hook.** Confirmed on 2.1.177: if a `PreToolUse` hook blocks past its
  timeout, the tool call **proceeds (runs)** - it does *not* fall back to a prompt. The hook
  is pure local computation (read files → match → print), so it returns in single-digit ms.
  Budget: target **< 20 ms**, ceiling **100 ms** including cold start (hence the GRDB-free,
  dependency-light hook binary).
- **Fail-safe default:** if `rules.yaml`/blocklist can't be read or parsed, or the stdin
  payload is malformed, `companion-hook` returns `ask` immediately (defer to Claude Code's
  native prompt) - never silently `allow`. A broken companion must never widen permissions,
  and because `ask` returns instantly it can't decay into `allow` via the block-timeout above.

## Acceptance criteria

- [ ] Installing the app registers all four hooks in `settings.json` and is cleanly
      removable.
- [ ] A non-matching Bash command returns `allow` with no prompt; audited as `allow`.
- [ ] `rm -rf /` returns `deny`, is blocked, audited, and notified.
- [ ] `git push` returns `ask` → Claude Code's native prompt appears (hook returns instantly).
- [ ] `auto_accept: false` makes every call return `ask`.
- [ ] `rules.yaml` unreadable/malformed → hook returns `ask` (fail-safe), not `allow`.
- [ ] `curl <known-malicious-domain>` → `deny`; `curl <compromised-good-domain>` → `ask` with
      the "normally-trusted, currently compromised" reason; `allow_overrides` host → `allow`.
- [ ] Decision latency p95 < 100 ms (cold start included), with no app running.
- [ ] Gate works with the menu-bar app quit (hook is standalone).
- [ ] A repo `.claude-companion.yaml` can tighten but provably cannot loosen.
- [x] GUI parity confirmed: `allow`/`deny` decisions are honored in the VSCode extension.

## Why a hook (not native `permissions` config)

Claude Code's native `permissions.{allow,ask,deny}` lists use **glob/prefix** matching
(`Bash(rm -rf:*)`), not regex, and can't express patterns like pipe-to-shell mid-command or
`$HOME` expansion. Our hook does its own **regex** evaluation, so it's strictly more
expressive - which is why we use the hook path despite the GUI caveat.

## Open questions

- *(Resolved - `companion-hook` ships **embedded in the app bundle** at
  `…/ClaudeCompanion.app/Contents/Helpers/companion-hook`; that absolute path is written into
  `settings.json`. No admin, no `/usr/local/bin`. See [foundation packaging](foundation.spec.md#packaging--self-contained-mirrors-ssm-connect).)*
- *(Resolved - GUI parity, hook schema, allow/deny behavior, and rtk coexistence all
  confirmed empirically. No external unknowns remain.)*
