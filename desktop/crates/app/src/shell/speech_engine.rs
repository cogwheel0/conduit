//! The window's half of read aloud. The daemon runs the reading (the
//! core's manager: sentences, queue, state) and puts each step to this
//! engine as `speech.command`; this says it with the Mac's voices
//! (`AVSpeechSynthesizer`, which reports each word), or plays the server's
//! speech (`AVAudioPlayer`, one clip per sentence, fetched from the
//! daemon's `/tts/{job}`), and reports back with `speech.report`.
//!
//! [`ClipQueue`] is the player's queue, as core's `AudioPlaybackPort`
//! expects one to behave (just_audio's: a clip that ends moves to the next,
//! the last one leaves the queue `completed` until it is moved or given
//! more). It drives [`ClipOutput`]s: `AVAudioPlayer` on macOS, a clock in
//! tests.
//!
//! **In a call.** While a Standard voice call is on, what is said plays on
//! the call's own engine ([`crate::voice::call_audio`]), whose microphone
//! runs through voice processing: the Mac's voice is written to samples
//! (`AVSpeechSynthesizer.write`) and the server's clips decoded, both played
//! on its player node, so the call does not hear its answer as the user's
//! words. The reports are the same, `complete` once the last of it was
//! heard; words are not reported there (nothing in a call shows them).
//!
//! **Null sink.** `CONDUIT_SPEECH_OUTPUT=null` (dev and E2E only) speaks
//! and plays everything at volume 0: the voices still report their words
//! and the clips still run their length, so a test hears nothing while the
//! reading moves on exactly as it would.

use std::collections::HashMap;
use std::time::Duration;

use conduit_protocol::{SpeechPlayerState, SpeechReport, SpeechReportKind};

/// Whether this run plays nothing aloud (`CONDUIT_SPEECH_OUTPUT=null`).
pub fn muted() -> bool {
    std::env::var("CONDUIT_SPEECH_OUTPUT").is_ok_and(|v| v == "null")
}

/// One clip, loaded and ready to play.
pub trait ClipOutput {
    /// Its length.
    fn duration(&self) -> Duration;
    /// Where it is.
    fn position(&self) -> Duration;
    fn play(&mut self);
    fn pause(&mut self);
    fn stop(&mut self);
    fn seek(&mut self, to: Duration);
    /// 1 is normal.
    fn set_speed(&mut self, speed: f64);
    /// Whether it is sounding now: false once it ran to its end.
    fn is_playing(&self) -> bool;
}

/// Makes a [`ClipOutput`] from a clip's bytes; None when they won't play.
pub type ClipLoader = Box<dyn Fn(&[u8], f64) -> Option<Box<dyn ClipOutput>>>;

/// The player's queue: clips by the daemon's path, the one playing, and
/// whether it plays.
pub struct ClipQueue {
    load: ClipLoader,
    /// Every clip's bytes, by path, fetched before a command needs them.
    bytes: HashMap<String, Vec<u8>>,
    clips: Vec<String>,
    index: Option<usize>,
    current: Option<Box<dyn ClipOutput>>,
    state: SpeechPlayerState,
    playing: bool,
    speed: f64,
}

impl ClipQueue {
    pub fn new(load: ClipLoader) -> Self {
        Self {
            load,
            bytes: HashMap::new(),
            clips: vec![],
            index: None,
            current: None,
            state: SpeechPlayerState::Idle,
            playing: false,
            speed: 1.0,
        }
    }

    /// Whether clip `path`'s bytes are here.
    pub fn has(&self, path: &str) -> bool {
        self.bytes.contains_key(path)
    }

    /// Keeps clip `path`'s bytes.
    pub fn keep(&mut self, path: String, bytes: Vec<u8>) {
        self.bytes.insert(path, bytes);
    }

    /// The length of clip `path`, without touching the queue.
    pub fn duration_of(&self, path: &str) -> Option<Duration> {
        let bytes = self.bytes.get(path)?;
        (self.load)(bytes, 1.0).map(|c| c.duration())
    }

    /// Replaces the queue and moves to clip `index` at `position`.
    pub fn set(&mut self, clips: Vec<String>, index: usize, position: Duration) {
        self.stop_current();
        self.clips = clips;
        self.playing = false;
        self.move_to(index, position);
    }

    /// Appends clips without interrupting.
    pub fn add(&mut self, clips: Vec<String>) {
        self.clips.extend(clips);
        match self.index {
            None if !self.clips.is_empty() => self.move_to(0, Duration::ZERO),
            // Moved to a clip before it was queued: it plays now it is.
            Some(i) if self.state == SpeechPlayerState::Loading && i < self.clips.len() => {
                self.move_to(i, Duration::ZERO);
                if self.playing
                    && let Some(c) = &mut self.current
                {
                    c.play();
                }
            }
            _ => {}
        }
    }

    pub fn clear(&mut self) {
        self.stop_current();
        self.clips.clear();
        self.index = None;
        self.state = SpeechPlayerState::Idle;
        self.playing = false;
    }

    pub fn play(&mut self) {
        self.playing = true;
        if self.state == SpeechPlayerState::Ready
            && let Some(c) = &mut self.current
        {
            c.play();
        }
    }

    pub fn pause(&mut self) {
        self.playing = false;
        if let Some(c) = &mut self.current {
            c.pause();
        }
    }

    pub fn stop(&mut self) {
        self.stop_current();
        self.playing = false;
        self.state = SpeechPlayerState::Idle;
    }

    /// Moves within clip `index` (the current one when None).
    pub fn seek(&mut self, index: Option<usize>, position: Duration) {
        match index {
            Some(i) if Some(i) != self.index || self.current.is_none() => {
                self.stop_current();
                self.move_to(i, position);
            }
            _ => {
                if let Some(c) = &mut self.current {
                    c.seek(position);
                    if self.state == SpeechPlayerState::Completed {
                        self.state = SpeechPlayerState::Ready;
                    }
                } else if let Some(i) = self.index {
                    self.move_to(i, position);
                }
            }
        }
        if self.playing
            && self.state == SpeechPlayerState::Ready
            && let Some(c) = &mut self.current
        {
            c.play();
        }
    }

    pub fn set_speed(&mut self, speed: f64) {
        self.speed = speed;
        if let Some(c) = &mut self.current {
            c.set_speed(speed);
        }
    }

    /// Moves on when the clip ran to its end; true when the queue changed
    /// (a new clip, or the end of the queue).
    pub fn tick(&mut self) -> bool {
        if !self.playing || self.state != SpeechPlayerState::Ready {
            return false;
        }
        let ended = self.current.as_ref().is_none_or(|c| !c.is_playing());
        if !ended {
            return false;
        }
        let next = self.index.map_or(0, |i| i + 1);
        if next < self.clips.len() {
            self.stop_current();
            self.move_to(next, Duration::ZERO);
            if let Some(c) = &mut self.current {
                c.play();
            }
        } else {
            // The end of the queue: it waits there, as just_audio's does,
            // until it is moved or given more.
            self.state = SpeechPlayerState::Completed;
            self.playing = false;
        }
        true
    }

    /// Whether a clip is sounding (the queue polls it while so).
    pub fn is_running(&self) -> bool {
        self.playing && self.state == SpeechPlayerState::Ready
    }

    /// What the daemon is told after each command and tick.
    pub fn report(&self) -> SpeechReport {
        SpeechReport {
            kind: Some(SpeechReportKind::Player),
            playing: self.playing,
            state: Some(self.state),
            index: self.index.map(|i| i as i64),
            position_ms: Some(
                self.current
                    .as_ref()
                    .map_or(0, |c| c.position().as_millis() as i64),
            ),
            ..Default::default()
        }
    }

    fn stop_current(&mut self) {
        if let Some(mut c) = self.current.take() {
            c.stop();
        }
    }

    fn move_to(&mut self, index: usize, position: Duration) {
        self.index = Some(index);
        let Some(path) = self.clips.get(index) else {
            // Not queued yet: it is played once it is.
            self.state = SpeechPlayerState::Loading;
            return;
        };
        match self
            .bytes
            .get(path)
            .and_then(|b| (self.load)(b, self.speed))
        {
            Some(mut clip) => {
                if position > Duration::ZERO {
                    clip.seek(position);
                }
                self.current = Some(clip);
                self.state = SpeechPlayerState::Ready;
            }
            None => {
                log::warn!("speech clip {path} would not load");
                self.current = None;
                self.state = SpeechPlayerState::Ready;
            }
        }
    }
}

/// What the Mac's voice did, for `speech.report`.
#[derive(Clone, Debug, PartialEq)]
pub struct VoiceEvent {
    pub kind: SpeechReportKind,
    pub utterance: i64,
    /// The word, as UTF-16 offsets in the utterance's text (`progress`).
    pub range: Option<(i64, i64)>,
}

impl VoiceEvent {
    pub fn report(&self) -> SpeechReport {
        SpeechReport {
            kind: Some(self.kind),
            utterance: self.utterance,
            start: self.range.map(|r| r.0),
            end: self.range.map(|r| r.1),
            ..Default::default()
        }
    }
}

#[cfg(target_os = "macos")]
pub use mac::{Voice, av_clip, clip_loader};

#[cfg(not(target_os = "macos"))]
pub fn clip_loader(_muted: bool) -> ClipLoader {
    Box::new(|_, _| None)
}

#[cfg(not(target_os = "macos"))]
pub fn av_clip(_bytes: &[u8], _speed: f64, _muted: bool) -> Option<Box<dyn ClipOutput>> {
    None
}

/// No voices off macOS.
#[cfg(not(target_os = "macos"))]
pub struct Voice;

#[cfg(not(target_os = "macos"))]
impl Voice {
    pub fn new(_events: futures::channel::mpsc::UnboundedSender<VoiceEvent>, _muted: bool) -> Self {
        Self
    }
    pub fn available(&self) -> bool {
        false
    }
    #[allow(clippy::too_many_arguments)]
    pub fn speak(
        &mut self,
        _u: i64,
        _t: &str,
        _v: Option<&str>,
        _r: f64,
        _p: f64,
        _vol: f64,
    ) -> bool {
        false
    }
    pub fn pause(&mut self) -> bool {
        false
    }
    pub fn resume(&mut self) -> bool {
        false
    }
    pub fn stop(&mut self) -> bool {
        false
    }
}

#[cfg(target_os = "macos")]
mod mac {
    use std::cell::RefCell;
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use block2::RcBlock;
    use futures::channel::mpsc::UnboundedSender;
    use objc2::rc::{Allocated, Retained};
    use objc2::runtime::{AnyClass, AnyObject, NSObject, NSObjectProtocol};
    use objc2::{AllocAnyThread as _, DefinedClass as _, define_class, msg_send};
    use objc2_foundation::{NSRange, NSString};

    use conduit_protocol::SpeechReportKind;

    use super::{ClipLoader, ClipOutput, VoiceEvent};
    use crate::voice::call_audio::{self, CallAudio, Utterance};
    use crate::voice::call_audio_mac;
    use crate::voice::pcm::Resampler;

    #[link(name = "AVFoundation", kind = "framework")]
    unsafe extern "C" {}

    struct DelegateIvars {
        events: UnboundedSender<VoiceEvent>,
        /// Recent utterances and their numbers, kept alive so a late
        /// callback finds the number its utterance had.
        utterances: RefCell<VecDeque<(Retained<AnyObject>, i64)>>,
    }

    define_class!(
        // SAFETY: NSObject has no subclassing requirements and the delegate
        // does not implement Drop.
        #[unsafe(super(NSObject))]
        #[ivars = DelegateIvars]
        struct SpeechDelegate;

        unsafe impl NSObjectProtocol for SpeechDelegate {}

        // AVSpeechSynthesizerDelegate, on the main thread.
        impl SpeechDelegate {
            #[unsafe(method(speechSynthesizer:didStartSpeechUtterance:))]
            fn did_start(&self, _synth: &AnyObject, utterance: &AnyObject) {
                self.send(SpeechReportKind::Start, utterance, None);
            }

            #[unsafe(method(speechSynthesizer:didFinishSpeechUtterance:))]
            fn did_finish(&self, _synth: &AnyObject, utterance: &AnyObject) {
                self.send(SpeechReportKind::Complete, utterance, None);
            }

            #[unsafe(method(speechSynthesizer:didPauseSpeechUtterance:))]
            fn did_pause(&self, _synth: &AnyObject, utterance: &AnyObject) {
                self.send(SpeechReportKind::Pause, utterance, None);
            }

            #[unsafe(method(speechSynthesizer:didContinueSpeechUtterance:))]
            fn did_continue(&self, _synth: &AnyObject, utterance: &AnyObject) {
                self.send(SpeechReportKind::Resume, utterance, None);
            }

            #[unsafe(method(speechSynthesizer:didCancelSpeechUtterance:))]
            fn did_cancel(&self, _synth: &AnyObject, utterance: &AnyObject) {
                self.send(SpeechReportKind::Cancel, utterance, None);
            }

            #[unsafe(method(speechSynthesizer:willSpeakRangeOfSpeechString:utterance:))]
            fn will_speak(&self, _synth: &AnyObject, range: NSRange, utterance: &AnyObject) {
                let start = range.location as i64;
                let end = (range.location + range.length) as i64;
                self.send(SpeechReportKind::Progress, utterance, Some((start, end)));
            }
        }
    );

    impl SpeechDelegate {
        fn new(events: UnboundedSender<VoiceEvent>) -> Retained<Self> {
            let this = Self::alloc().set_ivars(DelegateIvars {
                events,
                utterances: RefCell::new(VecDeque::new()),
            });
            // SAFETY: NSObject's designated initializer.
            unsafe { msg_send![super(this), init] }
        }

        fn remember(&self, utterance: Retained<AnyObject>, number: i64) {
            let mut list = self.ivars().utterances.borrow_mut();
            list.push_back((utterance, number));
            while list.len() > 8 {
                list.pop_front();
            }
        }

        fn send(&self, kind: SpeechReportKind, utterance: &AnyObject, range: Option<(i64, i64)>) {
            let number = self
                .ivars()
                .utterances
                .borrow()
                .iter()
                .find(|(u, _)| std::ptr::eq(&**u, utterance))
                .map(|(_, n)| *n);
            if let Some(utterance) = number {
                let _ = self.ivars().events.unbounded_send(VoiceEvent {
                    kind,
                    utterance,
                    range,
                });
            }
        }
    }

    /// The Mac's voices: one synthesizer per utterance, so one that is
    /// replaced can't hold up the next.
    pub struct Voice {
        delegate: Retained<SpeechDelegate>,
        synth: Option<Retained<AnyObject>>,
        muted: bool,
        events: UnboundedSender<VoiceEvent>,
        /// The utterance being said on a call's engine.
        call: Option<CallSpeech>,
    }

    impl Voice {
        pub fn new(events: UnboundedSender<VoiceEvent>, muted: bool) -> Self {
            Self {
                delegate: SpeechDelegate::new(events.clone()),
                synth: None,
                muted,
                events,
                call: None,
            }
        }

        /// Whether any voice is installed.
        pub fn available(&self) -> bool {
            !crate::shell::speech::voices().is_empty()
        }

        /// Says `text` as utterance `number`, replacing whatever is being
        /// said (whose events then carry its own, older number).
        pub fn speak(
            &mut self,
            number: i64,
            text: &str,
            voice: Option<&str>,
            rate: f64,
            pitch: f64,
            volume: f64,
        ) -> bool {
            self.stop();
            let volume = if self.muted {
                0.0
            } else {
                volume.clamp(0.0, 1.0)
            };
            let Some((synth, utterance)) = made(text, voice, rate, pitch, volume) else {
                return false;
            };
            // A Standard call is on: said on its engine, where the
            // microphone's voice processing hears it.
            if let Some(audio) = call_audio::current() {
                self.call = CallSpeech::start(audio, synth, utterance, number, &self.events);
                return self.call.is_some();
            }
            // SAFETY: AVFoundation on the main thread; the synthesizer is
            // kept in `self.synth` and the utterance by the delegate.
            unsafe {
                let delegate: &AnyObject = &self.delegate;
                let _: () = msg_send![&*synth, setDelegate: delegate];
                self.delegate.remember(utterance.clone(), number);
                let _: () = msg_send![&*synth, speakUtterance: &*utterance];
                self.synth = Some(synth);
            }
            true
        }

        pub fn pause(&mut self) -> bool {
            if let Some(call) = &self.call {
                return call.pause();
            }
            let Some(synth) = &self.synth else {
                return false;
            };
            // SAFETY: as above. 0 = AVSpeechBoundaryImmediate.
            unsafe { msg_send![&**synth, pauseSpeakingAtBoundary: 0isize] }
        }

        pub fn resume(&mut self) -> bool {
            if let Some(call) = &self.call {
                return call.resume();
            }
            let Some(synth) = &self.synth else {
                return false;
            };
            // SAFETY: as above.
            unsafe { msg_send![&**synth, continueSpeaking] }
        }

        /// Stops (the Mac's voice reports `cancel` when it can; a call's never
        /// does).
        pub fn stop(&mut self) -> bool {
            if let Some(call) = self.call.take() {
                return call.stop();
            }
            let Some(synth) = self.synth.take() else {
                return false;
            };
            // SAFETY: as above.
            unsafe { msg_send![&*synth, stopSpeakingAtBoundary: 0isize] }
        }
    }

    /// A synthesizer and the utterance of `text` it is to say.
    fn made(
        text: &str,
        voice: Option<&str>,
        rate: f64,
        pitch: f64,
        volume: f64,
    ) -> Option<(Retained<AnyObject>, Retained<AnyObject>)> {
        let synth_class = AnyClass::get(c"AVSpeechSynthesizer")?;
        let utterance_class = AnyClass::get(c"AVSpeechUtterance")?;
        // SAFETY: AVFoundation on the main thread; both are returned owned.
        unsafe {
            let synth: Option<Retained<AnyObject>> = msg_send![synth_class, new];
            let synth = synth?;
            let text = NSString::from_str(text);
            let utterance: Option<Retained<AnyObject>> =
                msg_send![utterance_class, speechUtteranceWithString: &*text];
            let utterance = utterance?;
            if let Some(id) = voice
                && let Some(voice_class) = AnyClass::get(c"AVSpeechSynthesisVoice")
            {
                let id = NSString::from_str(id);
                let voice: Option<Retained<AnyObject>> =
                    msg_send![voice_class, voiceWithIdentifier: &*id];
                if let Some(voice) = voice {
                    let _: () = msg_send![&*utterance, setVoice: &*voice];
                }
            }
            let _: () = msg_send![&*utterance, setRate: rate.clamp(0.0, 1.0) as f32];
            let _: () = msg_send![&*utterance, setPitchMultiplier: pitch.clamp(0.5, 2.0) as f32];
            let _: () = msg_send![&*utterance, setVolume: volume as f32];
            Some((synth, utterance))
        }
    }

    /// One utterance said on a call's engine: the voice writes it to
    /// samples, which play on the call's player as they come.
    struct CallSpeech {
        audio: Arc<CallAudio>,
        synth: Retained<AnyObject>,
        number: i64,
        state: Arc<Mutex<Utterance>>,
        events: UnboundedSender<VoiceEvent>,
    }

    /// How long a voice may take to write a sentence's first audio.
    const SILENT: Duration = Duration::from_secs(4);

    /// How long the voice may go quiet, everything written so far heard,
    /// before its utterance counts as said: the Mac ends a written one with
    /// an empty buffer, which is not promised.
    const QUIET: Duration = Duration::from_millis(800);

    fn tell(events: &UnboundedSender<VoiceEvent>, kind: SpeechReportKind, utterance: i64) {
        let _ = events.unbounded_send(VoiceEvent {
            kind,
            utterance,
            range: None,
        });
    }

    /// Plays `samples` on `audio` as the next chunk of the utterance.
    fn chunk(
        audio: &Arc<CallAudio>,
        samples: &[f32],
        state: &Arc<Mutex<Utterance>>,
        events: &UnboundedSender<VoiceEvent>,
        number: i64,
    ) {
        if samples.is_empty() {
            return;
        }
        let first = state.lock().is_ok_and(|mut u| u.scheduled());
        if first {
            log::debug!("call speech {number}: first audio");
            tell(events, SpeechReportKind::Start, number);
        }
        let generation = audio.generation();
        let weak = Arc::downgrade(audio);
        let heard = {
            let state = state.clone();
            let events = events.clone();
            move || {
                let (complete, drained, count) = match state.lock() {
                    Ok(mut u) => (u.played(), u.drained(), u.scheduled_count()),
                    Err(_) => return,
                };
                if complete {
                    log::debug!("call speech {number}: heard");
                    tell(&events, SpeechReportKind::Complete, number);
                } else if drained {
                    // Everything written was heard: ended, unless more
                    // comes soon.
                    std::thread::spawn(move || {
                        std::thread::sleep(QUIET);
                        let live = weak.upgrade().is_some_and(|a| a.generation() == generation);
                        let ended = live
                            && state.lock().is_ok_and(|mut u| {
                                u.drained() && u.scheduled_count() == count && u.ended()
                            });
                        if ended {
                            log::debug!("call speech {number}: heard (no end mark)");
                            tell(&events, SpeechReportKind::Complete, number);
                        }
                    });
                }
            }
        };
        if !audio.schedule(samples, Box::new(heard)) {
            // Nothing to play it on: it counts as heard, so the call goes on.
            let complete = state.lock().is_ok_and(|mut u| u.played());
            if complete {
                tell(events, SpeechReportKind::Complete, number);
            }
        }
    }

    impl CallSpeech {
        fn start(
            audio: Arc<CallAudio>,
            synth: Retained<AnyObject>,
            utterance: Retained<AnyObject>,
            number: i64,
            events: &UnboundedSender<VoiceEvent>,
        ) -> Option<Self> {
            audio.stop();
            audio.set_rate(1.0);
            let generation = audio.generation();
            let state = Arc::new(Mutex::new(Utterance::default()));
            let resampler: Mutex<Option<Resampler>> = Mutex::new(None);
            let written = {
                let audio = audio.clone();
                let state = state.clone();
                let events = events.clone();
                RcBlock::new(move |buffer: *mut AnyObject| {
                    if audio.generation() != generation {
                        return;
                    }
                    // SAFETY: the buffer the voice hands over, alive for
                    // this call.
                    let written = unsafe { call_audio_mac::buffer_samples(buffer) };
                    let Ok(mut resampler) = resampler.lock() else {
                        return;
                    };
                    match written {
                        Some((samples, rate)) if !samples.is_empty() => {
                            let resampler = resampler
                                .get_or_insert_with(|| Resampler::to(rate, call_audio::RATE));
                            let samples = resampler.push(&samples);
                            chunk(&audio, &samples, &state, &events, number);
                        }
                        // An empty buffer: the voice has written it all.
                        _ => {
                            if let Some(mut resampler) = resampler.take() {
                                let tail = resampler.push(&vec![
                                    0.0;
                                    64.max(
                                        resampler.input_rate() as usize / 50
                                    )
                                ]);
                                chunk(&audio, &tail, &state, &events, number);
                            }
                            let (start, complete) = match state.lock() {
                                Ok(mut u) => {
                                    log::debug!(
                                        "call speech {number}: written ({} chunks)",
                                        u.scheduled_count()
                                    );
                                    let complete = u.ended();
                                    (complete && u.take_start(), complete)
                                }
                                Err(_) => (false, false),
                            };
                            if start {
                                tell(&events, SpeechReportKind::Start, number);
                            }
                            if complete {
                                tell(&events, SpeechReportKind::Complete, number);
                            }
                        }
                    }
                })
            };
            // SAFETY: AVFoundation; the synthesizer is kept by the
            // `CallSpeech` and copies the block.
            unsafe {
                let _: () = msg_send![
                    &*synth,
                    writeUtterance: &*utterance,
                    toBufferCallback: &*written
                ];
            }
            audio.play();
            audio.count_said();
            log::debug!("call speech {number}: writing");
            // A voice that writes nothing (the Mac's synthesizer can, right
            // after another was stopped mid-sentence) would hold the call on
            // this sentence: it counts as said, and the call goes on.
            {
                let weak = Arc::downgrade(&audio);
                let state = state.clone();
                let events = events.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(SILENT);
                    let live = weak.upgrade().is_some_and(|a| a.generation() == generation);
                    let silent = live
                        && state.lock().is_ok_and(|mut u| {
                            let silent = u.scheduled_count() == 0 && !u.is_done() && u.ended();
                            if silent {
                                u.take_start();
                            }
                            silent
                        });
                    if silent {
                        log::warn!("call speech {number}: the voice wrote nothing; going on");
                        tell(&events, SpeechReportKind::Start, number);
                        tell(&events, SpeechReportKind::Complete, number);
                    }
                });
            }
            Some(Self {
                audio,
                synth,
                number,
                state,
                events: events.clone(),
            })
        }

        fn pause(&self) -> bool {
            self.audio.pause();
            tell(&self.events, SpeechReportKind::Pause, self.number);
            true
        }

        fn resume(&self) -> bool {
            self.audio.play();
            tell(&self.events, SpeechReportKind::Resume, self.number);
            true
        }

        fn stop(self) -> bool {
            log::debug!("call speech {}: stopped", self.number);
            // The player first: a last buffer the voice hands over as it
            // stops is then the stopped utterance's, and reports nothing.
            self.audio.stop();
            // SAFETY: the synthesizer this utterance is written by.
            unsafe {
                let _: bool = msg_send![&*self.synth, stopSpeakingAtBoundary: 0isize];
            }
            // Done, and never reported: whoever stops it knows (the
            // daemon's own stop says it was cancelled), while a `cancel`
            // that reached the daemon after it began the next answer, before
            // that answer's first sentence, would end the next answer too.
            // (The Mac's own voice is released as it stops, and says
            // nothing either.)
            let _ = self.state.lock().map(|mut u| u.cancel());
            true
        }
    }

    /// One of the server's clips, decoded and played on a call's engine.
    struct CallClip {
        audio: Arc<CallAudio>,
        samples: Arc<Vec<f32>>,
        /// Where it plays from next, in samples.
        from: usize,
        /// The player's generation it was scheduled in.
        scheduled: Option<u64>,
        finished: Arc<AtomicBool>,
        speed: f64,
        counted: bool,
    }

    impl CallClip {
        fn load(audio: Arc<CallAudio>, bytes: &[u8], speed: f64) -> Option<Self> {
            let (samples, rate) = call_audio_mac::decode(bytes)?;
            Some(Self {
                audio,
                samples: Arc::new(call_audio::to_rate(&samples, rate)),
                from: 0,
                scheduled: None,
                finished: Arc::new(AtomicBool::new(false)),
                speed,
                counted: false,
            })
        }

        /// It is what the player has now.
        fn live(&self) -> bool {
            self.scheduled == Some(self.audio.generation())
        }
    }

    impl ClipOutput for CallClip {
        fn duration(&self) -> Duration {
            call_audio::frames_to_time(self.samples.len())
        }
        fn position(&self) -> Duration {
            if self.live() {
                call_audio::clip_position(self.from, self.audio.played(), self.samples.len())
            } else {
                call_audio::frames_to_time(self.from.min(self.samples.len()))
            }
        }
        fn play(&mut self) {
            self.audio.set_rate(self.speed);
            if self.live() {
                // Paused: on from there.
                self.audio.play();
                return;
            }
            self.audio.stop();
            self.finished.store(false, Ordering::SeqCst);
            let rest = &self.samples[self.from.min(self.samples.len())..];
            let finished = self.finished.clone();
            let done = Box::new(move || finished.store(true, Ordering::SeqCst));
            if !self.audio.schedule(rest, done) {
                self.finished.store(true, Ordering::SeqCst);
            }
            self.scheduled = Some(self.audio.generation());
            self.audio.play();
            if !std::mem::replace(&mut self.counted, true) {
                self.audio.count_said();
            }
        }
        fn pause(&mut self) {
            if self.live() {
                self.audio.pause();
            }
        }
        fn stop(&mut self) {
            if self.live() {
                self.audio.stop();
            }
            self.scheduled = None;
        }
        fn seek(&mut self, to: Duration) {
            if self.live() {
                self.audio.stop();
            }
            self.scheduled = None;
            self.finished.store(false, Ordering::SeqCst);
            self.from = call_audio::time_to_frames(to).min(self.samples.len());
        }
        fn set_speed(&mut self, speed: f64) {
            self.speed = speed;
            if self.live() {
                self.audio.set_rate(speed);
            }
        }
        fn is_playing(&self) -> bool {
            self.live() && !self.finished.load(Ordering::SeqCst)
        }
    }

    /// One clip in an `AVAudioPlayer`.
    struct AvClip {
        player: Retained<AnyObject>,
    }

    impl ClipOutput for AvClip {
        fn duration(&self) -> Duration {
            // SAFETY: AVFoundation on the main thread.
            let secs: f64 = unsafe { msg_send![&*self.player, duration] };
            Duration::from_secs_f64(secs.max(0.0))
        }
        fn position(&self) -> Duration {
            // SAFETY: as above.
            let secs: f64 = unsafe { msg_send![&*self.player, currentTime] };
            Duration::from_secs_f64(secs.max(0.0))
        }
        fn play(&mut self) {
            // SAFETY: as above.
            let _: bool = unsafe { msg_send![&*self.player, play] };
        }
        fn pause(&mut self) {
            // SAFETY: as above.
            let _: () = unsafe { msg_send![&*self.player, pause] };
        }
        fn stop(&mut self) {
            // SAFETY: as above.
            let _: () = unsafe { msg_send![&*self.player, stop] };
        }
        fn seek(&mut self, to: Duration) {
            // SAFETY: as above.
            let _: () = unsafe { msg_send![&*self.player, setCurrentTime: to.as_secs_f64()] };
        }
        fn set_speed(&mut self, speed: f64) {
            // SAFETY: as above; `enableRate` was set before `prepareToPlay`.
            let _: () = unsafe { msg_send![&*self.player, setRate: speed as f32] };
        }
        fn is_playing(&self) -> bool {
            // SAFETY: as above.
            unsafe { msg_send![&*self.player, isPlaying] }
        }
    }

    /// Loads clips into `AVAudioPlayer`s (silent ones when `muted`), or,
    /// while a Standard call is on, onto the call's engine.
    pub fn clip_loader(muted: bool) -> ClipLoader {
        Box::new(move |bytes: &[u8], speed: f64| {
            if let Some(audio) = call_audio::current() {
                return CallClip::load(audio, bytes, speed)
                    .map(|c| Box::new(c) as Box<dyn ClipOutput>);
            }
            av_clip(bytes, speed, muted)
        })
    }

    /// One clip in its own `AVAudioPlayer` (silent when `muted`): any
    /// format Core Audio plays (WAV, MP3, AAC/M4A, CAF, FLAC). None when
    /// the bytes won't play.
    pub fn av_clip(bytes: &[u8], speed: f64, muted: bool) -> Option<Box<dyn ClipOutput>> {
        {
            let (Some(player_class), Some(data_class)) =
                (AnyClass::get(c"AVAudioPlayer"), AnyClass::get(c"NSData"))
            else {
                return None;
            };
            // SAFETY: AVFoundation on the main thread; the player is owned
            // by the clip.
            unsafe {
                let data: Option<Retained<AnyObject>> = msg_send![
                    data_class,
                    dataWithBytes: bytes.as_ptr().cast::<std::ffi::c_void>(),
                    length: bytes.len()
                ];
                let data = data?;
                let alloc: Allocated<AnyObject> = msg_send![player_class, alloc];
                let error: *mut *mut AnyObject = std::ptr::null_mut();
                let player: Option<Retained<AnyObject>> =
                    msg_send![alloc, initWithData: &*data, error: error];
                let player = player?;
                let _: () = msg_send![&*player, setEnableRate: true];
                let _: bool = msg_send![&*player, prepareToPlay];
                let _: () = msg_send![&*player, setRate: speed as f32];
                if muted {
                    let _: () = msg_send![&*player, setVolume: 0f32];
                }
                Some(Box::new(AvClip { player }) as Box<dyn ClipOutput>)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;

    use super::*;

    /// A clip that lasts `len` and is moved by hand.
    struct FakeClip {
        len: Duration,
        at: Rc<Cell<Duration>>,
        playing: bool,
    }

    impl ClipOutput for FakeClip {
        fn duration(&self) -> Duration {
            self.len
        }
        fn position(&self) -> Duration {
            self.at.get()
        }
        fn play(&mut self) {
            self.playing = true;
        }
        fn pause(&mut self) {
            self.playing = false;
        }
        fn stop(&mut self) {
            self.playing = false;
        }
        fn seek(&mut self, to: Duration) {
            self.at.set(to);
        }
        fn set_speed(&mut self, _speed: f64) {}
        fn is_playing(&self) -> bool {
            self.playing && self.at.get() < self.len
        }
    }

    fn queue() -> (ClipQueue, Rc<Cell<Duration>>) {
        let at = Rc::new(Cell::new(Duration::ZERO));
        let shared = at.clone();
        let mut q = ClipQueue::new(Box::new(move |bytes, _| {
            shared.set(Duration::ZERO);
            Some(Box::new(FakeClip {
                len: Duration::from_secs(bytes[0] as u64),
                at: shared.clone(),
                playing: false,
            }) as Box<dyn ClipOutput>)
        }));
        q.keep("/tts/a".into(), vec![2]);
        q.keep("/tts/b".into(), vec![3]);
        q.keep("/tts/c".into(), vec![1]);
        (q, at)
    }

    #[test]
    fn a_clip_that_ends_moves_to_the_next_and_the_last_waits_completed() {
        let (mut q, at) = queue();
        assert_eq!(q.duration_of("/tts/b"), Some(Duration::from_secs(3)));
        q.set(vec!["/tts/a".into()], 0, Duration::ZERO);
        q.play();
        assert!(q.is_running());
        assert!(!q.tick(), "still playing");
        // The first ends with nothing after it: the queue completes.
        at.set(Duration::from_secs(2));
        assert!(q.tick());
        assert_eq!(q.report().state, Some(SpeechPlayerState::Completed));
        assert!(!q.report().playing);
        // More arrives: it stays completed until moved, as just_audio does.
        q.add(vec!["/tts/b".into()]);
        assert_eq!(q.report().state, Some(SpeechPlayerState::Completed));
        q.seek(Some(1), Duration::ZERO);
        q.play();
        assert_eq!(q.report().index, Some(1));
        assert_eq!(q.report().state, Some(SpeechPlayerState::Ready));
        assert!(q.is_running());
    }

    #[test]
    fn a_queue_plays_through_and_seeks_across_clips() {
        let (mut q, at) = queue();
        q.set(
            vec!["/tts/a".into(), "/tts/b".into(), "/tts/c".into()],
            0,
            Duration::ZERO,
        );
        q.play();
        at.set(Duration::from_secs(2));
        assert!(q.tick());
        assert_eq!(q.report().index, Some(1));
        assert!(q.report().playing);
        // Paused, a seek stays paused.
        q.pause();
        q.seek(Some(2), Duration::from_millis(500));
        assert_eq!(q.report().index, Some(2));
        assert_eq!(q.report().position_ms, Some(500));
        assert!(!q.is_running());
        q.play();
        assert!(q.is_running());
        q.stop();
        assert_eq!(q.report().state, Some(SpeechPlayerState::Idle));
    }
}
