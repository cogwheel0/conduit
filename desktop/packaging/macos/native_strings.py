#!/usr/bin/env python3
"""The bundle's native string tables, from the app's ARB catalogs.

The ARB files (lib/l10n/app_*.arb and lib/l10n/desktop/desktop_*.arb) stay
the one source of every string; this writes what the parts of the bundle
that macOS or Swift read themselves need, in all 14 languages:

    native_strings.py table L10N_DIR OUT_DIR TABLE KEY=ARB_KEY[%] ...
        <lproj>/TABLE .strings files: the Services menu's titles
        (ServicesMenu.strings) and the Share extension's sheet
        (Localizable.strings), as share/build.sh asks. KEY is the .strings
        key, ARB_KEY the catalog key. A trailing % marks a format string:
        `{name}` placeholders become `%1$@`, `%2$@` ... in the English
        text's order, and a literal % becomes %%. Plurals and selects are
        refused (a .strings table cannot hold them).

    native_strings.py intents RESOURCES L10N_DIR INTENTS_DIR
    native_strings.py intents --verify RESOURCES L10N_DIR INTENTS_DIR
        The App Intents' <lproj>/Localizable.strings and
        AppShortcuts.strings, as intents.sh asks (bundle and verify). The
        strings an intent shows are its Swift literals (crates/app/intents):
        titles, descriptions, parameter names and summaries, read from the
        extracted Metadata.appintents, plus the few looked up at run time
        (`IntentDialog`, the unexpected-failure message). Each must be the
        English text of a `desktopIntent*` key (with `{name}` where Swift
        interpolates `${name}`); a string with none fails the build, so
        Shortcuts never shows an untranslated word. --verify checks a
        bundle: the metadata names every intent, and every locale has every
        string.

    native_strings.py infoplist L10N_DIR INFO_PLIST OUT_DIR
    native_strings.py infoplist --verify L10N_DIR APP
        The privacy prompts' words (Info.plist's *UsageDescription keys) as
        <lproj>/InfoPlist.strings in OUT_DIR, as bundle.sh and run.sh ask.
        Each key has its catalog key in USAGE_KEYS; Info.plist's own text
        (the development language's) must be that key's English text, and a
        usage key with no catalog key fails, so no prompt goes out in
        English only. --verify checks a built app: every language has every
        usage key its Info.plist names.

    native_strings.py widget L10N_DIR OUT_FILE
        The desktop widget's words as a Swift table (WidgetStrings.swift),
        compiled into the widget by widget/build.sh: the widget follows the
        app's language, not the system's, so it carries every locale.

A key a locale lacks takes the English text, as the app does. Reads the
ARBs and the intents' metadata; writes only what it is asked to.
"""

import json
import os
import re
import subprocess
import sys

TOOL = "native_strings"
# ARB locale -> .lproj folder name.
LPROJ = {"zh": "zh-Hans", "zh_Hant": "zh-Hant"}


def fail(message):
    print(f"{TOOL}: {message}", file=sys.stderr)
    sys.exit(1)


# ── The catalogs ──────────────────────────────────────────────────────────


def catalog(path):
    """One ARB file's messages (no @-metadata); {} when there is none."""
    if not os.path.isfile(path):
        return {}
    with open(path, encoding="utf-8") as f:
        try:
            data = json.load(f)
        except ValueError:
            fail(f"not a JSON object: {path}")
    if not isinstance(data, dict):
        fail(f"not a JSON object: {path}")
    return {k: v for k, v in data.items() if not k.startswith("@") and isinstance(v, str)}


def locales(l10n_dir):
    """The app's locales (lib/l10n/app_<locale>.arb), sorted."""
    if not os.path.isdir(l10n_dir):
        fail(f"no folder {l10n_dir}")
    found = sorted(
        name[len("app_") : -len(".arb")]
        for name in os.listdir(l10n_dir)
        if name.startswith("app_") and name.endswith(".arb")
    )
    if "en" not in found:
        fail(f"no app_en.arb in {l10n_dir}")
    return found


def messages(l10n_dir, locale):
    """A locale's messages: the app's, then the desktop's over them."""
    merged = catalog(os.path.join(l10n_dir, f"app_{locale}.arb"))
    merged.update(catalog(os.path.join(l10n_dir, "desktop", f"desktop_{locale}.arb")))
    return merged


def lproj(locale):
    return LPROJ.get(locale, locale.replace("_", "-")) + ".lproj"


def strings_escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def write_strings(folder, table, header, rows):
    """One .strings file: a comment, then `"key" = "value";` per row."""
    lines = [f"/* {header} */"]
    lines += [f'"{strings_escape(k)}" = "{strings_escape(v)}";' for k, v in rows]
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, table), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def select(message, value):
    """An ICU `{name, select, a{...} b{...} other{...}}` message for value."""
    match = re.fullmatch(r"\{\s*\w+\s*,\s*select\s*,(.*)\}", message, re.S)
    if not match:
        fail(f"not a select message: {message}")
    body, cases, i = match.group(1), {}, 0
    while i < len(body):
        head = re.match(r"\s*([\w-]+)\s*\{", body[i:])
        if not head:
            if body[i:].strip():
                fail(f"a select message this tool can't read: {message}")
            break
        start = i + head.end()
        depth, j = 1, start
        while j < len(body) and depth:
            depth += {"{": 1, "}": -1}.get(body[j], 0)
            j += 1
        cases[head.group(1)] = body[start : j - 1]
        i = j
    return cases.get(value, cases.get("other", ""))


# ── table: Services and the Share extension ───────────────────────────────


def placeholders_in_order(message):
    """`{name}` placeholders in order of first use."""
    names = []
    for inside in re.findall(r"\{([^}]*)\}", message):
        if "," in inside:
            fail(f"plural or select in a native string: {message}")
        if inside not in names:
            names.append(inside)
    return names


def printf_format(message, order):
    text = message.replace("%", "%%")
    for index, name in enumerate(order):
        text = text.replace("{" + name + "}", f"%{index + 1}$@")
    if "{" in text:
        fail(f"a placeholder the English text lacks: {message}")
    return text


def table_main(argv):
    if len(argv) < 4:
        fail("usage: native_strings.py table L10N_DIR OUT_DIR TABLE KEY=ARB_KEY[%] ...")
    l10n_dir, out_dir, table, specs = argv[0], argv[1], argv[2], argv[3:]
    entries = []
    for spec in specs:
        if "=" not in spec:
            fail(f"not KEY=ARB_KEY: {spec}")
        key, arb_key = spec.rsplit("=", 1)
        fmt = arb_key.endswith("%")
        entries.append((key, arb_key.rstrip("%") if fmt else arb_key, fmt))
    all_locales = locales(l10n_dir)
    english = messages(l10n_dir, "en")
    for _, arb_key, _ in entries:
        if arb_key not in english:
            fail(f"no English text for {arb_key}")
    for locale in all_locales:
        found = messages(l10n_dir, locale)
        rows = []
        for key, arb_key, fmt in entries:
            value = found.get(arb_key, english[arb_key])
            if fmt:
                value = printf_format(value, placeholders_in_order(english[arb_key]))
            elif "{" in value:
                fail(f"{arb_key} has placeholders: mark it with %")
            rows.append((key, value))
        write_strings(
            os.path.join(out_dir, lproj(locale)),
            table,
            "Generated by desktop/packaging/macos/native_strings.py from lib/l10n.",
            rows,
        )
    print(f"{TOOL}: {table} in {len(all_locales)} languages")


# ── intents: Shortcuts, Siri and Spotlight ────────────────────────────────

INTENT_PREFIX = "desktopIntent"
# What the metadata must name: the intents, the chat entity and its query.
ACTIONS = {
    "AskConduitIntent",
    "NewChatIntent",
    "OpenChatIntent",
    "StartVoiceCallIntent",
    "QuickAskIntent",
    "SendTextIntent",
    "SendLinkIntent",
    "SendImageIntent",
}
ENTITIES = {"ChatEntity"}
QUERIES = {"ChatEntityQuery"}

SWIFT_STRING = r'"((?:[^"\\]|\\.)*)"'
RUNTIME_LITERALS = [
    re.compile(r"IntentDialog\(" + SWIFT_STRING + r"\)"),
    re.compile(r"case \.unexpected: " + SWIFT_STRING),
]


def intent_catalogs(l10n_dir):
    """locale -> the desktopIntent* messages, for every desktop ARB."""
    desktop = os.path.join(l10n_dir, "desktop")
    out = {}
    for name in sorted(os.listdir(desktop)):
        match = re.fullmatch(r"desktop_(.+)\.arb", name)
        if match:
            out[match.group(1)] = {
                k: v for k, v in catalog(os.path.join(desktop, name)).items()
                if k.startswith(INTENT_PREFIX)
            }
    if "en" not in out:
        fail(f"no desktop_en.arb in {desktop}")
    return out


def app_intents_format(message):
    """ARB `{name}` placeholders -> App Intents' `${name}`."""
    return re.sub(r"\{(\w+)\}", r"${\1}", message)


def intents_metadata(resources):
    path = os.path.join(resources, "Metadata.appintents", "extract.actionsdata")
    if not os.path.isfile(path):
        fail(f"no {path}")
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def intent_strings_needed(data, intents_dir):
    """(Localizable keys, AppShortcuts phrase keys) the intents show."""
    keys, phrases = set(), set()

    def walk(node, in_phrases):
        if isinstance(node, dict):
            if isinstance(node.get("key"), str) and "alternatives" in node:
                (phrases if in_phrases else keys).add(node["key"])
            for name, value in node.items():
                walk(value, in_phrases or name == "phraseTemplates")
        elif isinstance(node, list):
            for value in node:
                walk(value, in_phrases)
        elif isinstance(node, str) and "${" in node and not in_phrases:
            # Parameter summaries: "Ask Conduit ${prompt}".
            keys.add(node)

    walk(data, False)
    for name in sorted(os.listdir(intents_dir)):
        if not name.endswith(".swift"):
            continue
        with open(os.path.join(intents_dir, name), encoding="utf-8") as f:
            text = f.read()
        for pattern in RUNTIME_LITERALS:
            for match in pattern.finditer(text):
                keys.add(match.group(1).encode().decode("unicode_escape"))
    return keys, phrases


def dollar_placeholders(text):
    return sorted(re.findall(r"\$\{(\w+)\}", text))


def intent_tables(catalogs, keys, phrases):
    """locale -> {table name -> {English -> translation}}."""
    english = {app_intents_format(m): k for k, m in catalogs["en"].items()}
    missing = sorted(k for k in keys | phrases if k not in english)
    if missing:
        fail(
            "no desktop ARB key (desktopIntent*) has the English text of:\n  "
            + "\n  ".join(missing)
        )
    out = {}
    for locale, found in catalogs.items():
        out[locale] = {}
        for table, wanted in (("Localizable", keys), ("AppShortcuts", phrases)):
            rows = {}
            for source in sorted(wanted):
                key = english[source]
                if key not in found:
                    fail(f"{locale}: no {key}")
                translated = app_intents_format(found[key])
                if dollar_placeholders(translated) != dollar_placeholders(source):
                    fail(
                        f"{locale}: {key} has {dollar_placeholders(translated)}, "
                        f"English {dollar_placeholders(source)}"
                    )
                if table == "AppShortcuts" and translated.count("${applicationName}") != 1:
                    fail(f"{locale}: {key} must name the app exactly once")
                rows[source] = translated
            out[locale][table] = rows
    return out


def read_strings(path):
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", path], capture_output=True, text=True
    )
    if result.returncode != 0:
        fail(f"{path} does not parse: {result.stderr.strip()}")
    return json.loads(result.stdout)


def intents_main(argv):
    verifying = argv[:1] == ["--verify"]
    if verifying:
        argv = argv[1:]
    if len(argv) != 3:
        fail("usage: native_strings.py intents [--verify] RESOURCES L10N_DIR INTENTS_DIR")
    resources, l10n_dir, intents_dir = argv
    data = intents_metadata(resources)
    keys, phrases = intent_strings_needed(data, intents_dir)
    out = intent_tables(intent_catalogs(l10n_dir), keys, phrases)
    if not verifying:
        for locale, by_table in out.items():
            for table, rows in by_table.items():
                write_strings(
                    os.path.join(resources, lproj(locale)),
                    f"{table}.strings",
                    "Conduit's App Intents, from lib/l10n/desktop "
                    "(packaging/macos/native_strings.py).",
                    rows.items(),
                )
        count = sum(len(rows) for rows in next(iter(out.values())).values())
        print(f"{TOOL}: {count} intent strings in {len(out)} locales")
        return
    problems = []
    for kind, wanted in (("actions", ACTIONS), ("entities", ENTITIES), ("queries", QUERIES)):
        have = set(data.get(kind, {}).keys())
        if not wanted <= have:
            problems.append(f"metadata {kind}: missing {sorted(wanted - have)}")
    shortcuts = {s.get("actionIdentifier") for s in data.get("autoShortcuts", [])}
    if shortcuts != ACTIONS:
        problems.append(f"App Shortcuts for {sorted(shortcuts)}, want {sorted(ACTIONS)}")
    if not data.get("autoShortcutProviderMangledName"):
        problems.append("no App Shortcuts provider")
    for locale, by_table in out.items():
        for table, rows in by_table.items():
            path = os.path.join(resources, lproj(locale), f"{table}.strings")
            if not os.path.isfile(path):
                problems.append(f"no {path}")
            elif read_strings(path) != rows:
                problems.append(f"{path} is not what lib/l10n/desktop says")
    if problems:
        fail("\n  ".join(["the bundle's App Intents are incomplete:"] + problems))
    print(
        f"{TOOL}: ok: {len(ACTIONS)} actions, {len(shortcuts)} App Shortcuts, "
        f"strings in {len(out)} locales"
    )


# ── widget: the desktop widget's Swift table ──────────────────────────────

# WidgetL10n.Key's raw values -> ARB keys.
WIDGET_KEYS = [
    ("ask", "desktopWidgetAsk"),
    ("newChat", "desktopWidgetNewChat"),
    ("voiceCall", "desktopWidgetVoiceCall"),
    ("clipboard", "desktopWidgetClipboard"),
    ("recentChats", "desktopWidgetRecentChats"),
    ("noChats", "desktopWidgetNoChats"),
    ("signedOut", "desktopWidgetSignedOut"),
    ("openConduit", "desktopWidgetOpenConduit"),
    ("galleryDescription", "desktopWidgetDescription"),
    ("yesterday", "yesterday"),
]
# weekday1 ... weekday7, Monday first, as the sidebar dates chats.
WEEKDAY_KEY = "desktopWeekdayLong"


def widget_main(argv):
    if len(argv) != 2:
        fail("usage: native_strings.py widget L10N_DIR OUT_FILE")
    l10n_dir, out_file = argv
    found_locales = locales(l10n_dir)
    # English first, as the app lists its languages.
    ordered = ["en"] + [l for l in found_locales if l != "en"]
    english = messages(l10n_dir, "en")
    for _, arb_key in WIDGET_KEYS + [(None, WEEKDAY_KEY)]:
        if arb_key not in english:
            fail(f"no English text for {arb_key}")

    def swift(text):
        return text.replace("\\", "\\\\").replace('"', '\\"')

    lines = [
        "// Generated from lib/l10n by desktop/packaging/macos/native_strings.py",
        "// (widget/build.sh); do not edit.",
        "// The keys are WidgetL10n.Key's, plus weekday1…weekday7 (Monday first).",
        "",
        "enum WidgetStrings {",
        "    static let table: [String: [String: String]] = [",
    ]
    for locale in ordered:
        found = messages(l10n_dir, locale)
        lines.append(f'        "{locale}": [')
        for key, arb_key in WIDGET_KEYS:
            value = found.get(arb_key, english[arb_key])
            if "{" in value:
                fail(f"{locale}: {arb_key} has placeholders")
            lines.append(f'            "{key}": "{swift(value)}",')
        weekdays = found.get(WEEKDAY_KEY, english[WEEKDAY_KEY])
        for day in range(1, 8):
            lines.append(f'            "weekday{day}": "{swift(select(weekdays, str(day)))}",')
        lines.append("        ],")
    lines += ["    ]", "}"]
    os.makedirs(os.path.dirname(os.path.abspath(out_file)), exist_ok=True)
    with open(out_file, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{TOOL}: the widget's words in {len(ordered)} languages")


# ── infoplist: the privacy prompts ───────────────────────────────────────

# Info.plist usage key -> its catalog key.
USAGE_KEYS = {
    "NSMicrophoneUsageDescription": "desktopUsageMicrophone",
    "NSSpeechRecognitionUsageDescription": "desktopUsageSpeechRecognition",
    "NSLocalNetworkUsageDescription": "desktopUsageLocalNetwork",
    "NSLocationUsageDescription": "desktopUsageLocation",
    "NSLocationWhenInUseUsageDescription": "desktopUsageLocation",
}


def usage_keys_in(info_plist):
    """Info.plist's *UsageDescription keys and their (English) texts."""
    try:
        raw = subprocess.check_output(
            ["plutil", "-convert", "json", "-o", "-", info_plist], stderr=subprocess.DEVNULL
        )
    except (OSError, subprocess.CalledProcessError):
        fail(f"cannot read {info_plist}")
    data = json.loads(raw)
    return {k: v for k, v in data.items() if k.endswith("UsageDescription")}


def infoplist_main(argv):
    if argv[:1] == ["--verify"]:
        return infoplist_verify(argv[1:])
    if len(argv) != 3:
        fail("usage: native_strings.py infoplist L10N_DIR INFO_PLIST OUT_DIR")
    l10n_dir, info_plist, out_dir = argv
    usage = usage_keys_in(info_plist)
    english = messages(l10n_dir, "en")
    for key, text in sorted(usage.items()):
        arb_key = USAGE_KEYS.get(key)
        if arb_key is None:
            fail(f"{key} has no catalog key in USAGE_KEYS")
        if english.get(arb_key) != text:
            fail(f"Info.plist's {key} is not {arb_key}'s English text")
    all_locales = locales(l10n_dir)
    for locale in all_locales:
        found = messages(l10n_dir, locale)
        rows = []
        for key in sorted(usage):
            value = found.get(USAGE_KEYS[key], english[USAGE_KEYS[key]])
            if "{" in value:
                fail(f"{locale}: {USAGE_KEYS[key]} has placeholders")
            rows.append((key, value))
        write_strings(
            os.path.join(out_dir, lproj(locale)),
            "InfoPlist.strings",
            "Generated by desktop/packaging/macos/native_strings.py from lib/l10n.",
            rows,
        )
    print(f"{TOOL}: InfoPlist.strings ({len(usage)} usage keys) in {len(all_locales)} languages")


def infoplist_verify(argv):
    if len(argv) != 2:
        fail("usage: native_strings.py infoplist --verify L10N_DIR APP")
    l10n_dir, app = argv
    usage = usage_keys_in(os.path.join(app, "Contents", "Info.plist"))
    if not usage:
        fail("Info.plist names no usage keys")
    resources = os.path.join(app, "Contents", "Resources")
    missing = []
    all_locales = locales(l10n_dir)
    for locale in all_locales:
        path = os.path.join(resources, lproj(locale), "InfoPlist.strings")
        found = read_strings(path) if os.path.isfile(path) else {}
        missing += [f"{lproj(locale)}: {k}" for k in sorted(usage) if not found.get(k)]
        if locale == "en":
            missing += [
                f"en.lproj: {k} differs from Info.plist"
                for k in sorted(usage)
                if found.get(k) and found[k] != usage[k]
            ]
    if missing:
        fail("InfoPlist.strings incomplete: " + "; ".join(missing))
    print(f"{TOOL}: ok: InfoPlist.strings, {len(usage)} usage keys in {len(all_locales)} languages")


def main(argv):
    modes = {
        "table": table_main,
        "intents": intents_main,
        "widget": widget_main,
        "infoplist": infoplist_main,
    }
    if not argv or argv[0] not in modes:
        fail("usage: native_strings.py table|intents|widget|infoplist ... (see the file's docstring)")
    modes[argv[0]](argv[1:])


if __name__ == "__main__":
    main(sys.argv[1:])
