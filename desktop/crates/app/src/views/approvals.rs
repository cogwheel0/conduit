//! The card for the oldest waiting `ui.request`, with
//! `conduit-components`' approval card. The chat pane docks it above the
//! composer; the main and setup windows show it at the bottom of whatever
//! else they show.
//!
//! Every kind is answered here ([`card`]): confirmations and tool
//! approvals (Allow / Deny), prompts (text, password, select), MCP tool
//! approvals (once / session / always, "always" asked twice as on mobile),
//! Hermes decisions with the agent's own choices (and a paid tool's cost
//! chips), and what a Hermes agent asks: a clarify form, a sudo password or
//! a secret (typed masked, cleared once sent), an MCP set-up. A kind this
//! window cannot answer says to answer it on another device and only
//! dismisses.
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

use std::collections::HashMap;
use std::rc::Rc;

use conduit_components::assets::IconName;
use conduit_components::motion::{self, Anchor, Reveal, specs};
use conduit_components::views::approval::{
    ALLOW_KEYS, ApprovalAction, ApprovalCard, ApprovalKind, DENY_KEYS, SelectOption,
};
use conduit_protocol::{UiRequest, UiRequestKind};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, ClickEvent, Context, Entity, SharedString, Subscription, Window, div, px,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::stores::ui_requests::{Answer, Card, InputKind, UiRequestsEvent, allow, card, deny};
use crate::views::chat::blocks::{is_tool_id, tool_display_name};
use crate::views::forms;
use crate::views::hermes_cards::{self, ClarifyDraft, FormQuestion};

pub struct ApprovalsView {
    stores: Stores,
    /// The request the input below belongs to.
    for_request: Option<String>,
    input: Entity<InputState>,
    secret: Entity<InputState>,
    selected: usize,
    /// MCP "Always allow" asks once more.
    confirming_always: bool,
    /// A Hermes form's answers so far, by question id, and each open
    /// question's own-words field.
    clarify: HashMap<String, ClarifyDraft>,
    clarify_inputs: HashMap<String, Entity<InputState>>,
    _clarify_subscriptions: Vec<Subscription>,
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
        let toasts = stores.toasts.clone();
        let subscriptions = vec![
            cx.observe(&stores.ui_requests, |_, _, cx| cx.notify()),
            cx.subscribe_in(&input, window, enter),
            cx.subscribe_in(&secret, window, enter),
            // Sent too late: Hermes had its answer from elsewhere, or gave up.
            cx.subscribe(&stores.ui_requests, move |_, _, e, cx| {
                if let UiRequestsEvent::HermesSettledElsewhere = e {
                    let text = cx.l10n().hermes_clarify_already_settled();
                    toasts.update(cx, |t, cx| {
                        t.show(conduit_protocol::NoticeLevel::Info, text, cx)
                    });
                }
            }),
        ];
        Self {
            stores,
            for_request: None,
            input,
            secret,
            selected: 0,
            confirming_always: false,
            clarify: HashMap::new(),
            clarify_inputs: HashMap::new(),
            _clarify_subscriptions: vec![],
            last: None,
            _subscriptions: subscriptions,
        }
    }

    pub fn has_request(&self, cx: &App) -> bool {
        self.stores.ui_requests.read(cx).top().is_some()
    }

    /// The request the card on screen was last drawn for (its fields
    /// belong to it): a field filled before the card first draws a new
    /// request is reset by that draw.
    pub fn drawn_for(&self) -> Option<&str> {
        self.for_request.as_deref()
    }

    /// Resets the card's local state when the top request changes: another
    /// request id. The same request raised again (Hermes replays what a
    /// resumed chat still waits on; a prompt can be refreshed) keeps what
    /// the user typed and chose, and the caret where it is: only a question
    /// it did not ask before gets a field, and one it no longer asks loses
    /// its own.
    fn sync(&mut self, top: &UiRequest, window: &mut Window, cx: &mut Context<Self>) {
        if self.for_request.as_deref() == Some(top.request_id.as_str()) {
            if let Card::HermesClarify { questions, .. } = card(top) {
                let open: Vec<_> = questions.iter().filter(|q| !q.locked).collect();
                self.clarify_inputs
                    .retain(|id, _| open.iter().any(|q| &q.id == id));
                for q in open {
                    if !self.clarify_inputs.contains_key(&q.id) {
                        self.add_clarify_input(q, window, cx);
                    }
                }
            }
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
        self.clarify.clear();
        self.clarify_inputs.clear();
        self._clarify_subscriptions.clear();
        match card(top) {
            Card::HermesClarify { questions, .. } => {
                for q in questions.iter().filter(|q| !q.locked) {
                    self.add_clarify_input(q, window, cx);
                }
            }
            Card::HermesSecret { .. } => {
                let hint = cx.l10n().hermes_sensitive_response();
                self.input.update(cx, |i, cx| i.set_value("", window, cx));
                self.secret.update(cx, |i, cx| {
                    i.set_value("", window, cx);
                    i.set_placeholder(hint, window, cx);
                    i.focus(window, cx);
                });
            }
            _ => {}
        }
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

    /// The own-words field of form question `q`.
    fn add_clarify_input(
        &mut self,
        q: &crate::stores::ui_requests::ClarifyQuestion,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let placeholder = if q.choices.is_empty() {
            cx.l10n().hermes_response()
        } else {
            cx.l10n().hermes_clarify_other_answer()
        };
        let state = forms::input(placeholder.clone(), false, window, cx);
        state.update(cx, |i, cx| i.set_placeholder(placeholder, window, cx));
        let question = q.clone();
        self._clarify_subscriptions.push(cx.subscribe_in(
            &state,
            window,
            move |this: &mut Self, state, e: &InputEvent, _, cx| match e {
                InputEvent::Change => {
                    let typed = forms::raw(state, cx);
                    this.clarify
                        .entry(question.id.clone())
                        .or_default()
                        .typed(&question, &typed);
                    cx.notify();
                }
                InputEvent::PressEnter { .. } => {
                    this.allow(cx);
                }
                _ => {}
            },
        ));
        self.clarify_inputs.insert(q.id.clone(), state);
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
            // What the card shows ([`Self::card_parts`] keeps the pick in
            // range when the same request comes back with fewer choices).
            Card::Input {
                input: InputKind::Select(options),
                ..
            } => options
                .get(self.selected.min(options.len().saturating_sub(1)))
                .map(|o| o.value.clone()),
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

    /// A form question's own-words field (for a test to type in).
    #[cfg(feature = "harness")]
    pub(crate) fn clarify_input(&self, question: &str) -> Option<Entity<InputState>> {
        self.clarify_inputs.get(question).cloned()
    }

    /// The masked field a password or secret is typed in.
    #[cfg(feature = "harness")]
    pub(crate) fn secret_input(&self) -> Entity<InputState> {
        self.secret.clone()
    }

    /// A Hermes question's answer to `request_id`, through
    /// `hermes.decisions.answer`, and only while it waits.
    fn answer_hermes(
        &mut self,
        request_id: &str,
        answers: Vec<conduit_protocol::HermesClarifyAnswer>,
        value: Option<String>,
        cx: &mut Context<Self>,
    ) {
        if self.waiting(request_id, cx).is_none() {
            return;
        }
        self.stores
            .ui_requests
            .update(cx, |u, cx| u.answer_hermes(request_id, answers, value, cx));
        cx.notify();
    }

    /// The request the card on screen was drawn for, while it waits.
    fn drawn(&self, cx: &App) -> Option<UiRequest> {
        self.waiting(self.for_request.as_deref()?, cx)
    }

    /// A form question's answer so far and its own words.
    fn draft_of(
        &self,
        q: &crate::stores::ui_requests::ClarifyQuestion,
        cx: &App,
    ) -> (ClarifyDraft, String) {
        (
            self.clarify.get(&q.id).cloned().unwrap_or_default(),
            hermes_cards::typed(self.clarify_inputs.get(&q.id), cx),
        )
    }

    /// Picks a form choice: question index, choice value.
    pub(crate) fn pick(
        &mut self,
        question: usize,
        value: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(top) = self.drawn(cx) else { return };
        let Card::HermesClarify { questions, .. } = card(&top) else {
            return;
        };
        let Some(q) = questions.get(question) else {
            return;
        };
        let clear = self
            .clarify
            .entry(q.id.clone())
            .or_default()
            .pick(q, &value);
        if clear && let Some(input) = self.clarify_inputs.get(&q.id) {
            input.update(cx, |i, cx| i.set_value("", window, cx));
        }
        cx.notify();
    }

    pub(crate) fn skip(&mut self, question: usize, cx: &mut Context<Self>) {
        let Some(top) = self.drawn(cx) else { return };
        let Card::HermesClarify { questions, .. } = card(&top) else {
            return;
        };
        if let Some(q) = questions.get(question) {
            let draft = self.clarify.entry(q.id.clone()).or_default();
            draft.skipped = !draft.skipped;
            cx.notify();
        }
    }

    /// ⌥⌘↩ on a Hermes question: Send Response (once every question is
    /// answered or skipped), the typed password or secret, or Set Up. The
    /// answers and fields are the card's drawn last: for another request
    /// there is nothing to send.
    fn allow_hermes(&mut self, top: &UiRequest, cx: &mut Context<Self>) -> bool {
        let id = top.request_id.clone();
        if self.for_request.as_deref() != Some(id.as_str()) {
            return false;
        }
        match card(top) {
            Card::HermesClarify { questions, .. } => {
                let (_, _, ready) = hermes_cards::progress(&questions, |q| self.draft_of(q, cx));
                if !ready {
                    return false;
                }
                let answers = hermes_cards::answers(&questions, |q| self.draft_of(q, cx));
                self.answer_hermes(&id, answers, None, cx);
                true
            }
            Card::HermesSecret { .. } => {
                let value = forms::raw(&self.secret, cx);
                if value.is_empty() {
                    return false;
                }
                self.answer_hermes(&id, vec![], Some(value), cx);
                true
            }
            Card::HermesSetup { .. } => {
                self.answer_hermes(&id, vec![], Some("approve".into()), cx);
                true
            }
            _ => false,
        }
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
        if crate::stores::ui_requests::is_hermes_question(&request) {
            return self.allow_hermes(&request, cx);
        }
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

    /// Deny, cancel, or dismiss. On a Hermes password or secret it skips
    /// (Hermes goes on without one), on a set-up it says Not Now; a form has
    /// no such answer (each question has its own Skip).
    fn deny_request(&mut self, request_id: &str, cx: &mut Context<Self>) -> bool {
        let Some(request) = self.waiting(request_id, cx) else {
            return false;
        };
        match card(&request) {
            Card::HermesSecret { .. } => {
                self.answer_hermes(request_id, vec![], Some(String::new()), cx);
                return true;
            }
            Card::HermesSetup { .. } => {
                self.answer_hermes(request_id, vec![], Some("decline".into()), cx);
                return true;
            }
            Card::HermesClarify { .. } => return false,
            _ => {}
        }
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

    fn card_for(
        &mut self,
        top: &UiRequest,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> ApprovalCard {
        let (card, actions) = self.card_parts(top, l10n, window, cx);
        card.actions(actions)
    }

    /// The card for `top` and its buttons, each bound to `top`.
    fn card_parts(
        &mut self,
        top: &UiRequest,
        l10n: &L10n,
        window: &mut Window,
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
                    if top.message_code == "librechat.toolApproval" {
                        l10n.libre_chat_approval_run(&librechat_tool_name(&title))
                    } else {
                        tool_question(&title, l10n)
                    },
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
                        // A LibreChat question's Cancel stops the reply, as on
                        // the phone.
                        secondary(cancel_label.unwrap_or_else(|| {
                            if top.kind == UiRequestKind::LibreChatQuestion {
                                l10n.cancel()
                            } else {
                                l10n.desktop_skip()
                            }
                        })),
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
            Card::Hermes {
                summary,
                choices,
                cost,
            } => {
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
                let card = ApprovalCard::new(
                    id.clone(),
                    l10n.desktop_approval_required(),
                    or(summary, l10n.hermes_approval_fallback()),
                    l10n.desktop_hermes_agent(),
                    ApprovalKind::Message,
                )
                .tile(IconName::Bot);
                // A paid tool: what it costs, and what the chat has spent.
                let card = match cost {
                    Some(cost) => card.body(hermes_cards::cost_chips(&cost, l10n, cx)),
                    None => card,
                };
                (card, actions)
            }
            Card::HermesClarify { questions, .. } => {
                let (settled, total, ready) =
                    hermes_cards::progress(&questions, |q| self.draft_of(q, cx));
                let drawn: Vec<FormQuestion<'_>> = questions
                    .iter()
                    .map(|q| FormQuestion {
                        question: q,
                        draft: self.clarify.get(&q.id).cloned().unwrap_or_default(),
                        input: self.clarify_inputs.get(&q.id).cloned(),
                    })
                    .collect();
                let on_pick: hermes_cards::OnPick = {
                    let this = this.clone();
                    Rc::new(move |q, value, window, cx| {
                        let _ = this.update(cx, |s, cx| s.pick(q, value, window, cx));
                    })
                };
                let on_skip: hermes_cards::OnSkip = {
                    let this = this.clone();
                    Rc::new(move |q, _, cx| {
                        let _ = this.update(cx, |s, cx| s.skip(q, cx));
                    })
                };
                let form = hermes_cards::clarify_form(
                    &id, drawn, !answering, on_pick, on_skip, l10n, window, cx,
                );
                // Hermes' prompt repeats the first question: the line under
                // the title is the progress, as on the phone.
                let detail = l10n.hermes_clarify_progress(settled as i64, total as i64);
                let card = ApprovalCard::new(
                    id.clone(),
                    l10n.hermes_clarification_title(),
                    detail,
                    l10n.desktop_hermes_agent(),
                    ApprovalKind::Message,
                )
                .tile(IconName::MessageSquare)
                .body(form);
                let card = if ready || answering {
                    card
                } else {
                    card.note(l10n.hermes_clarify_answer_or_skip())
                };
                (
                    card,
                    vec![
                        ApprovalAction::new(format!("allow-{id}"), l10n.hermes_send_response())
                            .primary()
                            .shortcut(ALLOW_KEYS)
                            .disabled(answering || !ready)
                            .on_click(allow_cb.clone()),
                    ],
                )
            }
            Card::HermesSecret { prompt, sudo } => {
                let typed = !forms::raw(&self.secret, cx).is_empty();
                let label: SharedString = l10n.hermes_sensitive_response().into();
                (
                    ApprovalCard::new(
                        id.clone(),
                        if sudo {
                            l10n.hermes_sudo_title()
                        } else {
                            l10n.hermes_secret_title()
                        },
                        prompt,
                        l10n.desktop_hermes_agent(),
                        ApprovalKind::Input {
                            state: self.secret.clone(),
                            label,
                        },
                    )
                    .tile(if sudo {
                        IconName::Lock
                    } else {
                        IconName::KeyRound
                    }),
                    vec![
                        secondary(l10n.hermes_clarify_skip()),
                        ApprovalAction::new(format!("allow-{id}"), l10n.hermes_send_response())
                            .primary()
                            .shortcut(ALLOW_KEYS)
                            .disabled(answering || !typed)
                            .on_click(allow_cb.clone()),
                    ],
                )
            }
            Card::HermesSetup { server, action } => {
                let detail = [action, server]
                    .into_iter()
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join(" ");
                (
                    ApprovalCard::new(
                        id.clone(),
                        l10n.hermes_mcp_setup_title(),
                        detail,
                        l10n.desktop_hermes_agent(),
                        ApprovalKind::Message,
                    )
                    .tile(IconName::Server),
                    vec![
                        secondary(l10n.hermes_not_now()),
                        primary(l10n.hermes_set_up()),
                    ],
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
            // The phone's question, in its words: Hermes' reason when it
            // gave one. Keep sends nothing and gives the words back.
            Card::HermesModelSwitch { model, reason } => (
                ApprovalCard::new(
                    id.clone(),
                    l10n.hermes_model_switch_confirm_title(&model),
                    reason.unwrap_or_else(|| l10n.hermes_model_switch_confirm_message()),
                    l10n.desktop_hermes_agent(),
                    ApprovalKind::Message,
                )
                .tile(IconName::Cpu),
                vec![
                    secondary(l10n.hermes_model_switch_keep_current()),
                    primary(l10n.hermes_model_switch_confirm_action()),
                ],
            ),
        }
    }
}

/// A LibreChat tool's name as people read it: an MCP tool's own name
/// without its server (`lookup_tide_mcp_harbour_docs` → "lookup_tide").
pub(crate) fn librechat_tool_name(name: &str) -> String {
    match name.split_once("_mcp_") {
        Some((tool, _)) if !tool.is_empty() => tool.to_string(),
        _ => name.to_string(),
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
        // A password or secret is kept in the field only while its card waits
        // for it: once sent (or the card has gone) the field is emptied.
        let typing_secret = top.as_ref().is_some_and(|r| {
            !self
                .stores
                .ui_requests
                .read(cx)
                .answering
                .contains(&r.request_id)
                && matches!(
                    card(r),
                    Card::HermesSecret { .. }
                        | Card::Input {
                            input: InputKind::Password,
                            ..
                        }
                )
        });
        if !typing_secret && !forms::raw(&self.secret, cx).is_empty() {
            self.secret.update(cx, |i, cx| i.set_value("", window, cx));
        }
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
                let card = self.card_for(&last, &l10n, window, cx);
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
        let (count, answering, error, hermes_failed) = {
            let u = self.stores.ui_requests.read(cx);
            (
                u.queue.len(),
                u.answering.contains(&top.request_id),
                u.error.clone(),
                u.hermes_failed.contains(&top.request_id),
            )
        };
        let card_kind = card(&top);
        let mut card = self.card_for(&top, &l10n, window, cx);
        if count > 1 {
            card = card.queue(1, count);
        }
        if answering {
            card = card.note(l10n.desktop_answering());
        } else if hermes_failed {
            card = card.note(match card_kind {
                Card::HermesClarify { .. } => l10n.hermes_clarify_send_failed(),
                _ => l10n.desktop_approval_failed(),
            });
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
        let actions = vcx.update(|window, cx| {
            b.view.update(cx, |v, cx| {
                let top = v.top(cx).unwrap();
                v.for_request = Some(top.request_id.clone());
                let l10n = cx.l10n().clone();
                v.card_parts(&top, &l10n, window, cx).1
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
            vcx.update(|window, cx| {
                b.view.update(cx, |v, cx| {
                    let top = v.top(cx).unwrap();
                    assert_eq!(top.request_id, id);
                    v.for_request = Some(id.clone());
                    let l10n = cx.l10n().clone();
                    v.card_parts(&top, &l10n, window, cx).1
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
        let actions = vcx.update(|window, cx| {
            b.view.update(cx, |v, cx| {
                let top = v.top(cx).unwrap();
                v.for_request = Some(top.request_id.clone());
                let l10n = cx.l10n().clone();
                v.card_parts(&top, &l10n, window, cx).1
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

#[cfg(test)]
mod replay_tests {
    use std::collections::BTreeMap;

    use conduit_components::theme::{ConduitTheme, DesignPrefs, install};
    use conduit_protocol::{UiInputOption, UiInputType};
    use gpui_kit::{TestAppContext, VisualTestContext};
    use serde_json::json;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    fn hermes(id: &str, kind: UiRequestKind, prompt: &str, detail: serde_json::Value) -> UiRequest {
        UiRequest {
            request_id: id.into(),
            kind,
            message_code: "hermes.secret".into(),
            message_args: BTreeMap::from([("prompt".to_string(), prompt.to_string())]),
            detail,
            timeout_ms: Some(300_000),
            default_choice: "deny".into(),
            input_type: None,
            options: None,
        }
    }

    fn form(id: &str, questions: &[(&str, &str)]) -> UiRequest {
        let rows: Vec<_> = questions
            .iter()
            .map(|(qid, text)| json!({"id": qid, "text": text, "choices": []}))
            .collect();
        hermes(
            id,
            UiRequestKind::HermesClarify,
            "",
            json!({"chatId": "local:hermes_s", "questions": rows}),
        )
    }

    fn draw(vcx: &mut VisualTestContext) {
        vcx.update(|window, cx| window.draw(cx).clear(cx));
        vcx.run_until_parked();
    }

    fn value(state: &Entity<InputState>, vcx: &mut VisualTestContext) -> String {
        vcx.update(|_, cx| forms::raw(state, cx))
    }

    /// A Hermes secret, password or form field the user is typing into
    /// keeps what it holds when the same request is raised again (Hermes
    /// replays what a resumed chat waits on); what the request says is
    /// refreshed. Only another request empties it.
    #[gpui_kit::test]
    fn a_request_raised_again_keeps_what_its_field_holds(cx: &mut TestAppContext) {
        let scratch =
            std::env::temp_dir().join(format!("conduit-approvals-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&scratch);
        let rpc = FakeDaemon::new().rpc();
        cx.update(|cx| {
            gpui_kit::init(cx);
            install(
                ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
                cx,
            );
            cx.set_global(conduit_components::Strings::default());
            cx.set_global(L10n::new("en"));
        });
        let stores = cx.update(|cx| crate::fixture::stores(rpc, &scratch, cx));
        let requests = stores.ui_requests.clone();
        let (view, vcx) =
            cx.add_window_view(move |window, cx| ApprovalsView::new(stores, window, cx));
        draw(vcx);

        for kind in [UiRequestKind::HermesSecret, UiRequestKind::HermesSudo] {
            let id = format!("{kind:?}");
            requests.update(vcx, |r, cx| {
                r.on_request(
                    hermes(&id, kind, "Enter your Demo Weather API key", json!({})),
                    cx,
                )
            });
            draw(vcx);
            let secret = view.read_with(vcx, |v, _| v.secret_input());
            vcx.update(|window, cx| {
                secret.update(cx, |i, cx| i.set_value("synthetic-hal", window, cx))
            });
            draw(vcx);
            // Raised again, its prompt refreshed.
            requests.update(vcx, |r, cx| {
                r.on_request(
                    hermes(
                        &id,
                        kind,
                        "Enter your Demo Weather API key again",
                        json!({}),
                    ),
                    cx,
                )
            });
            draw(vcx);
            assert_eq!(value(&secret, vcx), "synthetic-hal", "{kind:?}");
            let shown = requests.read_with(vcx, |r, _| {
                (
                    r.queue.len(),
                    r.top().and_then(|t| t.message_args.get("prompt").cloned()),
                )
            });
            assert_eq!(
                shown,
                (1, Some("Enter your Demo Weather API key again".to_string())),
                "{kind:?}: refreshed in place"
            );
            // Withdrawn, then another request: emptied.
            requests.update(vcx, |r, cx| r.on_settled(&id, cx));
            requests.update(vcx, |r, cx| {
                r.on_request(
                    hermes(&format!("{id}-next"), kind, "Another key", json!({})),
                    cx,
                )
            });
            draw(vcx);
            assert_eq!(value(&secret, vcx), "", "{kind:?}");
            requests.update(vcx, |r, cx| r.on_settled(&format!("{id}-next"), cx));
            draw(vcx);
        }

        // A form: a question's own words stay; a question asked anew gets a
        // field; another request starts afresh.
        requests.update(vcx, |r, cx| {
            r.on_request(form("f1", &[("q0", "Any dietary notes?")]), cx)
        });
        draw(vcx);
        let q0 = view
            .read_with(vcx, |v, _| v.clarify_inputs.get("q0").cloned())
            .expect("the question's field");
        vcx.update(|window, cx| q0.update(cx, |i, cx| i.set_value("No nuts", window, cx)));
        draw(vcx);
        requests.update(vcx, |r, cx| {
            r.on_request(
                form(
                    "f1",
                    &[("q0", "Any dietary notes?"), ("q1", "Serving style?")],
                ),
                cx,
            )
        });
        draw(vcx);
        let (kept, added) = view.read_with(vcx, |v, _| {
            (
                v.clarify_inputs.get("q0").cloned(),
                v.clarify_inputs.contains_key("q1"),
            )
        });
        assert!(kept.is_some_and(|k| k == q0), "the same field");
        assert_eq!(value(&q0, vcx), "No nuts");
        assert!(added, "the new question has its field");
        requests.update(vcx, |r, cx| r.on_settled("f1", cx));
        requests.update(vcx, |r, cx| {
            r.on_request(form("f2", &[("q0", "Any dietary notes?")]), cx)
        });
        draw(vcx);
        let fresh = view.read_with(vcx, |v, _| v.clarify_inputs.get("q0").cloned());
        assert!(
            fresh.is_some_and(|f| f != q0),
            "another request, another field"
        );
    }

    /// A select raised again with fewer choices answers with the choice its
    /// card shows, never an empty answer.
    #[gpui_kit::test]
    fn a_select_raised_again_answers_what_it_shows(cx: &mut TestAppContext) {
        let scratch =
            std::env::temp_dir().join(format!("conduit-approvals-select-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&scratch);
        let rpc = FakeDaemon::new().rpc();
        cx.update(|cx| {
            gpui_kit::init(cx);
            install(
                ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
                cx,
            );
            cx.set_global(conduit_components::Strings::default());
            cx.set_global(L10n::new("en"));
        });
        let stores = cx.update(|cx| crate::fixture::stores(rpc, &scratch, cx));
        let requests = stores.ui_requests.clone();
        let (view, vcx) =
            cx.add_window_view(move |window, cx| ApprovalsView::new(stores, window, cx));
        let select = |values: &[&str]| UiRequest {
            request_id: "s1".into(),
            kind: UiRequestKind::InputPrompt,
            message_code: "ui.input".into(),
            message_args: BTreeMap::from([("title".to_string(), "Pick a bed".to_string())]),
            detail: json!({}),
            timeout_ms: Some(300_000),
            default_choice: "cancel".into(),
            input_type: Some(UiInputType::Select),
            options: Some(
                values
                    .iter()
                    .map(|v| UiInputOption {
                        value: v.to_string(),
                        label: v.to_uppercase(),
                    })
                    .collect(),
            ),
        };
        requests.update(vcx, |r, cx| r.on_request(select(&["a", "b", "c"]), cx));
        draw(vcx);
        view.update(vcx, |v, _| v.selected = 2);
        requests.update(vcx, |r, cx| r.on_request(select(&["a", "b"]), cx));
        draw(vcx);
        let top = select(&["a", "b"]);
        let sent = view.read_with(vcx, |v, cx| v.typed(&top, cx));
        assert_eq!(sent.as_deref(), Some("b"), "an empty answer would go");
    }
}
