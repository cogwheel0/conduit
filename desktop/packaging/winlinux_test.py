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
import winlinux_feed  # noqa: E402

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
        self.file("WinSparkle.dll", pe(["KERNEL32.dll", "WININET.dll"]))
        self.file("conduitd/bin/conduitd.exe", pe(["KERNEL32.dll"]))
        self.file("conduitd/lib/sqlite3.dll", pe(["KERNEL32.dll"]))
        self.file("conduitd/model_logos/catalog.json", b"{}")
        self.file("THIRD_PARTY_NOTICES.md", b"# Third-party notices: Conduit Desktop for Windows\n")
        return self

    def linux(self):
        self.file("conduit-desktop", b"\x7fELF app", 0o755)
        self.file("conduitd/bin/conduitd", b"\x7fELF daemon", 0o755)
        self.file("conduitd/lib/libsqlite3.so", b"\x7fELF sqlite", 0o644)
        self.file("conduitd/model_logos/catalog.json", b"{}")
        self.file("THIRD_PARTY_NOTICES.md", b"# Third-party notices: Conduit Desktop for Linux\n")
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

    def test_the_whole_value_is_the_version(self):
        # Nothing before or after it, a final newline included.
        for version in ("1.2.3\n", "1.2.3\nfoo", " 1.2.3", "1.2.3 "):
            with self.assertRaises(ValueError, msg=repr(version)):
                winlinux.check_version(version)

    def test_windows_file_version_is_four_numbers(self):
        self.assertEqual(winlinux.windows_file_version("1.2.3"), "1.2.3.0")
        self.assertEqual(winlinux.windows_file_version("1.2.3-beta.4"), "1.2.3.0")
        # VERSIONINFO holds 16-bit numbers.
        with self.assertRaises(ValueError):
            winlinux.windows_file_version("70000.0.0")


class FeedVersions(unittest.TestCase):
    """The Windows and Linux feeds order releases by the Mac's build
    numbers, which the apps compute too (updates::config)."""

    def test_build_numbers(self):
        self.assertEqual(winlinux_feed.build_number("1.2.0"), 1020099)
        self.assertEqual(winlinux_feed.build_number("1.2.0-beta.3"), 1020003)
        self.assertEqual(winlinux_feed.build_number("0.0.0"), 99)
        for bad in ("1.2", "01.2.0", "1.100.0", "1.2.0-beta.99", "1.2.0-beta.0", "1.2.0\n"):
            with self.assertRaises(winlinux_feed.FeedError, msg=bad):
                winlinux_feed.build_number(bad)

    @unittest.skipIf(os.name == "nt", "lib.sh is the Mac's bash library")
    def test_agree_with_the_mac_scripts(self):
        lib = HERE / "macos" / "lib.sh"
        for version in ("0.0.0", "1.2.0", "1.2.1", "1.10.0", "10.99.99", "1.2.0-beta.1", "1.2.0-beta.98"):
            mac = subprocess.run(
                ["bash", "-c", '. "$1" && build_number "$2"', "bash", str(lib), version],
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
            self.assertEqual(str(winlinux_feed.build_number(version)), mac, version)

    def test_each_feed_sits_beside_the_mac_appcast(self):
        env = {"RELEASE_REPO": "owner/project", "APPCAST_RELEASE_TAG": "feeds", "APPCAST_BRANCH": "feed-branch"}
        for hosting, url in (
            ("release-asset", "https://github.com/owner/project/releases/download/feeds/appcast-windows.xml"),
            ("pages", "https://owner.github.io/project/desktop/appcast-windows.xml"),
            ("branch", "https://raw.githubusercontent.com/owner/project/feed-branch/appcast-windows.xml"),
        ):
            self.assertEqual(winlinux_feed.feed_url("windows", {**env, "APPCAST_HOSTING": hosting}), url)
        self.assertTrue(
            winlinux_feed.feed_url("linux", {**env, "APPCAST_HOSTING": "release-asset"}).endswith("/appcast-linux.xml")
        )


def pascal_body(text, signature):
    """An Inno [Code] routine from its signature to its closing `end;`."""
    body = text[text.index(signature):]
    return body[:body.index("\nend;")]


def pascal_call_args(text, name):
    """The argument text of each call to `name` (it ends with "("), up to
    its matching parenthesis, quotes skipped."""
    calls, at = [], 0
    while (at := text.find(name, at)) >= 0:
        if at > 0 and (text[at - 1].isalnum() or text[at - 1] == "_"):
            at += len(name)
            continue
        i, depth, quoted = at + len(name), 1, False
        while depth:
            c = text[i]
            if c == "'":
                quoted = not quoted
            elif not quoted and c in "()":
                depth += 1 if c == "(" else -1
            i += 1
        calls.append(text[at + len(name):i - 1])
        at = i
    return calls


def entry_mime_types():
    line = next(
        l for l in DESKTOP_ENTRY.read_text(encoding="utf-8").splitlines()
        if l.startswith("MimeType=")
    )
    return line[len("MimeType="):].rstrip(";").split(";")


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
        self.assertEqual(
            entry_mime_types(),
            ["x-scheme-handler/conduit"] + winlinux.desktop_entry_types(INFO_PLIST),
        )

    def test_the_desktop_entry_lists_no_type_a_parent_type_reaches(self):
        # GIO (GNOME's file manager, and xdg-open there) takes an app that
        # lists a type itself before its parent type's default. Listed,
        # Markdown, CSV and JSON would open in Conduit wherever only
        # text/plain has a default (GNOME), and Word, Excel and PowerPoint
        # files wherever no office suite is installed (application/zip's
        # default, the Archive Manager, opens them otherwise).
        listed = entry_mime_types()
        for parent_reaches in [
            "text/markdown",
            "text/csv",
            "application/json",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        ]:
            self.assertIn(parent_reaches, winlinux.linux_mime_types(INFO_PLIST))
            self.assertNotIn(parent_reaches, listed)
        # Open With still offers Conduit for them: text/plain's apps are
        # theirs too.
        self.assertIn("text/plain", listed)


class InstallerIdentity(unittest.TestCase):
    def test_the_app_id_never_changes(self):
        # An installer with another AppId installs a second copy beside the
        # first instead of upgrading it; smoke.ps1 finds the uninstall key
        # from the define.
        text = ISS.read_text(encoding="utf-8")
        self.assertIn('#define AppGuid "536D4CBE-1A63-41FD-94E6-E05B2555BECC"\n', text)
        self.assertIn("\nAppId={{{#AppGuid}}\n", text)


class UpdateInstall(unittest.TestCase):
    """What WinSparkle runs the downloaded installer with, and what the
    installer does with it."""

    def test_winsparkle_runs_the_installer_silently_and_it_relaunches_the_app(self):
        args = winlinux_feed.INSTALLER_ARGUMENTS.split()
        self.assertIn("/SILENT", args)
        self.assertIn("/RELAUNCH=1", args)
        text = ISS.read_text(encoding="utf-8")
        # The app again once the update is in, whatever /SILENT skips.
        run = next(l for l in text.splitlines() if "Check: RelaunchAfterUpdate" in l)
        self.assertIn('Filename: "{app}\\conduit-desktop.exe"', run)
        self.assertNotIn("skipifsilent", run)
        self.assertIn("ExpandConstant('{param:RELAUNCH|0}') = '1'", text)
        # A running Conduit and its conduitd are closed first, before Setup
        # replaces and Uninstall removes their files, by [Code] over the
        # processes running from the app's folder: never Inno's
        # CloseApplications, which shuts down every program and service
        # with those files open.
        self.assertIn("\nCloseApplications=no\n", text)
        prepare = pascal_body(text, "function PrepareToInstall(")
        # A listing Restart Manager couldn't make can't say Conduit isn't
        # running: both gates stop on it as on a failed close.
        self.assertTrue("function FindRunningApp(" in text, "FindRunningApp doesn't report whether it could list")
        find = pascal_body(text, "function FindRunningApp(")
        self.assertIn("): Boolean;", find.splitlines()[0])
        self.assertIn("Result := False;", find)
        for call in ("RmStartSession", "RmRegisterResources", "RmGetList"):
            self.assertIn(f"Restart Manager: {call} failed", find)
        self.assertRegex(prepare, r"if not FindRunningApp\(Ours, Names\) then\s+begin\s+Result := SetupMessage\(msgErrorCloseApplications\)")
        # A Conduit that didn't end, or one started meanwhile and still there
        # after a few rounds, stops the install: files in use can't be
        # replaced.
        self.assertRegex(prepare, r"if not CloseUntilNoneRun\(Ours, Names\) then\s+Result := SetupMessage\(msgErrorCloseApplications\)")
        self.assertTrue("function CloseUntilNoneRun(" in text, "no listing again after the close")
        rounds = pascal_body(text, "function CloseUntilNoneRun(")
        self.assertRegex(rounds, r"for Round := 1 to CloseRounds do")
        self.assertLess(rounds.index("CloseProcesses(Ours)"), rounds.index("FindRunningApp(Ours, Names)"))
        # The uninstall stops before removing anything unless Conduit ended:
        # Inno's own running-app question (OK tries again), then Abort,
        # which ends Uninstall from usUninstall.
        uninstall = pascal_body(text, "procedure CurUninstallStepChanged(")
        self.assertRegex(uninstall, r"if FindRunningApp\(Ours, Names\) then\s+if CloseUntilNoneRun\(Ours, Names\) then\s+Exit;")
        for used in ("usUninstall", "SetupMessage(msgUninstallAppRunningError)",
                     "MB_OKCANCEL, IDCANCEL", "Abort;"):
            self.assertIn(used, uninstall)
        # Closing succeeds only once each process has really ended, waited
        # on by handle, a reused pid told apart by its start time.
        close = pascal_body(text, "function CloseProcesses(")
        self.assertIn("): Boolean;", close.splitlines()[0])
        self.assertIn("ProcessEnded(", close)
        ended = pascal_body(text, "function ProcessEnded(")
        for used in ("WaitForSingleObject(", "GetProcessTimes(", "StartTimeLow", "ERROR_ACCESS_DENIED"):
            self.assertIn(used, ended)
        # Run by hand, Setup asks first, in Inno's own translated words (its
        # Preparing to Install page's); No stops it with Inno's message.
        for used in ("not WizardSilent", "SuppressibleMsgBox(", "SetupMessage(msgApplicationsFound)",
                     "SetupMessage(msgCloseApplications)", "Result := SetupMessage(msgErrorCloseApplications)"):
            self.assertIn(used, prepare)
        # RmShutdown runs only in a session that registers Conduit's own
        # processes, never the files.
        self.assertNotIn("RmShutdown(", find)
        # Conduit's processes are the ones running from its folder, whatever
        # Restart Manager calls them: to an unelevated Setup, an elevated
        # Conduit is "critical", and leaving it alone let the uninstall go on.
        self.assertNotIn("AppType <>", find)
        self.assertIn("RmShutdown(", close)
        self.assertIn("RmRegisterProcess(", close)
        self.assertNotIn("RmRegisterFiles(", close)

    def test_the_installer_shows_inno_setups_words_only(self):
        # New text would need a translation in every language the installer
        # has: what [Code] shows comes from Inno's messages (SetupMessage).
        code = ISS.read_text(encoding="utf-8").split("\n[Code]\n", 1)[1]
        shown = [a for name in ("MsgBox(", "SuppressibleMsgBox(", "TaskDialogMsgBox(") for a in pascal_call_args(code, name)]
        shown += re.findall(r"Result := (.*?);", pascal_body(code, "function PrepareToInstall("), re.S)
        self.assertGreaterEqual(len(shown), 2)
        for text in shown:
            # A preprocessor value ('{#AppName}') is the product's name.
            self.assertIsNone(re.search(r"'(?!\{#\w+\}')[^']*[A-Za-z][^']*'", text), text)


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

    def test_winsparkle_sits_beside_the_app(self):
        # The app loads it from its own folder (updates::winsparkle); in
        # conduitd\\ or missing, the installed app has no updater.
        tree = Tree(self).windows()
        (tree.root / "WinSparkle.dll").unlink()
        problems = winlinux.layout_problems(tree.root, "windows")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("WinSparkle.dll", problems[0])
        tree.file("conduitd/bin/WinSparkle.dll", pe(["KERNEL32.dll"]))
        self.assertEqual(len(winlinux.layout_problems(tree.root, "windows")), 1)

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

    def test_each_os_ships_its_own_notices_beside_the_app(self):
        # The licences of what that OS's build includes, in the install
        # folder (on Linux too: a minimized system drops /usr/share/doc), not
        # missing, and not the Mac's or another OS's (made for another
        # target).
        for os_name, other in (("windows", b"Linux"), ("linux", b"Windows")):
            for notices in (None, b"# Third-party notices: Conduit Desktop for " + other + b"\n"):
                tree = getattr(Tree(self), os_name)()
                path = tree.root / "THIRD_PARTY_NOTICES.md"
                if notices is None:
                    path.unlink()
                else:
                    path.write_bytes(notices)
                problems = winlinux.layout_problems(tree.root, os_name)
                self.assertEqual(len(problems), 1, f"{os_name}: {problems}")
                self.assertIn("THIRD_PARTY_NOTICES.md", problems[0])

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
        # Beside conduitd.exe, the process that loads it, it is found.
        tree.file("conduitd/bin/vcruntime140.dll", pe(["KERNEL32.dll"]))
        self.assertEqual(winlinux.layout_problems(tree.root, "windows"), [])

    def test_a_runtime_dll_the_importing_process_cant_see(self):
        # Windows looks beside the process's executable (then the system),
        # never in another folder of the install: not beside the importing
        # DLL itself, nor beside the other process's executable.
        for importer, elsewhere in (
            ("conduit-desktop.exe", "conduitd/lib/vcruntime140.dll"),
            ("conduit-desktop.exe", "conduitd/bin/vcruntime140.dll"),
            ("conduitd/bin/conduitd.exe", "vcruntime140.dll"),
            ("conduitd/lib/sqlite3.dll", "conduitd/lib/vcruntime140.dll"),
        ):
            tree = Tree(self).windows()
            tree.file(importer, pe(["KERNEL32.dll", "VCRUNTIME140.dll"]))
            tree.file(elsewhere, pe(["KERNEL32.dll"]))
            problems = winlinux.layout_problems(tree.root, "windows")
            self.assertTrue(
                any(p.startswith(importer) and "VCRUNTIME140.dll" in p for p in problems),
                f"{importer} with the DLL at {elsewhere}: {problems}",
            )


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


DEB_LISTING = """\
drwxr-xr-x 0/0               0 2026-11-23 12:00 ./
drwxr-xr-x 0/0               0 2026-11-23 12:00 ./usr/
drwxr-xr-x root/root         0 2026-11-23 12:00 ./usr/lib/conduit/
-rwxr-xr-x root/root  91000000 2026-11-23 12:00 ./usr/lib/conduit/conduit-desktop
drwxr-xr-x root/root         0 2026-11-23 12:00 ./usr/lib/conduit/conduitd/bin/
-rwxr-xr-x root/root  20000000 2026-11-23 12:00 ./usr/lib/conduit/conduitd/bin/conduitd
-rw-r--r-- root/root   1500000 2026-11-23 12:00 ./usr/lib/conduit/conduitd/lib/libsqlite3.so
-rw-r--r-- root/root      9000 2026-11-23 12:00 ./usr/share/applications/conduit-desktop.desktop
lrwxrwxrwx root/root         0 2026-11-23 12:00 ./usr/bin/conduit-desktop -> /usr/lib/conduit/conduit-desktop
"""

RPM_LISTING = """\
lrwxrwxrwx    1 root     root                       32 Nov 23 12:00 /usr/bin/conduit-desktop -> /usr/lib/conduit/conduit-desktop
drwxr-xr-x    2 root     root                        0 Nov 23 12:00 /usr/lib/conduit
-rwxr-xr-x    1 root     root                 91000000 Nov 23 12:00 /usr/lib/conduit/conduit-desktop
-rwxr-xr-x    1 root     root                 20000000 Nov 23 12:00 /usr/lib/conduit/conduitd/bin/conduitd
-rw-r--r--    1 root     root                  1500000 Nov 23 12:00 /usr/lib/conduit/conduitd/lib/libsqlite3.so
"""


class Modes(unittest.TestCase):
    """A package built under any umask installs files every user can read
    and run: nfpm keeps the staged modes."""

    @unittest.skipIf(os.name == "nt", "Windows has no POSIX modes or umask")
    def test_the_staged_tree_is_readable_by_everyone_whatever_the_umask(self):
        tree = Tree(self)
        old = os.umask(0o077)
        try:
            app = tree.file("conduit-desktop", b"\x7fELF", 0o700)
            data = tree.file("conduitd/lib/libsqlite3.so", b"\x7fELF", 0o600)
            (tree.root / "conduitd" / "model_logos").mkdir()
        finally:
            os.umask(old)
        (tree.root / "conduitd").chmod(0o700)
        winlinux.normalize_modes(tree.root)
        mode = lambda p: p.stat().st_mode & 0o7777
        self.assertEqual(mode(app), 0o755)
        self.assertEqual(mode(data), 0o644)
        for folder in (tree.root, tree.root / "conduitd", tree.root / "conduitd" / "model_logos"):
            self.assertEqual(mode(folder), 0o755, folder)

    def test_a_built_package_installs_nothing_root_only(self):
        self.assertEqual(winlinux.package_mode_problems(DEB_LISTING, "deb"), [])
        self.assertEqual(winlinux.package_mode_problems(RPM_LISTING, "rpm"), [])
        bad_deb = DEB_LISTING.replace(
            "drwxr-xr-x root/root         0 2026-11-23 12:00 ./usr/lib/conduit/\n",
            "drwx------ root/root         0 2026-11-23 12:00 ./usr/lib/conduit/\n",
        ).replace("-rwxr-xr-x root/root  91000000", "-rwx------ root/root  91000000")
        problems = winlinux.package_mode_problems(bad_deb, "deb")
        self.assertEqual(len(problems), 2, problems)
        self.assertTrue(any("/usr/lib/conduit/ " in p for p in problems), problems)
        bad_rpm = RPM_LISTING.replace(
            "-rw-r--r--    1 root     root                  1500000",
            "-rw-------    1 root     root                  1500000",
        )
        problems = winlinux.package_mode_problems(bad_rpm, "rpm")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("libsqlite3.so", problems[0])
        # A file owned by someone else than root.
        problems = winlinux.package_mode_problems(
            DEB_LISTING.replace("root/root   1500000", "1001/1001   1500000"), "deb"
        )
        self.assertEqual(len(problems), 1, problems)

    def test_the_executables_stay_executable(self):
        listing = DEB_LISTING.replace(
            "-rwxr-xr-x root/root  20000000", "-rw-r--r-- root/root  20000000"
        )
        problems = winlinux.package_mode_problems(listing, "deb")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("conduitd/bin/conduitd", problems[0])


class PackageRequires(unittest.TestCase):
    """Beyond their libraries, the packages require the system's root
    certificates: the update notice reads its feed over HTTPS with them."""

    def test_the_root_certificates_are_required(self):
        deb = "libc6 (>= 2.35), libgtk-3-0 (>= 3.24), ca-certificates"
        self.assertEqual(winlinux.missing_requires(deb, "deb"), [])
        self.assertEqual(winlinux.missing_requires("libc6 (>= 2.35), libgtk-3-0", "deb"), ["ca-certificates"])
        # An alternative counts; a longer name that starts the same doesn't.
        self.assertEqual(winlinux.missing_requires("ca-certificates | ca-bundle", "deb"), [])
        self.assertEqual(winlinux.missing_requires("ca-certificates-java", "deb"), ["ca-certificates"])
        rpm = "libc.so.6()(64bit)\nca-certificates\nrpmlib(CompressedFileNames) <= 3.0.4-1\n"
        self.assertEqual(winlinux.missing_requires(rpm, "rpm"), [])
        self.assertEqual(winlinux.missing_requires("libc.so.6()(64bit)\n", "rpm"), ["ca-certificates"])


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


class ForgetHandler(unittest.TestCase):
    """crates/app/run.sh --unregister-scheme takes the dev entry out of the
    user's mimeapps.list, where xdg-mime made it conduit://'s default."""

    LIST = (
        "[Default Applications]\n"
        "x-scheme-handler/conduit=conduit-dev.desktop;\n"
        "text/plain=org.example.Editor.desktop;\n"
        "\n"
        "[Added Associations]\n"
        "x-scheme-handler/conduit=conduit-dev.desktop;conduit-desktop.desktop;\n"
        "text/plain=conduit-dev.desktop;\n"
    )

    def test_takes_out_only_that_entry_for_that_type(self):
        self.assertEqual(
            winlinux.forget_handler(self.LIST, "x-scheme-handler/conduit", "conduit-dev.desktop"),
            "[Default Applications]\n"
            "text/plain=org.example.Editor.desktop;\n"
            "\n"
            "[Added Associations]\n"
            "x-scheme-handler/conduit=conduit-desktop.desktop;\n"
            "text/plain=conduit-dev.desktop;\n",
        )

    def test_a_list_naming_other_entries_stays_as_it_is(self):
        for entry in ("conduit-dev", "other.desktop"):
            self.assertEqual(
                winlinux.forget_handler(self.LIST, "x-scheme-handler/conduit", entry), self.LIST
            )

    def test_the_file_is_written_only_when_it_changes(self):
        tree = Tree(self)
        path = tree.root / "mimeapps.list"
        path.write_text(self.LIST)
        args = ["forget-handler", str(path), "x-scheme-handler/conduit"]
        before = path.stat().st_mtime_ns
        self.assertEqual(winlinux.main(args + ["other.desktop"]), 0)
        self.assertEqual(path.stat().st_mtime_ns, before)
        self.assertEqual(winlinux.main(args + ["conduit-dev.desktop"]), 0)
        self.assertNotIn("conduit-dev.desktop;conduit", path.read_text())
        # No list at all: nothing to take out.
        self.assertEqual(winlinux.main(["forget-handler", str(tree.root / "none.list"),
                                        "x-scheme-handler/conduit", "conduit-dev.desktop"]), 0)
        self.assertFalse((tree.root / "none.list").exists())


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
