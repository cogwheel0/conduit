//! `--e2e channels`: channels end to end on the seeded server.
//!
//! The seed has a group channel, trail-crew, shared with a second user
//! (Riley) who posted three messages the admin has not read. Riley acts
//! through `owui.sh peer` (the server's API and a socket of Riley's own,
//! `tool/local_owui/channel_peer.py`), and an app's card is put in the
//! channel before the pass (an app is a remote service the local server
//! cannot reach, so its buttons answer with the server's error).
//!
//! Checks: the channel lists with its unread count and opens (from a
//! `conduit://channel` link) read; its messages, the app's card and the
//! day heading draw; a post from the composer; Riley's post, reaction and
//! typing arrive live; react, pin, edit and delete; a thread with a reply;
//! an app button's refused press, and a private app answer with Dismiss;
//! unread counted while another channel is in front, then Mark as Read;
//! mentions-only dims the row; a direct message from Riley titled by
//! Riley; the members sheet removes and adds Riley; New Channel, Edit
//! Channel and Delete Channel; the reaction picker. Screenshots in light
//! and dark, and AccessKit checks of the pane.

use std::path::Path;
use std::process::Command;
use std::time::Duration;

use conduit_protocol::{ChannelKind, ChannelSummary};
use gpui_kit::{App, AsyncApp, Entity};

use super::{
    E2eInputs, NO_SERVER, ax, connect_server, fresh_profile, has, in_main, in_setup, ok, settle,
    shell_links, shoot_main, sign_in_password, wait_main, wait_route, wait_setup, wait_until,
};
use crate::AppState;
use crate::smoke::current_route;
use crate::stores::channel::ChannelStore;
use crate::stores::navigation::{Area, AreaItem};
use crate::stores::session::Route;
use crate::views::channels::{ChannelCommand, ChannelMenu, ChannelPane};

/// The peer helper: Riley, acting on the local server.
fn peer(args: &[&str]) -> Option<serde_json::Value> {
    let script =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../tool/local_owui/owui.sh");
    let out = Command::new(script).arg("peer").args(args).output().ok()?;
    if !out.status.success() {
        println!(
            "SMOKE note peer {} failed: {}",
            args.first().copied().unwrap_or_default(),
            String::from_utf8_lossy(&out.stderr)
                .lines()
                .last()
                .unwrap_or_default()
        );
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    serde_json::from_str(text.lines().last().unwrap_or("null")).ok()
}

fn pane(cx: &mut App) -> Option<Entity<ChannelPane>> {
    crate::views::channels::current_pane(cx)
}

fn store(cx: &mut App) -> Option<Entity<ChannelStore>> {
    Some(pane(cx)?.read(cx).store.clone())
}

fn channels(cx: &mut App) -> Vec<ChannelSummary> {
    cx.global::<AppState>()
        .stores
        .areas
        .read(cx)
        .channels
        .clone()
        .unwrap_or_default()
}

fn channel(id: &str, cx: &mut App) -> Option<ChannelSummary> {
    channels(cx).into_iter().find(|c| c.id == id)
}

/// The open channel's message whose text contains `text`.
fn message_with(text: &str, cx: &mut App) -> Option<conduit_protocol::ChannelMessageDto> {
    let store = store(cx)?;
    let s = store.read(cx);
    s.list
        .messages()
        .iter()
        .chain(s.thread.iter().flat_map(|t| t.list.messages()))
        .find(|m| m.content.contains(text))
        .cloned()
}

fn open_channel(id: &str, cx: &mut AsyncApp) {
    let id = id.to_string();
    cx.update(|cx| {
        let nav = cx.global::<AppState>().stores.navigation.clone();
        nav.update(cx, |n, cx| n.open_item(AreaItem::Channel(id), cx));
    });
}

/// Runs `f` with the main window, without holding its view (the channel
/// pane is read through the view, which an update would hold).
fn in_window(cx: &mut AsyncApp, f: impl FnOnce(&mut gpui_kit::Window, &mut App)) {
    let Some(handle) = cx.update(|cx| cx.try_global::<AppState>().and_then(|s| s.main_window))
    else {
        return;
    };
    let _ = handle.update(cx, |_, window: &mut gpui_kit::Window, cx: &mut App| {
        f(window, cx)
    });
}

/// Runs `f` on the open channel's pane, with the main window.
fn in_pane(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut ChannelPane, &mut gpui_kit::Window, &mut gpui_kit::Context<ChannelPane>),
) {
    let Some(view) = cx.update(pane) else {
        return;
    };
    in_window(cx, move |window, cx| {
        view.update(cx, |p, cx| f(p, window, cx))
    });
}

async fn command(channel_id: &str, command: ChannelCommand, cx: &mut AsyncApp) {
    let menu = ChannelMenu {
        channel_id: channel_id.to_string(),
        command,
    };
    let stores = cx.update(|cx| cx.global::<AppState>().stores.clone());
    in_window(cx, move |window, cx| {
        crate::views::channels::run_channel_command(&stores, &menu, None, window, cx)
    });
}

/// Types `text` in the channel's composer (or its thread's) and sends it.
fn post(text: &str, thread: bool, cx: &mut AsyncApp) {
    let text = text.to_string();
    in_pane(cx, move |p, window, cx| {
        let composer = if thread {
            p.thread_composer.clone()
        } else {
            p.composer.clone()
        };
        composer.update(cx, |c, cx| {
            c.set_text(&text, window, cx);
            c.submit(window, cx);
        });
    });
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let Some(trail) = inputs.get("OWUI_CHANNEL") else {
        return ok("OWUI_CHANNEL in the env file (owui.sh reset)", false);
    };
    let riley = inputs
        .get("OWUI_SECOND_NAME")
        .unwrap_or_else(|| "Riley Example".into());
    // The app's card goes in before the first read of the channel.
    let app_card = peer(&["app", &trail]);
    let mut pass = ok(
        "an app's card is in trail-crew (owui.sh peer app)",
        app_card.is_some(),
    );

    let routed = wait_until(cx, Duration::from_secs(90), |cx| {
        current_route(cx) != Route::Unknown
    })
    .await;
    pass &= ok("routed", routed);
    if cx.update(current_route) != Route::Onboarding {
        pass &= fresh_profile(cx).await;
    }
    pass &= ok("the setup window opened", wait_setup(cx).await.is_some());
    in_setup(cx, |sw, window, cx| {
        sw.onboarding.update(cx, |o, cx| o.choose(window, cx))
    });
    settle(cx, 500).await;
    connect_server(&url, "Lab server", cx).await;
    pass &= wait_route(cx, Route::SignIn, Duration::from_secs(60)).await;
    sign_in_password(&email, &password, cx).await;
    pass &= wait_route(cx, Route::Main, Duration::from_secs(60)).await;
    let Some(main) = wait_main(cx).await else {
        return ok("main window", false);
    };

    // ── The list ──────────────────────────────────────────────────────
    let listed = wait_until(cx, Duration::from_secs(60), |cx| {
        channel(&trail, cx).is_some_and(|c| c.unread >= 3)
    })
    .await;
    pass &= ok("trail-crew lists with its unread messages", listed);
    let group = cx.update(|cx| channel(&trail, cx));
    pass &= ok(
        "trail-crew is a group the user (its maker) may edit, leave and delete",
        group.as_ref().is_some_and(|c| {
            c.kind == ChannelKind::Group && c.can_leave && c.can_delete && c.manager
        }),
    );
    pass &= ok(
        "New Channel is offered",
        cx.update(|cx| {
            cx.global::<AppState>()
                .stores
                .areas
                .read(cx)
                .channels_can_create
        }),
    );

    // ── Open from a link: read, with its messages ─────────────────────
    shell_links(&[&format!("conduit://channel/{trail}")], cx);
    let opened = wait_until(cx, Duration::from_secs(20), |cx| {
        store(cx).is_some_and(|s| {
            let s = s.read(cx);
            s.loaded && s.details.is_some() && s.list.len() >= 4
        })
    })
    .await;
    pass &= ok(
        "conduit://channel opens the channel with its messages",
        opened,
    );
    let read = wait_until(cx, Duration::from_secs(15), |cx| {
        channel(&trail, cx).is_some_and(|c| c.unread == 0)
    })
    .await;
    pass &= ok("opening the channel reads it (unread 0)", read);
    let seeded = cx.update(|cx| message_with("north trailhead", cx));
    pass &= ok(
        "Riley's seeded message shows under Riley's name",
        seeded
            .as_ref()
            .is_some_and(|m| m.user.as_ref().is_some_and(|u| u.name == riley) && !m.mine),
    );
    let card = cx.update(|cx| message_with("Seed order shipped", cx));
    pass &= ok(
        "the app's message carries its card and buttons",
        card.as_ref().and_then(|m| m.app.as_ref()).is_some_and(|a| {
            a.embeds.first().is_some_and(|e| e.title == "Order 1042")
                && a.actions
                    .iter()
                    .any(|x| x.action_id.as_deref() == Some("track"))
                && a.actions.iter().any(|x| x.url.is_some())
        }),
    );
    let rows = cx.update(|cx| {
        pane(cx)
            .map(|p| p.read(cx).timeline.read(cx).rows().to_vec())
            .unwrap_or_default()
    });
    pass &= ok(
        "the timeline heads the day and groups Riley's run",
        rows.iter()
            .any(|r| matches!(r, crate::views::channels::model::TimelineRow::Day(_)))
            && rows
                .iter()
                .filter(|r| {
                    matches!(
                        r,
                        crate::views::channels::model::TimelineRow::Message {
                            group_start: false,
                            ..
                        }
                    )
                })
                .count()
                >= 1,
    );
    settle(cx, 800).await;
    shoot_main(dir, "channel", cx).await;

    // ── Post from the composer ────────────────────────────────────────
    post("Bringing trail mix for everyone", false, cx);
    let posted = wait_until(cx, Duration::from_secs(15), |cx| {
        message_with("Bringing trail mix", cx).is_some_and(|m| m.mine)
    })
    .await;
    pass &= ok("a post from the composer shows as the user's", posted);
    let mine = cx
        .update(|cx| message_with("Bringing trail mix", cx))
        .map(|m| m.id)
        .unwrap_or_default();

    // ── Riley: a post, a reaction and typing, live ────────────────────
    let water = peer(&["post", &trail, "Water stop at the ridge"]);
    pass &= ok("Riley posted (peer)", water.is_some());
    let live = wait_until(cx, Duration::from_secs(15), |cx| {
        message_with("Water stop at the ridge", cx).is_some()
    })
    .await;
    pass &= ok("Riley's post arrives live (channels.message)", live);
    pass &= ok(
        "a post in the channel in front leaves it read",
        cx.update(|cx| channel(&trail, cx).is_some_and(|c| c.unread == 0)),
    );
    peer(&["react", &trail, &mine, "👍"]);
    let reacted = wait_until(cx, Duration::from_secs(15), |cx| {
        message_with("Bringing trail mix", cx).is_some_and(|m| {
            m.reactions
                .iter()
                .any(|r| r.name == "👍" && r.count == 1 && !r.mine)
        })
    })
    .await;
    pass &= ok("Riley's reaction arrives live", reacted);
    let typing_peer = {
        let trail = trail.clone();
        std::thread::spawn(move || peer(&["typing", &trail, "5"]))
    };
    let typing = wait_until(cx, Duration::from_secs(12), |cx| {
        store(cx).is_some_and(|s| !s.read(cx).typing.is_empty())
    })
    .await;
    pass &= ok("Riley typing shows above the composer", typing);
    if typing {
        settle(cx, 300).await;
        shoot_main(dir, "channel-typing", cx).await;
    }
    let _ = typing_peer.join();
    let stopped = wait_until(cx, Duration::from_secs(10), |cx| {
        store(cx).is_some_and(|s| s.read(cx).typing.is_empty())
    })
    .await;
    pass &= ok("the typing line goes when Riley stops", stopped);

    // ── React, pin, edit, delete ─────────────────────────────────────
    let water_id = cx
        .update(|cx| message_with("Water stop", cx))
        .map(|m| m.id)
        .unwrap_or_default();
    cx.update(|cx| {
        if let Some(s) = store(cx) {
            let id = water_id.clone();
            s.update(cx, |s, cx| s.toggle_reaction(&id, "🎉", cx));
        }
    });
    let my_reaction = wait_until(cx, Duration::from_secs(10), |cx| {
        message_with("Water stop", cx)
            .is_some_and(|m| m.reactions.iter().any(|r| r.name == "🎉" && r.mine))
    })
    .await;
    pass &= ok("a reaction of the user's shows as theirs", my_reaction);
    // The picker under the pointer: a click on an emoji reacts.
    {
        let id = water_id.clone();
        in_pane(cx, move |p, window, cx| {
            p.show_reaction_picker(
                id,
                gpui_kit::point(gpui_kit::px(400.), gpui_kit::px(300.)),
                window,
                cx,
            )
        });
    }
    settle(cx, 400).await;
    shoot_main(dir, "channel-reaction-picker", cx).await;
    let picker_ax = ax(main, "channel-picker", dir, cx).await;
    pass &= ok(
        "the reaction picker names its emoji for VoiceOver",
        has(&picker_ax, "Button", "👀"),
    );
    press_key(main, "escape", cx);
    settle(cx, 300).await;
    pass &= ok(
        "Esc closes the reaction picker",
        cx.update(|cx| pane(cx).is_some_and(|p| !p.read(cx).picker_open())),
    );

    cx.update(|cx| {
        if let Some(s) = store(cx) {
            let id = mine.clone();
            s.update(cx, |s, cx| s.set_pinned(&id, true, cx));
        }
    });
    let pinned = wait_until(cx, Duration::from_secs(10), |cx| {
        message_with("Bringing trail mix", cx).is_some_and(|m| m.pinned)
    })
    .await;
    pass &= ok("pinning marks the message", pinned);
    cx.update(|cx| {
        if let Some(s) = store(cx) {
            let id = mine.clone();
            s.update(cx, |s, cx| s.start_editing(Some(id), cx));
        }
    });
    settle(cx, 500).await;
    shoot_main(dir, "channel-editing", cx).await;
    cx.update(|cx| {
        if let Some(s) = store(cx) {
            let id = mine.clone();
            s.update(cx, |s, cx| {
                s.save_edit(&id, "Bringing trail mix and spare socks".into(), cx)
            });
        }
    });
    let edited = wait_until(cx, Duration::from_secs(10), |cx| {
        message_with("spare socks", cx).is_some_and(|m| m.edited_at_ms.is_some() || m.mine)
    })
    .await;
    pass &= ok("an own message is edited", edited);

    // ── A thread ──────────────────────────────────────────────────────
    {
        let id = water_id.clone();
        in_pane(cx, move |p, window, cx| p.open_thread(id, window, cx));
    }
    let thread_open = wait_until(cx, Duration::from_secs(10), |cx| {
        store(cx).is_some_and(|s| s.read(cx).thread.as_ref().is_some_and(|t| !t.loading))
    })
    .await;
    pass &= ok(
        "Reply in Thread opens the thread beside the channel",
        thread_open,
    );
    post("I can carry the water filter", true, cx);
    let replied = wait_until(cx, Duration::from_secs(15), |cx| {
        store(cx).is_some_and(|s| {
            s.read(cx).thread.as_ref().is_some_and(|t| {
                t.list
                    .messages()
                    .iter()
                    .any(|m| m.content.contains("water filter"))
            })
        })
    })
    .await;
    pass &= ok("a reply in the thread shows there", replied);
    let counted = wait_until(cx, Duration::from_secs(15), |cx| {
        store(cx).is_some_and(|s| {
            s.read(cx)
                .list
                .get(&water_id)
                .is_some_and(|m| m.reply_count >= 1)
        })
    })
    .await;
    pass &= ok("the parent counts its reply", counted);
    settle(cx, 500).await;
    shoot_main(dir, "channel-thread", cx).await;
    in_pane(cx, |p, window, cx| p.close_thread(window, cx));

    // ── An app: a refused button, then a private answer ───────────────
    let card_id = card.as_ref().map(|m| m.id.clone()).unwrap_or_default();
    cx.update(|cx| {
        if let Some(s) = store(cx) {
            let id = card_id.clone();
            s.update(cx, |s, cx| s.press_app_action(&id, "track", None, cx));
        }
    });
    let answered = wait_until(cx, Duration::from_secs(20), |cx| {
        store(cx).is_some_and(|s| s.read(cx).pending_actions.is_empty())
    })
    .await;
    let toasted = wait_until(cx, Duration::from_secs(5), |cx| {
        !cx.global::<AppState>()
            .stores
            .toasts
            .read(cx)
            .toasts
            .is_empty()
    })
    .await;
    pass &= ok(
        "an app button the app cannot answer says so (the server's reason)",
        answered && toasted,
    );
    // A private answer, as `channels.appReply` brings one.
    cx.update(|cx| {
        if let Some(s) = store(cx) {
            let reply: conduit_protocol::ChannelAppReplyEvent =
                serde_json::from_value(serde_json::json!({
                    "channelId": trail, "messageId": card_id, "appId": "conduit-e2e-builder",
                    "appName": "Seed Tracker",
                    "reply": {
                        "kind": "download", "title": "Order report",
                        "content": "# Order 1042\n\nFour packets.", "filename": "order-1042.md",
                    },
                }))
                .unwrap();
            s.update(cx, |s, cx| s.add_app_reply(reply, cx));
        }
    });
    settle(cx, 600).await;
    let shown = cx.update(|cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx).timeline.read(cx).rows().iter().any(|r| {
                matches!(
                    r,
                    crate::views::channels::model::TimelineRow::AppReply { .. }
                )
            })
        })
    });
    pass &= ok("an app's private answer shows under its message", shown);
    let pane_ax = ax(main, "channel", dir, cx).await;
    pass &= ok(
        "the private answer is marked as the user's alone, with Dismiss",
        has(&pane_ax, "Button", "Dismiss") && has(&pane_ax, "Button", "Download order-1042.md"),
    );
    pass &= ok(
        "the app's buttons and the pane's controls are labelled",
        has(&pane_ax, "Button", "Track Parcel")
            && has(&pane_ax, "Button", "Members")
            && has(&pane_ax, "Button", "More"),
    );
    shoot_main(dir, "channel-app", cx).await;
    cx.update(|cx| {
        if let Some(s) = store(cx) {
            let id = card_id.clone();
            s.update(cx, |s, cx| {
                s.dismiss_app_reply(&id, "conduit-e2e-builder", cx)
            });
        }
    });
    settle(cx, 300).await;
    pass &= ok(
        "Dismiss takes the private answer away",
        cx.update(|cx| store(cx).is_some_and(|s| s.read(cx).app_replies.is_empty())),
    );

    // ── Delete an own message ─────────────────────────────────────────
    cx.update(|cx| {
        if let Some(s) = store(cx) {
            let id = mine.clone();
            s.update(cx, |s, cx| s.delete(&id, cx));
        }
    });
    let deleted = wait_until(cx, Duration::from_secs(10), |cx| {
        message_with("spare socks", cx).is_none()
    })
    .await;
    pass &= ok("an own message is deleted", deleted);

    // ── Unread while another channel is in front; Mark as Read ────────
    let garden = cx.update(|cx| {
        channels(cx)
            .into_iter()
            .find(|c| c.name == "garden-club")
            .map(|c| c.id)
    });
    if let Some(garden) = &garden {
        open_channel(garden, cx);
        wait_until(cx, Duration::from_secs(10), |cx| {
            store(cx).is_some_and(|s| s.read(cx).channel_id() == garden && s.read(cx).loaded)
        })
        .await;
        settle(cx, 800).await;
        peer(&["post", &trail, "Forecast moved: rain after two"]);
        let counted = wait_until(cx, Duration::from_secs(15), |cx| {
            channel(&trail, cx).is_some_and(|c| c.unread >= 1)
        })
        .await;
        pass &= ok("a post in a channel not in front counts as unread", counted);
        command(&trail, ChannelCommand::MarkRead, cx).await;
        let marked = wait_until(cx, Duration::from_secs(10), |cx| {
            channel(&trail, cx).is_some_and(|c| c.unread == 0)
        })
        .await;
        pass &= ok("Mark as Read clears it", marked);
        // Mentions only: the row dims and counts no badge.
        command(&trail, ChannelCommand::Notify { muted: true }, cx).await;
        let muted = wait_until(cx, Duration::from_secs(10), |cx| {
            channel(&trail, cx).is_some_and(|c| c.muted)
        })
        .await;
        pass &= ok("Mentions Only is kept for the channel", muted);
        let dimmed = cx.update(|cx| {
            let view = cx.global::<AppState>().main_view.clone();
            view.is_some_and(|v| {
                v.read(cx).sidebar.read(cx).rows().iter().any(|r| match r {
                    crate::views::sidebar_model::SidebarItem::AreaRow(row) => {
                        row.item == AreaItem::Channel(trail.clone()) && row.dimmed
                    }
                    _ => false,
                })
            })
        });
        pass &= ok("a mentions-only channel's row is dimmed", dimmed);
        command(&trail, ChannelCommand::Notify { muted: false }, cx).await;
        wait_until(cx, Duration::from_secs(10), |cx| {
            channel(&trail, cx).is_some_and(|c| !c.muted)
        })
        .await;
    } else {
        pass &= ok("garden-club is listed", false);
    }

    // ── A direct message from Riley ───────────────────────────────────
    let dm = peer(&["dm", "Hi from the trail, see you Saturday"]);
    let dm_id = dm
        .as_ref()
        .and_then(|v| v["channel"].as_str())
        .unwrap_or_default()
        .to_string();
    let dm_listed = wait_until(cx, Duration::from_secs(20), |cx| {
        channel(&dm_id, cx).is_some()
    })
    .await;
    pass &= ok("Riley's direct message lists", dm_listed);
    let dm_summary = cx.update(|cx| channel(&dm_id, cx));
    pass &= ok(
        "a direct message is titled by the other person",
        dm_summary
            .as_ref()
            .is_some_and(|c| c.kind == ChannelKind::Dm && c.title == riley),
    );
    open_channel(&dm_id, cx);
    let dm_open = wait_until(cx, Duration::from_secs(15), |cx| {
        message_with("see you Saturday", cx).is_some()
    })
    .await;
    pass &= ok("the direct message opens with Riley's message", dm_open);
    let toolbar_title = cx.update(|cx| {
        cx.global::<AppState>()
            .main_view
            .clone()
            .and_then(|v| v.read(cx).area_pane.read(cx).title(cx))
    });
    pass &= ok(
        "the pane's title is Riley's name",
        toolbar_title.as_deref() == Some(riley.as_str()),
    );
    settle(cx, 500).await;
    shoot_main(dir, "channel-dm", cx).await;

    // ── Members ───────────────────────────────────────────────────────
    open_channel(&trail, cx);
    wait_until(cx, Duration::from_secs(10), |cx| {
        store(cx).is_some_and(|s| s.read(cx).channel_id() == trail && s.read(cx).details.is_some())
    })
    .await;
    command(&trail, ChannelCommand::Members, cx).await;
    let sheet_listed = wait_until(cx, Duration::from_secs(15), |cx| {
        crate::views::sheet::current::<crate::views::channels::members::MembersSheet>(cx)
            .is_some_and(|s| {
                s.read(cx)
                    .page
                    .as_ref()
                    .is_some_and(|p| p.members.iter().any(|m| m.name == riley) && p.can_manage)
            })
    })
    .await;
    pass &= ok(
        "the members sheet lists Riley, and the user manages them",
        sheet_listed,
    );
    if let Some(handle) = cx.update(|cx| crate::views::sheet::current_window(cx)) {
        crate::smoke::shoot_both_modes(handle, dir, "channel-members", cx).await;
    }
    let riley_member = cx.update(|cx| {
        crate::views::sheet::current::<crate::views::channels::members::MembersSheet>(cx).and_then(
            |s| {
                s.read(cx)
                    .page
                    .as_ref()
                    .and_then(|p| p.members.iter().find(|m| m.name == riley).cloned())
            },
        )
    });
    if let (Some(member), Some(handle)) = (
        riley_member,
        cx.update(|cx| crate::views::sheet::current_window(cx)),
    ) {
        let _ = handle.update(cx, |_, window: &mut gpui_kit::Window, cx: &mut App| {
            if let Some(s) =
                crate::views::sheet::current::<crate::views::channels::members::MembersSheet>(cx)
            {
                s.update(cx, |s, cx| s.remove(member.clone(), window, cx));
            }
        });
        let removed = wait_until(cx, Duration::from_secs(15), |cx| {
            crate::views::sheet::current::<crate::views::channels::members::MembersSheet>(cx)
                .is_some_and(|s| {
                    s.read(cx)
                        .page
                        .as_ref()
                        .is_some_and(|p| !p.members.iter().any(|m| m.id == member.id))
                })
        })
        .await;
        pass &= ok("Remove takes Riley out of the channel", removed);
        // Add People…: Riley back.
        let _ = handle.update(cx, |_, window: &mut gpui_kit::Window, cx: &mut App| {
            if let Some(s) =
                crate::views::sheet::current::<crate::views::channels::members::MembersSheet>(cx)
            {
                s.update(cx, |s, cx| {
                    s.start_adding(window, cx);
                    // A typed name finds people (the field's own change
                    // event does not fire for a value set in code).
                    s.search
                        .update(cx, |i, cx| i.set_value("Riley", window, cx));
                    s.find("Riley".into(), cx);
                });
            }
        });
        let found = wait_until(cx, Duration::from_secs(15), |cx| {
            crate::views::sheet::current::<crate::views::channels::members::MembersSheet>(cx)
                .is_some_and(|s| s.read(cx).found.iter().any(|p| p.id == member.id))
        })
        .await;
        pass &= ok("Add People finds Riley", found);
        crate::smoke::shoot_both_modes(handle, dir, "channel-members-add", cx).await;
        let _ = handle.update(cx, |_, window: &mut gpui_kit::Window, cx: &mut App| {
            if let Some(s) =
                crate::views::sheet::current::<crate::views::channels::members::MembersSheet>(cx)
            {
                let principal = s.read(cx).found.iter().find(|p| p.id == member.id).cloned();
                if let Some(p) = principal {
                    s.update(cx, |s, cx| {
                        s.toggle_chosen(p, cx);
                        s.add(window, cx);
                    });
                }
            }
        });
        let added = wait_until(cx, Duration::from_secs(15), |cx| {
            crate::views::sheet::current::<crate::views::channels::members::MembersSheet>(cx)
                .is_some_and(|s| {
                    let s = s.read(cx);
                    s.page
                        .as_ref()
                        .is_some_and(|p| p.members.iter().any(|m| m.id == member.id))
                })
        })
        .await;
        pass &= ok("Add puts Riley back", added);
    } else {
        pass &= ok("Riley is in the members sheet", false);
    }
    cx.update(crate::views::sheet::dismiss);
    settle(cx, 600).await;

    // ── New Channel, Edit Channel, Delete Channel ─────────────────────
    in_main(cx, |mw, window, cx| {
        crate::views::channels::form::open_new(mw.stores.clone(), window, cx)
    });
    let form_open = wait_until(cx, Duration::from_secs(5), |cx| {
        crate::views::sheet::current::<crate::views::channels::form::ChannelForm>(cx).is_some()
    })
    .await;
    pass &= ok("New Channel opens its sheet", form_open);
    if let Some(handle) = cx.update(|cx| crate::views::sheet::current_window(cx)) {
        let _ = handle.update(cx, |_, window: &mut gpui_kit::Window, cx: &mut App| {
            if let Some(f) =
                crate::views::sheet::current::<crate::views::channels::form::ChannelForm>(cx)
            {
                let (name, description) = (f.read(cx).name.clone(), f.read(cx).description.clone());
                name.update(cx, |s, cx| s.set_value("seed-swap", window, cx));
                description.update(cx, |s, cx| s.set_value("Trading spare seeds.", window, cx));
            }
        });
        settle(cx, 300).await;
        crate::smoke::shoot_both_modes(handle, dir, "channel-new", cx).await;
        let _ = handle.update(cx, |_, window: &mut gpui_kit::Window, cx: &mut App| {
            if let Some(f) =
                crate::views::sheet::current::<crate::views::channels::form::ChannelForm>(cx)
            {
                f.update(cx, |f, cx| f.save(window, cx));
            }
        });
    }
    let made = wait_until(cx, Duration::from_secs(15), |cx| {
        channels(cx).iter().any(|c| c.name == "seed-swap")
            && store(cx).is_some_and(|s| {
                channels(cx)
                    .iter()
                    .any(|c| c.name == "seed-swap" && c.id == s.read(cx).channel_id())
            })
    })
    .await;
    pass &= ok("a new channel is made, listed and opened", made);
    let made_id = cx
        .update(|cx| channels(cx).into_iter().find(|c| c.name == "seed-swap"))
        .map(|c| c.id)
        .unwrap_or_default();
    pass &= ok(
        "the user may edit and delete the channel they made",
        cx.update(|cx| channel(&made_id, cx).is_some_and(|c| c.manager && c.can_delete)),
    );
    command(&made_id, ChannelCommand::Edit, cx).await;
    settle(cx, 600).await;
    if let Some(handle) = cx.update(|cx| crate::views::sheet::current_window(cx)) {
        let _ = handle.update(cx, |_, window: &mut gpui_kit::Window, cx: &mut App| {
            if let Some(f) =
                crate::views::sheet::current::<crate::views::channels::form::ChannelForm>(cx)
            {
                let name = f.read(cx).name.clone();
                name.update(cx, |s, cx| s.set_value("seed-swap-spring", window, cx));
                f.update(cx, |f, cx| f.save(window, cx));
            }
        });
    }
    let renamed = wait_until(cx, Duration::from_secs(15), |cx| {
        channel(&made_id, cx).is_some_and(|c| c.name == "seed-swap-spring")
    })
    .await;
    pass &= ok("Edit Channel renames it", renamed);
    command(&made_id, ChannelCommand::Delete, cx).await;
    let gone = wait_until(cx, Duration::from_secs(15), |cx| {
        channel(&made_id, cx).is_none()
            && cx
                .global::<AppState>()
                .stores
                .navigation
                .read(cx)
                .selected_item()
                != Some(&AreaItem::Channel(made_id.clone()))
    })
    .await;
    pass &= ok("Delete Channel takes it away and closes its pane", gone);

    // ── The sidebar ───────────────────────────────────────────────────
    open_channel(&trail, cx);
    // The list draws only what is on screen and the chats fill it: closed,
    // the Channels section is in view.
    in_main(cx, |mw, _, cx| {
        mw.sidebar
            .update(cx, |s, cx| s.toggle_area(Area::Chats, cx))
    });
    settle(cx, 1200).await;
    shoot_main(dir, "channel-sidebar", cx).await;
    let sidebar_ax = ax(main, "channel-sidebar", dir, cx).await;
    in_main(cx, |mw, _, cx| {
        mw.sidebar
            .update(cx, |s, cx| s.toggle_area(Area::Chats, cx))
    });
    pass &= ok(
        "the sidebar offers New Channel and lists the channels",
        has(&sidebar_ax, "Button", "New Channel") && has(&sidebar_ax, "TreeItem", "trail-crew"),
    );
    cx.update(|cx| {
        let areas = cx.global::<AppState>().stores.areas.clone();
        areas.update(cx, |a, cx| a.refresh(Area::Channels, cx))
    });
    pass
}

fn press_key(handle: gpui_kit::AnyWindowHandle, key: &str, cx: &mut AsyncApp) {
    super::press(handle, key, cx);
}
