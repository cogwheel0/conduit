use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use super::*;

/// Accessor names the app's sources call (`l10n.<name>(` or
/// `l10n().<name>(`), with the key each one reads.
fn used_keys() -> Vec<(&'static str, &'static str)> {
    fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                walk(&path, out);
            } else if path.extension().is_some_and(|e| e == "rs") {
                out.push(path);
            }
        }
    }
    let mut files = vec![];
    walk(
        &PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src"),
        &mut files,
    );
    let mut used = BTreeSet::new();
    for file in files {
        let text = std::fs::read_to_string(&file).unwrap();
        for (i, name) in ACCESSORS.iter().enumerate() {
            let a = format!("l10n.{name}(");
            let b = format!("l10n().{name}(");
            // The components' strings, through `l: &L10n`.
            let c = format!("(l.{name}(");
            if text.contains(&a) || text.contains(&b) || text.contains(&c) {
                used.insert((KEYS[i], *name));
            }
        }
    }
    used.into_iter().collect()
}

#[test]
fn the_app_uses_localized_strings() {
    let used = used_keys();
    assert!(used.len() > 40, "found only {} keys: {used:?}", used.len());
}

#[test]
fn every_locale_has_every_key_the_app_uses() {
    let mut missing = vec![];
    for (key, _) in used_keys() {
        let index = key_index(key).unwrap();
        for locale in LOCALES {
            if !L10n::new(locale).has(index) {
                missing.push(format!("{locale}: {key}"));
            }
        }
    }
    assert!(
        missing.is_empty(),
        "missing translations:\n{}",
        missing.join("\n")
    );
}

#[test]
fn every_locale_has_every_desktop_key() {
    let mut missing = vec![];
    for (index, key) in KEYS.iter().enumerate() {
        if !IS_DESKTOP_KEY[index] {
            continue;
        }
        for locale in LOCALES {
            if !L10n::new(locale).has(index) {
                missing.push(format!("{locale}: {key}"));
            }
        }
    }
    assert!(
        missing.is_empty(),
        "missing desktop translations:\n{}",
        missing.join("\n")
    );
}

#[test]
fn translations_keep_the_placeholders_the_app_passes() {
    let mut broken = vec![];
    for (key, _) in used_keys() {
        let index = key_index(key).unwrap();
        let expected: BTreeSet<String> =
            PLACEHOLDERS[index].iter().map(|s| s.to_string()).collect();
        for locale in LOCALES {
            let l = L10n::new(locale);
            let got: BTreeSet<String> = icu::placeholders(&icu::parse(l.message(index)))
                .into_iter()
                .collect();
            if !got.is_subset(&expected) {
                broken.push(format!(
                    "{locale}: {key} uses {got:?}, English has {expected:?}"
                ));
            }
        }
    }
    assert!(broken.is_empty(), "{}", broken.join("\n"));
}

#[test]
fn fourteen_locales_with_english_first() {
    assert_eq!(LOCALES.len(), 14);
    assert_eq!(LOCALES[0], "en");
    assert!(LOCALES.contains(&"zh_Hant"));
    assert!(KEYS.windows(2).all(|w| w[0] < w[1]), "KEYS is sorted");
}

#[test]
fn placeholders_and_fallback() {
    let en = L10n::new("en");
    assert_eq!(
        en.desktop_shortcut_conflict("⌘K", "Search"),
        "⌘K is already used by Search."
    );
    // Arguments go in the order the ARB declares its placeholders.
    assert_eq!(en.desktop_position_of("1", "3"), "1 of 3");
    // Decimals keep their digits.
    assert_eq!(
        en.prompt_variable_number_min(0.001),
        "Minimum value is 0.001"
    );
    assert_eq!(en.tts_speed_value(1.234), "1.234×");
    assert_eq!(en.tts_speed_value(0.1 + 0.2), "0.3×");
    assert_eq!(en.tts_speed_value(2.), "2×");
    // Unknown locales fall back to English.
    assert_eq!(L10n::new("xx").locale(), "en");
}

#[test]
fn plurals_follow_cldr_and_exact_matches() {
    let en = L10n::new("en");
    assert_eq!(en.quick_actions_selected_count(0), "No actions selected");
    assert_eq!(en.quick_actions_selected_count(1), "1 action selected");
    assert_eq!(en.quick_actions_selected_count(7), "7 actions selected");

    // Russian: `#` is the number, and few/many differ.
    let ru = L10n::new("ru");
    let one = ru.hermes_tool_count(1);
    let few = ru.hermes_tool_count(3);
    let many = ru.hermes_tool_count(5);
    assert!(one.starts_with("1 "), "{one}");
    assert!(few.starts_with("3 "), "{few}");
    assert!(many.starts_with("5 "), "{many}");
    assert_ne!(one, few.replacen('3', "1", 1));
    assert_ne!(few.replacen('3', "5", 1), many);
}

#[test]
fn icu_rendering() {
    let en = L10n::new("en");
    let mut out = String::new();
    en.render(
        &icu::parse("{n, plural, =0{none} one{# file} other{# files}} in {where}"),
        &[("n", Arg::Int(2)), ("where", Arg::Str("Docs"))],
        None,
        &mut out,
    );
    assert_eq!(out, "2 files in Docs");
    let mut out = String::new();
    en.render(
        &icu::parse("{kind, select, chat{Chat} other{Item}}: {size}"),
        &[("kind", Arg::Str("chat")), ("size", Arg::Num(14.5))],
        None,
        &mut out,
    );
    assert_eq!(out, "Chat: 14.5");
}
