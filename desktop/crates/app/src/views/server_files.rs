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
        // Another query: the last one's rows go until this one's come, so
        // Enter, ↑ ↓ or a click never reach a file that does not match it.
        if query != self.query {
            self.files = None;
        }
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
                // The rows are new: the highlight starts at the top.
                this.highlighted = 0;
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
    /// Moves the highlight, and says where it landed (VoiceOver; the
    /// search field keeps focus).
    pub fn step(&mut self, key: &str, cx: &mut Context<Self>) {
        let len = self.files().len();
        self.highlighted = crate::views::chat::composer::menu_step(key, self.highlighted, len);
        if let Some(file) = self.files().get(self.highlighted) {
            let name = file.name.clone();
            crate::views::a11y::announce_row(&name, self.highlighted, len, cx);
        }
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

#[cfg(test)]
mod tests {
    use conduit_protocol::ServerFileList;
    use gpui_kit::TestAppContext;
    use serde_json::json;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    fn file(id: &str, name: &str) -> ServerFile {
        ServerFile {
            id: id.into(),
            name: name.into(),
            size: None,
            content_type: None,
            updated_at_ms: None,
        }
    }

    /// While a new search waits, the last search's rows are gone: Enter or
    /// ↓ never reach a file that does not match what was typed, and the
    /// answer's rows start highlighted at the top.
    #[gpui_kit::test]
    fn a_new_search_offers_none_of_the_last_ones_files(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.on::<methods::FilesList>(|p| {
            let items = match p["query"].as_str().unwrap_or("") {
                "budget" => vec![file("f2", "budget.csv")],
                _ => vec![
                    file("f1", "field-notes.txt"),
                    file("f3", "tide-table.pdf"),
                    file("f4", "gull-sketch.png"),
                ],
            };
            Ok(serde_json::to_value(ServerFileList { items }).unwrap())
        });
        cx.update(crate::views::test_globals);
        let rpc = daemon.rpc();
        let (picker, vcx) =
            cx.add_window_view(move |window, cx| ServerFilesPicker::new(rpc, window, cx));
        vcx.run_until_parked();
        assert_eq!(picker.read_with(vcx, |p, _| p.files().len()), 3);
        let picked: std::rc::Rc<std::cell::RefCell<Vec<String>>> = Default::default();
        let _listening = vcx.update(|_, cx| {
            let picked = picked.clone();
            cx.subscribe(&picker, move |_, e: &ServerFilesEvent, _| {
                if let ServerFilesEvent::Picked(f) = e {
                    picked.borrow_mut().push(f.name.clone());
                }
            })
        });
        let held = daemon.hold::<methods::FilesList>();
        picker.update(vcx, |p, cx| {
            p.run_search("budget".into(), cx);
            p.key("down", cx);
            p.key("down", cx);
            p.key("enter", cx);
        });
        vcx.run_until_parked();
        assert!(
            picked.borrow().is_empty(),
            "the last search's file was picked: {:?}",
            picked.borrow()
        );
        assert!(!picker.read_with(vcx, |p, _| p.listed()));
        held.release();
        vcx.run_until_parked();
        assert_eq!(picker.read_with(vcx, |p, _| p.highlighted), 0);
        picker.update(vcx, |p, cx| {
            p.key("enter", cx);
        });
        assert_eq!(*picked.borrow(), vec!["budget.csv".to_string()]);
        assert_eq!(
            daemon.calls::<methods::FilesList>()[1],
            json!({ "query": "budget" })
        );
    }
}
