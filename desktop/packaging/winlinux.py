#!/usr/bin/env python3
"""What the Windows and Linux packaging scripts share (windows/build.ps1,
windows/smoke.ps1, linux/package.sh, linux/smoke.sh). Python 3 standard
library only, so it runs on every build and test machine.

  winlinux.py version V            V, checked as the Mac's scripts check it
                                   (lib.sh check_version); with --windows,
                                   the X.Y.Z.0 a Windows file version takes
  winlinux.py types windows|linux  the file types the app opens: the Mac's
                                   CFBundleDocumentTypes (macos/Info.plist)
                                   as extensions or MIME types, one a line
  winlinux.py types desktop-entry  the MIME types the Linux desktop entry
                                   lists for them (never one whose parent
                                   type would reach its default app)
  winlinux.py layout DIR --os windows|linux
                                   checks an install folder (or the staged
                                   one): the app, conduitd beside it as
                                   paths::packaged_daemon_for expects, its
                                   SQLite and the model logo catalog; no test
                                   harness in the app; THIRD_PARTY_NOTICES.md
                                   for that OS; on Windows, WinSparkle.dll
                                   beside the app (the updater), and no PE that
                                   needs a C/C++ runtime DLL Windows lacks
                                   unless it sits beside the executable of
                                   the process that loads that PE
  winlinux.py modes DIR            sets the modes of a staged tree as every
                                   user needs them, whatever the builder's
                                   umask: folders and executables 0755, the
                                   rest 0644
  winlinux.py package-modes PKG... fails unless every file a built .deb or
                                   .rpm installs is root's and readable by
                                   everyone (dpkg-deb -c, rpm -qlvp)
  winlinux.py extra-requires       what the packages require beyond the
                                   libraries their binaries link, one a line
  winlinux.py package-requires PKG...
                                   fails unless every built .deb and .rpm
                                   requires those (dpkg-deb -f, rpm -qp
                                   --requires)
  winlinux.py rpm-requires DIR     the rpm requirements of the ELF files under
                                   DIR (sonames and glibc symbol versions, as
                                   rpmbuild finds them), from readelf
  winlinux.py notices FILE --os windows|linux
                                   checks third-party notices were made for
                                   that OS (notices.sh --target)
  winlinux.py gone PATH...         fails, listing them, if any of the files
                                   or folders is still there (an uninstall)
  winlinux.py forget-handler LIST TYPE ENTRY
                                   takes desktop entry ENTRY out of TYPE's
                                   lists in mimeapps.list LIST, written only
                                   if it named it (crates/app/run.sh
                                   --unregister-scheme)
  winlinux.py ico OUT PNG...       packs square PNGs of up to 256 px into OUT
"""

import argparse
import mmap
import os
import plistlib
import re
import struct
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
INFO_PLIST = HERE / "macos" / "Info.plist"

# Kept in a build with the test harness (crates/app/src/lib.rs HARNESS_MARKER,
# macos/lib.sh has_harness_marker).
HARNESS_MARKER = b"conduit-desktop: test harness build"

# As macos/lib.sh check_version: X.Y.Z or X.Y.Z-beta.N, no leading zeros.
_PART = r"(0|[1-9][0-9]*)"
_VERSION = re.compile(rf"^{_PART}\.{_PART}\.{_PART}(-beta\.{_PART})?$")


def check_version(version):
    if not _VERSION.fullmatch(version):
        raise ValueError(f"version '{version}' is not X.Y.Z or X.Y.Z-beta.N (no leading zeros)")
    return version


def windows_file_version(version):
    """The four 16-bit numbers of VERSIONINFO: X.Y.Z.0 (a beta's too, since
    the Mac's build number doesn't fit)."""
    core = check_version(version).split("-")[0]
    parts = [int(p) for p in core.split(".")]
    if any(p > 0xFFFF for p in parts):
        raise ValueError(f"{version}: Windows file versions hold numbers up to 65535")
    return ".".join(str(p) for p in parts + [0])


# The Mac's document types (Uniform Type Identifiers) as Windows extensions
# and Linux MIME types. A type the Mac adds must be added here too: an
# unknown one is refused, so the three lists can't drift apart.
DOCUMENT_TYPES = {
    "com.adobe.pdf": ([".pdf"], ["application/pdf"]),
    "public.plain-text": ([".txt"], ["text/plain"]),
    "net.daringfireball.markdown": ([".md", ".markdown"], ["text/markdown"]),
    "public.comma-separated-values-text": ([".csv"], ["text/csv"]),
    "public.json": ([".json"], ["application/json"]),
    "org.openxmlformats.wordprocessingml.document": (
        [".docx"],
        ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"],
    ),
    "org.openxmlformats.spreadsheetml.sheet": (
        [".xlsx"],
        ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"],
    ),
    "org.openxmlformats.presentationml.presentation": (
        [".pptx"],
        ["application/vnd.openxmlformats-officedocument.presentationml.presentation"],
    ),
    "public.png": ([".png"], ["image/png"]),
    "public.jpeg": ([".jpg", ".jpeg"], ["image/jpeg"]),
    "com.compuserve.gif": ([".gif"], ["image/gif"]),
    "org.webmproject.webp": ([".webp"], ["image/webp"]),
}


def mac_document_types(plist=INFO_PLIST):
    with open(plist, "rb") as f:
        info = plistlib.load(f)
    return [uti for doc in info.get("CFBundleDocumentTypes", []) for uti in doc["LSItemContentTypes"]]


def map_types(utis):
    unknown = [u for u in utis if u not in DOCUMENT_TYPES]
    if unknown:
        raise ValueError(f"no Windows or Linux equivalent for {', '.join(unknown)} (winlinux.py DOCUMENT_TYPES)")
    return [DOCUMENT_TYPES[u] for u in utis]


def windows_extensions(plist=INFO_PLIST):
    return [ext for exts, _ in map_types(mac_document_types(plist)) for ext in exts]


def linux_mime_types(plist=INFO_PLIST):
    return [mime for _, mimes in map_types(mac_document_types(plist)) for mime in mimes]


# What the Linux desktop entry lists in place of a type whose parent type
# reaches its default app (None: nothing). GIO, and so GNOME's file manager
# and xdg-open, takes an app that lists a type itself before the default of
# the type's parent, so listed themselves these would open in Conduit:
# Markdown, CSV and JSON wherever only text/plain has a default (GNOME), the
# Office formats wherever no office suite is installed (application/zip's
# default, the Archive Manager, opens them otherwise). text/plain keeps
# Conduit in the first three's Open With.
LISTED_AS = {
    "text/markdown": "text/plain",
    "text/csv": "text/plain",
    "application/json": "text/plain",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": None,
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": None,
    "application/vnd.openxmlformats-officedocument.presentationml.presentation": None,
}


def desktop_entry_types(plist=INFO_PLIST):
    listed = []
    for mime in linux_mime_types(plist):
        mime = LISTED_AS.get(mime, mime)
        if mime is not None and mime not in listed:
            listed.append(mime)
    return listed


# --- PE imports -------------------------------------------------------------


def _u16(data, at):
    return struct.unpack_from("<H", data, at)[0]


def _u32(data, at):
    return struct.unpack_from("<I", data, at)[0]


def pe_imports(data):
    """The DLLs a PE image imports, load-time then delay-loaded, in table
    order."""
    try:
        if data[:2] != b"MZ":
            raise ValueError("no MZ header")
        pe = _u32(data, 0x3C)
        if data[pe : pe + 4] != b"PE\0\0":
            raise ValueError("no PE header")
        coff = pe + 4
        sections, optional_size = _u16(data, coff + 2), _u16(data, coff + 16)
        optional = coff + 20
        plus = _u16(data, optional) == 0x20B
        image_base = struct.unpack_from("<Q", data, optional + 24)[0] if plus else _u32(data, optional + 28)
        directories = optional + (112 if plus else 96)
        count = _u32(data, directories - 4)
        table = [
            (s + 12, s + 8, s + 16, s + 20)
            for s in range(optional + optional_size, optional + optional_size + 40 * sections, 40)
        ]

        def offset(rva):
            for va_at, vsize_at, rawsize_at, raw_at in table:
                va = _u32(data, va_at)
                if va <= rva < va + max(_u32(data, vsize_at), _u32(data, rawsize_at)):
                    return rva - va + _u32(data, raw_at)
            raise ValueError(f"RVA {rva:#x} is in no section")

        def name(rva):
            at = offset(rva)
            return data[at : data.index(b"\0", at)].decode("ascii")

        def directory(index):
            return _u32(data, directories + 8 * index) if index < count else 0

        names = []
        rva = directory(1)
        if rva:
            at = offset(rva)
            while data[at : at + 20] != bytes(20):
                names.append(name(_u32(data, at + 12)))
                at += 20
        rva = directory(13)
        if rva:
            at = offset(rva)
            while data[at : at + 32] != bytes(32):
                attributes, dll = _u32(data, at), _u32(data, at + 4)
                # Old delay-load tables hold addresses, not RVAs.
                names.append(name(dll if attributes & 1 else dll - image_base))
                at += 32
        return names
    except (struct.error, IndexError, UnicodeDecodeError) as e:
        raise ValueError(f"not a readable PE image: {e}") from e


# The C and C++ runtimes Windows doesn't come with: the Visual C++
# Redistributable's DLLs (and the debug CRT), and MinGW's.
_RUNTIME_DLL = re.compile(
    r"^(vcruntime\d+.*|msvcp\d+.*|vccorlib\d+.*|concrt\d+.*|vcomp\d+.*|vcamp\d+.*|mfc\d+.*"
    r"|ucrtbased|libgcc_s_.*|libstdc\+\+-.*|libwinpthread-.*)\.dll$",
    re.IGNORECASE,
)


# --- install layout ---------------------------------------------------------


def _has_marker(path):
    with open(path, "rb") as f:
        if os.fstat(f.fileno()).st_size == 0:
            return False
        with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
            return m.find(HARNESS_MARKER) != -1


def notices_problems(path, os_name):
    """What's wrong with the third-party notices at `path` for `os_name`'s
    package: they must be there, made for that target (notices.sh
    --target), not the Mac's or another OS's."""
    path = Path(path)
    heading = f"# Third-party notices: Conduit Desktop for {'Windows' if os_name == 'windows' else 'Linux'}"
    if not path.is_file():
        return [f"no {path.name} (the licences of what the package includes)"]
    with open(path, encoding="utf-8", errors="replace") as f:
        first = f.readline().rstrip("\n")
    if first != heading:
        return [f"{path.name} begins '{first}', not '{heading}' (notices.sh --target)"]
    return []


def layout_problems(root, os_name):
    """What's wrong with the install folder `root` (empty when nothing is)."""
    root = Path(root)
    windows = os_name == "windows"
    exe = ".exe" if windows else ""
    problems = []
    app = root / f"conduit-desktop{exe}"
    daemon = root / "conduitd" / "bin" / f"conduitd{exe}"
    for path in (app, daemon):
        if not path.is_file():
            problems.append(f"no {path.relative_to(root).as_posix()}")
        elif not windows and not os.access(path, os.X_OK):
            problems.append(f"{path.relative_to(root).as_posix()} is not executable")
    sqlite = "*sqlite3*.dll" if windows else "libsqlite3*.so*"
    if not list((root / "conduitd" / "lib").glob(sqlite)):
        problems.append(f"no conduitd/lib/{sqlite} (the SQLite conduitd loads)")
    if not (root / "conduitd" / "model_logos" / "catalog.json").is_file():
        problems.append("no conduitd/model_logos/catalog.json (the model logo catalog)")
    if windows and not (root / "conduit.ico").is_file():
        problems.append("no conduit.ico (the Start menu and link icon)")
    # The app loads it from its own folder (crates/app/src/updates/winsparkle.rs).
    if windows and not (root / "WinSparkle.dll").is_file():
        problems.append("no WinSparkle.dll beside the app (the updater)")
    problems += notices_problems(root / "THIRD_PARTY_NOTICES.md", os_name)
    if app.is_file() and _has_marker(app):
        problems.append(f"{app.name} was built with the test harness (the `harness` feature): never shipped")
    if windows:
        for path in sorted(p for p in root.rglob("*") if p.is_file()):
            if path.suffix.lower() not in (".exe", ".dll"):
                continue
            rel = path.relative_to(root).as_posix()
            try:
                imports = pe_imports(path.read_bytes())
            except ValueError as e:
                problems.append(f"{rel}: {e}")
                continue
            # Windows resolves a DLL beside the executable of the process
            # that loads it, then in the system: everything under conduitd\
            # runs in conduitd.exe's process, the rest in the app's.
            folder = daemon.parent if rel.startswith("conduitd/") else root
            beside = {p.name.lower() for p in folder.iterdir() if p.is_file()} if folder.is_dir() else set()
            for dll in imports:
                if _RUNTIME_DLL.match(dll) and dll.lower() not in beside:
                    problems.append(
                        f"{rel} needs {dll}, which Windows doesn't come with and isn't in "
                        f"{folder.relative_to(root).as_posix()}/ beside the process's executable"
                    )
    return problems


# --- modes --------------------------------------------------------------------


def normalize_modes(root):
    """Folders 0755; files 0755 when their owner may run them, else 0644.
    nfpm packages the staged modes, which the builder's umask set."""
    root = Path(root)
    for path in [root, *root.rglob("*")]:
        if path.is_symlink():
            continue
        if path.is_dir():
            path.chmod(0o755)
        else:
            path.chmod(0o755 if path.stat().st_mode & 0o100 else 0o644)


# The package's executables, which must stay so for every user.
_EXECUTABLES = ("/usr/lib/conduit/conduit-desktop", "/usr/lib/conduit/conduitd/bin/conduitd")


def package_mode_problems(listing, fmt):
    """What in a package listing (`dpkg-deb -c` for "deb", `rpm -qlvp` for
    "rpm") a user other than root couldn't read or run."""
    problems = []
    for line in listing.splitlines():
        if not line.strip():
            continue
        if fmt == "deb":
            perms, owner, _size, _date, _time, rest = line.split(maxsplit=5)
            path = rest.split(" -> ")[0].removeprefix(".")
            root_owned = owner in ("root/root", "0/0")
        else:
            perms, _links, owner, group, _size, _month, _day, _time, rest = line.split(maxsplit=8)
            path = rest.split(" -> ")[0]
            root_owned = (owner, group) == ("root", "root")
        if perms.startswith("l"):
            continue
        if perms.startswith("d"):
            wanted = ("drwxr-xr-x",)
        elif path in _EXECUTABLES:
            wanted = ("-rwxr-xr-x",)
        else:
            wanted = ("-rw-r--r--", "-rwxr-xr-x")
        if perms not in wanted or not root_owned:
            problems.append(f"{path} is {perms} {owner}, not {' or '.join(wanted)} owned by root")
    return problems


def _package_listing(package):
    command = ["dpkg-deb", "-c"] if package.endswith(".deb") else ["rpm", "-qlvp"]
    return subprocess.run([*command, package], check=True, capture_output=True, text=True).stdout


# --- what the packages require -----------------------------------------------

# Beyond the libraries the binaries link: the system's root certificates,
# which the update notice reads its HTTPS feed with
# (crates/app/src/updates/notice.rs). Named so on Debian, Ubuntu, Fedora and
# openSUSE.
EXTRA_REQUIRES = ("ca-certificates",)


def missing_requires(requires, fmt):
    """The EXTRA_REQUIRES a package's requirements lack: `dpkg-deb -f PKG
    Depends` for "deb", `rpm -qp --requires PKG` for "rpm"."""
    if fmt == "deb":
        names = {alt.split()[0] for dep in requires.split(",") for alt in dep.split("|") if alt.strip()}
    else:
        names = {line.split()[0] for line in requires.splitlines() if line.strip()}
    return [name for name in EXTRA_REQUIRES if name not in names]


def _package_requires(package):
    command = ["dpkg-deb", "-f", package, "Depends"] if package.endswith(".deb") else ["rpm", "-qp", "--requires", package]
    return subprocess.run(command, check=True, capture_output=True, text=True).stdout


# --- rpm requirements -------------------------------------------------------


def _needed(readelf):
    return re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", readelf)


def shipped_sonames(readelf_outputs):
    return {s for out in readelf_outputs for s in re.findall(r"\(SONAME\)\s+Library soname: \[([^\]]+)\]", out)}


def rpm_requires(readelf_outputs, shipped):
    """What rpmbuild's ELF dependency generator would require for 64-bit
    files with this `readelf -d -V --wide` output: each needed soname, and
    each symbol version needed from it, except libraries the package ships."""
    requires = set()
    for out in readelf_outputs:
        requires.update(f"{s}()(64bit)" for s in _needed(out) if s not in shipped)
        in_needs, file = False, None
        for line in out.splitlines():
            if line.startswith("Version needs section"):
                in_needs = True
            elif line and not line.startswith(" "):
                in_needs = False
            elif in_needs:
                m = re.search(r"\bFile: (\S+)", line)
                if m:
                    file = m.group(1)
                m = re.search(r"\bName: (\S+)", line)
                if m and file and file not in shipped:
                    requires.add(f"{file}({m.group(1)})(64bit)")
    return sorted(requires)


def _elf_files(root):
    for path in sorted(Path(root).rglob("*")):
        if path.is_file() and not path.is_symlink():
            with open(path, "rb") as f:
                if f.read(4) == b"\x7fELF":
                    yield path


def _readelf(path):
    return subprocess.run(
        ["readelf", "-d", "-V", "--wide", str(path)], check=True, capture_output=True, text=True
    ).stdout


# --- uninstall --------------------------------------------------------------


def leftovers(paths):
    """The files (or empty folders) still at `paths`."""
    left = []
    for path in map(Path, paths):
        if path.is_dir() and not path.is_symlink():
            inside = sorted(str(p) for p in path.rglob("*") if not p.is_dir())
            left.extend(inside or [str(path)])
        elif path.exists() or path.is_symlink():
            left.append(str(path))
    return left


def forget_handler(text, mime_type, entry):
    """`text` (a mimeapps.list) with desktop entry `entry` taken out of
    `mime_type`'s lists in every group, and a key left with none dropped."""
    out = []
    for line in text.splitlines(keepends=True):
        key, sep, value = line.partition("=")
        if sep and key.strip() == mime_type:
            entries = [e.strip() for e in value.strip().split(";") if e.strip()]
            if entry in entries:
                kept = [e for e in entries if e != entry]
                if not kept:
                    continue
                line = f"{key}={';'.join(kept)};\n"
        out.append(line)
    return "".join(out)


# --- icons ------------------------------------------------------------------


def _png_side(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError("not a PNG")
    width, height = struct.unpack_from(">II", data, 16)
    if width != height or not 1 <= width <= 256:
        raise ValueError(f"an icon image is square and at most 256 px, not {width}x{height}")
    return width


def ico(pngs):
    """An .ico holding each PNG as it is (PNG entries: Windows Vista and
    later)."""
    sides = [_png_side(p) for p in pngs]
    out = struct.pack("<HHH", 0, 1, len(pngs))
    offset = 6 + 16 * len(pngs)
    for side, data in zip(sides, pngs):
        out += struct.pack("<BBBBHHII", side % 256, side % 256, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    return out + b"".join(pngs)


# --- command line -----------------------------------------------------------


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)
    p = sub.add_parser("version")
    p.add_argument("version")
    p.add_argument("--windows", action="store_true")
    p = sub.add_parser("types")
    p.add_argument("os", choices=["windows", "linux", "desktop-entry"])
    p = sub.add_parser("layout")
    p.add_argument("dir")
    p.add_argument("--os", required=True, choices=["windows", "linux"])
    p = sub.add_parser("notices")
    p.add_argument("file")
    p.add_argument("--os", required=True, choices=["windows", "linux"])
    p = sub.add_parser("modes")
    p.add_argument("dir")
    p = sub.add_parser("package-modes")
    p.add_argument("packages", nargs="+")
    sub.add_parser("extra-requires")
    p = sub.add_parser("package-requires")
    p.add_argument("packages", nargs="+")
    p = sub.add_parser("rpm-requires")
    p.add_argument("dir")
    p = sub.add_parser("gone")
    p.add_argument("paths", nargs="+")
    p = sub.add_parser("forget-handler")
    p.add_argument("list")
    p.add_argument("mime_type")
    p.add_argument("entry")
    p = sub.add_parser("ico")
    p.add_argument("out")
    p.add_argument("pngs", nargs="+")
    args = ap.parse_args(argv)

    try:
        if args.command == "version":
            print(windows_file_version(args.version) if args.windows else check_version(args.version))
        elif args.command == "types":
            types = {"windows": windows_extensions, "linux": linux_mime_types,
                     "desktop-entry": desktop_entry_types}[args.os]()
            print("\n".join(types))
        elif args.command == "layout":
            problems = layout_problems(args.dir, args.os)
            for problem in problems:
                print(f"error: {problem}", file=sys.stderr)
            if problems:
                return 1
            print(f"{args.dir}: the {args.os} install layout is complete")
        elif args.command == "notices":
            problems = notices_problems(args.file, args.os)
            for problem in problems:
                print(f"error: {problem}", file=sys.stderr)
            if problems:
                return 1
        elif args.command == "modes":
            normalize_modes(args.dir)
        elif args.command == "package-modes":
            problems = [
                f"{Path(pkg).name}: {problem}"
                for pkg in args.packages
                for problem in package_mode_problems(
                    _package_listing(pkg), "deb" if pkg.endswith(".deb") else "rpm"
                )
            ]
            for problem in problems:
                print(f"error: {problem}", file=sys.stderr)
            if problems:
                return 1
            print(f"every file of {len(args.packages)} package(s) is root's and readable by everyone")
        elif args.command == "extra-requires":
            print("\n".join(EXTRA_REQUIRES))
        elif args.command == "package-requires":
            problems = [
                f"{Path(pkg).name} doesn't require {name}"
                for pkg in args.packages
                for name in missing_requires(_package_requires(pkg), "deb" if pkg.endswith(".deb") else "rpm")
            ]
            for problem in problems:
                print(f"error: {problem}", file=sys.stderr)
            if problems:
                return 1
            print(f"{len(args.packages)} package(s) require {', '.join(EXTRA_REQUIRES)}")
        elif args.command == "rpm-requires":
            outputs = [_readelf(p) for p in _elf_files(args.dir)]
            shipped = shipped_sonames(outputs) | {p.name for p in Path(args.dir).rglob("*.so*")}
            print("\n".join(rpm_requires(outputs, shipped)))
        elif args.command == "gone":
            left = leftovers(args.paths)
            for path in left:
                print(f"error: still there: {path}", file=sys.stderr)
            if left:
                return 1
            print(f"none of the {len(args.paths)} paths is left")
        elif args.command == "forget-handler":
            path = Path(args.list)
            if path.is_file():
                text = path.read_text(encoding="utf-8")
                kept = forget_handler(text, args.mime_type, args.entry)
                if kept != text:
                    path.write_text(kept, encoding="utf-8")
                    print(f"{path}: {args.entry} is no longer listed for {args.mime_type}")
        elif args.command == "ico":
            Path(args.out).write_bytes(ico([Path(p).read_bytes() for p in args.pngs]))
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
