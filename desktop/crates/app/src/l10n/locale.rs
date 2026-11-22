//! Picking a catalog locale: the system's preferred languages (or the
//! Settings override) mapped onto the 14 locales the ARBs carry.

use super::LOCALES;

/// The user's preferred languages, most preferred first (BCP-47, e.g.
/// `de-DE`, `zh-Hant-TW`): the Mac's Language & Region list, Windows'
/// display languages, or Linux's `LANGUAGE` and locale ([`posix_languages`]).
pub fn system_languages() -> Vec<String> {
    #[cfg(target_os = "macos")]
    {
        let langs = objc2_foundation::NSLocale::preferredLanguages();
        let out: Vec<String> = langs.iter().map(|s| s.to_string()).collect();
        if !out.is_empty() {
            return out;
        }
    }
    #[cfg(target_os = "windows")]
    {
        let out = windows::preferred_ui_languages();
        if !out.is_empty() {
            return out;
        }
    }
    if cfg!(target_os = "macos") {
        return std::env::var("LANG")
            .ok()
            .map(|l| vec![l.split('.').next().unwrap_or("en").replace('_', "-")])
            .unwrap_or_default();
    }
    posix_languages(|name| std::env::var(name).ok())
}

/// The locale dates are written for (BCP-47), off the Mac: Windows' user
/// locale, else `LC_ALL`, `LC_TIME` or `LANG`. `None` for the C locale.
pub fn system_format_locale() -> Option<String> {
    #[cfg(target_os = "windows")]
    if let Some(tag) = windows::user_locale() {
        return Some(tag);
    }
    posix_category(&|name| std::env::var(name).ok(), "LC_TIME")
}

/// The languages a POSIX environment asks for, as gettext reads them:
/// `LANGUAGE` (a `:` list) first, unless the locale is C, then the locale
/// of `LC_ALL`, else `LC_MESSAGES`, else `LANG`.
pub fn posix_languages(var: impl Fn(&str) -> Option<String>) -> Vec<String> {
    let locale = posix_category(&var, "LC_MESSAGES");
    let mut out: Vec<String> = vec![];
    if locale.is_some() {
        out.extend(
            var("LANGUAGE")
                .unwrap_or_default()
                .split(':')
                .filter_map(posix_to_bcp47),
        );
    }
    out.extend(locale);
    out.dedup();
    out
}

/// The locale a POSIX category is in (`LC_ALL`, else the category, else
/// `LANG`), as BCP-47; `None` when unset or C.
fn posix_category(var: &dyn Fn(&str) -> Option<String>, category: &str) -> Option<String> {
    ["LC_ALL", category, "LANG"]
        .into_iter()
        .find_map(|name| var(name).filter(|v| !v.is_empty()))
        .and_then(|v| posix_to_bcp47(&v))
}

/// A POSIX locale name as BCP-47: `de_DE.UTF-8` is `de-DE`, `sr_RS@latin`
/// `sr-Latn-RS`; `C` and `POSIX` are none.
pub fn posix_to_bcp47(name: &str) -> Option<String> {
    let (rest, modifier) = match name.split_once('@') {
        Some((rest, m)) => (rest, Some(m)),
        None => (name, None),
    };
    let base = rest.split('.').next().unwrap_or("");
    if base.is_empty() || base == "C" || base == "POSIX" {
        return None;
    }
    let mut parts = base.split(['_', '-']);
    let language = parts.next()?.to_ascii_lowercase();
    if !(2..=3).contains(&language.len()) || !language.chars().all(|c| c.is_ascii_alphabetic()) {
        return None;
    }
    let mut tag = language;
    match modifier {
        Some("latin") => tag.push_str("-Latn"),
        Some("cyrillic") => tag.push_str("-Cyrl"),
        _ => {}
    }
    if let Some(region) = parts.next().filter(|r| !r.is_empty()) {
        tag.push('-');
        tag.push_str(&region.to_ascii_uppercase());
    }
    Some(tag)
}

/// The strings of a Windows multi-string (each ends with a NUL, the list
/// with another).
pub fn multi_sz(buffer: &[u16]) -> Vec<String> {
    buffer
        .split(|c| *c == 0)
        .take_while(|s| !s.is_empty())
        .map(String::from_utf16_lossy)
        .collect()
}

#[cfg(target_os = "windows")]
mod windows {
    use ::windows::Win32::Globalization::{
        GetUserDefaultLocaleName, GetUserPreferredUILanguages, MUI_LANGUAGE_NAME,
    };
    use ::windows::core::PWSTR;

    /// Windows' display languages, most preferred first.
    pub fn preferred_ui_languages() -> Vec<String> {
        let mut count = 0u32;
        let mut len = 0u32;
        // SAFETY: a null buffer asks for the length only.
        if unsafe { GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &mut count, None, &mut len) }
            .is_err()
        {
            return vec![];
        }
        let mut buffer = vec![0u16; len as usize];
        // SAFETY: the buffer holds the `len` characters asked for.
        if unsafe {
            GetUserPreferredUILanguages(
                MUI_LANGUAGE_NAME,
                &mut count,
                Some(PWSTR(buffer.as_mut_ptr())),
                &mut len,
            )
        }
        .is_err()
        {
            return vec![];
        }
        super::multi_sz(&buffer)
    }

    /// The user's locale for formats (Region › Regional format).
    pub fn user_locale() -> Option<String> {
        let mut buffer = [0u16; 85];
        // SAFETY: LOCALE_NAME_MAX_LENGTH (85) characters fit.
        let len = unsafe { GetUserDefaultLocaleName(&mut buffer) };
        (len > 1).then(|| String::from_utf16_lossy(&buffer[..len as usize - 1]))
    }
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

    /// gettext's order: `LANGUAGE`'s list, then the messages locale
    /// (`LC_ALL`, else `LC_MESSAGES`, else `LANG`); a C locale turns
    /// `LANGUAGE` off.
    #[test]
    fn linux_languages_come_as_gettext_reads_them() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |name: &str| {
                pairs
                    .iter()
                    .find(|(k, _)| *k == name)
                    .map(|(_, v)| v.to_string())
            }
        };
        assert_eq!(
            posix_languages(env(&[("LANGUAGE", "pt_BR:de"), ("LANG", "fr_FR.UTF-8")])),
            vec!["pt-BR", "de", "fr-FR"]
        );
        assert_eq!(
            resolve(&posix_languages(env(&[
                ("LANGUAGE", "pt_BR:de"),
                ("LANG", "fr_FR.UTF-8")
            ]))),
            "de"
        );
        assert_eq!(
            posix_languages(env(&[
                ("LC_MESSAGES", "zh_TW.UTF-8"),
                ("LANG", "en_US.UTF-8")
            ])),
            vec!["zh-TW"]
        );
        assert_eq!(
            posix_languages(env(&[("LC_ALL", "C"), ("LANGUAGE", "de")])),
            Vec::<String>::new()
        );
        assert_eq!(
            posix_languages(env(&[("LC_ALL", "C.UTF-8"), ("LANG", "de_DE")])),
            Vec::<String>::new()
        );
        assert_eq!(posix_to_bcp47("sr_RS@latin").as_deref(), Some("sr-Latn-RS"));
        assert_eq!(posix_to_bcp47("POSIX"), None);
        assert_eq!(posix_to_bcp47("de").as_deref(), Some("de"));
    }

    #[test]
    fn windows_display_languages_read_from_a_multi_string() {
        let wide: Vec<u16> = "de-DE\0en-US\0\0".encode_utf16().collect();
        assert_eq!(multi_sz(&wide), vec!["de-DE", "en-US"]);
        assert!(multi_sz(&[0, 0]).is_empty());
        assert_eq!(resolve(&multi_sz(&wide)), "de");
    }

    #[test]
    fn every_catalog_has_a_native_name() {
        for l in LOCALES {
            assert!(l == &"en" || native_name(l) != "English", "{l}");
        }
        assert_eq!(bcp47("zh_Hant"), "zh-Hant");
    }
}
