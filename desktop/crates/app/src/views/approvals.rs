//! The card for the oldest waiting `ui.request`, with
//! `conduit-components`' approval card. The chat pane docks it above the
//! composer; the main and setup windows show it at the bottom of whatever
//! else they show.
//!
//! Every kind is answered here ([`card`]): confirmations and tool
//! approvals (Allow / Deny), prompts (text, password, select), MCP tool
//! approvals (once / session / always, "always" asked twice as on mobile),
//! and Hermes decisions with the agent's own choices. A kind this window
//! cannot answer says to answer it on another device and only dismisses.
//! ⌥⌘↩ and ⌥⌘⌫ answer the card on screen ([`ApprovalsView::allow`],
//! [`ApprovalsView::deny`]). Every button and shortcut answers the request
//! its card was drawn for, and only while that request still waits.
//!
//! The card docks over 200 ms, rising from the composer as its height opens
//! and it fades in. Once answered it leaves over 150 ms where it stands
//! (`motion::specs::CARD_*`): it fades in place, its bottom edge on the
//! composer, and the room it took closes once it has all but gone, so its
//! buttons are never cut. The last card drawn stays, taking nothing, while
//! it goes. Under Reduce Motion it only crossfades.

use std::rc::Rc;

use conduit_components::assets::IconName;
use conduit_components::motion::{self, Anchor, Reveal, specs};
use conduit_components::views::approval::{
    ALLOW_KEYS, ApprovalAction, ApprovalCard, ApprovalKind, DENY_KEYS, SelectOption,
};
use conduit_protocol::UiRequest;
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, ClickEvent, Context, Entity, SharedString, Subscription, Window, div, px,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::stores::ui_requests::{Answer, Card, InputKind, allow, card, deny};
use crate::views::chat::blocks::{is_tool_id, tool_display_name};
use crate::views::forms;

pub struct ApprovalsView {
    stores: Stores,
    /// The request the input below belongs to.
    for_request: Option<String>,
    input: Entity<InputState>,
    secret: Entity<InputState>,
    selected: usize,
    /// MCP "Always allow" asks once more.
    confirming_always: bool,
    /// The last request drawn, shown while its card leaves.
    last: Option<UiRequest>,
    _subscriptions: Vec<Subscription>,
}

impl ApprovalsView {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let input = forms::input("", false, window, cx);
        let secret = forms::input("", true, window, cx);
        let enter = |this: &mut Self,
                     _: &Entity<InputState>,
                     e: &InputEvent,
                     _: &mut Window,
                     cx: &mut Context<Self>| {
            if let InputEvent::PressEnter { .. } = e {
                this.allow(cx);
            }
        };
        let subscriptions = vec![
            cx.observe(&stores.ui_requests, |_, _, cx| cx.notify()),
            cx.subscribe_in(&input, window, enter),
            cx.subscribe_in(&secret, window, enter),
        ];
        Self {
            stores,
            for_request: None,
            input,
            secret,
            selected: 0,
            confirming_always: false,
            last: None,
            _subscriptions: subscriptions,
        }
    }

    pub fn has_request(&self, cx: &App) -> bool {
        self.stores.ui_requests.read(cx).top().is_some()
    }

    /// Resets the card's local state when the top request changes.
    fn sync(&mut self, top: &UiRequest, window: &mut Window, cx: &mut Context<Self>) {
        if self.for_request.as_deref() == Some(top.request_id.as_str()) {
            return;
        }
        self.for_request = Some(top.request_id.clone());
        // A select starts on the value the server offered, if it names one.
        self.selected = match card(top) {
            Card::Input {
                input: InputKind::Select(options),
                initial,
                ..
            } => options
                .iter()
                .position(|o| !initial.is_empty() && o.value == initial)
                .unwrap_or(0),
            _ => 0,
        };
        self.confirming_always = false;
        if let Card::Input {
            initial,
            placeholder,
            input,
            ..
        } = card(top)
        {
            let target = if input == InputKind::Password {
                &self.secret
            } else {
                &self.input
            };
            let value = if input == InputKind::Password {
                String::new()
            } else {
                initial
            };
            for state in [&self.input, &self.secret] {
                state.update(cx, |i, cx| i.set_value("", window, cx));
            }
            target.update(cx, |i, cx| {
                i.set_value(value, window, cx);
                i.set_placeholder(placeholder.unwrap_or_default(), window, cx);
                i.focus(window, cx);
            });
        }
    }

    fn top(&self, cx: &App) -> Option<UiRequest> {
        self.stores.ui_requests.read(cx).top().cloned()
    }

    /// `request_id` while it is still waiting.
    fn waiting(&self, request_id: &str, cx: &App) -> Option<UiRequest> {
        self.stores
            .ui_requests
            .read(cx)
            .queue
            .iter()
            .find(|r| r.request_id == request_id)
            .cloned()
    }

    fn typed(&self, top: &UiRequest, cx: &App) -> Option<String> {
        match card(top) {
            Card::Input {
                input: InputKind::Password,
                ..
            } => Some(forms::raw(&self.secret, cx)),
            Card::Input {
                input: InputKind::Select(options),
                ..
            } => options.get(self.selected).map(|o| o.value.clone()),
            Card::Input { .. } => Some(forms::raw(&self.input, cx)),
            _ => None,
        }
    }

    /// Answers `request_id`, the request a card was drawn for, and only
    /// while it waits: a request settled meanwhile (between a button's
    /// press and its release, say) is never answered for the next one.
    fn answer(&mut self, request_id: &str, answer: Answer, remember: bool, cx: &mut Context<Self>) {
        if self.waiting(request_id, cx).is_none() {
            return;
        }
        self.stores
            .ui_requests
            .update(cx, |u, cx| u.respond(request_id, answer, remember, cx));
        cx.notify();
    }

    /// ⌥⌘↩: the primary answer of the card on screen.
    pub fn allow(&mut self, cx: &mut Context<Self>) -> bool {
        match self.for_request.clone() {
            Some(id) => self.allow_request(&id, cx),
            None => false,
        }
    }

    /// ⌥⌘⌫: deny, cancel, or dismiss the card on screen.
    pub fn deny(&mut self, cx: &mut Context<Self>) -> bool {
        match self.for_request.clone() {
            Some(id) => self.deny_request(&id, cx),
            None => false,
        }
    }

    fn allow_request(&mut self, request_id: &str, cx: &mut Context<Self>) -> bool {
        let Some(request) = self.waiting(request_id, cx) else {
            return false;
        };
        // The fields hold the text of the card drawn last.
        let text = if self.for_request.as_deref() == Some(request_id) {
            self.typed(&request, cx)
        } else {
            None
        };
        match allow(&request, text) {
            Some(answer) => {
                self.answer(request_id, answer, false, cx);
                true
            }
            None => false,
        }
    }

    fn deny_request(&mut self, request_id: &str, cx: &mut Context<Self>) -> bool {
        let Some(request) = self.waiting(request_id, cx) else {
            return false;
        };
        self.answer(request_id, deny(&request), false, cx);
        true
    }

    /// A button that answers `choice` to `request_id`.
    fn button(
        &self,
        id: &str,
        label: String,
        request_id: &str,
        choice: &str,
        cx: &mut Context<Self>,
    ) -> ApprovalAction {
        let this = cx.entity().downgrade();
        let (request_id, choice) = (request_id.to_string(), choice.to_string());
        ApprovalAction::new(SharedString::from(id.to_string()), label).on_click(Rc::new(
            move |_: &ClickEvent, _: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| {
                    s.answer(&request_id, Answer::new(&choice), false, cx)
                });
            },
        ))
    }

    fn card_for(&mut self, top: &UiRequest, l10n: &L10n, cx: &mut Context<Self>) -> ApprovalCard {
        let (card, actions) = self.card_parts(top, l10n, cx);
        card.actions(actions)
    }

    /// The card for `top` and its buttons, each bound to `top`.
    fn card_parts(
        &mut self,
        top: &UiRequest,
        l10n: &L10n,
        cx: &mut Context<Self>,
    ) -> (ApprovalCard, Vec<ApprovalAction>) {
        let id = top.request_id.clone();
        let this = cx.entity().downgrade();
        let answering = self.stores.ui_requests.read(cx).answering.contains(&id);
        let allow_cb = {
            let (this, id) = (this.clone(), id.clone());
            Rc::new(move |_: &ClickEvent, _: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| s.allow_request(&id, cx));
            })
        };
        let deny_cb = {
            let (this, id) = (this.clone(), id.clone());
            Rc::new(move |_: &ClickEvent, _: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| s.deny_request(&id, cx));
            })
        };
        let primary = |label: String| {
            ApprovalAction::new(SharedString::from(format!("allow-{id}")), label)
                .primary()
                .shortcut(ALLOW_KEYS)
                .disabled(answering)
                .on_click(allow_cb.clone())
        };
        let secondary = |label: String| {
            ApprovalAction::new(SharedString::from(format!("deny-{id}")), label)
                .shortcut(DENY_KEYS)
                .disabled(answering)
                .on_click(deny_cb.clone())
        };
        let source = l10n.desktop_server_asks();
        match card(top) {
            Card::Confirm {
                title,
                message,
                confirm_label,
                cancel_label,
            } => (
                ApprovalCard::new(
                    id.clone(),
                    or(title, l10n.desktop_server_asks()),
                    message,
                    source,
                    ApprovalKind::Message,
                ),
                vec![
                    secondary(cancel_label.unwrap_or_else(|| l10n.desktop_deny())),
                    primary(confirm_label.unwrap_or_else(|| l10n.desktop_allow())),
                ],
            ),
            Card::Tool { title, message } => (
                ApprovalCard::new(
                    id.clone(),
                    tool_question(&title, l10n),
                    message,
                    source,
                    ApprovalKind::Message,
                ),
                vec![
                    secondary(l10n.desktop_deny()),
                    primary(l10n.desktop_allow()),
                ],
            ),
            Card::Input {
                title,
                message,
                input,
                confirm_label,
                cancel_label,
                ..
            } => {
                let label: SharedString = or(title.clone(), l10n.desktop_server_asks()).into();
                let kind = match input {
                    InputKind::Text => ApprovalKind::Input {
                        state: self.input.clone(),
                        label: label.clone(),
                    },
                    InputKind::Password => ApprovalKind::Input {
                        state: self.secret.clone(),
                        label: label.clone(),
                    },
                    InputKind::Select(options) => ApprovalKind::Select {
                        options: options
                            .iter()
                            .map(|o| SelectOption {
                                label: o.label.clone().into(),
                                detail: None,
                            })
                            .collect(),
                        selected: self.selected.min(options.len().saturating_sub(1)),
                    },
                };
                let pick = {
                    let (this, id) = (this.clone(), id.clone());
                    Rc::new(move |i: usize, _: &mut Window, cx: &mut App| {
                        let _ = this.update(cx, |s, cx| {
                            // Only while this request's card is the one shown.
                            if s.for_request.as_deref() == Some(id.as_str()) {
                                s.selected = i;
                                cx.notify();
                            }
                        });
                    })
                };
                (
                    ApprovalCard::new(id.clone(), label, message, source, kind).on_option(pick),
                    vec![
                        // Answering a server's question: Skip answers nothing,
                        // Send sends the choice (Deny and Allow stay the tool
                        // cards' words).
                        secondary(cancel_label.unwrap_or_else(|| l10n.desktop_skip())),
                        primary(confirm_label.unwrap_or_else(|| l10n.send())),
                    ],
                )
            }
            Card::Mcp {
                server,
                tool,
                arguments,
            } => {
                let detail = format!("{tool} \u{b7} {server}");
                let code: SharedString = if arguments.is_empty() || arguments == "{}" {
                    SharedString::default()
                } else {
                    arguments.into()
                };
                let actions = if self.confirming_always {
                    let back = {
                        let (this, id) = (this.clone(), id.clone());
                        Rc::new(move |_: &ClickEvent, _: &mut Window, cx: &mut App| {
                            let _ = this.update(cx, |s, cx| {
                                // Only while this request's card is the one shown.
                                if s.for_request.as_deref() == Some(id.as_str()) {
                                    s.confirming_always = false;
                                    cx.notify();
                                }
                            });
                        })
                    };
                    vec![
                        ApprovalAction::new(format!("always-back-{id}"), l10n.cancel())
                            .on_click(back),
                        self.button(
                            &format!("always-{id}"),
                            l10n.desktop_always_allow(),
                            &id,
                            "allowAlways",
                            cx,
                        )
                        .primary(),
                    ]
                } else {
                    let ask_always = {
                        let (this, id) = (this.clone(), id.clone());
                        Rc::new(move |_: &ClickEvent, _: &mut Window, cx: &mut App| {
                            let _ = this.update(cx, |s, cx| {
                                // Only while this request's card is the one shown.
                                if s.for_request.as_deref() == Some(id.as_str()) {
                                    s.confirming_always = true;
                                    cx.notify();
                                }
                            });
                        })
                    };
                    vec![
                        secondary(l10n.direct_mcp_approval_deny()),
                        ApprovalAction::new(
                            format!("ask-always-{id}"),
                            l10n.desktop_always_allow(),
                        )
                        .disabled(answering)
                        .on_click(ask_always),
                        self.button(
                            &format!("session-{id}"),
                            l10n.desktop_allow_for_session(),
                            &id,
                            "allowSession",
                            cx,
                        )
                        .disabled(answering),
                        primary(l10n.desktop_allow_once()),
                    ]
                };
                // "Allow Read File?"; the tool's id and its server under it.
                let card = ApprovalCard::new(
                    id.clone(),
                    tool_question(&tool, l10n),
                    detail,
                    source,
                    ApprovalKind::Code {
                        caption: l10n.desktop_tool_input().into(),
                        code,
                    },
                );
                let card = if self.confirming_always {
                    card.note(l10n.desktop_mcp_always_allow_note(&server, &top_tool(top)))
                } else {
                    card
                };
                (card, actions)
            }
            Card::Hermes { summary, choices } => {
                let label = |c: &str| match c {
                    "once" => l10n.desktop_allow_once(),
                    "session" => l10n.desktop_allow_for_session(),
                    "always" => l10n.desktop_always_allow(),
                    "deny" => l10n.hermes_approval_deny_action(),
                    other => other.to_string(),
                };
                // Deny first, the others, then "once" (primary) last.
                let mut ordered: Vec<&String> = choices.iter().filter(|c| *c == "deny").collect();
                ordered.extend(choices.iter().filter(|c| *c != "deny" && *c != "once"));
                let mut actions: Vec<ApprovalAction> = ordered
                    .into_iter()
                    .map(|c| {
                        if c == "deny" {
                            secondary(label(c))
                        } else {
                            // The agent's own choice, as it offered it.
                            self.button(&format!("{c}-{id}"), label(c), &id, c, cx)
                                .disabled(answering)
                        }
                    })
                    .collect();
                if choices.iter().any(|c| c == "once") {
                    actions.push(primary(label("once")));
                }
                (
                    ApprovalCard::new(
                        id.clone(),
                        l10n.desktop_approval_required(),
                        or(summary, l10n.hermes_approval_fallback()),
                        l10n.desktop_hermes_agent(),
                        ApprovalKind::Message,
                    )
                    .tile(IconName::Bot),
                    actions,
                )
            }
            Card::Unsupported => (
                ApprovalCard::new(
                    id.clone(),
                    l10n.desktop_approval_unsupported_title(),
                    l10n.desktop_approval_unsupported_body(),
                    source,
                    ApprovalKind::Message,
                )
                .tile(IconName::Smartphone),
                vec![
                    ApprovalAction::new(format!("dismiss-{id}"), l10n.desktop_release_dismiss())
                        .shortcut(DENY_KEYS)
                        .disabled(answering)
                        .on_click(deny_cb.clone()),
                ],
            ),
            Card::McpAppTool {
                server,
                tool,
                arguments,
            } => (
                ApprovalCard::new(
                    id.clone(),
                    tool_question(&tool, l10n),
                    l10n.mcp_app_tool_call_message(&server, &tool),
                    source,
                    ApprovalKind::Code {
                        caption: l10n.desktop_tool_input().into(),
                        code: if arguments.trim().is_empty() || arguments.trim() == "{}" {
                            SharedString::default()
                        } else {
                            arguments.into()
                        },
                    },
                )
                .tile(IconName::AppWindow),
                vec![
                    secondary(l10n.direct_mcp_approval_deny()),
                    primary(l10n.mcp_app_tool_call_allow()),
                ],
            ),
            Card::OpenLink { url } => (
                ApprovalCard::new(
                    id.clone(),
                    l10n.mcp_app_open_link_title(),
                    url,
                    source,
                    ApprovalKind::Message,
                )
                .tile(IconName::ExternalLink),
                vec![
                    secondary(l10n.cancel()),
                    primary(l10n.mcp_app_open_link_confirm()),
                ],
            ),
        }
    }
}

fn or(text: String, fallback: String) -> String {
    if text.trim().is_empty() {
        fallback
    } else {
        text
    }
}

/// A tool approval's title as a question: "Allow Get Current Timestamp?"
/// when the server titles it with the tool's id (Open WebUI does), the
/// server's own words when it wrote some, and "Tool Approval" for a tool
/// with no name (core's stand-in is "Tool").
pub(crate) fn tool_question(title: &str, l10n: &L10n) -> String {
    let title = title.trim();
    if title.is_empty() || title.eq_ignore_ascii_case("tool") {
        l10n.desktop_tool_approval()
    } else if is_tool_id(title) {
        l10n.desktop_tool_approval_question(&tool_display_name(title))
    } else {
        title.to_string()
    }
}

fn top_tool(top: &UiRequest) -> String {
    top.message_args
        .get("toolName")
        .cloned()
        .unwrap_or_default()
}

impl ApprovalsView {
    /// The card in its dock: `shown` opens its height and fades it; `gap`
    /// is the room under it, which opens and closes with it.
    pub(crate) fn docked(
        card: AnyElement,
        shown: motion::Appear,
        gap: f32,
        reduce: bool,
    ) -> AnyElement {
        let dock = dock_motion(shown, reduce);
        let slot = div()
            .w_full()
            .pb(px(gap))
            .relative()
            .top(px(dock.travel))
            .opacity(dock.opacity)
            .child(card);
        div()
            .id("approvals-dock")
            .w_full()
            // The card's shadow is drawn whole, not cut at the dock's edges.
            .child(
                Reveal::new("approvals-reveal", dock.height, slot.into_any_element())
                    .anchor(dock.anchor)
                    .bleed(24.),
            )
            .into_any_element()
    }

    /// Room under the docked card, above the composer.
    pub const DOCK_GAP: f32 = 8.;
}

/// How the docked card is drawn at one point of coming or going.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Dock {
    /// Share of its height the dock takes.
    height: f32,
    opacity: f32,
    /// Points it sits below its place.
    travel: f32,
    /// The edge kept in place as the dock opens or closes.
    anchor: Anchor,
}

/// Coming in, the card rises 12 pt from behind the composer as its height
/// opens (top edge first) and it fades in. Going, it stays where it stands:
/// it fades out over the first half, its bottom edge on the composer, and
/// the room closes over the second (so nothing visible is cut or moved).
/// Under Reduce Motion it only fades, and its room goes once it has.
fn dock_motion(shown: motion::Appear, reduce: bool) -> Dock {
    let p = shown.progress;
    if reduce {
        return Dock {
            height: 1.,
            opacity: shown.opacity,
            travel: 0.,
            anchor: Anchor::Top,
        };
    }
    if shown.leaving {
        return Dock {
            height: (p / 0.55).min(1.),
            opacity: ((p - 0.45) / 0.55).clamp(0., 1.),
            travel: 0.,
            anchor: Anchor::Bottom,
        };
    }
    Dock {
        height: p,
        opacity: shown.opacity,
        travel: shown.offset(12.),
        anchor: Anchor::Top,
    }
}

impl Render for ApprovalsView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let top = self.top(cx);
        let shown = motion::appear(
            "approval-card",
            top.is_some(),
            specs::CARD_IN,
            specs::CARD_OUT,
            window,
            cx,
        );
        let reduce = cx.reduce_motion();
        let Some(top) = top else {
            self.for_request = None;
            // Leaving: the last card, as it was, taking nothing.
            if shown.visible
                && let Some(last) = self.last.clone()
            {
                let l10n = cx.l10n().clone();
                let card = self.card_for(&last, &l10n, cx);
                // A shield over it: its buttons would answer the next card.
                let card = div()
                    .relative()
                    .w_full()
                    .child(card)
                    .child(div().id("approvals-leaving").absolute().inset_0().occlude())
                    .into_any_element();
                return Self::docked(card, shown, Self::DOCK_GAP, reduce);
            }
            self.last = None;
            return div().into_any_element();
        };
        self.last = Some(top.clone());
        self.sync(&top, window, cx);
        let l10n = cx.l10n().clone();
        let (count, answering, error) = {
            let u = self.stores.ui_requests.read(cx);
            (
                u.queue.len(),
                u.answering.contains(&top.request_id),
                u.error.clone(),
            )
        };
        let mut card = self.card_for(&top, &l10n, cx);
        if count > 1 {
            card = card.queue(1, count);
        }
        if answering {
            card = card.note(l10n.desktop_answering());
        } else if error.is_some() {
            card = card.note(l10n.desktop_approval_failed());
        }
        let card = div()
            .id("approvals")
            // A request waiting for an answer comes first in the Tab cycle
            // (from the composer, Tab goes on to its buttons), as a sheet's
            // buttons would. The container itself is not a stop.
            .tab_group()
            .tab_index(-1)
            .tab_stop(false)
            // …and a click on the card's text leaves focus in the composer.
            .on_mouse_down(gpui_kit::MouseButton::Left, |_, window, _| {
                window.prevent_default()
            })
            // The composer's width and edges (the dock is its column).
            .w_full()
            .child(card)
            .into_any_element();
        Self::docked(card, shown, Self::DOCK_GAP, reduce)
    }
}

#[cfg(test)]
mod dock_tests {
    use super::*;

    #[test]
    fn an_answered_card_fades_where_it_stands_then_its_room_closes() {
        let going = |p: f32| dock_motion(motion::appear_at(p, false, false), false);
        for i in 0..=20 {
            let d = going(i as f32 / 20.);
            assert_eq!((d.travel, d.anchor), (0., Anchor::Bottom), "{d:?}");
            // Visible at all: (almost) whole.
            if d.opacity > 0.15 {
                assert!(d.height > 0.95, "cut while visible: {d:?}");
            }
        }
        assert_eq!(going(1.).opacity, 1.);
        assert_eq!(going(0.45).opacity, 0.);
        assert_eq!(going(0.).height, 0.);
        // Coming in it still rises from the composer.
        let coming = dock_motion(motion::appear_at(0.5, true, false), false);
        assert_eq!(coming.anchor, Anchor::Top);
        assert!(coming.travel > 0.);
        // Reduce Motion: a fade, the room kept until it has gone.
        let reduced = dock_motion(motion::appear_at(0.5, false, true), true);
        assert_eq!((reduced.height, reduced.travel), (1., 0.));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_approvals_ask_a_question_in_words() {
        let l10n = L10n::new("en");
        assert_eq!(
            tool_question("get_current_timestamp", &l10n),
            "Allow Get Current Timestamp?"
        );
        assert_eq!(tool_question("search", &l10n), "Allow Search?");
        // The server's own words stay as written.
        assert_eq!(
            tool_question("Run the clock tool", &l10n),
            "Run the clock tool"
        );
        // No name (core says "Tool"): the generic title.
        assert_eq!(tool_question("Tool", &l10n), "Tool Approval");
        assert_eq!(tool_question(" ", &l10n), "Tool Approval");
        let de = L10n::new("de");
        assert!(tool_question("tide_table", &de).contains("Tide Table"));
    }
}

#[cfg(test)]
mod answer_tests {
    use std::collections::BTreeMap;

    use conduit_protocol::{AcceptedResult, UiRequestKind, methods};
    use gpui_kit::{TestAppContext, VisualTestContext};

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    fn request(id: &str, kind: UiRequestKind, detail: serde_json::Value) -> UiRequest {
        UiRequest {
            request_id: id.into(),
            kind,
            message_code: if kind == UiRequestKind::HermesDecision {
                "hermes.approval".into()
            } else {
                "server.confirm".into()
            },
            message_args: BTreeMap::new(),
            detail,
            timeout_ms: None,
            default_choice: "deny".into(),
            input_type: None,
            options: None,
        }
    }

    struct Bench {
        daemon: FakeDaemon,
        stores: Stores,
        view: Entity<ApprovalsView>,
    }

    fn bench(cx: &mut TestAppContext) -> (Bench, &mut VisualTestContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::UiRespond>(AcceptedResult { accepted: true });
        let scratch =
            std::env::temp_dir().join(format!("conduit-approvals-{}", std::process::id()));
        let stores = cx.update(|cx| {
            gpui_kit::init(cx);
            conduit_components::theme::install(
                conduit_components::theme::ConduitTheme::new(
                    "conduit",
                    false,
                    conduit_components::theme::DesignPrefs::default(),
                    gpui_kit::black(),
                ),
                cx,
            );
            cx.set_global(conduit_components::Strings::default());
            cx.set_global(crate::l10n::L10n::new("en"));
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let s = stores.clone();
        let (view, vcx) = cx.add_window_view(move |window, cx| ApprovalsView::new(s, window, cx));
        (
            Bench {
                daemon,
                stores,
                view,
            },
            vcx,
        )
    }

    #[gpui_kit::test]
    fn a_button_answers_only_the_request_it_was_drawn_for(cx: &mut TestAppContext) {
        let (b, vcx) = bench(cx);
        b.stores.ui_requests.update(vcx, |u, cx| {
            u.on_request(
                request("a", UiRequestKind::Confirm, serde_json::json!({})),
                cx,
            );
            u.on_request(
                request("b", UiRequestKind::Confirm, serde_json::json!({})),
                cx,
            );
        });
        // A's card, as drawn; A's Allow pressed.
        let actions = vcx.update(|_, cx| {
            b.view.update(cx, |v, cx| {
                let top = v.top(cx).unwrap();
                v.for_request = Some(top.request_id.clone());
                let l10n = cx.l10n().clone();
                v.card_parts(&top, &l10n, cx).1
            })
        });
        let allow_a = actions
            .iter()
            .find(|a| a.id.as_ref() == "allow-a")
            .and_then(|a| a.on_click.clone())
            .expect("A's Allow");
        // A settles before the release, and no frame is drawn between.
        b.stores
            .ui_requests
            .update(vcx, |u, cx| u.on_settled("a", cx));
        vcx.update(|window, cx| allow_a(&ClickEvent::default(), window, cx));
        // So does a shortcut pressed while A's card is still the one on
        // screen.
        vcx.update(|_, cx| {
            b.view.update(cx, |v, cx| {
                v.for_request = Some("a".into());
                assert!(!v.allow(cx));
                assert!(!v.deny(cx));
            })
        });
        vcx.run_until_parked();
        assert!(
            b.daemon.calls::<methods::UiRespond>().is_empty(),
            "B was answered for A"
        );
        b.stores.ui_requests.read_with(vcx, |u, _| {
            assert!(u.answering.is_empty());
            assert_eq!(u.top().map(|r| r.request_id.as_str()), Some("b"));
        });
    }

    #[gpui_kit::test]
    fn always_allow_asked_on_one_card_never_confirms_another(cx: &mut TestAppContext) {
        let (b, vcx) = bench(cx);
        b.stores.ui_requests.update(vcx, |u, cx| {
            for id in ["a", "b"] {
                u.on_request(
                    request(
                        id,
                        UiRequestKind::McpApproval,
                        serde_json::json!({"serverName": "lab", "toolName": "read"}),
                    ),
                    cx,
                );
            }
        });
        let parts = |id: &str, vcx: &mut VisualTestContext| {
            let id = id.to_string();
            vcx.update(|_, cx| {
                b.view.update(cx, |v, cx| {
                    let top = v.top(cx).unwrap();
                    assert_eq!(top.request_id, id);
                    v.for_request = Some(id.clone());
                    let l10n = cx.l10n().clone();
                    v.card_parts(&top, &l10n, cx).1
                })
            })
        };
        let ask_a = parts("a", vcx)
            .iter()
            .find(|a| a.id.as_ref() == "ask-always-a")
            .and_then(|a| a.on_click.clone())
            .expect("A's Always Allow");
        // A settles and B's card comes up before A's click lands.
        b.stores
            .ui_requests
            .update(vcx, |u, cx| u.on_settled("a", cx));
        parts("b", vcx);
        vcx.update(|window, cx| ask_a(&ClickEvent::default(), window, cx));
        let actions = parts("b", vcx);
        assert!(
            actions.iter().all(|a| a.id.as_ref() != "always-b"),
            "B skipped its own first step"
        );
    }

    #[gpui_kit::test]
    fn an_agents_own_choice_is_answered_as_offered(cx: &mut TestAppContext) {
        let (b, vcx) = bench(cx);
        b.stores.ui_requests.update(vcx, |u, cx| {
            u.on_request(
                request(
                    "h",
                    UiRequestKind::HermesDecision,
                    serde_json::json!({"choices": ["retry", "deny"]}),
                ),
                cx,
            );
        });
        let actions = vcx.update(|_, cx| {
            b.view.update(cx, |v, cx| {
                let top = v.top(cx).unwrap();
                v.for_request = Some(top.request_id.clone());
                let l10n = cx.l10n().clone();
                v.card_parts(&top, &l10n, cx).1
            })
        });
        let retry = actions
            .iter()
            .find(|a| a.id.as_ref() == "retry-h")
            .and_then(|a| a.on_click.clone())
            .expect("the agent's Retry");
        vcx.update(|window, cx| retry(&ClickEvent::default(), window, cx));
        vcx.run_until_parked();
        let calls = b.daemon.calls::<methods::UiRespond>();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0]["choice"], "retry");
    }
}
