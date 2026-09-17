# PLAN — Per-release changelog in the OTA feed + "What's new" in the Updater

**Goal:** every entry in `pepito.json` carries the release's changelog, and the Updater app can show it, without any risk to the download/verify/install path or to phones still running the current (unpatched) Updater.

**Status 2026-09-17: Phases 0–2 IMPLEMENTED; app FLASH-EQUIVALENT VALIDATED on dut1 via `adb install -r` (cells 1–5, 7 ✅). dut1 keeps the new Updater in /data/app. Embedding is now UNCONDITIONAL in `release.sh` (opt-in flag removed 09-17 after cell 1 passed). Remaining: ship in a release (cell 9).**
- Phase 0: fork `solarkennedy/android_packages_apps_Updater` created; `solarkennedy` remote added; branch `pepito-ota-changelog` (1 commit `ba29c23` on top of upstream `179c69f`); Updater added to `gen-changelog.sh` REPOS and `release-all.sh` TAG_REPOS.
- Phase 1: `gen-ota-json.py` has `--changelog-file/--changelog-url/--backfill` + `clean_changelog()`; dry-run on a copy of the live feed verified (stock keys intact, no keys emitted without the flag, backfill fills 7/9 kept entries). `release.sh` embeds the notes whenever `--notes`/`--notes-file` is given (always, via `release-all.sh`); the interim opt-in `--changelog` flag was removed once cell 1 passed.
- Phase 2: app change committed (see Updater diff); pepito-only overlay `device/xiaomi/Mi8937/overlay-pepito/packages/apps/Updater/.../strings.xml` repoints "Show changelog" at our CHANGELOG.md (uncommitted in the device tree).
- **Validation 2026-09-17 on dut1 (c39a6acf, SNAPSHOT 20260915), APK from Kyle's full remote build (09:20), `adb install -r`, test feed on throwaway landing branch `t` (deleted afterwards):**
  - Cell 2 (new app, live old-format feed) ✅ parsed, no crash, no menu item.
  - Cell 3 ✅ "What's new" on the card with a changelog; dialog = bold headers + bullets, scrolls; "Full changelog" opened Jelly on the release URL.
  - Cell 4 ✅ `""` and `null` → no menu item; number → item present, dialog shows `12345`.
  - Cell 5 ✅ real download started + paused (DB row INCOMPLETE), app restarted → log shows the "already added" branch, card still offers "What's new".
  - Cell 7 ✅ rotation with the dialog open, no FATAL.
  - Cell 1 ✅ shipped old Updater (`pm uninstall` of the update reverts to the system copy) + new-format feed: all 4 entries listed, no crash, no extra menu item. **Feed change is safe for un-updated phones — go for rollout step 4.**
  - ⚠️ `lineage.updater.uri` cap is 92 bytes: a branch name longer than ~4 chars pushes the raw URL over it, hence branch `t`. Also raw.githubusercontent caches ~1–5 min; after pushing a feed change, poll before trusting the device's fetch.
  - Not done: cell 6 (local import), cell 8 (background check), cell 9 (real end-to-end release), `--backfill` on the live feed, Phase 3.

---

## What we have today (surveyed 2026-09-16)

- **Feed:** `scripts/gen-ota-json.py` writes `pepito.json` (landing repo root) with the 7 stock keys per entry (`datetime, filename, id, sha256, romtype, size, url, version`). It *merges* into the existing file: same-filename entries are replaced, everything else is kept verbatim, then trimmed to `--keep` per romtype.
- **Changelog:** `scripts/gen-changelog.sh` already produces exactly the text we want, per release, in `.release-notes.md` (one `## VERSION (date)` section with `### repo (since tag)` headers and `- subject` bullets). `release-all.sh` runs it *before* the builds, and `release-remotely.sh` rsyncs it to the server and passes `--notes-file` to `release.sh`, which calls `gen-ota-json.py` at line ~573. So the changelog text is already sitting next to the JSON generator at the moment the JSON is written. Both variants of a day get the same section.
- **Updater app:** `packages/apps/Updater` is *pristine upstream* (`github` remote only, clean tree, no `solarkennedy` fork, not in `gen-changelog.sh` REPOS or `release-all.sh` TAG_REPOS). Relevant code:
  - `misc/Utils.parseJsonUpdate()` reads the 7 keys with `getString`/`getLong` and **ignores unknown keys** — a JSON with extra fields is harmless to the app in the field.
  - `Utils.checkForNewUpdates()` compares download IDs only — editing/adding changelog text never fires a "new update" notification.
  - `controller/UpdaterController` constructor loads persisted entries from `updates.db` (7 columns, `DATABASE_VERSION = 1`, `onUpgrade` **drops the table**), then `UpdatesActivity.loadUpdatesList()` re-parses the cached `updates.json` on every open and calls `addUpdate()`; for an entry already present it only refreshes `availableOnline` and `downloadUrl` ("already added" branch, line ~324).
  - Per-card overflow menu (`UpdatesListAdapter.showPopupMenu`, `menu_action_mode.xml`) has Export / Delete / Copy URL, each shown conditionally.
  - Top-level "Show changelog" menu item opens `https://download.lineageos.org/<ro.lineage.device>/changes` = **upstream Mi8937's page**, which is wrong for our users.

## Design decisions

1. **Embed the text in the JSON, don't link to it.** One new *optional* string key per entry, `changelog` (the cleaned notes section), plus `changelog_url` (the GitHub release page, `https://github.com/solarkennedy/lineageos-pepito/releases/tag/<tag>`). Works offline once the feed is cached, no second fetch, no new network code in the app. Cost: ~1–5 KB per entry × ≤10 entries. Old entries kept by the merge simply lack the key.
2. **Plain string, not a structured array.** The app does `optString` and shows text. No structure for the app to mis-parse. Rendering is a trivial line prettifier with a raw-text fallback.
3. **Cleaning happens in the generator, not the app.** `gen-ota-json.py` strips the `## VERSION` heading, the `(since pepito-23.2-…)` suffixes and the "first tagged … no prior anchor" bullets, and drops the `landing (docs/scripts)` section. The app never sees release-engineering noise.
4. **No DB schema change.** The changelog is reconstituted from the cached JSON on every activity open, so it is never persisted. A DB version bump would drop the table and lose in-progress download state for everyone — not worth it.
5. **UI = one overflow-menu item + one dialog.** "What's new" in the per-card menu, visible only when the entry has a non-blank changelog; opens an `AlertDialog` with scrollable text and a "Full changelog" button that opens `changelog_url` (falls back to the top-level changelog URL). Zero changes to the card layout, the progress views, or the status state machine. (The expandable-card design is nicer but touches `onBindViewHolder` + the active/inactive layout switch — exactly the code we must not disturb. Phase 3 candidate, not phase 1.)
6. **Feed-side change is flag-gated** (`--changelog-file`), so scripts can land first and the key only appears once `release.sh` passes it.

## Phase 0 — Fork the Updater (bookkeeping, no code)

Follow the opt/telephony precedent (09-12):
- Fork `LineageOS/android_packages_apps_Updater` → `solarkennedy/android_packages_apps_Updater`, branch off `lineage-23.2` (HEAD `179c69f`) as `pepito-ota-changelog` (merge to the pepito working branch when validated).
- `git -C packages/apps/Updater remote add solarkennedy git@github.com:solarkennedy/android_packages_apps_Updater.git`.
- Add `"$TREE/packages/apps/Updater	Updater"` to `gen-changelog.sh` REPOS and `"$TREE/packages/apps/Updater	solarkennedy"` to `release-all.sh` TAG_REPOS, so the change itself shows up in the next release's changelog and gets tagged.
- Builder sync copies content, so no manifest change needed (same as every other fork). Remember `generated_kernel_headers`-style caveat: nothing to delete here, only additions.

## Phase 1 — Feed side (`scripts/`, landing repo)

### `gen-ota-json.py`
- New args: `--changelog-file PATH` (optional) and `--changelog-url URL` (optional; `release.sh` passes the release page).
- `clean_changelog(text)`:
  - drop lines matching `^## ` (the version heading);
  - `### name (since …)` → `### name`;
  - drop bullets matching `first tagged in .* no prior anchor`, and drop a section left with no bullets;
  - drop the `### landing (docs/scripts)` section entirely (script/doc churn, not ROM content);
  - collapse runs of blank lines; strip; if the result is empty → **omit the key** (never write `""`).
  - hard cap ~16 KB, truncating at a line boundary with a trailing `…` (belt-and-braces; the dialog would cope anyway).
- Attach `"changelog"` and `"changelog_url"` to the *new* entry only. Existing entries pass through untouched (they may already have theirs from their own run).
- Optional `--backfill CHANGELOG.md`: for kept entries lacking `changelog`, find the `## <tag>` section whose tag matches the entry's release tag (parsed from `url`) and fill it. Nice for the first run so the new app shows something for the entries already in the feed; not required.
- Print the changelog byte count in the existing summary line.

### `release.sh`
- After `--notes`/`--notes-file` parsing, if `NOTES` is non-empty, write it to a temp file (`mktemp`) and pass `--changelog-file "$TMP" --changelog-url "https://github.com/$REPO/releases/tag/$TAG"` to `gen-ota-json.py`. (Using a temp file rather than the notes path means the inline `--notes "…"` form works too, and nothing depends on the server's landing mirror layout.)
- Same-day second variant: `release.sh` skips the release body (release already exists) but still passes the notes to the JSON generator, so both variants carry it. Verify this is what happens — the `--notes-file` no-op comment in `release-remotely.sh` refers only to `gh release create`.

### Landing repo
- `README.md` OTA section: document the two new keys as *optional* and *ignored by the stock Updater*.
- **Do not** touch the `lineage.updater.uri` prop (91-byte cap) — nothing changes there.

## Phase 2 — Updater app (fork branch)

Minimal diff, every new read is `opt*`, every new UI path is guarded by "changelog present".

1. **Model**
   - `UpdateBaseInfo`: add `String getChangelog();` and `String getChangelogUrl();`
   - `UpdateBase`: `mChangelog`, `mChangelogUrl` (default `null`), getters/setters, and copy them in the `UpdateBase(UpdateBaseInfo)` copy-constructor. `Update` and `UpdateImporter` inherit nulls — no change needed there (importer-created and DB-loaded entries simply have no changelog).
2. **Parse** (`Utils.parseJsonUpdate`):
   ```java
   String cl = object.optString("changelog", "");
   update.setChangelog(cl.trim().isEmpty() ? null : cl);
   String clUrl = object.optString("changelog_url", "");
   update.setChangelogUrl(clUrl.trim().isEmpty() ? null : clUrl);
   ```
   `optString` never throws, and a non-string value is coerced, so a malformed feed can at worst show odd text, never crash or drop the entry.
3. **Merge** (`UpdaterController.addUpdate`, "already added" branch): alongside the existing `setDownloadUrl`, add `if (updateInfo.getChangelog() != null) updateAdded.setChangelog(...)` and the same for the URL. **This is the one subtle line:** without it, an update that was downloaded earlier (so it comes from the DB with no changelog) never picks its changelog up on re-parse.
4. **UI** (`UpdatesListAdapter.showPopupMenu` + `menu_action_mode.xml`):
   - New menu item `menu_show_whats_new` ("What's new"), `setVisible(update.getChangelog() != null)`.
   - Click → `new AlertDialog.Builder(mActivity).setTitle(buildVersionString).setMessage(prettify(changelog)).setPositiveButton(android.R.string.ok, null)`, plus `.setNeutralButton(R.string.menu_full_changelog, …)` opening `changelogUrl != null ? changelogUrl : Utils.getChangelogURL(mActivity)` via `ACTION_VIEW` wrapped in try/catch for `ActivityNotFoundException`. Long text scrolls natively in `setMessage`.
   - `prettify()`: line-based — `### x` → bold `x` (SpannableStringBuilder), `- y` → `• y`, everything else verbatim. Any exception → show the raw string. Keep it in a small `misc/Changelog.java` helper so the adapter diff stays ~15 lines.
   - Strings: `menu_show_whats_new`, `menu_full_changelog` in `values/strings.xml` (English only; other locales fall back to English).
5. **Top-level "Show changelog" URL fix** (independent, no Java): overlay `menu_changelog_url` to `https://github.com/solarkennedy/lineageos-pepito/blob/lineageos23.2/CHANGELOG.md` under the existing pepito overlay tree (`device/xiaomi/Mi8937/overlay/packages/apps/Updater/app/src/main/res/values/strings.xml`, note the `app/src/main/res` path). Gate it with the other pepito-only overlays so Mi8917/Mi8937 non-pepito products are untouched.

Explicitly **not** touched: `UpdatesDbHelper`, `UpdaterService`, `DownloadClient`, `ABUpdateInstaller`/`UpdateInstaller`, `UpdatesCheckReceiver`, `ExportUpdateService`, `onBindViewHolder`, the card layout.

## Phase 3 — optional polish (only after Phase 2 is flash-validated)

- Show the first few changelog lines in the "New update available" notification (`BigTextStyle`) from `UpdatesCheckReceiver`.
- Expandable "What's new" section inside the card instead of the menu item.
- A "What's new in this build" entry in the top-level menu using the *installed* build's changelog (would need the section shipped in the ROM, e.g. `/system_ext/etc/changelog.txt` from the same notes file at build time). Different lane.

## Validation (the part that keeps the fleet safe)

Bench loop, all run by Kyle. No flash needed until the last step: `m Updater` on the builder, then `adb install -r` the platform-signed APK onto a DUT already on our A16 (same signing key ⇒ installs as a system-app update in `/data/app`; `pm uninstall org.lineageos.updater` reverts to the `/system_ext` copy). Test feed = a throwaway branch of the landing repo with a hand-edited `pepito.json`; point a unit at it with `setprop lineage.updater.uri <raw URL>` (read at every check, not `ro.`), and restore the prop afterwards.

Cells, in order:

| # | Setup | Expect |
|---|-------|--------|
| 1 | **Old (shipped) Updater** + new-format feed on a unit that is NOT reflashed | identical behaviour to today: entries listed, download starts, no crash, no menu change. Proves the field is safe before any feed change ships. |
| 2 | New Updater + **old-format** feed (current `pepito.json`) | identical to today; no "What's new" item anywhere. |
| 3 | New Updater + new feed, entry newer than the DUT build | "What's new" appears, dialog shows cleaned text, "Full changelog" opens the release page. |
| 4 | Feed entry with `"changelog": ""`, `null`, and a number | no menu item / no crash for the first two; the number renders as text, no crash. |
| 5 | Download an update fully (VERIFIED), kill the app, reopen | "What's new" still present (exercises the `addUpdate` merge branch through the DB-load path). |
| 6 | Local import of a zip (`UpdateImporter`) | no menu item, no crash. |
| 7 | Rotate the screen with the dialog open | no crash (dialog dismisses, same as the existing Delete dialog). |
| 8 | Background check: `adb shell am broadcast` the updates-check alarm path, or wait for the interval | notification unchanged; `logcat -s UpdatesCheckReceiver Utils` shows the parse succeeded with the extra keys. |
| 9 | Full happy path with the new app: check → download → verify → install → reboot into the new build | unchanged. This one needs a real release; do it on the first release that ships the new Updater. |

Feed-side checks (no phone): run `gen-ota-json.py` twice on a copy of the live `pepito.json` (with and without `--changelog-file`) and `diff` — only the new entry may differ, and `python3 -c 'import json;json.load(open("pepito.json"))'` must pass. Confirm every kept entry still has all 7 stock keys.

## Rollout order

1. Phase 0 (fork) and Phase 1 scripts land, **without** `release.sh` passing `--changelog-file` yet. Next release proves the generator still produces a byte-identical feed shape.
2. Cell 1 above on the test feed (old app, new keys). This is the go/no-go for the feed change.
3. Phase 2 app change reviewed, `adb install -r` cells 2–8.
4. Enable `--changelog-file` in `release.sh`; the release that ships the new Updater is also the first release whose entries carry a changelog. Cell 9 on that release.
5. Optional `--backfill` for the older entries; Phase 3 later.

## Risks / open points

- **Release-body vs. JSON divergence:** both come from the same `.release-notes.md`, cleaned differently (GitHub gets the raw section, the JSON gets the cleaned one). Acceptable; document it.
- **Two variants, one changelog:** SNAPSHOT (gapps) and UNOFFICIAL (vanilla) entries of a day carry identical text. Correct today since the sources are identical; if a gapps-only change ever matters, add a variant line in `gen-changelog.sh`, not in the app.
- **`optString` on a JSON `null`** returns the string `"null"` on some Android `org.json` versions when no fallback is given — always pass the `""` fallback and additionally `isNull()`-check. Covered by cell 4.
- **Translation import churn:** upstream "Automatic translation import" commits will conflict only on `strings.xml` if they ever touch our two new strings (they won't; ours are untranslated). Rebases stay trivial.
- **Field size:** a release with a very long section (dozens of commits across 17 repos) could hit tens of KB. The 16 KB cap and the `--keep 5` window bound the feed to well under 200 KB.
