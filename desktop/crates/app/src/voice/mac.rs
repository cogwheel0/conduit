//! The Mac's side of dictation, through objc2 (no Swift layer, as
//! `shell::speech` does AVSpeech):
//!
//! * the microphone: `AVAudioEngine`'s input node, tapped. The tap runs on
//!   AVFAudio's own thread and only hands samples to the dictation thread.
//!   The input node is the system's default input device; when that
//!   changes, the engine posts `AVAudioEngineConfigurationChangeNotification`
//!   and the dictation thread starts it again on the new device;
//! * this Mac's recognizer: `SFSpeechRecognizer` with an audio-buffer
//!   request, on-device only (the phone's device engine allows no online
//!   fallback either), partial results on, punctuation added. Apple's newer
//!   `SpeechAnalyzer` (macOS 26) is Swift-only -- async sequences with no
//!   Objective-C face -- so it would need a Swift bridge in the bundle; the
//!   older recognizer reaches every macOS the app supports (14+);
//! * the permissions both need, and a file recognition for a saved
//!   recording.

use std::ptr::null_mut;
use std::sync::Mutex;
use std::sync::mpsc::Sender;

use block2::RcBlock;
use objc2::rc::{Allocated, Retained};
use objc2::runtime::{AnyObject, Bool};
use objc2::{class, msg_send};
use objc2_foundation::NSString;

use super::pcm;
use super::session::{
    Input, InputError, InputFactory, Recognizer, RecognizerFactory, SessionError, WorkerMsg,
};

#[link(name = "AVFAudio", kind = "framework")]
unsafe extern "C" {
    static AVAudioEngineConfigurationChangeNotification: &'static NSString;
}

#[link(name = "AVFoundation", kind = "framework")]
unsafe extern "C" {
    static AVMediaTypeAudio: &'static NSString;
}

#[link(name = "Speech", kind = "framework")]
unsafe extern "C" {}

/// A permission's state, as AVFoundation and Speech report it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Permission {
    NotAsked,
    Denied,
    /// A profile or parental control forbids it.
    Restricted,
    Granted,
}

/// The microphone's permission (`AVCaptureDevice`).
pub fn microphone() -> Permission {
    // SAFETY: a class method with a constant argument.
    let status: isize = unsafe {
        msg_send![class!(AVCaptureDevice), authorizationStatusForMediaType: AVMediaTypeAudio]
    };
    match status {
        0 => Permission::NotAsked,
        1 => Permission::Restricted,
        2 => Permission::Denied,
        _ => Permission::Granted,
    }
}

/// Asks for the microphone (the system's prompt, once); `done` hears the
/// answer on another thread.
pub fn request_microphone(done: impl FnOnce(bool) + Send + 'static) {
    // A scripted run never raises the prompt (see `crate::scripted`).
    if crate::scripted::active() {
        log::info!("microphone not asked for: a scripted run");
        done(false);
        return;
    }
    let done = Mutex::new(Some(done));
    let block = RcBlock::new(move |granted: Bool| {
        if let Some(done) = done.lock().ok().and_then(|mut d| d.take()) {
            done(granted.as_bool());
        }
    });
    // SAFETY: AVFoundation copies the block and calls it once.
    unsafe {
        let _: () = msg_send![
            class!(AVCaptureDevice),
            requestAccessForMediaType: AVMediaTypeAudio,
            completionHandler: &*block
        ];
    }
}

/// Speech recognition's permission (`SFSpeechRecognizer`).
pub fn speech() -> Permission {
    // SAFETY: a class method.
    let status: isize = unsafe { msg_send![class!(SFSpeechRecognizer), authorizationStatus] };
    match status {
        0 => Permission::NotAsked,
        1 => Permission::Denied,
        2 => Permission::Restricted,
        _ => Permission::Granted,
    }
}

/// Asks for speech recognition (the system's prompt, once).
pub fn request_speech(done: impl FnOnce(Permission) + Send + 'static) {
    // A scripted run never raises the prompt (see `crate::scripted`).
    if crate::scripted::active() {
        log::info!("speech recognition not asked for: a scripted run");
        done(speech());
        return;
    }
    let done = Mutex::new(Some(done));
    let block = RcBlock::new(move |_status: isize| {
        if let Some(done) = done.lock().ok().and_then(|mut d| d.take()) {
            done(speech());
        }
    });
    // SAFETY: Speech copies the block and calls it once.
    unsafe {
        let _: () = msg_send![class!(SFSpeechRecognizer), requestAuthorization: &*block];
    }
}

// ── The microphone ─────────────────────────────────────────────────────

/// The default input device, through `AVAudioEngine`.
pub fn microphone_input() -> InputFactory {
    microphone_input_with(false)
}

/// The default input device; with `voice_processing`, through the
/// voice-processing unit (a call's microphone), which takes what the Mac
/// plays out of what it hears, so a spoken answer is not heard back as the
/// user's words.
pub fn microphone_input_with(voice_processing: bool) -> InputFactory {
    Box::new(move |tx: Sender<WorkerMsg>| {
        let mut mic = Mic::new(tx)?;
        mic.voice_processing = voice_processing;
        mic.start()?;
        Ok(Box::new(mic) as Box<dyn Input>)
    })
}

struct Mic {
    engine: Retained<AnyObject>,
    tx: Sender<WorkerMsg>,
    observer: Option<Retained<AnyObject>>,
    tapped: bool,
    voice_processing: bool,
}

/// `AVAudioVoiceProcessingOtherAudioDuckingConfiguration` (macOS 14).
#[repr(C)]
struct DuckingConfiguration {
    enable_advanced_ducking: Bool,
    ducking_level: isize,
}

// SAFETY: the layout and encoding of the AVFAudio struct.
unsafe impl objc2::Encode for DuckingConfiguration {
    const ENCODING: objc2::Encoding = objc2::Encoding::Struct(
        "AVAudioVoiceProcessingOtherAudioDuckingConfiguration",
        &[Bool::ENCODING, isize::ENCODING],
    );
}

/// Turns on `input`'s voice processing (echo cancellation), ducking other
/// audio as little as it can: the answer a Standard call speaks plays
/// through the Mac's voices, outside this engine. False when the Mac
/// refused; the microphone then works without it.
///
/// # Safety
/// `input` is the engine's `AVAudioInputNode`; the engine is stopped.
pub(crate) unsafe fn enable_voice_processing(input: *mut AnyObject) -> bool {
    // SAFETY: the caller's.
    unsafe {
        let mut error: *mut AnyObject = null_mut();
        let ok: bool = msg_send![input, setVoiceProcessingEnabled: true, error: &mut error];
        if !ok {
            log::warn!("voice processing: {}", describe(error));
            return false;
        }
        let ducking = objc2::sel!(setVoiceProcessingOtherAudioDuckingConfiguration:);
        let responds: bool = msg_send![input, respondsToSelector: ducking];
        if responds {
            let configuration = DuckingConfiguration {
                enable_advanced_ducking: Bool::YES,
                // AVAudioVoiceProcessingOtherAudioDuckingLevelMin.
                ducking_level: 10,
            };
            let _: () = msg_send![
                input,
                setVoiceProcessingOtherAudioDuckingConfiguration: configuration
            ];
        }
        true
    }
}

impl Mic {
    fn new(tx: Sender<WorkerMsg>) -> Result<Self, InputError> {
        // No input device at all (a Mac mini with nothing plugged in): the
        // engine's input node would raise rather than answer.
        // SAFETY: a class method with a constant argument.
        let device: Option<Retained<AnyObject>> = unsafe {
            msg_send![class!(AVCaptureDevice), defaultDeviceWithMediaType: AVMediaTypeAudio]
        };
        if device.is_none() {
            return Err(InputError::Unavailable("no input device".into()));
        }
        // SAFETY: AVFAudio on the dictation thread, which owns the engine.
        unsafe {
            let engine: Option<Retained<AnyObject>> = msg_send![class!(AVAudioEngine), new];
            let engine = engine.ok_or_else(|| InputError::Unavailable("no audio engine".into()))?;
            let changed = tx.clone();
            let block = RcBlock::new(move |_: *mut AnyObject| {
                let _ = changed.send(WorkerMsg::InputChanged);
            });
            let center: *mut AnyObject = msg_send![class!(NSNotificationCenter), defaultCenter];
            let observer: Option<Retained<AnyObject>> = msg_send![
                center,
                addObserverForName: AVAudioEngineConfigurationChangeNotification,
                object: &*engine,
                queue: null_mut::<AnyObject>(),
                usingBlock: &*block
            ];
            Ok(Self {
                engine,
                tx,
                observer,
                tapped: false,
                voice_processing: false,
            })
        }
    }

    fn start(&mut self) -> Result<(), InputError> {
        // SAFETY: as above; the tap block only reads the buffer it is given.
        unsafe {
            let input: *mut AnyObject = msg_send![&*self.engine, inputNode];
            if input.is_null() {
                return Err(InputError::Unavailable("no input node".into()));
            }
            if self.voice_processing {
                // Before the format is read: the unit has its own.
                enable_voice_processing(input);
            }
            let format: *mut AnyObject = msg_send![input, outputFormatForBus: 0usize];
            let rate: f64 = msg_send![format, sampleRate];
            let channels: u32 = msg_send![format, channelCount];
            if rate < 1.0 || channels == 0 {
                return Err(InputError::Unavailable("no input device".into()));
            }
            let tx = self.tx.clone();
            let rate = rate.round() as u32;
            let block = RcBlock::new(move |buffer: *mut AnyObject, _when: *mut AnyObject| {
                if let Some(samples) = mono_samples(buffer) {
                    let _ = tx.send(WorkerMsg::Audio { samples, rate });
                }
            });
            let _: () = msg_send![
                input,
                installTapOnBus: 0usize,
                bufferSize: 4096u32,
                format: format,
                block: &*block
            ];
            self.tapped = true;
            let _: () = msg_send![&*self.engine, prepare];
            let mut error: *mut AnyObject = null_mut();
            let started: bool = msg_send![&*self.engine, startAndReturnError: &mut error];
            if !started {
                self.stop_engine();
                return Err(InputError::Unavailable(describe(error)));
            }
        }
        Ok(())
    }

    fn stop_engine(&mut self) {
        // SAFETY: as above.
        unsafe {
            let _: () = msg_send![&*self.engine, stop];
            if self.tapped {
                let input: *mut AnyObject = msg_send![&*self.engine, inputNode];
                if !input.is_null() {
                    let _: () = msg_send![input, removeTapOnBus: 0usize];
                }
                self.tapped = false;
            }
        }
    }
}

/// A tap buffer's samples, mono.
///
/// # Safety
/// `buffer` is an `AVAudioPCMBuffer` (or null).
pub(crate) unsafe fn mono_samples(buffer: *mut AnyObject) -> Option<Vec<f32>> {
    if buffer.is_null() {
        return None;
    }
    // SAFETY: the caller's; the data pointers are valid for frameLength
    // frames while the tap block runs.
    unsafe {
        let frames: u32 = msg_send![buffer, frameLength];
        let data: *const *mut f32 = msg_send![buffer, floatChannelData];
        if frames == 0 || data.is_null() {
            return None;
        }
        let format: *mut AnyObject = msg_send![buffer, format];
        let channels: u32 = msg_send![format, channelCount];
        let channels = channels.max(1) as usize;
        let interleaved: bool = msg_send![format, isInterleaved];
        let frames = frames as usize;
        if interleaved {
            let all = std::slice::from_raw_parts(*data, frames * channels);
            Some(
                all.chunks(channels)
                    .map(|f| f.iter().sum::<f32>() / channels as f32)
                    .collect(),
            )
        } else {
            let planes: Vec<&[f32]> = (0..channels)
                .map(|c| std::slice::from_raw_parts(*data.add(c), frames) as &[f32])
                .collect();
            Some(pcm::downmix(&planes))
        }
    }
}

impl Input for Mic {
    fn restart(&mut self) -> Result<(), InputError> {
        // The device changed under the engine, which stopped: start it on
        // the new default.
        self.stop_engine();
        self.start()
    }

    fn stop(&mut self) {
        self.stop_engine();
        if let Some(observer) = self.observer.take() {
            // SAFETY: the token this observer registered.
            unsafe {
                let center: *mut AnyObject = msg_send![class!(NSNotificationCenter), defaultCenter];
                let _: () = msg_send![center, removeObserver: &*observer];
            }
        }
    }
}

impl Drop for Mic {
    fn drop(&mut self) {
        self.stop();
    }
}

// ── This Mac's recognizer ──────────────────────────────────────────────

/// The locales this Mac's recognizer knows (`en-US`).
pub fn supported_locales() -> Vec<String> {
    // SAFETY: class methods returning an NSSet of NSLocale.
    unsafe {
        let set: Option<Retained<AnyObject>> =
            msg_send![class!(SFSpeechRecognizer), supportedLocales];
        let Some(set) = set else { return vec![] };
        let all: Option<Retained<AnyObject>> = msg_send![&*set, allObjects];
        let Some(all) = all else { return vec![] };
        let count: usize = msg_send![&*all, count];
        (0..count)
            .filter_map(|i| {
                let locale: Option<Retained<AnyObject>> = msg_send![&*all, objectAtIndex: i];
                let id: Option<Retained<NSString>> = msg_send![&*locale?, localeIdentifier];
                id.map(|s| s.to_string())
            })
            .collect()
    }
}

/// The user's locale, as macOS has it (`de-CH`).
pub fn current_locale() -> String {
    // SAFETY: Foundation class method.
    unsafe {
        let locale: Option<Retained<AnyObject>> = msg_send![class!(NSLocale), currentLocale];
        let id: Option<Retained<NSString>> = locale.and_then(|l| msg_send![&*l, localeIdentifier]);
        id.map(|s| s.to_string()).unwrap_or_else(|| "en-US".into())
    }
}

/// A recognizer for `language` (the transcription language; the Mac's own
/// when unset), on-device only.
///
/// # Safety
/// Called on the thread that will use the recognizer.
unsafe fn recognizer_for(language: Option<&str>) -> Result<Retained<AnyObject>, SessionError> {
    let supported = supported_locales();
    let current = current_locale();
    let locale_id = super::pick_locale(&supported, language, &current)
        .ok_or_else(|| SessionError::NotOnThisMac(language.unwrap_or(&current).to_string()))?;
    // SAFETY: the caller's.
    unsafe {
        let id = NSString::from_str(&locale_id);
        let locale: Option<Retained<AnyObject>> =
            msg_send![class!(NSLocale), localeWithLocaleIdentifier: &*id];
        let locale = locale.ok_or_else(|| SessionError::NotOnThisMac(locale_id.clone()))?;
        let alloc: Allocated<AnyObject> = msg_send![class!(SFSpeechRecognizer), alloc];
        let recognizer: Option<Retained<AnyObject>> = msg_send![alloc, initWithLocale: &*locale];
        let recognizer = recognizer.ok_or_else(|| SessionError::NotOnThisMac(locale_id.clone()))?;
        let on_device: bool = msg_send![&*recognizer, supportsOnDeviceRecognition];
        if !on_device {
            return Err(SessionError::NotOnThisMac(locale_id));
        }
        // Results on a queue of their own, not the main thread's.
        let queue: Option<Retained<AnyObject>> = msg_send![class!(NSOperationQueue), new];
        if let Some(queue) = queue {
            let _: () = msg_send![&*recognizer, setQueue: &*queue];
        }
        Ok(recognizer)
    }
}

/// Builds the result handler: words go to `tx`; "no speech" is
/// [`WorkerMsg::NoSpeech`], other errors fail.
fn result_handler(tx: Sender<WorkerMsg>) -> RcBlock<dyn Fn(*mut AnyObject, *mut AnyObject)> {
    RcBlock::new(move |result: *mut AnyObject, error: *mut AnyObject| {
        // SAFETY: Speech's result and error, valid during the call.
        unsafe {
            if !result.is_null() {
                let best: *mut AnyObject = msg_send![result, bestTranscription];
                let text: Option<Retained<NSString>> = if best.is_null() {
                    None
                } else {
                    msg_send![best, formattedString]
                };
                let is_final: bool = msg_send![result, isFinal];
                let _ = tx.send(WorkerMsg::Words {
                    text: text.map(|t| t.to_string()).unwrap_or_default(),
                    is_final,
                });
            } else if !error.is_null() {
                let code: isize = msg_send![error, code];
                // kAFAssistantErrorDomain 1110: no speech detected.
                let _ = tx.send(if code == 1110 {
                    WorkerMsg::NoSpeech
                } else {
                    WorkerMsg::RecognizerFailed(describe(error))
                });
            }
        }
    })
}

/// This Mac's recognizer for `language`.
pub fn speech_recognizer(language: Option<String>) -> RecognizerFactory {
    Box::new(move |tx: Sender<WorkerMsg>| {
        if speech() != Permission::Granted {
            return Err(SessionError::SpeechDenied);
        }
        // SAFETY: Speech and AVFAudio on the dictation thread, which keeps
        // every object below until the dictation ends.
        unsafe {
            let recognizer = recognizer_for(language.as_deref())?;
            let request: Option<Retained<AnyObject>> =
                msg_send![class!(SFSpeechAudioBufferRecognitionRequest), new];
            let request = request.ok_or_else(|| SessionError::Recognizer("no request".into()))?;
            let _: () = msg_send![&*request, setShouldReportPartialResults: true];
            let _: () = msg_send![&*request, setRequiresOnDeviceRecognition: true];
            let _: () = msg_send![&*request, setAddsPunctuation: true];
            // SFSpeechRecognitionTaskHintDictation.
            let _: () = msg_send![&*request, setTaskHint: 1isize];
            let alloc: Allocated<AnyObject> = msg_send![class!(AVAudioFormat), alloc];
            // AVAudioPCMFormatFloat32, mono, 16 kHz, planar.
            let format: Option<Retained<AnyObject>> = msg_send![
                alloc,
                initWithCommonFormat: 1usize,
                sampleRate: f64::from(pcm::RATE),
                channels: 1u32,
                interleaved: false
            ];
            let format = format.ok_or_else(|| SessionError::Recognizer("no format".into()))?;
            let handler = result_handler(tx);
            let task: Option<Retained<AnyObject>> = msg_send![
                &*recognizer,
                recognitionTaskWithRequest: &*request,
                resultHandler: &*handler
            ];
            let task = task.ok_or_else(|| SessionError::Recognizer("no task".into()))?;
            Ok(Box::new(SpeechRecognizer {
                _recognizer: recognizer,
                request,
                task,
                format,
            }) as Box<dyn Recognizer>)
        }
    })
}

struct SpeechRecognizer {
    _recognizer: Retained<AnyObject>,
    request: Retained<AnyObject>,
    task: Retained<AnyObject>,
    format: Retained<AnyObject>,
}

impl Recognizer for SpeechRecognizer {
    fn append(&mut self, samples: &[f32]) {
        if samples.is_empty() {
            return;
        }
        // SAFETY: a fresh buffer of the request's format, filled within its
        // capacity.
        unsafe {
            let alloc: Allocated<AnyObject> = msg_send![class!(AVAudioPCMBuffer), alloc];
            let frames = samples.len() as u32;
            let buffer: Option<Retained<AnyObject>> =
                msg_send![alloc, initWithPCMFormat: &*self.format, frameCapacity: frames];
            let Some(buffer) = buffer else { return };
            let _: () = msg_send![&*buffer, setFrameLength: frames];
            let data: *const *mut f32 = msg_send![&*buffer, floatChannelData];
            if data.is_null() || (*data).is_null() {
                return;
            }
            std::ptr::copy_nonoverlapping(samples.as_ptr(), *data, samples.len());
            let _: () = msg_send![&*self.request, appendAudioPCMBuffer: &*buffer];
        }
    }

    fn finish(&mut self) {
        // SAFETY: as above.
        unsafe {
            let _: () = msg_send![&*self.request, endAudio];
        }
    }

    fn cancel(&mut self) {
        // SAFETY: as above.
        unsafe {
            let _: () = msg_send![&*self.task, cancel];
        }
    }
}

/// A saved recording (a WAV file at `path`) as text, by this Mac's
/// recognizer. Blocks the calling thread (not the UI's) until it is done.
pub fn transcribe_file(
    path: &std::path::Path,
    language: Option<&str>,
) -> Result<String, SessionError> {
    if speech() != Permission::Granted {
        return Err(SessionError::SpeechDenied);
    }
    objc2::rc::autoreleasepool(|_| {
        let (tx, rx) = std::sync::mpsc::channel();
        // SAFETY: Speech on this thread; every object lives until the
        // answer arrives or the wait ends.
        let _keep = unsafe {
            let recognizer = recognizer_for(language)?;
            let path = NSString::from_str(&path.to_string_lossy());
            let url: Option<Retained<AnyObject>> =
                msg_send![class!(NSURL), fileURLWithPath: &*path];
            let url = url.ok_or_else(|| SessionError::Recognizer("bad path".into()))?;
            let alloc: Allocated<AnyObject> =
                msg_send![class!(SFSpeechURLRecognitionRequest), alloc];
            let request: Option<Retained<AnyObject>> = msg_send![alloc, initWithURL: &*url];
            let request = request.ok_or_else(|| SessionError::Recognizer("no request".into()))?;
            let _: () = msg_send![&*request, setShouldReportPartialResults: false];
            let _: () = msg_send![&*request, setRequiresOnDeviceRecognition: true];
            let _: () = msg_send![&*request, setAddsPunctuation: true];
            let handler = result_handler(tx);
            let task: Option<Retained<AnyObject>> = msg_send![
                &*recognizer,
                recognitionTaskWithRequest: &*request,
                resultHandler: &*handler
            ];
            (recognizer, request, task, handler)
        };
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(180);
        loop {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            match rx.recv_timeout(left) {
                Ok(WorkerMsg::Words {
                    text,
                    is_final: true,
                }) => return Ok(text),
                Ok(WorkerMsg::NoSpeech) => return Ok(String::new()),
                Ok(WorkerMsg::RecognizerFailed(e)) => return Err(SessionError::Recognizer(e)),
                Ok(_) => {}
                Err(_) => return Err(SessionError::Recognizer("timed out".into())),
            }
        }
    })
}

/// An NSError's description.
pub(crate) fn describe(error: *mut AnyObject) -> String {
    if error.is_null() {
        return "unknown error".into();
    }
    // SAFETY: an NSError.
    unsafe {
        let text: Option<Retained<NSString>> = msg_send![error, localizedDescription];
        text.map(|t| t.to_string()).unwrap_or_default()
    }
}
