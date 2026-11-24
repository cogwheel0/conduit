//! ☰ in a window: how it opens, greys, takes the pointer and the keyboard,
//! and hands its action back; and GNOME's frame under the pointer.

use std::cell::Cell;
use std::rc::Rc;

use gpui_kit::prelude::*;
use gpui_kit::{
    Context, Decorations, Entity, FocusHandle, KeyBinding, Modifiers, MouseButton, MouseDownEvent,
    MouseMoveEvent, MouseUpEvent, PlatformInput, Point, TestAppContext, Tiling, VisualTestContext,
    Window, actions, div, point, px,
};

use super::ChromeStyle;
use super::controls::ClientFrame;
use super::main_menu::{MainMenu, MainMenuButton};
use super::menu::{ChromeMenuItem, ZoomPart, ZoomRow};
use crate::theme::{ConduitTheme, DesignPrefs};

actions!(
    chrome_window_test,
    [
        Answered,
        AlsoAnswered,
        Unanswered,
        Stop,
        Steal,
        ZoomOut,
        ZoomIn,
        ActualSize
    ]
);

/// Which menu the host opens.
#[derive(Clone, Copy)]
enum Menu {
    /// Answered, Unanswered, More ▸ (Unanswered), Also ▸ (AlsoAnswered).
    Rows,
    /// Answered, then a zoom row three steps deep: 90%, 100%, 110%.
    Zoom,
    /// Sixty rows, taller than the window.
    Long,
    /// Windows' ☰ in outline: File's rows, Edit ▸ (Find ▸ last), View ▸,
    /// Chat ▸ (Move to ▸ thirty folders first, then thirty-seven rows), Exit.
    Deep,
}

/// ☰ at the window's top left, a field, another field to take focus, and
/// handlers for some of the menu's actions on the root (as the app's main
/// window has its own).
struct Host {
    /// How far from the window's leading edge ☰ sits.
    menu_at: f32,
    field: FocusHandle,
    other: FocusHandle,
    menu: Entity<MainMenu>,
    answered: usize,
    also_answered: usize,
    /// -1, 0 (the actual size) or 1.
    level: Rc<Cell<i32>>,
}

impl Render for Host {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let level = self.level.get();
        let zoom = |h: &mut Host, by: i32, cx: &mut Context<Host>| {
            h.level.set(if by == 0 { 0 } else { h.level.get() + by });
            cx.notify();
        };
        div()
            .size_full()
            .flex()
            .flex_col()
            .on_action(cx.listener(|h, _: &Answered, _, _| h.answered += 1))
            .on_action(cx.listener(|h, _: &AlsoAnswered, _, _| h.also_answered += 1))
            .on_action(cx.listener(|h, _: &Steal, window, cx| {
                window.focus(&h.other, cx);
            }))
            .when(level < 1, |d| {
                d.on_action(cx.listener(move |h, _: &ZoomIn, _, cx| zoom(h, 1, cx)))
            })
            .when(level > -1, |d| {
                d.on_action(cx.listener(move |h, _: &ZoomOut, _, cx| zoom(h, -1, cx)))
            })
            .when(level != 0, |d| {
                d.on_action(cx.listener(move |h, _: &ActualSize, _, cx| zoom(h, 0, cx)))
            })
            .child(
                div()
                    .pl(px(self.menu_at))
                    .child(MainMenuButton::new(self.menu.clone())),
            )
            .child(div().track_focus(&self.field).size_full())
            .child(div().track_focus(&self.other).size(px(10.)))
    }
}

fn rows() -> Vec<ChromeMenuItem> {
    vec![
        ChromeMenuItem::action("Answered", Answered),
        ChromeMenuItem::action("Unanswered", Unanswered),
        ChromeMenuItem::submenu(
            "More",
            vec![ChromeMenuItem::action("Unanswered", Unanswered)],
        ),
        ChromeMenuItem::submenu(
            "Also",
            vec![ChromeMenuItem::action("Also Answered", AlsoAnswered)],
        ),
    ]
}

/// The zoom row as the app builds it: each part off by the same rule its
/// handler follows.
fn zoom_rows(level: i32) -> Vec<ChromeMenuItem> {
    let part = |label: &str, action: Box<dyn gpui_kit::Action>, disabled: bool| ZoomPart {
        label: label.to_string().into(),
        action,
        disabled,
    };
    vec![
        ChromeMenuItem::action("Answered", Answered),
        ChromeMenuItem::Separator,
        ChromeMenuItem::Zoom(ZoomRow {
            level: format!("{}%", 100 + 10 * level).into(),
            out: part("Zoom Out", Box::new(ZoomOut), level <= -1),
            reset: part("Actual Size", Box::new(ActualSize), level == 0),
            zoom_in: part("Zoom In", Box::new(ZoomIn), level >= 1),
        }),
    ]
}

fn answered(n: usize, label: &str) -> Vec<ChromeMenuItem> {
    (0..n)
        .map(|i| ChromeMenuItem::action(format!("{label} {i}"), Answered))
        .collect()
}

fn long_rows() -> Vec<ChromeMenuItem> {
    answered(60, "Row")
}

fn deep_rows() -> Vec<ChromeMenuItem> {
    use ChromeMenuItem::Separator as Sep;
    let mut edit = answered(7, "Edit");
    edit.extend([Sep, ChromeMenuItem::submenu("Find", answered(5, "Find"))]);
    let mut chat = vec![ChromeMenuItem::submenu("Move to", answered(30, "Folder"))];
    chat.extend(answered(37, "Chat"));
    let mut root = answered(4, "New");
    root.extend([
        Sep,
        ChromeMenuItem::action("Close Window", Answered),
        Sep,
        ChromeMenuItem::submenu("Edit", edit),
        ChromeMenuItem::submenu("View", answered(9, "View")),
        ChromeMenuItem::submenu("Go", answered(8, "Go")),
        ChromeMenuItem::submenu("Chat", chat),
        Sep,
    ]);
    root.extend(answered(3, "App"));
    root.extend([Sep, ChromeMenuItem::action("Exit", Answered)]);
    root
}

/// Opens the host; `stops` counts Esc's app-wide Stop.
fn open_host(
    style: ChromeStyle,
    menu: Menu,
    focus_field: bool,
    cx: &mut TestAppContext,
) -> (Entity<Host>, Rc<Cell<usize>>, &mut VisualTestContext) {
    let stops = Rc::new(Cell::new(0));
    cx.update(|cx| {
        // The views read the Conduit theme only (no GPUI Kit theme needed).
        cx.set_global(ConduitTheme::new(
            "conduit",
            false,
            DesignPrefs::default(),
            gpui_kit::blue(),
        ));
        // Esc's Stop, bound without a context and answered app-wide, as the
        // app binds it: an open menu must still get Esc.
        cx.bind_keys([
            KeyBinding::new("escape", Stop, None),
            KeyBinding::new("ctrl-k", Steal, None),
        ]);
        let stops = stops.clone();
        cx.on_action(move |_: &Stop, _| stops.set(stops.get() + 1));
    });
    let (host, vcx) = cx.add_window_view(|window, cx| {
        let field = cx.focus_handle();
        if focus_field {
            window.focus(&field, cx);
        }
        let level = Rc::new(Cell::new(0));
        let build: super::MenuItems = match menu {
            Menu::Rows => Rc::new(|_, _| rows()),
            Menu::Long => Rc::new(|_, _| long_rows()),
            Menu::Deep => Rc::new(|_, _| deep_rows()),
            Menu::Zoom => {
                let level = level.clone();
                Rc::new(move |_, _| zoom_rows(level.get()))
            }
        };
        let menu = cx.new(|cx| MainMenu::new(style, "Main Menu", build, window, cx));
        Host {
            menu_at: 0.,
            field,
            other: cx.focus_handle(),
            menu,
            answered: 0,
            also_answered: 0,
            level,
        }
    });
    vcx.update(|window, _| window.activate_window());
    draw(vcx);
    (host, stops, vcx)
}

fn draw(vcx: &mut VisualTestContext) {
    vcx.update(|window, cx| window.draw(cx).clear(cx));
    vcx.run_until_parked();
}

fn is_open(host: &Entity<Host>, vcx: &mut VisualTestContext) -> bool {
    vcx.update(|_, cx| host.read(cx).menu.read(cx).is_open())
}

/// (label, greyed) for each row of the open menu's top level.
fn top_rows(host: &Entity<Host>, vcx: &mut VisualTestContext) -> Vec<(String, bool)> {
    vcx.update(|_, cx| {
        host.read(cx)
            .menu
            .read(cx)
            .items()
            .iter()
            .map(|i| {
                (
                    i.label().map(|l| l.to_string()).unwrap_or_default(),
                    i.is_disabled(),
                )
            })
            .collect()
    })
}

fn field_focused(host: &Entity<Host>, vcx: &mut VisualTestContext) -> bool {
    vcx.update(|window, cx| host.read(cx).field.is_focused(window))
}

/// The centre of the element drawn with `selector`.
fn centre(selector: &'static str, vcx: &mut VisualTestContext) -> Point<gpui_kit::Pixels> {
    vcx.debug_bounds(selector)
        .unwrap_or_else(|| panic!("{selector} is not drawn"))
        .center()
}

fn bounds(selector: String, vcx: &mut VisualTestContext) -> gpui_kit::Bounds<gpui_kit::Pixels> {
    let selector: &'static str = Box::leak(selector.into_boxed_str());
    vcx.debug_bounds(selector)
        .unwrap_or_else(|| panic!("{selector} is not drawn"))
}

/// The highlighted row at `level` shows whole inside its panel, and every
/// open panel inside the window.
fn shows(
    host: &Entity<Host>,
    vcx: &mut VisualTestContext,
    window: gpui_kit::Size<gpui_kit::Pixels>,
) {
    let path = vcx.update(|_, cx| host.read(cx).menu.read(cx).cursor().path.clone());
    for level in 0..path.len() {
        let panel = bounds(format!("chrome-menu-panel-{level}"), vcx);
        assert!(
            panel.left() >= px(0.)
                && panel.top() >= px(0.)
                && panel.right() <= window.width
                && panel.bottom() <= window.height,
            "panel {level} {panel:?} is inside the {window:?} window"
        );
    }
    let level = path.len() - 1;
    let row = bounds(format!("chrome-menu-{level}-{}", path[level]), vcx);
    let panel = bounds(format!("chrome-menu-panel-{level}"), vcx);
    assert!(
        row.top() >= panel.top() && row.bottom() <= panel.bottom(),
        "row {path:?} {row:?} shows inside its panel {panel:?}"
    );
}

fn click(selector: &'static str, vcx: &mut VisualTestContext) {
    let at = centre(selector, vcx);
    vcx.simulate_click(at, Modifiers::none());
    draw(vcx);
}

#[gpui_kit::test]
fn f10_opens_the_menu_greyed_by_what_answers_where_focus_was(cx: &mut TestAppContext) {
    let (host, stops, vcx) = open_host(ChromeStyle::Gnome, Menu::Rows, true, cx);
    assert!(!is_open(&host, vcx));
    vcx.simulate_keystrokes("f10");
    draw(vcx);
    assert!(is_open(&host, vcx));
    assert_eq!(
        top_rows(&host, vcx),
        [
            ("Answered".to_string(), false),
            ("Unanswered".to_string(), true),
            ("More".to_string(), true),
            ("Also".to_string(), false),
        ],
        "AppKit's rule: an item is off when nothing where focus was answers it"
    );
    assert!(!field_focused(&host, vcx), "the open menu has the keyboard");
    // Esc closes it, and never reaches the app's Stop meanwhile.
    vcx.simulate_keystrokes("escape");
    draw(vcx);
    assert!(!is_open(&host, vcx));
    assert_eq!(stops.get(), 0, "Esc was the menu's");
    assert!(field_focused(&host, vcx), "focus goes back where it was");
    // With the menu shut, Esc is Stop's again.
    vcx.simulate_keystrokes("escape");
    assert_eq!(stops.get(), 1);
}

#[gpui_kit::test]
fn a_lone_alt_opens_the_menu_on_windows_only(cx: &mut TestAppContext) {
    let (host, _, vcx) = open_host(ChromeStyle::Windows, Menu::Rows, true, cx);
    vcx.simulate_modifiers_change(Modifiers::alt());
    vcx.simulate_modifiers_change(Modifiers::none());
    draw(vcx);
    assert!(is_open(&host, vcx));
    // Alt again closes it, as it leaves Windows' menu bar.
    vcx.simulate_modifiers_change(Modifiers::alt());
    vcx.simulate_modifiers_change(Modifiers::none());
    draw(vcx);
    assert!(!is_open(&host, vcx));
    // Alt with a key is a chord, not the menu.
    vcx.simulate_keystrokes("alt-x");
    draw(vcx);
    assert!(!is_open(&host, vcx));
}

/// Windows' activation injects an Alt press and release to win the
/// foreground: the lone Alt that follows the app bringing the window
/// forward is not the user's, and leaves ☰ shut with focus where it was.
/// The next one is the user's.
#[gpui_kit::test]
fn the_alt_an_activation_injects_leaves_the_menu_shut(cx: &mut TestAppContext) {
    let (host, _, vcx) = open_host(ChromeStyle::Windows, Menu::Rows, true, cx);
    vcx.update(|window, cx| super::activate(window, cx));
    vcx.simulate_modifiers_change(Modifiers::alt());
    vcx.simulate_modifiers_change(Modifiers::none());
    draw(vcx);
    assert!(!is_open(&host, vcx), "the activation's own Alt opened ☰");
    assert!(field_focused(&host, vcx));
    vcx.simulate_modifiers_change(Modifiers::alt());
    vcx.simulate_modifiers_change(Modifiers::none());
    draw(vcx);
    assert!(is_open(&host, vcx), "the user's Alt is ☰'s");
}

/// Two activations close together (the app's New Chat from Settings
/// brings the main window forward twice) inject two Alts: neither opens ☰.
#[gpui_kit::test]
fn each_activations_alt_is_owed(cx: &mut TestAppContext) {
    let (host, _, vcx) = open_host(ChromeStyle::Windows, Menu::Rows, true, cx);
    vcx.update(|window, cx| {
        super::activate(window, cx);
        super::activate(window, cx);
    });
    for _ in 0..2 {
        vcx.simulate_modifiers_change(Modifiers::alt());
        vcx.simulate_modifiers_change(Modifiers::none());
        draw(vcx);
        assert!(!is_open(&host, vcx), "an activation's Alt opened ☰");
    }
    vcx.simulate_modifiers_change(Modifiers::alt());
    vcx.simulate_modifiers_change(Modifiers::none());
    draw(vcx);
    assert!(is_open(&host, vcx), "the user's Alt is ☰'s");
}

/// Any key between the activation and a lone Alt means the activation's
/// Alt went elsewhere: that Alt is the user's.
#[gpui_kit::test]
fn a_key_after_an_activation_makes_the_next_alt_the_users(cx: &mut TestAppContext) {
    let (host, _, vcx) = open_host(ChromeStyle::Windows, Menu::Rows, true, cx);
    vcx.update(|window, cx| super::activate(window, cx));
    vcx.simulate_keystrokes("x");
    vcx.simulate_modifiers_change(Modifiers::alt());
    vcx.simulate_modifiers_change(Modifiers::none());
    draw(vcx);
    assert!(is_open(&host, vcx));
}

#[gpui_kit::test]
fn a_lone_alt_leaves_gnomes_menu_shut(cx: &mut TestAppContext) {
    let (host, _, vcx) = open_host(ChromeStyle::Gnome, Menu::Rows, true, cx);
    vcx.simulate_modifiers_change(Modifiers::alt());
    vcx.simulate_modifiers_change(Modifiers::none());
    draw(vcx);
    assert!(
        !is_open(&host, vcx),
        "GNOME opens its primary menu on F10 only"
    );
}

#[gpui_kit::test]
fn enter_runs_the_highlighted_item_where_focus_was(cx: &mut TestAppContext) {
    let (host, _, vcx) = open_host(ChromeStyle::Windows, Menu::Rows, true, cx);
    vcx.simulate_keystrokes("f10");
    draw(vcx);
    // Opened from the keyboard: the first item is highlighted.
    vcx.simulate_keystrokes("enter");
    draw(vcx);
    assert!(!is_open(&host, vcx));
    assert_eq!(vcx.update(|_, cx| host.read(cx).answered), 1);
    assert!(field_focused(&host, vcx));
    // The greyed rows are skipped: Down reaches Also, Right opens it.
    vcx.simulate_keystrokes("f10");
    draw(vcx);
    vcx.simulate_keystrokes("down right enter");
    draw(vcx);
    assert_eq!(vcx.update(|_, cx| host.read(cx).also_answered), 1);
}

#[gpui_kit::test]
fn clicking_a_row_runs_it_where_focus_was(cx: &mut TestAppContext) {
    let (host, _, vcx) = open_host(ChromeStyle::Windows, Menu::Rows, true, cx);
    click("main-menu", vcx);
    assert!(is_open(&host, vcx));
    click("chrome-menu-0-0", vcx);
    assert!(!is_open(&host, vcx));
    assert_eq!(vcx.update(|_, cx| host.read(cx).answered), 1);
    assert!(field_focused(&host, vcx));
}

#[gpui_kit::test]
fn clicking_a_submenu_row_opens_it_and_its_row_runs(cx: &mut TestAppContext) {
    let (host, _, vcx) = open_host(ChromeStyle::Windows, Menu::Rows, true, cx);
    click("main-menu", vcx);
    click("chrome-menu-0-3", vcx);
    assert!(is_open(&host, vcx), "a submenu row opens its submenu");
    click("chrome-menu-1-0", vcx);
    assert!(!is_open(&host, vcx));
    assert_eq!(vcx.update(|_, cx| host.read(cx).also_answered), 1);
}

#[gpui_kit::test]
fn the_menu_button_toggles_and_a_press_outside_closes(cx: &mut TestAppContext) {
    let (host, _, vcx) = open_host(ChromeStyle::Gnome, Menu::Rows, true, cx);
    click("main-menu", vcx);
    assert!(is_open(&host, vcx));
    click("main-menu", vcx);
    assert!(!is_open(&host, vcx), "☰ again closes it");
    click("main-menu", vcx);
    assert!(is_open(&host, vcx));
    vcx.simulate_click(point(px(900.), px(700.)), Modifiers::none());
    draw(vcx);
    assert!(!is_open(&host, vcx), "a press outside closes it");
}

#[gpui_kit::test]
fn a_right_click_on_the_menu_button_does_not_eat_a_later_click(cx: &mut TestAppContext) {
    let (host, _, vcx) = open_host(ChromeStyle::Windows, Menu::Rows, true, cx);
    vcx.simulate_keystrokes("f10");
    draw(vcx);
    let at = centre("main-menu", vcx);
    vcx.simulate_mouse_down(at, MouseButton::Right, Modifiers::none());
    vcx.simulate_mouse_up(at, MouseButton::Right, Modifiers::none());
    draw(vcx);
    vcx.simulate_keystrokes("escape");
    draw(vcx);
    assert!(!is_open(&host, vcx));
    click("main-menu", vcx);
    assert!(is_open(&host, vcx), "the left click on ☰ opens it");
}

#[gpui_kit::test]
fn focus_leaving_the_menu_closes_it(cx: &mut TestAppContext) {
    let (host, stops, vcx) = open_host(ChromeStyle::Gnome, Menu::Rows, true, cx);
    vcx.simulate_keystrokes("f10");
    draw(vcx);
    // A chord passes to the app, whose command takes focus elsewhere.
    vcx.simulate_keystrokes("ctrl-k");
    draw(vcx);
    assert!(!is_open(&host, vcx), "the menu goes with its focus");
    assert!(vcx.update(|window, cx| host.read(cx).other.is_focused(window)));
    vcx.simulate_keystrokes("escape");
    assert_eq!(stops.get(), 1, "Esc is the app's again");
}

/// A prompt the window draws (the app's own, off the Mac) has the keyboard:
/// F10 doesn't open the menu behind it.
#[gpui_kit::test]
fn a_drawn_prompt_keeps_f10(cx: &mut TestAppContext) {
    cx.update(|cx| cx.set_prompt_builder(gpui_kit::fallback_prompt_renderer));
    let (host, _, vcx) = open_host(ChromeStyle::Windows, Menu::Rows, true, cx);
    let _answer = vcx.update(|window, cx| {
        window.prompt(
            gpui_kit::PromptLevel::Info,
            "Synthetic question",
            None,
            &["OK"],
            cx,
        )
    });
    draw(vcx);
    assert!(vcx.update(|window, _| window.has_active_prompt()));
    vcx.simulate_keystrokes("f10");
    draw(vcx);
    assert!(!is_open(&host, vcx));
}

#[gpui_kit::test]
fn closing_with_nothing_focused_leaves_nothing_focused(cx: &mut TestAppContext) {
    let (host, _, vcx) = open_host(ChromeStyle::Gnome, Menu::Rows, false, cx);
    vcx.simulate_keystrokes("f10");
    draw(vcx);
    assert!(is_open(&host, vcx));
    vcx.simulate_keystrokes("escape");
    draw(vcx);
    assert!(!is_open(&host, vcx));
    assert!(vcx.update(|window, cx| window.focused(cx).is_none()));
}

/// The app's window in outline: its own focus deeper than the window's
/// root, where its commands are answered (Go's rows on the main window).
struct HomeHost {
    home: FocusHandle,
    menu: Entity<MainMenu>,
    answered: usize,
}

impl Render for HomeHost {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(
            div()
                .track_focus(&self.home)
                .size_full()
                .on_action(cx.listener(|h, _: &Answered, _, _| h.answered += 1))
                .child(MainMenuButton::new(self.menu.clone())),
        )
    }
}

/// With nothing focused, ☰ acts for the window: the rows the window
/// answers stay on, run there, and focus comes back to the window.
#[gpui_kit::test]
fn with_nothing_focused_the_menu_acts_for_the_window(cx: &mut TestAppContext) {
    cx.update(|cx| {
        cx.set_global(ConduitTheme::new(
            "conduit",
            false,
            DesignPrefs::default(),
            gpui_kit::blue(),
        ))
    });
    let (host, vcx) = cx.add_window_view(|window, cx| {
        let home = cx.focus_handle();
        let build: super::MenuItems = Rc::new(|_, _| rows());
        let menu = cx.new(|cx| {
            MainMenu::new(ChromeStyle::Windows, "Main Menu", build, window, cx).home(home.clone())
        });
        HomeHost {
            home,
            menu,
            answered: 0,
        }
    });
    vcx.update(|window, _| window.activate_window());
    draw(vcx);
    assert!(vcx.update(|window, cx| window.focused(cx).is_none()));
    vcx.simulate_keystrokes("f10");
    draw(vcx);
    let answered_on = vcx.update(|_, cx| {
        host.read(cx)
            .menu
            .read(cx)
            .items()
            .first()
            .is_some_and(|i| !i.is_disabled())
    });
    assert!(answered_on, "the window's own row is greyed");
    vcx.simulate_keystrokes("enter");
    draw(vcx);
    assert_eq!(vcx.update(|_, cx| host.read(cx).answered), 1);
    assert!(vcx.update(|window, cx| host.read(cx).home.is_focused(window)));
}

#[gpui_kit::test]
fn a_keyboard_zoom_in_lets_actual_size_act(cx: &mut TestAppContext) {
    let (host, _, vcx) = open_host(ChromeStyle::Gnome, Menu::Zoom, true, cx);
    vcx.simulate_keystrokes("f10");
    draw(vcx);
    // Down to the zoom row, Right to Zoom In, Enter: the menu stays open.
    vcx.simulate_keystrokes("down right enter");
    draw(vcx);
    assert_eq!(vcx.update(|_, cx| host.read(cx).level.get()), 1);
    assert!(is_open(&host, vcx));
    let reset_off = vcx.update(|_, cx| {
        host.read(cx)
            .menu
            .read(cx)
            .items()
            .iter()
            .find_map(|i| match i {
                ChromeMenuItem::Zoom(row) => Some(row.reset.disabled),
                _ => None,
            })
            .unwrap()
    });
    assert!(!reset_off, "Actual Size acts once zoomed");
}

/// The zoom level, and the zoom row's highlighted part: its name and
/// whether it can act.
fn zoom_highlight(host: &Entity<Host>, vcx: &mut VisualTestContext) -> (i32, String, bool) {
    vcx.update(|_, cx| {
        let host = host.read(cx);
        let menu = host.menu.read(cx);
        let row = menu
            .items()
            .iter()
            .find_map(|i| match i {
                ChromeMenuItem::Zoom(row) => Some(row),
                _ => None,
            })
            .unwrap();
        let part = row.parts()[menu.cursor().part];
        (host.level.get(), part.label.to_string(), !part.disabled)
    })
}

/// A zoom part that runs leaves the menu open and built again; the
/// highlight then moves off a part that can no longer act.
#[gpui_kit::test]
fn after_a_zoom_part_runs_the_highlight_sits_on_a_part_that_acts(cx: &mut TestAppContext) {
    let (host, _, vcx) = open_host(ChromeStyle::Windows, Menu::Zoom, true, cx);
    vcx.simulate_keystrokes("f10");
    draw(vcx);
    vcx.simulate_keystrokes("down");
    draw(vcx);
    let acts = |level: i32, part: &str| (level, part.to_string(), true);
    assert_eq!(zoom_highlight(&host, vcx), acts(0, "Zoom Out"));
    let steps = [
        ("enter", acts(-1, "Actual Size"), "Zoom Out at its least"),
        ("right enter", acts(0, "Zoom In"), "Zoom In still acts"),
        ("enter", acts(1, "Actual Size"), "Zoom In at its most"),
        ("enter", acts(0, "Zoom Out"), "Actual Size"),
    ];
    for (keys, after, case) in steps {
        vcx.simulate_keystrokes(keys);
        draw(vcx);
        assert_eq!(zoom_highlight(&host, vcx), after, "{case}");
    }
    assert!(is_open(&host, vcx));
    assert_eq!(
        vcx.update(|_, cx| host.read(cx).menu.read(cx).cursor().path.clone()),
        [2]
    );
}

/// The smallest main window.
fn smallest() -> gpui_kit::Size<gpui_kit::Pixels> {
    gpui_kit::size(px(720.), px(480.))
}

#[gpui_kit::test]
fn a_reopened_menu_shows_its_first_row(cx: &mut TestAppContext) {
    let (host, _, vcx) = open_host(ChromeStyle::Windows, Menu::Long, true, cx);
    vcx.simulate_resize(smallest());
    draw(vcx);
    vcx.simulate_keystrokes("f10");
    draw(vcx);
    // End scrolls the menu to its last row.
    vcx.simulate_keystrokes("end");
    draw(vcx);
    shows(&host, vcx, smallest());
    vcx.simulate_keystrokes("escape");
    draw(vcx);
    // Opened again, its first row is highlighted and in view.
    vcx.simulate_keystrokes("f10");
    draw(vcx);
    assert_eq!(
        vcx.update(|_, cx| host.read(cx).menu.read(cx).cursor().path.clone()),
        [0]
    );
    shows(&host, vcx, smallest());
}

#[gpui_kit::test]
fn the_deepest_chains_fit_the_smallest_window(cx: &mut TestAppContext) {
    let (host, _, vcx) = open_host(ChromeStyle::Windows, Menu::Deep, true, cx);
    vcx.simulate_resize(smallest());
    draw(vcx);
    let step = |keys: &str, vcx: &mut VisualTestContext| {
        vcx.simulate_keystrokes(keys);
        draw(vcx);
    };
    step("f10", vcx);
    // Chat, taller than the window: its last row.
    step("down down down down down down down down", vcx);
    step("right end", vcx);
    shows(&host, vcx, smallest());
    // Chat › Move to: its last folder.
    step("home right end", vcx);
    shows(&host, vcx, smallest());
    // Back to the menu, then Edit › Find: Edit opens at its top, not where
    // Chat was scrolled.
    step("escape escape up up up right", vcx);
    shows(&host, vcx, smallest());
    step("end right end", vcx);
    shows(&host, vcx, smallest());
}

/// A panel cut at the window's bottom shows a scroll bar, so the pointer
/// can see and reach the rows below the cut (Chat in a 720-point-tall
/// window); a panel that fits shows none.
#[gpui_kit::test]
fn a_panel_cut_at_the_window_shows_a_scroll_bar(cx: &mut TestAppContext) {
    let (_host, _, vcx) = open_host(ChromeStyle::Windows, Menu::Deep, true, cx);
    vcx.simulate_resize(smallest());
    draw(vcx);
    vcx.simulate_keystrokes("f10 down down down down down down down down right");
    draw(vcx);
    let panel = bounds("chrome-menu-panel-1".into(), vcx);
    let bar = vcx
        .debug_bounds("chrome-menu-scrollbar-1")
        .expect("Chat, cut at the window's bottom, shows no scroll bar");
    assert!(
        bar.right() <= panel.right() && bar.left() >= panel.left(),
        "the bar {bar:?} is inside its panel {panel:?}"
    );
    // Go, which fits, has none.
    vcx.simulate_keystrokes("escape up right");
    draw(vcx);
    assert!(vcx.debug_bounds("chrome-menu-panel-1").is_some());
    assert!(vcx.debug_bounds("chrome-menu-scrollbar-1").is_none());
}

/// Opens GNOME's menu with ☰ `menu_at` in from the leading edge of a
/// 1200-point window, then Also's submenu from the keyboard; the root
/// panel's bounds before and after.
fn root_before_and_after_a_submenu(
    menu_at: f32,
    cx: &mut TestAppContext,
) -> (
    gpui_kit::Bounds<gpui_kit::Pixels>,
    gpui_kit::Bounds<gpui_kit::Pixels>,
) {
    let (host, _, vcx) = open_host(ChromeStyle::Gnome, Menu::Rows, true, cx);
    vcx.simulate_resize(gpui_kit::size(px(1200.), px(800.)));
    vcx.update(|_, cx| {
        host.update(cx, |h, cx| {
            h.menu_at = menu_at;
            cx.notify();
        })
    });
    draw(vcx);
    vcx.simulate_keystrokes("f10");
    draw(vcx);
    let before = bounds("chrome-menu-panel-0".into(), vcx);
    // Down to Also, Right into its submenu.
    vcx.simulate_keystrokes("down right");
    draw(vcx);
    assert_eq!(
        vcx.update(|_, cx| host.read(cx).menu.read(cx).cursor().path.clone()),
        [3, 0]
    );
    let after = bounds("chrome-menu-panel-0".into(), vcx);
    let sub = bounds("chrome-menu-panel-1".into(), vcx);
    assert!(
        sub.left() >= px(0.) && sub.right() <= px(1200.),
        "the submenu {sub:?} is inside the window"
    );
    (before, after)
}

#[gpui_kit::test]
fn a_submenu_opening_left_leaves_gnomes_menu_where_it_was(cx: &mut TestAppContext) {
    let (before, after) = root_before_and_after_a_submenu(1150., cx);
    assert_eq!(after, before);
}

#[gpui_kit::test]
fn a_submenu_opening_right_leaves_gnomes_menu_where_it_was(cx: &mut TestAppContext) {
    let (before, after) = root_before_and_after_a_submenu(400., cx);
    assert_eq!(after, before);
}

#[gpui_kit::test]
fn gnomes_menu_stays_inside_the_visible_frame_not_its_shadow(cx: &mut TestAppContext) {
    let (host, _, vcx) = open_host(ChromeStyle::Gnome, Menu::Rows, true, cx);
    vcx.simulate_resize(gpui_kit::size(px(1200.), px(800.)));
    // Client-side decorated and floating: the frame sits a shadow's width
    // inside the window's surface.
    vcx.update(|_, cx| {
        let menu = host.read(cx).menu.clone();
        cx.set_global(super::ActiveChrome(Some(super::Chrome {
            style: ChromeStyle::Gnome,
            buttons: super::ButtonLayout::gnome(),
            decorations: Decorations::Client {
                tiling: Tiling::default(),
            },
            maximized: false,
            menu,
            labels: super::ControlLabels {
                minimize: "Minimize".into(),
                maximize: "Maximize".into(),
                restore: "Restore".into(),
                close: "Close".into(),
            },
            title: "Conduit".into(),
            on_close: None,
        })));
        host.update(cx, |h, cx| {
            h.menu_at = 1150.;
            cx.notify();
        });
    });
    draw(vcx);
    vcx.simulate_keystrokes("f10 down right");
    draw(vcx);
    let frame_right = px(1200. - super::controls::SHADOW);
    for panel in ["chrome-menu-panel-0", "chrome-menu-panel-1"] {
        let b = bounds(panel.into(), vcx);
        assert!(
            b.right() <= frame_right,
            "{panel} {b:?} ends inside the frame, at {frame_right:?} at most"
        );
    }
}

#[gpui_kit::test]
fn the_pointer_over_a_submenu_covering_its_parent_stays_in_the_submenu(cx: &mut TestAppContext) {
    let (host, _, vcx) = open_host(ChromeStyle::Windows, Menu::Deep, true, cx);
    vcx.simulate_resize(smallest());
    draw(vcx);
    // Edit › Find: with no room on the right, Find opens over Edit.
    vcx.simulate_keystrokes("f10 down down down down down right end right");
    draw(vcx);
    let path = || vec![7usize, 8, 0];
    assert_eq!(
        vcx.update(|_, cx| host.read(cx).menu.read(cx).cursor().path.clone()),
        path()
    );
    let row = bounds("chrome-menu-2-0".into(), vcx);
    let edit = bounds("chrome-menu-panel-1".into(), vcx);
    assert!(
        row.right() > edit.left() && row.top() < edit.bottom(),
        "Find's first row {row:?} covers Edit {edit:?}"
    );
    // A point on Find's row, over where Edit lies beneath.
    let at = point(
        (row.right() + edit.left().max(row.left())) / 2.,
        row.center().y,
    );
    vcx.simulate_mouse_move(at, None, Modifiers::none());
    draw(vcx);
    assert_eq!(
        vcx.update(|_, cx| host.read(cx).menu.read(cx).cursor().path.clone()),
        path(),
        "the covered Edit took no part in the move"
    );
}

/// A GNOME header bar alone, 200 × 40 at the window's top left.
struct Header;

impl Render for Header {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(
            super::header_drag("header", Some(ChromeStyle::Gnome), window, cx)
                .w(px(200.))
                .h(px(40.)),
        )
    }
}

/// GPUI's test window has no window move (`unimplemented!`), so reaching it
/// is how this test sees the drag start.
#[gpui_kit::test]
#[should_panic(expected = "not implemented")]
fn a_header_press_then_a_move_off_the_header_moves_the_window(cx: &mut TestAppContext) {
    let (_, vcx) = cx.add_window_view(|_, _| Header);
    draw(vcx);
    vcx.simulate_mouse_down(
        point(px(20.), px(20.)),
        MouseButton::Left,
        Modifiers::none(),
    );
    draw(vcx);
    // The first move after the press already leaves the header.
    vcx.simulate_mouse_move(
        point(px(20.), px(120.)),
        MouseButton::Left,
        Modifiers::none(),
    );
    draw(vcx);
}

/// A click on the header that ends before the next frame leaves no drag
/// waiting, whether it lets go on the header or just off it: a later drag in
/// the content doesn't move the window (it would reach the test window's
/// missing window move and panic).
#[gpui_kit::test]
fn a_quick_header_click_leaves_no_drag_waiting(cx: &mut TestAppContext) {
    let (_, vcx) = cx.add_window_view(|_, _| Header);
    draw(vcx);
    let none = Modifiers::none();
    let left = MouseButton::Left;
    let content = point(px(20.), px(200.));
    // Let go where it pressed, then 3 points down and off the header (the
    // drag starts at 4).
    for (press, release) in [
        (point(px(20.), px(20.)), point(px(20.), px(20.))),
        (point(px(20.), px(38.)), point(px(20.), px(41.))),
    ] {
        // Press, release and move to the content, all in one frame. A test
        // window draws after each simulated event, so they go in one update.
        vcx.update(|window, cx| {
            for event in [
                PlatformInput::MouseDown(MouseDownEvent {
                    position: press,
                    modifiers: none,
                    button: left,
                    click_count: 1,
                    first_mouse: false,
                }),
                PlatformInput::MouseMove(MouseMoveEvent {
                    position: release,
                    modifiers: none,
                    pressed_button: Some(left),
                }),
                PlatformInput::MouseUp(MouseUpEvent {
                    position: release,
                    modifiers: none,
                    button: left,
                    click_count: 1,
                }),
                PlatformInput::MouseMove(MouseMoveEvent {
                    position: content,
                    modifiers: none,
                    pressed_button: None,
                }),
            ] {
                window.dispatch_event(event, cx);
            }
        });
        draw(vcx);
        // A drag in the content, with no move between.
        vcx.simulate_mouse_down(content, left, none);
        vcx.simulate_mouse_move(point(px(20.), px(260.)), left, none);
        vcx.simulate_mouse_up(point(px(20.), px(260.)), left, none);
        draw(vcx);
    }
}

/// GNOME's frame alone, client-side decorated and floating.
struct Framed;

impl Render for Framed {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        ClientFrame::new(
            ChromeStyle::Gnome,
            Decorations::Client {
                tiling: Tiling::default(),
            },
            false,
            true,
            div().size_full(),
        )
    }
}

#[gpui_kit::test]
fn the_pointer_over_gnomes_resize_band_is_fine(cx: &mut TestAppContext) {
    cx.update(|cx| {
        cx.set_global(ConduitTheme::new(
            "conduit",
            false,
            DesignPrefs::default(),
            gpui_kit::blue(),
        ))
    });
    let (_, vcx) = cx.add_window_view(|_, _| Framed);
    draw(vcx);
    // In the left shadow band, then just inside the window's edge.
    vcx.simulate_mouse_move(point(px(6.), px(300.)), None, Modifiers::none());
    draw(vcx);
    vcx.simulate_mouse_move(
        point(px(super::controls::SHADOW + 2.), px(300.)),
        None,
        Modifiers::none(),
    );
    draw(vcx);
}
