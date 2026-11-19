//! A Standard call's engine on this Mac ([`super::call_audio`]): one
//! `AVAudioEngine`, its input through the voice-processing unit and
//! tapped, and a player node (through a time-pitch unit, for the reading's
//! speed) on the same engine, so what it plays is taken out of what the
//! microphone hears.
//!
//! The engine is made on the main thread; the player is scheduled from the
//! voice's writing thread too, always under [`super::call_audio`]'s lock.
//! The tap and the completion blocks only hand samples and calls on.

use std::ptr::null_mut;
use std::sync::Arc;
use std::time::Duration;

use block2::RcBlock;
use objc2::rc::{Allocated, Retained};
use objc2::runtime::AnyObject;
use objc2::{class, msg_send};
use objc2_foundation::NSString;

use super::call_audio::{RATE, Taps};
use super::mac::{describe, enable_voice_processing, mono_samples};

#[link(name = "AVFAudio", kind = "framework")]
unsafe extern "C" {
    static AVAudioEngineConfigurationChangeNotification: &'static NSString;
}

/// `AVAudioPCMFormatFloat32`.
const FLOAT32: usize = 1;
/// `AVAudioPCMFormatInt16`.
const INT16: usize = 3;
/// `AVAudioPlayerNodeCompletionDataPlayedBack`.
const PLAYED_BACK: isize = 2;

type Changed = Arc<dyn Fn() + Send + Sync>;

pub struct Engine {
    engine: Retained<AnyObject>,
    player: Retained<AnyObject>,
    pitch: Retained<AnyObject>,
    format: Retained<AnyObject>,
    microphone: bool,
    playing: bool,
    last_played: Duration,
    observer: Option<Retained<AnyObject>>,
    changed: Option<Changed>,
}

// SAFETY: the engine's objects are only touched under `call_audio`'s lock,
// one thread at a time; AVAudioEngine and its nodes may be driven from any
// thread so long as calls are not made at once.
unsafe impl Send for Engine {}

impl Engine {
    /// A started engine: the player, and with `taps` the microphone through
    /// voice processing, its samples to the taps.
    pub fn new(muted: bool, taps: Option<Arc<Taps>>) -> Result<Self, String> {
        // SAFETY: AVFAudio; every object is owned by the engine made here.
        unsafe {
            let engine: Option<Retained<AnyObject>> = msg_send![class!(AVAudioEngine), new];
            let engine = engine.ok_or("no audio engine")?;
            let microphone = taps.is_some();
            if let Some(taps) = taps {
                let device: Option<Retained<AnyObject>> = msg_send![
                    class!(AVCaptureDevice),
                    defaultDeviceWithMediaType: &*NSString::from_str("soun")
                ];
                if device.is_none() {
                    return Err("There is no microphone.".into());
                }
                let input: *mut AnyObject = msg_send![&*engine, inputNode];
                if input.is_null() {
                    return Err("There is no microphone.".into());
                }
                // Before the format is read, and before anything is
                // connected: the unit has its own.
                if !enable_voice_processing(input) {
                    log::warn!("call audio: no voice processing; echo is not cancelled");
                }
                let format: *mut AnyObject = msg_send![input, outputFormatForBus: 0usize];
                let rate: f64 = msg_send![format, sampleRate];
                let channels: u32 = msg_send![format, channelCount];
                if rate < 1.0 || channels == 0 {
                    return Err("There is no microphone.".into());
                }
                let rate = rate.round() as u32;
                let tap = RcBlock::new(move |buffer: *mut AnyObject, _when: *mut AnyObject| {
                    if let Some(samples) = mono_samples(buffer) {
                        taps.send(&samples, rate);
                    }
                });
                let _: () = msg_send![
                    input,
                    installTapOnBus: 0usize,
                    bufferSize: 2048u32,
                    format: format,
                    block: &*tap
                ];
            }
            let player: Option<Retained<AnyObject>> = msg_send![class!(AVAudioPlayerNode), new];
            let player = player.ok_or("no player")?;
            let pitch: Option<Retained<AnyObject>> = msg_send![class!(AVAudioUnitTimePitch), new];
            let pitch = pitch.ok_or("no time-pitch unit")?;
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
            let _: () = msg_send![&*engine, attachNode: &*pitch];
            let mixer: *mut AnyObject = msg_send![&*engine, mainMixerNode];
            let _: () = msg_send![&*engine, connect: &*player, to: &*pitch, format: &*format];
            let _: () = msg_send![&*engine, connect: &*pitch, to: mixer, format: &*format];
            if muted {
                let _: () = msg_send![&*player, setVolume: 0f32];
            }
            let _: () = msg_send![&*engine, prepare];
            let mut error: *mut AnyObject = null_mut();
            let started: bool = msg_send![&*engine, startAndReturnError: &mut error];
            if !started {
                if microphone {
                    let input: *mut AnyObject = msg_send![&*engine, inputNode];
                    let _: () = msg_send![input, removeTapOnBus: 0usize];
                }
                return Err(describe(error));
            }
            Ok(Self {
                engine,
                player,
                pitch,
                format,
                microphone,
                playing: false,
                last_played: Duration::ZERO,
                observer: None,
                changed: None,
            })
        }
    }

    pub fn has_microphone(&self) -> bool {
        self.microphone
    }

    /// `changed` runs (on a thread of its own, a moment later) when the
    /// audio device changes under the engine, which stops it.
    pub fn observe(&mut self, changed: Box<dyn Fn() + Send + Sync>) {
        let changed: Changed = Arc::from(changed);
        self.remove_observer();
        let call = changed.clone();
        let block = RcBlock::new(move |_: *mut AnyObject| {
            // Not here: the posting thread may wait on the one holding the
            // engine's lock.
            let call = call.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(100));
                call();
            });
        });
        // SAFETY: the notification center keeps the block; the token is
        // removed with the engine.
        unsafe {
            let center: *mut AnyObject = msg_send![class!(NSNotificationCenter), defaultCenter];
            let observer: Option<Retained<AnyObject>> = msg_send![
                center,
                addObserverForName: AVAudioEngineConfigurationChangeNotification,
                object: &*self.engine,
                queue: null_mut::<AnyObject>(),
                usingBlock: &*block
            ];
            self.observer = observer;
        }
        self.changed = Some(changed);
    }

    /// What [`Self::observe`] was given, for the engine made after this one.
    pub fn take_observer(&mut self) -> Option<Box<dyn Fn() + Send + Sync>> {
        self.remove_observer();
        self.changed
            .take()
            .map(|c| Box::new(move || c()) as Box<dyn Fn() + Send + Sync>)
    }

    fn remove_observer(&mut self) {
        if let Some(observer) = self.observer.take() {
            // SAFETY: the token `observe` got.
            unsafe {
                let center: *mut AnyObject = msg_send![class!(NSNotificationCenter), defaultCenter];
                let _: () = msg_send![center, removeObserver: &*observer];
            }
        }
    }

    fn running(&self) -> bool {
        // SAFETY: this engine.
        unsafe { msg_send![&*self.engine, isRunning] }
    }

    /// Starts the engine again (on the new device), and the player when it
    /// played.
    pub fn restart(&mut self) -> Result<(), String> {
        if !self.running() {
            // SAFETY: as above.
            unsafe {
                let _: () = msg_send![&*self.engine, prepare];
                let mut error: *mut AnyObject = null_mut();
                let started: bool = msg_send![&*self.engine, startAndReturnError: &mut error];
                if !started {
                    return Err(describe(error));
                }
            }
        }
        if self.playing {
            // SAFETY: the engine runs.
            unsafe {
                let _: () = msg_send![&*self.player, play];
            }
        }
        Ok(())
    }

    pub fn schedule(&self, samples: &[f32], done: Box<dyn Fn() + Send + Sync>) -> bool {
        if samples.is_empty() {
            return false;
        }
        // SAFETY: a buffer of the player's format, filled before it is
        // scheduled; the block only calls `done`.
        unsafe {
            let buffer: Allocated<AnyObject> = msg_send![class!(AVAudioPCMBuffer), alloc];
            let buffer: Option<Retained<AnyObject>> = msg_send![
                buffer,
                initWithPCMFormat: &*self.format,
                frameCapacity: samples.len() as u32
            ];
            let Some(buffer) = buffer else { return false };
            let _: () = msg_send![&*buffer, setFrameLength: samples.len() as u32];
            let data: *const *mut f32 = msg_send![&*buffer, floatChannelData];
            if data.is_null() || (*data).is_null() {
                return false;
            }
            std::slice::from_raw_parts_mut(*data, samples.len()).copy_from_slice(samples);
            let block = RcBlock::new(move |_kind: isize| done());
            let _: () = msg_send![
                &*self.player,
                scheduleBuffer: &*buffer,
                completionCallbackType: PLAYED_BACK,
                completionHandler: &*block
            ];
        }
        true
    }

    pub fn play(&mut self) {
        // A player whose engine is not running raises: start it first.
        if !self.running() && self.restart().is_err() {
            return;
        }
        self.playing = true;
        // SAFETY: the engine runs.
        unsafe {
            let _: () = msg_send![&*self.player, play];
        }
    }

    pub fn pause(&mut self) {
        self.last_played = self.played();
        self.playing = false;
        // SAFETY: this engine's player.
        unsafe {
            let _: () = msg_send![&*self.player, pause];
        }
    }

    pub fn stop(&mut self) {
        self.playing = false;
        self.last_played = Duration::ZERO;
        // SAFETY: as above.
        unsafe {
            let _: () = msg_send![&*self.player, stop];
        }
    }

    pub fn set_rate(&self, rate: f64) {
        // SAFETY: this engine's time-pitch unit.
        unsafe {
            let _: () = msg_send![&*self.pitch, setRate: rate.clamp(1.0 / 32.0, 32.0) as f32];
        }
    }

    /// The player's time: what it has played since it last started from a
    /// stop (where it was paused, while paused).
    pub fn played(&self) -> Duration {
        if !self.playing {
            return self.last_played;
        }
        // SAFETY: the player's own clock; both may be nil.
        unsafe {
            let node_time: *mut AnyObject = msg_send![&*self.player, lastRenderTime];
            if node_time.is_null() {
                return self.last_played;
            }
            let player_time: *mut AnyObject =
                msg_send![&*self.player, playerTimeForNodeTime: node_time];
            if player_time.is_null() {
                return self.last_played;
            }
            let sample: i64 = msg_send![player_time, sampleTime];
            let rate: f64 = msg_send![player_time, sampleRate];
            if rate < 1.0 || sample < 0 {
                return Duration::ZERO;
            }
            Duration::from_secs_f64(sample as f64 / rate)
        }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.remove_observer();
        // SAFETY: this engine and its nodes.
        unsafe {
            let _: () = msg_send![&*self.player, stop];
            let _: () = msg_send![&*self.engine, stop];
            if self.microphone {
                let input: *mut AnyObject = msg_send![&*self.engine, inputNode];
                if !input.is_null() {
                    let _: () = msg_send![input, removeTapOnBus: 0usize];
                }
            }
        }
    }
}

/// An `AVAudioPCMBuffer`'s samples, mono, and its rate: 32-bit float or
/// 16-bit integer (what the Mac's voices write).
///
/// # Safety
/// `buffer` is an `AVAudioBuffer` (or null), alive for the call.
pub unsafe fn buffer_samples(buffer: *mut AnyObject) -> Option<(Vec<f32>, u32)> {
    if buffer.is_null() {
        return None;
    }
    // SAFETY: the caller's; the data pointers are valid for frameLength
    // frames while the buffer lives.
    unsafe {
        let pcm: bool = msg_send![buffer, isKindOfClass: class!(AVAudioPCMBuffer)];
        if !pcm {
            return None;
        }
        let format: *mut AnyObject = msg_send![buffer, format];
        let rate: f64 = msg_send![format, sampleRate];
        let common: usize = msg_send![format, commonFormat];
        let rate = rate.round() as u32;
        match common {
            FLOAT32 => mono_samples(buffer).map(|s| (s, rate)),
            INT16 => {
                let frames: u32 = msg_send![buffer, frameLength];
                let data: *const *mut i16 = msg_send![buffer, int16ChannelData];
                if frames == 0 || data.is_null() {
                    return Some((vec![], rate));
                }
                let channels: u32 = msg_send![format, channelCount];
                let channels = channels.max(1) as usize;
                let interleaved: bool = msg_send![format, isInterleaved];
                let frames = frames as usize;
                let scale = 1.0 / 32_768.0;
                let samples = if interleaved {
                    std::slice::from_raw_parts(*data, frames * channels)
                        .chunks(channels)
                        .map(|f| f.iter().map(|s| f32::from(*s)).sum::<f32>() * scale)
                        .map(|s| s / channels as f32)
                        .collect()
                } else {
                    (0..frames)
                        .map(|i| {
                            (0..channels)
                                .map(|c| f32::from(*(*data.add(c)).add(i)))
                                .sum::<f32>()
                                * scale
                                / channels as f32
                        })
                        .collect()
                };
                Some((samples, rate))
            }
            _ => None,
        }
    }
}

/// A clip's file type from its first bytes, for the extension
/// `AVAudioFile` reads it by.
fn extension(bytes: &[u8]) -> &'static str {
    match bytes {
        [b'I', b'D', b'3', ..] => "mp3",
        [0xFF, b, ..] if b & 0xE0 == 0xE0 => "mp3",
        [b'O', b'g', b'g', b'S', ..] => "ogg",
        [b'f', b'L', b'a', b'C', ..] => "flac",
        [_, _, _, _, b'f', b't', b'y', b'p', ..] => "m4a",
        _ => "mp3",
    }
}

/// A clip's samples, mono, and its rate: WAV here, anything else the Mac
/// reads through `AVAudioFile` (from a file of the app's own, gone after).
pub fn decode(bytes: &[u8]) -> Option<(Vec<f32>, u32)> {
    if bytes.starts_with(b"RIFF") {
        return crate::voice::pcm::decode_wav(bytes).ok();
    }
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!(
        "conduit-call-clip-{}-{n}.{}",
        std::process::id(),
        extension(bytes)
    ));
    std::fs::write(&path, bytes).ok()?;
    let decoded = read_file(&path);
    let _ = std::fs::remove_file(&path);
    decoded
}

fn read_file(path: &std::path::Path) -> Option<(Vec<f32>, u32)> {
    // SAFETY: AVFAudio; the file and buffer live for this call.
    unsafe {
        let path = NSString::from_str(&path.to_string_lossy());
        let url: Option<Retained<AnyObject>> = msg_send![class!(NSURL), fileURLWithPath: &*path];
        let url = url?;
        let file: Allocated<AnyObject> = msg_send![class!(AVAudioFile), alloc];
        let mut error: *mut AnyObject = null_mut();
        let file: Option<Retained<AnyObject>> =
            msg_send![file, initForReading: &*url, error: &mut error];
        let Some(file) = file else {
            log::warn!("call audio: a clip would not open: {}", describe(error));
            return None;
        };
        let format: *mut AnyObject = msg_send![&*file, processingFormat];
        let length: i64 = msg_send![&*file, length];
        if length <= 0 || format.is_null() {
            return None;
        }
        let rate: f64 = msg_send![format, sampleRate];
        let buffer: Allocated<AnyObject> = msg_send![class!(AVAudioPCMBuffer), alloc];
        let buffer: Option<Retained<AnyObject>> = msg_send![
            buffer,
            initWithPCMFormat: format,
            frameCapacity: length.min(i64::from(u32::MAX)) as u32
        ];
        let buffer = buffer?;
        let read: bool = msg_send![&*file, readIntoBuffer: &*buffer, error: &mut error];
        if !read {
            log::warn!("call audio: a clip would not read: {}", describe(error));
            return None;
        }
        let ptr: *mut AnyObject = Retained::as_ptr(&buffer).cast_mut();
        mono_samples(ptr).map(|s| (s, rate.round() as u32))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_clip_is_read_by_what_its_bytes_say_it_is() {
        assert_eq!(extension(b"ID3\x04rest"), "mp3");
        assert_eq!(extension(&[0xFF, 0xFB, 0x90, 0x00]), "mp3");
        assert_eq!(extension(b"OggS\0\x02"), "ogg");
        assert_eq!(extension(b"fLaC\0\0"), "flac");
        assert_eq!(extension(b"\0\0\0\x20ftypM4A "), "m4a");
    }

    #[test]
    fn a_wav_clip_is_decoded_here() {
        let samples: Vec<f32> = (0..1600).map(|i| ((i % 40) as f32 - 20.0) / 40.0).collect();
        let wav = crate::voice::pcm::wav(&crate::voice::pcm::to_pcm16(&samples));
        let (decoded, rate) = decode(&wav).expect("decoded");
        assert_eq!(rate, crate::voice::pcm::RATE);
        assert_eq!(decoded.len(), samples.len());
    }
}
