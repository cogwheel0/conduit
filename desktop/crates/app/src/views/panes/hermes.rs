//! Hermes's Hidden Chats: the sessions hidden from every list, as the
//! phone's `hermes_hidden_sessions_page.dart` lists them. A session's row
//! opens its chat; Unhide lists it again. It is the only way back to a
//! hidden session.
//!
//! A Hermes session itself opens in the chat pane, as any chat does.

use std::rc::Rc;

use conduit_components::theme::ConduitTheme;
use conduit_components::views::focus::ControlExt as _;
use conduit_components::views::kit::{Button, raised_fill};
use gpui_kit::prelude::*;
use gpui_kit::{AnyElement, App, ElementId, FontWeight, Role, SharedString, div, px};

use crate::l10n::L10n;
use crate::stores::Stores;
use crate::stores::navigation::AreaItem;
use crate::views::hermes_sessions::{HermesCommand, run};
use crate::views::sidebar::hermes_title;

/// The Hidden Chats page.
pub fn hidden_pane(stores: &Stores, t: &ConduitTheme, l: &L10n, cx: &App) -> AnyElement {
    let r = t.roles;
    let note = |id: &'static str, text: String| {
        div()
            .id(id)
            .role(Role::Status)
            .aria_label(SharedString::from(text.clone()))
            .w_full()
            .py(px(24.))
            .text_center()
            .text_size(px(t.metrics.small))
            .text_color(r.text_subtle)
            .child(SharedString::from(text))
            .into_any_element()
    };
    let body: Vec<AnyElement> = match &stores.areas.read(cx).hermes_hidden {
        None => vec![note("hermes-hidden-loading", l.loading_short())],
        Some(Err(_)) => {
            let areas = stores.areas.downgrade();
            vec![
                note("hermes-hidden-failed", l.hermes_hidden_chats_load_error()),
                div()
                    .flex()
                    .justify_center()
                    .child(
                        Button::new("hermes-hidden-retry", l.desktop_try_again()).on_click(
                            Rc::new(move |_, _, cx| {
                                let _ = areas.update(cx, |a, cx| a.refresh_hermes_hidden(cx));
                            }),
                        ),
                    )
                    .into_any_element(),
            ]
        }
        Some(Ok(sessions)) if sessions.is_empty() => {
            vec![note("hermes-hidden-empty", l.hermes_hidden_chats_empty())]
        }
        Some(Ok(sessions)) => {
            let count = sessions.len();
            let rows: Vec<AnyElement> = sessions
                .iter()
                .enumerate()
                .map(|(ix, session)| {
                    let title = hermes_title(session, l);
                    let preview = session
                        .preview
                        .as_deref()
                        .map(str::trim)
                        .filter(|p| !p.is_empty() && *p != title)
                        .map(|p| p.lines().next().unwrap_or(p).to_string());
                    let open_stores = stores.clone();
                    let open_id = session.id.clone();
                    let unhide_stores = stores.clone();
                    let unhide_id = session.id.clone();
                    let spoken = match &preview {
                        Some(p) => format!("{title}, {p}"),
                        None => title.clone(),
                    };
                    div()
                        .id(ElementId::Name(
                            format!("hermes-hidden-{}", session.id).into(),
                        ))
                        .w_full()
                        .px(px(12.))
                        .py(px(8.))
                        .flex()
                        .items_center()
                        .gap(px(12.))
                        // A hairline between rows, as a grouped list's.
                        .when(ix + 1 < count, |d| d.border_b_1().border_color(r.border))
                        .child(
                            div()
                                .id(ElementId::Name(
                                    format!("hermes-hidden-open-{}", session.id).into(),
                                ))
                                .role(Role::Button)
                                .aria_label(SharedString::from(spoken))
                                .flex_1()
                                .min_w_0()
                                .flex()
                                .flex_col()
                                .gap(px(2.))
                                .rounded(px(6.))
                                .cursor_pointer()
                                .child(
                                    div()
                                        .truncate()
                                        .text_size(px(t.metrics.control))
                                        .font_weight(FontWeight::MEDIUM)
                                        .text_color(r.text)
                                        .child(SharedString::from(title)),
                                )
                                .children(preview.map(|p| {
                                    div()
                                        .truncate()
                                        .text_size(px(t.metrics.small))
                                        .text_color(r.text_subtle)
                                        .child(SharedString::from(p))
                                }))
                                .on_click(move |_, _, cx| {
                                    let item = AreaItem::HermesSession(open_id.clone());
                                    open_stores
                                        .navigation
                                        .update(cx, |n, cx| n.open_item(item, cx));
                                })
                                // A Tab stop with Full Keyboard Access, as
                                // the row's Unhide button is.
                                .keyboard_outline(6., cx),
                        )
                        .child(
                            Button::new(
                                ElementId::Name(format!("hermes-unhide-{}", session.id).into()),
                                l.hermes_session_unhide(),
                            )
                            .on_click(Rc::new(move |_, window, cx| {
                                run(
                                    &unhide_stores,
                                    &unhide_id,
                                    HermesCommand::Unhide,
                                    window,
                                    cx,
                                );
                            })),
                        )
                        .into_any_element()
                })
                .collect();
            // A grouped list with its own edge: the main pane is the plain
            // content colour, on which a settings group's fill alone does
            // not show in light.
            vec![
                div()
                    .id("hermes-hidden-list")
                    .role(Role::List)
                    .aria_label(SharedString::from(l.hermes_hidden_chats_title()))
                    .w_full()
                    .rounded(px(10.))
                    .border_1()
                    .border_color(r.border)
                    .bg(raised_fill(t))
                    .overflow_hidden()
                    .flex()
                    .flex_col()
                    .children(rows)
                    .into_any_element(),
                div()
                    .px(px(12.))
                    .text_size(px(t.metrics.small))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(l.desktop_hermes_hidden_chats_footer()))
                    .into_any_element(),
            ]
        }
    };
    div()
        .id("area-pane-body")
        .role(Role::Group)
        .aria_label(SharedString::from(l.hermes_hidden_chats_title()))
        .flex_1()
        .min_h_0()
        .overflow_y_scroll()
        .flex()
        .flex_col()
        .items_center()
        .px(px(32.))
        .pt(px(12.))
        .pb(px(32.))
        .child(
            div()
                .w_full()
                .max_w(px(560.))
                .flex()
                .flex_col()
                .gap(px(8.))
                .children(body),
        )
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use conduit_components::theme::ActiveConduitTheme as _;
    use conduit_components::views::focus::KeyboardAccess;
    use gpui_kit::prelude::*;
    use gpui_kit::{Context, TestAppContext, Window, div};

    use crate::stores::Stores;
    use crate::stores::navigation::{AreaItem, Selection};
    use crate::stores::rpc::fake::FakeDaemon;

    struct Pane {
        stores: Stores,
    }

    impl Render for Pane {
        fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            let t = cx.conduit().clone();
            let l = cx.global::<crate::l10n::L10n>().clone();
            div()
                .size_full()
                .child(super::hidden_pane(&self.stores, &t, &l, cx))
        }
    }

    /// With Full Keyboard Access on, Tab reaches a hidden chat's row before
    /// its Unhide button, and Return opens the chat.
    #[gpui_kit::test]
    fn tab_and_return_open_a_hidden_chat(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-hidden-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            cx.set_global(KeyboardAccess { all_controls: true });
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let session: conduit_protocol::HermesSessionDto = serde_json::from_value(
            serde_json::json!({"id": "s1", "chatId": "local:hermes_s1", "title": "Tide tables"}),
        )
        .expect("a session");
        stores.areas.update(cx, |a, cx| {
            a.hermes_hidden = Some(Ok(vec![session]));
            cx.notify();
        });
        let s = stores.clone();
        let (_, vcx) = cx.add_window_view(move |_, _| Pane { stores: s });
        vcx.update(|window, cx| window.draw(cx).clear(cx));
        vcx.update(|window, cx| window.focus_next(cx));
        vcx.update(|window, cx| window.draw(cx).clear(cx));
        vcx.simulate_keystrokes("enter");
        vcx.simulate_event(gpui_kit::KeyUpEvent {
            keystroke: gpui_kit::Keystroke::parse("enter").unwrap(),
        });
        vcx.run_until_parked();
        assert_eq!(
            stores
                .navigation
                .read_with(vcx, |n, _| n.selection().clone()),
            Selection::Area(AreaItem::HermesSession("s1".into())),
            "Return on the first Tab stop did not open the hidden chat"
        );
    }
}
