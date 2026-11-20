//! `--e2e notifications`: Settings › Notifications against the local
//! Open WebUI. The page's controls (and General without its old switches);
//! then, with the classes and surfaces changed through the store the
//! switches use, what a channel post (Riley, through `owui.sh peer`) and an
//! answer do, as the core decides it: an in-app banner whose View opens the
//! channel, nothing with Channel Messages off, only a direct message with
//! Only Mentions and Direct Messages, silence with In-App Banners off, the
//! cue with Always Play Sound, a system notification (delivered, clicked)
//! when the app counts as behind, the same for an answer finished on
//! another device (`owui.sh chat`: the server's socket, as the phone hears
//! it) and only one for this Mac's own, nothing with Chat Responses or
//! Allow Notifications off. Last, Webhook Destinations behind Advanced: one added
//! through the sheet, tested against the fake model's receiver, made the
//! default and deleted. Every pane and sheet is shot in light and dark.

use std::path::Path;
use std::time::Duration;

use conduit_protocol::{
    NoParams, NotificationSettingsDto, NotificationSettingsPatch, NotifySurface, methods,
};
use gpui_kit::{AnyWindowHandle, AsyncApp, Entity};

use super::*;
use crate::desktop::{self, Routed};
use crate::stores::navigation::AreaItem;
use crate::views::settings::SettingsView;
use crate::views::settings::notifications::NotificationsPane;
use crate::views::settings::webhook_editor::WebhookEditorSheet;
use crate::views::sheet;

/// Riley, acting on the local server (as the channels pass does).
fn peer(args: &[&str]) -> Option<serde_json::Value> {
    let script =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../tool/local_owui/owui.sh");
    let out = std::process::Command::new(script)
        .arg("peer")
        .args(args)
        .output()
        .ok()?;
    if !out.status.success() {
        println!(
            "SMOKE note peer {} failed",
            args.first().copied().unwrap_or_default()
        );
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    serde_json::from_str(text.lines().last().unwrap_or("null")).ok()
}

/// An answer finished on "another device": the local server's web-client
/// driver signs in as the same user and runs one chat turn (`owui.sh
/// chat`). Its chat's id.
fn answer_elsewhere(dir: &Path, prompt: &str) -> Option<String> {
    let script =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../tool/local_owui/owui.sh");
    let out = std::process::Command::new(script)
        .arg("chat")
        .arg(dir.join("elsewhere"))
        .arg(prompt)
        .output()
        .ok()?;
    if !out.status.success() {
        println!("SMOKE note owui.sh chat failed");
        return None;
    }
    // Its summary line (JSON) comes first, then what the chat stored.
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .find_map(|v| v["chat_id"].as_str().map(str::to_string))
}

fn settings_view(cx: &mut App) -> Option<(AnyWindowHandle, Entity<SettingsView>)> {
    cx.try_global::<AppState>()?.settings_window.clone()
}

fn pane(cx: &mut App) -> Option<Entity<NotificationsPane>> {
    settings_view(cx)?.1.read(cx).notifications.clone()
}

/// Runs `f` on the Notifications pane with the Settings window.
fn in_pane<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut NotificationsPane, &mut Window, &mut gpui_kit::Context<NotificationsPane>) -> R,
) -> Option<R> {
    let (handle, _) = cx.update(settings_view)?;
    let pane = cx.update(pane)?;
    handle
        .update(cx, |_, window, cx| {
            pane.update(cx, |p, cx| f(p, window, cx))
        })
        .ok()
}

fn in_sheet<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(
        &mut WebhookEditorSheet,
        &mut Window,
        &mut gpui_kit::Context<WebhookEditorSheet>,
    ) -> R,
) -> Option<R> {
    let handle = cx.update(|cx| sheet::current_window(cx))?;
    let entity = cx.update(|cx| sheet::current::<WebhookEditorSheet>(cx))?;
    cx.update(|cx| {
        handle
            .update(cx, |_, window, cx| {
                entity.update(cx, |v, cx| f(v, window, cx))
            })
            .ok()
    })
}

async fn settings_shot(dir: &Path, name: &str, cx: &mut AsyncApp) {
    if let Some((handle, _)) = cx.update(settings_view) {
        settle(cx, 500).await;
        shoot_both_modes(handle, dir, name, cx).await;
    }
}

/// The Settings window made tall (the pane is long), shot in light and
/// dark, and put back.
async fn tall_shot(dir: &Path, name: &str, cx: &mut AsyncApp) {
    let Some((handle, _)) = cx.update(settings_view) else {
        return;
    };
    let ns = cx.update(|cx| crate::smoke::ns_window(handle, cx));
    if let Some(ns) = &ns {
        crate::smoke::place(
            ns,
            (300., 40.),
            (crate::views::settings::SETTINGS_SIZE.0, 1040.),
        );
    }
    settle(cx, 600).await;
    shoot_both_modes(handle, dir, name, cx).await;
    if let Some(ns) = &ns {
        crate::smoke::place(ns, (300., 40.), crate::views::settings::SETTINGS_SIZE);
    }
}

fn set(patch: NotificationSettingsPatch, cx: &mut AsyncApp) {
    cx.update(|cx| {
        let store = cx.global::<AppState>().stores.notifications.clone();
        store.update(cx, |s, cx| s.set(patch, cx));
    });
}

/// What the daemon has stored (not what the store shows).
async fn stored(cx: &mut AsyncApp) -> Option<NotificationSettingsDto> {
    let call = cx.update(|cx| {
        cx.global::<AppState>()
            .connection
            .read(cx)
            .rpc()
            .call::<methods::NotificationsGet>(&NoParams)
    });
    call.await.ok()
}

/// Sets `patch` and waits until the daemon has it.
async fn change(patch: NotificationSettingsPatch, cx: &mut AsyncApp) -> bool {
    set(patch.clone(), cx);
    for _ in 0..25 {
        settle(cx, 200).await;
        if let Some(s) = stored(cx).await {
            let holds = patch.enabled.is_none_or(|v| s.enabled == v)
                && patch.in_app_banner.is_none_or(|v| s.in_app_banner == v)
                && patch.sound_always.is_none_or(|v| s.sound_always == v)
                && patch.answers.is_none_or(|v| s.answers == v)
                && patch.channels.is_none_or(|v| s.channels == v)
                && patch.mentions_only.is_none_or(|v| s.mentions_only == v);
            if holds {
                return true;
            }
        }
    }
    false
}

/// What the next notification for `id` after `mark` did.
async fn routed_after(mark: usize, id: &str, cx: &mut AsyncApp) -> Option<Routed> {
    let id = id.to_string();
    let find = move |cx: &mut App| {
        desktop::routed_notifications(cx)
            .into_iter()
            .skip(mark)
            .find(|r| r.id == id)
    };
    let found = {
        let find = find.clone();
        wait_until(cx, Duration::from_secs(20), move |cx| find(cx).is_some()).await
    };
    if !found {
        return None;
    }
    cx.update(find)
}

fn routed_len(cx: &mut AsyncApp) -> usize {
    cx.update(|cx| desktop::routed_notifications(cx).len())
}

/// The main window in front, so the app counts as in front.
async fn front(cx: &mut AsyncApp) {
    cx.update(desktop::show_main);
    wait_until(cx, Duration::from_secs(5), |cx| {
        desktop::on_screen(cx).main_key
    })
    .await;
}

fn open_chat(id: &str, cx: &mut AsyncApp) {
    let id = id.to_string();
    cx.update(|cx| {
        let nav = cx.global::<AppState>().stores.navigation.clone();
        nav.update(cx, |n, cx| n.open(id, cx));
    });
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let Some(trail) = inputs.get("OWUI_CHANNEL") else {
        return ok("OWUI_CHANNEL in the env file (owui.sh reset)", false);
    };
    let mut pass = super::chat::sign_in(&url, &email, &password, cx).await;
    let loaded = wait_until(cx, Duration::from_secs(20), |cx| {
        cx.global::<AppState>().stores.notifications.read(cx).loaded
    })
    .await;
    pass &= ok("notifications.get answered after sign-in", loaded);
    let start = stored(cx).await.unwrap_or_default();
    pass &= ok(
        "notifications start on, for answers and channel messages, mirrored to the account",
        start.enabled && start.answers && start.channels && !start.mentions_only && start.synced,
    );

    // ── The page ───────────────────────────────────────────────────────
    if let Some(h) = settings_tab(Tab::Desktop, dir, "notifications-general", cx).await {
        let controls = ax(h, "notifications-general", dir, cx).await;
        pass &= ok(
            "General no longer holds the notification switches",
            !has(&controls, "Switch", "Notify When an Answer")
                && !has(&controls, "Switch", "Chat Responses"),
        );
    }
    if let Some(h) = settings_tab(Tab::Notifications, dir, "notifications-pane", cx).await {
        let controls = ax(h, "notifications-pane", dir, cx).await;
        pass &= ok(
            "Notifications has the phone's switches and System Notification Settings",
            [
                "Allow Notifications",
                "In-App Banners",
                "System Notifications",
                "Sound",
                "Always Play Sound",
                "Chat Responses",
                "Channel Messages",
                "Only Mentions and Direct Messages",
            ]
            .iter()
            .all(|l| has(&controls, "Switch", l))
                && has(&controls, "Button", "Open System Settings"),
        );
        let listed = cx.update(|cx| {
            let stores = cx.global::<AppState>().stores.clone();
            Tab::visible(&stores, cx)
        });
        pass &= ok(
            "Notifications follows Profile in Settings",
            listed
                .iter()
                .position(|t| *t == Tab::Notifications)
                .is_some_and(|i| i > 0 && listed[i - 1] == Tab::Profile),
        );
    }

    // Quiet permission (no prompt), as the shell pass asks it.
    cx.update(|cx| desktop::ensure_permission(true, cx));
    wait_until(cx, Duration::from_secs(10), |cx| {
        let shell = cx.global::<desktop::Desktop>().shell.read(cx).notifications;
        !matches!(
            shell,
            crate::stores::shell::NotificationAccess::Unknown
                | crate::stores::shell::NotificationAccess::NotDetermined
        )
    })
    .await;
    let access = cx.update(|cx| cx.global::<desktop::Desktop>().shell.read(cx).notifications);
    println!("SMOKE info notification access {access:?}");
    let denied = access == crate::stores::shell::NotificationAccess::Denied;

    // A chat on screen in the main window.
    pass &= ok("models listed", super::chat::wait_models(cx).await);
    super::chat::send("Reply with exactly the word: tide", cx).await;
    pass &= ok(
        "a first answer",
        super::chat::wait_answer(cx, Duration::from_secs(60)).await,
    );
    let chat_id = cx.update(|cx| {
        super::chat::chat_store(cx)
            .map(|s| s.read(cx).chat_id().to_string())
            .unwrap_or_default()
    });
    let channel_key = crate::shell::notify::channel_identifier(&trail);
    let chat_key = crate::shell::notify::identifier(&chat_id);
    front(cx).await;
    println!(
        "SMOKE info app in front {}",
        cx.update(|cx| desktop::on_screen(cx).app_active)
    );

    // ── A channel post while Conduit is in front: a banner ────────────
    let mark = routed_len(cx);
    pass &= ok(
        "Riley posted",
        peer(&["post", &trail, "Low tide at four"]).is_some(),
    );
    let r = routed_after(mark, &channel_key, cx).await;
    pass &= ok(
        &format!("a channel post in front shows an in-app banner ({r:?})"),
        r.as_ref()
            .is_some_and(|r| r.surface == NotifySurface::Banner && !r.cue),
    );
    let toast = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .toasts
            .read(cx)
            .toasts
            .iter()
            .rev()
            .find(|t| t.action_label.is_some())
            .cloned()
    });
    pass &= ok(
        "the banner names who posted where, never the message, with View",
        toast.as_ref().is_some_and(|t| {
            t.message.contains("Riley")
                && !t.message.contains("Low tide")
                && t.action_label.as_deref() == Some("View")
        }),
    );
    shoot_main(dir, "notifications-banner", cx).await;
    if let Some(retry) = toast.and_then(|t| t.retry) {
        cx.update(|cx| (retry.0)(cx));
        let opened = wait_until(cx, Duration::from_secs(10), |cx| {
            cx.global::<AppState>()
                .stores
                .navigation
                .read(cx)
                .selected_item()
                == Some(&AreaItem::Channel(trail.clone()))
        })
        .await;
        pass &= ok("View on the banner opens the channel", opened);
    }
    open_chat(&chat_id, cx);
    settle(cx, 800).await;
    front(cx).await;

    // ── Channel Messages off: nothing ─────────────────────────────────
    pass &= ok(
        "Channel Messages turns off",
        change(
            NotificationSettingsPatch {
                channels: Some(false),
                ..Default::default()
            },
            cx,
        )
        .await,
    );
    let mark = routed_len(cx);
    peer(&["post", &trail, "Bring a rope"]);
    let r = routed_after(mark, &channel_key, cx).await;
    pass &= ok(
        "with Channel Messages off, a post notifies nothing",
        r.is_some_and(|r| r.surface == NotifySurface::Suppressed),
    );

    // ── Only mentions and direct messages ─────────────────────────────
    pass &= ok(
        "Only Mentions and Direct Messages turns on",
        change(
            NotificationSettingsPatch {
                channels: Some(true),
                mentions_only: Some(true),
                ..Default::default()
            },
            cx,
        )
        .await,
    );
    let mark = routed_len(cx);
    peer(&["post", &trail, "Kayaks at the slipway"]);
    let r = routed_after(mark, &channel_key, cx).await;
    pass &= ok(
        "with mentions only, a plain post notifies nothing",
        r.is_some_and(|r| r.surface == NotifySurface::Suppressed),
    );
    let mark = routed_len(cx);
    let dm = peer(&["dm", "Are you at the boathouse?"]);
    let dm_id = dm
        .as_ref()
        .and_then(|v| v["channel"].as_str())
        .unwrap_or_default()
        .to_string();
    let dm_key = crate::shell::notify::channel_identifier(&dm_id);
    let r = routed_after(mark, &dm_key, cx).await;
    pass &= ok(
        &format!("with mentions only, a direct message still notifies ({r:?})"),
        r.is_some_and(|r| r.surface == NotifySurface::Banner),
    );

    // ── In-app banners off: silent; Always Play Sound: the cue ───────
    pass &= ok(
        "In-App Banners off, Always Play Sound on",
        change(
            NotificationSettingsPatch {
                mentions_only: Some(false),
                in_app_banner: Some(false),
                sound_always: Some(true),
                ..Default::default()
            },
            cx,
        )
        .await,
    );
    if let Some(h) = cx.update(settings_view).map(|(h, _)| h) {
        cx.update(|cx| crate::open_settings(Some(Tab::Notifications), cx));
        settle(cx, 400).await;
        shoot_both_modes(h, dir, "notifications-pane-changed", cx).await;
    }
    front(cx).await;
    let mark = routed_len(cx);
    peer(&["post", &trail, "Fog rolling in"]);
    let r = routed_after(mark, &channel_key, cx).await;
    pass &= ok(
        &format!("with In-App Banners off, a post in front is silent, with the cue ({r:?})"),
        r.is_some_and(|r| r.surface == NotifySurface::Silent && r.cue),
    );
    change(
        NotificationSettingsPatch {
            in_app_banner: Some(true),
            sound_always: Some(false),
            ..Default::default()
        },
        cx,
    )
    .await;

    // ── Behind other apps: a system notification for the answer ──────
    cx.update(|cx| desktop::set_e2e_background(true, cx));
    let mark = routed_len(cx);
    super::chat::send("Reply with exactly the word: reef", cx).await;
    let r = routed_after(mark, &chat_key, cx).await;
    pass &= ok(
        &format!("an answer while the app is behind goes to Notification Center ({r:?})"),
        r.as_ref()
            .is_some_and(|r| r.surface == NotifySurface::System && r.system_sound),
    );
    if !denied {
        let mut delivered = None;
        for _ in 0..40 {
            if let Some(rx) = cx.update(|cx| desktop::delivered_notifications(cx)) {
                let list = rx.await.unwrap_or_default();
                if let Some(n) = list.into_iter().find(|n| n.id == chat_key) {
                    delivered = Some(n);
                    break;
                }
            }
            settle(cx, 250).await;
        }
        pass &= ok(
            "the system notification is delivered, with the chat's title only",
            delivered
                .as_ref()
                .is_some_and(|n| n.body == "The answer is ready." && !n.title.contains("reef")),
        );
        cx.update(|cx| desktop::simulate_notification_click(&chat_key, cx));
        let clicked = wait_until(cx, Duration::from_secs(8), |cx| {
            cx.global::<AppState>()
                .stores
                .navigation
                .read(cx)
                .selected_chat()
                == Some(chat_id.as_str())
        })
        .await;
        pass &= ok("clicking it shows the chat", clicked);
        cx.update(|cx| desktop::remove_all_notifications(cx));
    } else {
        println!("SMOKE info notifications are denied for this bundle; delivery not checked");
    }
    // The server says the same answer finished on its socket: no second
    // notification for it (the daemon announced it as its own).
    settle(cx, 3000).await;
    let own = cx.update(|cx| {
        desktop::routed_notifications(cx)
            .into_iter()
            .skip(mark)
            .filter(|r| r.id == chat_key)
            .count()
    });
    pass &= ok(
        &format!("this Mac's own answer notified once ({own})"),
        own == 1,
    );

    // ── An answer finished on another device: notified as the phone does ──
    let mark = routed_len(cx);
    match answer_elsewhere(dir, "Reply with exactly the word: kelp") {
        Some(elsewhere) => {
            let key = crate::shell::notify::identifier(&elsewhere);
            let r = routed_after(mark, &key, cx).await;
            pass &= ok(
                &format!(
                    "an answer finished on another device notifies, as the core routes it ({r:?})"
                ),
                r.as_ref()
                    .is_some_and(|r| r.surface == NotifySurface::System && r.system_sound),
            );
            settle(cx, 3000).await;
            let count = cx.update(|cx| {
                desktop::routed_notifications(cx)
                    .into_iter()
                    .skip(mark)
                    .filter(|r| r.id == key)
                    .count()
            });
            pass &= ok(&format!("…once ({count})"), count == 1);
        }
        None => pass &= ok("an answer finished on another device (owui.sh chat)", false),
    }

    // ── Chat Responses off: nothing for an answer ─────────────────────
    pass &= ok(
        "Chat Responses turns off",
        change(
            NotificationSettingsPatch {
                answers: Some(false),
                ..Default::default()
            },
            cx,
        )
        .await,
    );
    let mark = routed_len(cx);
    super::chat::send("Reply with exactly the word: shoal", cx).await;
    let r = routed_after(mark, &chat_key, cx).await;
    pass &= ok(
        "with Chat Responses off, an answer notifies nothing",
        r.is_some_and(|r| r.surface == NotifySurface::Suppressed),
    );
    cx.update(|cx| desktop::set_e2e_background(false, cx));
    change(
        NotificationSettingsPatch {
            answers: Some(true),
            ..Default::default()
        },
        cx,
    )
    .await;

    // ── Allow Notifications off: nothing at all ───────────────────────
    pass &= ok(
        "Allow Notifications turns off",
        change(
            NotificationSettingsPatch {
                enabled: Some(false),
                ..Default::default()
            },
            cx,
        )
        .await,
    );
    let mark = routed_len(cx);
    peer(&["post", &trail, "Harbour closed at dusk"]);
    let r = routed_after(mark, &channel_key, cx).await;
    pass &= ok(
        "with notifications off, a post notifies nothing",
        r.is_some_and(|r| r.surface == NotifySurface::Suppressed),
    );
    change(
        NotificationSettingsPatch {
            enabled: Some(true),
            ..Default::default()
        },
        cx,
    )
    .await;

    // ── Webhook destinations (Advanced) ───────────────────────────────
    pass &= webhooks(inputs, dir, cx).await;
    pass
}

fn hooks(cx: &mut App) -> Option<conduit_protocol::WebhookList> {
    pane(cx)?.read(cx).webhooks.clone()
}

async fn wait_closed(cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(20), |cx| !sheet::is_open(cx)).await
}

async fn webhooks(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    let base = inputs
        .get("FAKE_OPENAI_URL")
        .map(|u| u.trim_end_matches('/').trim_end_matches("/v1").to_string())
        .unwrap_or_default();
    let log = inputs.get("FAKE_MODEL_LOG").map(std::path::PathBuf::from);
    cx.update(|cx| {
        let s = cx.global::<AppState>().stores.app_settings.clone();
        s.update(cx, |s, cx| {
            s.set(
                conduit_protocol::AppSettingsPatch {
                    advanced_features_enabled: Some(true),
                    ..Default::default()
                },
                cx,
            )
        });
    });
    cx.update(|cx| crate::open_settings(Some(Tab::Notifications), cx));
    let listed = wait_until(cx, Duration::from_secs(20), |cx| {
        hooks(cx).is_some_and(|l| l.available && !l.failed)
    })
    .await;
    pass &= ok(
        "with Advanced on, Webhook Destinations lists (none yet)",
        listed,
    );
    if !listed {
        return pass;
    }
    in_pane(cx, |p, window, cx| p.open_editor(None, window, cx));
    pass &= ok(
        "Add Destination… opens a sheet",
        wait_until(cx, Duration::from_secs(10), |cx| {
            sheet::current::<WebhookEditorSheet>(cx).is_some()
        })
        .await,
    );
    let url = format!("{base}/webhook/e2e-desk");
    in_sheet(cx, move |s, window, cx| {
        set_text(&s.url.clone(), &url, window, cx);
        set_text(&s.name.clone(), "e2e-desk", window, cx);
        s.delivery = "always".into();
        if let Some(first) = s.catalog_first() {
            s.events.insert(first);
        }
        cx.notify();
    });
    settings_shot(dir, "webhook-new", cx).await;
    in_sheet(cx, |s, _, cx| s.save(cx));
    pass &= ok("Save closes the sheet", wait_closed(cx).await);
    let added = wait_until(cx, Duration::from_secs(10), |cx| {
        hooks(cx).is_some_and(|l| l.items.iter().any(|h| h.id == "e2e-desk"))
    })
    .await;
    let hook = cx
        .update(hooks)
        .and_then(|l| l.items.into_iter().find(|h| h.id == "e2e-desk"));
    pass &= ok(
        "the destination lists with a masked URL, Always, one event",
        added
            && hook.as_ref().is_some_and(|h| {
                h.enabled
                    && h.delivery == "always"
                    && h.events.len() == 1
                    && h.masked_url
                        .as_deref()
                        .is_some_and(|m| !m.contains("e2e-desk"))
            }),
    );
    tall_shot(dir, "notifications-webhooks", cx).await;

    // Send Test Notification: the server delivers one to the receiver.
    let mark = log
        .as_ref()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .map(|t| t.lines().count())
        .unwrap_or(0);
    let target = hook.clone();
    in_pane(cx, move |p, window, cx| p.open_editor(target, window, cx));
    wait_until(cx, Duration::from_secs(10), |cx| {
        sheet::current::<WebhookEditorSheet>(cx).is_some()
    })
    .await;
    settings_shot(dir, "webhook-edit", cx).await;
    in_sheet(cx, |s, _, cx| s.press_test(cx));
    let sent = wait_until(cx, Duration::from_secs(20), |cx| {
        sheet::current::<WebhookEditorSheet>(cx).is_some_and(|s| s.read(cx).note.is_some())
    })
    .await;
    pass &= ok("Send Test Notification says it was sent", sent);
    let delivered = match &log {
        Some(p) => {
            let p = p.clone();
            wait_until(cx, Duration::from_secs(10), move |_| {
                std::fs::read_to_string(&p).is_ok_and(|t| {
                    t.lines()
                        .skip(mark)
                        .any(|l| l.contains("\"webhook\"") && l.contains("/webhook/e2e-desk"))
                })
            })
            .await
        }
        None => false,
    };
    pass &= ok("the fake receiver got the test delivery", delivered);
    in_sheet(cx, |s, _, cx| s.press_make_default(cx));
    pass &= ok("Make Default closes the sheet", wait_closed(cx).await);
    let default = wait_until(cx, Duration::from_secs(10), |cx| {
        hooks(cx).is_some_and(|l| l.items.iter().any(|h| h.id == "e2e-desk" && h.is_default))
    })
    .await;
    pass &= ok("the destination is the default", default);

    // Delete… (the confirmation is answered yes by the pass).
    let target = cx
        .update(hooks)
        .and_then(|l| l.items.into_iter().find(|h| h.id == "e2e-desk"));
    in_pane(cx, move |p, window, cx| p.open_editor(target, window, cx));
    wait_until(cx, Duration::from_secs(10), |cx| {
        sheet::current::<WebhookEditorSheet>(cx).is_some()
    })
    .await;
    in_sheet(cx, |s, window, cx| s.press_delete(window, cx));
    pass &= ok("Delete… closes the sheet", wait_closed(cx).await);
    let gone = wait_until(cx, Duration::from_secs(10), |cx| {
        hooks(cx).is_some_and(|l| !l.items.iter().any(|h| h.id == "e2e-desk"))
    })
    .await;
    pass &= ok("the destination is deleted", gone);
    pass
}
