//! `--e2e dictation` and `--e2e dictation-recovered`, on the local
//! Open WebUI and its fake model, with WAV files standing in for the
//! microphone (`say`, invented sentences, made at test time). Run both
//! through `crates/app/e2e-dictation.sh`: the second launch is the first
//! one's relaunch.
//!
//! `dictation`:
//! * the composer's mic, with its shortcut; ⇧⌘L (the real keystroke)
//!   starts dictating after what is typed;
//! * the server's engine: the pause ends it (Settings › Audio's silence
//!   duration), the whole recording goes to the server in the chosen
//!   language (the fake model's log), its words land in the composer, and
//!   the recording is kept with the draft;
//! * "Transcribing…" while a long recording is with the server;
//! * Esc cancels: the text is put back and the recording dropped;
//! * a saved recording transcribed on the server, exported, discarded;
//! * Whisper on This Mac: a model downloaded (progress in Settings ›
//!   Audio) and used -- skipped, with the reason, when it cannot be had;
//! * This Mac's recognizer, partial words and all -- skipped, with the
//!   reason, unless Speech Recognition is already allowed (the pass never
//!   asks macOS for it);
//! * a refused microphone says so and offers System Settings;
//! * then the app quits in the middle of a dictation, as a crash would.
//!
//! `dictation-recovered`: that recording is back with the draft after the
//! relaunch; it is transcribed, exported, and goes with the draft when the
//! message is sent.
//!
//! Each new state is shot in light and dark.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use conduit_protocol::{AppSettingsPatch, NoParams, VoiceModelRef, VoiceSettingsEdit, methods};
use gpui_kit::{App, AsyncApp};
use serde_json::Value;

use super::chat::{in_pane, pane, send, sign_in, wait_answer, wait_models};
use super::composer::new_chat;
use super::*;
use crate::stores::dictation::{DictationStore, Notice, Phase};
use crate::views::chat::dictation::RecordingMenu;
use crate::voice::{EndReason, InputOverride};

/// The fake model's answer to every transcription.
const TRANSCRIPT: &str = "A synthetic transcript from the fake model.";
/// Invented sentences, spoken by `say` into the stand-in files.
const SPEECH: &str = "Plant the tomato seedlings beside the garden fence on Saturday morning.";
const LONG_SPEECH: &str = "Remember to water the herbs every evening, move the lemon tree into \
    the greenhouse before the frost, and order more compost for the vegetable beds.";

fn dictation(cx: &mut App) -> Option<Entity<DictationStore>> {
    pane(cx).and_then(|p| p.read(cx).composer.read(cx).dictation.clone())
}

fn phase(cx: &mut App) -> Phase {
    dictation(cx)
        .map(|d| d.read(cx).phase.clone())
        .unwrap_or(Phase::Idle)
}

pub(super) fn idle(cx: &mut App) -> bool {
    phase(cx) == Phase::Idle
}

pub(super) fn listening(cx: &mut App) -> bool {
    matches!(phase(cx), Phase::Listening { .. })
}

fn composer_text(cx: &mut App) -> String {
    pane(cx)
        .map(|p| p.read(cx).composer.read(cx).text(cx))
        .unwrap_or_default()
}

fn recordings(cx: &mut App) -> Vec<conduit_protocol::RecordingDto> {
    dictation(cx)
        .map(|d| d.read(cx).recordings.clone())
        .unwrap_or_default()
}

pub(super) fn set_input(input: Option<InputOverride>, cx: &mut AsyncApp) {
    cx.update(|cx| {
        if let Some(d) = dictation(cx) {
            d.update(cx, |d, _| d.set_input(input));
        }
    });
}

async fn set_composer_text(text: &str, cx: &mut AsyncApp) {
    let text = text.to_string();
    in_pane(cx, move |p, window, cx| {
        p.composer.update(cx, |c, cx| {
            c.focus_input(window, cx);
            c.set_text(&text, window, cx)
        })
    });
    settle(cx, 200).await;
}

/// Starts (or stops) dictating as the mic does.
pub(super) fn toggle(cx: &mut AsyncApp) {
    in_pane(cx, |p, window, cx| {
        p.composer
            .update(cx, |c, cx| c.toggle_dictation(window, cx))
    });
}

/// Writes `text` as speech, 16 kHz mono 16-bit WAV, with `say`.
pub(super) fn speak_to(path: &Path, text: &str) -> bool {
    Command::new("/usr/bin/say")
        .arg("-o")
        .arg(path)
        .arg("--file-format=WAVE")
        .arg("--data-format=LEI16@16000")
        .arg(text)
        .status()
        .is_ok_and(|s| s.success())
        && path.exists()
}

/// A WAV's length in seconds.
fn wav_seconds(path: &Path) -> f64 {
    std::fs::read(path)
        .ok()
        .and_then(|b| crate::voice::pcm::decode_wav(&b).ok())
        .map(|(s, rate)| s.len() as f64 / f64::from(rate))
        .unwrap_or_default()
}

/// The fake model's newest transcription upload, as its log has it.
fn last_upload(log: &Path) -> Option<Value> {
    let text = std::fs::read_to_string(log).ok()?;
    text.lines()
        .rev()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .find_map(|v| v.get("transcription").cloned())
}

fn uploads(log: &Path) -> usize {
    std::fs::read_to_string(log)
        .map(|t| {
            t.lines()
                .filter(|l| l.contains("\"transcription\""))
                .count()
        })
        .unwrap_or(0)
}

fn skip(reason: &str) {
    println!("SMOKE e2e skip {reason}");
}

/// Whether this Mac's recognizer is allowed for this app now (never asks).
fn speech_allowed() -> bool {
    #[cfg(target_os = "macos")]
    {
        crate::voice::mac::speech() == crate::voice::mac::Permission::Granted
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

pub(super) async fn set_settings(patch: AppSettingsPatch, cx: &mut AsyncApp) {
    cx.update(|cx| {
        let s = cx.global::<AppState>().stores.app_settings.clone();
        s.update(cx, |s, cx| s.set(patch, cx));
    });
    settle(cx, 800).await;
}

pub(super) async fn save_voice(edit: VoiceSettingsEdit, cx: &mut AsyncApp) -> bool {
    let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());
    rpc.call::<methods::VoiceSaveSettings>(&edit).await.is_ok()
}

/// Dictates `wav` until the dictation ends on its own; how long it took.
async fn dictate(wav: &Path, cx: &mut AsyncApp, timeout: Duration) -> Option<Duration> {
    set_input(Some(InputOverride::File(wav.to_path_buf())), cx);
    let started = Instant::now();
    toggle(cx);
    if !wait_until(cx, Duration::from_secs(10), |cx| !idle(cx)).await {
        return None;
    }
    wait_until(cx, timeout, idle)
        .await
        .then(|| started.elapsed())
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let Some(log) = inputs.get("FAKE_MODEL_LOG").map(PathBuf::from) else {
        return ok("FAKE_MODEL_LOG in the env file", false);
    };
    // The stand-in recordings, spoken now.
    let speech = dir.join("speech.wav");
    let long = dir.join("long-speech.wav");
    let mut pass = ok(
        "say wrote the stand-in recordings",
        speak_to(&speech, SPEECH) && speak_to(&long, LONG_SPEECH),
    );
    let (speech_secs, long_secs) = (wav_seconds(&speech), wav_seconds(&long));
    pass &= ok(
        &format!("the recordings last {speech_secs:.1} s and {long_secs:.1} s"),
        speech_secs > 2.0 && long_secs >= 6.5,
    );
    pass &= sign_in(&url, &email, &password, cx).await;
    let Some((main, _)) = cx.update(main_window) else {
        return ok("main window", false);
    };
    pass &= ok("models.list answered", wait_models(cx).await);
    let model = inputs.model();
    in_pane(cx, move |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.select_model(&model, cx))
    });
    new_chat(cx).await;
    pass &= ok(
        "the composer has dictation",
        cx.update(|cx| dictation(cx).is_some()),
    );

    // ── The mic, with its shortcut ─────────────────────────────────────
    let controls = ax(main, "dictation-idle", dir, cx).await;
    pass &= ok(
        "the composer offers Start Dictation",
        has(&controls, "Button", "Start Dictation"),
    );
    shoot_main(dir, "dictation-idle", cx).await;

    // ── The server's engine, ended by the pause ────────────────────────
    set_settings(
        AppSettingsPatch {
            stt_preference: Some("serverOnly".into()),
            stt_language_code: Some("en".into()),
            voice_silence_duration: Some(800),
            ..Default::default()
        },
        cx,
    )
    .await;
    pass &= ok(
        "Settings › Audio: the server's engine",
        save_voice(
            VoiceSettingsEdit {
                stt_engine: Some("server".into()),
                ..Default::default()
            },
            cx,
        )
        .await,
    );
    set_composer_text("Note:", cx).await;
    set_input(Some(InputOverride::File(speech.clone())), cx);
    let before = uploads(&log);
    let started = Instant::now();
    press(main, "cmd-shift-l", cx);
    pass &= ok(
        "⇧⌘L starts listening",
        wait_until(cx, Duration::from_secs(10), listening).await,
    );
    settle(cx, 1_500).await;
    let controls = ax(main, "dictation-listening", dir, cx).await;
    pass &= ok(
        "listening offers Stop and Cancel Dictation",
        has(&controls, "Button", "Stop Dictation") && has(&controls, "Button", "Cancel Dictation"),
    );
    pass &= ok(
        "the Chat menu says Stop Dictation",
        cx.update(|cx| crate::menus::menu_state(cx).dictating),
    );
    shoot_main(dir, "dictation-listening", cx).await;
    let ended = wait_until(cx, Duration::from_secs(30), idle).await;
    let took = started.elapsed();
    let end = cx.update(|cx| dictation(cx).and_then(|d| d.read(cx).last_end));
    pass &= ok(
        &format!("the pause ended it ({end:?} after {took:?})"),
        ended && end == Some(EndReason::Silence) && took.as_secs_f64() < speech_secs + 6.0,
    );
    let text = cx.update(composer_text);
    pass &= ok(
        &format!("the server's words follow the text ({text:?})"),
        text == format!("Note: {TRANSCRIPT}"),
    );
    let upload = last_upload(&log);
    let seconds = upload
        .as_ref()
        .and_then(|u| u.get("seconds"))
        .and_then(Value::as_f64)
        .unwrap_or_default();
    let language = upload
        .as_ref()
        .and_then(|u| u.get("language"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    pass &= ok(
        &format!("the whole recording went to the server ({seconds} s, language {language:?})"),
        uploads(&log) == before + 1
            && seconds >= speech_secs - 0.3
            && seconds <= speech_secs + 3.0
            && language == "en",
    );
    let kept = wait_until(cx, Duration::from_secs(10), |cx| recordings(cx).len() == 1).await;
    let listed = cx.update(recordings);
    pass &= ok(
        &format!("the recording is kept with the draft ({listed:?})"),
        kept && listed
            .first()
            .is_some_and(|r| (r.duration_ms as f64 / 1000.0 - seconds).abs() < 0.5),
    );
    shoot_main(dir, "dictation-saved-recording", cx).await;

    // ── Transcribing, while a long one is with the server ──────────────
    set_composer_text("", cx).await;
    set_input(Some(InputOverride::File(long.clone())), cx);
    toggle(cx);
    let transcribing = wait_until(cx, Duration::from_secs(40), |cx| {
        phase(cx) == Phase::Transcribing
    })
    .await;
    pass &= ok("a long recording shows Transcribing…", transcribing);
    if transcribing {
        shoot_main(dir, "dictation-transcribing", cx).await;
    }
    wait_until(cx, Duration::from_secs(30), idle).await;
    pass &= ok("its words arrive", cx.update(composer_text) == TRANSCRIPT);
    wait_until(cx, Duration::from_secs(10), |cx| recordings(cx).len() == 2).await;

    // ── Esc cancels ────────────────────────────────────────────────────
    set_composer_text("Keep this", cx).await;
    set_input(Some(InputOverride::File(long.clone())), cx);
    toggle(cx);
    let heard = wait_until(cx, Duration::from_secs(10), listening).await;
    settle(cx, 2_000).await;
    press(main, "escape", cx);
    let stopped = wait_until(cx, Duration::from_secs(10), idle).await;
    let end = cx.update(|cx| dictation(cx).and_then(|d| d.read(cx).last_end));
    settle(cx, 1_000).await;
    let (text, count) = cx.update(|cx| (composer_text(cx), recordings(cx).len()));
    pass &= ok(
        &format!("Esc cancels: the text is put back, the audio dropped ({text:?}, {count})"),
        heard && stopped && end == Some(EndReason::Cancelled) && text == "Keep this" && count == 2,
    );

    // ── A saved recording: on the server, exported, discarded ──────────
    set_composer_text("", cx).await;
    let first = cx.update(recordings).first().cloned();
    if let Some(first) = first {
        let id = first.id.clone();
        in_pane(cx, move |p, window, cx| {
            p.composer.update(cx, |c, cx| {
                c.on_recording_menu(&RecordingMenu::TranscribeOnServer(id), window, cx)
            })
        });
        let done = wait_until(cx, Duration::from_secs(20), |cx| {
            composer_text(cx) == TRANSCRIPT
                && dictation(cx).is_some_and(|d| d.read(cx).busy.is_none())
        })
        .await;
        pass &= ok("Transcribe on Server: its words in the composer", done);
        let path = dir.join("exported-recording.wav");
        let id = first.id.clone();
        let export = cx.update(|cx| {
            dictation(cx).map(|d| d.update(cx, |d, cx| d.export_to(&id, path.clone(), cx)))
        });
        let written = match export {
            Some(task) => task.await,
            None => false,
        };
        let bytes = std::fs::read(&path).unwrap_or_default();
        pass &= ok(
            &format!("Export…: a WAV of the recording ({} bytes)", bytes.len()),
            written && bytes.starts_with(b"RIFF") && bytes.len() as i64 == 44 + first.byte_count,
        );
        // Discard Recording… asks first: Cancel keeps it.
        cx.update(|cx| cx.set_global(AutoAnswer(None)));
        let id = first.id.clone();
        in_pane(cx, move |p, window, cx| {
            p.composer.update(cx, |c, cx| {
                c.on_recording_menu(&RecordingMenu::Discard(id), window, cx)
            })
        });
        settle(cx, 900).await;
        shoot_main(dir, "dictation-discard-sheet", cx).await;
        let ns = cx.update(|cx| crate::smoke::ns_window(main, cx));
        let attached = ns
            .as_ref()
            .is_some_and(|ns| crate::smoke::end_attached_sheet(ns));
        settle(cx, 600).await;
        cx.update(|cx| cx.set_global(AutoAnswer(Some(true))));
        pass &= ok(
            "Discard Recording… asks first, and Cancel keeps it",
            attached && cx.update(recordings).len() == 2,
        );
        let id = first.id.clone();
        in_pane(cx, move |p, window, cx| {
            p.composer.update(cx, |c, cx| {
                c.on_recording_menu(&RecordingMenu::Discard(id), window, cx)
            })
        });
        pass &= ok(
            "Discard Recording: it is gone",
            wait_until(cx, Duration::from_secs(10), |cx| recordings(cx).len() == 1).await,
        );
    } else {
        pass &= ok("a saved recording to act on", false);
    }

    // ── Whisper on this Mac ────────────────────────────────────────────
    pass &= whisper(&speech, dir, cx).await;

    // ── This Mac's recognizer ──────────────────────────────────────────
    pass &= this_mac(&speech, dir, cx).await;

    // ── A refused microphone ───────────────────────────────────────────
    set_settings(
        AppSettingsPatch {
            stt_preference: Some("serverOnly".into()),
            ..Default::default()
        },
        cx,
    )
    .await;
    save_voice(
        VoiceSettingsEdit {
            stt_engine: Some("server".into()),
            ..Default::default()
        },
        cx,
    )
    .await;
    set_composer_text("", cx).await;
    set_input(Some(InputOverride::Denied), cx);
    toggle(cx);
    let told = wait_until(cx, Duration::from_secs(10), |cx| {
        idle(cx)
            && dictation(cx).is_some_and(|d| d.read(cx).notice == Some(Notice::MicrophoneDenied))
    })
    .await;
    settle(cx, 400).await;
    let controls = ax(main, "dictation-mic-denied", dir, cx).await;
    pass &= ok(
        "a refused microphone says so, with System Settings",
        told && has(&controls, "Button", "Open System Settings"),
    );
    shoot_main(dir, "dictation-mic-denied", cx).await;
    // This Mac's recognizer turned off reads the same way (its words, and
    // Audio Settings…).
    cx.update(|cx| {
        if let Some(d) = dictation(cx) {
            d.update(cx, |d, cx| {
                d.notice = Some(Notice::SpeechDenied);
                cx.notify();
            });
        }
    });
    settle(cx, 300).await;
    shoot_main(dir, "dictation-speech-off", cx).await;
    cx.update(|cx| {
        if let Some(d) = dictation(cx) {
            d.update(cx, |d, cx| d.dismiss_notice(cx));
        }
    });

    // ── Quit in the middle of a dictation, as a crash would ────────────
    // Only that recording is left for the relaunch to find.
    let left: Vec<String> = cx.update(|cx| recordings(cx).into_iter().map(|r| r.id).collect());
    for id in left {
        cx.update(|cx| {
            if let Some(d) = dictation(cx) {
                d.update(cx, |d, cx| d.discard(&id, cx));
            }
        });
    }
    wait_until(cx, Duration::from_secs(10), |cx| recordings(cx).is_empty()).await;
    set_input(Some(InputOverride::File(long.clone())), cx);
    toggle(cx);
    let recording = wait_until(cx, Duration::from_secs(10), listening).await;
    // Three seconds of audio, each committed as it came.
    settle(cx, 3_500).await;
    pass &= ok("dictating when Conduit quits", recording);
    println!(
        "SMOKE e2e dictation {} before the quit",
        if pass { "passed" } else { "FAILED" }
    );
    // No Stop, no close: the process ends as a crash would end it.
    std::process::exit(if pass { 0 } else { 1 });
}

async fn whisper(speech: &Path, dir: &Path, cx: &mut AsyncApp) -> bool {
    let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());
    let Ok(settings) = rpc.call::<methods::VoiceSettings>(&NoParams).await else {
        return ok("voice.settings", false);
    };
    if !settings.local_stt {
        skip("Whisper on This Mac: this build has no whisper library (CONDUIT_WHISPER_LIB)");
        return true;
    }
    set_settings(
        AppSettingsPatch {
            stt_preference: Some("serverOnly".into()),
            ..Default::default()
        },
        cx,
    )
    .await;
    let mut pass = ok(
        "Settings › Audio: Whisper on This Mac",
        save_voice(
            VoiceSettingsEdit {
                stt_engine: Some("local".into()),
                local_model: Some("tiny.en".into()),
                ..Default::default()
            },
            cx,
        )
        .await,
    );
    let downloaded = |models: &conduit_protocol::VoiceModels| {
        models
            .models
            .iter()
            .any(|m| m.id == "tiny.en" && m.downloaded)
    };
    let models = rpc.call::<methods::VoiceModels>(&NoParams).await;
    if !models.as_ref().is_ok_and(downloaded) {
        // Downloaded now, its progress shown in Settings › Audio (open
        // first: a small model can arrive in seconds).
        cx.update(|cx| crate::open_settings(Some(Tab::Audio), cx));
        settle(cx, 600).await;
        let settings = cx.update(|cx| {
            cx.global::<AppState>()
                .settings_window
                .as_ref()
                .map(|(h, _)| *h)
        });
        if let Some(h) = settings {
            crate::smoke::place_settings(h, cx);
        }
        let _ = rpc
            .call::<methods::VoiceDownloadModel>(&VoiceModelRef {
                id: "tiny.en".into(),
            })
            .await;
        let deadline = Instant::now() + Duration::from_secs(300);
        let mut progress = vec![];
        let mut shot = false;
        loop {
            let m = rpc.call::<methods::VoiceModels>(&NoParams).await;
            if let Ok(m) = &m {
                if let Some(r) = m
                    .models
                    .iter()
                    .find(|m| m.id == "tiny.en")
                    .and_then(|m| m.received_bytes)
                {
                    progress.push(r);
                    // A fifth of the way in, where a fast download still shows.
                    if !shot
                        && r > 15_000_000
                        && let Some(h) = settings
                    {
                        shot = true;
                        shoot_both_modes(h, dir, "dictation-whisper-downloading", cx).await;
                    }
                }
                if downloaded(m) || m.failed_id.is_some() {
                    break;
                }
            }
            if Instant::now() > deadline {
                break;
            }
            settle(cx, 150).await;
        }
        let m = rpc.call::<methods::VoiceModels>(&NoParams).await;
        if !m.as_ref().is_ok_and(downloaded) {
            let why = m
                .ok()
                .and_then(|m| m.failure)
                .unwrap_or_else(|| "not finished in five minutes".into());
            skip(&format!(
                "Whisper on This Mac: the tiny model could not be downloaded ({why})"
            ));
            return pass;
        }
        pass &= ok(
            &format!(
                "the download reported its progress ({} steps)",
                progress.len()
            ),
            progress.len() >= 2 && progress.windows(2).all(|w| w[0] <= w[1]),
        );
    }
    settings_tab(Tab::Audio, dir, "dictation-whisper-ready", cx).await;
    cx.update(|cx| {
        if let Some((h, _)) = cx.global::<AppState>().settings_window.clone() {
            let _ = h.update(cx, |_, window, _| window.remove_window());
        }
    });
    set_composer_text("", cx).await;
    let took = dictate(speech, cx, Duration::from_secs(90)).await;
    let text = cx.update(composer_text).to_lowercase();
    pass &= ok(
        &format!("Whisper on This Mac heard it ({text:?}, {took:?})"),
        took.is_some() && (text.contains("tomato") || text.contains("garden")),
    );
    pass
}

async fn this_mac(speech: &Path, dir: &Path, cx: &mut AsyncApp) -> bool {
    if !speech_allowed() {
        skip(
            "On This Mac: Speech Recognition is not allowed for this dev build (an ad-hoc \
             signature loses the grant on every rebuild, and the pass never asks macOS)",
        );
        return true;
    }
    set_settings(
        AppSettingsPatch {
            stt_preference: Some("deviceOnly".into()),
            ..Default::default()
        },
        cx,
    )
    .await;
    set_composer_text("", cx).await;
    let partials = std::rc::Rc::new(std::cell::Cell::new(0usize));
    let seen = partials.clone();
    let sub = cx.update(|cx| {
        dictation(cx).map(|d| {
            cx.subscribe(
                &d,
                move |_, e: &crate::stores::dictation::DictationEvent, _| {
                    if matches!(
                        e,
                        crate::stores::dictation::DictationEvent::Text { done: false, .. }
                    ) {
                        seen.set(seen.get() + 1);
                    }
                },
            )
        })
    });
    let took = dictate(speech, cx, Duration::from_secs(40)).await;
    drop(sub);
    let text = cx.update(composer_text).to_lowercase();
    let mut pass = ok(
        &format!(
            "This Mac heard it, word by word ({text:?}, {} partials, {took:?})",
            partials.get()
        ),
        took.is_some()
            && partials.get() > 0
            && (text.contains("tomato") || text.contains("garden")),
    );
    shoot_main(dir, "dictation-this-mac", cx).await;
    // And a saved recording, by file recognition.
    let last = cx.update(recordings).last().cloned();
    if let Some(last) = last {
        set_composer_text("", cx).await;
        let id = last.id.clone();
        in_pane(cx, move |p, window, cx| {
            p.composer.update(cx, |c, cx| {
                c.on_recording_menu(&RecordingMenu::TranscribeOnThisMac(id), window, cx)
            })
        });
        let done = wait_until(cx, Duration::from_secs(60), |cx| {
            !composer_text(cx).is_empty()
                && dictation(cx).is_some_and(|d| d.read(cx).busy.is_none())
        })
        .await;
        let text = cx.update(composer_text).to_lowercase();
        pass &= ok(
            &format!("Transcribe on This Mac: a saved recording ({text:?})"),
            done && (text.contains("tomato") || text.contains("garden")),
        );
    }
    pass
}

/// After the quit: the recording is back with the draft.
pub async fn recovered(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    if inputs.owui().is_none() {
        return ok(NO_SERVER, false);
    }
    let mut pass = wait_route(cx, Route::Main, Duration::from_secs(90)).await;
    pass &= wait_main(cx).await.is_some();
    pass &= ok("models.list answered", wait_models(cx).await);
    new_chat(cx).await;
    let back = wait_until(cx, Duration::from_secs(20), |cx| recordings(cx).len() == 1).await;
    let rec = cx.update(recordings).first().cloned();
    pass &= ok(
        &format!("the recording made when Conduit quit is back ({rec:?})"),
        back && rec.as_ref().is_some_and(|r| r.byte_count >= 64_000),
    );
    shoot_main(dir, "dictation-recovered", cx).await;
    let Some(rec) = rec else {
        return pass;
    };
    set_composer_text("", cx).await;
    let id = rec.id.clone();
    in_pane(cx, move |p, window, cx| {
        p.composer.update(cx, |c, cx| {
            c.on_recording_menu(&RecordingMenu::TranscribeOnServer(id), window, cx)
        })
    });
    pass &= ok(
        "it is transcribed on the server",
        wait_until(cx, Duration::from_secs(20), |cx| {
            composer_text(cx) == TRANSCRIPT
        })
        .await,
    );
    let path = dir.join("recovered-recording.wav");
    let id = rec.id.clone();
    let export = cx.update(|cx| {
        dictation(cx).map(|d| d.update(cx, |d, cx| d.export_to(&id, path.clone(), cx)))
    });
    let written = match export {
        Some(task) => task.await,
        None => false,
    };
    let bytes = std::fs::read(&path).unwrap_or_default();
    pass &= ok(
        &format!("and exported ({} bytes)", bytes.len()),
        written && bytes.starts_with(b"RIFF") && bytes.len() as i64 == 44 + rec.byte_count,
    );
    // Sent: the draft's recordings go with it, as on the phone.
    send("Thanks, noted.", cx).await;
    pass &= ok(
        "the message went out",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    pass &= ok(
        "sending took the draft's recording with it",
        wait_until(cx, Duration::from_secs(10), |cx| recordings(cx).is_empty()).await,
    );
    let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());
    let listed = rpc
        .call::<methods::RecordingsList>(&conduit_protocol::RecordingTarget::default())
        .await;
    pass &= ok(
        "and the daemon keeps none for a new chat",
        listed.is_ok_and(|l| l.recordings.is_empty()),
    );
    pass
}
