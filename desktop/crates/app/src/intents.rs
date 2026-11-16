//! Shortcuts, Siri and Spotlight: the app's side of its App Intents.
//!
//! The intents are Swift (`crates/app/intents`), compiled by build.rs into
//! this binary; AppKit registers the process with the App Intents runtime
//! at launch, and `Metadata.appintents` in the bundle tells the system what
//! they are (`packaging/macos/intents.sh`). Each intent's `perform()` hands
//! [`conduit_intents_request`] one JSON [`Request`] and waits for one
//! [`Response`], which this module sends once, whatever happens:
//!
//! * **Ask Conduit** asks the daemon (`intents.ask`), which sends the
//!   question as a new chat and waits for the answer; the answer goes back
//!   as text, and "Open in Conduit" shows the chat afterwards. An answer that
//!   fails, waits in the outbox or takes longer than [`ASK_TIMEOUT`] fails
//!   the action with words that say where the answer will be.
//! * **New Chat** and **Open Chat** take the path `conduit://` links take
//!   ([`desktop::open_request`]): queued until the main window shows the
//!   main frame.
//! * **Show Quick Ask** shows the panel over the app in front; with text, as
//!   a new question with the text in its message box (the same request
//!   `conduit://quick-ask` makes, with the text).
//! * **Start Voice Call** takes the widget's `conduit://call` path
//!   ([`desktop::open_request`]): a new chat with a call in it, started with
//!   the call store (never the toggling `VoiceCall` action). The action
//!   waits for the call to be on, or says why the core refused it in the
//!   call strip's words ([`call_outcome`]).
//! * Open Chat's chat list asks the daemon too (`intents.chats`).
//!
//! An intent can come before anything is ready: the system launches the app
//! to run it. Requests wait in [`INBOX`] until [`install`] takes them, then
//! until the daemon is connected and the session knows where it routes
//! ([`READY_TIMEOUT`]); with no signed-in account they fail with words that
//! say so. Every failure is a sentence in the user's language.

use std::collections::BTreeSet;
use std::ffi::{CStr, c_char, c_void};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use conduit_daemon::RpcError;
use conduit_protocol::{
    CallPhase, ErrorCode, IntentAnswer, IntentAsk, IntentChatsQuery, TurnFinished, methods,
};
use futures::StreamExt as _;
use futures::channel::mpsc;
use gpui_kit::{App, AsyncApp, Global};
use serde::{Deserialize, Serialize};

use crate::AppState;
use crate::desktop;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::deep_link::{self, OpenRequest};
use crate::stores::session::Route;

/// How long Ask Conduit waits for the answer (the daemon's wait); the
/// answer keeps going in its chat afterwards.
pub const ASK_TIMEOUT: Duration = Duration::from_secs(120);

/// How long a request waits for a launch to finish: the daemon connected
/// and the session routed.
pub const READY_TIMEOUT: Duration = Duration::from_secs(30);

/// How many chats Open Chat's list offers at once.
const CHAT_LIMIT: i64 = 20;

/// One request from an intent: `IntentRequest` in intents/Bridge.swift.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Request {
    Ask {
        prompt: String,
        #[serde(default)]
        open_in_conduit: bool,
    },
    NewChat {
        prompt: Option<String>,
    },
    OpenChat {
        id: String,
    },
    StartVoiceCall,
    QuickAsk {
        text: Option<String>,
    },
    Chats {
        #[serde(default)]
        ids: Vec<String>,
        query: Option<String>,
    },
}

impl Request {
    /// Its kind, for the log: never the text, ids or queries.
    fn describe(&self) -> &'static str {
        match self {
            Self::Ask { .. } => "ask",
            Self::NewChat { .. } => "new chat",
            Self::OpenChat { .. } => "open chat",
            Self::StartVoiceCall => "voice call",
            Self::QuickAsk { .. } => "quick ask",
            Self::Chats { .. } => "chats",
        }
    }
}

/// One chat in Open Chat's list.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ChatOut {
    pub id: String,
    pub title: String,
}

/// The reply: `IntentReply` in intents/Bridge.swift. `error` is a sentence
/// in the user's language; none (`ok` false) makes the intent say Conduit
/// couldn't do it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Response {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chats: Option<Vec<ChatOut>>,
}

impl Response {
    pub fn done() -> Self {
        Self {
            ok: true,
            ..Self::default()
        }
    }

    pub fn value(value: String) -> Self {
        Self {
            ok: true,
            value: Some(value),
            ..Self::default()
        }
    }

    pub fn chats(chats: Vec<ChatOut>) -> Self {
        Self {
            ok: true,
            chats: Some(chats),
            ..Self::default()
        }
    }

    pub fn failed(message: String) -> Self {
        Self {
            ok: false,
            error: Some(message),
            ..Self::default()
        }
    }
}

/// Why an intent failed, said in the user's language by [`Failure::message`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Failure {
    /// No signed-in account (onboarding, or a sign-in is needed).
    NeedsSignIn,
    /// The launch did not get ready within [`READY_TIMEOUT`].
    NotReady,
    EmptyQuestion,
    /// The server is out of reach.
    Offline,
    /// The question waits in the outbox.
    Queued,
    /// No answer within [`ASK_TIMEOUT`]; it keeps going in this chat.
    TimedOut {
        title: Option<String>,
    },
    /// The model answered with an error (the server's words, if any).
    AnswerFailed {
        detail: Option<String>,
    },
    ChatMissing,
    /// The core refused the call, or it failed as it started: the call
    /// strip's words for why.
    CallFailed {
        reason: String,
    },
    Unexpected,
}

impl Failure {
    pub fn message(&self, l: &L10n) -> String {
        match self {
            Self::NeedsSignIn => l.desktop_intent_needs_sign_in(),
            Self::NotReady => l.desktop_intent_not_ready(),
            Self::EmptyQuestion => l.desktop_intent_ask_empty(),
            Self::Offline => l.desktop_intent_offline(),
            Self::Queued => l.desktop_intent_ask_queued(),
            Self::TimedOut { title: Some(title) } => l.desktop_intent_ask_timed_out(title),
            Self::TimedOut { title: None } => l.desktop_intent_ask_timed_out_untitled(),
            Self::AnswerFailed {
                detail: Some(detail),
            } => l.desktop_intent_ask_failed(detail),
            Self::AnswerFailed { detail: None } => l.desktop_intent_ask_failed_plain(),
            Self::ChatMissing => l.desktop_intent_chat_missing(),
            Self::CallFailed { reason } => reason.clone(),
            Self::Unexpected => l.desktop_intent_unexpected(),
        }
    }

    /// Which way it failed, for the log: none of what it carries.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::NeedsSignIn => "needs sign-in",
            Self::NotReady => "not ready",
            Self::EmptyQuestion => "empty question",
            Self::Offline => "offline",
            Self::Queued => "queued",
            Self::TimedOut { .. } => "timed out",
            Self::AnswerFailed { .. } => "answer failed",
            Self::ChatMissing => "chat missing",
            Self::CallFailed { .. } => "call failed",
            Self::Unexpected => "unexpected",
        }
    }

    /// What a failed daemon call means to the user.
    pub fn from_rpc(error: &RpcError) -> Self {
        match error.code {
            ErrorCode::Unauthenticated
            | ErrorCode::SessionExpired
            | ErrorCode::InvalidCredentials
            | ErrorCode::Unauthorized => Self::NeedsSignIn,
            ErrorCode::Offline | ErrorCode::ConnectionFailed | ErrorCode::TlsUntrusted => {
                Self::Offline
            }
            ErrorCode::DaemonUnavailable | ErrorCode::ShuttingDown => Self::NotReady,
            ErrorCode::ServerError => Self::AnswerFailed {
                detail: detail(error.args.get("detail").map(String::as_str)),
            },
            _ => Self::Unexpected,
        }
    }
}

/// The log's line for a failed intent: which way it failed, never what
/// the failure carries (a chat's title, the server's words, a call's reason).
fn failed_line(failure: &Failure) -> String {
    format!("intent failed: {}", failure.kind())
}

fn detail(text: Option<&str>) -> Option<String> {
    text.map(str::trim)
        .filter(|t| !t.is_empty())
        .map(str::to_string)
}

/// What `intents.ask`'s reply means for the shortcut: the answer, or why
/// there is none.
pub fn ask_outcome(answer: &IntentAnswer) -> Result<String, Failure> {
    match answer.outcome.as_str() {
        "answered" => Ok(answer.text.clone()),
        "queued" => Err(Failure::Queued),
        "timedOut" => Err(Failure::TimedOut {
            title: detail(answer.title.as_deref()),
        }),
        "failed" => Err(Failure::AnswerFailed {
            detail: detail(answer.detail.as_deref()),
        }),
        _ => Err(Failure::Unexpected),
    }
}

// ── The bridge ─────────────────────────────────────────────────────────────

/// `ConduitIntentsReply` in intents/ConduitIntentsBridge.h.
pub type ReplyFn = unsafe extern "C" fn(*mut c_void, *const c_char);

/// The one reply a request is owed. Dropped without [`Reply::send`] (the
/// app quitting with the request queued), it says it failed, so no
/// `perform()` waits forever.
pub struct Reply(Option<Box<dyn FnOnce(Response) + Send>>);

impl Reply {
    pub fn new(send: impl FnOnce(Response) + Send + 'static) -> Self {
        Self(Some(Box::new(send)))
    }

    /// A reply to Swift: `reply(context, json)`, once.
    fn ffi(context: *mut c_void, reply: ReplyFn) -> Self {
        /// The context pointer, which Swift keeps alive until its reply.
        struct Context(*mut c_void);
        // SAFETY: Swift's `ReplyBox` is retained for exactly this call and
        // may be resumed from any thread.
        unsafe impl Send for Context {}
        let context = Context(context);
        Self::new(move |response| {
            let context = context;
            let json =
                serde_json::to_string(&response).unwrap_or_else(|_| r#"{"ok":false}"#.to_string());
            // Never an interior NUL: JSON escapes control characters.
            let json = std::ffi::CString::new(json).unwrap_or_default();
            // SAFETY: `reply` is the bridge's C function; it copies the
            // bytes before returning.
            unsafe { reply(context.0, json.as_ptr()) };
        })
    }

    pub fn send(mut self, response: Response) {
        if let Some(send) = self.0.take() {
            send(response);
        }
    }
}

impl Drop for Reply {
    fn drop(&mut self) {
        if let Some(send) = self.0.take() {
            send(Response::default());
        }
    }
}

/// A request and the reply it is owed.
pub struct Job {
    pub request: Request,
    pub reply: Reply,
}

/// Requests before [`install`] (a launch for an intent), then the channel
/// to the app.
struct Inbox {
    sender: Option<mpsc::UnboundedSender<Job>>,
    waiting: Vec<Job>,
}

static INBOX: Mutex<Inbox> = Mutex::new(Inbox {
    sender: None,
    waiting: Vec::new(),
});

/// Hands `job` to the app, or keeps it until the app takes requests.
pub fn submit(job: Job) {
    let mut inbox = INBOX.lock().unwrap_or_else(|e| e.into_inner());
    match &inbox.sender {
        // A closed channel drops the job, whose reply then says it failed.
        Some(sender) => drop(sender.unbounded_send(job)),
        None => inbox.waiting.push(job),
    }
}

/// The app's end of the inbox: what waited, then what comes.
fn take_inbox() -> mpsc::UnboundedReceiver<Job> {
    let (sender, receiver) = mpsc::unbounded();
    let mut inbox = INBOX.lock().unwrap_or_else(|e| e.into_inner());
    for job in inbox.waiting.drain(..) {
        let _ = sender.unbounded_send(job);
    }
    inbox.sender = Some(sender);
    receiver
}

/// The intents' way in (intents/ConduitIntentsBridge.h): one JSON request,
/// one `reply` call back with the JSON response, from whichever thread.
///
/// # Safety
///
/// `request` is a NUL-terminated string (or null); `context` and `reply`
/// come from intents/Bridge.swift, which keeps `context` alive until
/// `reply` is called.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn conduit_intents_request(
    request: *const c_char,
    context: *mut c_void,
    reply: Option<ReplyFn>,
) {
    let Some(reply) = reply else {
        return;
    };
    let reply = Reply::ffi(context, reply);
    let text = if request.is_null() {
        None
    } else {
        // SAFETY: the caller passes a NUL-terminated string.
        unsafe { CStr::from_ptr(request) }.to_str().ok()
    };
    match text.and_then(|t| serde_json::from_str::<Request>(t).ok()) {
        Some(request) => submit(Job { request, reply }),
        None => {
            log::warn!("intents: a request that does not parse");
            reply.send(Response::default());
        }
    }
}

// ── The app ────────────────────────────────────────────────────────────────

/// Starts taking requests: each runs on its own, so a long Ask Conduit
/// never holds up Open Chat.
pub fn install(cx: &mut App) {
    let mut jobs = take_inbox();
    cx.spawn(async move |cx| {
        while let Some(Job { request, reply }) = jobs.next().await {
            log::info!("intent: {}", request.describe());
            cx.spawn(async move |cx| {
                let response = handle(request, cx).await;
                reply.send(response);
            })
            .detach();
        }
    })
    .detach();
}

async fn handle(request: Request, cx: &mut AsyncApp) -> Response {
    let result = match ready(cx).await {
        Ok(()) => run(request, cx).await,
        Err(failure) => Err(failure),
    };
    match result {
        Ok(response) => response,
        Err(failure) => {
            log::info!("{}", failed_line(&failure));
            let message = cx.update(|cx| failure.message(cx.l10n()));
            Response::failed(message)
        }
    }
}

async fn run(request: Request, cx: &mut AsyncApp) -> Result<Response, Failure> {
    match request {
        Request::Ask {
            prompt,
            open_in_conduit,
        } => ask(prompt, open_in_conduit, cx).await,
        Request::NewChat { prompt } => {
            let text = prompt
                .filter(|t| !t.trim().is_empty())
                .map(|t| t.chars().take(deep_link::MAX_TEXT).collect());
            cx.update(|cx| {
                desktop::open_request(
                    OpenRequest::NewChat {
                        text,
                        files: vec![],
                    },
                    cx,
                )
            });
            Ok(Response::done())
        }
        Request::OpenChat { id } => {
            if !deep_link::valid_id(&id) || chats(vec![id.clone()], None, cx).await?.is_empty() {
                return Err(Failure::ChatMissing);
            }
            cx.update(|cx| desktop::open_request(OpenRequest::Chat { id }, cx));
            Ok(Response::done())
        }
        Request::QuickAsk { text } => {
            cx.update(|cx| desktop::open_request(OpenRequest::QuickAsk { text }, cx));
            Ok(Response::done())
        }
        Request::Chats { ids, query } => Ok(Response::chats(chats(ids, query, cx).await?)),
        Request::StartVoiceCall => start_voice_call(cx).await,
    }
}

/// Ask Conduit: the daemon asks and waits; the reply is the answer.
async fn ask(prompt: String, open: bool, cx: &mut AsyncApp) -> Result<Response, Failure> {
    let text = prompt.trim().to_string();
    if text.is_empty() {
        return Err(Failure::EmptyQuestion);
    }
    let rpc = cx.update(|cx| cx.global::<AppState>().connection.read(cx).rpc());
    let params = IntentAsk {
        text,
        model: None,
        timeout_ms: ASK_TIMEOUT.as_millis() as i64,
    };
    cx.update(|cx| cx.default_global::<HeldNotifications>().begin());
    // The daemon gives up on the answer first, and says so in its reply.
    let answer = rpc
        .call_with_timeout::<methods::IntentsAsk>(&params, ASK_TIMEOUT + Duration::from_secs(15))
        .await;
    // The shortcut has this chat's answer (or its failure) in hand: no
    // notification for it. One still coming notifies when it lands.
    let answered = match &answer {
        Ok(a) if a.outcome != "timedOut" => Some(a.chat_id.clone()),
        _ => None,
    };
    cx.update(|cx| {
        let due = cx.default_global::<HeldNotifications>().end(answered);
        for finished in &due {
            desktop::notify_turn_finished(finished, cx);
        }
    });
    let answer = answer.map_err(|e| {
        log::warn!("intents.ask: {e}");
        Failure::from_rpc(&e)
    })?;
    // Shown whatever came of it: the chat exists, and its answer (or the
    // reason there is none) is there.
    if open {
        let id = answer.chat_id.clone();
        cx.update(|cx| desktop::open_request(OpenRequest::Chat { id }, cx));
    }
    ask_outcome(&answer).map(Response::value)
}

/// Answer notifications while Ask Conduit waits. `turn.finished` can come
/// before the ask's reply names its chat, so every answer that finishes
/// meanwhile is held; once no ask waits, those of chats a shortcut was
/// given are dropped and the rest are posted.
#[derive(Debug, Default)]
pub struct HeldNotifications {
    asking: usize,
    held: Vec<TurnFinished>,
    answered: BTreeSet<String>,
}

impl Global for HeldNotifications {}

impl HeldNotifications {
    pub fn begin(&mut self) {
        self.asking += 1;
    }

    /// Holds `finished` while an ask waits; false when none does.
    pub fn hold(&mut self, finished: &TurnFinished) -> bool {
        if self.asking == 0 {
            return false;
        }
        self.held.push(finished.clone());
        true
    }

    /// An ask ended (`answered`: the chat whose answer the shortcut got).
    /// What to notify now: nothing until the last waiting ask ends.
    pub fn end(&mut self, answered: Option<String>) -> Vec<TurnFinished> {
        self.asking = self.asking.saturating_sub(1);
        self.answered.extend(answered);
        if self.asking > 0 {
            return vec![];
        }
        let answered = std::mem::take(&mut self.answered);
        std::mem::take(&mut self.held)
            .into_iter()
            .filter(|f| !answered.contains(&f.chat_id))
            .collect()
    }
}

/// Whether the answer notification for `finished` waits for an ask
/// ([`HeldNotifications`]); [`desktop`] asks before posting one.
pub fn hold_notification(finished: &TurnFinished, cx: &mut App) -> bool {
    cx.try_global::<HeldNotifications>().is_some()
        && cx.global_mut::<HeldNotifications>().hold(finished)
}

/// Open Chat's list, by id, search or recency.
async fn chats(
    ids: Vec<String>,
    query: Option<String>,
    cx: &mut AsyncApp,
) -> Result<Vec<ChatOut>, Failure> {
    let rpc = cx.update(|cx| cx.global::<AppState>().connection.read(cx).rpc());
    let query = IntentChatsQuery {
        ids,
        query: query.filter(|q| !q.trim().is_empty()),
        limit: CHAT_LIMIT,
    };
    let found = rpc
        .call::<methods::IntentsChats>(&query)
        .await
        .map_err(|e| {
            log::warn!("intents.chats: {e}");
            Failure::from_rpc(&e)
        })?;
    Ok(found
        .chats
        .into_iter()
        .map(|c| ChatOut {
            id: c.id,
            title: c.title,
        })
        .collect())
}

/// Start Voice Call: the widget's Voice Call link, then the call's
/// outcome. A call already on is shown and left on.
async fn start_voice_call(cx: &mut AsyncApp) -> Result<Response, Failure> {
    let call = cx.update(|cx| cx.global::<AppState>().stores.call.clone());
    let before = cx.update(|cx| call.read(cx).state().call);
    let was_on = cx.update(|cx| call.read(cx).is_active());
    cx.update(|cx| desktop::open_request(OpenRequest::VoiceCall, cx));
    if was_on {
        return Ok(Response::done());
    }
    // The link waits for the main window; the call answers "starting" at
    // once, then goes on or fails.
    let deadline = Instant::now() + READY_TIMEOUT;
    loop {
        let outcome = cx.update(|cx| {
            let store = call.read(cx);
            let state = store.state();
            let started = state.call != before;
            call_outcome(started, state.phase).map(|ok| {
                ok.map_err(|()| Failure::CallFailed {
                    reason: crate::views::chat::call::error_text(store, cx.l10n()),
                })
            })
        });
        match outcome {
            Some(result) => return result.map(|()| Response::done()),
            None if Instant::now() >= deadline => {
                let started = cx.update(|cx| call.read(cx).state().call != before);
                return at_deadline(started).map(|()| Response::done());
            }
            None => {
                cx.background_executor()
                    .timer(Duration::from_millis(100))
                    .await
            }
        }
    }
}

/// What a Start Voice Call came to: on (`Ok`), refused or failed (`Err`:
/// the call strip says why), or not yet known (None: not started, or still
/// starting). `started`: the call store has moved on to a new call since
/// the intent asked; a new call back at idle failed before it started (the
/// daemon could not open its chat). A call ended while it started, by the
/// user, counts as done.
fn call_outcome(started: bool, phase: CallPhase) -> Option<Result<(), ()>> {
    if !started {
        return None;
    }
    match phase {
        CallPhase::Error | CallPhase::Idle => Some(Err(())),
        CallPhase::Starting | CallPhase::Unknown => None,
        CallPhase::Listening
        | CallPhase::Sending
        | CallPhase::Speaking
        | CallPhase::Paused
        | CallPhase::Muted
        | CallPhase::Ending
        | CallPhase::Ended => Some(Ok(())),
    }
}

/// A Start Voice Call still unsettled when the wait ends: a call that
/// started and is still starting goes on from its strip; no call at all
/// (another chat took the window before the call could start in the new
/// one) is a failure, never a success.
fn at_deadline(started: bool) -> Result<(), Failure> {
    if started {
        Ok(())
    } else {
        Err(Failure::Unexpected)
    }
}

/// Waits for the daemon and the session's route.
async fn ready(cx: &mut AsyncApp) -> Result<(), Failure> {
    let deadline = Instant::now() + READY_TIMEOUT;
    loop {
        match cx.update(readiness) {
            Readiness::Ready => return Ok(()),
            Readiness::SignedOut => return Err(Failure::NeedsSignIn),
            Readiness::Waiting if Instant::now() >= deadline => return Err(Failure::NotReady),
            Readiness::Waiting => {
                cx.background_executor()
                    .timer(Duration::from_millis(100))
                    .await
            }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Readiness {
    Ready,
    SignedOut,
    Waiting,
}

fn readiness(cx: &mut App) -> Readiness {
    let Some(state) = cx.try_global::<AppState>() else {
        return Readiness::Waiting;
    };
    if !state.connection.read(cx).is_connected() {
        return Readiness::Waiting;
    }
    route_readiness(state.stores.session.read(cx).route(cx))
}

fn route_readiness(route: Route) -> Readiness {
    match route {
        Route::Main => Readiness::Ready,
        Route::Unknown => Readiness::Waiting,
        Route::Onboarding | Route::SignIn => Readiness::SignedOut,
    }
}

// ── Self-test (`--e2e intents`) ────────────────────────────────────────────

#[cfg(target_os = "macos")]
unsafe extern "C" {
    /// intents/SelfTest.swift: runs a script of intents and queries.
    fn conduit_intents_selftest(script: *const c_char, context: *mut c_void, done: ReplyFn);
}

/// Runs the Swift intents' own `perform()` and queries from a JSON script
/// (`{"steps": [...]}`), in this process, as Shortcuts would; the outcomes
/// as JSON. For `--e2e intents`, which can't drive Shortcuts itself.
#[cfg(target_os = "macos")]
pub async fn self_test(script: &serde_json::Value) -> Option<serde_json::Value> {
    use futures::channel::oneshot;

    unsafe extern "C" fn done(context: *mut c_void, json: *const c_char) {
        // SAFETY: `context` is the boxed sender made below, released here once.
        let sender = unsafe { Box::from_raw(context as *mut oneshot::Sender<String>) };
        let text = if json.is_null() {
            String::new()
        } else {
            // SAFETY: SelfTest.swift passes a NUL-terminated string.
            unsafe { CStr::from_ptr(json) }
                .to_string_lossy()
                .into_owned()
        };
        let _ = sender.send(text);
    }

    let (sender, receiver) = oneshot::channel::<String>();
    let script = std::ffi::CString::new(script.to_string()).ok()?;
    let context = Box::into_raw(Box::new(sender)) as *mut c_void;
    // SAFETY: `done` takes back the box exactly once.
    unsafe { conduit_intents_selftest(script.as_ptr(), context, done) };
    let text = receiver.await.ok()?;
    serde_json::from_str(&text).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The log keeps no chat title, no server words and no call reason:
    /// only which way the intent failed.
    #[test]
    fn a_failure_is_logged_without_what_it_carries() {
        for failure in [
            Failure::TimedOut {
                title: Some("Weekend hiking plan".into()),
            },
            Failure::AnswerFailed {
                detail: Some("quota of the hiking team exceeded".into()),
            },
            Failure::CallFailed {
                reason: "hiking microphone busy".into(),
            },
        ] {
            let line = failed_line(&failure);
            assert!(!line.contains("hiking"), "{line}");
            assert!(line.starts_with("intent failed: "), "{line}");
        }
        assert_eq!(
            failed_line(&Failure::TimedOut { title: None }),
            "intent failed: timed out"
        );
    }
    use std::sync::Arc;

    fn parse(json: &str) -> Request {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn reads_what_the_swift_intents_send() {
        assert_eq!(
            parse(r#"{"kind":"ask","prompt":"Hi","openInConduit":true}"#),
            Request::Ask {
                prompt: "Hi".into(),
                open_in_conduit: true
            }
        );
        assert_eq!(
            parse(r#"{"kind":"ask","prompt":"Hi"}"#),
            Request::Ask {
                prompt: "Hi".into(),
                open_in_conduit: false
            }
        );
        assert_eq!(
            parse(r#"{"kind":"newChat"}"#),
            Request::NewChat { prompt: None }
        );
        assert_eq!(
            parse(r#"{"kind":"openChat","id":"chat-1"}"#),
            Request::OpenChat {
                id: "chat-1".into()
            }
        );
        assert_eq!(
            parse(r#"{"kind":"startVoiceCall"}"#),
            Request::StartVoiceCall
        );
        assert_eq!(
            parse(r#"{"kind":"quickAsk","text":"x"}"#),
            Request::QuickAsk {
                text: Some("x".into())
            }
        );
        assert_eq!(
            parse(r#"{"kind":"chats","ids":["a"],"query":"q"}"#),
            Request::Chats {
                ids: vec!["a".into()],
                query: Some("q".into())
            }
        );
        assert_eq!(
            parse(r#"{"kind":"chats"}"#),
            Request::Chats {
                ids: vec![],
                query: None
            }
        );
        assert!(serde_json::from_str::<Request>(r#"{"kind":"deleteEverything"}"#).is_err());
    }

    #[test]
    fn replies_as_the_swift_bridge_reads_them() {
        assert_eq!(
            serde_json::to_string(&Response::value("Thyme.".into())).unwrap(),
            r#"{"ok":true,"value":"Thyme."}"#
        );
        assert_eq!(
            serde_json::to_string(&Response::failed("No.".into())).unwrap(),
            r#"{"ok":false,"error":"No."}"#
        );
        assert_eq!(
            serde_json::to_string(&Response::chats(vec![ChatOut {
                id: "c".into(),
                title: "T".into()
            }]))
            .unwrap(),
            r#"{"ok":true,"chats":[{"id":"c","title":"T"}]}"#
        );
        assert_eq!(
            serde_json::to_string(&Response::default()).unwrap(),
            r#"{"ok":false}"#
        );
    }

    #[test]
    fn a_reply_is_sent_once_even_when_dropped() {
        let sent = Arc::new(Mutex::new(vec![]));
        let reply = {
            let sent = sent.clone();
            Reply::new(move |r| sent.lock().unwrap().push(r))
        };
        reply.send(Response::done());
        let dropped = {
            let sent = sent.clone();
            Reply::new(move |r| sent.lock().unwrap().push(r))
        };
        drop(dropped);
        assert_eq!(
            *sent.lock().unwrap(),
            vec![Response::done(), Response::default()]
        );
    }

    fn answer(
        outcome: &str,
        text: &str,
        title: Option<&str>,
        detail: Option<&str>,
    ) -> IntentAnswer {
        IntentAnswer {
            chat_id: "c1".into(),
            message_id: "a1".into(),
            outcome: outcome.into(),
            text: text.into(),
            detail: detail.map(Into::into),
            title: title.map(Into::into),
        }
    }

    #[test]
    fn an_ask_reply_is_the_answer_or_where_it_will_be() {
        assert_eq!(
            ask_outcome(&answer("answered", "Thyme.", None, None)),
            Ok("Thyme.".into())
        );
        assert_eq!(
            ask_outcome(&answer("timedOut", "Th", Some("Herbs"), None)),
            Err(Failure::TimedOut {
                title: Some("Herbs".into())
            })
        );
        assert_eq!(
            ask_outcome(&answer("timedOut", "", Some("  "), None)),
            Err(Failure::TimedOut { title: None })
        );
        assert_eq!(
            ask_outcome(&answer("failed", "", None, Some("Needs a plan."))),
            Err(Failure::AnswerFailed {
                detail: Some("Needs a plan.".into())
            })
        );
        assert_eq!(
            ask_outcome(&answer("queued", "", None, None)),
            Err(Failure::Queued)
        );
        assert_eq!(
            ask_outcome(&answer("somethingNew", "", None, None)),
            Err(Failure::Unexpected)
        );
    }

    #[test]
    fn daemon_errors_become_words_the_user_can_act_on() {
        let with = |code: ErrorCode| RpcError::new(code);
        assert_eq!(
            Failure::from_rpc(&with(ErrorCode::Unauthenticated)),
            Failure::NeedsSignIn
        );
        assert_eq!(
            Failure::from_rpc(&with(ErrorCode::SessionExpired)),
            Failure::NeedsSignIn
        );
        assert_eq!(
            Failure::from_rpc(&with(ErrorCode::Offline)),
            Failure::Offline
        );
        assert_eq!(
            Failure::from_rpc(&with(ErrorCode::DaemonUnavailable)),
            Failure::NotReady
        );
        let mut refused = with(ErrorCode::ServerError);
        refused
            .args
            .insert("detail".into(), "This model needs a plan.".into());
        assert_eq!(
            Failure::from_rpc(&refused),
            Failure::AnswerFailed {
                detail: Some("This model needs a plan.".into())
            }
        );
        assert_eq!(
            Failure::from_rpc(&with(ErrorCode::Internal)),
            Failure::Unexpected
        );
    }

    #[test]
    fn every_failure_has_its_own_words_in_every_locale() {
        let failures = [
            Failure::NeedsSignIn,
            Failure::NotReady,
            Failure::EmptyQuestion,
            Failure::Offline,
            Failure::Queued,
            Failure::TimedOut {
                title: Some("Herbs".into()),
            },
            Failure::TimedOut { title: None },
            Failure::AnswerFailed {
                detail: Some("Needs a plan.".into()),
            },
            Failure::AnswerFailed { detail: None },
            Failure::ChatMissing,
            Failure::Unexpected,
        ];
        for locale in crate::l10n::LOCALES {
            let l = L10n::new(locale);
            let words: std::collections::BTreeSet<String> =
                failures.iter().map(|f| f.message(&l)).collect();
            assert_eq!(
                words.len(),
                failures.len(),
                "{locale}: two failures share words"
            );
        }
        let en = L10n::new("en");
        assert!(
            Failure::TimedOut {
                title: Some("Herbs".into())
            }
            .message(&en)
            .contains("Herbs")
        );
    }

    /// The words in the Swift intents, as the ARB keys write them:
    /// `\(\.$prompt)` is `{prompt}`, `\(.applicationName)` is
    /// `{applicationName}`. Only literals a person reads (capitals or
    /// spaces): not request kinds, SF Symbols or bare interpolations.
    fn swift_words() -> std::collections::BTreeSet<String> {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("intents");
        let mut words = std::collections::BTreeSet::new();
        for name in [
            "Bridge.swift",
            "ChatEntity.swift",
            "Intents.swift",
            "Shortcuts.swift",
        ] {
            let text = std::fs::read_to_string(dir.join(name)).unwrap();
            let mut rest = text.as_str();
            while let Some(start) = rest.find('"') {
                let after = &rest[start + 1..];
                let Some(end) = after.find('"') else {
                    break;
                };
                let literal = &after[..end];
                rest = &after[end + 1..];
                let words_in = literal
                    .replace("\\(.applicationName)", "{applicationName}")
                    .replace("\\(\\.$", "{")
                    .replace(')', "}");
                let readable = literal.contains(' ') || literal.starts_with(char::is_uppercase);
                if readable && !literal.starts_with("\\(") {
                    words.insert(words_in);
                }
            }
        }
        words
    }

    #[test]
    fn the_swift_intents_say_only_what_the_arb_keys_say() {
        use crate::l10n::{ACCESSORS, KEYS};
        let en = L10n::new("en");
        let swift = swift_words();
        // Titles, descriptions, fields, summaries, dialogs and phrases.
        assert_eq!(swift.len(), 32, "{swift:#?}");
        assert!(swift.contains("Ask Conduit {prompt}") && swift.contains("Call {applicationName}"));
        let ours = include_str!("intents.rs");
        let mut english = std::collections::BTreeSet::new();
        for (index, key) in KEYS.iter().enumerate() {
            if !key.starts_with("desktopIntent") {
                continue;
            }
            let text = en.message(index).to_string();
            let in_rust = ours.contains(&format!("{}(", ACCESSORS[index]));
            assert!(
                swift.contains(&text) || in_rust,
                "{key} ({text:?}) is neither in the Swift intents nor said here"
            );
            english.insert(text);
        }
        let unkeyed: Vec<_> = swift.difference(&english).collect();
        assert!(
            unkeyed.is_empty(),
            "Swift words with no desktopIntent* key: {unkeyed:?}"
        );
    }

    fn finished(chat: &str) -> TurnFinished {
        TurnFinished {
            chat_id: chat.into(),
            message_id: format!("{chat}-answer"),
            ok: true,
            code: None,
            queued: false,
        }
    }

    #[test]
    fn a_shortcuts_answer_gets_no_notification_and_others_still_do() {
        let mut held = HeldNotifications::default();
        // No ask waiting: nothing is held.
        assert!(!held.hold(&finished("before")));

        held.begin();
        held.begin();
        // Two asks wait; answers finish before either reply.
        assert!(held.hold(&finished("asked-1")));
        assert!(held.hold(&finished("typed")));
        assert!(held.hold(&finished("asked-2")));
        // The first ask ends: still one waiting, nothing posted yet.
        assert!(held.end(Some("asked-1".into())).is_empty());
        // The second ends: the typed chat's answer is posted, the asked ones
        // not.
        let due = held.end(Some("asked-2".into()));
        assert_eq!(due, vec![finished("typed")]);
        // A timed-out ask (no chat given) leaves its later answer alone.
        held.begin();
        assert!(held.end(None).is_empty());
        assert!(!held.hold(&finished("slow")));
    }

    #[test]
    fn start_voice_call_waits_for_the_call_to_be_on_or_refused() {
        // Before the link reached the call store: nothing to say yet.
        for phase in [CallPhase::Idle, CallPhase::Listening, CallPhase::Error] {
            assert_eq!(call_outcome(false, phase), None, "{phase:?}");
        }
        assert_eq!(call_outcome(true, CallPhase::Starting), None);
        assert_eq!(call_outcome(true, CallPhase::Listening), Some(Ok(())));
        assert_eq!(call_outcome(true, CallPhase::Ended), Some(Ok(())));
        // The core's refusal (no model, a backend that takes no calls)
        // ends the call in an error: the action fails with its words.
        assert_eq!(call_outcome(true, CallPhase::Error), Some(Err(())));
        assert_eq!(call_outcome(true, CallPhase::Idle), Some(Err(())));
        // At the end of the wait: a call still starting goes on from its
        // strip, but no call at all (another chat took the window first)
        // is no success.
        assert_eq!(at_deadline(true), Ok(()));
        assert_eq!(at_deadline(false), Err(Failure::Unexpected));
        let reason = "Choose a model before starting a voice call.".to_string();
        assert_eq!(
            Failure::CallFailed {
                reason: reason.clone()
            }
            .message(&L10n::new("en")),
            reason
        );
    }

    #[test]
    fn requests_wait_for_a_signed_in_session() {
        assert_eq!(route_readiness(Route::Main), Readiness::Ready);
        assert_eq!(route_readiness(Route::Unknown), Readiness::Waiting);
        assert_eq!(route_readiness(Route::Onboarding), Readiness::SignedOut);
        assert_eq!(route_readiness(Route::SignIn), Readiness::SignedOut);
    }
}
