//! Add Account: a window sheet on Settings, as System Settings › Internet
//! Accounts › Add Account and Mail's account sheet present one.
//!
//! The sheet is a window of its own hosting the server form (AppKit's
//! `beginSheet:` hangs it from Settings' title bar, window-modal), with
//! Cancel and Connect at its bottom-right. Esc and ⌘. cancel (⌘W too, as
//! the sheet's window is the one in front); Return connects once an
//! address is typed. The window follows the form's height (taller with
//! Advanced Settings open), up to what fits under Settings' title bar, and
//! scrolls beyond that. Sign-in for the new account follows in the setup
//! window once the server answers.

use std::cell::Cell;
use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::theme::UI_FONT;
use conduit_components::views::kit::grouped_tones;
use gpui_kit::prelude::*;
use gpui_kit::{
    App, Bounds, Context, Entity, EventEmitter, FocusHandle, Focusable, Pixels, Role, SharedString,
    Subscription, Window, WindowBackgroundAppearance, WindowBounds, WindowKind, WindowOptions, div,
    point, px, size,
};

use crate::actions::CloseWindow;
use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::views::server_form::{ServerForm, ServerFormEvent};

/// The sheet's width (Mail's account sheet is about this wide).
pub const SHEET_WIDTH: f32 = 480.;
/// The form's inset from the sheet's edges.
pub const PADDING: f32 = 20.;
/// What the sheet opens at, before its first frame measures the form.
pub const FIRST_HEIGHT: f32 = 330.;
/// The least room left under the sheet in its parent.
pub const PARENT_MARGIN: f64 = 40.;

/// The sheet's window: opened hidden and fixed; `beginSheet:` shows it.
pub fn window_options() -> WindowOptions {
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
            point(px(0.), px(0.)),
            size(px(SHEET_WIDTH), px(FIRST_HEIGHT)),
        ))),
        titlebar: Some(gpui_kit::TitlebarOptions {
            title: None,
            appears_transparent: true,
            traffic_light_position: None,
        }),
        focus: false,
        show: false,
        kind: WindowKind::Normal,
        is_movable: false,
        is_resizable: false,
        is_minimizable: false,
        window_background: WindowBackgroundAppearance::Opaque,
        window_min_size: None,
        ..Default::default()
    }
}

/// Whether a sheet sized for `requested` must change for a form `measured`
/// tall (half a point either way is the same height).
pub fn needs_fit(requested: Option<f32>, measured: f32) -> bool {
    requested.is_none_or(|r| (r - measured).abs() >= 0.5)
}

pub struct AddAccountSheet {
    pub form: Entity<ServerForm>,
    focus: FocusHandle,
    /// The height last asked of the window, so a request never repeats
    /// while AppKit resizes it.
    requested: Rc<Cell<Option<f32>>>,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<ServerFormEvent> for AddAccountSheet {}

impl AddAccountSheet {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let form = cx.new(|cx| {
            let mut f = ServerForm::new(stores, window, cx);
            f.reset(true, window, cx);
            f.sheet = true;
            f
        });
        // The address takes the caret, as the sheet drops in.
        let url = form.read(cx).url.clone();
        let field = gpui_kit::Focusable::focus_handle(url.read(cx), cx);
        window.focus(&field, cx);
        let subscriptions = vec![
            // Cancel and Connected reach Settings, which ends the sheet.
            cx.subscribe(&form, |_, _, e: &ServerFormEvent, cx| cx.emit(e.clone())),
        ];
        Self {
            form,
            focus: cx.focus_handle(),
            requested: Rc::new(Cell::new(None)),
            _subscriptions: subscriptions,
        }
    }

    /// Cancel, as the form's Cancel button: unless a server is being
    /// checked.
    pub fn cancel(&mut self, cx: &mut Context<Self>) {
        if !self.form.read(cx).busy {
            cx.emit(ServerFormEvent::Back);
        }
    }
}

impl Focusable for AddAccountSheet {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

/// Fits the sheet's window to the form, `height` points tall, after this
/// frame (AppKit calls back into GPUI on a resize). The first fit comes
/// as the sheet drops in, so it doesn't animate on top of AppKit's slide.
fn fit(height: f32, first: bool, window: &Window, cx: &App) {
    #[cfg(target_os = "macos")]
    if let Some(ns) = crate::shell::macos::ns_window(window) {
        let animate = !first && !cx.reduce_motion();
        cx.foreground_executor()
            .spawn(async move {
                crate::shell::macos::fit_sheet(&ns, f64::from(height), PARENT_MARGIN, animate)
            })
            .detach();
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (height, first, window, cx);
}

impl Render for AddAccountSheet {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let (page, _) = grouped_tones(&t);
        let requested = self.requested.clone();
        // The form's natural height (the content box, padding included).
        let probe = gpui_kit::canvas(
            |bounds: Bounds<Pixels>, _, _| f32::from(bounds.size.height),
            move |_, height, window, cx| {
                let before = requested.get();
                if needs_fit(before, height) {
                    requested.set(Some(height));
                    fit(height, before.is_none(), window, cx);
                }
            },
        )
        .absolute()
        .top_0()
        .left_0()
        .size_full();
        div()
            .id("add-account-sheet")
            .role(Role::Dialog)
            .aria_label(SharedString::from(cx.l10n().desktop_add_account()))
            .key_context("ConduitSheet")
            .track_focus(&self.focus)
            .size_full()
            .overflow_y_scroll()
            .font_family(UI_FONT)
            .bg(page)
            .text_color(t.roles.text)
            // Esc and ⌘. cancel, as in any sheet.
            .on_key_down(cx.listener(|this, e: &gpui_kit::KeyDownEvent, _, cx| {
                let k = &e.keystroke;
                let m = &k.modifiers;
                let esc = k.key == "escape" && !(m.platform || m.alt || m.control || m.shift);
                let cmd_period = k.key == "." && m.platform && !(m.alt || m.control);
                if esc || cmd_period {
                    this.cancel(cx);
                    cx.stop_propagation();
                }
            }))
            // ⌘W in a sheet cancels it (the window under it stays).
            .on_action(cx.listener(|this, _: &CloseWindow, _, cx| this.cancel(cx)))
            .child(
                div()
                    .relative()
                    .w_full()
                    .p(px(PADDING))
                    .child(self.form.clone())
                    .child(probe),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_sheet_opens_hidden_fixed_and_480_wide() {
        let o = window_options();
        assert!(!o.show && !o.focus);
        assert!(!o.is_resizable && !o.is_minimizable && !o.is_movable);
        assert!(o.window_min_size.is_none());
        match o.window_bounds {
            Some(WindowBounds::Windowed(b)) => {
                assert_eq!(f32::from(b.size.width), SHEET_WIDTH)
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn the_sheet_refits_only_when_the_form_changes_height() {
        assert!(needs_fit(None, 310.));
        assert!(!needs_fit(Some(310.), 310.3));
        assert!(needs_fit(Some(310.), 512.));
        assert!(needs_fit(Some(512.), 310.));
    }
}
