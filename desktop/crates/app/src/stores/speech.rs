//! Read aloud (`speech.*`): the reading the daemon runs, and this window's
//! part in it.
//!
//! * **The reading.** `speech.changed` brings its progress (status, the
//!   sentence and word being said, time); its sentences come once per
//!   reading from `speech.get`. Every action (Read Aloud, pause, skip, seek,
//!   stop, Settings' Preview) is a `speech.*` call, and its answer replaces
//!   what is shown: nothing is patched here.
//! * **The engine.** The daemon's manager speaks through this window:
//!   `speech.command`s run one at a time, in order, on
//!   [`crate::shell::speech_engine`] (the Mac's voices, or the server's
//!   clips fetched from `/tts/{job}`), and each is answered, as is what the
//!   voice and the player then do, with `speech.report`.
//! * **The system.** Now Playing and the media keys follow the reading
//!   ([`crate::shell::now_playing`]).

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use conduit_protocol::{
    NoParams, SpeechCommand, SpeechCommandKind, SpeechPreview, SpeechProgress, SpeechReport,
    SpeechSeek, SpeechState, SpeechStatus, SpeechToggle, SpeechVoice, events, methods,
};
use futures::StreamExt as _;
use futures::channel::mpsc;
use gpui_kit::{App, AsyncApp, Context, Entity, EventEmitter, Task, WeakEntity};

use super::Stores;
use super::connection::ConnectionStore;
use super::rpc::Rpc;
use crate::shell::speech_engine::{self, ClipQueue, Voice, VoiceEvent};

/// The events this store follows.
pub const EVENTS: &[&str] = &[events::SPEECH_CHANGED, events::SPEECH_COMMAND];

/// What the media keys and Control Center ask for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RemoteCommand {
    TogglePause,
    Play,
    Pause,
    Stop,
    Next,
    Previous,
}

/// Emitted when the reading changes, for whoever follows it in place (the
/// transcript's highlight).
pub struct SpeechChanged;

/// A Pause or Resume the user asked for, said to VoiceOver once the
/// reading is so: the daemon's answer, or a later `speech.changed`, shows
/// it paused (or speaking again). The status follows the commands: a
/// desktop reading is marked paused from the Pause request itself, and
/// speaking again once the voice answered Resume, so `speech.resume`'s own
/// answer may still say paused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Said {
    Paused,
    Resumed,
}

impl Said {
    /// Whether a reading in `status` did what was asked.
    pub fn reached(self, status: SpeechStatus) -> bool {
        match self {
            Self::Paused => status == SpeechStatus::Paused,
            Self::Resumed => status == SpeechStatus::Speaking,
        }
    }

    /// Whether a reading in `status` can no longer get there: it stopped
    /// or failed. (A Resume answered while still paused is waiting for the
    /// voice; a Pause or Resume asked for after replaces it.)
    pub fn abandoned(self, status: SpeechStatus) -> bool {
        matches!(status, SpeechStatus::Idle | SpeechStatus::Error)
    }
}

/// What a reading does when dictation starts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DictationYield {
    Pause,
    Stop,
}

/// A reading that speaks pauses for dictation, so it can go on after; one
/// still starting has said nothing yet and stops. Paused, failed and idle
/// readings are left as they are.
pub fn yield_for_dictation(status: SpeechStatus) -> Option<DictationYield> {
    match status {
        SpeechStatus::Speaking => Some(DictationYield::Pause),
        SpeechStatus::Loading | SpeechStatus::Initializing => Some(DictationYield::Stop),
        _ => None,
    }
}

pub struct SpeechStore {
    rpc: Rpc,
    connection: Entity<ConnectionStore>,
    /// The reading now, as the daemon last said.
    progress: SpeechProgress,
    /// Its sentences, and the reading they are of.
    sentences: Vec<String>,
    sentences_of: i64,
    _sentences: Option<Task<()>>,
    /// A Pause or Resume asked for and not yet reached, with its reading.
    say: Option<(Said, i64)>,

    voice: Voice,
    queue: ClipQueue,
    /// Commands waiting for the one running to finish.
    commands: VecDeque<SpeechCommand>,
    running: bool,
    /// Polls the clip playing, to move on and report where it is.
    _ticker: Option<Task<()>>,
    last_position_report: Option<Instant>,
    _voice_events: Task<()>,
    /// What the engine was asked to say (text, AVSpeech rate), newest last,
    /// and how many clips it fetched from `/tts/{job}`: for the E2E pass.
    pub spoken: Vec<(String, f64)>,
    pub fetched: usize,
}

impl EventEmitter<SpeechChanged> for SpeechStore {}

impl SpeechStore {
    pub fn new(rpc: Rpc, connection: Entity<ConnectionStore>, cx: &mut Context<Self>) -> Self {
        let muted = speech_engine::muted();
        let (tx, mut rx) = mpsc::unbounded::<VoiceEvent>();
        let voice_events = cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            while let Some(event) = rx.next().await {
                if this
                    .update(cx, |s, cx| s.send_report(event.report(), cx))
                    .is_err()
                {
                    break;
                }
            }
        });
        Self {
            rpc,
            connection,
            progress: SpeechProgress::default(),
            sentences: vec![],
            sentences_of: -1,
            _sentences: None,
            say: None,
            voice: Voice::new(tx, muted),
            queue: ClipQueue::new(speech_engine::clip_loader(muted)),
            commands: VecDeque::new(),
            running: false,
            _ticker: None,
            last_position_report: None,
            _voice_events: voice_events,
            spoken: vec![],
            fetched: 0,
        }
    }

    // ---------------------------------------------------------------
    // What views read.

    pub fn progress(&self) -> &SpeechProgress {
        &self.progress
    }

    /// The reading's sentences (empty until fetched).
    pub fn sentences(&self) -> &[String] {
        if self.sentences_of == self.progress.reading {
            &self.sentences
        } else {
            &[]
        }
    }

    /// Whether a reading is under way (loading, speaking, paused or failed).
    pub fn is_active(&self) -> bool {
        self.progress.status != SpeechStatus::Idle && self.progress.message_id.is_some()
    }

    /// Whether it is saying something now (or about to).
    pub fn is_speaking(&self) -> bool {
        matches!(
            self.progress.status,
            SpeechStatus::Speaking | SpeechStatus::Loading | SpeechStatus::Initializing
        )
    }

    pub fn is_paused(&self) -> bool {
        self.progress.status == SpeechStatus::Paused
    }

    /// Whether message `id` is the one being read.
    pub fn is_reading(&self, id: &str) -> bool {
        self.is_active() && self.progress.message_id.as_deref() == Some(id)
    }

    /// The chat being read in, unless it is Settings' preview.
    pub fn chat_id(&self) -> Option<&str> {
        self.is_active()
            .then_some(self.progress.chat_id.as_deref())
            .flatten()
    }

    // ---------------------------------------------------------------
    // Actions.

    /// Read Aloud for answer `message_id` in `chat_id`: reads it, or stops
    /// (resumes, when paused) the reading of it.
    pub fn toggle(&mut self, chat_id: String, message_id: String, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::SpeechToggle>(&SpeechToggle {
            chat_id,
            message_id,
        });
        self.adopt(call, cx);
    }

    /// Pause (the bar, the media keys, another chat opening): VoiceOver
    /// hears "Reading paused" once the reading is.
    pub fn pause(&mut self, cx: &mut Context<Self>) {
        self.expect(Said::Paused);
        self.pause_quietly(cx);
    }

    /// Pause without a word: dictation starting, whose microphone would
    /// hear VoiceOver say it.
    fn pause_quietly(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::SpeechPause>(&NoParams {});
        self.adopt(call, cx);
    }

    /// Resume: VoiceOver hears "Reading resumed" once it speaks again.
    pub fn resume(&mut self, cx: &mut Context<Self>) {
        self.expect(Said::Resumed);
        let call = self.rpc.call::<methods::SpeechResume>(&NoParams {});
        self.adopt(call, cx);
    }

    /// Keeps what a Pause or Resume will say, when the reading is not so
    /// already (a second Pause says nothing).
    fn expect(&mut self, said: Said) {
        self.say = (self.is_active() && !said.reached(self.progress.status))
            .then_some((said, self.progress.reading));
    }

    /// Play/Pause: resumes a paused reading, pauses one that speaks.
    pub fn toggle_pause(&mut self, cx: &mut Context<Self>) {
        match self.progress.status {
            SpeechStatus::Paused => self.resume(cx),
            SpeechStatus::Speaking => self.pause(cx),
            SpeechStatus::Error => self.retry(cx),
            _ => {}
        }
    }

    /// Dictation is starting: the microphone would hear the reading, so a
    /// reading that speaks pauses (the bar keeps Play) and one still
    /// loading stops.
    pub fn yield_to_dictation(&mut self, cx: &mut Context<Self>) {
        // Nothing asked before is said once the microphone listens (a
        // Resume still out would say "Reading resumed" into it).
        self.say = None;
        match yield_for_dictation(self.progress.status) {
            Some(DictationYield::Pause) => self.pause_quietly(cx),
            Some(DictationYield::Stop) => self.stop(cx),
            None => {}
        }
    }

    /// Stop Speaking.
    pub fn stop(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::SpeechStop>(&NoParams {});
        self.adopt(call, cx);
    }

    pub fn retry(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::SpeechRetry>(&NoParams {});
        self.adopt(call, cx);
    }

    /// Next Sentence (`by` 1) or Previous Sentence (-1).
    pub fn skip(&mut self, by: i64, cx: &mut Context<Self>) {
        self.seek(
            SpeechSeek {
                sentence: None,
                by: Some(by),
                ms: None,
            },
            cx,
        );
    }

    /// Moves to the start of sentence `index` (a click on it).
    pub fn seek_sentence(&mut self, index: usize, cx: &mut Context<Self>) {
        self.seek(
            SpeechSeek {
                sentence: Some(index as i64),
                by: None,
                ms: None,
            },
            cx,
        );
    }

    fn seek(&mut self, seek: SpeechSeek, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::SpeechSeek>(&seek);
        self.adopt(call, cx);
    }

    /// Settings › Audio's Preview, or stops it.
    pub fn preview(&mut self, text: String, cx: &mut Context<Self>) {
        let call = self
            .rpc
            .call::<methods::SpeechPreview>(&SpeechPreview { text });
        self.adopt(call, cx);
    }

    /// The media keys and Control Center.
    pub fn remote(&mut self, command: RemoteCommand, cx: &mut Context<Self>) {
        if !self.is_active() {
            return;
        }
        match command {
            RemoteCommand::TogglePause => self.toggle_pause(cx),
            RemoteCommand::Play if self.is_paused() => self.resume(cx),
            RemoteCommand::Pause if self.progress.status == SpeechStatus::Speaking => {
                self.pause(cx)
            }
            RemoteCommand::Stop => self.stop(cx),
            RemoteCommand::Next if self.progress.can_seek_sentences => self.skip(1, cx),
            RemoteCommand::Previous if self.progress.can_seek_sentences => self.skip(-1, cx),
            _ => {}
        }
    }

    /// A new daemon session (a reconnect, or a restarted daemon, which
    /// numbers its readings from 0 again): its answer is the reading, older
    /// number or not.
    pub fn reconnected(&mut self, cx: &mut Context<Self>) {
        self.progress.reading = i64::MIN;
        self.refresh(cx);
    }

    /// Fetches the reading (a window that connected late, or a gap).
    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::SpeechGet>(&NoParams {});
        self.adopt(call, cx);
    }

    fn adopt(
        &mut self,
        call: impl std::future::Future<Output = Result<SpeechState, conduit_daemon::RpcError>> + 'static,
        cx: &mut Context<Self>,
    ) {
        cx.spawn(async move |this, cx| match call.await {
            Ok(state) => {
                let _ = this.update(cx, |s, cx| s.apply_state(state, cx));
            }
            Err(e) => log::warn!("speech: {e}"),
        })
        .detach();
    }

    fn apply_state(&mut self, state: SpeechState, cx: &mut Context<Self>) {
        // An answer older than the progress already shown changes nothing.
        if state.progress.reading < self.progress.reading {
            return;
        }
        self.sentences = state.sentences;
        self.sentences_of = state.progress.reading;
        self.apply_progress(state.progress, cx);
    }

    fn apply_progress(&mut self, progress: SpeechProgress, cx: &mut Context<Self>) {
        // Each reading's sentences, once: a progress of a newer reading
        // asks for them.
        if progress.reading != self.sentences_of && progress.message_id.is_some() {
            let reading = progress.reading;
            let call = self.rpc.call::<methods::SpeechGet>(&NoParams {});
            self._sentences = Some(cx.spawn(async move |this, cx| {
                if let Ok(state) = call.await {
                    let _ = this.update(cx, |s, cx| {
                        if state.progress.reading >= reading {
                            s.sentences = state.sentences;
                            s.sentences_of = state.progress.reading;
                            cx.emit(SpeechChanged);
                            cx.notify();
                        }
                    });
                }
            }));
        }
        self.progress = progress;
        if let Some((said, reading)) = self.say {
            let status = self.progress.status;
            if self.progress.reading != reading || said.abandoned(status) {
                self.say = None;
            } else if said.reached(status) {
                self.say = None;
                use crate::l10n::ActiveL10n as _;
                let text = match said {
                    Said::Paused => cx.l10n().desktop_reading_paused(),
                    Said::Resumed => cx.l10n().desktop_reading_resumed(),
                };
                conduit_components::announce::announce(
                    text,
                    conduit_components::announce::Priority::Medium,
                    cx,
                );
            }
        }
        crate::shell::now_playing::update(&self.progress, self.sentences());
        cx.emit(SpeechChanged);
        cx.notify();
    }

    // ---------------------------------------------------------------
    // The engine.

    fn on_command(&mut self, command: SpeechCommand, cx: &mut Context<Self>) {
        self.commands.push_back(command);
        self.pump(cx);
    }

    /// Runs the next command, once its clips are here.
    fn pump(&mut self, cx: &mut Context<Self>) {
        if self.running {
            return;
        }
        let Some(command) = self.commands.pop_front() else {
            return;
        };
        let missing: Vec<String> = match command.kind {
            SpeechCommandKind::PlayerSet
            | SpeechCommandKind::PlayerAdd
            | SpeechCommandKind::PlayerDuration => command
                .clips
                .iter()
                .filter(|c| !self.queue.has(c))
                .cloned()
                .collect(),
            _ => vec![],
        };
        if missing.is_empty() {
            let report = self.run(&command, cx);
            self.send_report(report, cx);
            self.pump(cx);
            return;
        }
        self.running = true;
        let http = self.connection.read(cx).http().cloned();
        cx.spawn(async move |this, cx| {
            let mut fetched = vec![];
            let mut failure = None;
            for path in missing {
                let job = path.trim_start_matches("/tts/").to_string();
                match &http {
                    Some(http) => match fetch_clip(http.clone(), job).await {
                        Ok(bytes) => fetched.push((path, bytes)),
                        Err(e) => {
                            failure = Some(format!("{path}: {e}"));
                            break;
                        }
                    },
                    None => {
                        failure = Some("no connection to the daemon".into());
                        break;
                    }
                }
            }
            let _ = this.update(cx, |s, cx| {
                s.running = false;
                for (path, bytes) in fetched {
                    s.fetched += 1;
                    s.queue.keep(path, bytes);
                }
                let report = match failure {
                    Some(error) => {
                        log::warn!("speech: {error}");
                        SpeechReport {
                            id: Some(command.id),
                            ok: false,
                            error: Some(error),
                            ..Default::default()
                        }
                    }
                    None => s.run(&command, cx),
                };
                s.send_report(report, cx);
                s.pump(cx);
            });
        })
        .detach();
    }

    fn run(&mut self, c: &SpeechCommand, cx: &mut Context<Self>) -> SpeechReport {
        use SpeechCommandKind as K;
        let yes = |value: bool| SpeechReport {
            value: Some(value),
            ..Default::default()
        };
        let mut report = match c.kind {
            K::DeviceAvailable => yes(self.voice.available()),
            K::DeviceVoices => SpeechReport {
                voices: crate::shell::speech::voices()
                    .into_iter()
                    .map(|v| SpeechVoice {
                        id: v.id,
                        name: v.name,
                        language: v.language,
                    })
                    .collect(),
                ..Default::default()
            },
            K::DeviceSpeak => {
                if self.spoken.len() >= 32 {
                    self.spoken.remove(0);
                }
                self.spoken
                    .push((c.text.clone().unwrap_or_default(), c.rate.unwrap_or(0.5)));
                yes(self.voice.speak(
                    c.utterance,
                    c.text.as_deref().unwrap_or(""),
                    c.voice.as_deref(),
                    c.rate.unwrap_or(0.5),
                    c.pitch.unwrap_or(1.0),
                    c.volume.unwrap_or(1.0),
                ))
            }
            K::DevicePause => yes(self.voice.pause()),
            K::DeviceResume => yes(self.voice.resume()),
            K::DeviceStop => yes(self.voice.stop()),
            K::PlayerDuration => SpeechReport {
                duration_ms: c
                    .clips
                    .first()
                    .and_then(|p| self.queue.duration_of(p))
                    .map(|d| d.as_millis() as i64),
                ..Default::default()
            },
            K::PlayerSet => {
                let at = Duration::from_millis(c.position_ms.unwrap_or(0).max(0) as u64);
                self.queue
                    .set(c.clips.clone(), c.index.unwrap_or(0).max(0) as usize, at);
                self.queue.report()
            }
            K::PlayerAdd => {
                self.queue.add(c.clips.clone());
                self.queue.report()
            }
            K::PlayerClear => {
                self.queue.clear();
                self.queue.report()
            }
            K::PlayerPlay => {
                self.queue.play();
                self.queue.report()
            }
            K::PlayerPause => {
                self.queue.pause();
                self.queue.report()
            }
            K::PlayerStop => {
                self.queue.stop();
                self.queue.report()
            }
            K::PlayerSeek => {
                let at = Duration::from_millis(c.position_ms.unwrap_or(0).max(0) as u64);
                self.queue.seek(c.index.map(|i| i.max(0) as usize), at);
                self.queue.report()
            }
            K::PlayerSpeed => {
                self.queue.set_speed(c.speed.unwrap_or(1.0));
                self.queue.report()
            }
            K::Unknown => SpeechReport {
                ok: false,
                error: Some("this window does not know that command".into()),
                ..Default::default()
            },
        };
        report.id = Some(c.id);
        self.follow_queue(cx);
        report
    }

    /// Polls the playing clip every 50 ms while one plays: a clip that ends
    /// moves the queue on, and where it is goes to the daemon a few times a
    /// second.
    fn follow_queue(&mut self, cx: &mut Context<Self>) {
        if !self.queue.is_running() || self._ticker.is_some() {
            return;
        }
        self._ticker = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(50))
                    .await;
                let go_on = this
                    .update(cx, |s, cx| {
                        let moved = s.queue.tick();
                        let due = s
                            .last_position_report
                            .is_none_or(|t| t.elapsed() >= Duration::from_millis(250));
                        if moved || due {
                            s.last_position_report = Some(Instant::now());
                            let report = s.queue.report();
                            s.send_report(report, cx);
                        }
                        let running = s.queue.is_running();
                        if !running {
                            s._ticker = None;
                        }
                        running
                    })
                    .unwrap_or(false);
                if !go_on {
                    break;
                }
            }
        }));
    }

    fn send_report(&mut self, report: SpeechReport, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::SpeechReport>(&report);
        cx.background_executor()
            .spawn(async move {
                if let Err(e) = call.await {
                    log::debug!("speech.report: {e}");
                }
            })
            .detach();
    }
}

/// Fetches clip `job` (`GET /tts/{job}`) on the daemon client's tokio
/// runtime, which its HTTP client needs; any executor can await it.
async fn fetch_clip(
    http: conduit_daemon::http::HttpClient,
    job: String,
) -> Result<Vec<u8>, String> {
    let (tx, rx) = futures::channel::oneshot::channel();
    conduit_daemon::runtime::shared().spawn(async move {
        let result = http
            .speech(&job)
            .await
            .map(|f| f.bytes.to_vec())
            .map_err(|e| e.to_string());
        let _ = tx.send(result);
    });
    rx.await
        .unwrap_or_else(|_| Err("the download was dropped".into()))
}

/// Follows `speech.*` events, and catches up on (re)connecting.
pub fn wire(stores: &Stores, cx: &mut App) {
    stores
        .connection
        .update(cx, |c, _| c.subscribe("speech", EVENTS, vec![]));
    let s = stores.speech.clone();
    cx.subscribe(&stores.connection, move |_, event, cx| {
        use super::connection::ConnectionEvent;
        match event {
            ConnectionEvent::Connected { .. } => {
                s.update(cx, |s, cx| s.reconnected(cx));
            }
            ConnectionEvent::Gap => {
                s.update(cx, |s, cx| s.refresh(cx));
            }
            ConnectionEvent::Daemon(event) => match event.as_ref() {
                conduit_protocol::Event::SpeechChanged(progress) => {
                    let progress = progress.clone();
                    s.update(cx, |s, cx| s.apply_progress(progress, cx));
                }
                conduit_protocol::Event::SpeechCommand(command) => {
                    let command = command.clone();
                    s.update(cx, |s, cx| s.on_command(command, cx));
                }
                _ => {}
            },
            ConnectionEvent::LocalDataReset { .. } => {}
        }
    })
    .detach();
    let s = stores.speech.clone();
    crate::shell::now_playing::install(
        move |command, cx| s.update(cx, |s, cx| s.remote(command, cx)),
        cx,
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_pause_or_resume_is_said_once_the_reading_is_so() {
        use SpeechStatus as S;
        // Pause: said when paused; kept while loading; dropped once the
        // reading stopped or failed.
        assert!(Said::Paused.reached(S::Paused) && !Said::Paused.reached(S::Speaking));
        assert!(!Said::Paused.abandoned(S::Loading) && !Said::Paused.abandoned(S::Speaking));
        assert!(Said::Paused.abandoned(S::Idle) && Said::Paused.abandoned(S::Error));
        // Resume: said once it speaks; its own answer may still say paused
        // (the voice answers after), and a server clip may load first.
        assert!(Said::Resumed.reached(S::Speaking) && !Said::Resumed.reached(S::Paused));
        assert!(!Said::Resumed.abandoned(S::Paused) && !Said::Resumed.abandoned(S::Loading));
        assert!(Said::Resumed.abandoned(S::Idle) && Said::Resumed.abandoned(S::Error));
    }

    #[test]
    fn dictation_pauses_a_reading_that_speaks_and_stops_one_starting() {
        use DictationYield::{Pause, Stop};
        assert_eq!(yield_for_dictation(SpeechStatus::Speaking), Some(Pause));
        assert_eq!(yield_for_dictation(SpeechStatus::Loading), Some(Stop));
        assert_eq!(yield_for_dictation(SpeechStatus::Initializing), Some(Stop));
        for left in [
            SpeechStatus::Idle,
            SpeechStatus::Paused,
            SpeechStatus::Error,
        ] {
            assert_eq!(yield_for_dictation(left), None, "{left:?}");
        }
    }

    /// Dictation starts while a Resume is still out: the reading that
    /// speaks after says nothing into the microphone.
    #[gpui_kit::test]
    fn nothing_asked_before_dictation_is_said_into_it(cx: &mut gpui_kit::TestAppContext) {
        use conduit_components::announce::AnnouncementLog;

        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        let scratch =
            std::env::temp_dir().join(format!("conduit-speech-yield-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            AnnouncementLog::install(cx);
            super::super::Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let paused = |status| SpeechProgress {
            status,
            reading: 3,
            message_id: Some("answer-1".into()),
            ..Default::default()
        };
        stores.speech.update(cx, |s, cx| {
            s.progress = paused(SpeechStatus::Paused);
            s.sentences_of = 3;
            // Resume asked; the voice has not answered yet.
            s.expect(Said::Resumed);
            s.yield_to_dictation(cx);
            s.apply_progress(paused(SpeechStatus::Speaking), cx);
        });
        cx.update(|cx| {
            assert_eq!(
                AnnouncementLog::texts(cx),
                Vec::<gpui_kit::SharedString>::new(),
                "said into the dictation"
            )
        });
    }

    /// A restarted daemon numbers its readings from 0 again: the reading
    /// shown before it went is not kept over its answer.
    #[gpui_kit::test]
    fn a_restarted_daemon_ends_the_reading_shown(cx: &mut gpui_kit::TestAppContext) {
        use super::super::connection::ConnectionEvent;
        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::SpeechGet>(SpeechState {
            progress: SpeechProgress::default(),
            sentences: vec![],
        });
        let scratch = std::env::temp_dir().join(format!("conduit-speech-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            let stores = super::super::Stores::for_test(daemon.rpc(), &scratch, cx);
            wire(&stores, cx);
            stores
        });
        // Paused in the third reading of the daemon before.
        stores.speech.update(cx, |s, _| {
            s.progress = SpeechProgress {
                status: SpeechStatus::Paused,
                reading: 3,
                message_id: Some("answer-1".into()),
                ..Default::default()
            };
        });
        stores.connection.update(cx, |_, cx| {
            cx.emit(ConnectionEvent::Connected {
                handshake: Box::new(conduit_daemon::rpc::Handshake::from_value(
                    serde_json::json!({}),
                )),
                request: serde_json::from_value(serde_json::json!({
                    "protocolVersion": "1", "clientName": "test", "clientVersion": "1",
                    "windowKind": "main", "locale": "en"
                }))
                .unwrap(),
            })
        });
        cx.run_until_parked();
        stores.speech.read_with(cx, |s, _| {
            assert_eq!(
                s.progress.status,
                SpeechStatus::Idle,
                "the old reading stayed"
            );
            assert_eq!(s.progress.message_id, None);
        });
    }
}
