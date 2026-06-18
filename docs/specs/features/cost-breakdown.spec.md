# Feature Spec - Cost Breakdown

> Part of [Claude Companion](../claude-companion-spec.md). Build order **7** (M4).
> Depends on [foundation](foundation.spec.md), [session-monitor](session-monitor.spec.md).
> Status: **spec**.

## Purpose

Turn the token counts from session-monitor into estimated cost, broken down per project and
per model, for today and the current week. Estimates, not billing-accurate figures.

## Pricing table

- Lives in the foundation `pricing` table, seeded from a **config-editable** source so the
  user can update prices without recompiling:
  `~/.config/claude-companion/pricing.yaml` → synced into the `pricing` table on load.
```yaml
# pricing.yaml - USD per million tokens
claude-opus-4-8:   { input: 15.0, output: 75.0, cache_read: 1.5,  cache_write: 18.75 }
claude-sonnet-4-6: { input: 3.0,  output: 15.0, cache_read: 0.3,  cache_write: 3.75  }
claude-fable-5:    { input: 1.0,  output: 5.0,  cache_read: 0.1,  cache_write: 1.25  }
# values illustrative - confirm against current pricing before shipping
```
- Unknown model → cost shown as "-" with a "no price for <model>" hint, never a wrong
  number.

## Computation

- Cost per usage row = Σ (tokens_of_kind × price_of_kind) / 1e6, summed over input, output,
  cache-read, cache-write.
- Roll up by **project** and by **model**, windowed to **today** and **this week** (local
  time; week boundary matches the usage-limits weekly reset for consistency).
- Computed in-app; surfaced to the Projects section via in-process state (no daemon/push).

## Acceptance criteria

- [ ] Per-project today/week cost totals appear in the Projects section and reconcile with
      the underlying `token_usage` rows.
- [ ] Per-model breakdown is available and sums to the per-project total.
- [ ] Editing `pricing.yaml` hot-reloads and recomputes without restart.
- [ ] Unknown model → "-" + hint, never a fabricated cost.
- [ ] Cache-read vs cache-write priced separately and correctly.

## Open questions

- Confirm current per-model pricing (incl. separate cache-read/cache-write rates) before
  shipping defaults.
- Week boundary source of truth: mirror the usage endpoint's weekly reset, or local
  Monday-00:00? (Lean: mirror usage endpoint so bars and cost agree.)
