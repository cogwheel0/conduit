//! The app's own preferences, as JSON under userData:
//!
//! * `window-state.json`: main-window geometry and layout (sidebar shown,
//!   width);
//! * `desktop-preferences.json`: appearance, the language override, the
//!   user's shortcut overrides and Settings › Desktop (menu bar, open at
//!   login, Quick Ask, answer notifications).
//!
//! The daemon keeps the preferences mobile shares (`settings.getApp` and
//! `settings.setApp`); this stays the app-side store for what only the
//! shell uses. A missing or unreadable
//! file yields defaults; writes go through a temp file and a rename.

use std::collections::BTreeMap;
use std::path::Path;

use conduit_components::theme::{Density, SidebarStyle};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

/// Main-window geometry and layout.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WindowState {
    /// Top-left in screen points; `None` centres the window.
    pub x: Option<f32>,
    pub y: Option<f32>,
    pub width: f32,
    pub height: f32,
    pub maximized: bool,
    pub sidebar_visible: bool,
    /// The app fronted the main window last (a session), not the setup
    /// window: what it opens before the daemon answers. `None` in a file
    /// from before the setup window, where a saved frame means it had.
    pub last_main: Option<bool>,
}

impl WindowState {
    /// Whether to open the main window at launch, before the route is known.
    pub fn opens_main(&self) -> bool {
        self.last_main.unwrap_or(self.x.is_some())
    }
}

impl Default for WindowState {
    fn default() -> Self {
        let (width, height) = conduit_components::window::MAIN_WINDOW_SIZE;
        Self {
            x: None,
            y: None,
            width,
            height,
            maximized: false,
            sidebar_visible: true,
            last_main: None,
        }
    }
}

impl WindowState {
    /// Clamps the size to the window minimum.
    pub fn sanitized(mut self) -> Self {
        let (min_w, min_h) = conduit_components::window::MAIN_WINDOW_MIN;
        let default = Self::default();
        if !self.width.is_finite() {
            self.width = default.width;
        }
        if !self.height.is_finite() {
            self.height = default.height;
        }
        self.width = self.width.max(min_w);
        self.height = self.height.max(min_h);
        self.x = self.x.filter(|v| v.is_finite());
        self.y = self.y.filter(|v| v.is_finite());
        self
    }
}

/// Light, dark, or following the system.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ThemeMode {
    #[default]
    System,
    Light,
    Dark,
}

/// The sidebar backdrop setting (`SidebarStyle`, serialized).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SidebarChoice {
    #[default]
    Material,
    Surface,
}

impl From<SidebarChoice> for SidebarStyle {
    fn from(c: SidebarChoice) -> Self {
        match c {
            SidebarChoice::Material => Self::Material,
            SidebarChoice::Surface => Self::Surface,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DensityChoice {
    #[default]
    Compact,
    Comfortable,
}

impl From<DensityChoice> for Density {
    fn from(c: DensityChoice) -> Self {
        match c {
            DensityChoice::Compact => Self::Compact,
            DensityChoice::Comfortable => Self::Comfortable,
        }
    }
}

/// Message text size bounds, in points.
pub const TEXT_SIZE_MIN: f32 = 12.;
pub const TEXT_SIZE_MAX: f32 = 20.;

/// Settings › Appearance.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Appearance {
    /// A `palettes.json` id; unknown ids fall back to Conduit's own. The
    /// retired desktop-only `zai` reads as `conduit` (see [`palette_id`]).
    #[serde(deserialize_with = "palette_id")]
    pub palette: String,
    pub mode: ThemeMode,
    pub sidebar: SidebarChoice,
    pub density: DensityChoice,
    /// Message text size; `None` follows the density (14 / 15 pt).
    pub text_size: Option<f32>,
}

/// The palette a new install starts with: Conduit's own monochrome one, as
/// on the phone.
pub const DEFAULT_PALETTE: &str = "conduit";

/// Earlier builds offered a desktop-only palette, `zai`; the desktop now
/// offers exactly the phone's palettes, so a stored `zai` becomes the
/// default and is written back as such on the next save.
fn palette_id<'de, D: serde::Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    let id = String::deserialize(d)?;
    Ok(if id == "zai" {
        DEFAULT_PALETTE.into()
    } else {
        id
    })
}

impl Default for Appearance {
    fn default() -> Self {
        Self {
            palette: DEFAULT_PALETTE.into(),
            mode: ThemeMode::System,
            sidebar: SidebarChoice::Material,
            density: DensityChoice::Compact,
            text_size: None,
        }
    }
}

impl Appearance {
    /// The message text size in effect.
    pub fn effective_text_size(&self) -> f32 {
        self.text_size
            .filter(|s| s.is_finite())
            .map(|s| s.clamp(TEXT_SIZE_MIN, TEXT_SIZE_MAX))
            .unwrap_or_else(|| {
                conduit_components::theme::Metrics::for_density(self.density.into()).body
            })
    }
}

/// The Quick Ask shortcut when the user has not chosen one: ⇧⌘Space.
pub const DEFAULT_QUICK_ASK_SHORTCUT: &str = "mod+shift+ ";

/// Settings › Desktop: how the app lives on the desktop.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DesktopPrefs {
    /// Closing the main window hides it; the app keeps running with a
    /// menu-bar item.
    pub close_to_menu_bar: bool,
    /// The user asked to open at login (`SMAppService.mainApp`). What the
    /// system reports wins on screen; this is the user's last choice.
    pub launch_at_login: bool,
    /// The global Quick Ask shortcut is registered.
    pub quick_ask: bool,
    /// The Quick Ask chord, encoded as the keymap does (`mod+shift+ `).
    pub quick_ask_shortcut: String,
    /// "Notify when an answer finishes".
    pub notify_answers: bool,
    /// "Notify About Channel Messages": someone else posted in a channel
    /// that is not in front of the user (by the channel's own setting).
    pub notify_channels: bool,
    /// The two switches above moved to the core's notification settings
    /// (Settings › Notifications); they are read once more, never written.
    pub notifications_moved: bool,
    /// Settings › Keyboard › "Use Option as Meta Key": in the terminal,
    /// Option sends Escape before the key instead of typing a character.
    pub terminal_option_as_meta: bool,
}

impl Default for DesktopPrefs {
    fn default() -> Self {
        Self {
            close_to_menu_bar: false,
            launch_at_login: false,
            quick_ask: true,
            quick_ask_shortcut: DEFAULT_QUICK_ASK_SHORTCUT.into(),
            notify_answers: true,
            notify_channels: true,
            notifications_moved: false,
            terminal_option_as_meta: false,
        }
    }
}

impl DesktopPrefs {
    /// The Quick Ask chord; the default when the stored one is unreadable.
    pub fn quick_ask_stroke(&self) -> crate::keymap::KeyStroke {
        crate::keymap::decode(&self.quick_ask_shortcut)
            .filter(|s| s.is_chord())
            .or_else(|| crate::keymap::decode(DEFAULT_QUICK_ASK_SHORTCUT))
            .unwrap_or_else(|| crate::keymap::KeyStroke::new(" ").primary().shift())
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Preferences {
    pub appearance: Appearance,
    /// A catalog locale (`de`, `zh_Hant`); `None` follows the system.
    pub locale: Option<String>,
    /// Shortcut overrides by action name (`newChat` → `mod+n`).
    pub shortcuts: BTreeMap<String, String>,
    /// Menu bar, open at login, Quick Ask, notifications.
    pub desktop: DesktopPrefs,
    /// Sites whose pictures (and PDF previews) in answers load without a
    /// click, by host: Always Load Images from … adds one, Settings › Chats
    /// lists and removes them. Lower case, sorted, no repeats. App-wide,
    /// not per account: a site is trusted or not whichever server's model
    /// linked it, as core keeps look-and-feel settings device-wide.
    pub remote_image_hosts: Vec<String>,
}

/// Reads `path`, or the default when it is missing.
///
/// A value this build cannot read (a setting a newer build added a choice
/// to, or a wrong type) costs only that value: it takes its default, and
/// every other setting is kept. A file that does not parse at all gives the
/// defaults. Either way the file is first copied to `<name>.bad`, so the
/// next save never destroys the only copy.
pub fn load<T: DeserializeOwned + Default>(path: &Path) -> T {
    let Ok(bytes) = std::fs::read(path) else {
        return T::default();
    };
    let e = match serde_json::from_slice(&bytes) {
        Ok(value) => return value,
        Err(e) => e,
    };
    log::warn!(
        "{} is partly unreadable ({e}); keeping what reads",
        path.display()
    );
    let backup = path.with_extension("json.bad");
    if let Err(e) = std::fs::write(&backup, &bytes) {
        log::warn!("{}: {e}", backup.display());
    }
    serde_json::from_slice::<serde_json::Value>(&bytes)
        .ok()
        .and_then(|value| serde_json::from_value(salvage::<T>(&[], &value)?).ok())
        .unwrap_or_default()
}

/// The part of `value` (found at `path` in the file) that reads as `T`:
/// the whole of it when it does, else, for an object, each of its entries
/// that does. Every struct here defaults its missing fields, so a value is
/// tried on its own, nested at its path.
fn salvage<T: DeserializeOwned>(
    path: &[&str],
    value: &serde_json::Value,
) -> Option<serde_json::Value> {
    let nested = path.iter().rev().fold(value.clone(), |inner, key| {
        serde_json::Value::Object([(key.to_string(), inner)].into_iter().collect())
    });
    if serde_json::from_value::<T>(nested).is_ok() {
        return Some(value.clone());
    }
    let serde_json::Value::Object(map) = value else {
        return None;
    };
    let kept = map
        .iter()
        .filter_map(|(key, inner)| {
            let mut at = path.to_vec();
            at.push(key);
            salvage::<T>(&at, inner).map(|v| (key.clone(), v))
        })
        .collect();
    Some(serde_json::Value::Object(kept))
}

/// Writes `value` to `path` atomically (temp file, then rename).
pub fn save<T: Serialize>(path: &Path, value: &T) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut json = serde_json::to_vec_pretty(value).map_err(std::io::Error::other)?;
    json.push(b'\n');
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json)?;
    std::fs::rename(&tmp, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!("conduit-prefs-{name}-{}", std::process::id()))
    }

    #[test]
    fn round_trips_and_defaults() {
        let path = dir("rt").join("desktop-preferences.json");
        assert_eq!(load::<Preferences>(&path), Preferences::default());
        let mut prefs = Preferences::default();
        prefs.appearance.palette = "catppuccin".into();
        prefs.appearance.mode = ThemeMode::Dark;
        prefs.appearance.text_size = Some(16.);
        prefs.locale = Some("de".into());
        prefs.shortcuts.insert("newChat".into(), "mod+n".into());
        save(&path, &prefs).unwrap();
        assert_eq!(load::<Preferences>(&path), prefs);
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("\"textSize\": 16.0"), "{text}");
    }

    #[test]
    fn desktop_settings_persist_with_their_defaults() {
        let d = DesktopPrefs::default();
        assert!(!d.close_to_menu_bar && !d.launch_at_login);
        assert!(d.quick_ask && d.notify_answers);
        assert_eq!(
            d.quick_ask_stroke(),
            crate::keymap::KeyStroke::new(" ").primary().shift()
        );
        let path = dir("desktop").join("desktop-preferences.json");
        let mut prefs = Preferences::default();
        prefs.desktop.close_to_menu_bar = true;
        prefs.desktop.notify_answers = false;
        prefs.desktop.quick_ask_shortcut = "mod+alt+k".into();
        save(&path, &prefs).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(
            text.contains("\"quickAskShortcut\": \"mod+alt+k\""),
            "{text}"
        );
        let back = load::<Preferences>(&path);
        assert_eq!(back, prefs);
        assert_eq!(
            back.desktop.quick_ask_stroke(),
            crate::keymap::KeyStroke::new("k").primary().alt()
        );
        // A file without the newer desktop settings gets their defaults; a bad
        // chord falls back.
        std::fs::write(
            &path,
            br#"{"locale": "de", "desktop": {"quickAskShortcut": "k"}}"#,
        )
        .unwrap();
        let old = load::<Preferences>(&path);
        assert_eq!(old.locale.as_deref(), Some("de"));
        assert!(old.desktop.quick_ask && old.desktop.notify_answers);
        assert_eq!(
            old.desktop.quick_ask_stroke(),
            crate::keymap::KeyStroke::new(" ").primary().shift()
        );
    }

    #[test]
    fn a_saved_beta_updates_switch_is_ignored() {
        // Releases are stable only: an older build's "Receive beta updates"
        // stays in the file until the next save, and nothing reads it.
        let path = dir("beta").join("desktop-preferences.json");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(
            &path,
            br#"{"desktop": {"betaUpdates": true, "closeToMenuBar": true}}"#,
        )
        .unwrap();
        let prefs = load::<Preferences>(&path);
        assert!(prefs.desktop.close_to_menu_bar);
        save(&path, &prefs).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(!text.contains("betaUpdates"), "{text}");
    }

    #[test]
    fn unreadable_files_give_defaults() {
        let path = dir("bad").join("window-state.json");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"{not json").unwrap();
        assert_eq!(load::<WindowState>(&path), WindowState::default());
        // Unknown fields and missing ones are fine.
        std::fs::write(&path, br#"{"width": 900, "future": 1}"#).unwrap();
        let s = load::<WindowState>(&path);
        assert_eq!(s.width, 900.);
        assert_eq!(s.height, 860.);
        assert!(s.sidebar_visible);
    }

    #[test]
    fn a_value_this_build_cannot_read_costs_only_that_value() {
        // A newer build's choices and a wrong type, among good settings.
        let path = dir("salvage").join("desktop-preferences.json");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let text = br#"{
            "appearance": {"palette": "claude", "mode": "sepia", "density": "comfortable"},
            "locale": "de",
            "shortcuts": {"newChat": "mod+n", "search": 7},
            "desktop": {"quickAsk": "yes", "notifyAnswers": false, "launchAtLogin": true}
        }"#;
        std::fs::write(&path, text).unwrap();
        let prefs = load::<Preferences>(&path);
        assert_eq!(prefs.appearance.palette, "claude");
        assert_eq!(prefs.appearance.mode, ThemeMode::System);
        assert_eq!(prefs.appearance.density, DensityChoice::Comfortable);
        assert_eq!(prefs.locale.as_deref(), Some("de"));
        assert_eq!(
            prefs.shortcuts,
            BTreeMap::from([("newChat".to_string(), "mod+n".to_string())])
        );
        // The struct's own default, not the type's.
        assert!(prefs.desktop.quick_ask);
        assert!(!prefs.desktop.notify_answers);
        assert!(prefs.desktop.launch_at_login);
        // The file as it was, kept beside it.
        assert_eq!(
            std::fs::read(path.with_extension("json.bad")).unwrap(),
            text.to_vec()
        );
    }

    #[test]
    fn the_window_to_open_first_is_the_one_fronted_last() {
        // A first run: the setup window.
        assert!(!WindowState::default().opens_main());
        // A file from before the setup window, with a saved frame: main.
        let old: WindowState =
            serde_json::from_str(r#"{"x":10,"y":20,"width":1280,"height":860}"#).unwrap();
        assert!(old.opens_main());
        // Signed out last time, whatever the frame says: setup.
        let out: WindowState = serde_json::from_str(r#"{"x":10,"y":20,"lastMain":false}"#).unwrap();
        assert!(!out.opens_main());
        let back = serde_json::to_string(&out).unwrap();
        assert!(back.contains(r#""lastMain":false"#), "{back}");
    }

    #[test]
    fn window_state_respects_the_minimum() {
        let s = WindowState {
            width: 100.,
            height: f32::NAN,
            x: Some(f32::INFINITY),
            ..Default::default()
        }
        .sanitized();
        assert_eq!((s.width, s.height), (720., 860.));
        assert_eq!(s.x, None);
    }

    #[test]
    fn conduit_is_the_default_and_a_stored_zai_moves_to_it() {
        assert_eq!(Appearance::default().palette, "conduit");
        let old: Appearance = serde_json::from_str(r#"{"palette":"zai","mode":"dark"}"#).unwrap();
        assert_eq!(old.palette, "conduit");
        assert_eq!(old.mode, ThemeMode::Dark);
        let kept: Appearance = serde_json::from_str(r#"{"palette":"claude"}"#).unwrap();
        assert_eq!(kept.palette, "claude");
    }

    #[test]
    fn text_size_follows_density_until_set() {
        let mut a = Appearance::default();
        assert_eq!(a.effective_text_size(), 14.);
        a.density = DensityChoice::Comfortable;
        assert_eq!(a.effective_text_size(), 15.);
        a.text_size = Some(40.);
        assert_eq!(a.effective_text_size(), TEXT_SIZE_MAX);
    }
}
