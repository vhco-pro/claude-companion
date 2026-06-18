# Plan - Cost Breakdown

> Implements [cost-breakdown.spec.md](../specs/features/cost-breakdown.spec.md). Build order **7**.
> Depends on [foundation](1-foundation.plan.md) + [session-monitor](4-session-monitor.plan.md).

## Phases

### P0 - Pricing table
- `~/.config/claude-companion/pricing.yaml` (USD per Mtok: input, output, cache_read,
  cache_write per model). Sync into the `pricing` table on load; hot-reload via config watcher.
- Seed with current per-model values (confirm before shipping defaults).
- *Test:* editing pricing.yaml hot-reloads and re-syncs the table.

### P1 - Cost computation
- Per usage row: Σ(tokens_kind × price_kind)/1e6 over input/output/cache_read/cache_write
  (note: `cache_creation_input_tokens` = write, `cache_read_input_tokens` = read).
- Roll up by project and by model, windowed today / this-week. Week boundary mirrors the
  usage-endpoint weekly reset (so bars and cost agree).
- Computed in-app; surfaced to the Projects section via in-process state.
- *Test:* per-project totals reconcile with `token_usage`; per-model sums to project total.

### P2 - Unknown model handling
- No price for a model ⇒ cost "-" + "no price for <model>" hint, never a fabricated number.
- *Test:* an unpriced model shows "-" + hint.

### P3 - Push to UI
- Emit cost `event` for the Projects section (today/week, per-project, per-model).
- *Test:* Projects section shows live today/week cost.

## Acceptance criteria (from spec)
- [ ] Per-project today/week totals reconcile with token_usage.
- [ ] Per-model breakdown sums to per-project total.
- [ ] pricing.yaml hot-reload recomputes.
- [ ] Unknown model ⇒ "-" + hint.
- [ ] cache-read vs cache-write priced separately.

## Risks
- Current per-model pricing (incl. separate cache rates) - confirm before shipping defaults.
- Week-boundary source of truth depends on usage-limits (plan 5) being landed first for the
  reset timestamp; until then, fall back to local Monday-00:00.
