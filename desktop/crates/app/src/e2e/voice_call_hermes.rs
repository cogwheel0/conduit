//! `--e2e voice-call-hermes`: a Hermes GPT-Live voice call, over the
//! real daemon, on a real local Hermes Desktop Gateway (`hermes serve`)
//! whose GPT-Live vendor is faked (`tool/local_hermes_live`): the gateway
//! exchanges the app's WebRTC offer at the fake vendor, whose peer page
//! (WebKit, in a process of its own) answers it, plays a tone as the voice,
//! measures what it hears, and speaks GPT-Live's data-channel events. The
//! env file (`--e2e-env`) names the gateway (`HERMES_DESKTOP_URL`,
//! `HERMES_DESKTOP_TOKEN`), the vendor (`GPT_LIVE_URL`) and its TURN relay
//! on 127.0.0.1 (`GPT_LIVE_TURN_URL`, `_USER`, `_CREDENTIAL`).
//!
//! The app's page hears a stand-in tone (never the Mac's microphone, which
//! is never asked for) and plays the voice into nothing. Both pages use only
//! the loopback relay: no packet of the call reaches the local network, no
//! mDNS name is registered, and macOS never asks for Local Network access
//! (checked: the offer has relay candidates only, and every relay client
//! is 127.0.0.1).
//!
//! * The Hermes chat's call is Realtime (the core admits GPT-Live). The
//!   page is a secure context with WebRTC and `getUserMedia`, on screen
//!   (invisibly) while the microphone opens and off screen after.
//! * The gateway asked for GPT-Live with client delegation, and the offer
//!   reached the vendor exactly as the page wrote it.
//! * The connection is up, the data channel open, and audio flows both
//!   ways, measured at both ends; the call's meter moves.
//! * The user's words and the voice's reply show in the strip; the request
//!   the voice hands over runs as a turn in the Hermes chat, and its answer
//!   goes back for the voice to say.
//! * Mute silences what the voice hears and tells it; unmute; pause; Stop
//!   Speaking tells the voice to stop.
//! * End Call closes the session (the voice confirms), the page and its
//!   window; a second call opens a page of its own.
//! * With the Hermes model as the default model, the widget's Voice Call
//!   (`conduit://call`) and Shortcuts' Start Voice Call each start a
//!   GPT-Live call in a new chat, through `CallStore::start` as from the
//!   chat.
//!
//! Each state is shot in light and dark.

use std::path::Path;
use std::time::Duration;

use conduit_protocol::{AppSettingsPatch, CallMode, CallPhase, HermesSettingsEdit, methods};
use gpui_kit::{App, AsyncApp, Entity};
use serde_json::Value;

use super::chat::{chat_store, in_pane};
use super::composer::new_chat;
use super::dictation::set_settings;
use super::*;
use crate::stores::call::CallStore;
use crate::stores::chat::Role as MessageRole;
use crate::voice::InputOverride;

/// What the fake voice hears the user say, says, and is answered (the
/// gateway's scripted model; all invented).
const USER_WORDS: &str = "harbour opening hours";
const VOICE_WORDS: &str = "Let me check with the chat.";
const ANSWER: &str = "opens at eight";

fn call(cx: &mut App) -> Entity<CallStore> {
    cx.global::<AppState>().stores.call.clone()
}

fn phase(cx: &mut App) -> CallPhase {
    call(cx).read(cx).state().phase
}

fn says(cx: &mut App, role: MessageRole, text: &str) -> bool {
    let Some(store) = chat_store(cx) else {
        return false;
    };
    let s = store.read(cx);
    s.rows()
        .iter()
        .filter_map(|r| s.item(*r))
        .any(|i| i.role == role && i.text.contains(text))
}

/// A steady tone as 16 kHz mono 16-bit WAV: the microphone's stand-in.
fn write_tone(path: &Path, hz: f32, seconds: f32) -> bool {
    let rate = crate::voice::pcm::RATE as f32;
    let count = (rate * seconds) as usize;
    let mut pcm = Vec::with_capacity(count * 2);
    for i in 0..count {
        let t = i as f32 / rate;
        let sample = (0.3 * (std::f32::consts::TAU * hz * t).sin() * f32::from(i16::MAX)) as i16;
        pcm.extend_from_slice(&sample.to_le_bytes());
    }
    std::fs::write(path, crate::voice::pcm::wav(&pcm)).is_ok()
}

/// The fake vendor's `/stats`: its sessions, what its peer heard (`peer`)
/// and the events it got (`events`).
async fn vendor(live: &str, cx: &mut AsyncApp) -> Value {
    let url = format!("{}/stats", live.trim_end_matches('/'));
    cx.background_executor()
        .spawn(async move { super::direct::http_request("GET", &url, None, None) })
        .await
        .and_then(|(status, body)| (status == 200).then_some(body))
        .and_then(|body| serde_json::from_str(&body).ok())
        .unwrap_or_default()
}

/// Waits until the vendor's stats satisfy `done`; the last ones read.
async fn wait_vendor(
    live: &str,
    secs: u64,
    done: impl Fn(&Value) -> bool,
    cx: &mut AsyncApp,
) -> (bool, Value) {
    wait_vendor_steady(live, secs, 1, done, cx).await
}

/// Waits until the vendor's stats satisfy `done` `times` reads in a row
/// (250 ms apart): silence that lasts, not a dip.
async fn wait_vendor_steady(
    live: &str,
    secs: u64,
    times: usize,
    done: impl Fn(&Value) -> bool,
    cx: &mut AsyncApp,
) -> (bool, Value) {
    let deadline = std::time::Instant::now() + Duration::from_secs(secs);
    let mut run = 0;
    loop {
        let stats = vendor(live, cx).await;
        run = if done(&stats) { run + 1 } else { 0 };
        if run >= times {
            return (true, stats);
        }
        if std::time::Instant::now() > deadline {
            return (false, stats);
        }
        settle(cx, 250).await;
    }
}

fn events<'a>(stats: &'a Value, kind: &'a str) -> impl Iterator<Item = &'a Value> + 'a {
    stats["events"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(move |e| e["kind"] == kind)
}

fn heard(stats: &Value) -> f64 {
    stats["peer"]["heard"].as_f64().unwrap_or(0.0)
}

async fn wait_phase(want: CallPhase, secs: u64, cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(secs), move |cx| phase(cx) == want).await
}

/// Every state the call goes through from now on, and its loudest meter.
fn record(cx: &mut AsyncApp) -> std::rc::Rc<std::cell::RefCell<(Vec<CallPhase>, f64)>> {
    let seen = std::rc::Rc::new(std::cell::RefCell::new((Vec::<CallPhase>::new(), 0.0_f64)));
    let sink = seen.clone();
    cx.update(|cx| {
        let store = call(cx);
        cx.subscribe(
            &store,
            move |store, _: &crate::stores::call::CallChanged, cx| {
                let state = store.read(cx).state();
                let mut seen = sink.borrow_mut();
                if seen.0.last() != Some(&state.phase) {
                    seen.0.push(state.phase);
                }
                seen.1 = seen.1.max(state.level);
            },
        )
        .detach();
    });
    seen
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let (Some(url), Some(token), Some(live), Some(turn), Some(user), Some(credential)) = (
        inputs.get("HERMES_DESKTOP_URL"),
        inputs.get("HERMES_DESKTOP_TOKEN"),
        inputs.get("GPT_LIVE_URL"),
        inputs.get("GPT_LIVE_TURN_URL"),
        inputs.get("GPT_LIVE_TURN_USER"),
        inputs.get("GPT_LIVE_TURN_CREDENTIAL"),
    ) else {
        return ok(
            "the env file names the Hermes gateway, the fake GPT-Live and its loopback relay",
            false,
        );
    };
    let relay = crate::voice::peer::Relay {
        url: turn,
        username: user,
        credential,
    };
    if !relay.is_loopback() {
        return ok("the test relay is on 127.0.0.1", false);
    }
    let mut pass = fresh_profile(cx).await;
    // Never the Mac's microphone: a stand-in tone from the start.
    let tone = dir.join("call-tone.wav");
    pass &= ok(
        "a stand-in tone for the microphone",
        write_tone(&tone, 440.0, 2.0),
    );
    cx.update(|cx| {
        call(cx).update(cx, |c, cx| {
            c.set_input(Some(InputOverride::File(tone.clone())), cx);
            c.set_test_relay(Some(relay.clone()));
        })
    });

    // Hermes Desktop Gateway, with the gateway's legacy session token.
    let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());
    let saved = rpc
        .call::<methods::HermesSaveSettings>(&HermesSettingsEdit {
            enabled: true,
            base_url: url,
            mode: "desktop".into(),
            api_key: None,
            session_key: None,
            desktop_profile: "default".into(),
            desktop_auth_kind: "legacyToken".into(),
            legacy_token: Some(token),
            allow_self_signed_certificates: false,
            onboarding: true,
        })
        .await;
    pass &= ok("Hermes Desktop Gateway saved", saved.is_ok());
    pass &= wait_route(cx, Route::Main, Duration::from_secs(60)).await;
    let Some(main) = wait_main(cx).await else {
        return ok("the main window opened", false);
    };
    settle(cx, 1500).await;
    // Settings › Audio: Realtime when the backend offers it.
    set_settings(
        AppSettingsPatch {
            voice_call_mode: Some("auto".into()),
            ..Default::default()
        },
        cx,
    )
    .await;
    new_chat(cx).await;
    let ready = wait_until(cx, Duration::from_secs(30), |cx| {
        main_window(cx).is_some_and(|(_, mw)| {
            let composer = mw.read(cx).chat_pane.read(cx).composer.clone();
            composer.read(cx).call_ready
        })
    })
    .await;
    pass &= ok("a Hermes chat offers a voice call", ready);

    // ── A GPT-Live call ────────────────────────────────────────────────
    let seen = record(cx);
    in_pane(cx, |p, _, cx| p.start_call(cx));
    if wait_phase(CallPhase::Starting, 3, cx).await {
        shoot_main(dir, "call-hermes-connecting", cx).await;
    }
    let live_call = wait_until(cx, Duration::from_secs(60), |cx| {
        let state = call(cx).read(cx).state().clone();
        state.mode == Some(CallMode::Realtime)
            && matches!(
                state.phase,
                CallPhase::Listening | CallPhase::Speaking | CallPhase::Sending
            )
    })
    .await;
    let state = cx.update(|cx| call(cx).read(cx).state().clone());
    pass &= ok(
        &format!(
            "the Hermes chat's call is a realtime one ({:?}, {:?}, {:?}, {:?}, model {:?})",
            state.phase, state.mode, state.standard_reason, state.error, state.model_id
        ),
        live_call,
    );
    if !live_call {
        let stats = cx.update(|cx| format!("{:?}", call(cx).read(cx).peer_stats));
        log::warn!("e2e: peer {stats}");
        log::warn!("e2e: vendor {}", vendor(&live, cx).await);
        cx.update(|cx| call(cx).update(cx, |c, cx| c.end(cx)));
        return false;
    }
    let peer = cx.update(|cx| call(cx).read(cx).peer_stats.clone());
    let ready = peer.ready.clone().unwrap_or_default();
    pass &= ok(
        &format!(
            "the call's page is a secure context with WebRTC and the microphone's API ({ready})"
        ),
        ready["secure"] == true
            && ready["webrtc"] == true
            && ready["getUserMedia"] == true
            && ready["worklet"] == true,
    );
    pass &= ok(
        &format!(
            "the page was on screen while the microphone opened ({:?}), and is off screen now",
            peer.offer_visible
        ),
        peer.offer_visible.as_deref() == Some("visible")
            && cx.update(|cx| call(cx).read(cx).peer_on_screen()) == Some(false),
    );
    let stats = vendor(&live, cx).await;
    let session = &stats["sessions"][0];
    pass &= ok(
        &format!("the gateway opened GPT-Live with client delegation ({session})"),
        session["model"] == "gpt-live-1"
            && session["voice"] == "marin"
            && session["delegation"] == "client",
    );
    pass &= ok(
        "the offer reached the vendor as the page wrote it: audio, the data channel, the closing CRLF",
        session["offerHasAudio"] == true
            && session["offerHasData"] == true
            && session["offerEndsWithCrlf"] == true,
    );
    let candidates = &session["candidates"];
    pass &= ok(
        &format!(
            "the offer's candidates are the loopback relay's only: no host or mDNS one ({candidates}, mDNS {})",
            session["mdnsCandidates"]
        ),
        candidates["relay"].as_u64().unwrap_or(0) > 0
            && candidates["host"] == 0
            && candidates["srflx"] == 0
            && session["mdnsCandidates"] == 0,
    );
    // The running page's own media policy: its microphone, never a camera.
    let media = cx.update(|cx| {
        use crate::shell::web_media::{CAMERA, MICROPHONE, mac::ask};
        let host = call(cx).read(cx).peer_host()?;
        let webview = host.webview()?;
        let scheme = crate::voice::peer::SCHEME;
        Some((
            ask(webview, scheme, true, MICROPHONE),
            ask(webview, scheme, true, CAMERA),
            ask(webview, "https", true, MICROPHONE),
        ))
    });
    pass &= ok(
        &format!(
            "the call page may use the microphone, never the camera, nor another origin ({media:?})"
        ),
        media == Some((Some(1), Some(2), Some(2))),
    );
    let switches = cx.update(|cx| call(cx).read(cx).peer_stats.switches.clone());
    pass &= ok(
        &format!("the hidden page is never suspended ({switches:?})"),
        switches.contains(&"_setPageVisibilityBasedProcessSuppressionEnabled:")
            && switches.contains(&"_setICECandidateFilteringEnabled:"),
    );
    let connected = wait_until(cx, Duration::from_secs(20), |cx| {
        let p = &call(cx).read(cx).peer_stats;
        p.states.iter().any(|s| s == "connected") && p.channel_open && p.received > 0
    })
    .await;
    pass &= ok(
        "the connection is up, the data channel open, the voice's events arriving",
        connected,
    );
    settle(cx, 500).await;
    let controls = ax(main, "call-hermes-listening", dir, cx).await;
    pass &= ok(
        "the strip offers Mute and End Call",
        has(&controls, "Button", "Mute") && has(&controls, "Button", "End Call"),
    );
    shoot_main(dir, "call-hermes-listening", cx).await;

    // ── Audio both ways ────────────────────────────────────────────────
    let (heard_app, stats) = wait_vendor(
        &live,
        20,
        |s| s["peer"]["heardPeak"].as_f64().unwrap_or(0.0) > 0.02,
        cx,
    )
    .await;
    pass &= ok(
        &format!(
            "the voice hears the app's microphone (peak {:.3})",
            stats["peer"]["heardPeak"].as_f64().unwrap_or(0.0)
        ),
        heard_app,
    );
    let app_heard = wait_until(cx, Duration::from_secs(20), |cx| {
        let p = &call(cx).read(cx).peer_stats;
        p.output_peak > 0.02 && p.input_peak > 0.02 && p.bytes_sent > 0 && p.bytes_received > 0
    })
    .await;
    let peer = cx.update(|cx| call(cx).read(cx).peer_stats.clone());
    pass &= ok(
        &format!(
            "the app hears the voice (peak {:.3}) and its own microphone (peak {:.3}); {} bytes out, {} in",
            peer.output_peak, peer.input_peak, peer.bytes_sent, peer.bytes_received
        ),
        app_heard,
    );
    pass &= ok(
        &format!("the call's meter moves ({:.2})", seen.borrow().1),
        wait_until(cx, Duration::from_secs(10), {
            let seen = seen.clone();
            move |_| seen.borrow().1 > 0.1
        })
        .await,
    );

    // ── What is said, and the request handed to the chat ───────────────
    let captions = wait_until(cx, Duration::from_secs(30), |cx| {
        let state = call(cx).read(cx).state().clone();
        state.transcript.contains(USER_WORDS) && state.reply.contains(VOICE_WORDS)
    })
    .await;
    pass &= ok(
        "the strip says the user's words and the voice's reply",
        captions,
    );
    let thinking = wait_phase(CallPhase::Sending, 20, cx).await;
    if thinking {
        shoot_main(dir, "call-hermes-thinking", cx).await;
    }
    pass &= ok(
        "the request went to the chat: Thinking…",
        thinking || seen.borrow().0.contains(&CallPhase::Sending),
    );
    pass &= ok(
        "the request ran as a turn in the Hermes chat, and was answered",
        wait_until(cx, Duration::from_secs(90), |cx| {
            says(cx, MessageRole::User, USER_WORDS) && says(cx, MessageRole::Assistant, ANSWER)
        })
        .await,
    );
    let (handed_back, stats) = wait_vendor(
        &live,
        30,
        |s| {
            events(s, "session.commentary.append")
                .any(|e| e["content"].as_str().is_some_and(|c| c.contains(ANSWER)))
        },
        cx,
    )
    .await;
    pass &= ok(
        "the chat's answer went back to the voice to say, after a word that it works on it",
        handed_back
            && events(&stats, "session.thinking.append").count() > 0
            && events(&stats, "delegated").count() == 1,
    );
    // The voice says the answer word by word: Speaking, with its words.
    let saying = wait_until(cx, Duration::from_secs(20), |cx| {
        let state = call(cx).read(cx).state().clone();
        state.phase == CallPhase::Speaking && state.reply.contains("harbour office")
    })
    .await;
    if saying {
        shoot_main(dir, "call-hermes-speaking", cx).await;
    }
    pass &= ok(
        "the voice says the answer",
        saying
            && wait_until(cx, Duration::from_secs(20), |cx| {
                call(cx).read(cx).state().reply.contains(ANSWER)
            })
            .await,
    );

    // ── Mute and unmute ────────────────────────────────────────────────
    cx.update(|cx| call(cx).update(cx, |c, cx| c.toggle_mute(cx)));
    let muted = wait_until(cx, Duration::from_secs(10), |cx| {
        let c = call(cx);
        let c = c.read(cx);
        c.state().muted && !c.peer_stats.microphone_on
    })
    .await;
    pass &= ok(
        "Mute: the call is muted and the page's microphone off",
        muted,
    );
    let (quiet, stats) = wait_vendor_steady(
        &live,
        15,
        4,
        |s| events(s, "session.input_audio.mute").count() == 1 && heard(s) < 0.003,
        cx,
    )
    .await;
    pass &= ok(
        &format!(
            "the voice was told, and hears nothing ({:.4})",
            heard(&stats)
        ),
        quiet,
    );
    if muted {
        shoot_main(dir, "call-hermes-muted", cx).await;
    }
    cx.update(|cx| call(cx).update(cx, |c, cx| c.toggle_mute(cx)));
    let (back, stats) = wait_vendor(
        &live,
        15,
        |s| events(s, "session.input_audio.unmute").count() == 1 && heard(s) > 0.02,
        cx,
    )
    .await;
    pass &= ok(
        &format!(
            "Unmute: the voice hears the app again ({:.3})",
            heard(&stats)
        ),
        back && cx.update(|cx| !call(cx).read(cx).state().muted),
    );

    // ── Pause, and Stop Speaking ───────────────────────────────────────
    let instructions = events(&stats, "session.instructions.append").count();
    let can_pause = cx.update(|cx| call(cx).read(cx).state().can_pause);
    pass &= ok("the realtime call can be paused", can_pause);
    cx.update(|cx| call(cx).update(cx, |c, cx| c.toggle_pause(cx)));
    let paused = wait_until(cx, Duration::from_secs(10), |cx| {
        let state = call(cx).read(cx).state().clone();
        state.muted && state.can_resume
    })
    .await;
    let (told, stats) = wait_vendor(
        &live,
        10,
        |s| {
            events(s, "session.instructions.append").count() > instructions
                && events(s, "session.input_audio.mute").count() == 2
        },
        cx,
    )
    .await;
    pass &= ok(
        "Pause: the voice is told to stop and the microphone goes quiet",
        paused && told,
    );
    if paused {
        shoot_main(dir, "call-hermes-paused", cx).await;
    }
    // Unmuting ends the pause too, as on the phone.
    cx.update(|cx| call(cx).update(cx, |c, cx| c.toggle_mute(cx)));
    pass &= ok(
        "the call is back",
        wait_until(cx, Duration::from_secs(10), |cx| {
            let state = call(cx).read(cx).state().clone();
            !state.muted && crate::stores::call::is_active(state.phase)
        })
        .await,
    );
    let instructions = events(&stats, "session.instructions.append").count();
    cx.update(|cx| call(cx).update(cx, |c, cx| c.skip(cx)));
    let (stopped, _) = wait_vendor(
        &live,
        10,
        |s| events(s, "session.instructions.append").count() > instructions,
        cx,
    )
    .await;
    pass &= ok("Stop Speaking tells the voice to stop", stopped);

    // ── End Call ───────────────────────────────────────────────────────
    cx.update(|cx| call(cx).update(cx, |c, cx| c.end(cx)));
    let ended = wait_until(cx, Duration::from_secs(20), |cx| {
        let c = call(cx);
        let c = c.read(cx);
        !c.is_active() && !c.has_peer()
    })
    .await;
    pass &= ok("End Call ends the call and closes its page", ended);
    pass &= ok(
        "the call ended plainly",
        cx.update(|cx| phase(cx) == CallPhase::Ended),
    );
    let (closed, _) = wait_vendor(
        &live,
        10,
        |s| events(s, "session.close").count() == 1 && events(s, "closed").count() == 1,
        cx,
    )
    .await;
    pass &= ok("the session was closed with the voice", closed);
    pass &= ok(
        "the chat keeps the request and its answer",
        cx.update(|cx| says(cx, MessageRole::Assistant, ANSWER)),
    );

    // ── A second call opens a page of its own ──────────────────────────
    in_pane(cx, |p, _, cx| p.start_call(cx));
    let again = wait_until(cx, Duration::from_secs(60), |cx| {
        let c = call(cx);
        let c = c.read(cx);
        c.state().mode == Some(CallMode::Realtime)
            && c.has_peer()
            && c.peer_stats.opened == 2
            && matches!(c.state().phase, CallPhase::Listening | CallPhase::Speaking)
    })
    .await;
    let state = cx.update(|cx| call(cx).read(cx).state().clone());
    pass &= ok(
        &format!(
            "a second call opens its own page and goes live ({:?}, {:?}, {:?}, {:?}, model {:?})",
            state.phase, state.mode, state.standard_reason, state.error, state.model_id
        ),
        again,
    );
    cx.update(|cx| call(cx).update(cx, |c, cx| c.end(cx)));
    let gone = wait_until(cx, Duration::from_secs(20), |cx| {
        let c = call(cx);
        let c = c.read(cx);
        !c.is_active() && !c.has_peer() && c.peer_stats.closed == 2
    })
    .await;
    pass &= ok("and its page goes with it", gone);
    let stats = vendor(&live, cx).await;
    pass &= ok(
        "the gateway opened one GPT-Live session per call",
        stats["sessions"].as_array().is_some_and(|s| s.len() == 2),
    );
    let turn = &stats["turn"];
    let sources: Vec<&str> = turn["sources"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    pass &= ok(
        &format!(
            "every packet went through the relay on loopback ({} relayed, clients {sources:?}, {} refused)",
            turn["relayed"], turn["refused"]
        ),
        turn["relayed"].as_u64().unwrap_or(0) > 100
            && turn["refused"] == 0
            && sources.len() >= 4
            && sources.iter().all(|s| s.starts_with("127.0.0.1:")),
    );

    // ── From outside the chat, with Hermes as the default model ────────
    let Some(model) = state.model_id.clone() else {
        return ok("the Hermes call named its model", false);
    };
    set_settings(
        AppSettingsPatch {
            default_model: Some(model.clone()),
            ..Default::default()
        },
        cx,
    )
    .await;
    for (n, what) in [
        "the widget's Voice Call (conduit://call)",
        "Shortcuts' Start Voice Call",
    ]
    .into_iter()
    .enumerate()
    {
        let opened = cx.update(|cx| call(cx).read(cx).peer_stats.opened);
        let outcome = if n == 0 {
            super::shell::links(&["conduit://call"], cx);
            None
        } else {
            Some(super::intents::step(serde_json::json!({ "intent": "startVoiceCall" })).await)
        };
        let live = wait_until(cx, Duration::from_secs(60), |cx| {
            let c = call(cx);
            let c = c.read(cx);
            c.state().mode == Some(CallMode::Realtime)
                && c.has_peer()
                && c.peer_stats.opened > opened
                && matches!(c.state().phase, CallPhase::Listening | CallPhase::Speaking)
        })
        .await;
        let state = cx.update(|cx| call(cx).read(cx).state().clone());
        pass &= ok(
            &format!(
                "{what} starts a GPT-Live call with the default Hermes model ({:?}, {:?}, model {:?}{})",
                state.phase,
                state.mode,
                state.model_id,
                outcome
                    .as_ref()
                    .map(|o| format!(", {}", super::intents::brief(o)))
                    .unwrap_or_default()
            ),
            live && state.model_id.as_deref() == Some(model.as_str())
                && outcome.as_ref().is_none_or(super::intents::succeeded),
        );
        if live {
            shoot_main(dir, &format!("call-hermes-outside-{n}"), cx).await;
        }
        cx.update(|cx| call(cx).update(cx, |c, cx| c.end(cx)));
        let gone = wait_until(cx, Duration::from_secs(20), |cx| {
            let c = call(cx);
            let c = c.read(cx);
            !c.is_active() && !c.has_peer()
        })
        .await;
        pass &= ok("…and it ends, its page closed", gone);
    }
    pass
}
