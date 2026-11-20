//! The daemon asking the user something: `ui.request` events queue here,
//! `ui.respond` answers them, and `ui.settled` takes them away (answered
//! here, in another window, or by the daemon's timeout).
//!
//! [`card`] reads a request into what its card shows ([`Card`]): a plain
//! confirmation, a tool approval, a text, password or select prompt, an MCP
//! tool approval, a Hermes decision with the agent's own choices (and a paid
//! tool's cost), a Hermes clarify form, sudo password, secret or MCP set-up,
//! or, for a kind this window cannot answer, [`Card::Unsupported`], which
//! says to answer it on mobile or the web and only dismisses (with the
//! request's conservative default). [`allow`] and [`deny`] are what ⌥⌘↩ and
//! ⌥⌘⌫ send for the request on top; a Hermes question is answered with
//! `hermes.decisions.answer` instead ([`UiRequestsStore::answer_hermes`]),
//! which waits for Hermes to take it.

use std::collections::HashSet;

use conduit_daemon::RpcError;
use conduit_protocol::{
    HermesClarifyAnswer, HermesDecisionAnswer, HermesDecisionStatus, UiInputOption, UiInputType,
    UiRequest, UiRequestKind, UiResponse, methods,
};
use gpui_kit::{AsyncApp, Context, EventEmitter, WeakEntity};
use serde_json::Value;

use super::rpc::Rpc;

/// What a request's card shows. Server and agent text arrives as prose in
/// `messageArgs` (the daemon has no locale); the window words the rest.
#[derive(Clone, Debug, PartialEq)]
pub enum Card {
    /// Allow or deny, with the server's own labels when it gave any.
    Confirm {
        title: String,
        message: String,
        confirm_label: Option<String>,
        cancel_label: Option<String>,
    },
    /// An Open WebUI tool asking to run.
    Tool { title: String, message: String },
    /// A value mid-turn: text, password (never echoed) or one of `options`.
    Input {
        title: String,
        message: String,
        placeholder: Option<String>,
        initial: String,
        input: InputKind,
        confirm_label: Option<String>,
        cancel_label: Option<String>,
    },
    /// An MCP tool asking to run: once, for the session, always, or deny.
    Mcp {
        server: String,
        tool: String,
        arguments: String,
    },
    /// A Hermes agent asking to go on, with the choices it offers, and a
    /// paid tool's price.
    Hermes {
        summary: String,
        choices: Vec<String>,
        cost: Option<HermesCost>,
    },
    /// A Hermes agent's questions, answered as one form.
    HermesClarify {
        prompt: String,
        questions: Vec<ClarifyQuestion>,
    },
    /// A Hermes agent needs the sudo password (`sudo`) or a secret: typed
    /// masked, never kept.
    HermesSecret { prompt: String, sudo: bool },
    /// A Hermes agent wants to set up an MCP server.
    HermesSetup { server: String, action: String },
    /// An MCP App in a chat wants to call one of its server's tools.
    McpAppTool {
        server: String,
        tool: String,
        arguments: String,
    },
    /// An MCP App asks to open a web page.
    OpenLink { url: String },
    /// Hermes holds a switch to another model until the user confirms it:
    /// Switch and Send (`allow`) or Keep Current Model (`deny`), with
    /// Hermes' own reason when it gave one.
    HermesModelSwitch {
        model: String,
        reason: Option<String>,
    },
    /// A kind this window does not host: answer on mobile or the web.
    Unsupported,
}

/// What a paid MCP tool's call costs, as Hermes stated it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct HermesCost {
    /// "5 credits".
    pub price: Option<String>,
    pub approximate: bool,
    /// "per poster".
    pub note: Option<String>,
    /// What the chat spent so far, and its limit.
    pub spent: Option<String>,
    pub limit: Option<String>,
    pub server: Option<String>,
    /// The call would pass the chat's spend limit.
    pub over_limit: bool,
}

/// One question of a Hermes clarify form.
#[derive(Clone, Debug, PartialEq)]
pub struct ClarifyQuestion {
    pub id: String,
    /// Empty for a plain reply asked without question text.
    pub text: String,
    pub choices: Vec<ClarifyChoice>,
    pub multi: bool,
    /// Answered elsewhere already: shown, not asked.
    pub locked: bool,
    pub locked_answer: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ClarifyChoice {
    /// What goes back.
    pub value: String,
    pub label: String,
    pub recommended: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum InputKind {
    Text,
    Password,
    Select(Vec<UiInputOption>),
}

fn arg(r: &UiRequest, key: &str) -> Option<String> {
    r.message_args.get(key).cloned().filter(|s| !s.is_empty())
}

/// Whether `request` shows (and is answered) while `chat` is open: a held
/// Hermes model switch is the question of the chat whose message waits
/// (`detail.chatId`), shown with that chat only and never answered from
/// another; every other request shows with any chat.
pub fn shown_with(request: &UiRequest, chat: Option<&str>) -> bool {
    match request.kind {
        UiRequestKind::HermesModelSwitch => request
            .detail
            .get("chatId")
            .and_then(serde_json::Value::as_str)
            .is_some_and(|owner| chat == Some(owner)),
        _ => true,
    }
}

/// The card for `request`.
pub fn card(request: &UiRequest) -> Card {
    let title = arg(request, "title").unwrap_or_default();
    let message = arg(request, "message").unwrap_or_default();
    match request.kind {
        UiRequestKind::Confirm => Card::Confirm {
            title,
            message,
            confirm_label: arg(request, "confirmLabel"),
            cancel_label: arg(request, "cancelLabel"),
        },
        // A LibreChat run paused on a tool: its description, then the
        // arguments it would run with.
        UiRequestKind::ToolApproval if request.message_code == "librechat.toolApproval" => {
            let arguments = request
                .detail
                .get("arguments")
                .and_then(Value::as_str)
                .unwrap_or_default();
            Card::Tool {
                title,
                message: [message.as_str(), arguments]
                    .into_iter()
                    .filter(|s| !s.trim().is_empty())
                    .collect::<Vec<_>>()
                    .join("\n\n"),
            }
        }
        UiRequestKind::ToolApproval => Card::Tool { title, message },
        UiRequestKind::InputPrompt => {
            let input = match request.input_type {
                None | Some(UiInputType::Text) => InputKind::Text,
                Some(UiInputType::Password) => InputKind::Password,
                Some(UiInputType::Select) => match &request.options {
                    Some(options) if !options.is_empty() => InputKind::Select(options.clone()),
                    // A select with nothing to pick cannot be answered.
                    _ => return Card::Unsupported,
                },
                Some(UiInputType::Unknown) => return Card::Unsupported,
            };
            Card::Input {
                title,
                message,
                placeholder: arg(request, "placeholder"),
                initial: arg(request, "initialValue").unwrap_or_default(),
                input,
                confirm_label: arg(request, "confirmLabel"),
                cancel_label: arg(request, "cancelLabel"),
            }
        }
        // A LibreChat agent's question: its options to pick from, or words
        // of one's own when it offers none. Cancel stops the reply.
        UiRequestKind::LibreChatQuestion => {
            let options: Vec<UiInputOption> = request
                .detail
                .get("options")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(|o| o.get("label").and_then(Value::as_str))
                        .map(|label| UiInputOption {
                            value: label.to_string(),
                            label: label.to_string(),
                        })
                        .collect()
                })
                .unwrap_or_default();
            let description = request
                .detail
                .get("description")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            Card::Input {
                title,
                message: description,
                placeholder: None,
                initial: String::new(),
                input: if options.is_empty() {
                    InputKind::Text
                } else {
                    InputKind::Select(options)
                },
                confirm_label: None,
                cancel_label: None,
            }
        }
        UiRequestKind::McpApproval => Card::Mcp {
            server: arg(request, "serverName").unwrap_or_default(),
            tool: arg(request, "toolName").unwrap_or_default(),
            arguments: match request.detail.get("arguments") {
                Some(Value::String(s)) => s.clone(),
                Some(Value::Null) | None => String::new(),
                Some(other) => other.to_string(),
            },
        },
        UiRequestKind::HermesDecision if request.message_code == "hermes.mcpSetup" => {
            Card::HermesSetup {
                server: arg(request, "server").unwrap_or_default(),
                action: arg(request, "action").unwrap_or_default(),
            }
        }
        UiRequestKind::HermesClarify => {
            let questions = clarify_questions(&request.detail);
            if questions.is_empty() {
                Card::Unsupported
            } else {
                Card::HermesClarify {
                    prompt: arg(request, "prompt").unwrap_or_default(),
                    questions,
                }
            }
        }
        UiRequestKind::HermesSudo | UiRequestKind::HermesSecret => Card::HermesSecret {
            prompt: arg(request, "prompt").unwrap_or_default(),
            sudo: request.kind == UiRequestKind::HermesSudo,
        },
        UiRequestKind::HermesDecision if request.message_code == "hermes.approval" => {
            let choices: Vec<String> = request
                .detail
                .get("choices")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(|c| c.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default();
            Card::Hermes {
                summary: arg(request, "summary").unwrap_or_default(),
                choices: if choices.is_empty() {
                    vec!["once".into(), "deny".into()]
                } else {
                    choices
                },
                cost: request.detail.get("cost").and_then(hermes_cost),
            }
        }
        UiRequestKind::McpAppToolCall => Card::McpAppTool {
            server: arg(request, "serverName").unwrap_or_default(),
            tool: arg(request, "toolName").unwrap_or_default(),
            arguments: match request.detail.get("arguments") {
                Some(Value::String(s)) => s.clone(),
                Some(Value::Null) | None => String::new(),
                Some(other) => other.to_string(),
            },
        },
        UiRequestKind::McpAppOpenLink => match arg(request, "url") {
            Some(url) => Card::OpenLink { url },
            None => Card::Unsupported,
        },
        UiRequestKind::HermesModelSwitch => match arg(request, "model") {
            Some(model) => Card::HermesModelSwitch {
                model,
                reason: arg(request, "reason"),
            },
            None => Card::Unsupported,
        },
        UiRequestKind::HermesDecision | UiRequestKind::Unknown => Card::Unsupported,
    }
}

fn text_of(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// A Hermes approval's `detail.cost`.
fn hermes_cost(raw: &Value) -> Option<HermesCost> {
    let cost = HermesCost {
        price: text_of(raw.get("price")),
        approximate: raw.get("approximate").and_then(Value::as_bool) == Some(true),
        note: text_of(raw.get("note")),
        spent: text_of(raw.get("spent")),
        limit: text_of(raw.get("limit")),
        server: text_of(raw.get("server")),
        over_limit: raw.get("overLimit").and_then(Value::as_bool) == Some(true),
    };
    (cost != HermesCost::default()).then_some(cost)
}

/// A `hermesClarify` request's questions (`detail.questions`).
pub fn clarify_questions(detail: &Value) -> Vec<ClarifyQuestion> {
    let Some(rows) = detail.get("questions").and_then(Value::as_array) else {
        return vec![];
    };
    rows.iter()
        .filter_map(|q| {
            let id = text_of(q.get("id"))?;
            let choices = q
                .get("choices")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(|c| {
                            let value = text_of(c.get("value"))?;
                            Some(ClarifyChoice {
                                label: text_of(c.get("label")).unwrap_or_else(|| value.clone()),
                                value,
                                recommended: c.get("recommended").and_then(Value::as_bool)
                                    == Some(true),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            Some(ClarifyQuestion {
                id,
                text: text_of(q.get("text")).unwrap_or_default(),
                choices,
                multi: q.get("multiSelect").and_then(Value::as_bool) == Some(true),
                locked: q.get("locked").and_then(Value::as_bool) == Some(true),
                locked_answer: text_of(q.get("lockedAnswer")),
            })
        })
        .collect()
}

/// An answer: `choice`, plus the text for a prompt.
#[derive(Clone, Debug, PartialEq)]
pub struct Answer {
    pub choice: String,
    pub text: Option<String>,
}

impl Answer {
    pub fn new(choice: &str) -> Self {
        Self {
            choice: choice.into(),
            text: None,
        }
    }

    pub fn with_text(choice: &str, text: String) -> Self {
        Self {
            choice: choice.into(),
            text: Some(text),
        }
    }
}

/// What ⌥⌘↩ answers: the card's primary action. `text` is a prompt's
/// value; `None` for anything else (and for an unsupported card, which has
/// no "allow").
pub fn allow(request: &UiRequest, text: Option<String>) -> Option<Answer> {
    match card(request) {
        Card::Confirm { .. }
        | Card::Tool { .. }
        | Card::Mcp { .. }
        | Card::McpAppTool { .. }
        | Card::OpenLink { .. }
        | Card::HermesModelSwitch { .. } => Some(Answer::new("allow")),
        Card::Input { .. } => Some(Answer {
            choice: "allow".into(),
            text: Some(text.unwrap_or_default()),
        }),
        Card::Hermes { choices, .. } => {
            let once = choices.iter().find(|c| *c == "once");
            let first = choices.iter().find(|c| *c != "deny");
            once.or(first).map(|c| Answer::new(c))
        }
        // Answered with `hermes.decisions.answer`, from the card.
        Card::HermesClarify { .. }
        | Card::HermesSecret { .. }
        | Card::HermesSetup { .. }
        | Card::Unsupported => None,
    }
}

/// Whether `request` is a Hermes question answered with
/// `hermes.decisions.answer` (not `ui.respond`).
pub fn is_hermes_question(request: &UiRequest) -> bool {
    matches!(
        card(request),
        Card::HermesClarify { .. } | Card::HermesSecret { .. } | Card::HermesSetup { .. }
    )
}

/// What ⌥⌘⌫ answers: deny, cancel a prompt, or dismiss with the request's
/// conservative default.
pub fn deny(request: &UiRequest) -> Answer {
    match card(request) {
        Card::Input { .. } => Answer::new("cancel"),
        Card::Unsupported => Answer::new(&request.default_choice),
        _ => Answer::new("deny"),
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum UiRequestsEvent {
    /// A request arrived (the window raises itself and announces it).
    Arrived(String),
    /// A Hermes question was answered elsewhere or expired before this
    /// window's answer arrived: it was not sent.
    HermesSettledElsewhere,
}

pub struct UiRequestsStore {
    rpc: Rpc,
    /// Oldest first; the card shows the first.
    pub queue: Vec<UiRequest>,
    /// Requests answered here whose `ui.settled` has not arrived yet.
    pub answering: HashSet<String>,
    pub error: Option<RpcError>,
    /// The request whose answer [`Self::error`] is about: its card says so,
    /// and no other.
    pub error_for: Option<String>,
    /// Hermes questions whose answer did not arrive (the card says so and
    /// stays, to be answered again).
    pub hermes_failed: HashSet<String>,
}

impl EventEmitter<UiRequestsEvent> for UiRequestsStore {}

impl UiRequestsStore {
    pub fn new(rpc: Rpc) -> Self {
        Self {
            rpc,
            queue: vec![],
            answering: HashSet::new(),
            error: None,
            error_for: None,
            hermes_failed: HashSet::new(),
        }
    }

    pub fn top(&self) -> Option<&UiRequest> {
        self.queue.first()
    }

    /// The first request the dock shows while `chat` is open: a request
    /// that is one chat's alone ([`shown_with`]) waits for that chat.
    pub fn top_for(&self, chat: Option<&str>) -> Option<&UiRequest> {
        self.queue.iter().find(|r| shown_with(r, chat))
    }

    /// How many requests the dock has while `chat` is open.
    pub fn shown_count(&self, chat: Option<&str>) -> usize {
        self.queue.iter().filter(|r| shown_with(r, chat)).count()
    }

    /// A new daemon session: the daemon sends what is still waiting again.
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.queue.clear();
        self.answering.clear();
        cx.notify();
    }

    /// `ui.request`. The same request raised again is refreshed in place
    /// (what it says may have changed), not announced again: its card keeps
    /// what is typed into it.
    pub fn on_request(&mut self, request: UiRequest, cx: &mut Context<Self>) {
        if let Some(shown) = self
            .queue
            .iter_mut()
            .find(|r| r.request_id == request.request_id)
        {
            if *shown != request {
                *shown = request;
                cx.notify();
            }
            return;
        }
        let id = request.request_id.clone();
        self.queue.push(request);
        cx.emit(UiRequestsEvent::Arrived(id));
        cx.notify();
    }

    /// `ui.settled`.
    pub fn on_settled(&mut self, request_id: &str, cx: &mut Context<Self>) {
        self.answering.remove(request_id);
        self.hermes_failed.remove(request_id);
        let before = self.queue.len();
        self.queue.retain(|r| r.request_id != request_id);
        if self.queue.len() != before {
            cx.notify();
        }
    }

    /// `ui.respond`. The card stays (marked answering) until `ui.settled`;
    /// an answer that came too late (`accepted: false`) takes it away now.
    pub fn respond(
        &mut self,
        request_id: &str,
        answer: Answer,
        remember: bool,
        cx: &mut Context<Self>,
    ) {
        // Settled (or never here): there is nothing to answer.
        if !self.queue.iter().any(|r| r.request_id == request_id) {
            return;
        }
        if !self.answering.insert(request_id.to_string()) {
            return;
        }
        self.error = None;
        self.error_for = None;
        let id = request_id.to_string();
        let call = self.rpc.call::<methods::UiRespond>(&UiResponse {
            request_id: id.clone(),
            choice: answer.choice,
            text: answer.text,
            remember,
        });
        cx.notify();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                match result {
                    Ok(r) if !r.accepted => s.on_settled(&id, cx),
                    Ok(_) => {}
                    Err(e) => {
                        log::warn!("ui.respond: {e}");
                        s.answering.remove(&id);
                        s.error = Some(e);
                        s.error_for = Some(id.clone());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// `hermes.decisions.answer`: a clarify form's `answers`, or the
    /// `value` of a password, secret, reply or set-up card. The card stays
    /// (answering) until `ui.settled`; an answer that did not arrive leaves
    /// it to be given again, saying so. A password or secret is passed on
    /// and not kept.
    pub fn answer_hermes(
        &mut self,
        request_id: &str,
        answers: Vec<HermesClarifyAnswer>,
        value: Option<String>,
        cx: &mut Context<Self>,
    ) {
        // Settled (or never here): there is nothing to answer.
        if !self.queue.iter().any(|r| r.request_id == request_id) {
            return;
        }
        if !self.answering.insert(request_id.to_string()) {
            return;
        }
        self.hermes_failed.remove(request_id);
        self.error = None;
        self.error_for = None;
        let id = request_id.to_string();
        let call = self
            .rpc
            .call::<methods::HermesDecisionsAnswer>(&HermesDecisionAnswer {
                request_id: id.clone(),
                answers,
                value,
            });
        cx.notify();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                match result {
                    // `ui.settled` takes the card away.
                    Ok(r) if r.status == HermesDecisionStatus::Answered => {}
                    Ok(r) if r.status == HermesDecisionStatus::Settled => {
                        cx.emit(UiRequestsEvent::HermesSettledElsewhere);
                        s.on_settled(&id, cx);
                    }
                    Ok(_) => {
                        s.answering.remove(&id);
                        s.hermes_failed.insert(id.clone());
                    }
                    Err(e) => {
                        log::warn!("hermes.decisions.answer: {e}");
                        s.answering.remove(&id);
                        s.hermes_failed.insert(id.clone());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// ⌥⌘↩ on the top request. `text` is the prompt field's value.
    pub fn allow_top(&mut self, text: Option<String>, cx: &mut Context<Self>) -> bool {
        let Some(top) = self.top().cloned() else {
            return false;
        };
        match allow(&top, text) {
            Some(answer) => {
                self.respond(&top.request_id, answer, false, cx);
                true
            }
            None => false,
        }
    }

    /// ⌥⌘⌫ on the top request.
    pub fn deny_top(&mut self, cx: &mut Context<Self>) -> bool {
        let Some(top) = self.top().cloned() else {
            return false;
        };
        let answer = deny(&top);
        self.respond(&top.request_id, answer, false, cx);
        true
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use conduit_protocol::AcceptedResult;
    use gpui_kit::{AppContext as _, TestAppContext};
    use serde_json::json;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    fn request(id: &str, kind: UiRequestKind, args: &[(&str, &str)]) -> UiRequest {
        UiRequest {
            request_id: id.into(),
            kind,
            message_code: "server.prompt".into(),
            message_args: args
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect::<BTreeMap<_, _>>(),
            detail: json!({}),
            timeout_ms: None,
            default_choice: "deny".into(),
            input_type: None,
            options: None,
        }
    }

    #[test]
    fn every_kind_reads_into_a_card() {
        let confirm = request(
            "1",
            UiRequestKind::Confirm,
            &[("title", "Delete?"), ("confirmLabel", "Delete")],
        );
        assert_eq!(
            card(&confirm),
            Card::Confirm {
                title: "Delete?".into(),
                message: String::new(),
                confirm_label: Some("Delete".into()),
                cancel_label: None
            }
        );
        let tool = request("2", UiRequestKind::ToolApproval, &[("title", "Run search")]);
        assert!(matches!(card(&tool), Card::Tool { .. }));

        let mut text = request("3", UiRequestKind::InputPrompt, &[("title", "Name?")]);
        assert!(matches!(
            card(&text),
            Card::Input {
                input: InputKind::Text,
                ..
            }
        ));
        text.input_type = Some(UiInputType::Password);
        assert!(matches!(
            card(&text),
            Card::Input {
                input: InputKind::Password,
                ..
            }
        ));
        text.input_type = Some(UiInputType::Select);
        assert_eq!(card(&text), Card::Unsupported, "a select with no options");
        text.options = Some(vec![UiInputOption {
            value: "a".into(),
            label: "Alpha".into(),
        }]);
        assert!(matches!(
            card(&text),
            Card::Input {
                input: InputKind::Select(_),
                ..
            }
        ));

        let mut mcp = request(
            "4",
            UiRequestKind::McpApproval,
            &[("serverName", "Files"), ("toolName", "read")],
        );
        mcp.message_code = "mcp.approval".into();
        mcp.detail = json!({"arguments": "{\"path\":\"/tmp\"}"});
        assert_eq!(
            card(&mcp),
            Card::Mcp {
                server: "Files".into(),
                tool: "read".into(),
                arguments: "{\"path\":\"/tmp\"}".into()
            }
        );

        let mut hermes = request(
            "5",
            UiRequestKind::HermesDecision,
            &[("summary", "rm -r x")],
        );
        hermes.message_code = "hermes.approval".into();
        hermes.detail = json!({"choices": ["once", "session", "always", "deny"]});
        assert_eq!(
            card(&hermes),
            Card::Hermes {
                summary: "rm -r x".into(),
                choices: vec![
                    "once".into(),
                    "session".into(),
                    "always".into(),
                    "deny".into()
                ],
                cost: None,
            }
        );
        // A Hermes decision code this build does not know.
        let mut other = hermes.clone();
        other.message_code = "hermes.other".into();
        assert_eq!(card(&other), Card::Unsupported);
        let unknown = request("6", UiRequestKind::Unknown, &[]);
        assert_eq!(card(&unknown), Card::Unsupported);
    }

    #[test]
    fn a_held_model_switch_is_switch_or_keep() {
        let held = request(
            "m",
            UiRequestKind::HermesModelSwitch,
            &[("model", "Heron Large"), ("reason", "It costs more.")],
        );
        assert_eq!(
            card(&held),
            Card::HermesModelSwitch {
                model: "Heron Large".into(),
                reason: Some("It costs more.".into()),
            }
        );
        // ⌥⌘↩ switches; ⌥⌘⌫ keeps the current model.
        assert_eq!(allow(&held, None), Some(Answer::new("allow")));
        assert_eq!(deny(&held), Answer::new("deny"));
        let unnamed = request("n", UiRequestKind::HermesModelSwitch, &[]);
        assert_eq!(card(&unnamed), Card::Unsupported);
    }

    #[test]
    fn the_shortcuts_pick_the_primary_and_the_safe_answer() {
        let tool = request("1", UiRequestKind::ToolApproval, &[]);
        assert_eq!(allow(&tool, None), Some(Answer::new("allow")));
        assert_eq!(deny(&tool), Answer::new("deny"));

        let prompt = request("2", UiRequestKind::InputPrompt, &[]);
        assert_eq!(
            allow(&prompt, Some("hi".into())),
            Some(Answer::with_text("allow", "hi".into()))
        );
        assert_eq!(deny(&prompt), Answer::new("cancel"));

        let mut hermes = request("3", UiRequestKind::HermesDecision, &[]);
        hermes.message_code = "hermes.approval".into();
        hermes.detail = json!({"choices": ["session", "deny"]});
        assert_eq!(allow(&hermes, None), Some(Answer::new("session")));
        hermes.detail = json!({"choices": ["always", "once", "deny"]});
        assert_eq!(allow(&hermes, None), Some(Answer::new("once")));

        let mut unknown = request("4", UiRequestKind::Unknown, &[]);
        unknown.default_choice = "cancel".into();
        assert_eq!(
            allow(&unknown, None),
            None,
            "no allow for what is not hosted"
        );
        assert_eq!(deny(&unknown), Answer::new("cancel"));
    }

    #[gpui_kit::test]
    fn requests_queue_answer_and_settle(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::UiRespond>(AcceptedResult { accepted: true });
        let store = cx.new(|_| UiRequestsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.on_request(request("a", UiRequestKind::ToolApproval, &[]), cx);
            s.on_request(request("b", UiRequestKind::Confirm, &[]), cx);
            // The daemon resends on a new subscription: no duplicates.
            s.on_request(request("a", UiRequestKind::ToolApproval, &[]), cx);
        });
        assert_eq!(store.read_with(cx, |s, _| s.queue.len()), 2);

        store.update(cx, |s, cx| assert!(s.allow_top(None, cx)));
        cx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::UiRespond>(),
            vec![json!({"requestId": "a", "choice": "allow", "remember": false})]
        );
        // Answered, but still shown until `ui.settled`.
        store.read_with(cx, |s, _| {
            assert_eq!(s.top().map(|r| r.request_id.as_str()), Some("a"));
            assert!(s.answering.contains("a"));
        });
        // A second press while answering sends nothing.
        store.update(cx, |s, cx| s.allow_top(None, cx));
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::UiRespond>().len(), 1);

        store.update(cx, |s, cx| s.on_settled("a", cx));
        assert_eq!(
            store.read_with(cx, |s, _| s.top().map(|r| r.request_id.clone())),
            Some("b".into())
        );
        store.update(cx, |s, cx| assert!(s.deny_top(cx)));
        cx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::UiRespond>()[1],
            json!({"requestId": "b", "choice": "deny", "remember": false})
        );
    }

    /// An answer that did not arrive is said on its own card only: the
    /// next card shown (another chat's) is not marked failed.
    #[gpui_kit::test]
    fn a_failed_answer_is_said_on_its_own_card(cx: &mut gpui_kit::TestAppContext) {
        let daemon = crate::stores::rpc::fake::FakeDaemon::new();
        daemon.once::<methods::UiRespond>(Err(conduit_daemon::protocol::error(
            "rpc.timeout",
            "no answer",
        )));
        let store = cx.new(|_| UiRequestsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.on_request(request("a", UiRequestKind::ToolApproval, &[]), cx);
            s.on_request(request("b", UiRequestKind::ToolApproval, &[]), cx);
            s.respond("a", Answer::new("allow"), false, cx);
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.error.is_some());
            assert_eq!(s.error_for.as_deref(), Some("a"));
        });
    }

    #[test]
    fn hermes_questions_read_into_their_cards() {
        let mut clarify = request("c", UiRequestKind::HermesClarify, &[("prompt", "")]);
        clarify.detail = json!({
            "chatId": "local:hermes_s",
            "questions": [
                {"id": "q0", "text": "Which cuisine?", "multiSelect": false, "locked": false,
                 "choices": [{"value": "Japanese", "label": "Japanese", "recommended": true}]},
                {"id": "q1", "text": "Courses?", "multiSelect": true, "locked": true,
                 "lockedAnswer": "Main", "choices": []},
            ],
        });
        let Card::HermesClarify { questions, .. } = card(&clarify) else {
            panic!("a clarify card");
        };
        assert_eq!(questions.len(), 2);
        assert!(questions[0].choices[0].recommended);
        assert!(questions[1].multi && questions[1].locked);
        assert_eq!(questions[1].locked_answer.as_deref(), Some("Main"));
        // A form with no question it can read cannot be answered here.
        clarify.detail = json!({"questions": []});
        assert_eq!(card(&clarify), Card::Unsupported);

        let secret = request(
            "s",
            UiRequestKind::HermesSecret,
            &[("prompt", "Paste the key")],
        );
        assert_eq!(
            card(&secret),
            Card::HermesSecret {
                prompt: "Paste the key".into(),
                sudo: false
            }
        );
        let sudo = request("u", UiRequestKind::HermesSudo, &[]);
        assert!(matches!(card(&sudo), Card::HermesSecret { sudo: true, .. }));
        let mut setup = request(
            "m",
            UiRequestKind::HermesDecision,
            &[("server", "demo_shop"), ("action", "Install")],
        );
        setup.message_code = "hermes.mcpSetup".into();
        assert!(matches!(card(&setup), Card::HermesSetup { .. }));
        // Answered from the card, not with ⌥⌘↩'s `ui.respond`.
        for r in [&secret, &sudo, &setup] {
            assert!(is_hermes_question(r));
            assert_eq!(allow(r, Some("x".into())), None);
        }

        let mut paid = request("p", UiRequestKind::HermesDecision, &[("summary", "Render")]);
        paid.message_code = "hermes.approval".into();
        paid.detail = json!({
            "choices": ["once", "deny"],
            "cost": {"price": "5 credits", "approximate": true, "spent": "10 credits",
                     "limit": "20 credits", "server": "demo_shop", "overLimit": false},
        });
        let Card::Hermes {
            cost: Some(cost), ..
        } = card(&paid)
        else {
            panic!("a paid approval");
        };
        assert_eq!(cost.price.as_deref(), Some("5 credits"));
        assert!(cost.approximate && !cost.over_limit);
    }

    #[gpui_kit::test]
    fn a_hermes_answer_waits_for_hermes(cx: &mut TestAppContext) {
        use conduit_protocol::{HermesDecisionResult, HermesDecisionStatus};
        let daemon = FakeDaemon::new();
        daemon.once::<methods::HermesDecisionsAnswer>(Ok(HermesDecisionResult {
            status: HermesDecisionStatus::Failed,
        }));
        daemon.returns::<methods::HermesDecisionsAnswer>(HermesDecisionResult {
            status: HermesDecisionStatus::Answered,
        });
        let store = cx.new(|_| UiRequestsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.on_request(request("s", UiRequestKind::HermesSecret, &[]), cx);
            s.answer_hermes("s", vec![], Some("synthetic-value".into()), cx);
        });
        cx.run_until_parked();
        // Not taken: the card stays, saying so, to be answered again.
        store.read_with(cx, |s, _| {
            assert!(s.hermes_failed.contains("s"));
            assert!(!s.answering.contains("s"));
            assert_eq!(s.queue.len(), 1);
        });
        store.update(cx, |s, cx| {
            s.answer_hermes("s", vec![], Some("again".into()), cx)
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(!s.hermes_failed.contains("s"));
            assert!(s.answering.contains("s"), "until ui.settled");
        });
        assert_eq!(
            daemon.calls::<methods::HermesDecisionsAnswer>()[1],
            json!({"requestId": "s", "answers": [], "value": "again"})
        );
        store.update(cx, |s, cx| s.on_settled("s", cx));
        assert!(store.read_with(cx, |s, _| s.queue.is_empty()));
    }

    #[gpui_kit::test]
    fn a_late_answer_takes_the_card_away(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::UiRespond>(AcceptedResult { accepted: false });
        let store = cx.new(|_| UiRequestsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.on_request(request("a", UiRequestKind::Confirm, &[]), cx);
            s.respond("a", Answer::new("allow"), false, cx);
        });
        cx.run_until_parked();
        assert!(store.read_with(cx, |s, _| s.queue.is_empty()));
    }

    #[gpui_kit::test]
    fn a_failed_answer_can_be_given_again(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.once::<methods::UiRespond>(Err(conduit_daemon::protocol::error(
            "transport.disconnected",
            "dropped",
        )));
        daemon.returns::<methods::UiRespond>(AcceptedResult { accepted: true });
        let store = cx.new(|_| UiRequestsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.on_request(request("a", UiRequestKind::Confirm, &[]), cx);
            s.respond("a", Answer::new("allow"), false, cx);
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.error.is_some());
            assert!(!s.answering.contains("a"));
        });
        store.update(cx, |s, cx| s.respond("a", Answer::new("allow"), true, cx));
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::UiRespond>().len(), 2);
        assert_eq!(
            daemon.calls::<methods::UiRespond>()[1]["remember"],
            json!(true)
        );
    }
}
