//! ☰: the menu the app draws in place of the Mac's menu bar.
//!
//! It works like an NSMenu: items are greyed when it opens, by the same
//! `App::is_action_available` question AppKit asks for the Mac's menus; it
//! takes the keyboard while open (Esc, arrows, Enter) before any binding
//! does; and the chosen action goes to whatever had focus before it opened.

use std::rc::Rc;

use gpui_kit::prelude::*;
use gpui_kit::{
    Action, Anchor, AnyElement, App, Context, ElementId, Entity, FocusHandle, Hsla, MouseButton,
    MouseDownEvent, Pixels, Point, Role, SharedString, Subscription, Window, anchored, deferred,
    div, point, px,
};

use super::ChromeStyle;
use super::keys::{menu_key, opens_main_menu};
use super::menu::{ChromeMenuItem, Cursor, Outcome, ZoomPart, grey};
use crate::assets::{IconName, icon};
use crate::theme::{ActiveConduitTheme, ConduitTheme, UI_FONT, with_alpha};
use crate::views::kit::overlay_shadow;

/// Builds ☰'s items when it opens (the app's menus as they stand).
pub type MenuItems = Rc<dyn Fn(&mut Window, &mut App) -> Vec<ChromeMenuItem>>;

/// ☰'s state: shut, or open with its items as they were when it opened.
pub struct MainMenu {
    style: ChromeStyle,
    label: SharedString,
    build: MenuItems,
    items: Vec<ChromeMenuItem>,
    open: bool,
    cursor: Cursor,
    focus: FocusHandle,
    /// What had focus before it opened: it gets focus and the chosen action
    /// back.
    return_focus: Option<FocusHandle>,
    /// A press outside closed it: the same press on ☰ must not open it again.
    dismissed_at: Option<Point<Pixels>>,
    _intercept: Subscription,
}

impl MainMenu {
    /// `label`: ☰'s accessible name, which the open menu reads out too.
    pub fn new(
        style: ChromeStyle,
        label: impl Into<SharedString>,
        build: MenuItems,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let home = window.window_handle();
        let menu = cx.entity().downgrade();
        // Keystrokes reach interceptors before any key binding: F10 and a
        // lone Alt open the menu, and while it is open its keys can't be
        // taken by a binding without a context (Esc's Stop).
        let intercept = cx.intercept_keystrokes(move |event, window, cx| {
            if window.window_handle() != home {
                return;
            }
            let Some(menu) = menu.upgrade() else {
                return;
            };
            if menu.update(cx, |m, cx| m.key(&event.keystroke, window, cx)) {
                cx.stop_propagation();
            }
        });
        Self {
            style,
            label: label.into(),
            build,
            items: vec![],
            open: false,
            cursor: Cursor::default(),
            focus: cx.focus_handle(),
            return_focus: None,
            dismissed_at: None,
            _intercept: intercept,
        }
    }

    pub fn style(&self) -> ChromeStyle {
        self.style
    }

    pub fn label(&self) -> &SharedString {
        &self.label
    }

    pub fn is_open(&self) -> bool {
        self.open
    }

    /// The items as last opened (greyed).
    pub fn items(&self) -> &[ChromeMenuItem] {
        &self.items
    }

    pub fn cursor(&self) -> &Cursor {
        &self.cursor
    }

    /// Opens it, or closes it when open: ☰'s click, F10, Alt.
    pub fn toggle(&mut self, by_keyboard: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.open {
            self.close(window, cx);
        } else {
            self.open(by_keyboard, window, cx);
        }
    }

    /// Opens it with fresh items. AppKit-style greying asks the app which
    /// actions have a handler where focus is now, so it runs before focus
    /// moves into the menu, and outside this window's update:
    /// `App::is_action_available` asks the active window, which it can't
    /// read while this window is being updated.
    pub fn open(&mut self, by_keyboard: bool, window: &mut Window, cx: &mut Context<Self>) {
        let items = (self.build)(window, cx);
        self.return_focus = window.focused(cx);
        let menu = cx.entity().downgrade();
        let home = window.window_handle();
        cx.defer(move |cx| {
            let items = grey(items, &mut |a| cx.is_action_available(a));
            let _ = home.update(cx, |_, window, cx| {
                let _ = menu.update(cx, |m, cx| m.show(items, by_keyboard, window, cx));
            });
        });
    }

    fn show(
        &mut self,
        items: Vec<ChromeMenuItem>,
        by_keyboard: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.cursor = if by_keyboard {
            Cursor::opened_by_keyboard(&items)
        } else {
            Cursor::default()
        };
        self.items = items;
        self.open = true;
        window.focus(&self.focus, cx);
        cx.notify();
    }

    pub fn close(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.open {
            return;
        }
        self.open = false;
        self.cursor = Cursor::default();
        if let Some(back) = self.return_focus.clone() {
            window.focus(&back, cx);
        }
        cx.notify();
    }

    /// One keystroke, closed or open; true when the menu used it.
    fn key(
        &mut self,
        keystroke: &gpui_kit::Keystroke,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.open {
            if opens_main_menu(self.style, keystroke) {
                self.toggle(true, window, cx);
                return true;
            }
            return false;
        }
        let Some(key) = menu_key(self.style, keystroke) else {
            return false;
        };
        match self.cursor.key(&self.items, key) {
            Outcome::None => {}
            Outcome::Moved => cx.notify(),
            Outcome::Activate { action, keep_open } => self.activate(action, keep_open, window, cx),
            Outcome::Close => self.close(window, cx),
        }
        true
    }

    /// Runs `action` where focus was before the menu opened. The zoom row's
    /// parts keep it open, with items read again once the action has run.
    fn activate(
        &mut self,
        action: Box<dyn Action>,
        keep_open: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let target = self.return_focus.clone();
        if !keep_open {
            self.close(window, cx);
        }
        match &target {
            Some(focus) => focus.dispatch_action(action.as_ref(), window, cx),
            None => window.dispatch_action(action, cx),
        }
        if keep_open {
            let menu = cx.entity().downgrade();
            let home = window.window_handle();
            let build = self.build.clone();
            // After the action, which is deferred too.
            cx.defer(move |cx| {
                let Ok(items) = home.update(cx, |_, window, cx| build(window, cx)) else {
                    return;
                };
                let items = grey(items, &mut |a| cx.is_action_available(a));
                let _ = menu.update(cx, |m, cx| {
                    m.items = items;
                    cx.notify();
                });
            });
        }
    }

    /// The pointer is over row `index` at `level`: it is highlighted, and a
    /// submenu row opens its submenu.
    pub fn hover(&mut self, level: usize, index: usize, cx: &mut Context<Self>) {
        let before = self.cursor.clone();
        self.cursor.hover(&self.items, level, index);
        if self.cursor != before {
            cx.notify();
        }
    }

    fn click_row(
        &mut self,
        level: usize,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.cursor.hover(&self.items, level, index);
        let Some(rows) = self.cursor.rows(&self.items, level) else {
            return;
        };
        if let Some(ChromeMenuItem::Action {
            action,
            disabled: false,
            ..
        }) = rows.get(index)
        {
            let action = action.boxed_clone();
            self.activate(action, false, window, cx);
        }
        cx.notify();
    }

    fn click_zoom(&mut self, action: Box<dyn Action>, window: &mut Window, cx: &mut Context<Self>) {
        self.activate(action, true, window, cx);
    }

    /// A press outside the open menu closes it.
    fn dismiss(&mut self, at: Point<Pixels>, window: &mut Window, cx: &mut Context<Self>) {
        if self.open {
            self.dismissed_at = Some(at);
            self.close(window, cx);
        }
    }

    /// ☰ was pressed at `at`.
    pub fn press(&mut self, at: Point<Pixels>, window: &mut Window, cx: &mut Context<Self>) {
        if self.dismissed_at.take() == Some(at) {
            return;
        }
        self.toggle(false, window, cx);
    }
}

/// How each style draws its menus: the platform's shape in the palette's
/// colours.
struct Look {
    width: f32,
    submenu_width: f32,
    padding: f32,
    row: f32,
    separator: f32,
    zoom_row: f32,
    radius: f32,
    row_radius: f32,
    text: f32,
}

impl Look {
    fn of(style: ChromeStyle, t: &ConduitTheme) -> Self {
        match style {
            // WinUI's MenuFlyout.
            ChromeStyle::Windows => Self {
                width: 280.,
                submenu_width: 300.,
                padding: 4.,
                row: 30.,
                separator: 9.,
                zoom_row: 30.,
                radius: 8.,
                row_radius: 4.,
                text: t.metrics.body,
            },
            // libadwaita's popover menu.
            ChromeStyle::Gnome => Self {
                width: 280.,
                submenu_width: 280.,
                padding: 6.,
                row: 32.,
                separator: 13.,
                zoom_row: 44.,
                radius: 12.,
                row_radius: 6.,
                text: t.metrics.body,
            },
        }
    }

    fn height(&self, item: &ChromeMenuItem) -> f32 {
        match item {
            ChromeMenuItem::Separator => self.separator,
            ChromeMenuItem::Zoom(_) => self.zoom_row,
            _ => self.row,
        }
    }

    /// The top of row `index` inside its panel.
    fn row_top(&self, rows: &[ChromeMenuItem], index: usize) -> f32 {
        self.padding + rows.iter().take(index).map(|r| self.height(r)).sum::<f32>()
    }
}

/// The open menu's panels: the menu, then each open submenu beside the row
/// that opened it.
fn panels(menu: &MainMenu, window: &mut Window, cx: &mut Context<MainMenu>) -> AnyElement {
    let t = cx.conduit().clone();
    let look = Look::of(menu.style, &t);
    let levels = menu.cursor.open_levels(&menu.items);
    let mut x = 0.;
    let mut y = 0.;
    let mut out = div().relative().w(px(look.width));
    for level in 0..levels {
        let Some(rows) = menu.cursor.rows(&menu.items, level) else {
            break;
        };
        let width = if level == 0 {
            look.width
        } else {
            look.submenu_width
        };
        let label = if level == 0 {
            menu.label.clone()
        } else {
            menu.cursor
                .rows(&menu.items, level - 1)
                .and_then(|parent| parent.get(menu.cursor.path[level - 1]))
                .and_then(|r| r.label().cloned())
                .unwrap_or_default()
        };
        let panel = panel(menu, level, rows, label, width, &look, &t, window, cx);
        out = out.child(
            div()
                .absolute()
                .left(px(x))
                .top(px(y))
                .w(px(width))
                .child(panel),
        );
        // The next submenu opens beside its row, its first row level with it.
        if let Some(&at) = menu.cursor.path.get(level) {
            x += width - 4.;
            y += look.row_top(rows, at) - look.padding;
        }
    }
    out.into_any_element()
}

#[allow(clippy::too_many_arguments)]
fn panel(
    menu: &MainMenu,
    level: usize,
    rows: &[ChromeMenuItem],
    label: SharedString,
    width: f32,
    look: &Look,
    t: &ConduitTheme,
    window: &mut Window,
    cx: &mut Context<MainMenu>,
) -> AnyElement {
    let r = t.roles;
    let highlighted = menu.cursor.path.get(level).copied();
    let entity = cx.entity().downgrade();
    // A column for check marks only where a row has one.
    let checks = rows
        .iter()
        .any(|r| matches!(r, ChromeMenuItem::Action { checked: true, .. }));
    div()
        .id(ElementId::Name(format!("chrome-menu-{level}").into()))
        .role(Role::Menu)
        .aria_label(label)
        .when(level == 0, |d| d.track_focus(&menu.focus))
        .w(px(width))
        .p(px(look.padding))
        .flex()
        .flex_col()
        .rounded(px(look.radius))
        .border_1()
        .border_color(r.border)
        .bg(r.overlay)
        .shadow(overlay_shadow(t))
        .font_family(UI_FONT)
        .text_size(px(look.text))
        .text_color(r.text)
        // A press in a submenu is not outside the menu.
        .on_mouse_down(MouseButton::Left, |_, window, cx| {
            window.prevent_default();
            cx.stop_propagation();
        })
        .children(rows.iter().enumerate().map(|(i, row)| {
            let on = highlighted == Some(i);
            match row {
                ChromeMenuItem::Separator => div()
                    .h(px(look.separator))
                    .flex()
                    .items_center()
                    .child(div().w_full().h(px(1.)).bg(r.divider))
                    .into_any_element(),
                ChromeMenuItem::Zoom(zoom) => {
                    zoom_row(menu, level, i, zoom, on, look, t, window, cx).into_any_element()
                }
                ChromeMenuItem::Action {
                    label,
                    shortcut,
                    checked,
                    disabled,
                    ..
                } => {
                    let entity = entity.clone();
                    let entity_hover = entity.clone();
                    row_box(level, i, look, on, *disabled, t)
                        .role(if *checked {
                            Role::MenuItemCheckBox
                        } else {
                            Role::MenuItem
                        })
                        .aria_label(label.clone())
                        .when(*checked, |d| d.aria_toggled(gpui_kit::Toggled::True))
                        .when_some(shortcut.clone(), |d, s| d.aria_keyshortcuts(s))
                        .when(on, |d| d.aria_active_descendant())
                        .on_mouse_move(move |_, _, cx| {
                            let _ = entity_hover.update(cx, |m, cx| m.hover(level, i, cx));
                        })
                        .on_click(move |_, window, cx| {
                            let _ = entity.update(cx, |m, cx| m.click_row(level, i, window, cx));
                        })
                        .when(checks, |d| {
                            d.child(
                                div().w(px(18.)).flex_none().when(*checked, |d| {
                                    d.child(icon(IconName::Check, 14., r.text))
                                }),
                            )
                        })
                        .child(div().flex_1().min_w_0().truncate().child(label.clone()))
                        .children(shortcut.clone().map(|s| {
                            div()
                                .flex_none()
                                .pl(px(16.))
                                .text_size(px(t.metrics.small))
                                .text_color(r.text_subtle)
                                .child(s)
                        }))
                        .into_any_element()
                }
                ChromeMenuItem::Submenu {
                    label, disabled, ..
                } => {
                    let entity = entity.clone();
                    row_box(level, i, look, on, *disabled, t)
                        .role(Role::MenuItem)
                        .aria_label(label.clone())
                        .aria_expanded(on)
                        .when(on, |d| d.aria_active_descendant())
                        .on_mouse_move(move |_, _, cx| {
                            let _ = entity.update(cx, |m, cx| m.hover(level, i, cx));
                        })
                        .when(checks, |d| d.child(div().w(px(18.)).flex_none()))
                        .child(div().flex_1().min_w_0().truncate().child(label.clone()))
                        .child(icon(IconName::ChevronRight, 14., r.text_subtle))
                        .into_any_element()
                }
            }
        }))
        .into_any_element()
}

fn row_box(
    level: usize,
    index: usize,
    look: &Look,
    on: bool,
    disabled: bool,
    t: &ConduitTheme,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    let r = t.roles;
    div()
        .id(ElementId::Name(
            format!("chrome-menu-{level}-{index}").into(),
        ))
        .h(px(look.row))
        .px(px(8.))
        .flex()
        .items_center()
        .rounded(px(look.row_radius))
        .when(on && !disabled, |d| d.bg(r.overlay_hover))
        .when(disabled, |d| d.text_color(with_alpha(r.text, 0.38)))
}

#[allow(clippy::too_many_arguments)]
fn zoom_row(
    menu: &MainMenu,
    level: usize,
    index: usize,
    zoom: &super::menu::ZoomRow,
    on: bool,
    look: &Look,
    t: &ConduitTheme,
    _window: &mut Window,
    cx: &mut Context<MainMenu>,
) -> impl IntoElement {
    let r = t.roles;
    let entity = cx.entity().downgrade();
    let part_on = |k: usize| on && menu.cursor.part == k;
    let button = |k: usize, part: &ZoomPart, body: AnyElement| {
        let entity = entity.clone();
        let action = part.action.boxed_clone();
        let disabled = part.disabled;
        div()
            .id(ElementId::Name(format!("chrome-zoom-{k}").into()))
            .role(Role::Button)
            .aria_label(part.label.clone())
            .when(part_on(k), |d| d.aria_active_descendant())
            .h(px(32.))
            .min_w(px(32.))
            .px(px(8.))
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(look.row_radius))
            .when(part_on(k) && !disabled, |d| d.bg(r.overlay_hover))
            .when(!disabled, |d| d.hover(|s| s.bg(r.overlay_hover)))
            .when(disabled, |d| d.opacity(0.38))
            .on_click(move |_, window, cx| {
                if disabled {
                    return;
                }
                let action = action.boxed_clone();
                let _ = entity.update(cx, |m, cx| m.click_zoom(action, window, cx));
            })
            .child(body)
    };
    div()
        .id(ElementId::Name(
            format!("chrome-menu-{level}-{index}").into(),
        ))
        .role(Role::Group)
        .h(px(look.zoom_row))
        .px(px(4.))
        .flex()
        .items_center()
        .justify_between()
        .child(button(
            0,
            &zoom.out,
            icon(IconName::ZoomOut, 16., r.text).into_any_element(),
        ))
        .child(button(
            1,
            &zoom.reset,
            div().child(zoom.level.clone()).into_any_element(),
        ))
        .child(button(
            2,
            &zoom.zoom_in,
            icon(IconName::ZoomIn, 16., r.text).into_any_element(),
        ))
}

impl Render for MainMenu {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if !self.open {
            return div().into_any_element();
        }
        let menu = cx.entity().downgrade();
        div()
            .id("chrome-menu-outside")
            .on_mouse_down_out(move |e: &MouseDownEvent, window, cx| {
                let _ = menu.update(cx, |m, cx| m.dismiss(e.position, window, cx));
            })
            .child(panels(self, window, cx))
            .into_any_element()
    }
}

/// ☰ itself, with the open menu below it.
#[derive(IntoElement)]
pub struct MainMenuButton {
    menu: Entity<MainMenu>,
}

impl MainMenuButton {
    pub fn new(menu: Entity<MainMenu>) -> Self {
        Self { menu }
    }
}

impl RenderOnce for MainMenuButton {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let (style, label, open) = {
            let m = self.menu.read(cx);
            (m.style, m.label.clone(), m.open)
        };
        let size = super::layout::MENU_BUTTON;
        let press = self.menu.clone();
        let opened = open.then(|| {
            let look = Look::of(style, &t);
            let anchor = match style {
                ChromeStyle::Windows => Anchor::TopLeft,
                ChromeStyle::Gnome => Anchor::TopRight,
            };
            // Windows drops the menu from ☰'s leading edge; GNOME's popover
            // hangs centred under it, kept inside the window.
            let offset = match style {
                ChromeStyle::Windows => point(px(0.), px(size + 4.)),
                ChromeStyle::Gnome => point(px(look.width / 2. + size / 2.), px(size + 6.)),
            };
            deferred(
                anchored()
                    .anchor(anchor)
                    .offset(offset)
                    .snap_to_window_with_margin(px(8.))
                    .child(self.menu.clone()),
            )
            .with_priority(1)
        });
        let hover = with_alpha(r.text, if t.dark { 0.10 } else { 0.07 });
        div()
            .relative()
            .flex_none()
            .child(
                div()
                    .id("main-menu")
                    .role(Role::Button)
                    .aria_label(label)
                    .aria_expanded(open)
                    .occlude()
                    .size(px(size))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(match style {
                        ChromeStyle::Windows => 4.,
                        ChromeStyle::Gnome => 6.,
                    }))
                    .when(open, |d| d.bg(hover))
                    .hover(move |s| s.bg(hover))
                    .on_mouse_down(MouseButton::Left, move |e, window, cx| {
                        window.prevent_default();
                        cx.stop_propagation();
                        let at = e.position;
                        press.update(cx, |m, cx| m.press(at, window, cx));
                    })
                    .child(icon(IconName::Menu, 16., r.text)),
            )
            .children(opened)
    }
}

/// A colour a little off the header's, for flat header-bar buttons.
pub fn flat_hover(t: &ConduitTheme) -> Hsla {
    with_alpha(t.roles.text, if t.dark { 0.10 } else { 0.07 })
}
