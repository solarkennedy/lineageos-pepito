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
# source/, where the zip itself lives -- see below); nothing generated here
# should ever be hand-edited.
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
import re
import shutil
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
