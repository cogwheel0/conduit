//! One dictation, on a thread of its own: the input (the microphone, or a
//! WAV file standing in for it) is made 16 kHz mono, then metered, cut into
//! one-second chunks for the recording, watched for the pause that ends it
//! ([`super::vad`]), and handed to this Mac's recognizer when that is the
//! engine. Nothing here runs on the UI thread; the window hears it all as
//! [`SessionEvent`]s.
//!
//! The input and the recognizer are made on this thread by factories:
//! their AppKit objects never cross threads, and tests stand fakes in.

use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

use futures::channel::mpsc::UnboundedSender;

use super::pcm::{self, BYTES_PER_SECOND, Resampler};
use super::vad::{Endpointer, Verdict};

/// What the thread hears: from the input, the recognizer and the window.
#[derive(Debug)]
pub enum WorkerMsg {
    /// More audio: mono samples at `rate`.
    Audio {
        samples: Vec<f32>,
        rate: u32,
    },
    /// The default input device changed: start it again.
    InputChanged,
    /// A file input ran out.
    InputEnded,
    InputFailed(InputError),
    /// The recognizer's words so far (`is_final`: its last word on them).
    Words {
        text: String,
        is_final: bool,
    },
    RecognizerFailed(String),
    /// The recognizer heard no speech in a while (it may say so on its
    /// own, before the pause would).
    NoSpeech,
    /// The window's Stop: transcribe what was said.
    Stop,
    /// The window's Cancel: drop it.
    Cancel,
}

/// Why the input could not start or went away.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InputError {
    /// The user said no (System Settings › Privacy & Security).
    Denied,
    /// No input device, or it would not start.
    Unavailable(String),
}

/// A running input.
pub trait Input {
    /// The default device changed: pick the new one up.
    fn restart(&mut self) -> Result<(), InputError>;
    fn stop(&mut self);
}

/// This Mac's recognizer, fed as the audio comes.
pub trait Recognizer {
    fn append(&mut self, samples: &[f32]);
    /// No more audio: say the last words.
    fn finish(&mut self);
    fn cancel(&mut self);
}

pub type InputFactory =
    Box<dyn FnOnce(Sender<WorkerMsg>) -> Result<Box<dyn Input>, InputError> + Send>;
pub type RecognizerFactory =
    Box<dyn FnOnce(Sender<WorkerMsg>) -> Result<Box<dyn Recognizer>, SessionError> + Send>;

/// How a dictation ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EndReason {
    /// The window's Stop.
    Stopped,
    /// The pause after speech.
    Silence,
    /// No speech in the wait.
    NothingHeard,
    /// Ten minutes.
    Limit,
    /// The file input ran out.
    InputEnded,
    Cancelled,
}

/// What the window hears.
#[derive(Clone, Debug, PartialEq)]
pub enum SessionEvent {
    /// The input is open and listening.
    Started,
    /// The meter, 0..1, about every 50 ms of audio.
    Level(f32),
    /// The next second (or the last part) of the recording: 16 kHz mono
    /// 16-bit PCM.
    Chunk(Vec<u8>),
    /// This Mac's recognizer's words so far.
    Partial(String),
    /// Over: the recognizer's last words (empty for the server's engines,
    /// and when nothing was heard), whether speech was heard, and for the
    /// server's engines every sample, as 16-bit PCM.
    Ended {
        reason: EndReason,
        text: String,
        heard: bool,
        pcm: Option<Vec<u8>>,
    },
    /// It could not go on: the input or the recognizer failed.
    Failed(SessionError),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionError {
    Input(InputError),
    /// This Mac's recognizer is off (System Settings › Privacy & Security
    /// › Speech Recognition).
    SpeechDenied,
    /// This Mac cannot recognize this language on its own (`locale`).
    NotOnThisMac(String),
    Recognizer(String),
}

#[derive(Clone, Debug)]
pub struct SessionConfig {
    /// The pause that ends it (Settings › Audio).
    pub pause_ms: u32,
    /// How long it waits for speech (the phone's 90 s).
    pub no_speech_ms: u32,
    /// The longest one (the phone's ten minutes, the recordings' limit).
    pub limit_ms: u32,
    /// Keep every sample for a server's or whisper's transcription.
    pub keep_pcm: bool,
    /// How long the recognizer may take over its last words.
    pub final_wait: Duration,
}

impl SessionConfig {
    pub fn new(pause_ms: u32, keep_pcm: bool) -> Self {
        Self {
            pause_ms,
            no_speech_ms: 90_000,
            limit_ms: 600_000,
            keep_pcm,
            final_wait: Duration::from_millis(2_500),
        }
    }
}

/// The window's handle on a running dictation.
pub struct Session {
    control: Sender<WorkerMsg>,
}

impl Session {
    /// Starts one on its own thread.
    pub fn spawn(
        config: SessionConfig,
        input: InputFactory,
        recognizer: Option<RecognizerFactory>,
        events: UnboundedSender<SessionEvent>,
    ) -> Self {
        let (tx, rx) = mpsc::channel();
        let worker_tx = tx.clone();
        let _ = std::thread::Builder::new()
            .name("conduit-dictation".into())
            .spawn(move || run(config, input, recognizer, worker_tx, rx, events));
        Self { control: tx }
    }

    /// Ends it and transcribes what was said.
    pub fn stop(&self) {
        let _ = self.control.send(WorkerMsg::Stop);
    }

    /// Ends it and drops what was said.
    pub fn cancel(&self) {
        let _ = self.control.send(WorkerMsg::Cancel);
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        // A dictation nobody holds is over.
        let _ = self.control.send(WorkerMsg::Cancel);
    }
}

struct Worker {
    config: SessionConfig,
    events: UnboundedSender<SessionEvent>,
    resampler: Option<Resampler>,
    endpointer: Endpointer,
    chunk: Vec<u8>,
    all: Vec<u8>,
    meter_samples: usize,
    meter_peak: f32,
    words: String,
}

fn run(
    config: SessionConfig,
    input: InputFactory,
    recognizer: Option<RecognizerFactory>,
    tx: Sender<WorkerMsg>,
    rx: Receiver<WorkerMsg>,
    events: UnboundedSender<SessionEvent>,
) {
    pool(|| {
        let mut w = Worker {
            endpointer: Endpointer::new(config.pause_ms, config.no_speech_ms, config.limit_ms),
            config,
            events,
            resampler: None,
            chunk: Vec::with_capacity(BYTES_PER_SECOND),
            all: vec![],
            meter_samples: 0,
            meter_peak: 0.0,
            words: String::new(),
        };
        let mut recognizer = match recognizer.map(|make| make(tx.clone())) {
            None => None,
            Some(Ok(r)) => Some(r),
            Some(Err(e)) => {
                w.send(SessionEvent::Failed(e));
                return;
            }
        };
        let mut input = match input(tx.clone()) {
            Ok(input) => input,
            Err(e) => {
                if let Some(r) = recognizer.as_mut() {
                    r.cancel();
                }
                w.send(SessionEvent::Failed(SessionError::Input(e)));
                return;
            }
        };
        w.send(SessionEvent::Started);
        let ending = loop {
            let msg = match rx.recv_timeout(Duration::from_millis(250)) {
                Ok(msg) => msg,
                Err(RecvTimeoutError::Timeout) => continue,
                Err(RecvTimeoutError::Disconnected) => break Some(EndReason::Cancelled),
            };
            match pool(|| w.handle(msg, &mut recognizer, input.as_mut())) {
                Step::Go => {}
                Step::End(reason) => break Some(reason),
                Step::Fail(e) => {
                    input.stop();
                    if let Some(r) = recognizer.as_mut() {
                        r.cancel();
                    }
                    w.send(SessionEvent::Failed(e));
                    break None;
                }
            }
        };
        let Some(reason) = ending else {
            return;
        };
        input.stop();
        if reason == EndReason::Cancelled {
            if let Some(r) = recognizer.as_mut() {
                r.cancel();
            }
            w.send(SessionEvent::Ended {
                reason,
                text: String::new(),
                heard: w.endpointer.heard(),
                pcm: None,
            });
            return;
        }
        // What is left of the recording.
        if !w.chunk.is_empty() {
            let rest = std::mem::take(&mut w.chunk);
            w.send(SessionEvent::Chunk(rest));
        }
        let mut text = String::new();
        if let Some(r) = recognizer.as_mut() {
            r.finish();
            text = w.words.clone();
            let deadline = Instant::now() + w.config.final_wait;
            loop {
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    break;
                }
                match rx.recv_timeout(left) {
                    Ok(WorkerMsg::Words { text: t, is_final }) => {
                        text = t;
                        if is_final {
                            break;
                        }
                    }
                    // "No speech detected" and the like, at the end: what
                    // was said so far is the answer.
                    Ok(WorkerMsg::RecognizerFailed(_) | WorkerMsg::NoSpeech) => break,
                    Ok(WorkerMsg::Cancel) => {
                        r.cancel();
                        w.send(SessionEvent::Ended {
                            reason: EndReason::Cancelled,
                            text: String::new(),
                            heard: w.endpointer.heard(),
                            pcm: None,
                        });
                        return;
                    }
                    Ok(_) => {}
                    Err(_) => break,
                }
            }
        }
        let heard = w.endpointer.heard() || !text.trim().is_empty();
        let pcm = w.config.keep_pcm.then(|| std::mem::take(&mut w.all));
        w.send(SessionEvent::Ended {
            reason,
            text: text.trim().to_string(),
            heard,
            pcm,
        });
    });
}

enum Step {
    Go,
    End(EndReason),
    Fail(SessionError),
}

impl Worker {
    fn send(&self, event: SessionEvent) {
        let _ = self.events.unbounded_send(event);
    }

    fn handle(
        &mut self,
        msg: WorkerMsg,
        recognizer: &mut Option<Box<dyn Recognizer>>,
        input: &mut dyn Input,
    ) -> Step {
        match msg {
            WorkerMsg::Audio { samples, rate } => self.audio(&samples, rate, recognizer),
            WorkerMsg::InputChanged => match input.restart() {
                Ok(()) => Step::Go,
                Err(e) => Step::Fail(SessionError::Input(e)),
            },
            WorkerMsg::InputEnded => Step::End(EndReason::InputEnded),
            WorkerMsg::InputFailed(e) => Step::Fail(SessionError::Input(e)),
            WorkerMsg::Words { text, .. } => {
                if text != self.words {
                    self.words = text.clone();
                    self.endpointer.note_words();
                    self.send(SessionEvent::Partial(text));
                }
                Step::Go
            }
            WorkerMsg::RecognizerFailed(e) => Step::Fail(SessionError::Recognizer(e)),
            // Before anything was said it changes nothing: the pause and the
            // wait for speech decide.
            WorkerMsg::NoSpeech => Step::Go,
            WorkerMsg::Stop => Step::End(EndReason::Stopped),
            WorkerMsg::Cancel => Step::End(EndReason::Cancelled),
        }
    }

    fn audio(
        &mut self,
        samples: &[f32],
        rate: u32,
        recognizer: &mut Option<Box<dyn Recognizer>>,
    ) -> Step {
        if self.resampler.as_ref().map(Resampler::input_rate) != Some(rate) {
            // A new device can run at another rate.
            self.resampler = Some(Resampler::new(rate));
        }
        let Some(resampler) = self.resampler.as_mut() else {
            return Step::Go;
        };
        let mono = resampler.push(samples);
        if mono.is_empty() {
            return Step::Go;
        }
        if let Some(r) = recognizer {
            r.append(&mono);
        }
        let bytes = pcm::to_pcm16(&mono);
        if self.config.keep_pcm {
            self.all.extend_from_slice(&bytes);
        }
        self.chunk.extend_from_slice(&bytes);
        while self.chunk.len() >= BYTES_PER_SECOND {
            let rest = self.chunk.split_off(BYTES_PER_SECOND);
            let full = std::mem::replace(&mut self.chunk, rest);
            self.send(SessionEvent::Chunk(full));
        }
        // The meter: the loudest 20 ms of each 50 ms, as a 0..1 reading.
        let verdict = self.meter_and_endpoint(&mono);
        match verdict {
            Verdict::Listening => Step::Go,
            Verdict::EndOfSpeech => Step::End(EndReason::Silence),
            Verdict::NothingHeard => Step::End(EndReason::NothingHeard),
            Verdict::Limit => Step::End(EndReason::Limit),
        }
    }

    fn meter_and_endpoint(&mut self, mono: &[f32]) -> Verdict {
        let mut verdict = Verdict::Listening;
        for piece in mono.chunks(320) {
            let v = self.endpointer.push(piece);
            if verdict == Verdict::Listening {
                verdict = v;
            }
            self.meter_peak = self.meter_peak.max(pcm::meter(pcm::level_db(piece)));
            self.meter_samples += piece.len();
            if self.meter_samples >= 800 {
                let level = std::mem::take(&mut self.meter_peak);
                self.meter_samples = 0;
                self.send(SessionEvent::Level(level));
            }
        }
        verdict
    }
}

/// Runs `f` inside an autorelease pool on macOS (this thread is not
/// AppKit's, and the frameworks autorelease as they go).
fn pool<R>(f: impl FnOnce() -> R) -> R {
    #[cfg(target_os = "macos")]
    {
        objc2::rc::autoreleasepool(|_| f())
    }
    #[cfg(not(target_os = "macos"))]
    {
        f()
    }
}

/// A WAV file standing in for the microphone (dev and E2E builds only:
/// `CONDUIT_DICTATION_INPUT`): its audio in 100 ms pieces at the pace it
/// would be spoken, then the quiet of an empty room until the window or
/// the pause ends it, or `tail` runs out.
pub fn file_input(path: std::path::PathBuf, tail: Duration) -> InputFactory {
    Box::new(move |tx: Sender<WorkerMsg>| {
        let bytes = std::fs::read(&path)
            .map_err(|e| InputError::Unavailable(format!("{}: {e}", path.display())))?;
        let (samples, rate) = pcm::decode_wav(&bytes).map_err(InputError::Unavailable)?;
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = stop.clone();
        std::thread::Builder::new()
            .name("conduit-dictation-file".into())
            .spawn(move || {
                let piece = (rate as usize / 10).max(1);
                let quiet = vec![0.0f32; piece];
                let tail_pieces = (tail.as_millis() / 100) as usize;
                let pieces = samples
                    .chunks(piece)
                    .map(<[f32]>::to_vec)
                    .chain(std::iter::repeat_n(quiet, tail_pieces));
                let started = Instant::now();
                for (i, samples) in pieces.enumerate() {
                    if flag.load(std::sync::atomic::Ordering::SeqCst) {
                        return;
                    }
                    if tx.send(WorkerMsg::Audio { samples, rate }).is_err() {
                        return;
                    }
                    // Real time: piece i ends 100 ms × (i + 1) in.
                    let due = started + Duration::from_millis(100 * (i as u64 + 1));
                    std::thread::sleep(due.saturating_duration_since(Instant::now()));
                }
                let _ = tx.send(WorkerMsg::InputEnded);
            })
            .map_err(|e| InputError::Unavailable(e.to_string()))?;
        Ok(Box::new(FileInput { stop }) as Box<dyn Input>)
    })
}

struct FileInput {
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

impl Input for FileInput {
    fn restart(&mut self) -> Result<(), InputError> {
        Ok(())
    }

    fn stop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::SeqCst);
    }
}

/// An input that refuses, as a denied microphone does (the override's
/// `denied`).
pub fn denied_input() -> InputFactory {
    Box::new(|_| Err(InputError::Denied))
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use futures::StreamExt as _;

    use super::*;

    /// Feeds `audio` (16 kHz) in 100 ms pieces, a millisecond apart (so
    /// the recognizer's words land among them), then nothing.
    fn fed(audio: Vec<f32>) -> InputFactory {
        Box::new(move |tx: Sender<WorkerMsg>| {
            std::thread::spawn(move || {
                for piece in audio.chunks(1_600) {
                    let sent = tx.send(WorkerMsg::Audio {
                        samples: piece.to_vec(),
                        rate: 16_000,
                    });
                    if sent.is_err() {
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(1));
                }
            });
            Ok(Box::new(Idle) as Box<dyn Input>)
        })
    }

    struct Idle;
    impl Input for Idle {
        fn restart(&mut self) -> Result<(), InputError> {
            Ok(())
        }
        fn stop(&mut self) {}
    }

    /// Says "hello" once it has heard a second, and "hello there" as its
    /// last words.
    struct Words {
        tx: Sender<WorkerMsg>,
        heard: usize,
        said: bool,
        log: Arc<Mutex<Vec<&'static str>>>,
    }

    impl Recognizer for Words {
        fn append(&mut self, samples: &[f32]) {
            self.heard += samples.len();
            if self.heard >= 16_000 && !self.said {
                self.said = true;
                let _ = self.tx.send(WorkerMsg::Words {
                    text: "hello".into(),
                    is_final: false,
                });
            }
        }
        fn finish(&mut self) {
            self.log.lock().unwrap().push("finish");
            let _ = self.tx.send(WorkerMsg::Words {
                text: "hello there".into(),
                is_final: true,
            });
        }
        fn cancel(&mut self) {
            self.log.lock().unwrap().push("cancel");
        }
    }

    /// A moment of quiet, 2 s of "speech", then quiet.
    fn speech_then_quiet() -> Vec<f32> {
        let mut audio = vec![0.0; 4_800];
        audio.extend(
            (0..32_000).map(|i| (std::f32::consts::TAU * 200.0 * i as f32 / 16_000.0).sin() * 0.3),
        );
        audio.extend(std::iter::repeat_n(0.0, 32_000));
        audio
    }

    fn collect(rx: futures::channel::mpsc::UnboundedReceiver<SessionEvent>) -> Vec<SessionEvent> {
        futures::executor::block_on(rx.collect::<Vec<_>>())
    }

    #[test]
    fn the_pause_ends_it_with_the_recognizers_last_words() {
        let (tx, rx) = futures::channel::mpsc::unbounded();
        let log = Arc::new(Mutex::new(vec![]));
        let words = log.clone();
        let session = Session::spawn(
            SessionConfig::new(1_000, false),
            fed(speech_then_quiet()),
            Some(Box::new(move |tx| {
                Ok(Box::new(Words {
                    tx,
                    heard: 0,
                    said: false,
                    log: words,
                }) as Box<dyn Recognizer>)
            })),
            tx,
        );
        let events = collect(rx);
        drop(session);
        assert_eq!(events[0], SessionEvent::Started);
        assert!(events.contains(&SessionEvent::Partial("hello".into())));
        assert!(
            events
                .iter()
                .any(|e| matches!(e, SessionEvent::Level(l) if *l > 0.5))
        );
        // Two full seconds of speech went out as chunks, then the rest.
        let chunks: Vec<usize> = events
            .iter()
            .filter_map(|e| match e {
                SessionEvent::Chunk(c) => Some(c.len()),
                _ => None,
            })
            .collect();
        assert_eq!(&chunks[..2], &[32_000, 32_000]);
        assert!(chunks.iter().sum::<usize>() < 4 * 32_000);
        assert_eq!(
            events.last(),
            Some(&SessionEvent::Ended {
                reason: EndReason::Silence,
                text: "hello there".into(),
                heard: true,
                pcm: None,
            })
        );
        assert_eq!(*log.lock().unwrap(), vec!["finish"]);
    }

    #[test]
    fn the_servers_engines_get_every_sample() {
        let (tx, rx) = futures::channel::mpsc::unbounded();
        let session = Session::spawn(
            SessionConfig::new(500, true),
            fed(speech_then_quiet()),
            None,
            tx,
        );
        let events = collect(rx);
        drop(session);
        let Some(SessionEvent::Ended {
            reason, pcm, heard, ..
        }) = events.last()
        else {
            panic!("{events:?}");
        };
        assert_eq!(*reason, EndReason::Silence);
        assert!(*heard);
        let pcm = pcm.as_ref().unwrap();
        // 0.3 s of quiet, 2 s of speech and the 0.5 s pause, give or take
        // a frame.
        assert!((89_000..=92_000).contains(&pcm.len()), "{}", pcm.len());
    }

    #[test]
    fn stop_and_cancel_from_the_window() {
        let (tx, rx) = futures::channel::mpsc::unbounded();
        let session = Session::spawn(
            SessionConfig::new(5_000, true),
            Box::new(|_| Ok(Box::new(Idle) as Box<dyn Input>)),
            None,
            tx,
        );
        session.stop();
        let events = collect(rx);
        assert!(matches!(
            events.last(),
            Some(SessionEvent::Ended {
                reason: EndReason::Stopped,
                heard: false,
                ..
            })
        ));

        let (tx, rx) = futures::channel::mpsc::unbounded();
        let log = Arc::new(Mutex::new(vec![]));
        let words = log.clone();
        let session = Session::spawn(
            SessionConfig::new(5_000, true),
            Box::new(|_| Ok(Box::new(Idle) as Box<dyn Input>)),
            Some(Box::new(move |tx| {
                Ok(Box::new(Words {
                    tx,
                    heard: 0,
                    said: false,
                    log: words,
                }) as Box<dyn Recognizer>)
            })),
            tx,
        );
        session.cancel();
        let events = collect(rx);
        assert!(matches!(
            events.last(),
            Some(SessionEvent::Ended {
                reason: EndReason::Cancelled,
                pcm: None,
                ..
            })
        ));
        assert_eq!(*log.lock().unwrap(), vec!["cancel"]);
    }

    #[test]
    fn a_denied_microphone_fails_at_once() {
        let (tx, rx) = futures::channel::mpsc::unbounded();
        let session = Session::spawn(SessionConfig::new(1_000, false), denied_input(), None, tx);
        let events = collect(rx);
        drop(session);
        assert_eq!(
            events,
            vec![SessionEvent::Failed(SessionError::Input(
                InputError::Denied
            ))]
        );
    }

    #[test]
    fn a_wav_file_stands_in_for_the_microphone() {
        let dir = std::env::temp_dir().join(format!("conduit-dictation-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("speech.wav");
        // 0.3 s of quiet, then 0.6 s of tone, at 44.1 kHz.
        let tone: Vec<f32> = std::iter::repeat_n(0.0, 13_230)
            .chain(
                (0..26_460)
                    .map(|i| (std::f32::consts::TAU * 220.0 * i as f32 / 44_100.0).sin() * 0.4),
            )
            .collect();
        let mut pcm16 = vec![];
        for s in &tone {
            pcm16.extend_from_slice(&((s * 32767.0) as i16).to_le_bytes());
        }
        let mut file = pcm::wav(&pcm16);
        // Re-label it 44.1 kHz.
        file[24..28].copy_from_slice(&44_100u32.to_le_bytes());
        file[28..32].copy_from_slice(&(44_100u32 * 2).to_le_bytes());
        std::fs::write(&path, &file).unwrap();
        let (tx, rx) = futures::channel::mpsc::unbounded();
        let session = Session::spawn(
            SessionConfig::new(300, true),
            file_input(path, Duration::from_secs(2)),
            None,
            tx,
        );
        let events = collect(rx);
        drop(session);
        let Some(SessionEvent::Ended { reason, pcm, .. }) = events.last() else {
            panic!("{events:?}");
        };
        assert_eq!(*reason, EndReason::Silence);
        // 0.9 s at 16 kHz, plus the pause.
        let len = pcm.as_ref().unwrap().len();
        assert!((37_000..=42_000).contains(&len), "{len}");
    }
}
