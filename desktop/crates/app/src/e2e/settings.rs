//! `--e2e settings`: Settings' phone pages against the local Open WebUI:
//! Profile (a field changed and put back), Personalization (a memory
//! added and deleted), Chat (switches and a quick action that persist in
//! the daemon, message actions reordered and reset), Connection (the
//! socket's health), Audio, Data Controls behind Advanced (the library
//! exported into a throwaway folder), Accounts' Sign Out, About, and the
//! after-update release notes (banner, sheet). Each pane is shot in light
//! and dark, and its controls are read through AccessKit.

use std::path::Path;
use std::time::Duration;

use conduit_protocol::{AppSettingsDto, NoParams, ProfileDto, methods};
use gpui_kit::{AnyWindowHandle, AsyncApp, Entity};
use serde_json::Value;

use super::*;
use crate::l10n::ActiveL10n as _;
use crate::views::settings::SettingsView;

fn settings_view(cx: &mut App) -> Option<(AnyWindowHandle, Entity<SettingsView>)> {
    cx.try_global::<AppState>()?.settings_window.clone()
}

/// Runs `f` on the Settings view with its window.
fn in_settings<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut SettingsView, &mut Window, &mut gpui_kit::Context<SettingsView>) -> R,
) -> Option<R> {
    let (handle, view) = cx.update(settings_view)?;
    handle
        .update(cx, |_, window, cx| {
            view.update(cx, |v, cx| f(v, window, cx))
        })
        .ok()
}

/// The daemon's settings, asked afresh (what persisted, not what a store
/// shows).
async fn daemon_settings(cx: &mut AsyncApp) -> Option<AppSettingsDto> {
    let call = cx.update(|cx| {
        cx.global::<AppState>()
            .connection
            .read(cx)
            .rpc()
            .call::<methods::SettingsGet>(&NoParams)
    });
    call.await.ok()
}

async fn daemon_profile(cx: &mut AsyncApp) -> Option<ProfileDto> {
    let call = cx.update(|cx| {
        cx.global::<AppState>()
            .connection
            .read(cx)
            .rpc()
            .call::<methods::ProfileGet>(&NoParams)
    });
    call.await.ok()
}

/// A tall Settings window, for the long panes' shots.
const TALL: f32 = 1040.;

/// Puts the Settings window back at its size, or tall.
fn size_settings(tall: bool, cx: &mut AsyncApp) {
    let Some((handle, _)) = cx.update(settings_view) else {
        return;
    };
    if let Some(ns) = cx.update(|cx| crate::smoke::ns_window(handle, cx)) {
        let size = if tall {
            (crate::views::settings::SETTINGS_SIZE.0, TALL)
        } else {
            crate::views::settings::SETTINGS_SIZE
        };
        crate::smoke::place(&ns, (300., 40.), size);
    }
}

/// Opens `tab`, shoots it (light and dark), and reads its controls.
async fn pane(tab: Tab, dir: &Path, name: &str, cx: &mut AsyncApp) -> Vec<String> {
    shot(tab, dir, name, false, cx).await
}

/// [`pane`], `tall` for a long pane, so it shows whole.
async fn shot(tab: Tab, dir: &Path, name: &str, tall: bool, cx: &mut AsyncApp) -> Vec<String> {
    cx.update(|cx| crate::open_settings(Some(tab), cx));
    settle(cx, 600).await;
    let Some((handle, _)) = cx.update(settings_view) else {
        return vec![];
    };
    size_settings(tall, cx);
    settle(cx, 500).await;
    shoot_both_modes(handle, dir, name, cx).await;
    let controls = ax(handle, name, dir, cx).await;
    if tall {
        size_settings(false, cx);
    }
    controls
}

/// Shoots the Settings window as it is now (`tall` for a long pane).
async fn again(dir: &Path, name: &str, tall: bool, cx: &mut AsyncApp) {
    let Some((handle, _)) = cx.update(settings_view) else {
        return;
    };
    size_settings(tall, cx);
    settle(cx, 500).await;
    shoot_both_modes(handle, dir, name, cx).await;
    if tall {
        size_settings(false, cx);
    }
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let mut pass = super::chat::sign_in(&url, &email, &password, cx).await;
    let loaded = wait_until(cx, Duration::from_secs(20), |cx| {
        cx.global::<AppState>().stores.app_settings.read(cx).loaded
    })
    .await;
    pass &= ok("settings.get answered after sign-in", loaded);

    // Every pane of an Open WebUI account is listed, in the phone's order.
    cx.update(|cx| crate::open_settings(Some(Tab::Desktop), cx));
    settle(cx, 600).await;
    let tabs = cx.update(|cx| {
        let stores = cx.global::<AppState>().stores.clone();
        Tab::visible(&stores, cx)
    });
    pass &= ok(
        &format!("the account's panes are listed, Data Controls not yet ({tabs:?})"),
        tabs.contains(&Tab::Profile)
            && tabs.contains(&Tab::Connection)
            && tabs.contains(&Tab::Chats)
            && !tabs.contains(&Tab::DataControls),
    );

    pass &= profile(dir, cx).await;
    pass &= personalization(dir, cx).await;
    pass &= chats(dir, cx).await;
    pass &= connection(dir, cx).await;
    pass &= audio(dir, cx).await;
    pass &= data_controls(dir, cx).await;
    pass &= accounts_and_about(dir, cx).await;
    pass &= release_notes(dir, cx).await;
    pass
}

async fn profile(dir: &Path, cx: &mut AsyncApp) -> bool {
    let controls = shot(Tab::Profile, dir, "settings-profile", true, cx).await;
    let mut pass = ok(
        "Profile has its fields, Save Profile and Change Password",
        has(&controls, "TextInput", "Name")
            && has(&controls, "Button", "Save Profile")
            && has(&controls, "Button", "Choose Photo")
            && has(&controls, "ComboBox", "Gender"),
    );
    let ready = wait_until(cx, Duration::from_secs(20), |cx| {
        settings_view(cx).is_some_and(|(_, v)| {
            v.read(cx)
                .profile
                .as_ref()
                .is_some_and(|p| p.read(cx).profile.is_some())
        })
    })
    .await;
    pass &= ok("the profile loaded", ready);
    let before = daemon_profile(cx).await;
    let original = before
        .as_ref()
        .and_then(|p| p.bio.clone())
        .unwrap_or_default();
    // A new bio, saved; then the one it had.
    for bio in ["Keeps bees on a quiet roof.", original.as_str()] {
        in_settings(cx, |v, window, cx| {
            if let Some(p) = v.profile.clone() {
                p.update(cx, |p, cx| {
                    p.bio
                        .update(cx, |i, cx| i.set_value(bio.to_string(), window, cx));
                    p.save(window, cx);
                });
            }
        });
        let saved = wait_until(cx, Duration::from_secs(20), |cx| {
            settings_view(cx).is_some_and(|(_, v)| {
                v.read(cx).profile.as_ref().is_some_and(|p| {
                    let p = p.read(cx);
                    !p.busy
                        && p.profile
                            .as_ref()
                            .is_some_and(|d| d.bio.clone().unwrap_or_default() == bio)
                })
            })
        })
        .await;
        let stored = daemon_profile(cx)
            .await
            .and_then(|p| p.bio)
            .unwrap_or_default();
        pass &= ok(
            &format!("the bio saved as {bio:?} (server: {stored:?})"),
            saved && stored == bio,
        );
        if bio != original {
            again(dir, "settings-profile-saved", true, cx).await;
        }
    }
    // Choosing Custom shows the field for the user's own words.
    in_settings(cx, |v, window, cx| {
        v.choose("profile-gender", "custom", window, cx)
    });
    settle(cx, 300).await;
    let custom = in_settings(cx, |v, _, cx| {
        v.profile
            .as_ref()
            .is_some_and(|p| p.read(cx).gender == "custom")
    })
    .unwrap_or(false);
    pass &= ok("a custom gender shows its field", custom);
    // Put the pop-up back without saving: the stored gender stays.
    let stored_gender = before.and_then(|p| p.gender).unwrap_or_default();
    let back = match stored_gender.as_str() {
        "" | "male" | "female" => stored_gender.clone(),
        _ => "custom".into(),
    };
    in_settings(cx, |v, window, cx| {
        v.choose("profile-gender", &back, window, cx)
    });
    pass
}

async fn personalization(dir: &Path, cx: &mut AsyncApp) -> bool {
    let controls = shot(
        Tab::Personalization,
        dir,
        "settings-personalization",
        true,
        cx,
    )
    .await;
    let mut pass = ok(
        "Personalization has the default model, Memory and Add Memory",
        has(&controls, "ComboBox", "Default Model")
            && has(&controls, "Switch", "Memory")
            && has(&controls, "Button", "Add Memory"),
    );
    let ready = wait_until(cx, Duration::from_secs(20), |cx| {
        settings_view(cx).is_some_and(|(_, v)| {
            v.read(cx)
                .personalization
                .as_ref()
                .is_some_and(|p| p.read(cx).memories.is_some())
        })
    })
    .await;
    pass &= ok("the memories loaded", ready);
    // Its own words each run, so a memory an earlier run left is never
    // taken for it.
    let memory_text = format!("Waters the ferns on Sundays (run {}).", std::process::id());
    let text = memory_text.clone();
    in_settings(cx, |v, window, cx| {
        if let Some(p) = v.personalization.clone() {
            p.update(cx, |p, cx| {
                p.open_editor(None, window, cx);
                p.memory_input
                    .update(cx, |i, cx| i.set_value(text.clone(), window, cx));
                p.save_memory(window, cx);
            });
        }
    });
    let memory_id = move |cx: &mut App| -> Option<String> {
        let (_, v) = settings_view(cx)?;
        let p = v.read(cx).personalization.clone()?;
        let list = p.read(cx).memories.clone()?;
        list.items
            .iter()
            .find(|m| m.content == memory_text)
            .map(|m| m.id.clone())
    };
    let added = wait_until(cx, Duration::from_secs(20), |cx| memory_id(cx).is_some()).await;
    let id = cx.update(|cx| memory_id(cx));
    pass &= ok("a memory was added", added);
    again(dir, "settings-personalization-memory", true, cx).await;
    if let Some(id) = id.clone() {
        in_settings(cx, |v, window, cx| {
            if let Some(p) = v.personalization.clone() {
                p.update(cx, |p, cx| p.delete_memory(id, window, cx));
            }
        });
    }
    let gone = id.clone();
    let deleted = wait_until(cx, Duration::from_secs(20), move |cx| {
        settings_view(cx)
            .and_then(|(_, v)| v.read(cx).personalization.clone())
            .and_then(|p| p.read(cx).memories.clone())
            .is_some_and(|l| !l.items.iter().any(|m| Some(&m.id) == gone.as_ref()))
    })
    .await;
    pass &= ok(
        "the memory was deleted (the sheet answered Delete)",
        deleted,
    );
    pass
}

async fn chats(dir: &Path, cx: &mut AsyncApp) -> bool {
    let controls = shot(Tab::Chats, dir, "settings-chat", true, cx).await;
    let mut pass = ok(
        "Chat has the composer switches, message actions and Advanced",
        has(&controls, "Switch", "Send with Enter")
            && has(&controls, "Switch", "Start Temporary Chats")
            && has(&controls, "Switch", "Automatic Actions")
            && has(&controls, "Switch", "Advanced"),
    );
    let read = daemon_settings(cx).await;
    let before = read.clone().unwrap_or_default();
    // Three switches and a quick action, through the controls' own calls.
    in_settings(cx, |v, _, cx| {
        let store = v.chats.clone();
        if let Some(c) = store {
            c.update(cx, |c, cx| c.toggle_pill("web", cx));
        }
        let app = cx.global::<AppState>().stores.app_settings.clone();
        app.update(cx, |s, cx| {
            s.set(
                conduit_protocol::AppSettingsPatch {
                    send_on_enter: Some(!before.send_on_enter),
                    temporary_chat_by_default: Some(!before.temporary_chat_by_default),
                    show_composer_notes_button: Some(!before.show_composer_notes_button),
                    ..Default::default()
                },
                cx,
            )
        });
    });
    settle(cx, 800).await;
    let after = daemon_settings(cx).await.unwrap_or_default();
    pass &= ok(
        &format!(
            "the switches and the Web quick action persist in the daemon ({:?})",
            (
                after.send_on_enter,
                after.temporary_chat_by_default,
                &after.quick_pills
            )
        ),
        after.send_on_enter != before.send_on_enter
            && after.temporary_chat_by_default != before.temporary_chat_by_default
            && after.show_composer_notes_button != before.show_composer_notes_button
            && after.quick_pills.contains(&"web".to_string())
                != before.quick_pills.contains(&"web".to_string()),
    );
    let shown = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .app_settings
            .read(cx)
            .settings()
            .send_on_enter
    });
    pass &= ok(
        "the store shows what the daemon has",
        shown == after.send_on_enter,
    );
    // Off by default only as the daemon read it: an unread value is no proof.
    let default = read.map(|s| s.show_model_name_in_composer);
    pass &= model_name_in_message_box(&controls, default, cx).await;

    // Message actions: Automatic off, Regenerate up, then Reset.
    in_settings(cx, |v, _, cx| {
        if let Some(c) = v.chats.clone() {
            c.update(cx, |c, cx| c.set_automatic(false, cx));
        }
    });
    settle(cx, 600).await;
    in_settings(cx, |v, _, cx| {
        if let Some(c) = v.chats.clone() {
            c.update(cx, |c, cx| c.move_action("regenerate", -1, cx));
        }
    });
    settle(cx, 600).await;
    let reordered = daemon_settings(cx)
        .await
        .and_then(|s| s.inline_message_actions);
    pass &= ok(
        &format!("Regenerate moved up ({reordered:?})"),
        reordered.as_deref().is_some_and(|a| {
            let at = |name: &str| a.iter().position(|x| x == name);
            matches!((at("regenerate"), at("tts")), (Some(r), Some(t)) if r < t)
        }),
    );
    again(dir, "settings-chat-actions", true, cx).await;
    in_settings(cx, |v, _, cx| {
        if let Some(c) = v.chats.clone() {
            c.update(cx, |c, cx| c.set_automatic(true, cx));
        }
    });
    settle(cx, 600).await;
    let reset = daemon_settings(cx).await;
    pass &= ok(
        "Reset to Defaults goes back to Automatic",
        reset
            .as_ref()
            .is_some_and(|s| s.inline_message_actions.is_none()),
    );
    // Put the switches back.
    in_settings(cx, |v, _, cx| {
        if let Some(c) = v.chats.clone() {
            c.update(cx, |c, cx| c.toggle_pill("web", cx));
        }
        let app = cx.global::<AppState>().stores.app_settings.clone();
        app.update(cx, |s, cx| {
            s.set(
                conduit_protocol::AppSettingsPatch {
                    send_on_enter: Some(before.send_on_enter),
                    temporary_chat_by_default: Some(before.temporary_chat_by_default),
                    show_composer_notes_button: Some(before.show_composer_notes_button),
                    ..Default::default()
                },
                cx,
            )
        });
    });
    settle(cx, 600).await;
    pass
}

/// The main window's empty message box, as it reads now.
fn placeholder(cx: &mut App) -> Option<(String, Option<String>)> {
    let pane = super::chat::pane(cx)?;
    let pane = pane.read(cx);
    let shown = pane.composer.read(cx).shown_placeholder().to_string();
    let model = pane
        .composer_store
        .read(cx)
        .selected_model()
        .map(|m| m.name.clone());
    Some((shown, model))
}

/// Show Model Name in Message Box (mobile's #1053): off by default; on, the
/// empty message box asks the selected model by name; off again, the app's
/// own words come back.
async fn model_name_in_message_box(
    controls: &[String],
    default: Option<bool>,
    cx: &mut AsyncApp,
) -> bool {
    let mut pass = ok(
        "Chat has Show Model Name in Message Box, off by default",
        has(controls, "Switch", "Show Model Name in Message Box") && default == Some(false),
    );
    let plain = cx.update(|cx| cx.l10n().message_hint_text());
    let before = cx.update(placeholder);
    pass &= ok(
        &format!("off, the message box says the app's words ({before:?})"),
        before.as_ref().is_some_and(|(shown, _)| *shown == plain),
    );
    let set = |on: bool, cx: &mut AsyncApp| {
        in_settings(cx, move |_, _, cx| {
            let app = cx.global::<AppState>().stores.app_settings.clone();
            app.update(cx, |s, cx| {
                s.set(
                    conduit_protocol::AppSettingsPatch {
                        show_model_name_in_composer: Some(on),
                        ..Default::default()
                    },
                    cx,
                )
            });
        });
    };
    set(true, cx);
    let named = wait_until(cx, Duration::from_secs(10), |cx| {
        placeholder(cx).is_some_and(|(shown, model)| {
            let want = model
                .as_deref()
                .and_then(crate::stores::composer::placeholder_model_name)
                .map(|n| cx.l10n().message_hint_text_for_model(&n));
            want.is_some_and(|w| shown == w && w.starts_with("Ask "))
        })
    })
    .await;
    let persisted = daemon_settings(cx)
        .await
        .is_some_and(|s| s.show_model_name_in_composer);
    pass &= ok(
        &format!(
            "on, it persists and the message box asks the model ({:?})",
            cx.update(placeholder)
        ),
        named && persisted,
    );
    set(false, cx);
    let back = wait_until(cx, Duration::from_secs(10), move |cx| {
        placeholder(cx).is_some_and(|(shown, _)| shown == plain)
    })
    .await;
    pass &= ok("off again, the app's words come back", back);
    // The profile keeps the value it started with.
    if default == Some(true) {
        set(true, cx);
    }
    pass
}

async fn connection(dir: &Path, cx: &mut AsyncApp) -> bool {
    let healthy = wait_until(cx, Duration::from_secs(30), |cx| {
        let s = cx.global::<AppState>().stores.app_settings.clone();
        s.update(cx, |s, cx| s.refresh_health(cx));
        s.read(cx)
            .health
            .as_ref()
            .is_some_and(|h| h.available && h.connected)
    })
    .await;
    let controls = pane(Tab::Connection, dir, "settings-connection", cx).await;
    ok("the socket is connected", healthy)
        & ok(
            "Connection has the transport choice and the health rows",
            has(&controls, "RadioButton", "WebSocket Only")
                || has(&controls, "Button", "WebSocket Only")
                || controls.iter().any(|c| c.contains("WebSocket Only")),
        )
}

async fn audio(dir: &Path, cx: &mut AsyncApp) -> bool {
    let controls = shot(Tab::Audio, dir, "settings-audio", true, cx).await;
    let mut pass = ok(
        "Audio has the engine, voice and speed controls and Preview",
        has(&controls, "ComboBox", "Speech Recognition")
            && has(&controls, "ComboBox", "Playback Voice")
            && has(&controls, "Button", "Preview Voice"),
    );
    let before = daemon_settings(cx).await.unwrap_or_default();
    in_settings(cx, |_, _, cx| {
        let app = cx.global::<AppState>().stores.app_settings.clone();
        app.update(cx, |s, cx| {
            s.set(
                conduit_protocol::AppSettingsPatch {
                    tts_speed: Some(1.25),
                    voice_barge_in_enabled: Some(!before.voice_barge_in_enabled),
                    ..Default::default()
                },
                cx,
            )
        });
    });
    settle(cx, 600).await;
    let after = daemon_settings(cx).await.unwrap_or_default();
    pass &= ok(
        "the speed and barge-in persist",
        (after.tts_speed - 1.25).abs() < 0.01
            && after.voice_barge_in_enabled != before.voice_barge_in_enabled,
    );
    in_settings(cx, |_, _, cx| {
        let app = cx.global::<AppState>().stores.app_settings.clone();
        app.update(cx, |s, cx| {
            s.set(
                conduit_protocol::AppSettingsPatch {
                    tts_speed: Some(before.tts_speed),
                    voice_barge_in_enabled: Some(before.voice_barge_in_enabled),
                    ..Default::default()
                },
                cx,
            )
        });
    });
    settle(cx, 400).await;
    pass
}

async fn data_controls(dir: &Path, cx: &mut AsyncApp) -> bool {
    // Advanced shows Data Controls.
    in_settings(cx, |_, _, cx| {
        let app = cx.global::<AppState>().stores.app_settings.clone();
        app.update(cx, |s, cx| {
            s.set(
                conduit_protocol::AppSettingsPatch {
                    advanced_features_enabled: Some(true),
                    ..Default::default()
                },
                cx,
            )
        });
    });
    let shown = wait_until(cx, Duration::from_secs(10), |cx| {
        let stores = cx.global::<AppState>().stores.clone();
        Tab::visible(&stores, cx).contains(&Tab::DataControls)
    })
    .await;
    let mut pass = ok("Advanced lists Data Controls", shown);
    let controls = pane(Tab::DataControls, dir, "settings-data-controls", cx).await;
    pass &= ok(
        "Data Controls has Export, Archive and Delete",
        has(&controls, "Button", "Export")
            && has(&controls, "Button", "Archive")
            && has(&controls, "Button", "Delete"),
    );
    // The library, exported into a throwaway folder.
    let folder = std::env::temp_dir().join(format!("conduit-e2e-export-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&folder);
    let file = folder.join("chat-export.json");
    let target = file.clone();
    in_settings(cx, |v, window, cx| {
        if let Some(d) = v.data_controls.clone() {
            d.update(cx, |d, cx| d.export_to(target, window, cx));
        }
    });
    let done = wait_until(cx, Duration::from_secs(60), |cx| {
        settings_view(cx).is_some_and(|(_, v)| {
            v.read(cx)
                .data_controls
                .as_ref()
                .is_some_and(|d| d.read(cx).outcome.is_some())
        })
    })
    .await;
    let outcome = cx.update(|cx| {
        settings_view(cx).and_then(|(_, v)| {
            v.read(cx)
                .data_controls
                .as_ref()
                .and_then(|d| d.read(cx).outcome.clone())
        })
    });
    let chats = std::fs::read_to_string(&file)
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| v.as_array().map(Vec::len));
    pass &= ok(
        &format!("the library was exported ({outcome:?}, {chats:?} chats)"),
        done && outcome.as_ref().is_some_and(|o| o.ok) && chats.is_some_and(|n| n > 0),
    );
    again(dir, "settings-data-controls-exported", false, cx).await;
    // Advanced off again; the pane goes with it.
    in_settings(cx, |_, _, cx| {
        let app = cx.global::<AppState>().stores.app_settings.clone();
        app.update(cx, |s, cx| {
            s.set(
                conduit_protocol::AppSettingsPatch {
                    advanced_features_enabled: Some(false),
                    ..Default::default()
                },
                cx,
            )
        });
    });
    settle(cx, 600).await;
    let gone = cx.update(|cx| {
        let stores = cx.global::<AppState>().stores.clone();
        !Tab::visible(&stores, cx).contains(&Tab::DataControls)
    });
    pass &= ok("turning Advanced off hides Data Controls", gone);
    pass
}

async fn accounts_and_about(dir: &Path, cx: &mut AsyncApp) -> bool {
    let accounts = pane(Tab::Accounts, dir, "settings-accounts-sign-out", cx).await;
    let mut pass = ok(
        "Accounts ends with Sign Out",
        has(&accounts, "Button", "Sign Out"),
    );
    cx.update(|cx| crate::open_settings(Some(Tab::About), cx));
    let about = wait_until(cx, Duration::from_secs(15), |cx| {
        settings_view(cx).is_some_and(|(_, v)| {
            v.read(cx)
                .about_info
                .as_ref()
                .is_some_and(|a| a.server && a.server_version.is_some())
        })
    })
    .await;
    pass &= ok("About shows the server's version", about);
    let controls = shot(Tab::About, dir, "settings-about", true, cx).await;
    pass &= ok(
        "About has What's New, the repository and Support Conduit",
        has(&controls, "Button", "What's New")
            && has(&controls, "Button", "GitHub Repository")
            && has(&controls, "Button", "Buy Me a Coffee"),
    );
    pass
}

async fn release_notes(dir: &Path, cx: &mut AsyncApp) -> bool {
    // As after an update: an older version first, then this one.
    cx.update(|cx| {
        let stores = cx.global::<AppState>().stores.clone();
        crate::views::release_notes::check("0.8.0", &stores, cx);
    });
    settle(cx, 800).await;
    cx.update(|cx| {
        let stores = cx.global::<AppState>().stores.clone();
        crate::views::release_notes::check("0.9.0", &stores, cx);
    });
    let banner = wait_until(cx, Duration::from_secs(10), |cx| {
        cx.try_global::<crate::views::release_notes::ReleaseNotesGlobal>()
            .is_some_and(|g| g.0.read(cx).banner.is_some())
    })
    .await;
    let mut pass = ok("an update shows the release-notes banner", banner);
    if let Some((handle, _)) = cx.update(settings_view) {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
    settle(cx, 600).await;
    shoot_main(dir, "release-notes-banner", cx).await;
    // Learn More: the sheet, on the main window.
    in_main(cx, |_, window, cx| {
        crate::views::release_notes::show_banner_notes(window, cx)
    });
    settle(cx, 1200).await;
    // One of the main window's sheets, on the shared host.
    let sheet = cx.update(|cx| crate::views::release_notes::sheet_window(cx));
    pass &= ok("Learn More opens the notes as a sheet", sheet.is_some());
    if let Some(main) = cx.update(main_window).map(|(h, _)| h) {
        shoot_both_modes(main, dir, "release-notes-sheet", cx).await;
    }
    cx.update(|cx| crate::views::release_notes::close_sheet(true, cx));
    settle(cx, 800).await;
    let dismissed = cx.update(|cx| {
        cx.try_global::<crate::views::release_notes::ReleaseNotesGlobal>()
            .is_some_and(|g| g.0.read(cx).banner.is_none())
            && crate::views::release_notes::sheet_window(cx).is_none()
            && !crate::views::sheet::is_open(cx)
    });
    pass &= ok("Done closes the sheet and the banner", dismissed);
    // The next launch of the same version shows none.
    cx.update(|cx| {
        let stores = cx.global::<AppState>().stores.clone();
        crate::views::release_notes::check("0.9.0", &stores, cx);
    });
    settle(cx, 800).await;
    let none = cx.update(|cx| {
        cx.try_global::<crate::views::release_notes::ReleaseNotesGlobal>()
            .is_some_and(|g| g.0.read(cx).banner.is_none())
    });
    pass &= ok("a dismissed banner stays gone", none);
    pass
}
