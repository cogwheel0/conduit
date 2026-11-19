//! A realtime call's audio in the window: the microphone, made 24 kHz mono
//! and cut into 40 ms frames, and the voice's speech played as it comes, on
//! one echo-cancelled engine (the voice-processing unit), with the reports
//! the daemon's bridge engine reads. It mirrors Open WebUI's
//! `realtime-audio.js` worklet, as the core's `RealtimePcmAudioPort` asks:
//! playback starts once [`START_AFTER`] samples are queued or the response
//! has ended, a hold pauses it without dropping anything, and a clear drops
//! what is queued and says how much of each item was heard.
//!
//! [`Playback`] is the queue and its clock, apart from any device, so it is
//! tested here; [`spawn`] runs it on a thread of its own with the input
//! (the microphone, or a WAV file in a dev build) and the output (the
//! device, or nothing in a dev build, which still keeps time).

use std::collections::{HashSet, VecDeque};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

use futures::channel::mpsc::UnboundedSender;

use super::InputOverride;
use super::pcm::{self, Resampler};

/// The voice's rate, in and out.
pub const RATE: u32 = 24_000;
/// Samples in one microphone frame (40 ms).
pub const FRAME: usize = 960;
/// Samples queued before playback starts, unless the response has ended.
pub const START_AFTER: u64 = 1_920;
/// How often the engine reports.
pub const REPORT_EVERY: Duration = Duration::from_millis(100);

/// What the daemon asks of the audio.
#[derive(Clone, Debug, PartialEq)]
pub enum AudioCommand {
    Capture(bool),
    Enqueue {
        response_id: String,
        item_id: String,
        content_index: i64,
        pcm: Vec<i16>,
    },
    /// No more speech comes for this response.
    End(String),
    /// Holds playback (the user may be starting to speak), or lets it go on.
    Hold(bool),
    Clear(i64),
    Stop,
}

/// How much of one item was heard before a clear.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rendered {
    pub response_id: String,
    pub item_id: String,
    pub content_index: i64,
    pub samples: u64,
}

/// What the audio tells the daemon.
#[derive(Clone, Debug, PartialEq)]
pub enum AudioOut {
    /// The audio runs; played audio takes this long to reach the speaker.
    Started {
        latency_ms: u64,
    },
    /// One microphone frame: 16-bit mono PCM at [`RATE`].
    Frame(Vec<u8>),
    Report {
        clear_id: i64,
        playback_active: bool,
        queued_samples: u64,
        received_samples: u64,
        input_level: f32,
        output_level: f32,
    },
    Cleared {
        clear_id: i64,
        items: Vec<Rendered>,
    },
    /// The audio stopped working (the microphone went away).
    Failure(String),
}

/// One stretch of speech, as queued.
#[derive(Clone, Debug)]
struct Buffer {
    response_id: String,
    item_id: String,
    content_index: i64,
    /// Its samples (kept for the output meter).
    pcm: Vec<i16>,
}

/// The playback queue and its clock: what is queued, what of it has been
/// heard, and whether it plays. The device plays the same buffers in the
/// same order; when it says a buffer is done, the clock follows it.
#[derive(Debug)]
pub struct Playback {
    queue: VecDeque<Buffer>,
    /// Samples received since the last clear.
    since_clear: u64,
    /// Samples received since the audio started: the engine compares what
    /// it sent with this, so a clear must not reset it.
    received: u64,
    /// Samples of buffers heard to their end since the last clear.
    played_whole: u64,
    /// How far into the head buffer it is, and since when it has gone on.
    head_played: u64,
    head_since: Option<Instant>,
    /// Playback has begun (enough queued, or the response ended).
    started: bool,
    held: bool,
    ended: HashSet<String>,
    /// What each item has had heard, in queue order, since the last clear.
    heard: Vec<Rendered>,
    pub clear_id: i64,
    /// Whether speech was heard since the last report.
    active: bool,
}

impl Default for Playback {
    fn default() -> Self {
        Self::new()
    }
}

impl Playback {
    pub fn new() -> Self {
        Self {
            queue: VecDeque::new(),
            since_clear: 0,
            received: 0,
            played_whole: 0,
            head_played: 0,
            head_since: None,
            started: false,
            held: false,
            ended: HashSet::new(),
            heard: vec![],
            clear_id: 0,
            active: false,
        }
    }

    /// Samples waiting to be heard.
    pub fn queued(&self) -> u64 {
        self.since_clear
            .saturating_sub(self.played_whole + self.head_played)
    }

    /// Samples received since the audio started (clears included).
    pub fn received(&self) -> u64 {
        self.received
    }

    /// Whether the device should be playing now.
    pub fn playing(&self) -> bool {
        self.started && !self.held && !self.queue.is_empty()
    }

    /// Queues `pcm` of an item; answers whether playback should begin now.
    pub fn enqueue(
        &mut self,
        response_id: &str,
        item_id: &str,
        content_index: i64,
        pcm: Vec<i16>,
        now: Instant,
    ) -> bool {
        if pcm.is_empty() {
            return false;
        }
        self.since_clear += pcm.len() as u64;
        self.received += pcm.len() as u64;
        self.queue.push_back(Buffer {
            response_id: response_id.to_string(),
            item_id: item_id.to_string(),
            content_index,
            pcm,
        });
        self.maybe_start(response_id, now)
    }

    /// The response has no more speech: what is queued plays.
    pub fn end(&mut self, response_id: &str, now: Instant) -> bool {
        self.ended.insert(response_id.to_string());
        self.maybe_start(response_id, now)
    }

    fn maybe_start(&mut self, response_id: &str, now: Instant) -> bool {
        let was = self.playing();
        if !self.started && (self.queued() >= START_AFTER || self.ended.contains(response_id)) {
            self.started = true;
        }
        if self.playing() && self.head_since.is_none() {
            self.head_since = Some(now);
        }
        !was && self.playing()
    }

    pub fn hold(&mut self, held: bool, now: Instant) {
        if held == self.held {
            return;
        }
        if held {
            self.tick(now, None);
            self.head_since = None;
        }
        self.held = held;
        if !held && self.playing() {
            self.head_since = Some(now);
        }
    }

    /// Moves the clock to `now`: the head buffer plays on, and those heard
    /// to their end leave the queue. `done`: the device finished this many
    /// buffers since the last tick (it keeps the clock honest); without a
    /// device, time alone does.
    pub fn tick(&mut self, now: Instant, done: Option<usize>) {
        if let Some(done) = done {
            for _ in 0..done {
                self.finish_head(now);
            }
        }
        let Some(since) = self.head_since else {
            return;
        };
        if self.held || !self.started {
            return;
        }
        let elapsed = now.saturating_duration_since(since);
        let mut progress = (elapsed.as_secs_f64() * f64::from(RATE)) as u64;
        self.head_since = Some(now);
        while progress > 0 {
            let Some(head) = self.queue.front() else {
                break;
            };
            let len = head.pcm.len() as u64;
            let left = len.saturating_sub(self.head_played);
            let step = progress.min(left);
            self.head_played += step;
            self.note_heard(step);
            progress -= step;
            if self.head_played >= len {
                if done.is_some() {
                    // The device says when it is done with a buffer.
                    break;
                }
                self.finish_head(now);
            }
        }
        if self.queue.is_empty() {
            self.head_since = None;
        }
    }

    fn note_heard(&mut self, samples: u64) {
        if samples == 0 {
            return;
        }
        self.active = true;
        let Some(head) = self.queue.front() else {
            return;
        };
        match self.heard.iter_mut().find(|r| {
            r.response_id == head.response_id
                && r.item_id == head.item_id
                && r.content_index == head.content_index
        }) {
            Some(r) => r.samples += samples,
            None => self.heard.push(Rendered {
                response_id: head.response_id.clone(),
                item_id: head.item_id.clone(),
                content_index: head.content_index,
                samples,
            }),
        }
    }

    fn finish_head(&mut self, now: Instant) {
        let Some(len) = self.queue.front().map(|h| h.pcm.len() as u64) else {
            return;
        };
        let rest = len.saturating_sub(self.head_played);
        self.note_heard(rest);
        self.queue.pop_front();
        self.played_whole += len;
        self.head_played = 0;
        self.head_since = (!self.queue.is_empty() && !self.held).then_some(now);
    }

    /// Drops what is queued; answers how much of each item was heard.
    pub fn clear(&mut self, clear_id: i64, now: Instant) -> Vec<Rendered> {
        self.tick(now, None);
        let heard = std::mem::take(&mut self.heard);
        self.queue.clear();
        self.since_clear = 0;
        self.played_whole = 0;
        self.head_played = 0;
        self.head_since = None;
        self.started = false;
        self.ended.clear();
        self.clear_id = clear_id;
        heard
    }

    /// The loudness of what is being heard, 0 to 1.
    pub fn output_level(&self) -> f32 {
        if !self.playing() {
            return 0.0;
        }
        let Some(head) = self.queue.front() else {
            return 0.0;
        };
        let at = self.head_played as usize;
        let window = &head.pcm[at.min(head.pcm.len())..(at + 2_400).min(head.pcm.len())];
        let samples: Vec<f32> = window.iter().map(|s| f32::from(*s) / 32_768.0).collect();
        pcm::meter(pcm::level_db(&samples))
    }

    /// Whether speech was heard since the last call (then reset).
    pub fn take_active(&mut self) -> bool {
        std::mem::take(&mut self.active)
    }
}

/// The microphone side: whatever rate the input gives, made 24 kHz mono and
/// cut into [`FRAME`]s of 16-bit PCM.
pub struct Framer {
    resampler: Option<Resampler>,
    pending: Vec<f32>,
}

impl Default for Framer {
    fn default() -> Self {
        Self::new()
    }
}

impl Framer {
    pub fn new() -> Self {
        Self {
            resampler: None,
            pending: vec![],
        }
    }

    /// Takes `samples` at `rate`; answers the whole frames now ready.
    pub fn push(&mut self, samples: &[f32], rate: u32) -> Vec<Vec<u8>> {
        if self
            .resampler
            .as_ref()
            .is_none_or(|r| r.input_rate() != rate)
        {
            self.resampler = Some(Resampler::to(rate, RATE));
        }
        let resampled = self
            .resampler
            .as_mut()
            .map(|r| r.push(samples))
            .unwrap_or_default();
        self.pending.extend_from_slice(&resampled);
        let mut frames = vec![];
        while self.pending.len() >= FRAME {
            let frame: Vec<f32> = self.pending.drain(..FRAME).collect();
            frames.push(pcm::to_pcm16(&frame));
        }
        frames
    }
}

/// 16-bit little-endian PCM as samples.
pub fn samples_of(bytes: &[u8]) -> Vec<i16> {
    bytes
        .as_chunks::<2>()
        .0
        .iter()
        .map(|b| i16::from_le_bytes(*b))
        .collect()
}

// ── The engine thread ─────────────────────────────────────────────────

/// What the engine thread hears.
pub enum EngineMsg {
    Command(AudioCommand),
    /// Microphone samples (mono) at a rate.
    Samples(Vec<f32>, u32),
    /// The device finished playing a buffer scheduled since its last stop
    /// (the stop's number: a stopped buffer's late word is dropped).
    Played(u64),
    InputFailed(String),
}

/// The device's side of playback.
pub trait Speaker {
    /// Plays `pcm` (24 kHz mono) after what is queued; tells the engine
    /// [`EngineMsg::Played`] once it has been heard.
    fn schedule(&mut self, pcm: &[i16]);
    fn play(&mut self);
    fn pause(&mut self);
    /// Drops everything scheduled; later buffers belong to the next
    /// generation.
    fn stop(&mut self);
    fn latency(&self) -> Duration;
}

/// Something that started the microphone; dropping it stops it.
pub trait Microphone {}

/// Where the audio goes and comes from.
pub struct Devices {
    pub microphone: Box<dyn Microphone>,
    /// None: nothing is played, but time is kept (a dev build's
    /// `CONDUIT_SPEECH_OUTPUT=null`).
    pub speaker: Option<Box<dyn Speaker>>,
}

/// Makes the devices on the engine thread, feeding it through the sender.
pub type DevicesFactory = Box<dyn FnOnce(Sender<EngineMsg>) -> Result<Devices, String> + Send>;

/// The window's handle on the engine thread.
pub struct AudioHandle {
    tx: Sender<EngineMsg>,
}

impl AudioHandle {
    pub fn send(&self, command: AudioCommand) {
        let _ = self.tx.send(EngineMsg::Command(command));
    }
}

impl Drop for AudioHandle {
    fn drop(&mut self) {
        let _ = self.tx.send(EngineMsg::Command(AudioCommand::Stop));
    }
}

/// The microphone's way to the voice: frames while capture is on, none
/// while it is off.
pub struct Capture {
    on: bool,
    framer: Framer,
}

impl Default for Capture {
    fn default() -> Self {
        Self::new()
    }
}

impl Capture {
    pub fn new() -> Self {
        Self {
            on: false,
            framer: Framer::new(),
        }
    }

    pub fn on(&self) -> bool {
        self.on
    }

    pub fn set(&mut self, on: bool) {
        // Turned on or off: what the framer holds of the time before is
        // not sent with what comes next.
        if on != self.on {
            self.framer = Framer::new();
        }
        self.on = on;
    }

    /// The whole frames `samples` make, to send (none while off).
    pub fn push(&mut self, samples: &[f32], rate: u32) -> Vec<Vec<u8>> {
        if !self.on {
            return vec![];
        }
        self.framer.push(samples, rate)
    }
}

/// Starts the audio on a thread of its own; what it says goes to `out`
/// ([`AudioOut::Started`] first, or [`AudioOut::Failure`]).
pub fn spawn(devices: DevicesFactory, out: UnboundedSender<AudioOut>) -> AudioHandle {
    let (tx, rx) = mpsc::channel();
    let worker = tx.clone();
    let _ = std::thread::Builder::new()
        .name("conduit-call-audio".into())
        .spawn(move || run(devices, worker, rx, out));
    AudioHandle { tx }
}

fn run(
    devices: DevicesFactory,
    tx: Sender<EngineMsg>,
    rx: Receiver<EngineMsg>,
    out: UnboundedSender<AudioOut>,
) {
    let mut devices = match devices(tx) {
        Ok(devices) => devices,
        Err(e) => {
            let _ = out.unbounded_send(AudioOut::Failure(e));
            return;
        }
    };
    let latency = devices
        .speaker
        .as_ref()
        .map(|s| s.latency())
        .unwrap_or_default();
    let _ = out.unbounded_send(AudioOut::Started {
        latency_ms: latency.as_millis() as u64,
    });
    let mut playback = Playback::new();
    let mut capture = Capture::new();
    let mut input_level = 0.0f32;
    let mut played = 0usize;
    // Bumped by each stop, so buffers it dropped are not counted as heard.
    let mut generation = 0u64;
    let mut last_report = Instant::now();
    loop {
        let message = rx.recv_timeout(Duration::from_millis(20));
        let now = Instant::now();
        match message {
            Ok(EngineMsg::Command(command)) => match command {
                AudioCommand::Capture(on) => capture.set(on),
                AudioCommand::Enqueue {
                    response_id,
                    item_id,
                    content_index,
                    pcm,
                } => {
                    if let Some(speaker) = devices.speaker.as_mut() {
                        speaker.schedule(&pcm);
                    }
                    if playback.enqueue(&response_id, &item_id, content_index, pcm, now)
                        && let Some(speaker) = devices.speaker.as_mut()
                    {
                        speaker.play();
                    }
                }
                AudioCommand::End(response_id) => {
                    if playback.end(&response_id, now)
                        && let Some(speaker) = devices.speaker.as_mut()
                    {
                        speaker.play();
                    }
                }
                AudioCommand::Hold(held) => {
                    playback.hold(held, now);
                    if let Some(speaker) = devices.speaker.as_mut() {
                        if held {
                            speaker.pause();
                        } else if playback.playing() {
                            speaker.play();
                        }
                    }
                }
                AudioCommand::Clear(clear_id) => {
                    if let Some(speaker) = devices.speaker.as_mut() {
                        speaker.stop();
                    }
                    generation += 1;
                    played = 0;
                    let items = playback.clear(clear_id, now);
                    let _ = out.unbounded_send(AudioOut::Cleared { clear_id, items });
                }
                AudioCommand::Stop => break,
            },
            Ok(EngineMsg::Samples(samples, rate)) => {
                input_level = pcm::meter(pcm::level_db(&samples)).max(input_level * 0.7);
                for frame in capture.push(&samples, rate) {
                    if out.unbounded_send(AudioOut::Frame(frame)).is_err() {
                        break;
                    }
                }
            }
            Ok(EngineMsg::Played(of)) => {
                if of == generation {
                    played += 1;
                }
            }
            Ok(EngineMsg::InputFailed(e)) => {
                let _ = out.unbounded_send(AudioOut::Failure(e));
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
        let device = devices.speaker.is_some();
        playback.tick(now, device.then(|| std::mem::take(&mut played)));
        if now.duration_since(last_report) >= REPORT_EVERY {
            last_report = now;
            let report = AudioOut::Report {
                clear_id: playback.clear_id,
                playback_active: playback.take_active(),
                queued_samples: playback.queued(),
                received_samples: playback.received(),
                input_level: if capture.on() { input_level } else { 0.0 },
                output_level: playback.output_level(),
            };
            input_level *= 0.5;
            if out.unbounded_send(report).is_err() {
                break;
            }
        }
    }
    if let Some(speaker) = devices.speaker.as_mut() {
        speaker.stop();
    }
    drop(devices);
}

/// The audio a call runs on: the override's input (a WAV file stands in for
/// the microphone in a dev build), else the microphone; the device's
/// speaker, unless `muted` (nothing played, time still kept).
pub fn devices(over: Option<InputOverride>, muted: bool) -> DevicesFactory {
    Box::new(move |tx: Sender<EngineMsg>| match over {
        Some(InputOverride::Denied) => Err("the microphone is not allowed".into()),
        Some(InputOverride::File(path)) => {
            let microphone = file_microphone(&path, tx.clone())?;
            #[cfg(target_os = "macos")]
            let speaker: Option<Box<dyn Speaker>> = if muted {
                None
            } else {
                Some(Box::new(super::realtime_mac::DeviceSpeaker::new(tx)?))
            };
            #[cfg(not(target_os = "macos"))]
            let speaker: Option<Box<dyn Speaker>> = {
                let _ = (tx, muted);
                None
            };
            Ok(Devices {
                microphone,
                speaker,
            })
        }
        None => {
            #[cfg(target_os = "macos")]
            {
                super::realtime_mac::devices(tx, muted)
            }
            #[cfg(not(target_os = "macos"))]
            {
                let _ = (tx, muted);
                Err("realtime calls need macOS".into())
            }
        }
    })
}

/// A WAV file played into the call in real time, then silence: a dev
/// build's stand-in for the microphone.
fn file_microphone(
    path: &std::path::Path,
    tx: Sender<EngineMsg>,
) -> Result<Box<dyn Microphone>, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let (samples, rate) = pcm::decode_wav(&bytes)?;
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = stop.clone();
    std::thread::Builder::new()
        .name("conduit-call-file".into())
        .spawn(move || {
            let piece = (rate as usize / 25).max(1);
            let quiet = vec![0.0f32; piece];
            let started = Instant::now();
            let pieces = samples
                .chunks(piece)
                .map(<[f32]>::to_vec)
                .chain(std::iter::repeat(quiet));
            for (i, samples) in pieces.enumerate() {
                if flag.load(std::sync::atomic::Ordering::SeqCst) {
                    return;
                }
                if tx.send(EngineMsg::Samples(samples, rate)).is_err() {
                    return;
                }
                let due = started + Duration::from_millis(40 * (i as u64 + 1));
                std::thread::sleep(due.saturating_duration_since(Instant::now()));
            }
        })
        .map_err(|e| e.to_string())?;
    Ok(Box::new(FileMicrophone { stop }))
}

struct FileMicrophone {
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

impl Microphone for FileMicrophone {}

impl Drop for FileMicrophone {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::SeqCst);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    fn tone(samples: usize) -> Vec<i16> {
        (0..samples)
            .map(|i| ((i as f32 * 0.2).sin() * 8_000.0) as i16)
            .collect()
    }

    #[test]
    fn playback_waits_for_enough_speech_or_the_end_of_the_response() {
        let t0 = Instant::now();
        let mut p = Playback::new();
        assert!(!p.enqueue("r1", "i1", 0, tone(960), t0));
        assert!(!p.playing());
        // 1 920 samples queued: it plays.
        assert!(p.enqueue("r1", "i1", 0, tone(960), t0));
        assert!(p.playing());

        let mut q = Playback::new();
        q.enqueue("r2", "i2", 0, tone(480), t0);
        assert!(!q.playing());
        // A short reply plays once it has ended.
        assert!(q.end("r2", t0));
        assert!(q.playing());
    }

    #[test]
    fn time_plays_the_queue_and_a_clear_says_what_was_heard() {
        let t0 = Instant::now();
        let mut p = Playback::new();
        p.enqueue("r1", "i1", 0, tone(2_400), t0);
        p.enqueue("r1", "i2", 0, tone(2_400), t0);
        assert_eq!(p.queued(), 4_800);
        // 150 ms at 24 kHz: 3 600 samples, the first item and half the next.
        p.tick(t0 + ms(150), None);
        assert_eq!(p.queued(), 1_200);
        assert!(p.take_active());
        let heard = p.clear(1, t0 + ms(150));
        assert_eq!(heard.len(), 2);
        assert_eq!((heard[0].item_id.as_str(), heard[0].samples), ("i1", 2_400));
        assert_eq!((heard[1].item_id.as_str(), heard[1].samples), ("i2", 1_200));
        assert_eq!(p.queued(), 0);
        // Received counts on from the start: the engine compares what it
        // sent with it.
        assert_eq!(p.received(), 4_800);
        assert_eq!(p.clear_id, 1);
        p.enqueue("r2", "i3", 0, tone(960), t0 + ms(150));
        assert_eq!(p.received(), 5_760);
        assert_eq!(p.queued(), 960);
        assert!(!p.playing());
    }

    #[test]
    fn a_hold_stops_the_clock_without_dropping_anything() {
        let t0 = Instant::now();
        let mut p = Playback::new();
        p.enqueue("r1", "i1", 0, tone(4_800), t0);
        p.tick(t0 + ms(50), None);
        assert_eq!(p.queued(), 3_600);
        p.hold(true, t0 + ms(50));
        p.tick(t0 + ms(500), None);
        assert_eq!(p.queued(), 3_600, "held: nothing plays");
        p.hold(false, t0 + ms(500));
        p.tick(t0 + ms(550), None);
        assert_eq!(p.queued(), 2_400);
    }

    #[test]
    fn the_device_says_when_a_buffer_is_done() {
        let t0 = Instant::now();
        let mut p = Playback::new();
        p.enqueue("r1", "i1", 0, tone(2_400), t0);
        p.enqueue("r1", "i2", 0, tone(2_400), t0);
        // The clock alone stops at the end of a buffer the device has not
        // finished.
        p.tick(t0 + ms(200), Some(0));
        assert_eq!(p.queued(), 2_400);
        p.tick(t0 + ms(210), Some(1));
        assert_eq!(p.queued(), 2_400);
        // The next buffer plays on from there.
        p.tick(t0 + ms(260), Some(0));
        assert_eq!(p.queued(), 1_200);
    }

    /// Unmuted, only what is said from then on goes: nothing heard while
    /// muted is sent with the first frame.
    #[test]
    fn nothing_said_while_muted_goes_out_after() {
        let mut capture = Capture::new();
        capture.set(true);
        assert_eq!(capture.push(&vec![0.1f32; FRAME], RATE).len(), 1);
        capture.set(false);
        // Muted: half a frame of words that must stay here.
        assert!(capture.push(&vec![0.5f32; FRAME / 2], RATE).is_empty());
        capture.set(true);
        let frames = capture.push(&vec![-0.25f32; FRAME], RATE);
        assert_eq!(frames.len(), 1);
        assert!(
            samples_of(&frames[0]).iter().all(|&s| s < 0),
            "words said while muted went out after it"
        );
    }

    #[test]
    fn the_microphone_becomes_40_ms_frames_at_24_khz() {
        let mut framer = Framer::new();
        // 100 ms at 48 kHz: about 2 400 samples out (less the kernel's
        // lead-in), two frames and some over.
        let frames = framer.push(&vec![0.1f32; 4_800], 48_000);
        assert_eq!(frames.len(), 2);
        assert!(frames.iter().all(|f| f.len() == FRAME * 2));
        // 200 ms in all: five frames' worth, less the lead-in.
        let more = framer.push(&vec![0.1f32; 4_800], 48_000);
        assert_eq!(frames.len() + more.len(), 4);
        assert_eq!(samples_of(&[1, 0, 255, 255]), vec![1, -1]);
    }
}
