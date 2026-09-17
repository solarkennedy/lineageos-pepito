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

    backfilled = 0
    if args.backfill:
        with open(args.backfill, encoding="utf-8") as f:
            sections = changelog_sections(f.read())
        for e in data["response"]:
            if e.get("changelog"):
                continue
            tag = release_tag_from_url(e.get("url"))
            if tag is None or tag not in sections:
                continue
            cleaned = clean_changelog(sections[tag])
            if not cleaned:
                continue
            e["changelog"] = cleaned
            e.setdefault("changelog_url", f"https://github.com/{args.repo}/releases/tag/{tag}")
            backfilled += 1

    os.makedirs(os.path.dirname(os.path.abspath(args.output)) or ".", exist_ok=True)
    with open(args.output, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")

    print(
        f"{args.output}: {len(data['response'])} entries, added {filename} "
        f"({size / 1_000_000:.0f} MB, sha256 {digest[:12]}..., "
        f"changelog {changelog_bytes} B, backfilled {backfilled})"
    )


if __name__ == "__main__":
    main()
