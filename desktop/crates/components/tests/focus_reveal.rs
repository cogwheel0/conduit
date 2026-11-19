//! Keyboard focus moving into a scrolled list brings the control into view
//! (`Window::set_focus_reveal_inset`, patch 3 in vendor/gpui-pre/PATCHES.md).

use gpui_kit::{
    AppContext as _, Context, Element as _, FocusHandle, FollowMode, InteractiveElement,
    IntoElement, ListAlignment, ListOffset, ListState, ParentElement, Render, Styled,
    TestAppContext, VisualTestContext, Window, div, list, point, px, size,
};

const ROWS: usize = 10;
const ROW: f32 = 50.;
const VIEWPORT: f32 = 200.;
const INSET: f32 = 24.;

fn rows(cx: &mut VisualTestContext) -> (ListState, Vec<FocusHandle>) {
    let handles: Vec<FocusHandle> =
        cx.update(|_, cx| (0..ROWS).map(|_| cx.focus_handle()).collect());
    let state = ListState::new(ROWS, ListAlignment::Top, px(ROW));
    state.splice_focusable(0..ROWS, handles.iter().cloned().map(Some));
    cx.update(|window, _| window.set_focus_reveal_inset(Some(px(INSET))));
    (state, handles)
}

struct Rows(ListState, Vec<FocusHandle>);

impl Render for Rows {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let handles = self.1.clone();
        list(self.0.clone(), move |ix, _, _| {
            div()
                .h(px(ROW))
                .w_full()
                .child(div().size_full().track_focus(&handles[ix]))
                .into_any()
        })
        .w_full()
        .h_full()
    }
}

fn draw(state: &ListState, handles: &[FocusHandle], cx: &mut VisualTestContext) {
    let rows = Rows(state.clone(), handles.to_vec());
    cx.draw(
        point(px(0.), px(0.)),
        size(px(100.), px(VIEWPORT)),
        move |_, cx| cx.new(|_| rows).into_any_element(),
    );
}

/// Tab moved focus: the last input was a key press.
fn focus_by_keyboard(handle: &FocusHandle, cx: &mut VisualTestContext) {
    cx.simulate_keystrokes("tab");
    cx.update(|window, cx| handle.focus(window, cx));
}

/// Where `row` sits in the viewport, from the list's scroll position.
fn row_top(state: &ListState, row: usize) -> f32 {
    let ListOffset {
        item_ix,
        offset_in_item,
    } = state.logical_scroll_top();
    (row as f32 - item_ix as f32) * ROW - f32::from(offset_in_item)
}

#[gpui_kit::test]
fn a_control_focused_above_a_followed_tail_is_revealed(cx: &mut TestAppContext) {
    let cx = cx.add_empty_window();
    let (state, handles) = rows(cx);
    state.set_follow_mode(FollowMode::Tail);
    draw(&state, &handles, cx);
    assert!(state.is_following_tail());

    focus_by_keyboard(&handles[2], cx);
    draw(&state, &handles, cx);

    let top = row_top(&state, 2);
    assert!(
        (0. ..=VIEWPORT - ROW).contains(&top),
        "row 2 is in view (top at {top})"
    );
    assert!(!state.is_following_tail(), "following paused");

    // Back at the bottom, the list follows the tail again.
    state.scroll_to(ListOffset {
        item_ix: ROWS,
        offset_in_item: px(0.),
    });
    draw(&state, &handles, cx);
    draw(&state, &handles, cx);
    assert!(state.is_following_tail());
}

#[gpui_kit::test]
fn a_control_focused_just_above_the_viewport_scrolls_by_its_row(cx: &mut TestAppContext) {
    let cx = cx.add_empty_window();
    let (state, handles) = rows(cx);
    state.scroll_to(ListOffset {
        item_ix: 5,
        offset_in_item: px(0.),
    });
    draw(&state, &handles, cx);

    focus_by_keyboard(&handles[4], cx);
    draw(&state, &handles, cx);

    // Row 4 lands at the top, the inset clear of the edge.
    assert_eq!(row_top(&state, 4), INSET);
}

#[gpui_kit::test]
fn a_clicked_control_does_not_scroll(cx: &mut TestAppContext) {
    let cx = cx.add_empty_window();
    let (state, handles) = rows(cx);
    state.scroll_to(ListOffset {
        item_ix: 5,
        offset_in_item: px(0.),
    });
    draw(&state, &handles, cx);

    cx.simulate_mouse_move(
        point(px(10.), px(10.)),
        None,
        gpui_kit::Modifiers::default(),
    );
    cx.update(|window, cx| handles[4].focus(window, cx));
    draw(&state, &handles, cx);

    assert_eq!(
        state.logical_scroll_top(),
        ListOffset {
            item_ix: 5,
            offset_in_item: px(0.)
        }
    );
}
