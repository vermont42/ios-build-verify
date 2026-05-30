---
name: ios-build-verify
description: Build and verify SwiftUI iOS apps. Bundles xcodebuild + xcbeautify for builds and AXe-driven simulator operations for verification — lifecycle, describe-ui, tap, screenshot, named-intent ops (read/verify/set value, verify screen loaded), and an annotation-check phase — behind named scripts driven by a per-project config.
---

# ios-build-verify

A Claude Code skill bundling the build and verify halves of the iOS agentic-coding loop for SwiftUI apps. Build operations pipe `xcodebuild` through `xcbeautify` for token-cheap output with raw fallback; verify operations drive the iOS Simulator via `xcrun simctl` and AXe so the agent can check its own work.

## Validated configuration

The skill has been validated against **Claude Code (CLI) running Claude Opus 4.7**. The shell scripts themselves are harness-agnostic, but the skill's *use* leans on agent judgment in places that have only been exercised on this configuration: reading SKILL.md after `set_value.sh` exit 6 and applying the documented Form-in-NavigationStack workaround; translating the Bool `simctl launch --` example to a string-valued `@AppStorage`; recognizing when to set `MAIN_TABS_COORDS` versus editing the shared `data/coordinates.json`; running the agent-led colloquy without it derailing. Behavior on untested setups (Sonnet, Haiku, non-Anthropic models, IDE-embedded agents, MCP-driven setups, Cursor/Cline/Aider/etc.) may vary from "works fine" to "subtly wrong in ways that look like skill bugs but are actually agent-judgment shortfalls." This is scope of validation, not scope of permission — reports from other configurations welcome.

Two checks back this up:

- **Harness check (script-driven).** `setup_project.sh` warns when `CLAUDECODE != 1` — Claude Code's subprocess env marker. The script proceeds either way; the warning surfaces the validation scope at first use without blocking.
- **Model check (agent-driven).** The active model is not propagated to subprocesses, so this check has to live in the agent — see **Step 0** of the First-use setup colloquy below for the imperative form. Treating background context as a runtime checklist is unreliable (May 2026 GenericApp validation, Q8: the validator read past this section's earlier prose-only model-check on first pass), so the runtime instruction lives at the top of the colloquy where the agent is already in checklist mode.

## External grounding

This skill is an applied instance of the principle Anthropic names in [*Best Practices for Claude Code*](https://code.claude.com/docs/en/best-practices) under the heading **"Give Claude a way to verify its work"**:

> *"Include tests, screenshots, or expected outputs so Claude can check itself. This is the single highest-leverage thing you can do."*

The skill gives the agent a real, simulator-driven verification loop so the human stays at the spec and review boundaries rather than serving as the sole feedback loop in the implementation middle.

## Self-verification framing

Self-verification, not self-direction or self-deployment. The agent verifies that its output meets criteria the human set; the human still defines the spec and reviews the result. Self-verification is the floor that makes higher-quality human-in-the-loop possible — not the abolition of it.

## Design principles

Two principles drive the skill's surface choices and where the next investment goes:

**Mechanize prose recipes.** Where SKILL.md tells the agent "compose this multi-step workflow" — calibrating tab-pill coordinates, dismissing first-launch onboarding, classifying a popover-vs-rollup error — that prose is a candidate for replacement by a shipped script. Prose recipes work, but exact a per-invocation cost in agent reasoning, and degrade on weaker models that don't reliably synthesize multi-step flows from background context. Shipped scripts collapse the cost to a single named call. New skill investment should preferentially convert prose recipes into shipped scripts rather than add new prose.

**Errors as state probes.** Error messages should classify the post-state when they fail, not just report the failure. The "present AXUniqueIds in the tree" hint emitted by `read_value.sh` / `verify_screen_loaded.sh` / `verify_value.sh` / `set_value.sh` on exit 4 is the canonical example: the same hint surface diagnoses identifier rollup (only 1–2 distinct ids), modal-popover gating (`PopoverDismissRegion` / `xmark.circle.fill` present), and unexpected app crash (home-screen app names present). One classifier in the script saves the agent from re-deriving the pattern on every failure. New error paths in this skill should follow the same shape.

## Common first-real-app friction

Adopters bringing the skill to an existing app — as opposed to a clean lab project — predictably hit one or more of the following. Each entry points at the detailed section below for the workaround.

1. **Greenfield identifiers (zero `.accessibilityIdentifier` calls).** The launch anchor needs one to exist. Pick a stable leaf element and add `.accessibilityIdentifier(...)` to it. See "Seven core questions" Q6 and "Identifier rollup."
2. **First-launch onboarding view.** Apps that gate the launch screen behind a one-time intro will fail `launch_app.sh`'s wait-for-render until dismissed. See "Onboarding dismissal" below; `dismiss_onboarding.sh` and the `ONBOARDING_DISMISS_LABEL` config field automate the one-time tap.
3. **Non-3-tab pill geometry.** The shipped `data/coordinates.json` defaults are calibrated for the canonical 3-tab pill; 2-tab and 4–5-tab pills need per-app calibration. See "iOS 26 Tab-bar coordinate fallback" and `scripts/measure_tab_pill.sh`.
4. **TipKit popovers gating mid-flow.** `Tips.configure(...)` on the launch screen will sporadically present popovers that gate the AXTree. See "Modal AXTree gating → TipKit."
5. **Form-in-NavigationStack walls.** `Toggle`/`Picker` inside `Form` inside `NavigationStack` on iOS 26 silently rejects HID dispatch. See "iOS 26 Form-in-NavigationStack" for the `simctl launch -- -key value` injection workaround.
6. **Launch-time modal auto-presentation.** Apps that auto-present a `.sheet` / `.alert` / `.popover` / `.fullScreenCover` on first render — review prompts, "what's new" sheets, IAP paywalls, custom permission primers, custom rate-this-app dialogs — gate the AXTree before `FIRST_SCREEN_ID` can be polled, and `launch_app.sh` exits 5 with `children: []` in the final tree. The modal-gating mechanism is the same one documented for verify-ops mid-flow (see "Modal AXTree gating" below); the launch-time variant just hits earlier. Recovery patterns: (a) if the dismiss button has a stable AXLabel across cold launches and the underlying AXTree exposes it, set `ONBOARDING_DISMISS_LABEL` to that label so the wait-for-render interleave taps it; (b) if the modal gates the AXTree completely (full children-not-enumerated case — common with custom popovers and some `.alert` shapes), one-time-tap the dismiss button via `axe describe-ui --point <x>,<y>` to locate it, then rely on the app's cooldown / "seen" flag to suppress on subsequent launches; (c) for a clean test sandbox, `xcrun simctl uninstall <UDID> <BUNDLE_ID>` resets the app's UserDefaults. The May 2026 Konjugieren validation surfaced this with a custom review prompt fired by accumulated `promptActionCount` UserDefaults — `launch_app.sh` exits with the gating hint that classifies the post-state.
7. **iOS 26 SwiftUI `TabView(.page)` gesture-injection wall.** Apps with onboarding or any other paged TabView (`.tabViewStyle(.page)`) cannot be advanced via `axe swipe`: the gesture executes at the AXe layer but the page coordinator's velocity threshold rejects it. Page-indicator dots (`.indexViewStyle`) are not hit-testable as accessibility elements either, so tapping the second dot does nothing. Recovery: read the source to understand the page sequence and the dismiss/skip mechanism, then either dismiss the modal entirely (if you only need the post-modal state) or drive page advancement programmatically by setting the bound state that `selection: $currentPage` reads. The May 5 2026 Konjugieren UI-audit validation hit this on `OnboardingView.swift` and ended up reading source for design inspection rather than capturing per-page screenshots. `swipe_page_tabview.sh` (below) is a fail-fast diagnostic: it runs a wide-and-slow swipe and exits 7 with this hint when the AXTree didn't change.

The friction is bounded — every item above has a documented workaround — but the *first* time you hit one in a new app is the moment to read the corresponding section, not after the fifth opaque verify failure.

## Non-goals

UI test authoring or execution (XCUITest, `*UITests` Xcode targets) is an explicit non-goal. The verify operations occupy the same problem space — assert post-conditions on a running app — in a different shape: agent-driven, immediate, composable with the rest of the agentic loop rather than maintained as a parallel test bundle invoked via `xcodebuild test`. Adopters who want XCUITest can keep it alongside this skill; the skill takes no position on coexistence, but its scripts do not generate, execute, or read XCUITest artifacts.

## Skill packaging

The skill is read-only after install. Per-project values (app display name, bundle identifier, target simulator, Xcode scheme, Xcode project file) live in `<project>/.claude/ios-build-verify.config.sh`, sourced by every script. One installation works across N apps; updates pull cleanly without merge conflicts.

Operations live in a flat `scripts/` directory with self-describing names. Build versus verify groupings emerge from script names rather than from formal sub-namespaces — a YAGNI choice. The `data/` directory ships device-specific reference data (e.g., `coordinates.json` for the iOS 26 Tab-bar coordinate fallback documented below).

### Per-project config schema

`<project>/.claude/ios-build-verify.config.sh` is a sourced bash file exporting:

| Variable | Example | Meaning |
|---|---|---|
| `APP_NAME` | `AztecCal` | Display name; used by verify ops to find `.app` in DerivedData. |
| `BUNDLE_ID` | `biz.joshadams.AztecCal` | iOS bundle identifier; used by `simctl launch`. |
| `PROJECT` | `AztecCal.xcodeproj` | Xcode project file (path relative to project root). May differ from `APP_NAME`. |
| `SCHEME` | `AztecCal` | Xcode scheme passed to `xcodebuild -scheme`. |
| `TARGET_SIM` | `iPhone 17` | Simulator device name passed via `-destination`. When the named device exists under multiple iOS runtimes, `launch_app.sh` resolves to the latest-runtime match. |
| `FIRST_SCREEN_ID` | `input_convert_month` | Accessibility identifier of an element known to be present on the launch screen. `launch_app.sh` polls `axe describe-ui` for this string to confirm the app rendered before returning. |
| `WAIT_FOR_RENDER_BUDGET_S` | `10` | Seconds `launch_app.sh` will wait for `FIRST_SCREEN_ID` to appear *after* `simctl bootstatus -b` completes (if cold boot) and `simctl launch` returns. Tunable per machine. |
| `MAIN_TABS` | `(convert info settings)` | Bash array of the app's main TabView tab names, in render order. `tap_tab.sh` looks up the requested name's index in this array. Empty (`MAIN_TABS=()`) is legitimate for apps without a TabView; `tap_tab.sh` exits cleanly with a "no tabs configured" error in that case. |
| `MAIN_TABS_COORDS` | `("115,822" "287,822")` | Bash array of `x,y` coordinates parallel to `MAIN_TABS`. When set, `tap_tab.sh` taps these coords and ignores `data/coordinates.json` entirely. Per-project coordinates exist because the modern `Tab(...)` DSL renders pills whose centers depend on tab count *and* device, so the shared default file can't be authoritative for both 2-tab and 3-tab apps on the same simulator. Calibrate via screenshot + measurement (see "iOS 26 Tab-bar coordinate fallback" below). Empty (`()`) means "fall back to `data/coordinates.json` defaults" — safe for the canonical 3-tab case on the shipped device entries. |
| `MAIN_TAB_ANCHORS` | `("Convert" "Info" "Settings")` | Optional. Bash array of `AXLabel` strings parallel to `MAIN_TABS` — one expected on-screen label per tab, used by `smoke_test.sh` for per-tab assertions via `verify_label_visible.sh`. Holds labels (matched against `axe describe-ui`'s `AXLabel` field), not identifiers — `calibrate.sh --tab-anchors` is the identifier-based counterpart. Empty (`()`) or unset means `smoke_test.sh` falls back to "AXTree changed after tap" verification, which catches no-op taps but doesn't confirm the destination screen rendered as expected. |
| `MAIN_TABS_COUNT_ACK` | `"2:3"` (quoted `<declared>:<coord-count>` tuple) | Optional. When present and equal to the current `<MAIN_TABS-length>:<data.tabs[TARGET_SIM]-length>` pair, `setup_project.sh` suppresses its MAIN_TABS-vs-coords-count mismatch warning (only consulted in the data-file fallback path; ignored when `MAIN_TABS_COORDS` is set). Set by `--ack-tab-mismatch`; preserved across re-runs; re-fires the warning when either side of the pair changes. Empty string (`""`) is the default. |
| `ONBOARDING_DISMISS_LABEL` | `Skip` | Optional. AXLabel of the Skip / Dismiss / Get-Started button shown by the app's first-launch onboarding view. When set, `launch_app.sh`'s wait-for-render loop interleaves a check for this label and taps it once if present, then continues polling for `FIRST_SCREEN_ID`. Empty (`''`) means no auto-dismiss; apps without an onboarding view leave this empty. The standalone `dismiss_onboarding.sh` reads the same field for direct invocation. |

The file is generated by the first-use colloquy (`scripts/setup_project.sh`); see the "First-use setup" section below. Hand-editing afterwards is safe — every script just sources the file.

## Dependencies

The skill targets macOS with Xcode and at least one iOS Simulator runtime installed. Beyond that:

| Dependency | Where from | Used by |
|---|---|---|
| Bash 3.2+ | `/bin/bash` (system) or Homebrew (`brew install bash`) | Every script's interpreter |
| `jq` | `/usr/bin/jq` (Apple-shipped on macOS) | `read_value.sh`, `verify_value.sh`, `verify_screen_loaded.sh`, `set_value.sh`, `tap_tab.sh` |
| `axe` | `brew install cameroncooke/axe/axe` | All verify-half scripts |
| `xcbeautify` | `brew install xcbeautify` | `build_app.sh`, `run_tests.sh` |
| `grep`, `awk`, `tr`, `sed` | macOS system | `find_id_in_source.sh`, `audit_view.sh`, `launch_app.sh` |
| `python3` | `/usr/bin/python3` (Apple-shipped on macOS 12.3+) or `brew install python@3.12` | `measure_tab_pill.sh` (only) |
| `Pillow` (Python `PIL` image library) | `python3 -m pip install --user --break-system-packages Pillow` *or* `brew install pillow` | `measure_tab_pill.sh` (only) |
| Xcode + simulator runtime | App Store or developer.apple.com | Build half + lifecycle |

**Pillow is a Python library** (a maintained fork of the original PIL — Python Imaging Library), not a Mac system component. Two install paths:

- **pip into whichever Python 3 your `python3` resolves to** (recommended): `python3 -m pip install --user --break-system-packages Pillow`. The `--break-system-packages` flag is required on macOS 12.3+'s system Python because Apple marks it as externally managed; on a Homebrew Python the flag is harmless.
- **Homebrew formula**: `brew install pillow` installs Pillow into Homebrew's bundled Python and pulls in image-codec dependencies (`jpeg-turbo`, `libavif`, etc.). Heavier than pip but integrated with the rest of the Homebrew toolchain you're already using for `axe` and `xcbeautify`.

`measure_tab_pill.sh` is the only script that needs Pillow; if it's missing, the script prints the pip install command and exits 4 — every other verify op continues to work without it. The skill validates Pillow's presence via `python3 -c 'import PIL'` at runtime, so whichever install path lands a working `import PIL` is fine.

### Shell compatibility (shebang vs. interactive shell)

Every script's first line is `#!/usr/bin/env bash`, which tells the OS to interpret the file with bash regardless of the user's interactive shell. macOS has shipped zsh as the default *interactive* shell since Catalina (2019), but `/bin/bash` is still present on every Mac for script compatibility — Apple kept it precisely so existing scripts don't break. So whether your login shell is bash, zsh, fish, or something else, the scripts run unchanged.

The scripts are written to bash 3.2 compatibility (no `mapfile`, no `${var,,}` lowercasing, no associative arrays, no `wait -n`, no other bash-4+ features), so they work on either the system `/bin/bash` (3.2.57, frozen since 2014 over GPL3 concerns) or a Homebrew bash 5+. `#!/usr/bin/env bash` resolves to whichever bash is first on PATH at script-run time. If Apple ever removes `/bin/bash` outright, `brew install bash` is the one-time mitigation; the scripts themselves don't change.

## Resolving the script path

Throughout this document, **`<scripts>/`** is shorthand for the resolved on-disk path to the skill's `scripts/` directory. The path varies by install shape:

**Plugin-marketplace install (canonical for v0.2.1+).** Installed via `claude plugin install ios-build-verify@<marketplace>`. Creates two on-disk locations, both containing equivalent copies of `scripts/`:

- **Cache** (versioned; the path recorded as `installPath` in `~/.claude/plugins/installed_plugins.json`): `~/.claude/plugins/cache/<marketplace>/ios-build-verify/<version>/skills/ios-build-verify/scripts/`. The `<version>` segment matches `version` in this skill's `.claude-plugin/plugin.json` and rotates on every release bump, so a hardcoded literal will rot. Refreshed by `claude plugin update`.
- **Marketplace clone** (unversioned, git working copy): `~/.claude/plugins/marketplaces/<marketplace>/skills/ios-build-verify/scripts/`. Stable path across version bumps; refreshed by `claude plugin marketplace update`.

Either path's `build_app.sh` works for invocation. The discovery one-liner below finds whichever the filesystem returns first; for routine use that's fine, since the two copies stay in sync after a normal `marketplace update` + `plugin update` flow.

**Manual install.** Skill checked out and placed under `~/.claude/skills/ios-build-verify/`. Resolves to `~/.claude/skills/ios-build-verify/scripts/` — stable across versions, but only applies when the consumer manages installation by hand rather than through the marketplace.

**Discovery (one-liner, install-shape-agnostic).** When in doubt about which path applies on the current machine:

```bash
find ~/.claude -path '*ios-build-verify*' -name build_app.sh 2>/dev/null | head -1
```

For repeated invocation in a session, export `IBV_SCRIPTS` once:

```bash
export IBV_SCRIPTS=$(dirname "$(find ~/.claude -path '*ios-build-verify*' -name build_app.sh 2>/dev/null | head -1)")
"$IBV_SCRIPTS/build_app.sh"
```

**For agents reading this document:** when you see `<scripts>/build_app.sh` in an example below, substitute the resolved path. The `find` one-liner above is the safe step when uncertain. A consumer project's `CLAUDE.md` should disclose its install shape so subsequent sessions don't need to rediscover.

## First-use setup

Each project needs its own per-project config (`<project>/.claude/ios-build-verify.config.sh`). The skill ships a colloquy that collects the answers and writes the file via `scripts/setup_project.sh`.

**Detection.** Before any build or verify op, check `<cwd>/.claude/ios-build-verify.config.sh`. If it exists, skip the colloquy and proceed. If it doesn't, run the colloquy below.

**Form: agent-led chat, not interactive shell.** `setup_project.sh` takes flags and never reads stdin — the agent asks the questions in chat, validates with the user, then invokes the script with the answers as flags. A `read -p`-style script would be harness-fragile: some Claude Code modes don't pass TTY to subprocesses cleanly.

**CLAUDE.md reconciliation.** If the project's `CLAUDE.md` documents a different build/test path (e.g., raw `xcodebuild` invocations), propose reconciling it as part of setup — typically by naming `build_app.sh` / `run_tests.sh` as the preferred path and demoting the existing commands to a diagnostic fallback. Otherwise future sessions may default to the documented commands and never exercise the skill.

### Step 0: Model self-check (do this before asking the colloquy questions)

**Before asking the seven core questions below, perform this check explicitly in your reply:**

1. State your own model name and version, drawn from your system prompt (e.g., "I am Claude Opus 4.7").
2. If you are **Claude Opus 4.7 or a more capable Anthropic model**, proceed directly to the colloquy.
3. If you are **anything else** (Sonnet, Haiku, a non-Anthropic model, an unknown model, or a model whose identity you cannot verify), **stop and warn the user** before proceeding. The warning must:
   - Name your model and harness explicitly.
   - State that this skill's use has only been validated on Claude Code (CLI) + Claude Opus 4.7. The shell scripts are harness-agnostic, but agent-judgment-driven flows (reading SKILL.md after `set_value.sh` exit 6, applying the documented Form-in-NavigationStack workaround, the colloquy itself) may degrade.
   - Ask the user to confirm they want to proceed against an untested configuration.

The harness check (`setup_project.sh`'s `CLAUDECODE` warning) handles the script-side half; this step is the agent-side half. Both fire warnings, not refusals — adopters opting in to an untested configuration may have legitimate reasons.

### Seven core questions (ask in order)

1. **App display name** (e.g., `AztecCal`).
2. **Bundle identifier** (e.g., `biz.joshadams.AztecCal`).
3. **Xcode project file**, relative to project root (e.g., `AztecCal.xcodeproj`). If exactly one `*.xcodeproj` is in `<cwd>`, omit the `--project` flag and `setup_project.sh` auto-detects.
4. **Xcode scheme** (e.g., `AztecCal`). Default to the app display name if the user is unsure.
5. **Target simulator** (e.g., `iPhone 17`). When the device exists under multiple iOS runtimes, `launch_app.sh` resolves to the latest match.
6. **First-screen accessibility identifier** (e.g., `input_convert_month`). The element `launch_app.sh` polls `axe describe-ui` for to confirm the app rendered. Should be present on launch, unique, stable across builds. Mention to the user: the wait-for-render budget defaults to 10 seconds (stored as `WAIT_FOR_RENDER_BUDGET_S` in the config) and is tunable in the file later without re-running the colloquy. Greenfield fallback: if no element on the launch screen carries an `.accessibilityIdentifier` yet, suggest adding one to a stable **leaf** element (the app's title `Text`, a fixed header `Image`) — *not* a root `VStack`/`ZStack` container; SwiftUI rolls a parent's identifier over every descendant in the AXTree (see "Identifier rollup" below). If the launch screen genuinely has no stable leaf, add a hidden anchor `Text("")` rather than landing the identifier on the root. Or accept a placeholder and update the config later — the identifier just needs to exist by the time `launch_app.sh` runs.
7. **Main tabs, in order** (e.g., `convert info settings`). Names you'll use to tap tabs via `tap_tab.sh`. Order must match how the tabs render in the app's TabView — first-rendered tab is index 0. The script validates the count against `data/coordinates.json` for `TARGET_SIM` and warns on mismatch. Apps without a TabView can leave `MAIN_TABS` empty by passing `--main-tabs ""` (or omitting the flag entirely); `setup_project.sh` writes `MAIN_TABS=()` and skips the count-vs-coords warning. `tap_tab.sh` then exits cleanly with a "no tabs configured for this project" error (exit 2) if invoked — no surprises later.
8. **Tab coordinates, in order** (optional; e.g., `115,822 287,822` for a 2-tab app). Per-project pixel centers when the app has a non-3-tab pill or any other non-default geometry. Best path: skip this question at colloquy time, write the config without coords, then run `calibrate.sh` (see below) for automated end-to-end measurement. Manual fallback: `screenshot.sh tabbar-precheck`, open the PNG at 100% (the inline downsampled view loses ~10pt of precision), measure each tab icon's visual center in pixels, divide by the simulator's retina scale (3× for iPhone 17 / Pro), pass via `--main-tabs-coords "x1,y1 x2,y2 ..."`. Omit for canonical 3-tab apps on shipped device entries — `tap_tab.sh` falls back to `data/coordinates.json` defaults. Per-project values take precedence; editing the shared data file affects every project on this machine using `TARGET_SIM`, so prefer the per-project route when calibration differs.
9. **Onboarding dismiss label** (optional; e.g., `Skip`, `Continue`, `Get Started`). The AXLabel of the button that dismisses the app's first-launch onboarding view, if any. When set, `launch_app.sh`'s wait-for-render loop interleaves a check for this label and taps it once if present, so the launch path works on a fresh simulator without manual intervention. Pass via `--onboarding-dismiss-label "Skip"`. Omit when the app has no onboarding view (the field stays empty in the config; the launch path skips the interleave). The label must match the rendered glyph exactly — pass `Get Started`, not `get-started`. The standalone `dismiss_onboarding.sh` reads the same field for direct invocation against non-launch-time onboarding (e.g., a "what's new" sheet after a version bump).

**Adopter-side ergonomics.** For any value with a *deterministic project-file source*, prefer introspection over asking the user — the user can accept a wrong proposed default (May 2026 Calculator3 incident: user said `com.joshadams.Calculator`; pbxproj said `biz.joshadams.Calculator`; `launch_app.sh` failed two turns later). For other values, ask the user.

| Value | Source | Mechanism |
|---|---|---|
| `BUNDLE_ID` | `PRODUCT_BUNDLE_IDENTIFIER` in pbxproj | `grep -m1 PRODUCT_BUNDLE_IDENTIFIER <project>.xcodeproj/project.pbxproj \| awk -F'= ' '{print $2}' \| tr -d ' ;'` |
| `SCHEME` | Xcode's scheme list | `xcodebuild -list -project <project>.xcodeproj -json \| jq -r '.project.schemes[]'`. If exactly one scheme, use it silently; if more than one (common when the project includes a widget extension, watch app, or test-host scheme), list them all and ask the user. **Do not guess** — "first in the list" or "matches APP_NAME" both fail on common configurations (extensions named differently, schemes ordered alphabetically). |
| `PROJECT` | `*.xcodeproj` glob | Already auto-detected by `setup_project.sh` when exactly one matches; ask the user when multiple |
| `APP_NAME` | n/a | Ask the user (display name; not pinned to any deterministic source) |
| `TARGET_SIM` | n/a | Ask the user (machine-specific preference) |
| `FIRST_SCREEN_ID` | n/a | Ask the user, or accept a placeholder (per Q6 fallback) |

For `BUNDLE_ID` and `SCHEME`, propose the introspected value as a default and surface it for confirmation; for everything else, ask. Even cheap-to-introspect values can fail if the user has a non-canonical project layout, so the proposal is still confirmable rather than silent.

### Three gitignore questions (each yes/no, with default)

- `build.log` → `.gitignore`? *(default yes — large, rebuilt every run)*
- `.claude/ios-build-verify.*` → `.gitignore`? *(default yes — config may carry developer-specific paths)*
- `docs/screenshots/` → `.gitignore`? *(default **no** — screenshots are durable verification artifacts; ignore only if repo size matters more than artifact value)*

If the project isn't a git repository (no `.git` directory), skip these questions entirely and pass none of the `--gitignore-*` flags — `setup_project.sh` only updates `.gitignore` when at least one is set, so omission is safe.

### Invocation

Compose a single call with the user's answers:

```bash
<scripts>/setup_project.sh \
  --app-name "AztecCal" --bundle-id "biz.joshadams.AztecCal" \
  --project "AztecCal.xcodeproj" --scheme "AztecCal" \
  --target-sim "iPhone 17" --first-screen-id "input_convert_month" \
  --main-tabs "convert info settings" \
  --main-tabs-coords "115,822 201,822 287,822" \
  --gitignore-build-log --gitignore-config
  # --gitignore-screenshots  # default: don't add — screenshots are durable verification artifacts
  # --main-tabs-coords        # optional; omit when canonical 3-tab geometry on shipped devices
```

The script writes `<cwd>/.claude/ios-build-verify.config.sh`, optionally updates `<cwd>/.gitignore` under a `# ios-build-verify` header (idempotent), and runs `find_id_in_source.sh` on `FIRST_SCREEN_ID` as a post-write source-existence check. The source check is informational: a miss surfaces a warning (the identifier may not exist yet, or may use an interpolation form the heuristic doesn't catch) but does not fail the setup.

After success, summarize what was written (config path, gitignore changes, any warnings) for the user.

### Existing-config branch

If the per-project config already exists, the script exits non-zero with a unified diff between the current file and the would-be config. Surface the diff to the user, ask whether to overwrite, and re-run with `--force` if so — unless the user has already explicitly authorized the change in their request, in which case proceed without re-asking. Per-field edits are out of scope for v1 — refuse-show-diff-optionally-force is the simplest correct shape.

**`--force` rewrites the entire config from passed flags.** Absent flags revert to script defaults rather than preserving existing values. Re-pass every flag from the previous run to avoid surprise drift in fields you didn't intend to change.

Exit codes for `setup_project.sh`: `0` setup complete; `2` invalid or missing required input; `3` config already exists and `--force` not passed.

## Setup calibration

After `setup_project.sh` writes the config, the agent should immediately run `calibrate.sh` to give the adopter end-to-end proof the skill works in their app — not just proof the config file was written. Calibration composes build + launch + measure + (optional) per-tab tap-and-verify into one command.

```bash
<scripts>/calibrate.sh                                                    # build, launch, measure tab pill, write coords
<scripts>/calibrate.sh --tab-anchors "input_a text_b card_c"              # plus tap-and-verify each tab against its anchor
<scripts>/calibrate.sh --skip-build                                       # already built; just re-measure / re-verify
```

Steps the script runs in order: `build_app.sh` (filtered through the recommended grep), `launch_app.sh` (which auto-dismisses onboarding when configured), `measure_tab_pill.sh` (centroid-detection on a fresh screenshot), in-place rewrite of the `MAIN_TABS_COORDS=` line in `<project>/.claude/ios-build-verify.config.sh`, and (when `--tab-anchors` is passed) `tap_tab.sh <name> --verify-anchor <id>` for each tab.

**Why this is the v2 banner feature.** The skill's value is unproven at the end of a setup colloquy — the config is just text on disk. Calibration is the difference between "the config was written" and "the skill demonstrably drives the app on this machine." Adopters bringing the skill to a first-time project should run calibrate as the *next* step after setup, before any feature work, so any calibration-class friction surfaces in a self-contained one-shot rather than mid-feature.

**`--tab-anchors` is optional but strongly recommended.** Without it, calibration measures the pill but never confirms each tab actually loads the right screen on tap. With it, you end the calibration with a green light on every tab. Since the agent is asking about tab anchors anyway during the migration-by-use annotation pass, surfacing them here is cheap.

**`calibrate.sh` rewrites `<project>/.claude/ios-build-verify.config.sh` in place** (the `MAIN_TABS_COORDS=` line specifically, via an `awk` substitution). An agent that pre-`Read` the config file and then tries to `Edit` it post-calibration will hit Claude Code's stale-read protection (`File has been modified since read`) and need to re-`Read` before editing. Either re-`Read` after every calibrate, or read fields from the config in-process by sourcing it (`source .claude/ios-build-verify.config.sh; echo "$MAIN_TABS_COORDS"`) rather than holding a stale `Read` snapshot.

**Validate-before-write on count mismatch.** When `measure_tab_pill.sh` exits 5 (detected tab count differs from `MAIN_TABS`), `calibrate.sh` propagates exit 5 and does **not** modify the config. The detected coords line is still printed on stdout for the agent to inspect, but corrupting the config with wrong-shape coords would silently mis-tap on every subsequent `tap_tab.sh` invocation; failing loud is the safer default. Try a fresh screenshot with the first tab selected, or pass `--y-band-lo/--y-band-hi/--min-gap-px` overrides to `measure_tab_pill.sh` directly.

Exit codes: `0` calibration successful; `2` config missing, bad arg, or no TabView; `3` `measure_tab_pill.sh` did not emit a coords line; `5` count mismatch (config NOT modified — manual review needed); `6` one or more `--tab-anchors` failed to verify; non-zero propagated from any other composed step (build, launch, measure).

## Build operations

### `scripts/build_app.sh`

Builds the configured Xcode project for the configured simulator. Pipes `xcodebuild` output through `xcbeautify` for concise summary output; mirrors raw output to `build.log` (in cwd) as a lossy-filter fallback. Invoke from the project root:

```bash
<scripts>/build_app.sh
```

Exit code is propagated from `xcodebuild` via `set -o pipefail`. On failure, `xcbeautify`'s output surfaces `file:line:col: error:` anchors; if those are insufficient, fall back to `grep -B2 -A20 'error:' build.log` for the raw diagnostic. Deepest fallback (rare): `xcrun xcresulttool get --path ./Build/.../Test-*.xcresult --format json`.

When piping `build_app.sh` output to a filter, prefer `grep -E "(Compiling|Build Succeeded|error:)"` over `tail -N` — `tail` drops the per-file `[Compiling X.swift]` lines that confirm a recompile happened, while `grep` keeps them.

**Trust `build_app.sh` over SourceKit diagnostics.** In any sufficiently large SwiftUI project, edits to a view file routinely trigger SourceKit (LSP) diagnostics like `Cannot find 'X' in scope`, `Cannot find type 'Y' in scope`, or `Type 'any Z' has no member 'foo'` — even when the symbols resolve correctly under `xcodebuild`. SourceKit reads files in isolation; it cannot resolve same-module symbols (other types, enums, top-level functions, extension methods) that the actual compiler sees. If `build_app.sh` succeeds, the build is authoritative; do not "fix" the SourceKit-only diagnostics. May 2026 Konjugieren onboarding burned ~10 false-positive diagnostics per edit cycle on a brownfield app until this was named explicitly.

### `scripts/run_tests.sh`

Runs `xcodebuild test` with xcbeautify formatting, parallel testing disabled (`-parallel-testing-enabled NO` to avoid simulator flakiness under Swift Testing), raw log tee'd to `build.log`, and a Swift Testing parameterized-test summary surfaced from `build.log` after xcbeautify completes. Prefer over raw `xcodebuild test` for both build and verify cycles — xcbeautify's filter collapses parameterized-test output to a single suite-pass line, and the post-process restores per-`@Test`-function visibility without reintroducing the raw stream's noise.

Optional `--only-testing <Target/Suite/method()>` filters to a single suite or method (chainable: pass multiple `--only-testing` flags to run multiple targeted tests). Each value is forwarded as a separate `-only-testing:` arg to `xcodebuild`. Use the Swift Testing form `Target/Suite/method()` — note the trailing `()` on method names; omitting it causes xcodebuild to silently run zero tests.

```bash
<scripts>/run_tests.sh
<scripts>/run_tests.sh --only-testing AztecCalTests/ConverterTests           # whole suite
<scripts>/run_tests.sh --only-testing AztecCalTests/ConverterTests/convert\(\)  # single method
```

Suite-level form omits the trailing `/method()`; method-level form requires the trailing `()`. Both work; use whichever scopes match what you're iterating on.

Exit code propagates from `xcodebuild`. The parameterized-summary post-process recognizes both display-named (`Test "Display Name" with N test cases`) and unnamed (`Test funcName(arg:) ... with N arguments`) summary forms. When no parameterized lines match, the script still surfaces the `Test run with N tests in M suites` line so the agent gets a count xcbeautify would otherwise collapse.

## Verify operations

The verify half wraps `xcrun simctl` (lifecycle: boot, install, launch, terminate) and AXe (drive: tap, type, swipe; observe: describe-ui, screenshot) behind named operations: lifecycle, the cheapest observation primitive (`describe-ui`), the three tap selectors (`--id`, `--label`, `-x -y`), the tab-bar coordinate wrapper, `screenshot`, the named-intent ops (`read_value`, `verify_value`, `verify_segment`, `verify_screen_loaded`, `verify_label_visible`, `set_value`, `type_text`), and the annotation-check phase (`find_id_in_source`, `audit_view`). The lab project's `docs/EDD_PRD.md` carries the full design.

**Screenshot before AND after UI changes.** For any code change that affects rendered layout, color, typography, or spacing, capture screenshots via `screenshot.sh` both before the edit and after — even if `describe-ui`-based assertions pass. The May 1 Calculator validation found three distinct bug classes (bordered-button frame collapse, iOS 26 floating-tab-pill location, hue confirmation) where the AXTree reported green but the rendered UI was wrong. Screenshots are not a fallback to AXTree — they are a different verification surface that catches a different class of bugs. The before-shot makes the diff an explicit artifact (not just a memory of "what it looked like a moment ago"), and is cheap insurance against the case where the layout changed in a way you didn't expect: a regressed neighboring view, an unintended layout shift, a screen that looks identical to memory but differs in detail.

### Coordinate space: logical points, not pixels

`axe tap`, `axe swipe`, and `axe describe-ui` consume **logical points**, not pixels. `xcrun simctl io <UDID> screenshot <path>` writes a PNG in **pixels** at the device's native scale (3× on iPhone 17 / 17 Pro / 17 Plus). Mixing them produces taps that land far off-screen and look like silent failures — the May 5 2026 Konjugieren UI-audit validation hit this when an agent screenshotted a "Dismiss" button at pixel `(1024, 184)`, called `axe tap -x 1024 -y 184`, and tapped well off the visible viewport (which on iPhone 17 is roughly 393 × 852 points).

When a candidate coordinate is already in hand (e.g., measured off a screenshot), divide the pixel coordinate by the device's scale factor to recover logical points, then pass the result to `describe_ui.sh --point <x>,<y>` to confirm what element sits there. The returned `AXFrame` is already in logical points; tap `(frame.x + frame.w/2, frame.y + frame.h/2)`.

When only an `AXLabel` is in hand, walk the full describe-ui tree for a node whose label matches and read its `frame`:

```bash
axe describe-ui --udid "$UDID" | python3 -c "
import json, sys
data = json.load(sys.stdin)
def walk(node):
    if isinstance(node, dict):
        if node.get('AXLabel') == 'Dismiss' and node.get('type') == 'Button':
            print(node.get('frame'))
        for v in node.values(): walk(v)
    elif isinstance(node, list):
        for v in node: walk(v)
walk(data)
"
```

### Key dispatch

`axe key <keycode>` takes a **positional** keycode argument, not a `--keycode` flag (`axe key --keycode 40` errors with "Unknown option `--keycode`"). The codes are HID usage codes: `40` = return, `42` = backspace, `41` = escape, `43` = tab. For modifier-key combinations, use `axe key-combo --modifiers <mask> --key <code>` instead — `set_value.sh` calls `axe key-combo --modifiers 227 --key 4` to send Cmd+A as its select-all-then-replace primitive, and the non-ASCII typing path (below) calls `axe key-combo --modifiers 227 --key 25` for Cmd+V.

**`axe type` is ASCII-only; non-ASCII text uses a pasteboard fallback.** `axe type` converts text to USB HID keyboard events via a fixed US-layout keycode table, so it supports only A-Z a-z 0-9 and ASCII symbols and **rejects** anything else (accented letters `éñü`, currency `£€¥`, CJK, emoji) up front with `unsupportedCharacter` — it never types a partial string, and `--stdin`/`--file` don't help (same validator). The AXe author documents this as an intentional HID-protocol limitation, not a bug, and there is no upstream fix (repo researched May 2026, no matching issue). The skill works around it in `_type_text.sh`: `type_into_focused_field` detects any non-ASCII byte and, for those strings, stages the text on the target simulator's pasteboard (`xcrun simctl pbcopy <udid>`) and pastes with Cmd+V instead of typing. Paste bypasses HID entirely and inserts the string literally (also dodging the smart-quote/smart-dash substitution the typed path is subject to). Pure-ASCII text keeps the original `axe type` path unchanged. Both `set_value.sh` and `type_text.sh --xy` route through this helper, so accented input (Konjugieren's quiz: `parlé`, `réussî`, …) now works through the normal named ops.

### `scripts/launch_app.sh`

Takes a fresh build to a launched, observable app. Resolves the target simulator by name (config: `TARGET_SIM`), preferring the latest-runtime match; boots if needed and waits for full boot via `simctl bootstatus -b`; resolves the `.app` path via `xcodebuild -showBuildSettings`; **terminates any running instance of `BUNDLE_ID` before installing** (rules out stale-process serving pre-edit UI after a rebuild — the May 1 Calculator validation observed this exact incident); installs and launches by bundle identifier; polls `axe describe-ui` until `FIRST_SCREEN_ID` appears (budget `WAIT_FOR_RENDER_BUDGET_S`). Invoke from project root after `build_app.sh`:

```bash
<scripts>/launch_app.sh
<scripts>/launch_app.sh --reuse-install   # skip terminate (warm cache)
```

`--reuse-install` skips the pre-launch terminate. The default behavior pays a ~1s cost per launch in exchange for a freshness guarantee; use the flag only when warm-cache reuse is intentional.

Exit codes: `0` on launch + render confirmed; `2` config missing; `3` `TARGET_SIM` not found; `4` `.app` missing in DerivedData (tells you to run `build_app.sh` first); `5` `FIRST_SCREEN_ID` never appeared in `describe-ui` within the budget (when `ONBOARDING_DISMISS_LABEL` is configured but the label was also never seen, the error message says so explicitly).

**Onboarding-dismiss interleave.** When `ONBOARDING_DISMISS_LABEL` is set in the per-project config, the wait-for-render loop interleaves a check for that label and taps it once if present, then continues polling for `FIRST_SCREEN_ID`. This handles the canonical first-launch onboarding view (a `Skip` / `Continue` / `Get Started` button gating the launch screen on a fresh simulator) without manual intervention. The check is per-launch, idempotent (the label leaves the tree once tapped), and a no-op when the label isn't present (subsequent launches after the "seen" flag persists). For non-launch-time onboarding (a "what's new" sheet shown after a version bump, a feature-discovery overlay), invoke `dismiss_onboarding.sh` directly — see below.

### `scripts/dismiss_onboarding.sh`

Tap the first-launch onboarding dismiss button (Skip / Continue / Get Started) by AXLabel. With no argument, uses `ONBOARDING_DISMISS_LABEL` from the per-project config. Idempotent: when the labeled element isn't in the current AXTree (already-dismissed onboarding, no onboarding view), exits 0 without tapping.

```bash
<scripts>/dismiss_onboarding.sh           # uses config's ONBOARDING_DISMISS_LABEL
<scripts>/dismiss_onboarding.sh "Skip"    # one-off override (e.g., for a "what's new" sheet)
```

The script is also called automatically inside `launch_app.sh`'s wait-for-render loop when `ONBOARDING_DISMISS_LABEL` is set; direct invocation is for non-launch-time onboarding (a version-bump "what's new" sheet, a feature-discovery overlay shown mid-session).

Exit codes: `0` dismissed or no-op (idempotent); `2` config missing or no label configured; `3` no booted simulator.

### `scripts/describe_ui.sh`

Thin wrapper over `axe describe-ui` for whichever simulator is currently booted. Emits the structured accessibility-tree dump on stdout; the agent pipes to `grep`/`jq` or `Read`s in full as needed.

```bash
<scripts>/describe_ui.sh | grep -A3 input_convert_month
<scripts>/describe_ui.sh --point 200,540    # per-point inspection
```

No-arg invocation returns the full tree (no subtree filtering). `--point x,y` describes the single element at the given logical-points coordinate (see "Per-point inspection" below). Exit codes: `0` on success; `2` config missing or malformed `--point` argument; `3` no booted simulator.

**Per-point inspection (`describe_ui.sh --point <x>,<y>`).** A second observation primitive worth knowing about, especially after the May 2026 GenericApp validation discovered it reaches elements the regular tree misses. The full-tree call dumps the AXTree as enumerated by AXe — but composite controls subject to the iOS 26 children-not-enumerated bug (TabView, segmented/menu/palette `Picker`, popover overlays) appear as a single root element with `children: []`, so their interior elements (tab buttons, picker segments, popover options) are invisible to full-tree traversal. `describe_ui.sh --point <x>,<y>` queries the element under the given screen coordinate directly (UDID resolution is internal), returning its `AXLabel`, `AXValue`, `role`, `subrole`, and `AXFrame` even when the regular tree hides it. For segmented Pickers, `--point` aimed at a segment center returns the segment's selected state (`AXValue: 1` for selected, `0` for unselected) — the canonical verify path documented in `verify_segment.sh` below. The same per-point primitive backs `tap_xy.sh --verify-target` (a guarded coordinate tap that pre-checks the AXLabel under the target point before dispatching) and `verify_segment.sh`'s segment-center lookup. Coordinates are logical points, not pixels.

### `scripts/terminate_app.sh`

`simctl terminate` against the configured `BUNDLE_ID` on the booted simulator. Cheap clean state-reset between runs. Exit codes: `0` on success; `2` config missing; `3` no booted simulator.

### `scripts/tap_id.sh`

Tap the element matching `AXUniqueId`. Default selector path; cheapest, most stable, works for everything except the iOS 26 Tab bar.

```bash
<scripts>/tap_id.sh input_convert_month
```

Pre-flight: looks up the target's `AXFrame` and checks whether its y-center falls within the device's `floating_tab_pill_y_band` (per `data/coordinates.json`). On overlap, exits 7 with a "likely obscured by floating tab pill" warning and a pointer to the "Designing for verify ops" section's adaptive-list-height pattern. Catches the silent-miss-tap-on-the-pill class at the boundary instead of letting it propagate.

Exit codes: `0` on dispatch (note: dispatch ≠ behavioral effect; see below); `1` propagated from AXe when the identifier isn't found in the tree; `2` config missing or no argument; `3` no booted simulator; `7` resolved AXFrame y-center overlaps the floating tab pill (HID tap would land on the pill, not the target — fix the upstream layout).

### `scripts/tap_label.sh`

Tap the element matching `AXLabel`. Secondary selector when the identifier is unknown or unstable; useful during exploratory verification before the agent learns a codebase's identifier convention. Labels can collide more easily than identifiers (multiple "Settings" buttons across screens), so identifier-tap is the recommended default.

```bash
<scripts>/tap_label.sh "Month input"
<scripts>/tap_label.sh "÷"   # pass the rendered glyph, not the ASCII alternative
```

Pass the exact rendered glyph as the label argument — typographic operators (`÷ × −`, U+00F7 / U+00D7 / U+2212) are different characters from ASCII (`/ * -`) at the AXLabel layer. SwiftUI Buttons get an implicit AXLabel from their `Text` content, so whatever you put in `Text("÷")` is what `tap_label.sh` must match.

The same floating-tab-pill overlap pre-flight that `tap_id.sh` runs applies here (lookup is by AXLabel instead of AXUniqueId; same exit 7 on overlap).

Exit codes mirror `tap_id.sh`.

### `scripts/tap_xy.sh`

Tap raw coordinates (points, origin top-left). Fallback for the iOS 26 Tab bar and any other element the accessibility tree doesn't expose. Validates that both arguments are numeric (decimals allowed; AXe accepts subpixel coords).

```bash
<scripts>/tap_xy.sh 287 822
<scripts>/tap_xy.sh 200 540 --verify-target "Not Now"
```

Optional `--verify-target <expected-axlabel>` pre-queries the element under (x,y) via `describe_ui.sh --point` and refuses to tap unless the actual `AXLabel` matches. Catches the "off-by-pixel" failure mode where the gesture dispatches successfully but lands on the wrong element — the May 2026 Konjugieren audit-validation session hit this when an agent-estimated coordinate (200, 425) struck the "Enjoying Konjugieren?" heading `StaticText` instead of the "Not Now" `Button` two rows below; `tap_xy.sh` reported a successful gesture and the bug surfaced only at the next failed verify. Optional second flag `--verify-role <role>` disambiguates when the same AXLabel appears across roles (a `Button` and a `StaticText` both labeled "Done"); pass the role string exactly as `describe_ui.sh --point x,y` reports it. End-to-end gating-recovery composition: `screenshot.sh launch-fail` (capture the modal), `describe_ui.sh --point 200,540` (confirm the dismiss button is at this point), `tap_xy.sh 200 540 --verify-target "Not Now"` (guarded dispatch).

Exit codes: `0` on dispatch; `2` config missing or non-numeric input; `3` no booted simulator; `8` `--verify-target` / `--verify-role` mismatch (no tap dispatched; the actual `AXLabel`, role, and `AXFrame` under the coordinate are written to stderr for diagnosis). **AXe is HID dispatch, not behavioral assertion** — `tap_xy.sh 5000 5000` exits 0 even though the tap lands off-screen, unless `--verify-target` is set to constrain dispatch by the pre-queried element. Verification of the tap's behavioral *effect* (post-tap state change) still composes with a follow-up `describe_ui.sh` regardless.

### `scripts/tap_tab.sh`

Tap a tab in the main TabView by name. Wraps the iOS 26 Tab-bar coordinate workaround so the agent doesn't have to know the bug exists. Resolves the tab name to an index via the per-project config's `MAIN_TABS` array, then chooses coordinates from one of two sources:

1. **`MAIN_TABS_COORDS`** in the per-project config (preferred when present). Per-project pixel centers; doesn't affect any other project on the machine.
2. **`data/coordinates.json`** under the skill (default fallback). Per-device default centers, useful for canonical 3-tab geometry on the shipped device entries.

```bash
<scripts>/tap_tab.sh settings
<scripts>/tap_tab.sh settings --verify-anchor card_settings_caso
```

Why two layers: tab *names* are app-specific (`convert/info/settings` for AztecCal; `home/profile/settings` for another app), tab *positions* depend on **both** device geometry and tab count (a 2-tab pill is much narrower than a 3-tab pill on the same iPhone 17). Names live in the per-project config. Positions belong with names when the app's pill differs from the canonical 3-tab default, and only then; otherwise the shared default file works.

A preflight check refuses with exit 4 when the chosen coord source's count doesn't match `len(MAIN_TABS)`. The error message points at SKILL.md's iOS 26 Tab-bar section for recalibration steps and recommends `MAIN_TABS_COORDS` over hand-editing the shared data file (which has cross-project blast radius).

Optional `--verify-anchor <accessibility-identifier>` adds a post-tap render check: poll `describe-ui` for the named element to appear within `WAIT_FOR_RENDER_BUDGET_S` (the same budget `verify_screen_loaded.sh` uses). On success, prints `rendered: <id>` and exits 0; on timeout, exits 5. Without the flag, behavior is unchanged (dispatch only — see the AXe HID-dispatch caveat under `tap_xy.sh`). Tab transitions typically complete in 100–300ms, so the 10-second default budget is over-generous but not problematic; reusing the config's existing budget keeps the schema flat.

Uses `jq` to read `data/coordinates.json` only when `MAIN_TABS_COORDS` is unset (Apple ships `/usr/bin/jq` on macOS). Exit codes: `0` on dispatch (or anchor rendered, when `--verify-anchor` is set); `2` config missing, no argument, `MAIN_TABS` empty/undeclared (no-TabView app), or fallback coords data file missing; `3` no booted simulator; `4` `MAIN_TABS`-vs-`MAIN_TABS_COORDS` count mismatch, `MAIN_TABS`-vs-data-file count mismatch, tab name not in `MAIN_TABS`, malformed coord entry, or no coords for the resolved index on `TARGET_SIM`; `5` `--verify-anchor` did not appear within `WAIT_FOR_RENDER_BUDGET_S`.

### `scripts/swipe_page_tabview.sh`

Fail-fast diagnostic for the iOS 26 SwiftUI `TabView(.page)` gesture-injection wall (see "Common first-real-app friction" item 7). Runs a wide right-to-left horizontal swipe with extended duration, then `shasum`-fingerprints `axe describe-ui` before and after to detect whether the page actually advanced. On no change, exits 7 with a hint pointing at the friction-list workaround.

```bash
<scripts>/swipe_page_tabview.sh
<scripts>/swipe_page_tabview.sh --start-x 43 --end-x 350   # back swipe
```

Defaults are calibrated for iPhone 17's 393pt-wide viewport: `(350,425) → (43,425)` over 0.8s. Override via `--start-x` / `--start-y` / `--end-x` / `--end-y` / `--duration` for back swipes, vertical paged TabViews, or alternate viewports. The defaults are intentionally slow and wide — they're chosen to clear most page-coordinator velocity thresholds *when those thresholds are reachable at all*. The script's value is in the failure path (classifying the no-op silent rejection), not the swipe parameters; if defaults don't advance the page, alternate parameters won't either.

Exit codes: `0` AXTree changed after swipe (page likely advanced — verify with `verify_label_visible.sh` against an expected per-page label if the destination is known); `2` config missing or malformed argument; `3` no booted simulator; `7` AXTree unchanged (the gesture-injection wall — see SKILL.md "Common first-real-app friction" item 7).

### `scripts/screenshot.sh`

`axe screenshot` writing to `<project>/docs/screenshots/<timestamp>-<context>.png`. Echoes the absolute path of the written file on stdout for the agent to capture as a file reference (per the EDD's token-conservation strategy: screenshots as file references, not embedded payloads). Creates `docs/screenshots/` on demand (`mkdir -p`).

```bash
SHOT=$(<scripts>/screenshot.sh settings-tab-after-correlation-change)
# $SHOT now holds the absolute path. Read the PNG only when visual verification is actually required.
```

The argument is a context slug, not a path; the script generates the output path internally. Path-shaped arguments (containing `/` or ending in `.png`) are refused with exit 2 and a hint pointing at `xcrun simctl io <UDID> screenshot <abs-path>` for the rare case where a custom output path is actually wanted. The May 5 2026 Konjugieren UI-audit validation hit the unguarded form: `screenshot.sh docs/screenshots/onboarding-2.png` was accepted as a slug and produced a nested `docs/screenshots/<timestamp>-docs/screenshots/onboarding-2.png.png`, after which the agent abandoned the wrapper for the rest of the session and bypassed skill-internal logging.

Timestamp is local-time (`%Y%m%d-%H%M%S`). Context slugs follow `lowercase-kebab-case` so they nest cleanly in `ls`-sorted output (lenient — not enforced by the script). Exit codes: `0` on success; `2` config missing, no argument, or path-shaped argument; `3` no booted simulator.

### `scripts/read_value.sh`

Read the `AXValue` of the element matching `<accessibility-identifier>` from the current `describe-ui`. Encapsulates the JSON-traversal logic (`AXValue` lives 15–20 lines deep in `describe-ui`'s per-element output) so the agent never grep-and-counts through nested JSON.

```bash
<scripts>/read_value.sh input_convert_month
# → "4"
```

Uses `jq`'s recursive descent (`.. | objects | select(.AXUniqueId? == $id)`) — works regardless of how deeply the element nests under VStacks, ScrollViews, TabViews. `.AXValue // ""` defaults missing-AXValue elements to empty string. Exit codes: `0` value found (printed on stdout); `2` config missing or no argument; `3` no booted simulator; `4` no element matches the identifier; `5` ambiguous — multiple elements match (the script refuses to silently pick one, since multiplicity usually signals an annotation bug worth surfacing).

On exit 4, the error message also enumerates the AXUniqueIds currently present in the tree and classifies the post-state when it can — see "Errors as state probes" above for the four classes (rollup, popover, SpringBoard/crash, unknown). The hint also recommends running `audit_view.sh` on the relevant view file to surface unannotated nearby elements. This is the cheapest path from "verification failed" to "I know which line of Swift to edit."

On exit 0 with empty stdout, the script also emits a hint when the element exists but exposes no `AXValue` (i.e., the SwiftUI declaration carries `.accessibilityIdentifier(...)` but no `.accessibilityValue(...)`, or wraps a `UIViewRepresentable` whose underlying UIKit view's `accessibilityValue` was never set). The hint branches on the two cases: SwiftUI-native (add `.accessibilityValue(...)` to the declaration) and `UIViewRepresentable` (set `accessibilityValue` on the wrapped view inside `updateUIView` — SwiftUI modifiers don't bridge through). This converts a confusing "I asked for the value and got an empty string" into a localized fix recipe in one command.

### `scripts/verify_value.sh`

Assert the `AXValue` of the element matching `<accessibility-identifier>` equals `<expected-value>`. Composes `read_value.sh` (single source of truth for the AXUniqueId lookup); strict string equality. On match, echoes the actual value on stdout — useful as a "read-with-assertion" op when the agent wants both observation and verification in one call.

```bash
<scripts>/verify_value.sh input_convert_month "7"
<scripts>/verify_value.sh --audit input_convert_month "7"
# → "7" on match (exit 0); "error: expected '7', got '4'." on mismatch (exit 6)
```

Optional `--audit` runs `find_id_in_source.sh` to locate the identifier, then `audit_view.sh` on each matched file before driving the verify. The audit output goes to stderr; the verify result goes to stdout. Cheap proactive nudge that pulls audit-view-shaped attention onto the verification path without changing default behavior.

Exit codes: `0` match; `2` config missing or fewer than two arguments; `3`/`4`/`5` propagated from `read_value.sh`; `6` value mismatch.

The `picker_settings_correlation` AXValue is a string `"Kirchhoff"`, not `"kirchhoff"` — verifications use whatever string the SwiftUI view binds (typically `displayName`, not `rawValue`). Future flows that need numeric or normalized comparison should normalize before calling; the script keeps strict equality so its contract stays deterministic.

### `scripts/verify_segment.sh`

Assert that a specific segment of a composite control (segmented `Picker`, `.palette` `Picker`) carries the expected `AXLabel` and is currently selected (`AXValue == 1`). Closes the verification gap for controls that the iOS 26 children-not-enumerated bug hides — `verify_value.sh` returns `null` against the parent's identifier, but `verify_segment.sh` reaches the segment directly via `axe describe-ui --point`.

**Not supported for `.menu` Picker.** The script's segmentation model assumes horizontal segments each carrying `AXValue: 1` (selected) or `0` (unselected); `.menu` renders as a single `AXPopUpButton` whose `AXValue` is the selected option's display string. For `.menu` Pickers, use `read_value.sh` against the Picker's identifier — when `.accessibilityValue(...)` is set on the SwiftUI Picker, the modifier propagates and `read_value.sh` returns the selected option's string directly. (May 2026 GenericApp + GenericApp2 validation: `verify_segment.sh` against `.menu` Pickers exits 6 with the full label including the title prefix, or 7 with the AXValue-as-string mismatching the expected `1`.)

```bash
<scripts>/verify_segment.sh picker_translate_direction 1 "Morse → English"
# → "segment 1 selected: 'Morse → English'"   on match (exit 0)
# → "error: segment 1 expected 'Morse → English', got 'English → Morse'."   on label mismatch (exit 6)
# → "error: segment 1 not selected (AXValue=0)."   on selection mismatch (exit 7)
```

Composition: reads the parent control's `AXFrame` from `describe-ui` (existence check propagates exits 4/5 from `read_value.sh`-style lookup); divides the frame's width into N equal-width segments where N is inferred from the control's child-count metadata or passed explicitly via `--segments N`; computes the requested segment's center; calls `axe describe-ui --point <x>,<y> --udid <UDID>` to fetch the segment record; asserts `AXLabel` matches `<expected-label>` (strict equality) and `AXValue == 1`.

The script doesn't drive selection — it only verifies. To *change* the selected segment, use `tap_xy.sh` at the same computed coordinate (or compose a future `tap_segment.sh` wrapper). The verify/drive split mirrors `read_value.sh` / `set_value.sh`.

Exit codes: `0` segment matches expected label and is selected; `2` config missing or fewer than three arguments; `3` no booted simulator; `4` parent control identifier not found in tree; `5` ambiguous parent identifier; `6` label mismatch; `7` segment not currently selected. Replaces the side-effect inference pattern (drive a downstream operation that depends on the selection and assert its output) the May 2026 GenericApp prompt-3 session was forced into.

### `scripts/verify_screen_loaded.sh`

Poll `describe-ui` until an anchor `<accessibility-identifier>` appears, with the same `WAIT_FOR_RENDER_BUDGET_S` budget `launch_app.sh` uses. The mid-flow standalone counterpart of `launch_app.sh`'s wait-for-render — for verifying tab transitions, modal presentations, sheet pushes, etc.

```bash
<scripts>/tap_tab.sh settings
<scripts>/verify_screen_loaded.sh card_settings_caso
```

Quick-path: the first `describe-ui` call runs before any `sleep`, so when the anchor is already on screen the op returns in one iteration (no built-in floor latency). Slow-path: poll-until-budget for genuine wait scenarios. Uses jq's recursive-descent count (same shape as `read_value.sh`) rather than a substring grep — robust against JSON-encoding edge cases. Exit codes: `0` rendered; `2` config missing or no argument; `3` no booted simulator; `5` anchor never appeared within `WAIT_FOR_RENDER_BUDGET_S`.

### `scripts/verify_label_visible.sh`

Single-shot assertion that an element with a given `AXLabel` is present in the current AXTree. The most generic presence probe — covers the "did Settings render?" / "did the modal dismiss?" / "did the toast appear?" cases that don't fit the more specialized verify ops (which key off `AXUniqueId`, value, or selection).

```bash
<scripts>/verify_label_visible.sh "Settings"
<scripts>/verify_label_visible.sh "Done" --role Button
```

`--role <role>` (matched against the `type` field `axe describe-ui` returns) disambiguates when the same label appears across roles — a `Button` and a `StaticText` both labeled "Done," say.

Use cases: after `tap_xy.sh` to confirm the screen actually changed (especially when the tap dispatch reported success but no `verify_*` op currently asserts the post-state); after `launch_app.sh` to confirm a screen-specific label rendered when `FIRST_SCREEN_ID` is too generic to distinguish post-launch from a deep-nav state; inside audit-driving loops that need a single-step "is this here?" probe without composing `axe describe-ui | grep` ad hoc. No polling — for wait-for-render semantics, key off `AXUniqueId` and use `verify_screen_loaded.sh`.

Exit codes: `0` label present; `2` config missing, no argument, or malformed `--role`; `3` no booted simulator; `4` label not present in AXTree.

### `scripts/set_value.sh`

Focus a TextField and replace its contents with `<text>`. Resolves the "AXe `type` appends, doesn't replace" surface — the named-intent layer's job is to make "set this field to X" do what its name says.

```bash
<scripts>/set_value.sh input_convert_month "7"
# → "set: input_convert_month = '7'"           on success (exit 0)
# → "error: set ... failed read-back: ..."     on no-op write (exit 6)
```

Composition: validates the identifier via `read_value.sh` (existence + uniqueness; propagates exits 3/4/5); focuses the field via `tap_id.sh`; sends Cmd+A (`axe key-combo --modifiers 227 --key 4`) to select all existing text; sends `axe type "$TEXT"` to replace the selection; **reads the AXValue back and compares to `$TEXT`**. The read-back loop catches silent no-op writes (the canonical case is Toggles inside Form inside NavigationStack on iOS 26 — see "iOS 26 Form-in-NavigationStack" below) where HID dispatch reports success but the widget's bound state didn't change.

The Cmd+A approach is constant-time regardless of existing field length (no per-character backspace loop) and works on `.numberPad` TextFields as well as standard ones — verified empirically against AztecCal's `input_convert_month` (`"49"` → `"7"` in two HID dispatches).

Exit codes: `0` write confirmed (AXValue read back equals `$TEXT`); `2` config missing or fewer than two arguments; `3`/`4`/`5` propagated from `read_value.sh`; `6` write read-back mismatch (HID dispatch returned but the value didn't land — diagnose: Toggle or Picker in Form in NavStack on iOS 26, TextField/TextEditor input filter mutating typed string (smart dashes, smart quotes, autocapitalization), or element with no exposed AXValue); `7` propagated from `tap_id.sh` when the target overlaps the floating tab pill. The exit-6 stderr hint enumerates the four causes in detail with a SwiftUI-native vs. UIViewRepresentable branch for the no-AXValue case.

### `scripts/type_text.sh`

Type text into a `TextField` / `TextEditor` regardless of whether the field has an `.accessibilityIdentifier()`. Two modes:

```bash
<scripts>/type_text.sh --id input_convert_month "7"
<scripts>/type_text.sh --xy 196,512 "wrong-answer"
<scripts>/type_text.sh --xy 196,512 --verify-target "Answer" --verify-role TextField "wrong-answer"
```

`--id` is a thin alias for `set_value.sh` — focuses by identifier, clears via Cmd+A, types, and read-back-verifies. Use when the field has an identifier; this path inherits all of `set_value.sh`'s exit codes (including exit 6 read-back mismatch with the four-cause hint).

`--xy` is for fields with no identifier — common on screens whose `TextField` carries `.focused`/`.accessibilityFocused`/`.accessibilityHint` modifiers but no `.accessibilityIdentifier()`. The May 5 2026 Konjugieren UI-audit validation hit this exact shape on `QuizView.swift`'s answer field and surfaced two gaps: (1) `xcrun simctl io <UDID> type "..."` is **not a real subcommand** (silent no-op); the underlying primitive is `axe type "$TEXT" --udid "$UDID"`, which `type_text.sh` mechanizes; (2) without an identifier there is no read-back path, so the script taps to focus, clears, types, and exits 0 with a "no read-back verification" message — the caller is expected to assert post-state via `verify_label_visible.sh`, a screenshot, or another follow-up observation.

Optional `--verify-target <axlabel>` (and `--verify-role <role>`) are threaded through `tap_xy.sh` — the focus tap inherits the same AXLabel/role guard, so coordinate-driven typing won't fire if the coordinate doesn't actually land on the expected element. `--verify-role TextField` is the typical guard for unidentified text fields.

**Non-ASCII text (accented/Unicode) is handled automatically.** Both modes route typing through `_type_text.sh`'s `type_into_focused_field`, which sends ASCII via `axe type` and anything containing a non-ASCII byte (accented letters, currency, CJK, emoji) via the `simctl pbcopy` + Cmd+V pasteboard fallback — see "Key dispatch → `axe type` is ASCII-only" for the why. This is what makes Konjugieren's accented-conjugation quiz (`parlé`, `réussî`, …) drivable; before the fallback, `axe type` rejected those strings outright with `unsupportedCharacter`. No caller change is needed — pass the accented string as `<text>` and the right path is chosen by content. In `--id` mode the read-back still verifies the value landed; paste inserts literally, so accented strings read back exactly (no smart-punctuation drift).

The `axe type "$TEXT"` primitive is also usable directly (e.g., to type without a prior focus tap, when the field is already focused and the keyboard is up) — but it is ASCII-only; for arbitrary text call `type_into_focused_field "$UDID" "$TEXT"` after sourcing `_type_text.sh`, or just use `type_text.sh`. Surfaced here once so the agent doesn't have to read `set_value.sh`'s source to discover it.

Exit codes: in `--id` mode, all of `set_value.sh`'s codes are propagated. In `--xy` mode: `0` typed (no read-back); `2` config missing, malformed args, or `--verify-target`/`--verify-role` passed in `--id` mode; `3` no booted simulator; `8` `--verify-target`/`--verify-role` mismatch (no tap dispatched, no typing).

### `scripts/smoke_test.sh`

End-to-end first-real-app smoke test: `build_app.sh` → `launch_app.sh` → `screenshot.sh smoke-launch` → for each `MAIN_TABS` entry, `tap_tab.sh` + `screenshot.sh smoke-tab-<name>` + per-tab assertion → `terminate_app.sh`. Each step emits `✓ <name>` on success or `✗ <name> (<reason>)` with a SKILL.md hint on failure. The script continues past per-tab failures so the operator gets a complete pass/fail rollup; build and launch failures are blocking and abort the run.

```bash
<scripts>/smoke_test.sh
# ✓ build
# ✓ launch (FIRST_SCREEN_ID 'verb_browse_anchor' seen in 4s)
# ✓ screenshot smoke-launch
# ✓ tab verbs (anchor 'Verbs' visible)
# ✓ tab families (anchor 'Families' visible)
# ✗ tab quiz (anchor 'Quiz' not present — check the label exact-match, or see SKILL.md 'Identifier rollup' if a parent container's identifier is masking the leaf)
# ✓ terminate
# ---
# smoke_test.sh: 6 pass, 1 fail, 18s
```

Per-tab assertion mode depends on whether `MAIN_TAB_ANCHORS` is configured. When set (and parallel to `MAIN_TABS`), the script asserts each anchor via `verify_label_visible.sh` — the canonical "did the right screen render?" probe. When unset, the script falls back to "AXTree changed after `tap_tab.sh`" verification: it captures a `shasum` fingerprint of `axe describe-ui` before and after the tap and reports `✓` if the trees differ. The fallback catches no-op taps (mis-calibrated coords, hit-tested off-pill) but doesn't confirm the destination screen is the *expected* one — `MAIN_TAB_ANCHORS` is the upgrade path.

The first run on a new project does the friction discovery a human would otherwise do across multiple sessions. Build failures point at the build environment; launch failures map to the "Common first-real-app friction" items (greenfield identifiers, onboarding gating, modal auto-presentation); per-tab failures classify into tab-pill calibration (exit 4 from `tap_tab.sh`) versus identifier rollup or label-mismatch (exit 4 from `verify_label_visible.sh`).

**Distinct from `calibrate.sh`.** `calibrate.sh` is one-time setup: it *writes* `MAIN_TABS_COORDS` to the config based on `measure_tab_pill.sh` output and verifies via `tap_tab.sh --verify-anchor` (AXUniqueId). `smoke_test.sh` is ongoing: it doesn't modify the config, asserts via `verify_label_visible.sh` (AXLabel), and includes screenshots and a terminate step. Run `calibrate.sh` once after `setup_project.sh`; run `smoke_test.sh` whenever you want to confirm the app still drives end-to-end.

Exit codes: `0` all steps passed; `1` one or more steps failed (per-step output classifies which); `2` config missing; non-zero from build or launch (script aborts and propagates the underlying script's exit semantics via the per-step output).

### Annotation-check phase (migration-by-use)

The verify ops' surface is the runtime accessibility tree (`describe-ui`); the project's Swift source is the *write* surface for what shows up in that tree. The annotation-check phase connects the two so a verify op's failure becomes a localizable, fixable change rather than an opaque error.

Two scripts power the phase:

- `scripts/find_id_in_source.sh <id>` — answers "is this identifier written somewhere in the Swift source, and where?"
- `scripts/audit_view.sh <swift-view-file>` — answers "which SwiftUI elements in this view file are missing the modifiers a future verification flow will need?"

The agent invokes them in two patterns:

**Reactive (post-failure).** When a named-intent op exits 4 (`no element with AXUniqueId 'X'`), run `find_id_in_source.sh X` to disambiguate:
- If the script also exits 4, the identifier is *not* in the source — propose adding the relevant modifiers to the view (located via the identifier's `{category}_{context}_{element}` convention; e.g., `input_convert_month` → `ConvertView.swift`). **Branch the proposed annotation by which op failed:**
  - `tap_id` / `tap_label` failure → propose `.accessibilityIdentifier("X")` alone. The selector path needs nothing more.
  - `read_value` / `verify_value` failure → propose `.accessibilityIdentifier("X")` **and** `.accessibilityValue(<expression>)`. Identifier alone makes the next call exit 0 with empty string (a more confusing failure than the original exit 4); the value modifier is what populates `AXValue` for the assertion.
  - `verify_screen_loaded` failure → propose `.accessibilityIdentifier("X")` on the new screen's anchor element. Pick a stable **leaf** (a title `Text`, a header `Image`); avoid root `VStack`/`ZStack` containers — see "Identifier rollup" below.
- If the script returns matches, the identifier is in the source but the element isn't currently in the rendered tree. Most common causes: the screen hasn't been navigated to, the element is conditionally rendered, or — for `TabView`/segmented `Picker` cases — the iOS 26 children-not-enumerated bug is hiding it (not an annotation problem; coord-tap is the workaround).

**Proactive (pre-flight).** When starting a verification flow on an unfamiliar view, run `audit_view.sh <view-file>` and review candidates with the user before driving the flow. Acceptable to defer additions when a candidate isn't in the path of the current flow; the migration-by-use ethos is "annotate what you're about to verify," not "annotate everything visible." Each annotation added is justified by the verification flow that needed it.

The audit is **verify-shaped, not a11y-shaped**: it flags missing `.accessibilityIdentifier` (the lookup key for verify ops) and missing `.accessibilityValue` on stateful interactables (the AXValue for assertion). It does not check `.accessibilityLabel` or `.accessibilityHint` — those serve VoiceOver, not the verify surface. Adopters who want VoiceOver coverage want a separate a11y audit; this one targets agent-driven verification.

`audit_view.sh` uses an indentation-based heuristic to decide which modifiers belong to which element. Known false-positive classes the agent should review and dismiss with judgment:

- **`.accessibilityElement(children: .combine)` parents.** Children flattened into the parent's surface get flagged anyway — the heuristic doesn't see the boundary.
- **Extracted view variables and helper functions.** A `Button` defined in a `var saveButton: some View` gets flagged when the modifier lives at the call site instead.
- **`.onTapGesture` on custom views.** v1 doesn't audit `.onTapGesture` chains; views made tappable this way are not flagged at all (false negative, not positive — but listed here for completeness).

Detected element types: `Button`, `TextField`, `Toggle`, `Picker`, `Slider`, `NavigationLink`, `Stepper`, `DatePicker`, `ColorPicker`. Stateful interactables (everything except `Button` and `NavigationLink`) are also checked for `.accessibilityValue`.

**Audit hits are sized by source-declaration site, not rendered-element count.** A single helper `func key(_ label: String) -> some View { Button { ... } label: { Text(label) } }` declaration emits ONE audit hit even when invoked from a `ForEach` that produces 18 keypad buttons. This is the right shape — you can't reasonably annotate "the Button on line N" 18 different ways from one source site without indirection — but it means the audit's count is "places to add a modifier," not "interactable elements on screen."

**Plain `Text` views holding stateful values are not flagged.** Calculator displays, computed result rows, status indicators, and similar `Text(state)` callsites are exactly the surfaces verify ops most often need to read, but the audit doesn't detect them — every static label would also match. Identify them by hand from your `@State`/`@Binding`/`@AppStorage` callsites and add `.accessibilityIdentifier` + `.accessibilityValue` directly. The audit's coverage gap is genuine; the doc is here so adopters know to look manually.

`find_id_in_source.sh`'s interpolation match progressively shortens the prefix (`a_b_c_d` → `a_b_c_` → `a_b_` → `a_`) until a match is found, since SwiftUI's `\(rawValue)` interpolation can replace any segment. Interpolation matches are flagged with a `# possible interpolation match` comment line so the agent treats them as candidates needing runtime confirmation, not definite hits.

The phase is **lenient**: scripts produce candidate lists, not blocking violations. Coverage grows wherever active work touches the codebase; the most-verified parts of the app become the most-annotated parts.

Dependencies: BSD `grep` (preinstalled on macOS) and pure bash. No new tools.

### Identifier rollup

When a parent SwiftUI container (`VStack`, `ZStack`, `Form`, `NavigationStack`, etc.) carries `.accessibilityIdentifier("X")`, SwiftUI rolls that identifier up over **every descendant** in the rendered AXTree — including descendants you've explicitly annotated with their own identifiers. The descendants' AXValue / AXLabel may survive, but their AXUniqueId is overwritten by the parent's. Verify ops that look up by identifier (`read_value`, `verify_value`, `set_value`, `verify_screen_loaded`) then exit 4 with "no element with AXUniqueId 'X'" even though the element is rendered and labeled.

May 2026 Calculator2 validation surfaced this directly: a launch-anchor identifier added to a root `VStack` made every later child identifier on the screen unfindable. Fix: anchor on a stable **leaf** (a title `Text`, a header `Image`) — not a root container.

Two `.accessibilityElement(...)` escape hatches address different cases:

- **`.accessibilityElement(children: .contain)` on the parent** — exposes the parent as a structural container without rolling its identifier over children. Use when you want the children to remain individually queryable. Tradeoff: when `.contain` is set, the parent itself disappears from the AXTree as an identifiable element. So `.contain` works for restoring child queryability, but breaks if the parent was *also* serving as a launch-screen anchor.
- **`.accessibilityElement(children: .combine)` on the parent** — flattens children into a single accessibility element on the parent. Use when the container IS the right verification surface (a row in a list whose name + type are one semantic thing, a card with name + value laid out together). The parent's `AXUniqueId` is preserved; its `AXLabel` is auto-synthesized as the comma-separated concatenation of child labels (e.g., `"Sencha, Green"` for a row with two `Text`s). Your `.accessibilityValue("\(name)   \(displayName)")` modifier is preserved as-set.

The cleanest pattern when neither escape hatch fits: never put `.accessibilityIdentifier` on a container; put it on a leaf and use that leaf for both launch detection and verification.

**Runtime hint.** When `read_value.sh` / `verify_value.sh` / `set_value.sh` / `verify_screen_loaded.sh` exit 4 (or `verify_screen_loaded.sh` exits 5), the error message lists the AXUniqueIds currently present in the tree. If only 1–2 distinct identifiers are present and the identifier you asked for is absent, suspect rollup; the hint says so explicitly. This turns "no element with X" from an opaque error into a localizable change.

### Notes on the lifecycle path

- **Multi-booted-simulator handling.** All verify-half scripts resolve `TARGET_SIM` → booted UDID through `scripts/_resolve_udid.sh`, which uses the same name-match-and-prefer-latest-runtime logic `launch_app.sh` uses for its boot-or-resolve path. Multi-booted-sim configurations work correctly: verify ops always target the project's configured sim. The helper exits 3 with an actionable message (`no booted simulator named '<TARGET_SIM>'. Run launch_app.sh first, ...`) when no booted sim matches.
- **Multi-runtime same-name handling.** A name like `iPhone 17` may exist under several iOS runtimes (e.g., 26.0 and 26.3). `launch_app.sh` picks the latest by relying on `simctl list devices`'s ascending-runtime ordering. To target a specific runtime, set `TARGET_SIM` to a more precise name or upgrade the config schema to take a UDID.
- **Cold-boot vs warm-boot.** Cold boot adds ~25–30s for `simctl bootstatus -b` on top of the wait-for-render budget. The render-budget itself is measured from after `simctl launch` returns, not from script start.

### iOS 26 controls with empty AXTree children

A class of iOS 26 SwiftUI controls (still present in 26.3) renders as a **single AXTree element with empty `children: []` and `null` AXValue**, even though the control visually presents multiple interactive sub-elements. `axe describe-ui` (full-tree) cannot reach the sub-elements; `tap_id.sh` / `tap_label.sh` / `read_value.sh` against them all fail. The bug lives at the FBSimulatorControl layer beneath AXe, idb, and any other accessibility-tree-based tool — switching tools does not fix it.

**Confirmed affected (May 2026 Calculator + GenericApp validation):**

- **`TabView { Tab(...) }`** — tab buttons aren't enumerated as children of the Tab Bar `AXGroup`. Additionally, `.accessibilityIdentifier` on `Tab(...)` is silently overridden by the SF Symbol name. Both bugs apply.
- **`Picker(...).pickerStyle(.segmented)`** — the AXTabGroup root is queryable but its children are empty; per-segment AXLabels are nowhere in the regular tree.
- **`Picker(...).pickerStyle(.menu)`** — renders as `AXPopUpButton` with empty children. AXValue: when `.accessibilityValue(...)` is set on the SwiftUI Picker, the modifier propagates and `AXValue` returns the selected option's string (so `read_value.sh` is the verify path); without the modifier, `AXValue` is null. When the menu is OPEN, the option `AXButton`s appear in the regular tree as siblings (not children) — they have proper `AXLabel`s but no `AXUniqueId`; tap them via `tap_xy` on the option's frame center. After tapping an option, the Picker briefly leaves the AXTree during the dismiss animation (~1s); sleep before re-reading.
- **`Picker(...).pickerStyle(.palette)`** — same shape as `.segmented`.

**`Picker(...).pickerStyle(.inline)` triggers identifier rollup** and should be avoided for verify-driven testing. `.inline` renders as a heading + N AXButton siblings, **all of which share the parent's `AXUniqueId`**. Verify ops by identifier hit the rollup; prefer `.menu` or `.segmented`. (The `audit_view.sh` script flags `.inline` Picker declarations.)

May 2026 GenericApp validation initially attributed a session-wide `tap_id` resolver-poisoning error (`typeMismatch ... Expected to decode Dictionary<String, Any> but found an array instead`) to `.inline` Picker. May 2026 GenericApp2 isolated this to a different cause via controlled removal — the SwiftUI `Slider` control. **The actual mechanism is JSON-type dependent: AXe's decoder hard-types `AXValue` as `String?`, and any element emitting `AXValue` as a Number (Slider, wheel Picker) breaks the tree decode. See "Slider AXTree" below.** `.inline` Picker remains a foot-gun (rollup is real), but the resolver poisoning is not its fault on iPhone 17 / iOS 26.3 / Xcode 26.3.

**`Picker(...).pickerStyle(.wheel)` renders as a no-id `AXSlider`** (UIPickerView underneath). Same resolver-poisoning class as `Slider` — see "Slider AXTree" below. The `AXValue` is the **selected index** (Int, 0-based), not the underlying value or formatted string. `.accessibilityIdentifier` and `.accessibilityValue` modifiers do **not** propagate to UIPickerView. To find the wheel programmatically, filter `describe-ui` for `AXSlider`-role elements and disambiguate from real `Slider`s by frame height (wheel ≥ 100pt; Slider ≤ 40pt). Drive via `axe swipe` (vertical, momentum-driven and imprecise — read-back-and-correct iteration to land on a specific index averages 5–8 round-trips).

#### Two workaround paths

**Drive (`tap_tab.sh`, `tap_xy.sh`).** Coordinate-tap by computed segment/tab center. The skill ships `data/coordinates.json` with known tab centers per device, and `scripts/tap_tab.sh` reads it so callers ask for tabs by name (`tap_tab.sh settings`) rather than juggling magic numbers. For Picker segments, compute `parent_x + (parent_w / N) * (i + 0.5)` from the parent's `AXFrame` — `verify_segment.sh` does this internally.

**Verify (`verify_segment.sh`, `axe describe-ui --point <x>,<y>`).** The May 2026 GenericApp validation discovered that `axe describe-ui --point` reaches the sub-elements that the regular tree misses — segment AXLabels, segment AXValues (1 = selected, 0 = not), tab labels, popover-option labels. This is the cleanest verify path and replaces the side-effect inference pattern (drive a downstream operation that depends on the selection and assert its output) earlier validations were forced into. See `verify_segment.sh` above.

#### Tab-bar-specific notes

**Modern `Tab(...)` DSL renders as a centered floating pill, not a full-width bar.** Apps using SwiftUI's modern DSL — `TabView { Tab("Name", systemImage: "...") { ... } }` — get a centered floating pill rather than the older full-width tab bar. The pill width depends on tab count: a 3-tab pill spans most of the screen; a 2-tab pill is much narrower and sits closer to the screen's horizontal center. **The Tab Bar `AXFrame` reports the full screen width regardless** (e.g., `{0, 791, 402, 83}` even when the visible pill spans only 50–352pt), so coordinates derived from `AXFrame` will hit reliably for 3-tab apps (where the pill is wide enough that the older full-width centers still land within hit-box-tolerance) and miss in 2-tab apps (where the pill is too narrow). Calibrate from a full-resolution screenshot, not from `describe-ui`'s frame data: take a `screenshot.sh tabbar-precheck`, open the PNG at 100% (the inline downsampled view loses ~10pt of precision), measure the per-tab visual centers in pixels, then divide by the simulator's retina scale (3× for iPhone 17 / Pro) to get points. **Calibrated values belong in `MAIN_TABS_COORDS` in the per-project config**, not in `data/coordinates.json` — the shared file affects every project on this machine using the same `TARGET_SIM`, so a 2-tab calibration there silently miss-taps any 3-tab app. Validation against AztecCal's 3-tab DSL pill on 2026-05-01 confirmed the shipped coords land within ~1pt of dead-center for all three tabs; non-3-tab adopters set `MAIN_TABS_COORDS` and leave `data/coordinates.json` alone.

**Adding a new device to `data/coordinates.json`.** Boot the device, launch the app, run `describe_ui.sh | jq '.. | objects | select(.AXLabel? == "Tab Bar")'` and read the Tab Bar `AXGroup`'s `frame`. The frame's vertical center gives `y`; the children of the Tab Bar are not enumerated (that's the bug), so divide the bar's width into per-tab segments and tap-test the candidate centers. Empirically: on the iPhone 17 simulator (iOS 26.3) the Tab Bar's frame is `{0, 791, 402, 83}` — same width as iPhone 17 Pro, even though Apple's published phone-spec dimensions differ. The Pro coordinates `(115, 822)`, `(201, 822)`, `(287, 822)` work as-is; the data file ships the same numbers under both device entries. Also populate the device's `floating_tab_pill_y_band` (see "Designing for verify ops" below) — the y-extent of the pill that `tap_id.sh` / `tap_label.sh` use for proactive overlap warnings.

**If you're an agent without visual access to a full-resolution screenshot.** The "open the PNG at 100% and measure" instruction presumes a human in front of Preview.app. An agent reads PNGs through `Read`, which returns a downscaled inline view that loses ~10pt of precision — borderline tolerable for 3-tab pills with their generous hit-box, unreliable for 2-tab pills where centers cluster closer to the bar's middle. Two paths:

1. **Centroid detection from the screenshot.** Quantize the middle third of a tight icon-row y-band (defaults 0.92H–0.965H) to find the modal pill background color, mask "not the pill bg" by per-channel distance, project to a 1D x-histogram of icon-pixel counts per column, and split clusters at zero-runs of ≥20 image pixels. Each cluster's count-weighted centroid is a tab x-coordinate. Sort by x, emit as `MAIN_TABS_COORDS`. ~80 lines of PIL; tab-count-agnostic; light/dark-mode-agnostic (modal-bg detection adapts); color-agnostic for selected-tab tints. May 2026 Calculator3 validated the earlier "mask 'not the pill grey'" form for the 2-tab case; May 2026 Konjugieren validated the modal-bg + zero-gap form for the 5-tab dark-mode case.
2. **Settle for the inline-preview measurement.** Eyeball the icon centers from `Read`'s output and accept the ~10pt imprecision. Works for 3-tab pills; risk of silent miss-tap on 2-tab.

A shipped `scripts/measure_tab_pill.sh` mechanizes path 1 — see below.

### `scripts/measure_tab_pill.sh`

Centroid-detection wrapper around an inline Python (Pillow) script. Takes a screenshot, detects the pill background via 16-level color quantization of the middle third of a tight icon-row y-band (default 0.92H–0.965H), masks pixels whose RGB differs from the modal bg by >40 in any channel as "icon," projects icon-pixel counts to a 1D x-histogram, splits clusters at zero-runs of ≥20 image pixels, and emits a count-weighted centroid per cluster as a `MAIN_TABS_COORDS=(...)` line. Modal-bg detection makes the algorithm light/dark-mode-agnostic without a hand-coded heuristic.

```bash
<scripts>/measure_tab_pill.sh                                              # takes a fresh screenshot
<scripts>/measure_tab_pill.sh --screenshot docs/screenshots/<existing>.png # analyze existing PNG
```

Output is the `MAIN_TABS_COORDS=(...)` line on stdout (last line; callers can extract via `tail -1`); a `# detected N tab(s) ...` comment goes to stderr. Validated against AztecCal's 3-tab light-mode pill: detected centers `(115.0, 201.0, 286.8)` match the canonical shipped coords `(115, 201, 287)` to within sub-pixel precision. Validated against Konjugieren's 5-tab dark-mode pill: detected centers `(63.0, 132.4, 200.7, 269.3, 338.5)` show ~69pt even spacing — the geometric signature of a correct read. **Reproducible measurement requires the FIRST tab to be selected** (the typical state on a fresh launch); the iOS 26 pill widens the selected tab to make room for an inline label, so a non-first selected tab biases that cluster's centroid by ~5–10pt. Run `measure_tab_pill.sh` after a clean launch, not after navigating tabs.

Dependencies: Python 3 (stock on macOS 12.3+) and Pillow. Pillow isn't installed by default; the script prints `python3 -m pip install --user --break-system-packages Pillow` and exits 4 when missing.

When `MAIN_TABS` is set in the per-project config, the script validates the detected tab count against `${#MAIN_TABS[@]}` and exits 5 with a warning on mismatch (the `MAIN_TABS_COORDS=` line is still printed for inspection — the algorithm may have over- or under-segmented, and a manual review or fresh screenshot may be the right next step).

Exit codes: `0` success; `2` config missing or bad arg; `3` pill not detected; `4` Pillow not installed; `5` count mismatch with `MAIN_TABS`.

### Slider AXTree

The SwiftUI `Slider` control renders as `AXSlider` with these properties:

- **`AXValue` is a normalized Double 0.0–1.0**, not the explicit `.accessibilityValue("...")` string set in SwiftUI. The accessibility-value modifier does NOT propagate over the inherent UISlider percentage. Recover the underlying value with `min + AXValue × (max - min)`.
- **AXe v1.6.0 bug — `tap_id` resolver dies whenever an `AXSlider` is rendered.** Every `tap_id.sh` (and any script that embeds it: `set_value.sh`, etc.) exits `1` with `typeMismatch(... "Expected to decode Dictionary<String, Any> but found an array instead.")`, regardless of which identifier you target. The error is identifier-agnostic — every Button, Stepper, Text in the same tree fails the same way. **Cause:** AXe's `AccessibilityElement.AXValue` is hard-typed `String?`; iOS emits Float for `AXSlider` and Int for `Picker(.wheel)`-backed `AXSlider`; JSONDecoder aborts the whole tree. The "Dictionary vs Array" framing is a red herring caused by a `try?`-swallow + retry in AXe's decode path. There is no AXe-side cache — the apparent "session-wide" persistence is just the slider staying on screen. Tracked as [cameroncooke/AXe#45](https://github.com/cameroncooke/AXe/issues/45); fix is one Codable-type change. `axe describe-ui` is unaffected (it bypasses the buggy decoder). Isolated by controlled removal in May 2026 GenericApp2 validation.
- **`UIPageControl` shares the `AXSlider` role but emits `AXValue` as a String (e.g., `'page 3 of 5'`) and does NOT poison.** Confirms the bug is about the `AXValue` JSON type, not the role. `ProgressView`, `Stepper`, `Toggle`, `UIDatePicker` also emit String `AXValue` and are safe.
- **Workaround (recommended for verify-driven testing): `.accessibilityRepresentation { Text(...) }`.** Wrap the Slider with a SwiftUI proxy that carries a String `AXValue` into the tree. Visual rendering is unchanged; only the AX representation is swapped. Identifier and value modifiers go INSIDE the closure, on the proxy:

  ```swift
  Slider(value: $temperature, in: 140...212, step: 1)
      .accessibilityRepresentation {
          Text("\(temperature)")
              .accessibilityIdentifier("slider_temperature")
              .accessibilityValue("\(temperature)")
      }
  ```

  After this, `tap_id` works on every identifier in the view, and `read_value slider_temperature` returns the human-readable value (e.g. `"175"`) instead of `0.486111...`. The same pattern works on `Picker(.wheel)` and as a bonus gets it an `AXUniqueId` for the first time (the modifier doesn't bridge to UIPickerView, but it does bridge to the proxy `Text`). The proxy closure is re-evaluated on every state change — drive-and-read sequencing is identical to driving a non-proxied control (wheel Pickers still need the existing settle-sleep between swipe and read while the wheel decelerates).

  **Caveat for shipping apps — VoiceOver regression.** The proxy collapses the slider/picker to `AXStaticText` in the AX tree. The `.adjustable` trait is lost, so VoiceOver announces the control as static text rather than as an adjustable slider, removing the swipe-up/swipe-down adjust gesture. SwiftUI's public `AccessibilityTraits` set has no `.isAdjustable` member; `.accessibilityAdjustableAction { ... }` adds the action handler but does not restore the `AXSlider` role / `.adjustable` trait. For test-only builds this is fine; for apps that ship to humans, gate the workaround behind `#if DEBUG` or a launch-time flag, or fall back to a `UIViewRepresentable` wrapper around a custom `UIView` with `accessibilityTraits = .adjustable` + a String `accessibilityValue` (the only path that preserves both AX-tree adjustability and avoids the AXe bug — at the cost of reimplementing the Slider's visuals, gestures, and value-tracking).

  **`set_value.sh` is unusable on the proxied control.** `tap_id` lands on the proxy `Text`, which doesn't accept text input; Cmd+A and `axe type` go nowhere; the read-back catches the mismatch and exits 6 with the documented hint enumeration. After applying `.accessibilityRepresentation`, drive via `axe swipe` and verify with `read_value`.

- **Workaround (when AXe access to the Slider isn't needed):** `.accessibilityHidden(true)` on the Slider. Suppresses poisoning by removing the Slider from the AX tree entirely. Use when the Slider exists for visual / direct-touch use only and you don't need `read_value` or `tap_id` on it.
- **Workaround (last resort): `tap_xy.sh`** against AXFrame centers for the entire view containing the Slider. Slower per-element setup; use only if `.accessibilityRepresentation` doesn't fit (e.g., the Slider isn't in your code to modify). Until the upstream AXe fix lands, this is the path for third-party screens.
- **Drive a Slider** via `axe swipe` from the thumb's current x-position to the target x-position, computed from `frame.x + frame.width × AXValue` (current) and `frame.x + frame.width × (target-min)/(max-min)` (target). Read-back-and-correct loop to land within ±1 unit averages 4 round-trips. Works regardless of which workaround above is in place.

**What does NOT work:** overriding `accessibilityValue: String?` on a `UISlider` subclass via `UIViewRepresentable`. iOS's serializer reads the underlying `value: Float` directly and ignores the override; the `AXValue` in the tree stays a Float and poisoning persists. SwiftUI's `.accessibilityAdjustableAction` modifier on a Text proxy preserves the action handler but does not restore the `AXSlider` role / `.adjustable` trait in describe-ui, so the proxy still announces as static text in VoiceOver.

### Toolbar AXTree

iOS 26's `NavigationStack` + `.toolbar { ... }` has two surfaces worth knowing about:

- **Single toolbar item: `tap_id` works.** A single `ToolbarItem(placement: .topBarTrailing) { Button(...) }` is queryable via `tap_id.sh`. Note: `axe describe-ui` may NOT enumerate the button in its tree, but AXe's resolver still reaches it via a separate path. Don't rely on `describe-ui` alone to confirm presence — try `tap_id.sh` directly.
- **N>1 toolbar items in `.topBarTrailing`: breaks `tap_id` for ALL items.** Adding a second `ToolbarItem` (any combination — two `Button`s, `Button` + `Menu`, etc.) makes both items disappear from AXe's resolver. `tap_id.sh button_X` exits 1 with `No accessibility element matched --id 'X'`. Workaround: `tap_xy.sh` on the visual icon position. The system `Menu` toolbar item also doesn't propagate `.accessibilityIdentifier` to the AXTree even when alone — `tap_xy` is required regardless. When a `Menu` is open, its child items DO appear as `AXButton` siblings with proper labels (no AXUniqueId); use `tap_label.sh` against the item label.

Confirmed via May 2026 GenericApp2 validation with controlled A/B (single Button → reachable; add a second Button → both disappear; remove second → first recovers).

### Modal AXTree gating

A class of iOS 26 modal presentations gates the parent AXTree while shown — `axe describe-ui` returns only the modal's elements (plus null-id wrappers); the parent screen's identifiers are not queryable. Verify ops against parent identifiers exit 4 ("no element with AXUniqueId 'X'") until the modal dismisses.

Confirmed across May 2026 GenericApp + GenericApp2 validation:

- `.sheet(isPresented: ...)` — full sheet
- `.popover(isPresented: ...)` — popover (compact mode on iPhone)
- `.fullScreenCover(isPresented: ...)` — full-screen cover
- `.alert(...)` — modal alert. Both buttons enumerated as `AXButton` even with `.cancel` role; `tap_label.sh "Cancel"` works.
- `.confirmationDialog(...)` — bottom-sheet popover. Only the `.destructive`/default buttons enumerated; the `.cancel`-role button is NOT in the AXTree. Dismiss via `tap_xy` on a known-empty area outside the popover (and outside any toolbar controls — the `BackButton` at `{16, 62, 44, 44}` is an easy accidental hit).
- Form Picker popover (see "iOS 26 Form-in-NavigationStack" below)

**Pattern for verify flows:** structure as "open modal → drive → close → verify parent" rather than interleaving. The parent is unreachable mid-modal.

**`PopoverDismissRegion` quirk.** The dismiss region's AXFrame reports as the full screen (e.g., `{0, 0, 402, 874}`). `tap_id PopoverDismissRegion` taps the calculated center, which often lands on the popover content rather than the surrounding dismiss zone. To reliably dismiss, `tap_xy` on a known-empty point outside the popover.

**`NavigationLink` push behaves similarly** — the pushed view replaces the parent in the AXTree (not strictly modal, but symmetric for verify-flow purposes). The system back button is exposed with `AXUniqueId: "BackButton"` and `AXLabel: "Back"` (literal string "Back", NOT the parent screen title). Tap via `tap_id BackButton` or `tap_label "Back"`.

#### TipKit popovers

`Tips.configure(...)` registered tips present as popovers on the screen they're attached to. These follow the modal-AXTree-gating pattern: while the popover is shown, `axe describe-ui` returns only the popover's elements (`PopoverDismissRegion`, `xmark.circle.fill`, the tip's title/body), and the underlying screen's identifiers are not queryable. The verify ops' present-AXUniqueIds hint will surface this as the popover-gating classification (see "Errors as state probes" above). Friction surfaces because **TipKit's presentation timing is unpredictable** — a tip configured for `.displayFrequency(.immediate)` may appear between any two ops in a verify flow, with no signal in between.

**Recommended workaround for verify-driven sessions:** gate the `Tips.configure(...)` call behind an env-var check so verify-driven runs can suppress tips entirely.

```swift
@main
struct YourApp: App {
    init() {
        if ProcessInfo.processInfo.environment["DISABLE_TIPKIT"] != "1" {
            try? Tips.configure([.displayFrequency(.immediate)])
        }
    }
    // ...
}
```

Then launch verify-driven sessions with `SIMCTL_CHILD_DISABLE_TIPKIT=1`. The skill's `launch_app.sh` doesn't currently set this automatically (env-var passthrough is the adopter's choice, not a skill default), but adopters whose apps use TipKit on the launch screen should consider exporting it for the duration of a verify session:

```bash
export SIMCTL_CHILD_DISABLE_TIPKIT=1
<scripts>/launch_app.sh
```

The same `SIMCTL_CHILD_*` mechanism documented under "iOS 26 Form-in-NavigationStack" applies — Apple strips the `SIMCTL_CHILD_` prefix and forwards the remainder into the launched process's environment.

### iOS 26 Form-in-NavigationStack

`Form { Toggle/Picker/Slider/... }` inside `NavigationStack` on iOS 26 has two confirmed walls that the May 2026 Calculator2 validation surfaced and follow-up sessions confirmed:

1. **`AXFrame` coordinates don't equal screen coordinates.** For elements inside the NavigationStack content area (Form rows, navigation title, header text), `describe-ui`'s reported `AXFrame` reads as if the content were laid out in unscaled space — observed ratio `visual_y / AX_y ≈ 1.30` for a Toggle whose `AXFrame.y` reports as 296 but visually centers at y≈382. `tap_label.sh` and `tap_id.sh` use the AXFrame center as the HID dispatch coord, so taps mis-land in the wrong screen region. Plain SwiftUI Buttons *outside* a NavigationStack are unaffected.
2. **HID dispatch into Toggles and Pickers fails silently.** Even `tap_xy.sh` at the visually-measured screen center doesn't reliably trigger gestures inside this combination on iOS 26.0 / 26.3. The validation tested all three drive paths against annotated Settings controls:
   - `read_value.sh` against a **Toggle** → exit 0, returns the Toggle's AXValue (`"0"` or `"1"`). **Read path works for Toggles.**
   - `read_value.sh` against a **Picker mid-tap** → exit 0 with empty AXValue. **Form Pickers gate the entire AXTree behind a popover when tapped — see "Form Picker popover" below.**
   - `tap_id.sh` / `tap_label.sh` → exit 0 with "Tap completed successfully," but a follow-up `read_value` shows the AXValue unchanged. **Tap-dispatch path silently fails.**
   - `set_value.sh` against a **Toggle** → exit 6 with `expected '1', got '0'` (read-back returns the unchanged value).
   - `set_value.sh` against a **Picker** → exit 6 with `expected '<new>', got ''` (read-back returns empty because the popover gates the AXTree). Same wall, different read-back surface.

This appears to be a real FBSimulatorControl / AXe limitation, not a SKILL.md prose problem — switching to `idb` or any other accessibility-tree-based tool inherits the same constraint.

**Form Picker popover.** Tapping a Form Picker presents a centered floating popover with the option list (a checkmark on the currently selected) — **not** a NavigationStack push. Critically, while the popover is shown, `axe describe-ui` returns 0 AXUniqueIds: the entire AXTree is gated behind the popover overlay. The underlying Settings screen with the Picker and any sibling Toggle is not queryable until the popover dismisses (tap outside or tap an option). Implication for verify ops: a `set_value` flow against a Form Picker will always read back empty mid-flow, because the popover hides the source identifier. The `simctl launch -- -key value` workaround below is the right answer; "navigate-back-then-read" doesn't apply (no navigation to go back from).

**Workaround: don't drive Toggle/Picker state via UI dispatch.** Inject the underlying state directly:

- **`@AppStorage`-backed settings:** pass via `simctl launch -- -DefaultsKey value` (e.g., `simctl launch <udid> $BUNDLE_ID -- -showSubtitle 0`). The `--` separates simctl args from app launch args; iOS reads them as preference overrides.
- **`@State`-backed settings:** add a debug menu in DEBUG builds that exposes a button to toggle the state, then drive the button via the working `tap_id.sh` path. Or expose a launch-arg branch in the view's **`init()`** that reads from `ProcessInfo.processInfo.arguments` or `ProcessInfo.processInfo.environment` and applies the requested state. **Do NOT use `.onAppear`** for first-render reads — `.onAppear` fires AFTER the first body evaluation, so the AXValue is rendered with the pre-flip state and the read-back appears to fail. `init()` runs before any body evaluation and is the correct hook. (May 2026 GenericApp2 validation burned 4–5 wasted iterations on this exact failure mode before isolating it.)

  ```swift
  init() {
      let initialAdvanced = ProcessInfo.processInfo.environment["SHOW_ADVANCED"] == "1"
      _showAdvanced = State(initialValue: initialAdvanced)
  }
  ```

  Launch invocation using the documented `SIMCTL_CHILD_*` env-var passthrough (Apple-documented prefix that strips `SIMCTL_CHILD_` and forwards the remainder into the launched process's environment):

  ```bash
  SIMCTL_CHILD_SHOW_ADVANCED=1 xcrun simctl launch "$UDID" "$BUNDLE_ID"
  ```

  **Verifying propagation.** *(May 2026 GenericApp2 initially flagged this mechanism as flaky based on six tested var names appearing not to propagate. Re-validation later that month refuted the finding — the original test inferred propagation from a UI signal gated by an `init()` branch checking only one name. All var names propagate; see `validation_notes.md` § SIMCTL_CHILD env-var asymmetry investigation for the methodology and transcripts.)*

  `xcrun simctl getenv <udid> <name>` reads launchd's environment, not the launched app's `ProcessInfo.environment` — it returns "not found" even for vars that do propagate. The reliable verification path is to dump `ProcessInfo.environment` to a JSON file in the app container and read it host-side:

  ```swift
  // In an early init() or App.init() — runs before the first body evaluation.
  if let docs = try? FileManager.default.url(
      for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
  ) {
      let url = docs.appendingPathComponent("env_probe.json")
      let payload: [String: Any] = [
          "environment": ProcessInfo.processInfo.environment,
          "arguments": ProcessInfo.processInfo.arguments,
          "launch_nonce": UUID().uuidString
      ]
      if let data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys) {
          try? data.write(to: url)
      }
  }
  ```

  Read back from the host shell:

  ```bash
  CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)
  jq '.environment | with_entries(select(.key | test("YOUR_VAR_PATTERN")))' \
    "$CONTAINER/Documents/env_probe.json"
  ```

  `simctl terminate` + `simctl launch` is asynchronous; the launched process typically writes the file ~1.2–1.3s after `simctl launch` returns on Apple-Silicon-equivalent hardware (median 1209ms, range 1194–1305ms across five clean runs on iPhone 17 sim / iOS 26.3.1). A fixed sub-second sleep is fragile — gate reads on the `launch_nonce` changing from the pre-launch value, polling at ~200ms intervals with a 5s budget.

  **Argv shape × storage.** `@AppStorage` argument-domain only parses `-key value` (single-dash + space-separated value). `--key`, `-key` (no value), and any form without the `--` separator silently fall through to the registered default. `@State` reading `ProcessInfo.arguments` accepts any shape (the verbatim argv is in `arguments`). So the workaround syntax depends on the storage type: `-- -showAdvanced 1` for `@AppStorage`, `--showAdvanced` for `@State`.
- **Verification stays normal (Toggles only):** `read_value.sh` works on the rendered Toggle, so post-condition assertions on Toggles don't need any workaround. For Pickers, the read-back works once the popover dismisses (i.e., after the workaround launch, the Picker's AXValue is queryable on the rendered Settings screen).

**Worked sequence — copy-paste-clean for the `@AppStorage` case (Bool).** `launch_app.sh` doesn't pass through args (the script takes a fresh build to a launched app and doesn't accept arbitrary trailing arguments), so applying the workaround requires bypassing the skill's normal lifecycle. Replace the `<...>` placeholders:

```bash
# 1. Terminate any running instance (no-op-safe when nothing is running).
<scripts>/terminate_app.sh

# 2. Recover the booted simulator's UDID (matches launch_app.sh's resolution path).
UDID=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)

# 3. Launch with the @AppStorage override. Replace -DefaultsKey and value.
#    Bool overrides accept YES/NO or 1/0; integer/string overrides take literals.
xcrun simctl launch "$UDID" "$BUNDLE_ID" -- -<DefaultsKey> <value>

# 4. Re-navigate to the screen that consumes the setting (simctl launch returns
#    immediately without polling, so describe-ui / verify ops should wait for
#    the relevant anchor to appear before driving further).
<scripts>/tap_tab.sh <tab-name> --verify-anchor <anchor-id>

# 5. Confirm the state landed.
<scripts>/read_value.sh <toggle-id>
```

`$BUNDLE_ID` resolves from your sourced config; you don't need to substitute it explicitly when this runs from the project root and `.claude/ios-build-verify.config.sh` is already sourced (e.g., as part of a script that sources the config first). For one-off shell invocations, expand it: `xcrun simctl launch "$UDID" biz.joshadams.AztecCal -- -showSubtitle 0`. May 2026 Calculator3 walked this exact sequence end-to-end without consulting external resources.

**Worked sequence for a string-valued `@AppStorage`.** Identical structure; the critical difference is shell quoting on the value. **Use double quotes around values containing spaces; single quotes around the entire `-key value` arg silently fail.**

```bash
# Steps 1-2 identical to the Bool case (terminate, recover UDID).

# 3. String override. Note the double quotes around the value: bash word-splitting
#    + double-quote preservation passes argv ["-wordSeparator", " | "] to the app,
#    which NSUserDefaults' argument-domain parser binds to the @AppStorage key.
xcrun simctl launch "$UDID" "$BUNDLE_ID" -- -wordSeparator " | "

# Single-quote forms DO NOT work and silently fall through to the @AppStorage default:
#   xcrun simctl launch "$UDID" "$BUNDLE_ID" -- '-wordSeparator " | "'
# Bash collapses the single-quoted form into one argv entry containing the entire
# string-with-quotes; NSUserDefaults sees a single non-`-key value` token and ignores it.
# Symptom: read_value.sh returns the @AppStorage default after launch, not the override.

# Steps 4-5 identical (re-navigate, read-back to confirm).
```

The wall is bounded to `Form { stateful-control } in NavigationStack`. Toggles and Pickers in plain `VStack`s, list cells with `.onTapGesture`, and direct top-level controls all dispatch normally. When a verification flow needs Toggle/Picker state and the control is in a Form, prefer state injection over HID dispatch — the loud-fail in `set_value.sh` will tell you when you've hit the wall.

## Naming convention

Verifiable elements in target SwiftUI apps follow `{category}_{context}_{element}`:

- `input_convert_month` — TextField input on the Convert screen
- `card_settings_caso` — tappable card on the Settings screen
- `row_convert_tonalpohualli` — stateful display row on the Convert screen
- `tab_main_settings` — Settings tab in the main TabView

Useful categories: `input`, `output`, `button`, `card`, `row`, `tab`, `picker`, `toggle`. Add categories as needed.

The convention is **advisory, not enforced**. Segment casing is loose — `input_convert_month` and `input_convertMonth` and `input_verbBrowse_count` all work identically at runtime; the convention exists to keep identifiers searchable and predictable, not to satisfy a regex. `setup_project.sh` does not validate `FIRST_SCREEN_ID` against the convention. Adopters who want a project-wide audit of identifier hygiene should run `audit_view.sh` across their view files; setup-time enforcement creates friction for greenfield apps without payoff.

## Annotation policy: lenient, not strict

The skill's verification surface is the accessibility tree. The skill is **lenient**: it works against whatever annotations are present, and verification quality scales with annotation coverage rather than failing without it. A strict skill would refuse to operate on any existing codebase that hasn't been pre-prepared, closing the adoption door; a lenient skill produces value on day one and grows into its full surface as users improve coverage.

The four `.accessibility*` modifiers are not equally load-bearing for the skill, and "interactable" understates the surface — verifiable elements include both interactables (Buttons, TextFields, Pickers) and stateful display-only elements (rows whose value is worth asserting against).

| Modifier | Powers | Required when |
|---|---|---|
| `.accessibilityIdentifier` | Stable selector for `axe tap --id`; grep anchor in `describe-ui` | Any element to be tapped, queried, or verified |
| `.accessibilityValue` | State assertion (`AXValue` in `describe-ui`) | Element has a stateful value worth verifying (Picker, Toggle, Slider, TextField, computed display) |
| `.accessibilityLabel` | Human-readable name; powers `axe tap --label` fallback | Always good practice; required for VoiceOver |
| `.accessibilityHint` | Description of the affordance | Optional; mostly serves VoiceOver |

Identifier and value are the load-bearing pair. Label and hint are positive externalities — paying the annotation cost yields VoiceOver quality as a side effect.

## Designing for verify ops

A small set of code-shape choices materially affect how easily the skill's verify ops can drive a screen. None are "must do" — the skill is lenient — but each removes a specific friction class adopters have hit.

### Eager rendering for moderate row counts

`List` and `LazyVStack` virtualize: rows below the fold are removed from the AXTree until scrolled into view. Verify ops that look up a row by `accessibilityIdentifier` then exit 4 ("no element with AXUniqueId 'X'") even though the row is conceptually present, just not currently rendered. Workarounds (programmatic scroll-to-id, swipe calibration) are doable but add round-trips and brittleness.

For moderate row counts, prefer eager-rendering containers (`ScrollView { VStack { ForEach … } }`) so all rows live in the AXTree on first paint. May 2026 GenericApp validation: a 43-row Reference list rendered eagerly produced ~30 KB of `describe-ui` JSON (~715 bytes per row including row chrome) and `read_value.sh` against any row resolved instantly.

| Row count | `describe-ui` size (estimated, eager) | Notes |
|---|---|---|
| ~10 | ~7 KB | Trivially cheap |
| ~50 | ~36 KB | Subjectively snappy (`describe-ui` + `jq` < 100 ms on M-series Macs) |
| ~100 | ~71 KB | Untested but probably fine |
| ~200 | ~143 KB | Likely the high end before parse cost is noticeable |
| ~500+ | ~360 KB+ | Don't — virtualize and accept the scroll-calibration cost |

The thresholds are extrapolations from one tested data point; treat "moderate" as "tens, not hundreds." When the row count exceeds the budget, virtualize and use `ScrollViewReader` to scroll-to-id before driving — at that point the verify cost stops being constant.

### Adaptive list heights vs. the floating tab pill

iOS 26's `TabView { Tab(...) }` DSL renders a floating pill that overlays content (the pill is *over* the TabView's child screens, not below them). Layouts that compose a `List` or other container at the bottom of a tab's content with a fixed `.frame(height:)` can push downstream interactables (a TextField below the list, a Button below the field, etc.) under the pill — the AXFrame is correct, the visual is wrong, and `tap_id.sh` dispatched at the AXFrame center lands on the pill instead of the intended element. The HID dispatch returns success; the tab silently switches; the verify flow fails downstream with a confusing trace.

Pattern (not specific constants): make list-shaped sections' `.frame(height:)` proportional to their content count, so the rest of the layout reflows when the list shrinks.

```swift
// Anti-pattern — fixed height pushes followers under the floating pill
// when the list has fewer rows than fill the fixed height.
List { ForEach(savedRows) { row in /* ... */ } }
  .frame(height: 180)  // always 180pt regardless of count

// Pattern — adaptive height matches content, lets followers reflow above the pill
let listHeight = min(savedRows.count * 52 + 16, 180)
List { ForEach(savedRows) { row in /* ... */ } }
  .frame(height: CGFloat(listHeight))
```

The constants (52, 16, 180) are not portable; the *shape* `min(content × per-row + padding, max)` is. Calibrate per-app from a couple of `describe-ui` AXFrame readings.

`tap_id.sh` and `tap_label.sh` ship a proactive overlap check: before HID dispatch, they look up the target's AXFrame and compare its y-center against the device's `floating_tab_pill_y_band` from `data/coordinates.json`. On overlap, they exit 7 with a "likely obscured by floating tab pill" warning rather than dispatching the doomed tap. This catches the bug at the boundary instead of letting it propagate downstream.

### Screenshot before driving taps on a freshly-grown layout

The "Screenshot after UI changes" guidance in verify ops also applies *before* — when the layout may have grown beyond the visible viewport since the last verified state, take a `screenshot.sh` and `Read` the PNG before driving taps. The pill-overlap class is visually obvious in the screenshot (the obscured field peeks out from behind the pill), so a human-in-the-loop reviewer or an agent reading the PNG can catch it without driving a doomed tap. This is cheap insurance for any flow that adds rows, expands sections, or unhides previously-collapsed UI.

### Choosing controls with verify ops in mind

Some SwiftUI controls verify cleanly; others have known walls (see "iOS 26 controls with empty AXTree children" and "iOS 26 Form-in-NavigationStack" below). When choice is available — picking a `pickerStyle`, deciding between `Toggle`-in-`Form` vs `Toggle`-in-`VStack`, etc. — prefer the verify-friendly option:

- **Pickers:** `.segmented` and `.palette` work cleanly with `verify_segment.sh` (which uses `axe describe-ui --point` to reach segments). `.menu` works with `read_value.sh` directly when `.accessibilityValue(...)` is set on the SwiftUI Picker. `.wheel` renders as a no-id `AXSlider` (UIPickerView underneath) and is in the Slider-poisoning class — drive via `axe swipe`. `.inline` is a foot-gun (identifier rollup); `audit_view.sh` flags it.
- **Slider:** Renders as `AXSlider` with normalized 0–1 Double `AXValue`. **Session-wide `tap_id` poisoning:** any rendered `Slider` (or `.wheel` Picker) makes ALL `tap_id` calls in the same `describe-ui` session fail with `typeMismatch`. Workaround: use `tap_xy.sh` for the entire view. Drive via `axe swipe` (read-back-and-correct, ~4 RTs to land within ±1 unit). See "Slider AXTree" above.
- **Toolbar items:** `.topBarTrailing` with N>1 items breaks `tap_id` for ALL items (not Menu-specific). Use `tap_xy` on visual icon position. See "Toolbar AXTree" above.
- **Toggle / Picker:** Inside `Form` inside `NavigationStack` triggers the iOS 26 wall — `set_value.sh` requires the `simctl launch -- -DefaultsKey value` workaround. Outside `Form`, all dispatch normally.
- **Custom `UIViewRepresentable` wrappers:** Set `accessibilityValue` directly on the wrapped UIKit view inside `updateUIView` (SwiftUI `.accessibilityValue(...)` modifiers don't bridge through). May 2026 GenericApp validation: a `PlainTextEditor: UIViewRepresentable` wrapping `UITextView` to disable smart-punctuation needed `textView.accessibilityValue = text` in `updateUIView` for `read_value.sh` / `set_value.sh` to work cleanly.
- **`.textInputAutocapitalization(.never) + .autocorrectionDisabled()`** on `TextField`/`TextEditor` inputs that take ASCII operators (Morse code, regex, terminal commands). These two modifiers handle autocapitalization but **not** smart dashes / smart quotes — for those, only the `UIViewRepresentable` route works (the `.appearance()` proxy crashes on `setSmartDashesType:` because the property isn't `UI_APPEARANCE_SELECTOR`-marked).

Each of these is a small upstream code change that removes a downstream verify-op failure mode. The skill is lenient — none are required — but adopters who hit the failure modes can refactor to the patterns above.

## Three adoption paths

- **Greenfield projects.** A copy-pasteable `CLAUDE.md` snippet (TBD; ships once the verify half lands) enforces the convention going forward. Every new verifiable element gets the modifiers, named per the convention. The codebase grows annotation-complete by default.
- **Existing projects, migration-by-use (recommended default).** Verify operations include an annotation-check phase: when the agent verifies a screen, it ensures the relevant elements carry the necessary modifiers, proposing additions inline as part of the same change. Migration cost is amortized across normal feature work; coverage matches use; every annotation is justified at the moment of writing by the verification flow that needed it.
- **Existing projects, bulk audit (optional power-user).** A `scripts/audit_accessibility.sh` script scans Swift files for SwiftUI interactable patterns and reports modifier gaps. Bash + ripgrep; imperfect but adequate. Deferred to v2.

## See also

- `docs/EDD_PRD.md` (in the AztecCal lab project) — full design including build pipeline rationale, AXe vs alternatives, and the iOS 26 Tab-bar workaround.
- `docs/blog_notes.md` (in the AztecCal lab project) — running record of post-relevant design choices and rationale (cognitive debt, names-last, prose-now-code-later, self-verification framing).
