//! The server's files, to pick one: mobile's server-file picker sheet
//! (`server_file_picker_sheet.dart`), shared by the composer's Server
//! Files panel and a knowledge base's Attach Server File…. A search field
//! over the user's files (`files.list`, newest first), the rows under it;
//! ↑ ↓ move, Enter or a click picks, Esc dismisses. The host draws the
//! frame around it (the composer's card, a sheet) and hears what was
//! picked ([`ServerFilesEvent`]).

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_protocol::{ComposerSearch, ServerFile, methods};
use gpui_kit::Focusable as _;
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    Context, ElementId, Entity, EventEmitter, FocusHandle, KeyDownEvent, Role, SharedString,
    Subscription, Task, Window, div, px,
};

use crate::l10n::ActiveL10n as _;
use crate::stores::rpc::Rpc;
use crate::views::chat::composer_panels::{note, row, search_field, when_size};

/// What the picker says to its host.
#[derive(Clone, Debug)]
pub enum ServerFilesEvent {
    Picked(ServerFile),
    Dismissed,
}

pub struct ServerFilesPicker {
    rpc: Rpc,
    pub search: Entity<InputState>,
    /// The answer for `query`, once it came.
    files: Option<Result<Vec<ServerFile>, ()>>,
    query: String,
    pub highlighted: usize,
    _subscription: Subscription,
    _search: Option<Task<()>>,
}

impl EventEmitter<ServerFilesEvent> for ServerFilesPicker {}

impl ServerFilesPicker {
    /// The picker, its field focused and the newest files asked for.
    pub fn new(rpc: Rpc, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let placeholder = cx.l10n().desktop_search_files();
        let search = cx.new(|cx| InputState::new(window, cx).placeholder(placeholder));
        search.update(cx, |s, cx| s.focus(window, cx));
        let subscription = cx.subscribe(&search, |this, input, e: &InputEvent, cx| match e {
            InputEvent::Change => {
                let query = input.read(cx).value().trim().to_string();
                this.run_search(query, cx);
            }
            InputEvent::PressEnter { .. } => this.pick_highlighted(cx),
            _ => {}
        });
        let mut this = Self {
            rpc,
            search,
            files: None,
            query: String::new(),
            highlighted: 0,
            _subscription: subscription,
            _search: None,
        };
        this.run_search(String::new(), cx);
        this
    }

    fn run_search(&mut self, query: String, cx: &mut Context<Self>) {
        self.query = query.clone();
        self.highlighted = 0;
        let call = self.rpc.call::<methods::FilesList>(&ComposerSearch {
            query: query.clone(),
        });
        let call = cx.background_spawn(call);
        self._search = Some(cx.spawn(async move |this, cx| {
            let result = call.await;
            let _ = this.update(cx, |this, cx| {
                // An answer for an older query is not shown.
                if this.query != query {
                    return;
                }
                this.files = Some(
                    result
                        .map(|l| l.items)
                        .map_err(|e| log::warn!("files.list: {e}")),
                );
                cx.notify();
            });
        }));
        cx.notify();
    }

    /// The files for the field's query, once listed.
    pub fn files(&self) -> &[ServerFile] {
        match &self.files {
            Some(Ok(files)) => files,
            _ => &[],
        }
    }

    /// Whether the files for the field's query have been listed.
    pub fn listed(&self) -> bool {
        self.files.is_some()
    }

    pub fn focus_handle(&self, cx: &gpui_kit::App) -> FocusHandle {
        self.search.read(cx).focus_handle(cx)
    }

    /// ↑ or ↓ (`up`, `down`) through the rows.
    pub fn step(&mut self, key: &str, cx: &mut Context<Self>) {
        let len = self.files().len();
        self.highlighted = crate::views::chat::composer::menu_step(key, self.highlighted, len);
        cx.notify();
    }

    /// Picks the row at `index`.
    pub fn pick(&mut self, index: usize, cx: &mut Context<Self>) {
        if let Some(file) = self.files().get(index).cloned() {
            cx.emit(ServerFilesEvent::Picked(file));
        }
    }

    pub fn pick_highlighted(&mut self, cx: &mut Context<Self>) {
        self.pick(self.highlighted, cx);
    }

    /// A key while the field has the keyboard (↑ ↓ Enter Esc); true when it
    /// was the picker's.
    pub fn key(&mut self, key: &str, cx: &mut Context<Self>) -> bool {
        match key {
            "up" | "down" => self.step(key, cx),
            "enter" => self.pick_highlighted(cx),
            "escape" => cx.emit(ServerFilesEvent::Dismissed),
            _ => return false,
        }
        true
    }
}

impl Render for ServerFilesPicker {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        let files = self.files().to_vec();
        let total = files.len();
        let list: Vec<gpui_kit::AnyElement> = files
            .into_iter()
            .enumerate()
            .map(|(i, f)| {
                row(
                    ElementId::NamedInteger("server-file".into(), i as u64),
                    IconName::FileText,
                    f.name.clone(),
                    when_size(f.size),
                    (i == self.highlighted, i, total),
                    &t,
                )
                .on_click(cx.listener(move |this, _, _, cx| this.pick(i, cx)))
                .into_any_element()
            })
            .collect();
        let empty = match &self.files {
            None => Some(note(l10n.desktop_loading(), &t, false)),
            Some(Err(())) => Some(note(l10n.desktop_server_files_failed(), &t, true)),
            Some(Ok(f)) if f.is_empty() => Some(note(l10n.desktop_no_files_match(), &t, false)),
            _ => None,
        };
        div()
            .flex()
            .flex_col()
            .gap(px(8.))
            .capture_key_down(cx.listener(|this, ev: &KeyDownEvent, _, cx| {
                let key = ev.keystroke.key.as_str();
                if matches!(key, "up" | "down" | "escape") && this.key(key, cx) {
                    cx.stop_propagation();
                }
            }))
            .child(search_field(&self.search, l10n.desktop_search_files(), &t))
            .child(
                div()
                    .id("server-files-list")
                    .role(Role::ListBox)
                    .aria_label(SharedString::from(l10n.composer_attach_server_files()))
                    .max_h(px(260.))
                    .overflow_y_scroll()
                    .flex()
                    .flex_col()
                    .children(empty)
                    .children(list),
            )
    }
}
