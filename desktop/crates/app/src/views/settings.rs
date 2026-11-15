//! The Settings window: a System Settings layout with working tabs, in
//! a Mac app's order (General first).
//!
//! * **General** (`Tab::Desktop`): close to the menu bar (with its
//!   menu-bar item), open at login (`SMAppService`, with the system's
//!   status), the Quick Ask shortcut (on/off, rebindable with conflict
//!   checks, and a note when another app holds it), and "Notify when an
//!   answer finishes" (whose footer says why a notification never carries
//!   the answer).
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
//! * **About**: the version, updates (Check Now, check automatically,
//!   "Receive beta updates"; see [`crate::updates`]), and the developer
//!   details behind a Diagnostics disclosure.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::motion::specs;
use conduit_components::theme::{self, SidebarStyle};
use conduit_components::views::focus::ControlExt as _;
use conduit_components::views::kit::{
    Button, IconButton, Segment, Segmented, SelectHandler, Switch, setting_row, warning_row,
};
use conduit_components::views::settings::{
    PaletteChoice, SchemeTile, SettingsTab, SettingsWindow, palette_picker_with, scheme_tiles,
    settings_section, stepper_with,
};
use conduit_components::views::shortcut_field::ShortcutField;
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Context, Entity, FocusHandle, Focusable, Role, SharedString, Subscription,
    Window, div, px,
};

use crate::actions::{RemoveAccount, SetLocale};
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
use crate::stores::shell::{HotkeyState, LoginState, NotificationAccess};
use crate::views::accounts::{accounts_sections, remove_account};
use crate::views::add_account::{self, AddAccountSheet};
use crate::views::direct::DirectView;
use crate::views::forms;
use crate::views::hermes::HermesView;
use crate::views::privacy;
use crate::views::server_form::{ServerForm, ServerFormEvent};
use crate::views::status::diagnostics_state;

/// Width of the Settings window's tab sidebar.
pub const SETTINGS_SIDEBAR: f32 = 210.;
/// The Settings window's size.
pub const SETTINGS_SIZE: (f32, f32) = (860., 760.);

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
}

impl Tab {
    /// General first, as every Mac app's Settings (Mail: General, then
    /// Accounts); then the accounts and connections, how the app looks and
    /// reads, and data and About.
    pub const ALL: [Self; 9] = [
        Self::Desktop,
        Self::Accounts,
        Self::Direct,
        Self::Hermes,
        Self::Appearance,
        Self::Language,
        Self::Keyboard,
        Self::Data,
        Self::About,
    ];

    /// The pane Settings opens on when nothing asks for another: General.
    pub const FIRST: Self = Self::ALL[0];

    /// Whether the tab starts a group in the list.
    fn group_start(self) -> bool {
        matches!(self, Self::Appearance | Self::Data)
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
    direct: Option<Entity<DirectView>>,
    hermes: Option<Entity<HermesView>>,
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
            cx.observe(&stores.accounts, |_, _, cx| cx.notify()),
            cx.observe(&stores.session, |_, _, cx| cx.notify()),
        ];
        if let Some(shell) = cx.try_global::<Desktop>().map(|d| d.shell.clone()) {
            subscriptions.push(cx.observe(&shell, |_, _, cx| cx.notify()));
        }
        // A Settings window that goes takes its sheet with it.
        subscriptions.push(cx.on_release(|this: &mut Self, cx: &mut App| {
            if let Some(sheet) = this.add_sheet.take() {
                end_sheet_window(sheet.handle, cx);
            }
        }));
        // The system's answers may have changed since (System Settings).
        crate::desktop::refresh_statuses(cx);
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        Self {
            settings,
            connection,
            stores,
            direct: None,
            hermes: None,
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

    /// Gives focus back to the window itself (nothing ringed), as it opens.
    pub fn rest_focus(&self, window: &mut Window, cx: &mut Context<Self>) {
        window.focus(&self.focus, cx);
        cx.notify();
    }

    /// Shows `tab`'s pane, fading it in over the one before.
    fn show_tab(&mut self, tab: Tab, cx: &mut Context<Self>) {
        if tab != self.tab {
            self.tab = tab;
            self.switched = Some(cx.background_executor().now());
            cx.notify();
        }
    }

    /// Add Account as a window sheet on Settings (AppKit's `beginSheet:`,
    /// as System Settings › Internet Accounts): the server's address, then
    /// Connect. Sign-in for the new account follows in the setup window.
    pub fn open_add_sheet(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.tab = Tab::Accounts;
        cx.notify();
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

    fn close_add_sheet(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self._add_sheet = None;
        if let Some(sheet) = self.add_sheet.take() {
            end_sheet_window(sheet.handle, cx);
        }
        window.focus(&self.focus, cx);
        cx.notify();
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
    fn language(&self, cx: &mut Context<Self>) -> Vec<AnyElement> {
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
        let rows = choices
            .into_iter()
            .enumerate()
            .map(|(i, (code, label))| {
                let on = code == current;
                div()
                    .id(gpui_kit::ElementId::NamedInteger(
                        "language".into(),
                        i as u64,
                    ))
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
        vec![settings_section(SharedString::default(), None, rows, cx).into_any_element()]
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
                        let keys = describe(&keymap::fixed_stroke(command), mac);
                        rows.push(
                            setting_row(label.clone(), None, fixed_keys(command, keys, label), cx)
                                .into_any_element(),
                        );
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
                KeyGroup::Window => l10n.desktop_menu_window(),
            };
            sections.push(settings_section(title, footer, rows, cx).into_any_element());
        }
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

    fn about(&self, window: &mut Window, cx: &mut Context<Self>) -> Vec<AnyElement> {
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
        vec![
            about_header(
                &l10n.app_title(),
                &l10n.desktop_about_version_line(&version),
                window.scale_factor(),
                &t,
            )
            .into_any_element(),
            self.updates_section(cx),
        ]
    }

    /// About › Updates: Sparkle's check and "check automatically" (release
    /// bundles only), and the saved "Receive beta updates".
    fn updates_section(&self, cx: &mut Context<Self>) -> AnyElement {
        let l10n = cx.l10n().clone();
        let available = crate::updates::available(cx);
        let beta = self.settings.read(cx).prefs.desktop.beta_updates;
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
        let settings = self.settings.clone();
        let beta_switch = Switch::new("beta-updates", l10n.desktop_beta_updates(), beta).on_click(
            Rc::new(move |_, _, cx| {
                settings.update(cx, |s, cx| s.set_desktop(|d| d.beta_updates = !beta, cx));
            }),
        );
        rows.push(
            setting_row(l10n.desktop_beta_updates(), None, beta_switch, cx).into_any_element(),
        );
        settings_section(
            l10n.desktop_updates_section(),
            Some(l10n.desktop_beta_updates_footer().into()),
            rows,
            cx,
        )
        .into_any_element()
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
                let Some(account) = stores
                    .accounts
                    .read(cx)
                    .accounts()
                    .iter()
                    .find(|a| a.id == id)
                    .cloned()
                else {
                    return;
                };
                let l10n = cx.l10n().clone();
                let name = privacy::name(&crate::stores::accounts::display_name(&account), cx);
                NativeMenu::new()
                    .menu(
                        l10n.desktop_sign_out_of(&name),
                        Box::new(RemoveAccount {
                            account_id: account.id.clone(),
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
        out
    }

    fn direct(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let l10n = cx.l10n().clone();
        let stores = self.stores.clone();
        // The view draws its own groups (the list, the form) at the page's
        // inset, as every other page's groups are, not inside another card.
        let direct = self
            .direct
            .get_or_insert_with(|| {
                cx.new(|cx| {
                    let mut v = DirectView::new(stores, false, window, cx);
                    v.footer = Some(l10n.direct_connections_description().into());
                    v
                })
            })
            .clone();
        vec![direct.into_any_element()]
    }

    fn hermes(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let stores = self.stores.clone();
        let hermes = self
            .hermes
            .get_or_insert_with(|| cx.new(|cx| HermesView::new(stores, false, window, cx)))
            .clone();
        vec![hermes.into_any_element()]
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
        let (hotkey, notifications, login, login_error) = shell;
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

        // Notifications.
        let notify = toggle(
            "notify-answers",
            l10n.desktop_notify_answers(),
            prefs.notify_answers,
            |d, on| d.notify_answers = on,
        );
        let mut notify_footer = l10n.desktop_notify_answers_footer();
        let denied = notifications == NotificationAccess::Denied && prefs.notify_answers;
        if denied {
            notify_footer = format!("{notify_footer}\n\n{}", l10n.desktop_notifications_denied());
        } else if notifications == NotificationAccess::Unavailable {
            notify_footer = format!(
                "{notify_footer}\n\n{}",
                l10n.desktop_notifications_unavailable()
            );
        }
        let mut notify_rows =
            vec![setting_row(l10n.desktop_notify_answers(), None, notify, cx).into_any_element()];
        if denied {
            notify_rows.push(
                setting_row(
                    l10n.desktop_notifications_off(),
                    None,
                    Button::new("notification-settings", l10n.desktop_open_system_settings())
                        .on_click(Rc::new(|_, _, cx| {
                            crate::desktop::open_notification_settings(cx)
                        })),
                    cx,
                )
                .into_any_element(),
            );
        }

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
            settings_section(
                l10n.desktop_notifications_section(),
                Some(notify_footer.into()),
                notify_rows,
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
        let clearing = conn.clearing;
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
                            .disabled(clearing || !connected)
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
        let tabs: Vec<SettingsTab> = Tab::ALL
            .iter()
            .map(|tab| SettingsTab {
                id: tab.id().into(),
                label: tab.label(&l10n).into(),
                icon: tab.icon(),
                group_start: tab.group_start(),
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
                let _ = view.update(cx, |v, cx| v.show_tab(Tab::ALL[i], cx));
            }));
        let sections = match self.tab {
            Tab::Appearance => self.appearance(window, cx),
            Tab::Language => self.language(cx),
            Tab::Accounts => self.accounts(cx),
            Tab::Direct => self.direct(window, cx),
            Tab::Hermes => self.hermes(window, cx),
            Tab::Keyboard => self.keyboard(cx),
            Tab::Desktop => self.desktop(cx),
            Tab::Data => self.data(cx),
            Tab::About => self.about(window, cx),
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
        div()
            .id("settings-root")
            .key_context("ConduitSettings")
            .track_focus(&self.focus)
            .on_action(move |a: &RemoveAccount, window, cx| {
                remove_account(&stores, &a.account_id, window, cx);
            })
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

    /// The app's Info.plist carries the same line (LICENSE's holder).
    #[test]
    fn the_about_copyright_is_the_bundles() {
        let plist = include_str!("../../../../packaging/macos/Info.plist");
        let key = plist.find("NSHumanReadableCopyright").unwrap();
        let value = &plist[key..];
        let start = value.find("<string>").unwrap() + "<string>".len();
        assert!(
            value[start..].starts_with(super::COPYRIGHT),
            "{}",
            &value[start..start + 40]
        );
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
