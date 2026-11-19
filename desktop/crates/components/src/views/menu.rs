//! Menus and toasts.
//!
//! The app shows real NSMenus (GPUI Kit's `native_menu::NativeMenu` for
//! context menus, tray-icon for the menu-bar item), which follow the system
//! appearance and accent, not the palette. [`MenuReplica`] draws the same
//! look in GPUI for the gallery, because an open NSMenu runs a modal
//! tracking loop that can't be captured in-process. [`Toast`] is in-app UI
//! and uses the palette.

use gpui_kit::prelude::*;
use gpui_kit::{
    App, BoxShadow, ElementId, FontWeight, Hsla, Role, SharedString, Window, div, point, px, rgb,
    rgba,
};

use crate::assets::{IconName, icon};
use crate::strings::ActiveStrings as _;
use crate::theme::{ActiveConduitTheme, with_alpha};
use crate::views::kit::{IconButton, overlay_shadow};

/// One NSMenu entry.
#[derive(Clone, Debug, PartialEq)]
pub enum MenuEntry {
    Item {
        label: SharedString,
        shortcut: Option<SharedString>,
        icon: Option<IconName>,
        checked: bool,
        destructive: bool,
        submenu: bool,
        disabled: bool,
    },
    Header(SharedString),
    Separator,
}

impl MenuEntry {
    pub fn item(label: impl Into<SharedString>) -> Self {
        Self::Item {
            label: label.into(),
            shortcut: None,
            icon: None,
            checked: false,
            destructive: false,
            submenu: false,
            disabled: false,
        }
    }
    pub fn shortcut(self, keys: impl Into<SharedString>) -> Self {
        self.map(|i| {
            if let Self::Item { shortcut, .. } = i {
                *shortcut = Some(keys.into());
            }
        })
    }
    pub fn icon(self, name: IconName) -> Self {
        self.map(|i| {
            if let Self::Item { icon, .. } = i {
                *icon = Some(name);
            }
        })
    }
    pub fn checked(self) -> Self {
        self.map(|i| {
            if let Self::Item { checked, .. } = i {
                *checked = true;
            }
        })
    }
    pub fn destructive(self) -> Self {
        self.map(|i| {
            if let Self::Item { destructive, .. } = i {
                *destructive = true;
            }
        })
    }
    pub fn submenu(self) -> Self {
        self.map(|i| {
            if let Self::Item { submenu, .. } = i {
                *submenu = true;
            }
        })
    }
    pub fn disabled(self) -> Self {
        self.map(|i| {
            if let Self::Item { disabled, .. } = i {
                *disabled = true;
            }
        })
    }
    fn map(mut self, f: impl FnOnce(&mut Self)) -> Self {
        f(&mut self);
        self
    }
}

/// System menu colours for the current appearance (NSMenu ignores the
/// palette).
struct MenuColors {
    bg: Hsla,
    border: Hsla,
    text: Hsla,
    secondary: Hsla,
    separator: Hsla,
    highlight: Hsla,
    destructive: Hsla,
}

fn menu_colors(dark: bool, accent: Hsla) -> MenuColors {
    if dark {
        MenuColors {
            bg: rgba(0x2a2a2cf5).into(),
            border: rgba(0xffffff26).into(),
            text: rgb(0xf2f2f2).into(),
            secondary: rgba(0xffffff8c).into(),
            separator: rgba(0xffffff1f).into(),
            highlight: accent,
            destructive: rgb(0xff6961).into(),
        }
    } else {
        MenuColors {
            bg: rgba(0xf6f6f6f5).into(),
            border: rgba(0x0000001f).into(),
            text: rgb(0x1d1d1f).into(),
            secondary: rgba(0x00000080).into(),
            separator: rgba(0x0000001a).into(),
            highlight: accent,
            destructive: rgb(0xd70015).into(),
        }
    }
}

/// An NSMenu drawn in GPUI (gallery only; see the module docs).
#[derive(IntoElement)]
pub struct MenuReplica {
    id: SharedString,
    entries: Vec<MenuEntry>,
    highlighted: Option<usize>,
    width: f32,
}

impl MenuReplica {
    pub fn new(id: impl Into<SharedString>, entries: Vec<MenuEntry>) -> Self {
        Self {
            id: id.into(),
            entries,
            highlighted: None,
            width: 240.,
        }
    }
    pub fn highlighted(mut self, index: usize) -> Self {
        self.highlighted = Some(index);
        self
    }
    pub fn width(mut self, width: f32) -> Self {
        self.width = width;
        self
    }
}

impl RenderOnce for MenuReplica {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit();
        let c = menu_colors(t.dark, t.system_accent);
        let white: Hsla = gpui_kit::white();
        let id = self.id.clone();
        div()
            .id(ElementId::Name(id.clone()))
            .role(Role::Menu)
            .aria_label(id.clone())
            .w(px(self.width))
            .p(px(5.))
            .flex()
            .flex_col()
            .rounded(px(10.))
            .border_1()
            .border_color(c.border)
            .bg(c.bg)
            .shadow(vec![
                BoxShadow {
                    color: with_alpha(gpui_kit::black(), if t.dark { 0.5 } else { 0.18 }),
                    offset: point(px(0.), px(10.)),
                    blur_radius: px(30.),
                    spread_radius: px(0.),
                    inset: false,
                },
                BoxShadow {
                    color: with_alpha(gpui_kit::black(), 0.12),
                    offset: point(px(0.), px(0.)),
                    blur_radius: px(1.),
                    spread_radius: px(0.),
                    inset: false,
                },
            ])
            .font_family(crate::theme::UI_FONT)
            .children(self.entries.into_iter().enumerate().map(move |(i, e)| {
                match e {
                    MenuEntry::Separator => div()
                        .mx(px(9.))
                        .my(px(5.))
                        .h(px(1.))
                        .bg(c.separator)
                        .into_any_element(),
                    MenuEntry::Header(label) => div()
                        .h(px(22.))
                        .px(px(9.))
                        .flex()
                        .items_center()
                        .text_size(px(11.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(c.secondary)
                        .child(label)
                        .into_any_element(),
                    MenuEntry::Item {
                        label,
                        shortcut,
                        icon: ic,
                        checked,
                        destructive,
                        submenu,
                        disabled,
                    } => {
                        let hot = self.highlighted == Some(i) && !disabled;
                        let fg = if hot {
                            white
                        } else if disabled {
                            c.secondary
                        } else if destructive {
                            c.destructive
                        } else {
                            c.text
                        };
                        let sub = if hot {
                            with_alpha(white, 0.8)
                        } else {
                            c.secondary
                        };
                        div()
                            .id(ElementId::NamedInteger(id.clone(), i as u64))
                            .role(Role::MenuItem)
                            .aria_label(label.clone())
                            .when_some(shortcut.clone(), |d, k| d.aria_keyshortcuts(k))
                            .h(px(24.))
                            .pl(px(6.))
                            .pr(px(9.))
                            .flex()
                            .items_center()
                            .gap(px(6.))
                            .rounded(px(5.))
                            .when(hot, |d| d.bg(c.highlight))
                            .child(
                                div()
                                    .w(px(14.))
                                    .flex()
                                    .justify_center()
                                    .when(checked, |d| d.child(icon(IconName::Check, 12., fg))),
                            )
                            .when_some(ic, |d, ic| d.child(icon(ic, 15., fg)))
                            .child(
                                div()
                                    .flex_1()
                                    .text_size(px(13.))
                                    .text_color(fg)
                                    .child(label),
                            )
                            .when_some(shortcut, |d, k| {
                                d.child(div().text_size(px(13.)).text_color(sub).child(k))
                            })
                            .when(submenu, |d| d.child(icon(IconName::ChevronRight, 12., sub)))
                            .on_click(|_, _, _| {})
                            .into_any_element()
                    }
                }
            }))
    }
}

/// Toast tone.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToastTone {
    Success,
    Info,
    Warning,
    Error,
}

/// An in-app toast (daemon `notify.show`, copy confirmations).
#[derive(IntoElement)]
pub struct Toast {
    id: SharedString,
    tone: ToastTone,
    title: SharedString,
    detail: Option<SharedString>,
    action: Option<SharedString>,
}

impl Toast {
    pub fn new(
        id: impl Into<SharedString>,
        tone: ToastTone,
        title: impl Into<SharedString>,
    ) -> Self {
        Self {
            id: id.into(),
            tone,
            title: title.into(),
            detail: None,
            action: None,
        }
    }
    pub fn detail(mut self, d: impl Into<SharedString>) -> Self {
        self.detail = Some(d.into());
        self
    }
    pub fn action(mut self, a: impl Into<SharedString>) -> Self {
        self.action = Some(a.into());
        self
    }
}

impl RenderOnce for Toast {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let st = cx.strings().clone();
        let r = t.roles;
        let m = t.metrics;
        let (ic, color) = match self.tone {
            ToastTone::Success => (IconName::CircleCheck, r.success),
            ToastTone::Info => (IconName::Info, r.text_subtle),
            ToastTone::Warning => (IconName::CircleAlert, r.warning),
            ToastTone::Error => (IconName::CircleAlert, r.danger),
        };
        let id = self.id.to_string();
        div()
            .id(ElementId::Name(format!("toast-{id}").into()))
            .role(Role::Alert)
            .aria_label(match &self.detail {
                Some(d) => format!("{}. {d}", self.title),
                None => self.title.to_string(),
            })
            .w(px(340.))
            .p(px(10.))
            .pl(px(12.))
            .flex()
            .items_start()
            .gap(px(10.))
            .rounded(px(12.))
            .border_1()
            .border_color(r.border_strong)
            .bg(r.overlay)
            .shadow(overlay_shadow(&t))
            .child(div().pt(px(1.)).child(icon(ic, 17., color)))
            .child(
                div()
                    .flex_1()
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .child(
                        div()
                            .text_size(px(m.control))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(r.text)
                            .child(self.title.clone()),
                    )
                    .when_some(self.detail.clone(), |d, s| {
                        d.child(
                            div()
                                .text_size(px(m.small))
                                .text_color(r.text_subtle)
                                .child(s),
                        )
                    }),
            )
            .when_some(self.action.clone(), |d, a| {
                d.child(
                    div()
                        .id(ElementId::Name(format!("toast-action-{id}").into()))
                        .role(Role::Button)
                        .aria_label(a.clone())
                        .h(px(24.))
                        .px(px(8.))
                        .flex()
                        .items_center()
                        .rounded(px(6.))
                        .cursor_pointer()
                        .hover(|s| s.bg(r.hover))
                        .text_size(px(m.small))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text)
                        .child(a)
                        .on_click(|_, _, _| {}),
                )
            })
            .child(
                IconButton::new(
                    ElementId::Name(format!("toast-close-{id}").into()),
                    IconName::X,
                    st.dismiss.clone(),
                )
                .size(22., 13.),
            )
    }
}
