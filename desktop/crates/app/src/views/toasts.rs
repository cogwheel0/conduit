//! Toasts: `notify.show` and the window's own notices, each with a dismiss
//! button. VoiceOver hears each as the store shows it
//! ([`crate::stores::toasts`]), not from here.
//!
//! On the main frame they dock in the chat column, 12 pt above the
//! composer and in the layout, so a toast never covers the transcript (the
//! latest message moves up to make room); elsewhere (sign-in, onboarding)
//! they float centred under the toolbar. A toast is as wide as its message
//! (at least [`TOAST_MIN_WIDTH`]) and wraps only past [`TOAST_WIDTH`]. An
//! error whose change can be sent again offers "Try Again", with
//! [`TOAST_ACTION_ROOM`] more for it.
//!
//! A toast fades in over 200 ms, travelling 8 pt into place (down from the
//! toolbar, up from the composer), and fades out over 150 ms where it was
//! (`motion::specs::TOAST_*`); its height opens and closes with it, so the
//! others slide rather than jump. Under Reduce Motion they only crossfade.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::motion::{self, Reveal, specs};
use conduit_components::theme::legible_text;
use conduit_components::views::kit::{Button, IconButton, overlay_shadow};
use conduit_protocol::NoticeLevel;
use gpui_kit::prelude::*;
use gpui_kit::{App, Div, ElementId, Entity, Role, Window, div, px, relative};

use crate::l10n::ActiveL10n as _;
use crate::stores::toasts::{Toast, ToastStore};

/// The widest a toast gets before its message wraps: room for a sentence
/// and a button on one line (a 360 pt toast wrapped most errors).
pub const TOAST_WIDTH: f32 = 480.;

/// The narrowest a toast gets, so short notices keep one shape.
pub const TOAST_MIN_WIDTH: f32 = 240.;

/// What Try Again takes beside the message: a toast with it may be this
/// much wider, so its message wraps no sooner than one without.
pub const TOAST_ACTION_ROOM: f32 = 100.;

/// How far a toast travels into place: down from the toolbar when it
/// floats, up from the composer when it docks.
const TRAVEL: f32 = 8.;

/// The toasts as last drawn, in order, with the ones on their way out.
#[derive(Default)]
struct Drawn {
    toasts: Vec<(Toast, bool)>,
}

impl Drawn {
    /// Takes in the store's toasts: new ones join at the end, gone ones
    /// stay in their place, leaving.
    fn sync(&mut self, live: &[Toast]) {
        for (toast, leaving) in &mut self.toasts {
            *leaving = !live.iter().any(|t| t.id == toast.id);
        }
        for toast in live {
            if !self.toasts.iter().any(|(t, _)| t.id == toast.id) {
                self.toasts.push((toast.clone(), false));
            }
        }
    }
}

/// Toasts floating centred under the toolbar, for screens without a
/// composer to dock them over.
pub fn toast_overlay(store: &Entity<ToastStore>, window: &mut Window, cx: &mut App) -> Option<Div> {
    let cards = toast_column(store, "toasts-floating", -TRAVEL, window, cx)?;
    Some(
        div()
            .absolute()
            .top(px(conduit_components::window::TOOLBAR_HEIGHT + 4.))
            .left_0()
            .right_0()
            .px(px(16.))
            .flex()
            .justify_center()
            .child(cards),
    )
}

/// Toasts in the layout, centred in the chat column above the composer.
pub fn toast_dock(store: &Entity<ToastStore>, window: &mut Window, cx: &mut App) -> Option<Div> {
    let cards = toast_column(store, "toasts-docked", TRAVEL, window, cx)?;
    Some(
        div()
            .w_full()
            .pb(px(4.))
            .flex()
            .justify_center()
            .child(cards),
    )
}

/// The toasts, each in a slot that opens and closes with it; `key` keeps
/// the floating and the docked stacks' state apart.
fn toast_column(
    store: &Entity<ToastStore>,
    key: &'static str,
    travel: f32,
    window: &mut Window,
    cx: &mut App,
) -> Option<Div> {
    let live = store.read(cx).toasts.clone();
    let drawn = window.use_keyed_state(key, cx, |_, _| Drawn::default());
    drawn.update(cx, |d, _| d.sync(&live));
    let mut toasts = vec![];
    for (toast, leaving) in drawn.read(cx).toasts.clone() {
        let shown = motion::appear(
            ElementId::NamedInteger("toast-motion".into(), toast.id),
            !leaving,
            specs::TOAST_IN,
            specs::TOAST_OUT,
            window,
            cx,
        );
        if shown.visible {
            toasts.push((toast, shown));
        }
    }
    // Forget the ones that have faded out.
    let kept: Vec<u64> = toasts.iter().map(|(t, _)| t.id).collect();
    drawn.update(cx, |d, _| d.toasts.retain(|(t, _)| kept.contains(&t.id)));
    if toasts.is_empty() {
        return None;
    }
    let reduce = cx.reduce_motion();
    let t = cx.conduit().clone();
    let r = t.roles;
    let dismiss_label = cx.l10n().desktop_release_dismiss();
    let try_again = cx.l10n().desktop_try_again();
    Some(
        div()
            .w_full()
            .max_w(px(TOAST_WIDTH + TOAST_ACTION_ROOM))
            .flex()
            .flex_col()
            .items_center()
            .children(toasts.into_iter().map(|(toast, shown)| {
                let (glyph, tone) = match toast.level {
                    NoticeLevel::Success => (IconName::CircleCheck, r.success),
                    NoticeLevel::Warning => (IconName::CircleAlert, r.warning),
                    NoticeLevel::Error => (IconName::CircleAlert, r.danger),
                    _ => (IconName::Info, r.text_subtle),
                };
                let bg = conduit_components::views::kit::raised_fill(&t);
                let tone = legible_text(tone, r.text, bg, 3.0);
                let id = toast.id;
                let store = store.clone();
                let card = div()
                    .id(ElementId::NamedInteger("toast".into(), id))
                    .role(if toast.level == NoticeLevel::Error {
                        Role::Alert
                    } else {
                        Role::Status
                    })
                    .aria_label(toast.message.clone())
                    // As wide as the message, wrapping only at the widest.
                    .min_w(px(TOAST_MIN_WIDTH))
                    .max_w(px(TOAST_WIDTH
                        + if toast.retry.is_some() {
                            TOAST_ACTION_ROOM
                        } else {
                            0.
                        }))
                    .px(px(12.))
                    .py(px(10.))
                    .flex()
                    .items_start()
                    .gap(px(9.))
                    .rounded(px(10.))
                    .bg(bg)
                    .border_1()
                    .border_color(r.border)
                    .shadow(overlay_shadow(&t))
                    .child(div().pt(px(1.)).child(icon(glyph, 15., tone)))
                    .child(
                        // Sized by its text (not a 0 basis), so the toast
                        // hugs a short message; min_w_0: a long one wraps
                        // inside the toast instead of running past its edge.
                        div()
                            .flex_grow(1.)
                            .flex_shrink_1()
                            .min_w_0()
                            .text_size(px(t.metrics.control))
                            .line_height(relative(1.4))
                            .text_color(r.text)
                            .child(toast.message.clone()),
                    )
                    .when_some(toast.retry.clone(), |d, retry| {
                        let store = store.clone();
                        d.child(
                            // Centred on the message's first line.
                            div().mt(px(-3.)).flex_none().child(
                                Button::new(
                                    ElementId::NamedInteger("toast-retry".into(), id),
                                    toast
                                        .action_label
                                        .clone()
                                        .unwrap_or_else(|| try_again.clone()),
                                )
                                .on_click(Rc::new(
                                    move |_, _, cx| {
                                        store.update(cx, |s, cx| s.dismiss(id, cx));
                                        (retry.0)(cx);
                                    },
                                )),
                            ),
                        )
                    })
                    .child(
                        IconButton::new(
                            ElementId::NamedInteger("toast-dismiss".into(), id),
                            IconName::X,
                            dismiss_label.clone(),
                        )
                        .size(20., 12.)
                        .on_click(Rc::new(move |_, _, cx| {
                            store.update(cx, |s, cx| s.dismiss(id, cx));
                        })),
                    );
                // The gap travels with the toast, so the stack closes up
                // evenly as one leaves.
                let slot = div()
                    .w_full()
                    .flex()
                    .justify_center()
                    .pb(px(8.))
                    .relative()
                    .top(px(shown.offset(travel)))
                    .opacity(shown.opacity)
                    .child(card);
                // The toast's shadow (12 pt down, 32 pt blur) is drawn whole,
                // not cut off at the slot's edges.
                Reveal::new(
                    ElementId::NamedInteger("toast-slot".into(), id),
                    if reduce { 1. } else { shown.progress },
                    slot.into_any_element(),
                )
                .bleed(48.)
            })),
    )
}
