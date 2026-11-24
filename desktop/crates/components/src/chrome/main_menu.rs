//! ☰: the menu the app draws in place of the Mac's menu bar.
//!
//! It works like an NSMenu: items are greyed when it opens, by the same
//! `App::is_action_available` question AppKit asks for the Mac's menus; it
//! takes the keyboard while open (Esc, arrows, Enter) before any binding
//! does; and the chosen action goes to whatever had focus before it opened.

use std::cell::Cell;
use std::rc::Rc;

use gpui_kit::base::{Scrollbar, ScrollbarMode};
use gpui_kit::prelude::*;
use gpui_kit::{
    Action, Anchor, AnyElement, App, Bounds, Context, ElementId, Entity, FocusHandle, Hsla,
    MouseButton, MouseDownEvent, Pixels, Point, Role, ScrollHandle, SharedString, Subscription,
    Window, anchored, canvas, deferred, div, point, px,
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
    /// The window's own focus: where the menu acts, and focus goes back,
    /// when nothing in the window had focus.
    home: Option<FocusHandle>,
    /// Where ☰ was last drawn: a press there is ☰'s own, not one outside
    /// the menu, and the menu fits itself to the window from there.
    trigger: Rc<Cell<Option<Bounds<Pixels>>>>,
    /// Each open panel's scroll, for panels taller than the window, and the
    /// highlighted path above it that owns it: another submenu at that level
    /// starts at its top.
    scrolls: Vec<(Vec<usize>, ScrollHandle)>,
    _intercept: Subscription,
    _focus_out: Subscription,
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
        // lone Alt open the menu (not the Alt Windows' activation injects),
        // and while it is open its keys can't be taken by a binding without
        // a context (Esc's Stop). A prompt the window draws keeps the
        // keyboard, as the app's interceptors leave it.
        let intercept = cx.intercept_keystrokes(move |event, window, cx| {
            if window.window_handle() != home {
                return;
            }
            if super::activation::is_injected_alt(home, &event.keystroke, cx) {
                cx.stop_propagation();
                return;
            }
            if window.has_active_prompt() {
                return;
            }
            let Some(menu) = menu.upgrade() else {
                return;
            };
            if menu.update(cx, |m, cx| m.key(&event.keystroke, window, cx)) {
                cx.stop_propagation();
            }
        });
        let focus = cx.focus_handle();
        // Focus taken elsewhere (a chord's command opened the palette)
        // closes it, and leaves focus there.
        let focus_out = cx.on_focus_out(&focus, window, |m, _, _, cx| m.let_go(cx));
        Self {
            style,
            label: label.into(),
            build,
            items: vec![],
            open: false,
            cursor: Cursor::default(),
            focus,
            return_focus: None,
            home: None,
            trigger: Rc::default(),
            scrolls: vec![],
            _intercept: intercept,
            _focus_out: focus_out,
        }
    }

    /// The window's own focus, for when nothing in it has focus: the menu
    /// greys and runs its rows as the window would, as the Mac's menu bar
    /// acts for the key window.
    pub fn home(mut self, home: FocusHandle) -> Self {
        self.home = Some(home);
        self
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
        if window.focused(cx).is_none()
            && let Some(home) = &self.home
        {
            window.focus(home, cx);
        }
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
        self.scrolls.clear();
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
        match self.return_focus.clone() {
            Some(back) => window.focus(&back, cx),
            None => window.blur(cx),
        }
        cx.notify();
    }

    /// Focus left the menu for something else: it closes, leaving focus be.
    fn let_go(&mut self, cx: &mut Context<Self>) {
        if self.open {
            self.open = false;
            self.cursor = Cursor::default();
            cx.notify();
        }
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
            Outcome::Moved => {
                self.keep_row_in_view();
                cx.notify()
            }
            Outcome::Activate { action, keep_open } => self.activate(action, keep_open, window, cx),
            Outcome::Close => self.close(window, cx),
        }
        true
    }

    /// The keyboard keeps its row in view in a panel that scrolls.
    fn keep_row_in_view(&mut self) {
        if let Some(&row) = self.cursor.path.last() {
            let level = self.cursor.path.len() - 1;
            self.scroll(level).scroll_to_item(row);
        }
    }

    fn scroll(&mut self, level: usize) -> ScrollHandle {
        let owner = self.cursor.path[..level.min(self.cursor.path.len())].to_vec();
        while self.scrolls.len() <= level {
            self.scrolls.push((owner.clone(), ScrollHandle::new()));
        }
        if self.scrolls[level].0 != owner {
            self.scrolls[level] = (owner, ScrollHandle::new());
        }
        self.scrolls[level].1.clone()
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
                    let row = m.cursor.path.clone();
                    m.cursor.settle(&m.items);
                    if m.cursor.path != row {
                        m.keep_row_in_view();
                    }
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

    fn hover_part(&mut self, level: usize, index: usize, part: usize, cx: &mut Context<Self>) {
        let before = self.cursor.clone();
        self.cursor.hover_part(&self.items, level, index, part);
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

    /// A press outside the open menu closes it; one on ☰ is ☰'s to answer.
    fn dismiss(&mut self, at: Point<Pixels>, window: &mut Window, cx: &mut Context<Self>) {
        if self.trigger.get().is_some_and(|b| b.contains(&at)) {
            return;
        }
        self.close(window, cx);
    }

    /// The window around where the menu hangs from ☰, as `place` fits panels
    /// into it: inside GNOME's frame, which a floating client-side decorated
    /// window draws a shadow's width inside its surface.
    fn room(&self, window: &Window, look: &Look, cx: &App) -> Room {
        let viewport = window.viewport_size();
        let (w, h) = (f32::from(viewport.width), f32::from(viewport.height));
        let frame = match super::active(cx) {
            Some(c) if c.style == ChromeStyle::Gnome && !c.maximized => match c.decorations {
                gpui_kit::Decorations::Client { tiling } => super::controls::frame_insets(tiling),
                gpui_kit::Decorations::Server => gpui_kit::Edges::default(),
            },
            _ => gpui_kit::Edges::default(),
        };
        let (x, y) = match self.trigger.get() {
            Some(b) => {
                let (left, top) = (f32::from(b.left()), f32::from(b.top()));
                let size = f32::from(b.size.width);
                match self.style {
                    ChromeStyle::Windows => (left, top + size + DROP),
                    ChromeStyle::Gnome => (left + size / 2. - look.width / 2., top + size + HANG),
                }
            }
            None => (MARGIN, MARGIN),
        };
        Room {
            left: frame.left + MARGIN - x,
            top: frame.top + MARGIN - y,
            right: w - frame.right - MARGIN - x,
            bottom: h - frame.bottom - MARGIN - y,
        }
    }
}

/// How far below ☰ Windows' menu drops, and GNOME's popover hangs.
const DROP: f32 = 4.;
const HANG: f32 = 6.;
/// What the menu keeps clear of the window's edges.
const MARGIN: f32 = 8.;

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

    /// A panel holding `rows`, its padding and its hairline.
    fn panel_height(&self, rows: &[ChromeMenuItem]) -> f32 {
        self.row_top(rows, rows.len()) + self.padding + 2.
    }
}

/// The open menu's panels: the menu, then each open submenu beside the row
/// that opened it, all inside the window. The menu's bounds hold every
/// panel, so a press on one is inside; a press between them is outside.
fn panels(menu: &mut MainMenu, window: &mut Window, cx: &mut Context<MainMenu>) -> AnyElement {
    let t = cx.conduit().clone();
    let look = Look::of(menu.style, &t);
    let levels = menu.cursor.open_levels(&menu.items);
    for level in 0..levels {
        menu.scroll(level);
    }
    let mut sizes: Vec<PanelSize> = vec![];
    for level in 0..levels {
        let Some(rows) = menu.cursor.rows(&menu.items, level) else {
            break;
        };
        let below_parent = match level.checked_sub(1) {
            None => 0.,
            Some(parent) => {
                let parent_rows = menu.cursor.rows(&menu.items, parent).unwrap_or_default();
                let scrolled = f32::from(menu.scrolls[parent].1.offset().y);
                look.row_top(parent_rows, menu.cursor.path[parent]) - look.padding + scrolled
            }
        };
        sizes.push(PanelSize {
            width: if level == 0 {
                look.width
            } else {
                look.submenu_width
            },
            height: look.panel_height(rows),
            below_parent,
        });
    }
    let placed = place(&sizes, menu.room(window, &look, cx));
    let min_x = placed.iter().fold(0f32, |m, p| m.min(p.x));
    let min_y = placed.iter().fold(0f32, |m, p| m.min(p.y));
    let max_x = placed
        .iter()
        .zip(&sizes)
        .fold(0f32, |m, (p, s)| m.max(p.x + s.width));
    let max_y = placed.iter().fold(0f32, |m, p| m.max(p.y + p.height));
    let outside = cx.entity().downgrade();
    let gap = outside.clone();
    let mut out = div()
        .id("chrome-menu-outside")
        // Every panel is under the focused node, so a screen reader follows
        // the highlight into a submenu. Only a node with a role is in the
        // tree to be that ancestor.
        .track_focus(&menu.focus)
        .role(Role::Group)
        .aria_label(menu.label.clone())
        .absolute()
        .left(px(min_x))
        .top(px(min_y))
        .w(px(max_x - min_x))
        .h(px(max_y - min_y))
        .on_mouse_down_out(move |e: &MouseDownEvent, window, cx| {
            let _ = outside.update(cx, |m, cx| m.dismiss(e.position, window, cx));
        })
        // Between the panels: outside them, though inside these bounds.
        .child(
            div()
                .id("chrome-menu-gaps")
                .absolute()
                .inset_0()
                .on_any_mouse_down(move |e: &MouseDownEvent, window, cx| {
                    let _ = gap.update(cx, |m, cx| m.dismiss(e.position, window, cx));
                }),
        );
    for (level, (p, size)) in placed.iter().zip(&sizes).enumerate() {
        let Some(rows) = menu.cursor.rows(&menu.items, level) else {
            break;
        };
        let label = match level.checked_sub(1) {
            None => menu.label.clone(),
            Some(parent) => menu
                .cursor
                .rows(&menu.items, parent)
                .and_then(|rows| rows.get(menu.cursor.path[parent]))
                .and_then(|r| r.label().cloned())
                .unwrap_or_default(),
        };
        let scroll = menu.scrolls[level].1.clone();
        // Cut at the window's edge: a scroll bar shows there are more rows,
        // and lets the pointer reach them.
        let cut = p.height < size.height;
        let bar = cut.then(|| {
            div()
                .id(ElementId::Name(
                    format!("chrome-menu-scrollbar-{level}").into(),
                ))
                .debug_selector(|| format!("chrome-menu-scrollbar-{level}"))
                .absolute()
                .top_0()
                .left_0()
                .w(px(size.width))
                .h(px(p.height))
                .child(
                    Scrollbar::vertical(&scroll)
                        .mode(ScrollbarMode::Always)
                        .viewport_from_layout(),
                )
        });
        let panel = panel(
            menu, level, rows, label, size.width, p.height, scroll, &look, &t, cx,
        );
        out = out.child(
            div()
                .absolute()
                .left(px(p.x - min_x))
                .top(px(p.y - min_y))
                .w(px(size.width))
                .child(panel)
                .children(bar),
        );
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
    height: f32,
    scroll: ScrollHandle,
    look: &Look,
    t: &ConduitTheme,
    cx: &mut Context<MainMenu>,
) -> AnyElement {
    let r = t.roles;
    let highlighted = menu.cursor.path.get(level).copied();
    // The highlight a screen reader is on: the deepest one.
    let deepest = menu.cursor.path.len() == level + 1;
    let entity = cx.entity().downgrade();
    // A column for check marks only where a row has one.
    let checks = rows
        .iter()
        .any(|r| matches!(r, ChromeMenuItem::Action { checked: true, .. }));
    div()
        .id(ElementId::Name(format!("chrome-menu-{level}").into()))
        .debug_selector(|| format!("chrome-menu-panel-{level}"))
        // A submenu laid over its parent takes the pointer alone.
        .occlude()
        .role(Role::Menu)
        .aria_label(label)
        .w(px(width))
        .max_h(px(height))
        .overflow_y_scroll()
        .track_scroll(&scroll)
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
        // Not a press on what is under the menu.
        .on_mouse_down(MouseButton::Left, |_, window, cx| {
            window.prevent_default();
            cx.stop_propagation();
        })
        .children(rows.iter().enumerate().map(|(i, row)| {
            let on = highlighted == Some(i);
            match row {
                ChromeMenuItem::Separator => div()
                    .flex_none()
                    .h(px(look.separator))
                    .flex()
                    .items_center()
                    .child(div().w_full().h(px(1.)).bg(r.divider))
                    .into_any_element(),
                ChromeMenuItem::Zoom(zoom) => {
                    zoom_row(menu, level, i, zoom, on, look, t, cx).into_any_element()
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
                        .when(on && deepest, |d| d.aria_active_descendant())
                        .on_mouse_move(move |_, _, cx| {
                            let _ = entity_hover.update(cx, |m, cx| m.hover(level, i, cx));
                        })
                        // A row that can't act offers no press.
                        .when(!*disabled, |d| {
                            d.on_click(move |_, window, cx| {
                                let _ =
                                    entity.update(cx, |m, cx| m.click_row(level, i, window, cx));
                            })
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
                    let entity_hover = entity.clone();
                    let expanded = on && menu.cursor.open_levels(&menu.items) > level + 1;
                    row_box(level, i, look, on, *disabled, t)
                        .role(Role::MenuItem)
                        .aria_label(label.clone())
                        .aria_expanded(expanded)
                        .when(on && deepest, |d| d.aria_active_descendant())
                        .on_mouse_move(move |_, _, cx| {
                            let _ = entity_hover.update(cx, |m, cx| m.hover(level, i, cx));
                        })
                        // A click, or a screen reader's press, opens it.
                        .when(!*disabled, |d| {
                            d.on_click(move |_, _, cx| {
                                let _ = entity.update(cx, |m, cx| m.hover(level, i, cx));
                            })
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
        .debug_selector(|| format!("chrome-menu-{level}-{index}"))
        .flex_none()
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
    cx: &mut Context<MainMenu>,
) -> impl IntoElement {
    let r = t.roles;
    let entity = cx.entity().downgrade();
    let deepest = menu.cursor.path.len() == level + 1;
    let part_on = |k: usize| on && menu.cursor.part == k;
    let button = |k: usize, part: &ZoomPart, body: AnyElement| {
        let entity = entity.clone();
        let entity_hover = entity.clone();
        let action = part.action.boxed_clone();
        let disabled = part.disabled;
        div()
            .id(ElementId::Name(format!("chrome-zoom-{k}").into()))
            .role(Role::Button)
            .aria_label(part.label.clone())
            .when(part_on(k) && deepest && !disabled, |d| {
                d.aria_active_descendant()
            })
            .h(px(32.))
            .min_w(px(32.))
            .px(px(8.))
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(look.row_radius))
            .when(part_on(k) && !disabled, |d| d.bg(r.overlay_hover))
            .when(disabled, |d| d.opacity(0.38))
            // The part under the pointer is the one Enter runs.
            .on_mouse_move(move |_, _, cx| {
                let _ = entity_hover.update(cx, |m, cx| m.hover_part(level, index, k, cx));
            })
            // A part that can't act offers no press.
            .when(!disabled, |d| {
                d.on_click(move |_, window, cx| {
                    let action = action.boxed_clone();
                    let _ = entity.update(cx, |m, cx| m.click_zoom(action, window, cx));
                })
            })
            .child(body)
    };
    div()
        .id(ElementId::Name(
            format!("chrome-menu-{level}-{index}").into(),
        ))
        .role(Role::Group)
        .flex_none()
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
        panels(self, window, cx)
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
        let (style, label, open, trigger) = {
            let m = self.menu.read(cx);
            (m.style, m.label.clone(), m.open, m.trigger.clone())
        };
        let size = super::layout::MENU_BUTTON;
        let click = self.menu.clone();
        let opened = open.then(|| {
            let look = Look::of(style, &t);
            // Windows drops the menu from ☰'s leading edge; GNOME's popover
            // hangs centred under it. Either way it hangs from a point, the
            // menu's own top-left corner, that `room` measures from: `place`
            // keeps the panels inside the window, so snapping keeps only
            // that point there, and an open submenu never moves the menu.
            let offset = match style {
                ChromeStyle::Windows => point(px(0.), px(size + DROP)),
                ChromeStyle::Gnome => point(px(size / 2. - look.width / 2.), px(size + HANG)),
            };
            // Hung from ☰'s top-left corner, out of the flow.
            div().absolute().top_0().left_0().child(
                deferred(
                    anchored()
                        .anchor(Anchor::TopLeft)
                        .offset(offset)
                        .snap_to_window_with_margin(px(MARGIN))
                        .child(div().size_0().child(self.menu.clone())),
                )
                .with_priority(1),
            )
        });
        let hover = with_alpha(r.text, if t.dark { 0.10 } else { 0.07 });
        div()
            .relative()
            .flex_none()
            .child(
                div()
                    .id("main-menu")
                    .debug_selector(|| "main-menu".into())
                    .role(Role::Button)
                    .aria_label(label)
                    .aria_expanded(open)
                    .occlude()
                    .relative()
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
                    // Not a press on the header (a drag, a double-click).
                    .on_mouse_down(MouseButton::Left, |_, window, cx| {
                        window.prevent_default();
                        cx.stop_propagation();
                    })
                    // A click, or a screen reader's press.
                    .on_click(move |_, window, cx| {
                        click.update(cx, |m, cx| m.toggle(false, window, cx));
                    })
                    .child(icon(IconName::Menu, 16., r.text))
                    // Where ☰ itself is drawn, not its row.
                    .child(
                        canvas(
                            move |bounds, _, _| trigger.set(Some(bounds)),
                            |_, _, _, _| {},
                        )
                        .absolute()
                        .inset_0(),
                    ),
            )
            .children(opened)
    }
}

/// A colour a little off the header's, for flat header-bar buttons.
pub fn flat_hover(t: &ConduitTheme) -> Hsla {
    with_alpha(t.roles.text, if t.dark { 0.10 } else { 0.07 })
}

/// A panel's size, and where the row that opened it puts its top: against
/// its parent's top, the row's top less the panel's padding.
#[derive(Clone, Copy, Debug, PartialEq)]
struct PanelSize {
    width: f32,
    height: f32,
    below_parent: f32,
}

/// The window around the menu's origin: `left` and `top` are at most 0.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Room {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
}

/// Where a panel goes, against the menu's origin, and how tall it is drawn
/// (it scrolls when that is less than its rows).
#[derive(Clone, Copy, Debug, PartialEq)]
struct Placed {
    x: f32,
    y: f32,
    height: f32,
}

/// Places each open panel inside `room`. The menu hangs from its origin,
/// moved left if it would run past the window's edge and cut at its bottom; a submenu opens beside its row, on the right
/// while it fits, else on the side with more room, kept inside; a panel
/// taller than the window takes its height and scrolls; one that would run
/// off the bottom moves up to end there.
fn place(panels: &[PanelSize], room: Room) -> Vec<Placed> {
    let full = room.bottom - room.top;
    let mut out: Vec<Placed> = vec![];
    for (i, p) in panels.iter().enumerate() {
        let Some(parent) = out.last().copied() else {
            out.push(Placed {
                x: 0f32.min(room.right - p.width).max(room.left),
                y: 0.,
                height: p.height.min(room.bottom),
            });
            continue;
        };
        let right = parent.x + panels[i - 1].width - 4.;
        let left = parent.x - p.width + 4.;
        let x = if right + p.width <= room.right {
            right
        } else if left >= room.left {
            left
        } else if room.right - right >= parent.x - room.left {
            right.min(room.right - p.width)
        } else {
            room.left
        };
        let height = p.height.min(full);
        let y = (parent.y + p.below_parent)
            .min(room.bottom - height)
            .max(room.top);
        out.push(Placed { x, y, height });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROOM: Room = Room {
        left: -8.,
        top: -46.,
        right: 1272.,
        bottom: 814.,
    };

    fn panel(width: f32, height: f32, below_parent: f32) -> PanelSize {
        PanelSize {
            width,
            height,
            below_parent,
        }
    }

    #[test]
    fn submenus_open_beside_their_row_while_they_fit() {
        let placed = place(&[panel(280., 400., 0.), panel(300., 200., 120.)], ROOM);
        assert_eq!(
            placed,
            [
                Placed {
                    x: 0.,
                    y: 0.,
                    height: 400.
                },
                Placed {
                    x: 276.,
                    y: 120.,
                    height: 200.
                },
            ]
        );
    }

    #[test]
    fn the_menu_itself_stays_inside_the_window() {
        // Hung from a ☰ near the window's right edge: 120 points of room.
        let tight = Room {
            left: -1000.,
            right: 120.,
            ..ROOM
        };
        let placed = place(&[panel(280., 400., 0.)], tight);
        assert_eq!(placed[0].x, 120. - 280.);
    }

    #[test]
    fn a_submenu_with_no_room_on_the_right_opens_on_the_left() {
        // A 720-point window: Edit, then its Find submenu.
        let narrow = Room {
            right: 712.,
            ..ROOM
        };
        let placed = place(
            &[
                panel(280., 400., 0.),
                panel(300., 300., 30.),
                panel(300., 150., 240.),
            ],
            narrow,
        );
        assert_eq!(placed[1].x, 276.);
        assert_eq!(
            placed[2].x, -8.,
            "Find opens on Edit's left, kept inside the window"
        );
        // With room on the left for all of it, it sits beside Edit.
        let wider = place(
            &[
                panel(280., 400., 0.),
                panel(300., 300., 30.),
                panel(250., 150., 240.),
            ],
            narrow,
        );
        assert_eq!(wider[2].x, 276. - 250. + 4.);
    }

    #[test]
    fn a_panel_taller_than_the_window_scrolls_and_one_below_moves_up() {
        // The root is cut at the window's bottom, and scrolls.
        let placed = place(&[panel(280., 1200., 0.)], ROOM);
        assert_eq!(placed[0].height, 814.);
        // A submenu taller than the window takes its whole height.
        let placed = place(&[panel(280., 400., 0.), panel(300., 2000., 90.)], ROOM);
        assert_eq!(placed[1].y, -46.);
        assert_eq!(placed[1].height, 860.);
        // A submenu that would run off the bottom moves up to end there.
        let placed = place(&[panel(280., 700., 0.), panel(300., 500., 600.)], ROOM);
        assert_eq!(placed[1].y, 814. - 500.);
        assert_eq!(placed[1].height, 500.);
    }
}
