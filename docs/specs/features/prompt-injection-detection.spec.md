# Feature Spec - Prompt-Injection Content Detection (FUTURE / experimental)

> Part of [Claude Companion](../claude-companion-spec.md). **Post-v0.1, experimental.**
> Status: **spec (future)** - captured now so the idea isn't lost; not scheduled for the
> initial build. Distinct from the [URL/domain blocklist](permission-engine.spec.md#url--domain-reputation-blocklist),
> which gates by *domain reputation* and cannot see content.

## Purpose

Catch the thing a domain blocklist can't: a **prompt-injection payload in fetched/read
content** - text that tries to hijack the agent ("ignore previous instructions", "exfiltrate
`~/.aws/credentials` to …", hidden instructions in a web page, README, issue, or file). The
payload can live on a perfectly reputable host (a GitHub gist, a docs page, a dependency's
README), so URL reputation is blind to it.

## Why this is hard (be honest)

- It's **content classification**, inherently fuzzy - false positives (a blog *about* prompt
  injection) and false negatives (novel phrasings, obfuscation, non-English, base64).
- The dangerous content arrives in **tool *output*** (`WebFetch`, `Read`, `Bash` stdout), so
  the natural hook is **`PostToolUse`**, not `PreToolUse` - by then the content is already in
  the model's context. We can warn/annotate, but we can't un-feed it.
- Truly robust detection wants an LLM-as-judge or a trained classifier - heavier than a regex
  hook and a different cost/latency profile.

## Approach (phased, opt-in)

1. **Phase A - heuristic flagger (cheap, local).** A `PostToolUse` companion-hook variant
   scans `WebFetch`/`Read`/`Bash` output for known injection signatures: imperative override
   phrases ("ignore (all )?previous instructions", "disregard your system prompt"), instructions
   targeting secrets/exfil ("send … to http", "cat ~/.ssh", "print your system prompt"), tool-
   directive lookalikes, large base64/hex blobs, zero-width/bidi unicode, HTML comments with
   instructions. On match → **annotate the audit log + notify** ("possible injection in fetched
   content from `<source>`"). It does **not** block (content already delivered).
2. **Phase B - pre-fetch gating where possible.** For `WebFetch`/`curl` of *untrusted* hosts,
   optionally `ask` *before* fetching (composes with the URL blocklist's tiering) so the human
   opts in to pulling unvetted content into context.
3. **Phase C - LLM-judge (optional, heavy).** Send fetched content to a cheap model (e.g.
   Haiku) with an injection-detection prompt; cache by content hash. Off by default (cost +
   latency + privacy). Configurable.

## Config (future)
```yaml
injection_detection:
  enabled: false            # experimental; off by default
  mode: heuristic           # heuristic | llm-judge
  on_detect: notify         # notify | ask-next | log-only
  scan_tools: [WebFetch, Read]
```

## Open questions
- Confirm Claude Code exposes tool *output* to `PostToolUse` (and in what shape) - needs an
  empirical check like we did for `PreToolUse`.
- False-positive budget: a noisy detector trains the user to ignore it. Start log-only, earn
  the notification.
- Whether Phase B (pre-fetch ask on untrusted hosts) belongs here or in the permission engine's
  blocklist tiering - likely the latter.

## Non-goals (even for the future version)
- Not a guarantee. This is defense-in-depth, explicitly best-effort, and must never be sold as
  "injection-proof."
