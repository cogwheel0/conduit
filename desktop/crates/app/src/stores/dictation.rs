//! Dictation for one text field (the composer's; a note's editor and a
//! call can hold their own): listens with the engine Settings › Audio
//! chose, shows how it goes, and hands the words over as
//! [`DictationEvent`]s.
//!
//! * **Engines** (`dictation.status` says which, and what each can do for
//!   the chat's model): this Mac's recognizer, on-device, with words as
//!   they are said; the chat's own backend (`POST /transcribe` with the
//!   model, so an Open WebUI server, the Voice Provider, a Hermes gateway
//!   or a LibreChat server); or whisper in the daemon.
//! * **The pause** ends it ([`crate::voice::vad`], Settings › Audio's
//!   silence duration); Stop ends it now; Cancel (Esc) drops it.
//! * **Permissions:** the microphone, and for this Mac's recognizer speech
//!   recognition, are asked for on first use; a refusal says what to do and
//!   offers System Settings ([`Notice`]).
//! * **Recordings**, as the phone keeps them: the audio goes to the
//!   daemon a second at a time (`recordings.append`, committed to the
//!   account's database as it comes), so a crash or a relaunch loses none.
//!   The draft's recordings are listed with the composer until it is sent;
//!   each can be transcribed on the server or on this Mac, exported, or
//!   discarded. A temporary chat keeps none.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use base64::Engine as _;
use conduit_daemon::RpcError;
use conduit_daemon::http::HttpClient;
use conduit_protocol::{
    DictationStatus, DictationTarget, RecordingChunk, RecordingDto, RecordingRef, RecordingTarget,
    RecordingTranscribe, VoiceTranscript, methods,
};
use futures::StreamExt as _;
use gpui_kit::{App, AsyncApp, Context, Entity, EventEmitter, Task, WeakEntity};

use super::connection::ConnectionStore;
use super::rpc::Rpc;
use crate::voice::{self, EndReason, InputError, InputOverride, SessionError, SessionEvent};

/// Which draft dictation is for, and with which model.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Target {
    pub chat_id: Option<String>,
    pub folder_id: Option<String>,
    pub model_id: Option<String>,
    /// The draft keeps recordings (not a temporary chat, not Quick Ask).
    pub keeps_recordings: bool,
}

impl Target {
    fn recordings(&self) -> RecordingTarget {
        RecordingTarget {
            chat_id: self.chat_id.clone(),
            folder_id: self.folder_id.clone(),
        }
    }

    fn same_draft(&self, other: &Target) -> bool {
        self.chat_id == other.chat_id
            && self.folder_id == other.folder_id
            && self.keeps_recordings == other.keeps_recordings
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Phase {
    Idle,
    /// Asking for permission, or opening the input.
    Starting,
    Listening {
        since: Instant,
    },
    /// The server or whisper is turning what was said into text.
    Transcribing,
}

/// What went wrong, or needs the user, shown with the composer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Notice {
    /// The microphone is refused (or there is none): System Settings.
    MicrophoneDenied,
    /// This Mac's recognizer is refused: System Settings.
    SpeechDenied,
    /// This Mac cannot recognize the language on its own.
    NotOnThisMac(String),
    /// The chat's backend does not transcribe.
    ServerUnavailable,
    /// Whisper is chosen but has no model yet.
    WhisperNeedsModel,
    /// A recording's transcription failed; the recording is kept.
    TranscriptionFailed(Option<String>),
    /// The audio could not be saved as it came.
    SaveFailed,
    ExportFailed,
    DiscardFailed,
}

impl Notice {
    /// Where System Settings shows the permission this notice is about.
    pub fn settings_url(&self) -> Option<&'static str> {
        match self {
            Self::MicrophoneDenied => {
                Some("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            }
            Self::SpeechDenied => Some(
                "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
            ),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum DictationEvent {
    /// The words so far for the text field (`done`: the last of them).
    Text { text: String, done: bool },
    /// A saved recording's transcription, to add to the text.
    Transcribed(String),
    /// Listening stopped and the server or whisper has what was said: the
    /// field is no longer listening.
    Heard,
    /// Listening ended; `restore`: put the text back as it was (Cancel).
    Ended { restore: bool },
}

/// The recording of the dictation under way.
struct Active {
    /// None until `recordings.begin` answers, and for a draft that keeps
    /// none.
    id: Option<String>,
    stored: bool,
    /// Audio waiting for the id.
    waiting: VecDeque<Vec<u8>>,
    /// Keep the audio when the dictation is cancelled (another chat was
    /// opened: what was said stays with the draft it was said for).
    keep: bool,
    /// The draft it is for (the composer may have moved on).
    target: Target,
}

pub struct DictationStore {
    rpc: Rpc,
    connection: Option<Entity<ConnectionStore>>,
    /// The microphone's stand-in (dev builds).
    input: Option<InputOverride>,
    pub phase: Phase,
    /// The meter, 0..1.
    pub level: f32,
    /// The engine of the dictation under way, or the last one.
    pub engine: String,
    pub status: Option<DictationStatus>,
    pub notice: Option<Notice>,
    target: Target,
    /// The account the draft is in (the composer's scope): another
    /// account's new chat is another draft, though its ids are the same.
    scope: u64,
    session: Option<voice::Session>,
    active: Option<Active>,
    generation: u64,
    /// The draft's saved recordings, oldest first.
    pub recordings: Vec<RecordingDto>,
    /// The recording being transcribed or exported.
    pub busy: Option<String>,
    /// Recordings a message took with it ([`Self::sent`]), by hold, with
    /// their draft: discarded once the message is taken, listed again if
    /// it is refused ([`Self::send_settled`]).
    held: Vec<(u64, Target, Vec<String>)>,
    next_held: u64,
    /// How the last dictation ended.
    pub last_end: Option<EndReason>,
    /// A voice call's listening ([`Self::for_call`]): the microphone's
    /// voice processing on, a reading left alone (the call's own answer),
    /// and nothing heard said by the call, not a toast.
    call: bool,
    _run: Option<Task<()>>,
    _list: Option<Task<()>>,
    _busy: Option<Task<()>>,
}

impl EventEmitter<DictationEvent> for DictationStore {}

/// The pause the daemon would send, until `dictation.status` answers.
const DEFAULT_PAUSE_MS: u32 = 2_000;

impl DictationStore {
    pub fn new(rpc: Rpc, connection: Option<Entity<ConnectionStore>>) -> Self {
        Self {
            rpc,
            connection,
            input: InputOverride::current(),
            phase: Phase::Idle,
            level: 0.0,
            engine: "device".into(),
            status: None,
            notice: None,
            target: Target::default(),
            scope: 0,
            session: None,
            active: None,
            generation: 0,
            recordings: vec![],
            busy: None,
            held: vec![],
            next_held: 0,
            last_end: None,
            call: false,
            _run: None,
            _list: None,
            _busy: None,
        }
    }

    /// For the app: the daemon of `connection`.
    pub fn for_connection(connection: Entity<ConnectionStore>, cx: &App) -> Self {
        let rpc = connection.read(cx).rpc();
        Self::new(rpc, Some(connection))
    }

    /// A voice call's ears ([`crate::stores::call`]): it keeps no
    /// recordings, leaves the call's spoken answer alone, says nothing of
    /// its own when nothing was heard, and listens through the microphone's
    /// voice processing.
    pub fn for_call(connection: Entity<ConnectionStore>, cx: &App) -> Self {
        let mut store = Self::for_connection(connection, cx);
        store.call = true;
        store
    }

    /// What stands in for the microphone from the next dictation on (the
    /// E2E pass changes it between steps; a release build never sets one).
    pub fn set_input(&mut self, input: Option<InputOverride>) {
        self.input = input;
    }

    pub fn is_listening(&self) -> bool {
        matches!(self.phase, Phase::Listening { .. } | Phase::Starting)
    }

    pub fn is_active(&self) -> bool {
        self.phase != Phase::Idle
    }

    /// The recording made by the dictation under way, if it is listed.
    pub fn active_recording(&self) -> Option<&str> {
        self.active.as_ref().and_then(|a| a.id.as_deref())
    }

    fn http(&self, cx: &App) -> Option<HttpClient> {
        self.connection
            .as_ref()
            .and_then(|c| c.read(cx).http().cloned())
    }

    // ── The draft ──────────────────────────────────────────────────────

    /// The composer now holds `target`'s draft. Its recordings are read;
    /// a dictation for another draft stops, its audio kept for that one.
    pub fn set_target(&mut self, target: Target, cx: &mut Context<Self>) {
        self.set_target_in(self.scope, target, cx);
    }

    /// [`Self::set_target`] for a draft of account scope `scope`: another
    /// account's draft is another draft, whatever its ids.
    pub fn set_target_in(&mut self, scope: u64, target: Target, cx: &mut Context<Self>) {
        let same = self.scope == scope && self.target.same_draft(&target);
        let model_changed = self.target.model_id != target.model_id;
        self.scope = scope;
        self.target = target;
        if same {
            if model_changed {
                cx.notify();
            }
            return;
        }
        if self.is_active() {
            if let Some(active) = self.active.as_mut() {
                active.keep = true;
            }
            // The field now holds the other draft: no more words go into
            // it from this dictation.
            cx.emit(DictationEvent::Ended { restore: false });
            self.cancel(cx);
        }
        self.notice = None;
        self.recordings.clear();
        self.busy = None;
        self._busy = None;
        self.refresh_recordings(cx);
        cx.notify();
    }

    /// Reads the draft's recordings again.
    pub fn refresh_recordings(&mut self, cx: &mut Context<Self>) {
        if !self.target.keeps_recordings {
            self.recordings.clear();
            self._list = None;
            cx.notify();
            return;
        }
        let call = self
            .rpc
            .call::<methods::RecordingsList>(&self.target.recordings());
        let target = self.target.clone();
        self._list = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    if !s.target.same_draft(&target) {
                        return;
                    }
                    match result {
                        Ok(list) => s.recordings = list.recordings,
                        Err(e) => log::warn!("recordings.list: {e}"),
                    }
                    cx.notify();
                });
            }),
        );
    }

    /// The draft was sent: its recordings go with it, as on the phone,
    /// once the message is taken. They leave the list now and are held
    /// (the hold returned) until [`Self::send_settled`] says how it went.
    pub fn sent(&mut self, cx: &mut Context<Self>) -> Option<u64> {
        let keep = self.active_recording().map(str::to_string);
        let ids: Vec<String> = std::mem::take(&mut self.recordings)
            .into_iter()
            .map(|r| r.id)
            .filter(|id| Some(id) != keep.as_ref())
            .collect();
        cx.notify();
        if ids.is_empty() {
            return None;
        }
        self.next_held += 1;
        self.held.push((self.next_held, self.target.clone(), ids));
        Some(self.next_held)
    }

    /// The message holding recordings `held` was taken (`accepted`): they
    /// are discarded. Refused: they stay with their draft, listed again
    /// when it is the one shown.
    pub fn send_settled(&mut self, held: u64, accepted: bool, cx: &mut Context<Self>) {
        let Some(at) = self.held.iter().position(|(h, _, _)| *h == held) else {
            return;
        };
        let (_, target, ids) = self.held.remove(at);
        if accepted {
            for id in ids {
                drop(
                    self.rpc
                        .call::<methods::RecordingsDiscard>(&reference(&target, &id)),
                );
            }
        } else if self.target.same_draft(&target) {
            self.refresh_recordings(cx);
        }
    }

    fn reference(&self, id: &str) -> RecordingRef {
        reference(&self.target, id)
    }

    // ── Listening ──────────────────────────────────────────────────────

    /// ⇧⌘L and the mic button: starts, or stops what is listening.
    pub fn toggle(&mut self, cx: &mut Context<Self>) {
        match self.phase {
            Phase::Idle => self.start(cx),
            Phase::Starting => self.cancel(cx),
            Phase::Listening { .. } => self.stop(cx),
            Phase::Transcribing => {}
        }
    }

    pub fn dismiss_notice(&mut self, cx: &mut Context<Self>) {
        self.notice = None;
        cx.notify();
    }

    /// Starts listening for the current draft.
    pub fn start(&mut self, cx: &mut Context<Self>) {
        if self.phase != Phase::Idle {
            return;
        }
        self.generation += 1;
        let generation = self.generation;
        self.phase = Phase::Starting;
        self.notice = None;
        self.level = 0.0;
        cx.notify();
        // The microphone would hear a reading: it pauses (one still
        // loading stops) before listening starts. A call's answer is the
        // call's to stop.
        if !self.call
            && let Some(speech) = cx
                .try_global::<crate::AppState>()
                .map(|s| s.stores.speech.clone())
        {
            speech.update(cx, |s, cx| s.yield_to_dictation(cx));
        }
        let status = self.rpc.call::<methods::DictationStatus>(&DictationTarget {
            model_id: self.target.model_id.clone(),
        });
        let input = self.input.clone();
        self._run = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let status = match status.await {
                    Ok(status) => status,
                    Err(e) => {
                        // The daemon is not answering: nothing to
                        // transcribe with.
                        log::warn!("dictation.status: {e}");
                        let _ = this.update(cx, |s, cx| {
                            s.refuse(generation, Notice::TranscriptionFailed(None), cx)
                        });
                        return;
                    }
                };
                // The engine chosen. Whisper without a model asks for one:
                // its promise is that the voice never leaves this Mac, so it
                // does not fall back to the server.
                let engine = match status.engine.as_str() {
                    "local" if status.local_ready => "local",
                    "local" => {
                        let _ = this.update(cx, |s, cx| {
                            s.refuse(generation, Notice::WhisperNeedsModel, cx)
                        });
                        return;
                    }
                    "server" if !status.server_available => {
                        let _ = this.update(cx, |s, cx| {
                            s.refuse(generation, Notice::ServerUnavailable, cx)
                        });
                        return;
                    }
                    "server" => "server",
                    _ => "device",
                }
                .to_string();
                // Permissions: the microphone (unless a file stands in for
                // it), and for this Mac's recognizer, speech recognition.
                if input.is_none() && !microphone_allowed().await {
                    let _ = this.update(cx, |s, cx| {
                        s.refuse(generation, Notice::MicrophoneDenied, cx)
                    });
                    return;
                }
                if engine == "device" && !speech_allowed().await {
                    let _ = this.update(cx, |s, cx| s.refuse(generation, Notice::SpeechDenied, cx));
                    return;
                }
                let _ = this.update(cx, |s, cx| s.listen(generation, status, engine, cx));
            }),
        );
    }

    fn refuse(&mut self, generation: u64, notice: Notice, cx: &mut Context<Self>) {
        if generation != self.generation {
            return;
        }
        self.phase = Phase::Idle;
        self.notice = Some(notice);
        cx.emit(DictationEvent::Ended { restore: false });
        cx.notify();
    }

    fn listen(
        &mut self,
        generation: u64,
        status: DictationStatus,
        engine: String,
        cx: &mut Context<Self>,
    ) {
        if generation != self.generation || self.phase != Phase::Starting {
            return;
        }
        let pause = u32::try_from(status.silence_ms).unwrap_or(DEFAULT_PAUSE_MS);
        let language = status.language.clone();
        self.status = Some(status);
        self.engine = engine.clone();
        // The recording: begun now, its audio held until the id comes.
        let target = self.target.clone();
        self.active = Some(Active {
            id: None,
            stored: target.keeps_recordings,
            waiting: VecDeque::new(),
            keep: false,
            target: target.clone(),
        });
        if target.keeps_recordings {
            let begin = self
                .rpc
                .call::<methods::RecordingsBegin>(&target.recordings());
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let started = begin.await;
                let _ = this.update(cx, |s, cx| {
                    s.recording_begun(generation, &target, started, cx)
                });
            })
            .detach();
        }
        let (tx, rx) = futures::channel::mpsc::unbounded();
        let recognizer = (engine == "device").then(|| recognizer(language));
        let config = voice::SessionConfig::new(pause, engine != "device");
        self.session = Some(voice::Session::spawn(
            config,
            voice::input_with(self.input.as_ref(), self.call),
            recognizer,
            tx,
        ));
        self._run = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let mut rx = rx;
                while let Some(event) = rx.next().await {
                    let alive = this
                        .update(cx, |s, cx| s.on_event(generation, event, cx))
                        .is_ok();
                    if !alive {
                        break;
                    }
                }
            }),
        );
        cx.notify();
    }

    fn recording_begun(
        &mut self,
        generation: u64,
        target: &Target,
        started: Result<conduit_protocol::RecordingStarted, RpcError>,
        cx: &mut Context<Self>,
    ) {
        let Some(active) = self
            .active
            .as_mut()
            .filter(|_| generation == self.generation)
        else {
            // Over before it was begun: nothing of it is kept.
            if let Ok(conduit_protocol::RecordingStarted { id: Some(id), .. }) = started {
                drop(
                    self.rpc
                        .call::<methods::RecordingsDiscard>(&reference(target, &id)),
                );
            }
            return;
        };
        match started {
            Ok(started) if started.stored && started.id.is_some() => {
                active.id = started.id;
                let waiting: Vec<Vec<u8>> = active.waiting.drain(..).collect();
                for pcm in waiting {
                    self.append(pcm, cx);
                }
                self.refresh_recordings(cx);
            }
            Ok(_) => {
                active.stored = false;
                active.waiting.clear();
            }
            Err(e) => {
                log::warn!("recordings.begin: {e}");
                active.stored = false;
                active.waiting.clear();
                self.notice = Some(Notice::SaveFailed);
            }
        }
        cx.notify();
    }

    /// Sends one chunk of the recording; a failed write is kept by the
    /// daemon and tried again with the next.
    fn append(&mut self, pcm: Vec<u8>, cx: &mut Context<Self>) {
        let Some(active) = self.active.as_mut() else {
            return;
        };
        if !active.stored {
            return;
        }
        let Some(id) = active.id.clone() else {
            active.waiting.push_back(pcm);
            return;
        };
        let call = self.rpc.call::<methods::RecordingsAppend>(&RecordingChunk {
            id,
            pcm: base64::engine::general_purpose::STANDARD.encode(&pcm),
        });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if let Err(e) = call.await {
                log::warn!("recordings.append: {e}");
                let _ = this.update(cx, |s, cx| {
                    s.notice = Some(Notice::SaveFailed);
                    cx.notify();
                });
            }
        })
        .detach();
    }

    /// Try Again on a failed save: the daemon writes what it holds.
    pub fn retry_save(&mut self, cx: &mut Context<Self>) {
        self.notice = None;
        if let Some(id) = self.active_recording().map(str::to_string) {
            let call = self.rpc.call::<methods::RecordingsAppend>(&RecordingChunk {
                id,
                pcm: String::new(),
            });
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                if call.await.is_err() {
                    let _ = this.update(cx, |s, cx| {
                        s.notice = Some(Notice::SaveFailed);
                        cx.notify();
                    });
                }
            })
            .detach();
        }
        cx.notify();
    }

    fn on_event(&mut self, generation: u64, event: SessionEvent, cx: &mut Context<Self>) {
        if generation != self.generation {
            return;
        }
        match event {
            SessionEvent::Started => {
                self.phase = Phase::Listening {
                    since: Instant::now(),
                };
                cx.notify();
            }
            SessionEvent::Level(level) => {
                // Up at once, down gently.
                self.level = level.max(self.level * 0.7);
                cx.notify();
            }
            SessionEvent::Chunk(pcm) => self.append(pcm, cx),
            SessionEvent::Partial(text) => {
                cx.emit(DictationEvent::Text { text, done: false });
            }
            SessionEvent::Ended {
                reason,
                text,
                heard,
                pcm,
            } => self.ended(generation, reason, text, heard, pcm, cx),
            SessionEvent::Failed(error) => {
                // A recognizer that failed mid-way leaves what was said with
                // the draft, to transcribe again (the phone's "Transcription
                // failed. Recording saved.").
                let keep = matches!(error, SessionError::Recognizer(_));
                let notice = match error {
                    SessionError::Input(InputError::Denied | InputError::Unavailable(_)) => {
                        Notice::MicrophoneDenied
                    }
                    SessionError::SpeechDenied => Notice::SpeechDenied,
                    SessionError::NotOnThisMac(locale) => Notice::NotOnThisMac(locale),
                    SessionError::Recognizer(e) => {
                        log::warn!("dictation: {e}");
                        Notice::TranscriptionFailed(self.active_recording().map(str::to_string))
                    }
                };
                self.finish_recording(keep, cx);
                self.session = None;
                self.phase = Phase::Idle;
                self.notice = Some(notice);
                cx.emit(DictationEvent::Ended { restore: false });
                cx.notify();
            }
        }
    }

    fn ended(
        &mut self,
        generation: u64,
        reason: EndReason,
        text: String,
        heard: bool,
        pcm: Option<Vec<u8>>,
        cx: &mut Context<Self>,
    ) {
        self.session = None;
        self.level = 0.0;
        self.last_end = Some(reason);
        let keep = self.active.as_ref().is_some_and(|a| a.keep);
        // Its draft moved (another chat, another account): ended as if
        // cancelled even when the session's own end was already on its way,
        // so nothing of it is transcribed for the draft or account now shown.
        if reason == EndReason::Cancelled || keep {
            // Dropped, unless it was cut off by opening another chat.
            let recording = self.active_recording().map(str::to_string);
            self.finish_recording(keep, cx);
            self.phase = Phase::Idle;
            cx.emit(DictationEvent::Ended { restore: !keep });
            if recording.is_some() && keep {
                self.refresh_recordings(cx);
            }
            cx.notify();
            return;
        }
        if !heard {
            // Nothing said: nothing to keep.
            self.finish_recording(false, cx);
            self.phase = Phase::Idle;
            if !self.call {
                let text = nothing_heard(cx);
                self.toast(text, cx);
            }
            cx.emit(DictationEvent::Ended { restore: true });
            cx.notify();
            return;
        }
        let recording = self.active_recording().map(str::to_string);
        self.finish_recording(true, cx);
        if self.engine == "device" {
            self.phase = Phase::Idle;
            if text.is_empty() {
                self.notice = Some(Notice::TranscriptionFailed(recording));
                cx.emit(DictationEvent::Ended { restore: true });
            } else {
                cx.emit(DictationEvent::Text { text, done: true });
                cx.emit(DictationEvent::Ended { restore: false });
            }
            cx.notify();
            return;
        }
        // The server or whisper: the whole recording, as WAV.
        let Some(pcm) = pcm.filter(|p| !p.is_empty()) else {
            self.phase = Phase::Idle;
            cx.emit(DictationEvent::Ended { restore: true });
            cx.notify();
            return;
        };
        self.phase = Phase::Transcribing;
        // Its row says so (and the others wait).
        self.busy = recording.clone();
        cx.emit(DictationEvent::Heard);
        cx.notify();
        let http = self.http(cx);
        let engine = self.engine.clone();
        let model = self.target.model_id.clone();
        self._run = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result: Result<VoiceTranscript, String> = match http {
                    Some(http) => on_io(async move {
                        http.transcribe(
                            bytes::Bytes::from(voice::pcm::wav(&pcm)),
                            Some(&engine),
                            model.as_deref(),
                        )
                        .await
                        .map_err(|e| e.to_string())
                        .and_then(|v| {
                            serde_json::from_value::<VoiceTranscript>(v).map_err(|e| e.to_string())
                        })
                    })
                    .await
                    .unwrap_or_else(|| Err("dropped".into())),
                    None => Err("not connected".into()),
                };
                let _ = this.update(cx, |s, cx| {
                    if generation != s.generation {
                        return;
                    }
                    s.phase = Phase::Idle;
                    s.busy = None;
                    match result {
                        Ok(t) if !t.text.trim().is_empty() => {
                            cx.emit(DictationEvent::Text {
                                text: t.text.trim().to_string(),
                                done: true,
                            });
                            cx.emit(DictationEvent::Ended { restore: false });
                        }
                        Ok(_) => {
                            if !s.call {
                                let text = nothing_heard(cx);
                                s.toast(text, cx);
                            }
                            cx.emit(DictationEvent::Ended { restore: true });
                        }
                        Err(e) => {
                            log::warn!("transcribe: {e}");
                            s.notice = Some(Notice::TranscriptionFailed(recording));
                            cx.emit(DictationEvent::Ended { restore: true });
                        }
                    }
                    cx.notify();
                });
            }),
        );
    }

    /// Closes the recording under way (kept) or discards it.
    fn finish_recording(&mut self, keep: bool, cx: &mut Context<Self>) {
        let Some(active) = self.active.take() else {
            return;
        };
        let Some(id) = active.id else {
            return;
        };
        let reference = reference(&active.target, &id);
        let close = if keep {
            Some(self.rpc.call::<methods::RecordingsClose>(&reference))
        } else {
            None
        };
        let discard = (!keep).then(|| self.rpc.call::<methods::RecordingsDiscard>(&reference));
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if let Some(close) = close
                && let Err(e) = close.await
            {
                log::warn!("recordings.close: {e}");
            }
            if let Some(discard) = discard
                && let Err(e) = discard.await
            {
                log::warn!("recordings.discard: {e}");
            }
            let _ = this.update(cx, |s, cx| s.refresh_recordings(cx));
        })
        .detach();
    }

    /// Stop: what was said is transcribed.
    pub fn stop(&mut self, cx: &mut Context<Self>) {
        match &self.session {
            Some(session) => session.stop(),
            None => self.cancel(cx),
        }
    }

    /// Cancel (Esc): what was said is dropped, and the text put back.
    pub fn cancel(&mut self, cx: &mut Context<Self>) {
        match (&self.session, &self.phase) {
            (Some(session), _) => session.cancel(),
            (None, Phase::Starting) => {
                // Still asking: nothing heard yet.
                self.generation += 1;
                self._run = None;
                self.phase = Phase::Idle;
                cx.emit(DictationEvent::Ended { restore: true });
                cx.notify();
            }
            (None, Phase::Transcribing) => {
                // The recording stays; its words are not waited for.
                self.generation += 1;
                self._run = None;
                self.phase = Phase::Idle;
                self.busy = None;
                cx.emit(DictationEvent::Ended { restore: true });
                self.refresh_recordings(cx);
                cx.notify();
            }
            _ => {}
        }
    }

    fn toast(&self, text: String, cx: &mut Context<Self>) {
        if let Some(stores) = cx.try_global::<crate::AppState>().map(|s| s.stores.clone()) {
            stores.toasts.update(cx, |t, cx| {
                t.show(conduit_protocol::NoticeLevel::Info, text, cx)
            });
        }
    }

    // ── Saved recordings ───────────────────────────────────────────────

    /// Transcribes saved recording `id` on the server (the chat's backend)
    /// or on this Mac (whisper when that is the engine and ready, else
    /// this Mac's recognizer); its words are added to the text.
    pub fn transcribe_saved(&mut self, id: &str, on_this_mac: bool, cx: &mut Context<Self>) {
        if self.busy.is_some() || self.is_active() {
            return;
        }
        self.busy = Some(id.to_string());
        self.notice = None;
        cx.notify();
        let id = id.to_string();
        let status = self.rpc.call::<methods::DictationStatus>(&DictationTarget {
            model_id: self.target.model_id.clone(),
        });
        let rpc = self.rpc.clone();
        let reference = self.reference(&id);
        let model = self.target.model_id.clone();
        let http = self.http(cx);
        self._busy = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let status = status.await.unwrap_or_default();
                let whisper = status.engine == "local" && status.local_ready;
                let result: Result<String, String> = if !on_this_mac || whisper {
                    rpc.call::<methods::RecordingsTranscribe>(&RecordingTranscribe {
                        id: reference.id.clone(),
                        chat_id: reference.chat_id.clone(),
                        folder_id: reference.folder_id.clone(),
                        engine: if on_this_mac { "local" } else { "server" }.into(),
                        model_id: model,
                    })
                    .await
                    .map(|t| t.text)
                    .map_err(|e| e.to_string())
                } else {
                    transcribe_here(http, reference, status.language).await
                };
                let _ = this.update(cx, |s, cx| {
                    s.busy = None;
                    match result {
                        Ok(text) if !text.trim().is_empty() => {
                            cx.emit(DictationEvent::Transcribed(text.trim().to_string()));
                        }
                        Ok(_) => {
                            let text = nothing_heard(cx);
                            s.toast(text, cx);
                        }
                        Err(e) => {
                            log::warn!("transcribing a recording: {e}");
                            s.notice = Some(Notice::TranscriptionFailed(Some(id)));
                        }
                    }
                    cx.notify();
                });
            }),
        );
    }

    /// Saved recording `id` as WAV, for Export.
    pub fn wav(
        &self,
        id: &str,
        cx: &App,
    ) -> impl std::future::Future<Output = Result<Vec<u8>, String>> + use<> {
        let http = self.http(cx);
        let reference = self.reference(id);
        async move { fetch_wav(http, reference).await }
    }

    /// Writes saved recording `id` to `path` (Export… after its save
    /// panel, or the E2E pass).
    pub fn export_to(
        &mut self,
        id: &str,
        path: std::path::PathBuf,
        cx: &mut Context<Self>,
    ) -> Task<bool> {
        self.busy = Some(id.to_string());
        cx.notify();
        let wav = self.wav(id, cx);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let written = match wav.await {
                Ok(bytes) => std::fs::write(&path, bytes).is_ok(),
                Err(e) => {
                    log::warn!("export: {e}");
                    false
                }
            };
            let _ = this.update(cx, |s, cx| {
                s.busy = None;
                if !written {
                    s.notice = Some(Notice::ExportFailed);
                }
                cx.notify();
            });
            written
        })
    }

    /// Discards saved recording `id` (after its confirmation).
    pub fn discard(&mut self, id: &str, cx: &mut Context<Self>) {
        let call = self
            .rpc
            .call::<methods::RecordingsDiscard>(&self.reference(id));
        let target = self.target.clone();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                if !s.target.same_draft(&target) {
                    return;
                }
                match result {
                    Ok(list) => {
                        s.recordings = list.recordings;
                        if matches!(
                            s.notice,
                            Some(Notice::TranscriptionFailed(_)) | Some(Notice::DiscardFailed)
                        ) {
                            s.notice = None;
                        }
                    }
                    Err(e) => {
                        log::warn!("recordings.discard: {e}");
                        s.notice = Some(Notice::DiscardFailed);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// How long the dictation under way has listened.
    pub fn elapsed(&self) -> Duration {
        match self.phase {
            Phase::Listening { since } => since.elapsed(),
            _ => Duration::ZERO,
        }
    }
}

/// Recording `id` of `target`'s draft.
fn reference(target: &Target, id: &str) -> RecordingRef {
    RecordingRef {
        id: id.to_string(),
        chat_id: target.chat_id.clone(),
        folder_id: target.folder_id.clone(),
    }
}

/// `m:ss`, as the phone shows a recording's length.
pub fn clock(duration: Duration) -> String {
    let seconds = duration.as_secs();
    format!("{}:{:02}", seconds / 60, seconds % 60)
}

/// A saved recording's length.
pub fn recording_length(recording: &RecordingDto) -> Duration {
    Duration::from_millis(recording.duration_ms.max(0) as u64)
}

fn nothing_heard(cx: &App) -> String {
    use crate::l10n::ActiveL10n as _;
    cx.l10n().desktop_nothing_heard()
}

/// Runs `f` (an HTTP call) on the daemon's tokio runtime; any executor can
/// await the answer.
pub(crate) async fn on_io<T: Send + 'static>(
    f: impl std::future::Future<Output = T> + Send + 'static,
) -> Option<T> {
    let (tx, rx) = futures::channel::oneshot::channel();
    conduit_daemon::runtime::shared().spawn(async move {
        let _ = tx.send(f.await);
    });
    rx.await.ok()
}

#[cfg(target_os = "macos")]
fn recognizer(language: Option<String>) -> voice::session::RecognizerFactory {
    voice::mac::speech_recognizer(language)
}

#[cfg(not(target_os = "macos"))]
fn recognizer(_language: Option<String>) -> voice::session::RecognizerFactory {
    Box::new(|_| Err(SessionError::NotOnThisMac(String::new())))
}

/// Whether the microphone may be used, asking the first time.
pub(crate) async fn microphone_allowed() -> bool {
    #[cfg(target_os = "macos")]
    {
        use voice::mac::{Permission, microphone, request_microphone};
        match microphone() {
            Permission::Granted => true,
            Permission::NotAsked => {
                let (tx, rx) = futures::channel::oneshot::channel();
                request_microphone(move |granted| {
                    let _ = tx.send(granted);
                });
                rx.await.unwrap_or(false)
            }
            _ => false,
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

/// Whether this Mac's recognizer may be used, asking the first time.
async fn speech_allowed() -> bool {
    #[cfg(target_os = "macos")]
    {
        use voice::mac::{Permission, request_speech, speech};
        match speech() {
            Permission::Granted => true,
            Permission::NotAsked => {
                let (tx, rx) = futures::channel::oneshot::channel();
                request_speech(move |answer| {
                    let _ = tx.send(answer == Permission::Granted);
                });
                rx.await.unwrap_or(false)
            }
            _ => false,
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

/// A saved recording of a draft, as WAV (`GET /recordings/{id}`).
async fn fetch_wav(http: Option<HttpClient>, reference: RecordingRef) -> Result<Vec<u8>, String> {
    let http = http.ok_or("not connected")?;
    on_io(async move {
        http.recording(
            &reference.id,
            reference.chat_id.as_deref(),
            reference.folder_id.as_deref(),
        )
        .await
        .map(|f| f.bytes.to_vec())
        .map_err(|e| e.to_string())
    })
    .await
    .unwrap_or_else(|| Err("dropped".into()))
}

/// A saved recording, by this Mac's recognizer: fetched as WAV into a
/// temporary file and recognized off the UI thread.
async fn transcribe_here(
    http: Option<HttpClient>,
    reference: RecordingRef,
    language: Option<String>,
) -> Result<String, String> {
    if !speech_allowed().await {
        return Err("speech recognition is off".into());
    }
    let id = reference.id.clone();
    let wav = fetch_wav(http, reference).await?;
    let path = std::env::temp_dir().join(format!("conduit-recording-{id}.wav"));
    std::fs::write(&path, &wav).map_err(|e| e.to_string())?;
    let (rx, _) = recognize_file(path, move |file| {
        #[cfg(target_os = "macos")]
        let result = voice::mac::transcribe_file(file, language.as_deref());
        #[cfg(not(target_os = "macos"))]
        let result: Result<String, SessionError> = {
            let _ = (file, language);
            Err(SessionError::NotOnThisMac(String::new()))
        };
        result
    });
    let result = rx.await.map_err(|e| e.to_string())?;
    result.map_err(|e| format!("{e:?}"))
}

/// Runs `recognize` on the recording at `path` on its own thread, then
/// removes the file there, whether or not anyone still waits for the words
/// on the receiver (the draft may have changed meanwhile).
fn recognize_file<R: Send + 'static>(
    path: std::path::PathBuf,
    recognize: impl FnOnce(&std::path::Path) -> R + Send + 'static,
) -> (
    futures::channel::oneshot::Receiver<R>,
    std::thread::JoinHandle<()>,
) {
    let (tx, rx) = futures::channel::oneshot::channel();
    let thread = std::thread::spawn(move || {
        let result = recognize(&path);
        let _ = std::fs::remove_file(&path);
        let _ = tx.send(result);
    });
    (rx, thread)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A recording copied out for this Mac's recognizer is removed once
    /// recognized, even when nobody waits for the words any more (the
    /// draft changed).
    #[test]
    fn a_recognized_recordings_copy_goes_even_unawaited() {
        let path =
            std::env::temp_dir().join(format!("conduit-recording-test-{}.wav", std::process::id()));
        std::fs::write(&path, b"RIFF").unwrap();
        let (rx, thread) = recognize_file(path.clone(), |file| file.exists());
        drop(rx);
        thread.join().unwrap();
        assert!(
            !path.exists(),
            "the recording's copy was left in the temporary folder"
        );
    }

    #[test]
    fn lengths_read_as_minutes_and_seconds() {
        assert_eq!(clock(Duration::from_millis(7_400)), "0:07");
        assert_eq!(clock(Duration::from_secs(65)), "1:05");
        assert_eq!(
            recording_length(&RecordingDto {
                id: "r".into(),
                created_at: 0,
                byte_count: 96_000,
                duration_ms: 3_000,
            }),
            Duration::from_secs(3)
        );
    }

    #[test]
    fn a_refused_permission_points_at_its_pane() {
        assert!(
            Notice::MicrophoneDenied
                .settings_url()
                .unwrap()
                .ends_with("Privacy_Microphone")
        );
        assert!(
            Notice::SpeechDenied
                .settings_url()
                .unwrap()
                .ends_with("Privacy_SpeechRecognition")
        );
        assert_eq!(Notice::ServerUnavailable.settings_url(), None);
    }

    #[test]
    fn the_same_draft_ignores_the_model() {
        let a = Target {
            chat_id: Some("c".into()),
            model_id: Some("m1".into()),
            keeps_recordings: true,
            ..Default::default()
        };
        let b = Target {
            model_id: Some("m2".into()),
            ..a.clone()
        };
        assert!(a.same_draft(&b));
        assert!(!a.same_draft(&Target::default()));
    }

    use crate::stores::rpc::fake::FakeDaemon;
    use conduit_protocol::{DictationStatus, RecordingList};
    use gpui_kit::{AppContext as _, TestAppContext};

    fn recording(id: &str) -> RecordingDto {
        RecordingDto {
            id: id.into(),
            created_at: 0,
            byte_count: 64_000,
            duration_ms: 2_000,
        }
    }

    fn chat(id: &str) -> Target {
        Target {
            chat_id: Some(id.into()),
            folder_id: None,
            model_id: Some("m".into()),
            keeps_recordings: true,
        }
    }

    #[gpui_kit::test]
    fn a_draft_lists_its_recordings_and_sending_takes_them(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::RecordingsList>(RecordingList {
            stored: true,
            recordings: vec![recording("a"), recording("b")],
        });
        daemon.returns::<methods::RecordingsDiscard>(RecordingList::default());
        let store = cx.new(|_| DictationStore::new(daemon.rpc(), None));
        store.update(cx, |s, cx| s.set_target(chat("c1"), cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| assert_eq!(s.recordings.len(), 2));
        // Another model, same draft: not read again.
        store.update(cx, |s, cx| {
            s.set_target(
                Target {
                    model_id: Some("other".into()),
                    ..chat("c1")
                },
                cx,
            )
        });
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::RecordingsList>().len(), 1);
        // Sent: each goes, for its draft, once the message is taken.
        let held = store.update(cx, |s, cx| s.sent(cx)).unwrap();
        cx.run_until_parked();
        assert!(daemon.calls::<methods::RecordingsDiscard>().is_empty());
        store.update(cx, |s, cx| s.send_settled(held, true, cx));
        cx.run_until_parked();
        let discarded = daemon.calls::<methods::RecordingsDiscard>();
        assert_eq!(discarded.len(), 2);
        assert_eq!(discarded[0]["chatId"], "c1");
        store.read_with(cx, |s, _| assert!(s.recordings.is_empty()));
        // A temporary chat keeps none, and is not asked.
        store.update(cx, |s, cx| {
            s.set_target(
                Target {
                    keeps_recordings: false,
                    ..chat("local:t")
                },
                cx,
            )
        });
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::RecordingsList>().len(), 1);
    }

    /// A dictation whose draft moved (another chat, another account) keeps
    /// its audio with that draft: an end the session had already sent when
    /// it was cancelled transcribes nothing, under nobody's account.
    #[gpui_kit::test]
    fn an_end_already_on_its_way_when_the_draft_moved_transcribes_nothing(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::RecordingsList>(RecordingList::default());
        let store = cx.new(|_| DictationStore::new(daemon.rpc(), None));
        let generation = store.update(cx, |s, cx| {
            s.set_target_in(1, chat("c1"), cx);
            // Listening on the server engine, its recording begun.
            s.engine = "server".into();
            s.phase = Phase::Listening {
                since: Instant::now(),
            };
            s.active = Some(Active {
                id: Some("r1".into()),
                stored: true,
                waiting: VecDeque::new(),
                keep: false,
                target: chat("c1"),
            });
            // Another account's new chat, the same ids.
            s.set_target_in(2, chat("c1"), cx);
            s.generation
        });
        // The end the session sent before it heard the cancel.
        store.update(cx, |s, cx| {
            s.on_event(
                generation,
                SessionEvent::Ended {
                    reason: EndReason::Silence,
                    text: String::new(),
                    heard: true,
                    pcm: Some(vec![1; 3200]),
                },
                cx,
            );
            assert_eq!(
                s.phase,
                Phase::Idle,
                "the last account's words were sent to transcribe"
            );
            assert_eq!(s.busy, None);
        });
        cx.run_until_parked();
        assert!(daemon.calls::<methods::RecordingsTranscribe>().is_empty());
    }

    // (A refused microphone is the session's: `voice::session` tests it;
    // GPUI's test scheduler takes no wake-ups from the dictation thread.)
    #[gpui_kit::test]
    fn whisper_without_a_model_asks_for_one_and_never_the_server(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::RecordingsList>(RecordingList::default());
        daemon.returns::<methods::DictationStatus>(DictationStatus {
            engine: "local".into(),
            server_available: true,
            local_ready: false,
            ..Default::default()
        });
        let store = cx.new(|_| DictationStore::new(daemon.rpc(), None));
        store.update(cx, |s, cx| {
            s.set_input(Some(InputOverride::Denied));
            s.set_target(chat("c1"), cx);
            s.toggle(cx);
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.notice, Some(Notice::WhisperNeedsModel));
            assert_eq!(s.phase, Phase::Idle);
        });
        assert!(daemon.calls::<methods::RecordingsBegin>().is_empty());
        // The chat's backend does not transcribe: said so, nothing begun.
        daemon.returns::<methods::DictationStatus>(DictationStatus {
            engine: "server".into(),
            server_available: false,
            ..Default::default()
        });
        store.update(cx, |s, cx| s.toggle(cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.notice, Some(Notice::ServerUnavailable))
        });
        assert!(daemon.calls::<methods::RecordingsBegin>().is_empty());
    }
}
