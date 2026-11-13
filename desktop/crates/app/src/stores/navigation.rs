//! Which chat the main window shows.
//!
//! The sidebar, the ⌘K palette and the New Chat command set the selection;
//! the chat pane follows it. A `route.remap` moves the selection to the
//! chat's new id without announcing a change: it is still the same chat,
//! and the chat store follows [`super::router::RouterEvent::Remapped`] itself.

use gpui_kit::{Context, EventEmitter};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Selection {
    /// A stored chat, by id.
    Chat(String),
    /// A chat that doesn't exist yet. A temporary chat is never saved.
    New { temporary: bool },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NavigationEvent {
    /// The user picked another chat, or started a new one.
    Changed(Selection),
}

pub struct NavigationStore {
    selection: Selection,
    /// The folder the new chat goes in once its first message is sent (a
    /// folder's "New Chat in Folder").
    new_chat_folder: Option<String>,
}

impl Default for NavigationStore {
    fn default() -> Self {
        Self {
            selection: Selection::New { temporary: false },
            new_chat_folder: None,
        }
    }
}

impl EventEmitter<NavigationEvent> for NavigationStore {}

impl NavigationStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn selection(&self) -> &Selection {
        &self.selection
    }

    /// The open stored chat, if one is open.
    pub fn selected_chat(&self) -> Option<&str> {
        match &self.selection {
            Selection::Chat(id) => Some(id),
            Selection::New { .. } => None,
        }
    }

    pub fn open(&mut self, id: impl Into<String>, cx: &mut Context<Self>) {
        self.set(Selection::Chat(id.into()), cx);
    }

    pub fn new_chat(&mut self, temporary: bool, cx: &mut Context<Self>) {
        self.new_chat_folder = None;
        self.set(Selection::New { temporary }, cx);
    }

    /// A new chat that is filed in `folder_id` once it exists.
    pub fn new_chat_in_folder(&mut self, folder_id: String, cx: &mut Context<Self>) {
        self.set(Selection::New { temporary: false }, cx);
        self.new_chat_folder = Some(folder_id);
        cx.notify();
    }

    /// The folder the new chat goes in, taken once (when it is created).
    pub fn take_new_chat_folder(&mut self) -> Option<String> {
        self.new_chat_folder.take()
    }

    /// The folder the new chat will go in.
    pub fn new_chat_folder(&self) -> Option<&str> {
        self.new_chat_folder.as_deref()
    }

    /// `route.remap`: the open chat keeps showing under its new id.
    pub fn on_remap(&mut self, from: &str, to: &str, cx: &mut Context<Self>) {
        if from != to && self.selected_chat() == Some(from) {
            self.selection = Selection::Chat(to.to_string());
            cx.notify();
        }
    }

    /// Another account, or no account: nothing selected carries over.
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.set(Selection::New { temporary: false }, cx);
    }

    fn set(&mut self, selection: Selection, cx: &mut Context<Self>) {
        if self.selection == selection {
            return;
        }
        if matches!(selection, Selection::Chat(_)) {
            self.new_chat_folder = None;
        }
        self.selection = selection.clone();
        cx.emit(NavigationEvent::Changed(selection));
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use gpui_kit::{AppContext as _, TestAppContext};

    use super::*;

    #[gpui_kit::test]
    fn selection_changes_announce_once_and_remaps_follow_quietly(cx: &mut TestAppContext) {
        let store = cx.new(|_| NavigationStore::new());
        let seen = Rc::new(RefCell::new(vec![]));
        cx.update(|cx| {
            let seen = seen.clone();
            cx.subscribe(&store, move |_, e: &NavigationEvent, _| {
                seen.borrow_mut().push(e.clone())
            })
            .detach();
        });
        store.update(cx, |s, cx| {
            s.open("c1", cx);
            s.open("c1", cx);
            s.on_remap("c1", "c2", cx);
            s.on_remap("other", "c3", cx);
        });
        store.read_with(cx, |s, _| assert_eq!(s.selected_chat(), Some("c2")));
        store.update(cx, |s, cx| s.new_chat(true, cx));
        store.read_with(cx, |s, _| {
            assert_eq!(s.selection(), &Selection::New { temporary: true });
            assert_eq!(s.selected_chat(), None);
        });
        store.update(cx, |s, cx| s.reset(cx));
        assert_eq!(
            *seen.borrow(),
            vec![
                NavigationEvent::Changed(Selection::Chat("c1".into())),
                NavigationEvent::Changed(Selection::New { temporary: true }),
                NavigationEvent::Changed(Selection::New { temporary: false }),
            ]
        );
    }
}
