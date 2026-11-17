#!/usr/bin/env python3
"""
Casting preflight for uYouEnhanced builds.

Point it at the *decrypted* YouTube.app that you build with (the folder inside
Payload/ of the IPA) and it reports:

  * which of the A/B flags used by "Fix Casting" (the YTweaks tweak) still exist
    in that YouTube version,
  * every selector / class name / string in the binary that mentions the local
    network permission (candidates for replacement flags when the old ones are gone),
  * the Bonjour / local-network keys in Info.plist,
  * the networking entitlements in the original (App Store) code signature.

Pure Python 3 standard library, so it runs on GitHub macOS runners and on a
Windows PC with no Xcode. The report is Markdown on stdout (append it to
$GITHUB_STEP_SUMMARY); warnings go to stderr as GitHub Actions annotations.

Usage:
  python3 Scripts/casting-preflight/casting_preflight.py Payload/YouTube.app
  python3 Scripts/casting-preflight/casting_preflight.py Payload/YouTube.app --version 20.44.2

Exit status: 0 on success, 2 if the binary could not be analyzed.
"""

import argparse
import mmap
import os
import plistlib
import re
import struct
import sys

CPU_TYPE_ARM64 = 0x0100000C
FAT_MAGIC = 0xCAFEBABE
MACHO_64_MAGIC = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
LC_ENCRYPTION_INFO_64 = 0x2C
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171

# Newest YouTube version where the A/B-flag based "Fix Casting" is documented to
# work (YTweaks README). The YouTube Plus FAQ gives 20.14.1 for its own builds.
LAST_KNOWN_GOOD = "20.10.4"

# (config class, selector, value Fix Casting forces) - mirrors YTweaks/Tweak.x
KNOWN_FLAGS = [
    ("YTColdConfig", "cxClientEnableIosLocalNetworkPermissionReliabilityFixes", "YES"),
    ("YTColdConfig", "cxClientEnableIosLocalNetworkPermissionUsingSockets", "NO"),
    ("YTColdConfig", "cxClientEnableIosLocalNetworkPermissionWifiFixes", "YES"),
    ("YTHotConfig", "isPromptForLocalNetworkPermissionsEnabled", "YES"),
]

# The two hook points of this fork's casting fix for YouTube 21.x (Sources/uYouPlusCastingFix.xm), found by reading the
# 21.38.2 binary: (class, selector, what the hook does)
CASTING_FIX_HOOKS = [
    ("MDXLocalNetworkPermissionsImpl", "localNetworkPermissionCheckRequired",
     "stops YouTube's multicast permission probe, which always fails on a re-signed app"),
    ("GCKCastOptions", "isCustomMulticastEnabled",
     "makes the Cast SDK find Chromecasts through the system's Bonjour instead of its own multicast sockets"),
]

LOCAL_NETWORK = re.compile(r"local[ _-]?network", re.IGNORECASE)
# Casting-ish names. "Cast" is matched with a capital C (or a leading "cast") so
# that "broadcast"/"podcast" do not match.
CAST_WORDS = re.compile(r"Cast|^cast|MDX|Mdx|^mdx|[Bb]onjour|[Mm]ulticast|SSDP|Ssdp|ssdp|[Ll]ounge|[Pp]airing")
FLAG_PREFIX = re.compile(r"^(cx|ios|is|enable|should|mdx|use|disable|allow)")
CLASS_WORDS = re.compile(r"MDX|Cast|GCK|Lounge|Network")
CLASS_KINDS = re.compile(r"Permission|Discovery|Bonjour|Multicast|Scanner|Browser|Reachability")


def warn(msg):
    print("::warning title=Casting preflight::%s" % msg, file=sys.stderr)


def notice(msg):
    print("::notice title=Casting preflight::%s" % msg, file=sys.stderr)


def vtuple(version):
    parts = []
    for p in re.split(r"[.\-]", version or ""):
        m = re.match(r"\d+", p)
        parts.append(int(m.group(0)) if m else 0)
    return tuple((parts + [0] * 4)[:4])


class MachO:
    def __init__(self, path):
        self._fh = open(path, "rb")
        self.data = mmap.mmap(self._fh.fileno(), 0, access=mmap.ACCESS_READ)
        data = self.data
        self.slice_off = 0
        if len(data) < 32:
            raise ValueError("file is too small to be a Mach-O")
        if struct.unpack_from(">I", data, 0)[0] == FAT_MAGIC:
            count = struct.unpack_from(">I", data, 4)[0]
            for i in range(count):
                cputype, _sub, off, _size, _align = struct.unpack_from(">IIIII", data, 8 + i * 20)
                if cputype == CPU_TYPE_ARM64:
                    self.slice_off = off
                    break
            else:
                raise ValueError("fat binary without an arm64 slice")
        magic = struct.unpack_from("<I", data, self.slice_off)[0]
        if magic != MACHO_64_MAGIC:
            raise ValueError("not a 64-bit Mach-O (magic 0x%x)" % magic)

        self.sections = {}
        self.cryptid = None
        self.codesig = None
        ncmds = struct.unpack_from("<I", data, self.slice_off + 16)[0]
        pos = self.slice_off + 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", data, pos)
            if cmd == LC_SEGMENT_64:
                nsects = struct.unpack_from("<I", data, pos + 64)[0]
                sp = pos + 72
                for _s in range(nsects):
                    sect = bytes(data[sp:sp + 16]).rstrip(b"\0").decode("latin1")
                    seg = bytes(data[sp + 16:sp + 32]).rstrip(b"\0").decode("latin1")
                    size = struct.unpack_from("<Q", data, sp + 40)[0]
                    offset = struct.unpack_from("<I", data, sp + 48)[0]
                    self.sections[(seg, sect)] = (offset, size)
                    sp += 80
            elif cmd == LC_ENCRYPTION_INFO_64:
                self.cryptid = struct.unpack_from("<I", data, pos + 16)[0]
            elif cmd == LC_CODE_SIGNATURE:
                self.codesig = struct.unpack_from("<II", data, pos + 8)
            pos += cmdsize

    def strings(self, segment, section):
        offset, size = self.sections.get((segment, section), (0, 0))
        if not offset or not size:
            return []
        start = self.slice_off + offset
        blob = bytes(self.data[start:start + size])
        return [t.decode("latin1") for t in blob.split(b"\0") if t]

    def entitlements(self):
        """Entitlements of the original code signature, or None if there is none."""
        if not self.codesig:
            return None
        base = self.slice_off + self.codesig[0]
        try:
            magic, _length, count = struct.unpack_from(">III", self.data, base)
            if magic != CSMAGIC_EMBEDDED_SIGNATURE:
                return None
            for i in range(count):
                _kind, off = struct.unpack_from(">II", self.data, base + 12 + i * 8)
                blob_magic, blob_len = struct.unpack_from(">II", self.data, base + off)
                if blob_magic == CSMAGIC_EMBEDDED_ENTITLEMENTS:
                    return plistlib.loads(bytes(self.data[base + off + 8:base + off + blob_len]))
        except Exception:
            return None
        return None


def clip(text, limit=200):
    text = text.replace("`", "'")
    return text if len(text) <= limit else text[:limit - 3] + "..."


def bullet_list(items, limit, out):
    items = sorted(set(items))
    if not items:
        out.append("_none_")
        return
    for item in items[:limit]:
        out.append("- `%s`" % clip(item))
    if len(items) > limit:
        out.append("- ... and %d more" % (len(items) - limit))


def main():
    ap = argparse.ArgumentParser(description="Report which casting flags a decrypted YouTube.app contains.")
    ap.add_argument("app", help="path to the extracted YouTube.app (inside Payload/)")
    ap.add_argument("--version", help="YouTube version (default: CFBundleVersion from Info.plist)")
    ap.add_argument("--limit", type=int, default=150, help="max entries per list (default 150)")
    args = ap.parse_args()

    out = []
    info = {}
    try:
        with open(os.path.join(args.app, "Info.plist"), "rb") as fh:
            info = plistlib.load(fh)
    except Exception as exc:
        warn("could not read Info.plist: %s" % exc)

    version = args.version or str(info.get("CFBundleVersion") or info.get("CFBundleShortVersionString") or "unknown")
    binary = os.path.join(args.app, str(info.get("CFBundleExecutable") or "YouTube"))
    out.append("## Casting preflight: YouTube %s" % version)
    out.append("")

    try:
        macho = MachO(binary)
    except Exception as exc:
        warn("could not analyze %s: %s" % (binary, exc))
        out.append("Could not analyze `%s`: %s" % (binary, exc))
        print("\n".join(out))
        return 2

    if macho.cryptid:
        warn("the YouTube binary is still encrypted; use a decrypted IPA")
        out.append("**The YouTube binary is still encrypted (App Store build).** Nothing can be read from it. "
                   "Use a decrypted IPA.")
        print("\n".join(out))
        return 2

    selectors = macho.strings("__TEXT", "__objc_methname")
    classes = macho.strings("__TEXT", "__objc_classname")
    cstrings = macho.strings("__TEXT", "__cstring")
    selector_set = set(selectors)

    # --- verdict ---------------------------------------------------------
    class_set = set(classes)
    present = [f for f in KNOWN_FLAGS if f[1] in selector_set]
    hooks_present = [h for h in CASTING_FIX_HOOKS if h[0] in class_set and h[1] in selector_set]
    hooks_ok = len(hooks_present) == len(CASTING_FIX_HOOKS)
    newer = vtuple(version) > vtuple(LAST_KNOWN_GOOD)
    if hooks_ok and (newer or not present):
        verdict = ("YouTube %s is newer than %s, so the A/B flags behind **Fix Casting** no longer decide anything "
                   "here (%d of %d still exist). Both hook points of this fork's 21.x casting fix are in this build, "
                   "so keep **Fix Casting** on. That fix comes from reading the 21.38.2 binary and has not been "
                   "confirmed on a device yet." % (version, LAST_KNOWN_GOOD, len(present), len(KNOWN_FLAGS)))
        notice("YouTube %s: the 21.x casting fix applies (hook points found); not confirmed on a device yet" % version)
    elif not present:
        verdict = ("None of the %d A/B flags used by **Fix Casting** exist in YouTube %s, so enabling it "
                   "changes nothing here. The hook points of this fork's 21.x casting fix are missing too "
                   "(%d of %d found)." % (len(KNOWN_FLAGS), version, len(hooks_present), len(CASTING_FIX_HOOKS)))
        warn("Fix Casting flags and casting fix hook points are gone from YouTube %s" % version)
    elif newer:
        verdict = ("The Fix Casting flags still exist, but YouTube %s is newer than %s, the last version they are "
                   "documented to work on (YouTube Plus's FAQ says 20.14.1), and the hook points of this fork's "
                   "21.x casting fix are not all present (%d of %d found). Expect casting to stay broken for "
                   "sideloaded builds." % (version, LAST_KNOWN_GOOD, len(hooks_present), len(CASTING_FIX_HOOKS)))
        warn("YouTube %s is newer than %s and the 21.x casting fix does not fit; casting is not expected to work"
             % (version, LAST_KNOWN_GOOD))
    else:
        verdict = ("YouTube %s is within the range where **Fix Casting** is expected to work "
                   "(up to %s). Leave it enabled." % (version, LAST_KNOWN_GOOD))
    out.append("> %s" % verdict)
    out.append("")
    out.append("Scanned %d selectors, %d class names and %d C strings." % (len(selectors), len(classes), len(cstrings)))
    out.append("")

    # --- known flags -----------------------------------------------------
    out.append("### Flags used by Fix Casting")
    out.append("")
    out.append("| Config class | Flag | Fix Casting forces | In this YouTube version |")
    out.append("|---|---|---|---|")
    for cls, flag, value in KNOWN_FLAGS:
        out.append("| `%s` | `%s` | %s | %s |" % (cls, flag, value, "present" if flag in selector_set else "**missing**"))
    out.append("")

    # --- hook points of the 21.x fix -----------------------------------------
    out.append("### Hook points of this fork's casting fix for YouTube 21.x")
    out.append("")
    out.append("| Class | Method | What the hook does | Class in this YouTube version | Method name in this YouTube version |")
    out.append("|---|---|---|---|---|")
    for cls, sel, what in CASTING_FIX_HOOKS:
        out.append("| `%s` | `%s` | %s | %s | %s |" % (
            cls, sel, what,
            "present" if cls in class_set else "**missing**",
            "present" if sel in selector_set else "**missing**"))
    out.append("")
    out.append("_Names are matched anywhere in the binary, not per class._")
    out.append("")

    # --- Info.plist --------------------------------------------------------
    out.append("### Local network keys in Info.plist")
    out.append("")
    desc = info.get("NSLocalNetworkUsageDescription")
    out.append("- `NSLocalNetworkUsageDescription`: %s" % ("present" if desc else "**missing**"))
    bonjour = info.get("NSBonjourServices")
    if bonjour:
        out.append("- `NSBonjourServices`: %s" % ", ".join("`%s`" % clip(str(s)) for s in bonjour))
    else:
        out.append("- `NSBonjourServices`: **missing**")
    out.append("")

    # --- entitlements ------------------------------------------------------
    out.append("### Networking entitlements in the original signature")
    out.append("")
    ents = macho.entitlements()
    if ents is None:
        out.append("_No readable signature (the dumper stripped it)._")
    else:
        net = {k: v for k, v in ents.items() if re.search(r"network|multicast|wifi", k, re.IGNORECASE)}
        if net:
            for key in sorted(net):
                out.append("- `%s` = `%s`" % (key, clip(str(net[key]), 80)))
            if any("multicast" in key.lower() for key in net):
                out.append("")
                out.append("Sideloading re-signs the app with your own profile, which cannot carry restricted "
                           "entitlements such as `com.apple.developer.networking.multicast`.")
        else:
            out.append("_No networking entitlements in the original signature._")
    out.append("")

    # --- candidates ---------------------------------------------------------
    local = ["sel: " + s for s in selectors if LOCAL_NETWORK.search(s)]
    local += ["cls: " + s for s in classes if LOCAL_NETWORK.search(s)]
    local += ["str: " + s for s in cstrings if LOCAL_NETWORK.search(s)]
    out.append("### Everything that mentions the local network")
    out.append("")
    out.append("<details><summary>%d entries</summary>" % len(set(local)))
    out.append("")
    bullet_list(local, args.limit, out)
    out.append("")
    out.append("</details>")
    out.append("")

    flags = [s for s in selectors if ":" not in s and FLAG_PREFIX.match(s) and CAST_WORDS.search(s)]
    out.append("### Cast / MDX flag-like selectors")
    out.append("")
    out.append("<details><summary>%d entries</summary>" % len(set(flags)))
    out.append("")
    bullet_list(flags, args.limit, out)
    out.append("")
    out.append("</details>")
    out.append("")

    names = [c for c in classes if CLASS_WORDS.search(c) and CLASS_KINDS.search(c)]
    out.append("### Discovery / permission class names")
    out.append("")
    out.append("<details><summary>%d entries</summary>" % len(set(names)))
    out.append("")
    bullet_list(names, args.limit, out)
    out.append("")
    out.append("</details>")
    out.append("")

    # --- what to do -----------------------------------------------------------
    out.append("### If casting is broken")
    out.append("")
    out.append("- Keep **Fix Casting** on (YTweaks settings) and make sure **Local Network** is on for YouTube in "
               "iOS Settings. iOS asks the first time YouTube looks for devices.")
    out.append("- Open **uYouEnhanced Debug Logs** in the settings after trying to cast and export the report. "
               "Lines that start with `[uYouPlus] CastingFix` show whether the casting fix was reached.")
    out.append("- Pair the TV manually with its code (reported to work while the app stays open), or use AirPlay if "
               "the TV supports it (iOS does that discovery, not the app).")
    out.append("- A YouTube IPA at or below %s still works with the flags alone, without the 21.x fix." % LAST_KNOWN_GOOD)
    out.append("- To look for other hook points, share the **local network** list above.")

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
