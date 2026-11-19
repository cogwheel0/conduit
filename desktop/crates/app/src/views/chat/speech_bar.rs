//! The playback bar: docked above the message field while an answer in
//! this chat is read aloud, as the phone's speech bar sits above its
//! composer. Mac-compact, one row:
//!
//! Previous Sentence · Pause/Resume · Next Sentence, then where the reading
//! is ("Sentence 2 of 5", or Preparing…, or what went wrong with Try Again)
//! over a track with one mark per sentence (a click on a mark moves the
//! reading there, as the phone's tap on its progress does), the time, the
//! speed (a pop-up of the phone's presets: the setting, which reaches the
//! reading under way) and Stop Speaking (⌘.).
//!
//! The track and the controls only change state; nothing slides, so Reduce
//! Motion has nothing to hold back here.

use std::rc::Rc;

use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{ConduitTheme, with_alpha};
use conduit_components::views::kit::{Button, IconButton};
use conduit_protocol::{AppSettingsPatch, SpeechStatus};
use gpui_kit::prelude::*;
use gpui_kit::{AnyElement, App, ElementId, Entity, FontWeight, Role, SharedString, div, px};

use crate::l10n::ActiveL10n as _;
use crate::stores::app_settings::AppSettingsStore;
use crate::stores::speech::SpeechStore;

/// Settings' speeds, as the pop-up lists them.
pub use crate::views::settings::audio::SPEEDS;

/// The speed chosen from the bar's pop-up: the setting, as Settings ›
/// Audio sets it.
#[derive(Clone, Debug, PartialEq, gpui_kit::Action)]
#[action(namespace = conduit_speech, no_json)]
pub struct SetSpeechSpeed {
    pub speed: f64,
}

/// Registers the pop-up's action on the app.
pub fn register(cx: &mut App) {
    cx.on_action(|a: &SetSpeechSpeed, cx: &mut App| {
        let Some(settings) = cx
            .try_global::<crate::AppState>()
            .map(|s| s.stores.app_settings.clone())
        else {
            return;
        };
        let speed = a.speed;
        settings.update(cx, |s, cx| {
            s.set(
                AppSettingsPatch {
                    tts_speed: Some(speed),
                    ..Default::default()
                },
                cx,
            )
        });
    });
}

/// `ms` as the bar shows it: `0:07`, `1:05`, `1:02:03`.
pub fn clock(ms: i64) -> String {
    let s = (ms.max(0) / 1000) as u64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, (s / 60) % 60, s % 60)
    } else {
        format!("{}:{:02}", s / 60, s % 60)
    }
}

/// How far each sentence's mark is filled: those read, the one being read
/// (by how far into it the word is), and those ahead.
pub fn mark_fill(index: usize, current: i64, within: f32) -> f32 {
    let current = current.max(0) as usize;
    match index.cmp(&current) {
        std::cmp::Ordering::Less => 1.0,
        std::cmp::Ordering::Equal => within.clamp(0.0, 1.0),
        std::cmp::Ordering::Greater => 0.0,
    }
}

/// The bar for the reading in chat `chat_id`, or nothing when no answer of
/// it is read.
pub fn speech_bar(
    speech: &Entity<SpeechStore>,
    settings: &Entity<AppSettingsStore>,
    chat_id: Option<&str>,
    t: &ConduitTheme,
    cx: &mut App,
) -> Option<AnyElement> {
    let s = speech.read(cx);
    if !s.is_active() || s.chat_id().is_none() || s.chat_id() != chat_id {
        return None;
    }
    let l10n = cx.l10n().clone();
    let r = t.roles;
    let m = t.metrics;
    let p = s.progress().clone();
    let sentences = s.sentences().to_vec();
    let total = sentences.len();
    let failed = p.status == SpeechStatus::Error;
    let paused = p.status == SpeechStatus::Paused;
    let busy = matches!(p.status, SpeechStatus::Loading | SpeechStatus::Initializing);
    let can_skip = p.can_seek_sentences && !busy && !failed && !p.seeking;
    let current = p.sentence;
    let speed = settings.read(cx).settings().tts_speed;
    let chord = |stroke: crate::keymap::KeyStroke| -> SharedString {
        crate::keymap::describe(&stroke, cfg!(target_os = "macos")).into()
    };

    let button = |id: &'static str, glyph: IconName, label: String, enabled: bool| {
        IconButton::new(id, glyph, label.clone())
            .size(26., 13.)
            .tooltip(label)
            .disabled(!enabled)
    };
    let store = speech.clone();
    let previous = button(
        "speech-previous",
        IconName::SkipBack,
        l10n.desktop_previous_sentence(),
        can_skip && current > 0,
    )
    .on_click(Rc::new(move |_, _, cx| {
        store.update(cx, |s, cx| s.skip(-1, cx));
    }));
    let store = speech.clone();
    let toggle_label = if paused {
        l10n.voice_call_resume()
    } else {
        l10n.voice_call_pause()
    };
    let toggle = button(
        "speech-toggle",
        if paused {
            IconName::Play
        } else {
            IconName::Pause
        },
        toggle_label,
        !busy && !failed,
    )
    .on_click(Rc::new(move |_, _, cx| {
        store.update(cx, |s, cx| s.toggle_pause(cx));
    }));
    let store = speech.clone();
    let next = button(
        "speech-next",
        IconName::SkipForward,
        l10n.desktop_next_sentence(),
        can_skip && (current + 1) < total as i64,
    )
    .on_click(Rc::new(move |_, _, cx| {
        store.update(cx, |s, cx| s.skip(1, cx));
    }));

    // Where it is, in words.
    let status_text = if failed {
        l10n.desktop_speech_failed()
    } else if busy || total == 0 {
        l10n.desktop_speech_preparing()
    } else {
        l10n.desktop_speech_sentence_of(
            &(current.max(0) + 1).min(total as i64).to_string(),
            &total.to_string(),
        )
    };
    let retry = failed.then(|| {
        let store = speech.clone();
        Button::new("speech-retry", l10n.desktop_try_again())
            .on_click(Rc::new(move |_, _, cx| {
                store.update(cx, |s, cx| s.retry(cx));
            }))
            .into_any_element()
    });

    // One mark per sentence; the one being read fills as its words go by.
    let within = match (p.word_end, sentences.get(current.max(0) as usize)) {
        (Some(end), Some(sentence)) if !sentence.is_empty() => {
            end as f32 / sentence.encode_utf16().count().max(1) as f32
        }
        _ => 0.0,
    };
    let marks: Vec<AnyElement> = sentences
        .iter()
        .enumerate()
        .map(|(i, _)| {
            let fill = if failed || busy {
                0.0
            } else {
                mark_fill(i, current, within)
            };
            let store = speech.clone();
            let label = l10n.desktop_go_to_sentence(&(i + 1).to_string());
            div()
                .id(ElementId::NamedInteger("speech-mark".into(), i as u64))
                .role(Role::Button)
                .aria_label(SharedString::from(label.clone()))
                .aria_selected(i as i64 == current)
                .flex_1()
                .min_w(px(2.))
                .h(px(14.))
                .flex()
                .items_center()
                .when(can_skip, |d| {
                    d.cursor_pointer()
                        .tooltip(conduit_components::views::focus::tooltip_builder(
                            label.into(),
                            None,
                        ))
                        .on_click(move |_, _, cx| {
                            store.update(cx, |s, cx| s.seek_sentence(i, cx));
                        })
                })
                .child(
                    div()
                        .w_full()
                        .h(px(4.))
                        .rounded(px(2.))
                        .bg(with_alpha(r.text, 0.14))
                        .overflow_hidden()
                        .child(div().h_full().w(gpui_kit::relative(fill)).bg(
                            if i as i64 == current {
                                r.text
                            } else {
                                with_alpha(r.text, 0.55)
                            },
                        )),
                )
                .into_any_element()
        })
        .collect();

    let time = if p.duration_ms > 0 {
        format!("{} / {}", clock(p.elapsed_ms), clock(p.duration_ms))
    } else {
        clock(p.elapsed_ms)
    };

    let speed_label = l10n.tts_speed_value(speed);
    let speed_menu = {
        let labels: Vec<(f64, String)> = SPEEDS
            .iter()
            .map(|v| (*v, l10n.tts_speed_value(*v)))
            .collect();
        let tip = l10n.tts_playback_speed();
        let button = Button::new("speech-speed", speed_label.clone()).on_click(Rc::new(
            move |e: &gpui_kit::ClickEvent, window, cx| {
                use gpui_kit::component::native_menu::NativeMenu;
                let mut menu = NativeMenu::new();
                for (value, label) in &labels {
                    menu = menu.menu_with_check(
                        label.clone(),
                        (*value - speed).abs() < 0.01,
                        Box::new(SetSpeechSpeed { speed: *value }),
                    );
                }
                menu.show(e.position(), window, cx);
            },
        ));
        div()
            .id("speech-speed-tip")
            .flex_none()
            .tooltip(conduit_components::views::focus::tooltip_builder(
                tip.into(),
                None,
            ))
            .child(button)
    };
    let store = speech.clone();
    let stop = IconButton::new("speech-stop", IconName::X, l10n.desktop_stop_speaking())
        .size(26., 13.)
        .tooltip(l10n.desktop_stop_speaking())
        .shortcut(Some(chord(crate::keymap::KeyStroke::new(".").primary())))
        .on_click(Rc::new(move |_, _, cx| {
            store.update(cx, |s, cx| s.stop(cx));
        }));

    Some(
        div()
            .id("speech-bar")
            .role(Role::Toolbar)
            .aria_label(SharedString::from(l10n.desktop_reading_aloud()))
            .w_full()
            .mb(px(8.))
            .pl(px(6.))
            .pr(px(6.))
            .h(px(44.))
            .flex()
            .items_center()
            .gap(px(4.))
            .rounded(t.card_radius())
            .border_1()
            .border_color(r.border)
            .bg(conduit_components::views::kit::on_raised_fill(t))
            .child(previous)
            .child(toggle)
            .child(next)
            .child(
                div()
                    .ml(px(6.))
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap(px(1.))
                    .child(
                        div()
                            .id("speech-status")
                            .role(Role::Status)
                            .aria_label(SharedString::from(status_text.clone()))
                            .flex()
                            .items_center()
                            .gap(px(6.))
                            .text_size(px(m.caption))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(if failed { r.danger } else { r.text_subtle })
                            .when(failed, |d| {
                                d.child(icon(IconName::CircleAlert, 11., r.danger))
                            })
                            .child(div().truncate().child(SharedString::from(status_text))),
                    )
                    .child(
                        div()
                            .id("speech-track")
                            .role(Role::Group)
                            .w_full()
                            .flex()
                            .items_center()
                            .gap(px(2.))
                            .children(marks),
                    ),
            )
            .children(retry)
            .child(
                div()
                    .id("speech-time")
                    .ml(px(4.))
                    .flex_none()
                    .text_size(px(m.caption))
                    .min_w(px(34.))
                    .text_right()
                    .text_color(r.text_subtle)
                    .child(SharedString::from(time)),
            )
            .child(speed_menu)
            .child(stop)
            .into_any_element(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_clock_reads_as_a_player_shows_it() {
        assert_eq!(clock(0), "0:00");
        assert_eq!(clock(7_400), "0:07");
        assert_eq!(clock(65_000), "1:05");
        assert_eq!(clock(3_723_000), "1:02:03");
        assert_eq!(clock(-5), "0:00");
    }

    #[test]
    fn marks_fill_behind_the_reading() {
        assert_eq!(mark_fill(0, 2, 0.5), 1.0);
        assert_eq!(mark_fill(2, 2, 0.5), 0.5);
        assert_eq!(mark_fill(3, 2, 0.5), 0.0);
        assert_eq!(mark_fill(0, -1, 0.5), 0.5);
    }
}
