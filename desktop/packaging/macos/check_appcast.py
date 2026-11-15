#!/usr/bin/env python3
"""Checks a generated appcast before it is published (appcast.sh runs it).

  check_appcast.py --new NEW.xml [--old OLD.xml] --dmg DMG --version V
                   --build N --url URL [--beta]

Fails (exit 1, a line saying why) unless:
* every item of the feed it started from (OLD, absent for a new feed) is
  still in NEW, by build number: a feed never drops earlier releases;
* NEW holds exactly one item for build N, version V, whose enclosure is
  URL, is as long as DMG, and carries a 64-byte EdDSA signature;
* build N is newer than every other item on its channel's way: a stable
  build newer than every stable item, a beta build newer than every item
  (Sparkle orders by build, and beta readers also see stable items);
* the item is on the beta channel exactly when --beta is given.

Only the standard library: it runs on any Mac or CI image.
"""
import argparse
import base64
import os
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def items(path):
    root = ET.parse(path).getroot()
    out = []
    for item in root.iter("item"):
        enc = item.find("enclosure")
        attr = lambda name: enc.get(name, "") if enc is not None else ""
        text = lambda tag: (item.findtext(f"{{{SPARKLE}}}{tag}") or "").strip()
        out.append(
            {
                "build": (text("version") or attr(f"{{{SPARKLE}}}version")).strip(),
                "short": text("shortVersionString") or attr(f"{{{SPARKLE}}}shortVersionString"),
                "channel": text("channel"),
                "url": attr("url"),
                "length": attr("length"),
                "signature": attr(f"{{{SPARKLE}}}edSignature"),
            }
        )
    return out


def check(args):
    new = items(args.new)
    old = items(args.old) if args.old else []
    builds = [i["build"] for i in new]
    for previous in old:
        if previous["build"] not in builds:
            return f"the new feed drops build {previous['build']} ({previous['short']})"
    mine = [i for i in new if i["build"] == str(args.build)]
    if len(mine) != 1:
        return f"the new feed has {len(mine)} items for build {args.build}, not one"
    item = mine[0]
    if item["short"] and item["short"] != args.version:
        return f"build {args.build} is labelled {item['short']}, not {args.version}"
    if item["url"] != args.url:
        return f"the enclosure is {item['url']!r}, not {args.url!r}"
    size = os.path.getsize(args.dmg)
    if item["length"] != str(size):
        return f"the enclosure says {item['length'] or 'no'} bytes; the DMG has {size}"
    try:
        signature = base64.b64decode(item["signature"], validate=True)
    except ValueError:
        signature = b""
    if len(signature) != 64:
        return "the enclosure has no EdDSA signature"
    for other in new:
        if other is item or (not args.beta and other["channel"] == "beta"):
            continue
        if not other["build"].isdigit() or int(other["build"]) >= args.build:
            return f"build {args.build} is not newer than build {other['build']} already in the feed"
    if (item["channel"] == "beta") != args.beta:
        return f"build {args.build} is on channel {item['channel'] or 'default'!r}"
    return None


def main():
    if "--signature-of" in sys.argv:
        # appcast.sh: the EdDSA signature of one build, for sign_update.
        build = sys.argv[sys.argv.index("--signature-of") + 1]
        path = sys.argv[sys.argv.index("--new") + 1]
        found = [i["signature"] for i in items(path) if i["build"] == build]
        if len(found) != 1 or not found[0]:
            sys.exit(f"no signature for build {build}")
        print(found[0])
        return
    p = argparse.ArgumentParser()
    p.add_argument("--new", required=True)
    p.add_argument("--old")
    p.add_argument("--dmg", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--build", type=int, required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--beta", action="store_true")
    problem = check(p.parse_args())
    if problem:
        print(f"appcast check failed: {problem}", file=sys.stderr)
        sys.exit(1)
    print("appcast check passed")


if __name__ == "__main__":
    main()
