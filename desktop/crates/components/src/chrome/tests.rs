//! ☰ in a window: how it opens, greys and hands its action back.

use std::rc::Rc;

use gpui_kit::prelude::*;
use gpui_kit::{
    Context, Entity, FocusHandle, KeyBinding, Modifiers, TestAppContext, VisualTestContext, Window,
    actions, div,
};

use super::ChromeStyle;
use super::main_menu::{MainMenu, MainMenuButton};
use super::menu::ChromeMenuItem;
use crate::theme::{ConduitTheme, DesignPrefs};

actions!(chrome_window_test, [Answered, Unanswered, Stop]);

/// A field with a handler for [`Answered`] only, and ☰.
struct Host {
    field: FocusHandle,
    menu: Entity<MainMenu>,
    answered: usize,
}

impl Render for Host {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .child(
                div()
                    .track_focus(&self.field)
                    .on_action(cx.listener(|h, _: &Answered, _, _| h.answered += 1))
                    .size_full(),
            )
            .child(MainMenuButton::new(self.menu.clone()))
    }
}

fn items() -> Vec<ChromeMenuItem> {
    vec![
        ChromeMenuItem::action("Answered", Answered),
        ChromeMenuItem::action("Unanswered", Unanswered),
        ChromeMenuItem::submenu(
            "More",
            vec![ChromeMenuItem::action("Unanswered", Unanswered)],
        ),
    ]
}

fn open_host(
    style: ChromeStyle,
    cx: &mut TestAppContext,
) -> (Entity<Host>, &mut VisualTestContext) {
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
        cx.bind_keys([KeyBinding::new("escape", Stop, None)]);
        cx.on_action(|_: &Stop, _| {});
    });
    let (host, vcx) = cx.add_window_view(|window, cx| {
        let field = cx.focus_handle();
        window.focus(&field, cx);
        let menu =
            cx.new(|cx| MainMenu::new(style, "Main Menu", Rc::new(|_, _| items()), window, cx));
        Host {
            field,
            menu,
            answered: 0,
        }
    });
    vcx.update(|window, _| window.activate_window());
    vcx.run_until_parked();
    (host, vcx)
}

fn is_open(host: &Entity<Host>, vcx: &mut VisualTestContext) -> bool {
    vcx.update(|_, cx| host.read(cx).menu.read(cx).is_open())
}

/// (label, greyed) for each row of the open menu's top level.
fn rows(host: &Entity<Host>, vcx: &mut VisualTestContext) -> Vec<(String, bool)> {
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

#[gpui_kit::test]
fn f10_opens_the_menu_greyed_by_what_answers_where_focus_was(cx: &mut TestAppContext) {
    let (host, vcx) = open_host(ChromeStyle::Gnome, cx);
    assert!(!is_open(&host, vcx));
    vcx.simulate_keystrokes("f10");
    vcx.run_until_parked();
    assert!(is_open(&host, vcx));
    assert_eq!(
        rows(&host, vcx),
        [
            ("Answered".to_string(), false),
            ("Unanswered".to_string(), true),
            ("More".to_string(), true),
        ],
        "AppKit's rule: an item is off when nothing where focus was answers it"
    );
    assert!(!field_focused(&host, vcx), "the open menu has the keyboard");
    // Esc closes it, though a binding without a context wants Esc too.
    vcx.simulate_keystrokes("escape");
    vcx.run_until_parked();
    assert!(!is_open(&host, vcx));
    assert!(field_focused(&host, vcx), "focus goes back where it was");
}

#[gpui_kit::test]
fn a_lone_alt_opens_the_menu_on_windows_only(cx: &mut TestAppContext) {
    let (host, vcx) = open_host(ChromeStyle::Windows, cx);
    vcx.simulate_modifiers_change(Modifiers::alt());
    vcx.simulate_modifiers_change(Modifiers::none());
    vcx.run_until_parked();
    assert!(is_open(&host, vcx));
    // Alt again closes it, as it leaves Windows' menu bar.
    vcx.simulate_modifiers_change(Modifiers::alt());
    vcx.simulate_modifiers_change(Modifiers::none());
    vcx.run_until_parked();
    assert!(!is_open(&host, vcx));
    // Alt with a key is a chord, not the menu.
    vcx.simulate_keystrokes("alt-x");
    vcx.run_until_parked();
    assert!(!is_open(&host, vcx));
}

#[gpui_kit::test]
fn a_lone_alt_leaves_gnomes_menu_shut(cx: &mut TestAppContext) {
    let (host, vcx) = open_host(ChromeStyle::Gnome, cx);
    vcx.simulate_modifiers_change(Modifiers::alt());
    vcx.simulate_modifiers_change(Modifiers::none());
    vcx.run_until_parked();
    assert!(
        !is_open(&host, vcx),
        "GNOME opens its primary menu on F10 only"
    );
}

#[gpui_kit::test]
fn enter_runs_the_highlighted_item_where_focus_was(cx: &mut TestAppContext) {
    let (host, vcx) = open_host(ChromeStyle::Windows, cx);
    vcx.simulate_keystrokes("f10");
    vcx.run_until_parked();
    // Opened from the keyboard: the first item is highlighted.
    vcx.simulate_keystrokes("enter");
    vcx.run_until_parked();
    assert!(!is_open(&host, vcx));
    assert_eq!(vcx.update(|_, cx| host.read(cx).answered), 1);
    assert!(field_focused(&host, vcx));
    // The greyed rows can't be reached: Down wraps back to the first.
    vcx.simulate_keystrokes("f10");
    vcx.run_until_parked();
    vcx.simulate_keystrokes("down enter");
    vcx.run_until_parked();
    assert_eq!(vcx.update(|_, cx| host.read(cx).answered), 2);
}
