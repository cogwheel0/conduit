//! The kit's controls and motion in a (test) window: a disabled button or
//! switch neither runs its action nor takes a Tab stop, and a fully open
//! reveal is its child's height in the frame it is drawn.

use std::cell::Cell;
use std::rc::Rc;

use conduit_components::motion::Reveal;
use conduit_components::theme::{ConduitTheme, DesignPrefs, install};
use conduit_components::views::focus::KeyboardAccess;
use conduit_components::views::kit::{Button, Switch};
use gpui_kit::prelude::*;
use gpui_kit::{
    Context, Modifiers, TestAppContext, VisualTestContext, Window, canvas, div, point, px, size,
};

fn setup(cx: &mut TestAppContext) {
    cx.update(|cx| {
        gpui_kit::init(cx);
        install(
            ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
            cx,
        );
        cx.set_global(conduit_components::Strings::default());
        cx.set_global(KeyboardAccess { all_controls: true });
    });
}

fn draw(vcx: &mut VisualTestContext) {
    vcx.update(|window, cx| window.draw(cx).clear(cx));
    vcx.run_until_parked();
}

/// A disabled button and a disabled switch, 20 pt from the top left.
struct Disabled {
    clicks: Rc<Cell<usize>>,
}

impl Render for Disabled {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let (a, b) = (self.clicks.clone(), self.clicks.clone());
        div()
            .size_full()
            .flex()
            .flex_col()
            .gap(px(20.))
            .p(px(20.))
            .child(
                div().debug_selector(|| "button".into()).child(
                    Button::new("delete", "Delete")
                        .disabled(true)
                        .on_click(Rc::new(move |_, _, _| a.set(a.get() + 1))),
                ),
            )
            .child(
                div().debug_selector(|| "switch".into()).child(
                    Switch::new("sync", "Sync", false)
                        .disabled(true)
                        .on_click(Rc::new(move |_, _, _| b.set(b.get() + 1))),
                ),
            )
    }
}

fn disabled(cx: &mut TestAppContext) -> (&mut VisualTestContext, Rc<Cell<usize>>) {
    setup(cx);
    let clicks: Rc<Cell<usize>> = Rc::default();
    let shared = clicks.clone();
    let (_, vcx) = cx.add_window_view(move |_, _| Disabled { clicks: shared });
    draw(vcx);
    (vcx, clicks)
}

#[gpui_kit::test]
fn a_disabled_button_does_not_run_its_action(cx: &mut TestAppContext) {
    let (vcx, clicks) = disabled(cx);
    let button = vcx.debug_bounds("button").expect("the button");
    vcx.simulate_click(button.center(), Modifiers::none());
    draw(vcx);
    let switch = vcx.debug_bounds("switch").expect("the switch");
    vcx.simulate_click(switch.center(), Modifiers::none());
    draw(vcx);
    assert_eq!(clicks.get(), 0);
}

#[gpui_kit::test]
fn tab_passes_a_disabled_button_and_switch_by(cx: &mut TestAppContext) {
    let (vcx, _) = disabled(cx);
    vcx.update(|window, cx| window.focus_next(cx));
    draw(vcx);
    assert!(vcx.update(|window, cx| window.focused(cx)).is_none());
    assert!(vcx.debug_bounds("focus-ring").is_none());
}

/// One layout pass of a fully open reveal over a box `height` tall, with a
/// marker under it: where the marker lands.
fn marker_under_open_reveal(vcx: &mut VisualTestContext, height: f32) -> f32 {
    let top = Rc::new(Cell::new(f32::NAN));
    let seen = top.clone();
    vcx.draw(
        point(px(0.), px(0.)),
        size(px(200.), px(200.)),
        move |_, _| {
            div()
                .size_full()
                .flex()
                .flex_col()
                .child(Reveal::new("open", 1., div().w_full().h(px(height))))
                .child(
                    canvas(
                        move |b, _, _| seen.set(f32::from(b.origin.y)),
                        |_, _, _, _| {},
                    )
                    .h(px(10.))
                    .w_full(),
                )
        },
    );
    top.get()
}

#[gpui_kit::test]
fn a_fully_open_reveal_is_its_childs_height_in_the_same_frame(cx: &mut TestAppContext) {
    setup(cx);
    let vcx = cx.add_empty_window();
    assert_eq!(marker_under_open_reveal(vcx, 40.), 40.);
    // Content that grows is followed at once, not a frame later.
    assert_eq!(marker_under_open_reveal(vcx, 64.), 64.);
}

#[gpui_kit::test]
fn kit_draws_secondary_text_in_the_legible_grey(cx: &mut TestAppContext) {
    for palette in ["conduit", "claude", "t3_chat", "catppuccin", "tangerine"] {
        for dark in [false, true] {
            cx.update(|cx| {
                gpui_kit::init(cx);
                let theme =
                    ConduitTheme::new(palette, dark, DesignPrefs::default(), gpui_kit::black());
                let subtle = theme.roles.text_subtle;
                install(theme, cx);
                let kit = gpui_kit::component::Theme::global(cx);
                assert_eq!(kit.muted_foreground, subtle, "{palette} dark={dark}");
                assert_eq!(kit.tab_foreground, subtle, "{palette} dark={dark}");
            });
        }
    }
}
