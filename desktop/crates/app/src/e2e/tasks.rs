//! `--e2e tasks`: the Scheduled Tasks pane on the seeded server.
//!
//! Signs in to the local Open WebUI as its admin, then: with Settings'
//! Advanced off the sidebar has no Scheduled Tasks and the pane, reached
//! anyway, offers to turn Advanced on, as the phone's page does; with it on
//! the section appears. A task is created in the editor (a daily schedule
//! chosen with the controls, the fake model), Run Now is watched until the
//! run is in its history, and the run's result chat opens with the model's
//! answer; the task is paused (and listed under Paused), renamed, and
//! deleted. Screenshots in light and dark, and AccessKit checks.

use std::path::Path;
use std::time::Duration;

use conduit_protocol::{AppSettingsPatch, AutomationDetail, AutomationList};
use gpui_kit::{App, AsyncApp, Entity};

use super::{E2eInputs, NO_SERVER, ax, has, main_window, ok, settle, shoot_main, wait_until};
use crate::AppState;
use crate::actions::SettingsChoice;
use crate::stores::navigation::{Area, AreaItem};
use crate::views::sheet;
use crate::views::tasks::TasksPane;
use crate::views::tasks::editor::TaskEditor;

fn list(cx: &mut App) -> Option<AutomationList> {
    cx.global::<AppState>().stores.tasks.read(cx).list.clone()
}

fn detail(cx: &mut App) -> Option<AutomationDetail> {
    cx.global::<AppState>().stores.tasks.read(cx).detail.clone()
}

fn task_id(name: &str, cx: &mut App) -> Option<String> {
    list(cx)?
        .items
        .into_iter()
        .find(|t| t.name == name)
        .map(|t| t.id)
}

fn pane(cx: &mut App) -> Option<Entity<TasksPane>> {
    let view = cx.global::<AppState>().main_view.clone()?;
    view.read(cx).area_pane.read(cx).tasks.clone()
}

fn in_pane<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut TasksPane, &mut gpui_kit::Window, &mut gpui_kit::Context<TasksPane>) -> R,
) -> Option<R> {
    let (handle, _) = cx.update(main_window)?;
    let pane = cx.update(pane)?;
    cx.update(|cx| {
        handle
            .update(cx, |_, window, cx| {
                pane.update(cx, |p, cx| f(p, window, cx))
            })
            .ok()
    })
}

fn editor(cx: &mut App) -> Option<Entity<TaskEditor>> {
    sheet::current::<TaskEditor>(cx)
}

fn in_editor<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut TaskEditor, &mut gpui_kit::Window, &mut gpui_kit::Context<TaskEditor>) -> R,
) -> Option<R> {
    let handle = cx.update(|cx| sheet::current_window(cx))?;
    let entity = cx.update(editor)?;
    cx.update(|cx| {
        handle
            .update(cx, |_, window, cx| {
                entity.update(cx, |v, cx| f(v, window, cx))
            })
            .ok()
    })
}

fn areas(cx: &mut App) -> Vec<Area> {
    let caps = cx
        .global::<AppState>()
        .stores
        .session
        .read(cx)
        .capabilities();
    crate::stores::areas::visible_areas(&caps)
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let model = inputs.model();
    let mut pass = super::chat::sign_in(&url, &email, &password, cx).await;

    // ── Advanced first, as on the phone ───────────────────────────────
    let allowed = wait_until(cx, Duration::from_secs(60), |cx| {
        let caps = cx
            .global::<AppState>()
            .stores
            .session
            .read(cx)
            .capabilities();
        caps.automations && caps.calendar
    })
    .await;
    pass &= ok("the server allows the admin scheduled tasks", allowed);
    pass &= ok(
        "with Advanced off the sidebar has no Scheduled Tasks",
        cx.update(|cx| !areas(cx).contains(&Area::Automations)),
    );
    let navigation = cx.update(|cx| cx.global::<AppState>().stores.navigation.clone());
    cx.update(|cx| navigation.update(cx, |n, cx| n.open_item(AreaItem::Automations, cx)));
    settle(cx, 800).await;
    shoot_main(dir, "tasks-advanced", cx).await;
    if let Some((main, _)) = cx.update(main_window) {
        let controls = ax(main, "tasks-advanced", dir, cx).await;
        pass &= ok(
            "reached anyway, the pane offers Turn On Advanced",
            has(&controls, "Button", "Turn On Advanced"),
        );
    }
    cx.update(|cx| {
        let settings = cx.global::<AppState>().stores.app_settings.clone();
        settings.update(cx, |s, cx| {
            s.set(
                AppSettingsPatch {
                    advanced_features_enabled: Some(true),
                    ..Default::default()
                },
                cx,
            )
        })
    });
    let offered = wait_until(cx, Duration::from_secs(30), |cx| {
        areas(cx).contains(&Area::Automations)
    })
    .await;
    pass &= ok("Advanced on, Scheduled Tasks joins the sidebar", offered);
    let listed = wait_until(cx, Duration::from_secs(30), |cx| {
        list(cx).is_some_and(|l| l.available && l.failure.is_none())
    })
    .await;
    pass &= ok("the pane lists the account's tasks", listed);
    pass &= ok(
        "a new account has none",
        cx.update(|cx| list(cx).is_some_and(|l| l.items.is_empty())),
    );
    settle(cx, 500).await;
    shoot_main(dir, "tasks-empty", cx).await;

    // ── Create a task ──────────────────────────────────────────────────
    let name = "Morning garden digest";
    in_pane(cx, |p, window, cx| p.new_task(window, cx));
    let model_check = model.clone();
    let opened = wait_until(cx, Duration::from_secs(30), move |cx| {
        editor(cx).is_some_and(|e| {
            let e = e.read(cx);
            e.fields.is_some()
                && e.editor
                    .as_ref()
                    .and_then(|ed| ed.models.as_ref())
                    .is_some_and(|m| m.iter().any(|m| m.id == model_check))
        })
    })
    .await;
    pass &= ok(
        "New Scheduled Task opens the editor, offering the server's models",
        opened,
    );
    in_editor(cx, |e, window, cx| e.save(window, cx));
    let refused = wait_until(cx, Duration::from_secs(10), |cx| {
        editor(cx).is_some_and(|e| {
            let e = e.read(cx);
            e.attempted && e.issues.iter().any(|i| i == "nameRequired")
        })
    })
    .await;
    pass &= ok("an empty task is refused with what it needs", refused);
    let chosen = model.clone();
    in_editor(cx, move |e, window, cx| {
        e.type_text(name, "Say the word: marigold", window, cx);
        e.on_choice(
            &SettingsChoice {
                menu: "task-model".into(),
                value: chosen,
            },
            cx,
        );
        e.choose_kind("weekly", cx);
    });
    let weekly = wait_until(cx, Duration::from_secs(10), |cx| {
        editor(cx).is_some_and(|e| {
            e.read(cx)
                .fields
                .as_ref()
                .is_some_and(|f| f.schedule.kind == "weekly" && f.schedule.days.len() == 1)
        })
    })
    .await;
    pass &= ok("Weekly starts on today's weekday", weekly);
    in_editor(cx, |e, _, cx| e.choose_kind("daily", cx));
    let daily = wait_until(cx, Duration::from_secs(10), |cx| {
        editor(cx).is_some_and(|e| {
            e.read(cx).fields.as_ref().is_some_and(|f| {
                f.schedule.kind == "daily" && f.schedule.rrule.starts_with("RRULE:FREQ=DAILY")
            })
        })
    })
    .await;
    pass &= ok("Daily keeps the time and carries its rule", daily);
    settle(cx, 500).await;
    shoot_main(dir, "tasks-editor", cx).await;
    if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
        let controls = ax(handle, "tasks-editor", dir, cx).await;
        pass &= ok(
            "the editor's fields and choices are labelled",
            has(&controls, "TextInput", "Name")
                && has(&controls, "Switch", "Active")
                && has(&controls, "ComboBox", "Model")
                && has(&controls, "RadioButton", "Daily")
                && has(&controls, "Button", "Time"),
        );
    }
    in_editor(cx, |e, window, cx| e.save(window, cx));
    let closed = wait_until(cx, Duration::from_secs(20), |cx| !sheet::is_open(cx)).await;
    pass &= ok("Save closes the editor", closed);
    let created = wait_until(cx, Duration::from_secs(20), move |cx| {
        task_id(name, cx).is_some()
            && detail(cx).is_some_and(|d| d.summary.name == name && !d.next_runs.is_empty())
    })
    .await;
    pass &= ok("the task is listed and shown, with its next runs", created);
    let Some(id) = cx.update(|cx| task_id(name, cx)) else {
        return ok("the task's id", false);
    };
    settle(cx, 500).await;
    shoot_main(dir, "tasks-detail", cx).await;
    if let Some((main, _)) = cx.update(main_window) {
        let controls = ax(main, "tasks-detail", dir, cx).await;
        pass &= ok(
            "the list and the task are labelled",
            has(&controls, "Button", "New Scheduled Task")
                && has(&controls, "RadioButton", "Paused")
                && has(&controls, "Switch", "Active")
                && has(&controls, "Button", "Run Now")
                && has(&controls, "Button", "Edit…"),
        );
    }

    // ── Run Now, watched until the run is in the history ──────────────
    // The server runs it as a chat turn this Mac did not start: its answer
    // notifies as the phone's does (the server's socket), once.
    let routed_before = cx.update(|cx| crate::desktop::routed_notifications(cx).len());
    let run_id = id.clone();
    in_pane(cx, move |p, _, cx| p.run(&run_id, cx));
    let waiting = wait_until(cx, Duration::from_secs(15), {
        let id = id.clone();
        move |cx| {
            cx.global::<AppState>()
                .stores
                .tasks
                .read(cx)
                .progress
                .get(&id)
                .is_some_and(|p| matches!(p.phase.as_str(), "waiting" | "finished"))
        }
    })
    .await;
    pass &= ok("Run Now is accepted and watched", waiting);
    let finished = wait_until(cx, Duration::from_secs(150), {
        let id = id.clone();
        move |cx| {
            let tasks = cx.global::<AppState>().stores.tasks.read(cx);
            tasks
                .progress
                .get(&id)
                .is_some_and(|p| p.phase == "finished")
                && tasks
                    .runs
                    .first()
                    .is_some_and(|r| r.succeeded && r.result_chat_id.is_some())
        }
    })
    .await;
    pass &= ok(
        "the run finishes and heads the history, with its chat",
        finished,
    );
    settle(cx, 500).await;
    shoot_main(dir, "tasks-run", cx).await;
    let run = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .tasks
            .read(cx)
            .runs
            .first()
            .cloned()
    });
    if let Some(run) = run {
        let chat = run.result_chat_id.clone().unwrap_or_default();
        let key = crate::shell::notify::identifier(&chat);
        let notified = |cx: &mut App| {
            crate::desktop::routed_notifications(cx)
                .into_iter()
                .skip(routed_before)
                .filter(|r| r.id == key)
                .collect::<Vec<_>>()
        };
        let heard = wait_until(cx, Duration::from_secs(20), |cx| !notified(cx).is_empty()).await;
        settle(cx, 2500).await;
        let routed = cx.update(notified);
        pass &= ok(
            &format!("the run's answer notifies once, as the core routes it ({routed:?})"),
            heard && routed.len() == 1,
        );
        in_pane(cx, move |p, _, cx| p.open_result(&run, cx));
        let opened = wait_until(cx, Duration::from_secs(40), move |cx| {
            super::chat::chat_store(cx).is_some_and(|s| {
                let s = s.read(cx);
                s.chat_id() == chat
                    && s.messages()
                        .iter()
                        .any(|m| m.role == "assistant" && m.content.contains("marigold"))
            })
        })
        .await;
        pass &= ok(
            "View Chat opens the run's chat with the model's answer",
            opened,
        );
        settle(cx, 500).await;
        shoot_main(dir, "tasks-result-chat", cx).await;
    }
    cx.update(|cx| navigation.update(cx, |n, cx| n.open_item(AreaItem::Automations, cx)));
    settle(cx, 500).await;

    // ── Pause, rename, delete ─────────────────────────────────────────
    let pause_id = id.clone();
    in_pane(cx, move |p, _, cx| p.set_active(&pause_id, false, cx));
    let paused = wait_until(cx, Duration::from_secs(20), {
        let id = id.clone();
        move |cx| {
            detail(cx).is_some_and(|d| !d.summary.active && d.next_runs.is_empty())
                && list(cx).is_some_and(|l| l.items.iter().any(|t| t.id == id && !t.active))
        }
    })
    .await;
    pass &= ok("pausing turns Active off and drops the next runs", paused);
    cx.update(|cx| {
        let tasks = cx.global::<AppState>().stores.tasks.clone();
        tasks.update(cx, |t, cx| t.filter("paused", cx));
    });
    let filtered = wait_until(cx, Duration::from_secs(15), {
        let id = id.clone();
        move |cx| {
            list(cx).is_some_and(|l| l.status == "paused" && l.items.iter().any(|t| t.id == id))
        }
    })
    .await;
    pass &= ok("Paused lists it", filtered);
    shoot_main(dir, "tasks-paused", cx).await;
    cx.update(|cx| {
        let tasks = cx.global::<AppState>().stores.tasks.clone();
        tasks.update(cx, |t, cx| t.filter("active", cx));
    });
    let gone_from_active = wait_until(cx, Duration::from_secs(15), {
        let id = id.clone();
        move |cx| {
            list(cx).is_some_and(|l| l.status == "active" && !l.items.iter().any(|t| t.id == id))
        }
    })
    .await;
    pass &= ok("Active does not", gone_from_active);
    cx.update(|cx| {
        let tasks = cx.global::<AppState>().stores.tasks.clone();
        tasks.update(cx, |t, cx| t.filter("all", cx));
    });
    let edit_id = id.clone();
    in_pane(cx, move |p, window, cx| p.edit(&edit_id, window, cx));
    let editing = wait_until(cx, Duration::from_secs(20), move |cx| {
        editor(cx).is_some_and(|e| {
            let e = e.read(cx);
            e.editor.as_ref().is_some_and(|ed| !ed.is_new)
                && e.fields
                    .as_ref()
                    .is_some_and(|f| f.name == name && !f.active)
        })
    })
    .await;
    pass &= ok("Edit… opens the task as stored", editing);
    in_editor(cx, |e, window, cx| {
        e.type_text(
            "Evening garden digest",
            "Say the word: marigold",
            window,
            cx,
        )
    });
    settle(cx, 300).await;
    in_editor(cx, |e, window, cx| e.save(window, cx));
    let renamed = wait_until(cx, Duration::from_secs(20), |cx| {
        !sheet::is_open(cx) && task_id("Evening garden digest", cx).is_some()
    })
    .await;
    pass &= ok("the rename is listed", renamed);
    let delete_id = id.clone();
    in_pane(cx, move |p, window, cx| p.delete(&delete_id, window, cx));
    let deleted = wait_until(cx, Duration::from_secs(20), {
        let id = id.clone();
        move |cx| {
            list(cx).is_some_and(|l| !l.items.iter().any(|t| t.id == id)) && detail(cx).is_none()
        }
    })
    .await;
    pass &= ok("Delete… (confirmed) removes the task", deleted);
    pass &= terminal_task(dir, cx).await;
    settle(cx, 400).await;
    shoot_main(dir, "tasks-after", cx).await;
    pass
}

const TERMINAL: &str = "buildbox";
const CODEX: &str = "agent:buildbox:codex:gpt-5.1";
const FOLDER: &str = "/home/demo/sketches";

/// A task on the Build box (the seeded server's fake Open Terminal) run by
/// its Codex agent in a working folder (Open WebUI 0.13.3): the editor
/// offers the terminal, then its agents; the three fields are saved, shown
/// on the task's page and in the list, and read back by the editor. Moving
/// the task off its terminal drops the agent and the folder.
async fn terminal_task(dir: &Path, cx: &mut AsyncApp) -> bool {
    let name = "Nightly sketch tidy";
    in_pane(cx, |p, window, cx| p.new_task(window, cx));
    let offered = wait_until(cx, Duration::from_secs(30), |cx| {
        editor(cx).is_some_and(|e| {
            e.read(cx).editor.as_ref().is_some_and(|ed| {
                ed.terminals
                    .as_ref()
                    .is_some_and(|t| t.iter().any(|t| t.id == TERMINAL && t.name == "Build box"))
            })
        })
    })
    .await;
    let mut pass = ok(
        "the editor offers the Build box as the task's terminal",
        offered,
    );
    in_editor(cx, |e, window, cx| {
        e.type_text(name, "Tidy the sketch folder", window, cx);
        e.on_choice(
            &SettingsChoice {
                menu: "task-terminal".into(),
                value: TERMINAL.into(),
            },
            cx,
        );
    });
    let agents = wait_until(cx, Duration::from_secs(30), |cx| {
        editor(cx).is_some_and(|e| {
            let e = e.read(cx);
            !e.agents_loading
                && e.editor.as_ref().is_some_and(|ed| {
                    ed.models.as_ref().is_some_and(|m| {
                        m.iter()
                            .any(|m| m.id == CODEX && m.agent && m.name == "Codex · gpt-5.1")
                    })
                })
        })
    })
    .await;
    pass &= ok(
        "with the Build box chosen, its agents follow the models",
        agents,
    );
    in_editor(cx, |e, window, cx| {
        e.type_folder(FOLDER, window, cx);
        e.on_choice(
            &SettingsChoice {
                menu: "task-model".into(),
                value: CODEX.into(),
            },
            cx,
        );
    });
    let ready = wait_until(cx, Duration::from_secs(20), |cx| {
        editor(cx).is_some_and(|e| {
            let e = e.read(cx);
            !e.agents_loading
                && e.fields.as_ref().is_some_and(|f| {
                    f.model_id == CODEX
                        && f.terminal_id.as_deref() == Some(TERMINAL)
                        && f.working_directory.as_deref() == Some(FOLDER)
                })
                && !e
                    .issues
                    .iter()
                    .any(|i| i.starts_with("model") || i == "terminalRequired")
        })
    })
    .await;
    pass &= ok("Codex in the folder is a task the server takes", ready);
    settle(cx, 600).await;
    shoot_main(dir, "tasks-agent-editor", cx).await;
    if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
        let controls = ax(handle, "tasks-agent-editor", dir, cx).await;
        pass &= ok(
            "the terminal and folder are labelled",
            has(&controls, "ComboBox", "Terminal") && has(&controls, "TextInput", "Working Folder"),
        );
    }
    // An agent posts only to a new chat.
    in_editor(cx, |e, _, cx| e.set_target(true, cx));
    in_editor(cx, |e, window, cx| e.save(window, cx));
    let refused = wait_until(cx, Duration::from_secs(10), |cx| {
        editor(cx).is_some_and(|e| e.read(cx).issues.iter().any(|i| i == "agentNeedsChat"))
    })
    .await;
    pass &= ok("an agent's results may not go to a channel", refused);
    in_editor(cx, |e, _, cx| e.set_target(false, cx));
    settle(cx, 500).await;
    in_editor(cx, |e, window, cx| e.save(window, cx));
    let closed = wait_until(cx, Duration::from_secs(20), |cx| !sheet::is_open(cx)).await;
    pass &= ok("the agent task saves", closed);
    let shown = wait_until(cx, Duration::from_secs(20), move |cx| {
        detail(cx).is_some_and(|d| {
            d.summary.name == name
                && d.terminal_id.as_deref() == Some(TERMINAL)
                && d.terminal_name.as_deref() == Some("Build box")
                && d.working_directory.as_deref() == Some(FOLDER)
                && d.model_name.as_deref() == Some("Codex · gpt-5.1")
                && d.agent.as_ref().is_some_and(|a| a.agent == "codex")
        }) && list(cx).is_some_and(|l| {
            l.items
                .iter()
                .any(|t| t.name == name && t.agent.as_ref().is_some_and(|a| a.model == "gpt-5.1"))
        })
    })
    .await;
    pass &= ok(
        "its page shows the terminal, folder and agent, and the list the agent",
        shown,
    );
    settle(cx, 500).await;
    shoot_main(dir, "tasks-agent-detail", cx).await;
    let Some(id) = cx.update(|cx| task_id(name, cx)) else {
        return ok("the agent task's id", false);
    };
    let edit_id = id.clone();
    in_pane(cx, move |p, window, cx| p.edit(&edit_id, window, cx));
    let read_back = wait_until(cx, Duration::from_secs(20), |cx| {
        editor(cx).is_some_and(|e| {
            let e = e.read(cx);
            e.editor
                .as_ref()
                .is_some_and(|ed| !ed.is_new && ed.agent_name.as_deref() == Some("Codex · gpt-5.1"))
                && e.fields.as_ref().is_some_and(|f| {
                    f.model_id == CODEX
                        && f.terminal_id.as_deref() == Some(TERMINAL)
                        && f.working_directory.as_deref() == Some(FOLDER)
                })
        })
    })
    .await;
    pass &= ok("Edit… reads the terminal, folder and agent back", read_back);
    in_editor(cx, |e, _, cx| {
        e.on_choice(
            &SettingsChoice {
                menu: "task-terminal".into(),
                value: String::new(),
            },
            cx,
        )
    });
    let dropped = wait_until(cx, Duration::from_secs(20), |cx| {
        editor(cx).is_some_and(|e| {
            e.read(cx).fields.as_ref().is_some_and(|f| {
                f.terminal_id.is_none() && f.model_id.is_empty() && f.working_directory.is_none()
            })
        })
    })
    .await;
    pass &= ok("no terminal: the agent and the folder go with it", dropped);
    cx.update(sheet::dismiss);
    settle(cx, 500).await;
    let delete_id = id.clone();
    in_pane(cx, move |p, window, cx| p.delete(&delete_id, window, cx));
    let deleted = wait_until(cx, Duration::from_secs(20), move |cx| {
        list(cx).is_some_and(|l| !l.items.iter().any(|t| t.id == id))
    })
    .await;
    pass &= ok("the agent task is deleted", deleted);
    pass
}
