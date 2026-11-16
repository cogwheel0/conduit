//! Read aloud in Now Playing: Control Center and the menu bar's Now Playing
//! show the reading (its opening words, its time while known) and its
//! play/pause, and the keyboard's media keys and AirPods controls drive it
//! (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`).
//!
//! The app claims none of this until a reading starts, and hands it back
//! (no info, state stopped) when the reading ends, so the media keys go to
//! Music or a browser the rest of the time.

use conduit_protocol::{SpeechProgress, SpeechStatus};
use gpui_kit::App;

use crate::stores::speech::RemoteCommand;

/// The reading, as Now Playing shows it.
#[derive(Clone, Debug, PartialEq)]
pub struct Playing {
    pub title: String,
    pub paused: bool,
    pub elapsed: f64,
    /// The whole reading's length, when known (server speech).
    pub duration: Option<f64>,
    /// Whether Next and Previous move by sentence.
    pub can_skip: bool,
}

/// What Now Playing shows for `progress` (None: nothing is read).
pub fn playing(progress: &SpeechProgress, sentences: &[String]) -> Option<Playing> {
    if progress.message_id.is_none() || progress.status == SpeechStatus::Idle {
        return None;
    }
    let first = sentences.first().map(String::as_str).unwrap_or("");
    Some(Playing {
        title: opening_words(first, 60),
        paused: matches!(progress.status, SpeechStatus::Paused | SpeechStatus::Error),
        // Whole seconds: Now Playing runs its own clock from the rate, so
        // it is told again when the second or the state changes, not on
        // every word.
        elapsed: (progress.elapsed_ms.max(0) / 1000) as f64,
        duration: (progress.duration_ms > 0).then(|| progress.duration_ms as f64 / 1000.0),
        can_skip: progress.can_seek_sentences,
    })
}

/// `text`'s opening words, up to `max` characters, with an ellipsis when
/// cut (never inside a word unless the first is longer).
pub fn opening_words(text: &str, max: usize) -> String {
    let text = text.trim();
    if text.chars().count() <= max {
        return text.to_string();
    }
    let cut: String = text.chars().take(max).collect();
    let cut = match cut.rfind(char::is_whitespace) {
        Some(i) if i > 0 => &cut[..i],
        _ => &cut[..],
    };
    format!("{}…", cut.trim_end_matches([',', ';', ':', '.', ' ']))
}

/// What becomes of the media keys when Now Playing shows `playing`
/// (true) or nothing, given whether the app holds them now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyChange {
    Claim,
    Release,
    Keep,
}

pub fn key_change(claimed: bool, playing: bool) -> KeyChange {
    match (claimed, playing) {
        (false, true) => KeyChange::Claim,
        (true, false) => KeyChange::Release,
        _ => KeyChange::Keep,
    }
}

/// Shows `progress` in Now Playing (or clears it).
pub fn update(progress: &SpeechProgress, sentences: &[String]) {
    #[cfg(target_os = "macos")]
    mac::show(playing(progress, sentences));
    #[cfg(not(target_os = "macos"))]
    let _ = (progress, sentences);
}

/// The title Now Playing shows now, if any (the E2E pass checks it).
pub fn current_title() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        mac::current_title()
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

/// Routes the media keys to `handler` once a reading claims them.
pub fn install(handler: impl Fn(RemoteCommand, &mut App) + 'static, cx: &mut App) {
    #[cfg(target_os = "macos")]
    mac::install(handler, cx);
    #[cfg(not(target_os = "macos"))]
    let _ = (handler, cx);
}

#[cfg(target_os = "macos")]
mod mac {
    use std::cell::RefCell;

    use block2::RcBlock;
    use futures::StreamExt as _;
    use futures::channel::mpsc::{self, UnboundedSender};
    use gpui_kit::{App, AsyncApp};
    use objc2::msg_send;
    use objc2::rc::Retained;
    use objc2::runtime::{AnyClass, AnyObject};
    use objc2_foundation::{NSNumber, NSString};

    use super::{KeyChange, Playing, key_change};
    use crate::stores::speech::RemoteCommand;

    #[link(name = "MediaPlayer", kind = "framework")]
    unsafe extern "C" {
        static MPMediaItemPropertyTitle: &'static NSString;
        static MPMediaItemPropertyArtist: &'static NSString;
        static MPMediaItemPropertyPlaybackDuration: &'static NSString;
        static MPNowPlayingInfoPropertyElapsedPlaybackTime: &'static NSString;
        static MPNowPlayingInfoPropertyPlaybackRate: &'static NSString;
    }

    thread_local! {
        static SENDER: RefCell<Option<UnboundedSender<RemoteCommand>>> = const { RefCell::new(None) };
        /// The handlers, once registered, kept alive with their commands.
        static TARGETS: RefCell<Vec<(Retained<AnyObject>, Retained<AnyObject>)>> = const { RefCell::new(Vec::new()) };
        static LAST: RefCell<Option<Playing>> = const { RefCell::new(None) };
    }

    pub fn install(handler: impl Fn(RemoteCommand, &mut App) + 'static, cx: &mut App) {
        let (tx, mut rx) = mpsc::unbounded();
        SENDER.with(|s| *s.borrow_mut() = Some(tx));
        cx.spawn(async move |cx: &mut AsyncApp| {
            while let Some(command) = rx.next().await {
                cx.update(|cx| handler(command, cx));
            }
        })
        .detach();
    }

    fn center() -> Option<Retained<AnyObject>> {
        let class = AnyClass::get(c"MPRemoteCommandCenter")?;
        // SAFETY: MediaPlayer class method, main thread.
        unsafe { msg_send![class, sharedCommandCenter] }
    }

    /// Registers the handlers when a reading starts.
    fn claim_keys() {
        let Some(center) = center() else { return };
        let commands: [(&std::ffi::CStr, RemoteCommand); 6] = [
            (c"togglePlayPauseCommand", RemoteCommand::TogglePause),
            (c"playCommand", RemoteCommand::Play),
            (c"pauseCommand", RemoteCommand::Pause),
            (c"stopCommand", RemoteCommand::Stop),
            (c"nextTrackCommand", RemoteCommand::Next),
            (c"previousTrackCommand", RemoteCommand::Previous),
        ];
        for (getter, command) in commands {
            let sel = objc2::runtime::Sel::register(getter);
            // SAFETY: each getter returns the center's MPRemoteCommand.
            let target: Option<Retained<AnyObject>> = unsafe {
                let raw: *mut AnyObject = msg_send![&*center, performSelector: sel];
                Retained::retain(raw)
            };
            let Some(target) = target else { continue };
            let block = RcBlock::new(move |_event: *mut AnyObject| -> isize {
                SENDER.with(|s| {
                    if let Some(tx) = s.borrow().as_ref() {
                        let _ = tx.unbounded_send(command);
                    }
                });
                0 // MPRemoteCommandHandlerStatusSuccess
            });
            // SAFETY: the block is copied by the command; the token it
            // answers is kept with it.
            let token: Option<Retained<AnyObject>> =
                unsafe { msg_send![&*target, addTargetWithHandler: &*block] };
            if let Some(token) = token {
                TARGETS.with(|t| t.borrow_mut().push((target, token)));
            }
        }
    }

    /// Removes the handlers once nothing is read, so the media keys go to
    /// Music or a browser again.
    fn release_keys() {
        for (target, token) in TARGETS.with(|t| std::mem::take(&mut *t.borrow_mut())) {
            // SAFETY: `token` is what `addTargetWithHandler:` returned for
            // this command.
            unsafe {
                let _: () = msg_send![&*target, removeTarget: &*token];
            }
        }
    }

    fn set_enabled(getter: &std::ffi::CStr, enabled: bool) {
        let Some(center) = center() else { return };
        let sel = objc2::runtime::Sel::register(getter);
        // SAFETY: as in `claim_keys`.
        unsafe {
            let raw: *mut AnyObject = msg_send![&*center, performSelector: sel];
            if !raw.is_null() {
                let _: () = msg_send![raw, setEnabled: enabled];
            }
        }
    }

    pub fn current_title() -> Option<String> {
        let class = AnyClass::get(c"MPNowPlayingInfoCenter")?;
        // SAFETY: MediaPlayer on the main thread.
        unsafe {
            let center: Option<Retained<AnyObject>> = msg_send![class, defaultCenter];
            let info: Option<Retained<AnyObject>> = msg_send![&*center?, nowPlayingInfo];
            let title: Option<Retained<NSString>> =
                msg_send![&*info?, objectForKey: MPMediaItemPropertyTitle];
            title.map(|t| t.to_string())
        }
    }

    pub fn show(playing: Option<Playing>) {
        if LAST.with(|l| *l.borrow() == playing) {
            return;
        }
        LAST.with(|l| *l.borrow_mut() = playing.clone());
        let claimed = TARGETS.with(|t| !t.borrow().is_empty());
        match key_change(claimed, playing.is_some()) {
            KeyChange::Claim => claim_keys(),
            KeyChange::Release => release_keys(),
            KeyChange::Keep => {}
        }
        let Some(class) = AnyClass::get(c"MPNowPlayingInfoCenter") else {
            return;
        };
        // SAFETY: MediaPlayer on the main thread.
        unsafe {
            let info_center: Option<Retained<AnyObject>> = msg_send![class, defaultCenter];
            let Some(info_center) = info_center else {
                return;
            };
            let Some(p) = playing else {
                let none: *const AnyObject = std::ptr::null();
                let _: () = msg_send![&*info_center, setNowPlayingInfo: none];
                // 3 = MPNowPlayingPlaybackStateStopped.
                let _: () = msg_send![&*info_center, setPlaybackState: 3usize];
                return;
            };
            set_enabled(c"nextTrackCommand", p.can_skip);
            set_enabled(c"previousTrackCommand", p.can_skip);
            let Some(dict_class) = AnyClass::get(c"NSMutableDictionary") else {
                return;
            };
            let dict: Retained<AnyObject> = msg_send![dict_class, dictionary];
            let put = |key: &NSString, value: &AnyObject| {
                let _: () = msg_send![&*dict, setObject: value, forKey: key];
            };
            put(MPMediaItemPropertyTitle, &NSString::from_str(&p.title));
            put(MPMediaItemPropertyArtist, &NSString::from_str("Conduit"));
            put(
                MPNowPlayingInfoPropertyElapsedPlaybackTime,
                &NSNumber::new_f64(p.elapsed),
            );
            put(
                MPNowPlayingInfoPropertyPlaybackRate,
                &NSNumber::new_f64(if p.paused { 0.0 } else { 1.0 }),
            );
            if let Some(d) = p.duration {
                put(MPMediaItemPropertyPlaybackDuration, &NSNumber::new_f64(d));
            }
            let _: () = msg_send![&*info_center, setNowPlayingInfo: &*dict];
            // 1 = playing, 2 = paused.
            let state: usize = if p.paused { 2 } else { 1 };
            let _: () = msg_send![&*info_center, setPlaybackState: state];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn titles_are_the_opening_words() {
        assert_eq!(opening_words("Short one.", 60), "Short one.");
        assert_eq!(
            opening_words(
                "The harbour lights come on one by one as the evening settles in.",
                30
            ),
            "The harbour lights come on…"
        );
    }

    /// The keys are the app's only while a reading is shown: once it ends
    /// they go back to Music or a browser.
    #[test]
    fn the_media_keys_are_held_only_while_reading() {
        assert_eq!(key_change(false, true), KeyChange::Claim);
        assert_eq!(key_change(true, true), KeyChange::Keep);
        assert_eq!(key_change(true, false), KeyChange::Release);
        assert_eq!(key_change(false, false), KeyChange::Keep);
    }

    #[test]
    fn nothing_shows_while_idle() {
        let idle = SpeechProgress::default();
        assert_eq!(playing(&idle, &[]), None);
        let paused = SpeechProgress {
            status: SpeechStatus::Paused,
            message_id: Some("m".into()),
            elapsed_ms: 1500,
            can_seek_sentences: true,
            ..Default::default()
        };
        let p = playing(&paused, &["A first sentence.".into()]).unwrap();
        assert!(p.paused);
        assert_eq!(p.elapsed, 1.0);
        assert_eq!(p.duration, None);
        assert!(p.can_skip);
    }
}
