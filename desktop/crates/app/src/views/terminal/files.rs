//! A terminal's files, as mobile's Files panel: a folder at a time, with
//! its path as breadcrumbs, Home and Enclosing Folder, Upload (and files
//! dropped from Finder), Download, Rename, Delete and New Folder, and a
//! file shown in the viewer or Quick Look.
//!
//! Finder's keys: ↑↓ move, ⌘↓ (or a double click) opens, ⌘↑ goes up, Return
//! renames, ⌘⌫ deletes, Space shows the file. Rename and New Folder edit the
//! name in place; Delete asks first, in a sheet.

use std::path::PathBuf;
use std::rc::Rc;

use base64::Engine as _;
use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::with_alpha;
use conduit_components::views::kit::{IconButton, bare_input};
use conduit_protocol::{TerminalEntry, TerminalFileAction, TerminalFileOp, TerminalPath, methods};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::prelude::*;
use gpui_kit::{
    Action, AnyElement, App, ClickEvent, Context, Entity, ExternalPaths, FocusHandle, Focusable,
    FontWeight, MouseButton, PathPromptOptions, Role, SharedString, Subscription, Task,
    UniformListScrollHandle, Window, div, px, uniform_list,
};

use crate::l10n::ActiveL10n as _;
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;

/// A file row's menu command.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileCommand {
    Open,
    Download,
    Rename,
    Delete,
}

/// A file row's context menu action: `command` on `path`.
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit_terminal_files, no_json)]
pub struct FileMenu {
    pub path: String,
    pub command: FileCommand,
}

/// The folder's own menu (a right click between rows).
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit_terminal_files, no_json)]
pub enum FolderMenu {
    Upload,
    NewFolder,
    Refresh,
}

/// `dir` with exactly one trailing slash.
pub fn as_dir(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    format!("{trimmed}/")
}

/// The folder holding `path` (a file or a folder); `/` holds itself.
pub fn parent_of(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    match trimmed.rfind('/') {
        Some(0) | None => "/".into(),
        Some(i) => format!("{}/", &trimmed[..i]),
    }
}

/// The breadcrumbs of `dir`: each folder's name and path, from `/`.
pub fn crumbs(dir: &str) -> Vec<(String, String)> {
    let mut out = vec![("/".to_string(), "/".to_string())];
    let mut path = String::from("/");
    for part in dir.split('/').filter(|p| !p.is_empty()) {
        path.push_str(part);
        path.push('/');
        out.push((part.to_string(), path.clone()));
    }
    out
}

/// Whether `name` can name an entry: not empty, no slash, not `.`/`..`.
pub fn valid_name(name: &str) -> bool {
    let name = name.trim();
    !name.is_empty() && !name.contains('/') && name != "." && name != ".."
}

/// A size as Finder writes it (decimal units).
pub fn human_size(bytes: i64) -> String {
    let b = bytes.max(0) as f64;
    if b < 1000. {
        return format!("{bytes} bytes");
    }
    let units = ["KB", "MB", "GB", "TB"];
    let mut v = b / 1000.;
    let mut unit = 0;
    while v >= 1000. && unit < units.len() - 1 {
        v /= 1000.;
        unit += 1;
    }
    if v < 10. {
        format!("{v:.1} {}", units[unit])
    } else {
        format!("{v:.0} {}", units[unit])
    }
}

/// The name being edited: an entry's (Rename) or a new folder's.
struct Editing {
    /// The entry renamed; None for a new folder.
    path: Option<String>,
    input: Entity<InputState>,
}

pub struct FilesView {
    stores: Stores,
    handle: Option<String>,
    /// Where the shell started: Home.
    home: String,
    path: String,
    entries: Vec<TerminalEntry>,
    loading: bool,
    failed: bool,
    selected: Option<String>,
    editing: Option<Editing>,
    busy: bool,
    focus: FocusHandle,
    scroll: UniformListScrollHandle,
    generation: u64,
    _tasks: Vec<Task<()>>,
    _subscriptions: Vec<Subscription>,
}

impl Focusable for FilesView {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl FilesView {
    pub fn new(stores: Stores, _window: &mut Window, cx: &mut Context<Self>) -> Self {
        Self {
            stores,
            handle: None,
            home: "/".into(),
            path: "/".into(),
            entries: vec![],
            loading: false,
            failed: false,
            selected: None,
            editing: None,
            busy: false,
            focus: cx.focus_handle(),
            scroll: UniformListScrollHandle::new(),
            generation: 0,
            _tasks: vec![],
            _subscriptions: vec![],
        }
    }

    pub fn path(&self) -> &str {
        &self.path
    }

    pub fn entries(&self) -> &[TerminalEntry] {
        &self.entries
    }

    pub fn selected(&self) -> Option<&str> {
        self.selected.as_deref()
    }

    pub fn is_loading(&self) -> bool {
        self.loading
    }

    pub fn focus(&self, window: &mut Window, cx: &mut App) {
        window.focus(&self.focus, cx);
    }

    /// Starts on `cwd` of the terminal `handle` names.
    pub fn open(&mut self, handle: String, cwd: String, cx: &mut Context<Self>) {
        self.handle = Some(handle);
        self.home = as_dir(&cwd);
        self.navigate(self.home.clone(), cx);
    }

    pub fn navigate(&mut self, path: String, cx: &mut Context<Self>) {
        self.path = as_dir(&path);
        self.selected = None;
        self.editing = None;
        self.entries.clear();
        self.load(cx);
        // The live watch follows the folder shown.
        if let Some(handle) = self.handle.clone() {
            let rpc = self.stores.connection.read(cx).rpc();
            let watch = rpc.call::<methods::TerminalWatch>(&conduit_protocol::TerminalWatch {
                handle,
                path: self.path.clone(),
            });
            self._tasks.push(cx.spawn(async move |_, _| {
                let _ = watch.await;
            }));
        }
    }

    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        self.load(cx);
    }

    fn load(&mut self, cx: &mut Context<Self>) {
        let Some(handle) = self.handle.clone() else {
            return;
        };
        self.generation += 1;
        let generation = self.generation;
        self.loading = true;
        cx.notify();
        let rpc = self.stores.connection.read(cx).rpc();
        let call = rpc.call::<methods::TerminalList>(&TerminalPath {
            handle,
            path: self.path.clone(),
        });
        self._tasks.push(cx.spawn(async move |this, cx| {
            let result = call.await;
            this.update(cx, |f, cx| {
                if f.generation != generation {
                    return;
                }
                f.loading = false;
                match result {
                    Ok(listing) => {
                        f.failed = false;
                        f.entries = listing.entries;
                        if f.selected
                            .as_ref()
                            .is_some_and(|s| !f.entries.iter().any(|e| &e.path == s))
                        {
                            f.selected = None;
                        }
                    }
                    Err(e) => {
                        log::warn!("terminal.list: {e}");
                        f.failed = true;
                        let text = cx.l10n().terminal_failed_to_load_files();
                        f.toast(text, cx);
                    }
                }
                cx.notify();
            })
            .ok();
        }));
    }

    fn toast(&self, text: String, cx: &mut Context<Self>) {
        self.stores.toasts.update(cx, |t, cx| {
            t.show(conduit_protocol::NoticeLevel::Error, text, cx)
        });
    }

    fn entry(&self, path: &str) -> Option<&TerminalEntry> {
        self.entries.iter().find(|e| e.path == path)
    }

    // ── Commands ────────────────────────────────────────────────────────

    /// Opens `path`: a folder shows its files, a file the viewer.
    pub fn open_entry(&mut self, path: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(entry) = self.entry(path).cloned() else {
            return;
        };
        if entry.directory {
            self.navigate(entry.path, cx);
        } else {
            self.show(&entry.path, window, cx);
        }
    }

    /// Shows `path` in the viewer (text, images) or Quick Look.
    pub fn show(&mut self, path: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(handle) = self.handle.clone() else {
            return;
        };
        super::viewer::show(
            self.stores.clone(),
            handle,
            path.to_string(),
            None,
            window,
            cx,
        );
    }

    /// Download…: the file's bytes, where the save panel says.
    pub fn download(&mut self, path: &str, cx: &mut Context<Self>) {
        let Some(handle) = self.handle.clone() else {
            return;
        };
        download(self.stores.clone(), handle, path.to_string(), cx);
    }

    /// Upload…: files from the system's picker into this folder.
    pub fn pick_upload(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let picked = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: true,
            prompt: None,
        });
        cx.spawn_in(window, async move |this, cx| {
            let Ok(Ok(Some(paths))) = picked.await else {
                return;
            };
            this.update(cx, |f, cx| f.upload(paths, cx)).ok();
        })
        .detach();
    }

    /// Files dropped from Finder land in this folder.
    pub fn drop_paths(&mut self, paths: &ExternalPaths, cx: &mut Context<Self>) {
        let files: Vec<PathBuf> = paths
            .paths()
            .iter()
            .filter(|p| p.is_file())
            .cloned()
            .collect();
        self.upload(files, cx);
    }

    /// Uploads `paths` (files on this Mac) into the folder shown.
    pub fn upload(&mut self, paths: Vec<PathBuf>, cx: &mut Context<Self>) {
        let (Some(handle), Some(http)) = (
            self.handle.clone(),
            self.stores.connection.read(cx).http().cloned(),
        ) else {
            return;
        };
        if paths.is_empty() {
            return;
        }
        let dir = self.path.clone();
        self.busy = true;
        cx.notify();
        let reads = cx.background_executor().spawn(async move {
            paths
                .into_iter()
                .filter_map(|p| {
                    let name = p.file_name()?.to_string_lossy().to_string();
                    let bytes = std::fs::read(&p).ok()?;
                    Some((name, bytes))
                })
                .collect::<Vec<_>>()
        });
        self._tasks.push(cx.spawn(async move |this, cx| {
            let files = reads.await;
            let mut failed = files.is_empty();
            let mut last = None;
            for (name, bytes) in files {
                let sent = conduit_daemon::runtime::shared()
                    .spawn({
                        let http = http.clone();
                        let (handle, dir, name) = (handle.clone(), dir.clone(), name.clone());
                        async move {
                            http.terminal_upload(&handle, &dir, &name, bytes.into())
                                .await
                        }
                    })
                    .await;
                match sent {
                    Ok(Ok(())) => last = Some(format!("{dir}{name}")),
                    Ok(Err(e)) => {
                        log::warn!("terminal upload: {e}");
                        failed = true;
                    }
                    Err(e) => {
                        log::warn!("terminal upload: {e}");
                        failed = true;
                    }
                }
            }
            this.update(cx, |f, cx| {
                f.busy = false;
                if failed {
                    let text = cx.l10n().terminal_upload_failed();
                    f.toast(text, cx);
                }
                if last.is_some() {
                    f.selected = last;
                }
                f.refresh(cx);
            })
            .ok();
        }));
    }

    pub fn start_rename(&mut self, path: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(entry) = self.entry(path).cloned() else {
            return;
        };
        self.selected = Some(entry.path.clone());
        self.edit(Some(entry.path), entry.name, window, cx);
    }

    /// New Folder: a row named "New Folder" (numbered when that is taken),
    /// its name selected; Return makes it.
    pub fn start_new_folder(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.handle.is_none() {
            return;
        }
        let base = cx.l10n().new_folder();
        let taken = |n: &str| self.entries.iter().any(|e| e.name == n);
        let mut name = base.clone();
        let mut i = 2;
        while taken(&name) {
            name = format!("{base} {i}");
            i += 1;
        }
        self.edit(None, name, window, cx);
    }

    fn edit(
        &mut self,
        path: Option<String>,
        name: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let input = cx.new(|cx| InputState::new(window, cx).default_value(name));
        input.update(cx, |s, cx| {
            s.focus(window, cx);
            s.select_all(window, cx);
        });
        let sub = cx.subscribe_in(
            &input,
            window,
            |this, _, e: &InputEvent, window, cx| match e {
                InputEvent::PressEnter { .. } => this.commit_edit(window, cx),
                InputEvent::Blur => this.commit_edit(window, cx),
                _ => {}
            },
        );
        self._subscriptions = vec![sub];
        self.editing = Some(Editing { path, input });
        cx.notify();
    }

    pub fn cancel_edit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.editing.take().is_some() {
            self._subscriptions.clear();
            window.focus(&self.focus, cx);
            cx.notify();
        }
    }

    fn commit_edit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(editing) = self.editing.take() else {
            return;
        };
        self._subscriptions.clear();
        window.focus(&self.focus, cx);
        let name = editing.input.read(cx).value().trim().to_string();
        cx.notify();
        if !valid_name(&name) {
            return;
        }
        match editing.path {
            Some(path) => {
                let Some(entry) = self.entry(&path).cloned() else {
                    return;
                };
                if entry.name == name {
                    return;
                }
                let destination = format!("{}{}", self.path, name);
                self.selected = Some(if entry.directory {
                    as_dir(&destination)
                } else {
                    destination.clone()
                });
                self.file_action(
                    TerminalFileOp::Move,
                    entry.path.trim_end_matches('/').to_string(),
                    Some(destination),
                    cx.l10n().terminal_rename_failed(),
                    cx,
                );
            }
            None => {
                let path = format!("{}{}", self.path, name);
                self.selected = Some(as_dir(&path));
                self.file_action(
                    TerminalFileOp::Mkdir,
                    path,
                    None,
                    cx.l10n().terminal_folder_create_failed(),
                    cx,
                );
            }
        }
    }

    /// Delete…: asks in a sheet, then deletes.
    pub fn confirm_delete(&mut self, path: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(entry) = self.entry(path).cloned() else {
            return;
        };
        let l = cx.l10n().clone();
        let spec = SheetSpec::new(
            l.desktop_terminal_delete_title(&entry.name),
            l.desktop_terminal_delete_message(),
            l.delete(),
            l.cancel(),
        )
        .destructive();
        let answer = present_sheet(window, spec, cx);
        cx.spawn(async move |this, cx| {
            if !answer.await {
                return;
            }
            this.update(cx, |f, cx| {
                let failed = cx.l10n().terminal_delete_failed();
                f.file_action(
                    TerminalFileOp::Delete,
                    entry.path.trim_end_matches('/').to_string(),
                    None,
                    failed,
                    cx,
                );
            })
            .ok();
        })
        .detach();
    }

    fn file_action(
        &mut self,
        op: TerminalFileOp,
        path: String,
        destination: Option<String>,
        failed: String,
        cx: &mut Context<Self>,
    ) {
        let Some(handle) = self.handle.clone() else {
            return;
        };
        let rpc = self.stores.connection.read(cx).rpc();
        let call = rpc.call::<methods::TerminalFileAction>(&TerminalFileAction {
            handle,
            op,
            path,
            destination,
        });
        self.busy = true;
        cx.notify();
        self._tasks.push(cx.spawn(async move |this, cx| {
            let result = call.await;
            this.update(cx, |f, cx| {
                f.busy = false;
                if let Err(e) = result {
                    log::warn!("terminal.fileAction: {e}");
                    f.toast(failed, cx);
                }
                f.refresh(cx);
            })
            .ok();
        }));
    }

    fn run(&mut self, menu: &FileMenu, window: &mut Window, cx: &mut Context<Self>) {
        match menu.command {
            FileCommand::Open => self.open_entry(&menu.path, window, cx),
            FileCommand::Download => self.download(&menu.path, cx),
            FileCommand::Rename => self.start_rename(&menu.path, window, cx),
            FileCommand::Delete => self.confirm_delete(&menu.path, window, cx),
        }
    }

    fn row_menu(
        &mut self,
        path: String,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(entry) = self.entry(&path).cloned() else {
            return;
        };
        self.selected = Some(path.clone());
        window.focus(&self.focus, cx);
        let l = cx.l10n().clone();
        let item = |command| {
            Box::new(FileMenu {
                path: path.clone(),
                command,
            })
        };
        let ellipsis = |s: String| format!("{s}\u{2026}");
        let mut menu = NativeMenu::new().menu(l.desktop_terminal_open(), item(FileCommand::Open));
        if !entry.directory {
            menu = menu.menu(ellipsis(l.download()), item(FileCommand::Download));
        }
        menu = menu
            .separator()
            .menu(l.rename(), item(FileCommand::Rename))
            .separator()
            .menu(ellipsis(l.delete()), item(FileCommand::Delete));
        cx.notify();
        menu.show(position, window, cx);
    }

    fn folder_menu(
        &mut self,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.handle.is_none() {
            return;
        }
        let l = cx.l10n().clone();
        window.focus(&self.focus, cx);
        NativeMenu::new()
            .menu(
                format!("{}\u{2026}", l.terminal_upload_action()),
                Box::new(FolderMenu::Upload),
            )
            .menu(l.new_folder(), Box::new(FolderMenu::NewFolder))
            .separator()
            .menu(l.desktop_terminal_refresh(), Box::new(FolderMenu::Refresh))
            .show(position, window, cx);
    }

    fn move_selection(&mut self, by: isize, cx: &mut Context<Self>) {
        if self.entries.is_empty() {
            return;
        }
        let current = self
            .selected
            .as_ref()
            .and_then(|s| self.entries.iter().position(|e| &e.path == s));
        let next = match current {
            None if by > 0 => 0,
            None => self.entries.len() - 1,
            Some(i) => (i as isize + by).clamp(0, self.entries.len() as isize - 1) as usize,
        };
        self.selected = Some(self.entries[next].path.clone());
        self.scroll
            .scroll_to_item(next, gpui_kit::ScrollStrategy::Nearest);
        cx.notify();
    }

    fn key(&mut self, e: &gpui_kit::KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        if self.editing.is_some() {
            if e.keystroke.key == "escape" {
                self.cancel_edit(window, cx);
                cx.stop_propagation();
            }
            return;
        }
        let k = &e.keystroke;
        let m = k.modifiers;
        let selected = self.selected.clone();
        match (k.key.as_str(), m.platform) {
            ("down", false) => self.move_selection(1, cx),
            ("up", false) => self.move_selection(-1, cx),
            ("down", true) | ("o", true) => {
                if let Some(path) = selected {
                    self.open_entry(&path, window, cx);
                }
            }
            ("up", true) => {
                let parent = parent_of(&self.path);
                if parent != self.path {
                    self.navigate(parent, cx);
                }
            }
            ("enter", false) => {
                if let Some(path) = selected {
                    self.start_rename(&path, window, cx);
                }
            }
            ("backspace", true) => {
                if let Some(path) = selected {
                    self.confirm_delete(&path, window, cx);
                }
            }
            ("space", false) => {
                if let Some(path) = selected
                    && self.entry(&path).is_some_and(|e| !e.directory)
                {
                    self.show(&path, window, cx);
                }
            }
            _ => return,
        }
        cx.stop_propagation();
    }
}

/// Test hook: when set, Download… saves into this folder without asking
/// (the E2E pass; a save panel cannot be driven).
#[derive(Clone, Debug, Default)]
pub struct DownloadTo(pub Option<PathBuf>);

impl gpui_kit::Global for DownloadTo {}

/// Downloads `path` through `handle` and saves it where the save panel
/// says (Downloads at first).
pub fn download(stores: Stores, handle: String, path: String, cx: &mut App) {
    let rpc = stores.connection.read(cx).rpc();
    let call = rpc.call::<methods::TerminalDownload>(&TerminalPath {
        handle,
        path: path.clone(),
    });
    let fallback = path.rsplit('/').next().unwrap_or("download").to_string();
    cx.spawn(async move |cx| {
        let failed = |cx: &mut gpui_kit::AsyncApp| {
            cx.update(|cx| {
                let text = cx.l10n().terminal_download_failed();
                stores.toasts.update(cx, |t, cx| {
                    t.show(conduit_protocol::NoticeLevel::Error, text, cx)
                });
            })
        };
        let file = match call.await {
            Ok(file) => file,
            Err(e) => {
                log::warn!("terminal.download: {e}");
                failed(cx);
                return;
            }
        };
        let bytes = match file
            .base64
            .as_deref()
            .map(|b| base64::engine::general_purpose::STANDARD.decode(b))
        {
            Some(Ok(bytes)) => bytes,
            _ => file.text.unwrap_or_default().into_bytes(),
        };
        let name = crate::stores::files::safe_name(if file.name.is_empty() {
            &fallback
        } else {
            &file.name
        });
        let preset = cx.update(|cx| cx.try_global::<DownloadTo>().and_then(|d| d.0.clone()));
        let target = match preset {
            Some(dir) => dir.join(&name),
            None => {
                let downloads = std::env::var_os("HOME")
                    .map(|h| PathBuf::from(h).join("Downloads"))
                    .filter(|d| d.is_dir())
                    .unwrap_or_else(std::env::temp_dir);
                let asked = cx.update(|cx| cx.prompt_for_new_path(&downloads, Some(&name)));
                let Ok(Ok(Some(target))) = asked.await else {
                    return;
                };
                target
            }
        };
        if let Err(e) = std::fs::write(&target, bytes) {
            log::warn!("terminal download: {e}");
            failed(cx);
        }
    })
    .detach();
}

impl Render for FilesView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let l = cx.l10n().clone();
        let at_root = parent_of(&self.path) == self.path;
        let ready = self.handle.is_some();
        // The path bar: Home, Enclosing Folder, the crumbs; Upload, New
        // Folder, Refresh at the trailing edge.
        let mut crumbs_row = div()
            .id("terminal-crumbs")
            .role(Role::Navigation)
            .aria_label(SharedString::from(l.terminal_current_path_label()))
            .flex_1()
            .min_w_0()
            .flex()
            .items_center()
            .gap(px(2.))
            .overflow_x_hidden();
        let parts = crumbs(&self.path);
        let last = parts.len() - 1;
        for (i, (name, path)) in parts.into_iter().enumerate() {
            if i > 0 {
                crumbs_row = crumbs_row.child(icon(IconName::ChevronRight, 11., r.text_faint));
            }
            let current = i == last;
            let target = path.clone();
            crumbs_row = crumbs_row.child(
                div()
                    .id(SharedString::from(format!("terminal-crumb-{i}")))
                    .role(Role::Link)
                    .aria_label(SharedString::from(path.clone()))
                    .px(px(5.))
                    .h(px(22.))
                    .flex()
                    .items_center()
                    .rounded(px(5.))
                    .flex_none()
                    .font_family(conduit_components::theme::MONO_FONT)
                    .text_size(px(m.small))
                    .text_color(if current { r.text } else { r.text_subtle })
                    .when(current, |d| d.font_weight(FontWeight::SEMIBOLD))
                    .when(!current, |d| {
                        d.cursor_pointer()
                            .hover(|s| s.bg(r.hover).text_color(r.text))
                            .on_click(
                                cx.listener(move |f, _, _, cx| f.navigate(target.clone(), cx)),
                            )
                    })
                    .child(SharedString::from(name)),
            );
        }
        let this = cx.entity().downgrade();
        let act = move |f: fn(&mut FilesView, &mut Window, &mut Context<FilesView>)| {
            let this = this.clone();
            Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                this.update(cx, |v, cx| f(v, window, cx)).ok();
            })
        };
        let bar = div()
            .id("terminal-files-bar")
            .role(Role::Toolbar)
            .aria_label(SharedString::from(l.files()))
            .flex_none()
            .h(px(40.))
            .px(px(10.))
            .flex()
            .items_center()
            .gap(px(4.))
            .border_b_1()
            .border_color(r.divider)
            .child(
                IconButton::new("terminal-home", IconName::House, l.terminal_home_action())
                    .size(28., 15.)
                    .disabled(!ready)
                    .on_click(act(|f, _, cx| {
                        let home = f.home.clone();
                        f.navigate(home, cx)
                    })),
            )
            .child(
                IconButton::new(
                    "terminal-up",
                    IconName::ArrowUp,
                    l.desktop_terminal_enclosing_folder(),
                )
                .size(28., 15.)
                .disabled(!ready || at_root)
                .on_click(act(|f, _, cx| {
                    let parent = parent_of(&f.path);
                    f.navigate(parent, cx)
                })),
            )
            .child(crumbs_row)
            .child(
                IconButton::new(
                    "terminal-upload",
                    IconName::Upload,
                    format!("{}\u{2026}", l.terminal_upload_action()),
                )
                .size(28., 15.)
                .disabled(!ready || self.busy)
                .on_click(act(|f, window, cx| f.pick_upload(window, cx))),
            )
            .child(
                IconButton::new("terminal-new-folder", IconName::FolderPlus, l.new_folder())
                    .size(28., 15.)
                    .disabled(!ready || self.busy)
                    .on_click(act(|f, window, cx| f.start_new_folder(window, cx))),
            )
            .child(
                IconButton::new(
                    "terminal-refresh",
                    IconName::RotateCw,
                    l.desktop_terminal_refresh(),
                )
                .size(28., 15.)
                .disabled(!ready)
                .on_click(act(|f, _, cx| f.refresh(cx))),
            );

        // The rows: the new folder being named first, then the entries.
        let mut rows: Vec<RowData> = vec![];
        if let Some(Editing { path: None, input }) = &self.editing {
            rows.push(RowData::New(input.clone()));
        }
        for entry in &self.entries {
            let edit = match &self.editing {
                Some(Editing {
                    path: Some(p),
                    input,
                }) if *p == entry.path => Some(input.clone()),
                _ => None,
            };
            rows.push(RowData::Entry(entry.clone(), edit));
        }
        let count = rows.len();
        let selected = self.selected.clone();
        let focused = self.focus.contains_focused(window, cx);
        let weak = cx.entity().downgrade();
        let rows = Rc::new(rows);
        let list = uniform_list("terminal-files", count, {
            let rows = rows.clone();
            move |range, _window, cx| {
                range
                    .map(|i| file_row(&rows[i], i, selected.as_deref(), focused, &weak, cx))
                    .collect::<Vec<_>>()
            }
        })
        .track_scroll(&self.scroll)
        .flex_1()
        .min_h_0();
        let empty = if self.entries.is_empty() && self.editing.is_none() {
            let text = if !ready || (self.loading && self.entries.is_empty()) {
                Some(l.desktop_loading())
            } else if self.failed {
                Some(l.terminal_failed_to_load_files())
            } else {
                Some(l.terminal_no_files())
            };
            text.map(|text| {
                div()
                    .id("terminal-files-empty")
                    .role(Role::Status)
                    .aria_label(SharedString::from(text.clone()))
                    .absolute()
                    .inset_0()
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_size(px(m.control))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(text))
            })
        } else {
            None
        };
        div()
            .id("terminal-files")
            .role(Role::Group)
            .aria_label(SharedString::from(l.files()))
            .key_context("TerminalFiles")
            .track_focus(&self.focus)
            .on_key_down(cx.listener(|f, e, window, cx| f.key(e, window, cx)))
            .on_action(cx.listener(|f, a: &FileMenu, window, cx| f.run(a, window, cx)))
            .on_action(cx.listener(|f, a: &FolderMenu, window, cx| match a {
                FolderMenu::Upload => f.pick_upload(window, cx),
                FolderMenu::NewFolder => f.start_new_folder(window, cx),
                FolderMenu::Refresh => f.refresh(cx),
            }))
            .size_full()
            .flex()
            .flex_col()
            .bg(r.content)
            .child(bar)
            .child(
                div()
                    .id("terminal-files-body")
                    .role(Role::ListBox)
                    .aria_label(SharedString::from(l.files()))
                    .relative()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .flex_col()
                    .on_mouse_down(
                        MouseButton::Right,
                        cx.listener(|f, e: &gpui_kit::MouseDownEvent, window, cx| {
                            f.folder_menu(e.position, window, cx)
                        }),
                    )
                    .drag_over::<ExternalPaths>(move |style, _, _, _| {
                        style.bg(with_alpha(r.text, 0.04))
                    })
                    .on_drop(cx.listener(|f, paths: &ExternalPaths, _, cx| f.drop_paths(paths, cx)))
                    .child(list)
                    .children(empty),
            )
    }
}

enum RowData {
    New(Entity<InputState>),
    Entry(TerminalEntry, Option<Entity<InputState>>),
}

fn file_row(
    row: &RowData,
    index: usize,
    selected: Option<&str>,
    focused: bool,
    weak: &gpui_kit::WeakEntity<FilesView>,
    cx: &App,
) -> AnyElement {
    let t = cx.conduit().clone();
    let r = t.roles;
    let m = t.metrics;
    let l = cx.l10n().clone();
    let (entry, edit) = match row {
        RowData::New(input) => (None, Some(input.clone())),
        RowData::Entry(entry, edit) => (Some(entry.clone()), edit.clone()),
    };
    let directory = entry.as_ref().is_none_or(|e| e.directory);
    let is_selected = entry
        .as_ref()
        .is_some_and(|e| Some(e.path.as_str()) == selected);
    let name = entry.as_ref().map(|e| e.name.clone()).unwrap_or_default();
    let detail = entry
        .as_ref()
        .filter(|e| !e.directory)
        .map(|e| {
            let size = e.size.map(human_size);
            let date = e
                .modified_at_ms
                .map(|ms| crate::views::dates::stamp(ms, &chrono::Local::now(), cx.l10n()).0);
            [size, date]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>()
                .join(" • ")
        })
        .unwrap_or_default();
    let label = if directory {
        l.desktop_terminal_folder_row(&name)
    } else {
        name.clone()
    };
    let path = entry.as_ref().map(|e| e.path.clone()).unwrap_or_default();
    let (bg, fg) = if is_selected && focused {
        (r.selected, r.text)
    } else if is_selected {
        (with_alpha(r.text, 0.08), r.text)
    } else {
        (gpui_kit::transparent_black(), r.text)
    };
    let mut d = div()
        .id(SharedString::from(format!("terminal-file-{index}")))
        .role(Role::ListBoxOption)
        .aria_label(SharedString::from(label))
        .aria_selected(is_selected)
        .h(px(30.))
        .mx(px(6.))
        .px(px(10.))
        .flex()
        .items_center()
        .gap(px(10.))
        .rounded(px(6.))
        .bg(bg)
        .text_color(fg)
        .child(icon(
            if directory {
                IconName::Folder
            } else {
                IconName::FileText
            },
            15.,
            if directory { r.text } else { r.text_subtle },
        ));
    match edit {
        Some(input) => {
            d = d.child(
                div().flex_1().min_w_0().child(
                    conduit_components::views::kit::field_frame(true, 24., cx).child(
                        bare_input(&input, l.rename(), m.control)
                            .accessibility_id("terminal-file-name"),
                    ),
                ),
            );
        }
        None => {
            d = d
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .truncate()
                        .text_size(px(m.control))
                        .child(SharedString::from(name)),
                )
                .when(!detail.is_empty(), |d| {
                    d.child(
                        div()
                            .flex_none()
                            .text_size(px(m.small))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(detail)),
                    )
                });
        }
    }
    if !path.is_empty() {
        let (select, open, menu) = (weak.clone(), weak.clone(), weak.clone());
        let (p1, p2, p3) = (path.clone(), path.clone(), path);
        d = d
            .cursor_pointer()
            .hover(|s| if is_selected { s } else { s.bg(r.hover) })
            .on_mouse_down(
                MouseButton::Left,
                move |e: &gpui_kit::MouseDownEvent, window, cx| {
                    let path = p1.clone();
                    select
                        .update(cx, |f, cx| {
                            f.selected = Some(path.clone());
                            window.focus(&f.focus, cx);
                            if e.click_count >= 2 {
                                f.open_entry(&path, window, cx);
                            }
                            cx.notify();
                        })
                        .ok();
                },
            )
            .on_click(move |e: &ClickEvent, window, cx| {
                if e.is_keyboard() {
                    let path = p2.clone();
                    open.update(cx, |f, cx| f.open_entry(&path, window, cx))
                        .ok();
                }
            })
            .on_mouse_down(
                MouseButton::Right,
                move |e: &gpui_kit::MouseDownEvent, window, cx| {
                    let path = p3.clone();
                    cx.stop_propagation();
                    menu.update(cx, |f, cx| f.row_menu(path, e.position, window, cx))
                        .ok();
                },
            );
    }
    d.into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_split_into_crumbs_and_parents() {
        assert_eq!(as_dir("/home/demo"), "/home/demo/");
        assert_eq!(as_dir("/"), "/");
        assert_eq!(parent_of("/home/demo/"), "/home/");
        assert_eq!(parent_of("/home/demo/notes.txt"), "/home/demo/");
        assert_eq!(parent_of("/home/"), "/");
        assert_eq!(parent_of("/"), "/");
        assert_eq!(
            crumbs("/home/demo/"),
            vec![
                ("/".to_string(), "/".to_string()),
                ("home".to_string(), "/home/".to_string()),
                ("demo".to_string(), "/home/demo/".to_string()),
            ]
        );
    }

    #[test]
    fn names_must_name_one_entry() {
        assert!(valid_name("notes.txt"));
        assert!(valid_name(" spaced "));
        assert!(!valid_name(""));
        assert!(!valid_name("   "));
        assert!(!valid_name("a/b"));
        assert!(!valid_name(".."));
    }

    #[test]
    fn sizes_read_as_finder_writes_them() {
        assert_eq!(human_size(12), "12 bytes");
        assert_eq!(human_size(1_500), "1.5 KB");
        assert_eq!(human_size(48_213), "48 KB");
        assert_eq!(human_size(3_200_000), "3.2 MB");
    }
}
