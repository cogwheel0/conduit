//! Dictation in the composer, drawn: the mic beside Send; while listening,
//! a pulsing mic where + was, the time so far, a level meter, Cancel (Esc)
//! and Stop (⇧⌘L); "Transcribing…" while the server or whisper works; the
//! draft's saved recordings above the field, each with its menu
//! (Transcribe on Server, Transcribe on This Mac, Export…, Discard
//! Recording…); and what went wrong, with what to do about it.
//!
//! The store is [`crate::stores::dictation`]; the composer owns the text.

use std::rc::Rc;
use std::time::Duration;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{ConduitTheme, with_alpha};
use conduit_components::views::kit::{Button, IconButton, icon_tile};
use gpui_kit::prelude::*;
use gpui_kit::{
    Animation, AnimationExt as _, AnyElement, App, Context, ElementId, Entity, FontWeight, Role,
    SharedString, div, px,
};

use super::composer::ChatComposer;
use crate::keymap::{KeyStroke, describe};
use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::dictation::{DictationStore, Notice, Phase, clock, recording_length};

/// What a saved recording's menu does.
#[derive(Clone, Debug, PartialEq, gpui_kit::Action)]
#[action(namespace = conduit_composer, no_json)]
pub enum RecordingMenu {
    TranscribeOnServer(String),
    TranscribeOnThisMac(String),
    Export(String),
    Discard(String),
}

fn esc() -> SharedString {
    describe(&KeyStroke::new("escape"), cfg!(target_os = "macos")).into()
}

/// The mic beside Send, while nothing is being dictated.
/// `enabled`: off while the chat's draft is read (nothing is written then).
pub fn mic_button(composer: &Entity<ChatComposer>, enabled: bool, cx: &App) -> AnyElement {
    let l10n = cx.l10n().clone();
    let r = cx.conduit().roles;
    let weak = composer.downgrade();
    IconButton::new("dictate", IconName::Mic, l10n.start_dictation())
        .size(30., 16.)
        .color(r.text_subtle)
        .disabled(!enabled)
        .shortcut(conduit_components::views::focus::hints(cx).dictate)
        .on_click(Rc::new(move |_, window, cx| {
            let _ = weak.update(cx, |c, cx| c.toggle_dictation(window, cx));
        }))
        .into_any_element()
}

/// Where + was, while listening: a mic that breathes (still under Reduce
/// Motion), the state for VoiceOver.
pub fn listening_mark(store: &DictationStore, cx: &App) -> AnyElement {
    let l10n = cx.l10n().clone();
    let t = cx.conduit().clone();
    let r = t.roles;
    let label = match store.phase {
        Phase::Transcribing => l10n.desktop_transcribing(),
        _ => l10n.desktop_listening_for(&clock(store.elapsed())),
    };
    let mark = div()
        .size(px(30.))
        .flex()
        .items_center()
        .justify_center()
        .rounded_full()
        .bg(with_alpha(r.text, if t.dark { 0.14 } else { 0.08 }))
        .child(icon(IconName::Mic, 16., r.text));
    let base = div()
        .id("dictation-state")
        .role(Role::Status)
        .aria_label(SharedString::from(label));
    if cx.reduce_motion() || store.phase == Phase::Transcribing {
        return base.child(mark).into_any_element();
    }
    base.child(mark.with_animation(
        "dictation-breath",
        Animation::new(Duration::from_millis(1_600)).repeat(),
        |d, delta| {
            // Down and back up: 1 → 0.45 → 1.
            let p = (delta * std::f32::consts::TAU).cos() * 0.5 + 0.5;
            d.opacity(0.45 + 0.55 * p)
        },
    ))
    .into_any_element()
}

/// The level meter: five bars, the middle ones the tallest.
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

/// Beside the field while dictating: the time, the meter, Cancel and Stop
/// (or "Transcribing…" and Cancel).
pub fn listening_controls(
    composer: &Entity<ChatComposer>,
    store: &DictationStore,
    cx: &App,
) -> AnyElement {
    let l10n = cx.l10n().clone();
    let t = cx.conduit().clone();
    let r = t.roles;
    let m = t.metrics;
    let cancel = {
        let weak = composer.downgrade();
        IconButton::new(
            "cancel-dictation",
            IconName::X,
            l10n.desktop_cancel_dictation(),
        )
        .size(28., 14.)
        .color(r.text_subtle)
        .shortcut(Some(esc()))
        .on_click(Rc::new(move |_, window, cx| {
            let _ = weak.update(cx, |c, cx| c.cancel_dictation(window, cx));
        }))
    };
    if store.phase == Phase::Transcribing {
        return div()
            .flex()
            .items_center()
            .gap(px(6.))
            .child(super::blocks::spinner("transcribing", 14., r.text_subtle))
            .child(
                div()
                    .text_size(px(m.small))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(l10n.desktop_transcribing())),
            )
            .child(cancel)
            .into_any_element();
    }
    let stop = {
        let weak = composer.downgrade();
        IconButton::new(
            "stop-dictation",
            IconName::Square,
            l10n.desktop_stop_dictation(),
        )
        .size(32., 13.)
        .filled(r.primary, r.primary_foreground)
        .shortcut(conduit_components::views::focus::hints(cx).dictate)
        .on_click(Rc::new(move |_, window, cx| {
            let _ = weak.update(cx, |c, cx| c.stop_dictation(window, cx));
        }))
    };
    div()
        .flex()
        .items_center()
        .gap(px(6.))
        .child(
            div()
                .min_w(px(34.))
                .text_size(px(m.small))
                .text_color(r.text_subtle)
                // Digits that do not jitter as they count.
                .font_family(conduit_components::theme::MONO_FONT)
                .child(SharedString::from(clock(store.elapsed()))),
        )
        .child(meter(store.level, &t))
        .child(cancel)
        .child(stop)
        .into_any_element()
}

/// The draft's saved recordings, above the composer, as the phone lists
/// them: "Saved Recording · 0:07" with its menu.
pub fn recordings_list(
    composer: &Entity<ChatComposer>,
    store: &DictationStore,
    cx: &App,
) -> Option<AnyElement> {
    if store.recordings.is_empty() {
        return None;
    }
    let l10n = cx.l10n().clone();
    let t = cx.conduit().clone();
    let r = t.roles;
    let m = t.metrics;
    let active = store.active_recording().map(str::to_string);
    let listening = store.is_active();
    let rows = store.recordings.iter().map(|rec| {
        let is_active = active.as_deref() == Some(rec.id.as_str());
        let busy = store.busy.as_deref() == Some(rec.id.as_str());
        let state = if is_active {
            l10n.desktop_recording_now()
        } else if busy {
            l10n.desktop_transcribing()
        } else {
            l10n.saved_recording()
        };
        // The one being made counts as it goes; the database has its last
        // committed second.
        let length = if is_active {
            store.elapsed()
        } else {
            recording_length(rec)
        };
        let label = format!("{state} \u{00b7} {}", clock(length));
        let trailing: Option<AnyElement> = if is_active {
            None
        } else if busy {
            Some(super::blocks::spinner(
                ElementId::Name(format!("recording-busy-{}", rec.id).into()),
                14.,
                r.text_subtle,
            ))
        } else {
            let weak = composer.downgrade();
            let id = rec.id.clone();
            Some(
                IconButton::new(
                    ElementId::Name(format!("recording-menu-{}", rec.id).into()),
                    IconName::Ellipsis,
                    l10n.desktop_recording_actions(),
                )
                .size(26., 14.)
                .color(r.text_subtle)
                .disabled(listening || store.busy.is_some())
                .on_click(Rc::new(move |e, window, cx| {
                    let position = e.position();
                    let _ =
                        weak.update(cx, |c, cx| c.show_recording_menu(&id, position, window, cx));
                }))
                .into_any_element(),
            )
        };
        div()
            .id(ElementId::Name(format!("recording-{}", rec.id).into()))
            .role(Role::Group)
            .aria_label(SharedString::from(label.clone()))
            .h(px(36.))
            .pl(px(4.))
            .pr(px(4.))
            .flex()
            .items_center()
            .gap(px(8.))
            .rounded(t.card_radius())
            .border_1()
            .border_color(r.border)
            .bg(conduit_components::views::kit::on_raised_fill(&t))
            .child(icon_tile(
                IconName::AudioLines,
                26.,
                with_alpha(r.text, if t.dark { 0.12 } else { 0.06 }),
                r.text_subtle,
                6.,
            ))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(px(m.small))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(r.text)
                    .child(SharedString::from(label)),
            )
            .children(trailing)
            .into_any_element()
    });
    Some(
        div()
            .id("composer-recordings")
            .role(Role::List)
            .aria_label(SharedString::from(l10n.saved_recording()))
            .px(px(6.))
            .flex()
            .flex_col()
            .gap(px(6.))
            .children(rows)
            .into_any_element(),
    )
}

/// What a notice says.
pub fn notice_text(notice: &Notice, l10n: &L10n) -> String {
    match notice {
        Notice::MicrophoneDenied => l10n.desktop_microphone_unavailable(),
        Notice::SpeechDenied => l10n.desktop_speech_recognition_off(),
        Notice::NotOnThisMac(locale) => l10n.desktop_speech_not_on_this_mac(locale),
        Notice::ServerUnavailable => l10n.desktop_server_does_not_transcribe(),
        Notice::WhisperNeedsModel => l10n.desktop_whisper_needs_model(),
        Notice::TranscriptionFailed(Some(_)) => l10n.recording_transcription_failed(),
        Notice::TranscriptionFailed(None) => l10n.desktop_transcription_failed(),
        Notice::SaveFailed => l10n.desktop_recording_save_failed(),
        Notice::ExportFailed => l10n.recording_export_failed(),
        Notice::DiscardFailed => l10n.recording_discard_failed(),
    }
}

/// What went wrong, above the composer, with what to do about it.
pub fn notice_banner(
    composer: &Entity<ChatComposer>,
    store: &Entity<DictationStore>,
    notice: &Notice,
    cx: &mut Context<ChatComposer>,
) -> AnyElement {
    let l10n = cx.l10n().clone();
    let t = cx.conduit().clone();
    let r = t.roles;
    let m = t.metrics;
    let mut actions: Vec<AnyElement> = vec![];
    if let Some(url) = notice.settings_url() {
        actions.push(
            Button::new(
                "dictation-system-settings",
                l10n.desktop_open_system_settings(),
            )
            .on_click(Rc::new(move |_, _, cx| cx.open_url(url)))
            .into_any_element(),
        );
    }
    match notice {
        Notice::NotOnThisMac(_)
        | Notice::ServerUnavailable
        | Notice::WhisperNeedsModel
        | Notice::SpeechDenied => {
            actions.push(
                Button::new(
                    "dictation-audio-settings",
                    l10n.desktop_audio_settings_button(),
                )
                .on_click(Rc::new(|_, _, cx| {
                    crate::open_settings(Some(crate::views::settings::Tab::Audio), cx)
                }))
                .into_any_element(),
            );
        }
        Notice::SaveFailed => {
            let store = store.clone();
            actions.push(
                Button::new("dictation-retry-save", l10n.desktop_try_again())
                    .on_click(Rc::new(move |_, _, cx| {
                        store.update(cx, |s, cx| s.retry_save(cx))
                    }))
                    .into_any_element(),
            );
        }
        Notice::TranscriptionFailed(Some(id)) => {
            for (key, here, label) in [
                ("dictation-retry-server", false, l10n.transcribe_on_server()),
                (
                    "dictation-retry-here",
                    true,
                    l10n.desktop_transcribe_on_this_mac(),
                ),
            ] {
                let weak = composer.downgrade();
                let id = id.clone();
                actions.push(
                    Button::new(key, label)
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = weak
                                .update(cx, |c, cx| c.transcribe_recording(&id, here, window, cx));
                        }))
                        .into_any_element(),
                );
            }
        }
        _ => {}
    }
    let dismiss = {
        let store = store.clone();
        IconButton::new(
            "dictation-dismiss",
            IconName::X,
            l10n.desktop_release_dismiss(),
        )
        .size(22., 12.)
        .color(r.text_subtle)
        .on_click(Rc::new(move |_, _, cx| {
            store.update(cx, |s, cx| s.dismiss_notice(cx))
        }))
    };
    div()
        .id("dictation-notice")
        .role(Role::Alert)
        .aria_label(SharedString::from(notice_text(notice, &l10n)))
        .mx(px(6.))
        .p(px(10.))
        .flex()
        .flex_col()
        .gap(px(8.))
        .rounded(t.card_radius())
        .border_1()
        .border_color(r.border)
        .bg(conduit_components::views::kit::on_raised_fill(&t))
        .child(
            div()
                .flex()
                .items_start()
                .gap(px(8.))
                .child(icon(
                    match notice {
                        Notice::MicrophoneDenied | Notice::SpeechDenied => IconName::Mic,
                        _ => IconName::CircleAlert,
                    },
                    15.,
                    r.text_subtle,
                ))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_size(px(m.small))
                        .text_color(r.text)
                        .child(SharedString::from(notice_text(notice, &l10n))),
                )
                .child(dismiss),
        )
        .when(!actions.is_empty(), |d| {
            d.child(
                div()
                    .pl(px(23.))
                    .flex()
                    .flex_wrap()
                    .gap(px(8.))
                    .children(actions),
            )
        })
        .into_any_element()
}
