#!/usr/bin/env python3
# Generate/update the static OTA JSON consumed by the LineageOS Updater app
# (packages/apps/Updater), for builds hosted as GitHub Release assets instead
# of a real OTA server. Point the device's lineage_updater_uri overlay at the
# raw.githubusercontent.com URL of the JSON this script writes.
#
# Usage:
#   gen-ota-json.py <zip> --device pepito --version 23.2 \
#       --repo you/lineageos-pepito --tag 20260714 --output pepito.json
#
# Keep --output at the repo root, not in a subdirectory: lineage_updater_uri
# is an Android system property, capped at 91 bytes (PROP_VALUE_MAX) — the
# raw.githubusercontent.com URL has very little room to spare already.
#
# Re-running with --output pointed at an existing file merges: the new build
# is added, any earlier entry for the same filename is replaced (re-run after
# re-signing), and only the newest --keep entries per romtype are kept (older
# release assets you've deleted from GitHub would otherwise 404 for clients).
import argparse
import hashlib
import json
import os


def sha256sum(path, buf_size=1024 * 1024):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(buf_size):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description="Generate/update static LineageOS Updater OTA JSON from a GitHub Release asset.")
    ap.add_argument("zip", help="path to the signed OTA zip")
    ap.add_argument("--device", required=True, help="device codename, e.g. pepito")
    ap.add_argument("--version", required=True, help="lineage version, e.g. 23.2")
    ap.add_argument("--romtype", default="nightly", help="build/release channel (default: nightly)")
    ap.add_argument("--repo", required=True, help="owner/repo hosting the GitHub Release, e.g. you/lineageos-pepito")
    ap.add_argument("--tag", required=True, help="release tag the zip is attached to")
    ap.add_argument("--output", required=True, help="JSON file to write/update")
    ap.add_argument("--keep", type=int, default=5, help="entries to keep per romtype (default: 5)")
    ap.add_argument("--datetime", type=int, help="override build datetime (unix epoch); default = zip mtime")
    args = ap.parse_args()

    filename = os.path.basename(args.zip)
    size = os.path.getsize(args.zip)
    digest = sha256sum(args.zip)
    dt = args.datetime or int(os.path.getmtime(args.zip))
    url = f"https://github.com/{args.repo}/releases/download/{args.tag}/{filename}"

    entry = {
        "datetime": dt,
        "filename": filename,
        "id": digest,
        "sha256": digest,  # some Updater forks read this key instead of "id"
        "romtype": args.romtype,
        "size": size,
        "url": url,
        "version": args.version,
    }

    data = {"response": []}
    if os.path.exists(args.output):
        with open(args.output) as f:
            data = json.load(f)

    # Drop any existing entry for this exact file (re-run after re-signing), then add the new one.
    data["response"] = [e for e in data["response"] if e.get("filename") != filename]
    data["response"].append(entry)

    # Keep only the newest --keep entries per romtype, so the JSON never points at a
    # release asset you've since deleted from GitHub.
    by_type = {}
    for e in data["response"]:
        by_type.setdefault(e.get("romtype"), []).append(e)
    kept = []
    for entries in by_type.values():
        entries.sort(key=lambda e: e["datetime"], reverse=True)
        kept.extend(entries[: args.keep])
    kept.sort(key=lambda e: e["datetime"], reverse=True)
    data["response"] = kept

    os.makedirs(os.path.dirname(os.path.abspath(args.output)) or ".", exist_ok=True)
    with open(args.output, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")

    print(
        f"{args.output}: {len(data['response'])} entries, added {filename} "
        f"({size / 1_000_000:.0f} MB, sha256 {digest[:12]}...)"
    )


if __name__ == "__main__":
    main()
