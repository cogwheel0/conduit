//! The kit's controls as a Mac user meets them, in a real (test) window:
//! an icon button names itself in a tooltip after a pause, Tab reaches it
//! only with Full Keyboard Access on and draws a ring there, and a click
//! never takes focus from where it was. A disabled control is no stop; a
//! segmented control is one, with the arrows choosing inside it; a focused
//! list shows its selection darker instead of a ring.

use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use conduit_components::assets::IconName;
use conduit_components::theme::{ConduitTheme, DesignPrefs, install};
use conduit_components::views::focus::{KeyboardAccess, TOOLTIP_DELAY};
use conduit_components::views::kit::IconButton;
use gpui_kit::prelude::*;
use gpui_kit::{Context, Modifiers, TestAppContext, VisualTestContext, Window, div, point, px};

/// Two icon buttons at known places: "New Chat" at 20…48, "Settings" at
/// 68…96 (both 28 pt square, 20 pt from the top).
struct Bench {
    clicks: Rc<Cell<usize>>,
}

impl Render for Bench {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let (a, b) = (self.clicks.clone(), self.clicks.clone());
        div().size_full().child(
            div()
                .absolute()
                .top(px(20.))
                .left(px(20.))
                .flex()
                .gap(px(20.))
                .child(
                    IconButton::new("first", IconName::SquarePen, "New Chat")
                        .shortcut(Some("⌘N".into()))
                        .on_click(Rc::new(move |_, _, _| a.set(a.get() + 1))),
                )
                .child(
                    IconButton::new("second", IconName::Settings, "Settings")
                        .on_click(Rc::new(move |_, _, _| b.set(b.get() + 1))),
                ),
        )
    }
}

fn bench(cx: &mut TestAppContext, full_access: bool) -> (&mut VisualTestContext, Rc<Cell<usize>>) {
    cx.update(|cx| {
        gpui_kit::init(cx);
        install(
            ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
            cx,
        );
        cx.set_global(conduit_components::Strings::default());
        cx.set_global(KeyboardAccess {
            all_controls: full_access,
        });
    });
    let clicks: Rc<Cell<usize>> = Rc::default();
    let shared = clicks.clone();
    let (_, vcx) = cx.add_window_view(move |_, _| Bench { clicks: shared });
    draw(vcx);
    (vcx, clicks)
}

fn draw(vcx: &mut VisualTestContext) {
    vcx.update(|window, cx| window.draw(cx).clear(cx));
    vcx.run_until_parked();
}

fn tab(vcx: &mut VisualTestContext) {
    vcx.update(|window, cx| window.focus_next(cx));
    draw(vcx);
}

#[gpui_kit::test]
fn an_icon_button_shows_its_name_after_a_pause(cx: &mut TestAppContext) {
    let (vcx, _) = bench(cx, true);
    vcx.simulate_mouse_move(point(px(34.), px(34.)), None, Modifiers::none());
    draw(vcx);
    assert!(
        vcx.debug_bounds("tooltip").is_none(),
        "no tooltip before the delay"
    );
    vcx.executor()
        .advance_clock(TOOLTIP_DELAY + Duration::from_millis(100));
    draw(vcx);
    let tip = vcx
        .debug_bounds("tooltip")
        .expect("a tooltip after the delay");
    // It opens under the pointer, as AppKit's do.
    assert!(tip.origin.y > px(34.), "{tip:?}");
}

#[gpui_kit::test]
fn tab_reaches_buttons_only_with_full_keyboard_access(cx: &mut TestAppContext) {
    let (vcx, _) = bench(cx, false);
    tab(vcx);
    assert!(
        vcx.update(|window, cx| window.focused(cx)).is_none(),
        "Tab passes buttons by while Keyboard Navigation is off"
    );
    assert!(vcx.debug_bounds("focus-ring").is_none());

    vcx.update(|_, cx| {
        cx.set_global(KeyboardAccess { all_controls: true });
        cx.refresh_windows();
    });
    draw(vcx);
    tab(vcx);
    assert!(vcx.update(|window, cx| window.focused(cx)).is_some());
    let ring = vcx.debug_bounds("focus-ring").expect("a focus ring");
    // Outside the 28 pt button by the gap and the ring's width.
    assert_eq!(ring.size.width, px(36.));
    assert_eq!(ring.origin.x, px(16.));
}

#[gpui_kit::test]
fn a_click_runs_the_button_and_leaves_focus_where_it_was(cx: &mut TestAppContext) {
    let (vcx, clicks) = bench(cx, true);
    tab(vcx);
    let before = vcx.update(|window, cx| window.focused(cx));
    assert!(before.is_some());
    vcx.simulate_click(point(px(82.), px(34.)), Modifiers::none());
    draw(vcx);
    assert_eq!(clicks.get(), 1, "the click reached the second button");
    assert_eq!(
        vcx.update(|window, cx| window.focused(cx)),
        before,
        "focus stayed on the first button"
    );
}

/// The Settings window's section list, as a source list.
struct Pages {
    selected: Rc<Cell<usize>>,
}

impl Render for Pages {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        use conduit_components::views::settings::{SettingsWindow, default_tabs};
        let tabs = default_tabs();
        let id = tabs[self.selected.get()].id.clone();
        let selected = self.selected.clone();
        SettingsWindow::new(tabs, id, 210.).on_select(Rc::new(move |i, _, _| selected.set(i)))
    }
}

#[gpui_kit::test]
fn the_settings_list_moves_with_the_arrows(cx: &mut TestAppContext) {
    cx.update(|cx| {
        gpui_kit::init(cx);
        install(
            ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
            cx,
        );
        cx.set_global(conduit_components::Strings::default());
        cx.set_global(KeyboardAccess { all_controls: true });
    });
    let selected = Rc::new(Cell::new(3));
    let shared = selected.clone();
    let (view, vcx) = cx.add_window_view(move |_, _| Pages { selected: shared });
    draw(vcx);
    // Tab reaches the list (its only stop here): its selection darkens,
    // with no ring drawn over it.
    tab(vcx);
    assert!(vcx.debug_bounds("settings-selection").is_some());
    assert!(
        vcx.debug_bounds("focus-ring").is_none(),
        "a focused list shows no ring"
    );
    let press = |keys: &str, vcx: &mut VisualTestContext| {
        vcx.simulate_keystrokes(keys);
        vcx.update(|_, cx| view.update(cx, |_, cx| cx.notify()));
        draw(vcx);
    };
    press("down", vcx);
    assert_eq!(selected.get(), 4, "↓ moves to the next section");
    press("up", vcx);
    press("up", vcx);
    assert_eq!(selected.get(), 2, "↑ moves back");
    press("end", vcx);
    assert_eq!(selected.get(), 8);
}

/// A disabled button between two others, and a segmented control.
struct Loop {
    chosen: Rc<Cell<usize>>,
}

impl Render for Loop {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        use conduit_components::views::kit::{Segment, Segmented};
        let chosen = self.chosen.clone();
        div().size_full().child(
            div()
                .absolute()
                .top(px(20.))
                .left(px(20.))
                .flex()
                .gap(px(20.))
                .child(IconButton::new("before", IconName::SquarePen, "New Chat"))
                .child(
                    IconButton::new("send", IconName::ArrowUp, "Send")
                        .filled(gpui_kit::black(), gpui_kit::white())
                        .disabled(true),
                )
                // At 116…: three segments.
                .child(
                    Segmented::new(
                        "layout",
                        "Layout",
                        vec![
                            Segment::new("Compact"),
                            Segment::new("Regular"),
                            Segment::new("Roomy"),
                        ],
                        self.chosen.get(),
                    )
                    .on_select(Rc::new(move |i, _, _| chosen.set(i))),
                ),
        )
    }
}

fn loop_bench(
    cx: &mut TestAppContext,
) -> (
    gpui_kit::Entity<Loop>,
    &mut VisualTestContext,
    Rc<Cell<usize>>,
) {
    cx.update(|cx| {
        gpui_kit::init(cx);
        install(
            ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
            cx,
        );
        cx.set_global(conduit_components::Strings::default());
        cx.set_global(KeyboardAccess { all_controls: true });
    });
    let chosen = Rc::new(Cell::new(1));
    let shared = chosen.clone();
    let (view, vcx) = cx.add_window_view(move |_, _| Loop { chosen: shared });
    draw(vcx);
    (view, vcx, chosen)
}

#[gpui_kit::test]
fn tab_passes_a_disabled_button_and_stops_once_on_a_segmented_control(cx: &mut TestAppContext) {
    let (_, vcx, _) = loop_bench(cx);
    tab(vcx);
    let first = vcx.update(|window, cx| window.focused(cx));
    assert!(first.is_some(), "New Chat takes focus");
    // Next: past the disabled Send, onto the segmented control as a whole.
    tab(vcx);
    let ring = vcx
        .debug_bounds("focus-ring")
        .expect("the chosen segment rings");
    assert!(
        ring.origin.x > px(116.),
        "the ring is on a segment, not Send: {ring:?}"
    );
    // Then round to New Chat: the other segments are no stops of their own.
    tab(vcx);
    assert_eq!(vcx.update(|window, cx| window.focused(cx)), first);
}

#[gpui_kit::test]
fn the_arrows_choose_inside_a_segmented_control(cx: &mut TestAppContext) {
    let (view, vcx, chosen) = loop_bench(cx);
    tab(vcx);
    tab(vcx);
    let ring = |vcx: &mut VisualTestContext| vcx.debug_bounds("focus-ring").map(|b| b.origin.x);
    let before = ring(vcx).expect("a ring on Regular");
    let press = |keys: &str, vcx: &mut VisualTestContext| {
        vcx.simulate_keystrokes(keys);
        vcx.update(|_, cx| view.update(cx, |_, cx| cx.notify()));
        draw(vcx);
    };
    press("right", vcx);
    assert_eq!(chosen.get(), 2, "→ chooses the next segment");
    let after = ring(vcx).expect("the ring follows the choice");
    assert!(after > before, "{after:?} after {before:?}");
    press("right", vcx);
    assert_eq!(chosen.get(), 2, "→ stops at the last segment");
    press("left", vcx);
    press("left", vcx);
    assert_eq!(chosen.get(), 0);
    press("end", vcx);
    assert_eq!(chosen.get(), 2);
}

#[gpui_kit::test]
fn a_click_on_a_segment_chooses_it_without_a_ring(cx: &mut TestAppContext) {
    let (_, vcx, chosen) = loop_bench(cx);
    let segment = vcx.debug_bounds("focus-ring").map(|b| b.origin.x);
    assert!(segment.is_none());
    // The first segment starts 2 pt into the control at 116.
    vcx.simulate_click(point(px(130.), px(34.)), Modifiers::none());
    draw(vcx);
    assert_eq!(chosen.get(), 0, "the click chose Compact");
    assert!(
        vcx.update(|window, cx| window.focused(cx)).is_none(),
        "a click takes no focus"
    );
    assert!(
        vcx.debug_bounds("focus-ring").is_none(),
        "and draws no ring"
    );
    // Nor does a right click (any button would focus a focusable element).
    let at = point(px(130.), px(34.));
    vcx.simulate_mouse_down(at, gpui_kit::MouseButton::Right, Modifiers::none());
    vcx.simulate_mouse_up(at, gpui_kit::MouseButton::Right, Modifiers::none());
    draw(vcx);
    assert!(vcx.update(|window, cx| window.focused(cx)).is_none());
}

/// Settings › Appearance's theme tiles: a radio group drawn by a builder
/// with no window.
struct Tiles {
    chosen: Rc<Cell<usize>>,
}

impl Render for Tiles {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        use conduit_components::views::settings::{SchemeTile, scheme_tiles};
        let chosen = self.chosen.clone();
        div()
            .size_full()
            .flex()
            .gap(px(20.))
            .child(IconButton::new("before", IconName::SquarePen, "New Chat"))
            .child(scheme_tiles(
                &[
                    (SchemeTile::System, "System".into()),
                    (SchemeTile::Light, "Light".into()),
                    (SchemeTile::Dark, "Dark".into()),
                ],
                self.chosen.get(),
                Some(Rc::new(move |i, _, _| chosen.set(i))),
                cx,
            ))
    }
}

#[gpui_kit::test]
fn the_theme_tiles_are_one_stop_with_the_arrows_inside(cx: &mut TestAppContext) {
    cx.update(|cx| {
        gpui_kit::init(cx);
        install(
            ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
            cx,
        );
        cx.set_global(conduit_components::Strings::default());
        cx.set_global(KeyboardAccess { all_controls: true });
    });
    let chosen = Rc::new(Cell::new(0));
    let shared = chosen.clone();
    let (view, vcx) = cx.add_window_view(move |_, _| Tiles { chosen: shared });
    draw(vcx);
    tab(vcx);
    let button = vcx.update(|window, cx| window.focused(cx));
    tab(vcx);
    let tiles = vcx.update(|window, cx| window.focused(cx));
    assert!(tiles.is_some() && tiles != button, "Tab reaches the tiles");
    vcx.simulate_keystrokes("right");
    vcx.update(|_, cx| view.update(cx, |_, cx| cx.notify()));
    draw(vcx);
    assert_eq!(chosen.get(), 1, "→ chooses Light");
    assert_eq!(
        vcx.update(|window, cx| window.focused(cx)),
        tiles,
        "focus stays on the group"
    );
    // Three tiles, one stop: the next Tab is back on the button.
    tab(vcx);
    assert_eq!(vcx.update(|window, cx| window.focused(cx)), button);
}

/// Three sidebar rows: plain, hovered without actions (another user's
/// read-only chat) and hovered with "…".
struct Rows;

impl Render for Rows {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        use conduit_components::ActiveConduitTheme as _;
        use conduit_components::views::model::ChatRow;
        use conduit_components::views::sidebar::{RowAction, RowState, chat_row};
        let t = cx.conduit().clone();
        let row = |id: &str| ChatRow {
            id: id.to_string().into(),
            title: "Trail snack ideas".into(),
            time: "5:46 AM".into(),
            time_spoken: "5:46 AM".into(),
            pinned: false,
            streaming: false,
            working: false,
            reduce_motion: false,
            status: None,
            note: None,
            unread: false,
            unread_spoken: None,
        };
        let hovered = RowState {
            hovered: true,
            ..RowState::default()
        };
        div()
            .w(px(240.))
            .flex()
            .flex_col()
            .child(chat_row(
                &row("plain"),
                RowState::default(),
                0.,
                vec![],
                None,
                &t,
            ))
            .child(chat_row(&row("read-only"), hovered, 0., vec![], None, &t))
            .child(chat_row(
                &row("with-more"),
                hovered,
                0.,
                vec![RowAction::new("more", IconName::Ellipsis, "More")],
                None,
                &t,
            ))
    }
}

#[gpui_kit::test]
fn hovering_a_row_never_moves_its_date(cx: &mut TestAppContext) {
    cx.update(|cx| {
        gpui_kit::init(cx);
        install(
            ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
            cx,
        );
        cx.set_global(conduit_components::Strings::default());
    });
    let (_, vcx) = cx.add_window_view(|_, _| Rows);
    draw(vcx);
    let right = |vcx: &mut VisualTestContext, id: &str| {
        vcx.debug_bounds(Box::leak(format!("row-time-{id}").into_boxed_str()))
            .map(|b| b.right())
            .expect("the date is laid out")
    };
    let plain = right(vcx, "plain");
    // A read-only row has no hover button, and its date stays where a
    // plain row's is.
    assert_eq!(right(vcx, "read-only"), plain);
    // With "…" the date keeps its slot (drawn under the button, hidden).
    assert_eq!(right(vcx, "with-more"), plain);
}

/// The chat toolbar as the main window draws it: a control at each end and
/// the title capsule in the middle.
struct ToolbarBench;

impl Render for ToolbarBench {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        use conduit_components::views::shell::{ChatToolbar, TitlePill};
        div().size_full().child(
            ChatToolbar::new("A chat", "Kestrel 8B")
                .bare()
                .leading(IconButton::new(
                    "show-sidebar",
                    IconName::PanelLeft,
                    "Show Sidebar",
                ))
                .pill(
                    TitlePill::new("Kestrel 8B", "Model: Kestrel 8B").title(Some("A chat".into())),
                )
                .trailing(IconButton::new(
                    "temporary-chat",
                    IconName::CircleDashed,
                    "Temporary Chat",
                ))
                .trailing(IconButton::new("chat-more", IconName::Ellipsis, "More")),
        )
    }
}

#[gpui_kit::test]
fn tab_crosses_the_toolbar_left_to_right(cx: &mut TestAppContext) {
    cx.update(|cx| {
        gpui_kit::init(cx);
        install(
            ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
            cx,
        );
        cx.set_global(conduit_components::Strings::default());
        cx.set_global(KeyboardAccess { all_controls: true });
    });
    let (_, vcx) = cx.add_window_view(|_, _| ToolbarBench);
    draw(vcx);
    // Reading order: the sidebar control, the title capsule (the model),
    // then Temporary Chat and More, never the capsule after its right.
    let mut xs = vec![];
    for _ in 0..4 {
        tab(vcx);
        let ring = vcx.debug_bounds("focus-ring").expect("a focus ring");
        xs.push(f32::from(ring.origin.x));
    }
    assert!(xs.windows(2).all(|w| w[0] < w[1]), "rings at {xs:?}");
}

/// The sidebar's frame with a search field holding a query (`clear`) or
/// not.
struct SearchBench {
    clear: bool,
    cleared: Rc<Cell<usize>>,
}

impl Render for SearchBench {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        use conduit_components::views::model::{Account, Backend, SyncState};
        use conduit_components::views::sidebar::SidebarFrame;
        let cleared = self.cleared.clone();
        let account = Account {
            id: "a".into(),
            name: "Avery".into(),
            email: "avery@example.test".into(),
            server: "example.test".into(),
            backend: Backend::OpenWebUi,
            active: true,
            needs_sign_in: false,
        };
        let synced = SyncState::Synced {
            detail: "Synced".into(),
        };
        let handler: conduit_components::views::kit::ClickHandler =
            Rc::new(move |_, _, _| cleared.set(cleared.get() + 1));
        div().size_full().child(
            SidebarFrame::new(div(), synced, account)
                .search(div().child("tides"))
                .on_clear_search(self.clear.then_some(handler)),
        )
    }
}

#[gpui_kit::test]
fn the_search_field_clears_with_its_cancel_button_only_while_it_has_text(cx: &mut TestAppContext) {
    cx.update(|cx| {
        gpui_kit::init(cx);
        install(
            ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
            cx,
        );
        cx.set_global(conduit_components::Strings::default());
        cx.set_global(KeyboardAccess {
            all_controls: false,
        });
    });
    let cleared: Rc<Cell<usize>> = Rc::default();
    let shared = cleared.clone();
    let (_, empty) = cx.add_window_view(move |_, _| SearchBench {
        clear: false,
        cleared: shared,
    });
    draw(empty);
    // Empty: the ⌥⌘F hint, no ⓧ.
    assert!(empty.debug_bounds("sidebar-search-clear").is_none());
    let shared = cleared.clone();
    let (_, typed) = cx.add_window_view(move |_, _| SearchBench {
        clear: true,
        cleared: shared,
    });
    draw(typed);
    let x = typed
        .debug_bounds("sidebar-search-clear")
        .expect("a query shows the cancel button");
    typed.simulate_click(x.center(), Modifiers::none());
    draw(typed);
    assert_eq!(cleared.get(), 1, "the ⓧ clears the field");
}

/// A form field with two lines of help under it, as onboarding's Server
/// Address.
struct FormBench {
    input: gpui_kit::Entity<gpui_kit::component::input::InputState>,
}

impl Render for FormBench {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(
            div()
                .absolute()
                .top(px(10.))
                .left(px(10.))
                .w(px(460.))
                .child(crate::views::forms::field(
                    "Server Address",
                    &self.input,
                    Some(
                        "Conduit checks the server before you sign in. It has to be \
                         reachable from this Mac, over http or https."
                            .into(),
                    ),
                    None,
                    window,
                    cx,
                )),
        )
    }
}

#[gpui_kit::test]
fn a_form_label_sits_on_its_fields_first_line(cx: &mut TestAppContext) {
    cx.update(|cx| {
        gpui_kit::init(cx);
        install(
            ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
            cx,
        );
        cx.set_global(conduit_components::Strings::default());
    });
    let (_, vcx) = cx.add_window_view(|window, cx| FormBench {
        input: crate::views::forms::input("https://openwebui.example.com", false, window, cx),
    });
    draw(vcx);
    let label = vcx.debug_bounds("form-label").expect("the label");
    let field = vcx.debug_bounds("form-field-box").expect("the field");
    // The label's line is the field's box, not the field and its help
    // together (which sat it 10–19 pt low).
    assert_eq!(label.origin.y, field.origin.y);
    assert_eq!(label.size.height, field.size.height);
    // A row without help keeps the old height: the field is centred in
    // the 44 pt row.
    let row = conduit_components::theme::Metrics::for_density(Default::default());
    assert_eq!(
        crate::views::forms::first_line_pad(row.row_height + 16., row.control_height - 4.) * 2.
            + row.control_height
            - 4.,
        row.row_height + 16.
    );
}
