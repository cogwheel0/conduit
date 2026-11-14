//! `--e2e workspace`: the workspace's sections and editors, on the seeded
//! local Open WebUI as its admin.
//!
//! Prompts: the seeded ones list, search narrows, a new prompt is made
//! (its command filled from its name), edited into a second version with a
//! commit message; the versions compare, the older one goes into
//! production and the other is deleted; the prompt is switched off in the
//! list, duplicated (the copy opens), shared with the seeded group as an
//! editor and with everyone, exported, deleted, and imported back from the
//! export. Models: a new model over the fake base model with a system
//! prompt and a tool, edited, switched off and on, hidden, deleted.
//! Knowledge: a new base from its sheet; a file uploaded, renamed,
//! re-indexed and moved into a new folder; a text file added; limits
//! saved. Tools: the seeded tool's code and server valves; a new tool from
//! the starting source. Skills: the seeded skill edited, a new one made
//! and deleted. A change from elsewhere (`workspace.changed`) refreshes
//! the list. Screenshots of each section in light and dark, and AccessKit
//! checks of the list and an editor.

use std::path::{Path, PathBuf};
use std::time::Duration;

use conduit_daemon::RpcMethod;
use conduit_protocol::{
    AccessRef, AccessResourceKind, WorkspaceDetail, WorkspaceItem, WorkspaceKind, WorkspaceRef,
    WorkspaceSave, WorkspaceValvesQuery, methods,
};
use gpui_kit::{App, AsyncApp, Context, Entity, Window};

use super::{
    E2eInputs, NO_SERVER, ax, connect_server, fresh_profile, has, in_setup, ok, settle, shoot_main,
    sign_in_password, wait_main, wait_route, wait_setup, wait_until,
};
use crate::AppState;
use crate::smoke::current_route;
use crate::stores::navigation::{AreaItem, WorkspaceSection};
use crate::stores::session::Route;
use crate::views::workspace::{
    EditorView, ItemCommand, ItemEditor as _, WorkspacePane, knowledge::KnowledgeEditor,
    model::ModelEditor, model::Relation, prompt::PromptEditor, sheets::FormSheet,
    skill::SkillEditor, tool::ToolEditor, transfer::TransferHook,
};

/// The workspace pane, once a section was shown.
pub(super) fn pane(cx: &mut App) -> Option<Entity<WorkspacePane>> {
    let view = cx.try_global::<AppState>()?.main_view.clone()?;
    view.read(cx).area_pane.read(cx).workspace.clone()
}

/// Runs `f` on the workspace pane with the main window.
pub(super) fn in_pane<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut WorkspacePane, &mut Window, &mut Context<WorkspacePane>) -> R,
) -> Option<R> {
    let pane = cx.update(pane)?;
    let (handle, _) = cx.update(super::main_window)?;
    handle
        .update(cx, |_, window, cx| {
            pane.update(cx, |p, cx| f(p, window, cx))
        })
        .ok()
}

/// The item named `name` in `section`'s list.
pub(super) fn listed(section: WorkspaceSection, name: &str, cx: &mut App) -> Option<WorkspaceItem> {
    let pane = pane(cx)?;
    pane.read(cx)
        .lists
        .get(&section)?
        .items
        .iter()
        .find(|i| i.name == name)
        .cloned()
}

fn editor(section: WorkspaceSection, cx: &mut App) -> Option<EditorView> {
    pane(cx)?.read(cx).editors.get(&section).cloned()
}

fn prompt_editor(cx: &mut App) -> Option<Entity<PromptEditor>> {
    match editor(WorkspaceSection::Prompts, cx)? {
        EditorView::Prompt(e) => Some(e),
        _ => None,
    }
}

pub(super) fn model_editor(cx: &mut App) -> Option<Entity<ModelEditor>> {
    match editor(WorkspaceSection::Models, cx)? {
        EditorView::Model(e) => Some(e),
        _ => None,
    }
}

pub(super) fn knowledge_editor(cx: &mut App) -> Option<Entity<KnowledgeEditor>> {
    match editor(WorkspaceSection::Knowledge, cx)? {
        EditorView::Knowledge(e) => Some(e),
        _ => None,
    }
}

fn tool_editor(cx: &mut App) -> Option<Entity<ToolEditor>> {
    match editor(WorkspaceSection::Tools, cx)? {
        EditorView::Tool(e) => Some(e),
        _ => None,
    }
}

fn skill_editor(cx: &mut App) -> Option<Entity<SkillEditor>> {
    match editor(WorkspaceSection::Skills, cx)? {
        EditorView::Skill(e) => Some(e),
        _ => None,
    }
}

/// Runs `f` on an editor entity with the main window.
pub(super) fn in_editor<T: 'static, R>(
    cx: &mut AsyncApp,
    get: fn(&mut App) -> Option<Entity<T>>,
    f: impl FnOnce(&mut T, &mut Window, &mut Context<T>) -> R,
) -> Option<R> {
    let e = cx.update(get)?;
    let (handle, _) = cx.update(super::main_window)?;
    handle
        .update(cx, |_, window, cx| e.update(cx, |e, cx| f(e, window, cx)))
        .ok()
}

/// Runs `f` on the sheet down now, when it is a `V`.
pub(super) fn in_sheet<V: 'static, R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut V, &mut Window, &mut Context<V>) -> R,
) -> Option<R> {
    let (handle, body) = cx.update(|cx| {
        Some((
            crate::views::sheet::current_window(cx)?,
            crate::views::sheet::current::<V>(cx)?,
        ))
    })?;
    handle
        .update(cx, |_, window, cx| {
            body.update(cx, |b, cx| f(b, window, cx))
        })
        .ok()
}

pub(super) async fn call<M: RpcMethod>(params: &M::Params, cx: &mut AsyncApp) -> Option<M::Result>
where
    M::Result: Send + 'static,
{
    let rpc = cx.update(|cx| cx.global::<AppState>().connection.read(cx).rpc());
    match rpc.call::<M>(params).await {
        Ok(r) => Some(r),
        Err(e) => {
            println!("SMOKE note {} failed: {e}", M::NAME);
            None
        }
    }
}

pub(super) async fn open_section(section: WorkspaceSection, cx: &mut AsyncApp) -> bool {
    cx.update(|cx| {
        let nav = cx.global::<AppState>().stores.navigation.clone();
        nav.update(cx, |n, cx| n.open_item(AreaItem::Workspace(section), cx));
    });
    wait_until(cx, Duration::from_secs(30), move |cx| {
        pane(cx).is_some_and(|p| {
            let p = p.read(cx);
            p.section == section
                && p.lists
                    .get(&section)
                    .is_some_and(|l| l.loaded && !l.loading)
        })
    })
    .await
}

/// Waits for `section`'s editor to have loaded item `name`'s detail.
pub(super) async fn wait_editor_loaded(section: WorkspaceSection, cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(20), move |cx| {
        match editor(section, cx) {
            Some(EditorView::Prompt(e)) => e.read(cx).detail.is_some(),
            Some(EditorView::Model(e)) => e.read(cx).detail.is_some(),
            Some(EditorView::Knowledge(e)) => {
                e.read(cx).detail.is_some() && e.read(cx).files.is_some()
            }
            Some(EditorView::Tool(e)) => e.read(cx).detail.is_some(),
            Some(EditorView::Skill(e)) => e.read(cx).detail.is_some(),
            None => false,
        }
    })
    .await
}

pub(super) fn open(section: WorkspaceSection, id: String, cx: &mut AsyncApp) {
    in_pane(cx, |p, window, cx| {
        p.open_now(section, Some(id), window, cx)
    });
}

pub(super) fn new_item(section: WorkspaceSection, cx: &mut AsyncApp) {
    in_pane(cx, |p, window, cx| p.open_now(section, None, window, cx));
}

fn command(section: WorkspaceSection, id: &str, command: ItemCommand, cx: &mut AsyncApp) {
    let id = id.to_string();
    in_pane(cx, |p, window, cx| p.run(section, id, command, window, cx));
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
    let exports = dir.join("exports");
    let _ = std::fs::create_dir_all(&exports);
    cx.update(|cx| {
        cx.set_global(TransferHook {
            export_dir: Some(exports.clone()),
            import_file: None,
        })
    });

    pass &= prompts(dir, &exports, inputs, main, cx).await;
    pass &= models(dir, cx).await;
    pass &= knowledge(dir, cx).await;
    pass &= tools(dir, inputs, cx).await;
    pass &= skills(dir, cx).await;
    pass
}

async fn prompts(
    dir: &Path,
    exports: &Path,
    inputs: &E2eInputs,
    main: gpui_kit::AnyWindowHandle,
    cx: &mut AsyncApp,
) -> bool {
    let s = WorkspaceSection::Prompts;
    let mut pass = ok(
        "Workspace › Prompts opens and lists",
        open_section(s, cx).await,
    );
    pass &= ok(
        "the seeded prompts are listed",
        cx.update(|cx| {
            listed(s, "Orbit facts", cx).is_some() && listed(s, "Write a brief", cx).is_some()
        }),
    );
    pass &= ok(
        "the account may manage, import, export and share prompts",
        cx.update(|cx| {
            pane(cx).is_some_and(|p| {
                let a = p.read(cx).allows(s);
                a.manage && a.import_items && a.export_items && a.share
            })
        }),
    );
    // Search narrows the list (on the server).
    in_pane(cx, |p, _, cx| {
        p.list(s).query = "brief".into();
        p.load(s, false, cx);
    });
    let narrowed = wait_until(cx, Duration::from_secs(15), |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx).lists.get(&s).is_some_and(|l| {
                !l.loading && l.items.len() == 1 && l.items[0].name == "Write a brief"
            })
        })
    })
    .await;
    pass &= ok("a search narrows the list to what matches", narrowed);
    in_pane(cx, |p, _, cx| {
        p.list(s).query = String::new();
        p.load(s, false, cx);
    });
    settle(cx, 800).await;

    // New: the command follows the name.
    new_item(s, cx);
    settle(cx, 300).await;
    in_editor(cx, prompt_editor, |e, window, cx| {
        e.set_field("name", "Trail checklist", window, cx);
        e.set_field("content", "List what to pack for {{trail}}.", window, cx);
    });
    settle(cx, 200).await;
    shoot_main(dir, "workspace-prompt-new", cx).await;
    in_editor(cx, prompt_editor, |e, window, cx| {
        crate::views::workspace::ItemEditor::save(e, window, cx)
    });
    let made = wait_until(cx, Duration::from_secs(20), |cx| {
        listed(s, "Trail checklist", cx).is_some()
            && prompt_editor(cx).is_some_and(|e| {
                e.read(cx)
                    .detail
                    .as_ref()
                    .and_then(|d| d.prompt.as_ref())
                    .is_some_and(|p| p.command == "trail-checklist")
            })
    })
    .await;
    pass &= ok("a new prompt is made, its command from its name", made);
    let Some(id) = cx.update(|cx| listed(s, "Trail checklist", cx).map(|i| i.id)) else {
        return ok("the new prompt is listed", false);
    };

    // A second version, with a commit message.
    in_editor(cx, prompt_editor, |e, window, cx| {
        e.set_field(
            "content",
            "List what to pack for {{trail}}, lightest first.",
            window,
            cx,
        );
        e.set_field("commit", "Lightest first", window, cx);
        crate::views::workspace::ItemEditor::save(e, window, cx)
    });
    // Two versions, the new one in production with its message. (A fast
    // local server stamps both in the same second, so the history's order
    // says nothing; the message names the new one.)
    let two = wait_until(cx, Duration::from_secs(20), |cx| {
        prompt_editor(cx).is_some_and(|e| {
            e.read(cx).history.as_ref().is_some_and(|h| {
                h.versions.len() == 2
                    && h.versions.iter().any(|v| {
                        v.production && v.commit_message.as_deref() == Some("Lightest first")
                    })
            })
        })
    })
    .await;
    pass &= ok(
        "a save makes a version with its commit message, in production",
        two,
    );
    settle(cx, 300).await;
    shoot_main(dir, "workspace-prompt-versions", cx).await;
    let versions: Vec<(String, bool)> = cx.update(|cx| {
        prompt_editor(cx)
            .and_then(|e| e.read(cx).history.clone())
            .map(|h| {
                h.versions
                    .iter()
                    .map(|v| {
                        (
                            v.id.clone(),
                            v.commit_message.as_deref() == Some("Lightest first"),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default()
    });
    let newest = versions
        .iter()
        .find(|(_, new)| *new)
        .map(|(id, _)| id.clone());
    let oldest = versions
        .iter()
        .find(|(_, new)| !*new)
        .map(|(id, _)| id.clone());
    if let (2, Some(newest), Some(oldest)) = (versions.len(), newest, oldest) {
        // Compare with production: the comparison sheet.
        let o = oldest.clone();
        in_editor(cx, prompt_editor, move |e, window, cx| {
            e.version_command("compare", &o, window, cx)
        });
        let compared = wait_until(cx, Duration::from_secs(10), |cx| {
            crate::views::sheet::current::<crate::views::workspace::sheets::DiffSheet>(cx).is_some()
        })
        .await;
        pass &= ok("Compare with Production shows the differences", compared);
        settle(cx, 500).await;
        shoot_main(dir, "workspace-prompt-diff", cx).await;
        cx.update(crate::views::sheet::dismiss);
        settle(cx, 600).await;
        // The older version into production, then the newer one deleted.
        let o = oldest.clone();
        in_editor(cx, prompt_editor, move |e, window, cx| {
            e.version_command("production", &o, window, cx)
        });
        let o = oldest.clone();
        let produced = wait_until(cx, Duration::from_secs(15), move |cx| {
            prompt_editor(cx).is_some_and(|e| {
                e.read(cx)
                    .history
                    .as_ref()
                    .is_some_and(|h| h.versions.iter().any(|v| v.id == o && v.production))
            })
        })
        .await;
        pass &= ok(
            "Set as Production moves production to the older version",
            produced,
        );
        let n = newest.clone();
        in_editor(cx, prompt_editor, move |e, window, cx| {
            e.version_command("delete", &n, window, cx)
        });
        let n = newest.clone();
        let deleted = wait_until(cx, Duration::from_secs(15), move |cx| {
            prompt_editor(cx).is_some_and(|e| {
                e.read(cx)
                    .history
                    .as_ref()
                    .is_some_and(|h| h.versions.len() == 1 && h.versions.iter().all(|v| v.id != n))
            })
        })
        .await;
        pass &= ok("Delete Version takes the other version away", deleted);
    } else {
        pass &= ok(
            &format!("two versions to work with ({})", versions.len()),
            false,
        );
    }

    // Switched off from the list.
    in_pane(cx, |p, _, cx| p.toggle(s, id.clone(), cx));
    let off = wait_until(cx, Duration::from_secs(15), |cx| {
        listed(s, "Trail checklist", cx).is_some_and(|i| i.active == Some(false))
    })
    .await;
    pass &= ok("the list's switch turns the prompt off", off);
    // The switch flips at once; the server's answer comes after.
    let mut server_off = false;
    for _ in 0..30 {
        server_off = call::<methods::WorkspaceGet>(
            &WorkspaceRef {
                kind: WorkspaceKind::Prompts,
                id: id.clone(),
            },
            cx,
        )
        .await
        .and_then(|d| d.prompt)
        .is_some_and(|p| !p.active);
        if server_off {
            break;
        }
        settle(cx, 300).await;
    }
    pass &= ok("and the server has it off", server_off);

    // Duplicate: the copy is made and opens.
    command(s, &id, ItemCommand::Duplicate, cx);
    let copied = wait_until(cx, Duration::from_secs(20), |cx| {
        listed(s, "Trail checklist (copy)", cx).is_some()
            && prompt_editor(cx).is_some_and(|e| {
                e.read(cx)
                    .detail
                    .as_ref()
                    .and_then(|d| d.prompt.as_ref())
                    .is_some_and(|p| p.command == "trail-checklist-copy")
            })
    })
    .await;
    pass &= ok("Duplicate makes a copy and opens it", copied);
    let copy_id = cx
        .update(|cx| listed(s, "Trail checklist (copy)", cx).map(|i| i.id))
        .unwrap_or_default();

    // Share Access…: the seeded group as an editor, and everyone.
    command(s, &copy_id, ItemCommand::Share, cx);
    let sheet_up = wait_until(cx, Duration::from_secs(10), |cx| {
        crate::views::sheet::current::<crate::views::access_sheet::AccessSheet>(cx)
            .is_some_and(|a| a.read(cx).state.is_some())
    })
    .await;
    pass &= ok("Share Access… opens the access sheet", sheet_up);
    let group_name = inputs
        .get("OWUI_GROUP_NAME")
        .unwrap_or_else(|| "Trail crew".into());
    let found = wait_until(cx, Duration::from_secs(10), |cx| {
        crate::views::sheet::current::<crate::views::access_sheet::AccessSheet>(cx)
            .is_some_and(|a| a.read(cx).results.iter().any(|p| p.name == group_name))
    })
    .await;
    pass &= ok("the sheet offers the server's groups", found);
    let g = group_name.clone();
    in_sheet::<crate::views::access_sheet::AccessSheet, _>(cx, move |a, window, cx| {
        if let Some(p) = a.results.iter().find(|p| p.name == g).cloned() {
            a.add(&p, window, cx);
            let key = format!("{}:{}", p.r#type, p.id);
            a.set_write(&key, true, cx);
            a.set_audience(conduit_protocol::AccessAudience::Public, cx);
        }
    });
    settle(cx, 300).await;
    shoot_main(dir, "workspace-share-access", cx).await;
    in_sheet::<crate::views::access_sheet::AccessSheet, _>(cx, |a, window, cx| a.save(window, cx));
    let closed = wait_until(cx, Duration::from_secs(15), |cx| {
        !crate::views::sheet::is_open(cx)
    })
    .await;
    pass &= ok("Save closes the access sheet", closed);
    let access = call::<methods::AccessGet>(
        &AccessRef {
            kind: AccessResourceKind::Prompt,
            id: copy_id.clone(),
        },
        cx,
    )
    .await;
    pass &= ok(
        "the copy is shared with the group as an editor and with everyone",
        access.as_ref().is_some_and(|a| {
            a.audience == conduit_protocol::AccessAudience::Public
                && a.grants.iter().any(|g| g.name == group_name && g.write)
        }),
    );
    let public = wait_until(cx, Duration::from_secs(10), |cx| {
        listed(s, "Trail checklist (copy)", cx).is_some_and(|i| i.public)
    })
    .await;
    pass &= ok("the list marks it shared with everyone", public);

    // Export, delete, import back.
    command(s, &copy_id, ItemCommand::Export, cx);
    let file = exports.join("trail-checklist-copy.json");
    let exported = wait_until(cx, Duration::from_secs(15), |_| file.exists()).await;
    pass &= ok("Export… writes the prompt's JSON", exported);
    command(s, &copy_id, ItemCommand::Delete, cx);
    let gone = wait_until(cx, Duration::from_secs(15), |cx| {
        listed(s, "Trail checklist (copy)", cx).is_none()
    })
    .await;
    pass &= ok("Delete… (confirmed) takes the copy away", gone);
    cx.update(|cx| {
        cx.set_global(TransferHook {
            export_dir: Some(exports.to_path_buf()),
            import_file: Some(file.clone()),
        })
    });
    in_pane(cx, |p, window, cx| {
        crate::views::workspace::transfer::import(p, s, window, cx)
    });
    let back = wait_until(cx, Duration::from_secs(20), |cx| {
        listed(s, "Trail checklist (copy)", cx).is_some()
    })
    .await;
    pass &= ok("Import… brings the exported prompt back", back);

    // A change from elsewhere: the list follows `workspace.changed`.
    let changed = match call::<methods::WorkspaceGet>(
        &WorkspaceRef {
            kind: WorkspaceKind::Prompts,
            id: id.clone(),
        },
        cx,
    )
    .await
    {
        Some(mut detail) => {
            if let Some(p) = detail.prompt.as_mut() {
                p.name = "Trail checklist, renamed".into();
            }
            call::<methods::WorkspaceSave>(
                &WorkspaceSave {
                    detail,
                    create: false,
                    metadata_only: true,
                },
                cx,
            )
            .await
            .is_some()
        }
        None => false,
    };
    let followed = changed
        && wait_until(cx, Duration::from_secs(15), |cx| {
            listed(s, "Trail checklist, renamed", cx).is_some()
        })
        .await;
    pass &= ok("a change saved elsewhere refreshes the list", followed);

    open(s, id.clone(), cx);
    wait_editor_loaded(s, cx).await;
    settle(cx, 500).await;
    shoot_main(dir, "workspace-prompts", cx).await;
    let controls = ax(main, "workspace-prompts", dir, cx).await;
    pass &= ok(
        "the list and editor are labelled for VoiceOver",
        has(&controls, "Switch", "Active")
            && has(&controls, "Button", "Share Access")
            && has(&controls, "Button", "More Actions")
            && has(&controls, "TextInput", "Name"),
    );
    pass
}

async fn models(dir: &Path, cx: &mut AsyncApp) -> bool {
    let s = WorkspaceSection::Models;
    let mut pass = ok(
        "Workspace › Models opens and lists",
        open_section(s, cx).await,
    );
    new_item(s, cx);
    let based = wait_until(cx, Duration::from_secs(15), |cx| {
        model_editor(cx).is_some_and(|e| !e.read(cx).base_models().is_empty())
    })
    .await;
    pass &= ok("a new model offers the base models", based);
    in_editor(cx, model_editor, |e, window, cx| {
        e.set_field("name", "Trail Guide", window, cx);
        e.set_field("system", "Answer as a calm trail guide.", window, cx);
        e.set_field("params", "{\"temperature\": 0.4}", window, cx);
        e.set_relation(Relation::Tools, vec!["trail_weather".into()], cx);
    });
    settle(cx, 300).await;
    shoot_main(dir, "workspace-model-new", cx).await;
    in_editor(cx, model_editor, |e, window, cx| {
        crate::views::workspace::ItemEditor::save(e, window, cx)
    });
    let made = wait_until(cx, Duration::from_secs(20), |cx| {
        listed(s, "Trail Guide", cx).is_some()
            && model_editor(cx).is_some_and(|e| {
                e.read(cx)
                    .detail
                    .as_ref()
                    .and_then(|d| d.model.as_ref())
                    .is_some_and(|m| {
                        m.id == "trail-guide"
                            && m.system == "Answer as a calm trail guide."
                            && m.tool_ids == ["trail_weather"]
                            && m.params.get("temperature").and_then(|v| v.as_f64()) == Some(0.4)
                    })
            })
    })
    .await;
    pass &= ok("a new model saves its prompt, parameters and tool", made);
    in_editor(cx, model_editor, |e, window, cx| {
        e.set_field("description", "Plans hikes.", window, cx);
        crate::views::workspace::ItemEditor::save(e, window, cx)
    });
    let edited = wait_until(cx, Duration::from_secs(15), |cx| {
        listed(s, "Trail Guide", cx).is_some_and(|i| i.subtitle.as_deref() == Some("Plans hikes."))
    })
    .await;
    pass &= ok("an edit saves and the list shows it", edited);
    settle(cx, 300).await;
    shoot_main(dir, "workspace-models", cx).await;
    in_pane(cx, |p, _, cx| p.toggle(s, "trail-guide".into(), cx));
    let off = wait_until(cx, Duration::from_secs(15), |cx| {
        listed(s, "Trail Guide", cx).is_some_and(|i| i.active == Some(false))
    })
    .await;
    pass &= ok("the switch turns the model off", off);
    command(s, "trail-guide", ItemCommand::Hide, cx);
    let hidden = wait_until(cx, Duration::from_secs(15), |cx| {
        listed(s, "Trail Guide", cx).is_some_and(|i| i.hidden)
    })
    .await;
    pass &= ok("Hide from Selector hides it", hidden);
    command(s, "trail-guide", ItemCommand::Delete, cx);
    let gone = wait_until(cx, Duration::from_secs(15), |cx| {
        listed(s, "Trail Guide", cx).is_none()
    })
    .await;
    pass &= ok("Delete… takes the model away", gone);
    pass
}

async fn knowledge(dir: &Path, cx: &mut AsyncApp) -> bool {
    let s = WorkspaceSection::Knowledge;
    let mut pass = ok(
        "Workspace › Knowledge opens and lists",
        open_section(s, cx).await,
    );
    pass &= ok(
        "the seeded knowledge base is listed",
        cx.update(|cx| listed(s, "Garden handbook", cx).is_some()),
    );
    // New Knowledge Base…: its sheet.
    in_pane(cx, |p, window, cx| p.new_item(window, cx));
    let up = wait_until(cx, Duration::from_secs(10), |cx| {
        crate::views::sheet::current::<FormSheet>(cx).is_some()
    })
    .await;
    pass &= ok("New Knowledge Base… asks for a name in a sheet", up);
    in_sheet::<FormSheet, _>(cx, |f, window, cx| {
        f.set_value(0, "Seed packets", window, cx);
        f.set_value(1, "Synthetic notes on seeds.", window, cx);
    });
    settle(cx, 300).await;
    shoot_main(dir, "workspace-knowledge-new", cx).await;
    in_sheet::<FormSheet, _>(cx, |f, window, cx| f.confirm(window, cx));
    let made = wait_until(cx, Duration::from_secs(20), |cx| {
        listed(s, "Seed packets", cx).is_some()
            && knowledge_editor(cx).is_some_and(|e| e.read(cx).files.is_some())
    })
    .await;
    pass &= ok("the base is made and opens with its files", made);
    // A file uploaded (as dropped), renamed, re-indexed.
    let file = dir.join("bean-rows.md");
    let _ = std::fs::write(
        &file,
        "# Bean rows\n\nSow beans 10 cm apart, rows 45 cm apart.\n",
    );
    let f = file.clone();
    in_editor(cx, knowledge_editor, move |e, _, cx| {
        e.upload_paths(vec![f], cx)
    });
    let uploaded = wait_until(cx, Duration::from_secs(60), |cx| {
        knowledge_editor(cx).is_some_and(|e| {
            e.read(cx).busy.is_none()
                && e.read(cx)
                    .files
                    .as_ref()
                    .is_some_and(|f| f.files.iter().any(|f| f.filename == "bean-rows.md"))
        })
    })
    .await;
    pass &= ok("a dropped file uploads into the base", uploaded);
    let file_id = cx
        .update(|cx| {
            knowledge_editor(cx).and_then(|e| {
                e.read(cx)
                    .files
                    .as_ref()?
                    .files
                    .iter()
                    .find(|f| f.filename == "bean-rows.md")
                    .map(|f| f.id.clone())
            })
        })
        .unwrap_or_default();
    let fid = file_id.clone();
    in_editor(cx, knowledge_editor, move |e, window, cx| {
        e.file_command("rename", &fid, window, cx)
    });
    let renaming = wait_until(cx, Duration::from_secs(10), |cx| {
        crate::views::sheet::current::<FormSheet>(cx).is_some()
    })
    .await;
    in_sheet::<FormSheet, _>(cx, |f, window, cx| {
        f.set_value(0, "bean-spacing.md", window, cx);
        f.confirm(window, cx)
    });
    let renamed = renaming
        && wait_until(cx, Duration::from_secs(15), |cx| {
            knowledge_editor(cx).is_some_and(|e| {
                e.read(cx)
                    .files
                    .as_ref()
                    .is_some_and(|f| f.files.iter().any(|f| f.filename == "bean-spacing.md"))
            })
        })
        .await;
    pass &= ok("Rename… renames the file", renamed);
    let fid = file_id.clone();
    in_editor(cx, knowledge_editor, move |e, window, cx| {
        e.file_command("reindex", &fid, window, cx)
    });
    let reindexed = wait_until(cx, Duration::from_secs(20), |cx| {
        knowledge_editor(cx).is_some_and(|e| e.read(cx).busy.is_none())
    })
    .await;
    pass &= ok("Re-Index runs", reindexed);
    // A folder, and the file moved into it.
    in_editor(cx, knowledge_editor, |e, window, cx| {
        e.new_folder_sheet(window, cx)
    });
    wait_until(cx, Duration::from_secs(10), |cx| {
        crate::views::sheet::current::<FormSheet>(cx).is_some()
    })
    .await;
    in_sheet::<FormSheet, _>(cx, |f, window, cx| {
        f.set_value(0, "Beds", window, cx);
        f.confirm(window, cx)
    });
    let folder = wait_until(cx, Duration::from_secs(15), |cx| {
        knowledge_editor(cx).is_some_and(|e| {
            e.read(cx)
                .files
                .as_ref()
                .is_some_and(|f| f.directories.iter().any(|d| d.name == "Beds"))
        })
    })
    .await;
    pass &= ok("New Folder… makes a folder", folder);
    let dir_id = cx
        .update(|cx| {
            knowledge_editor(cx).and_then(|e| {
                e.read(cx)
                    .files
                    .as_ref()?
                    .directories
                    .iter()
                    .find(|d| d.name == "Beds")
                    .map(|d| d.id.clone())
            })
        })
        .unwrap_or_default();
    let (fid, did) = (file_id.clone(), dir_id.clone());
    in_editor(cx, knowledge_editor, move |e, window, cx| {
        e.file_command(&format!("move:{did}"), &fid, window, cx)
    });
    let moved = wait_until(cx, Duration::from_secs(15), |cx| {
        knowledge_editor(cx).is_some_and(|e| {
            e.read(cx).busy.is_none()
                && e.read(cx)
                    .files
                    .as_ref()
                    .is_some_and(|f| f.files.iter().all(|f| f.filename != "bean-spacing.md"))
        })
    })
    .await;
    pass &= ok("Move › a folder moves the file out of the top", moved);
    let did = dir_id.clone();
    in_editor(cx, knowledge_editor, move |e, _, cx| {
        e.open_directory(did, cx)
    });
    let inside = wait_until(cx, Duration::from_secs(15), |cx| {
        knowledge_editor(cx).is_some_and(|e| {
            e.read(cx).files.as_ref().is_some_and(|f| {
                f.breadcrumbs.iter().any(|b| b.name == "Beds")
                    && f.files.iter().any(|f| f.filename == "bean-spacing.md")
            })
        })
    })
    .await;
    pass &= ok("the folder opens with the file in it", inside);
    // A text file, typed.
    in_editor(cx, knowledge_editor, |e, window, cx| {
        e.add_text_sheet(window, cx)
    });
    wait_until(cx, Duration::from_secs(10), |cx| {
        crate::views::sheet::current::<FormSheet>(cx).is_some()
    })
    .await;
    in_sheet::<FormSheet, _>(cx, |f, window, cx| {
        f.set_value(0, "watering", window, cx);
        f.set_value(1, "Water the beds at dawn in dry weeks.", window, cx);
        f.confirm(window, cx)
    });
    let texted = wait_until(cx, Duration::from_secs(30), |cx| {
        knowledge_editor(cx).is_some_and(|e| {
            e.read(cx)
                .files
                .as_ref()
                .is_some_and(|f| f.files.iter().any(|f| f.filename == "watering.txt"))
        })
    })
    .await;
    pass &= ok("Add Text File… adds a text file", texted);
    // Limits.
    in_editor(cx, knowledge_editor, |e, window, cx| {
        e.set_field("max_files", "12", window, cx);
        crate::views::workspace::ItemEditor::save(e, window, cx)
    });
    let limited = wait_until(cx, Duration::from_secs(15), |cx| {
        knowledge_editor(cx).is_some_and(|e| {
            e.read(cx)
                .detail
                .as_ref()
                .and_then(|d| d.knowledge.as_ref())
                .is_some_and(|k| k.max_file_count == Some(12))
        })
    })
    .await;
    pass &= ok("the base's file limit saves", limited);
    settle(cx, 400).await;
    shoot_main(dir, "workspace-knowledge", cx).await;
    pass
}

async fn tools(dir: &Path, inputs: &E2eInputs, cx: &mut AsyncApp) -> bool {
    let s = WorkspaceSection::Tools;
    let mut pass = ok(
        "Workspace › Tools opens and lists",
        open_section(s, cx).await,
    );
    let tool_id = inputs
        .get("OWUI_VALVE_TOOL")
        .unwrap_or_else(|| "trail_weather".into());
    open(s, tool_id.clone(), cx);
    pass &= ok("the seeded tool opens", wait_editor_loaded(s, cx).await);
    pass &= ok(
        "its source is in the code editor",
        cx.update(|cx| {
            tool_editor(cx)
                .is_some_and(|e| e.read(cx).code.read(cx).value().contains("class Tools"))
        }),
    );
    settle(cx, 500).await;
    shoot_main(dir, "workspace-tool", cx).await;
    // Valves…: the server's, 5 days.
    in_editor(cx, tool_editor, |e, window, cx| e.valves(window, cx));
    let up = wait_until(cx, Duration::from_secs(15), |cx| {
        crate::views::sheet::current::<crate::views::valves::ValvesSheet>(cx)
            .is_some_and(|v| v.read(cx).document.is_some())
    })
    .await;
    pass &= ok("Valves… opens the tool's valves", up);
    in_sheet::<crate::views::valves::ValvesSheet, _>(cx, |v, _, cx| v.set_value("days", "5", cx));
    settle(cx, 300).await;
    shoot_main(dir, "workspace-tool-valves", cx).await;
    in_sheet::<crate::views::valves::ValvesSheet, _>(cx, |v, window, cx| v.save(window, cx));
    let closed = wait_until(cx, Duration::from_secs(15), |cx| {
        !crate::views::sheet::is_open(cx)
    })
    .await;
    let saved = call::<methods::WorkspaceValves>(
        &WorkspaceValvesQuery {
            tool_id: tool_id.clone(),
            user: false,
        },
        cx,
    )
    .await
    .is_some_and(|v| v.values.get("days").and_then(|d| d.as_i64()) == Some(5));
    pass &= ok("the server valve saves, typed as a number", closed && saved);
    // A new tool from the starting source.
    new_item(s, cx);
    settle(cx, 300).await;
    pass &= ok(
        "a new tool starts from Open WebUI's starting source",
        cx.update(|cx| {
            tool_editor(cx).is_some_and(|e| {
                e.read(cx)
                    .code
                    .read(cx)
                    .value()
                    .contains("get_current_time")
            })
        }),
    );
    in_editor(cx, tool_editor, |e, window, cx| {
        e.set_field("name", "Seed counter", window, cx);
        e.set_field("description", "Counts seeds, invented.", window, cx);
        crate::views::workspace::ItemEditor::save(e, window, cx)
    });
    let made = wait_until(cx, Duration::from_secs(30), |cx| {
        listed(WorkspaceSection::Tools, "Seed counter", cx).is_some()
            && tool_editor(cx).is_some_and(|e| {
                e.read(cx)
                    .detail
                    .as_ref()
                    .and_then(|d| d.tool.as_ref())
                    .is_some_and(|t| {
                        t.id == "seed_counter"
                            && t.functions.iter().any(|f| f == "get_current_time")
                    })
            })
    })
    .await;
    pass &= ok(
        "a new tool saves, its id from its name, its functions read",
        made,
    );
    command(s, "seed_counter", ItemCommand::Delete, cx);
    let gone = wait_until(cx, Duration::from_secs(15), |cx| {
        listed(WorkspaceSection::Tools, "Seed counter", cx).is_none()
    })
    .await;
    pass &= ok("the new tool is deleted", gone);
    pass
}

async fn skills(dir: &Path, cx: &mut AsyncApp) -> bool {
    let s = WorkspaceSection::Skills;
    let mut pass = ok(
        "Workspace › Skills opens and lists",
        open_section(s, cx).await,
    );
    let Some(seeded) = cx.update(|cx| listed(s, "Plain English", cx).map(|i| i.id)) else {
        return ok("the seeded skill is listed", false);
    };
    open(s, seeded.clone(), cx);
    pass &= ok("the seeded skill opens", wait_editor_loaded(s, cx).await);
    in_editor(cx, skill_editor, |e, window, cx| {
        e.set_field(
            "description",
            "Short sentences, everyday words, no jargon.",
            window,
            cx,
        );
        crate::views::workspace::ItemEditor::save(e, window, cx)
    });
    let edited = wait_until(cx, Duration::from_secs(15), |cx| {
        listed(s, "Plain English", cx).is_some_and(|i| {
            i.subtitle.as_deref() == Some("Short sentences, everyday words, no jargon.")
        })
    })
    .await;
    pass &= ok("an edited skill saves", edited);
    settle(cx, 400).await;
    shoot_main(dir, "workspace-skill", cx).await;

    // Duplicate: a skill with unsaved edits is saved or discarded first;
    // then the server copies it (its `clone`, files and all).
    in_editor(cx, skill_editor, |e, window, cx| {
        e.set_field("description", "A draft not saved yet.", window, cx)
    });
    settle(cx, 200).await;
    command(s, &seeded, ItemCommand::Duplicate, cx);
    let refused = wait_until(cx, Duration::from_secs(10), |cx| {
        super::hermes_admin::toasts(cx)
            .iter()
            .any(|t| t.contains("Save or discard your changes before duplicating"))
    })
    .await;
    pass &= ok(
        "Duplicate asks for a skill's edits to be saved or discarded first",
        refused && cx.update(|cx| listed(s, "Plain English (Clone)", cx).is_none()),
    );
    in_editor(cx, skill_editor, |e, window, cx| {
        e.set_field(
            "description",
            "Short sentences, everyday words, no jargon.",
            window,
            cx,
        )
    });
    settle(cx, 300).await;
    command(s, &seeded, ItemCommand::Duplicate, cx);
    let copied = wait_until(cx, Duration::from_secs(20), |cx| {
        listed(s, "Plain English (Clone)", cx).is_some()
    })
    .await;
    let cloned = std::env::var("CONDUIT_OWUI_DIR")
        .ok()
        .and_then(|d| std::fs::read_to_string(format!("{d}/state/server.log")).ok())
        .is_some_and(|log| {
            log.lines()
                .any(|l| l.contains("POST /api/v1/skills/id/") && l.contains("/clone HTTP"))
        });
    pass &= ok(
        "Duplicate has the server copy the skill (its clone, files kept)",
        copied && cloned,
    );
    if let Some(copy) = cx.update(|cx| listed(s, "Plain English (Clone)", cx).map(|i| i.id)) {
        command(s, &copy, ItemCommand::Delete, cx);
        let gone = wait_until(cx, Duration::from_secs(15), |cx| {
            listed(s, "Plain English (Clone)", cx).is_none()
        })
        .await;
        pass &= ok("the copy is deleted", gone);
    }
    new_item(s, cx);
    settle(cx, 300).await;
    in_editor(cx, skill_editor, |e, window, cx| {
        e.set_field("name", "Packing lists", window, cx);
        e.set_field(
            "content",
            "Write packing lists as short bullet points.",
            window,
            cx,
        );
        crate::views::workspace::ItemEditor::save(e, window, cx)
    });
    let made = wait_until(cx, Duration::from_secs(20), |cx| {
        listed(s, "Packing lists", cx).is_some()
    })
    .await;
    pass &= ok("a new skill saves", made);
    in_pane(cx, |p, _, cx| p.toggle(s, "packing-lists".into(), cx));
    let off = wait_until(cx, Duration::from_secs(15), |cx| {
        listed(s, "Packing lists", cx).is_some_and(|i| i.active == Some(false))
    })
    .await;
    pass &= ok("the skill's switch turns it off", off);
    command(s, "packing-lists", ItemCommand::Delete, cx);
    let gone = wait_until(cx, Duration::from_secs(15), |cx| {
        listed(s, "Packing lists", cx).is_none()
    })
    .await;
    pass &= ok("the new skill is deleted", gone);

    // Import Markdown…: the file's front-matter fills a new skill.
    let md = dir.join("trail-packing.md");
    let _ = std::fs::write(
        &md,
        "---\nname: trail_packing\ndescription: Lists for day hikes\n---\nPack water first, then layers.\n",
    );
    let exports = dir.join("exports");
    cx.update(|cx| {
        cx.set_global(TransferHook {
            export_dir: Some(exports),
            import_file: Some(md),
        })
    });
    in_pane(cx, |p, window, cx| {
        crate::views::workspace::skill::import_markdown(p, window, cx)
    });
    let filled = wait_until(cx, Duration::from_secs(15), |cx| {
        skill_editor(cx).is_some_and(|e| e.read(cx).item_id().is_none())
    })
    .await;
    in_editor(cx, skill_editor, |e, window, cx| {
        crate::views::workspace::ItemEditor::save(e, window, cx)
    });
    let imported = filled
        && wait_until(cx, Duration::from_secs(20), |cx| {
            listed(s, "Trail Packing", cx).is_some_and(|i| {
                i.id == "trail_packing" && i.subtitle.as_deref() == Some("Lists for day hikes")
            })
        })
        .await;
    pass &= ok(
        "Import Markdown… fills a new skill from the file's front-matter",
        imported,
    );
    command(s, "trail_packing", ItemCommand::Delete, cx);
    let _: Option<(PathBuf, WorkspaceDetail)> = None;
    pass
}
