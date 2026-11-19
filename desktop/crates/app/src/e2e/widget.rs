//! `--e2e widget`: the desktop widget's side of the app, on the local
//! Open WebUI and its fake model:
//!
//! * the snapshot (`CONDUIT_WIDGET_SNAPSHOT`'s file, redirected into the
//!   run's folder): signed out on a fresh profile; after sign-in the newest
//!   chats' ids, titles and times only, newest first, owner-only; it
//!   follows a rename, an archive, a new chat and the app's language; and
//!   signing out leaves no title in it;
//! * WidgetKit is asked to reload after each write, when the bundle
//!   carries the widget's library (`CONDUIT_DEV_WIDGET=1 run.sh`);
//! * the widget's links as `on_open_urls` hands them over: `chat/<id>`,
//!   `new`, `quick-ask`, `call` and the phone widget's `new_chat` and
//!   `mic`.

use std::path::{Path, PathBuf};
use std::time::Duration;

use gpui_kit::{App, AsyncApp};
use serde_json::Value;

use super::chat::{send, sign_in, wait_answer, wait_models};
use super::*;
use crate::desktop;
use crate::stores::navigation::Selection;

fn snapshot_at(path: &Path) -> Option<Value> {
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
}

fn titles(v: &Value) -> Vec<String> {
    v["chats"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|c| c["title"].as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default()
}

fn ids(v: &Value) -> Vec<String> {
    v["chats"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|c| c["id"].as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default()
}

/// Waits until the snapshot on disk satisfies `want`.
async fn wait_snapshot(
    path: &Path,
    cx: &mut AsyncApp,
    want: impl Fn(&Value) -> bool,
) -> Option<Value> {
    let path = path.to_path_buf();
    let mut last = None;
    let found = wait_until(cx, Duration::from_secs(30), |_| {
        last = snapshot_at(&path);
        last.as_ref().is_some_and(&want)
    })
    .await;
    if found { last } else { None }
}

fn selection(cx: &mut App) -> Selection {
    cx.global::<AppState>()
        .stores
        .navigation
        .read(cx)
        .selection()
        .clone()
}

fn links(urls: &[&str], cx: &mut AsyncApp) {
    let urls: Vec<String> = urls.iter().map(|u| u.to_string()).collect();
    cx.update(|cx| desktop::handle_urls(urls, cx));
}

/// What the app's list holds, as the widget should show it.
fn expected(cx: &mut App) -> (Vec<String>, Vec<String>) {
    let l10n = crate::l10n::ActiveL10n::l10n(cx).clone();
    let recent = cx
        .global::<AppState>()
        .stores
        .chat_list
        .read(cx)
        .recent(crate::shell::widget::MAX_CHATS);
    let ids = recent.iter().map(|c| c.id.clone()).collect();
    let titles = recent
        .iter()
        .map(|c| {
            let title = if c.title.trim().is_empty() {
                l10n.new_chat()
            } else {
                c.title.trim().to_string()
            };
            // As the snapshot cuts it.
            title
                .chars()
                .take(crate::shell::widget::MAX_TITLE)
                .collect::<String>()
        })
        .collect();
    (ids, titles)
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let path: PathBuf = dir.join("widget-snapshot.json");
    let bridge = cx.update(|cx| {
        let feed = &mut cx.global_mut::<desktop::Desktop>().widget;
        feed.redirect(path.clone());
        feed.bridge_loaded()
    });
    println!(
        "E2E note: this bundle {} the widget's library",
        if bridge { "carries" } else { "lacks" }
    );

    // English whatever the Mac's own language is: the checks below
    // compare with English.
    let settings = cx.update(|cx| cx.global::<AppState>().settings.clone());
    cx.update(|cx| settings.update(cx, |s, cx| s.set_locale(Some("en".into()), cx)));
    let mut pass = sign_in(&url, &email, &password, cx).await;
    let _ = wait_models(cx).await;
    // The newest chats, as the list has them, once the snapshot shows
    // them (the list can still be syncing when the first one lands).
    let mut seen = None;
    let mut want = (vec![], vec![]);
    let matched = wait_until(cx, Duration::from_secs(30), |cx| {
        want = expected(cx);
        seen = snapshot_at(&path);
        seen.as_ref().is_some_and(|v| {
            v["signedIn"] == true && !want.0.is_empty() && ids(v) == want.0 && titles(v) == want.1
        })
    })
    .await;
    let (want_ids, _) = want;
    pass &= ok(
        &format!(
            "the snapshot says signed in and lists the newest chats, newest first ({} of them)",
            want_ids.len()
        ),
        matched,
    );
    let Some(first) = seen.filter(|_| matched) else {
        return false;
    };

    // Four fields each, no more.
    let keys_only = first.as_object().is_some_and(|o| {
        let mut k: Vec<&str> = o.keys().map(String::as_str).collect();
        k.sort();
        k == ["chats", "locale", "owner", "signedIn", "version"]
    }) && first["chats"].as_array().is_some_and(|a| {
        a.iter().all(|c| {
            let mut k: Vec<&str> = c
                .as_object()
                .map(|o| o.keys().map(String::as_str).collect())
                .unwrap_or_default();
            k.sort();
            k == ["id", "title", "updatedAtMs"]
        })
    });
    pass &= ok(
        "only ids, titles and times (and the owner's one-way tag): no message text, models or folders",
        keys_only && first["owner"].as_str().is_some_and(|o| !o.contains(&email)),
    );
    pass &= ok("the snapshot speaks English", first["locale"] == "en");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let mode = std::fs::metadata(&path)
            .map(|m| m.permissions().mode() & 0o777)
            .unwrap_or(0);
        pass &= ok(&format!("owner-only file ({mode:o})"), mode == 0o600);
    }
    let reloads = cx.update(|cx| {
        let f = &cx.global::<desktop::Desktop>().widget;
        (f.writes, f.reloads)
    });
    if bridge {
        pass &= ok(
            &format!("each write asked WidgetKit to reload ({reloads:?})"),
            reloads.0 > 0 && reloads.0 == reloads.1,
        );
    } else {
        println!("E2E skip: no widget library in this bundle, so no reloads ({reloads:?})");
    }

    // A rename shows.
    let target = want_ids[0].clone();
    let renamed = "Ridge walk packing list";
    {
        let target = target.clone();
        let task = cx.update(|cx| {
            let list = cx.global::<AppState>().stores.chat_list.clone();
            list.update(cx, |l, cx| l.rename(&target, renamed, cx))
        });
        let _ = task.await;
    }
    let after_rename = wait_snapshot(&path, cx, |v| titles(v).iter().any(|t| t == renamed)).await;
    pass &= ok("a rename reaches the snapshot", after_rename.is_some());

    // An archived chat leaves it.
    {
        let target = target.clone();
        let task = cx.update(|cx| {
            let list = cx.global::<AppState>().stores.chat_list.clone();
            list.update(cx, |l, cx| l.set_archived(&target, true, cx))
        });
        let _ = task.await;
    }
    let after_archive = {
        let target = target.clone();
        wait_snapshot(&path, cx, move |v| !ids(v).contains(&target)).await
    };
    pass &= ok(
        "an archived chat leaves the snapshot",
        after_archive.is_some(),
    );

    // A new chat comes first.
    links(&["conduit://new"], cx);
    let new_open = wait_until(cx, Duration::from_secs(10), |cx| {
        matches!(selection(cx), Selection::New { .. })
    })
    .await;
    pass &= ok("conduit://new opens a new chat", new_open);
    send("Suggest three names for a hiking club.", cx).await;
    pass &= ok(
        "the fake model answered",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let new_id = cx.update(|cx| match selection(cx) {
        Selection::Chat(id) => Some(id),
        _ => None,
    });
    let after_new = match new_id.clone() {
        Some(id) => wait_snapshot(&path, cx, move |v| ids(v).first() == Some(&id)).await,
        None => None,
    };
    pass &= ok("the new chat heads the snapshot", after_new.is_some());

    // The app's language goes with it.
    cx.update(|cx| settings.update(cx, |s, cx| s.set_locale(Some("de".into()), cx)));
    let german = wait_snapshot(&path, cx, |v| v["locale"] == "de").await;
    pass &= ok("the snapshot follows the app's language", german.is_some());
    cx.update(|cx| settings.update(cx, |s, cx| s.set_locale(Some("en".into()), cx)));
    let english = wait_snapshot(&path, cx, |v| v["locale"] == "en").await;
    pass &= ok("…and back", english.is_some());

    // The widget's links.
    let second = cx.update(expected).0.get(1).cloned();
    if let Some(id) = second.clone() {
        links(&[&format!("conduit://chat/{id}")], cx);
        let opened = wait_until(cx, Duration::from_secs(10), |cx| {
            selection(cx) == Selection::Chat(id.clone())
        })
        .await;
        pass &= ok("a chat row's link opens that chat", opened);
    } else {
        pass &= ok("a second chat to open", false);
    }
    links(&["conduit://quick-ask"], cx);
    let shown = wait_until(cx, Duration::from_secs(5), desktop::quick_ask_visible).await;
    pass &= ok("conduit://quick-ask shows Quick Ask", shown);
    cx.update(desktop::hide_quick_ask);
    settle(cx, 400).await;
    let quiet = super::voice_call::prepare_quiet_call(dir, cx).await;
    pass &= ok("a quiet stand-in for the call's microphone", quiet);
    // Never a call on the real microphone: without the stand-in, no links
    // that start one.
    let call_links: &[&str] = if quiet {
        &["conduit://call", "conduit://mic?homeWidget=true"]
    } else {
        &[]
    };
    for &link in call_links {
        links(&[link], cx);
        // A voice call in a new chat, as the phone's widget starts one.
        let started = wait_until(cx, Duration::from_secs(10), |cx| {
            super::voice_call::call_on(cx).is_some()
                && matches!(selection(cx), Selection::New { .. })
        })
        .await;
        pass &= ok(
            &format!("{link} starts a voice call in a new chat"),
            started,
        );
        if link == "conduit://call" {
            settle(cx, 600).await;
            shoot_main(dir, "widget-voice-call", cx).await;
        }
        pass &= ok(
            &format!("…and the call from {link} ends"),
            super::voice_call::end_call(cx).await,
        );
        if let Some(id) = second.clone() {
            links(&[&format!("conduit://chat/{id}")], cx);
            settle(cx, 600).await;
        }
    }
    links(&["conduit://new_chat?homeWidget=true"], cx);
    let phone = wait_until(cx, Duration::from_secs(10), |cx| {
        matches!(selection(cx), Selection::New { .. })
    })
    .await;
    pass &= ok("the phone widget's new_chat link opens a new chat", phone);
    settle(cx, 600).await;
    shoot_main(dir, "widget-new-chat-link", cx).await;

    // Signed out: no titles left on disk.
    let before = std::fs::read_to_string(&path).unwrap_or_default();
    let had_titles = cx.update(expected).1;
    in_main(cx, |mw, window, cx| {
        crate::views::accounts::sign_out_active(&mw.stores, window, cx)
    });
    pass &= wait_route(cx, Route::Onboarding, Duration::from_secs(60)).await;
    let out = wait_snapshot(&path, cx, |v| v["signedIn"] == false).await;
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    pass &= ok(
        "signed out: the snapshot holds no chats",
        out.as_ref()
            .is_some_and(|v| v["chats"].as_array().is_some_and(|a| a.is_empty())),
    );
    pass &= ok(
        "…and none of the titles it showed",
        !before.is_empty() && had_titles.iter().all(|t| !text.contains(t.as_str())),
    );
    pass
}
