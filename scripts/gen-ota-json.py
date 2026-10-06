#!/usr/bin/env python3
# Generate/update the static OTA JSON consumed by the LineageOS Updater app
# (packages/apps/Updater), for builds hosted as GitHub Release assets instead
# of a real OTA server. Point the device's lineage_updater_uri overlay at the
# raw.githubusercontent.com URL of the JSON this script writes.
#
# Usage:
#   gen-ota-json.py <zip> --device pepito --version 24.0 \
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
#
# Two output formats (--format):
#   v2 (default on the lineageos24.0 branch): the LineageOS API-v2 shape read by
#     the 24.0 (Android 17) Updater, a top-level array of
#     {"datetime", "type", "version", "files": [{"filename", "sha256", "size",
#     "url", "os_sdk_level", "os_patch_level", "ota_property_files"}]}. The SDK
#     and patch levels come from the zip's own META-INF/com/android/metadata.
#     The 23.2 Updater fork reads this shape too (packages/apps/Updater 6dd23de),
#     which is how the final 23.2 release follows this feed for the upgrade.
#   legacy: the {"response": [{flat entry}]} shape of the 23.2 feed.
# Writing v2 over an existing legacy file starts a fresh feed: entries from the
# other format (e.g. 23.2 builds inherited from the 23.2 branch) are dropped, so
# a 24.0 phone is never offered them.
#
# The 24.0 Updater's NetworkUpdate is @JsonIgnoreUnknownKeys, so the optional
# "changelog"/"changelog_url" keys below are safe even for a stock Updater; our
# fork (packages/apps/Updater pepito-24) shows them as "What's new".
#
# Optional per-entry release notes: --changelog-file FILE embeds the (cleaned)
# section as a "changelog" string and --changelog-url URL as "changelog_url".
# Both keys are OPTIONAL and IGNORED by the stock LineageOS Updater (its parser
# only reads the seven keys it knows); our patched Updater shows them under
# "What's new". Existing entries are passed through untouched; --backfill
# CHANGELOG.md fills the keys on kept entries that lack them, matching each
# entry's release tag (from its url) to a "## <tag>" section.
import argparse
import hashlib
import json
import os
import re
import zipfile

# Upper bound on the embedded notes, so one huge release can't bloat the feed
# every phone polls. Truncated at a line boundary with a marker.
CHANGELOG_MAX_BYTES = 16 * 1024
# Sections that are release-engineering noise, not ROM content.
CHANGELOG_DROP_SECTIONS = ("landing (docs/scripts)",)


def clean_changelog(text):
    """Turn a gen-changelog.sh section into user-facing notes.

    Drops the "## VERSION (date)" heading, the "(since <tag>)" suffixes on
    section headers, "first tagged ... no prior anchor" bullets, sections left
    empty, and the sections in CHANGELOG_DROP_SECTIONS. Returns "" when
    nothing user-facing remains (the caller then omits the key entirely).
    """
    sections = []   # [(header, [bullets])]
    header = None
    bullets = []

    def flush():
        if header is not None and bullets:
            sections.append((header, list(bullets)))

    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip():
            continue
        if line.startswith("## ") and not line.startswith("### "):
            continue                                    # version heading
        if line.startswith("### "):
            flush()
            header = re.sub(r"\s*\((?:since|first tagged)[^)]*\)\s*$", "", line[4:]).strip()
            bullets = []
            if header in CHANGELOG_DROP_SECTIONS:
                header = None
            continue
        if header is None:
            continue                                    # text outside any section
        if re.search(r"first tagged in .*no prior anchor", line):
            continue
        if line.startswith("- ") or line.startswith("* "):
            bullets.append("- " + line[2:].strip())
        else:
            bullets.append(line.strip())
    flush()

    out = []
    for h, bs in sections:
        out.append(f"### {h}")
        out.extend(bs)
        out.append("")
    result = "\n".join(out).strip()

    if len(result.encode("utf-8")) > CHANGELOG_MAX_BYTES:
        kept = []
        size = 0
        for line in result.splitlines():
            n = len(line.encode("utf-8")) + 1
            if size + n > CHANGELOG_MAX_BYTES - 16:
                break
            kept.append(line)
            size += n
        result = "\n".join(kept).rstrip() + "\n\u2026"
    return result


def changelog_sections(changelog_md):
    """Map "<tag>" -> raw section text for every "## <tag> ..." in CHANGELOG.md."""
    sections = {}
    tag = None
    buf = []
    for line in changelog_md.splitlines():
        m = re.match(r"^## (\S+)", line)
        if m:
            if tag is not None:
                sections[tag] = "\n".join(buf)
            tag = m.group(1)
            buf = [line]
        elif tag is not None:
            buf.append(line)
    if tag is not None:
        sections[tag] = "\n".join(buf)
    return sections


def release_tag_from_url(url):
    m = re.search(r"/releases/download/([^/]+)/", url or "")
    return m.group(1) if m else None


def ota_metadata(path):
    """key=value pairs from the OTA zip's META-INF/com/android/metadata."""
    with zipfile.ZipFile(path) as z:
        text = z.read("META-INF/com/android/metadata").decode("utf-8")
    meta = {}
    for line in text.splitlines():
        k, sep, v = line.partition("=")
        if sep:
            meta[k.strip()] = v.strip()
    return meta


# Field access that works for both entry shapes, so the merge / prune /
# backfill logic below is shared.
def entry_type(e):
    return e.get("type") if "files" in e else e.get("romtype")


def entry_filename(e):
    return e["files"][0].get("filename") if "files" in e else e.get("filename")


def entry_url(e):
    return e["files"][0].get("url") if "files" in e else e.get("url")


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
    ap.add_argument("--version", required=True, help="lineage version, e.g. 24.0")
    ap.add_argument("--romtype", default="nightly", help="build/release channel (default: nightly)")
    ap.add_argument("--repo", required=True, help="owner/repo hosting the GitHub Release, e.g. you/lineageos-pepito")
    ap.add_argument("--tag", required=True, help="release tag the zip is attached to")
    ap.add_argument("--output", required=True, help="JSON file to write/update")
    ap.add_argument("--format", choices=("v2", "legacy"), default="v2",
                    help="feed shape: v2 (24.0 Updater, default) or legacy (23.2 Updater)")
    ap.add_argument("--keep", type=int, default=5, help="entries to keep per romtype (default: 5)")
    ap.add_argument("--datetime", type=int, help="override build datetime (unix epoch); default = zip mtime")
    ap.add_argument("--changelog-file", help="markdown section (gen-changelog.sh output) to embed, cleaned, as 'changelog'")
    ap.add_argument("--changelog-url", help="URL to embed as 'changelog_url' (e.g. the GitHub release page)")
    ap.add_argument("--backfill", metavar="CHANGELOG_MD",
                    help="fill 'changelog' on kept entries that lack it, from the matching '## <tag>' section of this file")
    args = ap.parse_args()

    filename = os.path.basename(args.zip)
    size = os.path.getsize(args.zip)
    digest = sha256sum(args.zip)
    dt = args.datetime or int(os.path.getmtime(args.zip))
    url = f"https://github.com/{args.repo}/releases/download/{args.tag}/{filename}"

    if args.format == "v2":
        meta = ota_metadata(args.zip)
        file_info = {
            "filename": filename,
            "sha256": digest,
            "size": size,
            "url": url,
        }
        if meta.get("post-sdk-level"):
            file_info["os_sdk_level"] = int(meta["post-sdk-level"])
        if meta.get("post-security-patch-level"):
            file_info["os_patch_level"] = meta["post-security-patch-level"]
        if meta.get("ota-property-files"):
            file_info["ota_property_files"] = meta["ota-property-files"]
        entry = {
            "datetime": dt,
            "type": args.romtype,
            "version": args.version,
            "files": [file_info],
        }
    else:
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
    changelog_bytes = 0
    if args.changelog_file:
        with open(args.changelog_file, encoding="utf-8") as f:
            cleaned = clean_changelog(f.read())
        if cleaned:
            entry["changelog"] = cleaned
            changelog_bytes = len(cleaned.encode("utf-8"))
    if args.changelog_url:
        entry["changelog_url"] = args.changelog_url

    entries = []
    if os.path.exists(args.output):
        with open(args.output) as f:
            existing = json.load(f)
        existing_is_v2 = isinstance(existing, list)
        if existing_is_v2 == (args.format == "v2"):
            entries = existing if existing_is_v2 else existing.get("response", [])
        else:
            print(f"note: {args.output} is in the other feed format; starting a fresh {args.format} feed")

    # Drop any existing entry for this exact file (re-run after re-signing), then add the new one.
    entries = [e for e in entries if entry_filename(e) != filename]
    entries.append(entry)

    # Keep only the newest --keep entries per romtype, so the JSON never points at a
    # release asset you've since deleted from GitHub.
    by_type = {}
    for e in entries:
        by_type.setdefault(entry_type(e), []).append(e)
    kept = []
    for group in by_type.values():
        group.sort(key=lambda e: e["datetime"], reverse=True)
        kept.extend(group[: args.keep])
    kept.sort(key=lambda e: e["datetime"], reverse=True)
    entries = kept

    backfilled = 0
    if args.backfill:
        with open(args.backfill, encoding="utf-8") as f:
            sections = changelog_sections(f.read())
        for e in entries:
            if e.get("changelog"):
                continue
            tag = release_tag_from_url(entry_url(e))
            if tag is None or tag not in sections:
                continue
            cleaned = clean_changelog(sections[tag])
            if not cleaned:
                continue
            e["changelog"] = cleaned
            e.setdefault("changelog_url", f"https://github.com/{args.repo}/releases/tag/{tag}")
            backfilled += 1

    os.makedirs(os.path.dirname(os.path.abspath(args.output)) or ".", exist_ok=True)
    data = entries if args.format == "v2" else {"response": entries}
    with open(args.output, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")

    print(
        f"{args.output}: {len(entries)} {args.format} entries, added {filename} "
        f"({size / 1_000_000:.0f} MB, sha256 {digest[:12]}..., "
        f"changelog {changelog_bytes} B, backfilled {backfilled})"
    )


if __name__ == "__main__":
    main()
