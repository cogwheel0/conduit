//! Import and export: a section's items as the JSON file Open WebUI's own
//! workspace exports and imports (a knowledge base as a zip of its files),
//! through a save or open panel, as the phone shares and picks them.
//!
//! The daemon reads and writes the server (`workspace.export`,
//! `workspace.import`, one item at a time so one clash does not stop the
//! rest); the window only asks where.

use std::path::{Path, PathBuf};

use base64::Engine as _;
use conduit_protocol::{
    NoticeLevel, WorkspaceExportFile, WorkspaceExportQuery, WorkspaceImport, methods,
};
use gpui_kit::{App, AsyncWindowContext, Context, Global, PathPromptOptions, WeakEntity, Window};

use super::{WorkspacePane, kind_of};
use crate::l10n::ActiveL10n as _;
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::navigation::WorkspaceSection;

/// Test hook (the E2E pass, which cannot answer panels): exports go to
/// `export_dir` under the daemon's file name, and an import reads
/// `import_file`.
#[derive(Clone, Debug, Default)]
pub struct TransferHook {
    pub export_dir: Option<PathBuf>,
    pub import_file: Option<PathBuf>,
}

impl Global for TransferHook {}

fn hook(cx: &App) -> TransferHook {
    cx.try_global::<TransferHook>().cloned().unwrap_or_default()
}

/// `~/Downloads`, or home.
fn downloads() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"));
    let downloads = home.join("Downloads");
    if downloads.is_dir() { downloads } else { home }
}

/// The file's bytes: JSON text, or a zip sent as base64.
pub fn bytes_of(file: &WorkspaceExportFile) -> Option<Vec<u8>> {
    match (&file.text, &file.base64) {
        (Some(text), _) => Some(text.clone().into_bytes()),
        (None, Some(b64)) => base64::engine::general_purpose::STANDARD.decode(b64).ok(),
        _ => None,
    }
}

fn write(file: &WorkspaceExportFile, path: &Path) -> bool {
    match bytes_of(file).map(|b| std::fs::write(path, b)) {
        Some(Ok(())) => true,
        Some(Err(e)) => {
            log::warn!("export to {}: {e}", path.display());
            false
        }
        None => false,
    }
}

fn toast(pane: &WeakEntity<WorkspacePane>, level: NoticeLevel, text: String, cx: &mut App) {
    if let Some(p) = pane.upgrade() {
        let toasts = p.read(cx).stores().toasts.clone();
        toasts.update(cx, |t, cx| t.show(level, text, cx));
    }
}

/// Export…: item `id` of `section`, named `name`.
pub fn export_one(
    pane: &mut WorkspacePane,
    section: WorkspaceSection,
    id: String,
    name: String,
    window: &mut Window,
    cx: &mut Context<WorkspacePane>,
) {
    let _ = name;
    export(pane, section, Some(id), window, cx);
}

/// Export All…: the whole section.
pub fn export_all(
    pane: &mut WorkspacePane,
    section: WorkspaceSection,
    window: &mut Window,
    cx: &mut Context<WorkspacePane>,
) {
    export(pane, section, None, window, cx);
}

fn export(
    pane: &mut WorkspacePane,
    section: WorkspaceSection,
    id: Option<String>,
    window: &mut Window,
    cx: &mut Context<WorkspacePane>,
) {
    let call = pane
        .rpc()
        .call::<methods::WorkspaceExport>(&WorkspaceExportQuery {
            kind: kind_of(section),
            id,
        });
    let weak = cx.entity().downgrade();
    let hook = hook(cx);
    window
        .spawn(cx, async move |cx: &mut AsyncWindowContext| {
            let failed = |cx: &mut AsyncWindowContext| {
                let _ = cx.update(|_, cx| {
                    let text = cx.l10n().desktop_workspace_model_export_failed();
                    toast(&weak, NoticeLevel::Error, text, cx);
                });
            };
            let file = match call.await {
                Ok(file) => file,
                Err(e) => {
                    log::warn!("workspace.export: {e}");
                    failed(cx);
                    return;
                }
            };
            let path = match hook.export_dir {
                Some(dir) => dir.join(&file.filename),
                None => {
                    let Ok(asked) = cx
                        .update(|_, cx| cx.prompt_for_new_path(&downloads(), Some(&file.filename)))
                    else {
                        return;
                    };
                    let Ok(Ok(Some(path))) = asked.await else {
                        return;
                    };
                    path
                }
            };
            if write(&file, &path) {
                let name = path
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_default();
                let _ = cx.update(|_, cx| {
                    let text = cx.l10n().desktop_chat_exported(&name);
                    toast(&weak, NoticeLevel::Success, text, cx);
                });
            } else {
                failed(cx);
            }
        })
        .detach();
}

/// Import…: a JSON file picked with an open panel, into `section`.
pub fn import(
    pane: &mut WorkspacePane,
    section: WorkspaceSection,
    window: &mut Window,
    cx: &mut Context<WorkspacePane>,
) {
    let rpc = pane.rpc().clone();
    let weak = cx.entity().downgrade();
    let hook = hook(cx);
    let account = super::active_account(pane.stores(), cx);
    window
        .spawn(cx, async move |cx: &mut AsyncWindowContext| {
            let path = match hook.import_file {
                Some(path) => path,
                None => {
                    let Ok(asked) = cx.update(|_, cx| {
                        cx.prompt_for_paths(PathPromptOptions {
                            files: true,
                            directories: false,
                            multiple: false,
                            prompt: None,
                        })
                    }) else {
                        return;
                    };
                    let Ok(Ok(Some(mut paths))) = asked.await else {
                        return;
                    };
                    let Some(path) = paths.pop() else {
                        return;
                    };
                    path
                }
            };
            let Ok(text) = std::fs::read_to_string(&path) else {
                let _ = cx.update(|_, cx| {
                    let text = cx.l10n().desktop_workspace_import_read_failed();
                    toast(&weak, NoticeLevel::Error, text, cx);
                });
                return;
            };
            // Chosen under one account, it is never imported into the next.
            let same = cx
                .update(|_, cx| {
                    weak.upgrade()
                        .is_some_and(|p| super::active_account(p.read(cx).stores(), cx) == account)
                })
                .unwrap_or(false);
            if !same {
                return;
            }
            let result = rpc
                .call::<methods::WorkspaceImport>(&WorkspaceImport {
                    kind: kind_of(section),
                    text,
                })
                .await;
            let _ = cx.update(|window, cx| {
                // Another account's workspace now: this import's results
                // are not shown in it.
                if !weak
                    .upgrade()
                    .is_some_and(|p| super::active_account(p.read(cx).stores(), cx) == account)
                {
                    return;
                }
                let l = cx.l10n().clone();
                match result {
                    Ok(result) => {
                        let total = result.imported + result.failed.len() as i64;
                        toast(
                            &weak,
                            if result.failed.is_empty() {
                                NoticeLevel::Success
                            } else {
                                NoticeLevel::Info
                            },
                            l.desktop_workspace_import_summary(result.imported, total),
                            cx,
                        );
                        if !result.failed.is_empty() {
                            let items = result
                                .failed
                                .iter()
                                .map(|f| {
                                    if f.reason.is_empty() {
                                        f.label.clone()
                                    } else {
                                        format!("{} ({})", f.label, f.reason)
                                    }
                                })
                                .collect::<Vec<_>>()
                                .join(", ");
                            let spec = SheetSpec::notice(
                                l.desktop_workspace_import_batch_failed(),
                                l.desktop_workspace_import_failed(&items),
                                l.desktop_done(),
                            );
                            present_sheet(window, spec, cx).detach();
                        }
                        let _ = weak.update(cx, |p, cx| p.load(section, false, cx));
                    }
                    Err(e) => {
                        log::warn!("workspace.import: {e}");
                        let text = match e.code.as_str() {
                            "rpc.invalidParams" => l.desktop_workspace_import_invalid_json(),
                            _ => super::editor::failure_text(&e, &l),
                        };
                        toast(&weak, NoticeLevel::Error, text, cx);
                    }
                }
            });
        })
        .detach();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_export_is_its_text_or_its_decoded_zip() {
        let json = WorkspaceExportFile {
            filename: "prompts.json".into(),
            mime_type: "application/json".into(),
            text: Some("[]".into()),
            base64: None,
        };
        assert_eq!(bytes_of(&json).as_deref(), Some(&b"[]"[..]));
        let zip = WorkspaceExportFile {
            filename: "garden.zip".into(),
            mime_type: "application/zip".into(),
            text: None,
            base64: Some("UEsDBA==".into()),
        };
        assert_eq!(bytes_of(&zip).as_deref(), Some(&b"PK\x03\x04"[..]));
        let broken = WorkspaceExportFile {
            base64: Some("not base64!".into()),
            ..zip
        };
        assert_eq!(bytes_of(&broken), None);
    }
}
