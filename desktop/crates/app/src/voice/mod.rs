//! Voice input: dictation's audio and engines, apart from any view, so the
//! composer, a note's editor and a call can each drive one
//! ([`crate::stores::dictation`] is the store they hold).
//!
//! * [`session`]: one dictation on its own thread -- the input made 16 kHz
//!   mono ([`pcm`]), metered, chunked for the recording, ended by the pause
//!   ([`vad`]) and, for this Mac's engine, recognized as it goes;
//! * [`realtime`] (and [`realtime_mac`]): a realtime call's audio, the
//!   microphone and the voice on one echo-cancelled engine;
//! * [`call_audio`] (and [`call_audio_mac`]): a Standard call's, the
//!   microphone its listens hear and the player its answers are said on;
//! * [`peer`]: a Hermes GPT-Live call's WebRTC peer, a hidden web view with
//!   WebKit's echo-cancelled microphone;
//! * [`mac`]: the microphone (`AVAudioEngine`), this Mac's recognizer
//!   (`SFSpeechRecognizer`, on-device) and their permissions.
//!
//! The server's engines (the chat's backend, or whisper in the daemon) take
//! the finished recording as WAV through `POST /transcribe`.

pub mod call_audio;
pub mod pcm;
pub mod peer;
pub mod realtime;
pub mod session;
pub mod vad;

#[cfg(target_os = "macos")]
pub mod call_audio_mac;
#[cfg(target_os = "macos")]
pub mod mac;
#[cfg(target_os = "macos")]
pub mod realtime_mac;

use std::path::PathBuf;

use conduit_daemon::paths::Flavor;

pub use session::{EndReason, InputError, Session, SessionConfig, SessionError, SessionEvent};

/// What stands in for the microphone in a dev build
/// (`CONDUIT_DICTATION_INPUT`): a WAV file's audio, or a denied
/// microphone. A release build has none.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InputOverride {
    File(PathBuf),
    Denied,
}

impl InputOverride {
    pub const VAR: &'static str = "CONDUIT_DICTATION_INPUT";

    /// The override set for this run, when the build is a dev one.
    pub fn current() -> Option<Self> {
        if Flavor::detect() != Flavor::Dev {
            return None;
        }
        Self::parse(std::env::var(Self::VAR).ok().as_deref())
    }

    fn parse(value: Option<&str>) -> Option<Self> {
        match value.map(str::trim) {
            None | Some("") => None,
            Some("denied") => Some(Self::Denied),
            Some(path) => Some(Self::File(PathBuf::from(path))),
        }
    }
}

/// The input a dictation listens to: the override's, else the
/// microphone.
pub fn input(over: Option<&InputOverride>) -> session::InputFactory {
    input_with(over, false)
}

/// [`input`], with the microphone's voice processing on for a call
/// (`voice_processing`), which keeps what the Mac plays out of what it
/// hears.
pub fn input_with(over: Option<&InputOverride>, voice_processing: bool) -> session::InputFactory {
    match over {
        // Long enough for the longest pause setting to end it.
        Some(InputOverride::File(path)) => {
            session::file_input(path.clone(), std::time::Duration::from_secs(8))
        }
        Some(InputOverride::Denied) => session::denied_input(),
        None => {
            // A Standard call's ears hear its own engine, where what the call
            // says plays, so voice processing takes the answer out.
            if voice_processing
                && let Some(audio) = call_audio::current().filter(|a| a.has_microphone())
            {
                return audio.microphone_input();
            }
            #[cfg(target_os = "macos")]
            {
                mac::microphone_input_with(voice_processing)
            }
            #[cfg(not(target_os = "macos"))]
            let _ = voice_processing;
            #[cfg(not(target_os = "macos"))]
            {
                Box::new(|_| Err(InputError::Unavailable("dictation needs macOS".into())))
            }
        }
    }
}

/// The recognizer locale for `wanted` (the transcription language, `de` or
/// `pt-BR`; the Mac's own `current` when None) among `supported`: the exact
/// one, else the same language in the Mac's region, else that language's
/// first. None when this Mac knows no such language.
pub fn pick_locale(supported: &[String], wanted: Option<&str>, current: &str) -> Option<String> {
    let norm = |s: &str| s.replace('_', "-").to_lowercase();
    let wanted = norm(wanted.filter(|w| !w.trim().is_empty()).unwrap_or(current));
    let current = norm(current);
    if let Some(exact) = supported.iter().find(|s| norm(s) == wanted) {
        return Some(exact.clone());
    }
    let language = wanted.split('-').next().unwrap_or("");
    let region = current.split('-').nth(1).unwrap_or("");
    let same_language: Vec<&String> = supported
        .iter()
        .filter(|s| norm(s).split('-').next() == Some(language))
        .collect();
    if let Some(local) = same_language
        .iter()
        .find(|s| !region.is_empty() && norm(s).split('-').nth(1) == Some(region))
    {
        return Some((*local).clone());
    }
    // The language's home region (de-DE), else the commonest (en-US,
    // zh-CN, pt-BR), else the first.
    let home = match language {
        "en" => "en-us".to_string(),
        "zh" => "zh-cn".to_string(),
        "pt" => "pt-br".to_string(),
        other => format!("{other}-{other}"),
    };
    if let Some(home) = same_language.iter().find(|s| norm(s) == home) {
        return Some((*home).clone());
    }
    let mut same_language = same_language;
    same_language.sort();
    same_language.first().map(|s| (*s).clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_override_is_a_file_or_a_denied_microphone() {
        assert_eq!(InputOverride::parse(None), None);
        assert_eq!(InputOverride::parse(Some(" ")), None);
        assert_eq!(
            InputOverride::parse(Some("denied")),
            Some(InputOverride::Denied)
        );
        assert_eq!(
            InputOverride::parse(Some("/tmp/a.wav")),
            Some(InputOverride::File("/tmp/a.wav".into()))
        );
    }

    #[test]
    fn the_language_picks_a_locale_this_mac_knows() {
        let supported: Vec<String> = ["en-US", "en-GB", "de-DE", "de-CH", "pt-BR", "pt-PT"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        // Exact.
        assert_eq!(
            pick_locale(&supported, Some("pt-BR"), "en_US").as_deref(),
            Some("pt-BR")
        );
        // The language in the Mac's region, else its home region.
        assert_eq!(
            pick_locale(&supported, Some("de"), "fr_CH").as_deref(),
            Some("de-CH")
        );
        assert_eq!(
            pick_locale(&supported, Some("de"), "en_US").as_deref(),
            Some("de-DE")
        );
        assert_eq!(
            pick_locale(&supported, Some("pt"), "ja_JP").as_deref(),
            Some("pt-BR")
        );
        // None set: the Mac's own.
        assert_eq!(
            pick_locale(&supported, None, "en_GB").as_deref(),
            Some("en-GB")
        );
        assert_eq!(pick_locale(&supported, Some("ko"), "en_US"), None);
    }
}
