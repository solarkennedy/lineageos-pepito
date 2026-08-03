# PLAN-blocker.md — Blocker (per-component app control) as a system-UID ROM app

**Goal:** ship [Blocker](https://github.com/lihenggui/blocker) (Apache-2.0, `com.merxury.blocker`) in the
pepito build so its component control works **out of the box with no root and no Shizuku** — Kyle's
explicit constraint. Blocker disables individual activities / services / receivers / providers of
installed apps, which the Settings UI cannot do.

**Status 2026-08-03: ✅ WORKING END-TO-END, FLASH-VALIDATED. No root, no Shizuku.**

Confirmed live on DUT1 (`c39a6acf`):

- `sharedUser=android.uid.system/1000`, `codePath=/system/app/Blocker`,
  `CHANGE_COMPONENT_ENABLED_STATE granted=true`; process runs as `system` in domain
  `u:r:system_app:s0`. Zero avc denials, zero crashes.
- Kyle toggled components on phyphox in the UI → the app wrote
  `/data/system/ifw/de.rwth_aachen.phyphox.xml`, `system:system` mode 644, labelled
  **`ifw_data_file`**. The name-based `type_transition` did its job.
- `IntentFirewall: Read new rules` fires on each write, so system_server's FileObserver sees them.
- **Enforcement proven:** `am start` of a blocked activity returns **result code 102 =
  `START_ABORTED`** (`FIRST_START_NON_FATAL_ERROR_CODE 100 + 2`) and the process never starts;
  control launch of Settings in the same session returns `result code=0`.

⚠️ **Do not read `Read new rules (A:0 B:0 S:0)` as a failure.** That counter is
`resolvers[..].filterSet().size()`, which counts **intent** filters only; `<component-filter>`
entries go into a separate `mRulesByComponent` map that is never logged. Blocker writes component
filters exclusively, so those counters are permanently 0 even when enforcement works.

**PM controller path also proven** (same session, VLC): Blocker's app-level disable drove
`setApplicationEnabledSetting` through the in-process `IPackageManager` binder call, leaving
`org.videolan.vlc` at `enabled=3` = `COMPONENT_ENABLED_STATE_DISABLED_USER`. The framework acted on
it — Launcher dropped the icon (`PackageUpdatedTask: package … is disabled, removing package`),
MediaProvider and Icing purged it, and `am start` of its activity now fails with
`Activity class … does not exist`. So **both** backends work in-process with no root and no Shizuku.

**Bench state:** phyphox's activities are IFW-blocked and VLC is PM-disabled, both from testing.
Toggle them back in Blocker (or `adb shell pm enable org.videolan.vlc`) to restore.

⚠️ **Defect found on that flash, fixed but NOT yet re-flashed:** `CopyRulesToStorageWorker` failed
with `No files found in blocker-general-rules`. Upstream keeps that assets directory as a **git
submodule**, and submodule contents are absent from a source tarball, so the first import shipped it
empty — the curated rule browser would have been blank (component blocking itself unaffected). The
922 rule files are now vendored and the APK rebuilt (7.6 MB → **8.6 MB**, in line with upstream's
8.6/8.9 MB foss release). ⭐ General lesson: **check `.gitmodules` when importing from a tarball.**

Source of truth for the app is **`~/Projects/blocker`** (git, two commits: upstream import, then the
pepito patch). The device tree carries only the built APK.

### What to check on the first flash

1. `adb shell dumpsys package com.merxury.blocker | grep -E "userId|codePath"` → **userId=1000** and
   `/system/app/Blocker`. If it isn't 1000 the app installed but the shared UID was refused; nothing
   else below will work.
2. Open Blocker, pick any app, disable one component. Default controller is **IFW**.
3. `adb shell ls -lZ /data/system/ifw/` → a `<package>.xml` labelled **`ifw_data_file`**. Wrong label
   ⇒ the `type_transition` didn't apply (likely a dirty flash over an existing dir — see file_contexts
   note above).
4. `adb shell dmesg | grep avc` and `logcat -b all | grep -i denied` → expect **no denials** for
   `system_app` on `ifw_data_file`.
5. Switch the controller to **PM** in settings and disable a component again; confirm with
   `adb shell pm dump <pkg> | grep -A3 disabledComponents`.
6. Sanity: the "running apps" indicator is expected to be wrong/absent (shell-exec degradation).

---

## Why upstream can't just be dropped in

Two independent blockers, both confirmed by reading the sources, not assumed:

1. **Every privileged path in Blocker goes through an external helper.** `core/ifw-api`'s only
   `IfwFileSystem` implementation is `LibrootIfwFileSystem`, and all five operations (read, write,
   chmod, delete, list) run through `RootCommandExecutor` → librootkotlinx → a **root shell**. Same
   for the PM backend (`RootApiController`). Installing the upstream APK into `/system` changes
   nothing: it would still shell out to `su` and fail.
2. **"Only system applications can read/write the config directory" (upstream README) is about
   process UID, not install location.** `/data/system/ifw` is `system:system`; qualifying means
   running as **UID 1000**, which needs `sharedUserId="android.uid.system"` *and* the platform
   signature. Only a source rebuild can get there — a presigned APK can never be promoted.

⚠️ **And the obvious sepolicy shortcut does not exist.** `/data/system/ifw` inherits
`system_data_file`, and `system/sepolicy/private/app.te` carries an **unconditional**
`neverallow appdomain system_data_file:dir_file_class_set { create write … }`. `system_app` is in
`appdomain`, so it can never be granted write access to that label — the rule has no exemption list
to add ourselves to, and trying would fail the build's neverallow assertions. The directory needs
its **own type**. (An early read of this lane assumed `system_app.te` already allowed it; that was
wrong.)

## The shape of the fix

The happy discovery: **`RootCommand.execute()` bodies are already plain in-process code** — real
`java.io` calls and real `IPackageManager` / `IActivityManager` binder calls against in-tree hidden
API stubs (`core/component-controller/src/main/java/android/**`). librootkotlinx only *ships them
elsewhere to run*. As UID 1000 with the platform signature, that relocation is unnecessary: the same
bodies can run here. So the patch is a **transport swap**, not a reimplementation, and every
upstream feature (PM, IFW, force-stop, clear data/cache, uninstall, running services) comes along
for free.

Hidden-API restrictions don't apply — `ApplicationInfo.isSignedWithPlatformKey()` ⇒ enforcement
policy NONE. The bundled `hiddenapibypass` call becomes a harmless no-op.

### App patch (`~/Projects/blocker`, source drop of upstream `main` @ `58f16ac6`)

Six files. Every hook is guarded by `SystemPrivilege.isSystemUid`, so an ordinary (non-ROM) build of
this tree still behaves exactly like upstream.

| File | Change |
|---|---|
| `core/common/…/utils/SystemPrivilege.kt` | **new** — `isSystemUid` (`Process.myUid() == 1000`) + an `appContext` holder |
| `core/common/…/root/RootCommandExecutor.kt` | system UID → `command.execute()` in-process instead of via the root session |
| `core/common/…/utils/LibrootRootAvailabilityChecker.kt` | system UID → `isRootAvailable() = true` (gates `IfwController`, `AppStateCache`, controller `init()`) |
| `core/component-controller/…/root/api/RootApiCommands.kt` | use the app context instead of librootkotlinx's `systemContext` ⚠️ resolving `systemContext` in-process would start a **second ActivityThread** |
| `app-compose/…/BlockerApplication.kt` | publish `SystemPrivilege.appContext` |
| `app-compose/src/main/AndroidManifest.xml` | `sharedUserId="android.uid.system"` + `CHANGE_COMPONENT_ENABLED_STATE`, `INTERACT_ACROSS_USERS`, `FORCE_STOP_PACKAGES`, `CLEAR_APP_USER_DATA`, `DELETE_PACKAGES` (all granted by signature) |

Build-only edits, forced by the toolchain rather than by the feature:

- `compileSdk` 37 → 36 in `build-logic/…/KotlinAndroid.kt`. **API 37 does not exist yet** — the SDK
  repository manifests top out at 36 and the canary platform is a codename preview (`CinnamonBun`).
  36 is what the device runs, and `targetSdk` was already 36.
- `android.experimental.disableCompileSdkChecks=true` in `gradle.properties`: several Compose alpha
  AARs (`material3.adaptive`, `material3-window-size-class`) declare a compileSdk-37 floor in their
  AAR metadata. Their API 37 usage is version-guarded — a library genuinely needing API 37 symbols
  could not run on this device at all.
- `versionCode`/`versionName` pinned to 6419 (upstream commit count at the imported revision)
  instead of `git rev-list --count HEAD` — this is a tarball drop with no `.git`.

**Build environment (this machine):** `JAVA_HOME` must be a real **JDK 21** — the packaged
`java-21-openjdk-amd64` is a JRE with no `javac`, and both `jvmToolchain(21)` sites fail on it. A
Temurin JDK is unpacked at `~/.local/jdks/jdk-21.0.12+8`. SDK needs `platforms;android-36` +
`build-tools;36.0.0` (the bundled cmdline-tools 12.0 only understands SDK XML v3 and cannot see
newer packages, but 36 predates that cutoff).

```bash
cd ~/Projects/blocker && ANDROID_HOME=~/Android/Sdk JAVA_HOME=~/.local/jdks/jdk-21.0.12+8 \
  ./gradlew :app-compose:assembleFossRelease -PminifyWithR8=false
```

**Known degradation:** `RootCommandExecutor.run(...)` (shell exec of `pidof` / `dumpsys` / `am`) can't
work — `system_app` may not exec toolbox binaries. It's wrapped to return a failed `ShellResult`
rather than throw. Only affects the *legacy* command-flavour controllers and the "is this app
running" indicator; the running-**service** list uses `IActivityManager.getServices()` and is fine.

### ROM patch (`device/xiaomi/Mi8937`, all behind `TARGET_DEVICE_PEPITO`)

- `Blocker/Android.bp` — `android_app_import`, `certificate: "platform"`, **not** `privileged`.
  Non-privileged is deliberate: signature permissions are granted by signature alone, so a
  `/system/app` install needs no privapp-permissions allowlist entry (cf. VolumeTile, which bootlooped
  without one because it *is* privileged).
- `device.mk` — `PRODUCT_PACKAGES += Blocker`.
- `sepolicy/system_ext/private/ifw_data_file.te` — new `ifw_data_file` type, a **name-based
  `type_transition`** on `system_server` creating `ifw`, and `create_*_perms` for `system_server`
  (creates/reads/watches) and `system_app` (writes rules).
  ⭐ The `type_transition` is the load-bearing line: `file_contexts` only applies on **relabel**, not
  at creation, so without it `system_server`'s `mkdirs()` would produce a `system_data_file` dir and
  every write would be denied.
- `sepolicy/system_ext/private/file_contexts` — for repairing an existing `/data/system/ifw` with
  `restorecon -R` after a dirty flash. A wiped userdata (Kyle's normal flow) doesn't need it.
- `BoardConfig.mk` — `SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS +=` the above. Must be system_ext, not
  vendor/odm: `system_app`/`system_server` are core domains.

## Open items / risks

- [x] **Gradle build of the patched tree** — ✅ BUILD SUCCESSFUL 2026-08-03. `Blocker.apk` is
      **7.6 MB** (R8-minified; the unminified first pass was 24 MB, hence shipping the minified one).
      Verified in the built APK with `aapt2`: `sharedUserId="android.uid.system"`,
      `CHANGE_COMPONENT_ENABLED_STATE`, versionCode 6419, compileSdk/targetSdk 36. Verified in the
      dex that R8 kept what the patch needs — `Landroid/content/pm/IPackageManager;` unobfuscated
      (upstream's `consumer-proguard-rules.pro` keeps `android.content.pm.**` + `android.app.**`),
      plus `SystemPrivilege` and the `ANDROID_DATA` IFW-path logic.
- [x] **`uses-library` build trap** — the APK inherits optional `androidx.window.extensions` /
      `androidx.window.sidecar` from Compose, which Soong requires be acknowledged. `optional_uses_libs`
      is set in `Blocker/Android.bp` (same fix CarRadioApp needed). Caught pre-emptively; **this
      would otherwise have failed the ROM build.**
- [x] **`checkpolicy` neverallow check on the new .te** — ✅ **exit 0** (2026-08-03). Ran on
      Stellaris16 (no local `out/`): injected `type ifw_data_file, file_type, data_file_type,
      core_data_file_type;` plus the expanded `type_transition` + `allow` rules into a copy of
      `sepolicy_neverallows.checkpolicy.conf`, anchored after the `type system_app_data_file,` line.
      Method: PLAN.md §"Verifying SELinux policy changes".
- [x] **Does `sharedUserId` still install on A16?** ✅ Yes. `ParsingPackageUtils.parseSharedUser()`
      has no targetSdk gate; the only rejections are SDK/static-shared-library packages, and the
      "leaving shared user" migration path only triggers when `sharedUserMaxSdkVersion` is set,
      which we don't set.
- [ ] Default controller type is **IFW** (proto default), so the sepolicy work is on the
      out-of-box path, not optional.
- [ ] Security posture: this grants a large Compose app that fetches community rule sets over the
      network the system UID. Accepted for now; the paranoid alternative is an unprivileged app plus a
      minimal privileged writer behind a signature permission.
- [ ] Updates come only via ROM builds — our-key signing means F-Droid/Play/upstream APKs won't
      install over it.
- [ ] Release notes: warn that IFW-blocking GMS components can break push/sync in confusing ways.
      Ship with no default rules.

## Not a Play Integrity concern

Checked deliberately, since the build already fails integrity for unrelated reasons. DroidGuard keys
on tampering *tools* (`su`, Magisk/Zygisk, Xposed, Frida) and on the boot chain / signing key /
fingerprint — all of which this build's verdict already reflects. A platform-signed system-UID app is
what every OEM ships and carries no independent signal. (`ro.debuggable=1` on userdebug is a far
louder signal than anything in this lane.)
