//! `--e2e a11y-sweep`: the newer screens and announcements, as a VoiceOver
//! and keyboard user meets them, on the local Open WebUI.
//!
//! Full Keyboard Access is simulated in the app (`CONDUIT_FULL_KEYBOARD_ACCESS=1`,
//! which the runner sets; the system setting is never touched), and every
//! announcement is kept ([`AnnouncementLog`]) instead of being listened to.
//!
//! * **Announcements**: Temporary Chat turned on and off says the phone's
//!   words; ↓ in the `@` menu says the row and its place; Copy says
//!   "Copied"; moving the calendar's range says the new range.
//! * **Leaving the terminal by keyboard**: Tab into the console shows the
//!   way out under it and is the shell's inside it; Go › Move Focus to Next
//!   Area (⌥⌘`) and Previous Area (⌥⌘~) leave it for the controls after and
//!   before it, VoiceOver's help on it names both chords, and Settings ›
//!   Keyboard lists both (the Go group; the Terminal group's footer says it).
//! * **Screens**: Calendar, Scheduled Tasks, the Terminal (its console and
//!   files), Settings › Notifications and Personal Connections. On each:
//!   every control has a role and a label (the AccessKit dump), the key
//!   controls are there by role and name, and Tab, from the window's start,
//!   reaches them, stops only on labelled nodes, and moves in reading order
//!   (never back up a column).

use conduit_components::ActiveConduitTheme as _;
use conduit_components::announce::{AnnouncementLog, Priority};
use conduit_components::views::focus::KeyboardAccess;
use gpui_kit::{Bounds, Pixels, SharedString};

use crate::l10n::ActiveL10n as _;

use super::chat::{in_pane, pane, send, sign_in, wait_answer, wait_models};
use super::*;
use crate::capture::drive::{self, Node};
use crate::stores::navigation::AreaItem;
use crate::views::chat::composer::ChatComposerEvent;

/// Roles a Tab stop may have besides the controls: the lists, grids and
/// text areas that take the keyboard whole.
const CONTAINER_STOPS: &[&str] = &[
    "List",
    "ListBox",
    "Tree",
    "Table",
    "Grid",
    "Group",
    "Terminal",
    "Document",
    "TextInput",
    "MultilineTextInput",
    "ScrollView",
    "TabList",
    "RadioGroup",
    "Menu",
    "MenuBar",
    "Toolbar",
    "Row",
    "Cell",
    "ListItem",
    "Article",
];

/// One stop of a Tab walk: the node VoiceOver hears as focused, or None
/// when focus landed on something with no accessible node.
type Stop = Option<Node>;

/// Presses Tab (the key itself, through the window's key dispatch, so a
/// view that eats Tab or a missing binding shows) up to `max` times from
/// the window's start, and reads the focused node after each. In a
/// terminal's console, where Tab is the shell's, the walk leaves as a
/// keyboard user does: Go › Move Focus to Next Area.
async fn tab_walk(handle: AnyWindowHandle, max: usize, cx: &mut AsyncApp) -> Vec<Stop> {
    drive::activate(handle, cx);
    let _ = cx.update(|cx| handle.update(cx, |_, window, cx| window.blur(cx)));
    settle(cx, 200).await;
    let mut stops: Vec<Stop> = vec![];
    for _ in 0..max {
        let in_console = stops
            .last()
            .and_then(Option::as_ref)
            .is_some_and(|n| n.role == "Terminal");
        super::press(handle, if in_console { "alt-cmd-`" } else { "tab" }, cx);
        settle(cx, 150).await;
        let nodes = drive::nodes(handle, cx).await;
        let stop = nodes
            .iter()
            .find(|n| n.active)
            .or_else(|| nodes.iter().find(|n| n.focused))
            .cloned();
        // Round the loop: the first stop again.
        if stops.len() > 1
            && let (Some(Some(first)), Some(now)) = (stops.first(), &stop)
            && first.describe() == now.describe()
        {
            break;
        }
        stops.push(stop);
    }
    stops
}

/// Whether a stop is named: a control or container role with a label.
fn named(stop: &Node) -> bool {
    !stop.label.is_empty()
        && (CONTROL_ROLES.contains(&stop.role.as_str())
            || CONTAINER_STOPS.contains(&stop.role.as_str()))
}

/// Back-steps of a Tab walk inside `region`: a stop that sits above the
/// one before it in the same column or one further left (reading order
/// goes down a column, then to the next one on the right).
fn backsteps(stops: &[Stop], region: Option<Bounds<Pixels>>) -> Vec<String> {
    let inside = |b: &Bounds<Pixels>| {
        region.is_none_or(|r| {
            let c = b.center();
            c.x >= r.origin.x
                && c.x <= r.origin.x + r.size.width
                && c.y >= r.origin.y
                && c.y <= r.origin.y + r.size.height
        })
    };
    let placed: Vec<(&Node, Bounds<Pixels>)> = stops
        .iter()
        .flatten()
        .filter_map(|n| n.bounds.map(|b| (n, b)))
        .filter(|(_, b)| inside(b))
        .collect();
    placed
        .windows(2)
        .filter_map(|w| {
            let ((a, ab), (b, bb)) = (w[0], w[1]);
            let up = f32::from(bb.origin.y) + 8. < f32::from(ab.origin.y);
            let same_or_left = f32::from(bb.origin.x) <= f32::from(ab.origin.x) + 24.;
            (up && same_or_left).then(|| format!("{} → {}", a.describe(), b.describe()))
        })
        .collect()
}

/// One screen: its AccessKit dump labelled, `expect` (role, label) among
/// its controls, and a Tab walk that reaches each of `reach` on labelled
/// stops in reading order (inside `region`, the pane, when given).
async fn screen(
    handle: AnyWindowHandle,
    name: &str,
    expect: &[(&str, String)],
    reach: &[(&str, String)],
    region: Option<Bounds<Pixels>>,
    dir: &Path,
    cx: &mut AsyncApp,
) -> bool {
    let unlabelled = unlabelled_seen();
    let controls = ax(handle, name, dir, cx).await;
    let mut pass = !controls.is_empty();
    // An unlabelled control fails the screen, Tab stop or not.
    pass &= ok(
        &format!("{name}: every control has a label"),
        unlabelled_seen() == unlabelled,
    );
    for (role, label) in expect {
        pass &= ok(
            &format!("{name}: a {role} named “{label}”"),
            has(&controls, role, label),
        );
    }
    let stops = tab_walk(handle, 60, cx).await;
    let listed: Vec<String> = stops
        .iter()
        .map(|s| s.as_ref().map_or("(no node)".to_string(), Node::describe))
        .collect();
    std::fs::create_dir_all(dir.join("ax")).ok();
    std::fs::write(
        dir.join("ax").join(format!("{name}.tab.json")),
        serde_json::to_vec_pretty(&listed).unwrap_or_default(),
    )
    .ok();
    let unnamed: Vec<&String> = stops
        .iter()
        .zip(&listed)
        .filter(|(s, _)| s.as_ref().is_none_or(|n| !named(n)))
        .map(|(_, d)| d)
        .collect();
    pass &= ok(
        &format!(
            "{name}: Tab stops on {} labelled controls only ({unnamed:?})",
            stops.len()
        ),
        stops.len() >= 3 && unnamed.is_empty(),
    );
    let back = backsteps(&stops, region);
    pass &= ok(
        &format!("{name}: Tab follows the reading order ({back:?})"),
        back.is_empty(),
    );
    for (role, label) in reach {
        pass &= ok(
            &format!("{name}: Tab reaches the {role} “{label}”"),
            stops
                .iter()
                .flatten()
                .any(|n| n.role == *role && n.label.contains(label.as_str())),
        );
    }
    pass
}

/// The main window's content right of the sidebar, below the toolbar: the
/// pane a Tab walk's reading order is checked in.
fn main_pane(handle: AnyWindowHandle, cx: &mut AsyncApp) -> Option<Bounds<Pixels>> {
    cx.update(|cx| {
        let sidebar = cx.conduit().metrics.sidebar_width;
        handle
            .update(cx, |_, window, _| {
                let size = window.bounds().size;
                Bounds::new(
                    gpui_kit::point(gpui_kit::px(sidebar), gpui_kit::px(0.)),
                    size,
                )
            })
            .ok()
    })
}

/// The node VoiceOver hears as focused in `handle`.
async fn focused_node(handle: AnyWindowHandle, cx: &mut AsyncApp) -> Option<Node> {
    let nodes = drive::nodes(handle, cx).await;
    nodes
        .iter()
        .find(|n| n.active)
        .or_else(|| nodes.iter().find(|n| n.focused))
        .cloned()
}

/// The terminal's console keeps Tab for the shell; the keyboard's way out
/// is Go › Move Focus to Next Area (⌥⌘`) and Previous Area (⌥⌘~), which the
/// console's VoiceOver help and the bar under it name.
async fn leave_terminal(main: AnyWindowHandle, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some(pane) = cx.update(super::terminal::pane) else {
        return ok("the terminal's pane", false);
    };
    let console = cx.update(|cx| pane.read(cx).console.clone());
    let in_console = |cx: &mut AsyncApp| {
        cx.update(|cx| {
            main.update(cx, |_, window, cx| console.read(cx).is_focused(window))
                .unwrap_or(false)
        })
    };
    let (next, previous) = crate::views::terminal::console::leave_keys();
    // The chords as the keyboard sends them (the menus' own bindings).
    let (next_key, previous_key) = ("alt-cmd-`", "alt-cmd-~");
    drive::activate(main, cx);
    // Into the console from the control before it, by Tab.
    cx.update(|cx| {
        let _ = main.update(cx, |_, window, cx| {
            let handle = gpui_kit::Focusable::focus_handle(console.read(cx), cx);
            window.focus(&handle, cx);
        });
    });
    settle(cx, 200).await;
    super::press(main, previous_key, cx);
    settle(cx, 300).await;
    let mut pass = ok(
        &format!("{previous} leaves the console for the control before it"),
        !in_console(cx),
    );
    let before = focused_node(main, cx).await;
    pass &= ok(
        &format!(
            "…a labelled stop ({})",
            before.as_ref().map_or("(no node)".into(), Node::describe)
        ),
        before
            .as_ref()
            .is_some_and(|n| named(n) && n.role != "Terminal"),
    );
    super::press(main, "tab", cx);
    settle(cx, 300).await;
    pass &= ok("Tab from there goes into the console", in_console(cx));
    let hint = cx.update(|cx| pane.read(cx).shows_leave_hint());
    pass &= ok("…and the bar under it says how to leave", hint);
    shoot_main(dir, "a11y-terminal-leave-hint", cx).await;
    // VoiceOver's help on the console names both ways out.
    let help = cx.update(|cx| {
        let l = cx.l10n().clone();
        l.desktop_terminal_keys_help(&next, &previous)
    });
    let tree = cx.update(|cx| {
        main.update(cx, |_, window, _| window.debug_a11y_tree_json())
            .ok()
            .flatten()
            .unwrap_or_default()
    });
    // The dump writes each description as a JSON string, as serde does.
    let quoted = serde_json::to_string(&help).unwrap_or_default();
    pass &= ok(
        &format!("the console's VoiceOver help names {next} and {previous}"),
        tree.contains(&quoted),
    );
    // Inside, Tab is the shell's: focus stays.
    super::press(main, "tab", cx);
    settle(cx, 300).await;
    pass &= ok(
        "Tab inside the console stays there (the shell's)",
        in_console(cx),
    );
    // Next Area: out to the control after it.
    super::press(main, next_key, cx);
    settle(cx, 300).await;
    pass &= ok(
        &format!("{next} leaves the console for the control after it"),
        !in_console(cx),
    );
    let after = focused_node(main, cx).await;
    pass &= ok(
        &format!(
            "…a labelled stop ({})",
            after.as_ref().map_or("(no node)".into(), Node::describe)
        ),
        after
            .as_ref()
            .is_some_and(|n| named(n) && n.role != "Terminal"),
    );
    let hint = cx.update(|cx| pane.read(cx).shows_leave_hint());
    pass &= ok("…and the bar no longer says how to leave", !hint);
    pass
}

/// Settings › Keyboard lists Move Focus to Next and Previous Area with
/// their chords (the Go group), and the Terminal group's footer says how to
/// leave a terminal: shot in both modes with each group in view.
async fn keyboard_rows(dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some(handle) = settings_tab(Tab::Keyboard, dir, "a11y-settings-keyboard", cx).await else {
        return ok("Settings › Keyboard", false);
    };
    let (next, previous) = crate::views::terminal::console::leave_keys();
    let (next_row, previous_row) = cx.update(|cx| {
        let l = cx.l10n().clone();
        (l.desktop_menu_next_area(), l.desktop_menu_previous_area())
    });
    let mut pass = true;
    let mut reached_terminal = false;
    // The Go group, then the Terminal group and its footer, in view.
    let at = cx.update(|cx| {
        handle
            .update(cx, |_, window, _| {
                let size = window.bounds().size;
                gpui_kit::point(size.width * 0.65, size.height * 0.5)
            })
            .ok()
    });
    if let Some(at) = at {
        let mut shot_go = false;
        for _ in 0..40 {
            drive::scroll(handle, at, 120., cx);
            settle(cx, 120).await;
            let nodes = drive::nodes(handle, cx).await;
            let height = cx.update(|cx| {
                handle
                    .update(cx, |_, window, _| f32::from(window.bounds().size.height))
                    .unwrap_or(0.)
            });
            let in_view = |label: &str| {
                nodes.iter().any(|n| {
                    n.label.contains(label)
                        && n.bounds.is_some_and(|b| {
                            let y = f32::from(b.origin.y);
                            y > 60. && y < height - 140.
                        })
                })
            };
            if !shot_go && in_view(&previous_row) {
                // Drawn now (rows out of view have no accessible node): each
                // row's keycap, named for the row, with its chord as what
                // VoiceOver adds after the name (its description).
                let tree: serde_json::Value = cx
                    .update(|cx| {
                        handle
                            .update(cx, |_, window, _| window.debug_a11y_tree_json())
                            .ok()
                            .flatten()
                    })
                    .and_then(|json| serde_json::from_str(&json).ok())
                    .unwrap_or_default();
                for (label, chord) in [(&next_row, &next), (&previous_row, &previous)] {
                    pass &= ok(
                        &format!("Settings › Keyboard lists {label}, read with {chord}"),
                        described(&tree, label, chord),
                    );
                }
                crate::smoke::shoot_both_modes(handle, dir, "a11y-settings-keyboard-go", cx).await;
                shot_go = true;
            }
            if in_view(&cx.update(|cx| cx.l10n().desktop_terminal_clear_scrollback())) {
                // Past the Terminal group's last rows: its footer is below.
                drive::scroll(handle, at, 160., cx);
                settle(cx, 200).await;
                crate::smoke::shoot_both_modes(handle, dir, "a11y-settings-keyboard-terminal", cx)
                    .await;
                reached_terminal = true;
                break;
            }
        }
        pass &= ok("Settings › Keyboard's Go group shot in view", shot_go);
    } else {
        pass &= ok("Settings › Keyboard: a point to scroll at", false);
    }
    pass &= ok(
        "Settings › Keyboard's Terminal group and its footer shot in view",
        reached_terminal,
    );
    pass
}

/// Whether the accessibility dump `tree` has a node named `label` whose
/// description is `description`.
fn described(tree: &serde_json::Value, label: &str, description: &str) -> bool {
    match tree {
        serde_json::Value::Object(map) => {
            let aria = map.get("aria").unwrap_or(tree);
            let named = aria.get("label").and_then(|v| v.as_str()) == Some(label);
            let said = aria.get("description").and_then(|v| v.as_str()) == Some(description);
            (named && said) || map.values().any(|v| described(v, label, description))
        }
        serde_json::Value::Array(items) => items.iter().any(|v| described(v, label, description)),
        _ => false,
    }
}

fn announced(cx: &mut AsyncApp) -> Vec<SharedString> {
    cx.update(|cx| AnnouncementLog::texts(cx))
}

fn open_item(item: AreaItem, cx: &mut AsyncApp) {
    cx.update(|cx| {
        let nav = cx.global::<AppState>().stores.navigation.clone();
        nav.update(cx, |n, cx| n.open_item(item, cx));
    });
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let simulated = cx.update(|cx| {
        cx.try_global::<KeyboardAccess>()
            .is_some_and(|k| k.all_controls)
    });
    let mut pass = ok(
        "Full Keyboard Access is simulated in the app (CONDUIT_FULL_KEYBOARD_ACCESS=1)",
        simulated,
    );
    cx.update(AnnouncementLog::install);
    pass &= sign_in(&url, &email, &password, cx).await;
    let Some(main) = cx.update(main_window).map(|(h, _)| h) else {
        return ok("the main window", false);
    };
    pass &= ok("the models are listed", wait_models(cx).await);
    let l = cx.update(|cx| cx.l10n().clone());
    // Advanced on, as the phone asks before Scheduled Tasks and Personal
    // Connections.
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

    // ── Temporary Chat, said aloud ─────────────────────────────────────
    for (on, words) in [
        (true, l.temporary_chat_tooltip()),
        (false, l.desktop_announce_temporary_off()),
    ] {
        in_pane(cx, move |p, _, cx| {
            p.composer
                .update(cx, |_, cx| cx.emit(ChatComposerEvent::Temporary(on)))
        });
        settle(cx, 300).await;
        let last = cx.update(|cx| AnnouncementLog::last(cx));
        pass &= ok(
            &format!(
                "Temporary Chat {} is said: “{words}” ({last:?})",
                if on { "on" } else { "off" }
            ),
            last.is_some_and(|a| a.text.as_ref() == words && a.priority == Priority::Medium),
        );
    }

    // ── The `@` menu says each step ────────────────────────────────────
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| {
            c.focus_input(window, cx);
            c.set_text("Ask @", window, cx)
        })
    });
    let rows = wait_until(cx, Duration::from_secs(15), |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer
                .read(cx)
                .menu_rows(cx)
                .is_some_and(|(_, r)| r.len() >= 2)
        })
    })
    .await;
    pass &= ok("@ lists two rows or more", rows);
    // The people and channels come after the models: wait for the list to
    // stop growing, so the step is said against the rows as they stay.
    let mut count = 0;
    for _ in 0..20 {
        settle(cx, 400).await;
        let now = cx.update(|cx| {
            pane(cx)
                .and_then(|p| p.read(cx).composer.read(cx).menu_rows(cx))
                .map_or(0, |(_, r)| r.len())
        });
        if now == count {
            break;
        }
        count = now;
    }
    let before = cx.update(|cx| AnnouncementLog::len(cx));
    in_pane(cx, |p, window, cx| {
        p.composer
            .update(cx, |c, cx| c.menu_key("down", window, cx))
    });
    settle(cx, 200).await;
    let menu = cx.update(|cx| pane(cx).and_then(|p| p.read(cx).composer.read(cx).menu_rows(cx)));
    let expected = menu.as_ref().and_then(|(_, rows)| {
        let (group, title) = rows.get(1)?;
        let row = match group {
            Some(g) => format!("{title}, {g}"),
            None => title.clone(),
        };
        Some(crate::views::a11y::row_text(&l, &row, 1, rows.len()))
    });
    let last = cx.update(|cx| AnnouncementLog::last(cx));
    pass &= ok(
        &format!("↓ in the @ menu says the row and its place ({expected:?}, heard {last:?})"),
        cx.update(|cx| AnnouncementLog::len(cx)) == before + 1
            && expected.is_some()
            && last.is_some_and(|a| {
                Some(a.text.to_string()) == expected && a.priority == Priority::High
            }),
    );
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| {
            c.menu_key("escape", window, cx);
            c.set_text("", window, cx)
        })
    });

    // ── Copy says "Copied" ─────────────────────────────────────────────
    send("Name a hardy herb for a windowsill.", cx).await;
    pass &= ok(
        "the question is answered",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    in_pane(cx, |p, _, cx| p.copy_last_response(cx));
    settle(cx, 300).await;
    let copied = l.desktop_copied();
    pass &= ok(
        &format!("Copy is said: “{copied}”"),
        announced(cx).iter().any(|t| t.as_ref() == copied),
    );
    shoot_main(dir, "a11y-chat", cx).await;

    // ── Calendar ───────────────────────────────────────────────────────
    open_item(AreaItem::Calendar, cx);
    let loaded = wait_until(cx, Duration::from_secs(30), |cx| {
        cx.global::<AppState>()
            .stores
            .calendar
            .read(cx)
            .agenda
            .as_ref()
            .is_some_and(|a| a.failure.is_none() && a.first_day.is_some())
    })
    .await;
    pass &= ok("Calendar shows its agenda", loaded);
    settle(cx, 600).await;
    let region = main_pane(main, cx);
    pass &= screen(
        main,
        "a11y-calendar",
        &[
            ("Button", l.calendar_today()),
            ("Button", l.calendar_add_event()),
            ("Button", l.calendar_previous_days(14)),
            ("Button", l.calendar_next_days(14)),
        ],
        // Today is disabled (no stop) while the range starts today.
        &[
            ("Button", l.calendar_next_days(14)),
            ("Button", l.calendar_add_event()),
        ],
        region,
        dir,
        cx,
    )
    .await;
    // The range is said as it moves.
    let before = cx.update(|cx| AnnouncementLog::len(cx));
    let calendar = cx.update(|cx| {
        cx.global::<AppState>()
            .main_view
            .clone()
            .and_then(|v| v.read(cx).area_pane.read(cx).calendar.clone())
    });
    if let Some(calendar) = calendar {
        let _ = cx.update(|cx| main.update(cx, |_, _, cx| calendar.update(cx, |c, cx| c.next(cx))));
    }
    let moved = wait_until(cx, Duration::from_secs(20), |cx| {
        let Some(agenda) = cx
            .global::<AppState>()
            .stores
            .calendar
            .read(cx)
            .agenda
            .clone()
        else {
            return false;
        };
        let range = crate::views::calendar::format::range_label(&agenda, cx.l10n());
        AnnouncementLog::len(cx) > before
            && AnnouncementLog::last(cx).is_some_and(|a| a.text.as_ref() == range)
    })
    .await;
    pass &= ok("the calendar's new range is said as it moves", moved);
    shoot_main(dir, "a11y-calendar", cx).await;

    // ── Scheduled Tasks ────────────────────────────────────────────────
    open_item(AreaItem::Automations, cx);
    let listed = wait_until(cx, Duration::from_secs(30), |cx| {
        cx.global::<AppState>()
            .stores
            .tasks
            .read(cx)
            .list
            .as_ref()
            .is_some_and(|l| l.available && l.failure.is_none())
    })
    .await;
    pass &= ok("Scheduled Tasks lists the account's tasks", listed);
    settle(cx, 600).await;
    pass &= screen(
        main,
        "a11y-tasks",
        &[("Button", l.scheduled_tasks_add())],
        &[("Button", l.scheduled_tasks_add())],
        region,
        dir,
        cx,
    )
    .await;
    shoot_main(dir, "a11y-tasks", cx).await;

    // ── The Terminal ───────────────────────────────────────────────────
    let server = super::terminal::SERVER;
    let listed = wait_until(cx, Duration::from_secs(60), |cx| {
        cx.global::<AppState>()
            .stores
            .areas
            .read(cx)
            .terminal(server)
            .is_some()
    })
    .await;
    pass &= ok("the seed's terminal is listed", listed);
    if listed {
        open_item(AreaItem::Terminal(server.into()), cx);
        settle(cx, 2500).await;
        let picker = l.desktop_terminal_server_picker("Build box");
        let ports = l.terminal_ports_toggle();
        pass &= screen(
            main,
            "a11y-terminal",
            &[("Button", picker.clone())],
            &[
                ("Button", picker),
                ("Button", ports),
                ("Terminal", l.terminal()),
            ],
            region,
            dir,
            cx,
        )
        .await;
        shoot_main(dir, "a11y-terminal", cx).await;
        pass &= leave_terminal(main, dir, cx).await;
    }
    pass &= keyboard_rows(dir, cx).await;

    // ── Settings › Notifications and Personal Connections ──────────────
    for (tab, name) in [
        (Tab::Notifications, "a11y-settings-notifications"),
        (Tab::PersonalConnections, "a11y-settings-connections"),
    ] {
        let visible = cx.update(|cx| {
            let stores = cx.global::<AppState>().stores.clone();
            Tab::visible(&stores, cx).contains(&tab)
        });
        if !visible {
            println!("SMOKE e2e skip {name}: the account has no such tab");
            continue;
        }
        if let Some(handle) = settings_tab(tab, dir, name, cx).await {
            pass &= screen(handle, name, &[], &[], None, dir, cx).await;
        }
    }
    pass
}
