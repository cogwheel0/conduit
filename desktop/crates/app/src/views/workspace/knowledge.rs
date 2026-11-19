//! The knowledge editor: a base's name, description and file limits, and
//! its files as a Finder-style table with folders. Files arrive by Upload
//! Files…, by dropping them on the table, or as typed text (Add Text
//! File…); each can be renamed, moved to a folder, re-indexed, taken out of
//! the base, or deleted. Folders open, and can be made, renamed and
//! deleted. Reset… empties the base; failed files can be cleared away. A
//! connected (external) base is read-only, as on the phone.

use std::path::PathBuf;
use std::pin::Pin;
use std::rc::Rc;
use std::sync::Arc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::with_alpha;
use conduit_components::views::kit::{Button, grouped_section};
use conduit_protocol::{
    NoticeLevel, ServerFile, WorkspaceDetail, WorkspaceDirectory, WorkspaceDirectoryAction,
    WorkspaceDirectoryOp, WorkspaceFile, WorkspaceFileAction, WorkspaceFileOp, WorkspaceFiles,
    WorkspaceFilesAttach, WorkspaceFilesQuery, WorkspaceKind, WorkspaceKnowledgeDto, WorkspaceRef,
    WorkspaceSave, WorkspaceSectionAccess, WorkspaceTextFile, methods,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, ElementId, Entity, EventEmitter, ExternalPaths, FontWeight,
    MouseButton, MouseDownEvent, PathPromptOptions, Role, SharedString, Subscription, Task,
    WeakEntity, Window, div, px,
};

use super::WorkspacePane;
use super::editor::{self, EditorEvent, Frame, ItemEditor};
use super::sheets::{SheetField, SheetRun, open_form};
use crate::actions::SettingsChoice;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::navigation::WorkspaceSection;
use crate::stores::rpc::Rpc;
use crate::views::forms;
use crate::views::server_files::{ServerFilesEvent, ServerFilesPicker};
use crate::views::sheet::{self, SheetBody};

/// A file's size as Finder writes it ("12 KB", "3.4 MB").
pub fn size_text(bytes: i64) -> String {
    let b = bytes.max(0) as f64;
    if b < 1000. {
        format!("{} bytes", bytes.max(0))
    } else if b < 1_000_000. {
        format!("{:.0} KB", (b / 1000.).max(1.))
    } else if b < 1_000_000_000. {
        format!("{:.1} MB", b / 1_000_000.)
    } else {
        format!("{:.1} GB", b / 1_000_000_000.)
    }
}

/// A limit field's number: empty for none, else a whole number above zero.
pub fn parse_limit(text: &str) -> Option<Option<i64>> {
    let t = text.trim();
    if t.is_empty() {
        return Some(None);
    }
    match t.parse::<i64>() {
        Ok(n) if n > 0 => Some(Some(n)),
        _ => None,
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
struct KnowledgeForm {
    name: String,
    description: String,
    max_files: String,
    max_size: String,
}

pub struct KnowledgeEditor {
    stores: Stores,
    rpc: Rpc,
    pane: WeakEntity<WorkspacePane>,
    id: Option<String>,
    access: WorkspaceSectionAccess,
    pub detail: Option<WorkspaceDetail>,
    name: Entity<InputState>,
    description: Entity<InputState>,
    max_files: Entity<InputState>,
    max_size: Entity<InputState>,
    initial: KnowledgeForm,
    /// The folder shown, and what is in it.
    pub files: Option<WorkspaceFiles>,
    directory: String,
    /// What runs now ("Uploading 2 files…"), or None.
    pub busy: Option<String>,
    saving: bool,
    loading: bool,
    submitted: bool,
    failure: Option<String>,
    files_failure: Option<String>,
    /// A row whose menu is open.
    context_target: Option<String>,
    _subscriptions: Vec<Subscription>,
    _load: Option<Task<()>>,
    _files: Option<Task<()>>,
    /// How files go up: the daemon's `/upload` unless a test puts its own.
    pub upload: Option<FileUpload>,
}

impl EventEmitter<EditorEvent> for KnowledgeEditor {}

/// One file up through the daemon's `/upload`: its answer (the uploaded
/// file, by id), or why not.
pub type FileUpload = Arc<
    dyn Fn(
            String,
            PathBuf,
        ) -> Pin<
            Box<dyn Future<Output = Result<serde_json::Value, conduit_daemon::RpcError>> + Send>,
        > + Send
        + Sync,
>;

/// [`FileUpload`] through the daemon's HTTP client: the file read and sent
/// on the client's runtime, off the main thread.
fn daemon_file_upload(http: conduit_daemon::http::HttpClient) -> FileUpload {
    Arc::new(move |name: String, path: PathBuf| {
        let http = http.clone();
        let (tx, rx) = futures::channel::oneshot::channel();
        conduit_daemon::runtime::shared().spawn(async move {
            let result = match std::fs::read(&path) {
                Ok(bytes) => {
                    http.upload(&name, None, bytes::Bytes::from(bytes), None, 1)
                        .await
                }
                Err(e) => Err(conduit_daemon::protocol::error(
                    conduit_daemon::protocol::codes::INVALID_PARAMS,
                    e.to_string(),
                )),
            };
            let _ = tx.send(result);
        });
        Box::pin(async move {
            rx.await.map_err(|_| {
                conduit_daemon::protocol::error(
                    conduit_daemon::protocol::codes::INTERNAL,
                    "upload dropped",
                )
            })?
        })
    })
}

impl KnowledgeEditor {
    pub fn new(
        stores: Stores,
        pane: WeakEntity<WorkspacePane>,
        id: Option<String>,
        access: WorkspaceSectionAccess,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let rpc = stores.connection.read(cx).rpc();
        let l = cx.l10n().clone();
        let name = forms::input(l.desktop_workspace_knowledge_name(), false, window, cx);
        let description = forms::input(
            l.desktop_workspace_knowledge_description(),
            false,
            window,
            cx,
        );
        let max_files = forms::input(l.workspace_knowledge_limit_default(), false, window, cx);
        let max_size = forms::input(l.workspace_knowledge_limit_default(), false, window, cx);
        let subscriptions = [&name, &description, &max_files, &max_size]
            .into_iter()
            .map(|state| {
                cx.subscribe_in(state, window, |this, _, e: &InputEvent, _, cx| {
                    if matches!(e, InputEvent::Change) {
                        this.failure = None;
                        cx.notify();
                    }
                })
            })
            .collect();
        let mut this = Self {
            stores,
            rpc,
            pane,
            id,
            access,
            detail: None,
            name,
            description,
            max_files,
            max_size,
            initial: KnowledgeForm::default(),
            files: None,
            directory: String::new(),
            busy: None,
            saving: false,
            loading: false,
            submitted: false,
            failure: None,
            files_failure: None,
            context_target: None,
            _subscriptions: subscriptions,
            _load: None,
            _files: None,
            upload: None,
        };
        this.reload(window, cx);
        this
    }

    fn form(&self, cx: &App) -> KnowledgeForm {
        KnowledgeForm {
            name: self.name.read(cx).value().trim().to_string(),
            description: self.description.read(cx).value().trim().to_string(),
            max_files: self.max_files.read(cx).value().trim().to_string(),
            max_size: self.max_size.read(cx).value().trim().to_string(),
        }
    }

    fn dto(&self) -> Option<&WorkspaceKnowledgeDto> {
        self.detail.as_ref()?.knowledge.as_ref()
    }

    fn external(&self) -> bool {
        self.dto().is_some_and(|k| k.external)
    }

    /// The account may change the base and its files.
    fn writable(&self) -> bool {
        self.access.manage
            && !self.external()
            && self.detail.as_ref().is_none_or(|d| d.write_access)
    }

    /// A save answered while the form had changed since it was sent: the
    /// saved item is the one shown now (its id, its detail, what counts as
    /// unchanged), and the form keeps what was typed since.
    fn saved_under_edits(&mut self, detail: WorkspaceDetail, sent: KnowledgeForm) {
        let Some(id) = detail.knowledge.as_ref().map(|i| i.id.clone()) else {
            return;
        };
        self.id = Some(id);
        self.detail = Some(detail);
        self.initial = sent;
        self.submitted = false;
    }

    fn adopt(&mut self, detail: WorkspaceDetail, window: &mut Window, cx: &mut Context<Self>) {
        let Some(k) = detail.knowledge.clone() else {
            return;
        };
        self.id = Some(k.id.clone());
        let limit = |v: Option<i64>| v.map(|n| n.to_string()).unwrap_or_default();
        self.name
            .update(cx, |s, cx| s.set_value(k.name.clone(), window, cx));
        self.description
            .update(cx, |s, cx| s.set_value(k.description.clone(), window, cx));
        self.max_files
            .update(cx, |s, cx| s.set_value(limit(k.max_file_count), window, cx));
        self.max_size
            .update(cx, |s, cx| s.set_value(limit(k.max_file_size), window, cx));
        self.detail = Some(detail);
        self.initial = self.form(cx);
        self.submitted = false;
        cx.notify();
    }

    // ── Files ──────────────────────────────────────────────────────────

    /// Opens folder `directory` ("" is the top) and lists it.
    pub fn open_directory(&mut self, directory: String, cx: &mut Context<Self>) {
        let Some(id) = self.id.clone() else {
            return;
        };
        self.directory = directory.clone();
        let call = self
            .rpc
            .call::<methods::WorkspaceFiles>(&WorkspaceFilesQuery {
                knowledge_id: id,
                directory_id: directory,
                more: false,
            });
        self._files = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(files) => {
                            s.directory = files.directory_id.clone();
                            s.files = Some(files);
                            s.files_failure = None;
                        }
                        Err(e) => {
                            log::warn!("workspace.files: {e}");
                            s.files_failure =
                                Some(cx.l10n().desktop_workspace_knowledge_files_load_failed());
                        }
                    }
                    cx.notify();
                });
            }),
        );
        cx.notify();
    }

    /// Runs a call that answers with the folder as it is now; `done` is
    /// what a toast says once it went through.
    fn files_call(
        &mut self,
        busy: String,
        call: impl std::future::Future<Output = Result<WorkspaceFiles, conduit_daemon::RpcError>>
        + 'static,
        done: Option<String>,
        cx: &mut Context<Self>,
    ) {
        self.busy = Some(busy);
        self.files_failure = None;
        cx.notify();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.busy = None;
                let l = cx.l10n().clone();
                match result {
                    Ok(files) => {
                        s.directory = files.directory_id.clone();
                        s.files = Some(files);
                        if let Some(done) = done {
                            s.stores
                                .toasts
                                .update(cx, |t, cx| t.show(NoticeLevel::Success, done, cx));
                        }
                    }
                    Err(e) => {
                        log::warn!("knowledge files: {e}");
                        s.files_failure = Some(editor::failure_text(&e, &l));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// Upload Files…: picked in an open panel.
    pub fn pick_files(&mut self, cx: &mut Context<Self>) {
        let paths = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: true,
            prompt: None,
        });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if let Ok(Ok(Some(paths))) = paths.await {
                let _ = this.update(cx, |s, cx| s.upload_paths(paths, cx));
            }
        })
        .detach();
    }

    /// Uploads the files at `paths` (picked or dropped) into the folder
    /// shown: each goes up through the daemon, then the daemon links them
    /// once the server has read them in.
    pub fn upload_paths(&mut self, paths: Vec<PathBuf>, cx: &mut Context<Self>) {
        let Some(id) = self.id.clone() else {
            return;
        };
        if !self.writable() || paths.is_empty() {
            return;
        }
        let upload = match self.upload.clone() {
            Some(upload) => upload,
            None => match self.stores.connection.read(cx).http().cloned() {
                Some(http) => daemon_file_upload(http),
                None => return,
            },
        };
        let l = cx.l10n().clone();
        let files: Vec<PathBuf> = paths.into_iter().filter(|p| p.is_file()).collect();
        if files.is_empty() {
            return;
        }
        let first = files[0]
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        let rpc = self.rpc.clone();
        let directory = self.directory.clone();
        // Begun under one account: no file of it goes to the next, and
        // nothing is attached once the account changed.
        let account = super::active_account(&self.stores, cx);
        let same = move |this: &WeakEntity<Self>, cx: &mut AsyncApp| {
            this.update(cx, |s, cx| super::active_account(&s.stores, cx) == account)
                .unwrap_or(false)
        };
        let changed =
            || conduit_daemon::protocol::error("auth.sessionExpired", "the account changed");
        let call = cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let mut ids = vec![];
            for path in files {
                if !same(&this, cx) {
                    return Err(changed());
                }
                let name = path
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_else(|| "file".into());
                let uploaded = upload(name, path).await?;
                if let Some(id) = uploaded.get("id").and_then(|v| v.as_str()) {
                    ids.push(id.to_string());
                }
            }
            if !same(&this, cx) {
                return Err(changed());
            }
            rpc.call::<methods::WorkspaceAttachFiles>(&WorkspaceFilesAttach {
                knowledge_id: id,
                directory_id: directory,
                file_ids: ids,
                uploaded: true,
            })
            .await
        });
        self.files_call(
            l.desktop_workspace_knowledge_uploading(&first),
            call,
            None,
            cx,
        );
    }

    /// Attach Server File…: one of the user's files on the server, picked
    /// in a sheet (the composer's Server Files picker), linked into the
    /// folder shown as it is (mobile's Attach Server File).
    pub fn attach_server_file_sheet(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.id.is_none() || !self.writable() {
            return;
        }
        let rpc = self.rpc.clone();
        let stores = self.stores.clone();
        let editor = cx.entity().downgrade();
        sheet::open(window, 460., cx, move |window, cx| {
            ServerFileSheet::new(&stores, rpc, editor, window, cx)
        });
    }

    /// Links `file`, one of the user's files on the server, into the
    /// folder shown.
    pub fn attach_server_file(&mut self, file: ServerFile, cx: &mut Context<Self>) {
        let Some(id) = self.id.clone() else {
            return;
        };
        if !self.writable() {
            return;
        }
        let l = cx.l10n().clone();
        let call = self
            .rpc
            .call::<methods::WorkspaceAttachFiles>(&WorkspaceFilesAttach {
                knowledge_id: id,
                directory_id: self.directory.clone(),
                file_ids: vec![file.id.clone()],
                uploaded: false,
            });
        self.files_call(
            l.desktop_workspace_knowledge_attaching(&file.name),
            call,
            None,
            cx,
        );
    }

    fn add_text(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.id.clone() else {
            return;
        };
        let l = cx.l10n().clone();
        let rpc = self.rpc.clone();
        let directory = self.directory.clone();
        let weak = cx.entity().downgrade();
        let run: SheetRun = Rc::new(move |values, cx| {
            let call = rpc.call::<methods::WorkspaceAddText>(&WorkspaceTextFile {
                knowledge_id: id.clone(),
                directory_id: directory.clone(),
                filename: values
                    .first()
                    .cloned()
                    .unwrap_or_default()
                    .trim()
                    .to_string(),
                content: values.get(1).cloned().unwrap_or_default(),
            });
            let weak = weak.clone();
            cx.spawn(async move |cx: &mut AsyncApp| match call.await {
                Ok(files) => {
                    let _ = weak.update(cx, |s, cx| {
                        s.directory = files.directory_id.clone();
                        s.files = Some(files);
                        cx.notify();
                    });
                    Ok(())
                }
                Err(e) => Err(cx.update(|cx| editor::failure_text(&e, &cx.l10n().clone()))),
            })
        });
        open_form(
            self.stores.clone(),
            l.workspace_knowledge_add_text(),
            None,
            l.desktop_add(),
            vec![
                SheetField::line(l.workspace_knowledge_add_text_name(), "")
                    .placeholder("notes.txt"),
                SheetField::line(l.desktop_workspace_knowledge_add_text_content(), "").multiline(),
            ],
            run,
            window,
            cx,
        );
    }

    /// A name sheet whose default button runs `op` with the typed name.
    #[allow(clippy::too_many_arguments)]
    fn name_sheet(
        &mut self,
        title: String,
        label: String,
        value: String,
        confirm: String,
        op: Rc<dyn Fn(String) -> WorkspaceRequest>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let rpc = self.rpc.clone();
        let weak = cx.entity().downgrade();
        let run: SheetRun = Rc::new(move |values, cx| {
            let name = values
                .first()
                .cloned()
                .unwrap_or_default()
                .trim()
                .to_string();
            let call = op(name).send(&rpc);
            let weak = weak.clone();
            cx.spawn(async move |cx: &mut AsyncApp| match call.await {
                Ok(files) => {
                    let _ = weak.update(cx, |s, cx| {
                        s.directory = files.directory_id.clone();
                        s.files = Some(files);
                        cx.notify();
                    });
                    Ok(())
                }
                Err(e) => Err(cx.update(|cx| editor::failure_text(&e, &cx.l10n().clone()))),
            })
        });
        open_form(
            self.stores.clone(),
            title,
            None,
            confirm,
            vec![SheetField::line(label, value)],
            run,
            window,
            cx,
        );
    }

    fn new_folder(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.id.clone() else {
            return;
        };
        let l = cx.l10n().clone();
        let parent = self.directory.clone();
        self.name_sheet(
            l.workspace_knowledge_new_folder(),
            l.workspace_knowledge_folder_name(),
            String::new(),
            l.create(),
            Rc::new(move |name| {
                WorkspaceRequest::Directory(WorkspaceDirectoryAction {
                    knowledge_id: id.clone(),
                    op: WorkspaceDirectoryOp::Create,
                    directory_id: None,
                    parent_id: parent.clone(),
                    name,
                })
            }),
            window,
            cx,
        );
    }

    fn file(&self, id: &str) -> Option<WorkspaceFile> {
        let files = self.files.as_ref()?;
        files
            .files
            .iter()
            .chain(files.pending.iter())
            .find(|f| f.id == id)
            .cloned()
    }

    fn directory_named(&self, id: &str) -> Option<WorkspaceDirectory> {
        self.files
            .as_ref()?
            .directories
            .iter()
            .find(|d| d.id == id)
            .cloned()
    }

    /// A file's command from its menu: `rename`, `move:<dir>`, `reindex`,
    /// `remove`, `delete`.
    pub fn file_command(
        &mut self,
        op: &str,
        file_id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(id) = self.id.clone() else {
            return;
        };
        let Some(file) = self.file(file_id) else {
            return;
        };
        let l = cx.l10n().clone();
        let action = |op: WorkspaceFileOp, filename: Option<String>, directory: Option<String>| {
            WorkspaceFileAction {
                knowledge_id: id.clone(),
                file_id: file.id.clone(),
                op,
                filename,
                directory_id: directory,
            }
        };
        match op {
            "rename" => {
                let request = action(WorkspaceFileOp::Rename, None, None);
                self.name_sheet(
                    l.desktop_workspace_knowledge_file_rename(),
                    l.workspace_knowledge_add_text_name(),
                    file.filename.clone(),
                    l.rename(),
                    Rc::new(move |name| {
                        let mut r = request.clone();
                        r.filename = Some(name);
                        WorkspaceRequest::File(r)
                    }),
                    window,
                    cx,
                );
            }
            "reindex" => {
                let call = self.rpc.call::<methods::WorkspaceFileAction>(&action(
                    WorkspaceFileOp::Reindex,
                    None,
                    None,
                ));
                self.files_call(
                    l.desktop_loading(),
                    call,
                    Some(l.desktop_workspace_knowledge_file_reindexed()),
                    cx,
                );
            }
            "remove" | "delete" => {
                let delete = op == "delete";
                let spec = SheetSpec::new(
                    if delete {
                        l.desktop_workspace_delete_file_title()
                    } else {
                        l.desktop_workspace_knowledge_file_detach_title()
                    },
                    if delete {
                        l.desktop_workspace_delete_file_message(&file.filename)
                    } else {
                        l.desktop_workspace_knowledge_file_detach_message(&file.filename)
                    },
                    if delete {
                        l.delete()
                    } else {
                        l.desktop_workspace_remove()
                    },
                    l.cancel(),
                )
                .destructive();
                let ask = present_sheet(window, spec, cx);
                let request = action(
                    if delete {
                        WorkspaceFileOp::Delete
                    } else {
                        WorkspaceFileOp::Remove
                    },
                    None,
                    None,
                );
                // Asked first: the request goes only once confirmed.
                cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                    if ask.await {
                        let _ = this.update(cx, |s, cx| {
                            let call = s.rpc.call::<methods::WorkspaceFileAction>(&request);
                            let busy = cx.l10n().desktop_loading();
                            s.files_call(busy, call, None, cx)
                        });
                    }
                })
                .detach();
            }
            other => {
                if let Some(target) = other.strip_prefix("move:") {
                    let call = self.rpc.call::<methods::WorkspaceFileAction>(&action(
                        WorkspaceFileOp::Move,
                        None,
                        Some(target.to_string()),
                    ));
                    self.files_call(l.desktop_loading(), call, None, cx);
                }
            }
        }
    }

    /// A folder's command from its menu: `open`, `rename`, `delete`.
    pub fn directory_command(
        &mut self,
        op: &str,
        directory_id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(id) = self.id.clone() else {
            return;
        };
        let l = cx.l10n().clone();
        let Some(dir) = self.directory_named(directory_id) else {
            return;
        };
        let parent = self.directory.clone();
        match op {
            "open" => self.open_directory(dir.id.clone(), cx),
            "rename" => {
                let dir_id = dir.id.clone();
                self.name_sheet(
                    l.workspace_knowledge_rename_folder(),
                    l.workspace_knowledge_folder_name(),
                    dir.name.clone(),
                    l.rename(),
                    Rc::new(move |name| {
                        WorkspaceRequest::Directory(WorkspaceDirectoryAction {
                            knowledge_id: id.clone(),
                            op: WorkspaceDirectoryOp::Rename,
                            directory_id: Some(dir_id.clone()),
                            parent_id: parent.clone(),
                            name,
                        })
                    }),
                    window,
                    cx,
                );
            }
            "delete" => {
                let spec = SheetSpec::new(
                    l.desktop_workspace_knowledge_delete_folder_confirm_title(),
                    l.desktop_workspace_knowledge_delete_folder_confirm_message(&dir.name),
                    l.delete(),
                    l.cancel(),
                )
                .destructive();
                let ask = present_sheet(window, spec, cx);
                let request = WorkspaceDirectoryAction {
                    knowledge_id: id,
                    op: WorkspaceDirectoryOp::Delete,
                    directory_id: Some(dir.id.clone()),
                    parent_id: parent,
                    name: String::new(),
                };
                // Asked first: the request goes only once confirmed.
                cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                    if ask.await {
                        let _ = this.update(cx, |s, cx| {
                            let call = s.rpc.call::<methods::WorkspaceDirectoryAction>(&request);
                            let busy = cx.l10n().desktop_loading();
                            s.files_call(busy, call, None, cx)
                        });
                    }
                })
                .detach();
            }
            _ => {}
        }
    }

    /// Reset…: every file out of the base, the base kept.
    fn reset(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.id.clone() else {
            return;
        };
        let l = cx.l10n().clone();
        let name = self.dto().map(|k| k.name.clone()).unwrap_or_default();
        let spec = SheetSpec::new(
            l.desktop_workspace_knowledge_reset_confirm_title(),
            l.desktop_workspace_knowledge_reset_confirm_message(&name),
            l.desktop_workspace_knowledge_reset(),
            l.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        let rpc = self.rpc.clone();
        let handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if !ask.await {
                return;
            }
            let result = rpc
                .call::<methods::WorkspaceKnowledgeReset>(&WorkspaceRef {
                    kind: WorkspaceKind::Knowledge,
                    id,
                })
                .await;
            let _ = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |s, cx| {
                    let l = cx.l10n().clone();
                    match result {
                        Ok(detail) => {
                            s.detail = Some(detail);
                            s.open_directory(String::new(), cx);
                            s.stores.toasts.update(cx, |t, cx| {
                                t.show(
                                    NoticeLevel::Success,
                                    l.desktop_workspace_knowledge_reset_done(),
                                    cx,
                                )
                            });
                        }
                        Err(e) => s.files_failure = Some(editor::failure_text(&e, &l)),
                    }
                    let _ = window;
                    cx.notify();
                });
            });
        })
        .detach();
    }

    fn cleanup(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.id.clone() else {
            return;
        };
        let l = cx.l10n().clone();
        let call = self
            .rpc
            .call::<methods::WorkspaceKnowledgeCleanup>(&WorkspaceRef {
                kind: WorkspaceKind::Knowledge,
                id,
            });
        self.files_call(l.desktop_loading(), call, None, cx);
    }

    fn file_menu(
        &mut self,
        file: &WorkspaceFile,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let l = cx.l10n().clone();
        let choice = |op: String| -> Box<dyn gpui_kit::Action> {
            Box::new(SettingsChoice {
                menu: "knowledge-file".into(),
                value: format!("{op}|{}", file.id),
            })
        };
        let mut moves = NativeMenu::new();
        let files = self.files.clone().unwrap_or_else(|| WorkspaceFiles {
            knowledge_id: String::new(),
            directory_id: String::new(),
            breadcrumbs: vec![],
            directories: vec![],
            files: vec![],
            pending: vec![],
            total: 0,
            has_more: false,
        });
        if !self.directory.is_empty() {
            moves = moves.menu(l.workspace_knowledge_move_root(), choice("move:".into()));
            // The folders above this one.
            for crumb in files.breadcrumbs.iter().rev().skip(1) {
                moves = moves.menu(crumb.name.clone(), choice(format!("move:{}", crumb.id)));
            }
        }
        for dir in &files.directories {
            moves = moves.menu(dir.name.clone(), choice(format!("move:{}", dir.id)));
        }
        let mut menu = NativeMenu::new().menu(l.desktop_rename_ellipsis(), choice("rename".into()));
        if !moves.is_empty() {
            menu = menu.submenu(l.desktop_workspace_knowledge_file_move(), moves);
        }
        menu = menu
            .menu(
                l.workspace_knowledge_file_refresh(),
                choice("reindex".into()),
            )
            .separator()
            .menu(l.workspace_knowledge_file_detach(), choice("remove".into()))
            .menu(l.desktop_workspace_delete_file(), choice("delete".into()));
        self.context_target = Some(file.id.clone());
        cx.notify();
        menu.show(position, window, cx);
        self.clear_target_later(cx);
    }

    fn directory_menu(
        &mut self,
        dir: &WorkspaceDirectory,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let l = cx.l10n().clone();
        let choice = |op: &str| -> Box<dyn gpui_kit::Action> {
            Box::new(SettingsChoice {
                menu: "knowledge-dir".into(),
                value: format!("{op}|{}", dir.id),
            })
        };
        let mut menu = NativeMenu::new().menu(l.desktop_hermes_open_session(), choice("open"));
        if self.writable() {
            menu = menu
                .separator()
                .menu(l.workspace_knowledge_rename_folder(), choice("rename"))
                .menu(l.workspace_knowledge_delete_folder(), choice("delete"));
        }
        self.context_target = Some(dir.id.clone());
        cx.notify();
        menu.show(position, window, cx);
        self.clear_target_later(cx);
    }

    fn clear_target_later(&self, cx: &mut Context<Self>) {
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            cx.background_executor()
                .timer(std::time::Duration::from_millis(300))
                .await;
            let _ = this.update(cx, |s, cx| {
                s.context_target = None;
                cx.notify();
            });
        })
        .detach();
    }

    fn revert(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(detail) = self.detail.clone() {
            self.adopt(detail, window, cx);
        }
    }

    // ── Drawing ────────────────────────────────────────────────────────

    #[allow(clippy::too_many_arguments)]
    fn table_row(
        &self,
        index: usize,
        glyph: IconName,
        name: String,
        size: String,
        status: Option<(String, bool)>,
        target: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> gpui_kit::Stateful<gpui_kit::Div> {
        let t = cx.conduit().clone();
        let r = t.roles;
        let outlined = self.context_target.as_deref() == Some(target);
        let _ = window;
        div()
            .id(ElementId::NamedInteger(
                "knowledge-row".into(),
                index as u64,
            ))
            .role(Role::Row)
            .aria_label(SharedString::from(name.clone()))
            .h(px(32.))
            .px(px(12.))
            .flex()
            .items_center()
            .gap(px(8.))
            .hover(|s| s.bg(r.overlay_hover))
            .when(outlined, |d| d.border_2().border_color(r.focus))
            .child(icon(glyph, 14., r.text_subtle))
            .child(div().flex_1().min_w_0().truncate().child(name))
            .when_some(status, |d, (text, failed)| {
                d.child(
                    div()
                        .flex_none()
                        .text_size(px(t.metrics.small))
                        .text_color(if failed { r.danger } else { r.text_subtle })
                        .child(text),
                )
            })
            .child(
                div()
                    .flex_none()
                    .w(px(72.))
                    .text_right()
                    .text_size(px(t.metrics.small))
                    .text_color(r.text_subtle)
                    .child(size),
            )
    }

    fn files_section(
        &mut self,
        l: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let writable = self.writable();
        let files = self.files.clone();
        let mut rows: Vec<AnyElement> = vec![];
        // The path to the folder shown.
        if let Some(files) = &files {
            let mut crumbs: Vec<AnyElement> = vec![];
            let root = cx.listener(|this, _, _, cx| this.open_directory(String::new(), cx));
            crumbs.push(
                div()
                    .id("knowledge-crumb-root")
                    .role(Role::Link)
                    .cursor_pointer()
                    .text_color(if self.directory.is_empty() {
                        r.text
                    } else {
                        r.text_subtle
                    })
                    .child(l.desktop_workspace_knowledge_root())
                    .on_click(root)
                    .into_any_element(),
            );
            for (i, crumb) in files.breadcrumbs.iter().enumerate() {
                let id = crumb.id.clone();
                crumbs.push(icon(IconName::ChevronRight, 11., r.text_faint).into_any_element());
                crumbs.push(
                    div()
                        .id(ElementId::NamedInteger("knowledge-crumb".into(), i as u64))
                        .role(Role::Link)
                        .cursor_pointer()
                        .text_color(if i + 1 == files.breadcrumbs.len() {
                            r.text
                        } else {
                            r.text_subtle
                        })
                        .child(crumb.name.clone())
                        .on_click(
                            cx.listener(move |this, _, _, cx| this.open_directory(id.clone(), cx)),
                        )
                        .into_any_element(),
                );
            }
            rows.push(
                div()
                    .id("knowledge-path")
                    .role(Role::Navigation)
                    .px(px(12.))
                    .h(px(30.))
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .text_size(px(t.metrics.small + 0.5))
                    .children(crumbs)
                    .into_any_element(),
            );
        }
        let mut index = 0usize;
        match &files {
            None => rows.push(
                div()
                    .px(px(12.))
                    .py(px(10.))
                    .text_color(r.text_subtle)
                    .child(
                        self.files_failure
                            .clone()
                            .unwrap_or_else(|| l.desktop_loading()),
                    )
                    .into_any_element(),
            ),
            Some(files) => {
                for dir in &files.directories {
                    let open_id = dir.id.clone();
                    let menu_dir = dir.clone();
                    rows.push(
                        self.table_row(
                            index,
                            IconName::Folder,
                            dir.name.clone(),
                            String::new(),
                            None,
                            &dir.id,
                            window,
                            cx,
                        )
                        .cursor_pointer()
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.open_directory(open_id.clone(), cx)
                        }))
                        .on_mouse_down(
                            MouseButton::Right,
                            cx.listener(move |this, ev: &MouseDownEvent, window, cx| {
                                cx.stop_propagation();
                                this.directory_menu(&menu_dir, ev.position, window, cx)
                            }),
                        )
                        .into_any_element(),
                    );
                    index += 1;
                }
                for file in &files.files {
                    let size = file.size.map(size_text).unwrap_or_default();
                    let menu_file = file.clone();
                    let status = match file.status.as_deref() {
                        Some("failed") => {
                            Some((l.desktop_workspace_knowledge_status_failed(), true))
                        }
                        Some("processing" | "pending") => {
                            Some((l.desktop_workspace_knowledge_status_pending(), false))
                        }
                        _ => None,
                    };
                    let mut row = self.table_row(
                        index,
                        IconName::FileText,
                        file.filename.clone(),
                        size,
                        status,
                        &file.id,
                        window,
                        cx,
                    );
                    if writable {
                        row = row.on_mouse_down(
                            MouseButton::Right,
                            cx.listener(move |this, ev: &MouseDownEvent, window, cx| {
                                cx.stop_propagation();
                                this.file_menu(&menu_file, ev.position, window, cx)
                            }),
                        );
                    }
                    rows.push(row.into_any_element());
                    index += 1;
                }
                for file in &files.pending {
                    let failed = file.status.as_deref() == Some("failed");
                    rows.push(
                        self.table_row(
                            index,
                            IconName::FileText,
                            file.filename.clone(),
                            String::new(),
                            Some((
                                if failed {
                                    file.error
                                        .clone()
                                        .filter(|e| !e.trim().is_empty())
                                        .unwrap_or_else(|| {
                                            l.desktop_workspace_knowledge_status_failed()
                                        })
                                } else {
                                    l.desktop_workspace_knowledge_status_pending()
                                },
                                failed,
                            )),
                            &file.id,
                            window,
                            cx,
                        )
                        .into_any_element(),
                    );
                    index += 1;
                }
                if index == 0 {
                    rows.push(
                        div()
                            .id("knowledge-empty")
                            .px(px(12.))
                            .py(px(14.))
                            .text_color(r.text_subtle)
                            .child(if writable {
                                l.desktop_workspace_drop_files()
                            } else {
                                l.desktop_workspace_knowledge_files_empty()
                            })
                            .into_any_element(),
                    );
                }
            }
        }
        let busy = self.busy.clone();
        let failure = self.files_failure.clone().filter(|_| files.is_some());
        let has_failed = files.as_ref().is_some_and(|f| {
            f.pending
                .iter()
                .any(|p| p.status.as_deref() == Some("failed"))
        });
        let mut actions: Vec<AnyElement> = vec![];
        if writable {
            actions.push(
                Button::new("knowledge-upload", l.desktop_workspace_upload_files())
                    .icon(IconName::Upload)
                    .disabled(busy.is_some())
                    .on_click(Rc::new(cx.listener(|this, _, _, cx| this.pick_files(cx))))
                    .into_any_element(),
            );
            actions.push(
                Button::new(
                    "knowledge-attach-server-file",
                    l.desktop_workspace_attach_server_file(),
                )
                .ghost()
                .disabled(busy.is_some())
                .on_click(Rc::new(cx.listener(|this, _, window, cx| {
                    this.attach_server_file_sheet(window, cx)
                })))
                .into_any_element(),
            );
            actions.push(
                Button::new("knowledge-add-text", l.desktop_workspace_add_text_file())
                    .ghost()
                    .disabled(busy.is_some())
                    .on_click(Rc::new(
                        cx.listener(|this, _, window, cx| this.add_text(window, cx)),
                    ))
                    .into_any_element(),
            );
            actions.push(
                Button::new("knowledge-new-folder", l.desktop_workspace_new_folder())
                    .ghost()
                    .disabled(busy.is_some())
                    .on_click(Rc::new(
                        cx.listener(|this, _, window, cx| this.new_folder(window, cx)),
                    ))
                    .into_any_element(),
            );
        }
        actions.push(div().flex_1().into_any_element());
        if writable && has_failed {
            actions.push(
                Button::new("knowledge-cleanup", l.desktop_workspace_cleanup_failed())
                    .ghost()
                    .on_click(Rc::new(cx.listener(|this, _, _, cx| this.cleanup(cx))))
                    .into_any_element(),
            );
        }
        actions.push(
            Button::new(
                "knowledge-refresh",
                l.desktop_workspace_knowledge_refresh_files(),
            )
            .ghost()
            .icon(IconName::RefreshCw)
            .on_click(Rc::new(cx.listener(|this, _, _, cx| {
                let dir = this.directory.clone();
                this.open_directory(dir, cx)
            })))
            .into_any_element(),
        );
        let hover = with_alpha(r.focus, 0.12);
        let table = div()
            .id("knowledge-files")
            .role(Role::Table)
            .aria_label(SharedString::from(
                l.desktop_workspace_knowledge_files_title(),
            ))
            .rounded(px(10.))
            .when(writable, |d| {
                d.drag_over::<ExternalPaths>(move |style, _, _, _| style.bg(hover))
                    .on_drop(cx.listener(|this, paths: &ExternalPaths, _, cx| {
                        this.upload_paths(paths.paths().to_vec(), cx)
                    }))
            })
            .child(grouped_section(None, rows, None, cx));
        div()
            .flex()
            .flex_col()
            .gap(px(8.))
            .child(editor::group_heading(
                l.desktop_workspace_knowledge_files_title(),
                cx,
            ))
            .child(div().flex().items_center().gap(px(8.)).children(actions))
            .when_some(busy, |d, busy| {
                d.child(
                    div()
                        .id("knowledge-busy")
                        .role(Role::Status)
                        .px(px(12.))
                        .text_size(px(t.metrics.small))
                        .text_color(r.text_subtle)
                        .child(busy),
                )
            })
            .child(table)
            .when_some(failure, |d, f| {
                d.child(forms::form_error("knowledge-files-failure", f, cx))
            })
            .into_any_element()
    }
}

/// A call the name sheets make.
pub enum WorkspaceRequest {
    File(WorkspaceFileAction),
    Directory(WorkspaceDirectoryAction),
}

impl WorkspaceRequest {
    fn send(
        self,
        rpc: &Rpc,
    ) -> std::pin::Pin<
        Box<dyn std::future::Future<Output = Result<WorkspaceFiles, conduit_daemon::RpcError>>>,
    > {
        match self {
            Self::File(a) => Box::pin(rpc.call::<methods::WorkspaceFileAction>(&a)),
            Self::Directory(a) => Box::pin(rpc.call::<methods::WorkspaceDirectoryAction>(&a)),
        }
    }
}

impl KnowledgeEditor {
    /// Types `value` into field `field` (`name`, `description`,
    /// `max_files`, `max_size`): the E2E pass.
    pub fn set_field(
        &mut self,
        field: &str,
        value: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let value = value.to_string();
        match field {
            "name" => self.name.update(cx, |s, cx| s.set_value(value, window, cx)),
            "description" => self
                .description
                .update(cx, |s, cx| s.set_value(value, window, cx)),
            "max_files" => self
                .max_files
                .update(cx, |s, cx| s.set_value(value, window, cx)),
            "max_size" => self
                .max_size
                .update(cx, |s, cx| s.set_value(value, window, cx)),
            _ => {}
        }
        cx.notify();
    }

    /// New Folder… and Add Text File…, for the E2E pass.
    pub fn new_folder_sheet(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.new_folder(window, cx);
    }

    pub fn add_text_sheet(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.add_text(window, cx);
    }
}

impl ItemEditor for KnowledgeEditor {
    fn item_id(&self) -> Option<String> {
        self.id.clone()
    }

    fn is_dirty(&self, cx: &App) -> bool {
        self.detail.is_some() && self.form(cx) != self.initial
    }

    fn reload(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.id.clone() else {
            return;
        };
        self.loading = self.detail.is_none();
        let call = self.rpc.call::<methods::WorkspaceGet>(&WorkspaceRef {
            kind: WorkspaceKind::Knowledge,
            id,
        });
        let handle = window.window_handle();
        self._load = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = handle.update(cx, |_, window, cx| {
                    let _ = this.update(cx, |s, cx| {
                        s.loading = false;
                        match result {
                            Ok(detail) => s.adopt(detail, window, cx),
                            Err(e) => {
                                log::warn!("workspace.get knowledge: {e}");
                                s.failure = Some(editor::failure_text(&e, &cx.l10n().clone()));
                            }
                        }
                        cx.notify();
                    });
                });
            }),
        );
        let dir = self.directory.clone();
        self.open_directory(dir, cx);
    }

    fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.saving || !self.writable() {
            return;
        }
        self.submitted = true;
        let form = self.form(cx);
        let sent = form.clone();
        let l = cx.l10n().clone();
        let (Some(max_files), Some(max_size)) =
            (parse_limit(&form.max_files), parse_limit(&form.max_size))
        else {
            self.failure = Some(l.workspace_knowledge_limit_invalid());
            cx.notify();
            return;
        };
        if form.name.is_empty() {
            cx.notify();
            return;
        }
        let Some(mut dto) = self.dto().cloned() else {
            return;
        };
        dto.name = form.name;
        dto.description = form.description;
        dto.max_file_count = max_files;
        dto.max_file_size = max_size;
        let mut detail = self.detail.clone().expect("loaded");
        detail.knowledge = Some(dto);
        self.saving = true;
        self.failure = None;
        cx.notify();
        let call = self.rpc.call::<methods::WorkspaceSave>(&WorkspaceSave {
            detail,
            create: false,
            metadata_only: false,
        });
        let handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.saving = false;
                    let l = cx.l10n().clone();
                    match result {
                        Ok(detail) => {
                            let id = editor::detail_id(&detail).unwrap_or_default();
                            // Typed on while it saved: that stays, still to
                            // save, in this editor.
                            let kept = s.form(cx) != sent;
                            if kept {
                                s.saved_under_edits(detail, sent);
                            } else {
                                s.adopt(detail, window, cx);
                            }
                            s.stores.toasts.update(cx, |t, cx| {
                                t.show(
                                    NoticeLevel::Success,
                                    l.desktop_workspace_knowledge_saved(),
                                    cx,
                                )
                            });
                            cx.emit(EditorEvent::Saved(id));
                        }
                        Err(e) => {
                            log::warn!("workspace.save knowledge: {e}");
                            s.failure = Some(editor::failure_text(&e, &l));
                        }
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }

    fn on_choice(&mut self, action: &SettingsChoice, window: &mut Window, cx: &mut Context<Self>) {
        let Some((op, id)) = action.value.split_once('|') else {
            return;
        };
        let (op, id) = (op.to_string(), id.to_string());
        match action.menu.as_str() {
            "knowledge-file" => self.file_command(&op, &id, window, cx),
            "knowledge-dir" => self.directory_command(&op, &id, window, cx),
            _ => {}
        }
    }
}

impl Render for KnowledgeEditor {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l = cx.l10n().clone();
        let writable = self.writable();
        let form = self.form(cx);
        let name_error = (self.submitted && form.name.is_empty())
            .then(|| SharedString::from(l.desktop_workspace_knowledge_name_required()));
        let mut body: Vec<AnyElement> = vec![];
        if self.external() {
            body.push(
                forms::group_footer(l.desktop_workspace_knowledge_external_read_only(), cx)
                    .into_any_element(),
            );
        }
        body.push(
            forms::form_group(
                vec![
                    forms::field(
                        l.desktop_workspace_knowledge_name(),
                        &self.name,
                        None,
                        name_error,
                        window,
                        cx,
                    )
                    .into_any_element(),
                    forms::field(
                        l.desktop_workspace_knowledge_description(),
                        &self.description,
                        None,
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                ],
                cx,
            )
            .into_any_element(),
        );
        if !self.external() {
            body.push(
                grouped_section(
                    Some(l.workspace_knowledge_limits_title().into()),
                    vec![
                        forms::field(
                            l.workspace_knowledge_max_file_count(),
                            &self.max_files,
                            None,
                            None,
                            window,
                            cx,
                        )
                        .into_any_element(),
                        forms::field(
                            l.workspace_knowledge_max_file_size(),
                            &self.max_size,
                            None,
                            None,
                            window,
                            cx,
                        )
                        .into_any_element(),
                    ],
                    Some(l.workspace_knowledge_limits_footer().into()),
                    cx,
                )
                .into_any_element(),
            );
        }
        if self.detail.is_some() {
            body.push(self.files_section(&l, window, cx));
            if writable {
                body.push(
                    div()
                        .flex()
                        .justify_end()
                        .child(
                            Button::new("knowledge-reset", l.desktop_workspace_reset_ellipsis())
                                .danger()
                                .on_click(Rc::new(
                                    cx.listener(|this, _, window, cx| this.reset(window, cx)),
                                ))
                                .into_any_element(),
                        )
                        .into_any_element(),
                );
            }
        }
        let item = self
            .detail
            .as_ref()
            .and_then(|d| editor::listed_item(&self.pane, WorkspaceSection::Knowledge, d, cx));
        let title = self
            .dto()
            .map(|k| k.name.clone())
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| l.desktop_workspace_knowledge());
        let subtitle = self
            .detail
            .as_ref()
            .and_then(|d| editor::subtitle(d.owner_name.as_deref(), d.write_access, &l));
        let dirty = self.is_dirty(cx);
        let _ = FontWeight::NORMAL;
        editor::frame(
            "knowledge-editor",
            Frame {
                section: WorkspaceSection::Knowledge,
                title,
                subtitle,
                item,
                dirty,
                saving: self.saving,
                can_save: !form.name.is_empty(),
                read_only: !writable,
                creating: false,
                loading: self.loading,
                failure: self.failure.clone(),
                scroll: None,
            },
            self.pane.clone(),
            body,
            Rc::new(|v: &mut Self, window, cx| v.revert(window, cx)),
            Rc::new(|v: &mut Self, window, cx| v.save(window, cx)),
            cx,
        )
    }
}

/// Attach Server File…'s sheet: the user's files on the server, to pick
/// one (the composer's Server Files picker), with Cancel.
pub struct ServerFileSheet {
    pub picker: Entity<ServerFilesPicker>,
    editor: WeakEntity<KnowledgeEditor>,
    _subscription: Subscription,
    /// Another account signs in: the sheet, and the last account's files
    /// listed in it, go.
    _account: Subscription,
}

impl ServerFileSheet {
    fn new(
        stores: &Stores,
        rpc: Rpc,
        editor: WeakEntity<KnowledgeEditor>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let picker = cx.new(|cx| ServerFilesPicker::new(rpc, window, cx));
        let subscription = cx.subscribe_in(&picker, window, |this, _, e, window, cx| match e {
            ServerFilesEvent::Picked(file) => this.pick(file.clone(), cx),
            ServerFilesEvent::Dismissed => this.cancel(window, cx),
        });
        Self {
            picker,
            editor,
            _subscription: subscription,
            _account: sheet::close_with_account(stores, cx),
        }
    }

    /// Attaches `file` to the knowledge base and closes the sheet.
    pub fn pick(&mut self, file: ServerFile, cx: &mut Context<Self>) {
        let _ = self
            .editor
            .update(cx, |e, cx| e.attach_server_file(file, cx));
        sheet::dismiss(cx);
    }
}

impl SheetBody for ServerFileSheet {
    fn cancel(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        sheet::dismiss(cx);
    }

    fn label(&self, cx: &App) -> SharedString {
        cx.l10n().composer_attach_server_files().into()
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l = cx.l10n().clone();
        let cancel = cx.entity().downgrade();
        Some(
            forms::form_buttons(vec![
                Button::new("server-file-cancel", l.cancel())
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = cancel.update(cx, |v, cx| v.cancel(window, cx));
                    }))
                    .into_any_element(),
            ])
            .into_any_element(),
        )
    }
}

impl Render for ServerFileSheet {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        div()
            .id("knowledge-server-file-sheet")
            .w_full()
            .flex()
            .flex_col()
            .gap(px(14.))
            .child(
                div()
                    .id("sheet-title")
                    .role(Role::Heading)
                    .text_size(px(t.metrics.body + 2.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(l.composer_attach_server_files()),
            )
            .child(self.picker.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A batch of files begun under one account: once another signs in,
    /// no further file goes up and nothing is attached.
    #[gpui_kit::test]
    fn an_upload_stops_when_the_account_changes(cx: &mut gpui_kit::TestAppContext) {
        use std::sync::Mutex;

        use crate::views::sheet::bench::{bench, switch_account};
        use crate::views::workspace::editor::bench as editor_bench;
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::WorkspaceGet>(editor_bench::detail(
            WorkspaceKind::Knowledge,
            serde_json::json!({"id": "k1", "name": "Trail notes", "description": "",
                               "fileCount": 0, "external": false}),
        ));
        let dir = std::env::temp_dir().join(format!("conduit-kb-upload-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let files = ["ridge.pdf", "pass.pdf"].map(|name| {
            let path = dir.join(name);
            std::fs::write(&path, b"%PDF-1.4 synthetic").unwrap();
            path
        });
        // The first file's upload is held until the test lets it finish.
        let sent: Arc<Mutex<Vec<String>>> = Arc::default();
        let (finish, held) = futures::channel::oneshot::channel::<()>();
        let held = Arc::new(Mutex::new(Some(held)));
        let upload: FileUpload = {
            let sent = sent.clone();
            Arc::new(move |name: String, _path: PathBuf| {
                sent.lock().unwrap().push(name.clone());
                let held = held.lock().unwrap().take();
                Box::pin(async move {
                    if let Some(held) = held {
                        let _ = held.await;
                    }
                    Ok(serde_json::json!({"id": format!("file-{name}")}))
                })
            })
        };
        let editor = vcx.update(|window, cx| {
            cx.new(|cx| {
                KnowledgeEditor::new(
                    stores.clone(),
                    WeakEntity::new_invalid(),
                    Some("k1".into()),
                    editor_bench::manage(),
                    window,
                    cx,
                )
            })
        });
        vcx.run_until_parked();
        editor.update(vcx, |e, cx| {
            e.upload = Some(upload);
            e.upload_paths(files.to_vec(), cx);
        });
        vcx.run_until_parked();
        assert_eq!(*sent.lock().unwrap(), ["ridge.pdf"]);
        // Another account signs in while the first file goes up.
        switch_account(&stores, vcx);
        let _ = finish.send(());
        vcx.run_until_parked();
        assert_eq!(
            *sent.lock().unwrap(),
            ["ridge.pdf"],
            "Avery's next file went to Blake's server"
        );
        assert!(
            daemon.calls::<methods::WorkspaceAttachFiles>().is_empty(),
            "files were attached after the account changed"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Attach Server File's sheet, opened for one account, closes when
    /// another signs in: none of the last account's files is linked under
    /// the next.
    #[gpui_kit::test]
    fn the_server_file_sheet_closes_on_another_account(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::sheet::bench::switch_account;
        use crate::views::workspace::editor::bench;
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        daemon.returns::<methods::WorkspaceGet>(bench::detail(
            WorkspaceKind::Knowledge,
            serde_json::json!({"id": "k1", "name": "Trail notes", "description": "",
                               "fileCount": 0, "external": false}),
        ));
        daemon.returns::<methods::WorkspaceFiles>(
            serde_json::from_value(serde_json::json!({
                "knowledgeId": "k1", "directoryId": "", "breadcrumbs": [],
                "directories": [], "files": [], "pending": [], "total": 0, "hasMore": false
            }))
            .unwrap(),
        );
        let editor = vcx.update(|window, cx| {
            cx.new(|cx| {
                KnowledgeEditor::new(
                    stores.clone(),
                    WeakEntity::new_invalid(),
                    Some("k1".into()),
                    bench::manage(),
                    window,
                    cx,
                )
            })
        });
        vcx.run_until_parked();
        vcx.update(|window, cx| editor.update(cx, |e, cx| e.attach_server_file_sheet(window, cx)));
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<ServerFileSheet>(cx))
                .is_some(),
            "Attach Server File opens its sheet"
        );
        switch_account(&stores, vcx);
        assert!(
            vcx.update(|_, cx| sheet::current::<ServerFileSheet>(cx))
                .is_none(),
            "Avery's server files stayed open over Blake's account"
        );
        assert!(daemon.calls::<methods::WorkspaceAttachFiles>().is_empty());
    }

    /// Delete File, Remove and a folder's Delete go only once confirmed:
    /// Cancel leaves the file and the folder where they are.
    #[gpui_kit::test]
    fn a_cancelled_delete_sends_nothing(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::workspace::editor::bench;
        // The bench answers questions "no": Cancel.
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        daemon.returns::<methods::WorkspaceGet>(bench::detail(
            WorkspaceKind::Knowledge,
            serde_json::json!({"id": "k1", "name": "Trail notes", "description": "",
                               "fileCount": 1, "external": false}),
        ));
        daemon.returns::<methods::WorkspaceFiles>(
            serde_json::from_value(serde_json::json!({
                "knowledgeId": "k1", "directoryId": "", "breadcrumbs": [],
                "directories": [{"id": "d1", "name": "Maps"}],
                "files": [{"id": "f1", "filename": "ridge.pdf"}],
                "pending": [], "total": 1, "hasMore": false
            }))
            .unwrap(),
        );
        let editor = vcx.update(|window, cx| {
            cx.new(|cx| {
                KnowledgeEditor::new(
                    stores.clone(),
                    WeakEntity::new_invalid(),
                    Some("k1".into()),
                    bench::manage(),
                    window,
                    cx,
                )
            })
        });
        vcx.run_until_parked();
        assert!(editor.read_with(vcx, |e, _| e.file("f1").is_some()));
        for op in ["delete", "remove"] {
            vcx.update(|window, cx| {
                editor.update(cx, |e, cx| e.file_command(op, "f1", window, cx))
            });
            vcx.run_until_parked();
        }
        vcx.update(|window, cx| {
            editor.update(cx, |e, cx| e.directory_command("delete", "d1", window, cx))
        });
        vcx.run_until_parked();
        assert!(
            daemon.calls::<methods::WorkspaceFileAction>().is_empty(),
            "a file went before the question was answered"
        );
        assert!(
            daemon
                .calls::<methods::WorkspaceDirectoryAction>()
                .is_empty()
        );
    }

    /// Text typed while a save is out is kept, still to save.
    #[gpui_kit::test]
    fn text_typed_while_a_knowledge_base_saves_stays(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::workspace::editor::bench;
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        let item = |description: &str| {
            bench::detail(
                WorkspaceKind::Knowledge,
                serde_json::json!({"id": "k1", "name": "Trail notes", "description": description, "fileCount": 0, "external": false}),
            )
        };
        daemon.returns::<methods::WorkspaceGet>(item("Notes on trails"));
        daemon.returns::<methods::WorkspaceSave>(item("Notes on day trails"));
        let editor = vcx.update(|window, cx| {
            cx.new(|cx| {
                KnowledgeEditor::new(
                    stores.clone(),
                    WeakEntity::new_invalid(),
                    Some("k1".into()),
                    bench::manage(),
                    window,
                    cx,
                )
            })
        });
        vcx.run_until_parked();
        let set = |text: &str, vcx: &mut gpui_kit::VisualTestContext| {
            vcx.update(|window, cx| {
                editor.update(cx, |e, cx| e.set_field("description", text, window, cx))
            })
        };
        set("Notes on day trails", vcx);
        let held = daemon.hold::<methods::WorkspaceSave>();
        vcx.update(|window, cx| editor.update(cx, |e, cx| e.save(window, cx)));
        vcx.run_until_parked();
        set("Notes on day trails nearby", vcx);
        drop(held);
        vcx.run_until_parked();
        editor.read_with(vcx, |e, cx| {
            assert_eq!(
                e.description.read(cx).value().to_string(),
                "Notes on day trails nearby",
                "the save's answer replaced what was typed since"
            );
            assert!(e.is_dirty(cx), "the later words count as saved");
        });
        assert_eq!(daemon.calls::<methods::WorkspaceSave>().len(), 1);
    }

    #[test]
    fn sizes_read_as_finder_writes_them() {
        assert_eq!(size_text(512), "512 bytes");
        assert_eq!(size_text(12_400), "12 KB");
        assert_eq!(size_text(3_400_000), "3.4 MB");
    }

    #[test]
    fn limits_are_empty_or_whole_numbers_above_zero() {
        assert_eq!(parse_limit(""), Some(None));
        assert_eq!(parse_limit(" 20 "), Some(Some(20)));
        assert_eq!(parse_limit("0"), None);
        assert_eq!(parse_limit("2.5"), None);
        assert_eq!(parse_limit("lots"), None);
    }
}
