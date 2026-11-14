//! The workspace: models, knowledge bases, prompts, tools and
//! skills on the Open WebUI server, as the phone's Workspace manages them,
//! in the main pane when the sidebar's Workspace section has one selected.
//!
//! The pane is a list beside an editor, as Mail and Notes lay out a
//! message list and a message: the list column searches, filters and
//! sorts the section, switches items on and off, and has each item's
//! context menu (Edit, Duplicate, Export…, Share Access…, Delete…); the
//! editor column edits the selected item, or a new one, with Save and
//! Revert along its bottom edge. Small forms (a new knowledge base, a text
//! file, a folder, a tool's address) are window sheets.
//!
//! Everything goes through `workspace.*`: the daemon holds the core's
//! paged collections, saves over what the server has (keeping what an
//! editor does not show), and tells every window with `workspace.changed`,
//! which refreshes the section and an editor without edits.

pub mod editor;
pub mod knowledge;
pub mod model;
pub mod prompt;
pub mod sheets;
pub mod skill;
pub mod tool;
pub mod transfer;

use std::collections::HashMap;
use std::rc::Rc;
use std::time::Duration;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::announce::{Priority, live_text};
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::with_alpha;
use conduit_components::views::focus::{ControlExt as _, Ring};
use conduit_components::views::kit::{IconButton, Switch, bare_input, field_frame};
use conduit_protocol::{
    AccessResourceKind, Event, NoticeLevel, WorkspaceAccess, WorkspaceDuplicate, WorkspaceItem,
    WorkspaceKind, WorkspaceQuery, WorkspaceRef, WorkspaceSectionAccess, events, methods,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::component::{VirtualListScrollHandle, v_virtual_list};
use gpui_kit::prelude::*;
use gpui_kit::{
    Action, AnyElement, App, AsyncApp, Context, ElementId, Entity, FocusHandle, Focusable,
    FontWeight, MouseButton, MouseDownEvent, Pixels, Point, Role, SharedString, Size, Subscription,
    Task, Toggled, WeakEntity, Window, div, px, size,
};

use crate::actions::SettingsChoice;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::connection::ConnectionEvent;
use crate::stores::navigation::WorkspaceSection;
use crate::stores::rpc::Rpc;
use crate::views::forms;
use crate::views::settings::controls::{self, Choice};

pub use editor::{EditorEvent, ItemEditor};

/// The list column's width.
pub const LIST_WIDTH: f32 = 300.;
/// A list row's height: the name over one line of detail.
const ROW_HEIGHT: f32 = 54.;
/// How long typing pauses before the server is searched.
const SEARCH_DELAY: Duration = Duration::from_millis(250);

/// The protocol's name for a section.
pub fn kind_of(section: WorkspaceSection) -> WorkspaceKind {
    match section {
        WorkspaceSection::Models => WorkspaceKind::Models,
        WorkspaceSection::Knowledge => WorkspaceKind::Knowledge,
        WorkspaceSection::Prompts => WorkspaceKind::Prompts,
        WorkspaceSection::Tools => WorkspaceKind::Tools,
        WorkspaceSection::Skills => WorkspaceKind::Skills,
    }
}

/// The section a protocol kind names.
pub fn section_of(kind: WorkspaceKind) -> Option<WorkspaceSection> {
    Some(match kind {
        WorkspaceKind::Models => WorkspaceSection::Models,
        WorkspaceKind::Knowledge => WorkspaceSection::Knowledge,
        WorkspaceKind::Prompts => WorkspaceSection::Prompts,
        WorkspaceKind::Tools => WorkspaceSection::Tools,
        WorkspaceKind::Skills => WorkspaceSection::Skills,
        WorkspaceKind::Unknown => return None,
    })
}

/// The access sheet's name for an item of `section`.
pub fn access_kind(section: WorkspaceSection) -> AccessResourceKind {
    match section {
        WorkspaceSection::Models => AccessResourceKind::Model,
        WorkspaceSection::Knowledge => AccessResourceKind::Knowledge,
        WorkspaceSection::Prompts => AccessResourceKind::Prompt,
        WorkspaceSection::Tools => AccessResourceKind::Tool,
        WorkspaceSection::Skills => AccessResourceKind::Skill,
    }
}

/// What `access` allows in `section`.
pub fn section_access(
    access: &WorkspaceAccess,
    section: WorkspaceSection,
) -> &WorkspaceSectionAccess {
    match section {
        WorkspaceSection::Models => &access.models,
        WorkspaceSection::Knowledge => &access.knowledge,
        WorkspaceSection::Prompts => &access.prompts,
        WorkspaceSection::Tools => &access.tools,
        WorkspaceSection::Skills => &access.skills,
    }
}

/// The section's glyph (the sidebar's).
pub fn section_icon(section: WorkspaceSection) -> IconName {
    match section {
        WorkspaceSection::Models => IconName::Network,
        WorkspaceSection::Knowledge => IconName::LibraryBig,
        WorkspaceSection::Prompts => IconName::TextQuote,
        WorkspaceSection::Tools => IconName::Wrench,
        WorkspaceSection::Skills => IconName::WandSparkles,
    }
}

/// What New makes in `section` ("New Model", "New Knowledge Base…").
pub fn new_label(section: WorkspaceSection, l: &L10n) -> String {
    match section {
        WorkspaceSection::Models => l.workspace_model_new_title(),
        WorkspaceSection::Knowledge => l.desktop_workspace_new_knowledge(),
        WorkspaceSection::Prompts => l.workspace_prompt_create_title(),
        WorkspaceSection::Tools => l.desktop_workspace_new_tool(),
        WorkspaceSection::Skills => l.workspace_skill_create_title(),
    }
}

/// How the list is ordered.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum SortOrder {
    /// The most recently changed first (the server's order).
    #[default]
    Modified,
    /// By name, A to Z.
    Name,
}

/// One section's list as the window holds it.
#[derive(Clone, Debug)]
pub struct SectionList {
    pub query: String,
    /// `all`, `created` or `shared`.
    pub view: String,
    /// Knowledge only: empty (all), `local` or `external`.
    pub source: String,
    pub sort: SortOrder,
    pub items: Vec<WorkspaceItem>,
    pub total: i64,
    pub has_more: bool,
    pub loading: bool,
    pub loaded: bool,
    pub error: Option<String>,
    generation: u64,
}

impl Default for SectionList {
    fn default() -> Self {
        Self {
            query: String::new(),
            view: "all".into(),
            source: String::new(),
            sort: SortOrder::default(),
            items: vec![],
            total: 0,
            has_more: false,
            loading: false,
            loaded: false,
            error: None,
            generation: 0,
        }
    }
}

impl SectionList {
    /// The items in the order shown.
    pub fn shown(&self) -> Vec<WorkspaceItem> {
        let mut items = self.items.clone();
        if self.sort == SortOrder::Name {
            items.sort_by_key(|i| display_name(i).to_lowercase());
        }
        items
    }

    /// The item `id`, as listed.
    pub fn item(&self, id: &str) -> Option<&WorkspaceItem> {
        self.items.iter().find(|i| i.id == id)
    }
}

/// An item's name; an unnamed one shows its id.
pub fn display_name(item: &WorkspaceItem) -> String {
    if item.name.trim().is_empty() {
        item.id.clone()
    } else {
        item.name.clone()
    }
}

/// What a context menu or an editor's More menu asks of an item.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ItemCommand {
    Edit,
    Duplicate,
    Export,
    Share,
    Toggle,
    Hide,
    Delete,
}

/// A command on item `id` of `section`, from a context menu.
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit_workspace, no_json)]
pub struct WorkspaceMenu {
    pub section: WorkspaceSection,
    pub id: String,
    pub command: ItemCommand,
}

/// The list header's action menu: Import… and Export All….
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit_workspace, no_json)]
pub struct WorkspaceListMenu {
    pub section: WorkspaceSection,
    pub command: ListCommand,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ListCommand {
    Import,
    ImportMarkdown,
    ExportAll,
    ImportFromUrl,
}

/// An editor on screen, one per section.
#[derive(Clone)]
pub enum EditorView {
    Model(Entity<model::ModelEditor>),
    Knowledge(Entity<knowledge::KnowledgeEditor>),
    Prompt(Entity<prompt::PromptEditor>),
    Tool(Entity<tool::ToolEditor>),
    Skill(Entity<skill::SkillEditor>),
}

impl EditorView {
    pub fn any(&self) -> gpui_kit::AnyView {
        match self {
            Self::Model(e) => e.clone().into(),
            Self::Knowledge(e) => e.clone().into(),
            Self::Prompt(e) => e.clone().into(),
            Self::Tool(e) => e.clone().into(),
            Self::Skill(e) => e.clone().into(),
        }
    }

    /// The item it edits; None for a new one.
    pub fn item_id(&self, cx: &App) -> Option<String> {
        match self {
            Self::Model(e) => e.read(cx).item_id(),
            Self::Knowledge(e) => e.read(cx).item_id(),
            Self::Prompt(e) => e.read(cx).item_id(),
            Self::Tool(e) => e.read(cx).item_id(),
            Self::Skill(e) => e.read(cx).item_id(),
        }
    }

    pub fn is_dirty(&self, cx: &App) -> bool {
        match self {
            Self::Model(e) => e.read(cx).is_dirty(cx),
            Self::Knowledge(e) => e.read(cx).is_dirty(cx),
            Self::Prompt(e) => e.read(cx).is_dirty(cx),
            Self::Tool(e) => e.read(cx).is_dirty(cx),
            Self::Skill(e) => e.read(cx).is_dirty(cx),
        }
    }

    /// Reads the item again (it changed elsewhere), unless it has edits.
    pub fn reload_if_clean(&self, window: &mut Window, cx: &mut App) {
        if self.is_dirty(cx) {
            return;
        }
        match self {
            Self::Model(e) => e.update(cx, |e, cx| e.reload(window, cx)),
            Self::Knowledge(e) => e.update(cx, |e, cx| e.reload(window, cx)),
            Self::Prompt(e) => e.update(cx, |e, cx| e.reload(window, cx)),
            Self::Tool(e) => e.update(cx, |e, cx| e.reload(window, cx)),
            Self::Skill(e) => e.update(cx, |e, cx| e.reload(window, cx)),
        }
    }

    /// Save (⌘S).
    pub fn save(&self, window: &mut Window, cx: &mut App) {
        match self {
            Self::Model(e) => e.update(cx, |e, cx| e.save(window, cx)),
            Self::Knowledge(e) => e.update(cx, |e, cx| e.save(window, cx)),
            Self::Prompt(e) => e.update(cx, |e, cx| e.save(window, cx)),
            Self::Tool(e) => e.update(cx, |e, cx| e.save(window, cx)),
            Self::Skill(e) => e.update(cx, |e, cx| e.save(window, cx)),
        }
    }
}

/// The workspace pane: one section's list and the editor beside it.
pub struct WorkspacePane {
    stores: Stores,
    rpc: Rpc,
    focus: FocusHandle,
    pub section: WorkspaceSection,
    pub access: Option<WorkspaceAccess>,
    pub lists: HashMap<WorkspaceSection, SectionList>,
    /// The item each section has selected.
    pub selected: HashMap<WorkspaceSection, String>,
    /// The editor each section shows.
    pub editors: HashMap<WorkspaceSection, EditorView>,
    search: Entity<InputState>,
    scroll: VirtualListScrollHandle,
    /// A row whose context menu is open (outlined while it is).
    context_target: Option<String>,
    loads: HashMap<WorkspaceSection, Task<()>>,
    editor_subscriptions: HashMap<WorkspaceSection, Subscription>,
    _search: Option<Task<()>>,
    _access: Option<Task<()>>,
    _subscriptions: Vec<Subscription>,
}

impl WorkspacePane {
    pub fn new(
        stores: Stores,
        section: WorkspaceSection,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let rpc = stores.connection.read(cx).rpc();
        let search = forms::input(cx.l10n().desktop_search(), false, window, cx);
        stores.connection.update(cx, |c, _| {
            c.subscribe("workspace", &[events::WORKSPACE_CHANGED], vec![])
        });
        let subscriptions = vec![
            cx.subscribe_in(&search, window, |this, state, e: &InputEvent, _, cx| {
                if matches!(e, InputEvent::Change) {
                    let query = state.read(cx).value().to_string();
                    this.search_for(query, cx);
                }
            }),
            cx.subscribe_in(
                &stores.connection,
                window,
                |this, _, event: &ConnectionEvent, window, cx| match event {
                    ConnectionEvent::Daemon(e) => {
                        if let Event::WorkspaceChanged(changed) = e.as_ref() {
                            let (kind, id) = (changed.kind, changed.id.clone());
                            this.on_changed(kind, id, window, cx);
                        }
                    }
                    ConnectionEvent::Connected { .. } | ConnectionEvent::Gap => {
                        this.refresh_all(cx);
                    }
                    _ => {}
                },
            ),
        ];
        // Another account's workspace: nothing of this one's stays.
        let mut account = active_account(&stores, cx);
        let subscriptions = {
            let mut subscriptions = subscriptions;
            subscriptions.push(cx.observe(&stores.accounts, move |this, _, cx| {
                let now = active_account(&this.stores, cx);
                if now != account {
                    account = now;
                    this.reset(cx);
                }
            }));
            subscriptions
        };
        let mut this = Self {
            stores,
            rpc,
            focus: cx.focus_handle(),
            section,
            access: None,
            lists: HashMap::new(),
            selected: HashMap::new(),
            editors: HashMap::new(),
            search,
            scroll: VirtualListScrollHandle::new(),
            context_target: None,
            loads: HashMap::new(),
            editor_subscriptions: HashMap::new(),
            _search: None,
            _access: None,
            _subscriptions: subscriptions,
        };
        this.load_access(cx);
        this.load(section, false, cx);
        this
    }

    /// The list's scroll position (the perf fixture).
    pub fn scroll_handle(&self) -> &VirtualListScrollHandle {
        &self.scroll
    }

    pub fn stores(&self) -> &Stores {
        &self.stores
    }

    pub fn rpc(&self) -> &Rpc {
        &self.rpc
    }

    /// What the account may do in the section shown.
    pub fn allows(&self, section: WorkspaceSection) -> WorkspaceSectionAccess {
        self.access
            .as_ref()
            .map(|a| section_access(a, section).clone())
            .unwrap_or_default()
    }

    /// Forgets every list, selection and editor (the account changed), and
    /// loads the section shown again.
    fn reset(&mut self, cx: &mut Context<Self>) {
        self.lists.clear();
        self.selected.clear();
        self.editors.clear();
        self.editor_subscriptions.clear();
        self.loads.clear();
        self.access = None;
        self.load_access(cx);
        let section = self.section;
        self.load(section, false, cx);
    }

    /// The list of `section` (made empty the first time).
    pub fn list(&mut self, section: WorkspaceSection) -> &mut SectionList {
        self.lists.entry(section).or_default()
    }

    /// The list shown, if loaded.
    pub fn current(&self) -> Option<&SectionList> {
        self.lists.get(&self.section)
    }

    /// The editor the section shows.
    pub fn editor(&self) -> Option<&EditorView> {
        self.editors.get(&self.section)
    }

    /// The sidebar picked `section`: show it, its search text and its list.
    pub fn show(&mut self, section: WorkspaceSection, window: &mut Window, cx: &mut Context<Self>) {
        if self.section == section {
            return;
        }
        self.section = section;
        let query = self.list(section).query.clone();
        self.search
            .update(cx, |s, cx| s.set_value(query, window, cx));
        if !self.list(section).loaded {
            self.load(section, false, cx);
        }
        cx.notify();
    }

    fn load_access(&mut self, cx: &mut Context<Self>) {
        let call = self
            .rpc
            .call::<methods::WorkspaceCapabilities>(&conduit_protocol::NoParams);
        self._access = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(access) => s.access = Some(access),
                        Err(e) => log::warn!("workspace.capabilities: {e}"),
                    }
                    cx.notify();
                });
            }),
        );
    }

    /// Loads `section`'s list as its filters say; `more` adds the next page.
    pub fn load(&mut self, section: WorkspaceSection, more: bool, cx: &mut Context<Self>) {
        let list = self.list(section);
        list.generation += 1;
        list.loading = true;
        list.error = None;
        let generation = list.generation;
        let query = WorkspaceQuery {
            kind: kind_of(section),
            query: list.query.trim().to_string(),
            view: list.view.clone(),
            source: list.source.clone(),
            more,
        };
        let call = self.rpc.call::<methods::WorkspaceList>(&query);
        let task = cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                let l10n = cx.l10n().clone();
                let list = s.list(section);
                if list.generation != generation {
                    return;
                }
                list.loading = false;
                match result {
                    Ok(page) => {
                        list.items = page.items;
                        list.total = page.total;
                        list.has_more = page.has_more;
                        list.loaded = true;
                    }
                    Err(e) => {
                        log::warn!("workspace.list {}: {e}", section.id());
                        list.error = Some(l10n.desktop_workspace_load_failed());
                    }
                }
                cx.notify();
            });
        });
        self.loads.insert(section, task);
        cx.notify();
    }

    fn refresh_all(&mut self, cx: &mut Context<Self>) {
        self.load_access(cx);
        let loaded: Vec<WorkspaceSection> = self
            .lists
            .iter()
            .filter(|(_, l)| l.loaded)
            .map(|(s, _)| *s)
            .collect();
        for section in loaded {
            self.load(section, false, cx);
        }
    }

    /// `workspace.changed`: the section reloads, and an editor without
    /// edits on the item reads it again (a deleted one closes).
    fn on_changed(
        &mut self,
        kind: WorkspaceKind,
        id: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(section) = section_of(kind) else {
            return;
        };
        if self.lists.get(&section).is_some_and(|l| l.loaded) {
            self.load(section, false, cx);
        }
        if let (Some(id), Some(editor)) = (id, self.editors.get(&section).cloned())
            && editor.item_id(cx).as_deref() == Some(id.as_str())
        {
            editor.reload_if_clean(window, cx);
        }
    }

    /// Typing in the search field: the section searches once it pauses.
    fn search_for(&mut self, query: String, cx: &mut Context<Self>) {
        let section = self.section;
        if self.list(section).query == query {
            return;
        }
        self.list(section).query = query;
        self._search = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                cx.background_executor().timer(SEARCH_DELAY).await;
                let _ = this.update(cx, |s, cx| s.load(section, false, cx));
            }),
        );
    }

    fn on_choice(&mut self, action: &SettingsChoice, window: &mut Window, cx: &mut Context<Self>) {
        let section = self.section;
        match action.menu.as_str() {
            "workspace-view" => {
                self.list(section).view = action.value.clone();
                self.load(section, false, cx);
            }
            "workspace-source" => {
                self.list(section).source = action.value.clone();
                self.load(section, false, cx);
            }
            "workspace-sort" => {
                self.list(section).sort = if action.value == "name" {
                    SortOrder::Name
                } else {
                    SortOrder::Modified
                };
                cx.notify();
            }
            _ => {
                // An editor's pop-up.
                if let Some(editor) = self.editors.get(&section).cloned() {
                    let action = action.clone();
                    match editor {
                        EditorView::Model(e) => {
                            e.update(cx, |e, cx| e.on_choice(&action, window, cx))
                        }
                        EditorView::Knowledge(e) => {
                            e.update(cx, |e, cx| e.on_choice(&action, window, cx))
                        }
                        EditorView::Prompt(e) => {
                            e.update(cx, |e, cx| e.on_choice(&action, window, cx))
                        }
                        EditorView::Tool(e) => {
                            e.update(cx, |e, cx| e.on_choice(&action, window, cx))
                        }
                        EditorView::Skill(e) => {
                            e.update(cx, |e, cx| e.on_choice(&action, window, cx))
                        }
                    }
                }
            }
        }
    }

    // ── Opening items ──────────────────────────────────────────────────

    /// Runs `then` once the section's editor has no edits, asking first
    /// whether to throw them away.
    fn after_discard(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
        then: impl FnOnce(&mut Self, &mut Window, &mut Context<Self>) + 'static,
    ) {
        let dirty = self
            .editors
            .get(&self.section)
            .is_some_and(|e| e.is_dirty(cx));
        if !dirty {
            then(self, window, cx);
            return;
        }
        let l10n = cx.l10n().clone();
        let spec = SheetSpec::new(
            l10n.desktop_discard_changes_title(),
            l10n.desktop_discard_changes_message(),
            l10n.desktop_discard(),
            l10n.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        let handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if ask.await {
                let _ = handle.update(cx, |_, window, cx| {
                    let _ = this.update(cx, |s, cx| then(s, window, cx));
                });
            }
        })
        .detach();
    }

    /// [`Self::after_discard`], for callers outside the pane.
    pub fn after_discard_then(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
        then: impl FnOnce(&mut Self, &mut Window, &mut Context<Self>) + 'static,
    ) {
        self.after_discard(window, cx, then);
    }

    /// Selects item `id` and opens it in the editor (asking about edits).
    pub fn open(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        let section = self.section;
        if self.selected.get(&section) == Some(&id)
            && self
                .editors
                .get(&section)
                .is_some_and(|e| e.item_id(cx).as_deref() == Some(id.as_str()))
        {
            return;
        }
        self.after_discard(window, cx, move |s, window, cx| {
            s.open_now(section, Some(id), window, cx)
        });
    }

    /// New: a blank editor for the section (knowledge asks for a name in a
    /// sheet first).
    pub fn new_item(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let section = self.section;
        if !self.allows(section).manage {
            return;
        }
        if section == WorkspaceSection::Knowledge {
            // The new base opens in place of the one shown: its unsaved
            // edits are asked about first, as for any New.
            self.after_discard(window, cx, |s, window, cx| {
                sheets::new_knowledge(
                    cx.entity().downgrade(),
                    s.stores.clone(),
                    s.rpc.clone(),
                    window,
                    cx,
                )
            });
            return;
        }
        self.after_discard(window, cx, move |s, window, cx| {
            s.open_now(section, None, window, cx)
        });
    }

    /// Opens the editor for `id` (None: a new item) right away.
    pub fn open_now(
        &mut self,
        section: WorkspaceSection,
        id: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match &id {
            Some(id) => {
                self.selected.insert(section, id.clone());
            }
            None => {
                self.selected.remove(&section);
            }
        }
        let stores = self.stores.clone();
        let pane = cx.entity().downgrade();
        let access = self.allows(section);
        let editor =
            match section {
                WorkspaceSection::Models => EditorView::Model(
                    cx.new(|cx| model::ModelEditor::new(stores, pane, id, access, window, cx)),
                ),
                WorkspaceSection::Knowledge => EditorView::Knowledge(cx.new(|cx| {
                    knowledge::KnowledgeEditor::new(stores, pane, id, access, window, cx)
                })),
                WorkspaceSection::Prompts => EditorView::Prompt(
                    cx.new(|cx| prompt::PromptEditor::new(stores, pane, id, access, window, cx)),
                ),
                WorkspaceSection::Tools => EditorView::Tool(
                    cx.new(|cx| tool::ToolEditor::new(stores, pane, id, access, window, cx)),
                ),
                WorkspaceSection::Skills => EditorView::Skill(
                    cx.new(|cx| skill::SkillEditor::new(stores, pane, id, access, window, cx)),
                ),
            };
        let subscription = match &editor {
            EditorView::Model(e) => {
                cx.subscribe_in(e, window, move |this, _, ev: &EditorEvent, window, cx| {
                    this.on_editor(section, ev.clone(), window, cx)
                })
            }
            EditorView::Knowledge(e) => {
                cx.subscribe_in(e, window, move |this, _, ev: &EditorEvent, window, cx| {
                    this.on_editor(section, ev.clone(), window, cx)
                })
            }
            EditorView::Prompt(e) => {
                cx.subscribe_in(e, window, move |this, _, ev: &EditorEvent, window, cx| {
                    this.on_editor(section, ev.clone(), window, cx)
                })
            }
            EditorView::Tool(e) => {
                cx.subscribe_in(e, window, move |this, _, ev: &EditorEvent, window, cx| {
                    this.on_editor(section, ev.clone(), window, cx)
                })
            }
            EditorView::Skill(e) => {
                cx.subscribe_in(e, window, move |this, _, ev: &EditorEvent, window, cx| {
                    this.on_editor(section, ev.clone(), window, cx)
                })
            }
        };
        self.editor_subscriptions.insert(section, subscription);
        self.editors.insert(section, editor);
        cx.notify();
    }

    /// An editor saved, made, duplicated or deleted its item.
    pub fn on_editor(
        &mut self,
        section: WorkspaceSection,
        event: EditorEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match event {
            EditorEvent::Created(id) => {
                self.selected.insert(section, id.clone());
                self.load(section, false, cx);
                // The new item's own editor (it has an id now).
                self.open_now(section, Some(id), window, cx);
            }
            EditorEvent::Saved(id) => {
                self.selected.insert(section, id);
                self.load(section, false, cx);
            }
            EditorEvent::Deleted(id) => {
                if self.selected.get(&section) == Some(&id) {
                    self.selected.remove(&section);
                }
                self.editors.remove(&section);
                self.list(section).items.retain(|i| i.id != id);
                self.load(section, false, cx);
            }
            EditorEvent::Closed => {
                self.editors.remove(&section);
                self.selected.remove(&section);
                cx.notify();
            }
        }
    }

    // ── Commands ───────────────────────────────────────────────────────

    /// Runs a context-menu or More-menu command on item `id`.
    pub fn run(
        &mut self,
        section: WorkspaceSection,
        id: String,
        command: ItemCommand,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let l10n = cx.l10n().clone();
        let name = self
            .lists
            .get(&section)
            .and_then(|l| l.item(&id))
            .map(display_name)
            .unwrap_or_else(|| id.clone());
        match command {
            ItemCommand::Edit => {
                self.show(section, window, cx);
                self.open(id, window, cx);
            }
            ItemCommand::Duplicate => self.duplicate(section, id, window, cx),
            ItemCommand::Export => transfer::export_one(self, section, id, name, window, cx),
            ItemCommand::Share => crate::views::access_sheet::open_for_workspace(
                self.stores.clone(),
                access_kind(section),
                &id,
                name,
                window,
                cx,
            ),
            ItemCommand::Toggle => self.toggle(section, id, cx),
            ItemCommand::Hide => model::toggle_hidden(self, id, cx),
            ItemCommand::Delete => {
                let spec = delete_spec(section, &name, &l10n);
                let ask = present_sheet(window, spec, cx);
                let account = active_account(&self.stores, cx);
                cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                    if ask.await {
                        let _ = this.update(cx, |s, cx| {
                            // Asked under another account: its item is not
                            // this one's to delete.
                            if active_account(&s.stores, cx) == account {
                                s.delete(section, id, cx)
                            }
                        });
                    }
                })
                .detach();
            }
        }
    }

    fn toast(&self, level: NoticeLevel, text: String, cx: &mut App) {
        self.stores
            .toasts
            .update(cx, |t, cx| t.show(level, text, cx));
    }

    /// Switches item `id` on or off.
    pub fn toggle(&mut self, section: WorkspaceSection, id: String, cx: &mut Context<Self>) {
        // At once in the list; the daemon's answer settles it.
        if let Some(item) = self.list(section).items.iter_mut().find(|i| i.id == id)
            && let Some(active) = item.active
        {
            item.active = Some(!active);
        }
        cx.notify();
        let call = self.rpc.call::<methods::WorkspaceToggle>(&WorkspaceRef {
            kind: kind_of(section),
            id: id.clone(),
        });
        let account = active_account(&self.stores, cx);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                // Another account's lists now: nothing of this one's.
                if active_account(&s.stores, cx) != account {
                    return;
                }
                match result {
                    Ok(item) => {
                        if let Some(row) = s.list(section).items.iter_mut().find(|i| i.id == id) {
                            *row = item;
                        }
                    }
                    Err(e) => {
                        log::warn!("workspace.toggle: {e}");
                        let text = cx.l10n().error_message();
                        s.toast(NoticeLevel::Error, text, cx);
                        s.load(section, false, cx);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// Duplicate: the server makes the copy, which opens.
    pub fn duplicate(
        &mut self,
        section: WorkspaceSection,
        id: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let l10n = cx.l10n().clone();
        // The server copies a skill as saved, its files with it: a draft of
        // it is saved or discarded first, as on a phone.
        if section == WorkspaceSection::Skills
            && self
                .editors
                .get(&section)
                .is_some_and(|e| e.item_id(cx).as_deref() == Some(id.as_str()) && e.is_dirty(cx))
        {
            self.toast(
                NoticeLevel::Warning,
                l10n.workspace_skill_clone_save_first(),
                cx,
            );
            return;
        }
        let suffix = match section {
            WorkspaceSection::Models => l10n.desktop_workspace_model_clone_suffix(),
            WorkspaceSection::Prompts => l10n.desktop_workspace_prompt_clone_suffix(),
            WorkspaceSection::Tools => l10n.desktop_workspace_tool_clone_suffix(),
            WorkspaceSection::Skills => l10n.desktop_workspace_skill_clone_suffix(),
            WorkspaceSection::Knowledge => return,
        };
        let call = self
            .rpc
            .call::<methods::WorkspaceDuplicate>(&WorkspaceDuplicate {
                kind: kind_of(section),
                id,
                suffix,
            });
        let handle = window.window_handle();
        let account = active_account(&self.stores, cx);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |s, cx| match result {
                    // Another account's now: its copy is not opened here.
                    _ if active_account(&s.stores, cx) != account => {}
                    Ok(detail) => {
                        let copy = editor::detail_id(&detail);
                        s.load(section, false, cx);
                        if let Some(copy) = copy {
                            s.after_discard(window, cx, move |s, window, cx| {
                                s.open_now(section, Some(copy), window, cx)
                            });
                        }
                    }
                    Err(e) => {
                        log::warn!("workspace.duplicate: {e}");
                        let text = editor::failure_text(&e, &cx.l10n().clone());
                        s.toast(NoticeLevel::Error, text, cx);
                    }
                });
            });
        })
        .detach();
    }

    fn delete(&mut self, section: WorkspaceSection, id: String, cx: &mut Context<Self>) {
        let l10n = cx.l10n().clone();
        let call = self.rpc.call::<methods::WorkspaceDelete>(&WorkspaceRef {
            kind: kind_of(section),
            id: id.clone(),
        });
        let account = active_account(&self.stores, cx);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| match result {
                // Another account's lists now: nothing of this one's.
                _ if active_account(&s.stores, cx) != account => {}
                Ok(_) => {
                    s.toast(NoticeLevel::Success, deleted_text(section, &l10n), cx);
                    if s.editors
                        .get(&section)
                        .is_some_and(|e| e.item_id(cx).as_deref() == Some(id.as_str()))
                    {
                        s.editors.remove(&section);
                    }
                    if s.selected.get(&section) == Some(&id) {
                        s.selected.remove(&section);
                    }
                    s.list(section).items.retain(|i| i.id != id);
                    s.load(section, false, cx);
                }
                Err(e) => {
                    log::warn!("workspace.delete: {e}");
                    s.toast(NoticeLevel::Error, editor::failure_text(&e, &l10n), cx);
                }
            });
        })
        .detach();
    }

    // ── Keyboard ───────────────────────────────────────────────────────

    /// ↑ and ↓ in the list (with the keyboard on the pane, not in a
    /// field): the item above or below opens, as Mail's list shows the
    /// message selected. ⌘⌫ asks to delete the selected item.
    fn on_list_key(
        &mut self,
        e: &gpui_kit::KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.focus.is_focused(window) {
            return false;
        }
        let k = &e.keystroke;
        let m = &k.modifiers;
        let section = self.section;
        let shown = self.list(section).shown();
        let current = self
            .selected
            .get(&section)
            .and_then(|id| shown.iter().position(|i| &i.id == id));
        match k.key.as_str() {
            "up" | "down" if !(m.platform || m.alt || m.control || m.shift) => {
                if shown.is_empty() {
                    return true;
                }
                let next = match (k.key.as_str(), current) {
                    ("down", None) => 0,
                    ("up", None) => shown.len() - 1,
                    ("down", Some(i)) => (i + 1).min(shown.len() - 1),
                    (_, Some(i)) => i.saturating_sub(1),
                    _ => 0,
                };
                if Some(next) != current {
                    let id = shown[next].id.clone();
                    self.scroll
                        .scroll_to_item(next, gpui_kit::ScrollStrategy::Nearest);
                    // The pane has the keyboard, not the row: say which.
                    let name = display_name(&shown[next]);
                    crate::views::a11y::announce_row(&name, next, shown.len(), cx);
                    self.open(id, window, cx);
                }
                true
            }
            "backspace" | "delete" if m.platform && !(m.alt || m.control || m.shift) => {
                if let Some(i) = current
                    && shown[i].write_access
                {
                    let id = shown[i].id.clone();
                    self.run(section, id, ItemCommand::Delete, window, cx);
                }
                true
            }
            _ => false,
        }
    }

    // ── Menus ──────────────────────────────────────────────────────────

    /// The commands an item's menu offers, in order (None: a separator).
    pub fn item_commands(
        &self,
        section: WorkspaceSection,
        item: &WorkspaceItem,
        l: &L10n,
    ) -> Vec<Option<(String, ItemCommand)>> {
        let access = self.allows(section);
        let writable = item.write_access;
        let mut out = vec![Some((l.edit(), ItemCommand::Edit))];
        if access.manage && section != WorkspaceSection::Knowledge {
            out.push(Some((
                l.desktop_workspace_model_clone(),
                ItemCommand::Duplicate,
            )));
        }
        if access.export_items || section == WorkspaceSection::Knowledge {
            out.push(Some((l.desktop_export_ellipsis(), ItemCommand::Export)));
        }
        if access.share && writable {
            out.push(Some((
                l.desktop_share_access_ellipsis(),
                ItemCommand::Share,
            )));
        }
        if writable {
            if let Some(active) = item.active {
                out.push(None);
                out.push(Some((
                    if active {
                        l.desktop_workspace_model_deactivate()
                    } else {
                        l.desktop_workspace_model_activate()
                    },
                    ItemCommand::Toggle,
                )));
            }
            if section == WorkspaceSection::Models {
                if item.active.is_none() {
                    out.push(None);
                }
                out.push(Some((
                    if item.hidden {
                        l.workspace_model_unhide()
                    } else {
                        l.workspace_model_hide()
                    },
                    ItemCommand::Hide,
                )));
            }
            out.push(None);
            out.push(Some((l.desktop_delete_ellipsis(), ItemCommand::Delete)));
        }
        out
    }

    fn context_menu(
        &mut self,
        id: String,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let section = self.section;
        let Some(item) = self.lists.get(&section).and_then(|l| l.item(&id)).cloned() else {
            return;
        };
        let l = cx.l10n().clone();
        // The menu's commands come back along the focus path, through this
        // pane.
        if !self.focus.contains_focused(window, cx) {
            window.focus(&self.focus, cx);
        }
        let mut menu = NativeMenu::new();
        for entry in self.item_commands(section, &item, &l) {
            menu = match entry {
                Some((label, command)) => menu.menu(
                    label,
                    Box::new(WorkspaceMenu {
                        section,
                        id: id.clone(),
                        command,
                    }),
                ),
                None => menu.separator(),
            };
        }
        self.context_target = Some(id);
        cx.notify();
        menu.show(position, window, cx);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            cx.background_executor()
                .timer(Duration::from_millis(300))
                .await;
            let _ = this.update(cx, |s, cx| {
                s.context_target = None;
                cx.notify();
            });
        })
        .detach();
    }

    /// The list header's action menu (Import…, Export All…).
    fn list_menu(&mut self, position: Point<Pixels>, window: &mut Window, cx: &mut Context<Self>) {
        let section = self.section;
        let access = self.allows(section);
        let l = cx.l10n().clone();
        if !self.focus.contains_focused(window, cx) {
            window.focus(&self.focus, cx);
        }
        let entry = |command: ListCommand| -> Box<dyn Action> {
            Box::new(WorkspaceListMenu { section, command })
        };
        let mut menu = NativeMenu::new();
        if section != WorkspaceSection::Knowledge && access.import_items {
            menu = menu.menu(l.desktop_import_ellipsis(), entry(ListCommand::Import));
            if section == WorkspaceSection::Tools && self.access.as_ref().is_some_and(|a| a.admin) {
                menu = menu.menu(
                    l.desktop_workspace_import_from_url(),
                    entry(ListCommand::ImportFromUrl),
                );
            }
        }
        // A Markdown file becomes a new skill to review (a create, as the
        // phone's skill editor offers it).
        if section == WorkspaceSection::Skills && access.manage {
            menu = menu.menu(
                l.desktop_workspace_import_markdown_ellipsis(),
                entry(ListCommand::ImportMarkdown),
            );
        }
        if section != WorkspaceSection::Knowledge && access.export_items {
            menu = menu.menu(
                l.desktop_workspace_export_all_ellipsis(),
                entry(ListCommand::ExportAll),
            );
        }
        if menu.is_empty() {
            return;
        }
        menu.show(position, window, cx);
    }

    fn on_list_menu(&mut self, a: &WorkspaceListMenu, window: &mut Window, cx: &mut Context<Self>) {
        let section = a.section;
        match a.command {
            ListCommand::Import => transfer::import(self, section, window, cx),
            ListCommand::ExportAll => transfer::export_all(self, section, window, cx),
            ListCommand::ImportMarkdown => skill::import_markdown(self, window, cx),
            ListCommand::ImportFromUrl => {
                let pane = cx.entity().downgrade();
                self.after_discard(window, cx, move |s, window, cx| {
                    s.open_now(WorkspaceSection::Tools, None, window, cx);
                    let _ = pane;
                    if let Some(EditorView::Tool(editor)) =
                        s.editors.get(&WorkspaceSection::Tools).cloned()
                    {
                        editor.update(cx, |e, cx| e.import_from_url(window, cx));
                    }
                });
            }
        }
    }
}

/// The account in use, as the accounts list says.
pub(super) fn active_account(stores: &Stores, cx: &App) -> Option<String> {
    stores
        .accounts
        .read(cx)
        .list
        .as_ref()
        .and_then(|l| l.active_account_id.clone())
}

/// The delete question for an item of `section` named `name`.
fn delete_spec(section: WorkspaceSection, name: &str, l: &L10n) -> SheetSpec {
    let (title, message) = match section {
        WorkspaceSection::Models => (
            l.desktop_workspace_model_delete_confirm_title(),
            l.desktop_workspace_model_delete_confirm_message(name),
        ),
        WorkspaceSection::Knowledge => (
            l.desktop_workspace_knowledge_delete_confirm_title(),
            l.desktop_workspace_knowledge_delete_confirm_message(name),
        ),
        WorkspaceSection::Prompts => (
            l.desktop_workspace_prompt_delete_confirm_title(),
            l.desktop_workspace_prompt_delete_confirm_message(name),
        ),
        WorkspaceSection::Tools => (
            l.desktop_workspace_tool_delete_confirm_title(),
            l.desktop_workspace_tool_delete_confirm_message(name),
        ),
        WorkspaceSection::Skills => (
            l.desktop_workspace_skill_delete_confirm_title(),
            l.desktop_workspace_skill_delete_confirm_message(name),
        ),
    };
    SheetSpec::new(title, message, l.delete(), l.cancel()).destructive()
}

/// What a toast says once an item of `section` is gone.
pub fn deleted_text(section: WorkspaceSection, l: &L10n) -> String {
    match section {
        WorkspaceSection::Models => l.desktop_workspace_model_deleted(),
        WorkspaceSection::Knowledge => l.desktop_workspace_knowledge_deleted(),
        WorkspaceSection::Prompts => l.desktop_workspace_prompt_deleted(),
        WorkspaceSection::Tools => l.desktop_workspace_tool_deleted(),
        WorkspaceSection::Skills => l.desktop_workspace_skill_deleted(),
    }
}

// ── Drawing ────────────────────────────────────────────────────────────

impl WorkspacePane {
    fn header(&mut self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let section = self.section;
        let access = self.allows(section);
        let list = self.list(section).clone();
        let field = field_frame(
            self.search.read(cx).focus_handle(cx).is_focused(window),
            t.metrics.control_height,
            cx,
        )
        .child(icon(IconName::Search, 13., r.text_subtle))
        .child(div().flex_1().min_w_0().child(bare_input(
            &self.search,
            l.desktop_search(),
            t.metrics.control,
        )));
        let mut views = vec![
            Choice::new("all", l.desktop_workspace_knowledge_view_all()),
            Choice::new("created", l.workspace_knowledge_view_created()),
            Choice::new("shared", l.workspace_knowledge_view_shared()),
        ];
        if section == WorkspaceSection::Knowledge {
            views.push(Choice::new("", l.workspace_knowledge_source_all()).separated());
        }
        let view = controls::popup(
            "workspace-view",
            &l.desktop_workspace_show(),
            vec![
                Choice::new("all", l.desktop_workspace_knowledge_view_all()),
                Choice::new("created", l.workspace_knowledge_view_created()),
                Choice::new("shared", l.workspace_knowledge_view_shared()),
            ],
            &list.view,
            false,
            window,
            cx,
        );
        let source = (section == WorkspaceSection::Knowledge).then(|| {
            controls::popup(
                "workspace-source",
                &l.desktop_workspace_source(),
                vec![
                    Choice::new("", l.workspace_knowledge_source_all()),
                    Choice::new("local", l.desktop_workspace_knowledge_source_local()),
                    Choice::new("external", l.desktop_workspace_knowledge_source_external()),
                ],
                &list.source,
                false,
                window,
                cx,
            )
        });
        let sort = controls::popup(
            "workspace-sort",
            &l.desktop_workspace_sort_by(),
            vec![
                Choice::new("modified", l.desktop_workspace_sort_modified()),
                Choice::new("name", l.name()),
            ],
            if list.sort == SortOrder::Name {
                "name"
            } else {
                "modified"
            },
            false,
            window,
            cx,
        );
        let view_entity = cx.entity().downgrade();
        let menu_entity = cx.entity().downgrade();
        let new_label = new_label(section, &l);
        let has_list_menu = section != WorkspaceSection::Knowledge
            && (access.import_items
                || access.export_items
                || (section == WorkspaceSection::Skills && access.manage));
        div()
            .flex_none()
            .px(px(12.))
            .pt(px(4.))
            .pb(px(8.))
            .flex()
            .flex_col()
            .gap(px(8.))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .child(div().flex_1().min_w_0().child(field))
                    .when(has_list_menu, |d| {
                        d.child(
                            div().id("workspace-list-menu").child(
                                IconButton::new(
                                    "workspace-list-actions",
                                    IconName::Ellipsis,
                                    l.workspace_editor_more_actions(),
                                )
                                .size(28., 15.)
                                .on_click(Rc::new(
                                    move |e, window, cx| {
                                        let position = e.position();
                                        let _ = menu_entity
                                            .update(cx, |s, cx| s.list_menu(position, window, cx));
                                    },
                                )),
                            ),
                        )
                    })
                    .when(access.manage, |d| {
                        d.child(
                            IconButton::new("workspace-new", IconName::Plus, new_label)
                                .size(28., 15.)
                                .on_click(Rc::new(move |_, window, cx| {
                                    let _ = view_entity.update(cx, |s, cx| s.new_item(window, cx));
                                })),
                        )
                    }),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .flex_wrap()
                    .child(view)
                    .children(source)
                    .child(div().flex_1())
                    .child(sort),
            )
            .into_any_element()
    }

    fn render_rows(
        &mut self,
        range: std::ops::Range<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let section = self.section;
        let list = self.list(section).clone();
        let shown = list.shown();
        let more_row = list.has_more;
        range
            .map(|i| {
                if i < shown.len() {
                    self.row(&shown[i], i, window, cx)
                } else if more_row {
                    self.more_row(&list, cx)
                } else {
                    div().into_any_element()
                }
            })
            .collect()
    }

    fn more_row(&self, list: &SectionList, cx: &mut Context<Self>) -> AnyElement {
        let l = cx.l10n().clone();
        let entity = cx.entity().downgrade();
        let section = self.section;
        div()
            .h(px(ROW_HEIGHT))
            .px(px(12.))
            .flex()
            .items_center()
            .justify_center()
            .child(
                conduit_components::views::kit::Button::new(
                    "workspace-load-more",
                    if list.loading {
                        l.desktop_loading()
                    } else {
                        l.workspace_load_more()
                    },
                )
                .ghost()
                .disabled(list.loading)
                .on_click(Rc::new(move |_, _, cx| {
                    let _ = entity.update(cx, |s, cx| s.load(section, true, cx));
                })),
            )
            .into_any_element()
    }

    fn row(
        &mut self,
        item: &WorkspaceItem,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let section = self.section;
        let selected = self.selected.get(&section) == Some(&item.id);
        let outlined = self.context_target.as_deref() == Some(item.id.as_str());
        let name = display_name(item);
        let mut detail: Vec<String> = vec![];
        if let Some(s) = item.subtitle.as_deref().filter(|s| !s.trim().is_empty()) {
            detail.push(s.lines().next().unwrap_or_default().to_string());
        }
        if section == WorkspaceSection::Tools
            && let Some(n) = item.function_count
        {
            detail.push(l.workspace_tool_function_count(n));
        }
        if !item.write_access {
            detail.push(l.workspace_read_only_badge());
        }
        let detail = detail.join(" · ");
        let mut badges: Vec<(IconName, String)> = vec![];
        if item.public {
            badges.push((IconName::Globe, l.library_access_everyone_on_server()));
        }
        if item.hidden {
            badges.push((IconName::EyeOff, l.desktop_workspace_hidden()));
        }
        if item.external {
            badges.push((
                IconName::Link,
                l.desktop_workspace_knowledge_external_badge(),
            ));
        }
        let open_id = item.id.clone();
        let menu_id = item.id.clone();
        let toggle_id = item.id.clone();
        let entity = cx.entity().downgrade();
        let toggle_entity = entity.clone();
        let fg = r.text;
        let sub = if selected {
            r.selected_text_subtle
        } else {
            r.text_subtle
        };
        let active = item.active;
        let can_toggle = item.write_access && active.is_some();
        let label = SharedString::from(if detail.is_empty() {
            name.clone()
        } else {
            format!("{name}, {detail}")
        });
        div()
            .id(ElementId::NamedInteger(
                "workspace-row".into(),
                index as u64,
            ))
            .role(Role::Row)
            .aria_label(label)
            .aria_selected(selected)
            .h(px(ROW_HEIGHT))
            .px(px(6.))
            .py(px(2.))
            .child(
                div()
                    .size_full()
                    .px(px(8.))
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .rounded(px(7.))
                    .when(selected, |d| d.bg(r.selected))
                    .when(!selected, |d| d.hover(|s| s.bg(r.overlay_hover)))
                    .when(outlined, |d| d.border_2().border_color(r.focus))
                    .child(conduit_components::views::kit::icon_tile(
                        section_icon(section),
                        28.,
                        with_alpha(fg, if t.dark { 0.14 } else { 0.07 }),
                        if active == Some(false) { sub } else { fg },
                        7.,
                    ))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap(px(1.))
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap(px(5.))
                                    .child(
                                        div()
                                            .min_w_0()
                                            .truncate()
                                            .text_size(px(t.metrics.body))
                                            .font_weight(FontWeight::MEDIUM)
                                            .text_color(if active == Some(false) {
                                                sub
                                            } else {
                                                fg
                                            })
                                            .child(name),
                                    )
                                    .children(badges.into_iter().enumerate().map(
                                        |(b, (glyph, tip))| {
                                            div()
                                                .id(ElementId::NamedInteger(
                                                    SharedString::from(format!(
                                                        "workspace-badge-{index}"
                                                    )),
                                                    b as u64,
                                                ))
                                                .flex_none()
                                                .aria_label(SharedString::from(tip.clone()))
                                                .child(icon(glyph, 11., sub))
                                                .tip(tip, None)
                                        },
                                    )),
                            )
                            .when(!detail.is_empty(), |d| {
                                d.child(
                                    div()
                                        .truncate()
                                        .text_size(px(t.metrics.small))
                                        .text_color(sub)
                                        .child(detail),
                                )
                            }),
                    )
                    .when(can_toggle, |d| {
                        let on = active == Some(true);
                        d.child(
                            div()
                                .flex_none()
                                // A click on the switch is not a click on
                                // the row.
                                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                                .child(
                                    Switch::new(
                                        ElementId::NamedInteger(
                                            "workspace-active".into(),
                                            index as u64,
                                        ),
                                        l.desktop_workspace_active(),
                                        on,
                                    )
                                    .on_click(Rc::new(
                                        move |_, _, cx| {
                                            let id = toggle_id.clone();
                                            let _ = toggle_entity
                                                .update(cx, |s, cx| s.toggle(section, id, cx));
                                        },
                                    )),
                                ),
                        )
                    }),
            )
            .on_click({
                let entity = entity.clone();
                move |e, window, cx| {
                    let id = open_id.clone();
                    let _ = entity.update(cx, |s, cx| {
                        if !s.focus.contains_focused(window, cx) {
                            window.focus(&s.focus, cx);
                        }
                        s.open(id, window, cx);
                        let _ = e;
                    });
                }
            })
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(move |this, ev: &MouseDownEvent, window, cx| {
                    cx.stop_propagation();
                    this.context_menu(menu_id.clone(), ev.position, window, cx)
                }),
            )
            .keyboard_list_item(Ring::Inset(7.), window, cx)
            .into_any_element()
    }

    fn list_body(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let section = self.section;
        let list = self.list(section).clone();
        let count = list.items.len() + usize::from(list.has_more);
        if count == 0 {
            let text = if let Some(error) = &list.error {
                error.clone()
            } else if list.loading || !list.loaded {
                l.desktop_loading()
            } else if !list.query.trim().is_empty() {
                l.desktop_workspace_no_matches()
            } else {
                l.workspace_empty()
            };
            let retry = list.error.is_some();
            let entity = cx.entity().downgrade();
            return div()
                .id("workspace-list-empty")
                .role(Role::Status)
                .flex_1()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(px(10.))
                .px(px(24.))
                .text_center()
                .text_size(px(t.metrics.control))
                .text_color(r.text_subtle)
                .child(text.clone())
                // Loading, then what came: said as the phone's gate says it.
                .child(live_text(
                    "live",
                    Some(text.into()),
                    if retry {
                        Priority::High
                    } else {
                        Priority::Medium
                    },
                ))
                .when(retry, |d| {
                    d.child(
                        conduit_components::views::kit::Button::new(
                            "workspace-retry",
                            l.desktop_try_again(),
                        )
                        .on_click(Rc::new(move |_, _, cx| {
                            let _ = entity.update(cx, |s, cx| s.load(section, false, cx));
                        })),
                    )
                })
                .into_any_element();
        }
        let sizes = Rc::new(vec![size(px(LIST_WIDTH), px(ROW_HEIGHT)); count]);
        v_virtual_list(
            cx.entity(),
            "workspace-rows",
            sizes,
            |this, range, window, cx| this.render_rows(range, window, cx),
        )
        .track_scroll(&self.scroll)
        .flex_1()
        .into_any_element()
    }

    fn footer(&self, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let Some(list) = self.current() else {
            return div().into_any_element();
        };
        let count = list.total.max(list.items.len() as i64);
        div()
            .flex_none()
            .h(px(28.))
            .px(px(14.))
            .flex()
            .items_center()
            .border_t_1()
            .border_color(t.roles.divider)
            .text_size(px(t.metrics.small))
            .text_color(t.roles.text_subtle)
            .child(if list.loaded {
                l.desktop_workspace_item_count(count)
            } else {
                String::new()
            })
            .into_any_element()
    }

    fn editor_column(&mut self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        match self.editors.get(&self.section).cloned() {
            Some(editor) => {
                let _ = window;
                div()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .flex()
                    .flex_col()
                    .child(editor.any())
                    .into_any_element()
            }
            None => div()
                .id("workspace-no-selection")
                .role(Role::Status)
                .flex_1()
                .min_w_0()
                .h_full()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(px(8.))
                .pb(px(conduit_components::window::TOOLBAR_HEIGHT))
                .child(icon(section_icon(self.section), 28., r.text_faint))
                .child(
                    div()
                        .text_size(px(t.metrics.control))
                        .text_color(r.text_subtle)
                        .child(l.desktop_workspace_select_item()),
                )
                .into_any_element(),
        }
    }
}

impl Focusable for WorkspacePane {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for WorkspacePane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let section = self.section;
        let header = self.header(window, cx);
        let body = self.list_body(cx);
        let footer = self.footer(cx);
        let editor = self.editor_column(window, cx);
        let focus = self.focus.clone();
        div()
            .id("workspace-pane")
            .key_context("WorkspacePane")
            .track_focus(&self.focus)
            .flex_1()
            .min_h_0()
            .w_full()
            .flex()
            // Any click in the pane brings the keyboard here unless a field
            // inside has it: menus and pop-ups answer along this path.
            .on_mouse_down(MouseButton::Left, move |_, window, cx| {
                if !focus.contains_focused(window, cx) {
                    window.focus(&focus, cx);
                }
            })
            .on_action(
                cx.listener(|this, a: &SettingsChoice, window, cx| this.on_choice(a, window, cx)),
            )
            .on_action(cx.listener(|this, a: &WorkspaceMenu, window, cx| {
                this.run(a.section, a.id.clone(), a.command.clone(), window, cx)
            }))
            .on_key_down(cx.listener(|this, e: &gpui_kit::KeyDownEvent, window, cx| {
                if this.on_list_key(e, window, cx) {
                    cx.stop_propagation();
                }
            }))
            .on_action(cx.listener(|this, a: &WorkspaceListMenu, window, cx| {
                this.on_list_menu(a, window, cx)
            }))
            .child(
                div()
                    .id("workspace-list")
                    .role(Role::List)
                    .aria_label(SharedString::from(crate::views::sidebar::workspace_label(
                        section, &l,
                    )))
                    .w(px(LIST_WIDTH))
                    .flex_none()
                    .h_full()
                    .flex()
                    .flex_col()
                    .border_r_1()
                    .border_color(r.divider)
                    .child(header)
                    .child(body)
                    .child(footer),
            )
            .child(editor)
    }
}

/// Sizes for a list of `n` rows (tests).
pub fn row_sizes(n: usize) -> Vec<Size<Pixels>> {
    vec![size(px(LIST_WIDTH), px(ROW_HEIGHT)); n]
}

/// Whether `toggled` is the state an AccessKit switch reports for `on`.
pub fn toggled(on: bool) -> Toggled {
    if on { Toggled::True } else { Toggled::False }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, name: &str) -> WorkspaceItem {
        WorkspaceItem {
            kind: WorkspaceKind::Prompts,
            id: id.into(),
            name: name.into(),
            subtitle: None,
            owner_name: None,
            write_access: true,
            active: Some(true),
            public: false,
            updated_at_ms: None,
            tags: vec![],
            external: false,
            hidden: false,
            function_count: None,
        }
    }

    #[test]
    fn a_list_sorts_by_name_only_when_asked() {
        let mut list = SectionList {
            items: vec![item("b", "beta"), item("a", "Alpha"), item("c", "")],
            ..Default::default()
        };
        let ids = |l: &SectionList| l.shown().iter().map(|i| i.id.clone()).collect::<Vec<_>>();
        assert_eq!(ids(&list), ["b", "a", "c"], "the server's order");
        list.sort = SortOrder::Name;
        assert_eq!(
            ids(&list),
            ["a", "b", "c"],
            "an unnamed item sorts by its id"
        );
    }

    /// Delete asked, Hide from Selector read and Import chosen under one
    /// account: none of them is done under the account that signs in
    /// before they finish.
    #[gpui_kit::test]
    fn nothing_begun_under_one_account_lands_on_the_next(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::sheet::bench::{bench, switch_account};
        let (daemon, stores, vcx) = bench(cx);
        // Questions answer "yes" (Delete).
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        let file = std::env::temp_dir().join(format!("conduit-import-{}.json", std::process::id()));
        std::fs::write(&file, "[]").unwrap();
        vcx.update(|_, cx| {
            cx.set_global(transfer::TransferHook {
                export_dir: None,
                import_file: Some(file.clone()),
            })
        });
        let pane = vcx.update(|window, cx| {
            let stores = stores.clone();
            cx.new(|cx| WorkspacePane::new(stores, WorkspaceSection::Models, window, cx))
        });
        vcx.run_until_parked();
        daemon.returns::<methods::WorkspaceGet>(super::editor::bench::detail(
            WorkspaceKind::Models,
            serde_json::json!({"id": "trail-guide", "name": "Trail Guide"}),
        ));
        daemon.returns::<methods::WorkspaceDuplicate>(super::editor::bench::detail(
            WorkspaceKind::Models,
            serde_json::json!({"id": "trail-guide-copy", "name": "Trail Guide (Copy)"}),
        ));
        let held = daemon.hold::<methods::WorkspaceGet>();
        let copying = daemon.hold::<methods::WorkspaceDuplicate>();
        vcx.update(|window, cx| {
            pane.update(cx, |p, cx| {
                for command in [
                    ItemCommand::Delete,
                    ItemCommand::Hide,
                    ItemCommand::Duplicate,
                ] {
                    p.run(
                        WorkspaceSection::Models,
                        "trail-guide".into(),
                        command,
                        window,
                        cx,
                    );
                }
                transfer::import(p, WorkspaceSection::Models, window, cx);
            })
        });
        switch_account(&stores, vcx);
        drop(held);
        drop(copying);
        vcx.run_until_parked();
        assert!(
            pane.read_with(vcx, |p, _| p.editors.is_empty()),
            "Avery's copy opened in Blake's workspace"
        );
        assert!(
            daemon.calls::<methods::WorkspaceDelete>().is_empty(),
            "Avery's delete went to Blake's workspace"
        );
        assert!(
            daemon.calls::<methods::WorkspaceSave>().is_empty(),
            "Avery's model was saved under Blake"
        );
        assert!(
            daemon.calls::<methods::WorkspaceImport>().is_empty(),
            "Avery's file was imported under Blake"
        );
        let _ = std::fs::remove_file(&file);
    }

    /// An import or a new knowledge base answered after another account
    /// signed in shows nothing of it in the next account's workspace.
    #[gpui_kit::test]
    fn nothing_answered_for_one_account_shows_in_the_next(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::sheet::bench::{bench, switch_account};
        let (daemon, stores, vcx) = bench(cx);
        let file =
            std::env::temp_dir().join(format!("conduit-import-r2-{}.json", std::process::id()));
        std::fs::write(&file, "[]").unwrap();
        vcx.update(|_, cx| {
            cx.set_global(transfer::TransferHook {
                export_dir: None,
                import_file: Some(file.clone()),
            })
        });
        daemon.returns::<methods::WorkspaceImport>(
            serde_json::from_value(serde_json::json!({
                "imported": 1, "failed": [{"label": "Trail Guide", "reason": ""}]
            }))
            .unwrap(),
        );
        daemon.returns::<methods::WorkspaceSave>(super::editor::bench::detail(
            WorkspaceKind::Knowledge,
            serde_json::json!({"id": "k2", "name": "Ridge notes", "description": "",
                               "fileCount": 0, "external": false}),
        ));
        let pane = vcx.update(|window, cx| {
            let stores = stores.clone();
            cx.new(|cx| WorkspacePane::new(stores, WorkspaceSection::Knowledge, window, cx))
        });
        vcx.run_until_parked();
        let importing = daemon.hold::<methods::WorkspaceImport>();
        let making = daemon.hold::<methods::WorkspaceSave>();
        vcx.update(|window, cx| {
            pane.update(cx, |p, cx| {
                transfer::import(p, WorkspaceSection::Models, window, cx)
            })
        });
        let rpc = stores.connection.read_with(vcx, |c, _| c.rpc());
        vcx.update(|window, cx| {
            sheets::new_knowledge(pane.downgrade(), stores.clone(), rpc, window, cx)
        });
        vcx.run_until_parked();
        let form = vcx
            .update(|_, cx| crate::views::sheet::current::<sheets::FormSheet>(cx))
            .expect("New Knowledge Base opens");
        vcx.update(|window, cx| {
            form.update(cx, |f, cx| {
                f.set_value(0, "Ridge notes", window, cx);
                f.confirm(window, cx);
            })
        });
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::WorkspaceImport>().len(), 1);
        switch_account(&stores, vcx);
        drop(importing);
        drop(making);
        vcx.run_until_parked();
        assert!(
            stores.toasts.read_with(vcx, |t, _| t.toasts.is_empty()),
            "Avery's results showed in Blake's workspace"
        );
        assert!(
            pane.read_with(vcx, |p, _| p.editors.is_empty()),
            "Avery's new knowledge base opened in Blake's workspace"
        );
        let _ = std::fs::remove_file(&file);
    }

    /// New Knowledge Base opens in place of the knowledge base shown: its
    /// unsaved edits are asked about first (the bench keeps editing).
    #[gpui_kit::test]
    fn new_knowledge_base_asks_before_edits_go(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::sheet::bench::bench;
        let (daemon, stores, vcx) = bench(cx);
        let manage = serde_json::json!({"manage": true});
        daemon.returns::<methods::WorkspaceCapabilities>(
            serde_json::from_value(serde_json::json!({
                "models": manage, "knowledge": manage, "prompts": manage,
                "tools": manage, "skills": manage
            }))
            .unwrap(),
        );
        daemon.returns::<methods::WorkspaceGet>(super::editor::bench::detail(
            WorkspaceKind::Knowledge,
            serde_json::json!({"id": "k1", "name": "Trail notes", "description": "",
                               "fileCount": 0, "external": false}),
        ));
        let pane = vcx.update(|window, cx| {
            let stores = stores.clone();
            cx.new(|cx| WorkspacePane::new(stores, WorkspaceSection::Knowledge, window, cx))
        });
        vcx.run_until_parked();
        vcx.update(|window, cx| {
            pane.update(cx, |p, cx| {
                p.open_now(WorkspaceSection::Knowledge, Some("k1".into()), window, cx)
            })
        });
        vcx.run_until_parked();
        let Some(EditorView::Knowledge(editor)) = pane.read_with(vcx, |p, _| {
            p.editors.get(&WorkspaceSection::Knowledge).cloned()
        }) else {
            panic!("the knowledge base opens");
        };
        vcx.update(|window, cx| {
            editor.update(cx, |e, cx| {
                e.set_field("description", "Ridges and passes", window, cx)
            })
        });
        vcx.update(|window, cx| pane.update(cx, |p, cx| p.new_item(window, cx)));
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| crate::views::sheet::current::<sheets::FormSheet>(cx))
                .is_none(),
            "New Knowledge Base went on over unsaved edits without asking"
        );
    }

    #[test]
    fn sections_map_to_kinds_and_back() {
        for section in WorkspaceSection::ALL {
            assert_eq!(section_of(kind_of(section)), Some(section));
        }
        assert_eq!(section_of(WorkspaceKind::Unknown), None);
        assert_eq!(
            access_kind(WorkspaceSection::Tools),
            AccessResourceKind::Tool
        );
    }
}
