//! The app's preferences as a GPUI entity: appearance (palette, mode,
//! sidebar backdrop, density, text size), the language override, the
//! shortcut overrides and Settings › Desktop (menu bar, open at login, the
//! Quick Ask shortcut, answer notifications). Changing one saves
//! `desktop-preferences.json` and applies it: the Conduit theme (and GPUI
//! Kit's), the app appearance, the strings, and, through [`SettingsEvent`],
//! the menus, key bindings and the shell services.

use std::path::PathBuf;

use conduit_components::theme::{
    self, AccentPolicy, ConduitTheme, DesignPrefs, ToolbarLayout, UserMessageStyle,
};
use gpui_kit::{App, Context, EventEmitter, Hsla};

use crate::keymap::{KeyStroke, Keymap, ShortcutAction};
use crate::l10n::{L10n, LOCALES, locale};
use crate::prefs::{
    self, Appearance, DEFAULT_QUICK_ASK_SHORTCUT, DesktopPrefs, Preferences, ThemeMode,
};

#[derive(Clone, Debug, PartialEq)]
pub enum SettingsEvent {
    /// The strings changed: menus are rebuilt.
    LocaleChanged,
    /// The shortcut table changed: key bindings are rebuilt.
    KeymapChanged,
    /// Theme, palette, text size or language changed: the daemon is told
    /// (`settings.setApp`), since mobile reads the same keys.
    AppPreferencesChanged,
    /// Settings › Desktop changed: the shell re-applies the menu-bar item,
    /// the login item and the Quick Ask hotkey.
    DesktopChanged,
}

pub struct SettingsStore {
    pub prefs: Preferences,
    path: PathBuf,
    system_dark: bool,
    system_languages: Vec<String>,
    /// Settings › Keyboard is recording a new chord for this action.
    pub recording: Option<ShortcutAction>,
    pub record_message: Option<RecordMessage>,
    /// Settings › Desktop is recording a new Quick Ask chord.
    pub recording_quick_ask: bool,
    pub quick_ask_message: Option<RecordMessage>,
}

/// Why the last recorded chord was not taken.
#[derive(Clone, Debug, PartialEq)]
pub enum RecordMessage {
    /// Bare keys would eat typing (see `keymap::Shortcut::while_typing`).
    NeedsModifier,
    /// `stroke` already belongs to `other`.
    Conflict {
        stroke: KeyStroke,
        other: ShortcutAction,
    },
    /// `stroke` is the Quick Ask shortcut.
    ConflictQuickAsk { stroke: KeyStroke },
    /// `stroke` is a fixed command's (⌘R Regenerate, ⌘Q Quit).
    ConflictFixed {
        stroke: KeyStroke,
        command: crate::keymap::FixedCommand,
    },
}

impl EventEmitter<SettingsEvent> for SettingsStore {}

/// The app's settled design: monochrome accent, your messages in
/// bubbles, the chat title in the toolbar with the model picker in the
/// composer. Sidebar backdrop and density are settings.
pub fn design_prefs(appearance: &Appearance) -> DesignPrefs {
    DesignPrefs {
        sidebar: appearance.sidebar.into(),
        accent: AccentPolicy::Mono,
        user_message: UserMessageStyle::Bubble,
        density: appearance.density.into(),
        toolbar: ToolbarLayout::Pill,
    }
}

/// The preferences the daemon keeps for the app (`settings.setApp`), in
/// the keys mobile reads: theme mode, palette, text size and language.
pub fn app_preferences(prefs: &Preferences) -> conduit_protocol::AppPreferencesPatch {
    app_preferences_of(&prefs.appearance, prefs.locale.as_deref())
}

fn app_preferences_of(
    a: &Appearance,
    locale: Option<&str>,
) -> conduit_protocol::AppPreferencesPatch {
    use conduit_protocol::AppThemeMode;
    conduit_protocol::AppPreferencesPatch {
        theme_mode: Some(match a.mode {
            ThemeMode::System => AppThemeMode::System,
            ThemeMode::Light => AppThemeMode::Light,
            ThemeMode::Dark => AppThemeMode::Dark,
        }),
        theme_palette_id: Some(a.palette.clone()),
        ui_font_size: Some(a.effective_text_size().round() as i64),
        locale_code: locale.map(|l| l.replace('_', "-")),
        clear_locale_code: locale.is_none(),
    }
}

impl SettingsStore {
    pub fn new(
        prefs: Preferences,
        path: PathBuf,
        system_dark: bool,
        system_languages: Vec<String>,
    ) -> Self {
        Self {
            prefs,
            path,
            system_dark,
            system_languages,
            recording: None,
            record_message: None,
            recording_quick_ask: false,
            quick_ask_message: None,
        }
    }

    /// Reads the prefs file (defaults when missing).
    pub fn load(path: PathBuf, system_dark: bool, system_languages: Vec<String>) -> Self {
        Self::new(prefs::load(&path), path, system_dark, system_languages)
    }

    /// This Mac has its preferences file (written by the first change, and
    /// again as local data is cleared): its choices win over what the
    /// daemon has stored.
    pub fn has_file(&self) -> bool {
        self.path.is_file()
    }

    /// Takes the daemon's stored app preferences (`settings.getApp`):
    /// theme mode, palette, text size and language, then saves them here,
    /// so the next launch reads this Mac's file.
    pub fn adopt_app_preferences(
        &mut self,
        stored: &conduit_protocol::AppPreferences,
        cx: &mut Context<Self>,
    ) {
        use conduit_protocol::AppThemeMode;
        let a = &mut self.prefs.appearance;
        a.mode = match stored.theme_mode {
            AppThemeMode::Light => ThemeMode::Light,
            AppThemeMode::Dark => ThemeMode::Dark,
            _ => ThemeMode::System,
        };
        if theme::palettes()
            .ids()
            .any(|id| id == stored.theme_palette_id)
        {
            a.palette = stored.theme_palette_id.clone();
        }
        let size = stored.ui_font_size as f32;
        a.text_size = (size != crate::prefs::Appearance::default().effective_text_size())
            .then_some(size.clamp(crate::prefs::TEXT_SIZE_MIN, crate::prefs::TEXT_SIZE_MAX));
        let locale = stored
            .locale_code
            .as_deref()
            .map(|l| l.replace('-', "_"))
            .filter(|l| LOCALES.contains(&l.as_str()));
        let locale_changed = self.prefs.locale != locale;
        self.prefs.locale = locale;
        self.save();
        self.apply(cx);
        if locale_changed {
            cx.emit(SettingsEvent::LocaleChanged);
        }
        cx.notify();
    }

    pub fn dark(&self) -> bool {
        match self.prefs.appearance.mode {
            ThemeMode::System => self.system_dark,
            ThemeMode::Light => false,
            ThemeMode::Dark => true,
        }
    }

    /// The catalog locale: the override, else the system's languages.
    pub fn locale(&self) -> &'static str {
        self.prefs
            .locale
            .as_deref()
            .and_then(|l| LOCALES.iter().copied().find(|c| *c == l))
            .unwrap_or_else(|| locale::resolve(&self.system_languages))
    }

    pub fn keymap(&self) -> Keymap {
        Keymap::new(self.prefs.shortcuts.clone())
    }

    /// The theme these settings ask for.
    pub fn theme(&self, system_accent: Hsla) -> ConduitTheme {
        let a = &self.prefs.appearance;
        let mut t = ConduitTheme::new(&a.palette, self.dark(), design_prefs(a), system_accent);
        t.metrics.body = a.effective_text_size();
        t
    }

    /// Installs the theme, the strings and the app appearance.
    pub fn apply(&self, cx: &mut App) {
        let accent = conduit_components::window::system_accent_color();
        let theme = self.theme(accent);
        // AppKit's chrome may take the new look a frame before the content
        // beside it. Covering that with snapshots of the windows would need
        // screen capture, which can make macOS ask for Screen Recording.
        #[cfg(target_os = "macos")]
        crate::shell::macos::set_app_appearance(match self.prefs.appearance.mode {
            ThemeMode::System => None,
            ThemeMode::Light => Some(false),
            ThemeMode::Dark => Some(true),
        });
        theme::install(theme, cx);
        if cx.try_global::<L10n>().map(L10n::locale) != Some(self.locale()) {
            cx.set_global(L10n::new(self.locale()));
        }
    }

    pub fn save(&self) {
        if let Err(e) = prefs::save(&self.path, &self.prefs) {
            log::error!("could not save {}: {e}", self.path.display());
        }
    }

    pub fn set_appearance(&mut self, edit: impl FnOnce(&mut Appearance), cx: &mut Context<Self>) {
        let before = self.prefs.appearance.clone();
        edit(&mut self.prefs.appearance);
        if self.prefs.appearance == before {
            return;
        }
        self.save();
        self.apply(cx);
        if app_preferences(&self.prefs) != app_preferences_of(&before, self.prefs.locale.as_deref())
        {
            cx.emit(SettingsEvent::AppPreferencesChanged);
        }
        cx.notify();
    }

    /// The system's light/dark changed (matters in `ThemeMode::System`).
    pub fn set_system_dark(&mut self, dark: bool, cx: &mut Context<Self>) {
        if self.system_dark == dark {
            return;
        }
        self.system_dark = dark;
        if self.prefs.appearance.mode == ThemeMode::System {
            self.apply(cx);
            cx.notify();
        }
    }

    /// `None` follows the system.
    pub fn set_locale(&mut self, locale: Option<String>, cx: &mut Context<Self>) {
        if self.prefs.locale == locale {
            return;
        }
        self.prefs.locale = locale;
        self.save();
        self.apply(cx);
        cx.emit(SettingsEvent::LocaleChanged);
        cx.emit(SettingsEvent::AppPreferencesChanged);
        cx.notify();
    }

    /// Rebinds `action`; `Err(other)` when `other` already has `stroke`.
    pub fn set_shortcut(
        &mut self,
        action: ShortcutAction,
        stroke: KeyStroke,
        cx: &mut Context<Self>,
    ) -> Result<(), ShortcutAction> {
        let mut keymap = self.keymap();
        keymap.set(action, stroke)?;
        self.store_keymap(keymap, cx);
        Ok(())
    }

    /// Puts `action` back on its default. When another action has taken
    /// that chord since, nothing changes: the row records instead, and says
    /// which action has it.
    pub fn reset_shortcut(&mut self, action: ShortcutAction, cx: &mut Context<Self>) {
        let mut keymap = self.keymap();
        // Not onto the Quick Ask chord either.
        if let Some(stroke) = keymap.defaults_stroke(action)
            && self.prefs.desktop.quick_ask
            && stroke == self.prefs.desktop.quick_ask_stroke()
        {
            self.record_for(Some(action), cx);
            self.record_message = Some(RecordMessage::ConflictQuickAsk { stroke });
            cx.notify();
            return;
        }
        match keymap.reset(action) {
            Ok(()) => self.store_keymap(keymap, cx),
            Err(other) => {
                self.record_for(Some(action), cx);
                self.record_message = Some(RecordMessage::Conflict {
                    stroke: keymap
                        .defaults_stroke(action)
                        .unwrap_or_else(|| keymap.stroke(action)),
                    other,
                });
                cx.notify();
            }
        }
    }

    pub fn reset_all_shortcuts(&mut self, cx: &mut Context<Self>) {
        let mut keymap = self.keymap();
        keymap.reset_all();
        self.store_keymap(keymap, cx);
    }

    /// Starts (or, with `None`, cancels) recording a chord for `action`.
    pub fn record_for(&mut self, action: Option<ShortcutAction>, cx: &mut Context<Self>) {
        self.recording = action;
        self.record_message = None;
        if action.is_some() {
            self.recording_quick_ask = false;
            self.quick_ask_message = None;
        }
        cx.notify();
    }

    /// Ends any recording (the pane it was in went away).
    pub fn stop_recording(&mut self, cx: &mut Context<Self>) {
        if self.recording.is_some() || self.recording_quick_ask {
            self.recording = None;
            self.recording_quick_ask = false;
            self.record_message = None;
            self.quick_ask_message = None;
            cx.notify();
        }
    }

    /// Settings › Desktop: changes one of its settings.
    /// Whether pictures from `host` load without a click.
    pub fn image_host_allowed(&self, host: &str) -> bool {
        let host = crate::stores::media::normalize_host(host);
        self.prefs.remote_image_hosts.binary_search(&host).is_ok()
    }

    /// Always Load Images from `host`: pictures and PDF previews from it
    /// load without a click from now on, in every chat.
    pub fn allow_image_host(&mut self, host: &str, cx: &mut Context<Self>) {
        let host = crate::stores::media::normalize_host(host);
        if host.is_empty() {
            return;
        }
        if let Err(at) = self.prefs.remote_image_hosts.binary_search(&host) {
            self.prefs.remote_image_hosts.insert(at, host);
            self.save();
            cx.notify();
            cx.refresh_windows();
        }
    }

    /// Settings › Chats › Remove: pictures and PDF previews from `host`
    /// wait for a click again (one loaded with Load Image stays loaded
    /// until the app quits).
    pub fn forget_image_host(&mut self, host: &str, cx: &mut Context<Self>) {
        let host = crate::stores::media::normalize_host(host);
        if let Ok(at) = self.prefs.remote_image_hosts.binary_search(&host) {
            self.prefs.remote_image_hosts.remove(at);
            self.save();
            cx.notify();
            cx.refresh_windows();
        }
    }

    pub fn set_desktop(&mut self, edit: impl FnOnce(&mut DesktopPrefs), cx: &mut Context<Self>) {
        let before = self.prefs.desktop.clone();
        edit(&mut self.prefs.desktop);
        if self.prefs.desktop == before {
            return;
        }
        // Quick Ask off: its chord is no longer being recorded (the keys go
        // back to the app).
        if !self.prefs.desktop.quick_ask && self.recording_quick_ask {
            self.recording_quick_ask = false;
            self.quick_ask_message = None;
        }
        self.save();
        cx.emit(SettingsEvent::DesktopChanged);
        cx.notify();
    }

    /// Starts (`true`) or cancels recording the Quick Ask chord.
    pub fn record_quick_ask(&mut self, on: bool, cx: &mut Context<Self>) {
        self.recording_quick_ask = on;
        self.quick_ask_message = None;
        if on {
            self.recording = None;
            self.record_message = None;
        }
        cx.notify();
    }

    /// Puts the Quick Ask chord back to ⇧⌘Space.
    pub fn reset_quick_ask_shortcut(&mut self, cx: &mut Context<Self>) {
        self.quick_ask_message = None;
        self.set_desktop(
            |d| d.quick_ask_shortcut = DEFAULT_QUICK_ASK_SHORTCUT.into(),
            cx,
        );
    }

    /// Why `stroke` can't be the Quick Ask chord: it needs ⌘ or ⌥, and the
    /// app's own shortcuts keep theirs (the hotkey would swallow them).
    pub fn quick_ask_conflict(&self, stroke: &KeyStroke) -> Option<RecordMessage> {
        if !stroke.is_chord() {
            return Some(RecordMessage::NeedsModifier);
        }
        if let Some(command) = crate::keymap::fixed_conflict(stroke, None) {
            return Some(RecordMessage::ConflictFixed {
                stroke: stroke.clone(),
                command,
            });
        }
        self.keymap()
            .table()
            .into_iter()
            .find(|s| &s.stroke == stroke)
            .map(|s| RecordMessage::Conflict {
                stroke: stroke.clone(),
                other: s.action,
            })
    }

    /// Offers a keystroke to the recorder; answers whether it was consumed
    /// (so it neither types nor fires a binding). Esc cancels; a modifier
    /// alone keeps listening; a chord without ⌘ or ⌥ is refused; a chord
    /// another action has is a conflict.
    pub fn record(&mut self, keystroke: &gpui_kit::Keystroke, cx: &mut Context<Self>) -> bool {
        if self.recording_quick_ask {
            return self.record_quick_ask_key(keystroke, cx);
        }
        let Some(action) = self.recording else {
            return false;
        };
        let m = &keystroke.modifiers;
        if keystroke.key == "escape" && !(m.platform || m.alt || m.shift || m.control) {
            self.record_for(None, cx);
            return true;
        }
        let Some(stroke) = crate::keymap::from_gpui(keystroke) else {
            return true;
        };
        if !stroke.is_chord() {
            self.record_message = Some(RecordMessage::NeedsModifier);
            cx.notify();
            return true;
        }
        if self.prefs.desktop.quick_ask && stroke == self.prefs.desktop.quick_ask_stroke() {
            self.record_message = Some(RecordMessage::ConflictQuickAsk { stroke });
            cx.notify();
            return true;
        }
        if let Some(command) = crate::keymap::fixed_conflict(&stroke, Some(action)) {
            self.record_message = Some(RecordMessage::ConflictFixed { stroke, command });
            cx.notify();
            return true;
        }
        match self.set_shortcut(action, stroke.clone(), cx) {
            Ok(()) => {
                self.recording = None;
                self.record_message = None;
            }
            Err(other) => self.record_message = Some(RecordMessage::Conflict { stroke, other }),
        }
        cx.notify();
        true
    }

    /// [`Self::record`] while the Quick Ask chord is being recorded.
    fn record_quick_ask_key(
        &mut self,
        keystroke: &gpui_kit::Keystroke,
        cx: &mut Context<Self>,
    ) -> bool {
        let m = &keystroke.modifiers;
        if keystroke.key == "escape" && !(m.platform || m.alt || m.shift || m.control) {
            self.record_quick_ask(false, cx);
            return true;
        }
        let Some(stroke) = crate::keymap::from_gpui(keystroke) else {
            return true;
        };
        if let Some(message) = self.quick_ask_conflict(&stroke) {
            self.quick_ask_message = Some(message);
            cx.notify();
            return true;
        }
        self.recording_quick_ask = false;
        self.quick_ask_message = None;
        let encoded = crate::keymap::encode(&stroke);
        self.set_desktop(|d| d.quick_ask_shortcut = encoded, cx);
        cx.notify();
        true
    }

    fn store_keymap(&mut self, keymap: Keymap, cx: &mut Context<Self>) {
        if keymap.overrides == self.prefs.shortcuts {
            return;
        }
        self.prefs.shortcuts = keymap.overrides;
        self.save();
        cx.emit(SettingsEvent::KeymapChanged);
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prefs::{DensityChoice, SidebarChoice};
    use conduit_components::theme::{Density, SidebarStyle};
    use gpui_kit::component::{Theme, ThemeMode as KitMode};
    use gpui_kit::{AppContext as _, TestAppContext};

    /// A key press as GPUI delivers it, `secondary-` being the platform's
    /// primary modifier: ⌘ on the Mac, Ctrl on Windows and Linux.
    fn key(source: &str) -> gpui_kit::Keystroke {
        use gpui_kit::OperatingSystem as Os;
        let os = if cfg!(target_os = "macos") {
            Os::Mac
        } else if cfg!(windows) {
            Os::Windows
        } else {
            Os::Linux
        };
        gpui_kit::Keystroke::parse_with_os(source, os).unwrap()
    }

    fn store(dir: &str, system_dark: bool) -> SettingsStore {
        let path = std::env::temp_dir()
            .join(format!("conduit-settings-{dir}-{}", std::process::id()))
            .join("desktop-preferences.json");
        SettingsStore::new(
            Preferences::default(),
            path,
            system_dark,
            vec!["de-DE".into()],
        )
    }

    #[gpui_kit::test]
    fn applying_installs_the_conduit_and_kit_themes(cx: &mut TestAppContext) {
        cx.update(gpui_kit::init);
        let settings = cx.new(|_| store("apply", false));
        settings.update(cx, |s, cx| s.apply(cx));
        cx.update(|cx| {
            let t = cx.global::<ConduitTheme>();
            assert_eq!(t.palette_id.as_ref(), "conduit");
            assert!(!t.dark);
            // The locked design, with the default settings.
            assert_eq!(t.prefs.sidebar, SidebarStyle::Material);
            assert_eq!(t.prefs.density, Density::Compact);
            assert_eq!(t.prefs.user_message, UserMessageStyle::Bubble);
            assert_eq!(t.prefs.toolbar, ToolbarLayout::Pill);
            assert_eq!(t.prefs.accent, AccentPolicy::Mono);
            assert_eq!(t.metrics.body, 14.);
            assert_eq!(Theme::global(cx).mode, KitMode::Light);
            assert_eq!(cx.global::<L10n>().locale(), "de");
        });

        // Each appearance setting reaches the installed theme.
        settings.update(cx, |s, cx| {
            s.set_appearance(
                |a| {
                    a.palette = "catppuccin".into();
                    a.mode = ThemeMode::Dark;
                    a.sidebar = SidebarChoice::Surface;
                    a.density = DensityChoice::Comfortable;
                    a.text_size = Some(17.);
                },
                cx,
            )
        });
        cx.update(|cx| {
            let t = cx.global::<ConduitTheme>();
            assert_eq!(t.palette_id.as_ref(), "catppuccin");
            assert!(t.dark);
            assert_eq!(t.prefs.sidebar, SidebarStyle::Surface);
            assert_eq!(t.roles.sidebar, t.colors.sidebar_background);
            assert_eq!(t.metrics.row_height, 32.);
            assert_eq!(t.metrics.body, 17.);
            let kit = Theme::global(cx);
            assert_eq!(kit.mode, KitMode::Dark);
            assert_eq!(kit.font_size, gpui_kit::px(17.));
            assert_eq!(kit.background, t.surfaces.panel);
        });
        // And it was saved.
        let saved: Preferences = prefs::load(&settings.read_with(cx, |s, _| s.path.clone()));
        assert_eq!(saved.appearance.palette, "catppuccin");
        assert_eq!(saved.appearance.mode, ThemeMode::Dark);
    }

    #[gpui_kit::test]
    fn system_mode_follows_the_system(cx: &mut TestAppContext) {
        cx.update(gpui_kit::init);
        let settings = cx.new(|_| store("system", false));
        settings.update(cx, |s, cx| s.apply(cx));
        settings.update(cx, |s, cx| s.set_system_dark(true, cx));
        cx.update(|cx| assert!(cx.global::<ConduitTheme>().dark));
        // A forced mode ignores the system.
        settings.update(cx, |s, cx| {
            s.set_appearance(|a| a.mode = ThemeMode::Light, cx)
        });
        settings.update(cx, |s, cx| s.set_system_dark(false, cx));
        settings.update(cx, |s, cx| s.set_system_dark(true, cx));
        cx.update(|cx| assert!(!cx.global::<ConduitTheme>().dark));
    }

    #[gpui_kit::test]
    fn locale_override_and_shortcuts_persist(cx: &mut TestAppContext) {
        cx.update(gpui_kit::init);
        let settings = cx.new(|_| store("locale", false));
        settings.update(cx, |s, cx| s.apply(cx));
        settings.update(cx, |s, cx| s.set_locale(Some("ja".into()), cx));
        cx.update(|cx| assert_eq!(cx.global::<L10n>().locale(), "ja"));
        settings.update(cx, |s, cx| s.set_locale(None, cx));
        cx.update(|cx| assert_eq!(cx.global::<L10n>().locale(), "de"));

        let conflict = settings.update(cx, |s, cx| {
            s.set_shortcut(
                ShortcutAction::ToggleSidebar,
                KeyStroke::new("k").primary(),
                cx,
            )
        });
        assert_eq!(conflict, Err(ShortcutAction::OpenPalette));
        settings
            .update(cx, |s, cx| {
                s.set_shortcut(
                    ShortcutAction::ToggleSidebar,
                    KeyStroke::new("b").primary(),
                    cx,
                )
            })
            .unwrap();
        let path = settings.read_with(cx, |s, _| s.path.clone());
        let saved: Preferences = prefs::load(&path);
        assert_eq!(
            saved.shortcuts.get("toggleSidebar").map(String::as_str),
            Some("mod+b")
        );
        assert_eq!(saved.locale, None);
    }

    #[gpui_kit::test]
    fn desktop_settings_save_and_announce(cx: &mut TestAppContext) {
        let settings = cx.new(|_| store("desktop", false));
        let events = std::rc::Rc::new(std::cell::RefCell::new(vec![]));
        cx.update(|cx| {
            let events = events.clone();
            cx.subscribe(&settings, move |_, e: &SettingsEvent, _| {
                events.borrow_mut().push(e.clone())
            })
            .detach();
        });
        settings.update(cx, |s, cx| {
            s.set_desktop(|d| d.close_to_menu_bar = true, cx);
            // No change, no event.
            s.set_desktop(|d| d.close_to_menu_bar = true, cx);
            s.set_desktop(|d| d.notify_answers = false, cx);
        });
        assert_eq!(
            *events.borrow(),
            vec![SettingsEvent::DesktopChanged, SettingsEvent::DesktopChanged]
        );
        let saved: Preferences = prefs::load(&settings.read_with(cx, |s, _| s.path.clone()));
        assert!(saved.desktop.close_to_menu_bar);
        assert!(!saved.desktop.notify_answers);
        assert!(saved.desktop.quick_ask);
    }

    #[gpui_kit::test]
    fn a_profile_without_its_file_takes_the_daemons_preferences(cx: &mut TestAppContext) {
        cx.update(gpui_kit::init);
        let settings = cx.new(|_| store("adopt", false));
        // A first run: no file yet.
        let path = settings.read_with(cx, |s, _| s.path.clone());
        let _ = std::fs::remove_file(&path);
        assert!(!settings.read_with(cx, |s, _| s.has_file()));
        let stored = conduit_protocol::AppPreferences {
            theme_mode: conduit_protocol::AppThemeMode::Dark,
            theme_palette_id: "catppuccin".into(),
            ui_font_size: 16,
            locale_code: Some("zh-Hant".into()),
        };
        settings.update(cx, |s, cx| s.adopt_app_preferences(&stored, cx));
        settings.read_with(cx, |s, _| {
            assert!(s.has_file());
            assert_eq!(s.prefs.appearance.mode, ThemeMode::Dark);
            assert_eq!(s.prefs.appearance.palette, "catppuccin");
            assert_eq!(s.prefs.appearance.text_size, Some(16.));
            assert_eq!(s.prefs.locale.as_deref(), Some("zh_Hant"));
        });
        // A palette this build doesn't have is not taken.
        let unknown = conduit_protocol::AppPreferences {
            theme_palette_id: "retired".into(),
            ..stored
        };
        settings.update(cx, |s, cx| s.adopt_app_preferences(&unknown, cx));
        assert_eq!(
            settings.read_with(cx, |s, _| s.prefs.appearance.palette.clone()),
            "catppuccin"
        );
    }

    #[gpui_kit::test]
    fn recording_the_quick_ask_shortcut(cx: &mut TestAppContext) {
        let settings = cx.new(|_| store("quick-ask", false));
        // Turning Quick Ask off ends its recording: keys go back to the app.
        settings.update(cx, |s, cx| {
            s.record_quick_ask(true, cx);
            s.set_desktop(|d| d.quick_ask = false, cx);
        });
        settings.read_with(cx, |s, _| assert!(!s.recording_quick_ask));
        settings.update(cx, |s, cx| s.set_desktop(|d| d.quick_ask = true, cx));
        // A reset never puts a shortcut onto the Quick Ask chord.
        settings.update(cx, |s, cx| {
            s.set_shortcut(ShortcutAction::NewChat, KeyStroke::new("j").primary(), cx)
                .unwrap();
            s.set_desktop(|d| d.quick_ask_shortcut = "mod+n".into(), cx);
            s.reset_shortcut(ShortcutAction::NewChat, cx);
        });
        settings.read_with(cx, |s, _| {
            assert_eq!(
                s.keymap().stroke(ShortcutAction::NewChat),
                KeyStroke::new("j").primary()
            );
            assert!(matches!(
                s.record_message,
                Some(RecordMessage::ConflictQuickAsk { .. })
            ));
        });
        settings.update(cx, |s, cx| {
            s.record_for(None, cx);
            s.set_desktop(
                |d| d.quick_ask_shortcut = crate::prefs::DEFAULT_QUICK_ASK_SHORTCUT.into(),
                cx,
            );
            s.reset_shortcut(ShortcutAction::NewChat, cx);
        });
        settings.update(cx, |s, cx| s.record_quick_ask(true, cx));
        // A bare key is refused; an app shortcut's chord conflicts.
        assert!(settings.update(cx, |s, cx| s.record(&key("space"), cx)));
        settings.read_with(cx, |s, _| {
            assert_eq!(s.quick_ask_message, Some(RecordMessage::NeedsModifier));
            assert!(s.recording_quick_ask);
        });
        assert!(settings.update(cx, |s, cx| s.record(&key("secondary-k"), cx)));
        settings.read_with(cx, |s, _| {
            assert_eq!(
                s.quick_ask_message,
                Some(RecordMessage::Conflict {
                    stroke: KeyStroke::new("k").primary(),
                    other: ShortcutAction::OpenPalette
                })
            );
        });
        // A free chord is taken, saved, and recording stops.
        assert!(settings.update(cx, |s, cx| s.record(&key("alt-space"), cx)));
        settings.read_with(cx, |s, _| {
            assert!(!s.recording_quick_ask);
            assert_eq!(
                s.prefs.desktop.quick_ask_stroke(),
                KeyStroke::new(" ").alt()
            );
        });
        let path = settings.read_with(cx, |s, _| s.path.clone());
        assert_eq!(
            prefs::load::<Preferences>(&path).desktop.quick_ask_shortcut,
            "alt+ "
        );
        // An app shortcut can't take the Quick Ask chord either.
        settings.update(cx, |s, cx| {
            s.record_for(Some(ShortcutAction::ToggleSidebar), cx)
        });
        assert!(settings.update(cx, |s, cx| s.record(&key("alt-space"), cx)));
        settings.read_with(cx, |s, _| {
            assert_eq!(
                s.record_message,
                Some(RecordMessage::ConflictQuickAsk {
                    stroke: KeyStroke::new(" ").alt()
                })
            );
        });
        // Esc cancels; reset puts ⇧⌘Space back.
        settings.update(cx, |s, cx| s.record_quick_ask(true, cx));
        assert!(settings.update(cx, |s, cx| s.record(&key("escape"), cx)));
        settings.update(cx, |s, cx| s.reset_quick_ask_shortcut(cx));
        settings.read_with(cx, |s, _| {
            assert!(!s.recording_quick_ask && s.recording.is_none());
            assert_eq!(
                s.prefs.desktop.quick_ask_stroke(),
                KeyStroke::new(" ").primary().shift()
            );
        });
    }

    #[gpui_kit::test]
    fn recording_a_shortcut(cx: &mut TestAppContext) {
        let settings = cx.new(|_| store("record", false));
        // Not recording: keystrokes pass through.
        assert!(!settings.update(cx, |s, cx| s.record(&key("secondary-b"), cx)));
        settings.update(cx, |s, cx| {
            s.record_for(Some(ShortcutAction::ToggleSidebar), cx)
        });
        // A bare key is refused, a taken chord conflicts, both keep recording.
        assert!(settings.update(cx, |s, cx| s.record(&key("b"), cx)));
        settings.read_with(cx, |s, _| {
            assert_eq!(s.record_message, Some(RecordMessage::NeedsModifier));
            assert_eq!(s.recording, Some(ShortcutAction::ToggleSidebar));
        });
        assert!(settings.update(cx, |s, cx| s.record(&key("secondary-k"), cx)));
        settings.read_with(cx, |s, _| {
            assert_eq!(
                s.record_message,
                Some(RecordMessage::Conflict {
                    stroke: KeyStroke::new("k").primary(),
                    other: ShortcutAction::OpenPalette
                })
            );
        });
        // A free chord is taken and recording stops.
        assert!(settings.update(cx, |s, cx| s.record(&key("secondary-alt-b"), cx)));
        settings.read_with(cx, |s, _| {
            assert_eq!(s.recording, None);
            assert_eq!(
                s.keymap().stroke(ShortcutAction::ToggleSidebar),
                KeyStroke::new("b").primary().alt()
            );
        });
        // Esc cancels without changing anything.
        settings.update(cx, |s, cx| {
            s.record_for(Some(ShortcutAction::OpenSettings), cx)
        });
        assert!(settings.update(cx, |s, cx| s.record(&key("escape"), cx)));
        settings.read_with(cx, |s, _| {
            assert_eq!(s.recording, None);
            assert_eq!(
                s.keymap().stroke(ShortcutAction::OpenSettings),
                KeyStroke::new(",").primary()
            );
        });
    }

    #[gpui_kit::test]
    fn fixed_chords_are_refused_with_their_command(cx: &mut TestAppContext) {
        use crate::keymap::FixedCommand;
        let settings = cx.new(|_| store("fixed", false));
        // ⌘R is Regenerate's (Chat menu), not free for New Chat.
        settings.update(cx, |s, cx| s.record_for(Some(ShortcutAction::NewChat), cx));
        assert!(settings.update(cx, |s, cx| s.record(&key("secondary-r"), cx)));
        settings.read_with(cx, |s, _| {
            assert_eq!(
                s.record_message,
                Some(RecordMessage::ConflictFixed {
                    stroke: KeyStroke::new("r").primary(),
                    command: FixedCommand::Regenerate
                })
            );
            assert_eq!(s.recording, Some(ShortcutAction::NewChat));
            assert!(s.prefs.shortcuts.is_empty());
        });
        // Open Settings may take ⌘, back (it is its own).
        settings.update(cx, |s, cx| {
            s.record_for(Some(ShortcutAction::OpenSettings), cx)
        });
        assert!(settings.update(cx, |s, cx| s.record(&key("secondary-alt-,"), cx)));
        settings.update(cx, |s, cx| {
            s.record_for(Some(ShortcutAction::OpenSettings), cx)
        });
        assert!(settings.update(cx, |s, cx| s.record(&key("secondary-,"), cx)));
        settings.read_with(cx, |s, _| {
            assert_eq!(s.recording, None);
            assert!(s.prefs.shortcuts.is_empty());
        });
        // Quick Ask can't take ⌘Q.
        settings.update(cx, |s, cx| s.record_quick_ask(true, cx));
        assert!(settings.update(cx, |s, cx| s.record(&key("secondary-q"), cx)));
        settings.read_with(cx, |s, _| {
            assert_eq!(
                s.quick_ask_message,
                Some(RecordMessage::ConflictFixed {
                    stroke: KeyStroke::new("q").primary(),
                    command: FixedCommand::Quit
                })
            );
        });
    }
}
