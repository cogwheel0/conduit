//! The main window: new chat, a short chat, the long showcase chat (every
//! block kind), streaming, a read-only shared chat, the sidebar's states,
//! the ⌘K palette, the model picker, the native menus, approval cards and
//! toasts; hover, pressed and focus states, right-click menus, a drag over
//! a folder and tooltips. `narrow` repeats the main states at 900×700.

use std::time::Duration;

use conduit_protocol::{NoticeLevel, UiInputOption, UiInputType, UiRequest, UiRequestKind};
use gpui_kit::{AnyWindowHandle, App, AsyncApp, Entity, ListOffset, MouseButton, point, px};
use serde_json::json;

use super::onboarding::{in_main, set_text};
use super::{MAIN_ORIGIN, MAIN_SIZE, NARROW_SIZE, Run, Shot, drive, log, pause, place, wait_until};
use crate::AppState;
use crate::l10n::ActiveL10n as _;
use crate::stores::chat::{ChatStore, Role};
use crate::views::chat_pane::ChatPane;
use crate::views::main_window::MainWindow;

pub(super) fn view(cx: &mut App) -> Option<Entity<MainWindow>> {
    cx.try_global::<AppState>()?.main_view.clone()
}

pub(super) fn pane(cx: &mut App) -> Option<Entity<ChatPane>> {
    Some(view(cx)?.read(cx).chat_pane.clone())
}

pub(super) fn chat_store(cx: &mut App) -> Option<Entity<ChatStore>> {
    Some(pane(cx)?.read(cx).chat.as_ref()?.store.clone())
}

fn chat_titled(title: &str, cx: &mut App) -> Option<String> {
    let list = cx.global::<AppState>().stores.chat_list.read(cx);
    list.list
        .iter()
        .flat_map(|l| l.chats.iter())
        .find(|c| c.title == title)
        .map(|c| c.id.clone())
}

fn folder_named(name: &str, cx: &mut App) -> Option<String> {
    let list = cx.global::<AppState>().stores.chat_list.read(cx);
    list.list
        .as_ref()?
        .folders
        .iter()
        .find(|f| f.name == name)
        .map(|f| f.id.clone())
}

/// Opens a chat from the sidebar and waits for its transcript.
pub(super) async fn open_chat(run: &Run, id: &str, cx: &mut AsyncApp) -> bool {
    let chat = id.to_string();
    in_main(run, cx, move |mw, _, cx| {
        mw.sidebar.update(cx, |s, cx| s.open(&chat, cx))
    });
    let want = id.to_string();
    let loaded = wait_until(cx, Duration::from_secs(30), move |cx| {
        chat_store(cx).is_some_and(|s| {
            let s = s.read(cx);
            s.chat_id() == want && s.detail.is_some() && !s.messages().is_empty()
        })
    })
    .await;
    // Images and highlighting land a moment later.
    pause(cx, 900).await;
    loaded
}

pub(super) async fn new_chat(run: &Run, cx: &mut AsyncApp) {
    in_main(run, cx, |mw, window, cx| mw.new_chat(false, window, cx));
    pause(cx, 500).await;
}

fn dispatch(run: &Run, action: Box<dyn gpui_kit::Action>, cx: &mut AsyncApp) {
    let main = run.main;
    cx.update(|cx| {
        let _ = main.update(cx, |_, window, cx| window.dispatch_action(action, cx));
    });
}

/// Writes the window's AccessKit nodes to `notes/ax/<name>.json` and
/// returns them.
pub(super) async fn ax_dump(
    run: &Run,
    handle: AnyWindowHandle,
    name: &str,
    cx: &mut AsyncApp,
) -> Vec<drive::Node> {
    let nodes = drive::nodes(handle, cx).await;
    let rows: Vec<_> = nodes
        .iter()
        .filter(|n| !n.role.is_empty() && n.role != "GenericContainer")
        .map(|n| {
            let mut row = json!({
                "role": n.role,
                "label": n.label,
                "focused": n.focused,
                "bounds": n.bounds.map(|b| [f32::from(b.origin.x), f32::from(b.origin.y), f32::from(b.size.width), f32::from(b.size.height)]),
            });
            // The states VoiceOver reads: selected, open or closed, on or
            // off, and the row or option a list reports as focused.
            if let Some(o) = row.as_object_mut() {
                if let Some(v) = n.selected {
                    o.insert("selected".into(), json!(v));
                }
                if let Some(v) = n.expanded {
                    o.insert("expanded".into(), json!(v));
                }
                if let Some(v) = &n.toggled {
                    o.insert("toggled".into(), json!(v));
                }
                if n.active {
                    o.insert("reported_focus".into(), json!(true));
                }
            }
            row
        })
        .collect();
    let out = run.path("notes/ax", &format!("{name}.json"));
    std::fs::write(out, serde_json::to_vec_pretty(&rows).unwrap_or_default()).ok();
    nodes
}

async fn find_node(
    run: &Run,
    role: &str,
    label: impl Fn(&str) -> bool,
    cx: &mut AsyncApp,
) -> Option<drive::Node> {
    let nodes = drive::nodes(run.main, cx).await;
    drive::find(&nodes, role, label).cloned()
}

/// Opens each collapsed disclosure on screen in the transcript, once each
/// (`opened` holds the labels clicked so far): one at a time, since each
/// moves the ones below it, and never twice, since a second click closes it
/// again (and quick clicks on one spot read as a multi-click that selects
/// text).
async fn open_disclosures(
    run: &Run,
    opened: &mut std::collections::BTreeSet<String>,
    cx: &mut AsyncApp,
) {
    let main = run.main;
    for _ in 0..8 {
        let nodes = drive::nodes(main, cx).await;
        let next = nodes.iter().find(|n| {
            (n.role == "Button" || n.role == "DisclosureTriangle")
                && n.expanded == Some(false)
                && !n.label.starts_with("Model:")
                && !opened.contains(&n.label)
                && n.bounds.is_some_and(|b| {
                    let (x, y) = (f32::from(b.origin.x), f32::from(b.origin.y));
                    x > 330. && y > 60. && y < 760.
                })
        });
        let Some((label, at)) = next.and_then(|n| n.center().map(|c| (n.label.clone(), c))) else {
            break;
        };
        opened.insert(label);
        drive::click(main, at, cx).await;
        pause(cx, 600).await;
    }
}

/// Scrolls the transcript until a node passing `pick` is in view; its
/// centre.
async fn reveal(
    run: &Run,
    pick: impl Fn(&drive::Node) -> bool,
    cx: &mut AsyncApp,
) -> Option<gpui_kit::Point<gpui_kit::Pixels>> {
    for _ in 0..8 {
        let nodes = drive::nodes(run.main, cx).await;
        if let Some(n) = nodes.iter().find(|n| pick(n))
            && let Some(b) = n.bounds
        {
            let y = f32::from(b.origin.y);
            if (90. ..720.).contains(&y) {
                return n.center();
            }
            scroll_transcript(None, y - 360., cx);
        } else {
            scroll_transcript(None, 480., cx);
        }
        pause(cx, 400).await;
    }
    None
}

/// Clicks the node `pick` finds, once hovering it has settled the layout
/// (an answer's action row appears on hover and moves what is under the
/// pointer; a press and release on different text would select it).
async fn click_settled(run: &Run, pick: impl Fn(&drive::Node) -> bool, cx: &mut AsyncApp) -> bool {
    let main = run.main;
    let Some(at) = drive::nodes(main, cx)
        .await
        .iter()
        .find(|n| pick(n))
        .and_then(|n| n.center())
    else {
        return false;
    };
    drive::hover(main, at, cx);
    pause(cx, 350).await;
    let Some(at) = drive::nodes(main, cx)
        .await
        .iter()
        .find(|n| pick(n))
        .and_then(|n| n.center())
    else {
        return false;
    };
    drive::hover(main, at, cx);
    pause(cx, 150).await;
    drive::click(main, at, cx).await;
    true
}

/// Hover then press (held) on a control, with a shot of each; released off
/// the control so nothing is clicked.
async fn hover_and_press(
    run: &mut Run,
    node: &drive::Node,
    area: &str,
    what: &str,
    cx: &mut AsyncApp,
) {
    let Some(at) = node.center() else { return };
    let main = run.main;
    drive::hover(main, at, cx);
    pause(cx, 120).await;
    drive::hover(main, at, cx);
    pause(cx, 250).await;
    run.interaction(
        main,
        area,
        &format!("{what}-hover"),
        &format!("{} under the pointer.", node.describe()),
        Shot::quick(),
        cx,
    )
    .await;
    drive::press(main, at, MouseButton::Left, cx);
    pause(cx, 150).await;
    run.interaction(
        main,
        area,
        &format!("{what}-pressed"),
        &format!("{} pressed (held, not released).", node.describe()),
        Shot::quick(),
        cx,
    )
    .await;
    // Off the control first: a release outside is not a click.
    let away = point(px(640.), px(8.));
    drive::drag_to(main, away, cx);
    drive::release(main, away, MouseButton::Left, cx);
    drive::unhover(main, cx);
    pause(cx, 200).await;
}

/// Drags from `from` over `to` in a few steps and takes an interaction
/// shot there, then lets go where nothing takes the drop, so nothing moves.
async fn drag_over(
    run: &mut Run,
    from: gpui_kit::Point<gpui_kit::Pixels>,
    to: gpui_kit::Point<gpui_kit::Pixels>,
    state: &str,
    description: &str,
    sprung: Option<&str>,
    cx: &mut AsyncApp,
) {
    let main = run.main;
    drive::hover(main, from, cx);
    pause(cx, 100).await;
    drive::press(main, from, MouseButton::Left, cx);
    pause(cx, 80).await;
    drive::drag_to(main, point(from.x + px(6.), from.y + px(6.)), cx);
    pause(cx, 80).await;
    for k in 1..=6 {
        let f = k as f32 / 6.;
        let at = point(from.x + (to.x - from.x) * f, from.y + (to.y - from.y) * f);
        drive::drag_to(main, at, cx);
        pause(cx, 40).await;
    }
    pause(cx, 300).await;
    run.interaction(main, "sidebar", state, description, Shot::quick(), cx)
        .await;
    if let Some(sprung) = sprung {
        // Held there: a closed folder springs open after 0.7 s.
        drive::drag_to(main, point(to.x + px(1.), to.y), cx);
        pause(cx, 1000).await;
        run.interaction(
            main,
            "sidebar",
            sprung,
            "The same drag held over the closed folder for a second: it has sprung open (Finder's spring-loaded folders), still outlined as the drop target.",
            Shot::quick(),
            cx,
        )
        .await;
    }
    // Dropped where nothing takes it: the drag ends, nothing moves.
    let away = point(px(900.), px(400.));
    drive::drag_to(main, away, cx);
    pause(cx, 60).await;
    drive::release(main, away, MouseButton::Left, cx);
    drive::unhover(main, cx);
    pause(cx, 300).await;
}

fn request(id: &str, kind: UiRequestKind, args: &[(&str, &str)]) -> UiRequest {
    UiRequest {
        request_id: id.into(),
        kind,
        message_code: "server.prompt".into(),
        message_args: args
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
        detail: json!({}),
        timeout_ms: None,
        default_choice: "deny".into(),
        input_type: None,
        options: None,
    }
}

pub(super) fn tool_request(id: &str) -> UiRequest {
    let mut tool = request(
        id,
        UiRequestKind::ToolApproval,
        &[
            ("title", "get_current_timestamp"),
            ("message", "The model wants to read the clock."),
        ],
    );
    tool.message_code = "server.prompt".into();
    tool
}

fn select_request(id: &str) -> UiRequest {
    let mut select = request(
        id,
        UiRequestKind::InputPrompt,
        &[
            ("title", "Which station?"),
            ("message", "The tide tool needs a station to read."),
        ],
    );
    select.input_type = Some(UiInputType::Select);
    select.options = Some(vec![
        UiInputOption {
            value: "wren".into(),
            label: "Port Wren".into(),
        },
        UiInputOption {
            value: "ardmore".into(),
            label: "Port Ardmore".into(),
        },
        UiInputOption {
            value: "kestrel".into(),
            label: "Kestrel Bay".into(),
        },
    ]);
    select
}

pub(super) fn dock(req: UiRequest, cx: &mut AsyncApp) {
    cx.update(|cx| {
        let u = cx.global::<AppState>().stores.ui_requests.clone();
        u.update(cx, |u, cx| u.on_request(req, cx));
    });
}

pub(super) fn deny_all(cx: &mut AsyncApp) {
    cx.update(|cx| {
        if let Some(v) = view(cx) {
            let approvals = v.read(cx).approvals.clone();
            for _ in 0..4 {
                approvals.update(cx, |a, cx| a.deny(cx));
            }
        }
    });
}

/// Dismisses every toast (so the next shots don't carry one).
pub(super) fn clear_toasts(cx: &mut AsyncApp) {
    cx.update(|cx| {
        let t = cx.global::<AppState>().stores.toasts.clone();
        let ids: Vec<u64> = t.read(cx).toasts.iter().map(|t| t.id).collect();
        t.update(cx, |t, cx| {
            for id in ids {
                t.dismiss(id, cx);
            }
        });
    });
}

pub(super) fn toast(level: NoticeLevel, text: &str, cx: &mut AsyncApp) {
    let text = text.to_string();
    cx.update(|cx| {
        let t = cx.global::<AppState>().stores.toasts.clone();
        t.update(cx, |t, cx| t.show(level, text, cx));
    });
}

fn scroll_transcript(to: Option<usize>, by: f32, cx: &mut AsyncApp) {
    cx.update(|cx| {
        let Some(p) = pane(cx) else { return };
        let Some(t) = p.read(cx).chat.as_ref().map(|c| c.transcript.clone()) else {
            return;
        };
        t.update(cx, |t, cx| {
            if let Some(item_ix) = to {
                t.list_state().scroll_to(ListOffset {
                    item_ix,
                    offset_in_item: px(0.),
                });
                cx.notify();
            }
            if by != 0. {
                t.scroll_by(px(by), cx);
            }
        });
    });
}

fn scroll_to_end(cx: &mut AsyncApp) {
    cx.update(|cx| {
        let Some(p) = pane(cx) else { return };
        if let Some(t) = p.read(cx).chat.as_ref().map(|c| c.transcript.clone()) {
            t.update(cx, |t, cx| t.scroll_to_end(cx));
        }
    });
}

pub(super) async fn send(text: &str, cx: &mut AsyncApp) {
    let text = text.to_string();
    let main = cx.update(|cx| cx.global::<AppState>().main_window);
    let Some(main) = main else { return };
    let Some(p) = cx.update(pane) else { return };
    let _ = main.update(cx, |_, window, cx| {
        p.update(cx, |p, cx| {
            p.composer.update(cx, |c, cx| {
                c.set_text(&text, window, cx);
                c.submit(window, cx);
            })
        })
    });
}

pub(super) async fn wait_streaming(cx: &mut AsyncApp, timeout: Duration) -> bool {
    wait_until(cx, timeout, |cx| {
        chat_store(cx).is_some_and(|s| {
            s.read(cx)
                .live
                .as_ref()
                .is_some_and(|l| l.streaming() && !l.blocks.is_empty())
        })
    })
    .await
}

pub(super) async fn wait_answer(cx: &mut AsyncApp, timeout: Duration) -> bool {
    wait_until(cx, timeout, |cx| {
        let Some(store) = chat_store(cx) else {
            return false;
        };
        let s = store.read(cx);
        let last = s.rows().last().and_then(|r| s.item(*r));
        !s.is_streaming()
            && s.live.is_none()
            && s.pending.is_none()
            && last.is_some_and(|i| i.role == Role::Assistant && !i.text.trim().is_empty())
    })
    .await
}

pub async fn run(run: &mut Run, cx: &mut AsyncApp) {
    if !run.wants("main") {
        return;
    }
    let main = run.main;
    run.mode(crate::prefs::ThemeMode::Light, cx).await;

    // ── New chat ──────────────────────────────────────────────────────
    new_chat(run, cx).await;
    // The composer shows the account's model once models.list answered.
    let models = wait_until(cx, Duration::from_secs(30), |cx| {
        pane(cx).is_some_and(|p| {
            let c = p.read(cx).composer_store.read(cx);
            c.models.as_ref().is_some_and(|m| !m.models.is_empty()) && c.selected_model().is_some()
        })
    })
    .await;
    if !models {
        run.problem("the composer had no selected model 30 s after sign-in");
    }
    pause(cx, 500).await;
    drive::unhover(main, cx);
    ax_dump(run, main, "main-new-chat", cx).await;
    run.state(main, "main", "new-chat", "A new chat: the greeting over the capsule composer; the sidebar's date sections, pinned chats and folders.", Shot::default(), cx).await;
    run.tooltips(main, "main-new-chat", cx).await;
    // The composer's own controls, by keyboard.
    in_main(run, cx, |mw, window, cx| {
        mw.chat_pane
            .update(cx, |p, cx| p.focus_composer(window, cx))
    });
    pause(cx, 300).await;
    run.focus_walk(main, "composer", "tab", 8, cx).await;
    run.focus_walk(main, "composer-back", "shift-tab", 6, cx)
        .await;
    // The sidebar by keyboard: from its search field.
    if let Some(search) = find_node(
        run,
        "TextInput",
        |l| l.to_lowercase().contains("search"),
        cx,
    )
    .await
    {
        if let Some(at) = search.center() {
            drive::click(main, at, cx).await;
            pause(cx, 300).await;
            run.focus_walk(main, "sidebar", "tab", 10, cx).await;
            // The chat list as a source list: focus in it (Tab reaches it
            // from the search field), then the arrows.
            in_main(run, cx, |mw, window, cx| {
                mw.sidebar.update(cx, |s, cx| s.focus_list(window, cx))
            });
            pause(cx, 300).await;
            run.focus_walk(main, "sidebar-rows", "down", 3, cx).await;
        }
    } else {
        run.missing(
            "focus · sidebar",
            "no sidebar search field in the AccessKit tree",
        );
    }
    drive::key(main, "escape", cx);
    new_chat(run, cx).await;

    // The sidebar further down: older sections and folders.
    in_main(run, cx, |mw, _, cx| {
        mw.sidebar.read(cx).scroll_handle().scroll_to_bottom();
        mw.sidebar.update(cx, |_, cx| cx.notify());
    });
    pause(cx, 500).await;
    run.state(
        main,
        "sidebar",
        "sections-scrolled",
        "The sidebar scrolled to its end: month sections and older chats.",
        Shot::default(),
        cx,
    )
    .await;
    in_main(run, cx, |mw, _, cx| {
        mw.sidebar
            .read(cx)
            .scroll_handle()
            .scroll_to_item(0, gpui_kit::ScrollStrategy::Top);
        mw.sidebar.update(cx, |_, cx| cx.notify());
    });
    pause(cx, 400).await;

    // ── A short chat (and the selected row) ───────────────────────────
    let short = cx.update(|cx| chat_titled("Sourdough starter schedule", cx));
    let short_ok = match &short {
        Some(id) => open_chat(run, id, cx).await,
        None => false,
    };
    if short_ok {
        drive::unhover(main, cx);
        ax_dump(run, main, "main-short-chat", cx).await;
        run.state(
            main,
            "main",
            "short-chat",
            "A short chat (one exchange); its row selected in the sidebar.",
            Shot::default(),
            cx,
        )
        .await;

        // A hovered sidebar row, with its actions.
        if let Some(row) = find_node(
            run,
            "TreeItem",
            |l| l.starts_with("Orbital period of a moon"),
            cx,
        )
        .await
            && let Some(at) = row.center()
        {
            drive::hover(main, at, cx);
            pause(cx, 120).await;
            drive::hover(main, at, cx);
            pause(cx, 300).await;
            run.state(
                main,
                "sidebar",
                "row-hover",
                "A sidebar row under the pointer, showing its actions.",
                Shot::quick(),
                cx,
            )
            .await;
            drive::unhover(main, cx);
            pause(cx, 200).await;
            hover_and_press(run, &row, "sidebar", "row", cx).await;
        } else {
            run.missing(
                "sidebar · row-hover",
                "no row for \u{201c}Orbital period of a moon\u{201d}",
            );
        }

        // The answer's actions, on hover.
        let nodes = drive::nodes(main, cx).await;
        if let Some(answer) = nodes
            .iter()
            .find(|n| n.role == "Article" && !n.label.starts_with("You"))
            .cloned()
            && let Some(at) = answer.center()
        {
            drive::hover(main, at, cx);
            pause(cx, 120).await;
            drive::hover(main, at, cx);
            pause(cx, 300).await;
            run.interaction(
                main,
                "message",
                "answer-hover",
                "The answer under the pointer: its action row.",
                Shot::quick(),
                cx,
            )
            .await;
            if let Some(copy) = find_node(run, "Button", |l| l == "Copy", cx).await {
                hover_and_press(run, &copy, "message", "copy", cx).await;
            }
            // Its tooltips, the answer kept hovered.
            drive::hover(main, at, cx);
            pause(cx, 300).await;
            let answer_bounds = answer.bounds;
            run.tooltips_where(
                main,
                "message-actions",
                move |n| {
                    answer_bounds.is_some_and(|b| n.bounds.is_some_and(|nb| b.intersects(&nb)))
                },
                cx,
            )
            .await;
            // The rating menu (More), for real.
            drive::hover(main, at, cx);
            pause(cx, 300).await;
            if let Some(more) = drive::nodes(main, cx).await.into_iter().find(|n| {
                n.role == "Button"
                    && n.label == "More"
                    && answer_bounds.is_some_and(|b| n.bounds.is_some_and(|nb| b.intersects(&nb)))
            }) && let Some(mat) = more.center()
            {
                run.native_menu(
                    main,
                    "menu-answer-more",
                    "The answer's More menu (rating), a real NSMenu.",
                    |cx| {
                        let main = cx.update(|cx| cx.global::<AppState>().main_window);
                        if let Some(main) = main {
                            cx.spawn(async move |cx| drive::click(main, mat, cx).await)
                                .detach();
                        }
                    },
                    cx,
                )
                .await;
            }
        } else {
            run.missing(
                "message · answer-hover",
                "no answer article in the AccessKit tree",
            );
        }

        // Toolbar: More, hover and pressed, then its menu for real.
        if let Some(more) = find_node(run, "Button", |l| l == "More", cx).await {
            hover_and_press(run, &more, "toolbar", "more", cx).await;
            if let Some(mat) = more.center() {
                let opened = run
                    .native_menu_pair(main, "menu", "chat-more", "The toolbar's More menu for the open chat (the same items as the sidebar's right-click menu), a real NSMenu.", true, move |cx| {
                        let main = cx.update(|cx| cx.global::<AppState>().main_window);
                        if let Some(main) = main {
                            cx.spawn(async move |cx| drive::click(main, mat, cx).await).detach();
                        }
                    }, cx)
                    .await;
                if !opened {
                    run.missing("menu · chat-more", "the toolbar's More menu did not open");
                }
            }
        }
        let items = in_main(run, cx, |mw, _, cx| {
            let id = short.clone()?;
            let chat = mw.stores.chat_list.read(cx).find(&id).cloned()?;
            Some(
                mw.sidebar
                    .read(cx)
                    .menu_items(&chat, cx)
                    .into_iter()
                    .map(|(l, _)| l)
                    .collect::<Vec<_>>(),
            )
        })
        .flatten()
        .unwrap_or_default();
        run.notes.menus.push((
            "Chat menu items (SidebarView::menu_items, for the short chat)".into(),
            items,
            false,
        ));

        // Right-click on a sidebar row, for real.
        if let Some(row) =
            find_node(run, "TreeItem", |l| l.starts_with("Raised bed layout"), cx).await
            && let Some(at) = row.center()
        {
            run.native_menu(
                main,
                "menu-sidebar-row-right-click",
                "Right-click on a filed sidebar row: its context menu, a real NSMenu.",
                |cx| {
                    let main = cx.update(|cx| cx.global::<AppState>().main_window);
                    if let Some(main) = main {
                        drive::hover(main, at, cx);
                        drive::press(main, at, MouseButton::Right, cx);
                        drive::release(main, at, MouseButton::Right, cx);
                    }
                },
                cx,
            )
            .await;
        }
        // Right-click on a folder.
        if let Some(folder) = find_node(run, "TreeItem", |l| l.starts_with("Recipes"), cx).await
            && let Some(at) = folder.center()
        {
            let opened = run
                .native_menu(
                    main,
                    "menu-folder-right-click",
                    "Right-click on a folder row.",
                    |cx| {
                        let main = cx.update(|cx| cx.global::<AppState>().main_window);
                        if let Some(main) = main {
                            drive::hover(main, at, cx);
                            drive::press(main, at, MouseButton::Right, cx);
                            drive::release(main, at, MouseButton::Right, cx);
                        }
                    },
                    cx,
                )
                .await;
            if opened.is_none() {
                run.missing(
                    "menu · folder right-click",
                    "a right-click on a folder opens no menu",
                );
            }
        }

        // Composer: + menu for real, send hover/pressed.
        if let Some(plus) = find_node(
            run,
            "Button",
            |l| {
                let l = l.to_lowercase();
                l.contains("attach") || l.contains("add") || l == "more options"
            },
            cx,
        )
        .await
            && let Some(pat) = plus.center()
        {
            // Image Generation on, so the shot shows a switch's check mark
            // in the menu and its chip in the composer; off again after.
            let set_image = |on: bool, cx: &mut AsyncApp| {
                cx.update(|cx| {
                    if let Some(p) = pane(cx) {
                        let store = p.read(cx).composer_store.clone();
                        store.update(cx, |s, cx| {
                            if s.options.image_generation && s.image_generation != on {
                                s.toggle_image_generation(cx);
                            }
                        });
                    }
                });
            };
            set_image(true, cx);
            pause(cx, 200).await;
            let opened = run.native_menu_pair(main, "menu", "composer-plus", "The composer's + menu: Attach Files and the switches the model allows (Image Generation on: checked, with its chip in the composer), a real NSMenu.", true, move |cx| {
                let main = cx.update(|cx| cx.global::<AppState>().main_window);
                if let Some(main) = main {
                    cx.spawn(async move |cx| drive::click(main, pat, cx).await).detach();
                }
            }, cx)
            .await;
            if !opened {
                run.missing("menu · composer +", "the + button opened no menu");
            }
            set_image(false, cx);
        } else {
            run.missing(
                "menu · composer +",
                "no + button found by label in the composer",
            );
        }
        if let Some(p) = cx.update(pane) {
            let _ = main.update(cx, |_, window, cx| {
                p.update(cx, |p, cx| {
                    p.composer.update(cx, |c, cx| {
                        c.set_text("How warm should the kitchen be?", window, cx)
                    })
                })
            });
        }
        pause(cx, 300).await;
        if let Some(send) =
            find_node(run, "Button", |l| l == "Send" || l.starts_with("Send"), cx).await
        {
            hover_and_press(run, &send, "composer", "send", cx).await;
        } else {
            run.missing(
                "composer · send hover",
                "no Send button in the AccessKit tree",
            );
        }
        if let Some(p) = cx.update(pane) {
            let _ = main.update(cx, |_, window, cx| {
                p.update(cx, |p, cx| {
                    p.composer.update(cx, |c, cx| c.set_text("", window, cx))
                })
            });
        }

        // The model picker.
        in_main(run, cx, |mw, window, cx| {
            mw.chat_pane
                .update(cx, |p, cx| p.open_model_picker(window, cx))
        });
        pause(cx, 500).await;
        ax_dump(run, main, "popover-model-picker", cx).await;
        run.state(
            main,
            "popover",
            "model-picker",
            "The model picker hanging under the title capsule.",
            Shot::default(),
            cx,
        )
        .await;
        run.focus_walk(main, "model-picker", "down", 4, cx).await;
        drive::key(main, "escape", cx);
        in_main(run, cx, |mw, window, cx| {
            mw.chat_pane.update(cx, |p, cx| {
                p.composer.update(cx, |c, cx| c.close_picker(window, cx))
            })
        });
        pause(cx, 300).await;
    } else {
        run.missing("main · short-chat", "the seeded short chat did not open");
    }

    // ── The long chat: every block kind ───────────────────────────────
    let showcase = run.env.get("OWUI_SHOWCASE_CHAT").cloned();
    match showcase {
        Some(id) if open_chat(run, &id, cx).await => {
            drive::unhover(main, cx);
            scroll_transcript(Some(0), 0., cx);
            pause(cx, 600).await;
            // The answer's generated image loads through the daemon.
            let mut loaded = false;
            for _ in 0..16 {
                let nodes = drive::nodes(main, cx).await;
                let image = nodes
                    .iter()
                    .find(|n| n.role == "Image" && n.label.contains("High water"));
                if image
                    .and_then(|n| n.bounds)
                    .is_some_and(|b| f32::from(b.size.width) > 20.)
                {
                    loaded = true;
                    break;
                }
                pause(cx, 500).await;
            }
            if !loaded {
                run.missing("main · long chat image", "the answer's generated image (high-water.png, served by the local server) never loaded: the app draws a 2×2 placeholder (an app finding, not a capture problem)");
            }
            ax_dump(run, main, "main-long-chat", cx).await;
            run.state(main, "main", "long-chat-1-top", "The showcase chat from the top: the question with its file, the answer's status line (a web search), reasoning and two tool calls (collapsed), citation pills, headings, a list, inline and display math.", Shot::default(), cx).await;
            scroll_transcript(None, 560., cx);
            pause(cx, 600).await;
            run.state(main, "main", "long-chat-2-middle", "The showcase chat, further down: display math, Python with highlighting, a code-interpreter section (collapsed), a table, the code execution (collapsed).", Shot::default(), cx).await;
            scroll_to_end(cx);
            pause(cx, 700).await;
            run.state(main, "main", "long-chat-3-end", "The showcase chat's end: an answer that failed (error banner), a retry, and the Suggestions under the last answer.", Shot::default(), cx).await;

            // Open every disclosure: status, reasoning, tools, the run.
            scroll_transcript(Some(0), 0., cx);
            pause(cx, 500).await;
            // One at a time: each opens and moves the ones below it.
            let mut toggles = std::collections::BTreeSet::new();
            open_disclosures(run, &mut toggles, cx).await;
            log(format!("opened: {toggles:?}"));
            drive::unhover(main, cx);
            scroll_transcript(Some(0), 0., cx);
            pause(cx, 600).await;
            if toggles.is_empty() {
                run.missing(
                    "main · long-chat-expanded",
                    "no collapsed disclosure (expanded=false) in the AccessKit tree",
                );
            }
            run.state(
                main,
                "main",
                "long-chat-expanded",
                "The showcase chat with the status timeline, reasoning and tool calls opened.",
                Shot::default(),
                cx,
            )
            .await;
            // The run and the execution, lower down: each brought into view
            // and opened. Both read "Ran code, …": the interpreter's names
            // its first line of code, the execution its seeded name.
            const INTERPRETER: &str = "Ran code, lags";
            const EXECUTION: &str = "Ran code, Average daily lag";
            for name in [INTERPRETER, EXECUTION] {
                let pick = |n: &drive::Node| n.role == "Button" && n.label.starts_with(name);
                if reveal(run, pick, cx).await.is_some() {
                    open_disclosures(run, &mut toggles, cx).await;
                }
            }
            reveal(
                run,
                |n| n.role == "Button" && n.label.starts_with(INTERPRETER),
                cx,
            )
            .await;
            drive::unhover(main, cx);
            pause(cx, 400).await;
            run.state(main, "main", "long-chat-expanded-2", "Further down with the sections opened: the code-interpreter run and the code execution.", Shot::default(), cx).await;

            // A citation pill, then the sources pill.
            scroll_transcript(Some(0), 0., cx);
            pause(cx, 500).await;
            let cite = |n: &drive::Node| n.role == "Link" && n.label.starts_with("Source ");
            if reveal(run, cite, cx).await.is_some() && click_settled(run, cite, cx).await {
                pause(cx, 600).await;
                run.state(
                    main,
                    "popover",
                    "citation",
                    "A citation pill clicked: the source's popover.",
                    Shot::quick(),
                    cx,
                )
                .await;
                drive::key(main, "escape", cx);
                cx.update(|cx| {
                    if let Some(p) = pane(cx)
                        && let Some(t) = p.read(cx).chat.as_ref().map(|c| c.transcript.clone())
                    {
                        t.update(cx, |t, cx| t.close_citation(cx));
                    }
                });
                pause(cx, 300).await;
            } else {
                run.missing(
                    "popover · citation",
                    "no citation pill (Link \u{201c}Source n\u{201d}) could be scrolled into view",
                );
            }
            // The sources pill on a freshly opened chat: no state left over
            // from the clicks above.
            if let Some(short) = cx.update(|cx| chat_titled("Sourdough starter schedule", cx)) {
                open_chat(run, &short, cx).await;
            }
            open_chat(run, &id, cx).await;
            scroll_transcript(Some(0), 0., cx);
            pause(cx, 500).await;
            let pill = |n: &drive::Node| n.role == "Button" && n.label.starts_with("Sources");
            if reveal(run, pill, cx).await.is_some() && click_settled(run, pill, cx).await {
                // It opens the Sources sheet (as the phone's sources sheet).
                pause(cx, 900).await;
                drive::unhover(main, cx);
                run.state(
                    main,
                    "main",
                    "long-chat-sources",
                    "The sources pill opened: the Sources sheet, every source the answer cites.",
                    Shot::default(),
                    cx,
                )
                .await;
                // Done: the sheet goes before the next step.
                cx.update(crate::views::sheet::dismiss);
                pause(cx, 800).await;
            } else {
                run.missing(
                    "main · sources list",
                    "no Sources pill could be scrolled into view",
                );
            }
            // ⌘F: Find in Chat over the showcase chat, "tide" typed and the
            // second match made current with ⌘G.
            dispatch(run, Box::new(crate::actions::FindInChat), cx);
            pause(cx, 300).await;
            in_main(run, cx, |mw, window, cx| {
                mw.chat_pane
                    .update(cx, |p, cx| p.type_find("tide", window, cx))
            });
            let found = wait_until(cx, Duration::from_secs(10), |cx| {
                pane(cx)
                    .and_then(|p| {
                        p.read(cx)
                            .chat
                            .as_ref()
                            .and_then(|c| c.transcript.read(cx).find_status())
                    })
                    .is_some_and(|(_, n)| n > 1)
            })
            .await;
            dispatch(run, Box::new(crate::actions::FindNext), cx);
            pause(cx, 800).await;
            drive::unhover(main, cx);
            if found {
                run.state(
                    main,
                    "main",
                    "find-in-chat",
                    "\u{2318}F: Find in Chat with \u{201c}tide\u{201d} typed and \u{2318}G pressed once: every match highlighted, the current one stronger; the count, Find Previous and Next (\u{21e7}\u{2318}G, \u{2318}G) and Done (Esc).",
                    Shot::default(),
                    cx,
                )
                .await;
            } else {
                run.missing(
                    "main · find in chat",
                    "Find in Chat found fewer than two \u{201c}tide\u{201d} in 10 s",
                );
            }
            in_main(run, cx, |mw, window, cx| {
                mw.chat_pane.update(cx, |p, cx| p.close_find(window, cx))
            });
            pause(cx, 400).await;

            // Up through the newest answer's controls from the composer
            // (clicks on them leave focus where it was, as on macOS).
            in_main(run, cx, |mw, window, cx| {
                mw.chat_pane
                    .update(cx, |p, cx| p.focus_composer(window, cx))
            });
            pause(cx, 300).await;
            run.focus_walk(main, "transcript", "shift-tab", 10, cx)
                .await;
            drive::key(main, "escape", cx);
        }
        _ => run.missing(
            "main · long chat",
            "no showcase chat (OWUI_SHOWCASE_CHAT) or it did not open",
        ),
    }

    // ── The sidebar's states ──────────────────────────────────────────
    new_chat(run, cx).await;
    // An expanded folder (Garden, as the account left it) and the shared one.
    let shared = run.env.get("OWUI_SHARED_FOLDER").cloned();
    let garden = cx.update(|cx| folder_named("Garden", cx));
    cx.update(|cx| {
        let s = cx.global::<AppState>().stores.chat_list.clone();
        if let Some(g) = &garden
            && !s.read(cx).is_expanded(g)
        {
            s.update(cx, |c, cx| c.toggle_folder(g, cx));
        }
        if let Some(f) = &shared
            && !s.read(cx).is_expanded(f)
        {
            s.update(cx, |c, cx| c.toggle_folder(f, cx));
        }
    });
    pause(cx, 1500).await;
    let shared_chat = run.env.get("OWUI_SHARED_CHAT").cloned();
    if let Some(chat) = shared_chat.clone() {
        let id = chat.clone();
        in_main(run, cx, move |mw, _, cx| {
            mw.sidebar.update(cx, |s, cx| s.hover(Some(&id), cx))
        });
    }
    pause(cx, 300).await;
    ax_dump(run, main, "sidebar-folders", cx).await;
    run.state(main, "sidebar", "folders-expanded", "Folders: Garden expanded (with its nested Seeds folder) and the folder another user shared (read-only, marked shared).", Shot::default(), cx).await;
    in_main(run, cx, |mw, _, cx| {
        mw.sidebar.update(cx, |s, cx| s.hover(None, cx))
    });

    // Folder management: the menus' items, renaming in place, a new
    // folder, and what Delete Folder… asks.
    let recipes = cx.update(|cx| folder_named("Recipes", cx));
    let menus = in_main(run, cx, |mw, _, cx| {
        let store = mw.stores.chat_list.read(cx);
        let list = store.list.as_ref()?;
        let labels = |f: &conduit_protocol::FolderSummary| {
            mw.sidebar
                .read(cx)
                .folder_menu_items(f, store.is_expanded(&f.id), cx)
                .into_iter()
                .map(|i| i.map_or("—".to_string(), |(label, _)| label))
                .collect::<Vec<_>>()
        };
        let own = list
            .folders
            .iter()
            .find(|f| f.name == "Recipes")
            .map(labels);
        let shared = list.folders.iter().find(|f| f.shared).map(labels);
        Some((own, shared))
    })
    .flatten();
    if let Some((own, shared)) = menus {
        if let Some(items) = own {
            run.notes.menus.push((
                "Folder menu (the account's own folder, Recipes): right-click or Control-click"
                    .into(),
                items,
                false,
            ));
        }
        if let Some(items) = shared {
            run.notes.menus.push((
                "Folder menu (a read-only folder another user shared): only what the grant allows"
                    .into(),
                items,
                false,
            ));
        }
    }
    if let Some(id) = recipes.clone() {
        let action = crate::views::sidebar::FolderMenu {
            folder_id: id,
            command: crate::views::sidebar::FolderCommand::Rename,
        };
        dispatch(run, Box::new(action), cx);
        pause(cx, 500).await;
        run.state(main, "sidebar", "folder-rename", "Rename… on the Recipes folder (or Return on it while the list has focus): the name edited in place, selected; Return saves it, Esc leaves it as it was.", Shot::default(), cx).await;
        in_main(run, cx, |mw, window, cx| {
            mw.sidebar.update(cx, |s, cx| s.cancel_rename(window, cx))
        });
        pause(cx, 300).await;
    }
    dispatch(run, Box::new(crate::actions::NewFolder), cx);
    pause(cx, 600).await;
    run.state(main, "sidebar", "new-folder", "File › New Folder (also the Folders heading's + and the list's right-click menu): a folder row at the top of Folders named \u{201c}New Folder\u{201d}, selected to type over; Return makes it, Esc drops it.", Shot::default(), cx).await;
    in_main(run, cx, |mw, window, cx| {
        mw.sidebar.update(cx, |s, cx| s.cancel_rename(window, cx))
    });
    pause(cx, 300).await;
    {
        let l = cx.update(|cx| cx.l10n().clone());
        run.notes.menus.push((
            "Delete Folder… (⌘⌫ on a selected folder): a native sheet (NSAlert, warning style), Delete in red; for a folder with subfolders".into(),
            vec![
                l.desktop_delete_folder_title("Garden"),
                l.desktop_delete_folder_with_subfolders(),
                format!("{} (destructive, Return)", l.delete()),
                format!("{} (Esc)", l.cancel()),
            ],
            false,
        ));
        run.notes.menus.push((
            "Delete Folder…, for a folder without subfolders".into(),
            vec![
                l.desktop_delete_folder_title("Recipes"),
                l.desktop_delete_folder_keeps_chats(),
            ],
            false,
        ));
    }

    // Drag a chat over a folder.
    // A visible chat row (the list's length varies) and a folder.
    let nodes = drive::nodes(main, cx).await;
    let row = [
        "Regex for ISO dates",
        "Quilt pattern maths",
        "Jazz chord voicings",
        "Tide station weekly report",
    ]
    .iter()
    .find_map(|title| {
        nodes
            .iter()
            .find(|n| {
                n.role == "TreeItem"
                    && n.label.starts_with(title)
                    && n.bounds.is_some_and(|b| {
                        let y = f32::from(b.origin.y);
                        y > 100. && y < 780.
                    })
            })
            .cloned()
    });
    let target = drive::find(&nodes, "TreeItem", |l| l.starts_with("Side project")).cloned();
    match (
        row.and_then(|r| r.center()),
        target.and_then(|t| t.center()),
    ) {
        (Some(from), Some(to)) => {
            let side = cx.update(|cx| folder_named("Side project", cx));
            let was_open = cx.update(|cx| {
                side.as_ref().is_some_and(|id| {
                    cx.global::<AppState>()
                        .stores
                        .chat_list
                        .read(cx)
                        .is_expanded(id)
                })
            });
            drag_over(run, from, to, "drag-over-folder", "A chat dragged over the Side project folder: the folder outlined as the drop target; the drag image is the row itself (its glyph and title) on an opaque card, 4 pt below-right of the pointer.", Some("drag-over-folder-sprung"), cx).await;
            // Put the spring-loaded folder back as it was for the shots after.
            if let Some(id) = side.filter(|_| !was_open) {
                cx.update(|cx| {
                    let list = cx.global::<AppState>().stores.chat_list.clone();
                    if list.read(cx).is_expanded(&id) {
                        list.update(cx, |c, cx| c.toggle_folder(&id, cx));
                    }
                });
                pause(cx, 300).await;
            }
        }
        _ => run.missing(
            "sidebar · drag over folder",
            "no visible chat row or Side project folder",
        ),
    }

    // Multiple selection, as Mail's and Finder's: a click on the first
    // chat, then ⌘-clicks on two more (real clicks where the rows are on
    // screen, which make the list key).
    let titles = [
        "Why tides lag the moon",
        "Migration plan",
        "Dialing in espresso",
    ];
    for (i, title) in titles.iter().enumerate() {
        let modifiers = if i == 0 {
            gpui_kit::Modifiers::none()
        } else {
            gpui_kit::Modifiers::command()
        };
        let nodes = drive::nodes(main, cx).await;
        let row = nodes
            .iter()
            .find(|n| {
                n.role == "TreeItem"
                    && n.label.starts_with(title)
                    && n.bounds.is_some_and(|b| {
                        let y = f32::from(b.origin.y);
                        y > 100. && y < 780.
                    })
            })
            .and_then(|n| n.center());
        match row {
            Some(at) => drive::click_with(main, at, modifiers, cx).await,
            None => {
                let id = cx.update(|cx| chat_titled(title, cx));
                let how = if i == 0 {
                    crate::views::sidebar_keys::Pick::Only
                } else {
                    crate::views::sidebar_keys::Pick::Toggle
                };
                if let Some(id) = id {
                    in_main(run, cx, move |mw, window, cx| {
                        mw.sidebar.update(cx, |s, cx| {
                            s.pick_chat(&id, how, cx);
                            s.focus_list(window, cx);
                        })
                    });
                }
            }
        }
        pause(cx, 300).await;
    }
    drive::unhover(main, cx);
    pause(cx, 500).await;
    run.state(
        main,
        "sidebar",
        "bulk-select",
        "Multiple selection: one chat clicked, two more ⌘-clicked; the list is key, so the three rows draw as its (inverted) selection, with the selection bar above (archive, move to, delete). Checkboxes (Select Chats…) remain the fallback.",
        Shot::default(),
        cx,
    )
    .await;
    // A selected chat drags the whole selection: the preview counts them.
    let nodes = drive::nodes(main, cx).await;
    let checked = nodes.iter().find(|n| {
        n.role == "TreeItem"
            && n.label.starts_with("Why tides lag the moon")
            && n.bounds.is_some_and(|b| {
                let y = f32::from(b.origin.y);
                y > 100. && y < 780.
            })
    });
    let target = drive::find(&nodes, "TreeItem", |l| l.starts_with("Side project"));
    match (
        checked.and_then(|n| n.center()),
        target.and_then(|t| t.center()),
    ) {
        (Some(from), Some(to)) => {
            drag_over(run, from, to, "drag-selection-over-folder", "Multiple selection: one of the three selected chats dragged over the Side project folder; the drag preview carries a count badge (3).", None, cx).await;
        }
        _ => run.missing(
            "sidebar · drag a selection over a folder",
            "no visible selected chat or Side project folder",
        ),
    }
    run.tooltips_where(
        main,
        "sidebar-bulk",
        |n| n.bounds.is_some_and(|b| f32::from(b.origin.x) < 320.),
        cx,
    )
    .await;
    // The selection ends, and focus goes back to the message field (the
    // ⌘-clicks made the list key).
    in_main(run, cx, |mw, window, cx| {
        mw.sidebar.update(cx, |s, cx| s.end_selection(cx));
        window.dispatch_action(Box::new(crate::actions::FocusComposer), cx);
    });
    pause(cx, 300).await;

    // Search.
    let search = in_main(run, cx, |mw, _, cx| mw.sidebar.read(cx).search.clone());
    if let Some(search) = search {
        let s2 = search.clone();
        in_main(run, cx, move |mw, window, cx| {
            set_text(&s2, "tide", window, cx);
            mw.stores
                .chat_list
                .update(cx, |c, cx| c.set_query("tide", cx));
        });
        let found = wait_until(cx, Duration::from_secs(20), |cx| {
            let s = cx.global::<AppState>().stores.chat_list.read(cx);
            s.searched() == "tide" && s.results.as_ref().is_some_and(|r| !r.hits.is_empty())
        })
        .await;
        pause(cx, 500).await;
        if found {
            run.state(
                main,
                "sidebar",
                "search-results",
                "Sidebar search for \u{201c}tide\u{201d}: the hits replace the list.",
                Shot::default(),
                cx,
            )
            .await;
        } else {
            run.missing(
                "sidebar · search results",
                "the search found nothing in 20 s",
            );
        }
        in_main(run, cx, move |mw, window, cx| {
            set_text(&search, "", window, cx);
            mw.stores.chat_list.update(cx, |c, cx| c.set_query("", cx));
        });
        pause(cx, 400).await;
    }

    // ── The ⌘K palette ─────────────────────────────────────────────────
    dispatch(run, Box::new(crate::actions::OpenPalette), cx);
    pause(cx, 600).await;
    ax_dump(run, main, "palette", cx).await;
    run.state(
        main,
        "palette",
        "recent",
        "⌘K: the palette with recent chats and commands.",
        Shot::default(),
        cx,
    )
    .await;
    run.focus_walk(main, "palette", "down", 6, cx).await;
    in_main(run, cx, |mw, window, cx| {
        mw.palette
            .update(cx, |p, cx| p.type_query("tide", window, cx))
    });
    let hits = wait_until(cx, Duration::from_secs(20), |cx| {
        let p = cx.global::<AppState>().stores.palette.read(cx);
        p.searched() == "tide"
    })
    .await;
    pause(cx, 500).await;
    if hits {
        run.state(
            main,
            "palette",
            "results",
            "⌘K with \u{201c}tide\u{201d} typed: matching chats and commands.",
            Shot::default(),
            cx,
        )
        .await;
    } else {
        run.missing(
            "palette · results",
            "the palette search did not answer in 20 s",
        );
    }
    in_main(run, cx, |mw, window, cx| {
        mw.palette.update(cx, |p, cx| p.close(window, cx))
    });
    pause(cx, 400).await;

    // ── Read-only shared chat ─────────────────────────────────────────
    match shared_chat {
        Some(id) if open_chat(run, &id, cx).await => {
            drive::unhover(main, cx);
            run.state(main, "main", "read-only", "Another user's chat from a shared folder: Read-only in the toolbar, no composer, a notice instead.", Shot::default(), cx).await;
        }
        _ => run.missing(
            "main · read-only",
            "the shared chat (OWUI_SHARED_CHAT) did not open",
        ),
    }

    // ── Approval cards, docked above the composer ─────────────────────
    let short = cx.update(|cx| chat_titled("Sourdough starter schedule", cx));
    if let Some(id) = short {
        open_chat(run, &id, cx).await;
    }
    dock(tool_request("hc-tool"), cx);
    pause(cx, 600).await;
    run.state(
        main,
        "approval",
        "tool",
        "A tool approval docked above the composer (Allow Command-Option-Return, Deny Command-Option-Delete).",
        Shot::default(),
        cx,
    )
    .await;
    run.focus_walk(main, "approval-tool", "tab", 5, cx).await;
    deny_all(cx);
    pause(cx, 500).await;
    dock(select_request("hc-select"), cx);
    pause(cx, 600).await;
    run.state(
        main,
        "approval",
        "select",
        "A tool asking the user to pick (a select input) docked above the composer.",
        Shot::default(),
        cx,
    )
    .await;
    deny_all(cx);
    pause(cx, 600).await;

    // ── Toasts ────────────────────────────────────────────────────────
    toast(NoticeLevel::Success, "Exported 12 chats to Downloads.", cx);
    pause(cx, 450).await;
    run.state(
        main,
        "toast",
        "success",
        "A success toast.",
        Shot::quick(),
        cx,
    )
    .await;
    clear_toasts(cx);
    pause(cx, 600).await;
    // A failed rename the daemon marks retryable, as the sidebar shows one:
    // its own sentence and Try Again (which sends nothing here).
    cx.update(|cx| {
        let text = cx.l10n().desktop_chat_change_failed();
        let t = cx.global::<AppState>().stores.toasts.clone();
        t.update(cx, |t, cx| {
            t.show_with_retry(
                NoticeLevel::Error,
                text,
                Some(crate::stores::toasts::Retry::new(|_| {
                    log::info!("capture: Try Again pressed")
                })),
                cx,
            )
        });
    });
    pause(cx, 450).await;
    run.state(
        main,
        "toast",
        "error",
        "A retryable error toast, with Try Again.",
        Shot::quick(),
        cx,
    )
    .await;
    clear_toasts(cx);
    pause(cx, 600).await;

    // ── Streaming mid-answer ──────────────────────────────────────────
    new_chat(run, cx).await;
    send("A slow answer, please", cx).await;
    if wait_streaming(cx, Duration::from_secs(30)).await {
        pause(cx, 2200).await;
        let shot = Shot {
            settle: Duration::from_millis(150),
            ..Shot::default()
        };
        run.state(
            main,
            "main",
            "streaming",
            "Streaming mid-answer: the answer growing under the question, Stop in place of Send.",
            shot,
            cx,
        )
        .await;
        dispatch(run, Box::new(crate::actions::StopGenerating), cx);
        wait_answer(cx, Duration::from_secs(30)).await;
    } else {
        run.missing(
            "main · streaming",
            "the fake model's answer never started streaming",
        );
    }
    pause(cx, 800).await;

    // ── Sidebar hidden ────────────────────────────────────────────────
    if let Some(id) = cx.update(|cx| chat_titled("Sourdough starter schedule", cx)) {
        open_chat(run, &id, cx).await;
    }
    drive::unhover(main, cx);
    cx.update(|cx| {
        let layout = cx.global::<AppState>().layout.clone();
        layout.update(cx, |l, cx| l.toggle_sidebar(cx));
    });
    pause(cx, 500).await;
    run.state(main, "main", "sidebar-hidden", "The sidebar hidden (⌃⌘S): Show Sidebar and New Chat in the toolbar beside the traffic lights.", Shot::default(), cx).await;
    run.tooltips_where(
        main,
        "toolbar-sidebar-hidden",
        |n| n.bounds.is_some_and(|b| f32::from(b.origin.y) < 60.),
        cx,
    )
    .await;
    cx.update(|cx| {
        let layout = cx.global::<AppState>().layout.clone();
        layout.update(cx, |l, cx| l.toggle_sidebar(cx));
    });
    pause(cx, 500).await;
    let _ = (MAIN_ORIGIN, MAIN_SIZE);
}

/// The main window at 900×700: new chat, a short chat, the long chat.
pub async fn narrow(run: &mut Run, cx: &mut AsyncApp) {
    if !run.wants("narrow") {
        return;
    }
    let main = run.main;
    place(main, MAIN_ORIGIN, NARROW_SIZE, cx);
    pause(cx, 600).await;
    new_chat(run, cx).await;
    drive::unhover(main, cx);
    run.state(
        main,
        "narrow",
        "new-chat",
        "The main window at 900×700: a new chat.",
        Shot::default(),
        cx,
    )
    .await;
    if let Some(id) = cx.update(|cx| chat_titled("Sourdough starter schedule", cx))
        && open_chat(run, &id, cx).await
    {
        drive::unhover(main, cx);
        run.state(
            main,
            "narrow",
            "short-chat",
            "900×700: a short chat.",
            Shot::default(),
            cx,
        )
        .await;
    }
    if let Some(id) = run.env.get("OWUI_SHOWCASE_CHAT").cloned()
        && open_chat(run, &id, cx).await
    {
        drive::unhover(main, cx);
        scroll_transcript(Some(0), 0., cx);
        pause(cx, 500).await;
        scroll_transcript(None, 420., cx);
        pause(cx, 500).await;
        run.state(
            main,
            "narrow",
            "long-chat",
            "900×700: the showcase chat (math, code, tables at a narrow width).",
            Shot::default(),
            cx,
        )
        .await;
    }
    place(main, MAIN_ORIGIN, MAIN_SIZE, cx);
    pause(cx, 600).await;
}
