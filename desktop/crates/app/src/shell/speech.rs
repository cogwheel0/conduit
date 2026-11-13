//! The Mac's own text-to-speech for Settings › Audio: the installed voices
//! (`AVSpeechSynthesisVoice`) for the voice pop-up, and a preview spoken by
//! `AVSpeechSynthesizer`, or the server's speech played with `NSSound`.
//! Read aloud and calls themselves are not here yet.

/// One installed voice.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceVoice {
    /// `com.apple.voice.compact.en-US.Samantha`.
    pub id: String,
    pub name: String,
    /// BCP-47, `en-US`.
    pub language: String,
}

/// AVSpeech's rate for one of core's speeds (1 = the voice's own pace,
/// AVSpeech's 0.5), held to AVSpeech's range.
pub fn rate_for(speed: f64) -> f32 {
    ((speed * 0.5) as f32).clamp(0.0, 1.0)
}

/// The voices for `language` (its first subtag: `en` lists every English
/// voice), by name; every voice when none matches.
pub fn voices_for(all: &[DeviceVoice], language: &str) -> Vec<DeviceVoice> {
    let lang = language
        .split(['-', '_'])
        .next()
        .unwrap_or("")
        .to_lowercase();
    let mut matching: Vec<DeviceVoice> = all
        .iter()
        .filter(|v| {
            v.language
                .split(['-', '_'])
                .next()
                .is_some_and(|l| l.eq_ignore_ascii_case(&lang))
        })
        .cloned()
        .collect();
    if matching.is_empty() {
        matching = all.to_vec();
    }
    matching.sort_by(|a, b| a.name.cmp(&b.name).then(a.language.cmp(&b.language)));
    matching.dedup_by(|a, b| a.id == b.id);
    matching
}

#[cfg(target_os = "macos")]
mod mac {
    use std::cell::RefCell;

    use objc2::msg_send;
    use objc2::rc::{Allocated, Retained};
    use objc2::runtime::{AnyClass, AnyObject};
    use objc2_foundation::NSString;

    use super::DeviceVoice;

    #[link(name = "AVFoundation", kind = "framework")]
    unsafe extern "C" {}

    thread_local! {
        /// The synthesizer speaking the preview, kept alive while it does.
        static SYNTH: RefCell<Option<Retained<AnyObject>>> = const { RefCell::new(None) };
        /// The server preview's sound, kept alive while it plays.
        static SOUND: RefCell<Option<Retained<AnyObject>>> = const { RefCell::new(None) };
    }

    fn string(obj: Option<Retained<NSString>>) -> String {
        obj.map(|s| s.to_string()).unwrap_or_default()
    }

    pub fn voices() -> Vec<DeviceVoice> {
        let Some(class) = AnyClass::get(c"AVSpeechSynthesisVoice") else {
            return vec![];
        };
        // SAFETY: AVFoundation class methods, on the main thread.
        unsafe {
            let array: Option<Retained<AnyObject>> = msg_send![class, speechVoices];
            let Some(array) = array else { return vec![] };
            let count: usize = msg_send![&*array, count];
            (0..count)
                .filter_map(|i| {
                    let voice: Option<Retained<AnyObject>> = msg_send![&*array, objectAtIndex: i];
                    let voice = voice?;
                    let id: Option<Retained<NSString>> = msg_send![&*voice, identifier];
                    let name: Option<Retained<NSString>> = msg_send![&*voice, name];
                    let language: Option<Retained<NSString>> = msg_send![&*voice, language];
                    Some(DeviceVoice {
                        id: string(id),
                        name: string(name),
                        language: string(language),
                    })
                })
                .filter(|v| !v.id.is_empty())
                .collect()
        }
    }

    pub fn speak(text: &str, voice: Option<&str>, rate: f32) {
        stop();
        let (Some(synth_class), Some(utterance_class)) = (
            AnyClass::get(c"AVSpeechSynthesizer"),
            AnyClass::get(c"AVSpeechUtterance"),
        ) else {
            return;
        };
        // SAFETY: AVFoundation on the main thread; the synthesizer is kept
        // in SYNTH until the next preview or stop.
        unsafe {
            let synth: Option<Retained<AnyObject>> = msg_send![synth_class, new];
            let Some(synth) = synth else { return };
            let text = NSString::from_str(text);
            let utterance: Option<Retained<AnyObject>> =
                msg_send![utterance_class, speechUtteranceWithString: &*text];
            let Some(utterance) = utterance else { return };
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
            let _: () = msg_send![&*utterance, setRate: rate];
            let _: () = msg_send![&*synth, speakUtterance: &*utterance];
            SYNTH.with(|s| *s.borrow_mut() = Some(synth));
        }
    }

    /// Plays `bytes` (the server's speech: mp3, wav, aac) with `NSSound`.
    pub fn play(bytes: &[u8]) -> bool {
        stop();
        let (Some(sound_class), Some(data_class)) =
            (AnyClass::get(c"NSSound"), AnyClass::get(c"NSData"))
        else {
            return false;
        };
        // SAFETY: AppKit on the main thread; the sound stays in SOUND while
        // it plays.
        unsafe {
            let data: Option<Retained<AnyObject>> = msg_send![
                data_class,
                dataWithBytes: bytes.as_ptr().cast::<std::ffi::c_void>(),
                length: bytes.len()
            ];
            let Some(data) = data else { return false };
            let alloc: Allocated<AnyObject> = msg_send![sound_class, alloc];
            let sound: Option<Retained<AnyObject>> = msg_send![alloc, initWithData: &*data];
            let Some(sound) = sound else { return false };
            let played: bool = msg_send![&*sound, play];
            SOUND.with(|s| *s.borrow_mut() = Some(sound));
            played
        }
    }

    pub fn stop() {
        SYNTH.with(|s| {
            if let Some(synth) = s.borrow_mut().take() {
                // SAFETY: as above. 0 = AVSpeechBoundaryImmediate.
                unsafe {
                    let _: bool = msg_send![&*synth, stopSpeakingAtBoundary: 0isize];
                }
            }
        });
        SOUND.with(|s| {
            if let Some(sound) = s.borrow_mut().take() {
                // SAFETY: as above.
                unsafe {
                    let _: bool = msg_send![&*sound, stop];
                }
            }
        });
    }
}

/// The installed voices (none off macOS).
pub fn voices() -> Vec<DeviceVoice> {
    #[cfg(target_os = "macos")]
    {
        mac::voices()
    }
    #[cfg(not(target_os = "macos"))]
    {
        vec![]
    }
}

/// Speaks `text` with `voice` (the system's default when None) at `speed`.
pub fn speak(text: &str, voice: Option<&str>, speed: f64) {
    #[cfg(target_os = "macos")]
    mac::speak(text, voice, rate_for(speed));
    #[cfg(not(target_os = "macos"))]
    let _ = (text, voice, speed);
}

/// Plays the server's speech; false when it can't.
pub fn play(bytes: &[u8]) -> bool {
    #[cfg(target_os = "macos")]
    {
        mac::play(bytes)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = bytes;
        false
    }
}

pub fn stop() {
    #[cfg(target_os = "macos")]
    mac::stop();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn voice(id: &str, name: &str, language: &str) -> DeviceVoice {
        DeviceVoice {
            id: id.into(),
            name: name.into(),
            language: language.into(),
        }
    }

    #[test]
    fn speeds_map_onto_avspeech_rates() {
        assert_eq!(rate_for(1.0), 0.5);
        assert_eq!(rate_for(0.75), 0.375);
        assert_eq!(rate_for(2.0), 1.0);
        assert_eq!(rate_for(3.0), 1.0);
    }

    #[test]
    fn voices_are_the_language_s_by_name_or_all() {
        let all = vec![
            voice("b", "Zoe", "en-GB"),
            voice("a", "Alex", "en-US"),
            voice("c", "Anna", "de-DE"),
        ];
        let english: Vec<_> = voices_for(&all, "en").into_iter().map(|v| v.name).collect();
        assert_eq!(english, vec!["Alex", "Zoe"]);
        let german: Vec<_> = voices_for(&all, "de_DE")
            .into_iter()
            .map(|v| v.id)
            .collect();
        assert_eq!(german, vec!["c"]);
        assert_eq!(voices_for(&all, "ko").len(), 3);
    }
}
