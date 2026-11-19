"""Assembles THIRD_PARTY_NOTICES.md (run by notices.sh), and fails when the
licence set is incomplete.

Inputs, all passed by notices.sh:
  --rust FILE          cargo-about's rendering of the Rust crates (about.hbs)
  --expected-crates F  `cargo tree --prefix none --format {p}` of the app's
                       normal dependencies: every one must be in --rust
  --pub-deps FILE      `dart pub deps --json` from apps/daemon
  --package-config F   the workspace's .dart_tool/package_config.json
  --sparkle-license F  LICENSE from the pinned Sparkle release
  --dart-sdk-license F the Dart SDK's LICENSE (the runtime inside conduitd)
  --repo DIR           the repository root
  --out FILE

Everything is read from files pinned by the repository (Cargo.lock,
pubspec.lock, release.env, the vendored copies), so the output only
changes when a shipped dependency does.
"""

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

LICENSE_NAMES = ("LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE", "COPYING", "license")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace").strip()


def fence(text: str) -> str:
    # A fence longer than any backtick run inside the text.
    longest = max((len(m) for m in re.findall(r"`+", text)), default=0)
    ticks = "`" * max(3, longest + 1)
    return f"{ticks}text\n{text}\n{ticks}"


def section(title: str, body: list[str]) -> str:
    return "\n".join([f"### {title}", "", *body, ""])


def bundled(repo: Path, args) -> list[str]:
    desktop = repo / "desktop"
    env = dict(
        line.split("=", 1)
        for line in read(desktop / "packaging/macos/release.env").splitlines()
        if line and not line.startswith("#") and "=" in line
    )
    cmake = read(repo / "apps/daemon/native/whisper/CMakeLists.txt")
    whisper_tag = re.search(r"GIT_TAG\s+(\S+)", cmake).group(1)
    chart_header = read(repo / "assets/chartjs.min.js")[:300]
    chart_version = re.search(r"Chart\.js v(\S+)", chart_header).group(1)
    mermaid_readme = read(desktop / "crates/app/assets/preview/README.md")
    mermaid_version = re.search(r"mermaid (\d+\.\d+\.\d+)", mermaid_readme).group(1)
    registry = registry_root(args)
    texts = Path(__file__).parent / "texts"

    out = []
    out.append(
        section(
            "gpui-pre 0.3.11 (GPUI), vendored and modified",
            [
                "Zed Industries' GPUI as published by GPUI Kit (gpui-pre), Apache-2.0.",
                "Conduit vendors a copy in `desktop/vendor/gpui-pre` with a few small changes;",
                "`desktop/vendor/gpui-pre/PATCHES.md` describes every modification.",
                "",
                fence(read(desktop / "vendor/gpui-pre/LICENSE-APACHE")),
            ],
        )
    )
    out.append(
        section(
            f"Sparkle {env['SPARKLE_VERSION']}",
            [
                "The update framework in Contents/Frameworks/Sparkle.framework (MIT, with the",
                "notices of the code it includes).",
                "",
                fence(read(Path(args.sparkle_license))),
            ],
        )
    )
    out.append(
        section(
            f"whisper.cpp {whisper_tag} (with ggml)",
            [
                "Local speech recognition, built into conduitd's lib/libconduit_whisper.dylib (MIT).",
                "",
                fence(read(texts / "whisper.cpp-LICENSE")),
            ],
        )
    )
    out.append(
        section(
            "SQLite",
            [
                "conduitd's database engine, lib/libsqlite3.dylib (built by the Dart `sqlite3`",
                "package's build hook).",
                "",
                fence(read(texts / "sqlite-BLESSING.txt")),
            ],
        )
    )
    out.append(
        section(
            "Dart SDK runtime",
            [
                "conduitd is compiled ahead of time with the Dart SDK and includes its runtime",
                "(BSD-3-Clause).",
                "",
                fence(read(Path(args.dart_sdk_license))),
            ],
        )
    )
    out.append(
        section(
            f"mermaid {mermaid_version}",
            [
                "Diagram rendering in the Preview window (MIT).",
                "",
                fence(read(desktop / "crates/app/assets/preview/MERMAID-LICENSE")),
            ],
        )
    )
    out.append(
        section(
            f"Chart.js {chart_version}",
            [
                "Chart rendering in the Preview window (MIT).",
                "",
                fence(read(texts / "chart.js-LICENSE.md")),
            ],
        )
    )
    novnc = read(repo / "assets/computer/novnc-LICENSE.txt")
    novnc_version = re.search(r"noVNC (\d+\.\d+\.\d+)", novnc).group(1)
    out.append(
        section(
            f"noVNC {novnc_version}",
            [
                "The Computer viewer's remote desktop client, in the app's copy of",
                "assets/computer/viewer.js (MPL-2.0; the notice says what the build changes",
                "and where its source is).",
                "",
                fence(novnc),
            ],
        )
    )
    lucide = sorted(registry.glob("gpui-kit-assets-*/LICENSE-LUCIDE"))
    if lucide:
        out.append(
            section(
                "Lucide icons",
                [
                    "The interface icons, through GPUI Kit's gpui-kit-assets (ISC).",
                    "",
                    fence(read(lucide[-1])),
                ],
            )
        )
    katex = sorted(registry.glob("ratex-katex-fonts-*/fonts"))
    if katex:
        fonts = katex[-1]
        body = ["The KaTeX math fonts, through ratex-katex-fonts (SIL Open Font License 1.1).", ""]
        if (fonts / "FONT_NOTICE.txt").exists():
            body += [fence(read(fonts / "FONT_NOTICE.txt")), ""]
        body.append(fence(read(fonts / "OFL.txt")))
        out.append(section("KaTeX fonts", body))
    return out


def registry_root(args) -> Path:
    # Where cargo unpacked the crates the Rust notices came from.
    return Path(args.cargo_registry)


def dart_packages(args) -> list[str]:
    deps = json.loads(Path(args.pub_deps).read_text())
    config = json.loads(Path(args.package_config).read_text())
    config_dir = Path(args.package_config).parent
    roots = {}
    for p in config["packages"]:
        uri = p["rootUri"]
        if uri.startswith("file:"):
            roots[p["name"]] = Path(unquote(urlparse(uri).path))
        else:
            roots[p["name"]] = (config_dir / uri).resolve()

    packages = {p["name"]: p for p in deps["packages"]}
    seen, stack = set(), ["conduitd"]
    while stack:
        name = stack.pop()
        if name in seen:
            continue
        seen.add(name)
        p = packages[name]
        # Workspace members list dev dependencies under `dependencies`
        # too; `directDependencies` is what ships.
        stack += p.get("directDependencies", p.get("dependencies", []))

    by_text: dict[str, list[str]] = {}
    missing = []
    for name in sorted(seen):
        p = packages[name]
        if p["source"] == "root":
            continue  # Conduit's own packages
        root = roots.get(name)
        lic = next((root / n for n in LICENSE_NAMES if root and (root / n).is_file()), None)
        if lic is None:
            missing.append(name)
            continue
        by_text.setdefault(read(lic), []).append(f"{name} {p['version']}")
    if missing:
        sys.exit(f"no licence file for Dart packages: {', '.join(missing)}")

    out = []
    for text, names in sorted(by_text.items(), key=lambda kv: kv[1][0]):
        out.append(f"### {', '.join(names)}\n\n{fence(text)}\n")
    return out, sum(len(n) for n in by_text.values())


def missing_crates(rust: str, expected_path: str) -> list[str]:
    """The crates cargo builds into the app that the notices leave out.

    `cargo tree` lists each as `name vX.Y.Z`, marked `(*)` when repeated or
    `(proc-macro)`; the workspace's own crates and the vendored gpui-pre are
    path crates (`(/…)`): ours, or listed with the bundled components.
    """
    listed = set(re.findall(r"^- (\S+ \S+)", rust, re.M))
    expected = set()
    for line in Path(expected_path).read_text().splitlines():
        # Escape codes, should colour ever reach the listing.
        line = re.sub(r"\x1b\[[0-9;]*m", "", line)
        line = line.replace(" (*)", "").replace(" (proc-macro)", "").strip()
        if not line or " (" in line:
            continue
        name, version = line.split(" ", 1)
        expected.add(f"{name} {version.removeprefix('v')}")
    return sorted(expected - listed)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rust", required=True)
    ap.add_argument("--expected-crates", required=True)
    ap.add_argument("--pub-deps", required=True)
    ap.add_argument("--package-config", required=True)
    ap.add_argument("--sparkle-license", required=True)
    ap.add_argument("--dart-sdk-license", required=True)
    ap.add_argument("--cargo-registry", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    repo = Path(args.repo)

    rust = read(Path(args.rust))
    rust_crates = len(set(re.findall(r"^- (\S+ \S+)", rust, re.M)))
    missing = missing_crates(rust, args.expected_crates)
    if missing:
        sys.exit(f"crates in the app without a licence in the notices: {', '.join(missing)}")
    dart, dart_count = dart_packages(args)

    doc = [
        "# Third-party notices: Conduit Desktop for macOS",
        "",
        "Conduit Desktop includes the open-source software listed here. Each part keeps",
        "its own licence, reproduced below. This file is generated by",
        "`desktop/packaging/notices/notices.sh`; do not edit it by hand.",
        "",
        "1. Components bundled directly",
        f"2. Rust crates compiled into the app ({rust_crates} crates, from `desktop/Cargo.lock`)",
        f"3. Dart packages compiled into conduitd ({dart_count} packages, from `pubspec.lock`)",
        "",
        "## 1. Components bundled directly",
        "",
        *bundled(repo, args),
        "## 2. Rust crates",
        "",
        "Grouped by licence text; generated with cargo-about.",
        "",
        rust,
        "",
        "## 3. Dart packages (conduitd)",
        "",
        "Grouped by licence text.",
        "",
        *dart,
    ]
    text = "\n".join(doc).rstrip() + "\n"
    text = re.sub(r"\n{3,}", "\n\n", text)
    Path(args.out).write_text(text, encoding="utf-8")
    print(f"{args.out}: {rust_crates} Rust crates, {dart_count} Dart packages, {len(text)} bytes")


if __name__ == "__main__":
    main()
