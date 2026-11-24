Conduit Desktop @VERSION@ for macOS, Windows and Linux.

**macOS** (Apple silicon, macOS 14 Sonoma or later): download `Conduit-@VERSION@.dmg`, open it and drag Conduit to Applications. Installed copies update themselves.

**Windows** (x64, Windows 10 or later): download `Conduit-@VERSION@-windows-x64-setup.exe` and run it. It installs for your account only, without administrator rights, and installed copies update themselves. The installer isn't signed yet, so on its first run SmartScreen stops it ("Windows protected your PC", publisher unknown): first check the download against its SHA-256 in `SHA256SUMS-windows.txt`, then choose **More info**, then **Run anyway**. Where Smart App Control is on, it blocks the installer outright.

**Linux** (x86_64): `conduit-desktop_@VERSION@-1_amd64.deb` for Debian 12 or later and Ubuntu 22.04 or later, `conduit-desktop-@VERSION@-1.x86_64.rpm` for Fedora and other RPM distributions. Install it with your package manager, for example `sudo apt install ./conduit-desktop_@VERSION@-1_amd64.deb` or `sudo dnf install ./conduit-desktop-@VERSION@-1.x86_64.rpm`. The app says when a newer version is out; your package manager installs it.

Release assets: the notarized DMG; `Conduit-@VERSION@-dSYMs.zip`, the Mac debug symbols for crash reports; the Windows installer; the .deb and the .rpm; `THIRD_PARTY_NOTICES-windows.md` and `THIRD_PARTY_NOTICES-linux.md`, the licences of what the Windows and Linux builds include; the signed update feeds `appcast.xml`, `appcast-windows.xml` and `appcast-linux.xml`, which go live when this release is published; and the checksums `SHA256SUMS.txt` (macOS), `SHA256SUMS-windows.txt` and `SHA256SUMS-linux.txt`.
