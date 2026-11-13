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
pub use mac::{Voice, clip_loader};

#[cfg(not(target_os = "macos"))]
pub fn clip_loader(_muted: bool) -> ClipLoader {
    Box::new(|_, _| None)
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
    use std::time::Duration;

    use futures::channel::mpsc::UnboundedSender;
    use objc2::rc::{Allocated, Retained};
    use objc2::runtime::{AnyClass, AnyObject, NSObject, NSObjectProtocol};
    use objc2::{AllocAnyThread as _, DefinedClass as _, define_class, msg_send};
    use objc2_foundation::{NSRange, NSString};

    use conduit_protocol::SpeechReportKind;

    use super::{ClipLoader, ClipOutput, VoiceEvent};

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
    }

    impl Voice {
        pub fn new(events: UnboundedSender<VoiceEvent>, muted: bool) -> Self {
            Self {
                delegate: SpeechDelegate::new(events),
                synth: None,
                muted,
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
            let (Some(synth_class), Some(utterance_class)) = (
                AnyClass::get(c"AVSpeechSynthesizer"),
                AnyClass::get(c"AVSpeechUtterance"),
            ) else {
                return false;
            };
            // SAFETY: AVFoundation on the main thread; the synthesizer is
            // kept in `self.synth` and the utterance by the delegate.
            unsafe {
                let synth: Option<Retained<AnyObject>> = msg_send![synth_class, new];
                let Some(synth) = synth else { return false };
                let text = NSString::from_str(text);
                let utterance: Option<Retained<AnyObject>> =
                    msg_send![utterance_class, speechUtteranceWithString: &*text];
                let Some(utterance) = utterance else {
                    return false;
                };
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
                let _: () =
                    msg_send![&*utterance, setPitchMultiplier: pitch.clamp(0.5, 2.0) as f32];
                let volume = if self.muted {
                    0.0
                } else {
                    volume.clamp(0.0, 1.0)
                };
                let _: () = msg_send![&*utterance, setVolume: volume as f32];
                let delegate: &AnyObject = &self.delegate;
                let _: () = msg_send![&*synth, setDelegate: delegate];
                self.delegate.remember(utterance.clone(), number);
                let _: () = msg_send![&*synth, speakUtterance: &*utterance];
                self.synth = Some(synth);
            }
            true
        }

        pub fn pause(&mut self) -> bool {
            let Some(synth) = &self.synth else {
                return false;
            };
            // SAFETY: as above. 0 = AVSpeechBoundaryImmediate.
            unsafe { msg_send![&**synth, pauseSpeakingAtBoundary: 0isize] }
        }

        pub fn resume(&mut self) -> bool {
            let Some(synth) = &self.synth else {
                return false;
            };
            // SAFETY: as above.
            unsafe { msg_send![&**synth, continueSpeaking] }
        }

        /// Stops; the utterance reports `cancel`.
        pub fn stop(&mut self) -> bool {
            let Some(synth) = self.synth.take() else {
                return false;
            };
            // SAFETY: as above.
            unsafe { msg_send![&*synth, stopSpeakingAtBoundary: 0isize] }
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

    /// Loads clips into `AVAudioPlayer`s (silent ones when `muted`).
    pub fn clip_loader(muted: bool) -> ClipLoader {
        Box::new(move |bytes: &[u8], speed: f64| {
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
        })
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
