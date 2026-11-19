//! The Mac's installed voices (`AVSpeechSynthesisVoice`), for Settings ›
//! Audio's voice pop-up and read aloud's engine
//! ([`super::speech_engine`]), which says and plays everything, Settings'
//! preview included.

/// One installed voice.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceVoice {
    /// `com.apple.voice.compact.en-US.Samantha`.
    pub id: String,
    pub name: String,
    /// BCP-47, `en-US`.
    pub language: String,
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
    use objc2::msg_send;
    use objc2::rc::Retained;
    use objc2::runtime::{AnyClass, AnyObject};
    use objc2_foundation::NSString;

    use super::DeviceVoice;

    #[link(name = "AVFoundation", kind = "framework")]
    unsafe extern "C" {}

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
