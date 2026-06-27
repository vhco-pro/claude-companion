# Feature Spec - Allow Tier ("always allow this" / actionable denials)

> Part of [Claude Companion](../claude-companion-spec.md). Extends
> [permission-engine](permission-engine.spec.md) and [menubar-ui](menubar-ui.spec.md) B4 (recent
> decisions). Status: **shipped (implemented 2026-06-28; see [plan](../plans/10-allow-tier.plan.md)).**
> Engine `allow` tier + `rules.local.yaml` merge + "Always allow this" / "Block this" / guarded
> "Edit deny rule" in the recent-decisions panel. All acceptance criteria met + unit-tested; the
> real `companion-hook` binary honors exceptions (verified E2E).

## Purpose

When the hook `ask`s or denies (via a compromised-domain match), there is currently no in-app way
to say "this one is fine, stop bothering me." The only escape is hand-editing `rules.yaml`. This
feature adds an **`allow` override tier** to the engine plus an app-owned local rules file, so a
recent decision can be turned into a working exception from the UI in one click - without touching
the comment-rich shipped `rules.yaml`, and **without ever being able to override a hard `deny`**.

> Originally v0.2 Theme B item **B4** (see [v0.2 spec §4](../claude-companion-v0.2.spec.md)).
> Promoted to its own spec for discoverability; it is the most likely next actionable feature.
> Deliberately deferred from v0.1/v0.2: it needs real new infra in the headline decision path, not
> just a button, so it was judged not worth bolting on at the time.

## Why it is not "just a button"

The headline gate (`companion-hook`) reads `rules.compiled.json` and returns allow/deny/ask. There
is today no concept of an *allow exception* - only `deny` and `ask` blacklist tiers over an
implicit allow-everything default. Making "always allow this" real means changing the evaluator's
decision order AND giving the app a safe file to write exceptions into. Both are below.

## Design

### 1. The `allow` override tier in the engine

Add an `allow` tier to `CompiledRules` / `RuleEngine`, evaluated **after `deny` and the
malicious-URL check, before `ask`**:

```
deny  ->  malicious-URL  ->  ALLOW (new)  ->  ask  ->  compromised-URL  ->  allow-default
```

Consequences of that ordering:
- An `allow` exception **clears an `ask` match or a compromised-domain match** (the cases a user
  would reasonably want to wave through).
- An `allow` exception **cannot override a hard `deny` or a malicious-URL block** - you can never
  whitelist a fork bomb or a known-malicious domain. This preserves the locked-down stance.
- Therefore the UI only offers **"Always allow this"** on `ask`/compromised decisions. On a hard
  `deny` it instead offers **"Edit the deny rule"** (a [B3](menubar-ui.spec.md) rules-edit action,
  with a clear warning) rather than a silent allow.

### 2. App-owned `rules.local.yaml` (do not mutate the shipped rules)

The shipped `rules.yaml` is comment-rich and citation-heavy; round-tripping it through a
serializer would destroy that. Instead:

- Keep an **app-owned `rules.local.yaml`** holding: `allow` exceptions, user-added custom
  `deny`/`ask` rules, and a `disabled:` list for shipped rules toggled off in the UI.
- The rules **compiler merges base (`rules.yaml`) + local (`rules.local.yaml`)** into the single
  `rules.compiled.json` the hook already consumes. The hook is **unchanged** (still reads compiled
  JSON, no awareness of the split).
- The app only ever rewrites `rules.local.yaml` (struct -> YAML), so there is no comment- or
  formatting-preservation problem; the hand-authored `rules.yaml` is never written by the app.

This same `rules.local.yaml` machinery is what **[B3](menubar-ui.spec.md)** (toggle/add rules from
the UI) should also be built on - so this spec is the shared infra for both.

### 3. UI (recent decisions, actionable)

In the recent-decisions list (menubar-ui B4): click a `deny`/`ask`/compromised entry to see the
**rule/reason that matched** and the command/URL. Then:
- **"Always allow this"** (on `ask`/compromised only) -> appends a scoped `allow` exception to
  `rules.local.yaml` and recompiles. The exception is scoped to the matched tool + pattern, not a
  blanket allow.
- **"Block this domain/command"** -> appends a `deny` to `rules.local.yaml` and recompiles.
- **"Edit the deny rule"** (on hard `deny`) -> opens the B3 rule editor with a warning; no silent
  allow path exists for `deny`.

## Out of scope (v1 of this feature)

- A full rules-language editor. This is structured add / remove / toggle, not a YAML IDE.
- Time-boxed or session-scoped exceptions ("allow for this session only"). v1 exceptions are
  persistent until removed. (Possible later.)
- Any change to the hook binary's contract - it keeps reading `rules.compiled.json`.

## Acceptance criteria

- [ ] `RuleEngine` evaluates an `allow` tier in the order deny -> malicious -> allow -> ask ->
      compromised -> default, with unit tests for each precedence boundary.
- [ ] An `allow` exception clears an `ask`/compromised match but **cannot** clear a hard `deny` or
      malicious-URL block (unit-tested).
- [ ] The compiler merges `rules.yaml` + `rules.local.yaml` into `rules.compiled.json`; the shipped
      `rules.yaml` is never modified by the app.
- [ ] "Always allow this" on a recent `ask` decision creates a scoped exception and the hook honors
      it on its next call - no manual YAML editing.
- [ ] "Always allow this" is **not offered** on a hard `deny`; that path offers a guarded rule-edit
      instead.
- [ ] A toggled-off shipped rule (via the `disabled:` list) stops matching after recompile, without
      deleting it from `rules.yaml`.

## Open questions

- **Exception scoping granularity:** exact command string vs tool+pattern vs tool-only. Default to
  the matched tool + pattern; confirm that is neither too broad nor too narrow in practice.
- **Removing exceptions:** the UI to list and delete entries in `rules.local.yaml` (pairs with B3).
- **Conflict/merge precedence** when base and local both match the same tool+pattern with different
  tiers - define and test the deterministic winner (local `disabled:` and `allow` should win over
  the corresponding base entry, but never over a base hard `deny`).
