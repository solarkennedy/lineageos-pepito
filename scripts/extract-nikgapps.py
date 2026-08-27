#!/usr/bin/env python3
# Extract a NikGapps flashable zip into an AOSP product-tree layout
# (vendor/pepito-gapps/): PRODUCT_COPY_FILES for plain files, and Soong
# android_app_import modules (+ PRODUCT_PACKAGES) for .apk files -- AOSP's
# build/make/core/Makefile hard-rejects any PRODUCT_COPY_FILES destination
# ending in .apk ("Prebuilt apk found in PRODUCT_COPY_FILES, use
# BUILD_PREBUILT instead!"), discovered by an actual failed build.
#
# NikGapps ships as a TWRP/Magisk-module installer, not AOSP build-system
# prebuilts: each AppSet/<Category>/<App>.zip payload uses "___" in place of
# "/" for its path segments (e.g. ___priv-app___Foo/Foo.apk decodes to
# priv-app/Foo/Foo.apk), and common/install.sh lists each app's destination
# partition (product or system_ext -- both fold into /system on pepito, see
# TARGET_COPY_OUT_* in device/xiaomi/Mi8937/BoardConfig.mk).
#
# Apps under a "priv-app" directory get privileged: true; apps under "app"
# don't. Anything under "overlay" (GmsCoreOverlay.apk from basic,
# AndroidAutoOverlay.apk from the AndroidAuto addon) is skipped --
# android_app_import has no clean way to place a prebuilt into
# <partition>/overlay/ instead of app/priv-app/, and it's a minor
# resource-only tweak, not a functional dependency.
#
# Re-running replaces product/, system_ext/, gapps.mk and Android.bp (NOT
# source/, where the zip itself lives, and NOT overrides/); nothing generated
# here should ever be hand-edited.
#
# To ship a newer APK than NikGapps provides, drop it at
# overrides/<ModuleName>.apk -- see OVERRIDES_DIRNAME below.
#
# Usage (pass the base package plus any addon zips -- all merged into one payload):
#   extract-nikgapps.py \
#       vendor/pepito-gapps/source/NikGapps-basic-arm64-16-20260222-signed.zip \
#       vendor/pepito-gapps/source/NikGapps-Addon-16-AndroidAuto-20260222-signed.zip
#
# The AndroidAuto addon ships AndroidAutoStubPrebuilt (a tiny Google-signed
# priv-app stub) + its privapp-permissions allowlist; a Play Store install of
# Android Auto then grafts onto the stub as an UPDATED_SYSTEM_APP, which is what
# clears gearhead's "Communication error 22 - not preinstalled" on a real car.
#
# NOTE: vendor/pepito-gapps is NOT part of the vendor/xiaomi git repo (that
# repo pushes to the public solarkennedy/proprietary_vendor_xiaomi on GitHub)
# and must never be added to a git repo that has a public remote -- it
# contains Google's proprietary GApps binaries, which is a real redistribution
# problem if pushed publicly. Keep it local-only, or in a private remote if
# you ever want it version-controlled. (There's a .gitignore in there too,
# but that only helps once/if this tree ends up inside a git working copy.)
import argparse
import io
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

TREE_ROOT = Path("/home/kyle/android/lineage-23")
DEFAULT_OUT = TREE_ROOT / "vendor" / "pepito-gapps"

PARTITION_VAR = {
    "product": "TARGET_COPY_OUT_PRODUCT",
    "system_ext": "TARGET_COPY_OUT_SYSTEM_EXT",
    "system": "TARGET_COPY_OUT_SYSTEM",
    "vendor": "TARGET_COPY_OUT_VENDOR",
}
PARTITION_SOONG_PROP = {
    "product": "product_specific",
    "system_ext": "system_ext_specific",
}

# AppSet payloads to drop entirely (keyed on the AppSet/<Category>/<App>.zip
# stem, which is also install.sh's manifest name). Excluding an app-set drops
# every file it ships, not just its .apk.
#
# GoogleClock: its PrebuiltDeskClockGoogle apk declares package
# com.android.deskclock -- the *same* package name as LineageOS's own
# DeskClock, but landing in priv-app, so it wins the collision and is then
# subject to privileged-permission enforcement. NikGapps writes its
# allowlists for com.google.android.deskclock (both
# com.google.android.deskclock.xml and NikGapps-privapp-permissions-google-p
# .xml), which never matches the real package, so
# CONTROL_DISPLAY_COLOR_TRANSFORMS and START_FOREGROUND_SERVICES_FROM_BACKGROUND
# stay unallowlisted and system_server throws IllegalStateException at
# AppIdPermissionPolicy.onSystemReady -> zygote death -> boot loop (diagnosed
# on-device 2026-07-16). Dropping the app-set leaves Lineage's DeskClock as
# the only clock, with no priv-app and no allowlist needed. The leftover
# NikGapps allowlist/sysconfig entries naming com.google.android.deskclock are
# inert once no such package is installed.
EXCLUDED_APP_SETS = {
    "GoogleClock",
}

# --- APK overrides -------------------------------------------------------
# NikGapps freezes some payloads for years (CarrierServices shipped
# 117.0/2022-08-08 in the 2026-02-22 basic package). Drop a replacement APK at
# overrides/<ModuleName>.apk -- ModuleName being the priv-app/app *directory*
# name as it appears in the tree, e.g. overrides/CarrierServices.apk -- and it
# is swapped in after extraction, with its privapp-permissions allowlist
# regenerated to match.
#
# overrides/ is NEVER wiped by a re-run (only product/, system_ext/, system/,
# vendor/, gapps.mk and Android.bp are), so an override survives re-extraction.
#
# Safety rails, all HARD FAILURES -- a bad override must break the build here,
# not bootloop the phone:
#   * signer cert digest must equal the APK being replaced. Google signs
#     CarrierServices with CN=rcsstack, which *defines* the
#     com.google.android.ims.* permissions Bugle holds; a different Google key
#     silently breaks the Bugle<->Jibe binding and looks like "RCS just won't
#     provision".
#   * package name must match.
#   * the override must correspond to a module that actually got extracted
#     (otherwise it is stale and silently doing nothing).
#
# The allowlist is regenerated as the UNION of what NikGapps shipped and what
# the override requests, across EVERY xml declaring that package -- note
# CarrierServices appears in both com.google.android.ims.xml *and*
# NikGapps-privapp-permissions-google-p.xml. A privileged permission that is
# requested but not allowlisted throws IllegalStateException in
# AppIdPermissionPolicy.onSystemReady -> zygote death -> boot loop; that is
# exactly the GoogleClock failure documented above. Union (never subtract)
# means we cannot drop an entry some other app still depends on.
OVERRIDES_DIRNAME = "overrides"


# Self-test args that make each tool exit 0 without doing real work. The tree's
# prebuilts/sdk/tools/linux/bin/apksigner is a wrapper that cannot find its own
# apksigner.jar in this checkout and fails with "can't find apksigner.jar" on
# *stdout* at rc=1 -- so candidates are probed, not merely found on disk.
_TOOL_SELFTEST = {"aapt2": ["version"], "apksigner": ["--version"]}
_TOOL_CACHE = {}


def _tool(name):
    """Locate a working build tool, preferring the tree's prebuilts but verifying each."""
    if name in _TOOL_CACHE:
        return _TOOL_CACHE[name]
    candidates = [
        TREE_ROOT / "prebuilts" / "sdk" / "tools" / "linux" / "bin" / name,
        TREE_ROOT / "prebuilts" / "sdk" / "tools" / name,
    ]
    found = shutil.which(name)
    if found:
        candidates.append(Path(found))
    tried = []
    for c in candidates:
        if not (c.is_file() and os.access(c, os.X_OK)):
            continue
        probe = subprocess.run([str(c)] + _TOOL_SELFTEST.get(name, ["--version"]),
                               capture_output=True, text=True)
        if probe.returncode == 0:
            _TOOL_CACHE[name] = str(c)
            return str(c)
        tried.append(f"{c} (rc={probe.returncode}: "
                     f"{(probe.stdout or probe.stderr).strip().splitlines()[0][:60] if (probe.stdout or probe.stderr).strip() else 'no output'})")
    detail = "\n  ".join(tried) if tried else "no candidate was executable"
    sys.exit(f"error: no working '{name}' found (needed to validate overrides):\n  {detail}")


def _apk_badging(apk):
    out = subprocess.run([_tool("aapt2"), "dump", "badging", str(apk)],
                         capture_output=True, text=True).stdout
    m = re.search(r"package: name='([^']+)'.*?versionCode='([^']+)'.*?versionName='([^']*)'", out)
    if not m:
        sys.exit(f"error: cannot read package info from {apk}")
    return m.group(1), int(m.group(2)), m.group(3)


def _apk_permissions(apk):
    out = subprocess.run([_tool("aapt2"), "dump", "permissions", str(apk)],
                         capture_output=True, text=True).stdout
    return {m.group(1) for m in re.finditer(r"^uses-permission: name='([^']+)'", out, re.M)}


def _apk_signer(apk):
    out = subprocess.run([_tool("apksigner"), "verify", "--print-certs", str(apk)],
                         capture_output=True, text=True).stdout
    m = re.search(r"Signer #1 certificate SHA-256 digest:\s*([0-9a-f]+)", out)
    if not m:
        sys.exit(f"error: cannot read signing certificate from {apk} (unsigned?)")
    return m.group(1)


def _rewrite_allowlist(xml_path, package, perms):
    """Union `perms` into the <privapp-permissions package=...> block. Returns added set."""
    text = xml_path.read_text()
    pat = re.compile(
        r'(<privapp-permissions\s+package="' + re.escape(package) + r'"\s*>)(.*?)(</privapp-permissions>)',
        re.S)
    m = pat.search(text)
    if not m:
        return set()
    existing = set(re.findall(r'name="([^"]+)"', m.group(2)))
    added = perms - existing
    if not added:
        return set()
    indent = "\t\t"
    body = "\n".join(f'{indent}<permission name="{p}"/>' for p in sorted(existing | perms))
    xml_path.write_text(text[:m.start()] + m.group(1) + "\n" + body + "\n\t" + m.group(3) + text[m.end():])
    return added


def apply_overrides(out_dir, apk_modules):
    """Swap in overrides/<ModuleName>.apk and refresh their allowlists."""
    ov_dir = out_dir / OVERRIDES_DIRNAME
    if not ov_dir.is_dir():
        return
    overrides = sorted(ov_dir.glob("*.apk"))
    if not overrides:
        return

    for ov in overrides:
        module = ov.stem
        if module not in apk_modules:
            sys.exit(f"error: override {ov.name} names module '{module}', which was not "
                     f"extracted from any zip -- stale override, remove it or fix the name")
        partition, rel, privileged = apk_modules[module]
        target = out_dir / partition / rel

        old_pkg, old_vc, old_vn = _apk_badging(target)
        new_pkg, new_vc, new_vn = _apk_badging(ov)
        if old_pkg != new_pkg:
            sys.exit(f"error: override {ov.name} is package '{new_pkg}' but replaces "
                     f"'{old_pkg}' -- refusing")
        old_sig, new_sig = _apk_signer(target), _apk_signer(ov)
        if old_sig != new_sig:
            sys.exit(f"error: override {ov.name} signer mismatch -- refusing.\n"
                     f"  shipped:  {old_sig}\n  override: {new_sig}\n"
                     f"  A different signing key breaks signature-protected permissions "
                     f"this package defines for other apps.")
        if new_vc < old_vc:
            print(f"warning: override {ov.name} versionCode {new_vc} is OLDER than the "
                  f"shipped {old_vc} -- swapping anyway", file=sys.stderr)

        target.write_bytes(ov.read_bytes())
        print(f"override: {module} {old_vn} ({old_vc}) -> {new_vn} ({new_vc})")

        if not privileged:
            continue
        perms = _apk_permissions(ov)
        touched = []
        for xml_path in sorted((out_dir / partition / "etc" / "permissions").glob("*.xml")):
            added = _rewrite_allowlist(xml_path, new_pkg, perms)
            if added:
                touched.append((xml_path, added))
        if touched:
            for xml_path, added in touched:
                print(f"  allowlist {xml_path.relative_to(out_dir)}: +{len(added)} "
                      f"({', '.join(sorted(added))})")
        else:
            print("  allowlist: already covers every requested permission")


def parse_install_manifest(zf):
    """Return {app_name: partition} from common/install.sh's Name,Size,Partition lines."""
    text = zf.read("common/install.sh").decode()
    manifest = {}
    for line in text.splitlines():
        m = re.match(r"^\s*(\w+),(\d+),(\w+)\s*$", line)
        if m:
            name, _size, partition = m.groups()
            manifest[name] = partition
    return manifest


def decode_member_path(name):
    """NikGapps encodes '/' as '___' in each payload's path segments."""
    return name.replace("___", "/").lstrip("/")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("zips", nargs="+", metavar="zip",
                    help="path(s) to NikGapps flashable zip(s): the base package "
                         "plus any addon zips (e.g. AndroidAuto). Every zip's "
                         "AppSets are merged into one payload.")
    ap.add_argument("--out", default=str(DEFAULT_OUT), help="output vendor tree root")
    args = ap.parse_args()

    zip_paths = [Path(z).resolve() for z in args.zips]
    out_dir = Path(args.out)

    # Only wipe the generated subset, not the whole dir -- the zip itself may
    # live under out_dir/source/, and rmtree'ing that out from under an
    # already-open zipfile handle would be bad news on a re-run.
    for name in ("product", "system_ext", "system", "vendor", "gapps.mk", "Android.bp"):
        p = out_dir / name
        if p.is_dir():
            shutil.rmtree(p)
        elif p.exists():
            p.unlink()
    out_dir.mkdir(parents=True, exist_ok=True)

    copy_files = {}       # (partition, rel) -> True, for plain PRODUCT_COPY_FILES (some
                           # files, e.g. dialer.support.jar, ship identically in more than
                           # one NikGapps app-set payload -- dedupe by destination)
    apk_modules = {}      # module_name -> (partition, rel, privileged)
    total_bytes = 0
    skipped = []

    for zip_path in zip_paths:
        with zipfile.ZipFile(zip_path) as zf:
            manifest = parse_install_manifest(zf)
            app_zips = [n for n in zf.namelist() if re.match(r"^AppSet/[^/]+/[^/]+\.zip$", n)]

            for member in app_zips:
                app_name = Path(member).stem
                if app_name in EXCLUDED_APP_SETS:
                    skipped.append(f"{app_name}: excluded (see EXCLUDED_APP_SETS)")
                    continue
                partition = manifest.get(app_name)
                if partition is None:
                    skipped.append(f"{app_name}: not in install.sh manifest")
                    continue
                if partition not in PARTITION_VAR:
                    skipped.append(f"{app_name}: unknown partition '{partition}'")
                    continue

                with zipfile.ZipFile(io.BytesIO(zf.read(member))) as app_zf:
                    for inner in app_zf.namelist():
                        if inner in ("installer.sh", "uninstaller.sh") or inner.endswith("/"):
                            continue
                        rel = decode_member_path(inner)
                        parts = rel.split("/")
                        category = parts[0] if parts else ""

                        if rel.endswith(".apk"):
                            if category not in ("app", "priv-app"):
                                skipped.append(f"{rel}: .apk under '{category}/', not app/priv-app -- skipped")
                                continue
                            module_name = Path(rel).parent.name
                            dest = out_dir / partition / rel
                            dest.parent.mkdir(parents=True, exist_ok=True)
                            payload = app_zf.read(inner)
                            dest.write_bytes(payload)
                            total_bytes += len(payload)
                            apk_modules[module_name] = (partition, rel, category == "priv-app")
                            continue

                        dest = out_dir / partition / rel
                        dest.parent.mkdir(parents=True, exist_ok=True)
                        payload = app_zf.read(inner)
                        dest.write_bytes(payload)
                        total_bytes += len(payload)
                        copy_files[(partition, rel)] = True

    if skipped:
        print("warning: skipped entries:", file=sys.stderr)
        for s in skipped:
            print(f"  {s}", file=sys.stderr)

    apply_overrides(out_dir, apk_modules)

    sorted_copy_files = sorted(copy_files)
    sorted_apk_modules = sorted(apk_modules.items())

    # --- Android.bp: one android_app_import per prebuilt apk ----------------
    bp_path = out_dir / "Android.bp"
    with open(bp_path, "w") as f:
        f.write("// Auto-generated by scripts/extract-nikgapps.py -- do not hand-edit.\n\n")
        for module_name, (partition, rel, privileged) in sorted_apk_modules:
            f.write("android_app_import {\n")
            f.write(f'    name: "{module_name}",\n')
            f.write(f'    apk: "{partition}/{rel}",\n')
            f.write("    presigned: true,\n")
            # Google ships these targeting API 30+ (signature v2); Soong's
            # check_prebuilt_presigned_apk.py refuses to build them without
            # this, since further processing would break the v2 signature.
            f.write("    preprocessed: true,\n")
            if privileged:
                f.write("    privileged: true,\n")
            f.write("    dex_preopt: {\n        enabled: false,\n    },\n")
            f.write(f"    {PARTITION_SOONG_PROP[partition]}: true,\n")
            f.write("}\n\n")

    # --- gapps.mk: PRODUCT_COPY_FILES for plain files, PRODUCT_PACKAGES for apks
    mk_path = out_dir / "gapps.mk"
    with open(mk_path, "w") as f:
        f.write("# Auto-generated by scripts/extract-nikgapps.py -- do not hand-edit.\n")
        f.write(f"# Source: {', '.join(p.name for p in zip_paths)}\n\n")

        if sorted_copy_files:
            f.write("PRODUCT_COPY_FILES += \\\n")
            lines = [
                f"    vendor/pepito-gapps/{partition}/{rel}:$({PARTITION_VAR[partition]})/{rel}"
                for partition, rel in sorted_copy_files
            ]
            f.write(" \\\n".join(lines))
            f.write("\n\n")

        if sorted_apk_modules:
            f.write("PRODUCT_PACKAGES += \\\n")
            lines = [f"    {module_name}" for module_name, _ in sorted_apk_modules]
            f.write(" \\\n".join(lines))
            f.write("\n")

    print(
        f"{out_dir}: {len(copy_files)} plain files + {len(apk_modules)} apk modules, "
        f"{total_bytes / 1_000_000:.0f} MB, wrote {mk_path} and {bp_path}"
    )


if __name__ == "__main__":
    main()
