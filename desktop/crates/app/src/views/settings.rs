//! The Settings window: a System Settings layout with working tabs, in
//! a Mac app's order (General first).
//!
//! * **General** (`Tab::Desktop`): close to the menu bar (with its
//!   menu-bar item), open at login (`SMAppService`, with the system's
//!   status), the Quick Ask shortcut (on/off, rebindable with conflict
//!   checks, and a note when another app holds it).
//! * **Notifications** ([`notifications`]): the phone's page (what notifies
//!   and how), and the account's webhook destinations behind Advanced.
//! * **Accounts**: the saved accounts with the active one marked; Switch,
//!   Sign in again, a row menu to sign out of (and remove) one, and Add
//!   Account (a window sheet, [`crate::views::add_account`]). Signing out
//!   lives here only.
//! * **Direct connections** and **Hermes**: the same forms onboarding uses.
//! * **Appearance**: light/dark/system, every palette in `palettes.json`,
//!   the sidebar material or surface, density, message text size.
//! * **Language**: the system's or one the app speaks.
//! * **Keyboard**: every shortcut, grouped as the menus are (Chats,
//!   Messages, Find & View, Window): the rebindable ones in recorder fields
//!   with conflict detection, the fixed ones as text, and Quick Ask's.
//! * **Data**: clear local data (asked with a native sheet) and export the
//!   diagnostic report.
//! * **About**: the version, the server's name and version, What's New,
//!   the source repository and open-source licenses, Support Conduit, and
//!   updates (Check Now and check automatically; see [`crate::updates`]).
//!
//! The phone's Settings pages, in the phone's groups (see [`Tab::ALL`]):
//! **Profile**, **Personalization** and **Connection** for the account
//! ([`profile`], [`personalization`], [`connection`]); **Chat** and
//! **Audio** with Appearance ([`chats`], [`audio`]); and **Personal
//! Connections** and **Data Controls** behind Advanced ([`connections`],
//! [`data_controls`]). Accounts ends with Sign Out (this
//! account, or all of them).

pub mod audio;
pub mod chats;
pub mod connection;
pub mod connection_editor;
pub mod connections;
pub mod controls;
pub mod data_controls;
pub mod hermes;
pub mod librechat_memories;
pub mod notifications;
pub mod personalization;
pub mod profile;
pub mod server_sheet;
pub mod webhook_editor;

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::motion::specs;
use conduit_components::theme;
#[cfg(target_os = "macos")]
use conduit_components::theme::SidebarStyle;
use conduit_components::views::focus::{
    ControlExt as _, RadioGroupExt as _, Ring, radio_option_id,
};
use conduit_components::views::kit::{
    Button, IconButton, Segment, Segmented, SelectHandler, Switch, grouped, setting_row,
    warning_row,
};
use conduit_components::views::settings::{
    PaletteChoice, SchemeTile, SettingsTab, SettingsWindow, palette_picker_with, scheme_tiles,
    settings_section, stepper_with,
};
use conduit_components::views::shortcut_field::ShortcutField;
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Context, Entity, FocusHandle, Focusable, FontWeight, Role, SharedString,
    Subscription, Window, div, px,
};

use crate::actions::{RemoveAccount, SetLocale, SettingsChoice};
use crate::desktop::Desktop;
use crate::keymap::{self, FixedCommand, KeyGroup, KeyRow, ShortcutAction, describe};
use crate::l10n::{ActiveL10n as _, L10n, LOCALES, locale};
use crate::prefs::{
    DEFAULT_QUICK_ASK_SHORTCUT, DensityChoice, SidebarChoice, TEXT_SIZE_MAX, TEXT_SIZE_MIN,
    ThemeMode,
};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::connection::ConnectionStore;
use crate::stores::settings::{RecordMessage, SettingsStore};
use crate::stores::shell::{HotkeyState, LoginState};
use crate::views::accounts::{accounts_sections, remove_account};
use crate::views::add_account::{self, AddAccountSheet};
use crate::views::direct::pane::DirectPane;
use crate::views::forms;
use crate::views::privacy;
use crate::views::server_form::{ServerForm, ServerFormEvent};
use crate::views::status::diagnostics_state;

/// Width of the Settings window's tab sidebar.
pub const SETTINGS_SIDEBAR: f32 = 210.;
/// The Settings window's size.
pub const SETTINGS_SIZE: (f32, f32) = (860., 760.);

/// The `SettingsChoice` menu an account row's Server Settings… sends (the
/// server's id).
pub const SERVER_SETTINGS_MENU: &str = "server-settings";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tab {
    Appearance,
    Language,
    Accounts,
    Direct,
    Hermes,
    Keyboard,
    Desktop,
    Data,
    About,
    Profile,
    Personalization,
    Connection,
    Chats,
    Audio,
    DataControls,
    Notifications,
    PersonalConnections,
}

impl Tab {
    /// General first, as every Mac app's Settings (Mail: General, then
    /// Accounts); then the phone's groups in the phone's order: the
    /// account's pages (Profile, Personalization, Connection), the app's
    /// (Appearance, Chat, Audio, then the Mac's Language and Keyboard), the
    /// connections (Direct, Hermes), Advanced (Personal Connections, Data
    /// Controls), and last what is about this Mac and the app (Data,
    /// About). Notifications follows Profile, as on the phone, and shows for
    /// every backend (answers notify for all of them).
    pub const ALL: [Self; 17] = [
        Self::Desktop,
        Self::Accounts,
        Self::Profile,
        Self::Notifications,
        Self::Personalization,
        Self::Connection,
        Self::Appearance,
        Self::Chats,
        Self::Audio,
        Self::Language,
        Self::Keyboard,
        Self::Direct,
        Self::Hermes,
        Self::PersonalConnections,
        Self::DataControls,
        Self::Data,
        Self::About,
    ];

    /// The pane Settings opens on when nothing asks for another: General.
    pub const FIRST: Self = Self::ALL[0];

    /// The group the tab sits in (the list puts room between groups).
    fn group(self) -> u8 {
        match self {
            Self::Desktop | Self::Accounts => 0,
            Self::Profile | Self::Notifications | Self::Personalization | Self::Connection => 1,
            Self::Appearance | Self::Chats | Self::Audio | Self::Language | Self::Keyboard => 2,
            Self::Direct | Self::Hermes => 3,
            Self::PersonalConnections | Self::DataControls => 4,
            Self::Data | Self::About => 5,
        }
    }

    /// The tabs shown now, as the phone gates its pages: the account's own
    /// pages need an Open WebUI account, Personalization an Open WebUI
    /// account or a Direct connection (not Hermes alone), and Data Controls
    /// Advanced too.
    pub fn visible(stores: &Stores, cx: &App) -> Vec<Self> {
        let open_webui = stores.accounts.read(cx).active().is_some();
        let hermes_only = stores.session.read(cx).hermes_only(cx);
        let advanced = stores
            .app_settings
            .read(cx)
            .settings()
            .advanced_features_enabled;
        Self::ALL
            .into_iter()
            .filter(|tab| match tab {
                Self::Profile | Self::Connection => open_webui,
                Self::Personalization => open_webui || !hermes_only,
                Self::DataControls | Self::PersonalConnections => open_webui && advanced,
                _ => true,
            })
            .collect()
    }

    /// The tab a `conduit://settings/<tab>` link names (`general` too, the
    /// Desktop tab's name now).
    pub fn from_id(id: &str) -> Option<Self> {
        if id == "general" {
            return Some(Self::Desktop);
        }
        Self::ALL.into_iter().find(|t| t.id() == id)
    }

    pub fn id(self) -> &'static str {
        match self {
            Self::Appearance => "appearance",
            Self::Language => "language",
            Self::Accounts => "accounts",
            Self::Direct => "direct",
            Self::Hermes => "hermes",
            Self::Keyboard => "keyboard",
            Self::Desktop => "desktop",
            Self::Data => "data",
            Self::About => "about",
            Self::Profile => "profile",
            Self::Personalization => "personalization",
            Self::Connection => "connection",
            Self::Chats => "chat",
            Self::Audio => "audio",
            Self::DataControls => "data-controls",
            Self::Notifications => "notifications",
            Self::PersonalConnections => "personal-connections",
        }
    }

    fn icon(self) -> IconName {
        match self {
            Self::Appearance => IconName::Palette,
            Self::Language => IconName::Globe,
            Self::Accounts => IconName::Users,
            Self::Direct => IconName::Zap,
            Self::Hermes => IconName::Bot,
            Self::Keyboard => IconName::Keyboard,
            // General, as System Settings draws it.
            Self::Desktop => IconName::Settings,
            Self::Data => IconName::Database,
            Self::About => IconName::Info,
            Self::Profile => IconName::CircleUser,
            Self::Personalization => IconName::Sparkles,
            Self::Connection => IconName::Wifi,
            Self::Chats => IconName::MessageSquare,
            Self::Audio => IconName::AudioLines,
            Self::DataControls => IconName::DatabaseBackup,
            Self::Notifications => IconName::Bell,
            Self::PersonalConnections => IconName::Network,
        }
    }

    fn label(self, l10n: &L10n) -> String {
        match self {
            Self::Appearance => l10n.desktop_settings_appearance_tab(),
            Self::Language => l10n.app_language(),
            Self::Accounts => l10n.desktop_settings_accounts_tab(),
            Self::Direct => l10n.desktop_settings_direct_tab(),
            Self::Hermes => l10n.desktop_hermes_agent(),
            Self::Keyboard => l10n.desktop_settings_keyboard_tab(),
            Self::Desktop => l10n.desktop_settings_desktop_tab(),
            Self::Data => l10n.desktop_settings_data_tab(),
            Self::About => l10n.about_app(),
            Self::Profile => l10n.profile_title(),
            Self::Personalization => l10n.personalization(),
            Self::Connection => l10n.settings_data_and_connection(),
            Self::Chats => l10n.chat_settings(),
            Self::Audio => l10n.audio_settings_title(),
            Self::DataControls => l10n.chat_data_controls_title(),
            Self::Notifications => l10n.notifications_title(),
            Self::PersonalConnections => l10n.personal_connections_title(),
        }
    }
}

/// Applies a control's selected index to the appearance.
type AppearanceEdit = Rc<dyn Fn(&mut crate::prefs::Appearance, usize)>;

/// A shortcut's name in Settings › Keyboard.
pub fn shortcut_label(action: ShortcutAction, l10n: &L10n) -> String {
    use ShortcutAction as A;
    match action {
        A::NewChat => l10n.new_chat(),
        A::OpenPalette => l10n.desktop_shortcut_open_palette(),
        A::FocusComposer => l10n.desktop_shortcut_focus_composer(),
        A::FocusModelPicker => l10n.desktop_shortcut_focus_model_picker(),
        A::StopGenerating => l10n.desktop_stop_generating(),
        A::OpenSettings => l10n.desktop_shortcut_open_settings(),
        A::ShowShortcuts => l10n.desktop_shortcut_show_shortcuts(),
        A::CopyLastResponse => l10n.desktop_shortcut_copy_last_response(),
        A::CopyLastCodeBlock => l10n.desktop_shortcut_copy_last_code_block(),
        A::AllowRequest => l10n.desktop_shortcut_allow_request(),
        A::DenyRequest => l10n.desktop_shortcut_deny_request(),
        A::Dictate => l10n.desktop_shortcut_dictate(),
        A::ToggleSidebar => l10n.desktop_shortcut_toggle_sidebar(),
        A::ReadAloud => l10n.desktop_read_aloud(),
        A::VoiceCall => l10n.voice_call_title(),
    }
}

/// Two sentences as one footer: a space between them, none after a
/// full-width stop (Chinese, Japanese).
pub fn join_sentences(first: &str, second: &str) -> String {
    if first.ends_with('。') {
        format!("{first}{second}")
    } else {
        format!("{first} {second}")
    }
}

/// A fixed command's name in Settings › Keyboard (the menu item's, where it
/// reads alone).
pub fn fixed_label(command: FixedCommand, l10n: &L10n) -> String {
    use FixedCommand as F;
    match command {
        F::NewTemporaryChat => l10n.desktop_new_temporary_chat(),
        F::SearchChats => l10n.desktop_menu_search_chats(),
        F::DeleteChat => l10n.desktop_keyboard_delete_chat(),
        F::NextChat => l10n.desktop_menu_next_chat(),
        F::PreviousChat => l10n.desktop_menu_previous_chat(),
        F::Regenerate => l10n.regenerate(),
        F::StopSpeaking => l10n.desktop_stop_speaking(),
        F::ExpandEditor => l10n.desktop_expand_editor(),
        F::AskConduit => l10n.ask_conduit_action(),
        F::ChatSettings => l10n.chat_settings_title(),
        F::FindInChat => l10n.desktop_keyboard_find_in_chat(),
        F::FindNext => l10n.desktop_find_next(),
        F::FindPrevious => l10n.desktop_find_previous(),
        F::ActualSize => l10n.desktop_menu_actual_size(),
        F::ZoomIn => l10n.desktop_menu_zoom_in(),
        F::ZoomOut => l10n.desktop_menu_zoom_out(),
        F::Settings => l10n.desktop_shortcut_open_settings(),
        F::Quit => l10n.desktop_menu_quit(),
        F::Hide => l10n.desktop_menu_hide(),
        F::HideOthers => l10n.desktop_menu_hide_others(),
        F::CloseWindow => l10n.desktop_menu_close_window(),
        F::Minimize => l10n.desktop_minimize_window(),
        F::FullScreen => l10n.desktop_menu_enter_full_screen(),
        F::Back => l10n.desktop_menu_back(),
        F::Forward => l10n.desktop_menu_forward(),
        F::GoToSection(_) => l10n.desktop_keyboard_go_to_section(),
        F::NextArea => l10n.desktop_menu_next_area(),
        F::PreviousArea => l10n.desktop_menu_previous_area(),
    }
}

/// An area key's name in Settings › Keyboard: the Format menu's item, the
/// File menu's New Note, Save.
pub fn area_key_label(key: keymap::AreaKey, l10n: &L10n) -> String {
    use keymap::AreaKey as K;
    match key {
        K::NewNote => l10n.desktop_new_note(),
        K::Title => l10n.desktop_note_style_title(),
        K::Heading => l10n.desktop_note_style_heading(),
        K::Subheading => l10n.desktop_note_style_subheading(),
        K::Body => l10n.desktop_note_style_body(),
        K::Bold => l10n.desktop_note_bold(),
        K::Italic => l10n.desktop_note_italic(),
        K::Strikethrough => l10n.desktop_note_strikethrough(),
        K::Code => l10n.desktop_note_code(),
        K::Link => l10n.desktop_add_link_ellipsis(),
        K::BulletedList => l10n.desktop_note_bulleted_list(),
        K::NumberedList => l10n.desktop_note_numbered_list(),
        K::Checklist => l10n.desktop_note_checklist(),
        K::MarkChecked => l10n.desktop_note_mark_checked(),
        K::Quote => l10n.desktop_note_quote(),
        K::CodeBlock => l10n.desktop_note_code_block(),
        K::SaveWorkspaceItem | K::SaveCalendarEvent | K::SaveScheduledTask => l10n.save(),
        K::CalendarEarlier => l10n.desktop_keyboard_calendar_earlier(),
        K::CalendarLater => l10n.desktop_keyboard_calendar_later(),
        K::CalendarToday => l10n.calendar_today(),
        K::DeleteCalendarItem | K::DeleteScheduledTask => l10n.desktop_delete_ellipsis(),
        K::TerminalFind => l10n.desktop_menu_find(),
        K::TerminalCopy => l10n.copy(),
        K::TerminalPaste => l10n.terminal_paste_action(),
        K::TerminalSelectAll => l10n.desktop_menu_select_all(),
        K::TerminalClearScrollback => l10n.desktop_terminal_clear_scrollback(),
        K::SavePdf => l10n.desktop_preview_save(),
        K::SendInRoom => l10n.send(),
        K::SaveHermesJob => l10n.save(),
    }
}

/// A fixed chord: the same keycap as a recorder field's, dimmed and with
/// nothing to click (the pane's footer says why).
fn fixed_keys(command: FixedCommand, keys: String, label: String) -> ShortcutField {
    ShortcutField::new(
        SharedString::from(format!("fixed-{command:?}")),
        keys,
        label,
        SharedString::default(),
    )
    .fixed(true)
}

/// A palette's localized name.
fn palette_label(id: &str, l10n: &L10n) -> String {
    match id {
        "conduit" => l10n.theme_palette_conduit_label(),
        // Named for their colours on the Mac, not for other products.
        "claude" => l10n.desktop_palette_clay(),
        "t3_chat" => l10n.desktop_palette_berry(),
        "catppuccin" => l10n.theme_palette_catppuccin_label(),
        "tangerine" => l10n.theme_palette_tangerine_label(),
        other => other.to_string(),
    }
}

/// Add Account's sheet: its window, hung from Settings' title bar.
#[derive(Clone)]
pub struct AddSheet {
    pub handle: gpui_kit::AnyWindowHandle,
    pub view: Entity<AddAccountSheet>,
}

impl AddSheet {
    /// The server form in the sheet.
    pub fn form(&self, cx: &App) -> Entity<ServerForm> {
        self.view.read(cx).form.clone()
    }
}

/// Ends a sheet's window (it slides up) and closes it, between GPUI
/// borrows (AppKit calls back into GPUI as the parent takes the keyboard).
pub fn end_sheet_window(handle: gpui_kit::AnyWindowHandle, cx: &mut App) {
    // The main window's sheet host no longer has it down.
    crate::views::sheet::forget(handle, cx);
    #[cfg(target_os = "macos")]
    let ns = handle
        .update(cx, |_, w, _| crate::shell::macos::ns_window(w))
        .ok()
        .flatten();
    cx.spawn(async move |cx| {
        #[cfg(target_os = "macos")]
        if let Some(ns) = ns {
            crate::shell::macos::end_sheet(&ns);
        }
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    })
    .detach();
}

pub struct SettingsView {
    settings: Entity<SettingsStore>,
    connection: Entity<ConnectionStore>,
    stores: Stores,
    pub direct: Option<Entity<DirectPane>>,
    pub profile: Option<Entity<profile::ProfilePane>>,
    pub personalization: Option<Entity<personalization::PersonalizationPane>>,
    pub chats: Option<Entity<chats::ChatsPane>>,
    pub audio: Option<Entity<audio::AudioPane>>,
    pub data_controls: Option<Entity<data_controls::DataControlsPane>>,
    pub notifications: Option<Entity<notifications::NotificationsPane>>,
    pub personal_connections: Option<Entity<connections::PersonalConnectionsPane>>,
    /// About's server rows and links (`settings.about`).
    pub about_info: Option<conduit_protocol::AboutInfo>,
    /// The account the panes above were made for: another one starts them
    /// over, so nothing of the last account's is shown or saved to it.
    account: Option<String>,
    /// About's last fetch failed: asked again when About shows next.
    about_failed: bool,
    /// Bumped per account: an About answer for the last one is dropped.
    about_round: u64,
    pub tab: Tab,
    /// When the pane last changed by a click or key in the window (the new
    /// one fades in); `None` while it shows the pane it opened with.
    switched: Option<std::time::Instant>,
    focus: FocusHandle,
    /// About's developer details (core, protocol, folders) are shown.
    /// Add Account's sheet, while it is down.
    pub add_sheet: Option<AddSheet>,
    _add_sheet: Option<Subscription>,
    #[cfg(target_os = "macos")]
    material: crate::shell::macos::SidebarMaterial,
    _subscriptions: Vec<Subscription>,
}

impl SettingsView {
    pub fn new(
        settings: Entity<SettingsStore>,
        stores: Stores,
        tab: Tab,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let connection = stores.connection.clone();
        let mut subscriptions = vec![
            cx.observe(&settings, |_, _, cx| cx.notify()),
            cx.observe(&connection, |_, _, cx| cx.notify()),
            // The account in charge of the chats: an Open WebUI account, or
            // a LibreChat one while the Open WebUI account stays parked.
            cx.observe(&stores.accounts, |this: &mut Self, accounts, cx| {
                let active = accounts.read(cx).scope_key();
                if active != this.account {
                    this.account = active;
                    this.forget_account(cx);
                }
                cx.notify()
            }),
            cx.observe(&stores.session, |_, _, cx| cx.notify()),
            cx.observe(&stores.app_settings, |_, _, cx| cx.notify()),
            cx.observe(&stores.hermes_admin, |_, _, cx| cx.notify()),
        ];
        if let Some(shell) = cx.try_global::<Desktop>().map(|d| d.shell.clone()) {
            subscriptions.push(cx.observe(&shell, |_, _, cx| cx.notify()));
        }
        // A Settings window that goes takes its sheet with it.
        subscriptions.push(cx.on_release(|this: &mut Self, cx: &mut App| {
            if let Some(sheet) = this.add_sheet.take() {
                end_sheet_window(sheet.handle, cx);
            }
            // A chord being recorded is the window's: keys go back to the
            // app once it closes.
            this.settings.update(cx, |s, cx| s.stop_recording(cx));
            if let Some(audio) = this.audio.clone() {
                audio.update(cx, |a, cx| a.stop_preview(cx));
            }
        }));
        let account = stores.accounts.read(cx).scope_key();
        // The system's answers may have changed since (System Settings).
        crate::desktop::refresh_statuses(cx);
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        Self {
            settings,
            connection,
            stores,
            direct: None,
            profile: None,
            personalization: None,
            chats: None,
            audio: None,
            data_controls: None,
            notifications: None,
            personal_connections: None,
            about_info: None,
            account,
            about_failed: false,
            about_round: 0,
            tab,
            switched: None,
            focus,
            add_sheet: None,
            _add_sheet: None,
            #[cfg(target_os = "macos")]
            material: Default::default(),
            _subscriptions: subscriptions,
        }
    }

    /// Another account is active: the panes holding the last one's profile,
    /// prompt, memories, chats, voices and data counts start over, and
    /// About asks its server again.
    fn forget_account(&mut self, cx: &mut Context<Self>) {
        if let Some(audio) = self.audio.take() {
            audio.update(cx, |a, cx| a.stop_preview(cx));
        }
        self.profile = None;
        self.personalization = None;
        // The account's connections, history and web search settings.
        self.direct = None;
        self.chats = None;
        self.data_controls = None;
        // The account's webhook destinations and its own tool servers and
        // terminals.
        self.notifications = None;
        self.personal_connections = None;
        self.about_info = None;
        self.about_failed = false;
        self.about_round += 1;
    }

    /// Gives focus back to the window itself (nothing ringed), as it opens.
    pub fn rest_focus(&self, window: &mut Window, cx: &mut Context<Self>) {
        window.focus(&self.focus, cx);
        cx.notify();
    }

    /// Shows `tab`'s pane, fading it in over the one before. Every tab
    /// change comes through here, so a recording never outlives its pane.
    pub fn show_tab(&mut self, tab: Tab, cx: &mut Context<Self>) {
        if tab != self.tab {
            // Recording belongs to the pane it started in, and so does
            // Preview Voice.
            self.settings.update(cx, |s, cx| s.stop_recording(cx));
            if let Some(audio) = self.audio.clone() {
                audio.update(cx, |a, cx| a.stop_preview(cx));
            }
            if tab == Tab::About && std::mem::take(&mut self.about_failed) {
                self.about_info = None;
            }
            self.tab = tab;
            self.switched = Some(cx.background_executor().now());
            // Direct Connections reads the account's connections again
            // each time it is shown, as mobile's page does.
            if tab == Tab::Direct
                && let Some(p) = &self.direct
            {
                p.update(cx, |p, cx| p.refresh_quietly(cx));
            }
            cx.notify();
            // Personal Connections reads them again each time it is shown,
            // as mobile's page does (another device may have changed them).
            if tab == Tab::PersonalConnections
                && let Some(p) = &self.personal_connections
            {
                p.update(cx, |p, cx| p.refresh(cx));
            }
            // A read that failed is tried again when its tab is shown.
            if tab == Tab::Notifications
                && let Some(p) = &self.notifications
            {
                p.update(cx, |p, cx| p.shown(cx));
            }
        }
    }

    /// Add Account as a window sheet on Settings (AppKit's `beginSheet:`,
    /// as System Settings › Internet Accounts): the server's address, then
    /// Connect. Sign-in for the new account follows in the setup window.
    pub fn open_add_sheet(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.show_tab(Tab::Accounts, cx);
        if let Some(sheet) = &self.add_sheet {
            // Already down: it keeps the keyboard.
            let handle = sheet.handle;
            cx.defer(move |cx| {
                let _ = handle.update(cx, |_, window, _| window.activate_window());
            });
            return;
        }
        let stores = self.stores.clone();
        let opened = conduit_components::window::open_window_clear_root(
            add_account::window_options(),
            cx,
            |window, cx| cx.new(|cx| AddAccountSheet::new(stores, window, cx)),
        );
        let (handle, view) = match opened {
            Ok(v) => v,
            Err(e) => {
                log::error!("could not open Add Account: {e}");
                return;
            }
        };
        self._add_sheet = Some(cx.subscribe_in(
            &view,
            window,
            |this, _, event: &ServerFormEvent, window, cx| {
                this.close_add_sheet(window, cx);
                // A Hermes connection or a provider: its editor, once the
                // sheet has gone (AppKit hangs one sheet at a time).
                match event {
                    ServerFormEvent::AddHermes => {
                        this.show_tab(Tab::Hermes, cx);
                        let stores = this.stores.clone();
                        cx.defer_in(window, move |_, window, cx| {
                            crate::views::hermes_connection::open(&stores, None, window, cx)
                        });
                        return;
                    }
                    ServerFormEvent::AddDirect => {
                        this.show_tab(Tab::Direct, cx);
                        let pane = this.direct_pane(window, cx);
                        cx.defer_in(window, move |_, window, cx| {
                            pane.update(cx, |p, cx| p.open_editor(None, false, window, cx))
                        });
                        return;
                    }
                    _ => {}
                }
                if matches!(event, ServerFormEvent::Connected) {
                    // Sign-in for the new account is next, in the setup
                    // window, which comes forward.
                    cx.defer(|cx| {
                        crate::windows::sync(cx);
                        crate::windows::show_front(cx);
                    });
                }
            },
        ));
        self.add_sheet = Some(AddSheet { handle, view });
        #[cfg(target_os = "macos")]
        {
            let parent = crate::shell::macos::ns_window(window);
            let sheet = handle
                .update(cx, |_, w, _| crate::shell::macos::ns_window(w))
                .ok()
                .flatten();
            if let (Some(parent), Some(sheet)) = (parent, sheet) {
                // After this update: AppKit calls back into GPUI as the
                // sheet takes the keyboard.
                cx.foreground_executor()
                    .spawn(async move { crate::shell::macos::begin_sheet(&parent, &sheet) })
                    .detach();
            }
        }
    }

    /// A saved Open WebUI server's sheet: its accounts and addresses.
    pub fn open_server(&mut self, server_id: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.tab = Tab::Accounts;
        cx.notify();
        server_sheet::open(&self.stores, server_id, window, cx);
    }

    fn close_add_sheet(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self._add_sheet = None;
        if let Some(sheet) = self.add_sheet.take() {
            end_sheet_window(sheet.handle, cx);
        }
        window.focus(&self.focus, cx);
        cx.notify();
    }

    fn profile_pane(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<profile::ProfilePane> {
        let stores = self.stores.clone();
        self.profile
            .get_or_insert_with(|| cx.new(|cx| profile::ProfilePane::new(stores, window, cx)))
            .clone()
    }

    fn personalization_pane(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<personalization::PersonalizationPane> {
        let stores = self.stores.clone();
        self.personalization
            .get_or_insert_with(|| {
                cx.new(|cx| personalization::PersonalizationPane::new(stores, window, cx))
            })
            .clone()
    }

    fn chats_pane(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<chats::ChatsPane> {
        let stores = self.stores.clone();
        self.chats
            .get_or_insert_with(|| cx.new(|cx| chats::ChatsPane::new(stores, window, cx)))
            .clone()
    }

    fn audio_pane(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<audio::AudioPane> {
        let stores = self.stores.clone();
        self.audio
            .get_or_insert_with(|| cx.new(|cx| audio::AudioPane::new(stores, window, cx)))
            .clone()
    }

    fn notifications_pane(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<notifications::NotificationsPane> {
        let stores = self.stores.clone();
        self.notifications
            .get_or_insert_with(|| {
                cx.new(|cx| notifications::NotificationsPane::new(stores, window, cx))
            })
            .clone()
    }

    fn personal_connections_pane(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<connections::PersonalConnectionsPane> {
        let stores = self.stores.clone();
        self.personal_connections
            .get_or_insert_with(|| {
                cx.new(|cx| connections::PersonalConnectionsPane::new(stores, window, cx))
            })
            .clone()
    }

    fn data_controls_pane(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<data_controls::DataControlsPane> {
        let stores = self.stores.clone();
        self.data_controls
            .get_or_insert_with(|| {
                cx.new(|cx| data_controls::DataControlsPane::new(stores, window, cx))
            })
            .clone()
    }

    /// A pop-up button's pick ([`SettingsChoice`]), for the pane that drew
    /// it.
    pub fn choose(&mut self, menu: &str, value: &str, window: &mut Window, cx: &mut Context<Self>) {
        match menu {
            "profile-gender" => {
                if let Some(p) = &self.profile {
                    p.update(cx, |p, cx| p.choose_gender(value, cx));
                }
            }
            "default-model" => {
                if let Some(p) = &self.personalization {
                    p.update(cx, |p, cx| p.choose_default_model(value, cx));
                }
            }
            menu if menu.starts_with("direct-") || menu.starts_with("web-search-") => {
                if let Some(p) = &self.direct {
                    p.update(cx, |p, cx| p.choose(menu, value, window, cx));
                }
            }
            hermes::MCP_MENU | hermes::CATALOG_MENU => {
                hermes::choose(&self.stores, menu, value, window, cx)
            }
            SERVER_SETTINGS_MENU => self.open_server(value, window, cx),
            menu if menu.starts_with("audio-") => {
                if let Some(p) = &self.audio {
                    p.update(cx, |p, cx| p.choose(menu, value, window, cx));
                }
            }
            other => log::debug!("no pop-up {other}"),
        }
    }

    fn appearance(&self, window: &mut Window, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let a = self.settings.read(cx).prefs.appearance.clone();
        let store = self.settings.clone();
        let edit = |f: AppearanceEdit| -> SelectHandler {
            let store = store.clone();
            Rc::new(move |i, _, cx| {
                let f = f.clone();
                store.update(cx, |s, cx| s.set_appearance(|a| f(a, i), cx));
            })
        };

        // The phone's scheme tiles: a miniature screen per mode.
        let modes = [ThemeMode::System, ThemeMode::Light, ThemeMode::Dark];
        let mode = scheme_tiles(
            &[
                (SchemeTile::System, l10n.system().into()),
                (SchemeTile::Light, l10n.theme_light().into()),
                (SchemeTile::Dark, l10n.theme_dark().into()),
            ],
            modes.iter().position(|m| *m == a.mode).unwrap_or(0),
            Some(edit(Rc::new(move |a, i| a.mode = modes[i]))),
            cx,
        )
        .aria_label(SharedString::from(l10n.desktop_settings_appearance_tab()));

        let palettes: Vec<String> = theme::palettes().ids().map(str::to_string).collect();
        let choices: Vec<PaletteChoice> = palettes
            .iter()
            .map(|id| {
                let v = theme::palettes().get(id).variant(t.dark);
                PaletteChoice {
                    id: id.clone().into(),
                    label: palette_label(id, &l10n).into(),
                    swatches: [
                        v.surfaces.window,
                        v.surfaces.panel,
                        v.colors.sidebar_background,
                        v.colors.primary,
                        v.colors.foreground,
                    ],
                }
            })
            .collect();
        let ids = palettes.clone();
        let picker = palette_picker_with(
            &choices,
            &t.palette_id,
            Some(edit(Rc::new(move |a, i| a.palette = ids[i].clone()))),
            cx,
        );

        let sidebars = [SidebarChoice::Material, SidebarChoice::Surface];
        let sidebar = Segmented::new(
            "sidebar-style",
            l10n.desktop_sidebar(),
            vec![
                Segment::new(l10n.desktop_sidebar_translucent()),
                Segment::new(l10n.desktop_sidebar_solid()),
            ],
            sidebars.iter().position(|s| *s == a.sidebar).unwrap_or(0),
        )
        .on_select(edit(Rc::new(move |a, i| a.sidebar = sidebars[i])));

        let densities = [DensityChoice::Compact, DensityChoice::Comfortable];
        let density = Segmented::new(
            "density",
            l10n.desktop_density(),
            vec![
                Segment::new(l10n.desktop_density_compact()),
                Segment::new(l10n.desktop_density_comfortable()),
            ],
            densities.iter().position(|d| *d == a.density).unwrap_or(0),
        )
        .on_select(edit(Rc::new(move |a, i| a.density = densities[i])));

        let size = a.effective_text_size();
        let text_size = stepper_with(
            "text-size",
            &l10n.desktop_ui_font_size(),
            l10n.desktop_ui_font_size_value(size.round() as i64),
            Some(edit(Rc::new(|a, up| {
                let now = a.effective_text_size();
                let next = if up == 1 { now + 1. } else { now - 1. };
                a.text_size = Some(next.clamp(TEXT_SIZE_MIN, TEXT_SIZE_MAX));
            }))),
            cx,
        );

        let _ = window;

        // Theme, Palette and Layout: each a titled group, its title over
        // the card as every Settings section has it.
        vec![
            settings_section(
                l10n.desktop_appearance_theme(),
                None,
                vec![mode.into_any_element()],
                cx,
            )
            .into_any_element(),
            settings_section(
                l10n.desktop_palette(),
                None,
                vec![div().pt(px(12.)).child(picker).into_any_element()],
                cx,
            )
            .into_any_element(),
            settings_section(
                l10n.desktop_appearance_layout(),
                Some(l10n.desktop_ui_font_size_hint().into()),
                vec![
                    setting_row(l10n.desktop_sidebar(), None, sidebar, cx).into_any_element(),
                    setting_row(l10n.desktop_density(), None, density, cx).into_any_element(),
                    setting_row(l10n.desktop_ui_font_size(), None, text_size, cx)
                        .into_any_element(),
                ],
                cx,
            )
            .into_any_element(),
        ]
    }

    /// The phone's App Language page: the system's language, then each
    /// language the app speaks in its own name, the chosen one checked.
    fn language(&self, window: &mut Window, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let current = self.settings.read(cx).prefs.locale.clone();
        let system_locale = locale::resolve(&locale::system_languages());
        let system_label = l10n.desktop_language_system(locale::native_name(system_locale));
        let mut choices: Vec<(Option<String>, String)> = vec![(None, system_label)];
        choices.extend(
            LOCALES
                .iter()
                .map(|l| (Some(l.to_string()), locale::native_name(l).to_string())),
        );
        let count = choices.len();
        let selected = choices
            .iter()
            .position(|(code, _)| *code == current)
            .unwrap_or(0);
        // One key-view stop, as AppKit's radio groups: the chosen language,
        // whose arrows choose the next or the last.
        let codes: Vec<Option<String>> = choices.iter().map(|(code, _)| code.clone()).collect();
        let choose: SelectHandler = Rc::new(move |i, window, cx| {
            if let Some(code) = codes.get(i) {
                window.dispatch_action(
                    Box::new(SetLocale {
                        locale: code.clone(),
                    }),
                    cx,
                );
            }
        });
        let rows = choices
            .into_iter()
            .enumerate()
            .map(|(i, (code, label))| {
                let on = i == selected;
                div()
                    .id(radio_option_id("language", i, on))
                    .when(on, |d| d.keyboard_control(Ring::Inset(0.), window, cx))
                    .role(gpui_kit::Role::RadioButton)
                    .aria_label(SharedString::from(label.clone()))
                    .aria_selected(on)
                    .aria_position_in_set(i + 1)
                    .aria_size_of_set(count)
                    // The form spec's row (as every Settings row): 44 pt
                    // compact, 12 pt inset.
                    .w_full()
                    .h(px(m.row_height + 16.))
                    .px(px(12.))
                    .flex()
                    .items_center()
                    .cursor_pointer()
                    .hover(|s| s.bg(r.hover))
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(m.control))
                            .text_color(r.text)
                            .child(SharedString::from(label)),
                    )
                    .when(on, |d| {
                        d.child(conduit_components::assets::icon(
                            IconName::Check,
                            14.,
                            r.text,
                        ))
                    })
                    .on_click(move |_, window, cx| {
                        window.dispatch_action(
                            Box::new(SetLocale {
                                locale: code.clone(),
                            }),
                            cx,
                        )
                    })
                    .into_any_element()
            })
            .collect();
        vec![
            div()
                .id("language-group")
                .role(Role::RadioGroup)
                .aria_label(SharedString::from(l10n.app_language()))
                .radio_group(selected, count, Some(choose), cx)
                .child(settings_section(SharedString::default(), None, rows, cx))
                .into_any_element(),
        ]
    }

    /// Settings › Keyboard: every shortcut the app has, in the menus'
    /// groups. A rebindable command's chord sits in a field that records a
    /// new one when clicked (System Settings › Keyboard Shortcuts); a fixed
    /// one's is the same keycap, dimmed; Quick Ask's records here as in
    /// General.
    fn keyboard(&self, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let l10n = cx.l10n().clone();
        let store = self.settings.read(cx);
        let keymap = store.keymap();
        let recording = store.recording;
        let message = store.record_message.clone();
        let desktop = store.prefs.desktop.clone();
        let recording_quick_ask = store.recording_quick_ask;
        let quick_ask_message = store.quick_ask_message.clone();
        let mac = cfg!(target_os = "macos");
        let mut sections = vec![
            // What the keycaps do, once, above the groups (as System
            // Settings › Keyboard Shortcuts says it): how to change one, and
            // why the dimmed ones can't be.
            div()
                .flex()
                .flex_col()
                .gap(px(2.))
                .child(forms::group_footer(l10n.desktop_shortcut_record_help(), cx))
                .child(forms::group_footer(l10n.desktop_shortcut_fixed_note(), cx))
                .into_any_element(),
        ];
        for (group, rows_of) in keymap::keyboard_groups() {
            let mut rows = vec![];
            // The note under the group whose row is recording.
            let mut footer: Option<SharedString> = None;
            for row in rows_of {
                match row {
                    KeyRow::Rebindable(action) => {
                        let is_recording = recording == Some(action);
                        if is_recording && let Some(m) = &message {
                            footer = Some(record_message(m, &l10n).into());
                        }
                        rows.push(self.rebindable_row(action, &keymap, is_recording, cx));
                    }
                    KeyRow::Fixed(command) => {
                        let label = fixed_label(command, &l10n);
                        let keys = match command {
                            // One row for the eight: ⌘1–⌘8.
                            keymap::FixedCommand::GoToSection(_) => format!(
                                "{}\u{2013}{}",
                                describe(
                                    &keymap::fixed_stroke(keymap::FixedCommand::GoToSection(1)),
                                    mac
                                ),
                                describe(
                                    &keymap::fixed_stroke(keymap::FixedCommand::GoToSection(
                                        crate::actions::GO_SECTIONS as u8
                                    )),
                                    mac
                                ),
                            ),
                            _ => describe(&keymap::fixed_stroke(command), mac),
                        };
                        rows.push(
                            setting_row(label.clone(), None, fixed_keys(command, keys, label), cx)
                                .into_any_element(),
                        );
                    }
                    KeyRow::Area(key) => {
                        let label = area_key_label(key, &l10n);
                        let keys = describe(&keymap::area_stroke(key), mac);
                        let field = ShortcutField::new(
                            SharedString::from(format!("area-{key:?}")),
                            keys,
                            label.clone(),
                            SharedString::default(),
                        )
                        .fixed(true);
                        rows.push(setting_row(label, None, field, cx).into_any_element());
                    }
                    KeyRow::QuickAsk => {
                        if recording_quick_ask && let Some(m) = &quick_ask_message {
                            footer = Some(record_message(m, &l10n).into());
                        } else if !desktop.quick_ask {
                            footer = Some(l10n.desktop_keyboard_quick_ask_off().into());
                        }
                        let control = self.quick_ask_shortcut(&desktop, recording_quick_ask, cx);
                        rows.push(
                            setting_row(l10n.desktop_quick_ask_title(), None, control, cx)
                                .into_any_element(),
                        );
                    }
                }
            }
            let title = match group {
                KeyGroup::Chats => l10n.desktop_keyboard_chats(),
                KeyGroup::Messages => l10n.desktop_keyboard_messages(),
                KeyGroup::FindAndView => l10n.desktop_keyboard_find_and_view(),
                KeyGroup::Go => l10n.desktop_menu_go(),
                KeyGroup::Window => l10n.desktop_menu_window(),
                KeyGroup::Notes => l10n.sidebar_notes_tab(),
                KeyGroup::Workspace => l10n.workspace_title(),
                KeyGroup::Calendar => l10n.calendar_title(),
                KeyGroup::ScheduledTasks => l10n.scheduled_tasks_title(),
                KeyGroup::Terminal => l10n.terminal(),
                KeyGroup::HermesRooms => l10n.hermes_rooms_title(),
                KeyGroup::HermesJobs => l10n.hermes_scheduled_agents_title(),
            };
            // Where these keys work, under the areas' own groups.
            let footer = footer.or_else(|| match group {
                KeyGroup::Notes => Some(l10n.desktop_keyboard_notes_footer().into()),
                KeyGroup::Workspace => Some(l10n.desktop_keyboard_workspace_footer().into()),
                KeyGroup::Calendar => Some(l10n.desktop_keyboard_calendar_footer().into()),
                KeyGroup::ScheduledTasks => Some(l10n.desktop_keyboard_tasks_footer().into()),
                // And the way out of it, whose Tab is the shell's.
                KeyGroup::Terminal => {
                    let (next, _) = crate::views::terminal::console::leave_keys();
                    Some(
                        join_sentences(
                            &l10n.desktop_keyboard_terminal_footer(),
                            &l10n.desktop_terminal_leave_hint(&next),
                        )
                        .into(),
                    )
                }
                KeyGroup::HermesRooms => Some(l10n.desktop_keyboard_rooms_footer().into()),
                KeyGroup::HermesJobs => Some(l10n.desktop_keyboard_hermes_jobs_footer().into()),
                _ => None,
            });
            sections.push(settings_section(title, footer, rows, cx).into_any_element());
        }
        // The terminal's Option key: Meta, or the character it types.
        let meta = desktop.terminal_option_as_meta;
        let settings = self.settings.clone();
        let meta_switch = Switch::new(
            "terminal-option-as-meta",
            l10n.desktop_terminal_option_as_meta(),
            meta,
        )
        .on_click(Rc::new(move |_, _, cx| {
            settings.update(cx, |s, cx| {
                s.set_desktop(|d| d.terminal_option_as_meta = !meta, cx)
            });
        }));
        sections.push(
            settings_section(
                l10n.terminal(),
                Some(l10n.desktop_terminal_option_as_meta_footer().into()),
                vec![
                    setting_row(
                        l10n.desktop_terminal_option_as_meta(),
                        None,
                        meta_switch,
                        cx,
                    )
                    .into_any_element(),
                ],
                cx,
            )
            .into_any_element(),
        );
        let s = self.settings.clone();
        sections.push(
            div()
                .flex()
                .justify_end()
                .child(
                    Button::new("reset-all-shortcuts", l10n.desktop_shortcut_reset_all())
                        .disabled(keymap.overrides.is_empty())
                        .on_click(Rc::new(move |_, _, cx| {
                            s.update(cx, |s, cx| s.reset_all_shortcuts(cx))
                        })),
                )
                .into_any_element(),
        );
        sections
    }

    /// A rebindable command's row: its chord in a recorder field, and a
    /// reset button once it differs from the default.
    fn rebindable_row(
        &self,
        action: ShortcutAction,
        keymap: &keymap::Keymap,
        is_recording: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let l10n = cx.l10n().clone();
        let mac = cfg!(target_os = "macos");
        let stroke = keymap.stroke(action);
        let overridden = keymap.overrides.contains_key(action.name());
        let label = shortcut_label(action, &l10n);
        let s = self.settings.clone();
        let mut trailing = div().flex().items_center().gap(px(6.));
        if overridden && !is_recording {
            let s = self.settings.clone();
            trailing = trailing.child(
                IconButton::new(
                    SharedString::from(format!("reset-{}", action.name())),
                    IconName::RotateCcw,
                    l10n.desktop_shortcut_reset_to_default(),
                )
                .size(24., 13.)
                .on_click(Rc::new(move |_, _, cx| {
                    s.update(cx, |s, cx| s.reset_shortcut(action, cx))
                })),
            );
        }
        trailing = trailing.child(
            ShortcutField::new(
                SharedString::from(format!("change-{}", action.name())),
                describe(&stroke, mac),
                l10n.desktop_shortcut_change_label(&label),
                l10n.desktop_shortcut_type_shortcut(),
            )
            .recording(is_recording)
            .on_click(Rc::new(move |_, _, cx| {
                s.update(cx, |s, cx| {
                    let next = if s.recording == Some(action) {
                        None
                    } else {
                        Some(action)
                    };
                    s.record_for(next, cx)
                })
            })),
        );
        setting_row(label, None, trailing, cx).into_any_element()
    }

    /// Quick Ask's chord: a recorder (off while Quick Ask is), and a reset
    /// once it differs from ⇧⌘Space. General and Keyboard both show it.
    fn quick_ask_shortcut(
        &self,
        prefs: &crate::prefs::DesktopPrefs,
        recording: bool,
        cx: &mut Context<Self>,
    ) -> gpui_kit::Div {
        let l10n = cx.l10n().clone();
        let mac = cfg!(target_os = "macos");
        let stroke = prefs.quick_ask_stroke();
        let mut control = div().flex().items_center().gap(px(6.));
        if prefs.quick_ask_shortcut != DEFAULT_QUICK_ASK_SHORTCUT && !recording {
            let settings = self.settings.clone();
            control = control.child(
                IconButton::new(
                    "reset-quick-ask",
                    IconName::RotateCcw,
                    l10n.desktop_shortcut_reset_to_default(),
                )
                .size(24., 13.)
                .on_click(Rc::new(move |_, _, cx| {
                    settings.update(cx, |s, cx| s.reset_quick_ask_shortcut(cx))
                })),
            );
        }
        let settings = self.settings.clone();
        control.child(
            ShortcutField::new(
                "change-quick-ask",
                describe(&stroke, mac),
                l10n.desktop_shortcut_change_label(&l10n.desktop_quick_ask_title()),
                l10n.desktop_shortcut_type_shortcut(),
            )
            .recording(recording)
            .disabled(!prefs.quick_ask)
            .on_click(Rc::new(move |_, _, cx| {
                settings.update(cx, |s, cx| {
                    let next = !s.recording_quick_ask;
                    s.record_quick_ask(next, cx)
                })
            })),
        )
    }

    fn about(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        // The version as System Settings' About shows it: "1.2.0 (345)", or
        // only the version where no build number was stamped in.
        let version = match crate::BUILD {
            Some(build) => format!("{} ({build})", crate::VERSION),
            None => crate::VERSION.to_string(),
        };
        // What only a developer or a bug report needs is in Data ›
        // Diagnostics, beside the report itself.
        if self.about_info.is_none() {
            self.fetch_about(window, cx);
        }
        let mut out = vec![
            about_header(
                &l10n.app_title(),
                &l10n.desktop_about_version_line(&version),
                window.scale_factor(),
                &t,
            )
            .into_any_element(),
        ];
        out.extend(self.about_sections(cx));
        out.push(self.updates_section(cx));
        out
    }

    fn fetch_about(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // One fetch per window; a placeholder stops a second.
        self.about_info = Some(conduit_protocol::AboutInfo::default());
        let round = self.about_round;
        let call = self
            .connection
            .read(cx)
            .rpc()
            .call::<conduit_protocol::methods::SettingsAbout>(&conduit_protocol::NoParams);
        cx.spawn_in(
            window,
            async move |this, cx: &mut gpui_kit::AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s: &mut Self, cx| {
                    if s.about_round != round {
                        return;
                    }
                    match result {
                        Ok(info) => s.about_info = Some(info),
                        Err(e) => {
                            log::warn!("settings.about: {e}");
                            s.about_failed = true;
                        }
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// About's server rows, What's New and the links, and Support Conduit.
    fn about_sections(&self, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let l10n = cx.l10n().clone();
        let info = self.about_info.clone().unwrap_or_default();
        let mut out = vec![];
        if info.server {
            let value =
                |v: Option<String>| controls::value(v.unwrap_or_else(|| "\u{2014}".into()), cx);
            let mut rows = vec![
                setting_row(
                    l10n.server_name_label(),
                    None,
                    value(info.server_name.clone().map(|n| privacy::host(&n, cx))),
                    cx,
                )
                .into_any_element(),
                setting_row(
                    l10n.server_version_label(),
                    None,
                    value(info.server_version.clone()),
                    cx,
                )
                .into_any_element(),
            ];
            if info.latest_version.is_some() {
                rows.push(
                    setting_row(
                        l10n.latest_version_label(),
                        None,
                        value(info.latest_version.clone()),
                        cx,
                    )
                    .into_any_element(),
                );
            }
            let unavailable = info.server_version.is_none() && info.server_name.is_none();
            out.push(
                settings_section(
                    l10n.server_information(),
                    unavailable.then(|| l10n.server_info_unavailable().into()),
                    rows,
                    cx,
                )
                .into_any_element(),
            );
        }
        let link = |id: &'static str,
                    icon: IconName,
                    title: String,
                    subtitle: Option<String>,
                    url: String| {
            conduit_components::views::kit::nav_row(
                id,
                icon,
                title.into(),
                subtitle.map(SharedString::from),
                cx,
            )
            .on_click(move |_, _, cx| {
                if !url.is_empty() {
                    cx.open_url(&url);
                }
            })
            .into_any_element()
        };
        let whats_new = conduit_components::views::kit::nav_row(
            "about-whats-new",
            IconName::Megaphone,
            l10n.release_notes_title().into(),
            None,
            cx,
        )
        .on_click(|_, window, cx| crate::views::release_notes::show_latest(window, cx))
        .into_any_element();
        out.push(
            settings_section(
                SharedString::default(),
                None,
                vec![
                    whats_new,
                    link(
                        "about-repository",
                        IconName::Github,
                        l10n.github_repository(),
                        Some("github.com/cogwheel0/conduit".into()),
                        info.repository_url.clone(),
                    ),
                    link(
                        "about-licenses",
                        IconName::ScrollText,
                        l10n.open_source_licenses(),
                        None,
                        licenses_url(&info.repository_url),
                    ),
                ],
                cx,
            )
            .into_any_element(),
        );
        out.push(
            settings_section(
                l10n.support_conduit(),
                Some(l10n.support_conduit_subtitle().into()),
                vec![
                    link(
                        "about-coffee",
                        IconName::Coffee,
                        l10n.buy_me_a_coffee_title(),
                        Some(l10n.buy_me_a_coffee_subtitle()),
                        info.buy_me_a_coffee_url.clone(),
                    ),
                    link(
                        "about-sponsors",
                        IconName::Heart,
                        l10n.github_sponsors_title(),
                        Some(l10n.github_sponsors_subtitle()),
                        info.github_sponsors_url.clone(),
                    ),
                ],
                cx,
            )
            .into_any_element(),
        );
        out
    }

    /// About › Updates: Sparkle's check and "check automatically" (release
    /// bundles only). Releases are stable only, so there is no channel to
    /// pick.
    fn updates_section(&self, cx: &mut Context<Self>) -> AnyElement {
        let l10n = cx.l10n().clone();
        let available = crate::updates::available(cx);
        let mut rows = vec![];
        // The row names the subject, the button keeps the verb.
        let check = Button::new("check-for-updates", l10n.desktop_check_now())
            .disabled(!crate::updates::can_check(cx))
            .on_click(Rc::new(|_, _, cx| crate::updates::check_for_updates(cx)));
        rows.push(
            setting_row(
                l10n.desktop_software_update(),
                (!available).then(|| l10n.desktop_updates_unavailable().into()),
                check,
                cx,
            )
            .into_any_element(),
        );
        if let Some(on) = crate::updates::automatic_checks(cx) {
            // Sparkle keeps this one; redraw to show what it now says.
            let view = cx.entity().downgrade();
            let auto = Switch::new(
                "automatic-update-checks",
                l10n.desktop_automatic_update_checks(),
                on,
            )
            .on_click(Rc::new(move |_, _, cx| {
                crate::updates::set_automatic_checks(!on, cx);
                view.update(cx, |_, cx| cx.notify()).ok();
            }));
            rows.push(
                setting_row(l10n.desktop_automatic_update_checks(), None, auto, cx)
                    .into_any_element(),
            );
        }
        settings_section(l10n.desktop_updates_section(), None, rows, cx).into_any_element()
    }

    fn accounts(&self, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let l10n = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let add = Rc::new(
            move |_: &gpui_kit::ClickEvent, window: &mut Window, cx: &mut App| {
                let _ = view.update(cx, |v, cx| v.open_add_sheet(window, cx));
            },
        );
        let more = {
            let stores = self.stores.clone();
            Rc::new(move |id: &str, window: &mut Window, cx: &mut App| {
                // An Open WebUI account, or a LibreChat one.
                let name = {
                    let store = stores.accounts.read(cx);
                    store
                        .accounts()
                        .iter()
                        .find(|a| a.id == id)
                        .map(crate::stores::accounts::display_name)
                        .or_else(|| {
                            store
                                .libre_chat_accounts()
                                .iter()
                                .find(|a| a.id == id)
                                .map(crate::stores::accounts::libre_chat_display_name)
                        })
                };
                let Some(name) = name else {
                    return;
                };
                // An Open WebUI account's server has a sheet of its own.
                let server = stores
                    .accounts
                    .read(cx)
                    .accounts()
                    .iter()
                    .find(|a| a.id == id)
                    .map(|a| a.server_id.clone());
                let l10n = cx.l10n().clone();
                let name = privacy::name(&name, cx);
                let mut menu = NativeMenu::new();
                if let Some(server_id) = server {
                    menu = menu
                        .menu(
                            l10n.desktop_server_settings_ellipsis(),
                            Box::new(SettingsChoice {
                                menu: SERVER_SETTINGS_MENU.into(),
                                value: server_id,
                            }),
                        )
                        .separator();
                }
                menu.menu(
                    l10n.desktop_sign_out_of(&name),
                    Box::new(RemoveAccount {
                        account_id: id.to_string(),
                    }),
                )
                .show(window.mouse_position(), window, cx);
            })
        };
        let mut sections = accounts_sections(&self.stores, add, more, cx).into_iter();
        let list = sections.next().unwrap_or_else(|| div().into_any_element());
        let footer = self
            .stores
            .accounts
            .read(cx)
            .notice
            .as_ref()
            // Only failures stay here; the rest were toasts.
            .filter(|n| matches!(n, crate::stores::accounts::AccountNotice::Failed { .. }))
            .and_then(|n| crate::views::words::account_notice(&privacy::notice(n, cx), &l10n))
            .map(|(_, text)| SharedString::from(text));
        // The page is titled Accounts: the list needs no second heading.
        let mut out = vec![
            settings_section(SharedString::default(), footer, vec![list], cx).into_any_element(),
        ];
        out.extend(sections);
        out.extend(self.servers_section(cx));
        out.extend(self.sign_out_section(cx));
        out
    }

    /// Accounts › Servers: each saved Open WebUI server, opening its sheet
    /// (as the phone's Accounts page heads each server's accounts with a
    /// row to its page).
    fn servers_section(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let r = t.roles;
        let store = self.stores.accounts.read(cx);
        // One row per server, in the order its first account is listed;
        // its address in use is the active account's (else the first's).
        let mut servers: Vec<(String, String, String)> = vec![];
        for a in store.accounts() {
            match servers.iter_mut().find(|(id, _, _)| *id == a.server_id) {
                Some(row) if a.is_active => row.2 = a.connection.url.clone(),
                Some(_) => {}
                None => servers.push((
                    a.server_id.clone(),
                    a.connection.name.clone(),
                    a.connection.url.clone(),
                )),
            }
        }
        if servers.is_empty() {
            return None;
        }
        let hover = r.hover;
        let pressed = conduit_components::views::focus::pressed_fill(r.hover, &t);
        let rows: Vec<AnyElement> = servers
            .into_iter()
            .enumerate()
            .map(|(i, (id, name, url))| {
                let view = cx.entity().downgrade();
                let name = privacy::name(&name, cx);
                let host = privacy::host(&forms::host_of(&url), cx);
                div()
                    .id(SharedString::from(format!("server-row-{i}")))
                    .role(Role::Button)
                    // With the host the row shows: two servers of one
                    // name are told apart.
                    .aria_label(SharedString::from(
                        [
                            name.clone(),
                            host.clone(),
                            l10n.desktop_server_settings_ellipsis(),
                        ]
                        .into_iter()
                        .filter(|part| !part.trim().is_empty())
                        .collect::<Vec<_>>()
                        .join(", "),
                    ))
                    .w_full()
                    .px(px(12.))
                    .py(px(9.))
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .cursor_pointer()
                    .hover(move |s| s.bg(hover))
                    .active(move |s| s.bg(pressed))
                    .when(i > 0, |d| d.border_t_1().border_color(r.divider))
                    .keyboard_shadow(cx)
                    .tip(l10n.desktop_server_settings_ellipsis(), None)
                    .on_click(move |_, window, cx| {
                        let _ = view.update(cx, |v, cx| v.open_server(&id, window, cx));
                    })
                    .child(conduit_components::assets::icon(
                        IconName::Server,
                        15.,
                        r.text_subtle,
                    ))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap(px(1.))
                            .child(
                                div()
                                    .truncate()
                                    .text_size(px(t.metrics.control))
                                    .font_weight(FontWeight::MEDIUM)
                                    .text_color(r.text)
                                    .child(name),
                            )
                            .child(
                                div()
                                    .truncate()
                                    .text_size(px(t.metrics.small))
                                    .text_color(r.text_subtle)
                                    .child(host),
                            ),
                    )
                    .child(conduit_components::assets::icon(
                        IconName::ChevronRight,
                        13.,
                        r.text_faint,
                    ))
                    .into_any_element()
            })
            .collect();
        Some(
            settings_section(
                l10n.desktop_servers_section(),
                None,
                vec![grouped(rows, cx).into_any_element()],
                cx,
            )
            .into_any_element(),
        )
    }

    /// Accounts › Sign Out, as the phone's Settings ends: the account in
    /// use, and with more than one, every account.
    fn sign_out_section(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l10n = cx.l10n().clone();
        let accounts = self.stores.accounts.read(cx);
        let active = accounts.active()?.clone();
        let several = accounts.accounts().len() > 1;
        let name = privacy::name(&crate::stores::accounts::display_name(&active), cx);
        let mut buttons = vec![];
        if several {
            let view = cx.entity().downgrade();
            buttons.push(
                Button::new("sign-out-all", l10n.desktop_sign_out_all_ellipsis())
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = view.update(cx, |v, cx| v.sign_out_all(window, cx));
                    }))
                    .into_any_element(),
            );
        }
        let id = active.id.clone();
        buttons.push(
            Button::new(
                "sign-out-active",
                if several {
                    l10n.desktop_sign_out_of(&name)
                } else {
                    l10n.desktop_sign_out_ellipsis()
                },
            )
            .danger()
            .on_click(Rc::new(move |_, window, cx| {
                window.dispatch_action(
                    Box::new(RemoveAccount {
                        account_id: id.clone(),
                    }),
                    cx,
                );
            }))
            .into_any_element(),
        );
        Some(
            div()
                .flex()
                .flex_col()
                .gap(px(8.))
                .child(forms::group_footer(
                    if several {
                        l10n.accounts_sign_out_confirm_message()
                    } else {
                        l10n.desktop_sign_out_last_footer()
                    },
                    cx,
                ))
                .child(div().flex().justify_end().gap(px(8.)).children(buttons))
                .into_any_element(),
        )
    }

    /// Sign Out of All Accounts…: asks, then signs out of each (asking
    /// again when an answer is still being written).
    pub fn sign_out_all(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let l10n = cx.l10n().clone();
        let spec = SheetSpec::new(
            l10n.desktop_sign_out_all_title(),
            l10n.desktop_sign_out_all_message(),
            l10n.accounts_sign_out_all(),
            l10n.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        let rpc = self.connection.read(cx).rpc();
        let accounts = self.stores.accounts.clone();
        cx.spawn_in(
            window,
            async move |_, cx: &mut gpui_kit::AsyncWindowContext| {
                if !ask.await {
                    return;
                }
                let mut force = false;
                loop {
                    let result = rpc
                        .call::<conduit_protocol::methods::ProfileSignOutAll>(
                            &conduit_protocol::SignOutAll { force },
                        )
                        .await;
                    match result {
                        Ok(r)
                            if r.outcome
                                == conduit_protocol::AccountChangeOutcome::BlockedByActiveReply
                                && !force =>
                        {
                            let again = cx.update(|window, cx| {
                                let l10n = cx.l10n().clone();
                                present_sheet(
                                    window,
                                    SheetSpec::new(
                                        l10n.desktop_reply_in_progress(),
                                        l10n.desktop_sign_out_all_message(),
                                        l10n.desktop_sign_out_anyway(),
                                        l10n.cancel(),
                                    )
                                    .destructive(),
                                    cx,
                                )
                            });
                            let Ok(task) = again else { return };
                            if !task.await {
                                return;
                            }
                            force = true;
                        }
                        Ok(_) => break,
                        Err(e) => {
                            log::warn!("profile.signOutAll: {e}");
                            break;
                        }
                    }
                }
                let _ = cx.update(|_, cx| accounts.update(cx, |a, cx| a.refresh(cx)));
            },
        )
        .detach();
    }

    fn direct(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Vec<AnyElement> {
        // The pane draws its own groups at the page's inset, as every
        // other page's groups are, not inside another card.
        vec![self.direct_pane(window, cx).into_any_element()]
    }

    /// Settings › Direct Connections, made once.
    pub fn direct_pane(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<DirectPane> {
        let stores = self.stores.clone();
        self.direct
            .get_or_insert_with(|| cx.new(|cx| DirectPane::new(stores, window, cx)))
            .clone()
    }

    /// Settings › Hermes ([`hermes`]): the switch, the connections, and
    /// the connection in use's status, schedules, catalog and MCP servers.
    fn hermes(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Vec<AnyElement> {
        hermes::sections(&self.stores, window, cx)
    }

    fn desktop(&self, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let l10n = cx.l10n().clone();
        let store = self.settings.read(cx);
        let prefs = store.prefs.desktop.clone();
        let recording = store.recording_quick_ask;
        let message = store.quick_ask_message.clone();
        let shell = cx
            .try_global::<Desktop>()
            .map(|d| d.shell.read(cx))
            .map(|s| (s.hotkey, s.notifications, s.login, s.login_error.clone()))
            .unwrap_or_default();
        let (hotkey, _, login, login_error) = shell;
        let settings = self.settings.clone();
        let toggle = |id: &'static str,
                      label: String,
                      on: bool,
                      edit: fn(&mut crate::prefs::DesktopPrefs, bool)| {
            let settings = settings.clone();
            Switch::new(id, label, on).on_click(Rc::new(move |_, _, cx| {
                settings.update(cx, |s, cx| s.set_desktop(|d| edit(d, !on), cx));
            }))
        };

        // Menu bar and open at login.
        let close = toggle(
            "close-to-menu-bar",
            l10n.desktop_close_to_menu_bar(),
            prefs.close_to_menu_bar,
            |d, on| d.close_to_menu_bar = on,
        );
        let login_on = login.is_on();
        // macOS can't register this copy (it isn't in Applications), or the
        // last change failed: the switch can't work, so it says why
        // instead of flipping back.
        let login_unavailable = login == LoginState::NotFound || login_error.is_some();
        let login_switch = Switch::new("launch-at-login", l10n.desktop_launch_at_login(), login_on)
            .disabled(login_unavailable)
            .on_click(Rc::new(move |_, _, cx| {
                crate::desktop::set_launch_at_login(!login_on, cx)
            }));
        let login_hint: SharedString = match (login, &login_error) {
            // A fixed sentence; the reason went to the log when it failed.
            (_, Some(_)) => l10n.desktop_login_item_failed().into(),
            (LoginState::NeedsApproval, _) => l10n.desktop_login_item_needs_approval().into(),
            (LoginState::NotFound, _) => l10n.desktop_login_item_not_found().into(),
            _ => l10n.desktop_launch_at_login_hint().into(),
        };
        let login_control = div()
            .flex()
            .items_center()
            .gap(px(8.))
            .when(login == LoginState::NeedsApproval, |d| {
                d.child(
                    Button::new("login-items-settings", l10n.desktop_open_system_settings())
                        .ghost()
                        .on_click(Rc::new(|_, _, _| {
                            crate::desktop::open_login_items_settings()
                        })),
                )
            })
            .child(login_switch);

        // Quick Ask.
        let quick = toggle(
            "quick-ask",
            l10n.desktop_quick_ask_enabled(),
            prefs.quick_ask,
            |d, on| d.quick_ask = on,
        );
        let shortcut_control = self.quick_ask_shortcut(&prefs, recording, cx);
        let shortcut_note: Option<SharedString> = match (&message, hotkey) {
            (Some(m), _) => Some(record_message(m, &l10n).into()),
            (None, HotkeyState::Taken) if prefs.quick_ask => {
                Some(l10n.desktop_quick_ask_shortcut_taken().into())
            }
            (None, HotkeyState::Invalid) if prefs.quick_ask => {
                Some(l10n.desktop_quick_ask_shortcut_unsupported().into())
            }
            (None, HotkeyState::Unavailable) if prefs.quick_ask => {
                Some(l10n.desktop_quick_ask_shortcut_unavailable().into())
            }
            _ => None,
        };

        vec![
            settings_section(
                l10n.desktop_menu_bar_section(),
                None,
                vec![
                    setting_row(
                        l10n.desktop_close_to_menu_bar(),
                        Some(l10n.desktop_close_to_menu_bar_description().into()),
                        close,
                        cx,
                    )
                    .into_any_element(),
                    if login_unavailable {
                        warning_row(
                            l10n.desktop_launch_at_login(),
                            login_hint,
                            login_control,
                            cx,
                        )
                        .into_any_element()
                    } else {
                        setting_row(
                            l10n.desktop_launch_at_login(),
                            Some(login_hint),
                            login_control,
                            cx,
                        )
                        .into_any_element()
                    },
                ],
                cx,
            )
            .into_any_element(),
            settings_section(
                l10n.desktop_quick_ask_title(),
                shortcut_note,
                vec![
                    setting_row(l10n.desktop_quick_ask_enabled(), None, quick, cx)
                        .into_any_element(),
                    setting_row(
                        l10n.desktop_quick_ask_shortcut(),
                        None,
                        shortcut_control,
                        cx,
                    )
                    .into_any_element(),
                ],
                cx,
            )
            .into_any_element(),
        ]
    }

    /// Data: what the app keeps on this Mac (clear it) and the report a bug
    /// needs (export it). Signing out lives in Accounts, once.
    fn data(&self, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let conn = self.connection.read(cx);
        let handshake = conn.handshake.clone();
        let paths = conn.paths().clone();
        let value = |v: String| {
            div()
                .max_w(px(360.))
                .truncate()
                .text_size(px(t.metrics.control))
                .text_color(t.roles.text_subtle)
                .child(v)
        };
        let path = |p: &std::path::Path| {
            let full = home_relative(p);
            div()
                .text_size(px(t.metrics.control))
                .text_color(t.roles.text_subtle)
                .child(middle_truncate(&full, 44))
        };
        let can_clear = conn.can_clear();
        let connected = conn.is_connected();
        let exporting = conn.diagnostics == crate::stores::connection::Diagnostics::Exporting;
        let state = diagnostics_state(&conn.diagnostics, cx);
        let export = {
            let connection = self.connection.clone();
            Rc::new(
                move |_: &gpui_kit::ClickEvent, _: &mut Window, cx: &mut App| {
                    connection.update(cx, |c, cx| c.export_diagnostics(cx))
                },
            )
        };
        let clear = {
            let connection = self.connection.clone();
            Rc::new(
                move |_: &gpui_kit::ClickEvent, window: &mut Window, cx: &mut App| {
                    let l10n = cx.l10n().clone();
                    let spec = SheetSpec::new(
                        l10n.desktop_clear_local_data_confirm_title(),
                        l10n.desktop_clear_local_data_confirm_body(),
                        l10n.desktop_clear_local_data_confirm(),
                        l10n.cancel(),
                    )
                    .destructive();
                    let ask = present_sheet(window, spec, cx);
                    let connection = connection.clone();
                    cx.spawn(async move |cx| {
                        if ask.await {
                            connection.update(cx, |c, cx| c.clear_local_data(cx));
                        }
                    })
                    .detach();
                },
            )
        };
        // Each row names its subject, its button the verb.
        vec![
            settings_section(
                SharedString::default(),
                None,
                vec![
                    setting_row(
                        l10n.desktop_local_data(),
                        Some(l10n.desktop_clear_local_data_hint().into()),
                        Button::new("clear-local-data", l10n.desktop_clear_ellipsis())
                            .danger()
                            .disabled(!can_clear)
                            .on_click(clear),
                        cx,
                    )
                    .into_any_element(),
                ],
                cx,
            )
            .into_any_element(),
            // Everything a bug report needs in one group: the report, and
            // the versions and folders it describes.
            settings_section(
                l10n.desktop_diagnostics(),
                None,
                vec![
                    // The row names what is made; the button, what it does.
                    setting_row(
                        l10n.desktop_diagnostic_report(),
                        Some(
                            state.unwrap_or_else(|| l10n.desktop_export_diagnostics_hint().into()),
                        ),
                        Button::new("export-diagnostics", l10n.desktop_export_ellipsis())
                            .icon(IconName::Download)
                            .disabled(!connected || exporting)
                            .on_click(export),
                        cx,
                    )
                    .into_any_element(),
                    // "Background Service Version  1.4.2 (1.56.0)": the protocol in
                    // parentheses, as About This Mac shows a build.
                    setting_row(
                        l10n.desktop_about_daemon(),
                        None,
                        value(helper_version(
                            handshake.as_ref().map(|h| h.daemon_version.as_str()),
                            conduit_protocol::PROTOCOL_VERSION,
                        )),
                        cx,
                    )
                    .into_any_element(),
                    setting_row(
                        l10n.desktop_about_user_data(),
                        None,
                        path(&paths.user_data),
                        cx,
                    )
                    .into_any_element(),
                    setting_row(l10n.desktop_about_logs(), None, path(&paths.logs), cx)
                        .into_any_element(),
                ],
                cx,
            )
            .into_any_element(),
        ]
    }
}

/// The open-source notices: the copy this bundle carries, or, for a build
/// that has none (a dev build), the repository's page on how they are made.
fn licenses_url(repository: &str) -> String {
    let bundled = std::env::current_exe()
        .ok()
        .and_then(|exe| {
            exe.parent()
                .map(|d| d.join("../Resources/THIRD_PARTY_NOTICES.md"))
        })
        .filter(|p| p.is_file());
    match bundled.and_then(|p| p.canonicalize().ok()) {
        Some(path) => format!("file://{}", path.display()),
        None if !repository.is_empty() => {
            format!("{repository}/blob/main/desktop/packaging/notices/README.md")
        }
        None => String::new(),
    }
}

/// The copyright line of the About header: the first sentence of the
/// bundle's `NSHumanReadableCopyright` (packaging/macos/Info.plist), which
/// the standard About panel shows. Legal text, so not translated.
pub const COPYRIGHT: &str = "Copyright © 2026 Tunap Paul.";

/// The app's icon for the About header, at 1x and 2x (64 pt drawn).
const APP_ICON_1X: &[u8] = include_bytes!("../../assets/about/app-icon-128.png");
const APP_ICON_2X: &[u8] = include_bytes!("../../assets/about/app-icon-256.png");

/// The size the About header draws the icon at.
pub const ABOUT_ICON: f32 = 64.;

/// About's header, as a Mac app's About window: the icon, the name, the
/// version and the copyright, centred over the pane's groups.
fn about_header(
    name: &str,
    version: &str,
    scale: f32,
    t: &conduit_components::theme::ConduitTheme,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    use std::sync::{Arc, OnceLock};
    static ICONS: OnceLock<[Arc<gpui_kit::Image>; 2]> = OnceLock::new();
    let icons = ICONS.get_or_init(|| {
        [APP_ICON_1X, APP_ICON_2X].map(|b| {
            Arc::new(gpui_kit::Image::from_bytes(
                gpui_kit::ImageFormat::Png,
                b.to_vec(),
            ))
        })
    });
    // The smaller copy on a 1x display, so it is drawn near its own size.
    let icon = icons[usize::from(scale > 1.5)].clone();
    let r = t.roles;
    let m = t.metrics;
    div()
        .id("about-header")
        .w_full()
        .pt(px(8.))
        .pb(px(4.))
        .flex()
        .flex_col()
        .items_center()
        .gap(px(4.))
        .child(
            gpui_kit::img(gpui_kit::ImageSource::Image(icon))
                .size(px(ABOUT_ICON))
                .mb(px(6.)),
        )
        .child(
            div()
                .id("about-name")
                .role(Role::Heading)
                .text_size(px(m.control + 7.))
                .font_weight(gpui_kit::FontWeight::BOLD)
                .text_color(r.text)
                .child(SharedString::from(name.to_string())),
        )
        .child(
            div()
                .text_size(px(m.control))
                .text_color(r.text_subtle)
                .child(SharedString::from(version.to_string())),
        )
        .child(
            div()
                .text_size(px(m.small))
                .text_color(r.text_subtle)
                .child(SharedString::from(COPYRIGHT)),
        )
}

/// Why a recorded chord was not taken.
/// The account's card atop the Settings list, as the phone's Settings
/// opens: its monogram, name and email (or server).
fn profile_card(
    account: &conduit_components::views::model::Account,
    t: &conduit_components::theme::ConduitTheme,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    let r = t.roles;
    let m = t.metrics;
    let subtitle = if account.email.is_empty() {
        account.server.clone()
    } else {
        account.email.clone()
    };
    div()
        .id("settings-profile")
        .role(gpui_kit::Role::Button)
        .aria_label(account.name.clone())
        .when(!subtitle.is_empty(), |d| {
            d.aria_description(subtitle.clone())
        })
        .w_full()
        .p(px(8.))
        .flex()
        .items_center()
        .gap(px(10.))
        .rounded(px(10.))
        .cursor_pointer()
        .hover(|s| s.bg(r.hover))
        .active(|s| s.bg(conduit_components::views::focus::pressed_fill(r.hover, t)))
        .child(conduit_components::views::sidebar::monogram(
            &account.initials(),
            36.,
            t,
        ))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .child(
                    div()
                        .truncate()
                        .text_size(px(m.control))
                        .font_weight(gpui_kit::FontWeight::SEMIBOLD)
                        .text_color(r.sidebar_text)
                        .child(account.name.clone()),
                )
                .when(!subtitle.is_empty(), |d| {
                    d.child(
                        div()
                            .truncate()
                            .text_size(px(m.small))
                            .text_color(r.sidebar_text_subtle)
                            .child(subtitle),
                    )
                }),
        )
}

fn record_message(m: &RecordMessage, l10n: &L10n) -> String {
    let mac = cfg!(target_os = "macos");
    match m {
        RecordMessage::NeedsModifier => l10n.desktop_shortcut_needs_modifier(),
        RecordMessage::Conflict { stroke, other } => {
            l10n.desktop_shortcut_conflict(&describe(stroke, mac), &shortcut_label(*other, l10n))
        }
        RecordMessage::ConflictQuickAsk { stroke } => {
            l10n.desktop_shortcut_conflict(&describe(stroke, mac), &l10n.desktop_quick_ask_title())
        }
        RecordMessage::ConflictFixed { stroke, command } => {
            l10n.desktop_shortcut_conflict(&describe(stroke, mac), &fixed_label(*command, l10n))
        }
    }
}

/// The helper's version with the protocol it speaks as its build:
/// "1.4.2 (1.56.0)", or "— (1.56.0)" before the helper has answered.
pub fn helper_version(daemon: Option<&str>, protocol: &str) -> String {
    let daemon = daemon
        .filter(|v| !v.trim().is_empty())
        .unwrap_or("\u{2014}");
    format!("{daemon} ({protocol})")
}

/// `text` cut in the middle to at most `max` characters, keeping the start
/// and more of the end (a path's last folders say most).
pub fn middle_truncate(text: &str, max: usize) -> String {
    let chars: Vec<char> = text.chars().collect();
    if chars.len() <= max || max < 5 {
        return text.to_string();
    }
    let head = (max - 1) * 2 / 5;
    let tail = max - 1 - head;
    let mut out: String = chars[..head].iter().collect();
    out.push('\u{2026}');
    out.extend(&chars[chars.len() - tail..]);
    out
}

fn home_relative(path: &std::path::Path) -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let p = path.to_string_lossy().to_string();
    match p.strip_prefix(&home) {
        Some(rest) if !home.is_empty() => format!("~{rest}"),
        _ => p,
    }
}

impl Focusable for SettingsView {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for SettingsView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        #[cfg(target_os = "macos")]
        self.material.sync(
            window,
            (t.prefs.sidebar == SidebarStyle::Material).then_some(f64::from(SETTINGS_SIDEBAR)),
        );
        // With nothing focused, Tab moves nowhere and actions reach the root
        // only: keep focus somewhere, as the main window does.
        if window.focused(cx).is_none() {
            window.focus(&self.focus, cx);
        }
        let visible = Tab::visible(&self.stores, cx);
        // A pane that went away (signed out, Advanced turned off) gives the
        // window back to General.
        if !visible.contains(&self.tab) {
            self.tab = Tab::FIRST;
        }
        let tabs: Vec<SettingsTab> = visible
            .iter()
            .enumerate()
            .map(|(i, tab)| SettingsTab {
                id: tab.id().into(),
                label: tab.label(&l10n).into(),
                icon: tab.icon(),
                group_start: i > 0 && visible[i - 1].group() != tab.group(),
            })
            .collect();
        let view = cx.entity().downgrade();
        // The phone's Settings open on the account's card; here it opens
        // Accounts.
        let account = crate::views::sidebar::footer_account(&self.stores, cx);
        let card_view = cx.entity().downgrade();
        let card = profile_card(&account, &t)
            .keyboard_control(
                conduit_components::views::focus::Ring::Outset(10.),
                window,
                cx,
            )
            .on_click(move |_, _, cx| {
                let _ = card_view.update(cx, |v, cx| v.show_tab(Tab::Accounts, cx));
            });
        let mut frame = SettingsWindow::new(tabs, self.tab.id(), SETTINGS_SIDEBAR)
            .title(l10n.desktop_settings_title())
            .header(card)
            .on_select(Rc::new(move |i, _, cx| {
                if let Some(tab) = visible.get(i).copied() {
                    let _ = view.update(cx, |v, cx| v.show_tab(tab, cx));
                }
            }));
        let sections = match self.tab {
            Tab::Appearance => self.appearance(window, cx),
            Tab::Language => self.language(window, cx),
            Tab::Accounts => self.accounts(cx),
            Tab::Direct => self.direct(window, cx),
            Tab::Hermes => self.hermes(window, cx),
            Tab::Keyboard => self.keyboard(cx),
            Tab::Desktop => self.desktop(cx),
            Tab::Data => self.data(cx),
            Tab::About => self.about(window, cx),
            Tab::Profile => vec![self.profile_pane(window, cx).into_any_element()],
            Tab::Personalization => {
                vec![self.personalization_pane(window, cx).into_any_element()]
            }
            Tab::Connection => connection::sections(&self.stores, cx),
            Tab::Chats => vec![self.chats_pane(window, cx).into_any_element()],
            Tab::Audio => vec![self.audio_pane(window, cx).into_any_element()],
            Tab::DataControls => vec![self.data_controls_pane(window, cx).into_any_element()],
            Tab::Notifications => vec![self.notifications_pane(window, cx).into_any_element()],
            Tab::PersonalConnections => {
                vec![
                    self.personal_connections_pane(window, cx)
                        .into_any_element(),
                ]
            }
        };
        // A pane replacing another fades in over 100 ms, from the frame the
        // button went down (a plain fade, so Reduce Motion keeps it); the
        // pane the window opens with is simply there.
        let fade = pane_fade(self.switched, cx.background_executor().now());
        if fade < 1. {
            window.request_animation_frame();
        }
        for s in sections {
            frame = frame.section(div().w_full().opacity(fade).child(s));
        }
        let stores = self.stores.clone();
        // A click on no control focuses the window itself: named, so
        // VoiceOver says where focus went rather than the whole window.
        div()
            .id("settings-root")
            .role(Role::Group)
            .aria_label(SharedString::from(l10n.desktop_settings_title()))
            .key_context("ConduitSettings")
            .track_focus(&self.focus)
            .on_action(move |a: &RemoveAccount, window, cx| {
                remove_account(&stores, &a.account_id, window, cx);
            })
            .on_action(cx.listener(|this, a: &SettingsChoice, window, cx| {
                this.choose(&a.menu, &a.value, window, cx);
            }))
            .map(|d| crate::menus::app_commands(d, &self.settings, &self.stores.speech, cx))
            .relative()
            .size_full()
            .child(frame)
    }
}

/// How far a newly chosen pane has faded in at `now` (1 once done, and for
/// the pane the window opened with).
fn pane_fade(switched: Option<std::time::Instant>, now: std::time::Instant) -> f32 {
    let Some(at) = switched else {
        return 1.;
    };
    let t =
        now.saturating_duration_since(at).as_secs_f32() / specs::CROSSFADE.duration.as_secs_f32();
    specs::CROSSFADE.curve.sample(t)
}

#[cfg(test)]
mod tests {
    use super::{helper_version, middle_truncate, pane_fade};

    #[test]
    fn the_helper_shows_its_protocol_as_a_build() {
        assert_eq!(helper_version(Some("1.4.2"), "1.56.0"), "1.4.2 (1.56.0)");
        assert_eq!(helper_version(None, "1.56.0"), "\u{2014} (1.56.0)");
        assert_eq!(helper_version(Some(" "), "1.56.0"), "\u{2014} (1.56.0)");
    }

    #[test]
    fn a_new_pane_fades_in_within_a_tenth_of_a_second_and_the_first_is_there() {
        let t0 = std::time::Instant::now();
        let at = |ms: u64| pane_fade(Some(t0), t0 + std::time::Duration::from_millis(ms));
        assert_eq!(pane_fade(None, t0), 1.);
        assert_eq!(at(0), 0.);
        assert!(at(17) > 0.3 && at(50) > 0.8, "{} {}", at(17), at(50));
        assert_eq!(at(100), 1.);
    }

    /// The app, its Share extension and its widget carry the same line
    /// (LICENSE's holder).
    #[test]
    fn the_about_copyright_is_the_bundles() {
        for plist in [
            include_str!("../../../../packaging/macos/Info.plist"),
            include_str!("../../../../packaging/macos/share/Info.plist"),
            include_str!("../../../../packaging/macos/widget/Info.plist"),
        ] {
            let key = plist.find("NSHumanReadableCopyright").unwrap();
            let value = &plist[key..];
            let start = value.find("<string>").unwrap() + "<string>".len();
            assert!(
                value[start..].starts_with(super::COPYRIGHT),
                "{}",
                &value[start..start + 40]
            );
        }
    }

    #[test]
    fn footers_join_sentences_as_each_language_does() {
        use super::join_sentences;
        assert_eq!(join_sentences("One.", "Two."), "One. Two.");
        assert_eq!(join_sentences("一。", "二。"), "一。二。");
    }

    #[test]
    fn long_paths_lose_their_middle_not_their_end() {
        let path = "~/Library/Application Support/Example/profiles/run-0042/userdata";
        let short = middle_truncate(path, 44);
        assert_eq!(short.chars().count(), 44);
        assert!(short.starts_with("~/Library/Applica"), "{short}");
        assert!(short.ends_with("profiles/run-0042/userdata"), "{short}");
        assert!(short.contains('\u{2026}'));
        assert_eq!(middle_truncate("~/Logs", 44), "~/Logs");
    }
}

#[cfg(test)]
mod language_tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use conduit_components::views::focus::KeyboardAccess;
    use gpui_kit::TestAppContext;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    #[gpui_kit::test]
    fn another_account_starts_the_account_panes_over(cx: &mut TestAppContext) {
        use crate::stores::accounts::tests::{account, list};
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-panes-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
        });
        let settings =
            cx.new(|_| SettingsStore::load(scratch.join("prefs.json"), false, vec!["en".into()]));
        let s = stores.clone();
        let (view, vcx) = cx.add_window_view(move |window, cx| {
            SettingsView::new(settings, s, Tab::Language, window, cx)
        });
        view.update_in(vcx, |v, window, cx| {
            v.profile_pane(window, cx);
            v.personalization_pane(window, cx);
            v.data_controls_pane(window, cx);
            v.direct_pane(window, cx);
            v.about_info = Some(conduit_protocol::AboutInfo::default());
        });
        stores.accounts.update(vcx, |a, cx| {
            a.adopt(
                list(vec![
                    account("a", "Avery", false, true),
                    account("b", "Blake", true, true),
                ]),
                cx,
            )
        });
        vcx.run_until_parked();
        view.read_with(vcx, |v, _| {
            assert!(v.profile.is_none(), "B's Profile shows A's details");
            assert!(v.personalization.is_none() && v.data_controls.is_none());
            assert!(v.about_info.is_none(), "About shows A's server");
            assert!(v.direct.is_none(), "Direct shows A's connections");
        });

        // LibreChat owns the chats, and its account changes while the Open
        // WebUI account stays parked: the panes start over too.
        let libre_chat = |id: &str| {
            let mut l = list(vec![
                account("a", "Avery", false, true),
                account("b", "Blake", true, true),
            ]);
            l.primary = conduit_protocol::PrimaryAccount::LibreChat;
            l.active_libre_chat_account_id = Some(id.into());
            l
        };
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(libre_chat("lc-1"), cx));
        vcx.run_until_parked();
        view.update_in(vcx, |v, window, cx| {
            v.personalization_pane(window, cx);
            v.profile_pane(window, cx);
        });
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(libre_chat("lc-2"), cx));
        vcx.run_until_parked();
        view.read_with(vcx, |v, _| {
            assert!(
                v.personalization.is_none(),
                "the second LibreChat account sees the first one's memories"
            );
            assert!(v.profile.is_none());
        });
    }

    /// Settings › Notifications couldn't read the settings: showing the tab
    /// again reads them again (as the pane opening does), not only a
    /// reconnect.
    #[gpui_kit::test]
    fn a_failed_notification_settings_read_is_tried_again_when_the_tab_shows(
        cx: &mut TestAppContext,
    ) {
        use conduit_protocol::methods;
        let daemon = FakeDaemon::new();
        daemon.on::<methods::NotificationsGet>(|_| {
            Err(conduit_daemon::protocol::error(
                conduit_daemon::protocol::codes::INTERNAL,
                "unreadable",
            ))
        });
        let scratch =
            std::env::temp_dir().join(format!("conduit-notify-tab-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.notifications.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        let settings =
            cx.new(|_| SettingsStore::load(scratch.join("prefs.json"), false, vec!["en".into()]));
        let s = stores.clone();
        let (view, vcx) = cx.add_window_view(move |window, cx| {
            SettingsView::new(settings, s, Tab::Notifications, window, cx)
        });
        view.update_in(vcx, |v, window, cx| {
            v.notifications_pane(window, cx);
        });
        vcx.run_until_parked();
        let reads = || daemon.calls::<methods::NotificationsGet>().len();
        let before = reads();
        assert!(stores.notifications.read_with(vcx, |s, _| s.load_failed));
        view.update(vcx, |v, cx| {
            v.show_tab(Tab::Language, cx);
            v.show_tab(Tab::Notifications, cx);
        });
        vcx.run_until_parked();
        assert_eq!(reads(), before + 1, "showing the tab again read nothing");
    }

    /// Focus that went nowhere (its control gone, a blur) comes back to the
    /// window, as in the main window: with none, Tab and the window's
    /// actions reach nothing.
    #[gpui_kit::test]
    fn a_settings_window_with_nothing_focused_takes_focus_back(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let scratch =
            std::env::temp_dir().join(format!("conduit-settings-blur-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let settings =
            cx.new(|_| SettingsStore::load(scratch.join("prefs.json"), false, vec!["en".into()]));
        let (_view, vcx) = cx.add_window_view(move |window, cx| {
            SettingsView::new(settings, stores, Tab::Language, window, cx)
        });
        vcx.run_until_parked();
        vcx.update(|window, cx| window.blur(cx));
        vcx.update(|window, cx| window.draw(cx).clear(cx));
        vcx.run_until_parked();
        assert!(vcx.update(|window, cx| window.focused(cx).is_some()));
    }

    #[gpui_kit::test]
    fn the_languages_are_one_keyboard_stop_whose_arrows_choose(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-language-{}", std::process::id()));
        let chosen: Rc<RefCell<Vec<Option<String>>>> = Rc::default();
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            cx.set_global(KeyboardAccess { all_controls: true });
            let seen = chosen.clone();
            cx.on_action(move |a: &SetLocale, _| seen.borrow_mut().push(a.locale.clone()));
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let settings =
            cx.new(|_| SettingsStore::load(scratch.join("prefs.json"), false, vec!["en".into()]));
        let (_view, vcx) = cx.add_window_view(move |window, cx| {
            SettingsView::new(settings, stores, Tab::Language, window, cx)
        });
        vcx.run_until_parked();
        // The system's language is chosen: its row is the group's one stop,
        // the pane's last, so Shift-Tab from the window reaches it.
        vcx.update(|window, cx| window.focus_prev(cx));
        vcx.run_until_parked();
        vcx.simulate_keystrokes("down");
        vcx.run_until_parked();
        assert_eq!(*chosen.borrow(), vec![Some(LOCALES[0].to_string())]);
    }

    /// In front, Settings takes View › Zoom In and the rest (Appearance shows
    /// the text size change) and Chat › Stop Speaking (Audio's preview), each
    /// only while it would act, as AppKit asks (the app's own handlers too).
    #[gpui_kit::test]
    fn settings_takes_the_zoom_items_and_stop_speaking_only_while_they_act(
        cx: &mut TestAppContext,
    ) {
        use conduit_protocol::{SpeechProgress, SpeechState, SpeechStatus, methods};

        use crate::actions::{ActualSize, StopSpeaking, ZoomIn, ZoomOut};
        use crate::menus::appkit_enables;
        use crate::prefs::TEXT_SIZE_MAX;
        let daemon = FakeDaemon::new();
        let scratch =
            std::env::temp_dir().join(format!("conduit-settings-menus-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            crate::register_actions(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let settings =
            cx.new(|_| SettingsStore::load(scratch.join("prefs.json"), false, vec!["en".into()]));
        let (s, prefs) = (stores.clone(), settings.clone());
        let (_view, vcx) = cx.add_window_view(move |window, cx| {
            SettingsView::new(prefs, s, Tab::Appearance, window, cx)
        });
        settings.update(vcx, |s, cx| {
            s.set_appearance(|a| a.text_size = Some(TEXT_SIZE_MAX), cx)
        });
        vcx.run_until_parked();
        assert!(
            !appkit_enables(vcx, &ZoomIn),
            "Zoom In is on at the largest size"
        );
        assert!(appkit_enables(vcx, &ZoomOut), "Zoom Out is off");
        assert!(appkit_enables(vcx, &ActualSize), "Actual Size is off");
        vcx.dispatch_action(ZoomOut);
        vcx.run_until_parked();
        assert_eq!(
            settings.read_with(vcx, |s, _| s.prefs.appearance.text_size),
            Some(TEXT_SIZE_MAX - 1.),
            "⌘− in Settings did not step the text size"
        );

        // A reading started and ended elsewhere (the main window), with
        // Audio's pane closed: followed at once.
        assert!(
            !appkit_enables(vcx, &StopSpeaking),
            "Stop Speaking is on with nothing read"
        );
        let state = |status, message: Option<&str>| SpeechState {
            progress: SpeechProgress {
                status,
                reading: 1,
                message_id: message.map(String::from),
                ..Default::default()
            },
            sentences: vec![],
        };
        daemon.returns::<methods::SpeechGet>(state(SpeechStatus::Speaking, Some("answer-1")));
        stores.speech.update(vcx, |s, cx| s.refresh(cx));
        vcx.run_until_parked();
        assert!(
            appkit_enables(vcx, &StopSpeaking),
            "Stop Speaking is off while a reading started elsewhere"
        );
        daemon.returns::<methods::SpeechGet>(state(SpeechStatus::Idle, None));
        stores.speech.update(vcx, |s, cx| s.refresh(cx));
        vcx.run_until_parked();
        assert!(
            !appkit_enables(vcx, &StopSpeaking),
            "Stop Speaking is on after the reading ended elsewhere"
        );
    }
}
