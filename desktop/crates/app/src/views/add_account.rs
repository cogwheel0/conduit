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
//!
//! A switch at the top picks the kind, as the phone's Add Account page
//! lists each: Open WebUI (the server form), LibreChat, whose whole
//! sign-in happens in the sheet ([`LibreChatSignInView`]), Hermes Agent and
//! Model Provider. Those two are connections, not sign-ins: Continue ends
//! the sheet and opens the Hermes connection editor or the provider editor
//! on Settings, as the phone's rows open their own forms.

use std::cell::Cell;
use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::theme::UI_FONT;
use conduit_components::views::kit::{Button, Segment, Segmented, grouped_tones};
use gpui_kit::prelude::*;
use gpui_kit::{
    App, Bounds, Context, Entity, EventEmitter, FocusHandle, Focusable, Pixels, Role, SharedString,
    Subscription, Window, WindowBackgroundAppearance, WindowBounds, WindowKind, WindowOptions, div,
    point, px, size,
};

use crate::actions::CloseWindow;
use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::views::librechat_sign_in::{LibreChatSignInEvent, LibreChatSignInView};
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

/// Which kind of account the sheet adds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    OpenWebUi,
    LibreChat,
    Hermes,
    Direct,
}

impl Kind {
    pub const ALL: [Self; 4] = [Self::OpenWebUi, Self::LibreChat, Self::Hermes, Self::Direct];
}

pub struct AddAccountSheet {
    pub form: Entity<ServerForm>,
    pub librechat: Entity<LibreChatSignInView>,
    pub kind: Kind,
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
            let mut f = ServerForm::new(stores.clone(), window, cx);
            f.reset(true, window, cx);
            f.sheet = true;
            f
        });
        let librechat = cx.new(|cx| {
            let mut view = LibreChatSignInView::new(stores.clone(), window, cx);
            view.sheet = true;
            view
        });
        // The address takes the caret, as the sheet drops in.
        let url = form.read(cx).url.clone();
        let field = gpui_kit::Focusable::focus_handle(url.read(cx), cx);
        window.focus(&field, cx);
        let subscriptions = vec![
            // Cancel and Connected reach Settings, which ends the sheet.
            cx.subscribe(&form, |_, _, e: &ServerFormEvent, cx| cx.emit(e.clone())),
            // A LibreChat account is signed in within the sheet: done.
            cx.subscribe(&librechat, |_, _, e: &LibreChatSignInEvent, cx| {
                cx.emit(match e {
                    LibreChatSignInEvent::Back => ServerFormEvent::Back,
                    LibreChatSignInEvent::SignedIn => ServerFormEvent::Connected,
                })
            }),
        ];
        Self {
            form,
            librechat,
            kind: Kind::OpenWebUi,
            focus: cx.focus_handle(),
            requested: Rc::new(Cell::new(None)),
            _subscriptions: subscriptions,
        }
    }

    /// Cancel, as the form's Cancel button: unless a server is being
    /// checked.
    pub fn cancel(&mut self, cx: &mut Context<Self>) {
        if !self.busy(cx) {
            cx.emit(ServerFormEvent::Back);
        }
    }

    /// Either form has a server check or a sign-in out: one that can still
    /// put its account in charge is never hidden or cancelled under it.
    fn busy(&self, cx: &App) -> bool {
        self.form.read(cx).busy || self.librechat.read(cx).busy
    }

    /// Shows the form for `kind`, its first field focused (not while a form
    /// is busy).
    pub fn set_kind(&mut self, kind: Kind, window: &mut Window, cx: &mut Context<Self>) {
        if self.kind == kind || self.busy(cx) {
            return;
        }
        self.kind = kind;
        let field = match kind {
            Kind::OpenWebUi => Some(self.form.read(cx).url.clone()),
            Kind::LibreChat => {
                self.librechat.update(cx, |l, cx| {
                    if !l.busy {
                        l.reset(window, cx)
                    }
                });
                Some(self.librechat.read(cx).first_field())
            }
            // No field: the sheet keeps the keyboard, Return continues.
            Kind::Hermes | Kind::Direct => None,
        };
        match field {
            Some(field) => window.on_next_frame(move |window, cx| {
                let handle = gpui_kit::Focusable::focus_handle(field.read(cx), cx);
                window.focus(&handle, cx);
            }),
            None => window.focus(&self.focus, cx),
        }
        cx.notify();
    }

    /// Continue, for a connection kind: Settings opens its editor.
    pub fn continue_with(&mut self, cx: &mut Context<Self>) {
        match self.kind {
            Kind::Hermes => cx.emit(ServerFormEvent::AddHermes),
            Kind::Direct => cx.emit(ServerFormEvent::AddDirect),
            Kind::OpenWebUi | Kind::LibreChat => {}
        }
    }

    /// What a connection kind says, with Cancel and Continue.
    fn connection_pane(&self, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        let (title, body, glyph) = match self.kind {
            Kind::Hermes => (
                l10n.backend_chooser_hermes_title(),
                l10n.backend_chooser_hermes_subtitle(),
                IconName::Server,
            ),
            _ => (
                l10n.backend_chooser_direct_title(),
                l10n.backend_chooser_direct_subtitle(),
                IconName::Link,
            ),
        };
        let this = cx.entity().downgrade();
        let cancel = {
            let this = this.clone();
            Button::new("add-connection-cancel", l10n.cancel()).on_click(Rc::new(
                move |_, _, cx| {
                    let _ = this.update(cx, |s, cx| s.cancel(cx));
                },
            ))
        };
        let next = Button::new("add-connection-continue", l10n.continue_button())
            .primary()
            .on_click(Rc::new(move |_, _, cx| {
                let _ = this.update(cx, |s, cx| s.continue_with(cx));
            }));
        div()
            .id("add-connection")
            .role(Role::Group)
            .aria_label(SharedString::from(title.clone()))
            .flex()
            .flex_col()
            .gap(px(18.))
            .child(
                div()
                    .flex()
                    .items_start()
                    .gap(px(12.))
                    .child(conduit_components::assets::icon(
                        glyph,
                        22.,
                        t.roles.text_subtle,
                    ))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap(px(4.))
                            .child(conduit_components::views::kit::heading(
                                "add-connection-title",
                                title,
                                1,
                                t.metrics.control + 3.,
                                gpui_kit::FontWeight::SEMIBOLD,
                                t.roles.text,
                            ))
                            .child(
                                div()
                                    .text_size(px(t.metrics.control))
                                    .text_color(t.roles.text_subtle)
                                    .child(body),
                            ),
                    ),
            )
            .child(crate::views::forms::form_buttons(vec![
                cancel.into_any_element(),
                next.into_any_element(),
            ]))
            .into_any_element()
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
        let l10n = cx.l10n().clone();
        let (page, _) = grouped_tones(&t);
        let this = cx.entity().downgrade();
        let kinds = Segmented::new(
            "add-account-kind",
            l10n.desktop_add_account(),
            vec![
                Segment::new(l10n.backend_chooser_open_web_ui_title()),
                Segment::new(l10n.libre_chat_title()),
                Segment::new(l10n.backend_chooser_hermes_title()),
                Segment::new(l10n.backend_chooser_direct_title()),
            ],
            Kind::ALL.iter().position(|k| *k == self.kind).unwrap_or(0),
        )
        .on_select(Rc::new(move |i, window, cx| {
            let _ = this.update(cx, |s, cx| {
                s.set_kind(
                    Kind::ALL.get(i).copied().unwrap_or(Kind::OpenWebUi),
                    window,
                    cx,
                )
            });
        }));
        let form = match self.kind {
            Kind::OpenWebUi => self.form.clone().into_any_element(),
            Kind::LibreChat => self.librechat.clone().into_any_element(),
            Kind::Hermes | Kind::Direct => self.connection_pane(cx),
        };
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
                // Return continues to a connection's editor.
                let enter = k.key == "enter" && !(m.platform || m.alt || m.control || m.shift);
                if enter && matches!(this.kind, Kind::Hermes | Kind::Direct) {
                    this.continue_with(cx);
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
                    .flex()
                    .flex_col()
                    .gap(px(16.))
                    .child(div().flex().justify_center().child(kinds))
                    .child(form)
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

    /// A sign-in still out keeps its form: the other kind is not shown over
    /// it, and Cancel waits, so a sign-in that can still put its account in
    /// charge is never hidden behind an idle form.
    #[gpui_kit::test]
    fn a_sign_in_still_out_keeps_its_form(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        let sheet = vcx.update(|window, cx| cx.new(|cx| AddAccountSheet::new(stores, window, cx)));
        let backs = Rc::new(Cell::new(0));
        let b = backs.clone();
        let _watch = vcx.update(|_, cx| {
            cx.subscribe(&sheet, move |_, e: &ServerFormEvent, _| {
                if matches!(e, ServerFormEvent::Back) {
                    b.set(b.get() + 1);
                }
            })
        });
        sheet.update_in(vcx, |s, window, cx| s.set_kind(Kind::LibreChat, window, cx));
        sheet.update(vcx, |s, cx| s.librechat.update(cx, |l, _| l.busy = true));
        sheet.update_in(vcx, |s, window, cx| s.set_kind(Kind::OpenWebUi, window, cx));
        assert_eq!(
            sheet.read_with(vcx, |s, _| s.kind),
            Kind::LibreChat,
            "the LibreChat sign-in still out was hidden"
        );
        // Either form busy: Cancel waits, whichever kind is shown.
        sheet.update(vcx, |s, cx| {
            s.librechat.update(cx, |l, _| l.busy = false);
            s.form.update(cx, |f, _| f.busy = true);
        });
        sheet.update(vcx, |s, cx| s.cancel(cx));
        assert_eq!(backs.get(), 0, "Cancel left a sign-in still out");
    }

    #[test]
    fn the_sheet_refits_only_when_the_form_changes_height() {
        assert!(needs_fit(None, 310.));
        assert!(!needs_fit(Some(310.), 310.3));
        assert!(needs_fit(Some(310.), 512.));
        assert!(needs_fit(Some(512.), 310.));
    }
}
