"""Tests for winlinux.py, the Windows and Linux packaging helper.

    python3 desktop/packaging/winlinux_test.py

Every tree and binary here is synthetic, made in a temporary folder.
"""

import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import winlinux  # noqa: E402

INFO_PLIST = HERE / "macos" / "Info.plist"
ISS = HERE / "windows" / "conduit.iss"
DESKTOP_ENTRY = HERE / "linux" / "conduit-desktop.desktop"
HARNESS = b"conduit-desktop: test harness build"


def pe(imports=(), delayed=()):
    """A minimal PE32+ image whose one section holds an import table for
    `imports` and a delay-load table for `delayed`."""
    rva = 0x1000
    names = list(imports) + list(delayed)
    tables = 20 * (len(imports) + 1) + 32 * (len(delayed) + 1)
    blob, name_rvas = b"", []
    for name in names:
        name_rvas.append(rva + tables + len(blob))
        blob += name.encode() + b"\0"
    section = b""
    for i in range(len(imports)):
        section += struct.pack("<5I", 0, 0, 0, name_rvas[i], rva)
    section += bytes(20)
    for i in range(len(delayed)):
        section += struct.pack("<8I", 1, name_rvas[len(imports) + i], 0, 0, 0, 0, 0, 0)
    section += bytes(32)
    section += blob
    raw = section + bytes(-len(section) % 0x200)

    optional = bytearray(240)
    struct.pack_into("<H", optional, 0, 0x20B)
    struct.pack_into("<Q", optional, 24, 0x140000000)
    struct.pack_into("<I", optional, 108, 16)
    struct.pack_into("<II", optional, 112 + 8 * 1, rva, 20 * (len(imports) + 1))
    if delayed:
        struct.pack_into(
            "<II", optional, 112 + 8 * 13, rva + 20 * (len(imports) + 1), 32 * (len(delayed) + 1)
        )
    header = b"MZ" + bytes(58) + struct.pack("<I", 0x40)
    header += b"PE\0\0" + struct.pack("<HHIIIHH", 0x8664, 1, 0, 0, 0, len(optional), 0x22)
    header += bytes(optional)
    header += struct.pack(
        "<8sIIIIIIHHI", b".idata", len(section), rva, len(raw), 0x200, 0, 0, 0, 0, 0x40000040
    )
    header += bytes(0x200 - len(header))
    return header + raw


def png(size):
    """A PNG signature and IHDR of `size` x `size`: what an icon entry reads."""
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + ihdr + b"\0\0\0\0"


class Tree:
    """A synthetic install folder."""

    def __init__(self, test):
        self.root = Path(tempfile.mkdtemp(prefix="conduit-winlinux-"))
        test.addCleanup(shutil.rmtree, self.root)

    def file(self, rel, data=b"", mode=0o644):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(mode)
        return path

    def windows(self):
        self.file("conduit-desktop.exe", pe(["KERNEL32.dll", "USER32.dll"], ["d3d11.dll"]))
        self.file("conduit.ico", b"\0\0\1\0")
        self.file("conduitd/bin/conduitd.exe", pe(["KERNEL32.dll"]))
        self.file("conduitd/lib/sqlite3.dll", pe(["KERNEL32.dll"]))
        self.file("conduitd/model_logos/catalog.json", b"{}")
        return self

    def linux(self):
        self.file("conduit-desktop", b"\x7fELF app", 0o755)
        self.file("conduitd/bin/conduitd", b"\x7fELF daemon", 0o755)
        self.file("conduitd/lib/libsqlite3.so", b"\x7fELF sqlite", 0o644)
        self.file("conduitd/model_logos/catalog.json", b"{}")
        return self


class Versions(unittest.TestCase):
    GOOD = ["0.0.0", "1.2.0", "10.20.30", "1.2.0-beta.3"]
    BAD = ["01.2.0", "1.2", "1.2.0-rc.1", "v1.2.0", "1.2.0-beta.01", "1.2.0-beta", ""]

    def test_the_mac_rule(self):
        for version in self.GOOD:
            winlinux.check_version(version)
        for version in self.BAD:
            with self.assertRaises(ValueError, msg=version):
                winlinux.check_version(version)

    @unittest.skipIf(os.name == "nt", "lib.sh is the Mac's bash library")
    def test_agrees_with_the_mac_scripts(self):
        lib = HERE / "macos" / "lib.sh"
        for version in self.GOOD + self.BAD:
            mac = subprocess.run(
                ["bash", "-c", '. "$1" && check_version "$2"', "bash", str(lib), version],
                capture_output=True,
            ).returncode == 0
            try:
                winlinux.check_version(version)
                ours = True
            except ValueError:
                ours = False
            self.assertEqual(ours, mac, version)

    def test_windows_file_version_is_four_numbers(self):
        self.assertEqual(winlinux.windows_file_version("1.2.3"), "1.2.3.0")
        self.assertEqual(winlinux.windows_file_version("1.2.3-beta.4"), "1.2.3.0")
        # VERSIONINFO holds 16-bit numbers.
        with self.assertRaises(ValueError):
            winlinux.windows_file_version("70000.0.0")


class FileTypes(unittest.TestCase):
    """The Mac's document types (Info.plist) are the source for Windows'
    Open With registrations and the Linux desktop entry's MIME types."""

    def test_every_mac_type_maps(self):
        self.assertEqual(
            winlinux.windows_extensions(INFO_PLIST),
            [".pdf", ".txt", ".md", ".markdown", ".csv", ".json", ".docx", ".xlsx",
             ".pptx", ".png", ".jpg", ".jpeg", ".gif", ".webp"],
        )
        self.assertIn("text/markdown", winlinux.linux_mime_types(INFO_PLIST))

    def test_an_unknown_mac_type_is_refused(self):
        with self.assertRaises(ValueError):
            winlinux.map_types(["public.plain-text", "com.example.unheard-of"])

    def test_the_installer_registers_exactly_the_mac_types(self):
        text = ISS.read_text(encoding="utf-8")
        progids = re.findall(r'Subkey: "Software\\Classes\\(\.[a-z]+)\\OpenWithProgids"', text)
        supported = re.findall(r'SupportedTypes"; ValueType: string; ValueName: "(\.[a-z]+)"', text)
        want = winlinux.windows_extensions(INFO_PLIST)
        self.assertEqual(progids, want)
        self.assertEqual(supported, want)

    def test_the_desktop_entry_lists_the_scheme_and_the_mac_types(self):
        line = next(
            l for l in DESKTOP_ENTRY.read_text(encoding="utf-8").splitlines()
            if l.startswith("MimeType=")
        )
        self.assertEqual(
            line[len("MimeType="):].rstrip(";").split(";"),
            ["x-scheme-handler/conduit"] + winlinux.linux_mime_types(INFO_PLIST),
        )


class InstallerIdentity(unittest.TestCase):
    def test_the_app_id_never_changes(self):
        # An installer with another AppId installs a second copy beside the
        # first instead of upgrading it; smoke.ps1 finds the uninstall key
        # from the define.
        text = ISS.read_text(encoding="utf-8")
        self.assertIn('#define AppGuid "536D4CBE-1A63-41FD-94E6-E05B2555BECC"\n', text)
        self.assertIn("\nAppId={{{#AppGuid}}\n", text)


class PeImports(unittest.TestCase):
    def test_reads_imports_and_delay_loads(self):
        image = pe(["KERNEL32.dll", "VCRUNTIME140.dll"], ["d3d11.dll"])
        self.assertEqual(
            winlinux.pe_imports(image), ["KERNEL32.dll", "VCRUNTIME140.dll", "d3d11.dll"]
        )

    def test_not_a_pe(self):
        with self.assertRaises(ValueError):
            winlinux.pe_imports(b"\x7fELF")


class Layout(unittest.TestCase):
    def test_a_complete_windows_install(self):
        self.assertEqual(winlinux.layout_problems(Tree(self).windows().root, "windows"), [])

    def test_a_complete_linux_install(self):
        self.assertEqual(winlinux.layout_problems(Tree(self).linux().root, "linux"), [])

    def test_the_daemon_and_its_sqlite_are_required(self):
        tree = Tree(self).linux()
        (tree.root / "conduitd/bin/conduitd").unlink()
        (tree.root / "conduitd/lib/libsqlite3.so").unlink()
        problems = winlinux.layout_problems(tree.root, "linux")
        self.assertTrue(any("conduitd/bin/conduitd" in p for p in problems), problems)
        self.assertTrue(any("sqlite3" in p for p in problems), problems)

    @unittest.skipIf(os.name == "nt", "Windows has no executable bit")
    def test_a_linux_app_that_isnt_executable(self):
        tree = Tree(self).linux()
        (tree.root / "conduit-desktop").chmod(0o644)
        self.assertEqual(len(winlinux.layout_problems(tree.root, "linux")), 1)

    def test_a_harness_build_never_ships(self):
        for os_name, exe in (("windows", "conduit-desktop.exe"), ("linux", "conduit-desktop")):
            tree = getattr(Tree(self), os_name)()
            path = tree.root / exe
            path.write_bytes(path.read_bytes() + b"..." + HARNESS + b"...")
            problems = winlinux.layout_problems(tree.root, os_name)
            self.assertTrue(any("test harness" in p for p in problems), problems)

    def test_a_windows_pe_needing_the_vc_runtime_it_doesnt_ship(self):
        tree = Tree(self).windows()
        tree.file("conduitd/lib/sqlite3.dll", pe(["KERNEL32.dll", "VCRUNTIME140.dll"]))
        problems = winlinux.layout_problems(tree.root, "windows")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("VCRUNTIME140.dll", problems[0])
        # Shipped with the app, it is found.
        tree.file("conduitd/lib/vcruntime140.dll", pe(["KERNEL32.dll"]))
        self.assertEqual(winlinux.layout_problems(tree.root, "windows"), [])


READELF_APP = """
Dynamic section at offset 0x5f0d0 contains 4 entries:
  Tag        Type                         Name/Value
 0x0000000000000001 (NEEDED)             Shared library: [libgtk-3.so.0]
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [libsqlite3.so]

Version symbols section '.gnu.version' contains 3 entries:
 Addr: 0x0000000000000a00  Offset: 0x000a00  Link: 5 (.dynsym)
  000:   0 (*local*)       2 (GLIBC_2.2.5)   3 (GLIBC_2.34)

Version needs section '.gnu.version_r' contains 1 entry:
 Addr: 0x0000000000000a28  Offset: 0x000a28  Link: 6 (.dynstr)
  000000: Version: 1  File: libc.so.6  Cnt: 2
  0x0010:   Name: GLIBC_2.34  Flags: none  Version: 3
  0x0020:   Name: GLIBC_2.2.5  Flags: none  Version: 2
"""

READELF_LIB = """
Dynamic section at offset 0x1000 contains 2 entries:
  Tag        Type                         Name/Value
 0x0000000000000001 (NEEDED)             Shared library: [libm.so.6]
 0x000000000000000e (SONAME)             Library soname: [libsqlite3.so]

Version definition section '.gnu.version_d' contains 1 entry:
 Addr: 0x0000000000000300  Offset: 0x000300  Link: 4 (.dynstr)
  000000: Rev: 1  Flags: BASE  Index: 1  Cnt: 1  Name: libsqlite3.so

Version needs section '.gnu.version_r' contains 1 entry:
 Addr: 0x0000000000000340  Offset: 0x000340  Link: 4 (.dynstr)
  000000: Version: 1  File: libm.so.6  Cnt: 1
  0x0010:   Name: GLIBC_2.29  Flags: none  Version: 2
"""


class RpmRequires(unittest.TestCase):
    def test_sonames_and_symbol_versions_except_what_ships(self):
        self.assertEqual(
            winlinux.rpm_requires([READELF_APP, READELF_LIB], {"libsqlite3.so"}),
            [
                "libc.so.6()(64bit)",
                "libc.so.6(GLIBC_2.2.5)(64bit)",
                "libc.so.6(GLIBC_2.34)(64bit)",
                "libgtk-3.so.0()(64bit)",
                "libm.so.6()(64bit)",
                "libm.so.6(GLIBC_2.29)(64bit)",
            ],
        )

    def test_the_sonames_a_package_ships(self):
        self.assertEqual(winlinux.shipped_sonames([READELF_APP, READELF_LIB]), {"libsqlite3.so"})


class Leftovers(unittest.TestCase):
    def test_what_an_uninstall_left(self):
        tree = Tree(self)
        tree.file("Conduit/conduitd/bin/conduitd.exe", b"x")
        tree.file("Conduit.lnk", b"x")
        self.assertEqual(
            winlinux.leftovers([tree.root / "Conduit", tree.root / "Conduit.lnk",
                                tree.root / "never-there"]),
            [str(tree.root / "Conduit" / "conduitd" / "bin" / "conduitd.exe"),
             str(tree.root / "Conduit.lnk")],
        )

    def test_an_empty_folder_left_behind_counts(self):
        tree = Tree(self)
        (tree.root / "Conduit").mkdir()
        self.assertEqual(winlinux.leftovers([tree.root / "Conduit"]), [str(tree.root / "Conduit")])


class Icons(unittest.TestCase):
    def test_packs_pngs_into_an_ico(self):
        images = [png(16), png(256)]
        ico = winlinux.ico(images)
        self.assertEqual(struct.unpack_from("<HHH", ico, 0), (0, 1, 2))
        offset = 6 + 16 * 2
        for i, (image, side) in enumerate(zip(images, (16, 0))):
            width, height, _, _, planes, bits, size, at = struct.unpack_from("<BBBBHHII", ico, 6 + 16 * i)
            self.assertEqual((width, height, planes, bits, size, at), (side, side, 1, 32, len(image), offset))
            self.assertEqual(ico[at:at + size], image)
            offset += size

    def test_refuses_what_an_icon_cant_hold(self):
        for bad in (png(512), b"not a png"):
            with self.assertRaises(ValueError):
                winlinux.ico([bad])


if __name__ == "__main__":
    unittest.main()
