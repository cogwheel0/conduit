//! A realtime call's audio on this Mac: one `AVAudioEngine` whose input
//! runs through the voice-processing unit, with the voice played on a
//! player node of the same engine. Echo cancellation needs both on the one
//! unit: what the node plays is taken out of what the microphone hears, so
//! the voice never hears itself (Open WebUI's web client gets the same from
//! the browser's echo cancellation).
//!
//! The objects live on the call's audio thread ([`super::realtime`]), which
//! made them; the tap and the completion blocks only send it messages.

use std::ptr::null_mut;
use std::sync::mpsc::Sender;
use std::time::Duration;

use block2::RcBlock;
use objc2::rc::{Allocated, Retained};
use objc2::runtime::AnyObject;
use objc2::{class, msg_send};
use objc2_foundation::NSString;

use super::mac::{describe, enable_voice_processing, mono_samples};
use super::realtime::{Devices, EngineMsg, Microphone, RATE, Speaker};

#[link(name = "AVFAudio", kind = "framework")]
unsafe extern "C" {
    static AVAudioEngineConfigurationChangeNotification: &'static NSString;
}

/// `AVAudioPCMFormatFloat32`.
const FLOAT32: usize = 1;
/// `AVAudioPlayerNodeCompletionDataPlayedBack`.
const PLAYED_BACK: isize = 2;

/// The microphone and the speaker on one voice-processing engine; the
/// speaker is left out when `muted` (time is still kept).
pub fn devices(tx: Sender<EngineMsg>, muted: bool) -> Result<Devices, String> {
    // SAFETY: AVFAudio on the call's audio thread, which owns the engine.
    unsafe {
        let device: Option<Retained<AnyObject>> = msg_send![
            class!(AVCaptureDevice),
            defaultDeviceWithMediaType: &*NSString::from_str("soun")
        ];
        if device.is_none() {
            return Err("There is no microphone.".into());
        }
        let engine: Option<Retained<AnyObject>> = msg_send![class!(AVAudioEngine), new];
        let engine = engine.ok_or("no audio engine")?;
        let input: *mut AnyObject = msg_send![&*engine, inputNode];
        if input.is_null() {
            return Err("There is no microphone.".into());
        }
        enable_voice_processing(input);
        let format: *mut AnyObject = msg_send![input, outputFormatForBus: 0usize];
        let rate: f64 = msg_send![format, sampleRate];
        let channels: u32 = msg_send![format, channelCount];
        if rate < 1.0 || channels == 0 {
            return Err("There is no microphone.".into());
        }
        let rate = rate.round() as u32;
        let taps = tx.clone();
        let tap = RcBlock::new(move |buffer: *mut AnyObject, _when: *mut AnyObject| {
            if let Some(samples) = mono_samples(buffer) {
                let _ = taps.send(EngineMsg::Samples(samples, rate));
            }
        });
        let _: () = msg_send![
            input,
            installTapOnBus: 0usize,
            bufferSize: 2048u32,
            format: format,
            block: &*tap
        ];
        let speaker = if muted {
            None
        } else {
            Some(DeviceSpeaker::attach(engine.clone(), tx.clone())?)
        };
        // A device that changes under the call stops the engine: the call
        // says so rather than going quiet.
        let changed = tx.clone();
        let block = RcBlock::new(move |_: *mut AnyObject| {
            let _ = changed.send(EngineMsg::InputFailed(
                "The audio device changed. Start the call again.".into(),
            ));
        });
        let center: *mut AnyObject = msg_send![class!(NSNotificationCenter), defaultCenter];
        let observer: Option<Retained<AnyObject>> = msg_send![
            center,
            addObserverForName: AVAudioEngineConfigurationChangeNotification,
            object: &*engine,
            queue: null_mut::<AnyObject>(),
            usingBlock: &*block
        ];
        let _: () = msg_send![&*engine, prepare];
        let mut error: *mut AnyObject = null_mut();
        let started: bool = msg_send![&*engine, startAndReturnError: &mut error];
        if !started {
            let _: () = msg_send![input, removeTapOnBus: 0usize];
            return Err(describe(error));
        }
        Ok(Devices {
            microphone: Box::new(EngineMicrophone { engine, observer }),
            speaker: speaker.map(|s| Box::new(s) as Box<dyn Speaker>),
        })
    }
}

struct EngineMicrophone {
    engine: Retained<AnyObject>,
    observer: Option<Retained<AnyObject>>,
}

impl Microphone for EngineMicrophone {}

impl Drop for EngineMicrophone {
    fn drop(&mut self) {
        // SAFETY: the engine and the observer this microphone made.
        unsafe {
            let _: () = msg_send![&*self.engine, stop];
            let input: *mut AnyObject = msg_send![&*self.engine, inputNode];
            if !input.is_null() {
                let _: () = msg_send![input, removeTapOnBus: 0usize];
            }
            if let Some(observer) = self.observer.take() {
                let center: *mut AnyObject = msg_send![class!(NSNotificationCenter), defaultCenter];
                let _: () = msg_send![center, removeObserver: &*observer];
            }
        }
    }
}

/// The voice, played on a node of the call's engine (or, with a WAV file
/// standing in for the microphone, an engine of its own).
pub struct DeviceSpeaker {
    engine: Retained<AnyObject>,
    player: Retained<AnyObject>,
    format: Retained<AnyObject>,
    tx: Sender<EngineMsg>,
    generation: u64,
    /// Whether this speaker started the engine itself.
    owns_engine: bool,
}

impl DeviceSpeaker {
    /// A speaker with an engine of its own (no microphone on it).
    pub fn new(tx: Sender<EngineMsg>) -> Result<Self, String> {
        // SAFETY: as in `devices`.
        unsafe {
            let engine: Option<Retained<AnyObject>> = msg_send![class!(AVAudioEngine), new];
            let engine = engine.ok_or("no audio engine")?;
            let mut speaker = Self::attach(engine, tx)?;
            let engine = speaker.engine.clone();
            let _: () = msg_send![&*engine, prepare];
            let mut error: *mut AnyObject = null_mut();
            let started: bool = msg_send![&*engine, startAndReturnError: &mut error];
            if !started {
                return Err(describe(error));
            }
            speaker.owns_engine = true;
            Ok(speaker)
        }
    }

    /// # Safety
    /// On the thread that owns `engine`, before it starts.
    unsafe fn attach(engine: Retained<AnyObject>, tx: Sender<EngineMsg>) -> Result<Self, String> {
        // SAFETY: the caller's.
        unsafe {
            let player: Option<Retained<AnyObject>> = msg_send![class!(AVAudioPlayerNode), new];
            let player = player.ok_or("no player")?;
            let format: Allocated<AnyObject> = msg_send![class!(AVAudioFormat), alloc];
            let format: Option<Retained<AnyObject>> = msg_send![
                format,
                initWithCommonFormat: FLOAT32,
                sampleRate: f64::from(RATE),
                channels: 1u32,
                interleaved: false
            ];
            let format = format.ok_or("no audio format")?;
            let _: () = msg_send![&*engine, attachNode: &*player];
            let mixer: *mut AnyObject = msg_send![&*engine, mainMixerNode];
            let _: () = msg_send![
                &*engine,
                connect: &*player,
                to: mixer,
                format: &*format
            ];
            Ok(Self {
                engine,
                player,
                format,
                tx,
                generation: 0,
                owns_engine: false,
            })
        }
    }
}

impl Speaker for DeviceSpeaker {
    fn schedule(&mut self, pcm: &[i16]) {
        if pcm.is_empty() {
            return;
        }
        // SAFETY: a buffer of this speaker's format, filled before it is
        // scheduled; the block only sends a message.
        unsafe {
            let buffer: Allocated<AnyObject> = msg_send![class!(AVAudioPCMBuffer), alloc];
            let buffer: Option<Retained<AnyObject>> = msg_send![
                buffer,
                initWithPCMFormat: &*self.format,
                frameCapacity: pcm.len() as u32
            ];
            let Some(buffer) = buffer else { return };
            let _: () = msg_send![&*buffer, setFrameLength: pcm.len() as u32];
            let data: *const *mut f32 = msg_send![&*buffer, floatChannelData];
            if data.is_null() || (*data).is_null() {
                return;
            }
            let channel = std::slice::from_raw_parts_mut(*data, pcm.len());
            for (out, sample) in channel.iter_mut().zip(pcm) {
                *out = f32::from(*sample) / 32_768.0;
            }
            let tx = self.tx.clone();
            let generation = self.generation;
            let done = RcBlock::new(move |_kind: isize| {
                let _ = tx.send(EngineMsg::Played(generation));
            });
            let _: () = msg_send![
                &*self.player,
                scheduleBuffer: &*buffer,
                completionCallbackType: PLAYED_BACK,
                completionHandler: &*done
            ];
        }
    }

    fn play(&mut self) {
        // SAFETY: this speaker's player.
        unsafe {
            let _: () = msg_send![&*self.player, play];
        }
    }

    fn pause(&mut self) {
        // SAFETY: as above.
        unsafe {
            let _: () = msg_send![&*self.player, pause];
        }
    }

    fn stop(&mut self) {
        self.generation += 1;
        // SAFETY: as above.
        unsafe {
            let _: () = msg_send![&*self.player, stop];
        }
    }

    fn latency(&self) -> Duration {
        // SAFETY: the engine's output node.
        let seconds: f64 = unsafe {
            let output: *mut AnyObject = msg_send![&*self.engine, outputNode];
            if output.is_null() {
                0.0
            } else {
                msg_send![output, presentationLatency]
            }
        };
        Duration::from_secs_f64(seconds.max(0.0))
    }
}

impl Drop for DeviceSpeaker {
    fn drop(&mut self) {
        // SAFETY: as above.
        unsafe {
            let _: () = msg_send![&*self.player, stop];
            if self.owns_engine {
                let _: () = msg_send![&*self.engine, stop];
            }
        }
    }
}
