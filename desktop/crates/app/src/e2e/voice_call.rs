//! `--e2e voice-call`: voice calls on the local Open WebUI and its fake
//! model, with WAV files standing in for the microphone (`say`, invented
//! sentences, made at test time) and the Mac's voice into a null sink
//! (`CONDUIT_SPEECH_OUTPUT=null`, as read aloud's pass has it).
//!
//! * **Standard:** the composer's call button; the call listens (the
//!   server's engine, ended by the pause), the words go to a new chat as a
//!   turn, the answer is said, and it listens again; the chat opens and
//!   holds both. Pause and resume, mute and unmute, minimise to the
//!   capsule (the menu-bar item shows the call), another chat's capsule,
//!   Show Call, and End Voice Call (⌥⌘V).
//! * **Barge-in:** the user talks over a long answer (the fake model's
//!   transcriptions are scripted, `<log>.transcripts`): the voice stops,
//!   the answer stops, and the new words go out.
//! * **Realtime:** Open WebUI's realtime bridge to the fake model's
//!   scripted voice (`/v1/realtime`): the microphone's frames go out, the
//!   voice's speech comes back and is played (into nothing), its own reply
//!   is saved with the words, a request it hands over runs as a chat turn
//!   whose answer it says, and the new chat gets a title.
//! * **A refused microphone** ends the call with what to do about it.
//!
//! Each state is shot in light and dark.

use std::path::{Path, PathBuf};
use std::time::Duration;

use conduit_protocol::{AppSettingsPatch, CallMode, CallPhase, VoiceSettingsEdit};
use gpui_kit::{App, AsyncApp, Entity};

use super::chat::{chat_store, in_pane, sign_in, wait_models};
use super::dictation::{save_voice, set_settings, speak_to};
use super::*;
use crate::stores::call::CallStore;
use crate::stores::chat::Role as MessageRole;
use crate::voice::InputOverride;

/// The fake model's answer to every transcription not scripted.
const TRANSCRIPT: &str = "A synthetic transcript from the fake model.";
/// Invented sentences, spoken by `say` into the stand-in files.
const SPEECH: &str = "What should I plant along the garden fence this spring?";
const SECOND: &str = "Please ask the chat for a short greeting.";
/// What the scripted transcriptions hear in the barge-in step.
const LONG_ASK: &str = "Tell me something long about the tides.";
const BARGE: &str = "Stop there, a shorter answer please.";
/// The fake realtime voice's lines.
const HEARD_FIRST: &str = "What is the weather like by the harbour";
const VOICE_SAYS: &str = "Calm water and a light breeze by the harbour this morning.";
const HEARD_SECOND: &str = "Ask the chat for a short greeting";

fn call(cx: &mut App) -> Entity<CallStore> {
    cx.global::<AppState>().stores.call.clone()
}

fn phase(cx: &mut App) -> CallPhase {
    call(cx).read(cx).state().phase
}

async fn wait_phase(want: CallPhase, secs: u64, cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(secs), move |cx| phase(cx) == want).await
}

/// The open chat's messages, as `(role, text)`.
fn messages(cx: &mut App) -> Vec<(MessageRole, String)> {
    let Some(store) = chat_store(cx) else {
        return vec![];
    };
    let s = store.read(cx);
    s.rows()
        .iter()
        .filter_map(|r| s.item(*r))
        .map(|i| (i.role, i.text))
        .collect()
}

fn says(cx: &mut App, role: MessageRole, text: &str) -> bool {
    messages(cx)
        .iter()
        .any(|(r, t)| *r == role && t.contains(text))
}

/// Every state the call goes through from now on, in order.
fn record_phases(cx: &mut AsyncApp) -> std::rc::Rc<std::cell::RefCell<Vec<CallPhase>>> {
    let seen = std::rc::Rc::new(std::cell::RefCell::new(Vec::<CallPhase>::new()));
    let sink = seen.clone();
    cx.update(|cx| {
        let store = call(cx);
        cx.subscribe(
            &store,
            move |store, _: &crate::stores::call::CallChanged, cx| {
                let phase = store.read(cx).state().phase;
                let mut seen = sink.borrow_mut();
                if seen.last() != Some(&phase) {
                    seen.push(phase);
                }
            },
        )
        .detach();
    });
    seen
}

fn open_chat(cx: &mut App) -> Option<String> {
    chat_store(cx).map(|s| s.read(cx).chat_id().to_string())
}

/// Quiet, 16 kHz mono 16-bit WAV.
fn write_silence(path: &Path, seconds: f32) -> bool {
    let samples = vec![0u8; (16_000.0 * seconds) as usize * 2];
    std::fs::write(path, crate::voice::pcm::wav(&samples)).is_ok()
}

/// Quiet, `first`, a pause, then `second`, as one WAV (the realtime voice
/// hears two utterances once it is set up).
fn write_two(path: &Path, first: &Path, second: &Path) -> bool {
    let read = |p: &Path| {
        std::fs::read(p)
            .ok()
            .and_then(|b| crate::voice::pcm::decode_wav(&b).ok())
    };
    let (Some((a, ra)), Some((b, rb))) = (read(first), read(second)) else {
        return false;
    };
    if ra != rb {
        return false;
    }
    // Quiet while the voice sets up (a caller waits for it to connect).
    let mut all = vec![0.0f32; ra as usize * 5];
    all.extend(a);
    all.extend(std::iter::repeat_n(0.0f32, (ra as f32 * 1.6) as usize));
    all.extend(b);
    let pcm = crate::voice::pcm::to_pcm16(&all);
    // decode_wav gave the file's own rate; the WAV writer is 16 kHz.
    if ra != crate::voice::pcm::RATE {
        return false;
    }
    std::fs::write(path, crate::voice::pcm::wav(&pcm)).is_ok()
}

/// For passes that start a call from elsewhere (the widget's link,
/// Shortcuts' Start Voice Call): a quiet stand-in for the call's microphone
/// (one that asked for the Mac's would put up its permission prompt) and
/// this pass's call settings (the server transcribes, the Mac speaks,
/// Standard calls).
pub(super) async fn prepare_quiet_call(dir: &Path, cx: &mut AsyncApp) -> bool {
    let quiet = dir.join("call-stand-in-quiet.wav");
    if !write_silence(&quiet, 60.0) {
        return false;
    }
    cx.update(|cx| {
        call(cx).update(cx, |c, cx| {
            c.set_input(Some(InputOverride::File(quiet.clone())), cx)
        })
    });
    set_settings(
        AppSettingsPatch {
            stt_preference: Some("serverOnly".into()),
            stt_language_code: Some("en".into()),
            voice_call_mode: Some("standard".into()),
            voice_barge_in_enabled: Some(false),
            ..Default::default()
        },
        cx,
    )
    .await;
    save_voice(
        VoiceSettingsEdit {
            stt_engine: Some("server".into()),
            tts_engine: Some("device".into()),
            ..Default::default()
        },
        cx,
    )
    .await
}

/// The call that is on now: its number, while one is on.
pub(super) fn call_on(cx: &mut App) -> Option<i64> {
    let store = call(cx);
    let store = store.read(cx);
    store.is_active().then(|| store.state().call)
}

/// Ends the call that is on, and waits until it is over.
pub(super) async fn end_call(cx: &mut AsyncApp) -> bool {
    cx.update(|cx| call(cx).update(cx, |c, cx| c.end(cx)));
    wait_until(cx, Duration::from_secs(10), |cx| call_on(cx).is_none()).await
}

/// Starts a call as the composer's call button does.
async fn start_call(cx: &mut AsyncApp) {
    in_pane(cx, |p, _, cx| p.start_call(cx));
    settle(cx, 100).await;
}

/// What the call's next listens hear, one each (the last one kept). Set
/// as the call's input too, so nothing asks for the Mac's microphone.
fn queue(inputs: Vec<PathBuf>, cx: &mut AsyncApp) {
    cx.update(|cx| {
        call(cx).update(cx, |c, cx| {
            if let Some(first) = inputs.first() {
                c.set_input(Some(InputOverride::File(first.clone())), cx);
            }
            c.queue_inputs(inputs.into_iter().map(InputOverride::File).collect())
        })
    });
}

/// The fake model's log lines naming the realtime voice's events.
fn realtime_events(log: &Path) -> Vec<String> {
    std::fs::read_to_string(log)
        .map(|t| {
            t.lines()
                .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
                .filter_map(|v| {
                    v.get("realtime")
                        .and_then(|r| r.as_str())
                        .map(str::to_string)
                })
                .collect()
        })
        .unwrap_or_default()
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let Some(log) = inputs.get("FAKE_MODEL_LOG").map(PathBuf::from) else {
        return ok("FAKE_MODEL_LOG in the env file", false);
    };
    let speech = dir.join("call-speech.wav");
    let second = dir.join("call-second.wav");
    let both = dir.join("call-two.wav");
    let quiet = dir.join("call-quiet.wav");
    let mut pass = ok(
        "say wrote the stand-in recordings",
        speak_to(&speech, SPEECH)
            && speak_to(&second, SECOND)
            && write_two(&both, &speech, &second)
            && write_silence(&quiet, 60.0),
    );
    pass &= sign_in(&url, &email, &password, cx).await;
    let Some((main, _)) = cx.update(main_window) else {
        return ok("main window", false);
    };
    // Never the Mac's microphone: a stand-in from the start.
    cx.update(|cx| {
        call(cx).update(cx, |c, cx| {
            c.set_input(Some(InputOverride::File(quiet.clone())), cx)
        })
    });
    pass &= ok("models.list answered", wait_models(cx).await);
    let model = inputs.model();
    in_pane(cx, move |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.select_model(&model, cx))
    });
    // The server's engine, ended by a short pause; Standard calls without
    // barge-in first.
    set_settings(
        AppSettingsPatch {
            stt_preference: Some("serverOnly".into()),
            stt_language_code: Some("en".into()),
            voice_silence_duration: Some(800),
            voice_call_mode: Some("standard".into()),
            voice_barge_in_enabled: Some(false),
            ..Default::default()
        },
        cx,
    )
    .await;
    pass &= ok(
        "Settings › Audio: the server transcribes, the Mac speaks",
        save_voice(
            VoiceSettingsEdit {
                stt_engine: Some("server".into()),
                tts_engine: Some("device".into()),
                ..Default::default()
            },
            cx,
        )
        .await,
    );

    // ── The composer's call button ─────────────────────────────────────
    let nav = cx.update(|cx| cx.global::<AppState>().stores.navigation.clone());
    nav.update(cx, |n, cx| n.new_chat(false, cx));
    settle(cx, 600).await;
    let controls = ax(main, "call-idle", dir, cx).await;
    pass &= ok(
        "an empty composer offers Start Voice Call",
        has(&controls, "Button", "Start Voice Call"),
    );
    pass &= ok(
        "the Chat menu offers Start Voice Call",
        cx.update(|cx| !crate::menus::menu_state(cx).in_call),
    );
    shoot_main(dir, "call-idle", cx).await;

    // ── A Standard call: listen, send, speak, listen again ─────────────
    // The first listen hears a long quiet (its state is shown and shot),
    // the next the recording, then quiet again.
    let seen = record_phases(cx);
    queue(vec![quiet.clone(), speech.clone(), quiet.clone()], cx);
    start_call(cx).await;
    if wait_phase(CallPhase::Starting, 3, cx).await {
        shoot_main(dir, "call-connecting", cx).await;
    }
    pass &= ok(
        "the call listens",
        wait_phase(CallPhase::Listening, 20, cx).await,
    );
    let state = cx.update(|cx| call(cx).read(cx).state().clone());
    pass &= ok(
        &format!(
            "a Standard call ({:?}, {:?})",
            state.mode, state.standard_reason
        ),
        state.mode == Some(CallMode::Standard),
    );
    let controls = ax(main, "call-listening", dir, cx).await;
    pass &= ok(
        "the strip offers Pause, Mute, Minimize and End Call",
        has(&controls, "Button", "Pause")
            && has(&controls, "Button", "Mute")
            && has(&controls, "Button", "Minimize")
            && has(&controls, "Button", "End Call"),
    );
    pass &= ok(
        "the Chat menu says End Voice Call",
        cx.update(|cx| crate::menus::menu_state(cx).in_call),
    );
    shoot_main(dir, "call-listening", cx).await;
    // Now the recording.
    cx.update(|cx| call(cx).update(cx, |c, cx| c.hear_next(cx)));
    pass &= ok(
        "it heard the words, sent them (Thinking…), said the answer, and listens again",
        wait_until(cx, Duration::from_secs(90), |cx| {
            let c = call(cx);
            let c = c.read(cx);
            c.said.len() == 1 && c.listens >= 3 && c.state().phase == CallPhase::Listening
        })
        .await,
    );
    let phases = seen.borrow().clone();
    pass &= ok(
        &format!("the call went through its states ({phases:?})"),
        [
            CallPhase::Listening,
            CallPhase::Sending,
            CallPhase::Speaking,
        ]
        .iter()
        .all(|p| phases.contains(p))
            && phases.iter().position(|p| *p == CallPhase::Sending)
                < phases.iter().rposition(|p| *p == CallPhase::Speaking),
    );
    let call_chat = cx.update(|cx| call(cx).read(cx).chat_id().map(str::to_string));
    pass &= ok(
        &format!("the call's new chat opened here ({call_chat:?})"),
        call_chat.is_some()
            && wait_until(cx, Duration::from_secs(10), |cx| {
                open_chat(cx).is_some()
                    && open_chat(cx) == call(cx).read(cx).chat_id().map(str::to_string)
            })
            .await,
    );
    pass &= ok(
        "the chat holds the words and the answer",
        wait_until(cx, Duration::from_secs(20), |cx| {
            says(cx, MessageRole::User, TRANSCRIPT)
                && messages(cx)
                    .iter()
                    .any(|(r, t)| *r == MessageRole::Assistant && !t.trim().is_empty())
        })
        .await,
    );
    pass &= ok(
        "the Mac's voice said the answer",
        cx.update(|cx| {
            !cx.global::<AppState>()
                .stores
                .speech
                .read(cx)
                .spoken
                .is_empty()
        }),
    );
    // On the call's own engine, whose microphone runs through voice
    // processing: the answer is not heard back as the user's words.
    let said_on_call = crate::voice::call_audio::said_on_calls();
    pass &= ok(
        &format!("the answer was said on the call's own audio engine ({said_on_call})"),
        said_on_call > 0 && crate::voice::call_audio::current().is_some(),
    );

    // ── Pause and resume, mute and unmute ──────────────────────────────
    cx.update(|cx| call(cx).update(cx, |c, cx| c.toggle_pause(cx)));
    let paused = wait_phase(CallPhase::Paused, 10, cx).await;
    pass &= ok("Pause", paused);
    if paused {
        let controls = ax(main, "call-paused", dir, cx).await;
        pass &= ok("paused offers Resume", has(&controls, "Button", "Resume"));
        shoot_main(dir, "call-paused", cx).await;
    }
    let listens = cx.update(|cx| call(cx).read(cx).listens);
    cx.update(|cx| call(cx).update(cx, |c, cx| c.toggle_pause(cx)));
    pass &= ok(
        "Resume listens again",
        wait_until(cx, Duration::from_secs(10), move |cx| {
            phase(cx) == CallPhase::Listening && call(cx).read(cx).listens > listens
        })
        .await,
    );
    cx.update(|cx| call(cx).update(cx, |c, cx| c.toggle_mute(cx)));
    let muted = wait_phase(CallPhase::Muted, 10, cx).await;
    pass &= ok(
        "Mute",
        muted && cx.update(|cx| call(cx).read(cx).state().muted),
    );
    if muted {
        shoot_main(dir, "call-muted", cx).await;
    }
    cx.update(|cx| call(cx).update(cx, |c, cx| c.toggle_mute(cx)));
    pass &= ok("Unmute", wait_phase(CallPhase::Listening, 10, cx).await);

    // ── Minimised, elsewhere, back ─────────────────────────────────────
    cx.update(|cx| call(cx).update(cx, |c, cx| c.toggle_collapsed(cx)));
    settle(cx, 500).await;
    let controls = ax(main, "call-minimized", dir, cx).await;
    pass &= ok(
        "minimised: the capsule offers Expand and End Call, and the composer is back",
        has(&controls, "Button", "Expand")
            && has(&controls, "Button", "End Call")
            && has(&controls, "Button", "Start Voice Call"),
    );
    #[cfg(target_os = "macos")]
    {
        pass &= ok(
            "the menu-bar item shows the call",
            cx.update(|cx| crate::desktop::menu_bar_shows_call(cx)),
        );
    }
    shoot_main(dir, "call-minimized", cx).await;
    nav.update(cx, |n, cx| n.new_chat(false, cx));
    settle(cx, 600).await;
    let controls = ax(main, "call-elsewhere", dir, cx).await;
    pass &= ok(
        "another chat shows the call's capsule with Show Call",
        has(&controls, "Button", "Show Call"),
    );
    shoot_main(dir, "call-elsewhere", cx).await;
    cx.update(|cx| cx.dispatch_action(&crate::actions::ShowCall));
    pass &= ok(
        "Show Call opens the call's chat with its strip",
        wait_until(cx, Duration::from_secs(10), |cx| {
            !call(cx).read(cx).collapsed
                && open_chat(cx) == call(cx).read(cx).chat_id().map(str::to_string)
        })
        .await,
    );

    // ── End Voice Call (⌥⌘V) ───────────────────────────────────────────
    press(main, "cmd-alt-v", cx);
    pass &= ok(
        "⌥⌘V ends the call",
        wait_until(cx, Duration::from_secs(15), |cx| {
            !call(cx).read(cx).is_active()
        })
        .await,
    );
    pass &= ok(
        "the call's audio engine went with it",
        crate::voice::call_audio::current().is_none(),
    );
    settle(cx, 500).await;
    #[cfg(target_os = "macos")]
    {
        pass &= ok(
            "the menu-bar item no longer shows a call",
            cx.update(|cx| !crate::desktop::menu_bar_shows_call(cx)),
        );
    }
    let controls = ax(main, "call-ended", dir, cx).await;
    pass &= ok(
        "the composer is back with its call button",
        has(&controls, "Button", "Start Voice Call") && !has(&controls, "Button", "End Call"),
    );

    // ── Barge-in ───────────────────────────────────────────────────────
    set_settings(
        AppSettingsPatch {
            voice_barge_in_enabled: Some(true),
            ..Default::default()
        },
        cx,
    )
    .await;
    // The fake model reads `<log>.transcripts` for what it hears next.
    let script = PathBuf::from(format!("{}.transcripts", log.display()));
    pass &= ok(
        "the transcriptions are scripted",
        std::fs::write(&script, format!("{LONG_ASK}\n{BARGE}\n")).is_ok(),
    );
    let spoken_before = cx.update(|cx| cx.global::<AppState>().stores.speech.read(cx).spoken.len());
    let said_before = crate::voice::call_audio::said_on_calls();
    // The words, quiet while the long answer is said, the words again over
    // it, then quiet.
    queue(
        vec![speech.clone(), quiet.clone(), speech.clone(), quiet.clone()],
        cx,
    );
    start_call(cx).await;
    pass &= ok(
        "a call in this chat listens",
        wait_phase(CallPhase::Listening, 20, cx).await,
    );
    let speaking = wait_phase(CallPhase::Speaking, 60, cx).await;
    pass &= ok("the long answer is said", speaking);
    if speaking {
        settle(cx, 800).await;
        let controls = ax(main, "call-speaking", dir, cx).await;
        pass &= ok(
            "speaking offers Stop Speaking",
            has(&controls, "Button", "Stop Speaking"),
        );
        shoot_main(dir, "call-speaking", cx).await;
    }
    pass &= ok(
        "with barge-in the same listen goes on through the answer",
        cx.update(|cx| call(cx).read(cx).state().phase == CallPhase::Speaking),
    );
    // The user talks over it.
    cx.update(|cx| call(cx).update(cx, |c, cx| c.hear_next(cx)));
    pass &= ok(
        "the user talked over it, and the new words went out",
        wait_until(cx, Duration::from_secs(60), |cx| {
            says(cx, MessageRole::User, BARGE)
        })
        .await,
    );
    // Only the first of its many sentences were said before the user
    // talked over it.
    let long_said = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .speech
            .read(cx)
            .spoken
            .iter()
            .filter(|(text, _)| text.contains("Synthetic paragraph"))
            .count()
    });
    pass &= ok(
        &format!("the long answer stopped being said ({long_said} of its sentences)"),
        (1..10).contains(&long_said),
    );
    let said = crate::voice::call_audio::said_on_calls() - said_before;
    pass &= ok(
        &format!(
            "with barge-in listening, the answer played on the call's engine ({said} sentences)"
        ),
        said >= long_said,
    );
    pass &= ok(
        "the call listens again after the new answer",
        wait_until(cx, Duration::from_secs(90), move |cx| {
            phase(cx) == CallPhase::Listening
                && cx.global::<AppState>().stores.speech.read(cx).spoken.len() > spoken_before + 1
                && says(cx, MessageRole::User, BARGE)
                && !chat_store(cx).is_some_and(|s| s.read(cx).is_streaming())
        })
        .await,
    );
    let _ = std::fs::write(&script, "");
    cx.update(|cx| call(cx).update(cx, |c, cx| c.end(cx)));
    pass &= ok(
        "End Call",
        wait_until(cx, Duration::from_secs(15), |cx| {
            !call(cx).read(cx).is_active()
        })
        .await,
    );
    set_settings(
        AppSettingsPatch {
            voice_barge_in_enabled: Some(false),
            ..Default::default()
        },
        cx,
    )
    .await;

    // ── Thinking… while a slow answer comes ────────────────────────────
    pass &= ok(
        "a slow answer is scripted",
        std::fs::write(&script, "Please answer slowly about the pier.\n").is_ok(),
    );
    queue(vec![speech.clone(), quiet.clone()], cx);
    start_call(cx).await;
    let thinking = wait_phase(CallPhase::Sending, 60, cx).await;
    pass &= ok("the words went to the chat: Thinking…", thinking);
    if thinking {
        settle(cx, 500).await;
        shoot_main(dir, "call-thinking", cx).await;
    }
    cx.update(|cx| call(cx).update(cx, |c, cx| c.end(cx)));
    pass &= ok(
        "End Call while it thinks",
        wait_until(cx, Duration::from_secs(15), |cx| {
            !call(cx).read(cx).is_active()
        })
        .await,
    );
    let _ = std::fs::write(&script, "");

    // ── Realtime: Open WebUI's bridge to the fake voice ────────────────
    set_settings(
        AppSettingsPatch {
            voice_call_mode: Some("auto".into()),
            ..Default::default()
        },
        cx,
    )
    .await;
    nav.update(cx, |n, cx| n.new_chat(false, cx));
    settle(cx, 600).await;
    cx.update(|cx| {
        call(cx).update(cx, |c, cx| {
            c.set_input(Some(InputOverride::File(both.clone())), cx)
        })
    });
    let before = realtime_events(&log).len();
    start_call(cx).await;
    // The voice takes a moment to set up: Connecting….
    if wait_phase(CallPhase::Starting, 3, cx).await {
        shoot_main(dir, "call-connecting", cx).await;
    }
    pass &= ok(
        "a realtime call listens",
        wait_until(cx, Duration::from_secs(45), |cx| {
            let state = call(cx).read(cx).state().clone();
            state.mode == Some(CallMode::Realtime)
                && matches!(state.phase, CallPhase::Listening | CallPhase::Speaking)
        })
        .await,
    );
    shoot_main(dir, "call-realtime-listening", cx).await;
    let speaking = wait_until(cx, Duration::from_secs(30), |cx| {
        let c = call(cx);
        let c = c.read(cx);
        c.state().phase == CallPhase::Speaking && !c.state().reply.is_empty()
    })
    .await;
    pass &= ok("the voice speaks, with its caption", speaking);
    if speaking {
        shoot_main(dir, "call-realtime-speaking", cx).await;
    }
    let (frames, enqueued) = cx.update(|cx| {
        let audio = call(cx).read(cx).audio.clone();
        (
            audio.frames.load(std::sync::atomic::Ordering::Relaxed),
            audio.enqueued.load(std::sync::atomic::Ordering::Relaxed),
        )
    });
    pass &= ok(
        &format!(
            "the microphone's frames went out ({frames}) and the voice came back ({enqueued})"
        ),
        frames > 20 && enqueued > 0,
    );
    pass &= ok(
        "the voice's reply is saved with the words it answered",
        wait_until(cx, Duration::from_secs(40), |cx| {
            says(cx, MessageRole::User, HEARD_FIRST) && says(cx, MessageRole::Assistant, VOICE_SAYS)
        })
        .await,
    );
    pass &= ok(
        "the request it handed over ran as a chat turn",
        wait_until(cx, Duration::from_secs(60), |cx| {
            says(cx, MessageRole::User, HEARD_SECOND)
                && messages(cx)
                    .last()
                    .is_some_and(|(r, t)| *r == MessageRole::Assistant && !t.trim().is_empty())
        })
        .await,
    );
    pass &= ok(
        "and the voice said its answer",
        wait_until(cx, Duration::from_secs(40), |cx| {
            call(cx)
                .read(cx)
                .state()
                .reply
                .contains("Here is what the chat said")
        })
        .await,
    );
    let events = realtime_events(&log);
    let seen = &events[before.min(events.len())..];
    pass &= ok(
        &format!(
            "the voice was set up and asked for replies ({} events)",
            seen.len()
        ),
        seen.iter().any(|e| e == "session.update")
            && seen.iter().filter(|e| *e == "response.create").count() >= 2
            && seen.iter().any(|e| e == "conversation.item.create"),
    );
    let title = wait_until(cx, Duration::from_secs(40), |cx| {
        chat_store(cx)
            .and_then(|s| s.read(cx).title().map(str::to_string))
            .is_some_and(|t| !t.is_empty() && !t.starts_with(HEARD_FIRST))
    })
    .await;
    pass &= ok("the call's chat got a title of its own", title);
    cx.update(|cx| call(cx).update(cx, |c, cx| c.end(cx)));
    pass &= ok(
        "the realtime call ends",
        wait_until(cx, Duration::from_secs(15), |cx| {
            !call(cx).read(cx).is_active()
        })
        .await,
    );
    set_settings(
        AppSettingsPatch {
            voice_call_mode: Some("standard".into()),
            ..Default::default()
        },
        cx,
    )
    .await;

    // ── A refused microphone ───────────────────────────────────────────
    cx.update(|cx| call(cx).update(cx, |c, cx| c.set_input(Some(InputOverride::Denied), cx)));
    start_call(cx).await;
    let failed = wait_phase(CallPhase::Error, 20, cx).await;
    pass &= ok("a refused microphone ends the call", failed);
    if failed {
        let controls = ax(main, "call-failed", dir, cx).await;
        pass &= ok(
            "it says what to do: Open System Settings, Dismiss",
            has(&controls, "Button", "Open System Settings") && has(&controls, "Button", "Dismiss"),
        );
        shoot_main(dir, "call-failed", cx).await;
    }
    cx.update(|cx| call(cx).update(cx, |c, cx| c.end(cx)));
    settle(cx, 300).await;
    pass &= ok(
        "Dismiss puts the composer back",
        cx.update(|cx| !call(cx).read(cx).is_shown()),
    );
    pass
}
