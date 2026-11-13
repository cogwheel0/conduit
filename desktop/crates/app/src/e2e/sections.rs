//! `--e2e sections`: the sidebar's areas, on the seeded server.
//!
//! Signs in to the local Open WebUI (seven notes, three channels, an admin
//! who manages every workspace section), then: the sections appear in the
//! phone's order under their headings, as `system.capabilities` says; the
//! notes list pinned first and stops at Show All; a channel shows its
//! unread count; a heading closes its section and the state is written per
//! account; the arrow keys cross the sections and ← and → close and open
//! them; `conduit://note` and `conduit://channel` open the item's pane; Go
//! › a section and Back and Forward; a note saved and a channel made
//! appear on `notes.changed` and `channels.changed`; Scheduled Tasks waits
//! for Settings' Advanced, as on the phone; and Hermes switched on and off
//! adds and takes away its section (`capabilities.changed`).
//! Screenshots in light and dark, and AccessKit checks of the headings.

use std::path::Path;
use std::time::Duration;

use conduit_daemon::RpcMethod;
use conduit_protocol::{ChannelEdit, HermesSettingsEdit, NoteSave, methods};
use gpui_kit::{AnyWindowHandle, App, AsyncApp};

use super::shell_links;
use super::{
    E2eInputs, NO_SERVER, ax, connect_server, fresh_profile, has, in_main, in_setup, ok, press,
    settle, shoot_main, sign_in_password, wait_main, wait_route, wait_setup, wait_until,
};
use crate::AppState;
use crate::smoke::current_route;
use crate::stores::navigation::{Area, AreaItem, Selection, WorkspaceSection};
use crate::stores::session::Route;
use crate::views::sidebar_keys::{KeyRow, ListKey};
use crate::views::sidebar_model::{AREA_FIRST, SidebarItem};

/// The sidebar's rows, as drawn last.
fn rows(cx: &mut App) -> Vec<SidebarItem> {
    let Some(view) = cx
        .try_global::<AppState>()
        .and_then(|s| s.main_view.clone())
    else {
        return vec![];
    };
    view.read(cx).sidebar.read(cx).rows().to_vec()
}

/// The areas under headings, in order, with whether each is open.
fn headings(cx: &mut App) -> Vec<(Area, bool)> {
    rows(cx)
        .iter()
        .filter_map(|r| match r {
            SidebarItem::AreaHeader { area, expanded } => Some((*area, *expanded)),
            _ => None,
        })
        .collect()
}

/// The items listed in `area`, in order (All Notes, which opens the list
/// pane, is no item of the list).
fn items(area: Area, cx: &mut App) -> Vec<AreaItem> {
    rows(cx)
        .iter()
        .filter_map(SidebarItem::area_item)
        .filter(|i| i.area() == area && **i != AreaItem::AllNotes)
        .cloned()
        .collect()
}

fn selection(cx: &mut App) -> Selection {
    cx.global::<AppState>()
        .stores
        .navigation
        .read(cx)
        .selection()
        .clone()
}

fn cursor(cx: &mut App) -> Option<KeyRow> {
    let view = cx.global::<AppState>().main_view.clone()?;
    view.read(cx).sidebar.read(cx).cursor().cloned()
}

async fn call<M: RpcMethod>(params: &M::Params, cx: &mut AsyncApp) -> bool
where
    M::Result: Send + 'static,
{
    let rpc = cx.update(|cx| cx.global::<AppState>().connection.read(cx).rpc());
    match rpc.call::<M>(params).await {
        Ok(_) => true,
        Err(e) => {
            println!("SMOKE note {} failed: {e}", M::NAME);
            false
        }
    }
}

/// The sidebar's sections file, as written.
fn sections_file(cx: &mut App) -> String {
    let path = cx
        .global::<AppState>()
        .paths
        .user_data
        .join("sidebar-sections.json");
    std::fs::read_to_string(path).unwrap_or_default()
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let routed = wait_until(cx, Duration::from_secs(90), |cx| {
        current_route(cx) != Route::Unknown
    })
    .await;
    let mut pass = ok("routed", routed);
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

    // ── Scheduled tasks wait for Settings' Advanced, as on the phone ──
    // The seed's server offers a terminal (owui.sh's "Build box").
    let without = [
        Area::Chats,
        Area::Notes,
        Area::Terminal,
        Area::Channels,
        Area::Workspace,
        Area::Calendar,
    ];
    let gated = wait_until(cx, Duration::from_secs(60), move |cx| {
        headings(cx).iter().map(|(a, _)| *a).collect::<Vec<_>>() == without
    })
    .await;
    pass &= ok(
        "with Advanced off there is no Scheduled Tasks section",
        gated,
    );
    cx.update(|cx| {
        let settings = cx.global::<AppState>().stores.app_settings.clone();
        settings.update(cx, |s, cx| {
            s.set(
                conduit_protocol::AppSettingsPatch {
                    advanced_features_enabled: Some(true),
                    ..Default::default()
                },
                cx,
            )
        })
    });

    // ── Sections, as the capabilities say ─────────────────────────────
    // The seed's server offers a terminal (owui.sh's "Build box").
    let expected = [
        Area::Chats,
        Area::Notes,
        Area::Terminal,
        Area::Channels,
        Area::Workspace,
        Area::Calendar,
        Area::Automations,
    ];
    let shown = wait_until(cx, Duration::from_secs(60), |cx| {
        headings(cx).iter().map(|(a, _)| *a).collect::<Vec<_>>() == expected
    })
    .await;
    let now: Vec<Area> = cx.update(|cx| headings(cx).iter().map(|(a, _)| *a).collect());
    pass &= ok(
        &format!("an Open WebUI admin's sections in the phone's order ({now:?})"),
        shown,
    );
    let caps = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .session
            .read(cx)
            .system_capabilities
            .clone()
    });
    pass &= ok(
        "system.capabilities answers with the account's real flags",
        caps.as_ref().is_some_and(|c| {
            c.notes
                && c.channels
                && c.calendar
                && c.automations
                && c.scheduled_tasks
                && c.workspace_prompts
                && c.folders
                && c.terminal
                && !c.hermes_only
        }),
    );

    // Notes: pinned first, the first few, then Show All.
    let note_count: usize = inputs
        .get("OWUI_NOTE_COUNT")
        .and_then(|n| n.parse().ok())
        .unwrap_or(7);
    let listed = wait_until(cx, Duration::from_secs(60), |cx| {
        items(Area::Notes, cx).len() == AREA_FIRST.min(note_count)
    })
    .await;
    pass &= ok("the notes list their first few", listed);
    // Pins arrive with the sync, a moment after the first list.
    let first_two = wait_until(cx, Duration::from_secs(30), |cx| {
        let store = cx.global::<AppState>().stores.areas.read(cx);
        let notes: Vec<_> = store.notes.iter().flatten().collect();
        notes.len() >= 2 && notes.iter().take(2).all(|n| n.pinned)
    })
    .await;
    pass &= ok("pinned notes come first", first_two);
    pass &= ok(
        "a long section ends in Show All",
        cx.update(|cx| {
            rows(cx).contains(&SidebarItem::ShowAll {
                area: Area::Notes,
                all: false,
            })
        }),
    );
    // Channels: the group with unread messages says how many.
    let unread_wanted: i64 = inputs
        .get("OWUI_CHANNEL_UNREAD")
        .and_then(|n| n.parse().ok())
        .unwrap_or(3);
    let unread = wait_until(cx, Duration::from_secs(30), |cx| {
        cx.global::<AppState>()
            .stores
            .areas
            .read(cx)
            .channels
            .iter()
            .flatten()
            .any(|c| c.unread == unread_wanted)
    })
    .await;
    pass &= ok("a channel shows its unread count", unread);
    pass &= ok(
        "the workspace lists every section an admin manages",
        cx.update(|cx| items(Area::Workspace, cx))
            == WorkspaceSection::ALL.map(AreaItem::Workspace).to_vec(),
    );
    settle(cx, 600).await;
    shoot_main(dir, "sections", cx).await;
    // The list draws only what is on screen, and the chats fill it: closed,
    // every other heading is in view.
    in_main(cx, |mw, _, cx| {
        mw.sidebar
            .update(cx, |s, cx| s.toggle_area(Area::Chats, cx))
    });
    settle(cx, 600).await;
    shoot_main(dir, "sections-overview", cx).await;
    let controls = ax(main, "sections", dir, cx).await;
    in_main(cx, |mw, _, cx| {
        mw.sidebar
            .update(cx, |s, cx| s.toggle_area(Area::Chats, cx))
    });
    pass &= ok(
        "the sections are headings that say they are open",
        has(&controls, "Heading", "Chats [collapsed]")
            && has(&controls, "Heading", "Notes [expanded]")
            && has(&controls, "Heading", "Channels [expanded]")
            && has(&controls, "Heading", "Scheduled Tasks [expanded]"),
    );
    pass &= ok(
        "an area's rows are labelled tree items",
        has(&controls, "TreeItem", "Garden plan for spring")
            && has(&controls, "TreeItem", "3 unread")
            && has(&controls, "TreeItem", "Show All"),
    );

    // Show All, then Show Less.
    in_main(cx, |mw, _, cx| {
        mw.sidebar
            .update(cx, |s, cx| s.toggle_show_all(Area::Notes, cx))
    });
    let all = wait_until(cx, Duration::from_secs(5), |cx| {
        items(Area::Notes, cx).len() == note_count
    })
    .await;
    pass &= ok("Show All lists every note", all);
    shoot_main(dir, "sections-show-all", cx).await;
    in_main(cx, |mw, _, cx| {
        mw.sidebar
            .update(cx, |s, cx| s.toggle_show_all(Area::Notes, cx))
    });

    // ── A heading closes its section, kept per account ────────────────
    in_main(cx, |mw, _, cx| {
        mw.sidebar.update(cx, |s, cx| {
            s.toggle_area(Area::Notes, cx);
            s.toggle_area(Area::Workspace, cx);
        })
    });
    let closed = wait_until(cx, Duration::from_secs(5), |cx| {
        headings(cx).contains(&(Area::Notes, false)) && items(Area::Notes, cx).is_empty()
    })
    .await;
    pass &= ok("a heading closes its section", closed);
    let written = wait_until(cx, Duration::from_secs(5), |cx| {
        let text = sections_file(cx);
        text.contains("\"notes\"") && text.contains("\"workspace\"") && text.contains("account:")
    })
    .await;
    pass &= ok("what is closed is written for this account", written);
    shoot_main(dir, "sections-collapsed", cx).await;
    in_main(cx, |mw, _, cx| {
        mw.sidebar
            .update(cx, |s, cx| s.toggle_area(Area::Chats, cx))
    });
    settle(cx, 400).await;
    let collapsed_ax = ax(main, "sections-collapsed", dir, cx).await;
    in_main(cx, |mw, _, cx| {
        mw.sidebar
            .update(cx, |s, cx| s.toggle_area(Area::Chats, cx))
    });
    pass &= ok(
        "a closed section's heading says so",
        has(&collapsed_ax, "Heading", "Notes [collapsed]"),
    );

    // ── The keyboard crosses the sections ─────────────────────────────
    // From the section under Notes: Terminal on the seeded server.
    in_main(cx, |mw, window, cx| {
        mw.sidebar
            .update(cx, |s, cx| s.go_to_area(Area::Terminal, window, cx))
    });
    settle(cx, 300).await;
    pass &= ok(
        "Go to a section puts the keyboard on its heading",
        cx.update(cursor) == Some(KeyRow::Area(Area::Terminal)),
    );
    // ↑ from Terminal: the closed Notes heading (its rows are hidden).
    press(main, "up", cx);
    settle(cx, 200).await;
    pass &= ok(
        "↑ goes to the section above",
        cx.update(cursor) == Some(KeyRow::Area(Area::Notes)),
    );
    press(main, "right", cx);
    let opened = wait_until(cx, Duration::from_secs(5), |cx| {
        headings(cx).contains(&(Area::Notes, true))
    })
    .await;
    pass &= ok("→ opens a closed section", opened);
    press(main, "right", cx);
    settle(cx, 300).await;
    let on_note = cx.update(cursor);
    // Its first row is All Notes, which opens the notes list.
    pass &= ok(
        &format!("→ again steps into it, and its first row opens ({on_note:?})"),
        on_note == Some(KeyRow::Item(AreaItem::AllNotes))
            && cx.update(selection) == Selection::Area(AreaItem::AllNotes),
    );
    press(main, "left", cx);
    settle(cx, 200).await;
    pass &= ok(
        "← goes up to the heading",
        cx.update(cursor) == Some(KeyRow::Area(Area::Notes)),
    );
    press(main, "left", cx);
    let shut = wait_until(cx, Duration::from_secs(5), |cx| {
        headings(cx).contains(&(Area::Notes, false))
    })
    .await;
    pass &= ok("← there closes it", shut);
    in_main(cx, |mw, _, cx| {
        mw.sidebar.update(cx, |s, cx| s.key(ListKey::Right, cx))
    });
    settle(cx, 300).await;
    // From the Chats area's last row, ↓ reaches the next heading.
    in_main(cx, |mw, window, cx| {
        mw.sidebar
            .update(cx, |s, cx| s.go_to_area(Area::Notes, window, cx))
    });
    settle(cx, 200).await;
    press(main, "up", cx);
    settle(cx, 200).await;
    let above = cx.update(cursor);
    press(main, "down", cx);
    settle(cx, 200).await;
    pass &= ok(
        &format!("↓ from the chats' last row reaches the Notes heading ({above:?})"),
        above.is_some_and(|k| !matches!(k, KeyRow::Area(_)))
            && cx.update(cursor) == Some(KeyRow::Area(Area::Notes)),
    );
    shoot_main(dir, "sections-keyboard", cx).await;

    // ── Links open the item's pane ────────────────────────────────────
    if let Some(note) = inputs.get("OWUI_NOTE") {
        shell_links(&[&format!("conduit://note/{note}")], cx);
        let shown = wait_until(cx, Duration::from_secs(10), |cx| {
            selection(cx) == Selection::Area(AreaItem::Note(note.clone()))
        })
        .await;
        pass &= ok("conduit://note/<id> opens the note's pane", shown);
        let title = in_main(cx, |mw, _, cx| mw.area_pane.read(cx).title(cx)).flatten();
        pass &= ok(
            &format!("the pane names the note ({title:?})"),
            title.as_deref() == Some("Garden plan for spring"),
        );
        settle(cx, 400).await;
        shoot_main(dir, "sections-note-pane", cx).await;
        let pane_ax = ax(main, "sections-note-pane", dir, cx).await;
        pass &= ok(
            "the pane's title is a heading",
            has(&pane_ax, "Heading", "Garden plan for spring"),
        );
    } else {
        pass &= ok("OWUI_NOTE in the env file (owui.sh reset)", false);
    }
    if let Some(channel) = inputs.get("OWUI_CHANNEL") {
        shell_links(&[&format!("conduit://channel/{channel}")], cx);
        let shown = wait_until(cx, Duration::from_secs(10), |cx| {
            selection(cx) == Selection::Area(AreaItem::Channel(channel.clone()))
        })
        .await;
        pass &= ok("conduit://channel/<id> opens the channel's pane", shown);
        shoot_main(dir, "sections-channel-pane", cx).await;
    }

    // ── Go › Back and Forward ─────────────────────────────────────────
    let dispatch = |action: Box<dyn gpui_kit::Action>, handle: AnyWindowHandle, cx: &mut App| {
        let _ = handle.update(cx, |_, window, cx| window.dispatch_action(action, cx));
    };
    cx.update(|cx| dispatch(Box::new(crate::actions::GoBack), main, cx));
    let back = wait_until(cx, Duration::from_secs(5), |cx| {
        matches!(selection(cx), Selection::Area(AreaItem::Note(_)))
    })
    .await;
    pass &= ok("Back shows the note again", back);
    cx.update(|cx| dispatch(Box::new(crate::actions::GoForward), main, cx));
    let forward = wait_until(cx, Duration::from_secs(5), |cx| {
        matches!(selection(cx), Selection::Area(AreaItem::Channel(_)))
    })
    .await;
    pass &= ok("Forward shows the channel again", forward);
    let menus = cx.update(|cx| crate::menus::menu_state(cx));
    pass &= ok(
        "the Go menu lists the sections and can go back",
        menus.areas == expected && menus.can_go_back && !menus.can_go_forward,
    );
    cx.update(|cx| dispatch(Box::new(crate::actions::GoToSection { index: 1 }), main, cx));
    settle(cx, 300).await;
    pass &= ok(
        "⌘1 goes to the first section",
        cx.update(cursor) == Some(KeyRow::Area(Area::Chats)),
    );

    // ── Lists follow notes.changed and channels.changed ───────────────
    let saved = call::<methods::NotesSave>(
        &NoteSave {
            id: None,
            title: "Kite knots".into(),
            ops: None,
            page_id: None,
            base_ops: None,
            account_id: None,
        },
        cx,
    )
    .await;
    let appeared = saved
        && wait_until(cx, Duration::from_secs(30), |cx| {
            cx.global::<AppState>()
                .stores
                .areas
                .read(cx)
                .notes
                .iter()
                .flatten()
                .any(|n| n.title == "Kite knots")
        })
        .await;
    pass &= ok("a note saved elsewhere appears (notes.changed)", appeared);
    let made = call::<methods::ChannelsSave>(
        &ChannelEdit {
            id: None,
            name: "seed-swap".into(),
            description: Some("Swapping saved seeds.".into()),
            private: false,
        },
        cx,
    )
    .await;
    let listed = made
        && wait_until(cx, Duration::from_secs(30), |cx| {
            cx.global::<AppState>()
                .stores
                .areas
                .read(cx)
                .channels
                .iter()
                .flatten()
                .any(|c| c.name == "seed-swap")
        })
        .await;
    pass &= ok(
        "a channel made elsewhere appears (channels.changed)",
        listed,
    );

    // ── Hermes on and off: its section comes and goes ─────────────────
    match (inputs.get("FAKE_HERMES_URL"), inputs.get("FAKE_HERMES_KEY")) {
        (Some(base_url), Some(key)) => {
            let edit = |enabled: bool| -> HermesSettingsEdit {
                serde_json::from_value(serde_json::json!({
                    "enabled": enabled,
                    "baseUrl": base_url,
                    "apiKey": key,
                }))
                .expect("a Hermes edit")
            };
            pass &= ok(
                "Hermes switched on",
                call::<methods::HermesSaveSettings>(&edit(true), cx).await,
            );
            let added = wait_until(cx, Duration::from_secs(30), |cx| {
                headings(cx).iter().any(|(a, _)| *a == Area::Hermes)
            })
            .await;
            pass &= ok(
                "Hermes's section appears beside Chats (capabilities.changed)",
                added && cx.update(|cx| headings(cx).get(1).map(|(a, _)| *a)) == Some(Area::Hermes),
            );
            // Its rows as the phone's tab has them: the connection in use
            // atop (the switcher, which comes with the connection list a
            // moment after the section), Scheduled Agents above the chats
            // when the connection runs them, Hidden Chats last. Go to a
            // section once they are in.
            let hermes_rows = |cx: &mut App| -> Vec<SidebarItem> {
                rows(cx)
                    .into_iter()
                    .skip_while(|r| {
                        !matches!(
                            r,
                            SidebarItem::AreaHeader {
                                area: Area::Hermes,
                                ..
                            }
                        )
                    })
                    .skip(1)
                    .take_while(|r| !matches!(r, SidebarItem::AreaHeader { .. }))
                    .collect()
            };
            let switcher = wait_until(cx, Duration::from_secs(30), |cx| {
                matches!(
                    hermes_rows(cx).first(),
                    Some(SidebarItem::HermesConnection { .. })
                )
            })
            .await;
            pass &= ok("the connection in use heads Hermes's section", switcher);
            in_main(cx, |mw, window, cx| {
                mw.sidebar
                    .update(cx, |s, cx| s.go_to_area(Area::Hermes, window, cx))
            });
            settle(cx, 800).await;
            let in_view = in_main(cx, |mw, _, cx| {
                mw.sidebar
                    .read(cx)
                    .row_near_top(&KeyRow::Area(Area::Hermes))
            });
            pass &= ok(
                "Go to a section brings its heading to the top",
                in_view == Some(true),
            );
            let laid = cx.update(hermes_rows);
            let at = |want: &dyn Fn(&AreaItem) -> bool| {
                laid.iter().position(|r| r.area_item().is_some_and(want))
            };
            let jobs = at(&|i| *i == AreaItem::HermesJobs);
            let first_chat = at(&|i| matches!(i, AreaItem::HermesSession(_)));
            pass &= ok(
                &format!("Scheduled Agents sits above the chats ({jobs:?} before {first_chat:?})"),
                match (jobs, first_chat) {
                    (Some(j), Some(c)) => j < c,
                    _ => true,
                },
            );
            pass &= ok(
                "Hidden Chats closes the section",
                laid.last().and_then(SidebarItem::area_item) == Some(&AreaItem::HermesHidden),
            );
            shoot_main(dir, "sections-hermes", cx).await;
            pass &= ok(
                "Hermes switched off",
                call::<methods::HermesSaveSettings>(&edit(false), cx).await,
            );
            let gone = wait_until(cx, Duration::from_secs(30), |cx| {
                !headings(cx).iter().any(|(a, _)| *a == Area::Hermes)
            })
            .await;
            pass &= ok("and goes when it is off", gone);
        }
        _ => pass &= ok("FAKE_HERMES_URL and FAKE_HERMES_KEY in the env file", false),
    }

    // Open everything again for whoever runs next on this profile.
    in_main(cx, |mw, _, cx| {
        mw.sidebar.update(cx, |s, cx| {
            if s.area_collapsed(Area::Workspace, cx) {
                s.toggle_area(Area::Workspace, cx);
            }
            if s.area_collapsed(Area::Notes, cx) {
                s.toggle_area(Area::Notes, cx);
            }
        })
    });
    settle(cx, 500).await;
    pass
}
