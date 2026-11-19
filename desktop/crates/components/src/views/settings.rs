//! The Settings window: a sidebar of tabs beside a grouped form, the System
//! Settings layout. Plus the pieces of the Appearance and Accounts tabs.

use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Div, ElementId, FontWeight, Hsla, MouseButton, Role, SharedString, Stateful,
    Window, div, px,
};

use std::rc::Rc;

use crate::assets::{IconName, icon};
use crate::strings::{ActiveStrings as _, Strings, fill};
use crate::theme::{ActiveConduitTheme, UI_FONT, with_alpha};
use crate::views::focus::{ControlExt as _, RadioGroupExt as _, radio_option_id};
use crate::views::kit::{Button, IconButton, SelectHandler, avatar, badge, grouped, heading};
use crate::views::model::{Account, Backend};
use crate::window::{TOOLBAR_HEIGHT, TRAFFIC_LIGHTS_WIDTH, drag_region};

/// A Settings tab.
#[derive(Clone, Debug, PartialEq)]
pub struct SettingsTab {
    pub id: SharedString,
    pub label: SharedString,
    pub icon: IconName,
    /// Starts a new group in the list, as the phone's root list groups its
    /// rows.
    pub group_start: bool,
}

/// The Settings window's tabs, in order.
pub fn default_tabs() -> Vec<SettingsTab> {
    let t = |id: &str, label: &str, icon: IconName, group_start: bool| SettingsTab {
        id: id.into(),
        label: label.into(),
        icon,
        group_start,
    };
    // The phone's root order and groups.
    vec![
        t("accounts", "Accounts", IconName::Users, false),
        t("direct", "Direct connections", IconName::Zap, true),
        t("hermes", "Hermes", IconName::Bot, false),
        t("appearance", "Appearance", IconName::Palette, true),
        t("language", "App Language", IconName::Globe, false),
        t("keyboard", "Keyboard", IconName::Keyboard, false),
        t("desktop", "Desktop", IconName::Monitor, false),
        t("data", "Data", IconName::Database, true),
        t("about", "About", IconName::Info, false),
    ]
}

/// The window scaffold: tabs on the left, the selected tab's sections on
/// the right.
#[derive(IntoElement)]
pub struct SettingsWindow {
    tabs: Vec<SettingsTab>,
    selected: SharedString,
    sidebar_width: f32,
    sections: Vec<AnyElement>,
    title: Option<SharedString>,
    on_select: Option<SelectHandler>,
    /// Drawn above the tabs (the account's profile card).
    header: Option<AnyElement>,
}

impl SettingsWindow {
    pub fn new(
        tabs: Vec<SettingsTab>,
        selected: impl Into<SharedString>,
        sidebar_width: f32,
    ) -> Self {
        Self {
            tabs,
            selected: selected.into(),
            sidebar_width,
            sections: vec![],
            title: None,
            on_select: None,
            header: None,
        }
    }
    /// A card above the tabs, as the phone's Settings opens on the profile.
    pub fn header(mut self, header: impl IntoElement) -> Self {
        self.header = Some(header.into_any_element());
        self
    }
    pub fn section(mut self, section: impl IntoElement) -> Self {
        self.sections.push(section.into_any_element());
        self
    }
    /// The tab list's accessible name (default "Settings").
    pub fn title(mut self, title: impl Into<SharedString>) -> Self {
        self.title = Some(title.into());
        self
    }
    /// Called with the index of the tab the user picked.
    pub fn on_select(mut self, handler: SelectHandler) -> Self {
        self.on_select = Some(handler);
        self
    }
}

/// Scrolls the Settings pane, on its next render, to this fraction of its
/// height (0 the top, 1 the end): its scroll is the window's, which only a
/// render can reach (the E2E's shots of sections below the fold).
#[derive(Clone, Copy, Debug, Default)]
pub struct PaneScrollRequest(pub Option<f32>);

impl gpui_kit::Global for PaneScrollRequest {}

impl RenderOnce for SettingsWindow {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let st = cx.strings().clone();
        let r = t.roles;
        let m = t.metrics;
        // The tab list is one keyboard stop, as a source list: Tab reaches
        // it, ↑/↓ change the section, and while it has focus its selection
        // is drawn darker (a click focuses it too, as AppKit's lists).
        let list_focus = crate::views::focus::control_focus_handle(
            &ElementId::Name("settings-tabs".into()),
            window,
            cx,
        )
        .tab_stop(true);
        let list_focused = list_focus.is_focused(window);
        let selected_index = self
            .tabs
            .iter()
            .position(|tab| tab.id == self.selected)
            .unwrap_or(0);
        let pressed = crate::views::focus::pressed_fill(r.hover, &t);
        let key_select = self.on_select.clone();
        let page = crate::views::kit::grouped_tones(&t).0;
        let scroll = window
            .use_keyed_state("settings-scroll-handle", cx, |_, _| {
                gpui_kit::ScrollHandle::new()
            })
            .read(cx)
            .clone();
        // A scroll asked for from outside a render ([`PaneScrollRequest`]).
        if let Some(fraction) = cx.try_global::<PaneScrollRequest>().and_then(|r| r.0) {
            let max = scroll.max_offset();
            scroll.set_offset(gpui_kit::point(px(0.), -max.y * fraction));
            cx.set_global(PaneScrollRequest(None));
        }
        let fade = pane_edge_fade(
            f32::from(scroll.offset().y),
            f32::from(scroll.max_offset().y),
        );
        let title = self
            .tabs
            .iter()
            .find(|tab| tab.id == self.selected)
            .map(|tab| tab.label.clone())
            .unwrap_or_default();
        let count = self.tabs.len();
        div()
            .size_full()
            .flex()
            .font_family(UI_FONT)
            .text_color(r.text)
            .child(
                div()
                    .id("settings-sidebar")
                    .role(Role::Navigation)
                    .aria_label(st.settings_sections.clone())
                    .w(px(self.sidebar_width))
                    .h_full()
                    .flex_none()
                    .flex()
                    .flex_col()
                    .bg(r.sidebar)
                    .child(
                        drag_region("settings-sidebar-titlebar")
                            .h(px(TOOLBAR_HEIGHT))
                            .flex_none()
                            .pl(px(TRAFFIC_LIGHTS_WIDTH)),
                    )
                    .when_some(self.header, |d, header| {
                        d.child(div().px(px(10.)).pb(px(10.)).child(header))
                    })
                    .child(
                        div()
                            .id("settings-tabs")
                            .role(Role::TabList)
                            .aria_label(self.title.clone().unwrap_or(st.settings.clone()))
                            .track_focus(&list_focus)
                            .on_key_down(move |ev: &gpui_kit::KeyDownEvent, window, cx| {
                                let k = &ev.keystroke;
                                if k.modifiers.modified() {
                                    return;
                                }
                                let next = match k.key.as_str() {
                                    "up" => selected_index.checked_sub(1),
                                    "down" => Some(selected_index + 1).filter(|i| *i < count),
                                    "home" => Some(0),
                                    "end" => count.checked_sub(1),
                                    _ => return,
                                };
                                if let (Some(i), Some(h)) = (next, &key_select) {
                                    h(i, window, cx);
                                }
                                cx.stop_propagation();
                            })
                            .px(px(10.))
                            .flex()
                            .flex_col()
                            .gap(px(1.))
                            .children(self.tabs.iter().enumerate().map(|(i, tab)| {
                                let on = tab.id == self.selected;
                                div()
                                    .id(ElementId::Name(format!("settings-tab-{}", tab.id).into()))
                                    .role(Role::Tab)
                                    .aria_label(tab.label.clone())
                                    .aria_selected(on)
                                    .aria_position_in_set(i + 1)
                                    .aria_size_of_set(count)
                                    // VoiceOver follows the selection as
                                    // the arrows move it.
                                    .when(on && list_focused, |d| d.aria_active_descendant())
                                    .when(tab.group_start && i > 0, |d| d.mt(px(12.)))
                                    .h(px(m.row_height + 2.))
                                    .px(px(8.))
                                    .flex()
                                    .items_center()
                                    .gap(px(9.))
                                    .rounded(t.row_radius())
                                    // The list's focus shows as a darker
                                    // selection, never a ring on top of it.
                                    .when(on, |d| {
                                        d.debug_selector(|| "settings-selection".into()).bg(
                                            crate::views::focus::selection_fill(&t, list_focused),
                                        )
                                    })
                                    .when(!on, |d| {
                                        d.hover(|s| s.bg(r.hover)).active(|s| s.bg(pressed))
                                    })
                                    .cursor_pointer()
                                    .child(icon(
                                        tab.icon,
                                        15.,
                                        if on && list_focused {
                                            crate::views::focus::selection_ink(&t)
                                        } else if on {
                                            r.selected_icon
                                        } else {
                                            r.sidebar_text_subtle
                                        },
                                    ))
                                    .child(
                                        div()
                                            .text_size(px(m.control))
                                            .text_color(crate::views::focus::on_selection(
                                                r.sidebar_text,
                                                &t,
                                                on && list_focused,
                                            ))
                                            .child(tab.label.clone()),
                                    )
                                    // The pane changes as the button goes
                                    // down, as in System Settings (the click
                                    // stays for VoiceOver's press).
                                    .on_mouse_down(MouseButton::Left, {
                                        let handler = self.on_select.clone();
                                        move |_, window, cx| {
                                            if !on && let Some(h) = &handler {
                                                h(i, window, cx)
                                            }
                                        }
                                    })
                                    .on_click({
                                        let handler = self.on_select.clone();
                                        move |_, window, cx| {
                                            if !on && let Some(h) = &handler {
                                                h(i, window, cx)
                                            }
                                        }
                                    })
                            })),
                    ),
            )
            .child(
                div()
                    .id("settings-content")
                    .role(Role::TabPanel)
                    .aria_label(title.clone())
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .flex()
                    .flex_col()
                    // The phone's grouped page, so groups read as lifted.
                    .bg(page)
                    .border_l_1()
                    .border_color(r.divider)
                    .child(
                        drag_region("settings-toolbar")
                            .h(px(TOOLBAR_HEIGHT))
                            .flex_none()
                            .px(px(24.))
                            .flex()
                            .items_center()
                            .child(heading(
                                "settings-title",
                                title,
                                1,
                                m.control + 2.,
                                FontWeight::SEMIBOLD,
                                r.text,
                            )),
                    )
                    .child(
                        div()
                            .relative()
                            .flex_1()
                            .min_h_0()
                            .child(
                                div()
                                    .id("settings-scroll")
                                    .size_full()
                                    .overflow_y_scroll()
                                    .track_scroll(&scroll)
                                    .px(px(24.))
                                    .flex()
                                    .flex_col()
                                    .gap(px(22.))
                                    .children(self.sections)
                                    // The list ends clear of the window's
                                    // edge, not flush with it.
                                    .child(div().flex_none().h(px(PANE_BOTTOM_INSET))),
                            )
                            // More below: the last rows fade into the page,
                            // as far as is left to scroll (up to 24 pt), so
                            // a list that runs past the edge never looks as
                            // if it ended there.
                            .when(fade > 0.5, |d| {
                                d.child(
                                    div()
                                        .absolute()
                                        .left_0()
                                        .right_0()
                                        .bottom_0()
                                        .h(px(fade))
                                        .bg(gpui_kit::linear_gradient(
                                            0.,
                                            gpui_kit::linear_color_stop(page, 0.),
                                            gpui_kit::linear_color_stop(with_alpha(page, 0.), 1.),
                                        )),
                                )
                            }),
                    ),
            )
    }
}

/// The room under a Settings pane's last group, when scrolled to its end.
pub const PANE_BOTTOM_INSET: f32 = 28.;

/// The tallest the fade at a Settings pane's bottom edge gets.
pub const PANE_EDGE_FADE: f32 = 24.;

/// How tall the bottom edge fade is: as much as is left to scroll, up to
/// [`PANE_EDGE_FADE`] (none at the end or when everything fits).
pub fn pane_edge_fade(offset_y: f32, max_y: f32) -> f32 {
    (max_y - (-offset_y).max(0.)).clamp(0., PANE_EDGE_FADE)
}

/// A titled group of settings rows, as the phone's inset-grouped sections:
/// a quiet title over the group and an optional footer under it.
pub fn settings_section(
    title: impl Into<SharedString>,
    footer: Option<SharedString>,
    rows: Vec<AnyElement>,
    cx: &App,
) -> Div {
    let title: SharedString = title.into();
    crate::views::kit::grouped_section((!title.is_empty()).then_some(title), rows, footer, cx)
}

/// One colour scheme in [`scheme_tiles`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SchemeTile {
    System,
    Light,
    Dark,
}

/// The corner radius of a scheme tile.
const TILE_RADIUS: f32 = 10.;

/// How an Appearance tile shows it is chosen, for themes and palettes
/// alike (System Settings' idiom): a 2 pt ring in the checked colour, 2 pt
/// outside the thumbnail, and nothing else (no radio circle, no check).
/// The ring's room is kept when off, so choosing moves nothing.
fn tile_ring(on: bool, radius: f32, thumbnail: impl IntoElement, t: &crate::ConduitTheme) -> Div {
    div()
        .p(px(2.))
        .rounded(px(radius + 4.))
        .border_2()
        .border_color(if on {
            t.roles.checked
        } else {
            with_alpha(t.roles.checked, 0.)
        })
        .child(thumbnail)
}

/// A tile's name under it: the control size, in the primary colour, a
/// little heavier when chosen.
fn tile_label(on: bool, label: SharedString, t: &crate::ConduitTheme) -> Div {
    div()
        .text_size(px(t.metrics.control))
        .text_color(t.roles.text)
        .font_weight(if on {
            FontWeight::MEDIUM
        } else {
            FontWeight::NORMAL
        })
        .child(label)
}

/// The phone's Appearance tiles: a miniature screen per scheme (System split
/// light and dark) and its name, the chosen one ringed (see [`tile_ring`]).
pub fn scheme_tiles(
    tiles: &[(SchemeTile, SharedString)],
    selected: usize,
    on_select: Option<SelectHandler>,
    cx: &App,
) -> Stateful<Div> {
    let t = cx.conduit().clone();
    let r = t.roles;
    let count = tiles.len();
    let page = |dark: bool| -> (Hsla, Hsla, Hsla) {
        // Page, ink and card of the active palette in that mode.
        let v = crate::theme::palettes().get(&t.palette_id).variant(dark);
        (v.surfaces.panel, v.colors.foreground, v.colors.card)
    };
    let mini = move |dark: bool| {
        let (bg, ink, card) = page(dark);
        div()
            .size_full()
            .bg(bg)
            .p(px(6.))
            .flex()
            .flex_col()
            .gap(px(3.))
            .child(div().w(px(18.)).h(px(4.)).rounded_full().bg(card))
            .child(div().ml_auto().w(px(22.)).h(px(6.)).rounded_full().bg(card))
            .child(
                div()
                    .mt(px(4.))
                    .w(px(34.))
                    .h(px(2.))
                    .bg(with_alpha(ink, 0.7)),
            )
            .child(div().w(px(28.)).h(px(2.)).bg(with_alpha(ink, 0.7)))
            .child(div().w(px(32.)).h(px(2.)).bg(with_alpha(ink, 0.7)))
            .child(div().mt_auto().w_full().h(px(7.)).rounded_full().bg(card))
    };
    div()
        .id("appearance-mode")
        .role(Role::RadioGroup)
        .radio_group(selected, count, on_select.clone(), cx)
        .w_full()
        .py(px(12.))
        .flex()
        .justify_around()
        .children(tiles.iter().enumerate().map(|(i, (tile, label))| {
            let on = i == selected;
            // The fill follows the tile's rounded corners (inside its 1 pt
            // border): a clip is only ever rectangular, so the halves of
            // System round their own outer corners.
            let inner = px(TILE_RADIUS - 1.);
            let preview = match tile {
                SchemeTile::Light => mini(false).rounded(inner).into_any_element(),
                SchemeTile::Dark => mini(true).rounded(inner).into_any_element(),
                SchemeTile::System => div()
                    .size_full()
                    .flex()
                    .child(
                        div()
                            .w_1_2()
                            .h_full()
                            .overflow_hidden()
                            .child(mini(false).rounded_tl(inner).rounded_bl(inner)),
                    )
                    .child(
                        div()
                            .w_1_2()
                            .h_full()
                            .overflow_hidden()
                            .child(mini(true).rounded_tr(inner).rounded_br(inner)),
                    )
                    .into_any_element(),
            };
            div()
                .id(radio_option_id("appearance-mode", i, on))
                .role(Role::RadioButton)
                .aria_label(label.clone())
                .aria_selected(on)
                .aria_position_in_set(i + 1)
                .aria_size_of_set(count)
                .flex()
                .flex_col()
                .items_center()
                .gap(px(4.))
                .cursor_pointer()
                .radio_option_outline(on, 14., cx)
                .child(tile_ring(
                    on,
                    TILE_RADIUS,
                    div()
                        .w(px(52.))
                        .h(px(84.))
                        .rounded(px(TILE_RADIUS))
                        .overflow_hidden()
                        .border_1()
                        .border_color(r.border_strong)
                        .child(preview),
                    &t,
                ))
                .child(tile_label(on, label.clone(), &t))
                .on_click({
                    let handler = on_select.clone();
                    move |_, window, cx| {
                        if let Some(h) = &handler {
                            h(i, window, cx)
                        }
                    }
                })
        }))
}

/// One palette in the picker.
#[derive(Clone, Debug, PartialEq)]
pub struct PaletteChoice {
    pub id: SharedString,
    pub label: SharedString,
    /// Window, panel, sidebar, strong colour, text.
    pub swatches: [Hsla; 5],
}

/// Palette cards: a miniature window per palette.
pub fn palette_picker(choices: &[PaletteChoice], selected: &str, cx: &App) -> Stateful<Div> {
    palette_picker_with(choices, selected, None, cx)
}

/// [`palette_picker`], calling `on_select` with the index of the card the
/// user picked.
pub fn palette_picker_with(
    choices: &[PaletteChoice],
    selected: &str,
    on_select: Option<SelectHandler>,
    cx: &App,
) -> Stateful<Div> {
    let t = cx.conduit().clone();
    let r = t.roles;
    let count = choices.len();
    div()
        .id("palette-picker")
        .role(Role::RadioGroup)
        .aria_label(cx.strings().palette_choice.clone())
        .radio_group(
            choices
                .iter()
                .position(|c| c.id.as_ref() == selected)
                .unwrap_or(0),
            count,
            on_select.clone(),
            cx,
        )
        .w_full()
        .px(px(12.))
        .pb(px(12.))
        .flex()
        .flex_wrap()
        .gap(px(12.))
        .children(choices.iter().enumerate().map(|(i, c)| {
            let on = c.id.as_ref() == selected;
            let [window, panel, sidebar, strong, text] = c.swatches;
            div()
                .id(radio_option_id("palette", i, on))
                .role(Role::RadioButton)
                .aria_label(c.label.clone())
                .aria_selected(on)
                .aria_position_in_set(i + 1)
                .aria_size_of_set(count)
                .w(px(164.))
                .flex()
                .flex_col()
                .items_center()
                .gap(px(4.))
                .cursor_pointer()
                .radio_option_outline(on, 12., cx)
                .child(tile_ring(
                    on,
                    8.,
                    div()
                        .h(px(68.))
                        .w(px(156.))
                        .rounded(px(8.))
                        .border_1()
                        .border_color(r.border_strong)
                        .bg(window)
                        .p(px(5.))
                        .flex()
                        .gap(px(4.))
                        .overflow_hidden()
                        .child(
                            div()
                                .w(px(26.))
                                .h_full()
                                .rounded(px(4.))
                                .bg(sidebar)
                                .flex()
                                .flex_col()
                                .gap(px(3.))
                                .p(px(4.))
                                .child(
                                    div()
                                        .h(px(3.))
                                        .w_full()
                                        .rounded_full()
                                        .bg(with_alpha(text, 0.5)),
                                )
                                .child(
                                    div()
                                        .h(px(3.))
                                        .w(px(12.))
                                        .rounded_full()
                                        .bg(with_alpha(text, 0.3)),
                                ),
                        )
                        .child(
                            div()
                                .flex_1()
                                .h_full()
                                .rounded(px(4.))
                                .bg(panel)
                                .p(px(5.))
                                .flex()
                                .flex_col()
                                .justify_between()
                                .child(
                                    div()
                                        .h(px(3.))
                                        .w(px(36.))
                                        .rounded_full()
                                        .bg(with_alpha(text, 0.6)),
                                )
                                .child(
                                    div()
                                        .h(px(3.))
                                        .w(px(24.))
                                        .rounded_full()
                                        .bg(with_alpha(text, 0.35)),
                                )
                                .child(
                                    div()
                                        .flex()
                                        .justify_end()
                                        .child(div().size(px(10.)).rounded_full().bg(strong)),
                                ),
                        ),
                    &t,
                ))
                .child(tile_label(on, c.label.clone(), &t))
                .on_click({
                    let handler = on_select.clone();
                    move |_, window, cx| {
                        if let Some(h) = &handler {
                            h(i, window, cx)
                        }
                    }
                })
        }))
}

/// A macOS pop-up button ("System (English) ⌄").
pub fn popup_button(
    id: &'static str,
    label: &str,
    value: impl Into<SharedString>,
    cx: &App,
) -> Stateful<Div> {
    let t = cx.conduit();
    let r = t.roles;
    let value = value.into();
    div()
        .id(id)
        .role(Role::Button)
        .aria_label(format!("{label}: {value}"))
        .h(px(t.metrics.control_height - 2.))
        .pl(px(10.))
        .pr(px(6.))
        .flex()
        .items_center()
        .gap(px(6.))
        .rounded(t.control_radius())
        .border_1()
        .border_color(r.border_strong)
        .bg(if t.dark {
            crate::theme::mix(t.surfaces.panel, r.text, 0.12)
        } else {
            t.surfaces.panel
        })
        .shadow(crate::views::kit::control_shadow(t))
        .cursor_pointer()
        .keyboard_shadow(cx)
        .text_size(px(t.metrics.control))
        .text_color(r.text)
        .child(value)
        .child(icon(IconName::ChevronsUpDown, 13., r.text_subtle))
        .on_click(|_, _, _| {})
}

/// A macOS stepper with its value ("14 pt").
pub fn stepper(id: &'static str, label: &str, value: impl Into<SharedString>, cx: &App) -> Div {
    stepper_with(id, label, value, None, cx)
}

/// [`stepper`] whose arrows call `on_step` with +1 (up) or 0 (down).
pub fn stepper_with(
    id: &'static str,
    label: &str,
    value: impl Into<SharedString>,
    on_step: Option<SelectHandler>,
    cx: &App,
) -> Div {
    let t = cx.conduit();
    let r = t.roles;
    let value = value.into();
    div()
        .flex()
        .items_center()
        .gap(px(8.))
        .child(
            div()
                .text_size(px(t.metrics.control))
                .text_color(r.text)
                .child(value.clone()),
        )
        .child(
            div()
                .id(id)
                .role(Role::SpinButton)
                .aria_label(format!("{label}: {value}"))
                .w(px(20.))
                .h(px(t.metrics.control_height - 4.))
                .flex()
                .flex_col()
                .rounded(px(5.))
                .border_1()
                .border_color(r.border_strong)
                .bg(t.surfaces.panel)
                // Reached by Tab, ↑ and ↓ step it, as AppKit's steppers.
                .keyboard_shadow(cx)
                .on_key_down({
                    let handler = on_step.clone();
                    move |ev: &gpui_kit::KeyDownEvent, window, cx| {
                        let step = match ev.keystroke.key.as_str() {
                            "up" => 1,
                            "down" => 0,
                            _ => return,
                        };
                        if let Some(h) = &handler {
                            h(step, window, cx);
                            cx.stop_propagation();
                        }
                    }
                })
                .child(
                    div()
                        .id("stepper-up")
                        .flex_1()
                        .flex()
                        .items_center()
                        .justify_center()
                        .cursor_pointer()
                        .child(icon(IconName::ChevronUp, 10., r.text_subtle))
                        .on_click({
                            let handler = on_step.clone();
                            move |_, window, cx| {
                                if let Some(h) = &handler {
                                    h(1, window, cx)
                                }
                            }
                        }),
                )
                .child(div().h(px(1.)).bg(r.border))
                .child(
                    div()
                        .id("stepper-down")
                        .flex_1()
                        .flex()
                        .items_center()
                        .justify_center()
                        .cursor_pointer()
                        .child(icon(IconName::ChevronDown, 10., r.text_subtle))
                        .on_click({
                            let handler = on_step.clone();
                            move |_, window, cx| {
                                if let Some(h) = &handler {
                                    h(0, window, cx)
                                }
                            }
                        }),
                )
                .on_click(|_, _, _| {}),
        )
}

/// A backend's name, in the window's language.
pub fn backend_label(b: Backend, st: &Strings) -> SharedString {
    match b {
        Backend::OpenWebUi => st.open_webui.clone(),
        Backend::Direct => st.direct.clone(),
        Backend::Hermes => st.hermes.clone(),
        Backend::LibreChat => st.librechat.clone(),
    }
}

/// What a row of [`accounts_list_with`] does, by account id.
pub type AccountHandler = Rc<dyn Fn(&str, &mut Window, &mut App) + 'static>;

/// The actions of the Accounts list.
#[derive(Clone, Default)]
pub struct AccountActions {
    /// "Switch", on a signed-in account that is not active.
    pub on_switch: Option<AccountHandler>,
    /// "Sign in again…", on an account whose session is gone.
    pub on_sign_in: Option<AccountHandler>,
    /// The "…" button: a menu with Sign out and Remove.
    pub on_more: Option<AccountHandler>,
    /// The account whose change is running: its button shows as busy.
    pub busy: Option<SharedString>,
}

fn account_click(handler: &Option<AccountHandler>, id: &str) -> crate::views::kit::ClickHandler {
    let handler = handler.clone();
    let id = id.to_string();
    Rc::new(move |_, window, cx| {
        if let Some(h) = &handler {
            h(&id, window, cx)
        }
    })
}

fn backend_icon(b: Backend) -> IconName {
    match b {
        Backend::OpenWebUi => IconName::Server,
        Backend::Direct => IconName::Zap,
        Backend::Hermes => IconName::Bot,
        Backend::LibreChat => IconName::MessagesSquare,
    }
}

/// The Accounts list: one row per account, the active one marked.
pub fn accounts_list(accounts: &[Account], cx: &App) -> Stateful<Div> {
    accounts_list_with(accounts, &AccountActions::default(), cx)
}

/// [`accounts_list`] with working buttons.
pub fn accounts_list_with(
    accounts: &[Account],
    actions: &AccountActions,
    cx: &App,
) -> Stateful<Div> {
    let t = cx.conduit().clone();
    let st = cx.strings().clone();
    let r = t.roles;
    let m = t.metrics;
    let rows: Vec<AnyElement> = accounts
        .iter()
        .map(|a| {
            let id = a.id.to_string();
            let status = if a.active {
                st.active.clone()
            } else if a.needs_sign_in {
                st.session_expired.clone()
            } else {
                SharedString::default()
            };
            let busy = actions.busy.as_deref() == Some(id.as_str());
            let trailing: AnyElement = if a.active {
                badge(
                    st.active.clone(),
                    with_alpha(r.success, if t.dark { 0.22 } else { 0.14 }),
                    crate::theme::legible_text(r.success, r.text, t.surfaces.panel, 4.5),
                    cx,
                )
                .into_any_element()
            } else if a.needs_sign_in {
                Button::new(
                    ElementId::Name(format!("reauth-{id}").into()),
                    st.sign_in_again.clone(),
                )
                .disabled(busy)
                .on_click(account_click(&actions.on_sign_in, &id))
                .into_any_element()
            } else {
                Button::new(
                    ElementId::Name(format!("switch-{id}").into()),
                    st.switch.clone(),
                )
                .disabled(busy)
                .on_click(account_click(&actions.on_switch, &id))
                .into_any_element()
            };
            let backend = backend_label(a.backend, &st);
            div()
                .id(ElementId::Name(format!("account-{id}").into()))
                .role(Role::Group)
                .aria_label(
                    [a.name.clone(), a.email.clone(), a.server.clone(), status]
                        .into_iter()
                        .filter(|s| !s.is_empty())
                        .collect::<Vec<_>>()
                        .join(", "),
                )
                .w_full()
                .px(px(12.))
                .py(px(10.))
                .flex()
                .items_center()
                .gap(px(12.))
                .child(
                    div()
                        .relative()
                        .child(avatar(
                            &a.initials(),
                            34.,
                            with_alpha(r.text, if t.dark { 0.16 } else { 0.08 }),
                            r.text,
                        ))
                        .child(
                            div()
                                .absolute()
                                .right(px(-5.))
                                .bottom(px(-4.))
                                .size(px(17.))
                                .rounded_full()
                                .bg(t.surfaces.panel)
                                .border_1()
                                .border_color(r.border)
                                .flex()
                                .items_center()
                                .justify_center()
                                .child(icon(backend_icon(a.backend), 10., r.text_subtle)),
                        ),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .gap(px(1.))
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap(px(6.))
                                .child(
                                    div()
                                        .text_size(px(m.control))
                                        .font_weight(FontWeight::MEDIUM)
                                        .text_color(r.text)
                                        .child(a.name.clone()),
                                )
                                .when(a.needs_sign_in, |d| {
                                    d.child(icon(IconName::CircleAlert, 13., r.warning))
                                }),
                        )
                        .child(
                            div()
                                .truncate()
                                .text_size(px(m.small))
                                .text_color(r.text_subtle)
                                .child(SharedString::from(
                                    [a.email.as_ref(), a.server.as_ref(), backend.as_ref()]
                                        .into_iter()
                                        .filter(|s| !s.is_empty())
                                        .collect::<Vec<_>>()
                                        .join(" \u{b7} "),
                                )),
                        )
                        .when(a.needs_sign_in, |d| {
                            d.child(
                                div()
                                    .text_size(px(m.small))
                                    .text_color(crate::theme::legible_text(
                                        r.warning,
                                        r.text,
                                        t.surfaces.panel,
                                        4.5,
                                    ))
                                    .child(st.session_expired.clone()),
                            )
                        }),
                )
                .child(trailing)
                .child(
                    IconButton::new(
                        ElementId::Name(format!("account-more-{id}").into()),
                        IconName::Ellipsis,
                        fill(&st.more_actions_for, &[("name", &a.name)]),
                    )
                    .tooltip(st.more.clone())
                    .size(26., 15.)
                    .on_click(account_click(&actions.on_more, &id)),
                )
                .into_any_element()
        })
        .collect();
    div()
        .id("accounts-list")
        .role(Role::List)
        .aria_label(st.accounts.clone())
        .child(grouped(rows, cx))
}
