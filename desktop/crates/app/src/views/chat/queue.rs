//! The messages queued behind the running answer, docked above the
//! composer as the phone's queue sheet lists them (`queue.*`).
//!
//! Each row shows a message's text and its files, with Edit, Remove and
//! Stop & Send (send it now, stopping the answer); the rest go out together
//! as one message when the answer ends. A row being sent cannot be changed.
//! The card says when the queue waits for a file, or why a batch was not
//! sent, with Try Again.

use std::rc::Rc;

use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{ConduitTheme, with_alpha};
use conduit_components::views::kit::{Button, IconButton};
use conduit_protocol::{QueuePhase, QueueState};
use gpui_kit::Focusable as _;
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, ElementId, Entity, FontWeight, Role, SharedString, Window, div, px,
};

use crate::l10n::ActiveL10n as _;
use crate::views::chat_pane::ChatPane;

/// A queued message being edited in place: its id and the field.
pub struct QueueEditing {
    pub draft_id: String,
    pub input: Entity<InputState>,
}

/// The queue card, or nothing while nothing is queued.
pub fn queue_panel(
    queue: &QueueState,
    editing: Option<&QueueEditing>,
    pane: gpui_kit::WeakEntity<ChatPane>,
    t: &ConduitTheme,
    window: &mut Window,
    cx: &mut App,
) -> Option<AnyElement> {
    if queue.drafts.is_empty() {
        return None;
    }
    let l10n = cx.l10n().clone();
    let r = t.roles;
    let m = t.metrics;
    let total = queue.drafts.len();
    let status = if queue.admission_failed {
        Some((l10n.queued_drafts_send_failed(), true))
    } else if queue.phase == QueuePhase::Admitting {
        Some((l10n.queued_drafts_sending(), false))
    } else {
        None
    };
    let rows: Vec<AnyElement> = queue
        .drafts
        .iter()
        .enumerate()
        .map(|(i, draft)| {
            let id = draft.id.clone();
            let frozen = draft.frozen || queue.phase != QueuePhase::Idle;
            let edit_here = editing.filter(|e| e.draft_id == draft.id);
            let body: AnyElement = match edit_here {
                Some(e) => div()
                    .flex_1()
                    .min_w_0()
                    .child(
                        conduit_components::views::kit::field_frame(
                            e.input.read(cx).focus_handle(cx).is_focused(window),
                            m.control_height + 4.,
                            cx,
                        )
                        .child(
                            Input::new(&e.input)
                                .appearance(false)
                                .bordered(false)
                                .px_0()
                                .text_size(px(m.control))
                                .aria_label(SharedString::from(
                                    l10n.desktop_queued_message_field(),
                                )),
                        ),
                    )
                    .into_any_element(),
                None => div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .child(
                        div()
                            .line_clamp(2)
                            .text_size(px(m.control))
                            .text_color(r.text)
                            .child(SharedString::from(draft.text.clone())),
                    )
                    .when(!draft.files.is_empty() || !draft.context.is_empty(), |d| {
                        let names: Vec<String> = draft
                            .files
                            .iter()
                            .map(|f| f.name.clone())
                            .chain(draft.context.iter().map(|c| c.name.clone()))
                            .collect();
                        d.child(
                            div()
                                .flex()
                                .items_center()
                                .gap(px(4.))
                                .text_size(px(m.caption))
                                .text_color(r.text_subtle)
                                .child(icon(IconName::Paperclip, 11., r.text_subtle))
                                .child(
                                    div().truncate().child(SharedString::from(names.join(", "))),
                                ),
                        )
                    })
                    .into_any_element(),
            };
            let actions: Vec<AnyElement> = if edit_here.is_some() {
                let (save, cancel) = (pane.clone(), pane.clone());
                vec![
                    Button::new(
                        ElementId::NamedInteger("queue-cancel".into(), i as u64),
                        l10n.cancel(),
                    )
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = cancel.update(cx, |p, cx| p.cancel_queue_edit(window, cx));
                    }))
                    .into_any_element(),
                    Button::new(
                        ElementId::NamedInteger("queue-save".into(), i as u64),
                        l10n.save(),
                    )
                    .primary()
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = save.update(cx, |p, cx| p.save_queue_edit(window, cx));
                    }))
                    .into_any_element(),
                ]
            } else {
                let (edit, remove, now) = (pane.clone(), pane.clone(), pane.clone());
                let (edit_id, remove_id, now_id) = (id.clone(), id.clone(), id.clone());
                let text = draft.text.clone();
                vec![
                    IconButton::new(
                        ElementId::NamedInteger("queue-edit".into(), i as u64),
                        IconName::Pencil,
                        l10n.edit(),
                    )
                    .size(26., 13.)
                    .tooltip(l10n.edit())
                    .disabled(frozen)
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = edit.update(cx, |p, cx| p.edit_queued(&edit_id, &text, window, cx));
                    }))
                    .into_any_element(),
                    IconButton::new(
                        ElementId::NamedInteger("queue-remove".into(), i as u64),
                        IconName::Trash,
                        l10n.desktop_remove_from_queue(),
                    )
                    .size(26., 13.)
                    .tooltip(l10n.desktop_remove_from_queue())
                    .disabled(frozen)
                    .on_click(Rc::new(move |_, _, cx| {
                        let _ = remove.update(cx, |p, cx| p.remove_queued(&remove_id, cx));
                    }))
                    .into_any_element(),
                    Button::new(
                        ElementId::NamedInteger("queue-send-now".into(), i as u64),
                        l10n.queued_draft_send_now(),
                    )
                    .disabled(frozen)
                    .on_click(Rc::new(move |_, _, cx| {
                        let _ = now.update(cx, |p, cx| p.send_queued_now(&now_id, cx));
                    }))
                    .into_any_element(),
                ]
            };
            div()
                .id(ElementId::NamedInteger("queued-draft".into(), i as u64))
                .role(Role::ListItem)
                .aria_label(SharedString::from(draft.text.clone()))
                .aria_position_in_set(i + 1)
                .aria_size_of_set(total)
                .min_h(px(m.row_height + 10.))
                .py(px(4.))
                .flex()
                .items_center()
                .gap(px(8.))
                .when(frozen, |d| d.opacity(0.6))
                .child(icon(IconName::Clock, 13., r.text_subtle))
                .child(body)
                .children(actions)
                .into_any_element()
        })
        .collect();
    let retry = queue.admission_failed.then(|| {
        let pane = pane.clone();
        Button::new("queue-retry", l10n.desktop_try_again())
            .on_click(Rc::new(move |_, _, cx| {
                let _ = pane.update(cx, |p, cx| p.retry_queue(cx));
            }))
            .into_any_element()
    });
    Some(
        div()
            .id("queued-drafts")
            .role(Role::List)
            .aria_label(SharedString::from(l10n.queued_drafts_count(total as i64)))
            .w_full()
            .mb(px(8.))
            .px(px(12.))
            .py(px(8.))
            .flex()
            .flex_col()
            .rounded(t.card_radius())
            .border_1()
            .border_color(r.border)
            .bg(conduit_components::views::kit::on_raised_fill(t))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .pb(px(2.))
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(m.caption))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(r.text_subtle)
                            .child(SharedString::from(l10n.queued_drafts_count(total as i64))),
                    )
                    .when_some(status, |d, (text, danger)| {
                        d.child(
                            div()
                                .text_size(px(m.caption))
                                .text_color(if danger { r.danger } else { r.text_subtle })
                                .child(SharedString::from(text)),
                        )
                    })
                    .children(retry),
            )
            .child(div().h(px(1.)).bg(with_alpha(r.text, 0.06)))
            .children(rows)
            .into_any_element(),
    )
}
