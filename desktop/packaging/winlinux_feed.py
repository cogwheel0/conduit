#!/usr/bin/env python3
"""The Windows and Linux update feeds: Sparkle appcasts beside the Mac's
appcast.xml, signed as the Mac's are. winlinux-appcast.sh runs it; the
release workflow publishes what it writes.

  winlinux_feed.py url windows|linux
      The feed's URL, as release.env hosts the Mac's (lib.sh appcast_url),
      with its own file name: appcast-windows.xml or appcast-linux.xml.
      The packaging scripts build it into the app.

  winlinux_feed.py add --os windows|linux --version V --out FILE
                       [--old FILE --old-public-key K]
                       [--installer FILE] [--download-url-prefix U]
                       [--release-url U] [--pub-date DATE]
      Writes FILE: the items of OLD (a feed as published; none for the
      first release) kept as they are, with V's item first, and the whole
      signed with the private key in WINDOWS_ED_PRIVATE_KEY or
      LINUX_ED_PRIVATE_KEY (base64 of the 32-byte seed, as Sparkle's
      `generate_keys -x` exports it). The key reaches openssl on stdin,
      never argv or a file. OLD must be signed with K (lib.sh verify_feed's
      check): a feed someone changed is never signed again. A stable
      version only: neither feed has a beta channel.
      * Windows: the item's enclosure is the installer, at the download
        URL prefix (default: the version's GitHub release), with its length
        and EdDSA signature, `sparkle:os` windows-x64 and the arguments
        WinSparkle runs it with (INSTALLER_ARGUMENTS).
      * Linux: the item names the release page (<link>) and nothing to
        download: the app only says a newer version exists.

  winlinux_feed.py installer-arguments
      What WinSparkle runs the Windows installer with (smoke.ps1 installs
      over a running app with them).

  winlinux_feed.py check --os windows|linux --feed FILE [--old FILE]
                         --version V [--installer FILE] [--url U] [--link P]
      Fails, saying why, unless FILE keeps every item of OLD as it was, has
      exactly one item for V (its build number, lib.sh build_number) that is newer
      than every other and on no channel, names P as its release page (when
      given), ends in one signature block, and (Windows) its enclosure is
      URL, as long as the installer, and signed.
      The signatures themselves are lib.sh's to check: verify_feed for the
      feed, verify_enclosure for the installer.

Each item's sparkle:version is the build number, as on the Mac, so
WinSparkle (`win_sparkle_set_app_build_version`) and the Linux notice
order releases as Sparkle does, and a beta sorts before its release.
OPENSSL names the openssl to sign with (lib.sh ed25519_openssl picks one
for winlinux-appcast.sh); without it, `openssl` on PATH. Python 3 standard
library only.
"""

import argparse
import base64
import binascii
import copy
import email.utils
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

HERE = Path(__file__).resolve().parent
RELEASE_ENV = HERE / "macos" / "release.env"

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SIGNATURE_PREFIX = b"<!-- sparkle-signatures:\n"

# What WinSparkle runs the downloaded installer with: Inno Setup without
# its wizard (a progress window only), closing Conduit and its conduitd as
# any install over a running copy does (conduit.iss CloseApplications), and
# starting the app again once it's done (/RELAUNCH=1, conduit.iss [Run]).
INSTALLER_ARGUMENTS = "/SILENT /SP- /SUPPRESSMSGBOXES /NORESTART /RELAUNCH=1"
# conduit.iss MinVersion.
WINDOWS_MIN = "10.0"
FEEDS = {"windows": "appcast-windows.xml", "linux": "appcast-linux.xml"}
KEY_ENV = {"windows": "WINDOWS_ED_PRIVATE_KEY", "linux": "LINUX_ED_PRIVATE_KEY"}

# As lib.sh check_version: X.Y.Z or X.Y.Z-beta.N, no leading zeros.
_PART = r"(0|[1-9][0-9]*)"
_VERSION = re.compile(rf"{_PART}\.{_PART}\.{_PART}(-beta\.{_PART})?")


class FeedError(Exception):
    pass


def release_env(path=RELEASE_ENV):
    env = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.fullmatch(r"([A-Z0-9_]+)=(.*)", line)
        if m:
            env[m.group(1)] = m.group(2)
    return env


def feed_url(os_name, env=None):
    """lib.sh appcast_url's choice of host, with this OS's file."""
    env = env or release_env()
    repo, name = env["RELEASE_REPO"], FEEDS[os_name]
    owner, project = repo.split("/", 1)
    hosting = env["APPCAST_HOSTING"]
    if hosting == "release-asset":
        return f"https://github.com/{repo}/releases/download/{env['APPCAST_RELEASE_TAG']}/{name}"
    if hosting == "pages":
        return f"https://{owner}.github.io/{project}/desktop/{name}"
    if hosting == "branch":
        return f"https://raw.githubusercontent.com/{repo}/{env['APPCAST_BRANCH']}/{name}"
    raise FeedError(f"APPCAST_HOSTING must be release-asset, pages or branch (got {hosting!r})")


def build_number(version):
    """lib.sh build_number: X*1000000 + Y*10000 + Z*100 + 99, a beta's N in
    place of the 99."""
    m = _VERSION.fullmatch(version)
    if not m:
        raise FeedError(f"version {version!r} is not X.Y.Z or X.Y.Z-beta.N (no leading zeros)")
    major, minor, patch = (int(m.group(i)) for i in (1, 2, 3))
    beta = int(m.group(5)) if m.group(5) is not None else 99
    if minor > 99 or patch > 99:
        raise FeedError(f"minor and patch must be 0-99 ({version})")
    if m.group(5) is not None and not 1 <= beta <= 98:
        raise FeedError(f"beta number must be 1-98 ({version})")
    return major * 1_000_000 + minor * 10_000 + patch * 100 + beta


def unsigned_content(data):
    """The bytes before the feed's last signature block (all of them when
    it has none)."""
    start = data.rfind(SIGNATURE_PREFIX)
    return data if start < 0 else data[:start]


def channel_items(root):
    """The <channel>'s own <item>s, which are all the apps read
    (updates/feed.rs; WinSparkle the first channel's). A feed with an <item>
    anywhere else is refused, so what is signed is what the apps see."""
    channels = root.findall("channel")
    if len(channels) != 1:
        raise FeedError(f"the feed has {len(channels)} <channel> elements, not one")
    direct = channels[0].findall("item")
    if len(list(root.iter("item"))) != len(direct):
        raise FeedError("the feed has an <item> outside <channel>, which the apps never read")
    return direct


def items(data):
    root = ET.fromstring(unsigned_content(data))
    if root.tag != "rss":
        raise FeedError("not an appcast (no <rss>)")
    out = []
    for item in channel_items(root):
        text = lambda tag, ns=SPARKLE: (item.findtext(f"{{{ns}}}{tag}" if ns else tag) or "").strip()
        enc = item.find("enclosure")
        attr = lambda name: (enc.get(name) or "") if enc is not None else ""
        out.append(
            {
                "build": text("version"),
                "short": text("shortVersionString"),
                "channel": text("channel"),
                "link": text("link", None),
                "url": attr("url"),
                "length": attr("length"),
                "signature": attr(f"{{{SPARKLE}}}edSignature"),
                "os": attr(f"{{{SPARKLE}}}os"),
                "arguments": attr(f"{{{SPARKLE}}}installerArguments"),
            }
        )
    return out


def whole_items(data):
    """The <channel>'s items whole (canonical XML, text trimmed), counted:
    an earlier item stays in a new feed with every element and attribute
    it had, as many times as it was there."""
    root = ET.fromstring(unsigned_content(data))
    out = Counter()
    for item in channel_items(root):
        item = copy.deepcopy(item)
        item.tail = None
        out[ET.canonicalize(ET.tostring(item, encoding="unicode"), strip_text=True)] += 1
    return out


# --- signing ------------------------------------------------------------------

# PKCS#8 for an Ed25519 private key, before its 32-byte seed.
_PKCS8_PREFIX = bytes.fromhex("302e020100300506032b657004220420")


def private_key_der(text):
    try:
        seed = base64.b64decode(text.strip(), validate=True)
    except binascii.Error:
        seed = b""
    if len(seed) != 32:
        raise FeedError("the private key is not an EdDSA key as generate_keys -x exports it (base64 of 32 bytes)")
    return _PKCS8_PREFIX + seed


def _openssl():
    return os.environ.get("OPENSSL") or "openssl"


def public_key(der):
    """The public half (base64) of a private key, by openssl."""
    out = subprocess.run(
        [_openssl(), "pkey", "-inform", "DER", "-pubout", "-outform", "DER"], input=der, capture_output=True
    )
    if out.returncode != 0 or len(out.stdout) < 32:
        raise FeedError(f"openssl could not read the private key: {out.stderr.decode(errors='replace').strip()}")
    return base64.b64encode(out.stdout[-32:]).decode()


def sign(der, path):
    """The Ed25519 signature (base64) of the file at `path`, by openssl,
    over its raw bytes as Sparkle signs."""
    out = subprocess.run(
        [_openssl(), "pkeyutl", "-sign", "-inkey", "/dev/stdin", "-keyform", "DER", "-rawin", "-in", str(path)],
        input=der,
        capture_output=True,
    )
    if out.returncode != 0 or len(out.stdout) != 64:
        raise FeedError(f"openssl could not sign {path}: {out.stderr.decode(errors='replace').strip()}")
    return base64.b64encode(out.stdout).decode()


def verified(data, public, name):
    """The bytes `data` signs when its last signature block is `public`'s
    Ed25519 signature over them: lib.sh verify_feed's check, which accepts
    the block only as Sparkle writes it."""
    start = data.rfind(SIGNATURE_PREFIX)
    if start < 0:
        raise FeedError(f"{name} is not signed (no sparkle-signatures block)")
    end = data.find(b"-->", start + len(SIGNATURE_PREFIX))
    if end < 0:
        raise FeedError(f"{name}'s signature block is not closed")
    content, block = data[:start], data[start + len(SIGNATURE_PREFIX) : end]
    if data[end + 3 :].strip():
        raise FeedError(f"something follows {name}'s signature block")
    m = re.fullmatch(rb"edSignature: ([A-Za-z0-9+/]+={0,2})\nlength: ([0-9]+)\n", block)
    if not m or int(m.group(2)) != len(content):
        raise FeedError(f"{name}'s signature block is not an edSignature and the length it signs")
    try:
        signature = base64.b64decode(m.group(1), validate=True)
        key = base64.b64decode(public, validate=True)
    except binascii.Error:
        raise FeedError("the signature or the key is not base64") from None
    if len(signature) != 64 or len(key) != 32:
        raise FeedError("not an Ed25519 signature and public key")
    with tempfile.TemporaryDirectory(prefix="conduit-feed-") as scratch:
        files = {
            "content": content,
            "signature": signature,
            "public.der": bytes.fromhex("302a300506032b6570032100") + key,
        }
        for file, value in files.items():
            Path(scratch, file).write_bytes(value)
        out = subprocess.run(
            [_openssl(), "pkeyutl", "-verify", "-pubin", "-keyform", "DER",
             "-inkey", str(Path(scratch, "public.der")), "-rawin",
             "-in", str(Path(scratch, "content")), "-sigfile", str(Path(scratch, "signature"))],
            capture_output=True,
        )
    if out.returncode != 0:
        raise FeedError(f"{name} is not signed with {public}: a release is added only to a feed that key signed")
    return content


def signature_block(signature, length):
    """What Sparkle's sign_update appends to a feed (SUSignatureVerifier's
    format; lib.sh verify_feed accepts nothing else)."""
    return f"<!-- sparkle-signatures:\nedSignature: {signature}\nlength: {length}\n-->\n".encode()


# --- the new item -------------------------------------------------------------


def new_item(os_name, version, release_url, pub_date, enclosure=None):
    lines = [
        "<item>",
        f"  <title>{escape(version)}</title>",
        f"  <link>{escape(release_url)}</link>",
        f"  <pubDate>{escape(pub_date)}</pubDate>",
        f"  <sparkle:version>{build_number(version)}</sparkle:version>",
        f"  <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>",
    ]
    if os_name == "windows":
        url, length, signature = enclosure
        lines += [
            f"  <sparkle:minimumSystemVersion>{WINDOWS_MIN}</sparkle:minimumSystemVersion>",
            f"  <enclosure url={quoteattr(url)} length=\"{length}\" type=\"application/octet-stream\""
            f" sparkle:os=\"windows-x64\" sparkle:installerArguments={quoteattr(INSTALLER_ARGUMENTS)}"
            f" sparkle:edSignature=\"{signature}\"/>",
        ]
    lines.append("</item>")
    return "\n".join("    " + line for line in lines) + "\n"


def empty_feed(release_page):
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f'<rss version="2.0" xmlns:sparkle="{SPARKLE}">\n'
        "  <channel>\n"
        "    <title>Conduit</title>\n"
        f"    <link>{escape(release_page)}</link>\n"
        "  </channel>\n"
        "</rss>\n"
    )


def with_item(old_text, item):
    """`old_text` (a feed, unsigned) with `item` before its first item, or
    at the end of its channel when it has none: the earlier items' bytes
    stay as they were."""
    for pattern in (r"^[ \t]*<item\b", r"<item\b", r"^[ \t]*</channel>", r"</channel>"):
        m = re.search(pattern, old_text, re.MULTILINE)
        if m:
            return old_text[: m.start()] + item + old_text[m.start() :]
    raise FeedError("the feed has no <channel>")


def add(args):
    env = release_env()
    repo = env["RELEASE_REPO"]
    version = args.version
    if "-beta." in version:
        raise FeedError(f"{version} is a beta: Conduit Desktop publishes stable releases only (one feed per OS, no beta channel)")
    build = build_number(version)
    key_env = KEY_ENV[args.os]
    if not os.environ.get(key_env):
        raise FeedError(f"{key_env} is not set")
    der = private_key_der(os.environ[key_env])
    release_url = args.release_url or f"https://github.com/{repo}/releases/tag/desktop-v{version}"
    if args.old:
        if not args.old_public_key:
            raise FeedError("--old-public-key: the key the published feed is signed with")
        old_content = verified(Path(args.old).read_bytes(), args.old_public_key, Path(args.old).name)
        old_items = items(old_content)
        old_text = old_content.decode("utf-8")
    else:
        old_items, old_text = [], empty_feed(f"https://github.com/{repo}/releases")
    for item in old_items:
        if item["build"] == str(build):
            raise FeedError(f"the feed already has build {build} ({item['short']})")
        if not item["build"].isdigit() or int(item["build"]) > build:
            raise FeedError(f"{version} (build {build}) is not newer than build {item['build']} already in the feed")
    enclosure = None
    if args.os == "windows":
        if not args.installer:
            raise FeedError("--installer: the Windows feed's item is the installer")
        installer = Path(args.installer)
        if installer.name != f"Conduit-{version}-windows-x64-setup.exe":
            raise FeedError(f"{installer.name} is not Conduit-{version}-windows-x64-setup.exe (build.ps1 names it so)")
        prefix = args.download_url_prefix or f"https://github.com/{repo}/releases/download/desktop-v{version}/"
        if not prefix.endswith("/"):
            prefix += "/"
        enclosure = (prefix + installer.name, installer.stat().st_size, sign(der, installer))
    elif args.installer:
        raise FeedError("--installer: the Linux feed names the release page, not a download")
    pub_date = args.pub_date or email.utils.formatdate(usegmt=True)
    text = with_item(old_text, new_item(args.os, version, release_url, pub_date, enclosure))
    content = text.encode("utf-8")
    out = Path(args.out)
    out.write_bytes(content)
    out.write_bytes(content + signature_block(sign(der, out), len(content)))
    print(f"{out}: {version} (build {build}) added, {len(old_items)} earlier item(s) kept; signed with {public_key(der)}")


def check(args):
    """What's wrong with the new feed (None when nothing is)."""
    data = Path(args.feed).read_bytes()
    if data.count(SIGNATURE_PREFIX) != 1:
        return f"the feed has {data.count(SIGNATURE_PREFIX)} signature blocks, not one"
    new = items(data)
    old_data = Path(args.old).read_bytes() if args.old else None
    old = items(old_data) if old_data is not None else []
    for previous in old:
        if previous not in new:
            return f"the new feed drops or changes build {previous['build']} ({previous['short']})"
    if old_data is not None:
        lost = whole_items(old_data) - whole_items(data)
        if lost:
            return (
                f"the new feed drops or changes {sum(lost.values())} earlier item(s): "
                "each stays as it was, every element and attribute"
            )
    build = str(build_number(args.version))
    mine = [i for i in new if i["build"] == build]
    if len(mine) != 1:
        return f"the new feed has {len(mine)} items for build {build}, not one"
    item = mine[0]
    if item["short"] != args.version:
        return f"build {build} is labelled {item['short']!r}, not {args.version}"
    for other in new:
        if other is not item and (not other["build"].isdigit() or int(other["build"]) >= int(build)):
            return f"build {build} is not newer than build {other['build']} already in the feed"
    if item["channel"]:
        return f"build {build} is on channel {item['channel']!r}"
    if not item["link"].startswith("https://"):
        return f"build {build} links to {item['link']!r}, not an https page"
    if args.link and item["link"] != args.link:
        return f"build {build} names {item['link']!r} as its release page, not {args.link!r}"
    if args.os == "linux":
        if item["url"]:
            return f"the Linux item has an enclosure ({item['url']}): the notice installs nothing"
        return None
    if not args.installer:
        return "--installer: the Windows item's enclosure is checked against it"
    if args.url and item["url"] != args.url:
        return f"the enclosure is {item['url']!r}, not {args.url!r}"
    size = os.path.getsize(args.installer)
    if item["length"] != str(size):
        return f"the enclosure says {item['length'] or 'no'} bytes; the installer has {size}"
    try:
        signature = base64.b64decode(item["signature"], validate=True)
    except binascii.Error:
        signature = b""
    if len(signature) != 64:
        return "the enclosure has no EdDSA signature"
    if item["os"] != "windows-x64" or item["arguments"] != INSTALLER_ARGUMENTS:
        return f"the enclosure is for {item['os']!r} with {item['arguments']!r}, not windows-x64 with {INSTALLER_ARGUMENTS!r}"
    return None


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)
    p = sub.add_parser("url")
    p.add_argument("os", choices=FEEDS)
    sub.add_parser("installer-arguments")
    p = sub.add_parser("add")
    p.add_argument("--os", required=True, choices=FEEDS)
    p.add_argument("--version", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--old")
    p.add_argument("--old-public-key")
    p.add_argument("--installer")
    p.add_argument("--download-url-prefix")
    p.add_argument("--release-url")
    p.add_argument("--pub-date")
    p = sub.add_parser("check")
    p.add_argument("--os", required=True, choices=FEEDS)
    p.add_argument("--feed", required=True)
    p.add_argument("--old")
    p.add_argument("--version", required=True)
    p.add_argument("--installer")
    p.add_argument("--url")
    p.add_argument("--link")
    args = ap.parse_args(argv)
    try:
        if args.command == "url":
            print(feed_url(args.os))
        elif args.command == "installer-arguments":
            print(INSTALLER_ARGUMENTS)
        elif args.command == "add":
            add(args)
        else:
            problem = check(args)
            if problem:
                print(f"feed check failed: {problem}", file=sys.stderr)
                return 1
            print(f"{args.feed}: the feed check passed")
    except (FeedError, ET.ParseError, OSError, UnicodeDecodeError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
