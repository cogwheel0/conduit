//! `--e2e intents`: the Shortcuts actions (App Intents) on the local Open
//! WebUI and its fake model. Shortcuts itself can't be driven from a test,
//! so the Swift intents' own `perform()` and their chat query run in this
//! process ([`crate::intents::self_test`]), the way the App Intents runtime
//! calls them, and each answer and what the app did is checked:
//!
//! * before sign-in, Ask Conduit says to sign in first;
//! * every type the bundle's `Metadata.appintents` names is in the binary;
//! * Ask Conduit answers as text (the reasoning left out, as Copy leaves
//!   it), leaves the main window as it was, and with Open in Conduit shows
//!   the chat; an empty question says what is missing;
//! * Open Chat's list: recent chats, a search, and saved ids (a deleted one
//!   left out); Open Chat opens one and says when one is gone;
//! * New Chat fills a new chat's message box without sending;
//! * Show Quick Ask, with and without text;
//! * Start Voice Call starts a call in a new chat (a quiet stand-in for
//!   the microphone first), and a second one leaves that call on.

use std::path::Path;
use std::time::Duration;

use gpui_kit::{App, AsyncApp};
use serde_json::{Value, json};

use super::chat::{chat_store, in_pane, pane, sign_in, wait_models};
use super::*;
use crate::desktop;
use crate::l10n::ActiveL10n as _;
use crate::stores::navigation::Selection;

/// An id no chat has.
const GONE: &str = "intent-chat-that-is-gone";

fn selection(cx: &mut App) -> Selection {
    cx.global::<AppState>()
        .stores
        .navigation
        .read(cx)
        .selection()
        .clone()
}

fn composer_text(cx: &mut App) -> String {
    pane(cx)
        .map(|p| {
            let c = p.read(cx).composer.clone();
            c.read(cx).text(cx)
        })
        .unwrap_or_default()
}

fn quick_ask_text(cx: &mut App) -> Option<String> {
    let (_, view) = cx.try_global::<desktop::Desktop>()?.quick_ask.clone()?;
    let composer = view.read(cx).composer.clone();
    Some(composer.read(cx).text(cx))
}

/// Runs one intent or query, as the App Intents runtime would.
pub(super) async fn step(step: Value) -> Value {
    crate::intents::self_test(&json!({ "steps": [step] }))
        .await
        .and_then(|out| out.get(0).cloned())
        .unwrap_or(Value::Null)
}

pub(super) fn succeeded(out: &Value) -> bool {
    out["ok"].as_bool() == Some(true)
}

fn error_is(out: &Value, words: &str) -> bool {
    out["ok"].as_bool() == Some(false) && out["error"].as_str() == Some(words)
}

fn chats_of(out: &Value) -> Vec<(String, String)> {
    out["chats"]
        .as_array()
        .map(|chats| {
            chats
                .iter()
                .map(|c| {
                    (
                        c["id"].as_str().unwrap_or_default().to_string(),
                        c["title"].as_str().unwrap_or_default().to_string(),
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

/// A short form of an outcome for the log: never the answer itself.
pub(super) fn brief(out: &Value) -> String {
    format!(
        "ok={} error={:?} chats={}",
        out["ok"],
        out["error"].as_str(),
        out["chats"].as_array().map(Vec::len).unwrap_or(0)
    )
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let l10n = cx.update(|cx| cx.l10n().clone());

    // ── Before sign-in ────────────────────────────────────────────────
    let mut pass = fresh_profile(cx).await;
    pass &= ok("the setup window opened", wait_setup(cx).await.is_some());
    let early = step(json!({ "intent": "ask", "prompt": "Reply with the word: early" })).await;
    pass &= ok(
        &format!(
            "Ask Conduit before sign-in says to sign in ({})",
            brief(&early)
        ),
        error_is(&early, &l10n.desktop_intent_needs_sign_in()),
    );

    pass &= sign_in(&url, &email, &password, cx).await;
    pass &= ok("models listed", wait_models(cx).await);
    settle(cx, 800).await;

    // ── The binary has what the metadata names ───────────────────────
    let types = step(json!({ "intent": "types" })).await;
    let named = types["named"].as_u64().unwrap_or(0);
    pass &= ok(
        &format!(
            "every type Metadata.appintents names is in the binary ({named} named, missing {})",
            types["missing"]
        ),
        succeeded(&types) && named >= 8 && types["missing"].as_array().is_some_and(Vec::is_empty),
    );

    // ── Ask Conduit ───────────────────────────────────────────────────
    let before = cx.update(selection);
    let asked = step(json!({ "intent": "ask", "prompt": "Reply with the word: heron" })).await;
    pass &= ok(
        &format!("Ask Conduit gives back the answer ({})", brief(&asked)),
        succeeded(&asked) && asked["value"].as_str().map(str::trim) == Some("heron"),
    );
    pass &= ok(
        "without Open in Conduit the main window stays where it was",
        cx.update(selection) == before,
    );

    let reasoned =
        step(json!({ "intent": "ask", "prompt": "Give a reasoned answer, please" })).await;
    let text = reasoned["value"].as_str().unwrap_or_default().to_string();
    pass &= ok(
        &format!(
            "an answer comes back as Copy copies it: no reasoning ({})",
            brief(&reasoned)
        ),
        succeeded(&reasoned)
            && text.contains("Hello from the fake model")
            && !text.contains("synthetic planet")
            && !text.contains("<details"),
    );

    let empty = step(json!({ "intent": "ask", "prompt": "   " })).await;
    pass &= ok(
        "an empty question says what is missing",
        error_is(&empty, &l10n.desktop_intent_ask_empty()),
    );

    let opened = step(json!({
        "intent": "ask",
        "prompt": "Reply with the word: kestrel",
        "openInConduit": true
    }))
    .await;
    pass &= ok(
        &format!(
            "Ask Conduit with Open in Conduit answers ({})",
            brief(&opened)
        ),
        succeeded(&opened) && opened["value"].as_str().map(str::trim) == Some("kestrel"),
    );
    // Found by search: the chat the question made.
    let found = step(json!({ "intent": "search", "query": "kestrel" })).await;
    let kestrel = chats_of(&found).first().map(|(id, _)| id.clone());
    pass &= ok(
        &format!(
            "Open Chat's search finds the asked chat ({})",
            brief(&found)
        ),
        kestrel.is_some(),
    );
    let shown = match &kestrel {
        Some(id) => {
            let id = id.clone();
            wait_until(cx, Duration::from_secs(10), move |cx| {
                selection(cx) == Selection::Chat(id.clone()) && desktop::main_visible(cx)
            })
            .await
        }
        None => false,
    };
    pass &= ok("Open in Conduit shows that chat in the main window", shown);
    settle(cx, 1200).await;
    shoot_main(dir, "intents-ask-opened", cx).await;

    // ── Open Chat's list ──────────────────────────────────────────────
    let suggested = step(json!({ "intent": "suggested" })).await;
    let recent = chats_of(&suggested);
    pass &= ok(
        &format!("Open Chat suggests recent chats ({})", brief(&suggested)),
        succeeded(&suggested)
            && recent.len() >= 3
            && kestrel
                .as_ref()
                .is_some_and(|k| recent.iter().any(|(id, _)| id == k)),
    );
    let (first, first_title) = recent.first().cloned().unwrap_or_default();
    let saved = step(json!({ "intent": "byId", "ids": [first.clone(), GONE] })).await;
    pass &= ok(
        &format!(
            "a saved shortcut's chats come back by id, a deleted one left out ({})",
            brief(&saved)
        ),
        chats_of(&saved) == vec![(first.clone(), first_title.clone())],
    );

    // ── Open Chat ─────────────────────────────────────────────────────
    let other = recent
        .iter()
        .map(|(id, _)| id.clone())
        .find(|id| Some(id) != kestrel.as_ref())
        .unwrap_or_default();
    let open = step(json!({ "intent": "openChat", "id": other.clone(), "title": "" })).await;
    let switched = wait_until(cx, Duration::from_secs(10), |cx| {
        selection(cx) == Selection::Chat(other.clone())
    })
    .await;
    pass &= ok(
        &format!("Open Chat opens the chat ({})", brief(&open)),
        succeeded(&open) && switched,
    );
    let gone = step(json!({ "intent": "openChat", "id": GONE, "title": "Gone" })).await;
    pass &= ok(
        "Open Chat says when the chat is gone",
        error_is(&gone, &l10n.desktop_intent_chat_missing()),
    );

    // ── New Chat ──────────────────────────────────────────────────────
    let drafted = step(json!({ "intent": "newChat", "prompt": "Draft from a shortcut" })).await;
    let prefilled = wait_until(cx, Duration::from_secs(10), |cx| {
        matches!(selection(cx), Selection::New { .. })
            && composer_text(cx) == "Draft from a shortcut"
            && chat_store(cx).is_none()
    })
    .await;
    pass &= ok(
        &format!(
            "New Chat fills a new chat's message box, not sent ({})",
            brief(&drafted)
        ),
        succeeded(&drafted) && prefilled,
    );
    settle(cx, 600).await;
    shoot_main(dir, "intents-new-chat", cx).await;
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.set_text("", window, cx))
    });

    // ── Show Quick Ask ────────────────────────────────────────────────
    let quick = step(
        json!({ "intent": "quickAsk", "text": "What's a good name for a sourdough starter?" }),
    )
    .await;
    let quick_shown = wait_until(cx, Duration::from_secs(5), |cx| {
        desktop::quick_ask_visible(cx)
            && quick_ask_text(cx).as_deref() == Some("What's a good name for a sourdough starter?")
    })
    .await;
    pass &= ok(
        &format!(
            "Show Quick Ask opens the panel with the text in it ({})",
            brief(&quick)
        ),
        succeeded(&quick) && quick_shown,
    );
    settle(cx, 700).await;
    if let Some((handle, _)) = cx.update(|cx| {
        cx.try_global::<desktop::Desktop>()
            .and_then(|d| d.quick_ask.clone())
    }) {
        shoot_both_modes(handle, dir, "intents-quick-ask", cx).await;
    }
    cx.update(desktop::hide_quick_ask);
    settle(cx, 400).await;
    let plain = step(json!({ "intent": "quickAsk" })).await;
    pass &= ok(
        "Show Quick Ask without text shows the panel as it was",
        succeeded(&plain)
            && wait_until(cx, Duration::from_secs(5), |cx| {
                desktop::quick_ask_visible(cx)
                    && quick_ask_text(cx).as_deref()
                        == Some("What's a good name for a sourdough starter?")
            })
            .await,
    );
    cx.update(desktop::hide_quick_ask);
    settle(cx, 400).await;

    // ── Start Voice Call ──────────────────────────────────────────────
    let quiet = super::voice_call::prepare_quiet_call(dir, cx).await;
    pass &= ok("a quiet stand-in for the call's microphone", quiet);
    if !quiet {
        // Never a call on the real microphone.
        return false;
    }
    let call = step(json!({ "intent": "startVoiceCall" })).await;
    let started = cx.update(super::voice_call::call_on);
    pass &= ok(
        "Start Voice Call starts a call in a new chat",
        succeeded(&call)
            && started.is_some()
            && matches!(cx.update(selection), Selection::New { .. }),
    );
    settle(cx, 600).await;
    shoot_main(dir, "intents-voice-call", cx).await;
    // Never the toggling Voice Call action: a second one leaves it on.
    let again = step(json!({ "intent": "startVoiceCall" })).await;
    settle(cx, 600).await;
    pass &= ok(
        "…and again while it is on leaves that call on",
        succeeded(&again) && started.is_some() && cx.update(super::voice_call::call_on) == started,
    );
    pass &= ok("the call ends", super::voice_call::end_call(cx).await);
    pass
}
