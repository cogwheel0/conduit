//! The sidebar's chats: `chats.list` and its paging, the folders' open
//! state and contents, the sync indicator, and sidebar search.
//!
//! * **List.** `chats.list` (and `chats.loadMore`), refetched on
//!   `chats.changed`, after a reconnect or an event gap, and when the
//!   account changes ([`wire`]). Every change the user makes goes through
//!   the daemon (`chats.rename/setPinned/setArchived/delete/move/bulk/
//!   setArchivedVisible`), whose answer is the new list; nothing is patched
//!   locally. Answers that arrive after a newer fetch or change are dropped.
//! * **Folders.** Which folders are open is seeded once per account from
//!   each folder's `expanded` flag (where the account last left it), then
//!   belongs to this window. An open folder's chats come from
//!   `chats.folder`, which reaches past the loaded page.
//! * **Sync.** `sync.get`, then the `sync.status` event.
//! * **Search.** `chats.search`, 200 ms after the last keystroke; re-run
//!   when the list or the sync moves, because the index fills during the
//!   first sync. The previous answer stays up while the next one runs.
//!
//! `chats.tree` is here too ([`ChatListStore::tree`]): the chat view's
//! branch overview asks for it.

use std::collections::{BTreeSet, HashMap};
use std::time::Duration;

use conduit_daemon::{RpcError, RpcMethod};
use conduit_protocol::{
    ArchivedVisibility, BulkChatAction, BulkChats, ChatList, ChatRef, ChatSearchQuery,
    ChatSearchResults, ChatShare, ChatSummary, ChatTree, ChatView, CreateFolder, Event, FolderRef,
    FolderSummary, MoveChat, NoParams, RenameChat, RenameFolder, SetChatFlag, ShownChat, SyncState,
    events, methods,
};
use gpui_kit::{App, AppContext as _, AsyncApp, Context, EventEmitter, Task, WeakEntity};

use super::Stores;
use super::connection::ConnectionEvent;
use super::rpc::Rpc;
use super::session::Route;
use super::toasts::Retry;
use crate::views::sidebar_model::{
    SidebarSections, build_sidebar, folder_path_to, with_folder_contents,
};

/// How long sidebar search waits after the last keystroke.
pub const SEARCH_DEBOUNCE: Duration = Duration::from_millis(200);
/// How many hits sidebar search asks for.
pub const SEARCH_LIMIT: i64 = 50;

/// A chat's read as the app quits ([`ChatListStore::mark_left_on_quit`]).
pub type QuitRead = futures::future::BoxFuture<'static, Result<(), RpcError>>;

/// A change the user asked for, for the failure notice.
#[derive(Clone, Debug, PartialEq)]
pub enum ChatAction {
    Rename,
    Pin,
    Unpin,
    Archive,
    Unarchive,
    Delete,
    Move,
    Bulk(BulkChatAction),
    ShowArchived,
    LoadMore,
    Share,
    NewFolder,
    RenameFolder,
    DeleteFolder,
    /// Mark as Unread (or read, `false`).
    MarkUnread(bool),
    GenerateTitle,
    Export,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ChatListEvent {
    /// A change failed; say so. `retry` sends it again, when the daemon
    /// says that could work (the toast's "Try Again").
    Failed {
        action: ChatAction,
        error: RpcError,
        retry: Option<Retry>,
    },
    /// A bulk change failed for some of the chats.
    PartlyFailed {
        action: BulkChatAction,
        failed: Vec<String>,
    },
}

pub struct ChatListStore {
    /// Chats marked unread here while they were open: leaving them, from
    /// any view, keeps the dot until they are shown again
    /// ([`Self::mark_read`]).
    pub marked_unread_here: std::collections::HashSet<String>,
    /// [`Self::note_answered`].
    answered_here: std::collections::HashSet<String>,
    /// Reads on leaving still on their way for chats answered here, by each
    /// read's number: a failed one leaves its chat to read on the next
    /// leave, unless a later read was sent, the chat was marked unread or
    /// another account came in between.
    answered_reads: HashMap<String, u64>,
    reads_sent: u64,
    rpc: Rpc,
    /// `None` until the daemon has answered once (for this account).
    pub list: Option<ChatList>,
    pub load_error: Option<RpcError>,
    pub loading_more: bool,
    /// The last page request failed: reaching the end does not ask again
    /// (only Load More, or a new list, does).
    pub more_failed: bool,
    /// Open folders; `None` until seeded from the first list with folders.
    expanded: Option<BTreeSet<String>>,
    /// `chats.folder` answers for the open folders.
    folder_contents: HashMap<String, Vec<ChatSummary>>,
    pub sync: Option<SyncState>,
    query: String,
    /// The last search answer, for [`Self::searched`].
    pub results: Option<ChatSearchResults>,
    pub search_error: Option<RpcError>,
    searched: String,
    pub searching: bool,
    /// Bumped whenever anything the sidebar draws from changes.
    revision: u64,
    generation: u64,
    /// Bumped by [`Self::reset`] (another account): answers and Try Again
    /// from before it are dropped.
    account: u64,
    search_generation: u64,
    _fetch: Option<Task<()>>,
    _sync: Option<Task<()>>,
    _search: Option<Task<()>>,
    _more: Option<Task<()>>,
    folder_fetches: HashMap<String, Task<()>>,
}

impl EventEmitter<ChatListEvent> for ChatListStore {}

impl ChatListStore {
    pub fn new(rpc: Rpc) -> Self {
        Self {
            marked_unread_here: Default::default(),
            answered_here: Default::default(),
            answered_reads: Default::default(),
            reads_sent: 0,
            rpc,
            list: None,
            load_error: None,
            loading_more: false,
            more_failed: false,
            expanded: None,
            folder_contents: HashMap::new(),
            sync: None,
            query: String::new(),
            results: None,
            search_error: None,
            searched: String::new(),
            searching: false,
            revision: 0,
            generation: 0,
            account: 0,
            search_generation: 0,
            _fetch: None,
            _sync: None,
            _search: None,
            _more: None,
            folder_fetches: HashMap::new(),
        }
    }

    /// Changes whenever anything the sidebar draws from changes.
    pub fn revision(&self) -> u64 {
        self.revision
    }

    fn changed(&mut self, cx: &mut Context<Self>) {
        self.revision += 1;
        cx.notify();
    }

    /// Forgets everything: another account (or none) is in use.
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.account += 1;
        self.answered_here.clear();
        self.answered_reads.clear();
        self.marked_unread_here.clear();
        self._sync = None;
        self.generation += 1;
        self.search_generation += 1;
        self.list = None;
        self.load_error = None;
        self.loading_more = false;
        self.more_failed = false;
        self.expanded = None;
        self.folder_contents.clear();
        self.folder_fetches.clear();
        self.sync = None;
        self.query.clear();
        self.results = None;
        self.search_error = None;
        self.searched.clear();
        self.searching = false;
        self._fetch = None;
        self._search = None;
        self._more = None;
        self.changed(cx);
    }

    /// Refetches the list (and the open folders' contents).
    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        self.generation += 1;
        let generation = self.generation;
        let call = self.rpc.call::<methods::ChatsList>(&NoParams);
        self._fetch = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                this.update(cx, |s, cx| {
                    if s.generation != generation {
                        return;
                    }
                    match result {
                        Ok(list) => s.adopt(list, cx),
                        Err(e) => {
                            log::warn!("chats.list: {e}");
                            s.load_error = Some(e);
                            s.changed(cx);
                        }
                    }
                })
                .ok();
            }),
        );
    }

    /// `sync.get`.
    pub fn refresh_sync(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::SyncGet>(&NoParams);
        let account = self.account;
        self._sync =
            Some(cx.spawn(
                async move |this: WeakEntity<Self>, cx: &mut AsyncApp| match call.await {
                    Ok(state) => {
                        this.update(cx, |s, cx| {
                            if s.account == account {
                                s.on_sync_status(state, cx)
                            }
                        })
                        .ok();
                    }
                    Err(e) => log::debug!("sync.get: {e}"),
                },
            ));
    }

    /// `sync.status`.
    pub fn on_sync_status(&mut self, state: SyncState, cx: &mut Context<Self>) {
        if self.sync.as_ref() == Some(&state) {
            return;
        }
        let index_moved = self.sync.as_ref().is_none_or(|old| {
            old.running != state.running || old.ever_completed != state.ever_completed
        });
        self.sync = Some(state);
        // The index fills during a sync: a search typed meanwhile looks again.
        if index_moved {
            self.search_again(cx);
        }
        self.changed(cx);
    }

    /// `chats.changed`: the list, the open folders and the search.
    pub fn on_chats_changed(&mut self, cx: &mut Context<Self>) {
        self.refresh(cx);
        self.search_again(cx);
    }

    fn adopt(&mut self, list: ChatList, cx: &mut Context<Self>) {
        self.load_error = None;
        if self.expanded.is_none() && !list.folders.is_empty() {
            self.expanded = Some(
                list.folders
                    .iter()
                    .filter(|f| f.expanded)
                    .map(|f| f.id.clone())
                    .collect(),
            );
        }
        // Contents for the open folders that still exist; drop the rest.
        let open: Vec<String> = self
            .expanded
            .iter()
            .flatten()
            .filter(|id| list.folders.iter().any(|f| &f.id == *id))
            .cloned()
            .collect();
        self.folder_contents.retain(|id, _| open.contains(id));
        self.list = Some(list);
        for id in open {
            self.fetch_folder(id, cx);
        }
        self.changed(cx);
    }

    /// `chats.loadMore`: the next page, appended.
    pub fn load_more(&mut self, cx: &mut Context<Self>) {
        if self.loading_more || !self.list.as_ref().is_some_and(|l| l.has_more) {
            return;
        }
        self.loading_more = true;
        self.more_failed = false;
        self.generation += 1;
        let generation = self.generation;
        let call = self.rpc.call::<methods::ChatsLoadMore>(&NoParams);
        self._more = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                this.update(cx, |s, cx| {
                    s.loading_more = false;
                    match result {
                        Ok(list) if s.generation == generation => s.adopt(list, cx),
                        Ok(_) => s.changed(cx),
                        Err(error) => {
                            // Only this list's page: an older one's failure
                            // never stops the newer list's paging.
                            if s.generation == generation {
                                s.more_failed = true;
                            }
                            cx.emit(ChatListEvent::Failed {
                                action: ChatAction::LoadMore,
                                error,
                                retry: None,
                            });
                            s.changed(cx);
                        }
                    }
                })
                .ok();
            }),
        );
        cx.notify();
    }

    // Folders.

    pub fn is_expanded(&self, folder_id: &str) -> bool {
        self.expanded
            .as_ref()
            .is_some_and(|e| e.contains(folder_id))
    }

    pub fn expanded(&self) -> BTreeSet<String> {
        self.expanded.clone().unwrap_or_default()
    }

    pub fn toggle_folder(&mut self, folder_id: &str, cx: &mut Context<Self>) {
        let expanded = self.expanded.get_or_insert_with(BTreeSet::new);
        if expanded.remove(folder_id) {
            self.folder_contents.remove(folder_id);
            self.folder_fetches.remove(folder_id);
        } else {
            expanded.insert(folder_id.to_string());
            self.fetch_folder(folder_id.to_string(), cx);
        }
        self.changed(cx);
    }

    /// Opens every folder in `ids`, leaving the rest as they are.
    pub fn reveal_folders(&mut self, ids: &[String], cx: &mut Context<Self>) {
        let expanded = self.expanded.get_or_insert_with(BTreeSet::new);
        let new: Vec<String> = ids
            .iter()
            .filter(|id| !expanded.contains(*id))
            .cloned()
            .collect();
        if new.is_empty() {
            return;
        }
        expanded.extend(new.iter().cloned());
        for id in new {
            self.fetch_folder(id, cx);
        }
        self.changed(cx);
    }

    /// Opens the folders around `chat_id`, so the open chat shows as open.
    /// Returns whether anything was opened.
    pub fn reveal_chat(&mut self, chat_id: &str, cx: &mut Context<Self>) -> bool {
        let Some(sections) = self.sections(chrono::Local::now()) else {
            return false;
        };
        match folder_path_to(chat_id, &sections.folders) {
            Some(path) if !path.iter().all(|id| self.is_expanded(id)) => {
                self.reveal_folders(&path, cx);
                true
            }
            _ => false,
        }
    }

    fn fetch_folder(&mut self, folder_id: String, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::ChatsFolder>(&FolderRef {
            folder_id: folder_id.clone(),
        });
        let generation = self.generation;
        let key = folder_id.clone();
        let task = cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            this.update(cx, |s, cx| {
                s.folder_fetches.remove(&folder_id);
                // Another account, or the folder was closed meanwhile.
                if s.generation < generation || !s.is_expanded(&folder_id) {
                    return;
                }
                match result {
                    Ok(contents) => {
                        s.folder_contents.insert(folder_id, contents.chats);
                        s.changed(cx);
                    }
                    Err(e) => log::debug!("chats.folder {folder_id}: {e}"),
                }
            })
            .ok();
        });
        self.folder_fetches.insert(key, task);
    }

    /// Whether `chats.folder` has answered for the open folder `folder_id`.
    pub fn has_folder_contents(&self, folder_id: &str) -> bool {
        self.folder_contents.contains_key(folder_id)
    }

    /// The list with the open folders' contents merged in.
    pub fn merged(&self) -> Option<ChatList> {
        self.list
            .as_ref()
            .map(|l| with_folder_contents(l, &self.folder_contents))
    }

    /// The list sorted into sections, as of `now`.
    pub fn sections<Tz: chrono::TimeZone>(
        &self,
        now: chrono::DateTime<Tz>,
    ) -> Option<SidebarSections> {
        self.merged().map(|l| build_sidebar(&l, &now))
    }

    /// A chat the list (or an open folder) holds.
    pub fn find(&self, chat_id: &str) -> Option<&ChatSummary> {
        self.list
            .iter()
            .flat_map(|l| l.chats.iter())
            .chain(self.folder_contents.values().flatten())
            .find(|c| c.id == chat_id)
    }

    /// The most recently touched chats, newest first, archived ones left
    /// out (the palette's recent list).
    pub fn recent(&self, n: usize) -> Vec<ChatSummary> {
        let mut chats: Vec<ChatSummary> = self
            .list
            .iter()
            .flat_map(|l| l.chats.iter())
            .filter(|c| !c.archived)
            .cloned()
            .collect();
        chats.sort_by_key(|c| std::cmp::Reverse(c.updated_at_ms));
        chats.truncate(n);
        chats
    }

    // Search.

    pub fn query(&self) -> &str {
        &self.query
    }

    /// Sets the query and the query answered, without searching.
    #[cfg(test)]
    pub fn set_query_for_test(&mut self, searched: &str, query: &str) {
        self.searched = searched.into();
        self.query = query.into();
    }

    /// The query whose answer [`Self::results`] holds.
    pub fn searched(&self) -> &str {
        &self.searched
    }

    /// Whether the sidebar shows search results rather than the list.
    pub fn is_searching(&self) -> bool {
        !self.query.trim().is_empty()
    }

    /// Sets the search text; searches [`SEARCH_DEBOUNCE`] after the last
    /// change. An empty query shows the list again at once.
    pub fn set_query(&mut self, query: impl Into<String>, cx: &mut Context<Self>) {
        let query = query.into();
        if query == self.query {
            return;
        }
        self.query = query;
        self.search_generation += 1;
        let trimmed = self.query.trim().to_string();
        if trimmed.is_empty() {
            self._search = None;
            self.results = None;
            self.search_error = None;
            self.searched.clear();
            self.searching = false;
        } else {
            self.searching = true;
            self._search = Some(self.spawn_search(trimmed, Some(SEARCH_DEBOUNCE), cx));
        }
        self.changed(cx);
    }

    fn search_again(&mut self, cx: &mut Context<Self>) {
        let trimmed = self.query.trim().to_string();
        if trimmed.is_empty() {
            return;
        }
        self.search_generation += 1;
        self._search = Some(self.spawn_search(trimmed, None, cx));
    }

    fn spawn_search(
        &mut self,
        query: String,
        delay: Option<Duration>,
        cx: &mut Context<Self>,
    ) -> Task<()> {
        let generation = self.search_generation;
        let rpc = self.rpc.clone();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if let Some(delay) = delay {
                cx.background_executor().timer(delay).await;
            }
            let result = rpc
                .call::<methods::ChatsSearch>(&ChatSearchQuery {
                    query: query.clone(),
                    limit: SEARCH_LIMIT,
                })
                .await;
            this.update(cx, |s, cx| {
                if s.search_generation != generation {
                    return;
                }
                s.searching = false;
                match result {
                    Ok(results) => {
                        s.results = Some(results);
                        s.search_error = None;
                        s.searched = query;
                    }
                    Err(e) => {
                        log::warn!("chats.search: {e}");
                        s.search_error = Some(e);
                    }
                }
                s.changed(cx);
            })
            .ok();
        })
    }

    // Changes.

    fn mutate<M>(
        &mut self,
        params: &M::Params,
        action: ChatAction,
        cx: &mut Context<Self>,
    ) -> Task<Result<(), RpcError>>
    where
        M: RpcMethod<Result = ChatList> + 'static,
        M::Params: Clone + 'static,
    {
        let call = self.rpc.call::<M>(params);
        let again = params.clone();
        let account = self.account;
        self.generation += 1;
        let generation = self.generation;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            this.update(cx, |s, cx| match &result {
                // Another account since: nothing of this one's to show.
                _ if s.account != account => {}
                Ok(list) if s.generation == generation => s.adopt(list.clone(), cx),
                Ok(_) => {}
                Err(error) => {
                    log::warn!("{}: {error}", M::NAME);
                    // The same request again, if it could go through now,
                    // and only for the account it was made in.
                    let retry = error.retryable.then(|| {
                        let store = cx.weak_entity();
                        let action = action.clone();
                        Retry::new(move |cx: &mut App| {
                            let _ = store.update(cx, |s, cx| {
                                if s.account == account {
                                    s.mutate::<M>(&again, action.clone(), cx).detach()
                                }
                            });
                        })
                    });
                    cx.emit(ChatListEvent::Failed {
                        action,
                        error: error.clone(),
                        retry,
                    });
                    // Whatever happened, show what the daemon has now.
                    s.refresh(cx);
                }
            })
            .ok();
            result.map(|_| ())
        })
    }

    pub fn rename(
        &mut self,
        id: &str,
        title: &str,
        cx: &mut Context<Self>,
    ) -> Task<Result<(), RpcError>> {
        self.mutate::<methods::ChatsRename>(
            &RenameChat {
                id: id.into(),
                title: title.trim().into(),
            },
            ChatAction::Rename,
            cx,
        )
    }

    pub fn set_pinned(
        &mut self,
        id: &str,
        pinned: bool,
        cx: &mut Context<Self>,
    ) -> Task<Result<(), RpcError>> {
        self.mutate::<methods::ChatsSetPinned>(
            &SetChatFlag {
                id: id.into(),
                value: pinned,
            },
            if pinned {
                ChatAction::Pin
            } else {
                ChatAction::Unpin
            },
            cx,
        )
    }

    pub fn set_archived(
        &mut self,
        id: &str,
        archived: bool,
        cx: &mut Context<Self>,
    ) -> Task<Result<(), RpcError>> {
        self.mutate::<methods::ChatsSetArchived>(
            &SetChatFlag {
                id: id.into(),
                value: archived,
            },
            if archived {
                ChatAction::Archive
            } else {
                ChatAction::Unarchive
            },
            cx,
        )
    }

    pub fn delete(&mut self, id: &str, cx: &mut Context<Self>) -> Task<Result<(), RpcError>> {
        self.mutate::<methods::ChatsDelete>(&ChatRef { id: id.into() }, ChatAction::Delete, cx)
    }

    /// Files `id` in `folder_id`, or takes it out of any folder (`None`).
    pub fn move_to(
        &mut self,
        id: &str,
        folder_id: Option<&str>,
        cx: &mut Context<Self>,
    ) -> Task<Result<(), RpcError>> {
        self.mutate::<methods::ChatsMove>(
            &MoveChat {
                chat_id: id.into(),
                folder_id: folder_id.map(Into::into),
            },
            ChatAction::Move,
            cx,
        )
    }

    pub fn set_archived_visible(
        &mut self,
        visible: bool,
        cx: &mut Context<Self>,
    ) -> Task<Result<(), RpcError>> {
        self.mutate::<methods::ChatsSetArchivedVisible>(
            &ArchivedVisibility { visible },
            ChatAction::ShowArchived,
            cx,
        )
    }

    /// `chats.bulk`; resolves with the ids it failed for.
    pub fn bulk(
        &mut self,
        ids: Vec<String>,
        action: BulkChatAction,
        folder_id: Option<String>,
        cx: &mut Context<Self>,
    ) -> Task<Result<Vec<String>, RpcError>> {
        let call = self.rpc.call::<methods::ChatsBulk>(&BulkChats {
            chat_ids: ids,
            action,
            folder_id,
        });
        self.generation += 1;
        let generation = self.generation;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            this.update(cx, |s, cx| match &result {
                Ok(done) => {
                    if s.generation == generation {
                        s.adopt(done.list.clone(), cx);
                    }
                    if !done.failed.is_empty() {
                        cx.emit(ChatListEvent::PartlyFailed {
                            action,
                            failed: done.failed.clone(),
                        });
                    }
                }
                Err(error) => {
                    cx.emit(ChatListEvent::Failed {
                        action: ChatAction::Bulk(action),
                        error: error.clone(),
                        retry: None,
                    });
                    s.refresh(cx);
                }
            })
            .ok();
            result.map(|r| r.failed)
        })
    }

    // Folders.

    /// A folder of the list, by id.
    pub fn folder(&self, folder_id: &str) -> Option<&FolderSummary> {
        self.list
            .iter()
            .flat_map(|l| l.folders.iter())
            .find(|f| f.id == folder_id)
    }

    /// Whether the account can make folders (an Open WebUI server with the
    /// feature on).
    pub fn folders_enabled(&self) -> bool {
        self.list.as_ref().is_some_and(|l| l.folders_enabled)
    }

    /// `folders.create`: `name` at the top level, or in `parent_id` (which
    /// opens, so the new folder shows). Resolves with the folder made.
    pub fn create_folder(
        &mut self,
        name: &str,
        parent_id: Option<&str>,
        cx: &mut Context<Self>,
    ) -> Task<Result<FolderSummary, RpcError>> {
        let call = self.rpc.call::<methods::FoldersCreate>(&CreateFolder {
            name: name.trim().into(),
            parent_id: parent_id.map(Into::into),
        });
        if let Some(parent) = parent_id {
            self.reveal_folders(&[parent.to_string()], cx);
        }
        self.generation += 1;
        let generation = self.generation;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            this.update(cx, |s, cx| match &result {
                Ok(made) if s.generation == generation => s.adopt(made.list.clone(), cx),
                Ok(_) => {}
                Err(error) => {
                    log::warn!("folders.create: {error}");
                    cx.emit(ChatListEvent::Failed {
                        action: ChatAction::NewFolder,
                        error: error.clone(),
                        retry: None,
                    });
                    s.refresh(cx);
                }
            })
            .ok();
            result.map(|made| made.folder)
        })
    }

    /// `folders.rename`.
    pub fn rename_folder(
        &mut self,
        folder_id: &str,
        name: &str,
        cx: &mut Context<Self>,
    ) -> Task<Result<(), RpcError>> {
        self.mutate::<methods::FoldersRename>(
            &RenameFolder {
                id: folder_id.into(),
                name: name.trim().into(),
            },
            ChatAction::RenameFolder,
            cx,
        )
    }

    /// `folders.delete`: the folder and its subfolders; their chats stay,
    /// out of any folder.
    pub fn delete_folder(
        &mut self,
        folder_id: &str,
        cx: &mut Context<Self>,
    ) -> Task<Result<(), RpcError>> {
        let was_open = self
            .expanded
            .as_mut()
            .is_some_and(|expanded| expanded.remove(folder_id));
        let task = self.mutate::<methods::FoldersDelete>(
            &FolderRef {
                folder_id: folder_id.into(),
            },
            ChatAction::DeleteFolder,
            cx,
        );
        // A refused delete leaves the folder open as it was, in the account
        // it was deleted in.
        let folder = folder_id.to_string();
        let account = self.account;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = task.await;
            if result.is_err() && was_open {
                let _ = this.update(cx, |s, cx| {
                    if s.account != account {
                        return;
                    }
                    if let Some(expanded) = s.expanded.as_mut() {
                        expanded.insert(folder);
                    }
                    s.changed(cx);
                });
            }
            result
        })
    }

    /// `chats.share`: makes or updates the link (`publish`), or reads it,
    /// and sets who may open it when `audience` is given.
    pub fn share(
        &mut self,
        id: &str,
        publish: bool,
        audience: Option<conduit_protocol::ShareAudience>,
        cx: &mut Context<Self>,
    ) -> Task<Result<ChatShare, RpcError>> {
        let call = self
            .rpc
            .call::<methods::ChatsShare>(&conduit_protocol::ShareChat {
                id: id.into(),
                publish,
                audience,
            });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            if let Err(error) = &result {
                this.update(cx, |_, cx| {
                    cx.emit(ChatListEvent::Failed {
                        action: ChatAction::Share,
                        error: error.clone(),
                        retry: None,
                    })
                })
                .ok();
            }
            result
        })
    }

    /// `id`'s answer is running in a window. The list holds its dot back
    /// while it answers, so until it is read, leaving it reads it whatever
    /// the list shows.
    pub fn note_answered(&mut self, id: &str) {
        if !self.answered_here.contains(id) {
            self.answered_here.insert(id.into());
        }
    }

    /// Leaving a chat reads it (what arrived while it was open), when it
    /// may not be read already ([`Self::reads_on_leaving`]). Nobody asked
    /// for this read: the dot goes at once, and a failure shows nothing but
    /// asks for the list again, which brings back what the daemon holds; a
    /// chat answered here stays to read on the next leave.
    pub fn mark_left(&mut self, id: &str, cx: &mut Context<Self>) {
        let answered = self.answered_here.contains(id);
        if !self.reads_on_leaving(id) {
            return;
        }
        if let Some(list) = &mut self.list
            && let Some(chat) = list.chats.iter_mut().find(|c| c.id == id)
            && chat.unread
        {
            chat.unread = false;
            self.changed(cx);
        }
        self.reads_sent += 1;
        let read = self.reads_sent;
        if answered {
            self.answered_reads.insert(id.into(), read);
        } else {
            self.answered_reads.remove(id);
        }
        let call = self.read_call(id);
        let id = id.to_string();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            this.update(cx, |s, cx| {
                let ours = s.answered_reads.get(&id) == Some(&read);
                if ours {
                    s.answered_reads.remove(&id);
                }
                if let Err(error) = result {
                    log::warn!("a chat left could not be read: {error}");
                    if ours {
                        s.answered_here.insert(id);
                    }
                    s.refresh(cx);
                }
            })
            .ok();
        })
        .detach();
    }

    /// [`Self::mark_left`] as the app quits: the daemon's answer, which the
    /// quit waits for before it stops the daemon.
    pub fn mark_left_on_quit(&mut self, id: &str) -> Option<QuitRead> {
        self.reads_on_leaving(id).then(|| self.read_call(id))
    }

    /// Whether leaving `id` reads it: listed with a dot, not listed yet
    /// (just made, or older and opened from search), or answered in a
    /// window since it was last read. Never one marked unread here, nor a
    /// chat kept only on this device's daemon (`local:`), which has no read
    /// state.
    fn reads_on_leaving(&mut self, id: &str) -> bool {
        let answered = self.answered_here.remove(id);
        if self.marked_unread_here.contains(id) || id.starts_with("local:") {
            return false;
        }
        answered || self.find(id).is_none_or(|c| c.unread)
    }

    fn read_call(&self, id: &str) -> QuitRead {
        let call = self
            .rpc
            .call::<methods::ChatsMarkUnread>(&conduit_protocol::MarkUnread {
                chat_id: id.into(),
                unread: false,
            });
        Box::pin(async move { call.await.map(|_| ()) })
    }

    /// `chats.unshare`: deletes the chat's link.
    pub fn unshare(
        &mut self,
        id: &str,
        cx: &mut Context<Self>,
    ) -> Task<Result<ChatShare, RpcError>> {
        let call = self
            .rpc
            .call::<methods::ChatsUnshare>(&ChatRef { id: id.into() });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            if let Err(error) = &result {
                this.update(cx, |_, cx| {
                    cx.emit(ChatListEvent::Failed {
                        action: ChatAction::Share,
                        error: error.clone(),
                        retry: None,
                    })
                })
                .ok();
            }
            result
        })
    }

    /// Marks `id` unread (a dot in the sidebar), or read again.
    pub fn mark_unread(
        &mut self,
        id: &str,
        unread: bool,
        cx: &mut Context<Self>,
    ) -> Task<Result<(), RpcError>> {
        self.answered_reads.remove(id);
        // The dot follows at once; the list the daemon answers with confirms.
        if let Some(list) = &mut self.list
            && let Some(chat) = list.chats.iter_mut().find(|c| c.id == id)
            && chat.unread != unread
        {
            chat.unread = unread;
            self.changed(cx);
        }
        self.mutate::<methods::ChatsMarkUnread>(
            &conduit_protocol::MarkUnread {
                chat_id: id.into(),
                unread,
            },
            ChatAction::MarkUnread(unread),
            cx,
        )
    }

    /// Opening `id`, or showing it again, reads it: its dot goes, here and
    /// on the server, and a mark of unread made here before ends. Nothing
    /// is asked of the daemon for a chat that has no dot.
    pub fn mark_read(&mut self, id: &str, cx: &mut Context<Self>) {
        self.marked_unread_here.remove(id);
        if self.find(id).is_some_and(|c| c.unread) {
            self.mark_unread(id, false, cx).detach();
        }
    }

    /// Generate Title: the server's model titles the chat.
    pub fn generate_title(
        &mut self,
        id: &str,
        cx: &mut Context<Self>,
    ) -> Task<Result<conduit_protocol::GeneratedTitle, RpcError>> {
        let call = self
            .rpc
            .call::<methods::ChatsGenerateTitle>(&ChatRef { id: id.into() });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            this.update(cx, |s, cx| match &result {
                Ok(_) => s.refresh(cx),
                Err(error) => log::warn!("chats.generateTitle: {error}"),
            })
            .ok();
            result
        })
    }

    /// Export: the chat as a file to save, read from its stored copy.
    pub fn export(
        &self,
        id: &str,
        format: conduit_protocol::ChatExportFormat,
        cx: &App,
    ) -> Task<Result<conduit_protocol::ChatExportFile, RpcError>> {
        let call = self
            .rpc
            .call::<methods::ChatsExport>(&conduit_protocol::ExportChat {
                chat_id: id.into(),
                format,
            });
        cx.background_spawn(call)
    }

    /// `chats.tree`: every branch of a chat (the chat view's overview).
    pub fn tree(&self, chat_id: &str, cx: &App) -> Task<Result<ChatTree, RpcError>> {
        let call = self
            .rpc
            .call::<methods::ChatsTree>(&ChatRef { id: chat_id.into() });
        cx.background_executor().spawn(call)
    }
}

/// What the list is scoped to: the account in use, and whether the window
/// shows the main frame.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Scope {
    pub account: Option<String>,
    pub main: bool,
}

/// What a scope change asks of the list and the navigation.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScopeChange {
    /// Forget the list and the selection: another account.
    pub reset: bool,
    /// Fetch the list and the sync state.
    pub refresh: bool,
}

/// What a view has told the daemon it shows on screen (`chats.setShown`),
/// so each change of that chat's stored copy is read while it shows.
pub struct ShownReport {
    view: ChatView,
    /// The chat last sent (`Some(None)`: none). `None` once the daemon
    /// refused it: the next report is sent whatever it holds.
    sent: Option<Option<String>>,
    /// Counts the reports sent, so only a refusal of the last one counts.
    sends: u64,
}

impl ShownReport {
    /// A view whose daemon knows of no chat it shows.
    pub fn new(view: ChatView) -> Self {
        Self {
            view,
            sent: Some(None),
            sends: 0,
        }
    }

    /// A new daemon session knows of no chat on screen.
    pub fn reconnected(&mut self) {
        self.sent = Some(None);
        self.sends += 1;
    }

    /// Tells the daemon the view shows `shown`, unless it was the last chat
    /// told. `of` finds this report in the view, for the daemon's answer.
    pub fn report<V: 'static>(
        &mut self,
        shown: Option<String>,
        rpc: &Rpc,
        cx: &mut Context<V>,
        of: fn(&mut V) -> &mut ShownReport,
    ) {
        if self.sent.as_ref() == Some(&shown) {
            return;
        }
        self.sent = Some(shown.clone());
        self.sends += 1;
        let send = self.sends;
        let call = rpc.call::<methods::ChatsSetShown>(&ShownChat {
            view: self.view,
            chat_id: shown,
        });
        cx.spawn(async move |this: WeakEntity<V>, cx: &mut AsyncApp| {
            if let Err(e) = call.await {
                log::warn!("chats.setShown: {e}");
                this.update(cx, |view, _| {
                    let report = of(view);
                    if report.sends == send {
                        report.sent = None;
                    }
                })
                .ok();
            }
        })
        .detach();
    }
}

/// The change between the scope last seen and `next`.
pub fn scope_change(last: Option<&Scope>, next: &Scope) -> ScopeChange {
    let Some(last) = last else {
        return ScopeChange {
            reset: false,
            refresh: next.main,
        };
    };
    let reset = last.account != next.account;
    ScopeChange {
        reset,
        refresh: next.main && (reset || !last.main),
    }
}

/// Wires the list to the daemon's events and to account and route changes.
pub fn wire(stores: &Stores, cx: &mut App) {
    stores.connection.update(cx, |c, _| {
        c.subscribe(
            "chat-list",
            &[events::CHATS_CHANGED, events::SYNC_STATUS],
            vec![],
        )
    });
    let main = |stores: &Stores, cx: &App| stores.session.read(cx).route(cx) == Route::Main;
    {
        let s = stores.clone();
        cx.subscribe(&stores.connection, move |_, event, cx| match event {
            ConnectionEvent::Connected { .. } | ConnectionEvent::Gap if main(&s, cx) => {
                s.chat_list.update(cx, |c, cx| {
                    c.refresh(cx);
                    c.refresh_sync(cx);
                });
            }
            ConnectionEvent::Daemon(event) => match event.as_ref() {
                Event::ChatsChanged(_) if main(&s, cx) => {
                    s.chat_list.update(cx, |c, cx| c.on_chats_changed(cx))
                }
                Event::SyncStatus(state) => {
                    let state = state.clone();
                    s.chat_list.update(cx, |c, cx| c.on_sync_status(state, cx));
                }
                _ => {}
            },
            _ => {}
        })
        .detach();
    }
    let last: std::rc::Rc<std::cell::RefCell<Option<Scope>>> = Default::default();
    let check = {
        let s = stores.clone();
        move |cx: &mut App| {
            let next = Scope {
                account: s.accounts.read(cx).scope_key(),
                main: main(&s, cx),
            };
            let change = scope_change(last.borrow().as_ref(), &next);
            *last.borrow_mut() = Some(next);
            if change.reset {
                s.navigation.update(cx, |n, cx| n.reset(cx));
                s.chat_list.update(cx, |c, cx| c.reset(cx));
            }
            if change.refresh {
                s.chat_list.update(cx, |c, cx| {
                    c.refresh(cx);
                    c.refresh_sync(cx);
                });
            }
        }
    };
    let check = std::rc::Rc::new(check);
    {
        let check = check.clone();
        cx.observe(&stores.session, move |_, cx| check(cx)).detach();
    }
    cx.observe(&stores.accounts, move |_, cx| check(cx))
        .detach();
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use conduit_protocol::{BulkChatsResult, ChatSearchHit, FolderContents, FolderSummary};
    use gpui_kit::{Entity, TestAppContext};
    use serde_json::json;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    fn chat(id: &str, folder: Option<&str>) -> ChatSummary {
        ChatSummary {
            unread: false,
            read_only: false,
            id: id.into(),
            title: format!("Chat {id}"),
            updated_at_ms: 1_000,
            pinned: false,
            archived: false,
            folder_id: folder.map(Into::into),
            model: None,
            tags: vec![],
            shared: false,
            menu: Default::default(),
        }
    }

    fn list(chats: Vec<ChatSummary>, folders: Vec<FolderSummary>) -> ChatList {
        ChatList {
            chats,
            has_more: false,
            archived_count: 0,
            archived_visible: false,
            folders,
            folders_enabled: true,
        }
    }

    fn folder(id: &str, expanded: bool) -> FolderSummary {
        FolderSummary {
            id: id.into(),
            name: id.to_uppercase(),
            parent_id: None,
            expanded,
            shared: false,
            owner_name: None,
            can_write: true,
            icon: None,
        }
    }

    fn events(
        store: &Entity<ChatListStore>,
        cx: &mut TestAppContext,
    ) -> Rc<RefCell<Vec<ChatListEvent>>> {
        let seen = Rc::new(RefCell::new(vec![]));
        cx.update(|cx| {
            let seen = seen.clone();
            cx.subscribe(store, move |_, e: &ChatListEvent, _| {
                seen.borrow_mut().push(e.clone())
            })
            .detach();
        });
        seen
    }

    #[gpui_kit::test]
    fn folders_open_as_the_account_left_them_and_load_past_the_page(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsList>(list(
            vec![chat("a", Some("work"))],
            vec![folder("work", true), folder("home", false)],
        ));
        daemon.on::<methods::ChatsFolder>(|p| {
            let id = p["folderId"].as_str().unwrap().to_string();
            Ok(serde_json::to_value(FolderContents {
                folder: folder(&id, true),
                chats: vec![chat("a", Some(&id)), chat(&format!("{id}-2"), Some(&id))],
            })
            .unwrap())
        });
        let store = cx.new(|_| ChatListStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.is_expanded("work"));
            assert!(!s.is_expanded("home"));
            let ids: Vec<String> = s
                .merged()
                .unwrap()
                .chats
                .into_iter()
                .map(|c| c.id)
                .collect();
            assert_eq!(ids, ["a", "work-2"]);
        });
        assert_eq!(
            daemon.calls::<methods::ChatsFolder>(),
            vec![json!({"folderId": "work"})]
        );

        // Seeded once: a later list does not reopen what the user closed.
        store.update(cx, |s, cx| s.toggle_folder("work", cx));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(!s.is_expanded("work"));
            assert_eq!(s.merged().unwrap().chats.len(), 1);
        });

        store.update(cx, |s, cx| s.toggle_folder("home", cx));
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::ChatsFolder>().len(), 2);
        store.read_with(cx, |s, _| assert!(s.is_expanded("home")));

        // Another account starts over.
        store.update(cx, |s, cx| s.reset(cx));
        store.read_with(cx, |s, _| {
            assert!(s.list.is_none());
            assert!(!s.is_expanded("home"));
        });
    }

    #[gpui_kit::test]
    fn search_waits_for_typing_to_pause(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.on::<methods::ChatsSearch>(|p| {
            Ok(json!({
                "hits": [{"chatId": "c1", "title": p["query"], "updatedAtMs": 5}],
                "complete": true,
            }))
        });
        let store = cx.new(|_| ChatListStore::new(daemon.rpc()));
        for q in ["s", "st", "sta"] {
            store.update(cx, |s, cx| s.set_query(q, cx));
            cx.executor().advance_clock(Duration::from_millis(100));
            cx.run_until_parked();
        }
        assert!(daemon.calls::<methods::ChatsSearch>().is_empty());
        store.read_with(cx, |s, _| assert!(s.searching && s.is_searching()));
        cx.executor().advance_clock(SEARCH_DEBOUNCE);
        cx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::ChatsSearch>(),
            vec![json!({"query": "sta", "limit": SEARCH_LIMIT})]
        );
        store.read_with(cx, |s, _| {
            assert!(!s.searching);
            assert_eq!(s.searched(), "sta");
            assert_eq!(
                s.results.as_ref().unwrap().hits,
                vec![ChatSearchHit {
                    chat_id: "c1".into(),
                    title: "sta".into(),
                    snippet: None,
                    updated_at_ms: 5,
                }]
            );
        });

        // A list change looks again at once; the old answer stays up.
        daemon.returns::<methods::ChatsList>(list(vec![], vec![]));
        store.update(cx, |s, cx| s.on_chats_changed(cx));
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::ChatsSearch>().len(), 2);

        // Clearing the field shows the list again, without a call.
        store.update(cx, |s, cx| s.set_query("  ", cx));
        cx.executor().advance_clock(SEARCH_DEBOUNCE);
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::ChatsSearch>().len(), 2);
        store.read_with(cx, |s, _| {
            assert!(!s.is_searching());
            assert!(s.results.is_none());
        });
    }

    #[gpui_kit::test]
    fn changes_go_through_the_daemon_and_adopt_its_list(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let renamed = list(vec![chat("a", None)], vec![]);
        daemon.returns::<methods::ChatsRename>(renamed.clone());
        daemon.returns::<methods::ChatsSetPinned>(renamed.clone());
        daemon.returns::<methods::ChatsSetArchived>(renamed.clone());
        daemon.returns::<methods::ChatsDelete>(list(vec![], vec![]));
        daemon.returns::<methods::ChatsMove>(renamed.clone());
        daemon.returns::<methods::ChatsSetArchivedVisible>(renamed.clone());
        daemon.returns::<methods::ChatsBulk>(BulkChatsResult {
            list: renamed.clone(),
            failed: vec!["b".into()],
        });
        let store = cx.new(|_| ChatListStore::new(daemon.rpc()));
        let seen = events(&store, cx);

        store
            .update(cx, |s, cx| s.rename("a", "  New title ", cx))
            .detach();
        store
            .update(cx, |s, cx| s.set_pinned("a", true, cx))
            .detach();
        store
            .update(cx, |s, cx| s.set_archived("a", false, cx))
            .detach();
        store
            .update(cx, |s, cx| s.move_to("a", Some("f"), cx))
            .detach();
        store.update(cx, |s, cx| s.move_to("a", None, cx)).detach();
        store
            .update(cx, |s, cx| s.set_archived_visible(true, cx))
            .detach();
        store
            .update(cx, |s, cx| {
                s.bulk(
                    vec!["a".into(), "b".into()],
                    BulkChatAction::Archive,
                    None,
                    cx,
                )
            })
            .detach();
        cx.run_until_parked();
        store.read_with(cx, |s, _| assert_eq!(s.list.as_ref(), Some(&renamed)));
        let delete = store.update(cx, |s, cx| s.delete("a", cx));
        cx.run_until_parked();
        cx.foreground_executor().block_test(delete).unwrap();
        store.read_with(cx, |s, _| {
            assert!(s.list.as_ref().unwrap().chats.is_empty())
        });

        assert_eq!(
            daemon.calls::<methods::ChatsRename>(),
            vec![json!({"id": "a", "title": "New title"})]
        );
        assert_eq!(
            daemon.calls::<methods::ChatsSetPinned>(),
            vec![json!({"id": "a", "value": true})]
        );
        assert_eq!(
            daemon.calls::<methods::ChatsMove>(),
            vec![
                json!({"chatId": "a", "folderId": "f"}),
                json!({"chatId": "a"})
            ]
        );
        assert_eq!(
            daemon.calls::<methods::ChatsSetArchivedVisible>(),
            vec![json!({"visible": true})]
        );
        assert_eq!(
            daemon.calls::<methods::ChatsBulk>(),
            vec![json!({"chatIds": ["a", "b"], "action": "archive"})]
        );
        assert_eq!(
            daemon.calls::<methods::ChatsDelete>(),
            vec![json!({"id": "a"})]
        );
        assert_eq!(
            seen.borrow().as_slice(),
            &[ChatListEvent::PartlyFailed {
                action: BulkChatAction::Archive,
                failed: vec!["b".into()],
            }]
        );
    }

    /// Leaving a chat whose answer ran in a window reads it even while
    /// this list shows it without a dot: the list holds the dot back while
    /// a chat answers, and may not have caught up since. A chat marked
    /// unread while it was open keeps its dot.
    #[gpui_kit::test]
    fn leaving_a_chat_that_answered_here_reads_it_unless_marked_unread(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let listed = list(vec![chat("a", None), chat("b", None)], vec![]);
        daemon.returns::<methods::ChatsList>(listed.clone());
        daemon.returns::<methods::ChatsMarkUnread>(listed);
        let store = cx.new(|_| ChatListStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();

        store.update(cx, |s, cx| {
            s.note_answered("a");
            s.mark_left("a", cx)
        });
        cx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::ChatsMarkUnread>(),
            vec![json!({"chatId": "a", "unread": false})],
            "leaving the chat did not read it"
        );

        store.update(cx, |s, cx| {
            s.note_answered("b");
            s.marked_unread_here.insert("b".into());
            s.mark_left("b", cx)
        });
        cx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::ChatsMarkUnread>().len(),
            1,
            "a chat marked unread while it was open was read on leaving"
        );
    }

    /// Leaving reads a chat only when it may not be read: listed with a
    /// dot, or not listed yet (one just made, an older one opened from
    /// search). Leaving one the list shows read asks nothing of the daemon.
    #[gpui_kit::test]
    fn leaving_reads_only_a_chat_not_known_to_be_read(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let dotted = ChatSummary {
            unread: true,
            ..chat("b", None)
        };
        let listed = list(vec![chat("a", None), dotted], vec![]);
        daemon.returns::<methods::ChatsList>(listed.clone());
        daemon.returns::<methods::ChatsMarkUnread>(listed);
        let store = cx.new(|_| ChatListStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();

        store.update(cx, |s, cx| s.mark_left("a", cx));
        cx.run_until_parked();
        assert!(
            daemon.calls::<methods::ChatsMarkUnread>().is_empty(),
            "leaving a read chat asked the daemon"
        );
        assert_eq!(daemon.calls::<methods::ChatsList>().len(), 1);

        store.update(cx, |s, cx| {
            s.mark_left("b", cx);
            s.mark_left("from-search", cx);
        });
        cx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::ChatsMarkUnread>(),
            vec![
                json!({"chatId": "b", "unread": false}),
                json!({"chatId": "from-search", "unread": false}),
            ]
        );
    }

    /// The read leaving a chat sends is nobody's request: a failure shows
    /// no notice, but brings the daemon's list back, and a list on its way
    /// is still taken. A chat answered here stays to read on the next leave.
    #[gpui_kit::test]
    fn a_read_on_leaving_shows_no_failure_and_drops_no_list(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let dotted = |id: &str| ChatSummary {
            unread: true,
            ..chat(id, None)
        };
        let first = list(vec![dotted("a"), dotted("b")], vec![]);
        daemon.returns::<methods::ChatsList>(first.clone());
        daemon.once::<methods::ChatsMarkUnread>(Err(conduit_daemon::protocol::error(
            "rpc.internal",
            "disk full",
        )));
        daemon.returns::<methods::ChatsMarkUnread>(first);
        let store = cx.new(|_| ChatListStore::new(daemon.rpc()));
        let seen = events(&store, cx);
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();

        store.update(cx, |s, cx| s.mark_left("a", cx));
        cx.run_until_parked();
        assert!(
            seen.borrow().is_empty(),
            "a failed read on leaving was shown"
        );
        // The daemon stored nothing: the list is asked again, and the chat
        // keeps its dot.
        assert_eq!(daemon.calls::<methods::ChatsList>().len(), 2);
        assert!(
            store.read_with(cx, |s, _| s.find("a").is_some_and(|c| c.unread)),
            "a failed read on leaving left the chat shown read"
        );

        let newer = list(
            vec![chat("a", None), chat("b", None), chat("c", None)],
            vec![],
        );
        daemon.returns::<methods::ChatsList>(newer.clone());
        let held = daemon.hold::<methods::ChatsList>();
        store.update(cx, |s, cx| {
            s.refresh(cx);
            s.mark_left("b", cx);
        });
        cx.run_until_parked();
        drop(held);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(
                s.list.as_ref(),
                Some(&newer),
                "the list on its way was dropped"
            )
        });

        // A chat with no dot while its answer runs here: a failed read
        // leaves it to read on the next leave.
        daemon.once::<methods::ChatsMarkUnread>(Err(conduit_daemon::protocol::error(
            "rpc.internal",
            "disk full",
        )));
        store.update(cx, |s, cx| {
            s.note_answered("c");
            s.mark_left("c", cx);
        });
        cx.run_until_parked();
        store.update(cx, |s, cx| s.mark_left("c", cx));
        cx.run_until_parked();
        let reads_of_c = daemon
            .calls::<methods::ChatsMarkUnread>()
            .iter()
            .filter(|call| call["chatId"] == "c")
            .count();
        assert_eq!(
            reads_of_c, 2,
            "the next leave did not read a chat whose read failed"
        );

        // Opened again while the list shows it read, it sends no read of its
        // own: the held one failing still leaves it to the next leave.
        daemon.once::<methods::ChatsMarkUnread>(Err(conduit_daemon::protocol::error(
            "rpc.internal",
            "disk full",
        )));
        let held = daemon.hold::<methods::ChatsMarkUnread>();
        store.update(cx, |s, cx| {
            s.note_answered("c");
            s.mark_left("c", cx);
            s.mark_read("c", cx);
        });
        cx.run_until_parked();
        drop(held);
        cx.run_until_parked();
        store.update(cx, |s, cx| s.mark_left("c", cx));
        cx.run_until_parked();
        let reads_of_c = daemon
            .calls::<methods::ChatsMarkUnread>()
            .iter()
            .filter(|call| call["chatId"] == "c")
            .count();
        assert_eq!(
            reads_of_c, 4,
            "a chat opened again lost the read its failed leave owed"
        );
    }

    /// A mark of unread made here holds for every view that shows the
    /// chat (the main window and Quick Ask): no leaving reads it until the
    /// chat is shown again.
    #[gpui_kit::test]
    fn a_mark_of_unread_holds_for_every_view_that_leaves(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let dotted = ChatSummary {
            unread: true,
            ..chat("a", None)
        };
        let listed = list(vec![dotted], vec![]);
        daemon.returns::<methods::ChatsList>(listed.clone());
        daemon.returns::<methods::ChatsMarkUnread>(listed);
        let store = cx.new(|_| ChatListStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();

        store.update(cx, |s, cx| {
            s.marked_unread_here.insert("a".into());
            s.mark_left("a", cx);
        });
        cx.run_until_parked();
        assert!(
            store.update(cx, |s, _| s.mark_left_on_quit("a")).is_none(),
            "the second view to leave read a chat marked unread"
        );
        assert!(daemon.calls::<methods::ChatsMarkUnread>().is_empty());

        // Shown again: read as an opened chat is.
        store.update(cx, |s, cx| s.mark_read("a", cx));
        cx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::ChatsMarkUnread>(),
            vec![json!({"chatId": "a", "unread": false})]
        );
    }

    #[gpui_kit::test]
    fn a_failed_change_is_reported_and_the_list_refetched(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.once::<methods::ChatsRename>(Err(conduit_daemon::protocol::error(
            "rpc.internal",
            "boom",
        )));
        daemon.returns::<methods::ChatsList>(list(vec![chat("a", None)], vec![]));
        let store = cx.new(|_| ChatListStore::new(daemon.rpc()));
        let seen = events(&store, cx);
        let task = store.update(cx, |s, cx| s.rename("a", "x", cx));
        cx.run_until_parked();
        assert!(cx.foreground_executor().block_test(task).is_err());
        assert!(matches!(
            seen.borrow().as_slice(),
            [ChatListEvent::Failed {
                action: ChatAction::Rename,
                ..
            }]
        ));
        assert_eq!(daemon.calls::<methods::ChatsList>().len(), 1);
        store.read_with(cx, |s, _| {
            assert_eq!(s.list.as_ref().unwrap().chats.len(), 1)
        });
    }

    #[gpui_kit::test]
    fn a_failed_page_is_not_asked_for_again_until_the_user_does(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let mut first = list(vec![chat("a", None)], vec![]);
        first.has_more = true;
        daemon.returns::<methods::ChatsList>(first);
        daemon.once::<methods::ChatsLoadMore>(Err(conduit_daemon::protocol::error(
            "net.offline",
            "offline",
        )));
        let store = cx.new(|_| ChatListStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        store.update(cx, |s, cx| s.load_more(cx));
        cx.run_until_parked();
        assert!(store.read_with(cx, |s, _| s.more_failed && !s.loading_more));

        // A page that fails after a newer list came does not stop its paging.
        let held = daemon.hold::<methods::ChatsLoadMore>();
        daemon.once::<methods::ChatsLoadMore>(Err(conduit_daemon::protocol::error(
            "net.offline",
            "offline",
        )));
        store.update(cx, |s, cx| s.load_more(cx));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        held.release();
        cx.run_until_parked();
        assert!(store.read_with(cx, |s, _| !s.more_failed));
    }

    #[gpui_kit::test]
    fn a_refused_folder_delete_leaves_it_open(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsList>(list(vec![], vec![folder("f1", true)]));
        daemon.on::<methods::ChatsFolder>(|_| Ok(json!({"chats": []})));
        daemon.once::<methods::FoldersDelete>(Err(conduit_daemon::protocol::error(
            "rpc.internal",
            "no",
        )));
        let store = cx.new(|_| ChatListStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        assert!(store.read_with(cx, |s, _| s.expanded().contains("f1")));
        let task = store.update(cx, |s, cx| s.delete_folder("f1", cx));
        cx.run_until_parked();
        assert!(cx.foreground_executor().block_test(task).is_err());
        assert!(store.read_with(cx, |s, _| s.expanded().contains("f1")));

        // Refused after another account's list came: that list is left alone.
        let held = daemon.hold::<methods::FoldersDelete>();
        daemon.once::<methods::FoldersDelete>(Err(conduit_daemon::protocol::error(
            "rpc.internal",
            "no",
        )));
        let task = store.update(cx, |s, cx| s.delete_folder("f1", cx));
        store.update(cx, |s, cx| {
            s.reset(cx);
            s.refresh(cx);
        });
        cx.run_until_parked();
        store.update(cx, |s, cx| s.toggle_folder("f1", cx));
        let open_after_reset = store.read_with(cx, |s, _| s.expanded().contains("f1"));
        held.release();
        cx.run_until_parked();
        assert!(cx.foreground_executor().block_test(task).is_err());
        assert_eq!(
            store.read_with(cx, |s, _| s.expanded().contains("f1")),
            open_after_reset
        );
    }

    #[gpui_kit::test]
    fn try_again_never_reaches_another_account(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.once::<methods::ChatsDelete>(Err({
            use conduit_daemon::protocol::RpcErrorExt as _;
            conduit_daemon::protocol::error("rpc.timeout", "slow").retryable()
        }));
        daemon.returns::<methods::ChatsList>(list(vec![chat("a", None)], vec![]));
        daemon.returns::<methods::SyncGet>(SyncState {
            running: true,
            progress: Some(0.5),
            ever_completed: false,
            last_error: None,
            online: true,
        });
        let store = cx.new(|_| ChatListStore::new(daemon.rpc()));
        let seen = events(&store, cx);
        let task = store.update(cx, |s, cx| s.delete("a", cx));
        cx.run_until_parked();
        let _ = cx.foreground_executor().block_test(task);
        let retry = match seen.borrow().as_slice() {
            [ChatListEvent::Failed { retry: Some(r), .. }] => r.clone(),
            other => panic!("{other:?}"),
        };
        // Another account, and its sidebar, before Try Again is pressed; a
        // sync answer for the last one arrives late.
        let held = daemon.hold::<methods::SyncGet>();
        store.update(cx, |s, cx| {
            s.refresh_sync(cx);
            s.reset(cx);
        });
        held.release();
        cx.update(|cx| (retry.0)(cx));
        cx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::ChatsDelete>().len(),
            1,
            "not sent again"
        );
        store.read_with(cx, |s, _| assert!(s.sync.is_none(), "{:?}", s.sync));
    }

    #[gpui_kit::test]
    fn load_more_appends_and_sync_follows_the_event(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let mut first = list(vec![chat("a", None)], vec![]);
        first.has_more = true;
        daemon.returns::<methods::ChatsList>(first);
        daemon.returns::<methods::ChatsLoadMore>(list(
            vec![chat("a", None), chat("b", None)],
            vec![],
        ));
        daemon.returns::<methods::SyncGet>(SyncState {
            running: true,
            progress: Some(0.25),
            ever_completed: false,
            last_error: None,
            online: true,
        });
        let store = cx.new(|_| ChatListStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.refresh(cx);
            s.refresh_sync(cx);
        });
        cx.run_until_parked();
        store.update(cx, |s, cx| {
            s.load_more(cx);
            // A second press while the first runs does nothing.
            s.load_more(cx);
        });
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::ChatsLoadMore>().len(), 1);
        store.read_with(cx, |s, _| {
            assert_eq!(s.list.as_ref().unwrap().chats.len(), 2);
            assert!(!s.list.as_ref().unwrap().has_more);
            assert_eq!(s.sync.as_ref().unwrap().progress, Some(0.25));
            assert_eq!(s.recent(1)[0].id, "a");
        });
        store.update(cx, |s, cx| {
            s.on_sync_status(
                SyncState {
                    running: false,
                    progress: None,
                    ever_completed: true,
                    last_error: None,
                    online: true,
                },
                cx,
            )
        });
        store.read_with(cx, |s, _| assert!(s.sync.as_ref().unwrap().ever_completed));
    }

    #[test]
    fn scope_changes_reset_on_another_account_and_refresh_on_the_main_frame() {
        let scope = |account: Option<&str>, main| Scope {
            account: account.map(Into::into),
            main,
        };
        // First look: fetch when the main frame shows.
        assert_eq!(
            scope_change(None, &scope(Some("a"), true)),
            ScopeChange {
                reset: false,
                refresh: true
            }
        );
        assert_eq!(
            scope_change(None, &scope(None, false)),
            ScopeChange::default()
        );
        // Signing in reaches the main frame.
        assert_eq!(
            scope_change(Some(&scope(Some("a"), false)), &scope(Some("a"), true)),
            ScopeChange {
                reset: false,
                refresh: true
            }
        );
        // Nothing moved.
        assert_eq!(
            scope_change(Some(&scope(Some("a"), true)), &scope(Some("a"), true)),
            ScopeChange::default()
        );
        // Another account: forget, then fetch.
        assert_eq!(
            scope_change(Some(&scope(Some("a"), true)), &scope(Some("b"), true)),
            ScopeChange {
                reset: true,
                refresh: true
            }
        );
        // Signed out of the last one.
        assert_eq!(
            scope_change(Some(&scope(Some("a"), true)), &scope(None, false)),
            ScopeChange {
                reset: true,
                refresh: false
            }
        );
    }
}
