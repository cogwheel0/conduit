//! Window sheets on the main window: Chat Settings, Tool Settings, Folder
//! Settings and Share Folder, as a Mac app presents a form about the thing
//! in front of it (Mail's rules, Calendar's Get Info for a calendar).
//!
//! A sheet is a window of its own, opened hidden and hung from the main
//! window with AppKit's `beginSheet:` (Add Account does the same on
//! Settings). It is window-modal: the main window waits, the sheet has the
//! keyboard. Esc, ⌘. and ⌘W go to the body's [`SheetBody::cancel`], which
//! asks before throwing edits away. The window follows the body's height,
//! up to what fits under the main window's title bar, and scrolls beyond
//! that. One sheet at a time, as AppKit allows one per window: the chat's
//! own sheets (Branches, Share Chat, in [`crate::views::chat::sheets`]) are
//! registered here too, so no sheet is ever begun under another.

use std::cell::Cell;
use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::theme::UI_FONT;
use conduit_components::views::kit::grouped_tones;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, AnyEntity, AnyWindowHandle, App, Bounds, Context, Entity, FocusHandle, Focusable,
    Global, Pixels, Role, SharedString, Subscription, Window, WindowBackgroundAppearance,
    WindowBounds, WindowKind, WindowOptions, div, point, px, size,
};

use crate::actions::CloseWindow;

/// The body's inset from the sheet's edges.
pub const PADDING: f32 = 20.;
/// What a sheet opens at, before its first frame measures the body.
const FIRST_HEIGHT: f32 = 360.;
/// The least room left under the sheet in the main window.
const PARENT_MARGIN: f64 = 40.;

/// What a sheet shows.
pub trait SheetBody: Render + Sized + 'static {
    /// Esc, ⌘. and ⌘W: close, unless the body asks first (unsaved edits).
    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>);

    /// What VoiceOver calls the sheet ("Chat Settings").
    fn label(&self, cx: &App) -> SharedString;

    /// Edits not saved yet: Quit asks through [`Self::cancel`] first.
    fn unsaved(&self, cx: &App) -> bool {
        let _ = cx;
        false
    }

    /// The buttons along the sheet's bottom edge, which stay put while the
    /// body scrolls (as a Mac sheet's).
    fn footer(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let _ = (window, cx);
        None
    }
}

/// The window around a [`SheetBody`].
pub struct SheetHost<V: SheetBody> {
    pub body: Entity<V>,
    focus: FocusHandle,
    /// The height last asked of the window, so a request never repeats
    /// while AppKit resizes it.
    requested: Rc<Cell<Option<f32>>>,
    /// The footer's height as last laid out.
    footer_height: Rc<Cell<f32>>,
    /// The body is taller than the sheet: a hairline marks where it
    /// scrolls under the footer.
    overflowing: Rc<Cell<bool>>,
}

/// What runs once a sheet has been dismissed (see [`after_dismiss`]).
type AfterDismiss = Box<dyn FnOnce(&mut App)>;

/// Whether the sheet down now holds unsaved edits, and its body's
/// [`SheetBody::cancel`] (which asks before throwing them away).
#[derive(Clone)]
struct Unsaved {
    edits: Rc<dyn Fn(&App) -> bool>,
    ask: Rc<dyn Fn(&mut App)>,
}

/// The sheet on the main window now, if any, and what runs once it has
/// gone.
#[derive(Default)]
struct OpenSheet {
    current: Option<(AnyWindowHandle, AnyEntity)>,
    after: Option<AfterDismiss>,
    unsaved: Option<Unsaved>,
}

impl Global for OpenSheet {}

fn window_options(width: f32) -> WindowOptions {
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
            point(px(0.), px(0.)),
            size(px(width), px(FIRST_HEIGHT)),
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

/// Opens a sheet `width` points wide on `parent` (the main window) with the
/// body `build` makes. Another sheet already down keeps the keyboard and
/// this one does not open: None then.
pub fn open<V: SheetBody>(
    parent: &Window,
    width: f32,
    cx: &mut App,
    build: impl FnOnce(&mut Window, &mut Context<V>) -> V + 'static,
) -> Option<Entity<V>> {
    if refuse_another(cx) {
        return None;
    }
    let opened = conduit_components::window::open_window_clear_root(
        window_options(width),
        cx,
        move |window, cx| {
            let body = cx.new(|cx| build(window, cx));
            cx.new(|cx| SheetHost {
                body,
                focus: cx.focus_handle(),
                requested: Rc::new(Cell::new(None)),
                footer_height: Rc::new(Cell::new(0.)),
                overflowing: Rc::new(Cell::new(false)),
            })
        },
    );
    let (handle, host) = match opened {
        Ok(v) => v,
        Err(e) => {
            log::error!("could not open a sheet: {e}");
            return None;
        }
    };
    let body = host.read(cx).body.clone();
    adopt(handle, body.clone().into_any(), cx);
    let (weak, asked) = (body.downgrade(), body.downgrade());
    cx.default_global::<OpenSheet>().unsaved = Some(Unsaved {
        edits: Rc::new(move |cx: &App| weak.upgrade().is_some_and(|b| b.read(cx).unsaved(cx))),
        ask: Rc::new(move |cx: &mut App| {
            let Some(body) = asked.upgrade() else { return };
            let _ = handle.update(cx, |_, window, cx| {
                window.activate_window();
                body.update(cx, |b, cx| b.cancel(window, cx));
            });
        }),
    });
    begin(parent, handle, cx);
    Some(body)
}

/// A sheet is down already: it keeps the keyboard (brought forward), and
/// another may not open.
pub fn refuse_another(cx: &mut App) -> bool {
    let Some((handle, _)) = cx.default_global::<OpenSheet>().current.clone() else {
        return false;
    };
    cx.defer(move |cx| {
        let _ = handle.update(cx, |_, window, _| window.activate_window());
    });
    true
}

/// Records `handle` (whose view is `body`) as the sheet down now, for a
/// sheet opened outside [`open`].
pub fn adopt(handle: AnyWindowHandle, body: AnyEntity, cx: &mut App) {
    let open = cx.default_global::<OpenSheet>();
    open.current = Some((handle, body));
    open.after = None;
    open.unsaved = None;
}

/// Hangs the sheet window `handle` from `parent` with `beginSheet:`, once
/// `parent` has no other sheet sliding away.
pub fn begin(parent: &Window, handle: AnyWindowHandle, cx: &mut App) {
    #[cfg(target_os = "macos")]
    {
        let parent = crate::shell::macos::ns_window(parent);
        let sheet = handle
            .update(cx, |_, w, _| crate::shell::macos::ns_window(w))
            .ok()
            .flatten();
        if let (Some(parent), Some(sheet)) = (parent, sheet) {
            // After this update: AppKit calls back into GPUI as the sheet
            // takes the keyboard. A sheet that has only just been dismissed
            // ends a moment later ([`dismiss`] ends it from a task); one
            // begun before then is queued by AppKit and never drawn, so the
            // new one waits for the window to be free (a second at most).
            let executor = cx.background_executor().clone();
            cx.spawn(async move |cx| {
                for _ in 0..60 {
                    if parent.attachedSheet().is_none() {
                        break;
                    }
                    executor.timer(std::time::Duration::from_millis(16)).await;
                }
                // Dismissed while it waited: its window is going, and
                // nothing would end it once hung.
                if cx.update(|cx| current_window(cx)) != Some(handle) {
                    return;
                }
                crate::shell::macos::begin_sheet(&parent, &sheet)
            })
            .detach();
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (parent, handle, cx);
}

/// Forgets `handle` as the sheet down now, when it is: it is being ended
/// some other way ([`crate::views::settings::end_sheet_window`]), and what
/// was to run after it does not.
pub fn forget(handle: AnyWindowHandle, cx: &mut App) {
    let current = cx
        .try_global::<OpenSheet>()
        .and_then(|o| o.current.as_ref().map(|(h, _)| *h));
    if current == Some(handle) {
        let open = cx.global_mut::<OpenSheet>();
        open.current = None;
        open.after = None;
        open.unsaved = None;
    }
}

/// Runs `then` once the sheet down now has been dismissed (saved or
/// cancelled), not when the app quits: Share Chat comes back after Who Has
/// Access, as the phone's share flow returns to its sheet.
pub fn after_dismiss(cx: &mut App, then: impl FnOnce(&mut App) + 'static) {
    let open = cx.default_global::<OpenSheet>();
    if open.current.is_some() {
        open.after = Some(Box::new(then));
    }
}

/// The body of the sheet down now, when it is a `V`.
pub fn current<V: 'static>(cx: &App) -> Option<Entity<V>> {
    cx.try_global::<OpenSheet>()?
        .current
        .as_ref()?
        .1
        .clone()
        .downcast::<V>()
        .ok()
}

/// The window of the sheet down now.
pub fn current_window(cx: &App) -> Option<AnyWindowHandle> {
    cx.try_global::<OpenSheet>()?
        .current
        .as_ref()
        .map(|(h, _)| *h)
}

/// Whether the sheet down now holds edits not saved yet.
pub fn has_unsaved(cx: &App) -> bool {
    cx.try_global::<OpenSheet>()
        .and_then(|s| s.unsaved.clone())
        .is_some_and(|unsaved| (unsaved.edits)(cx))
}

/// Whether a sheet is down on the main window.
pub fn is_open(cx: &App) -> bool {
    cx.try_global::<OpenSheet>()
        .is_some_and(|s| s.current.is_some())
}

/// Quits the app, first ending a sheet that is down (AppKit keeps a
/// window-modal sheet's app from terminating while it hangs there).
pub fn quit(cx: &mut App) {
    if !is_open(cx) {
        cx.quit();
        return;
    }
    // Unsaved edits: the sheet comes forward and asks, as Esc does; Quit
    // again once it has gone.
    if has_unsaved(cx) {
        if let Some(unsaved) = cx.try_global::<OpenSheet>().and_then(|s| s.unsaved.clone()) {
            cx.defer(move |cx| (unsaved.ask)(cx));
        }
        return;
    }
    cx.default_global::<OpenSheet>().after = None;
    dismiss(cx);
    cx.spawn(async move |cx| {
        cx.background_executor()
            .timer(std::time::Duration::from_millis(250))
            .await;
        cx.update(|cx| cx.quit());
    })
    .detach();
}

/// Closes the sheet whose body `cx` is once another account is active (a
/// switch in Settings, which has its own window): what it shows and would
/// save belongs to the account it opened for, never to the next one. Edits
/// go with it, and nothing it was to reopen ([`after_dismiss`]) opens.
pub fn close_with_account<V: SheetBody>(
    stores: &crate::stores::Stores,
    cx: &mut Context<V>,
) -> Subscription {
    let opened = stores.accounts.read(cx).active().map(|a| a.id.clone());
    cx.observe(&stores.accounts, move |_, accounts, cx| {
        // A list being read again (a reconnect) names nobody: no change.
        let Some(now) = accounts.read(cx).active().map(|a| a.id.clone()) else {
            return;
        };
        if Some(&now) == opened.as_ref() {
            return;
        }
        if current::<V>(cx).is_some_and(|body| body == cx.entity()) {
            cx.default_global::<OpenSheet>().after = None;
            dismiss(cx);
        }
    })
}

/// Closes the sheet down now (it slides up), from its body or anywhere.
pub fn dismiss(cx: &mut App) {
    let open = cx.default_global::<OpenSheet>();
    let Some((handle, _)) = open.current.take() else {
        return;
    };
    open.unsaved = None;
    let after = open.after.take();
    // The main window takes the keyboard back as AppKit ends the sheet, its
    // focus where it was.
    crate::views::settings::end_sheet_window(handle, cx);
    if let Some(after) = after {
        cx.defer(after);
    }
}

impl<V: SheetBody> Focusable for SheetHost<V> {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

/// Whether a sheet sized for `requested` must change for a body `measured`
/// tall (half a point either way is the same height).
fn needs_fit(requested: Option<f32>, measured: f32) -> bool {
    requested.is_none_or(|r| (r - measured).abs() >= 0.5)
}

/// Fits the sheet's window to the body, `height` points tall, after this
/// frame (AppKit calls back into GPUI on a resize). The first fit comes as
/// the sheet drops in, so it doesn't animate on top of AppKit's slide.
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

impl<V: SheetBody> Render for SheetHost<V> {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let (page, _) = grouped_tones(&t);
        let requested = self.requested.clone();
        let footer_height = self.footer_height.clone();
        let label = self.body.read(cx).label(cx);
        let footer = self.body.update(cx, |b, cx| b.footer(window, cx));
        let has_footer = footer.is_some();
        // The body's natural height (padding included), and the footer's:
        // the window is fitted to both.
        let footer_for_fit = footer_height.clone();
        let overflowing = self.overflowing.clone();
        let over = overflowing.get();
        let probe = gpui_kit::canvas(
            |bounds: Bounds<Pixels>, _, _| f32::from(bounds.size.height),
            move |_, height, window, cx| {
                let total = height + footer_for_fit.get();
                let now = total > f32::from(window.viewport_size().height) + 0.5;
                if overflowing.replace(now) != now {
                    window.refresh();
                }
                let before = requested.get();
                if needs_fit(before, total) {
                    requested.set(Some(total));
                    fit(total, before.is_none(), window, cx);
                }
            },
        )
        .absolute()
        .top_0()
        .left_0()
        .size_full();
        let footer_probe = gpui_kit::canvas(
            |bounds: Bounds<Pixels>, _, _| f32::from(bounds.size.height),
            move |_, height, _, _| footer_height.set(height),
        )
        .absolute()
        .top_0()
        .left_0()
        .size_full();
        let body = self.body.clone();
        let cancel_body = self.body.clone();
        div()
            .id("sheet")
            .role(Role::Dialog)
            .aria_label(label)
            .key_context("ConduitSheet")
            .track_focus(&self.focus)
            .size_full()
            .flex()
            .flex_col()
            .font_family(UI_FONT)
            .bg(page)
            .text_color(t.roles.text)
            // Esc and ⌘. cancel, as in any sheet.
            .on_key_down(move |e: &gpui_kit::KeyDownEvent, window, cx| {
                let k = &e.keystroke;
                let m = &k.modifiers;
                let esc = k.key == "escape" && !(m.platform || m.alt || m.control || m.shift);
                let cmd_period = k.key == "." && m.platform && !(m.alt || m.control);
                if esc || cmd_period {
                    body.update(cx, |b, cx| b.cancel(window, cx));
                    cx.stop_propagation();
                }
            })
            // ⌘W in a sheet cancels it (the window under it stays).
            .on_action(move |_: &CloseWindow, window, cx| {
                cancel_body.update(cx, |b, cx| b.cancel(window, cx));
            })
            .child(
                div()
                    .id("sheet-body")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .child(
                        div()
                            .relative()
                            .w_full()
                            .p(px(PADDING))
                            .when(has_footer, |d| d.pb(px(PADDING / 2.)))
                            .child(self.body.clone())
                            .child(probe),
                    ),
            )
            .when_some(footer, |d, footer| {
                d.child(
                    div()
                        .relative()
                        .flex_none()
                        .w_full()
                        .when(over, |d| d.border_t_1().border_color(t.roles.divider))
                        .px(px(PADDING))
                        .pt(px(PADDING / 2.))
                        .pb(px(PADDING))
                        .child(footer)
                        .child(footer_probe),
                )
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sheet_opens_hidden_fixed_and_as_wide_as_asked() {
        let o = window_options(520.);
        assert!(!o.show && !o.focus);
        assert!(!o.is_resizable && !o.is_minimizable && !o.is_movable);
        match o.window_bounds {
            Some(WindowBounds::Windowed(b)) => assert_eq!(f32::from(b.size.width), 520.),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_sheet_refits_only_when_its_body_changes_height() {
        assert!(needs_fit(None, 310.));
        assert!(!needs_fit(Some(310.), 310.3));
        assert!(needs_fit(Some(310.), 512.));
    }
}

/// A main window with stores for sheet tests, an account signed in.
#[cfg(test)]
pub mod bench {
    use gpui_kit::{TestAppContext, VisualTestContext};

    use crate::stores::Stores;
    use crate::stores::accounts::tests::{account, list};
    use crate::stores::rpc::fake::FakeDaemon;

    struct Parent;

    impl gpui_kit::Render for Parent {
        fn render(
            &mut self,
            _: &mut gpui_kit::Window,
            _: &mut gpui_kit::Context<Self>,
        ) -> impl gpui_kit::IntoElement {
            gpui_kit::div()
        }
    }

    pub fn bench(cx: &mut TestAppContext) -> (FakeDaemon, Stores, &mut VisualTestContext) {
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-sheet-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            // Questions answer "no" (keep editing) unless a test says.
            cx.set_global(crate::shell::sheet::AutoAnswer(Some(false)));
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
        });
        let (_, vcx) = cx.add_window_view(|_, _| Parent);
        (daemon, stores, vcx)
    }

    /// Settings makes Blake's account the active one.
    pub fn switch_account(stores: &Stores, vcx: &mut VisualTestContext) {
        stores.accounts.update(vcx, |a, cx| {
            a.adopt(
                list(vec![
                    account("a", "Avery", false, true),
                    account("b", "Blake", true, true),
                ]),
                cx,
            )
        });
        vcx.run_until_parked();
    }
}
