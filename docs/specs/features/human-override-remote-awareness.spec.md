# Feature Spec - Human-Override (`confirm`) Tier + Remote-Payload Awareness

> Part of [Claude Companion](../claude-companion-spec.md). Extends
> [permission-engine](permission-engine.spec.md) and [allow-tier](allow-tier.spec.md).
> Status: **draft** (2026-07-27). Adds a third decision tier (`confirm`) and remote-exec-wrapper
> awareness to the engine, so serious-but-legitimate operations become a per-invocation human
> approval instead of an un-overridable hard `deny` - without weakening any catastrophic block.

## Purpose

Today the engine has exactly two blacklist tiers over an allow-everything default: `ask` (prompt)
and `deny` (hard block). A hard `deny` is intentionally **un-overridable** - `allow` exceptions and
the `disabled:` list can never clear it ([allow-tier](allow-tier.spec.md), [RuleEngine](../../CompanionKit/Sources/CompanionCore/RuleEngine.swift)).
That invariant is correct for genuine catastrophes (a confused agent must not be able to whitelist
`rm -rf /`), but it has two painful consequences for legitimate work:

1. **No human escape hatch.** Reversible admin actions that happen to match a deny pattern - e.g. a
   Bash `> /etc/...` redirect writing a config/unit file - are hard-walled with no per-invocation
   way for the *human* to say "yes, I meant that." The only escape is hand-editing `rules.yaml`.
2. **Remote payloads false-deny.** The hook evaluates the **local** Bash string, but a large class
   of this user's commands run on a **remote** host via `aws ssm send-command` / `ssh`. A
   `> /etc/...` (or a `base64 -d | sh`) inside such a payload targets the *remote* box, yet it trips
   the macOS-oriented local-filesystem denies. Worse, the pattern often sits in a heredoc fed to an
   interpreter (`python3 <<'PY' ...`), which [`CommandSanitizer`](../../CompanionKit/Sources/CompanionCore/CommandSanitizer.swift)
   deliberately does **not** blank, so it matches as if it were a live local write.

This feature adds (A) a **`confirm` tier** = "hard-stop the model, require an explicit human
approval each time" and (B) **remote-exec-wrapper awareness** that reclassifies local-filesystem
denies to that tier when the action provably runs on a remote host. Neither ever clears a
catastrophic block.

## Why it is not "just move rules to `ask`"

`ask` already surfaces to the human, so moving a rule from `deny` to `ask` is *functionally* a human
override. But three things make a distinct tier worth it:
- **Audit + UX clarity.** A `confirm` decision is semantically "you overrode a serious rule," not
  "routine review." Keeping them separate lets the audit log and the recent-decisions panel treat
  them differently (stronger warning copy, distinct filtering) without changing hook plumbing.
- **Remote awareness needs engine logic anyway.** Detecting a remote-exec wrapper and downgrading a
  `deny` to a human checkpoint is an evaluator change; `confirm` is its natural landing tier.
- **Preserves the deny invariant.** Truly catastrophic patterns stay in `deny` and remain
  un-overridable even under a remote wrapper. `confirm` is only for the reversible middle ground.

## Design

### 1. Hook contract is unchanged (allow / deny / ask)

The hook must stay standalone and return **instantly** (no daemon, no socket; a block-timeout must
never decay into `allow`). So a `confirm` match compiles down to a returned `permissionDecision` of
**`ask`** - Claude Code's native prompt is the human approval, and the model can never self-approve.
`confirm` is an *engine/rules* concept, not a new wire value. The `permissionDecisionReason` carries
the stern override copy so the human sees why it is a checkpoint, not routine.

### 2. The `confirm` tier in the engine

Add `confirm: [Rule]` to `RulesFile`, `LocalRulesFile`, and `CompiledRules` (all lenient/optional
decode, so a pre-existing `rules.compiled.json` with no `confirm` key still loads). New decision
order in `RuleEngine.evaluate`:

```
deny  ->  malicious-URL  ->  [remote downgrade]  ->  ALLOW (clears ask/confirm/compromised)
      ->  confirm  ->  ask  ->  compromised-URL  ->  allow-default
```

- A `confirm` match returns `.ask` with reason `Self.confirmGuidance` ("Serious operation held for
  explicit human approval (override checkpoint). Approve only if you intend it.").
- An `allow` exception **clears a `confirm`** (a user who already whitelisted something is not
  re-prompted), exactly as it clears an `ask`. It still **cannot** clear a hard `deny`.
- `disabled:` may turn off a base `confirm` rule (like `ask`); it still cannot disable a `deny`.

### 3. Remote-exec-wrapper awareness

Add `RemoteExec.isRemoteExec(_ command:)` (in `CompanionCore`). Conservative, prefix/segment-based
detection of commands whose effect runs on another host:
- `aws ssm send-command ...` and `aws ssm start-session ... --document-name AWS-StartInteractiveCommand`
- `ssh [opts] host <command...>` and `ssh ... '<script>'` (a bare interactive `ssh host` with no
  remote command is NOT flagged - nothing runs unattended).

When `isRemoteExec` is true, the engine treats a matched **local-filesystem** `deny` rule (the
system-tree-write redirect + any `Write`/path-glob fs deny that a Bash payload text matches) as a
`confirm` instead of `.deny`. Catastrophic, host-agnostic rules are **exempt from the downgrade** and
still hard-deny even under a wrapper:
- `rm -rf /|~|$HOME|<top-level system dir>`, `--no-preserve-root`, `mkfs`/`newfs`,
  `dd of=/dev/<disk>`, fork bombs, `/etc/sudoers` edits.

Rules carry a compiled boolean `fsLocal` (or a tier-level tag) marking which denies are
"local-filesystem, safe to downgrade for a remote target." The catastrophic set is never tagged.

> Non-goal (future): semantically extracting and re-evaluating the *inner* remote script against a
> Linux ruleset. This spec only reclassifies decision *severity* for fs-local denies under a proven
> remote wrapper; it does not parse the payload.

### 4. Shipped-rule re-tiering (`default-rules.yaml`)

Move the **Bash-redirect** system-tree write `>>?\s*/(?:etc|usr|bin|sbin|System|Library)` from
`deny` to `confirm`. Leave hard-denied: the `Write`-tool path globs (`/etc/**`, `/System/**`,
`/usr/**`, LaunchAgents/Daemons), `/etc/sudoers`, and every catastrophic fs/disk rule. (The user's
*active* `rules.yaml` already carries the interim `deny -> ask` move; on rebuild the shipped default
supersedes it with the `confirm` tier.)

## Acceptance criteria

| # | Given | When | Then |
|---|-------|------|------|
| 1 | `confirm` rule for `> /etc` | local `cat > /etc/foo` | decision `ask`, reason = confirm/override copy |
| 2 | same | `aws ssm send-command ... 'cat > /etc/foo'` | decision `ask` (remote downgrade), not `deny` |
| 3 | catastrophic deny | `aws ssm send-command ... 'rm -rf /'` | decision `deny` (no downgrade under wrapper) |
| 4 | `allow` exception matching the command | a `confirm` match | decision `allow` (allow clears confirm) |
| 5 | `allow` exception matching the command | a hard `deny` match | decision `deny` (allow never clears deny) |
| 6 | pre-`confirm` `rules.compiled.json` (no key) | hook loads it | loads; behaves as before (empty confirm) |
| 7 | unreadable payload / missing rules | hook runs | `ask` (fail-safe unchanged) |
| 8 | bare `ssh host` (no remote command) | `> /etc` appears only as local redirect | NOT treated as remote; normal tiering |

## Test plan

- **RuleEngineTests**: criteria 1-5, 8 - confirm returns `.ask`; remote downgrade of fs-local deny;
  catastrophic exemption; allow clears confirm but not deny; remote detection negative case.
- **RulesCompilerTests**: `confirm` merges base + local; invalid regex dropped; `disabled` turns off
  a base confirm; criterion 6 backward-compatible decode.
- **RemoteExec** unit tests: ssm/ssh positive + interactive-ssh/scp negative classifications.
- **E2E**: build `companion-hook`, feed a synthetic `ssm ... 'cat > /etc/x'` payload on stdin,
  assert `permissionDecision:"ask"`.

## Out of scope

- Semantic evaluation of inner remote-script payloads against a Linux ruleset (future spec).
- Any in-app blocking approval dialog (the hook cannot wait; native `ask` is the approval surface).
- Changing the `deny` invariant: `allow`/`disabled` still never clear a hard `deny`.
