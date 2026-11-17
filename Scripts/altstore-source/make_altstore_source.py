#!/usr/bin/env python3
"""
Write an AltStore / SideStore / Feather source file for a freshly built IPA.

AltStore refuses to install an app whose bundle ID, version, hash or permissions
differ from what the source says, so everything that can be read from the IPA is
read from the IPA instead of being typed in:

  * bundle ID, version, build number, minimum iOS   <- Info.plist of the app
  * privacy permissions                             <- *UsageDescription keys in the Info.plists
  * entitlements                                    <- code signature of the app and its extensions
  * size and SHA-256                                <- the IPA file itself

The output is attached to the GitHub release next to the IPA, so
https://github.com/<owner>/<repo>/releases/latest/download/altstore-source.json
always describes the newest published build.

Pure Python 3 standard library (runs on the GitHub macOS runner as it is).

Usage:
  python3 make_altstore_source.py App.ipa --repo OWNER/REPO --tag TAG \
      [--sha COMMIT] [--run-number N] [--notes "release notes"] [--out altstore-source.json]

Exit status: 0 on success, 2 if the IPA could not be read.
"""

import argparse
import datetime
import hashlib
import json
import os
import plistlib
import re
import struct
import sys
import zipfile
from urllib.parse import quote

# --- what AltStore shows --------------------------------------------------------
SOURCE_NAME = "uYouEnhanced Bugfixes"
SOURCE_SUBTITLE = "uYouEnhanced with bug fixes"
APP_NAME = "uYouEnhanced (Bugfixes)"
DEVELOPER = "arichornlover & contributors (bugfix fork)"
DESCRIPTION = (
    "An unofficial uYouEnhanced build that attempts to fix bugs, starting with "
    "Chromecast casting on sideloaded builds."
)
CATEGORY = "photo-video"
TINT_COLOR = "E81E8A"
# Hosted from this repository, so it needs no extra files.
ICON_PATH = "Localizations/uYouPlus.bundle/AppIcons/uYouPlus.png"
FALLBACK_MIN_OS = "16.0"

# Mach-O / code signature constants
FAT_MAGIC = 0xCAFEBABE
CPU_TYPE_ARM64 = 0x0100000C
MACHO_64_MAGIC = 0xFEEDFACF
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171

# AltStore says these need not be listed because every app has them.
IMPLICIT_ENTITLEMENTS = {"application-identifier", "com.apple.developer.team-identifier"}


def fail(msg):
    print("::error title=AltStore source::%s" % msg, file=sys.stderr)
    sys.exit(2)


def warn(msg):
    print("::warning title=AltStore source::%s" % msg, file=sys.stderr)


def macho_entitlements(data):
    """Entitlements embedded in the code signature of a Mach-O, or None if there are none."""
    try:
        off = 0
        if struct.unpack_from(">I", data, 0)[0] == FAT_MAGIC:
            count = struct.unpack_from(">I", data, 4)[0]
            for i in range(count):
                cputype, _sub, slice_off, _size, _align = struct.unpack_from(">IIIII", data, 8 + i * 20)
                if cputype == CPU_TYPE_ARM64:
                    off = slice_off
                    break
            else:
                return None
        if struct.unpack_from("<I", data, off)[0] != MACHO_64_MAGIC:
            return None
        ncmds = struct.unpack_from("<I", data, off + 16)[0]
        pos = off + 32
        codesig = None
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", data, pos)
            if cmd == LC_CODE_SIGNATURE:
                codesig = struct.unpack_from("<II", data, pos + 8)
                break
            pos += cmdsize
        if not codesig:
            return None
        base = off + codesig[0]
        magic, _length, count = struct.unpack_from(">III", data, base)
        if magic != CSMAGIC_EMBEDDED_SIGNATURE:
            return None
        for i in range(count):
            _kind, blob_off = struct.unpack_from(">II", data, base + 12 + i * 8)
            blob_magic, blob_len = struct.unpack_from(">II", data, base + blob_off)
            if blob_magic == CSMAGIC_EMBEDDED_ENTITLEMENTS:
                return plistlib.loads(bytes(data[base + blob_off + 8:base + blob_off + blob_len]))
    except Exception:
        return None
    return None


def bundle_entitlements(zf, info, folder, label):
    """Entitlements of the executable of the bundle at `folder` (empty dict if none)."""
    exe = info.get("CFBundleExecutable")
    if not exe:
        warn("%s has no CFBundleExecutable; declaring no entitlements for it" % label)
        return {}
    try:
        data = zf.read(folder + "/" + exe)
    except KeyError:
        warn("%s: executable %s is missing from the IPA" % (label, exe))
        return {}
    ents = macho_entitlements(data)
    if ents is None:
        print("  %s: no entitlements in its code signature" % label)
        return {}
    return ents


def privacy_keys(info):
    return {k: v for k, v in info.items() if k.endswith("UsageDescription") and isinstance(v, str)}


def main():
    ap = argparse.ArgumentParser(description="Write an AltStore source file for an IPA.")
    ap.add_argument("ipa")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"), help="OWNER/REPO that hosts the release")
    ap.add_argument("--tag", required=True, help="tag of the release the IPA is uploaded to")
    ap.add_argument("--sha", default=os.environ.get("GITHUB_SHA"), help="commit the build is from (pins the icon URL)")
    ap.add_argument("--run-number", default=os.environ.get("GITHUB_RUN_NUMBER"))
    ap.add_argument("--notes", default="", help="short note on what changed in this build")
    ap.add_argument("--out", default="altstore-source.json")
    args = ap.parse_args()

    if not args.repo or "/" not in args.repo:
        fail("--repo OWNER/REPO is required")
    owner = args.repo.split("/", 1)[0]

    try:
        zf = zipfile.ZipFile(args.ipa)
    except (OSError, zipfile.BadZipFile) as exc:
        fail("cannot open %s: %s" % (args.ipa, exc))

    with zf:
        names = zf.namelist()
        mains = [n for n in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(mains) != 1:
            fail("expected exactly one Payload/<name>.app/Info.plist in the IPA, found %d" % len(mains))
        app_dir = mains[0].rsplit("/", 1)[0]
        info = plistlib.loads(zf.read(mains[0]))
        for key in ("CFBundleIdentifier", "CFBundleShortVersionString"):
            if not info.get(key):
                fail("Info.plist has no %s" % key)

        privacy = privacy_keys(info)
        entitlements = set(bundle_entitlements(zf, info, app_dir, "app"))

        ext_plist = re.compile(re.escape(app_dir) + r"/PlugIns/[^/]+\.appex/Info\.plist")
        extensions = sorted(n for n in names if ext_plist.fullmatch(n))
        for plist_path in extensions:
            ext_dir = plist_path.rsplit("/", 1)[0]
            ext_info = plistlib.loads(zf.read(plist_path))
            for key, value in privacy_keys(ext_info).items():
                privacy.setdefault(key, value)
            entitlements |= set(bundle_entitlements(zf, ext_info, ext_dir, os.path.basename(ext_dir)))

    entitlements = sorted(entitlements - IMPLICIT_ENTITLEMENTS)

    bundle_id = str(info["CFBundleIdentifier"])
    version = str(info["CFBundleShortVersionString"])
    build = str(info.get("CFBundleVersion") or version)
    min_os = str(info.get("MinimumOSVersion") or FALLBACK_MIN_OS)

    size = os.path.getsize(args.ipa)
    digest = hashlib.sha256()
    with open(args.ipa, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    sha256 = digest.hexdigest()

    asset = os.path.basename(args.ipa)
    # Parentheses stay as they are: GitHub itself writes them unencoded in release URLs.
    download_url = "https://github.com/%s/releases/download/%s/%s" % (
        args.repo, quote(args.tag, safe="()"), quote(asset))
    icon_url = "https://raw.githubusercontent.com/%s/%s/%s" % (args.repo, args.sha or "main", ICON_PATH)
    website = "https://github.com/%s" % args.repo

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    marketing = "%s (bugfix build %s)" % (version, args.run_number) if args.run_number else version
    notes = "YouTube %s with uYouEnhanced bugfixes." % version
    if args.notes.strip():
        notes += " Latest change: %s" % args.notes.strip()

    source = {
        "name": SOURCE_NAME,
        "identifier": "io.github.%s.uyouenhanced-bugfixing" % owner.lower(),
        "subtitle": SOURCE_SUBTITLE,
        "description": "%s\n\n%s" % (DESCRIPTION, website),
        "iconURL": icon_url,
        "website": website,
        "tintColor": TINT_COLOR,
        "apps": [
            {
                "beta": False,
                "name": APP_NAME,
                "bundleIdentifier": bundle_id,
                "developerName": DEVELOPER,
                "subtitle": SOURCE_SUBTITLE,
                "localizedDescription": DESCRIPTION,
                "iconURL": icon_url,
                "tintColor": TINT_COLOR,
                "category": CATEGORY,
                "versions": [
                    {
                        "version": version,
                        "buildVersion": build,
                        "marketingVersion": marketing,
                        "date": now,
                        "localizedDescription": notes,
                        "downloadURL": download_url,
                        "size": size,
                        "sha256": sha256,
                        "minOSVersion": min_os,
                    }
                ],
                # AltStore checks these against the IPA and refuses to install on a mismatch.
                "appPermissions": {"entitlements": entitlements, "privacy": privacy},
                # Older AltStore and SideStore versions read these keys.
                "version": version,
                "versionDate": now,
                "versionDescription": notes,
                "downloadURL": download_url,
                "size": size,
            }
        ],
        "news": [],
    }

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(source, fh, indent=2)
        fh.write("\n")

    print("AltStore source written to %s" % args.out)
    print("  app:          %s  %s (build %s), iOS %s+" % (bundle_id, version, build, min_os))
    print("  ipa:          %s, %d bytes" % (asset, size))
    print("  sha256:       %s" % sha256)
    print("  download:     %s" % download_url)
    print("  entitlements: %s" % (", ".join(entitlements) or "none"))
    print("  privacy keys: %s" % (", ".join(sorted(privacy)) or "none"))
    if not privacy:
        warn("no *UsageDescription keys found in Info.plist; the source declares no privacy permissions")


if __name__ == "__main__":
    main()
