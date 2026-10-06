#!/usr/bin/env python3
# audit-privapp-permissions.py — offline check that every privileged
# permission a priv-app requests is granted by some privapp-permissions
# allowlist, BEFORE flashing.
#
# Why: the build sets ro.control_privapp_permissions=enforce. A priv-app that
# requests a signature|privileged permission with no matching
# <privapp-permissions> entry stops the boot (PackageManager throws in
# system_server; memory: privapp-allowlist-bootloop). Prebuilt GApps carry
# allowlists written for one Android version, so a new platform release can
# add privileged permissions they request but do not grant.
#
# Protection levels come from the built platform (framework-res.apk and every
# APK in the image that DEFINES permissions), so the check is against the exact
# Android the image ships. Platform-signed apps are skipped (signature grants
# cover them).
#
# Usage (on the build server, after a build):
#   audit-privapp-permissions.py --tree ~/android/lineage-24 [--apps-dir DIR ...]
# Default apps dir: <tree>/vendor/pepito-gapps. Exit 1 if anything is missing.
import argparse
import glob
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


def aapt2(tree):
    return os.path.join(tree, "out/host/linux-x86/bin/aapt2")


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def defined_permissions(aapt, apk):
    """{name: protectionLevel string} for permissions an APK defines."""
    out = run([aapt, "dump", "xmltree", "--file", "AndroidManifest.xml", apk])
    perms = {}
    cur = None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("E: "):
            # any element ends the previous <permission>; save it first
            if cur and cur["name"]:
                perms[cur["name"]] = cur["level"]
            cur = None
            if s.startswith("E: permission ") or s == "E: permission":
                cur = {"name": None, "level": ""}
            continue
        if cur is None:
            continue
        m = re.search(r'A: http://schemas.android.com/apk/res/android:name\(0x[0-9a-f]+\)="([^"]+)"', s)
        if m:
            cur["name"] = m.group(1)
        # aapt2 prints either "=0x00000012" or "=(type 0x11)0x12"
        m = re.search(r'android:protectionLevel\(0x[0-9a-f]+\)=(?:\(type 0x[0-9a-f]+\))?(0x[0-9a-f]+)', s)
        if m:
            cur["level"] = m.group(1)
    if cur and cur["name"]:
        perms[cur["name"]] = cur["level"]
    return perms


PRIVILEGED_FLAG = 0x10  # PermissionInfo.PROTECTION_FLAG_PRIVILEGED


def is_privileged(level_hex):
    try:
        return bool(int(level_hex, 16) & PRIVILEGED_FLAG)
    except ValueError:
        return False


def requested_permissions(aapt, apk):
    out = run([aapt, "dump", "permissions", apk])
    pkg = None
    perms = set()
    for line in out.splitlines():
        m = re.match(r"package: (\S+)", line.strip())
        if m:
            pkg = m.group(1)
        m = re.match(r"uses-permission: name='([^']+)'", line.strip())
        if m:
            perms.add(m.group(1))
    return pkg, perms


def allowlists(paths):
    """{package: set(granted perms)} from every privapp-permissions XML found."""
    grants = {}
    for root_dir in paths:
        for path in glob.glob(os.path.join(root_dir, "**/*.xml"), recursive=True):
            try:
                root = ET.parse(path).getroot()
            except ET.ParseError:
                continue
            for pp in root.iter("privapp-permissions"):
                pkg = pp.get("package")
                s = grants.setdefault(pkg, set())
                for p in pp.iter("permission"):
                    s.add(p.get("name"))
    return grants


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", required=True)
    ap.add_argument("--apps-dir", action="append",
                    help="dir(s) holding the priv-apps to audit (default: <tree>/vendor/pepito-gapps)")
    ap.add_argument("--allowlist-dir", action="append",
                    help="extra dir(s) of privapp-permissions XMLs (default: the apps dirs + the built image's etc/permissions)")
    args = ap.parse_args()

    tree = os.path.expanduser(args.tree)
    aapt = aapt2(tree)
    out = os.path.join(tree, "out/target/product/Mi8937")
    apps_dirs = args.apps_dir or [os.path.join(tree, "vendor/pepito-gapps")]

    # Protection levels from everything the image defines permissions in.
    levels = {}
    platform_apks = [os.path.join(out, "system/framework/framework-res.apk")]
    platform_apks += glob.glob(os.path.join(out, "system/**/*.apk"), recursive=True)
    # The audited apps define privileged permissions too (e.g. GSF's
    # WRITE_GSERVICES); a vanilla image does not contain them.
    for apps_dir in apps_dirs:
        platform_apks += glob.glob(os.path.join(apps_dir, "**/*.apk"), recursive=True)
    for apk in platform_apks:
        for name, level in defined_permissions(aapt, apk).items():
            levels.setdefault(name, level)

    grant_dirs = list(apps_dirs) + (args.allowlist_dir or [])
    grant_dirs += [os.path.join(out, d) for d in
                   ("system/etc/permissions", "system/product/etc/permissions",
                    "system/system_ext/etc/permissions", "product/etc/permissions",
                    "system_ext/etc/permissions")]
    grants = allowlists(grant_dirs)

    missing_total = 0
    for apps_dir in apps_dirs:
        for apk in sorted(glob.glob(os.path.join(apps_dir, "**/priv-app/**/*.apk"), recursive=True)
                          + glob.glob(os.path.join(apps_dir, "overrides/*.apk"))):
            pkg, req = requested_permissions(aapt, apk)
            if not pkg:
                continue
            priv = sorted(p for p in req if is_privileged(levels.get(p, "")))
            missing = [p for p in priv if p not in grants.get(pkg, set())]
            rel = os.path.relpath(apk, apps_dir)
            print(f"{pkg:45s} {len(priv):3d} privileged, {len(missing):3d} missing  ({rel})")
            for p in missing:
                print(f"    MISSING {p}")
            missing_total += len(missing)

    print(f"\n{missing_total} missing privileged grant(s); {len(levels)} platform permissions known")
    sys.exit(1 if missing_total else 0)


if __name__ == "__main__":
    main()
