//! What the main window shows: a chat, or an item of another area of the
//! sidebar, with Finder's Back and Forward through what was shown.
//!
//! The sidebar, the ⌘K palette and the New Chat command set the selection;
//! the chat pane follows it while it is a chat, and the main window shows the
//! area's pane ([`crate::views::panes`]) for anything else. A `route.remap`
//! moves the selection to the chat's new id without announcing a change: it
//! is still the same chat, and the chat store follows
//! [`super::router::RouterEvent::Remapped`] itself.
//!
//! **History.** Every change the user makes is a step Back (⌘[) can undo
//! and Forward (⌘]) redo, as in Finder; a remap rewrites the steps that
//! named the old id, and another account forgets them.

use gpui_kit::{Context, EventEmitter};

/// An area of the sidebar: one section of its source list, in the order the
/// list shows them (the phone's tab order, then the Mac's own sections).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Area {
    Chats,
    Hermes,
    Notes,
    Terminal,
    Channels,
    Workspace,
    Calendar,
    Automations,
}

impl Area {
    pub const ALL: [Self; 8] = [
        Self::Chats,
        Self::Hermes,
        Self::Notes,
        Self::Terminal,
        Self::Channels,
        Self::Workspace,
        Self::Calendar,
        Self::Automations,
    ];

    /// The stored name (collapse state, the E2E).
    pub fn id(self) -> &'static str {
        match self {
            Self::Chats => "chats",
            Self::Hermes => "hermes",
            Self::Notes => "notes",
            Self::Terminal => "terminal",
            Self::Channels => "channels",
            Self::Workspace => "workspace",
            Self::Calendar => "calendar",
            Self::Automations => "automations",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|a| a.id() == id)
    }
}

/// A workspace section, as the phone's workspace orders them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum WorkspaceSection {
    Models,
    Knowledge,
    Prompts,
    Tools,
    Skills,
}

impl WorkspaceSection {
    pub const ALL: [Self; 5] = [
        Self::Models,
        Self::Knowledge,
        Self::Prompts,
        Self::Tools,
        Self::Skills,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Self::Models => "models",
            Self::Knowledge => "knowledge",
            Self::Prompts => "prompts",
            Self::Tools => "tools",
            Self::Skills => "skills",
        }
    }
}

/// An item of an area other than Chats: what its pane shows.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum AreaItem {
    Note(String),
    Channel(String),
    /// A Hermes session, by its session id.
    HermesSession(String),
    Workspace(WorkspaceSection),
    /// A terminal server, by its id.
    Terminal(String),
    Calendar,
    Automations,
}

impl AreaItem {
    pub fn area(&self) -> Area {
        match self {
            Self::Note(_) => Area::Notes,
            Self::Channel(_) => Area::Channels,
            Self::HermesSession(_) => Area::Hermes,
            Self::Workspace(_) => Area::Workspace,
            Self::Terminal(_) => Area::Terminal,
            Self::Calendar => Area::Calendar,
            Self::Automations => Area::Automations,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Selection {
    /// A stored chat, by id.
    Chat(String),
    /// A chat that doesn't exist yet. A temporary chat is never saved.
    New { temporary: bool },
    /// An item of another area, shown in its own pane.
    Area(AreaItem),
}

impl Selection {
    /// The area it belongs to.
    pub fn area(&self) -> Area {
        match self {
            Self::Chat(_) | Self::New { .. } => Area::Chats,
            Self::Area(item) => item.area(),
        }
    }

    /// The chat pane shows it (a chat, or a new one).
    pub fn is_chat(&self) -> bool {
        matches!(self, Self::Chat(_) | Self::New { .. })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NavigationEvent {
    /// The user picked another chat or item, or started a new chat.
    Changed(Selection),
}

/// How many steps Back remembers.
pub const HISTORY_LIMIT: usize = 64;

pub struct NavigationStore {
    selection: Selection,
    /// The folder the new chat goes in once its first message is sent (a
    /// folder's "New Chat in Folder").
    new_chat_folder: Option<String>,
    /// What was shown before, oldest first (Back pops the last).
    back: Vec<Selection>,
    /// What Back left, most recent last (Forward pops it).
    forward: Vec<Selection>,
}

impl Default for NavigationStore {
    fn default() -> Self {
        Self {
            selection: Selection::New { temporary: false },
            new_chat_folder: None,
            back: vec![],
            forward: vec![],
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
            Selection::New { .. } | Selection::Area(_) => None,
        }
    }

    /// The open item of another area, if one is open.
    pub fn selected_item(&self) -> Option<&AreaItem> {
        match &self.selection {
            Selection::Area(item) => Some(item),
            _ => None,
        }
    }

    pub fn open(&mut self, id: impl Into<String>, cx: &mut Context<Self>) {
        self.set(Selection::Chat(id.into()), cx);
    }

    /// Shows `item` in its area's pane.
    pub fn open_item(&mut self, item: AreaItem, cx: &mut Context<Self>) {
        self.set(Selection::Area(item), cx);
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

    /// `route.remap`: the open chat keeps showing under its new id, and
    /// history's steps to it follow.
    pub fn on_remap(&mut self, from: &str, to: &str, cx: &mut Context<Self>) {
        if from == to {
            return;
        }
        for step in self.back.iter_mut().chain(self.forward.iter_mut()) {
            if *step == Selection::Chat(from.to_string()) {
                *step = Selection::Chat(to.to_string());
            }
        }
        if self.selected_chat() == Some(from) {
            self.selection = Selection::Chat(to.to_string());
            cx.notify();
        }
    }

    /// Another account, or no account: nothing selected carries over, and
    /// neither does history.
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.new_chat_folder = None;
        self.back.clear();
        self.forward.clear();
        self.set_quietly(Selection::New { temporary: false }, cx);
    }

    /// Whether Back has somewhere to go that `usable` accepts.
    pub fn can_go_back(&self, usable: impl Fn(&Selection) -> bool) -> bool {
        self.back.iter().any(usable)
    }

    pub fn can_go_forward(&self, usable: impl Fn(&Selection) -> bool) -> bool {
        self.forward.iter().any(usable)
    }

    /// Go › Back (⌘[): what was shown before, passing over steps `usable`
    /// refuses (an area this account cannot use any more).
    pub fn go_back(&mut self, usable: impl Fn(&Selection) -> bool, cx: &mut Context<Self>) {
        while let Some(step) = self.back.pop() {
            if usable(&step) && step != self.selection {
                let current = std::mem::replace(&mut self.selection, step.clone());
                self.forward.push(current);
                self.announce(step, cx);
                return;
            }
        }
    }

    /// Go › Forward (⌘]).
    pub fn go_forward(&mut self, usable: impl Fn(&Selection) -> bool, cx: &mut Context<Self>) {
        while let Some(step) = self.forward.pop() {
            if usable(&step) && step != self.selection {
                let current = std::mem::replace(&mut self.selection, step.clone());
                self.back.push(current);
                self.announce(step, cx);
                return;
            }
        }
    }

    fn set(&mut self, selection: Selection, cx: &mut Context<Self>) {
        if self.selection == selection {
            return;
        }
        let previous = std::mem::replace(&mut self.selection, selection.clone());
        self.back.push(previous);
        if self.back.len() > HISTORY_LIMIT {
            self.back.remove(0);
        }
        self.forward.clear();
        self.announce(selection, cx);
    }

    /// A change that is not a step of history (an account's reset).
    fn set_quietly(&mut self, selection: Selection, cx: &mut Context<Self>) {
        if self.selection == selection {
            return;
        }
        self.selection = selection.clone();
        self.announce(selection, cx);
    }

    fn announce(&mut self, selection: Selection, cx: &mut Context<Self>) {
        if !matches!(selection, Selection::New { .. }) {
            self.new_chat_folder = None;
        }
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
        // A reset forgets the folder a new chat was going to go in.
        store.update(cx, |s, cx| {
            s.new_chat_in_folder("folder-a".into(), cx);
            s.reset(cx);
        });
        store.read_with(cx, |s, _| assert_eq!(s.new_chat_folder(), None));
        assert_eq!(
            *seen.borrow(),
            vec![
                NavigationEvent::Changed(Selection::Chat("c1".into())),
                NavigationEvent::Changed(Selection::New { temporary: true }),
                NavigationEvent::Changed(Selection::New { temporary: false }),
            ]
        );
    }

    #[gpui_kit::test]
    fn back_and_forward_walk_what_was_shown_across_areas(cx: &mut TestAppContext) {
        let store = cx.new(|_| NavigationStore::new());
        let note = Selection::Area(AreaItem::Note("n1".into()));
        store.update(cx, |s, cx| {
            s.open("c1", cx);
            s.open_item(AreaItem::Note("n1".into()), cx);
            s.open_item(AreaItem::Workspace(WorkspaceSection::Prompts), cx);
        });
        let any = |_: &Selection| true;
        store.update(cx, |s, cx| {
            s.go_back(any, cx);
            assert_eq!(s.selection(), &note);
            assert_eq!(s.selection().area(), Area::Notes);
            assert!(!s.selection().is_chat());
            s.go_back(any, cx);
            assert_eq!(s.selected_chat(), Some("c1"));
            assert!(s.can_go_forward(any));
            s.go_forward(any, cx);
            assert_eq!(s.selection(), &note);
            // A new step drops what Forward held.
            s.open("c9", cx);
            assert!(!s.can_go_forward(any));
            // Steps an account can no longer use are passed over.
            s.go_back(|step| step.area() != Area::Notes, cx);
            assert_eq!(s.selected_chat(), Some("c1"));
        });
    }

    #[gpui_kit::test]
    fn remaps_rewrite_history_and_a_reset_forgets_it(cx: &mut TestAppContext) {
        let store = cx.new(|_| NavigationStore::new());
        store.update(cx, |s, cx| {
            s.open("local:1", cx);
            s.open_item(AreaItem::Calendar, cx);
            s.on_remap("local:1", "c42", cx);
            s.go_back(|_| true, cx);
            assert_eq!(s.selected_chat(), Some("c42"));
            s.reset(cx);
            assert!(!s.can_go_back(|_| true) && !s.can_go_forward(|_| true));
        });
        for area in Area::ALL {
            assert_eq!(Area::from_id(area.id()), Some(area));
        }
    }
}
