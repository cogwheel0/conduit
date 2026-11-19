//! Picking a catalog locale: the system's preferred languages (or the
//! Settings override) mapped onto the 14 locales the ARBs carry.

use super::LOCALES;

/// The user's preferred languages, most preferred first (BCP-47, e.g.
/// `de-DE`, `zh-Hant-TW`).
pub fn system_languages() -> Vec<String> {
    #[cfg(target_os = "macos")]
    {
        let langs = objc2_foundation::NSLocale::preferredLanguages();
        let out: Vec<String> = langs.iter().map(|s| s.to_string()).collect();
        if !out.is_empty() {
            return out;
        }
    }
    std::env::var("LANG")
        .ok()
        .map(|l| vec![l.split('.').next().unwrap_or("en").replace('_', "-")])
        .unwrap_or_default()
}

/// The catalog locale for one BCP-47 tag, if there is one.
pub fn match_tag(tag: &str) -> Option<&'static str> {
    let lower = tag.replace('_', "-").to_ascii_lowercase();
    let mut parts = lower.split('-');
    let language = parts.next()?;
    let rest: Vec<&str> = parts.collect();
    if language == "zh" {
        let traditional = rest.contains(&"hant")
            || (!rest.contains(&"hans") && rest.iter().any(|p| matches!(*p, "tw" | "hk" | "mo")));
        return Some(if traditional { "zh_Hant" } else { "zh" });
    }
    LOCALES.iter().copied().find(|l| *l == language)
}

/// The first supported locale among `preferred`, else English.
pub fn resolve(preferred: &[String]) -> &'static str {
    preferred
        .iter()
        .find_map(|tag| match_tag(tag))
        .unwrap_or("en")
}

/// The catalog locale as a BCP-47 tag, for the handshake (`zh_Hant` →
/// `zh-Hant`).
pub fn bcp47(locale: &str) -> String {
    locale.replace('_', "-")
}

/// A language's name in that language, for the language picker.
pub fn native_name(locale: &str) -> &'static str {
    match locale {
        "en" => "English",
        "cs" => "Čeština",
        "de" => "Deutsch",
        "es" => "Español",
        "fr" => "Français",
        "it" => "Italiano",
        "ja" => "日本語",
        "ko" => "한국어",
        "nl" => "Nederlands",
        "pl" => "Polski",
        "ru" => "Русский",
        "sk" => "Slovenčina",
        "zh" => "简体中文",
        "zh_Hant" => "繁體中文",
        _ => "English",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_system_tags_onto_catalogs() {
        assert_eq!(match_tag("de-DE"), Some("de"));
        assert_eq!(match_tag("en-GB"), Some("en"));
        assert_eq!(match_tag("zh-Hans-CN"), Some("zh"));
        assert_eq!(match_tag("zh-Hant-TW"), Some("zh_Hant"));
        assert_eq!(match_tag("zh-TW"), Some("zh_Hant"));
        assert_eq!(match_tag("zh-HK"), Some("zh_Hant"));
        assert_eq!(match_tag("zh_CN"), Some("zh"));
        assert_eq!(match_tag("pt-BR"), None);
    }

    #[test]
    fn the_first_supported_language_wins() {
        let prefs = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(resolve(&prefs(&["pt-BR", "fr-CA", "de"])), "fr");
        assert_eq!(resolve(&prefs(&["pt-BR"])), "en");
        assert_eq!(resolve(&[]), "en");
    }

    #[test]
    fn every_catalog_has_a_native_name() {
        for l in LOCALES {
            assert!(l == &"en" || native_name(l) != "English", "{l}");
        }
        assert_eq!(bcp47("zh_Hant"), "zh-Hant");
    }
}
