//! A voice call (`calls.*`): the call the daemon runs, and this window's
//! part in it.
//!
//! * **The call.** The daemon runs it in the core's voice-mode controller,
//!   in the scope of its chat: when to listen, send, speak and listen again,
//!   barge-in, pause, mute, and a realtime voice when the backend offers
//!   one. `calls.changed` says where it is; every action is a `calls.*` call
//!   whose answer replaces what is shown.
//! * **The ears.** `calls.command` `listen` asks this window to listen as
//!   dictation does (Settings › Audio's engine and pause), through a
//!   [`DictationStore`] of the call's own: no recordings, the reading left
//!   alone, the microphone's voice processing on. Its words, meter and end
//!   go back as `calls.report`. With barge-in a listen goes on after each
//!   pause until the daemon stops it.
//! * **The realtime audio.** `calls.command` `audioStart` opens the voice's
//!   audio ([`crate::voice::realtime`]): the microphone and the voice on one
//!   echo-cancelled engine, over `WS /calls/{handle}`.
//! * **The speaker.** A Standard call's answers are spoken by the read-aloud
//!   engine ([`super::speech`]), which the daemon drives as it does a
//!   reading. While the call is on they play on the call's own engine
//!   ([`crate::voice::call_audio`]), whose microphone the ears hear through
//!   voice processing, so the answer is not heard back as the user's words
//!   when barge-in keeps listening through it.
//!
//! Minimising the call ([`CallStore::collapsed`]) is this window's own.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use conduit_protocol::{
    CallCommand, CallCommandKind, CallListenFailure, CallNotice, CallPhase, CallReport,
    CallReportKind, CallStart, CallState, NoParams, events, methods,
};
use futures::StreamExt as _;
use futures::channel::mpsc;
use gpui_kit::{
    App, AppContext as _, AsyncApp, Context, Entity, EventEmitter, Subscription, WeakEntity,
};

use super::Stores;
use super::connection::ConnectionStore;
use super::dictation::{DictationEvent, DictationStore, Notice, Target, microphone_allowed, on_io};
use super::rpc::Rpc;
use crate::l10n::ActiveL10n as _;
use crate::voice::InputOverride;
use crate::voice::realtime::{self, AudioCommand, AudioOut};

/// The events this store follows.
pub const EVENTS: &[&str] = &[events::CALLS_CHANGED, events::CALLS_COMMAND];

/// Emitted when the call changes (the strip, the menus, the menu-bar item).
pub struct CallChanged;

/// A listen the daemon asked for.
struct Listen {
    listen: i64,
    continuous: bool,
    model_id: Option<String>,
}

/// The realtime audio under way: its link to the daemon runs on the shared
/// runtime and owns the audio engine; aborting it stops both.
struct Realtime {
    link: tokio::task::JoinHandle<()>,
}

impl Drop for Realtime {
    fn drop(&mut self) {
        self.link.abort();
    }
}

/// What the E2E pass reads of the realtime audio.
#[derive(Default)]
pub struct AudioCounters {
    /// Microphone frames sent.
    pub frames: AtomicUsize,
    /// Speech buffers the voice sent.
    pub enqueued: AtomicUsize,
    /// Clears (the user talked over the voice).
    pub clears: AtomicUsize,
}

pub struct CallStore {
    rpc: Rpc,
    connection: Entity<ConnectionStore>,
    state: CallState,
    /// Minimised to its capsule (this window's choice).
    pub collapsed: bool,
    /// The call started a new chat, which the main window opens once the
    /// call's first turn has made it.
    pub follow_new: bool,
    ears: Entity<DictationStore>,
    listen: Option<Listen>,
    realtime: Option<Realtime>,
    /// The microphone's stand-in (dev builds).
    input: Option<InputOverride>,
    /// Stand-ins for the next listens, one each, the last one kept (the
    /// E2E pass: a recording, then silence).
    queued_inputs: std::collections::VecDeque<InputOverride>,
    /// Why the last listen could not go on, for the strip.
    pub failure: Option<CallListenFailure>,
    last_level: Option<Instant>,
    /// Ticks the clock while a call is on.
    _ticker: Option<gpui_kit::Task<()>>,
    _ears: Vec<Subscription>,
    /// For the E2E pass: listens asked for, words reported, the audio.
    pub listens: usize,
    pub said: Vec<String>,
    pub audio: Arc<AudioCounters>,
    /// Call states applied so far: a refresh's answer gives way to one
    /// applied after it was asked.
    applied: u64,
}

impl EventEmitter<CallChanged> for CallStore {}

impl CallStore {
    pub fn new(rpc: Rpc, connection: Entity<ConnectionStore>, cx: &mut Context<Self>) -> Self {
        let ears = {
            let connection = connection.clone();
            cx.new(|cx| DictationStore::for_call(connection, cx))
        };
        let subscriptions = vec![
            cx.subscribe(&ears, |this, _, event: &DictationEvent, cx| {
                this.on_ears(event, cx);
            }),
            cx.observe(&ears, |this, ears, cx| {
                let level = ears.read(cx).level;
                this.report_level(level, cx);
            }),
        ];
        Self {
            rpc,
            connection,
            state: CallState::default(),
            collapsed: false,
            follow_new: false,
            ears,
            listen: None,
            realtime: None,
            input: InputOverride::current(),
            queued_inputs: std::collections::VecDeque::new(),
            failure: None,
            last_level: None,
            _ticker: None,
            _ears: subscriptions,
            listens: 0,
            said: vec![],
            audio: Arc::new(AudioCounters::default()),
            applied: 0,
        }
    }

    // ---------------------------------------------------------------
    // What views read.

    pub fn state(&self) -> &CallState {
        &self.state
    }

    /// Whether a call is on (starting, listening, thinking, speaking,
    /// paused or muted).
    pub fn is_active(&self) -> bool {
        is_active(self.state.phase)
    }

    /// Whether the strip has something to show: a call on, or one that
    /// failed and has not been dismissed.
    pub fn is_shown(&self) -> bool {
        self.is_active() || self.state.phase == CallPhase::Error
    }

    /// The call's chat, once it has one.
    pub fn chat_id(&self) -> Option<&str> {
        self.state.chat_id.as_deref()
    }

    /// What stands in for the microphone from the next listen on (the E2E
    /// pass sets it; a release build never does).
    pub fn set_input(&mut self, input: Option<InputOverride>, cx: &mut Context<Self>) {
        self.input = input.clone();
        self.queued_inputs.clear();
        self.ears.update(cx, |e, _| e.set_input(input));
    }

    /// What the next listens hear, one each; the last one stays (the E2E
    /// pass: a recording, then silence).
    pub fn queue_inputs(&mut self, inputs: Vec<InputOverride>) {
        self.queued_inputs = inputs.into();
    }

    /// What stands in for the microphone now: the next queued, else the
    /// one set. A dev build's E2E pass sets one before any call, so the
    /// Mac's microphone (and its permission prompt) is never touched.
    fn stand_in(&self) -> Option<&InputOverride> {
        self.queued_inputs.front().or(self.input.as_ref())
    }

    /// Ends what the call is listening to now, as if nothing was heard, so
    /// the next stand-in plays (the E2E pass moves its script on).
    pub fn hear_next(&mut self, cx: &mut Context<Self>) {
        if self.listen.is_some() {
            self.ears.update(cx, |e, cx| e.cancel(cx));
        }
    }

    /// The next listen's stand-in, from the queue.
    fn take_input(&mut self, cx: &mut Context<Self>) {
        let next = if self.queued_inputs.len() > 1 {
            self.queued_inputs.pop_front()
        } else {
            self.queued_inputs.front().cloned()
        };
        if let Some(input) = next {
            self.input = Some(input.clone());
            self.ears.update(cx, |e, _| e.set_input(Some(input)));
        }
    }

    // ---------------------------------------------------------------
    // Actions.

    /// Starts a call in `chat_id` (a new chat when None) with `model`. A
    /// reading stops: the call owns the speaker.
    pub fn start(
        &mut self,
        chat_id: Option<String>,
        model: Option<String>,
        folder_id: Option<String>,
        temporary: bool,
        cx: &mut Context<Self>,
    ) {
        if self.is_active() {
            return;
        }
        self.failure = None;
        self.collapsed = false;
        self.follow_new = chat_id.is_none();
        if let Some(speech) = cx
            .try_global::<crate::AppState>()
            .map(|s| s.stores.speech.clone())
        {
            speech.update(cx, |s, cx| {
                if s.is_active() {
                    s.stop(cx);
                }
            });
        }
        let call = self.rpc.call::<methods::CallsStart>(&CallStart {
            chat_id,
            model,
            folder_id,
            temporary,
        });
        self.adopt(call, None, cx);
    }

    pub fn end(&mut self, cx: &mut Context<Self>) {
        if self.state.phase == CallPhase::Error {
            // Dismissed.
            self.state = CallState {
                call: self.state.call,
                ..CallState::default()
            };
            self.failure = None;
            cx.emit(CallChanged);
            cx.notify();
            return;
        }
        let call = self.rpc.call::<methods::CallsEnd>(&NoParams {});
        self.adopt(call, None, cx);
    }

    /// Pause, or Resume when paused or muted.
    pub fn toggle_pause(&mut self, cx: &mut Context<Self>) {
        if self.state.can_resume && !self.state.muted {
            let call = self.rpc.call::<methods::CallsResume>(&NoParams {});
            self.adopt(call, None, cx);
        } else if self.state.can_pause {
            let call = self.rpc.call::<methods::CallsPause>(&NoParams {});
            self.adopt(call, None, cx);
        }
    }

    pub fn toggle_mute(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::CallsMute>(&NoParams {});
        self.adopt(call, None, cx);
    }

    /// Stops the answer being said and listens again.
    pub fn skip(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::CallsSkip>(&NoParams {});
        self.adopt(call, None, cx);
    }

    pub fn toggle_collapsed(&mut self, cx: &mut Context<Self>) {
        self.collapsed = !self.collapsed;
        cx.emit(CallChanged);
        cx.notify();
    }

    /// The call now (on connecting, or after events were lost): the
    /// daemon's answer is its present call, applied whatever number the
    /// window last saw, since a restarted daemon numbers calls from 0 again,
    /// unless a call state came in while it was asked (that one is newer).
    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::CallsGet>(&NoParams {});
        self.adopt(call, Some(self.applied), cx);
    }

    fn adopt(
        &mut self,
        call: impl std::future::Future<Output = Result<CallState, conduit_daemon::RpcError>> + 'static,
        present: Option<u64>,
        cx: &mut Context<Self>,
    ) {
        cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut AsyncApp| match call.await {
                Ok(state) => {
                    let _ = this.update(cx, |s, cx| {
                        if let Some(asked) = present {
                            // Events and replies are taken by different
                            // tasks: a state applied since the request is
                            // newer than this answer.
                            if s.applied != asked {
                                return;
                            }
                            s.state.call = s.state.call.min(state.call);
                        }
                        s.apply(state, cx)
                    });
                }
                Err(e) => {
                    log::warn!("calls: {e}");
                    let _ = this.update(cx, |_, cx| {
                        let text = cx.l10n().voice_call_failed();
                        if let Some(toasts) = cx
                            .try_global::<crate::AppState>()
                            .map(|s| s.stores.toasts.clone())
                        {
                            toasts.update(cx, |t, cx| {
                                t.show(conduit_protocol::NoticeLevel::Error, text, cx)
                            });
                        }
                    });
                }
            },
        )
        .detach();
    }

    fn apply(&mut self, state: CallState, cx: &mut Context<Self>) {
        // An answer about an older call than the one shown changes nothing.
        if state.call < self.state.call {
            return;
        }
        self.applied += 1;
        let was_active = self.is_active();
        // A notice mid-call (words that could not be made out, a reply cut
        // short): said once, as the phone's snack bar says it.
        let noticed = state.call == self.state.call && state.notice_count > self.state.notice_count;
        if let Some(notice) = state.notice.filter(|_| noticed) {
            let l10n = cx.l10n();
            let text = match notice {
                CallNotice::TranscriptionFailed => l10n.voice_call_notice_transcription_failed(),
                CallNotice::ReplyIncomplete => l10n.voice_call_notice_reply_incomplete(),
                CallNotice::TranscriptNotSaved => l10n.voice_call_notice_transcript_not_saved(),
                CallNotice::Unknown => String::new(),
            };
            if !text.is_empty()
                && let Some(toasts) = cx
                    .try_global::<crate::AppState>()
                    .map(|s| s.stores.toasts.clone())
            {
                toasts.update(cx, |t, cx| {
                    t.show(conduit_protocol::NoticeLevel::Info, text, cx)
                });
            }
        }
        if state.phase != self.state.phase || state.call != self.state.call {
            log::info!("call {}: {:?} ({:?})", state.call, state.phase, state.mode);
        }
        self.state = state;
        // A Standard call's engine, for what it says and hears; a realtime
        // call has its own.
        if self.is_active()
            && self.realtime.is_none()
            && self.state.mode != Some(conduit_protocol::CallMode::Realtime)
        {
            crate::voice::call_audio::begin(crate::shell::speech_engine::muted());
        }
        if self.is_active() && self._ticker.is_none() {
            // The strip's clock and the menu-bar item's time.
            self._ticker = Some(cx.spawn(
                async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                    loop {
                        cx.background_executor().timer(Duration::from_secs(1)).await;
                        let on = this
                            .update(cx, |s, cx| {
                                cx.emit(CallChanged);
                                cx.notify();
                                s.is_active()
                            })
                            .unwrap_or(false);
                        if !on {
                            break;
                        }
                    }
                },
            ));
        }
        if !self.is_active() {
            self._ticker = None;
            if self.state.phase != CallPhase::Error {
                self.follow_new = false;
            }
            // Over: the ears and the audio go with it.
            self.stop_listening(cx);
            self.realtime = None;
            crate::voice::call_audio::end();
            if was_active {
                self.collapsed = false;
            }
        }
        cx.emit(CallChanged);
        cx.notify();
    }

    // ---------------------------------------------------------------
    // The daemon's commands.

    fn on_command(&mut self, command: CallCommand, cx: &mut Context<Self>) {
        log::info!(
            "call command {:?} (listen {})",
            command.kind,
            command.listen
        );
        match command.kind {
            CallCommandKind::Permission => {
                let rpc = self.rpc.clone();
                let file = matches!(self.stand_in(), Some(InputOverride::File(_)));
                let denied = matches!(self.stand_in(), Some(InputOverride::Denied));
                cx.spawn(async move |_, _| {
                    let granted = !denied && (file || microphone_allowed().await);
                    report(
                        &rpc,
                        CallReport {
                            id: Some(command.id),
                            value: Some(granted),
                            ..Default::default()
                        },
                    )
                    .await;
                })
                .detach();
            }
            CallCommandKind::Listen => {
                self.listens += 1;
                self.listen = Some(Listen {
                    listen: command.listen,
                    continuous: command.continuous,
                    model_id: command.model_id,
                });
                self.failure = None;
                self.hear_on_call_engine();
                self.listen_again(cx);
            }
            CallCommandKind::StopListen => {
                if self
                    .listen
                    .as_ref()
                    .is_some_and(|l| l.listen == command.listen)
                {
                    self.stop_listening(cx);
                }
            }
            CallCommandKind::AudioStart => self.start_audio(command, cx),
            CallCommandKind::AudioStop => {
                self.realtime = None;
            }
            // A newer daemon's: nothing this window can do.
            CallCommandKind::Unknown => {}
        }
    }

    // ---------------------------------------------------------------
    // The ears.

    fn listen_again(&mut self, cx: &mut Context<Self>) {
        let Some(listen) = self.listen.as_ref() else {
            return;
        };
        let target = Target {
            chat_id: self.state.chat_id.clone(),
            folder_id: None,
            model_id: listen.model_id.clone(),
            keeps_recordings: false,
        };
        self.take_input(cx);
        self.ears.update(cx, |e, cx| {
            e.set_target(target, cx);
            e.start(cx);
        });
    }

    /// The call's engine takes the microphone (voice processing on) for
    /// the ears, so what the call says there is not heard back. Never with
    /// a stand-in, nor before the microphone is allowed: the ears then open
    /// their own, as dictation does.
    fn hear_on_call_engine(&self) {
        if self.stand_in().is_some() {
            return;
        }
        #[cfg(target_os = "macos")]
        if crate::voice::mac::microphone() != crate::voice::mac::Permission::Granted {
            return;
        }
        if let Some(audio) = crate::voice::call_audio::current()
            && let Err(e) = audio.want_microphone()
        {
            log::warn!("call audio: no microphone on the call's engine: {e}");
        }
    }

    fn stop_listening(&mut self, cx: &mut Context<Self>) {
        if self.listen.take().is_some() {
            self.ears.update(cx, |e, cx| e.cancel(cx));
        }
    }

    fn on_ears(&mut self, event: &DictationEvent, cx: &mut Context<Self>) {
        let Some(listen) = self.listen.as_ref() else {
            return;
        };
        let id = listen.listen;
        match event {
            DictationEvent::Text { text, done } => {
                if *done {
                    self.said.push(text.clone());
                }
                self.send(
                    CallReport {
                        kind: Some(CallReportKind::Words),
                        listen: id,
                        text: Some(text.clone()),
                        done: *done,
                        ..Default::default()
                    },
                    cx,
                );
            }
            DictationEvent::Ended { .. } => {
                let notice = self.ears.read(cx).notice.clone();
                let failure = notice.as_ref().and_then(failure_of);
                if let Some(failure) = failure {
                    // Listening cannot go on: the call says why.
                    self.failure = Some(failure);
                    self.listen = None;
                    self.send(
                        CallReport {
                            kind: Some(CallReportKind::Failed),
                            listen: id,
                            failure: Some(failure),
                            ..Default::default()
                        },
                        cx,
                    );
                    cx.notify();
                    return;
                }
                if listen.continuous && self.is_active() {
                    // Barge-in: the next utterance, in the same listen.
                    self.take_input(cx);
                    let ears = self.ears.clone();
                    cx.defer(move |cx| ears.update(cx, |e, cx| e.start(cx)));
                    return;
                }
                self.listen = None;
                self.send(
                    CallReport {
                        kind: Some(CallReportKind::Ended),
                        listen: id,
                        ..Default::default()
                    },
                    cx,
                );
            }
            DictationEvent::Heard | DictationEvent::Transcribed(_) => {}
        }
    }

    fn report_level(&mut self, level: f32, cx: &mut Context<Self>) {
        let Some(listen) = self.listen.as_ref() else {
            return;
        };
        let now = Instant::now();
        if self
            .last_level
            .is_some_and(|t| now.duration_since(t) < Duration::from_millis(100))
        {
            return;
        }
        self.last_level = Some(now);
        let id = listen.listen;
        self.send(
            CallReport {
                kind: Some(CallReportKind::Level),
                listen: id,
                level: Some(f64::from(level)),
                ..Default::default()
            },
            cx,
        );
    }

    fn send(&self, report_: CallReport, cx: &mut Context<Self>) {
        let rpc = self.rpc.clone();
        cx.spawn(async move |_, _| report(&rpc, report_).await)
            .detach();
    }

    // ---------------------------------------------------------------
    // The realtime audio.

    fn start_audio(&mut self, command: CallCommand, cx: &mut Context<Self>) {
        self.realtime = None;
        // A realtime call: its own engine has the microphone and the voice.
        crate::voice::call_audio::end();
        let rpc = self.rpc.clone();
        let Some(path) = command.path.clone() else {
            return;
        };
        let http = self.connection.read(cx).http().cloned();
        let input = self.stand_in().cloned();
        let muted = crate::shell::speech_engine::muted();
        let counters = self.audio.clone();
        let id = command.id;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let fail = |error: String| CallReport {
                id: Some(id),
                ok: false,
                error: Some(error),
                ..Default::default()
            };
            if input.is_none() && !microphone_allowed().await {
                report(&rpc, fail("The microphone is not allowed.".into())).await;
                return;
            }
            let Some(http) = http else {
                report(&rpc, fail("not connected".into())).await;
                return;
            };
            let (out_tx, mut out_rx) = mpsc::unbounded::<AudioOut>();
            let handle = realtime::spawn(realtime::devices(input, muted), out_tx);
            let latency = match out_rx.next().await {
                Some(AudioOut::Started { latency_ms }) => latency_ms,
                Some(AudioOut::Failure(e)) => {
                    report(&rpc, fail(e)).await;
                    return;
                }
                _ => {
                    report(&rpc, fail("the audio did not start".into())).await;
                    return;
                }
            };
            let socket = on_io(async move { http.websocket(&path).await }).await;
            let socket = match socket {
                Some(Ok(socket)) => socket,
                Some(Err(e)) => {
                    report(&rpc, fail(e.to_string())).await;
                    return;
                }
                None => {
                    report(&rpc, fail("dropped".into())).await;
                    return;
                }
            };
            let link = conduit_daemon::runtime::shared()
                .spawn(run_link(socket, handle, out_rx, latency, counters));
            let kept = this
                .update(cx, |s, _| {
                    s.realtime = Some(Realtime { link });
                    s.is_active()
                })
                .unwrap_or(false);
            if kept {
                report(
                    &rpc,
                    CallReport {
                        id: Some(id),
                        ..Default::default()
                    },
                )
                .await;
            } else {
                // Over meanwhile.
                let _ = this.update(cx, |s, _| s.realtime = None);
            }
        })
        .detach();
    }
}

/// The realtime audio's link: the microphone's frames and the engine's
/// reports go to the daemon, its commands to the engine. Owns the engine,
/// which stops with it.
async fn run_link(
    socket: conduit_daemon::http::DaemonSocket,
    handle: realtime::AudioHandle,
    mut out: mpsc::UnboundedReceiver<AudioOut>,
    latency_ms: u64,
    counters: Arc<AudioCounters>,
) {
    use conduit_daemon::http::SocketMessage as Message;
    use futures::SinkExt as _;

    let (mut sink, mut stream) = socket.split();
    let started = serde_json::json!({"type": "started", "latencyMs": latency_ms});
    if sink.send(Message::text(started.to_string())).await.is_err() {
        return;
    }
    loop {
        tokio::select! {
            next = out.next() => {
                let message = match next {
                    None => break,
                    Some(AudioOut::Frame(frame)) => {
                        counters.frames.fetch_add(1, Ordering::Relaxed);
                        Message::binary(frame)
                    }
                    Some(AudioOut::Started { .. }) => continue,
                    Some(other) => Message::text(json_of(other).to_string()),
                };
                if sink.send(message).await.is_err() {
                    break;
                }
            }
            incoming = stream.next() => {
                let Some(Ok(message)) = incoming else { break };
                let Message::Text(text) = message else { continue };
                let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
                    continue;
                };
                match command_of(&value) {
                    Some(AudioCommand::Stop) => break,
                    Some(command) => {
                        match &command {
                            AudioCommand::Enqueue { .. } => {
                                counters.enqueued.fetch_add(1, Ordering::Relaxed);
                            }
                            AudioCommand::Clear(_) => {
                                counters.clears.fetch_add(1, Ordering::Relaxed);
                            }
                            _ => {}
                        }
                        handle.send(command);
                    }
                    None => {}
                }
            }
        }
    }
    drop(handle);
    let _ = sink.close().await;
}

/// A daemon message as an engine command.
fn command_of(value: &serde_json::Value) -> Option<AudioCommand> {
    let text = |key: &str| value.get(key).and_then(|v| v.as_str()).map(str::to_string);
    let flag = |key: &str| value.get(key).and_then(|v| v.as_bool()).unwrap_or(false);
    match value.get("type")?.as_str()? {
        "capture" => Some(AudioCommand::Capture(flag("enabled"))),
        "enqueue" => {
            use base64::Engine as _;
            let pcm = base64::engine::general_purpose::STANDARD
                .decode(text("pcm")?)
                .ok()?;
            Some(AudioCommand::Enqueue {
                response_id: text("responseId")?,
                item_id: text("itemId")?,
                content_index: value.get("contentIndex")?.as_i64()?,
                pcm: realtime::samples_of(&pcm),
            })
        }
        "end" => Some(AudioCommand::End(text("responseId")?)),
        "hold" => Some(AudioCommand::Hold(flag("paused"))),
        "clear" => Some(AudioCommand::Clear(value.get("clearId")?.as_i64()?)),
        "stop" => Some(AudioCommand::Stop),
        _ => None,
    }
}

/// What the engine says, as the daemon reads it.
fn json_of(out: AudioOut) -> serde_json::Value {
    use serde_json::json;
    match out {
        AudioOut::Report {
            clear_id,
            playback_active,
            queued_samples,
            received_samples,
            input_level,
            output_level,
        } => json!({
            "type": "report",
            "clearId": clear_id,
            "playbackActive": playback_active,
            "queuedSamples": queued_samples,
            "receivedSamples": received_samples,
            "inputLevel": input_level,
            "outputLevel": output_level,
        }),
        AudioOut::Cleared { clear_id, items } => json!({
            "type": "cleared",
            "clearId": clear_id,
            "items": items.iter().map(|i| json!({
                "responseId": i.response_id,
                "itemId": i.item_id,
                "contentIndex": i.content_index,
                "samples": i.samples,
            })).collect::<Vec<_>>(),
        }),
        AudioOut::Failure(message) => json!({"type": "failure", "message": message}),
        AudioOut::Started { latency_ms } => json!({"type": "started", "latencyMs": latency_ms}),
        AudioOut::Frame(_) => json!({}),
    }
}

async fn report(rpc: &Rpc, report: CallReport) {
    if let Err(e) = rpc.call::<methods::CallsReport>(&report).await {
        log::warn!("calls.report: {e}");
    }
}

/// Whether `phase` is a call that is on.
pub fn is_active(phase: CallPhase) -> bool {
    !matches!(phase, CallPhase::Idle | CallPhase::Ended | CallPhase::Error)
}

/// A dictation notice as a failed listen; None for one that only means
/// nothing usable was heard (the call listens again).
fn failure_of(notice: &Notice) -> Option<CallListenFailure> {
    match notice {
        Notice::MicrophoneDenied => Some(CallListenFailure::MicrophoneDenied),
        Notice::SpeechDenied => Some(CallListenFailure::SpeechDenied),
        Notice::NotOnThisMac(_) => Some(CallListenFailure::NotOnThisMac),
        Notice::ServerUnavailable => Some(CallListenFailure::ServerUnavailable),
        Notice::WhisperNeedsModel => Some(CallListenFailure::WhisperNeedsModel),
        Notice::TranscriptionFailed(_)
        | Notice::SaveFailed
        | Notice::ExportFailed
        | Notice::DiscardFailed => None,
    }
}

pub fn wire(stores: &Stores, cx: &mut App) {
    stores
        .connection
        .update(cx, |c, _| c.subscribe("calls", EVENTS, vec![]));
    let s = stores.call.clone();
    cx.subscribe(&stores.connection, move |_, event, cx| {
        use super::connection::ConnectionEvent;
        match event {
            ConnectionEvent::Connected { .. } | ConnectionEvent::Gap => {
                s.update(cx, |s, cx| s.refresh(cx));
            }
            ConnectionEvent::Daemon(event) => match event.as_ref() {
                conduit_protocol::Event::CallsChanged(state) => {
                    let state = state.clone();
                    s.update(cx, |s, cx| s.apply(state, cx));
                }
                conduit_protocol::Event::CallsCommand(command) => {
                    let command = command.clone();
                    s.update(cx, |s, cx| s.on_command(command, cx));
                }
                _ => {}
            },
            ConnectionEvent::LocalDataReset { .. } => {}
        }
    })
    .detach();
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A call that started while the refresh was out stays: the refresh's
    /// older answer is not applied over it.
    #[gpui_kit::test]
    fn a_call_seen_after_a_refresh_was_asked_stays(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        let state =
            |json: serde_json::Value| -> CallState { serde_json::from_value(json).unwrap() };
        daemon.returns::<methods::CallsGet>(state(serde_json::json!({"phase": "idle", "call": 4})));
        let held = daemon.hold::<methods::CallsGet>();
        stores.call.update(vcx, |c, cx| c.refresh(cx));
        vcx.run_until_parked();
        // The next call's event comes before the refresh's answer is taken.
        let on = state(serde_json::json!({
            "phase": "listening", "call": 5, "mode": "realtime", "chatId": "c1"
        }));
        stores.call.update(vcx, |c, cx| c.apply(on, cx));
        drop(held);
        vcx.run_until_parked();
        assert!(
            stores.call.read_with(vcx, |c, _| c.is_active()),
            "the refresh's older answer ended the call"
        );
    }

    /// A restarted daemon numbers its calls from 0 again: its first answer
    /// is the call now, whatever the last daemon numbered.
    #[gpui_kit::test]
    fn a_restarted_daemon_ends_the_last_ones_call(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        let state =
            |json: serde_json::Value| -> CallState { serde_json::from_value(json).unwrap() };
        let on = state(serde_json::json!({
            "phase": "listening", "call": 4, "mode": "realtime", "chatId": "c1"
        }));
        stores.call.update(vcx, |c, cx| c.apply(on, cx));
        assert!(stores.call.read_with(vcx, |c, _| c.is_active()));
        daemon.returns::<methods::CallsGet>(state(serde_json::json!({"phase": "idle", "call": 0})));
        stores.call.update(vcx, |c, cx| c.refresh(cx));
        vcx.run_until_parked();
        assert!(
            !stores.call.read_with(vcx, |c, _| c.is_active()),
            "the last daemon's call stayed on"
        );
        daemon.returns::<methods::CallsStart>(state(serde_json::json!({
            "phase": "starting", "call": 1, "mode": "realtime"
        })));
        stores
            .call
            .update(vcx, |c, cx| c.start(None, None, None, false, cx));
        vcx.run_until_parked();
        assert!(
            stores.call.read_with(vcx, |c, _| c.is_active()),
            "a new call never showed"
        );
    }

    #[test]
    fn the_daemon_messages_become_engine_commands() {
        use serde_json::json;
        assert_eq!(
            command_of(&json!({"type": "capture", "enabled": true})),
            Some(AudioCommand::Capture(true))
        );
        assert_eq!(
            command_of(&json!({
                "type": "enqueue", "responseId": "r", "itemId": "i",
                "contentIndex": 0, "pcm": "AQD//w=="
            })),
            Some(AudioCommand::Enqueue {
                response_id: "r".into(),
                item_id: "i".into(),
                content_index: 0,
                pcm: vec![1, -1],
            })
        );
        assert_eq!(
            command_of(&json!({"type": "clear", "clearId": 3})),
            Some(AudioCommand::Clear(3))
        );
        assert_eq!(command_of(&json!({"type": "nonsense"})), None);
        let cleared = json_of(AudioOut::Cleared {
            clear_id: 3,
            items: vec![realtime::Rendered {
                response_id: "r".into(),
                item_id: "i".into(),
                content_index: 0,
                samples: 480,
            }],
        });
        assert_eq!(cleared["items"][0]["samples"], 480);
    }

    #[test]
    fn only_lasting_problems_end_a_listen() {
        assert_eq!(
            failure_of(&Notice::MicrophoneDenied),
            Some(CallListenFailure::MicrophoneDenied)
        );
        assert_eq!(failure_of(&Notice::TranscriptionFailed(None)), None);
        assert!(is_active(CallPhase::Paused));
        assert!(!is_active(CallPhase::Error));
    }
}
