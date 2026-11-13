//! Screens outside the main window: first run, Settings, Quick Ask and the
//! menu-bar scene.

use conduit_components::ActiveConduitTheme;
use conduit_components::assets::{IconName, brand_mark, icon};
use conduit_components::theme::{self, Density, SidebarStyle};
use conduit_components::views::kit::Button;
use conduit_components::views::kit::{Segment, Segmented, Switch, setting_row};
use conduit_components::views::menu::{MenuEntry, MenuReplica};
use conduit_components::views::model::Backend;
use conduit_components::views::onboarding::{
    BackendChooser, ServerForm, SignInForm, first_run_frame,
};
use conduit_components::views::quick_ask::QuickAsk;
use conduit_components::views::settings::{
    PaletteChoice, SchemeTile, SettingsWindow, accounts_list, default_tabs, palette_picker,
    scheme_tiles, settings_section, stepper,
};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyView, Context, Entity, SharedString, Window, div, linear_color_stop, linear_gradient, px,
    rgb, rgba,
};

use crate::fake;
use crate::screens::Screen;
use crate::views::SETTINGS_SIDEBAR;

/// Onboarding and sign-in.
pub struct FirstRunScreen {
    screen: Screen,
    form: Option<AnyView>,
}

impl FirstRunScreen {
    pub fn new(screen: Screen, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let form: Option<AnyView> = match screen {
            Screen::OnboardingServer => {
                let f: Entity<ServerForm> = cx.new(|cx| {
                    let mut f = ServerForm::new(window, cx);
                    f.url.update(cx, |s, cx| {
                        s.set_value("https://chat.example.org", window, cx)
                    });
                    f.focused = Some(0);
                    f
                });
                Some(f.into())
            }
            Screen::SignIn => {
                let f: Entity<SignInForm> = cx.new(|cx| {
                    let mut f = SignInForm::new("chat.example.org", window, cx);
                    f.email
                        .update(cx, |s, cx| s.set_value("sam@example.org", window, cx));
                    f.password
                        .update(cx, |s, cx| s.set_value("correct-horse", window, cx));
                    f.focused = Some(1);
                    f
                });
                Some(f.into())
            }
            _ => None,
        };
        Self { screen, form }
    }
}

impl Render for FirstRunScreen {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let _ = self.screen;
        match &self.form {
            Some(form) => first_run_frame(form.clone(), cx),
            None => first_run_frame(BackendChooser::new(Backend::OpenWebUi), cx),
        }
    }
}

fn palette_label(id: &str) -> &'static str {
    match id {
        "conduit" => "Conduit",
        "claude" => "Claude",
        "t3_chat" => "T3 Chat",
        "catppuccin" => "Catppuccin",
        "tangerine" => "Tangerine",
        _ => "Palette",
    }
}

/// Settings › Appearance or Settings › Accounts.
pub struct SettingsScreen {
    screen: Screen,
}

impl SettingsScreen {
    pub fn new(screen: Screen) -> Self {
        Self { screen }
    }
}

impl Render for SettingsScreen {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let tab = if self.screen == Screen::Accounts {
            "accounts"
        } else {
            "appearance"
        };
        let mut window = SettingsWindow::new(default_tabs(), tab, SETTINGS_SIDEBAR).header(
            div()
                .p(px(8.))
                .flex()
                .items_center()
                .gap(px(10.))
                .child(conduit_components::views::sidebar::monogram("SR", 36., &t))
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .child(
                            div()
                                .text_size(px(t.metrics.control))
                                .font_weight(gpui_kit::FontWeight::SEMIBOLD)
                                .text_color(t.roles.sidebar_text)
                                .child("Sam Rivera"),
                        )
                        .child(
                            div()
                                .text_size(px(t.metrics.small))
                                .text_color(t.roles.sidebar_text_subtle)
                                .child("sam@example.org"),
                        ),
                ),
        );
        if self.screen == Screen::Accounts {
            window = window
                .section(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(8.))
                        .child(
                            div()
                                .px(px(2.))
                                .text_size(px(t.metrics.control))
                                .font_weight(gpui_kit::FontWeight::SEMIBOLD)
                                .text_color(t.roles.text)
                                .child("Signed-in accounts"),
                        )
                        .child(accounts_list(&fake::accounts(), cx))
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .justify_between()
                                .child(
                                    div()
                                        .px(px(2.))
                                        .text_size(px(t.metrics.small))
                                        .text_color(t.roles.text_subtle)
                                        .child("Each account keeps its own chats, models and settings."),
                                )
                                .child(Button::new("add-account", "Add Account\u{2026}").icon(IconName::Plus)),
                        ),
                )
                .section(settings_section(
                    "This account",
                    None,
                    vec![
                        setting_row(
                            "Sign out of chat.example.org",
                            Some("Chats stay on the server. Local copies are removed from this Mac.".into()),
                            Button::new("sign-out", "Sign Out\u{2026}").danger(),
                            cx,
                        )
                        .into_any_element(),
                    ],
                    cx,
                ));
        } else {
            let choices: Vec<PaletteChoice> = theme::palettes()
                .palettes
                .iter()
                .map(|p| {
                    let v = p.variant(t.dark);
                    PaletteChoice {
                        id: p.id.clone().into(),
                        label: palette_label(&p.id).into(),
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
            let mode = if t.dark { 2 } else { 1 };
            window = window
                .section(settings_section(
                    "Theme",
                    None,
                    vec![
                        scheme_tiles(
                            &[
                                (SchemeTile::System, "System".into()),
                                (SchemeTile::Light, "Light".into()),
                                (SchemeTile::Dark, "Dark".into()),
                            ],
                            mode,
                            None,
                            cx,
                        )
                        .into_any_element(),
                        div()
                            .flex()
                            .flex_col()
                            .child(setting_row(
                                "Palette",
                                Some(
                                    "Frames, text and the one strong colour. Conduit is monochrome."
                                        .into(),
                                ),
                                div(),
                                cx,
                            ))
                            .child(palette_picker(&choices, &t.palette_id, cx))
                            .into_any_element(),
                    ],
                    cx,
                ))
                .section(settings_section(
                    "Layout",
                    Some("Density changes row height and text size everywhere.".into()),
                    vec![
                        setting_row(
                            "Density",
                            None,
                            Segmented::new(
                                "density",
                                "Density",
                                vec![Segment::new("Compact"), Segment::new("Comfortable")],
                                if t.prefs.density == Density::Compact {
                                    0
                                } else {
                                    1
                                },
                            ),
                            cx,
                        )
                        .into_any_element(),
                        setting_row(
                            "Message text size",
                            None,
                            stepper(
                                "text-size",
                                "Message text size",
                                format!("{} pt", t.metrics.body),
                                cx,
                            ),
                            cx,
                        )
                        .into_any_element(),
                        setting_row(
                            "Translucent sidebar",
                            Some(
                                "Let the desktop show through. Off when Reduce Transparency is on."
                                    .into(),
                            ),
                            Switch::new(
                                "translucent-sidebar",
                                "Translucent sidebar",
                                t.prefs.sidebar == SidebarStyle::Material,
                            ),
                            cx,
                        )
                        .into_any_element(),
                    ],
                    cx,
                ));
        }
        window
    }
}

/// The Quick Ask panel.
pub struct QuickAskScreen {
    panel: Entity<QuickAsk>,
}

impl QuickAskScreen {
    pub fn new(screen: Screen, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let panel = cx.new(|cx| {
            let mut q = QuickAsk::new("Aster 2 Mini", window, cx);
            if screen == Screen::QuickAsk {
                q.set_query(fake::QUICK_QUESTION, window, cx);
                q.set_answer(fake::QUICK_ANSWER, cx);
            } else {
                q.recent = vec![
                    "What's a good substitute for buttermilk?".into(),
                    "Summarise the clipboard in three bullets".into(),
                    "Translate \u{201c}see you tomorrow\u{201d} into Portuguese".into(),
                    "How many weeks until the end of the year?".into(),
                ];
            }
            q
        });
        Self { panel }
    }
}

impl Render for QuickAskScreen {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(self.panel.clone())
    }
}

/// A drawn desktop corner: menu bar with Conduit's status item open.
pub struct MenuBarScene;

impl Render for MenuBarScene {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let dark = t.dark;
        let (a, b) = if dark {
            (0x1d2a4a, 0x3b2a52)
        } else {
            (0x9fb8e6, 0xe7c3c9)
        };
        let bar_bg = if dark {
            rgba(0x1e1e1ecc)
        } else {
            rgba(0xf4f4f4cc)
        };
        let bar_fg: gpui_kit::Hsla = if dark {
            rgb(0xf2f2f2).into()
        } else {
            rgb(0x1d1d1f).into()
        };
        let pressed = if dark {
            rgba(0xffffff33)
        } else {
            rgba(0x0000001f)
        };
        let item = |s: &'static str| div().text_size(px(13.)).text_color(bar_fg).child(s);
        let entries = vec![
            MenuEntry::item("Open Conduit"),
            MenuEntry::item("New Chat").shortcut("\u{2318}N"),
            MenuEntry::item("Quick Ask").shortcut("\u{21e7}\u{2318}Space"),
            MenuEntry::Separator,
            MenuEntry::Header("Recent".into()),
            MenuEntry::item("Orbital period of a moon"),
            MenuEntry::item("Dialing in espresso"),
            MenuEntry::item("Sourdough starter schedule"),
            MenuEntry::Separator,
            MenuEntry::item("Launch at Login").checked(),
            MenuEntry::item("Keep Running When Closed").checked(),
            MenuEntry::Separator,
            MenuEntry::item("Settings\u{2026}").shortcut("\u{2318},"),
            MenuEntry::item("Quit Conduit").shortcut("\u{2318}Q"),
        ];
        let _ = SharedString::default();
        div()
            .size_full()
            .relative()
            .bg(linear_gradient(
                135.,
                linear_color_stop(rgb(a), 0.),
                linear_color_stop(rgb(b), 1.),
            ))
            .child(
                div()
                    .absolute()
                    .top_0()
                    .left_0()
                    .right_0()
                    .h(px(28.))
                    .bg(bar_bg)
                    .px(px(14.))
                    .flex()
                    .items_center()
                    .gap(px(18.))
                    .child(div().flex_1())
                    .child(
                        div()
                            .id("status-item")
                            .role(gpui_kit::Role::Button)
                            .aria_label("Conduit")
                            .h(px(22.))
                            .px(px(7.))
                            .rounded(px(5.))
                            .bg(pressed)
                            .flex()
                            .items_center()
                            .child(brand_mark(16., bar_fg)),
                    )
                    .child(icon(IconName::Wifi, 15., bar_fg))
                    .child(item("Sun 9:41")),
            )
            .child(
                div().absolute().top(px(30.)).right(px(104.)).child(
                    MenuReplica::new("Conduit menu", entries)
                        .highlighted(2)
                        .width(270.),
                ),
            )
    }
}
