# Implementation prompt: harden the `launch_app.sh` stale-binary guard so the signal survives output filtering

## Context

You are working in `~/Desktop/workspace/ios-build-verify` — the source repo for the `ios-build-verify` Claude Code skill, published at `https://github.com/vermont42/ios-build-verify`.

A June 2026 Conjuguer Batch-F session lost a substantial debugging loop to the **stale-binary trap**: `launch_app.sh` installs and launches the last `build_app.sh` output and does **not** compile, so a bare `launch_app.sh` after editing source reinstalls the *previous* binary and serves pre-edit UI. The agent edited `InfoBrowseView.swift` repeatedly, re-ran `launch_app.sh` each time, and kept screenshotting the unchanged (pre-edit) screen — concluding variously that the fix "didn't work," then misattributing the symptom to `Section` vs. flat-list, to a `VStack` wrapper, and to the nav-bar appearance, before finally reading `launch_app.sh` and realizing it never recompiled. Several rebuild-shaped cycles were spent on stale binaries.

A first fix has already landed in the working tree (unstaged at the time of writing) and is **good as far as it goes**:

- `scripts/launch_app.sh` gained a **stale-binary guard**: a `find … -newer "$STALE_REF"` scan that emits a **non-fatal warning** to stderr when working-tree source files are newer than the installed `.app`, naming an example file and pointing at `build_app.sh`.
- `SKILL.md` and the repo `CLAUDE.md` now state plainly that `launch_app.sh` does NOT compile and that the sequence is `build_app.sh && launch_app.sh`.
- `launch_app.sh --help` documents the same.

**This prompt does not undo any of that.** It closes the one gap that keeps the guard from reliably *preventing* (rather than merely *warning about*) the trap.

## The gap

The warning is printed **before** install/launch, while the result (`launched: …` on success, or the exit-5 timeout error) is printed **last**. Two extremely common conditions silently drop the early warning:

1. **Output filtering.** Agents routinely pipe verbose build/launch output through `| tail -N` (the Conjuguer session used `launch_app.sh 2>&1 | tail -3` / `tail -2`). `tail` keeps the *last* lines — the `launched:` result — and **cuts the early warning entirely**. So in the exact workflow that triggers the trap, the mitigation is invisible.
2. **The skill's own documented temp-dir-full output loss.** When `$TMPDIR` fills with `TemporaryDirectory.*` entries, a Bash call can return "completed with no output" — early stderr is exactly what gets dropped.

The warning is also **non-fatal** (deliberately — reinstall-without-rebuild is a legitimate, if rare, flow), so a missed warning means the stale install still proceeds with no trace in the surviving output.

Net: the guard fires correctly, but its signal is positioned where the two most common output-handling patterns discard it.

## Design principle to apply

**Put unmissable signals where the reader is guaranteed to look: the last line and the exit path.** The skill already follows this for other foot-guns (the exit-5 `ERR_MSG` block appends hints to the failing output; the bundle-id check fails loud). A staleness condition that changes how every subsequent screenshot should be interpreted deserves the same treatment — it should ride on the `launched:` success line and the exit-5 error, not only on an early stderr line that `tail` removes. Keep the existing detailed early warning too (it's useful when output isn't filtered); this prompt *adds* a tail-surviving echo of the same fact, it does not replace the warning.

## Changes to make

All changes are in `skills/ios-build-verify/scripts/launch_app.sh` unless noted. Anchor by snippet text, not line number (the file shifts).

### 1. (HIGH) Capture staleness as a flag and surface it in the final output

**Why.** This is the core fix: make the staleness fact survive `| tail -N` and the temp-dir output loss by echoing it on the line the agent is guaranteed to keep.

**Implementation outline.**

(a) At the existing guard, record a flag and the example path instead of only echoing. Replace:

```bash
if [[ -n "$NEWER_SRC" ]]; then
  echo "warning: source files are newer than the built .app — this install will serve pre-edit UI." >&2
  echo "  launch_app.sh installs the last build and does NOT compile. e.g. modified since build: ${NEWER_SRC#"$(pwd)/"}" >&2
  echo "  fix: run build_app.sh first (build_app.sh && launch_app.sh) to pick up source edits." >&2
fi
```

with:

```bash
STALE_BUILD=0
STALE_EXAMPLE=""
if [[ -n "$NEWER_SRC" ]]; then
  STALE_BUILD=1
  STALE_EXAMPLE="${NEWER_SRC#"$(pwd)/"}"
  echo "warning: source files are newer than the built .app — this install will serve pre-edit UI." >&2
  echo "  launch_app.sh installs the last build and does NOT compile. e.g. modified since build: $STALE_EXAMPLE" >&2
  echo "  fix: run build_app.sh first (build_app.sh && launch_app.sh) to pick up source edits." >&2
fi
```

(b) On the success path, fold the warning into the `launched:` line. Replace:

```bash
  if echo "$TREE" | grep -q "$FIRST_SCREEN_ID"; then
    echo "launched: $APP_NAME ($BUNDLE_ID) on $TARGET_SIM ($UDID)"
    exit 0
  fi
```

with:

```bash
  if echo "$TREE" | grep -q "$FIRST_SCREEN_ID"; then
    if [[ "$STALE_BUILD" -eq 1 ]]; then
      echo "launched (STALE BUILD): $APP_NAME ($BUNDLE_ID) on $TARGET_SIM ($UDID) — installed .app is older than your source (e.g. $STALE_EXAMPLE); this UI is PRE-EDIT. Run build_app.sh, then launch_app.sh."
    else
      echo "launched: $APP_NAME ($BUNDLE_ID) on $TARGET_SIM ($UDID)"
    fi
    exit 0
  fi
```

Putting `(STALE BUILD)` adjacent to the word `launched` matters: agents grep/scan for `launched`, and `tail -1` keeps exactly this line.

(c) On the timeout path, append the staleness note to `ERR_MSG` so a modal-gated *or* slow stale launch still surfaces it. After the existing `ERR_MSG` is assembled (the block that adds the `children:[]` modal hint) and before the final `echo "$ERR_MSG" >&2`, add:

```bash
if [[ "$STALE_BUILD" -eq 1 ]]; then
  ERR_MSG+=$'\n  note: this install is STALE — source is newer than the .app (e.g. '"$STALE_EXAMPLE"$'). The screen being polled may be pre-edit UI. Run build_app.sh first, then launch_app.sh.'
fi
```

**Acceptance.** With the app built, then a `.swift` file `touch`ed, `launch_app.sh 2>&1 | tail -1` must contain `STALE BUILD`. With a fresh build (no edits since), the same command must contain `launched:` and must **not** contain `STALE`.

### 2. (MEDIUM — decision required) Add an opt-in fatal mode

**Why.** Even surfaced on the last line, the guard is advisory; an agent that doesn't condition on the result still installs the stale build. A fatal mode lets a careful caller (or a future `verify`-style wrapper) make staleness a hard stop. Keep it **opt-in** so the legitimate reinstall-without-rebuild flow — and every existing call site — is unchanged. (If the maintainer would rather make it *fatal-by-default* with an `--allow-stale` escape hatch, that is the stronger guarantee but changes the script's contract and the no-op-reinstall flow; this prompt recommends the additive opt-in unless the maintainer decides otherwise.)

**Implementation outline.** Add a `--require-fresh` flag in the existing arg-parse `while`/`case` (mirror `--reuse-install`), default `REQUIRE_FRESH=0`, and document it in the `--help` heredoc. Then, immediately after the guard sets `STALE_BUILD`:

```bash
if [[ "$STALE_BUILD" -eq 1 && "$REQUIRE_FRESH" -eq 1 ]]; then
  echo "error: --require-fresh set but the installed .app is older than your source (e.g. $STALE_EXAMPLE)." >&2
  echo "  fix: run build_app.sh first, then launch_app.sh." >&2
  exit 6
fi
```

**Exit code.** `6` is currently unused (`2` = usage/config, `3` = sim not found, `4` = app path / bundle-id mismatch, `5` = render timeout). Document `6 = stale build under --require-fresh` alongside the others in SKILL.md's exit-code list for `launch_app.sh`.

### 3. (LOW) Tighten the staleness detector

**Why.** Two correctness gaps in the `find` predicate can produce false negatives (says nothing while the build is actually stale), which is the worst failure mode for a guard.

**Implementation outline.**

- **`.xcassets` is a directory.** `-name '*.xcassets'` matches the *catalog directory*, whose mtime updates only when entries are added/removed — **not** when a file inside an existing catalog is edited. So changing an existing image/color set is missed. Either detect nested asset files instead of the directory, e.g. add `-o -path '*.xcassets/*'` (and keep `-type f` semantics by not pruning inside catalogs), or — if that proves noisy — drop the `.xcassets` term and note the limitation in the guard comment so it doesn't read as covered when it isn't. Silent partial coverage is worse than documented non-coverage.
- **Add modern source formats.** The predicate omits **`.xcstrings`** (String Catalogs — the current default for new localized strings; a project that has migrated off `.strings` would not trip the guard on a localization edit) and **`.entitlements`**. Consider `.xcstrings` at minimum. Keep the list tight; the goal is the common edit-then-launch case, not exhaustive coverage.

**Acceptance.** `touch`ing a file *inside* an existing `*.xcassets` and a `*.xcstrings` file each independently produces the stale signal from Change 1.

### 4. (LOW / optional) Address where the trap actually originates: consumer-project docs

**Why.** In the Conjuguer incident the misleading cue was not in the skill — it was in the **consumer project's own `CLAUDE.md`**, which had annotated the launch step `# build first, then boot + install + launch`. The agent followed that note and never suspected `launch_app.sh`. The skill's SKILL.md/CLAUDE.md fixes don't reach text that already lives in a consumer repo.

**Implementation outline (pick one, low effort):**

- If `setup_project.sh` writes or suggests any "Build and Test Commands" / verify snippet into a consumer's `CLAUDE.md` or README, ensure the emitted wording is the corrected form: `build_app.sh` on its own line annotated `# COMPILE first — launch_app.sh does NOT build`, and `launch_app.sh` annotated `# installs the last build + launch` (not "build first"). 
- Otherwise (or additionally), add one sentence to SKILL.md's `launch_app.sh` section instructing agents to **correct any consumer-doc note that implies `launch_app.sh` compiles** when they encounter it, since such a note will reproduce this trap regardless of the script's own warning.

## What NOT to change

- Don't remove the existing early stderr warning — it's the right behavior when output isn't filtered, and Change 1 is additive.
- Don't make the guard fatal-by-default without maintainer sign-off — the non-fatal choice is documented as deliberate (reinstall-without-rebuild is legitimate, and `--reuse-install` is explicitly orthogonal to staleness).
- Don't widen the `find` scan beyond bounded source globs or remove the derived-dir prunes — the scan runs on every launch and must stay cheap.

## Test plan (run from a real iOS project configured for the skill, e.g. Conjuguer or Konjugieren)

1. `build_app.sh` → `launch_app.sh 2>&1 | tail -1` ⇒ line contains `launched:`, not `STALE`.
2. `touch Sources/SomeView.swift` → `launch_app.sh 2>&1 | tail -1` ⇒ line contains `STALE BUILD` and the example filename.
3. Repeat (2) with a file inside an existing `*.xcassets` and with a `*.xcstrings` file ⇒ still flagged (Change 3).
4. `touch Sources/SomeView.swift` → `launch_app.sh --require-fresh; echo $?` ⇒ exits `6`, app **not** installed/launched (Change 2).
5. `build_app.sh && launch_app.sh --require-fresh; echo $?` ⇒ exits `0`, normal launch.
6. Force a render timeout while stale (e.g. wrong `FIRST_SCREEN_ID`) ⇒ exit-5 `ERR_MSG` includes the stale note (Change 1c).
7. `bash -n scripts/launch_app.sh` ⇒ clean.

## Versioning

These are behavior-affecting changes to a shipped script and warrant a patch bump (e.g. `0.3.1`) in the skill's `plugin.json`, with a one-line CHANGELOG/README note: "launch_app.sh now surfaces a stale-binary warning on the result line (survives `| tail`) and supports `--require-fresh`." Move this file to `backlog/done/` when landed.
