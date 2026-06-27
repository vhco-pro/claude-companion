# Plan - Allow Tier

> Implements [allow-tier.spec.md](../specs/features/allow-tier.spec.md). Build order **10**.
> Depends on [permission-engine](2-permission-engine.plan.md) + [menubar-ui](6-menubar-ui.plan.md).
> Tracking issue: [#4](https://github.com/vhco-pro/claude-companion/issues/4).

## Outcome

An `allow` override tier exists in the engine (evaluated `deny → malicious → ALLOW → ask →
compromised → default`), fed by an app-owned `rules.local.yaml` that the compiler merges with the
shipped `rules.yaml`. The hook is unchanged (still reads one `rules.compiled.json`). The UI turns a
recent `ask`/compromised decision into a scoped exception in one click; a hard `deny` never gets a
silent allow.

## Phases

### P1 - Engine `allow` tier (CompanionCore, fully unit-testable)
- Add `allow: [Rule]` to `CompiledRules` (Codable key `allow`, default `[]` for back-compat).
- Insert the tier in `RuleEngine.evaluate`: deny → malicious-URL → **allow** → ask →
  compromised-URL → default. An `allow` match short-circuits to `.allow`.
- *Tests:* allow clears an `ask` match; allow clears a compromised-URL match; allow **cannot**
  clear a hard `deny`; allow **cannot** clear a malicious-URL block; absent `allow` key still
  decodes (back-compat).

### P2 - Local file + compiler merge (CompanionKit)
- Extend `RulesFile` with `allow: [RuleSpec]` and `disabled: [String]` (identifiers of shipped
  rules toggled off). Identity of a rule = `tool|pattern` (commandRegex or pathGlob).
- New `LocalRulesFile` model for `rules.local.yaml` (allow / custom deny / custom ask / disabled).
- Compiler merges base + local → one `CompiledRules`: local `disabled` removes matching base
  rules; local `allow`/`deny`/`ask` append to their tiers. Base hard `deny` always survives.
- `Paths.rulesLocalFile`. App only ever writes `rules.local.yaml`; never `rules.yaml`.
- *Tests:* merge appends allow; `disabled` drops a base rule without editing `rules.yaml`; a local
  `disabled`/`allow` cannot remove a base hard `deny`; missing local file = base-only (no error).

### P3 - RulesManager write API (CompanionKit)
- `addAllowException(tool:pattern:)`, `addDeny(...)`, `setRuleDisabled(...)` → struct→YAML write of
  `rules.local.yaml` + recompile. Round-trip safe (no comment preservation needed - app owns it).
- *Tests:* adding an exception then recompiling makes the engine `allow` the previously-`ask`ed cmd.

### P4 - UI (ClaudeCompanion app)
- Recent-decisions row → detail (matched rule + command). "Always allow this" on `ask`/compromised
  only; "Block this" appends a deny; hard `deny` shows guarded "Edit the deny rule", no silent allow.

## End-to-end gate (before offering to ship)
Build the real `companion-hook`, seed a base `rules.yaml` with an `ask` on `git push`, add an
`allow` exception via `rules.local.yaml`, recompile, then run the **actual hook binary** against a
`git push` payload and assert it now returns `allow` (was `ask`) - no manual JSON editing.

## Acceptance criteria (from spec)
- [x] Engine order deny → malicious → allow → ask → compromised → default, unit-tested per boundary.
- [x] `allow` clears `ask`/compromised but never a hard `deny`/malicious-URL block.
- [x] Compiler merges `rules.yaml` + `rules.local.yaml`; `rules.yaml` never modified by the app.
- [x] "Always allow this" on a recent `ask` → scoped exception honored on the hook's next call.
- [x] "Always allow this" not offered on a hard `deny`; guarded rule-edit instead.
- [x] A `disabled:` shipped rule stops matching after recompile without deletion from `rules.yaml`.

## Status
**Implemented + verified 2026-06-27.** 68 unit tests pass; the real `companion-hook` binary honors
allow exceptions (control=ask / treatment=allow / safety=deny on a hard-deny); the built app
launches and runs the base+local merge clean against an isolated config. UI (P4) ships the
recent-decisions section with per-row actions; menu-bar popover rendering needs a human click-through.

## Open questions (carry from spec; resolve as we build)
- Exception scoping: default tool+pattern (matched rule's pattern), confirm in practice.
- Conflict precedence when base+local both match a tool+pattern: local `disabled`/`allow` win,
  except never over a base hard `deny`. Make explicit + tested in P2.
- Removing exceptions UI (list/delete `rules.local.yaml` entries) - pairs with B3, defer past v1.
