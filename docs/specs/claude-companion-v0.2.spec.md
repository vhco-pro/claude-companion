# Claude Companion - v0.2 Spec (interactivity, accurate sessions, branding)

> Builds on the shipped v0.1 (foundation · permission-engine · session-monitor · usage-limits ·
> cost-breakdown · menu-bar UI - all live, 46 tests). v0.1 is functional but **read-only,
> bare-bones, and its session "active" state is a heuristic.** v0.2 makes it interactive,
> accurate, and branded. Status: **spec.**

## 1. Goals (the v0.1 gaps this closes)

1. **Accurate session lifecycle** - "active" should mean *actually open*, not "had activity in
   the last 30 min."
2. **Interactivity** - you can hover, expand, drill into, and *edit* from the UI instead of
   reading static text and hand-editing YAML.
3. **Branding** - the vhco VH hexagon as the app icon + a monochrome menu-bar template.
4. **Awareness** - a passive notification when something is denied; an activity sparkline.

## 2. Non-goals (v0.2)

- No remote/cloud/multi-machine, no mobile (still local-only).
- No full rules *language* editor - structured add/remove/toggle, not a YAML IDE.
- No replacement of Claude Code's own prompt (unchanged from v0.1: `ask` defers to native).

---

## 3. Theme A - Accurate session lifecycle

**Problem:** `active` = `last_seen_at` within 30 min (a timer). It marks open-but-idle sessions
as dead and can't detect a real close. Tools like the Copilot/IDE panels track the actual
process; we can get the real signal from Claude Code's own hooks.

**Design:**
- We already register `SessionStart` and `Stop` hooks; today `companion-hook` exits silently for
  them. Make it **record them** (append to `audit.ndjson` or a sibling `lifecycle.ndjson` with
  `{event: session_start|stop, session_id, ts}`). The app ingests them and sets
  `sessions.status` = `active` on `SessionStart`, `ended` on `Stop`.
- **Recon required (spike):** confirm the `SessionStart`/`Stop` payload shapes + that `Stop`
  actually fires on session end in the **VSCode extension** (empirical, like we did for
  `PreToolUse`). Note from research: some notification-style hooks don't fire in the extension -
  so `Stop` reliability must be verified, with the 30-min heuristic kept as a **fallback** when
  no explicit `Stop` arrives (e.g. a hard kill).
- Status model: `active` (started, no stop) → `ended` (stop seen) → heuristic `idle` (no
  activity N min, no stop) as a soft state. The UI shows live/idle/ended distinctly.

**Acceptance:**
- [ ] Confirm `SessionStart`/`Stop` payloads + extension firing (spike, documented).
- [ ] Starting a session flips it `active`; ending it (Stop) flips it `ended` immediately.
- [ ] A hard-killed session (no Stop) falls back to `idle` after the window.
- [ ] The popover's "active" list reflects real open sessions, not a timer.

---

## 4. Theme B - Interactive popover

**Problem:** the popover is read-only `Text`. v0.2 makes each section explorable + editable.
This likely means moving from a single flat panel to a small navigable surface (sections that
expand, or a detail pane on click). Implementation note: `.menuBarExtraStyle(.window)` hosts a
real SwiftUI view tree, so hover (`.help`/`onHover`), `DisclosureGroup`, `List` selection,
`Popover`/sheet detail, and `TextField`/`Toggle` editing are all available.

### B1 - Blocklist, explorable
- Click/expand "Blocklist: N domains" → a **searchable list** of the cached domains (with their
  class: malicious/compromised) and **which feed** each came from; per-feed counts + last-refresh
  + any feed errors. A **Refresh now** button.
- Add/remove **allow-overrides** from the UI (writes `config.yaml` `blocklist.allow_overrides`).

### B2 - Session detail
- Click a session card → detail: full project path, model, **context-fill %**, msg count, the
  full tool chain (not truncated), token split (↓in ↑out cache-read/write), **cost split**, start
  time + duration, active/idle/ended state.

### B3 - Rules, editable
- View the active deny/ask rules grouped by category; **toggle** individual rules; **add** a
  custom `deny`/`ask` (tool + pattern) via a small form; surface invalid-regex warnings inline.
- "Open rules.yaml" / "Open config dir" buttons for power users.

### B4 - Decisions, actionable
- Recent decisions list: click a `deny`/`ask` → the **rule/reason** that matched and the command;
  **"Always allow this"** generates a scoped allow-exception (the one v0.1 deferred), and
  **"Block this domain/command"** adds a deny - both write `rules.yaml`/overrides and recompile.

**Acceptance (per sub-feature):**
- [x] **B1 (done):** the blocklist line expands to a searchable, lazy-rendered list of *all*
      cached domains (malicious/compromised colored) with a Refresh button. *(Still TODO:
      feed-per-domain attribution + add/remove overrides from the UI.)*
- [x] **B2 (done):** tapping a session expands its detail showing what the card doesn't - full
      cwd, start time, cache tokens, and a **per-tool breakdown** (`Bash ×412  Edit ×98 …`).
      Deliberately does NOT duplicate the card. *(Context-fill % still TODO - needs the per-model
      window table.)*
- [ ] **B3:** a rule can be toggled/added from the UI; the hook honors it on its next call.
- [ ] **B4 (deferred - specced, not built, 2026-06-18):** "Always allow this" on a decision
      creates a working exception without editing YAML.
  > **Why deferred:** it needs real new infra in the headline decision path, not just a button -
  > judged not worth bolting on right now. **Design when we do build it:**
  > - Add an **`allow` override tier** to `CompiledRules`/`RuleEngine`, evaluated **after `deny`
  >   + malicious-URL, before `ask`** (flow: deny → malicious → **allow** → ask → compromised →
  >   allow-default). So "always allow" clears an `ask`/compromised match but **cannot override a
  >   hard `deny`** (you can't whitelist a fork bomb) - keeps the locked-down stance. On a `deny`
  >   entry the UI offers "edit the deny rule" (a B3 action with a warning), not a silent allow.
  > - Don't mutate the comment-rich shipped `rules.yaml`. Keep an **app-owned `rules.local.yaml`**
  >   (allow exceptions + custom deny/ask + a `disabled:` list for toggled-off shipped rules); the
  >   compiler **merges** base + local → `rules.compiled.json`. The app rewrites only the local
  >   file (struct → YAML, no comment-preservation problem). The hook is unchanged (reads compiled
  >   JSON). This same `rules.local.yaml` machinery is what **B3** (toggle/add rules) should use.

---

## 5. Theme C - Branding (vhco VH hexagon)

Reuse `vhco-pro/ssm-connect`'s `AppIcon.icon` (Icon Composer, color VH-hexagon gradient).
- **App icon:** keep the **theme-adaptive Icon Composer `AppIcon.icon`** (auto light/dark/tinted/
  clear), `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`. ⚠️ **It only compiles on Xcode 26+.**
  Locally (Xcode 26.5) it emits `AppIcon.icns` + a full `Assets.car` + `CFBundleIconName` (verified).
  **CI MUST build on Xcode 26** - the release workflow already "selects the newest installed
  Xcode," so the runner must *have* 26. This is exactly what broke ssm-connect's icon: a release
  run used an **older** Xcode → `actool` copied the `.icon` in raw (no `.icns`, no
  `CFBundleIconName`) → blank Launchpad icon.
- **Safety net (required):** add a **post-build verification** to the release pipeline (the
  reusable `swift-release-action`) that **fails the release** if the built `.app` has no
  `CFBundleIconName` / no `AppIcon.icns` - so a broken icon never silently ships again; a failure
  is the signal the runner lacks Xcode 26.
- **Fallback only if a runner truly can't get Xcode 26:** a classic `.appiconset` (PNGs via
  `sips`) compiles anywhere but **loses the theme-adaptive variants** - last resort, not default.
- **Menu-bar item:** a **template** (monochrome black + alpha) rendering of the same VH-hexagon
  mark, set `isTemplate = true` so macOS tints it (white/dark menu bar, black/light, accent when
  open). Replaces the `bolt.shield` SF Symbol. Auto-accept state shown via a variant (filled vs
  outline, or a small dot badge) since a template can't use color.
- Produce the template from the logo (silhouette of hexagon + V + H) or export from Icon Composer.

**Acceptance:**
- [ ] App icon shows the VH hexagon in Finder/About.
- [ ] Menu-bar shows a crisp monochrome VH mark that tints correctly in light + dark menu bars.
- [ ] Auto-accept on/off is still distinguishable in the menu bar.

---

## 6. Theme D - Notifications & activity

- **Deny notification (best-effort):** the v0.1 approval-ux spec's passive
  `UNUserNotificationCenter` banner on `deny` (config `approval.notify_on_deny`). Verify whether
  it surfaces from a background menu-bar app in the VSCode-extension context.
- **Activity sparkline:** Swift Charts mini-chart of tool-call (or token) rate over time, from
  `tool_events.ts` bucketed per interval. The one reference-screenshot element still missing.

**Acceptance:**
- [ ] A `deny` posts a passive notification when enabled (or is documented as extension-dropped).
- [ ] The popover shows a sparkline of recent tool/token rate.

---

## 6.5 Theme E - Distribution (Homebrew tap)

Ship like `ssm-connect`: the release pipeline (already consuming `vhco-pro/swift-release-action`)
publishes a GitHub Release with the signed `.app` zip + sha256; a **Homebrew cask** in
**`vhco-pro/homebrew-tap`** is then bumped by the tap's own `sync-cask` workflow so users
`brew install --cask claude-companion`.

**Design:**
- `Casks/claude-companion.rb` in the tap: `version`, `sha256`, `url` → the GitHub Release asset;
  `app "ClaudeCompanion.app"`. Ad-hoc-signed/not-notarized for now → the cask documents the
  one-time Gatekeeper approval (`xattr -dr com.apple.quarantine` or right-click→Open), same as
  ssm-connect. (When a Developer-ID cert lands, drop the caveat.)
- The tap's `sync-cask` workflow watches claude-companion releases and opens the cask-bump PR
  (mirror ssm-connect's setup - confirm whether it's per-repo or a shared dispatcher).
- Our `release.yml` ends with a "release published → tap will sync" notice (as ssm-connect does).

**Acceptance:**
- [ ] A tagged release produces a GitHub Release asset the cask can point at.
- [ ] `vhco-pro/homebrew-tap` gains/bumps a `claude-companion` cask on release.
- [ ] `brew install --cask vhco-pro/tap/claude-companion` installs a runnable menu-bar app.

> Needs the repo to be **pushed to GitHub** + the release pipeline run at least once (you're
> driving git). The cask + tap wiring can be staged in parallel with the app work.

## 7. Open questions / spikes

- **`SessionStart`/`Stop` hook contract** in 2.1.x + **does `Stop` fire in the VSCode extension?**
  (empirical spike - top risk for Theme A).
- **Menu-bar template generation** - convert the color logo to a clean black-on-transparent
  template (sips/ImageMagick threshold) vs export from Icon Composer. Confirm the mark reads at
  18px.
- **In-UI editing model** - write structured edits back to `rules.yaml`/`config.yaml` while
  preserving the user's comments/formatting (the v0.1 `setAutoAccept` does a minimal text edit;
  generalize carefully, or keep a managed block).
- **Context-fill %** for session detail - derive from running tokens ÷ per-model context window
  (the `models.yaml` window table from session-monitor's open item).

## 8. Suggested phasing

1. **C (branding)** - quick, self-contained, visible. (app icon + menu-bar template)
2. **A (accurate sessions)** - spike the hooks, then record + ingest lifecycle.
3. **B (interactivity)** - the big one; do B1 (blocklist) → B4 (decisions) incrementally.
4. **D (notifications + sparkline)** - polish.
