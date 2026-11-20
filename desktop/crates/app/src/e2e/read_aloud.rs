//! `--e2e read-aloud`: read aloud on the local Open WebUI and its fake
//! model ("read aloud" in a prompt gets four long sentences; its
//! `/audio/speech` answers with silence as long as the text would take).
//! `run.sh` reads into a null sink (`CONDUIT_SPEECH_OUTPUT=null`): the
//! Mac's voice still reports its words and the clips still run their
//! length, so the reading moves on and nothing is heard.
//!
//! * **On This Mac:** Read Aloud on the answer; the reading speaks live,
//!   word by word (store state and the transcript's marks); the bar's
//!   controls are there; pause, Next Sentence while paused, resume (each
//!   said to VoiceOver once the reading is so: "Reading paused", "Reading
//!   resumed"); a click on a sentence's mark on the bar; a new speed says
//!   the rest at the new rate; Stop Speaking.
//! * **Keys:** Esc stops the reading; Chat › Read Aloud (⌥⌘R) reads the
//!   last answer and ⌘. stops it; Chat › Stop Speaking follows.
//! * **Dictation takes turns with it** (the microphone would hear the
//!   voice): dictating pauses the reading without a word to VoiceOver (the
//!   microphone would hear it), Esc cancels the dictation first, and Play
//!   ends the dictation as Stop does.
//! * **Elsewhere:** the reading pauses when another chat opens; Settings'
//!   Preview reads through the same engine.
//! * **Server:** the reading plays the server's speech, fetched from
//!   `/tts/{job}`: its length is known, so it seeks; skip, pause, stop.
//!
//! The chat it makes is deleted at the end.

use std::path::Path;
use std::time::Duration;

use conduit_protocol::{ChatRef, SpeechEngine, SpeechStatus, VoiceSettingsEdit, methods};
use gpui_kit::{AsyncApp, Entity};

use super::chat::{chat_store, in_pane, pane, send, sign_in, wait_answer, wait_models};
use super::*;
use crate::l10n::ActiveL10n as _;
use crate::stores::chat::Role as MessageRole;
use crate::stores::speech::SpeechStore;
use crate::views::chat::actions::{RowCommand, RowContext};
use conduit_components::announce::AnnouncementLog;

/// How many times VoiceOver was told `text` so far.
fn heard(text: &str, cx: &mut AsyncApp) -> usize {
    cx.update(|cx| {
        AnnouncementLog::texts(cx)
            .iter()
            .filter(|t| t.as_ref() == text)
            .count()
    })
}

fn speech(cx: &mut App) -> Entity<SpeechStore> {
    cx.global::<AppState>().stores.speech.clone()
}

fn status(cx: &mut App) -> SpeechStatus {
    speech(cx).read(cx).progress().status
}

fn sentence(cx: &mut App) -> i64 {
    speech(cx).read(cx).progress().sentence
}

/// The open chat's last answer, and the context its buttons run in.
fn last_answer(cx: &mut App) -> Option<(String, RowContext)> {
    let store = chat_store(cx)?;
    let pane = pane(cx)?;
    let item = {
        let s = store.read(cx);
        s.rows()
            .iter()
            .filter_map(|r| s.item(*r))
            .rev()
            .find(|i| i.role == MessageRole::Assistant)?
    };
    let target = crate::views::chat::rows::shown_answer_id(&item);
    Some((
        target.clone(),
        RowContext {
            store: store.downgrade(),
            pane: Some(pane.downgrade()),
            key: item.key.clone(),
            target,
            mergeable: vec![],
            position: gpui_kit::point(gpui_kit::px(400.), gpui_kit::px(300.)),
        },
    ))
}

/// Read Aloud on the last answer, as its button does.
async fn read_aloud(cx: &mut AsyncApp) -> Option<String> {
    let (id, ctx) = cx.update(last_answer)?;
    in_main(cx, move |_, window, cx| {
        crate::views::chat::actions::run(ctx, RowCommand::ReadAloud, window, cx)
    })?;
    Some(id)
}

/// The transcript's marks: the sentence and word painted.
fn painted(cx: &mut App) -> Option<(i64, Option<i64>)> {
    let pane = pane(cx)?;
    let t = pane.read(cx).chat.as_ref()?.transcript.clone();
    t.read(cx).reading_painted()
}

fn words_found(cx: &mut App) -> usize {
    pane(cx)
        .and_then(|p| p.read(cx).chat.as_ref().map(|c| c.transcript.clone()))
        .map_or(0, |t| t.read(cx).reading_words())
}

async fn set_engine(engine: &str, cx: &mut AsyncApp) -> bool {
    let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());
    let saved = rpc
        .call::<methods::VoiceSaveSettings>(&VoiceSettingsEdit {
            tts_engine: Some(engine.into()),
            speed: Some(1.0),
            ..Default::default()
        })
        .await;
    saved.is_ok_and(|s| s.tts_engine == engine)
}

async fn wait_status(want: SpeechStatus, secs: u64, cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(secs), move |cx| status(cx) == want).await
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    cx.update(AnnouncementLog::install);
    let mut pass = sign_in(&url, &email, &password, cx).await;
    let Some((main, _)) = cx.update(main_window) else {
        return ok("main window", false);
    };
    pass &= ok("models.list answered", wait_models(cx).await);
    let (paused_words, resumed_words) = cx.update(|cx| {
        let l = cx.l10n().clone();
        (l.desktop_reading_paused(), l.desktop_reading_resumed())
    });
    let model = inputs.model();
    in_pane(cx, move |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.select_model(&model, cx))
    });
    pass &= ok(
        "the Mac's voices read aloud",
        set_engine("device", cx).await,
    );

    // ── An answer to read ──────────────────────────────────────────────
    let nav = cx.update(|cx| cx.global::<AppState>().stores.navigation.clone());
    nav.update(cx, |n, cx| n.new_chat(false, cx));
    settle(cx, 400).await;
    send("Please read aloud the harbour note.", cx).await;
    pass &= ok(
        "the answer came",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let stored = wait_until(cx, Duration::from_secs(30), |cx| {
        chat_store(cx).is_some_and(|s| !s.read(cx).chat_id().starts_with("local:"))
    })
    .await;
    pass &= ok("the chat is on the server", stored);
    let chat_id = cx
        .update(|cx| chat_store(cx).map(|s| s.read(cx).chat_id().to_string()))
        .unwrap_or_default();

    // ── On This Mac ────────────────────────────────────────────────────
    let answer = read_aloud(cx).await.unwrap_or_default();
    pass &= ok(
        "Read Aloud starts speaking",
        wait_status(SpeechStatus::Speaking, 20, cx).await,
    );
    let (p, sentences) = cx.update(|cx| {
        let s = speech(cx);
        let s = s.read(cx);
        (s.progress().clone(), s.sentences().to_vec())
    });
    pass &= ok(
        "the reading is of this answer in this chat",
        p.message_id.as_deref() == Some(answer.as_str())
            && p.chat_id.as_deref() == Some(chat_id.as_str()),
    );
    pass &= ok(
        "the Mac's voice reads live",
        p.engine == Some(SpeechEngine::Device) && p.words_reported && p.can_seek_sentences,
    );
    let four = wait_until(cx, Duration::from_secs(5), |cx| {
        speech(cx).read(cx).sentences().len() == 4
    })
    .await;
    pass &= ok(
        &format!("four sentences to read (got {})", sentences.len()),
        four,
    );
    let words = wait_until(cx, Duration::from_secs(10), |cx| {
        speech(cx)
            .read(cx)
            .progress()
            .word_start
            .is_some_and(|w| w > 0)
    })
    .await;
    pass &= ok("the voice reports the words it says", words);
    let marked = wait_until(cx, Duration::from_secs(5), |cx| {
        painted(cx).is_some_and(|(s, w)| s == 0 && w.is_some()) && words_found(cx) >= 30
    })
    .await;
    pass &= ok("the sentence and its word are marked in the answer", marked);
    let menu_on = cx.update(|cx| crate::menus::menu_state(cx).speaking);
    pass &= ok("Chat › Stop Speaking is on while it reads", menu_on);
    let title = crate::shell::now_playing::current_title();
    pass &= ok(
        &format!("Now Playing shows the reading ({title:?})"),
        title.is_some_and(|t| t.starts_with("The harbour lights")),
    );

    // The bar: its controls, as VoiceOver finds them.
    let controls = ax(main, "read-aloud-bar", dir, cx).await;
    for label in [
        "Previous Sentence",
        "Next Sentence",
        "Pause",
        "Stop Speaking",
        "Go to Sentence 3",
    ] {
        pass &= ok(
            &format!("the bar has {label}"),
            has(&controls, "Button", label),
        );
    }

    // The media keys' play/pause, as Now Playing hands it over.
    let s = cx.update(speech);
    let (paused0, resumed0) = (heard(&paused_words, cx), heard(&resumed_words, cx));
    s.update(cx, |s, cx| {
        s.remote(crate::stores::speech::RemoteCommand::TogglePause, cx)
    });
    pass &= ok(
        "the play/pause key pauses",
        wait_status(SpeechStatus::Paused, 10, cx).await,
    );
    pass &= ok(
        &format!("…and VoiceOver hears “{paused_words}” once"),
        wait_until(cx, Duration::from_secs(5), |cx| {
            AnnouncementLog::texts(cx)
                .iter()
                .filter(|t| t.as_ref() == paused_words)
                .count()
                == paused0 + 1
        })
        .await,
    );
    s.update(cx, |s, cx| {
        s.remote(crate::stores::speech::RemoteCommand::TogglePause, cx)
    });
    pass &= ok(
        "…and plays again",
        wait_status(SpeechStatus::Speaking, 10, cx).await,
    );
    pass &= ok(
        &format!("…and VoiceOver hears “{resumed_words}” once"),
        wait_until(cx, Duration::from_secs(5), |cx| {
            AnnouncementLog::texts(cx)
                .iter()
                .filter(|t| t.as_ref() == resumed_words)
                .count()
                == resumed0 + 1
        })
        .await,
    );

    // Pause, move on while paused, resume.
    let paused1 = heard(&paused_words, cx);
    s.update(cx, |s, cx| s.pause(cx));
    pass &= ok(
        "Pause pauses",
        wait_status(SpeechStatus::Paused, 10, cx).await,
    );
    // The bar's Pause is said as the media key's was; a second Pause on a
    // paused reading says nothing more.
    settle(cx, 300).await;
    s.update(cx, |s, cx| s.pause(cx));
    settle(cx, 600).await;
    let said_paused = heard(&paused_words, cx);
    pass &= ok(
        &format!("Pause is said once ({} time(s))", said_paused - paused1),
        said_paused == paused1 + 1,
    );
    shoot_main(dir, "read-aloud-paused", cx).await;
    let said = cx.update(|cx| speech(cx).read(cx).spoken.len());
    s.update(cx, |s, cx| s.skip(1, cx));
    let moved = wait_until(cx, Duration::from_secs(10), |cx| sentence(cx) == 1).await;
    pass &= ok("Next Sentence moves on while paused", moved);
    let still = cx.update(|cx| {
        status(cx) == SpeechStatus::Paused && speech(cx).read(cx).spoken.len() == said
    });
    pass &= ok("…and stays paused, saying nothing", still);
    s.update(cx, |s, cx| s.resume(cx));
    let resumed = wait_until(cx, Duration::from_secs(10), |cx| {
        status(cx) == SpeechStatus::Speaking
            && speech(cx)
                .read(cx)
                .spoken
                .last()
                .is_some_and(|(t, _)| t.starts_with("Gulls"))
    })
    .await;
    pass &= ok("Resume says the next sentence", resumed);
    pass &= ok(
        "…and VoiceOver hears that it resumed",
        heard(&resumed_words, cx) > resumed0 + 1,
    );

    // A click on a sentence's mark on the bar.
    crate::capture::drive::activate(main, cx);
    settle(cx, 300).await;
    let nodes = crate::capture::drive::nodes(main, cx).await;
    let mark = crate::capture::drive::find(&nodes, "Button", |l| l == "Go to Sentence 4")
        .and_then(|n| n.center());
    match mark {
        Some(at) => {
            crate::capture::drive::click(main, at, cx).await;
            // The pointer leaves, so the shots show no tooltip.
            crate::capture::drive::unhover(main, cx);
            let jumped = wait_until(cx, Duration::from_secs(10), |cx| {
                sentence(cx) == 3
                    && speech(cx)
                        .read(cx)
                        .spoken
                        .last()
                        .is_some_and(|(t, _)| t.starts_with("By morning"))
            })
            .await;
            pass &= ok("a click on a sentence's mark reads from it", jumped);
        }
        None => pass &= ok("the fourth sentence's mark is on screen", false),
    }

    // A new speed says the rest at the new rate.
    s.update(cx, |s, cx| s.skip(-2, cx));
    wait_until(cx, Duration::from_secs(10), |cx| sentence(cx) == 1).await;
    cx.update(|cx| {
        cx.dispatch_action(&crate::views::chat::speech_bar::SetSpeechSpeed { speed: 1.5 })
    });
    let faster = wait_until(cx, Duration::from_secs(10), |cx| {
        speech(cx)
            .read(cx)
            .spoken
            .last()
            .is_some_and(|(_, rate)| (*rate - 0.75).abs() < 0.01)
    })
    .await;
    pass &= ok("a new speed reaches the reading under way", faster);
    let speeds = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .app_settings
            .read(cx)
            .settings()
            .tts_speed
    });
    pass &= ok("…and is the setting", (speeds - 1.5).abs() < 0.01);
    shoot_main(dir, "read-aloud-speaking", cx).await;

    // Esc stops it.
    super::press(main, "escape", cx);
    pass &= ok(
        "Esc stops the reading",
        wait_status(SpeechStatus::Idle, 10, cx).await,
    );
    let cleared = wait_until(cx, Duration::from_secs(5), |cx| painted(cx).is_none()).await;
    pass &= ok("…and its marks go", cleared);

    // Chat › Read Aloud (⌥⌘R) and ⌘.
    super::press(main, "alt-cmd-r", cx);
    pass &= ok(
        "⌥⌘R reads the last answer",
        wait_status(SpeechStatus::Speaking, 20, cx).await,
    );
    super::press(main, "cmd-.", cx);
    pass &= ok("⌘. stops it", wait_status(SpeechStatus::Idle, 10, cx).await);
    let menu_off = cx.update(|cx| !crate::menus::menu_state(cx).speaking);
    pass &= ok("Chat › Stop Speaking is off again", menu_off);
    pass &= ok(
        "Now Playing lets go",
        crate::shell::now_playing::current_title().is_none(),
    );

    pass &= with_dictation(main, dir, cx).await;

    // Another chat opens: the reading pauses.
    read_aloud(cx).await;
    wait_status(SpeechStatus::Speaking, 20, cx).await;
    nav.update(cx, |n, cx| n.new_chat(false, cx));
    pass &= ok(
        "the reading pauses when another chat opens",
        wait_status(SpeechStatus::Paused, 10, cx).await,
    );
    s.update(cx, |s, cx| s.stop(cx));
    wait_status(SpeechStatus::Idle, 10, cx).await;

    // Settings' Preview, through the same engine: its button says Stop
    // Speaking while it reads.
    const SAMPLE: &str = "This is how I sound when I read your answers aloud, \
                          one sentence at a time, at the speed you choose.";
    s.update(cx, |s, cx| s.preview(SAMPLE.into(), cx));
    let previewing = wait_until(cx, Duration::from_secs(10), |cx| {
        speech(cx)
            .read(cx)
            .spoken
            .last()
            .is_some_and(|(t, _)| t.starts_with("This is how I sound"))
    })
    .await;
    pass &= ok("Preview speaks with the chosen voice", previewing);
    let shown =
        cx.update(|cx| speech(cx).read(cx).progress().message_id.as_deref() == Some("tts_preview"));
    pass &= ok("…as the preview, with no chat", shown);
    // Held, so it is still the preview being read when Settings is shot.
    s.update(cx, |s, cx| s.pause(cx));
    wait_status(SpeechStatus::Paused, 10, cx).await;
    if let Some(handle) = super::settings_tab(
        crate::views::settings::Tab::Audio,
        dir,
        "read-aloud-preview",
        cx,
    )
    .await
    {
        let controls = ax(handle, "read-aloud-preview", dir, cx).await;
        pass &= ok(
            "Settings › Audio's Preview says Stop Speaking while it reads",
            has(&controls, "Button", "Stop Speaking"),
        );
        cx.update(|cx| {
            let _ = handle.update(cx, |_, window, _| window.remove_window());
        });
    }
    s.update(cx, |s, cx| s.stop(cx));
    wait_status(SpeechStatus::Idle, 10, cx).await;

    // ── The server's speech ────────────────────────────────────────────
    pass &= ok("the server reads aloud", set_engine("server", cx).await);
    let opened = {
        let id = chat_id.clone();
        nav.update(cx, |n, cx| n.open(id, cx));
        let want = chat_id.clone();
        wait_until(cx, Duration::from_secs(30), move |cx| {
            chat_store(cx).is_some_and(|s| {
                let s = s.read(cx);
                s.chat_id() == want && s.detail.is_some() && !s.loading
            })
        })
        .await
    };
    pass &= ok("the chat opens again", opened);
    read_aloud(cx).await;
    let playing = wait_until(cx, Duration::from_secs(30), |cx| {
        let s = speech(cx);
        let p = s.read(cx).progress();
        p.status == SpeechStatus::Speaking && p.engine == Some(SpeechEngine::Server)
    })
    .await;
    pass &= ok("the server's speech plays", playing);
    let fetched = wait_until(cx, Duration::from_secs(20), |cx| {
        let s = speech(cx);
        let s = s.read(cx);
        s.fetched >= 4 && s.progress().can_seek && s.progress().duration_ms > 0
    })
    .await;
    pass &= ok(
        "every sentence came from /tts/{job}, and the length is known",
        fetched,
    );
    let ticking = {
        let before = cx.update(|cx| speech(cx).read(cx).progress().elapsed_ms);
        settle(cx, 1200).await;
        cx.update(|cx| speech(cx).read(cx).progress().elapsed_ms) > before
    };
    pass &= ok("the time moves on", ticking);
    let word = wait_until(cx, Duration::from_secs(5), |cx| {
        speech(cx).read(cx).progress().word_start.is_some()
    })
    .await;
    pass &= ok("the word is estimated from the position", word);
    s.update(cx, |s, cx| s.seek_sentence(2, cx));
    pass &= ok(
        "the server's reading moves to a sentence",
        wait_until(cx, Duration::from_secs(10), |cx| sentence(cx) == 2).await,
    );
    s.update(cx, |s, cx| s.pause(cx));
    pass &= ok(
        "the server's reading pauses",
        wait_status(SpeechStatus::Paused, 10, cx).await,
    );
    shoot_main(dir, "read-aloud-server", cx).await;
    s.update(cx, |s, cx| s.stop(cx));
    pass &= ok(
        "the server's reading stops",
        wait_status(SpeechStatus::Idle, 10, cx).await,
    );

    // ── Clean up ───────────────────────────────────────────────────────
    set_engine("device", cx).await;
    let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());
    let _ = rpc
        .call::<methods::ChatsDelete>(&ChatRef { id: chat_id })
        .await;
    pass
}

/// Dictation and read aloud take turns: the microphone would hear the
/// voice. The server's engine, with a spoken file for the microphone.
async fn with_dictation(main: AnyWindowHandle, dir: &Path, cx: &mut AsyncApp) -> bool {
    use super::dictation::{
        idle, listening, save_voice, set_input, set_settings, speak_to, toggle,
    };
    use crate::voice::InputOverride;
    let wav = dir.join("dictation.wav");
    let mut pass = ok(
        "say wrote a stand-in recording",
        speak_to(
            &wav,
            "Bring the blue kayak to the north landing before lunch, then fold the sails \
             and hang the wet ropes in the boathouse to dry overnight.",
        ),
    );
    set_settings(
        conduit_protocol::AppSettingsPatch {
            stt_preference: Some("serverOnly".into()),
            ..Default::default()
        },
        cx,
    )
    .await;
    pass &= ok(
        "dictation on the server's engine",
        save_voice(
            VoiceSettingsEdit {
                stt_engine: Some("server".into()),
                ..Default::default()
            },
            cx,
        )
        .await,
    );
    read_aloud(cx).await;
    pass &= ok(
        "a reading under way",
        wait_status(SpeechStatus::Speaking, 20, cx).await,
    );
    let paused_words = cx.update(|cx| cx.l10n().desktop_reading_paused());
    let paused_before = heard(&paused_words, cx);
    set_input(Some(InputOverride::File(wav.clone())), cx);
    toggle(cx);
    pass &= ok(
        "dictating pauses the reading",
        wait_status(SpeechStatus::Paused, 10, cx).await,
    );
    settle(cx, 500).await;
    pass &= ok(
        "…without a word to VoiceOver (the microphone would hear it)",
        heard(&paused_words, cx) == paused_before,
    );
    let heard = wait_until(cx, Duration::from_secs(10), listening).await;
    settle(cx, 800).await;
    super::press(main, "escape", cx);
    let cancelled = wait_until(cx, Duration::from_secs(10), idle).await;
    settle(cx, 500).await;
    pass &= ok(
        "Esc cancels the dictation first; the reading stays paused",
        heard && cancelled && cx.update(status) == SpeechStatus::Paused,
    );
    // Dictating again, then Play on the bar: the reading goes on, and the
    // dictation ends as Stop does (its words are transcribed).
    set_input(Some(InputOverride::File(wav)), cx);
    toggle(cx);
    let again = wait_until(cx, Duration::from_secs(10), listening).await;
    cx.update(|cx| speech(cx).update(cx, |s, cx| s.toggle_pause(cx)));
    let ended = wait_until(cx, Duration::from_secs(30), idle).await;
    pass &= ok(
        "a reading that goes on ends the dictation",
        again && ended && wait_status(SpeechStatus::Speaking, 10, cx).await,
    );
    set_input(None, cx);
    cx.update(|cx| speech(cx).update(cx, |s, cx| s.stop(cx)));
    wait_status(SpeechStatus::Idle, 10, cx).await;
    // The composer's text from that dictation goes.
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.set_text("", window, cx))
    });
    // Outside a call, a reading plays as it always did: never on a call's
    // engine.
    pass &= ok(
        "a reading outside a call is not said on a call's engine",
        crate::voice::call_audio::said_on_calls() == 0
            && crate::voice::call_audio::current().is_none(),
    );
    pass
}
