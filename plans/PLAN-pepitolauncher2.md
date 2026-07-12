# PLAN — PepitoLauncher2 (reimplementation of the stock Palm launcher)

**Goal:** reproduce the original PVG100 launcher for the 3" screen as a small standalone app, shipped in the ROM alongside (not instead of) Trebuchet.

**Status 2026-07-10: Phase-1 skeleton exists and is wired into the build.** Canonical repo `~/Projects/PepitoLauncher2` (local only, no remote); build clone `packages/apps/PepitoLauncher2/`; `PRODUCT_PACKAGES += PepitoLauncher2` inside the existing `TARGET_DEVICE_PEPITO` gate in `device/xiaomi/Mi8937/device.mk` (uncommitted). Skeleton = offset 3-column grid + lens (placeholder curve) + tap-to-launch + divider bar (Settings live, quick-jump/manage stubbed). **Verified running on the DUT 2026-07-10** (offset column, lens, divider all render). Fast loop, no lunch/tree needed: `cd ~/Projects/PepitoLauncher2 && ./gradlew assembleDebug && android16-adb install -r build/outputs/apk/debug/PepitoLauncher2-debug.apk` (SDK at `~/Android/Sdk`, Gradle wrapper in-repo; dual-manifest layout — see the repo README). Tree/Soong build unchanged. Next: Step 0 below, then Phase 2.

**Verdict from scoping (2026-07-10):** moderate effort — roughly **3–5k lines of Kotlin as a from-scratch app**, 2–4 focused weeks. The work is distributed unevenly: the parts that feel exotic (lens effect, offset middle column, manage mode) are a few hundred lines total; the parts that feel "already solved by Trebuchet" (drag-and-drop, folders) are the expensive half, and Trebuchet's code will not help build them (see "Why not fork Launcher3" below).

---

## Behavior spec (from memory of the original)

The original pepito launcher was cool and unique, suitable for the 3" screen.

- Vertical scrolling drawer, 3 columns of icons (no labels). The middle column is vertically offset by ~half a cell so the side columns pack tighter, using most of the space.
- **Lens effect** while scrolling: icons near the vertical center of the screen are zoomed in, falling off toward the edges.
- Scrolled to the bottom of the tray is a **divider bar** with three fixed buttons: **settings** (opens Settings), **quick jump**, and **manage**.
- **Quick jump**: from the bottom of the home-screen icons, opens the second mode of the drawer — the **auxiliary drawer** — holding all the *other* (infrequently used) icons. When the aux drawer is open, pressing quick jump again slides the aux drawer back down, returning to the frequently-used section.
- **Aux drawer**: traditional folders-and-icons setup. Same vertical 3-column grid but **no lens effect**. User can make folders, drag icons into them, or keep single icons.
- **Manage mode**: the manage button unlocks the layout — disables the lens effect and enables drag-and-drop so the user can reorder icons and move them between the top (frequent) section and the aux drawer. The button reads "exit" while active; exiting re-enables the lens and restores normal drawer behavior.

Open spec questions (settle in Step 0, not by guessing):
- Is the aux drawer a **slide-over panel** on top of the frequent section, or a scroll continuation of one list? This decides the core view architecture (see below).
- Exact lens curve, cell dimensions, offset amount, animation timings.
- What the first-run default sort/population is (the layout is manually curated afterward via manage mode — no usage-frequency logic needed).

---

## Step 0 — exploit the stock device before writing any code

The **actual launcher runs live on `android8-adb`**. Two moves, in order:

1. **Try just running it.** Pull the Palm launcher APK off the A8 device and `adb install` it on the DUT, set it as home. 2018-era targetSdk-26 app; launchers mostly sit on stable APIs (`LauncherApps`, wallpaper). Odds it works unmodified aren't great (may lean on Palm framework overlays or hidden APIs A16 blocks), but it's a 10-minute experiment. **If it fully works, this whole plan collapses to zero.**
2. **If not, it's still the spec.** Screen-record the real thing for animation timing, and decompile the APK (jadx) to extract the exact lens curve, cell dims, offset constants, and to answer the slide-over-vs-one-list question. Same "ask the stock device, don't guess" rule that closed the modem saga, applied to UX.

---

## Architecture decision — standalone app, NOT a Launcher3/Trebuchet fork

The "icons/folders/drag-and-drop are already in the stock home screen" intuition is conceptually true but practically misleading. Launcher3 (`packages/apps/Launcher3`, ~1,900 source files) is one of the most entangled apps in AOSP: its drag system (`DragController`/`DragLayer`), folders, and icon grid (`CellLayout`/`Workspace`) are coupled to each other, to the horizontal paged-workspace model, and to quickstep/recents. Extracting "just the folders" is not a copy-paste job; forks (Lawnchair etc.) take the whole thing and fight it. Bending its paged workspace into a vertical offset-column lens scroller means fighting the framework at every step.

The pepito feature list — no workspace pages, no widgets, no search, one vertical grid with two sections — is *small*. Classic case where from-scratch beats a fork. Launcher3 remains useful as a **reference** for patterns only.

**Genuinely reusable prior art (use these):**
- **`iconloaderlib`** — `//frameworks/libs/systemui:iconloader` (also `iconloader_base`, which is what Launcher3 uses). Adaptive-icon normalization, themed icons, badging for free → icons look exactly like Trebuchet's.
- **`LauncherApps`** API — enumerating launchable activities + package add/remove/update callbacks. The stable surface every launcher uses; ~100 lines to wire.

**Key internal design choice:** make the whole surface **one RecyclerView** with item types (app icon, divider bar, folder) rather than two stacked lists — then "move icon between sections" in manage mode is plain reordering, no cross-view drag. *Caveat:* this holds only if the aux drawer is a scroll continuation. If Step 0 shows it's a true slide-over panel, it becomes two views and cross-section drag becomes the second-hardest piece after folders.

---

## Component breakdown

| Piece | Difficulty | Rough size | Notes |
|---|---|---|---|
| HOME activity + app list model | trivial | ~300 LOC | `LauncherApps` + callbacks; translucent window over wallpaper |
| 3-column grid, offset middle column | easy | ~150 LOC | `GridLayoutManager`; offset = `translationY = cellHeight/2` on middle-column children + `clipChildren=false` |
| Lens effect | easy; tuning takes taste | ~100 LOC | `OnScrollListener` scaling children by distance from viewport center (macOS-dock fisheye pattern). Subtlety: pure scale vs. translating neighbors to "make room" — on a 3" screen scale-only usually reads fine. Get the real curve from the decompile |
| Divider bar (settings / quick-jump / manage) | trivial | ~100 LOC | Footer item type |
| Two sections + quick-jump slide | easy | ~250 LOC | Smooth-scroll (or panel animation, per Step 0) |
| Manage mode | easy | ~200 LOC | `ItemTouchHelper` gives grid drag-reorder nearly free; manage mode = a boolean enabling it and disabling the lens |
| **Folders (aux drawer)** | **the hard ~40%** | ~1,500–2,000 LOC | Drag-onto-icon-to-create-folder is NOT `ItemTouchHelper` (reorder-only) — needs custom drop-target detection during drag, folder-open panel, drag-out, rename, mini-preview icon. Where Launcher3 spends thousands of lines and where most of ours goes |
| Persistence | easy | ~200 LOC | Two ordered lists + folder membership; flat JSON or tiny Room DB |

**Non-goals for v1:** widgets (none existed), long-press shortcut popups, notification dots, search.

## Phasing

1. Grid + offset column + lens + divider bar with a static app list — proves the signature look in a day or two.
2. Two sections + quick-jump slide animation.
3. Manage mode: drag-reorder + cross-section moves.
4. Folders.
5. Polish: package-change handling, themed icons, first-run defaults, RTL/small-DPI sanity.

Develops as a normal sideloadable APK — `adb install`, set as home — so iteration is fast and completely decoupled from the build/flash loop. ROM integration is the last afternoon, not the first.

---

## Repo layout + ROM integration

*(Done 2026-07-10 as described below — module name `PepitoLauncher2`.)*

**Dedicated git repo (`~/Projects/PepitoLauncher2`), cloned into the tree at `packages/apps/PepitoLauncher2/`** (`git pull` in the tree clone to pick up new work). Reasons:
- It's an app with its own iteration cadence (adb install), independent of ROM releases, and shouldn't add to the bring-up-debt in the device repos.
- `repo sync` only touches manifest-managed projects; a foreign directory at a non-manifest path is left alone. (Prefer a real clone over a symlink — Soong + symlinked project dirs is asking for trouble.)
- Once personal remotes exist (`PLAN-release.md` Gate 0), add it to `.repo/local_manifests/pepito.xml` so fresh checkouts get it automatically.

**Platform build:** an `Android.bp` in the repo root makes Soong build it like any other app:

```
android_app {
    name: "PepitoLauncher2",
    srcs: ["src/**/*.kt"],
    resource_dirs: ["res"],
    sdk_version: "current",        // public APIs only; no platform cert needed
    static_libs: ["androidx.recyclerview_recyclerview"],  // + "iconloader_base" later (themed icons)
}
```

Then `PRODUCT_PACKAGES += PepitoLauncher2` in `device.mk` inside the **existing** `TARGET_DEVICE_PEPITO` block (already wired there, next to VolumeTile) — doesn't ship to the Mi8937 siblings, consistent with the layering rule.

**Dual-build note:** for day-to-day dev in Android Studio, a parallel Gradle build is convenient (standard trick for AOSP-adjacent apps: `Android.bp` and `build.gradle` side by side, Soong ignores the latter). Friction point: `iconloaderlib` isn't on Maven — either vendor its sources into the Gradle build or stub icon loading (plain `PackageManager` icons) during dev and let the platform build use the real lib.

**Default home:** don't fight the HOME role at first — ship both launchers and pick PepitoLauncher manually in Settings. Making it the *default* via role/overlay config is an end-stage papercut for `PLAN-misc.md`.
