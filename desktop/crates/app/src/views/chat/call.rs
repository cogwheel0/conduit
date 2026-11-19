//! A voice call, drawn: a strip docked where the composer is, in the chat
//! the call talks in, and a capsule when it is minimised or another chat is
//! open.
//!
//! Docked rather than floating: what is said lands in the chat as ordinary
//! messages, so the call reads best with its chat above it, as the phone's
//! call island sits over its composer; a separate panel would cover the
//! transcript it adds to, and could be lost behind other windows. The
//! menu-bar item shows the call whatever the window does
//! ([`crate::shell::tray`]).
//!
//! * **The strip:** the state (Connecting…, Listening with the meter,
//!   Thinking…, Speaking, Paused, Muted) and the time; what the user said
//!   or the answer being said; Pause or Resume, Mute or Unmute, Stop
//!   Speaking while it speaks, Minimize, and End Call.
//! * **The capsule:** the state and the time, Expand (Show Call when the
//!   call is in another chat), and End Call.
//! * **A failed call:** why, with what to do about it, and Dismiss.
//!
//! The store is [`crate::stores::call`].

use std::rc::Rc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use conduit_components::ActiveConduitTheme as _;
use conduit_components::announce::{Priority, live_text};
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{ConduitTheme, with_alpha};
use conduit_components::views::kit::{Button, IconButton};
use conduit_protocol::{
    CallErrorKind, CallListenFailure, CallMode, CallPhase, CallRefusal, CallStandardReason,
};
use gpui_kit::prelude::*;
use gpui_kit::{
    Animation, AnimationExt as _, AnyElement, App, Entity, Role, SharedString, div, px,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::call::CallStore;
use crate::stores::dictation::clock;

/// How long the call has run.
pub fn elapsed(started_at_ms: Option<i64>) -> Duration {
    let Some(started) = started_at_ms.and_then(|ms| u64::try_from(ms).ok()) else {
        return Duration::ZERO;
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(started);
    Duration::from_millis(now.saturating_sub(started))
}

/// The state, in words.
pub fn status_text(phase: CallPhase, l10n: &L10n) -> String {
    match phase {
        CallPhase::Idle | CallPhase::Starting => l10n.desktop_connecting(),
        CallPhase::Listening => l10n.voice_call_listening(),
        CallPhase::Sending => l10n.desktop_call_thinking(),
        CallPhase::Speaking => l10n.voice_call_speaking(),
        CallPhase::Paused => l10n.voice_call_paused(),
        CallPhase::Muted => l10n.voice_call_muted(),
        CallPhase::Ending | CallPhase::Ended => l10n.voice_call_disconnected(),
        CallPhase::Error | CallPhase::Unknown => l10n.voice_call_failed(),
    }
}

/// Why core would not start a call, in this language (None for a reason
/// this build doesn't know, which keeps core's English).
pub fn refusal_text(refusal: CallRefusal, l10n: &L10n) -> Option<String> {
    Some(match refusal {
        CallRefusal::ModelRequired => l10n.desktop_call_refusal_model_required(),
        CallRefusal::HermesLoading => l10n.desktop_call_refusal_hermes_loading(),
        CallRefusal::HermesUnavailable => l10n.desktop_call_refusal_hermes_unavailable(),
        CallRefusal::DirectUnavailable => l10n.desktop_call_refusal_direct_unavailable(),
        CallRefusal::SignInRequired => l10n.desktop_call_refusal_sign_in(),
        CallRefusal::BackendUnsupported => l10n.voice_call_libre_chat_unavailable(),
        CallRefusal::Unknown => return None,
    })
}

/// "Listening · 0:42".
pub fn status_line(store: &CallStore, l10n: &L10n) -> String {
    let state = store.state();
    l10n.desktop_call_status_time(
        &status_text(state.phase, l10n),
        &clock(elapsed(state.started_at_ms)),
    )
}

/// Why the call failed, in the user's words: a listen the microphone or the
/// engine could not carry on says what to do, as dictation does.
pub fn error_text(store: &CallStore, l10n: &L10n) -> String {
    if let Some(failure) = store.failure {
        return match failure {
            CallListenFailure::MicrophoneDenied => l10n.desktop_microphone_unavailable(),
            CallListenFailure::SpeechDenied => l10n.desktop_speech_recognition_off(),
            CallListenFailure::NotOnThisMac => l10n.desktop_speech_not_on_this_mac(""),
            CallListenFailure::ServerUnavailable => l10n.desktop_server_does_not_transcribe(),
            CallListenFailure::WhisperNeedsModel => l10n.desktop_whisper_needs_model(),
            CallListenFailure::TranscriptionFailed | CallListenFailure::Unknown => {
                l10n.desktop_transcription_failed()
            }
        };
    }
    let state = store.state();
    match state.error_kind {
        Some(CallErrorKind::MicrophoneDenied) => l10n.desktop_microphone_unavailable(),
        Some(CallErrorKind::InputUnavailable) => l10n.voice_input_unavailable(),
        Some(CallErrorKind::Timeout) => l10n.voice_call_start_timeout(),
        Some(CallErrorKind::NoSpeech) => l10n.voice_call_no_speech(),
        // Core's refusals in this language; other messages (the server's
        // reply error) as they came.
        Some(CallErrorKind::Message) => state
            .refusal
            .and_then(|r| refusal_text(r, l10n))
            .or_else(|| state.error.clone().filter(|e| !e.trim().is_empty()))
            .unwrap_or_else(|| l10n.voice_call_failed()),
        _ => l10n.voice_call_failed(),
    }
}

/// Whether a realtime call was asked for and this chat cannot have one.
fn takes_turns(reason: Option<CallStandardReason>) -> bool {
    matches!(
        reason,
        Some(
            CallStandardReason::TemporaryChat
                | CallStandardReason::UnsupportedBackend
                | CallStandardReason::VoiceProviderIncomplete
                | CallStandardReason::ServerRealtimeOff
                | CallStandardReason::CallNotPermitted
                | CallStandardReason::NoSessionToken
                | CallStandardReason::HermesVoiceLiveOff
                | CallStandardReason::NoAudio
        )
    )
}

/// The meter: five bars, the middle ones the tallest.
fn meter(level: f32, t: &ConduitTheme) -> AnyElement {
    let r = t.roles;
    let weights = [0.55, 0.8, 1.0, 0.8, 0.55];
    div()
        .h(px(18.))
        .flex()
        .items_center()
        .gap(px(2.))
        .children(weights.iter().map(|w| {
            let h = 3. + 15. * (level * w).clamp(0., 1.);
            div().w(px(3.)).h(px(h)).rounded_full().bg(if level > 0.05 {
                r.text
            } else {
                r.text_faint
            })
        }))
        .into_any_element()
}

/// The state's mark, in a round tile: the meter while it listens (or the
/// voice speaks, in a realtime call), a spinner while it connects or
/// thinks, the speaker while it speaks, and the pause or the muted mic.
fn mark(store: &CallStore, size: f32, cx: &App) -> AnyElement {
    let t = cx.conduit().clone();
    let r = t.roles;
    let state = store.state();
    let level = state.level as f32;
    let inner: AnyElement = match state.phase {
        CallPhase::Idle | CallPhase::Starting | CallPhase::Sending => {
            if cx.reduce_motion() {
                icon(IconName::Ellipsis, size * 0.5, r.text_subtle).into_any_element()
            } else {
                super::blocks::spinner("call-busy", size * 0.5, r.text_subtle)
            }
        }
        CallPhase::Listening => meter(level, &t),
        CallPhase::Speaking if state.mode == Some(CallMode::Realtime) => meter(level, &t),
        CallPhase::Speaking => {
            let speaking = icon(IconName::AudioLines, size * 0.5, r.text).into_any_element();
            if cx.reduce_motion() {
                speaking
            } else {
                div()
                    .child(speaking)
                    .with_animation(
                        "call-speaking",
                        Animation::new(Duration::from_millis(1_400)).repeat(),
                        |d, delta| {
                            let p = (delta * std::f32::consts::TAU).cos() * 0.5 + 0.5;
                            d.opacity(0.5 + 0.5 * p)
                        },
                    )
                    .into_any_element()
            }
        }
        CallPhase::Paused => icon(IconName::Pause, size * 0.5, r.text_subtle).into_any_element(),
        CallPhase::Muted => icon(IconName::MicOff, size * 0.5, r.text_subtle).into_any_element(),
        _ => icon(IconName::CircleAlert, size * 0.5, r.danger).into_any_element(),
    };
    div()
        .size(px(size))
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .rounded_full()
        .bg(with_alpha(r.text, if t.dark { 0.14 } else { 0.07 }))
        .child(inner)
        .into_any_element()
}

/// What the strip shows as the words: the answer while it is said, else
/// what the user said; the end of a long one.
fn caption(store: &CallStore) -> Option<(String, bool)> {
    let state = store.state();
    let (text, reply) = match state.phase {
        CallPhase::Speaking if !state.reply.trim().is_empty() => (state.reply.as_str(), true),
        _ if !state.transcript.trim().is_empty() => (state.transcript.as_str(), false),
        _ => return None,
    };
    let text = text.trim();
    let chars: Vec<char> = text.chars().collect();
    let shown = if chars.len() > 220 {
        format!("…{}", chars[chars.len() - 220..].iter().collect::<String>())
    } else {
        text.to_string()
    };
    Some((shown, reply))
}

/// End Call: the strip's red button, labelled.
fn end_button(id: &'static str, call: &Entity<CallStore>, cx: &App) -> AnyElement {
    let l10n = cx.l10n().clone();
    let r = cx.conduit().roles;
    let weak = call.downgrade();
    IconButton::new(id, IconName::PhoneOff, l10n.voice_call_end())
        .size(30., 15.)
        .round()
        .filled(r.danger_fill, r.danger_foreground)
        .shortcut(conduit_components::views::focus::hints(cx).voice_call)
        .on_click(Rc::new(move |_, _, cx| {
            let _ = weak.update(cx, |c, cx| c.end(cx));
        }))
        .into_any_element()
}

/// The call strip, where the composer is, in the call's chat.
pub fn strip(call: &Entity<CallStore>, cx: &App) -> AnyElement {
    let store = call.read(cx);
    if store.state().phase == CallPhase::Error {
        return failed(call, cx);
    }
    let l10n = cx.l10n().clone();
    let t = cx.conduit().clone();
    let r = t.roles;
    let m = t.metrics;
    let frame = conduit_components::views::composer::composer_frame(&t);
    let state = store.state().clone();
    let status = status_line(store, &l10n);

    let mut controls: Vec<AnyElement> = vec![];
    if state.phase == CallPhase::Speaking {
        let weak = call.downgrade();
        controls.push(
            IconButton::new(
                "call-skip",
                IconName::SkipForward,
                l10n.desktop_stop_speaking(),
            )
            .size(30., 15.)
            .round()
            .on_click(Rc::new(move |_, _, cx| {
                let _ = weak.update(cx, |c, cx| c.skip(cx));
            }))
            .into_any_element(),
        );
    }
    {
        let paused = state.phase == CallPhase::Paused;
        let weak = call.downgrade();
        controls.push(
            IconButton::new(
                "call-pause",
                if paused {
                    IconName::Play
                } else {
                    IconName::Pause
                },
                if paused {
                    l10n.voice_call_resume()
                } else {
                    l10n.voice_call_pause()
                },
            )
            .size(30., 15.)
            .round()
            .disabled(!(state.can_pause || (paused && state.can_resume)))
            .on_click(Rc::new(move |_, _, cx| {
                let _ = weak.update(cx, |c, cx| c.toggle_pause(cx));
            }))
            .into_any_element(),
        );
    }
    {
        let weak = call.downgrade();
        controls.push(
            IconButton::new(
                "call-mute",
                if state.muted {
                    IconName::MicOff
                } else {
                    IconName::Mic
                },
                if state.muted {
                    l10n.unmute()
                } else {
                    l10n.mute()
                },
            )
            .size(30., 15.)
            .round()
            .active(state.muted)
            .disabled(state.phase == CallPhase::Starting)
            .on_click(Rc::new(move |_, _, cx| {
                let _ = weak.update(cx, |c, cx| c.toggle_mute(cx));
            }))
            .into_any_element(),
        );
    }
    {
        let weak = call.downgrade();
        controls.push(
            IconButton::new(
                "call-minimize",
                IconName::Minimize2,
                l10n.voice_call_minimize(),
            )
            .size(30., 15.)
            .round()
            .on_click(Rc::new(move |_, _, cx| {
                let _ = weak.update(cx, |c, cx| c.toggle_collapsed(cx));
            }))
            .into_any_element(),
        );
    }
    controls.push(end_button("call-end", call, cx));

    let words = caption(store).map(|(text, reply)| {
        div()
            .id("call-words")
            .role(Role::Status)
            .aria_label(SharedString::from(text.clone()))
            .text_size(px(m.body))
            .line_height(px(m.body * 1.4))
            .text_color(if reply { r.text } else { r.text_subtle })
            .line_clamp(2)
            .child(SharedString::from(text))
    });
    let note = takes_turns(state.standard_reason).then(|| {
        div()
            .text_size(px(m.small))
            .text_color(r.text_subtle)
            .child(SharedString::from(l10n.desktop_call_realtime_unavailable()))
    });
    let mode = (state.mode == Some(CallMode::Realtime)).then(|| {
        div()
            .px(px(7.))
            .py(px(1.))
            .rounded_full()
            .border_1()
            .border_color(r.border)
            .text_size(px(m.small))
            .text_color(r.text_subtle)
            .child(SharedString::from(l10n.voice_call_mode_realtime()))
    });

    div()
        .id("call-strip")
        .role(Role::Group)
        .aria_label(SharedString::from(l10n.voice_call_title()))
        .w_full()
        .flex()
        .flex_col()
        .gap(px(8.))
        .px(px(12.))
        .py(px(10.))
        .rounded(px(frame.radius))
        .border_1()
        .border_color(frame.border)
        .bg(frame.fill)
        .shadow(frame.shadow)
        .child(
            div()
                .flex()
                .items_center()
                .gap(px(10.))
                .child(mark(store, 32., cx))
                .child(
                    div()
                        .id("call-status")
                        .role(Role::Status)
                        .aria_label(SharedString::from(status.clone()))
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .child(
                            div()
                                .text_size(px(m.body))
                                .font_weight(gpui_kit::FontWeight::MEDIUM)
                                .text_color(r.text)
                                .truncate()
                                .child(SharedString::from(status)),
                        )
                        .children(mode),
                )
                .child(div().flex().items_center().gap(px(4.)).children(controls)),
        )
        .children(words.map(|w| div().pl(px(42.)).child(w)))
        .children(note.map(|n| div().pl(px(42.)).child(n)))
        .into_any_element()
}

/// A call that failed: why, with what to do, and Dismiss.
fn failed(call: &Entity<CallStore>, cx: &App) -> AnyElement {
    let l10n = cx.l10n().clone();
    let t = cx.conduit().clone();
    let r = t.roles;
    let m = t.metrics;
    let frame = conduit_components::views::composer::composer_frame(&t);
    let store = call.read(cx);
    let text = error_text(store, &l10n);
    let mut actions: Vec<AnyElement> = vec![];
    let microphone = store.failure == Some(CallListenFailure::MicrophoneDenied)
        || store.state().error_kind == Some(CallErrorKind::MicrophoneDenied);
    if microphone {
        actions.push(
            Button::new("call-system-settings", l10n.desktop_open_system_settings())
                .on_click(Rc::new(|_, _, cx| {
                    cx.open_url(
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                    )
                }))
                .into_any_element(),
        );
    } else if store.failure.is_some() {
        actions.push(
            Button::new("call-audio-settings", l10n.desktop_audio_settings_button())
                .on_click(Rc::new(|_, _, cx| {
                    crate::open_settings(Some(crate::views::settings::Tab::Audio), cx)
                }))
                .into_any_element(),
        );
    }
    {
        let weak = call.downgrade();
        actions.push(
            Button::new("call-dismiss", l10n.desktop_release_dismiss())
                .on_click(Rc::new(move |_, _, cx| {
                    let _ = weak.update(cx, |c, cx| c.end(cx));
                }))
                .into_any_element(),
        );
    }
    div()
        .id("call-failed")
        .role(Role::Alert)
        .aria_label(SharedString::from(text.clone()))
        .child(live_text(
            "live",
            Some(SharedString::from(text.clone())),
            Priority::High,
        ))
        .w_full()
        .flex()
        .items_center()
        .gap(px(10.))
        .px(px(12.))
        .py(px(10.))
        .rounded(px(frame.radius))
        .border_1()
        .border_color(frame.border)
        .bg(frame.fill)
        .child(icon(IconName::CircleAlert, 16., r.danger))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .text_size(px(m.body))
                .text_color(r.text)
                .child(SharedString::from(text)),
        )
        .child(div().flex().items_center().gap(px(6.)).children(actions))
        .into_any_element()
}

/// The capsule above the composer: the call minimised, or on in another
/// chat (`elsewhere`).
pub fn capsule(call: &Entity<CallStore>, elsewhere: bool, cx: &App) -> AnyElement {
    let l10n = cx.l10n().clone();
    let t = cx.conduit().clone();
    let r = t.roles;
    let m = t.metrics;
    let store = call.read(cx);
    let line = if elsewhere {
        l10n.desktop_call_status_time(
            &l10n.desktop_call_elsewhere(),
            &clock(elapsed(store.state().started_at_ms)),
        )
    } else {
        status_line(store, &l10n)
    };
    let show: AnyElement = if elsewhere {
        Button::new("call-show", l10n.desktop_show_call())
            .on_click(Rc::new(|_, window, cx| {
                window.dispatch_action(Box::new(crate::actions::ShowCall), cx);
            }))
            .into_any_element()
    } else {
        let weak = call.downgrade();
        IconButton::new("call-expand", IconName::Maximize2, l10n.voice_call_expand())
            .size(26., 13.)
            .round()
            .on_click(Rc::new(move |_, _, cx| {
                let _ = weak.update(cx, |c, cx| c.toggle_collapsed(cx));
            }))
            .into_any_element()
    };
    div()
        .id("call-capsule")
        .role(Role::Group)
        .aria_label(SharedString::from(l10n.voice_call_title()))
        .flex()
        .items_center()
        .gap(px(8.))
        .pl(px(4.))
        .pr(px(4.))
        .py(px(3.))
        .rounded_full()
        .border_1()
        .border_color(r.border)
        .bg(conduit_components::views::kit::raised_fill(&t))
        .child(mark(store, 24., cx))
        .child(
            div()
                .id("call-capsule-status")
                .role(Role::Status)
                .aria_label(SharedString::from(line.clone()))
                .text_size(px(m.small))
                .text_color(r.text)
                .child(SharedString::from(line)),
        )
        .child(show)
        .child(end_button("call-capsule-end", call, cx))
        .into_any_element()
}

/// The composer's call button, where Send is while there is nothing to
/// send, as on the phone.
/// What a button does when pressed.
pub type Press = Rc<dyn Fn(&mut gpui_kit::Window, &mut App)>;

pub fn call_button(enabled: bool, on_click: Press, cx: &App) -> AnyElement {
    let l10n = cx.l10n().clone();
    let t = cx.conduit().clone();
    let r = t.roles;
    IconButton::new(
        "start-call",
        IconName::AudioWaveform,
        l10n.desktop_start_voice_call(),
    )
    .size(32., 17.)
    .shortcut(conduit_components::views::focus::hints(cx).voice_call)
    .disabled(!enabled)
    .filled(
        if enabled {
            r.primary
        } else {
            with_alpha(r.text, if t.dark { 0.16 } else { 0.10 })
        },
        if enabled {
            r.primary_foreground
        } else {
            r.text_faint
        },
    )
    .on_click(Rc::new(move |_, window, cx| on_click(window, cx)))
    .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_call_counts_from_its_start() {
        assert_eq!(elapsed(None), Duration::ZERO);
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64;
        let ran = elapsed(Some(now - 42_000));
        assert!(ran >= Duration::from_secs(42) && ran < Duration::from_secs(44));
    }

    #[test]
    fn only_a_realtime_call_that_could_not_be_says_it_takes_turns() {
        assert!(!takes_turns(None));
        assert!(!takes_turns(Some(CallStandardReason::StandardChosen)));
        assert!(takes_turns(Some(CallStandardReason::ServerRealtimeOff)));
        assert!(takes_turns(Some(CallStandardReason::NoAudio)));
    }
}
