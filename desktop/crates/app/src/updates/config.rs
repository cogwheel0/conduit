//! What a Windows or Linux build's updater is made from: the feed and the
//! EdDSA public key its packaging script passes at build time
//! (`CONDUIT_UPDATE_FEED_URL`, `CONDUIT_UPDATE_PUBLIC_ED_KEY`;
//! packaging/windows/build.ps1, packaging/linux/package.sh), as the Mac's
//! bundle.sh writes `SUFeedURL` and `SUPublicEDKey`. A build without both
//! has no updater, and About says updates come with the installed app.

use base64::Engine as _;

/// The feed this build reads, when its packaging named one.
#[cfg(not(target_os = "macos"))]
pub const FEED_URL: Option<&str> = option_env!("CONDUIT_UPDATE_FEED_URL");
/// The EdDSA public key this build trusts (base64 of 32 bytes, as Sparkle's
/// `generate_keys -p` prints it).
#[cfg(not(target_os = "macos"))]
pub const PUBLIC_ED_KEY: Option<&str> = option_env!("CONDUIT_UPDATE_PUBLIC_ED_KEY");

/// Daily, as the Mac's `SUScheduledCheckInterval`.
pub const CHECK_INTERVAL_SECS: i64 = 86_400;

/// Why there is no updater (logged once at launch).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Unavailable {
    /// The build names no feed or no key (development builds).
    NotConfigured(&'static str),
    /// What the build names isn't usable: the key isn't an EdDSA public
    /// key, or the feed isn't an http(s) URL.
    Invalid(&'static str),
    /// The app's version makes no build number (lib.sh build_number).
    Version(String),
    /// WinSparkle.dll isn't beside the app, or wouldn't load.
    #[cfg(windows)]
    LoadFailed(String),
}

/// An updater's settings, checked.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Config {
    pub feed_url: String,
    /// The key as the build carries it (base64 of 32 bytes).
    pub public_key: String,
    /// The version this app is (`1.2.0`).
    pub version: String,
    /// Its build number, which the feeds order releases by.
    pub build: u64,
}

impl Config {
    /// The settings `feed_url`, `public_key` and `version` make, or why
    /// they make none.
    pub fn from_build(
        feed_url: Option<&str>,
        public_key: Option<&str>,
        version: &str,
    ) -> Result<Self, Unavailable> {
        let feed_url = feed_url
            .map(str::trim)
            .filter(|u| !u.is_empty())
            .ok_or(Unavailable::NotConfigured("CONDUIT_UPDATE_FEED_URL"))?;
        let public_key = public_key
            .map(str::trim)
            .filter(|k| !k.is_empty())
            .ok_or(Unavailable::NotConfigured("CONDUIT_UPDATE_PUBLIC_ED_KEY"))?;
        if parse_public_key(public_key).is_none() {
            return Err(Unavailable::Invalid("CONDUIT_UPDATE_PUBLIC_ED_KEY"));
        }
        let scheme = feed_url.split_once("://").map(|(s, _)| s);
        if !matches!(scheme, Some("https" | "http")) {
            return Err(Unavailable::Invalid("CONDUIT_UPDATE_FEED_URL"));
        }
        let build = build_number(version).ok_or_else(|| Unavailable::Version(version.into()))?;
        Ok(Self {
            feed_url: feed_url.into(),
            public_key: public_key.into(),
            version: version.into(),
            build,
        })
    }
}

/// The 32 bytes of an EdDSA public key in base64; `None` for anything else.
pub fn parse_public_key(text: &str) -> Option<[u8; 32]> {
    base64::engine::general_purpose::STANDARD
        .decode(text.trim())
        .ok()?
        .try_into()
        .ok()
}

/// One integer that orders every version, as packaging/macos/lib.sh's
/// `build_number` makes it: `X*1000000 + Y*10000 + Z*100 + 99` for a
/// release (1.2.0 is 1020099), with N in place of 99 for `X.Y.Z-beta.N`, so
/// a beta sorts before its release. `None` for anything else (leading
/// zeros, a minor or patch above 99, a beta outside 1–98).
pub fn build_number(version: &str) -> Option<u64> {
    let (core, beta) = match version.split_once("-beta.") {
        Some((core, beta)) => (core, Some(number(beta)?)),
        None => (version, None),
    };
    let mut parts = core.split('.');
    let (major, minor, patch) = (
        number(parts.next()?)?,
        number(parts.next()?)?,
        number(parts.next()?)?,
    );
    if parts.next().is_some() || minor > 99 || patch > 99 {
        return None;
    }
    let last = match beta {
        Some(n) if (1..=98).contains(&n) => n,
        Some(_) => return None,
        None => 99,
    };
    major
        .checked_mul(1_000_000)?
        .checked_add(minor * 10_000 + patch * 100 + last)
}

/// A version part: digits, no leading zero.
fn number(part: &str) -> Option<u64> {
    let digits = !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit());
    if !digits || (part.len() > 1 && part.starts_with('0')) {
        return None;
    }
    part.parse().ok()
}

/// What WinSparkle is told before it starts (updates::winsparkle).
#[cfg(any(windows, test))]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WinSparkleSettings {
    pub appcast_url: String,
    pub eddsa_public_key: String,
    /// The registry folder WinSparkle names from these (`HKCU\Software\
    /// <company>\<app>`) is moved by `registry_path`; the app name is also
    /// what its windows call the app.
    pub company_name: &'static str,
    pub app_name: &'static str,
    /// Shown to the user.
    pub app_version: String,
    /// What WinSparkle compares with each item's `sparkle:version`.
    pub build_version: String,
    /// Under HKCU: when it last checked, a skipped version, and "check
    /// automatically", which the app sets from its own switch each launch.
    pub registry_path: &'static str,
    pub check_interval_secs: i32,
    /// The language of WinSparkle's windows: the app's.
    pub lang: String,
}

#[cfg(any(windows, test))]
impl WinSparkleSettings {
    pub fn new(config: &Config, locale: &str) -> Self {
        Self {
            appcast_url: config.feed_url.clone(),
            eddsa_public_key: config.public_key.clone(),
            company_name: "Conduit",
            app_name: "Conduit",
            app_version: config.version.clone(),
            build_version: config.build.to_string(),
            registry_path: r"Software\Conduit\Updates",
            check_interval_secs: CHECK_INTERVAL_SECS as i32,
            lang: winsparkle_lang(locale),
        }
    }
}

/// The app's catalog locale (`de`, `zh_Hant`) as WinSparkle names its
/// translations (an ISO 639 code, with the region its Chinese ones need).
#[cfg(any(windows, test))]
fn winsparkle_lang(locale: &str) -> String {
    match locale {
        "zh_Hant" => "zh-TW".into(),
        "zh" | "zh_Hans" => "zh-CN".into(),
        other => other.replace('_', "-"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A made-up key: 32 bytes, base64.
    const KEY: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";
    const FEED: &str = "https://example.org/releases/download/feeds/appcast-windows.xml";

    #[test]
    fn build_numbers_order_versions_as_the_mac_scripts_do() {
        assert_eq!(build_number("1.2.0"), Some(1_020_099));
        assert_eq!(build_number("0.0.0"), Some(99));
        assert_eq!(build_number("1.2.0-beta.3"), Some(1_020_003));
        assert_eq!(build_number("10.99.99"), Some(10_999_999));
        // A beta sorts before its release, a patch after it, and a minor
        // after every patch of the one before.
        let order = [
            "1.2.0-beta.1",
            "1.2.0-beta.98",
            "1.2.0",
            "1.2.1",
            "1.10.0",
            "2.0.0",
        ];
        let builds: Vec<_> = order.iter().map(|v| build_number(v).unwrap()).collect();
        assert!(builds.windows(2).all(|w| w[0] < w[1]), "{builds:?}");
    }

    #[test]
    fn build_numbers_refuse_what_the_mac_scripts_refuse() {
        for bad in [
            "",
            "1.2",
            "1.2.3.4",
            "01.2.3",
            "1.02.3",
            "1.2.03",
            "1.100.0",
            "1.2.100",
            "1.2.0-beta.0",
            "1.2.0-beta.99",
            "1.2.0-beta.",
            "1.2.0-rc.1",
            "v1.2.0",
            "1.2.0 ",
            "1.-2.0",
            "+1.2.0",
        ] {
            assert_eq!(build_number(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn a_build_with_a_feed_and_a_key_has_an_updater() {
        let config = Config::from_build(Some(FEED), Some(KEY), "1.3.0").unwrap();
        assert_eq!(config.feed_url, FEED);
        assert_eq!(config.public_key, KEY);
        assert_eq!(parse_public_key(KEY).map(|k| k.len()), Some(32));
        assert_eq!(
            (config.version.as_str(), config.build),
            ("1.3.0", 1_030_099)
        );
    }

    #[test]
    fn a_build_without_a_feed_or_a_key_has_none() {
        assert_eq!(
            Config::from_build(None, Some(KEY), "1.3.0"),
            Err(Unavailable::NotConfigured("CONDUIT_UPDATE_FEED_URL"))
        );
        assert_eq!(
            Config::from_build(Some(FEED), None, "1.3.0"),
            Err(Unavailable::NotConfigured("CONDUIT_UPDATE_PUBLIC_ED_KEY"))
        );
        assert_eq!(
            Config::from_build(Some(" "), Some(" "), "1.3.0"),
            Err(Unavailable::NotConfigured("CONDUIT_UPDATE_FEED_URL"))
        );
    }

    #[test]
    fn a_key_that_is_not_32_bytes_of_base64_is_refused() {
        // WinSparkle would run unsigned updates without a valid key.
        for bad in [
            "not base64!",
            "AAAA",
            "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            &KEY.repeat(2),
        ] {
            assert_eq!(
                Config::from_build(Some(FEED), Some(bad), "1.3.0"),
                Err(Unavailable::Invalid("CONDUIT_UPDATE_PUBLIC_ED_KEY")),
                "{bad:?}"
            );
        }
    }

    #[test]
    fn a_feed_that_is_not_http_or_a_version_without_a_build_is_refused() {
        assert_eq!(
            Config::from_build(Some("file:///tmp/appcast.xml"), Some(KEY), "1.3.0"),
            Err(Unavailable::Invalid("CONDUIT_UPDATE_FEED_URL"))
        );
        assert_eq!(
            Config::from_build(Some(FEED), Some(KEY), "1.3"),
            Err(Unavailable::Version("1.3".into()))
        );
    }

    #[test]
    fn winsparkle_gets_the_feed_the_key_and_the_build_from_the_build_constants() {
        let config = Config::from_build(Some(FEED), Some(KEY), "1.3.0").unwrap();
        assert_eq!(
            WinSparkleSettings::new(&config, "de"),
            WinSparkleSettings {
                appcast_url: FEED.into(),
                eddsa_public_key: KEY.into(),
                company_name: "Conduit",
                app_name: "Conduit",
                app_version: "1.3.0".into(),
                build_version: "1030099".into(),
                registry_path: r"Software\Conduit\Updates",
                check_interval_secs: 86_400,
                lang: "de".into(),
            }
        );
    }

    #[test]
    fn winsparkle_speaks_the_apps_language() {
        let config = Config::from_build(Some(FEED), Some(KEY), "1.3.0").unwrap();
        let lang = |locale| WinSparkleSettings::new(&config, locale).lang;
        assert_eq!(lang("en"), "en");
        assert_eq!(lang("zh"), "zh-CN");
        assert_eq!(lang("zh_Hant"), "zh-TW");
        assert_eq!(lang("pt_BR"), "pt-BR");
    }
}
