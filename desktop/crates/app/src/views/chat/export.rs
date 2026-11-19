//! Export: a chat as a file (the phone's `chat_export_sheet.dart`). A JSON
//! backup Open WebUI can import holds the whole chat, every branch and its
//! settings; a Markdown transcript is the conversation shown, as readable
//! text. The daemon reads it from the chat's stored copy (`chats.export`);
//! a save panel asks where it goes, in Downloads by default.

use std::path::{Path, PathBuf};

use conduit_protocol::{ChatExportFile, ChatExportFormat, NoticeLevel};
use gpui_kit::{App, Window};

use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;

fn stores(cx: &App) -> Option<Stores> {
    cx.try_global::<crate::AppState>().map(|s| s.stores.clone())
}

/// `~/Downloads`, or home.
fn downloads() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"));
    let downloads = home.join("Downloads");
    if downloads.is_dir() { downloads } else { home }
}

fn toast(stores: &Stores, level: NoticeLevel, text: String, cx: &mut App) {
    stores.toasts.update(cx, |t, cx| t.show(level, text, cx));
}

/// Writes `file` to `path`; says so (and that it holds edits the server
/// has not had yet, when it does).
fn write(stores: &Stores, file: &ChatExportFile, path: &Path, cx: &mut App) -> bool {
    let l10n = cx.l10n().clone();
    match std::fs::write(path, file.content.as_bytes()) {
        Ok(()) => {
            let name = path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            toast(
                stores,
                NoticeLevel::Success,
                l10n.desktop_chat_exported(&name),
                cx,
            );
            if file.has_unsynced_changes {
                toast(
                    stores,
                    NoticeLevel::Info,
                    l10n.chat_export_unsent_note(),
                    cx,
                );
            }
            true
        }
        Err(e) => {
            log::warn!("export to {}: {e}", path.display());
            toast(stores, NoticeLevel::Error, l10n.chat_export_failed(), cx);
            false
        }
    }
}

/// Export › Backup (JSON)… or Transcript (Markdown)…: reads the chat, asks
/// where to save it, and saves it.
pub fn export(chat_id: String, format: ChatExportFormat, window: &mut Window, cx: &mut App) {
    let Some(stores) = stores(cx) else {
        return;
    };
    let task = stores.chat_list.read(cx).export(&chat_id, format, cx);
    window
        .spawn(cx, async move |cx| {
            let file = match task.await {
                Ok(file) => file,
                Err(e) => {
                    log::warn!("chats.export: {e}");
                    let _ = cx.update(|_, cx| {
                        let text = cx.l10n().chat_export_failed();
                        toast(&stores, NoticeLevel::Error, text, cx);
                    });
                    return;
                }
            };
            let asked =
                cx.update(|_, cx| cx.prompt_for_new_path(&downloads(), Some(&file.file_name)));
            let Ok(asked) = asked else {
                return;
            };
            let Ok(Ok(Some(path))) = asked.await else {
                return;
            };
            let _ = cx.update(|_, cx| write(&stores, &file, &path, cx));
        })
        .detach();
}

/// Exports `chat_id` straight to `dir` under the daemon's file name (the
/// E2E pass, which cannot answer a save panel). The task gives the path.
pub fn export_to_dir(
    chat_id: String,
    format: ChatExportFormat,
    dir: PathBuf,
    cx: &mut App,
) -> gpui_kit::Task<Option<PathBuf>> {
    let Some(stores) = stores(cx) else {
        return gpui_kit::Task::ready(None);
    };
    let task = stores.chat_list.read(cx).export(&chat_id, format, cx);
    cx.spawn(async move |cx| {
        let file = task.await.ok()?;
        let path = dir.join(&file.file_name);
        cx.update(|cx| write(&stores, &file, &path, cx))
            .then_some(path)
    })
}
