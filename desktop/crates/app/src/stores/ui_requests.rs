//! The daemon asking the user something: `ui.request` events queue here,
//! `ui.respond` answers them, and `ui.settled` takes them away (answered
//! here, in another window, or by the daemon's timeout).
//!
//! [`card`] reads a request into what its card shows ([`Card`]): a plain
//! confirmation, a tool approval, a text, password or select prompt, an MCP
//! tool approval, a Hermes decision with the agent's own choices, or, for a
//! kind this window cannot answer, [`Card::Unsupported`], which says to
//! answer it on mobile or the web and only dismisses (with the request's
//! conservative default). [`allow`] and [`deny`] are what ⌥⌘↩ and ⌥⌘⌫ send
//! for the request on top.

use std::collections::HashSet;

use conduit_daemon::RpcError;
use conduit_protocol::{UiInputOption, UiInputType, UiRequest, UiRequestKind, UiResponse, methods};
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
    /// A Hermes agent asking to go on, with the choices it offers.
    Hermes {
        summary: String,
        choices: Vec<String>,
    },
    /// An MCP App in a chat wants to call one of its server's tools.
    McpAppTool {
        server: String,
        tool: String,
        arguments: String,
    },
    /// An MCP App asks to open a web page.
    OpenLink { url: String },
    /// A kind this window does not host: answer on mobile or the web.
    Unsupported,
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
        UiRequestKind::McpApproval => Card::Mcp {
            server: arg(request, "serverName").unwrap_or_default(),
            tool: arg(request, "toolName").unwrap_or_default(),
            arguments: match request.detail.get("arguments") {
                Some(Value::String(s)) => s.clone(),
                Some(Value::Null) | None => String::new(),
                Some(other) => other.to_string(),
            },
        },
        // The daemon hosts Hermes run approvals; the agent's other questions
        // (clarify, sudo, secrets) are answered where the agent runs.
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
        UiRequestKind::HermesDecision | UiRequestKind::Unknown => Card::Unsupported,
    }
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
        | Card::OpenLink { .. } => Some(Answer::new("allow")),
        Card::Input { .. } => Some(Answer {
            choice: "allow".into(),
            text: Some(text.unwrap_or_default()),
        }),
        Card::Hermes { choices, .. } => {
            let once = choices.iter().find(|c| *c == "once");
            let first = choices.iter().find(|c| *c != "deny");
            once.or(first).map(|c| Answer::new(c))
        }
        Card::Unsupported => None,
    }
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
}

pub struct UiRequestsStore {
    rpc: Rpc,
    /// Oldest first; the card shows the first.
    pub queue: Vec<UiRequest>,
    /// Requests answered here whose `ui.settled` has not arrived yet.
    pub answering: HashSet<String>,
    pub error: Option<RpcError>,
}

impl EventEmitter<UiRequestsEvent> for UiRequestsStore {}

impl UiRequestsStore {
    pub fn new(rpc: Rpc) -> Self {
        Self {
            rpc,
            queue: vec![],
            answering: HashSet::new(),
            error: None,
        }
    }

    pub fn top(&self) -> Option<&UiRequest> {
        self.queue.first()
    }

    /// A new daemon session: the daemon sends what is still waiting again.
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.queue.clear();
        self.answering.clear();
        cx.notify();
    }

    /// `ui.request`.
    pub fn on_request(&mut self, request: UiRequest, cx: &mut Context<Self>) {
        if self
            .queue
            .iter()
            .any(|r| r.request_id == request.request_id)
        {
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
                ]
            }
        );
        // A Hermes question the daemon does not host.
        let mut clarify = hermes.clone();
        clarify.message_code = "hermes.clarify".into();
        assert_eq!(card(&clarify), Card::Unsupported);
        let unknown = request("6", UiRequestKind::Unknown, &[]);
        assert_eq!(card(&unknown), Card::Unsupported);
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
