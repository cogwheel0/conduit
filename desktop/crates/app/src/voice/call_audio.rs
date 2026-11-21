//! A Standard voice call's audio: one engine for what the call hears and
//! what it says.
//!
//! macOS's voice processing takes out of the microphone only what its own
//! engine plays. A Standard call's answer used to be said by the read-aloud
//! engine (`AVSpeechSynthesizer`, or the server's clips in
//! `AVAudioPlayer`), outside the microphone's engine: with barge-in on and
//! the Mac's speakers, the call could hear its own answer as the user's
//! words. While a Standard call is on, [`CallAudio`] holds the call's one
//! `AVAudioEngine`:
//!
//! * the microphone, through the voice-processing unit, tapped; each
//!   listen of the call's ears ([`crate::stores::dictation`]) subscribes to
//!   the tap ([`CallAudio::microphone_input`]) instead of opening an
//!   engine of its own;
//! * a player node, on which [`crate::shell::speech_engine`] plays what the
//!   call says: the Mac's voice rendered to samples
//!   (`AVSpeechSynthesizer.write`), or the server's clips decoded.
//!
//! With a stand-in for the microphone (dev builds and the E2E pass) the
//! engine has no microphone, only the player; the null sink
//! (`CONDUIT_SPEECH_OUTPUT=null`) plays it at volume 0, in real time.
//!
//! A realtime call has its own engine ([`super::realtime`]), and none of
//! this.

use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use super::session::{Input, InputError, InputFactory, WorkerMsg};

/// The rate the call's player runs at (a realtime voice's).
pub const RATE: u32 = super::realtime::RATE;

/// The call's audio while a Standard call is on.
static CURRENT: Mutex<Option<Arc<CallAudio>>> = Mutex::new(None);

/// Utterances and clips said on any call's engine, for the E2E pass.
static SAID: AtomicUsize = AtomicUsize::new(0);

/// How many utterances and clips calls have said on their own engine.
pub fn said_on_calls() -> usize {
    SAID.load(Ordering::Relaxed)
}

/// The call's audio, while a Standard call has one.
pub fn current() -> Option<Arc<CallAudio>> {
    CURRENT.lock().ok().and_then(|c| c.clone())
}

/// A Standard call is on: its engine, the player only until the call
/// listens ([`CallAudio::want_microphone`]). Kept when there is one.
pub fn begin(muted: bool) -> Option<Arc<CallAudio>> {
    let mut current = CURRENT.lock().ok()?;
    if let Some(audio) = current.as_ref() {
        return Some(audio.clone());
    }
    match CallAudio::new(muted) {
        Ok(audio) => {
            let audio = Arc::new(audio);
            audio.observe();
            *current = Some(audio.clone());
            Some(audio)
        }
        Err(e) => {
            log::warn!("call audio: {e}");
            None
        }
    }
}

/// The call is over, or became a realtime one: its engine stops once the
/// last thing playing on it lets go.
pub fn end() {
    if let Ok(mut current) = CURRENT.lock()
        && let Some(audio) = current.take()
    {
        audio.stop();
        audio.shut();
    }
}

/// The listens subscribed to the microphone's tap.
#[derive(Default)]
pub struct Taps {
    next: AtomicU64,
    list: Mutex<Vec<(u64, Sender<WorkerMsg>)>>,
}

impl Taps {
    fn add(&self, tx: Sender<WorkerMsg>) -> u64 {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        if let Ok(mut list) = self.list.lock() {
            list.push((id, tx));
        }
        id
    }

    fn remove(&self, id: u64) {
        if let Ok(mut list) = self.list.lock() {
            list.retain(|(i, _)| *i != id);
        }
    }

    /// The microphone's samples, to every listen (a gone one is dropped).
    pub fn send(&self, samples: &[f32], rate: u32) {
        if let Ok(mut list) = self.list.lock() {
            list.retain(|(_, tx)| {
                tx.send(WorkerMsg::Audio {
                    samples: samples.to_vec(),
                    rate,
                })
                .is_ok()
            });
        }
    }

    /// Tells every listen the microphone failed.
    pub fn fail(&self, error: &str) {
        if let Ok(list) = self.list.lock() {
            for (_, tx) in list.iter() {
                let _ = tx.send(WorkerMsg::InputFailed(InputError::Unavailable(
                    error.to_string(),
                )));
            }
        }
    }

    pub fn len(&self) -> usize {
        self.list.lock().map_or(0, |l| l.len())
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// One listen's share of the call's microphone.
struct TapInput {
    id: u64,
    taps: Arc<Taps>,
}

impl Input for TapInput {
    fn restart(&mut self) -> Result<(), InputError> {
        // The call's engine follows the device itself.
        Ok(())
    }

    fn stop(&mut self) {
        self.taps.remove(self.id);
    }
}

impl Drop for TapInput {
    fn drop(&mut self) {
        self.taps.remove(self.id);
    }
}

/// What one utterance said on the call's player has done: its chunks
/// scheduled and played back, whether the voice finished writing it, and
/// whether it was reported complete. The voice reports `start` with its
/// first chunk, and `complete` once it finished writing and every chunk
/// played -- when it was heard, not when it was written.
#[derive(Debug, Default)]
pub struct Utterance {
    started: bool,
    scheduled: usize,
    played: usize,
    ended: bool,
    done: bool,
}

impl Utterance {
    /// A chunk went to the player; true when it is the first (`start`).
    pub fn scheduled(&mut self) -> bool {
        self.scheduled += 1;
        !std::mem::replace(&mut self.started, true)
    }

    /// A chunk played back; true when that completed the utterance.
    pub fn played(&mut self) -> bool {
        self.played += 1;
        self.complete()
    }

    /// The voice finished writing; true when that completed it (every
    /// chunk had played, or there was none).
    pub fn ended(&mut self) -> bool {
        self.ended = true;
        self.complete()
    }

    /// Whether `start` is still to be reported (an utterance with no audio
    /// reports it as it completes).
    pub fn take_start(&mut self) -> bool {
        !std::mem::replace(&mut self.started, true)
    }

    /// Every chunk written so far has played, and the voice has not said
    /// it finished: the moment to wonder whether it ever will.
    pub fn drained(&self) -> bool {
        !self.ended && !self.done && self.scheduled > 0 && self.played >= self.scheduled
    }

    pub fn scheduled_count(&self) -> usize {
        self.scheduled
    }

    /// Stopped; true when it had not completed (`cancel` is reported).
    pub fn cancel(&mut self) -> bool {
        !std::mem::replace(&mut self.done, true)
    }

    pub fn is_done(&self) -> bool {
        self.done
    }

    fn complete(&mut self) -> bool {
        if !self.done && self.ended && self.played >= self.scheduled {
            self.done = true;
            true
        } else {
            false
        }
    }
}

/// A clip's place in its samples: where it was last scheduled from, plus
/// what the player has played since, never past its end.
pub fn clip_position(from: usize, played: Duration, len: usize) -> Duration {
    let played = (played.as_secs_f64() * f64::from(RATE)).round() as usize;
    frames_to_time(from.saturating_add(played).min(len))
}

pub fn frames_to_time(frames: usize) -> Duration {
    Duration::from_secs_f64(frames as f64 / f64::from(RATE))
}

pub fn time_to_frames(at: Duration) -> usize {
    (at.as_secs_f64() * f64::from(RATE)).round() as usize
}

/// Samples resampled to [`RATE`], to the end: the resampler's tail is
/// flushed with silence.
pub fn to_rate(samples: &[f32], rate: u32) -> Vec<f32> {
    if rate == RATE {
        return samples.to_vec();
    }
    let mut resampler = super::pcm::Resampler::to(rate, RATE);
    let mut out = resampler.push(samples);
    out.extend(resampler.push(&vec![0.0; 64.max(rate as usize / 100)]));
    let want = (samples.len() as f64 * f64::from(RATE) / f64::from(rate.max(1))).round() as usize;
    out.truncate(want);
    out
}

pub struct CallAudio {
    engine: Mutex<Option<platform::Engine>>,
    taps: Arc<Taps>,
    /// Bumped by every stop: a chunk scheduled before it never reports.
    generation: Arc<AtomicU64>,
    muted: bool,
}

impl CallAudio {
    fn new(muted: bool) -> Result<Self, String> {
        let taps = Arc::new(Taps::default());
        let engine = platform::Engine::new(muted, None)?;
        Ok(Self {
            engine: Mutex::new(Some(engine)),
            taps,
            generation: Arc::new(AtomicU64::new(0)),
            muted,
        })
    }

    /// Follows the audio device: a device that changes stops the engine,
    /// which starts again on the new one.
    fn observe(self: &Arc<Self>) {
        let weak = Arc::downgrade(self);
        if let Ok(mut engine) = self.engine.lock()
            && let Some(engine) = engine.as_mut()
        {
            engine.observe(Box::new(move || {
                if let Some(audio) = weak.upgrade() {
                    audio.restart();
                }
            }));
        }
    }

    fn restart(&self) {
        let failed = match self.engine.lock() {
            Ok(mut engine) => match engine.as_mut() {
                Some(engine) => engine.restart().err(),
                None => None,
            },
            Err(_) => None,
        };
        if let Some(e) = failed {
            log::warn!("call audio: the engine did not start again: {e}");
            self.taps
                .fail("The audio device changed. Start the call again.");
        }
    }

    /// The engine hears the microphone from now on, through voice
    /// processing; a no-op when it already does.
    pub fn want_microphone(&self) -> Result<(), String> {
        let mut engine = self.engine.lock().map_err(|_| "poisoned".to_string())?;
        if engine
            .as_ref()
            .is_some_and(platform::Engine::has_microphone)
        {
            return Ok(());
        }
        // Voice processing is set before anything is connected: the call's
        // engine is made again, with the microphone.
        let observer = engine.as_mut().and_then(platform::Engine::take_observer);
        *engine = None;
        self.generation.fetch_add(1, Ordering::SeqCst);
        let made = platform::Engine::new(self.muted, Some(self.taps.clone()));
        match made {
            Ok(mut made) => {
                if let Some(observer) = observer {
                    made.observe(observer);
                }
                *engine = Some(made);
                Ok(())
            }
            Err(e) => {
                // The player alone, as before.
                if let Ok(mut player) = platform::Engine::new(self.muted, None) {
                    if let Some(observer) = observer {
                        player.observe(observer);
                    }
                    *engine = Some(player);
                }
                Err(e)
            }
        }
    }

    pub fn has_microphone(&self) -> bool {
        self.engine
            .lock()
            .is_ok_and(|e| e.as_ref().is_some_and(platform::Engine::has_microphone))
    }

    /// A listen's input: the engine's microphone, shared.
    pub fn microphone_input(&self) -> InputFactory {
        let taps = self.taps.clone();
        Box::new(move |tx: Sender<WorkerMsg>| {
            let id = taps.add(tx);
            Ok(Box::new(TapInput { id, taps }) as Box<dyn Input>)
        })
    }

    /// How many listens hear the microphone now.
    pub fn listeners(&self) -> usize {
        self.taps.len()
    }

    pub fn generation(&self) -> u64 {
        self.generation.load(Ordering::SeqCst)
    }

    /// Plays `samples` (mono, at [`RATE`]) after what is scheduled; `done`
    /// runs once they played back, unless the player stopped since.
    /// False when the engine is gone.
    pub fn schedule(&self, samples: &[f32], done: Box<dyn FnOnce() + Send>) -> bool {
        if samples.is_empty() {
            return false;
        }
        let generation = self.generation.clone();
        let at = generation.load(Ordering::SeqCst);
        let done = Mutex::new(Some(done));
        let callback = Box::new(move || {
            if generation.load(Ordering::SeqCst) != at {
                return;
            }
            if let Some(done) = done.lock().ok().and_then(|mut d| d.take()) {
                done();
            }
        });
        self.engine.lock().is_ok_and(|e| {
            e.as_ref()
                .is_some_and(|engine| engine.schedule(samples, callback))
        })
    }

    /// Starts (or goes on) playing what is scheduled.
    pub fn play(&self) {
        if let Ok(mut engine) = self.engine.lock()
            && let Some(engine) = engine.as_mut()
        {
            engine.play();
        }
    }

    pub fn pause(&self) {
        if let Ok(mut engine) = self.engine.lock()
            && let Some(engine) = engine.as_mut()
        {
            engine.pause();
        }
    }

    /// Stops and forgets what is scheduled.
    pub fn stop(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
        if let Ok(mut engine) = self.engine.lock()
            && let Some(engine) = engine.as_mut()
        {
            engine.stop();
        }
    }

    /// 1 is normal (the server's clips at the reading's speed).
    pub fn set_rate(&self, rate: f64) {
        if let Ok(engine) = self.engine.lock()
            && let Some(engine) = engine.as_ref()
        {
            engine.set_rate(rate);
        }
    }

    /// What the player has played since it last started from a stop.
    pub fn played(&self) -> Duration {
        self.engine.lock().map_or(Duration::ZERO, |e| {
            e.as_ref().map_or(Duration::ZERO, platform::Engine::played)
        })
    }

    /// Counts an utterance or clip said on the call's engine.
    pub fn count_said(&self) {
        SAID.fetch_add(1, Ordering::Relaxed);
    }

    /// The engine stops now (the call is over); what holds this handle
    /// finds nothing to play on.
    fn shut(&self) {
        if let Ok(mut engine) = self.engine.lock() {
            engine.take();
        }
    }
}

#[cfg(target_os = "macos")]
use super::call_audio_mac as platform;

#[cfg(not(target_os = "macos"))]
mod platform {
    use std::sync::Arc;
    use std::time::Duration;

    use super::Taps;

    pub struct Engine;

    impl Engine {
        pub fn new(_muted: bool, _taps: Option<Arc<Taps>>) -> Result<Self, String> {
            Err("a call's audio needs macOS".into())
        }
        pub fn has_microphone(&self) -> bool {
            false
        }
        pub fn observe(&mut self, _changed: Box<dyn Fn() + Send + Sync>) {}
        pub fn take_observer(&mut self) -> Option<Box<dyn Fn() + Send + Sync>> {
            None
        }
        pub fn restart(&mut self) -> Result<(), String> {
            Ok(())
        }
        pub fn schedule(&self, _samples: &[f32], _done: Box<dyn Fn() + Send + Sync>) -> bool {
            false
        }
        pub fn play(&mut self) {}
        pub fn pause(&mut self) {}
        pub fn stop(&mut self) {}
        pub fn set_rate(&self, _rate: f64) {}
        pub fn played(&self) -> Duration {
            Duration::ZERO
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_utterance_completes_when_heard_not_when_written() {
        let mut u = Utterance::default();
        assert!(u.scheduled(), "the first chunk starts it");
        assert!(!u.scheduled());
        assert!(!u.played());
        // Written out while its second chunk still plays.
        assert!(!u.ended());
        assert!(!u.is_done());
        assert!(u.played(), "the last chunk heard completes it");
        assert!(u.is_done());
        // Once.
        assert!(!u.played());
        assert!(!u.cancel(), "a completed utterance is not cancelled");
    }

    #[test]
    fn an_utterance_written_out_after_its_chunks_played_completes_then() {
        let mut u = Utterance::default();
        u.scheduled();
        assert!(!u.played(), "more may come");
        assert!(u.drained());
        assert!(u.ended());
    }

    #[test]
    fn an_utterance_with_no_audio_starts_and_completes_as_it_ends() {
        let mut u = Utterance::default();
        assert!(u.ended());
        assert!(u.take_start());
        assert!(!u.drained());
    }

    #[test]
    fn a_stopped_utterance_is_cancelled_once_and_never_completes() {
        let mut u = Utterance::default();
        u.scheduled();
        assert!(u.cancel());
        assert!(!u.cancel());
        assert!(!u.ended());
        assert!(!u.played());
    }

    #[test]
    fn a_clip_is_where_it_was_scheduled_from_plus_what_played() {
        let second = RATE as usize;
        assert_eq!(
            clip_position(second, Duration::from_millis(500), 10 * second),
            Duration::from_millis(1500)
        );
        // Never past its end.
        assert_eq!(
            clip_position(second, Duration::from_secs(30), 2 * second),
            Duration::from_secs(2)
        );
        assert_eq!(time_to_frames(Duration::from_millis(250)), second / 4);
        assert_eq!(frames_to_time(second * 3), Duration::from_secs(3));
    }

    #[test]
    fn samples_come_to_the_players_rate_whole() {
        let tone: Vec<f32> = (0..22_050)
            .map(|i| (i as f32 * 440.0 * std::f32::consts::TAU / 22_050.0).sin() * 0.5)
            .collect();
        let out = to_rate(&tone, 22_050);
        assert_eq!(out.len(), RATE as usize, "one second in, one second out");
        // The tone's level survives, the tail included.
        let peak = out[out.len() - 200..]
            .iter()
            .fold(0.0f32, |m, s| m.max(s.abs()));
        assert!(peak > 0.3, "{peak}");
        assert_eq!(to_rate(&tone[..10], RATE), tone[..10].to_vec());
    }

    #[test]
    fn every_listen_hears_the_tap_and_a_gone_one_is_dropped() {
        let taps = Arc::new(Taps::default());
        let (a_tx, a_rx) = std::sync::mpsc::channel();
        let (b_tx, b_rx) = std::sync::mpsc::channel();
        let a = taps.add(a_tx);
        let _b = taps.add(b_tx);
        taps.send(&[0.25, 0.5], 48_000);
        for rx in [&a_rx, &b_rx] {
            match rx.try_recv() {
                Ok(WorkerMsg::Audio { samples, rate }) => {
                    assert_eq!((samples, rate), (vec![0.25, 0.5], 48_000))
                }
                _ => panic!("no audio"),
            }
        }
        taps.remove(a);
        drop(b_rx);
        taps.send(&[0.0], 48_000);
        assert!(taps.is_empty(), "the gone listen was dropped");
        assert!(a_rx.try_recv().is_err(), "a removed listen hears nothing");
    }

    #[test]
    fn a_listen_on_the_call_lets_go_of_the_tap_when_it_stops() {
        let taps = Arc::new(Taps::default());
        let factory = {
            let taps = taps.clone();
            Box::new(move |tx: Sender<WorkerMsg>| {
                let id = taps.add(tx);
                Ok(Box::new(TapInput { id, taps }) as Box<dyn Input>)
            }) as InputFactory
        };
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut input = factory(tx).ok().unwrap();
        assert_eq!(taps.len(), 1);
        assert!(input.restart().is_ok());
        input.stop();
        assert!(taps.is_empty());
        drop(input);
        assert!(taps.is_empty());
    }
}
