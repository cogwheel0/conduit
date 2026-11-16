//! A channel's pane, as the phone's channel page (`channel_page.dart`)
//! with a Mac's chrome: the timeline, who is typing, the composer, and the
//! thread beside it.
//!
//! * **Toolbar:** the channel's title in the pane's toolbar; Members (with
//!   the count) and More: Notifications (All Messages, Mentions Only),
//!   Edit Channel…, Leave Channel…, Delete Channel…, as the user may.
//! * **Timeline** ([`timeline`]): grouped messages with markdown, files,
//!   app cards, reactions, threads and pins; hover actions and a native
//!   context menu; an own message edits in place.
//! * **Composer:** the chat's composer in its channel mode (`@` mentions of
//!   the channel's members and of models, + for files and pictures), with
//!   "Replying to …" above it and who is typing over that.
//! * **Thread** (a message's replies) opens beside the timeline, with its
//!   own composer, as the phone's tablet layout.
//! * **Reactions** come from a picker of common emoji under the pointer.
//! * The daemon is told which channel is in front of the user (the pane
//!   shown in the key window), so its messages are read as they come and
//!   neither count as unread nor notify (`channels.focus`).
//!
//! Sheets: [`form`] (New Channel, Edit Channel), [`members`].

pub mod apps;
pub mod form;
pub mod members;
pub mod model;
pub mod timeline;

use std::collections::HashMap;
use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{ConduitTheme, with_alpha};
use conduit_components::views::kit::{IconButton, overlay_shadow};
use conduit_components::views::shell::toolbar_capsule;
use conduit_protocol::{
    ChannelAppReplyDto, ChannelFileDto, ChannelKind, ChannelMute, ChannelRef, ChannelSummary,
    NoticeLevel, methods,
};
use gpui_kit::component::input::InputEvent;
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::prelude::*;
use gpui_kit::{
    Action, AnyElement, App, ClipboardItem, Context, ElementId, Entity, FocusHandle, Focusable,
    FontWeight, Pixels, Point, Role, SharedString, Subscription, Window, anchored, deferred, div,
    px,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::channel::{
    CHANNEL_EVENTS, ChannelStore, ChannelStoreEvent, Failure, Subscribe, scope,
};
use crate::stores::composer::{ComposerPrefs, ComposerStore, OneShot};
use crate::stores::connection::ConnectionEvent;
use crate::stores::navigation::{Area, AreaItem};
use crate::views::chat::composer::{ChatComposer, ChatComposerEvent};
use crate::views::chat_pane::daemon_uploader;
use timeline::{ChannelTimeline, Source};

/// The reactions the picker offers: the phone's six first, then more of
/// the common ones.
pub const REACTIONS: [&str; 24] = [
    "👍", "❤️", "😂", "🎉", "🤔", "👀", "🙏", "🔥", "✅", "👏", "😮", "😢", "🚀", "💯", "🙌", "😄",
    "👎", "🤝", "⭐", "💡", "☕", "🌱", "🎯", "😅",
];
/// Picker columns.
const PICKER_COLUMNS: usize = 8;
/// The thread's width beside the timeline.
pub const THREAD_WIDTH: f32 = 360.;

/// What a channel's menu does (the sidebar's row, the pane's More).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChannelCommand {
    MarkRead,
    Notify { muted: bool },
    Edit,
    Leave,
    Delete,
    Members,
}

/// A channel menu's item: `command` on `channel_id`.
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit_channels, no_json)]
pub struct ChannelMenu {
    pub channel_id: String,
    pub command: ChannelCommand,
}

/// File › New Channel… and the sidebar's +.
#[derive(Clone, Debug, PartialEq, Default, Action)]
#[action(namespace = conduit_channels, no_json)]
pub struct NewChannel;

/// What a message's context menu does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MessageCommand {
    AddReaction,
    Reply,
    Thread,
    Pin(bool),
    Edit,
    Copy,
    Delete,
}

/// A message menu's item.
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit_channels, no_json)]
pub struct MessageMenu {
    pub message_id: String,
    pub command: MessageCommand,
    /// Where the menu opened, for the reaction picker.
    pub position: Point<Pixels>,
}

/// The reaction picker, open under the pointer.
#[derive(Clone, Debug)]
struct Picker {
    message_id: String,
    position: Point<Pixels>,
    highlighted: usize,
}

pub struct ChannelPane {
    stores: Stores,
    pub channel_id: String,
    pub store: Entity<ChannelStore>,
    pub timeline: Entity<ChannelTimeline>,
    pub thread: Option<Entity<ChannelTimeline>>,
    composer_store: Entity<ComposerStore>,
    pub composer: Entity<ChatComposer>,
    thread_store: Entity<ComposerStore>,
    pub thread_composer: Entity<ChatComposer>,
    /// The thread the thread composer holds words for, and the words (with
    /// what they would send) left in the other threads opened here.
    thread_parent: Option<String>,
    thread_drafts: HashMap<String, (String, OneShot)>,
    picker: Option<Picker>,
    picker_focus: FocusHandle,
    pub unavailable: bool,
    /// What the daemon was last told about this channel being in front.
    in_front: Option<bool>,
    _subscriptions: Vec<Subscription>,
}

impl ChannelPane {
    pub fn new(
        stores: Stores,
        channel_id: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let rpc = stores.connection.read(cx).rpc();
        let subscribe: Subscribe = {
            let connection = stores.connection.clone();
            Rc::new(move |id: Option<&str>, cx: &mut App| {
                let scopes: Vec<String> = id.into_iter().map(scope).collect();
                connection.update(cx, |c, _| c.subscribe("channel", CHANNEL_EVENTS, scopes));
            })
        };
        let store = {
            let id = channel_id.clone();
            let rpc = rpc.clone();
            cx.new(|cx| ChannelStore::new(rpc, subscribe, id, cx))
        };
        let pane = cx.entity().downgrade();
        let timeline = {
            let (store, pane) = (store.clone(), pane.clone());
            cx.new(|cx| ChannelTimeline::new(store, pane, Source::Channel, cx))
        };
        let prefs = ComposerPrefs::from_settings(stores.app_settings.read(cx).settings());
        let make_store = |cx: &mut Context<Self>| {
            let store = cx.new(|_| {
                ComposerStore::new(rpc.clone(), Some(daemon_uploader()))
                    .for_channel(channel_id.clone())
            });
            store.update(cx, |c, cx| {
                c.set_prefs(prefs.clone(), cx);
                c.refresh_models(cx);
            });
            store
        };
        let composer_store = make_store(cx);
        let thread_store = make_store(cx);
        let make_composer =
            |store: &Entity<ComposerStore>, window: &mut Window, cx: &mut Context<Self>| {
                cx.new(|cx| {
                    let mut c = ChatComposer::new(store.clone(), window, cx);
                    c.channel_mode = true;
                    c.inline_model = false;
                    c.compare_ui = false;
                    c.new_chat = false;
                    c
                })
            };
        let composer = make_composer(&composer_store, window, cx);
        let thread_composer = make_composer(&thread_store, window, cx);
        let mut subscriptions = vec![
            cx.subscribe(&store, |this, _, e: &ChannelStoreEvent, cx| {
                this.on_store_event(e, cx)
            }),
            cx.observe_in(&store, window, |this, _, window, cx| {
                this.sync_store(window, cx)
            }),
            cx.subscribe_in(
                &composer,
                window,
                |this, _, e: &ChatComposerEvent, window, cx| this.on_composer(e, false, window, cx),
            ),
            cx.subscribe_in(
                &thread_composer,
                window,
                |this, _, e: &ChatComposerEvent, window, cx| this.on_composer(e, true, window, cx),
            ),
            cx.subscribe(&stores.connection, |this, _, e: &ConnectionEvent, cx| {
                this.on_connection(e, cx)
            }),
            cx.observe_window_activation(window, |this, window, cx| this.report_front(window, cx)),
            // The picker's keys, ahead of the window's own bindings (Esc is
            // Stop Generating there), as the composer takes its menu's.
            cx.intercept_keystrokes({
                let weak = pane.clone();
                move |event, window, cx| {
                    let Some(this) = weak.upgrade() else {
                        return;
                    };
                    if this.read(cx).picker.is_none() || event.keystroke.modifiers.modified() {
                        return;
                    }
                    let key = event.keystroke.key.clone();
                    let handled = this.update(cx, |p, cx| p.picker_key(&key, window, cx));
                    if handled {
                        cx.stop_propagation();
                    }
                }
            }),
        ];
        for c in [&composer, &thread_composer] {
            let input = c.read(cx).input.clone();
            subscriptions.push(cx.subscribe(&input, |this, input, e: &InputEvent, cx| {
                if let InputEvent::Change = e {
                    let has_text = !input.read(cx).value().trim().is_empty();
                    this.store.update(cx, |s, cx| s.typed(has_text, cx));
                }
            }));
        }
        let mut this = Self {
            stores,
            channel_id,
            store,
            timeline,
            thread: None,
            composer_store,
            composer,
            thread_store,
            thread_composer,
            thread_parent: None,
            thread_drafts: HashMap::new(),
            picker: None,
            picker_focus: cx.focus_handle(),
            unavailable: false,
            in_front: None,
            _subscriptions: subscriptions,
        };
        this.sync_placeholder(window, cx);
        this.report_front(window, cx);
        this
    }

    /// The pane goes (another item, another account): the window stops
    /// listening, and the channel is no longer in front.
    pub fn close(&mut self, cx: &mut Context<Self>) {
        self.store.update(cx, |s, cx| s.close(cx));
        if self.in_front == Some(true) {
            let rpc = self.stores.connection.read(cx).rpc();
            crate::stores::channel::focus(&rpc, None, cx);
        }
        self.in_front = Some(false);
    }

    /// The channel as `channels.open` had it, with what the list has
    /// learned since (a member count after a change, the notification
    /// setting, a new name).
    pub fn summary(&self, cx: &App) -> Option<ChannelSummary> {
        let listed = self
            .stores
            .areas
            .read(cx)
            .channel(&self.channel_id)
            .cloned();
        let opened = self
            .store
            .read(cx)
            .details
            .as_ref()
            .map(|d| d.channel.clone());
        match (opened, listed) {
            (Some(mut c), Some(l)) => {
                c.name = l.name;
                c.description = l.description;
                c.muted = l.muted;
                if !l.title.trim().is_empty() {
                    c.title = l.title;
                }
                c.user_count = l.user_count.or(c.user_count);
                Some(c)
            }
            (opened, listed) => opened.or(listed),
        }
    }

    /// The channel's title, as its toolbar says it.
    pub fn title(&self, cx: &App) -> Option<String> {
        self.summary(cx).map(|c| display_title(&c, cx.l10n()))
    }

    /// What `/files` takes as the server: the active account's id.
    pub fn server_id(&self, cx: &App) -> Option<String> {
        self.stores
            .accounts
            .read(cx)
            .active()
            .map(|a| a.connection.id.clone())
    }

    /// Tells the daemon whether this channel is in front of the user.
    fn report_front(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let front = window.is_window_active() && !self.unavailable;
        if self.in_front == Some(front) {
            return;
        }
        self.in_front = Some(front);
        let rpc = self.stores.connection.read(cx).rpc();
        crate::stores::channel::focus(&rpc, front.then(|| self.channel_id.clone()), cx);
    }

    fn on_connection(&mut self, event: &ConnectionEvent, cx: &mut Context<Self>) {
        match event {
            ConnectionEvent::Connected { .. } | ConnectionEvent::Gap => {
                self.store.update(cx, |s, cx| s.on_reconnected(cx));
                if matches!(event, ConnectionEvent::Connected { .. }) {
                    // A new daemon session forgets what was in front.
                    self.in_front = None;
                }
            }
            ConnectionEvent::Daemon(event) => {
                self.store.update(cx, |s, cx| s.on_event(event, cx));
            }
            ConnectionEvent::LocalDataReset { .. } => {}
        }
    }

    fn on_store_event(&mut self, event: &ChannelStoreEvent, cx: &mut Context<Self>) {
        let l = cx.l10n().clone();
        match event {
            ChannelStoreEvent::Unavailable => {
                self.unavailable = true;
                cx.notify();
            }
            ChannelStoreEvent::Posted => {
                self.timeline.update(cx, |t, cx| t.jump_to_latest(cx));
            }
            ChannelStoreEvent::Failed(failure) => {
                let text = match failure {
                    Failure::Send => l.desktop_channel_send_failed(),
                    Failure::Edit => l.desktop_channel_edit_failed(),
                    Failure::Delete => l.desktop_channel_delete_failed(),
                    Failure::React => l.desktop_channel_react_failed(),
                    Failure::Pin => l.desktop_channel_pin_failed(),
                    Failure::LoadOlder => l.desktop_channel_older_failed(),
                    Failure::AppAction { detail, .. } => detail
                        .clone()
                        .unwrap_or_else(|| l.channel_app_error_fallback()),
                };
                self.toast(NoticeLevel::Error, text, cx);
            }
        }
    }

    /// The thread view follows the store's open thread.
    fn sync_store(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let parent = self
            .store
            .read(cx)
            .thread
            .as_ref()
            .map(|t| t.parent_id.clone());
        self.swap_thread_draft(parent.clone(), window, cx);
        let shown = self.thread.as_ref().map(|t| t.read(cx).source.clone());
        match (parent, shown) {
            (Some(p), Some(Source::Thread(q))) if p == q => {}
            (Some(p), _) => {
                let (store, pane) = (self.store.clone(), cx.entity().downgrade());
                self.thread =
                    Some(cx.new(|cx| ChannelTimeline::new(store, pane, Source::Thread(p), cx)));
            }
            (None, Some(_)) => self.thread = None,
            (None, None) => {}
        }
        cx.notify();
    }

    /// Another thread (or none) is open: the thread composer's words stay
    /// with the thread they were typed for, and that thread's come back.
    fn swap_thread_draft(
        &mut self,
        parent: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.thread_parent == parent {
            return;
        }
        let text = self.thread_composer.read(cx).text(cx);
        let mentions = self.thread_composer.read(cx).mentions(cx);
        let used = self.thread_store.update(cx, |c, cx| c.take_draft(cx));
        if let Some(left) = self.thread_parent.take()
            && (!text.trim().is_empty() || !used.attachments.is_empty())
        {
            self.thread_drafts
                .insert(left, (text, used.with_mentions(mentions)));
        }
        self.thread_composer
            .update(cx, |c, cx| c.set_text("", window, cx));
        if let Some((text, used)) = parent.as_ref().and_then(|p| self.thread_drafts.remove(p)) {
            self.put_thread_draft(text, used, window, cx);
        }
        self.thread_parent = parent;
    }

    /// `text` and what it would send, back in the thread composer.
    fn put_thread_draft(
        &mut self,
        text: String,
        used: OneShot,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let mentions = used.mentions.clone();
        if self.thread_store.update(cx, |c, cx| c.put_draft(used, cx)) {
            self.thread_composer
                .update(cx, |c, cx| c.restore_with(&text, &mentions, window, cx));
        }
    }

    /// A post that failed: its words go back where they were typed. A thread
    /// post's go to its own thread (kept for it while another is open).
    fn post_failed(
        &mut self,
        parent: Option<String>,
        text: String,
        used: OneShot,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(parent) = parent else {
            self.composer
                .update(cx, |c, cx| c.give_back(&text, used, window, cx));
            return;
        };
        // Words typed for the thread since stay, and so do the failed post's:
        // both kept, the failed post's first, with both posts' files.
        if self.thread_parent.as_ref() == Some(&parent) {
            let typed = self.thread_composer.read(cx).text(cx);
            let (text, used) = if typed.trim().is_empty() {
                (text, used)
            } else {
                let mentions = self.thread_composer.read(cx).mentions(cx);
                let later = self
                    .thread_store
                    .read(cx)
                    .text_only()
                    .with_mentions(mentions);
                self.thread_composer
                    .update(cx, |c, cx| c.set_text("", window, cx));
                OneShot::merge(&text, used, &typed, later)
            };
            self.put_thread_draft(text, used, window, cx);
        } else {
            let (text, used) = match self.thread_drafts.remove(&parent) {
                Some((typed, later)) => OneShot::merge(&text, used, &typed, later),
                None => (text, used),
            };
            self.thread_drafts.insert(parent, (text, used));
        }
    }

    fn sync_placeholder(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let l = cx.l10n().clone();
        let channel = self.title(cx).unwrap_or_else(|| l.sidebar_channels_tab());
        let hint = l.desktop_channel_message_hint(&channel);
        self.composer
            .update(cx, |c, cx| c.set_placeholder(&hint, window, cx));
        let thread_hint = l.desktop_channel_thread_hint();
        self.thread_composer
            .update(cx, |c, cx| c.set_placeholder(&thread_hint, window, cx));
    }

    fn toast(&self, level: NoticeLevel, text: String, cx: &mut App) {
        self.stores
            .toasts
            .update(cx, |t, cx| t.show(level, text, cx));
    }

    // ── Posting ─────────────────────────────────────────────────────────

    fn on_composer(
        &mut self,
        event: &ChatComposerEvent,
        thread: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let ChatComposerEvent::Submit { text, mentions } = event else {
            return;
        };
        let composer_store = if thread {
            self.thread_store.clone()
        } else {
            self.composer_store.clone()
        };
        let files: Vec<ChannelFileDto> = composer_store
            .read(cx)
            .pending_files()
            .into_iter()
            .filter_map(|f| {
                Some(ChannelFileDto {
                    id: f.id?,
                    name: f.name,
                    image: f.image,
                    size: None,
                    content_type: f.content_type,
                })
            })
            .collect();
        // Given back with the text if the post fails.
        let used = composer_store.read(cx).one_shot();
        composer_store.update(cx, |c, cx| c.clear_message(cx));
        let parent = if thread {
            self.store
                .read(cx)
                .thread
                .as_ref()
                .map(|t| t.parent_id.clone())
        } else {
            None
        };
        let (text, mentions) = (text.clone(), mentions.clone());
        let used = used.with_mentions(mentions.clone());
        let posted = self.store.update(cx, |s, cx| {
            s.post(text.clone(), mentions, files, parent.clone(), cx)
        });
        cx.spawn_in(window, async move |this, cx| {
            if posted.await == Ok(false) {
                let _ = this.update_in(cx, |this, window, cx| {
                    this.post_failed(parent, text, used, window, cx)
                });
            }
        })
        .detach();
    }

    /// Reply: the composer answers this message.
    pub fn reply_to(&mut self, message_id: String, window: &mut Window, cx: &mut Context<Self>) {
        self.store
            .update(cx, |s, cx| s.reply_to(Some(message_id), cx));
        self.composer.update(cx, |c, cx| c.focus_input(window, cx));
    }

    /// Reply in Thread: the message's thread opens beside the timeline.
    pub fn open_thread(&mut self, message_id: String, window: &mut Window, cx: &mut Context<Self>) {
        self.store
            .update(cx, |s, cx| s.open_thread(Some(message_id), cx));
        self.thread_composer
            .update(cx, |c, cx| c.focus_input(window, cx));
    }

    pub fn close_thread(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.store.update(cx, |s, cx| s.open_thread(None, cx));
        self.composer.update(cx, |c, cx| c.focus_input(window, cx));
    }

    // ── Messages ────────────────────────────────────────────────────────

    /// A message's right-click menu.
    pub fn message_menu(
        &mut self,
        message_id: String,
        in_thread: bool,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let store = self.store.read(cx);
        let Some(message) = store.message(&message_id).cloned() else {
            return;
        };
        let details = store.details.clone();
        let _ = store;
        let l = cx.l10n().clone();
        let can_post = details.as_ref().is_none_or(|d| d.channel.can_post);
        let moderator = details.as_ref().is_some_and(|d| d.moderator);
        let item = |command: MessageCommand| -> Box<dyn Action> {
            Box::new(MessageMenu {
                message_id: message_id.clone(),
                command,
                position,
            })
        };
        let mut menu = NativeMenu::new();
        if can_post {
            menu = menu.menu(
                l.desktop_channel_add_reaction_menu(),
                item(MessageCommand::AddReaction),
            );
            if !in_thread {
                menu = menu
                    .menu(l.channel_message_reply(), item(MessageCommand::Reply))
                    .menu(
                        l.desktop_channel_reply_in_thread(),
                        item(MessageCommand::Thread),
                    );
            }
            menu = menu.menu(
                if message.pinned { l.unpin() } else { l.pin() },
                item(MessageCommand::Pin(!message.pinned)),
            );
        }
        menu = menu
            .separator()
            .menu(l.desktop_channel_copy_text(), item(MessageCommand::Copy));
        if message.mine {
            menu = menu.menu(l.channel_message_edit(), item(MessageCommand::Edit));
        }
        if message.mine || moderator {
            menu = menu.separator().menu(
                l.desktop_channel_delete_message_menu(),
                item(MessageCommand::Delete),
            );
        }
        menu.show(position, window, cx);
    }

    /// A message menu's item was chosen.
    pub fn run_message(&mut self, menu: &MessageMenu, window: &mut Window, cx: &mut Context<Self>) {
        let id = menu.message_id.clone();
        match &menu.command {
            MessageCommand::AddReaction => self.show_reaction_picker(id, menu.position, window, cx),
            MessageCommand::Reply => self.reply_to(id, window, cx),
            MessageCommand::Thread => self.open_thread(id, window, cx),
            MessageCommand::Pin(pinned) => {
                let pinned = *pinned;
                self.store.update(cx, |s, cx| s.set_pinned(&id, pinned, cx));
            }
            MessageCommand::Edit => {
                self.store.update(cx, |s, cx| s.start_editing(Some(id), cx));
            }
            MessageCommand::Copy => {
                let text = self
                    .store
                    .read(cx)
                    .message(&id)
                    .map(|m| strip_mentions(&m.content))
                    .unwrap_or_default();
                cx.write_to_clipboard(ClipboardItem::new_string(text));
                let copied = cx.l10n().desktop_copied();
                self.toast(NoticeLevel::Info, copied, cx);
            }
            MessageCommand::Delete => self.confirm_delete(id, window, cx),
        }
    }

    /// Asks, then deletes the message for everyone.
    pub fn confirm_delete(
        &mut self,
        message_id: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let l = cx.l10n().clone();
        let spec = SheetSpec::new(
            l.desktop_channel_delete_message_title(),
            l.desktop_channel_delete_message_message(),
            l.channel_message_delete(),
            l.cancel(),
        )
        .destructive();
        let answer = present_sheet(window, spec, cx);
        let store = self.store.downgrade();
        let stores = self.stores.clone();
        let asked = active_account(&stores, cx);
        cx.spawn(async move |_, cx| {
            // Not once another account is in use: the message is this one's.
            if answer.await && cx.update(|cx| active_account(&stores, cx)) == asked {
                let _ = store.update(cx, |s, cx| s.delete(&message_id, cx));
            }
        })
        .detach();
    }

    /// Opens the reaction picker for `message_id` under the pointer.
    pub fn show_reaction_picker(
        &mut self,
        message_id: String,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.picker = Some(Picker {
            message_id,
            position,
            highlighted: 0,
        });
        window.focus(&self.picker_focus, cx);
        cx.notify();
    }

    /// The reaction picker is open.
    pub fn picker_open(&self) -> bool {
        self.picker.is_some()
    }

    fn close_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.picker.take().is_some() {
            self.composer.update(cx, |c, cx| c.focus_input(window, cx));
            cx.notify();
        }
    }

    fn pick(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(picker) = self.picker.clone() else {
            return;
        };
        if let Some(emoji) = REACTIONS.get(index) {
            self.store
                .update(cx, |s, cx| s.toggle_reaction(&picker.message_id, emoji, cx));
        }
        self.close_picker(window, cx);
    }

    /// A key while the picker is open: arrows move, Return or Space
    /// reacts, Esc closes. True when it was the picker's.
    fn picker_key(&mut self, key: &str, window: &mut Window, cx: &mut Context<Self>) -> bool {
        let Some(picker) = self.picker.as_mut() else {
            return false;
        };
        let n = REACTIONS.len();
        let h = picker.highlighted;
        picker.highlighted = match key {
            "right" => (h + 1) % n,
            "left" => (h + n - 1) % n,
            "down" => (h + PICKER_COLUMNS).min(n - 1),
            "up" => h.saturating_sub(PICKER_COLUMNS),
            "enter" | "space" => {
                self.pick(h, window, cx);
                return true;
            }
            "escape" => {
                self.close_picker(window, cx);
                return true;
            }
            _ => return false,
        };
        cx.notify();
        true
    }

    /// Saves an app's report as a file, where the user chooses.
    pub fn save_report(
        &mut self,
        reply: ChannelAppReplyDto,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let downloads = dirs_downloads();
        let name = crate::stores::files::safe_name(&reply.filename);
        let rx = cx.prompt_for_new_path(&downloads, Some(&name));
        let stores = self.stores.clone();
        cx.spawn(async move |_, cx| {
            let Ok(Ok(Some(path))) = rx.await else {
                return;
            };
            if let Err(e) = std::fs::write(&path, reply.content.as_bytes()) {
                log::warn!("app report not saved: {e}");
                cx.update(|cx| {
                    let text = cx.l10n().desktop_channel_download_failed();
                    stores
                        .toasts
                        .update(cx, |t, cx| t.show(NoticeLevel::Error, text, cx));
                });
            }
        })
        .detach();
    }

    // ── The toolbar ─────────────────────────────────────────────────────

    /// Members and More, at the toolbar's trailing edge.
    pub fn toolbar_items(&self, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let summary = self.summary(cx);
        let members = summary
            .as_ref()
            .and_then(|c| c.user_count)
            .map(|n| l.channel_members_title(n))
            .unwrap_or_else(|| l.desktop_channel_members());
        let (stores, id) = (self.stores.clone(), self.channel_id.clone());
        let pane = cx.entity().downgrade();
        toolbar_capsule(&t)
            .p(px(2.))
            .flex()
            .gap(px(2.))
            .child(
                IconButton::new("channel-members", IconName::Users, members)
                    .size(30., 16.)
                    .round()
                    .on_click(Rc::new(move |_, window, cx| {
                        members::open(stores.clone(), id.clone(), window, cx)
                    })),
            )
            .child(
                IconButton::new("channel-more", IconName::Ellipsis, l.more())
                    .size(30., 16.)
                    .round()
                    .on_click(Rc::new(move |e, window, cx| {
                        let position = e.position();
                        let _ = pane.update(cx, |p, cx| p.more_menu(position, window, cx));
                    })),
            )
            .into_any_element()
    }

    fn more_menu(&mut self, position: Point<Pixels>, window: &mut Window, cx: &mut Context<Self>) {
        let Some(channel) = self.summary(cx) else {
            return;
        };
        let menu = channel_menu(&channel, false, cx.l10n());
        menu.show(position, window, cx);
    }

    // ── Drawing ─────────────────────────────────────────────────────────

    fn typing_line(&self, l: &L10n, t: &ConduitTheme, cx: &App) -> Option<AnyElement> {
        let names = &self.store.read(cx).typing;
        let text = match names.as_slice() {
            [] => return None,
            [one] => l.desktop_channel_typing_one(one),
            [a, b] => l.desktop_channel_typing_two(a, b),
            _ => l.desktop_channel_typing_many(),
        };
        Some(
            div()
                .id("channel-typing")
                .role(Role::Status)
                .aria_label(SharedString::from(text.clone()))
                .px(px(4.))
                .pb(px(4.))
                .text_size(px(t.metrics.caption))
                .italic()
                .text_color(t.roles.text_subtle)
                .child(SharedString::from(text))
                .into_any_element(),
        )
    }

    fn reply_bar(&self, l: &L10n, t: &ConduitTheme, cx: &mut Context<Self>) -> Option<AnyElement> {
        let store = self.store.read(cx);
        let id = store.replying_to.clone()?;
        let name = store
            .message(&id)
            .map(|m| timeline::sender_name(m, l))
            .unwrap_or_else(|| l.channel_unknown_member());
        let r = t.roles;
        let store = self.store.downgrade();
        Some(
            div()
                .id("channel-replying")
                .role(Role::Status)
                .mx(px(4.))
                .mb(px(6.))
                .px(px(10.))
                .h(px(30.))
                .flex()
                .items_center()
                .gap(px(8.))
                .rounded(t.control_radius())
                .bg(with_alpha(r.text, 0.05))
                .child(icon(IconName::Reply, 14., r.text_subtle))
                .child(
                    div()
                        .flex_1()
                        .truncate()
                        .text_size(px(t.metrics.small))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(l.replying_to_user(&name))),
                )
                .child(
                    IconButton::new(
                        "channel-reply-cancel",
                        IconName::X,
                        l.desktop_channel_cancel_reply(),
                    )
                    .size(22., 12.)
                    .round()
                    .on_click(Rc::new(move |_, _, cx| {
                        let _ = store.update(cx, |s, cx| s.reply_to(None, cx));
                    })),
                )
                .into_any_element(),
        )
    }

    fn composer_dock(
        &self,
        composer: &Entity<ChatComposer>,
        extras: Vec<AnyElement>,
        can_post: bool,
    ) -> AnyElement {
        div()
            .flex_none()
            .w_full()
            .flex()
            .justify_center()
            .px(px(16.))
            .pb(px(14.))
            .child(
                div()
                    .w_full()
                    .max_w(px(timeline::COLUMN))
                    .flex()
                    .flex_col()
                    .children(extras)
                    .when(can_post, |d| d.child(composer.clone())),
            )
            .into_any_element()
    }

    fn thread_panel(
        &self,
        thread: &Entity<ChannelTimeline>,
        l: &L10n,
        t: &ConduitTheme,
        can_post: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let r = t.roles;
        let pane = cx.entity().downgrade();
        div()
            .id("channel-thread")
            .role(Role::Complementary)
            .aria_label(SharedString::from(l.thread()))
            .w(px(THREAD_WIDTH))
            .flex_none()
            .h_full()
            .flex()
            .flex_col()
            .border_l_1()
            .border_color(r.divider)
            .bg(r.content)
            .child(
                div()
                    .h(px(40.))
                    .flex_none()
                    .pl(px(16.))
                    .pr(px(8.))
                    .flex()
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(t.metrics.body))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(r.text)
                            .child(SharedString::from(l.thread())),
                    )
                    .child(
                        IconButton::new(
                            "channel-thread-close",
                            IconName::X,
                            l.desktop_channel_close_thread(),
                        )
                        .size(26., 14.)
                        .round()
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = pane.update(cx, |p, cx| p.close_thread(window, cx));
                        })),
                    ),
            )
            .child(thread.clone())
            .child(self.composer_dock(&self.thread_composer, vec![], can_post))
            .into_any_element()
    }

    fn picker_card(
        &self,
        picker: &Picker,
        l: &L10n,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let r = t.roles;
        let mut grid = div().flex().flex_wrap().w(px(PICKER_COLUMNS as f32 * 34.));
        for (i, emoji) in REACTIONS.iter().enumerate() {
            let on = i == picker.highlighted;
            grid = grid.child(
                div()
                    .id(ElementId::Name(format!("reaction-pick-{i}").into()))
                    .role(Role::Button)
                    .aria_label(SharedString::from(emoji.to_string()))
                    .when(on, |d| d.aria_selected(true))
                    .size(px(34.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(7.))
                    .cursor_pointer()
                    .when(on, |d| d.bg(r.selected))
                    .hover(|s| s.bg(r.hover))
                    .text_size(px(20.))
                    .child(SharedString::from(emoji.to_string()))
                    .on_click(cx.listener(move |this, _, window, cx| this.pick(i, window, cx))),
            );
        }
        deferred(
            anchored()
                .position(picker.position)
                .snap_to_window_with_margin(px(8.))
                .child(
                    div()
                        .id("reaction-picker")
                        .role(Role::Dialog)
                        .aria_label(SharedString::from(l.desktop_channel_emoji_picker()))
                        .track_focus(&self.picker_focus)
                        .on_mouse_down_out(
                            cx.listener(|this, _, window, cx| this.close_picker(window, cx)),
                        )
                        .p(px(6.))
                        .rounded(t.overlay_radius())
                        .border_1()
                        .border_color(r.border)
                        .bg(r.overlay)
                        .shadow(overlay_shadow(t))
                        .child(grid),
                ),
        )
        .with_priority(2)
        .into_any_element()
    }
}

impl Focusable for ChannelPane {
    fn focus_handle(&self, cx: &App) -> FocusHandle {
        self.composer.read(cx).input.read(cx).focus_handle(cx)
    }
}

impl Render for ChannelPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.report_front(window, cx);
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let r = t.roles;
        if self.unavailable {
            return div()
                .id("channel-unavailable")
                .role(Role::Status)
                .flex_1()
                .min_h_0()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(px(10.))
                .child(icon(IconName::Hash, 32., r.text_faint))
                .child(
                    div()
                        .text_size(px(t.metrics.body))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(l.desktop_channel_unavailable())),
                )
                .into_any_element();
        }
        let can_post = self.summary(cx).is_none_or(|c| c.can_post);
        let mut extras = vec![];
        extras.extend(self.typing_line(&l, &t, cx));
        extras.extend(self.reply_bar(&l, &t, cx));
        let main = div()
            .flex_1()
            .min_w_0()
            .h_full()
            .flex()
            .flex_col()
            .child(self.timeline.clone())
            .child(self.composer_dock(&self.composer, extras, can_post));
        let thread = self
            .thread
            .clone()
            .map(|thread| self.thread_panel(&thread, &l, &t, can_post, cx));
        let picker = self
            .picker
            .clone()
            .map(|p| self.picker_card(&p, &l, &t, cx));
        div()
            .id("channel-pane")
            .flex_1()
            .min_h_0()
            .w_full()
            .flex()
            .child(main)
            .children(thread)
            .children(picker)
            .into_any_element()
    }
}

// ── Channel commands (the sidebar's menu and the pane's More) ────────────

/// The title of `channel`: its name, or for a direct message the people in
/// it.
pub fn display_title(channel: &ChannelSummary, l: &L10n) -> String {
    let title = channel.title.trim();
    if !title.is_empty() {
        return title.to_string();
    }
    let name = channel.name.trim();
    if name.is_empty() {
        l.channel_unknown_member()
    } else {
        name.to_string()
    }
}

/// The glyph a channel's row and pane show: a person for a direct message,
/// people for a group, a lock for a private channel, else #.
pub fn channel_icon(channel: &ChannelSummary) -> IconName {
    match channel.kind {
        ChannelKind::Dm => IconName::User,
        ChannelKind::Group => IconName::Users,
        _ if channel.private => IconName::Lock,
        _ => IconName::Hash,
    }
}

/// A channel's menu: Mark as Read (from the sidebar, while unread),
/// Notifications, then Edit, Leave and Delete as the user may.
pub fn channel_menu(channel: &ChannelSummary, sidebar: bool, l: &L10n) -> NativeMenu {
    let item = |command: ChannelCommand| -> Box<dyn Action> {
        Box::new(ChannelMenu {
            channel_id: channel.id.clone(),
            command,
        })
    };
    let mut menu = NativeMenu::new();
    if sidebar {
        menu = menu.menu_with_disabled(
            l.desktop_channel_mark_read(),
            channel.unread == 0,
            item(ChannelCommand::MarkRead),
        );
        menu = menu.separator();
    }
    let notify = NativeMenu::new()
        .menu_with_check(
            l.channel_notify_all_messages(),
            !channel.muted,
            item(ChannelCommand::Notify { muted: false }),
        )
        .menu_with_check(
            l.channel_notify_mentions_only(),
            channel.muted,
            item(ChannelCommand::Notify { muted: true }),
        );
    menu = menu.submenu(l.desktop_notifications_section(), notify);
    if !sidebar {
        menu = menu.menu(l.desktop_channel_members(), item(ChannelCommand::Members));
    }
    if channel.manager && channel.kind != ChannelKind::Dm {
        menu = menu
            .separator()
            .menu(l.desktop_channel_edit_menu(), item(ChannelCommand::Edit));
    }
    if channel.can_leave || channel.can_delete {
        menu = menu.separator();
    }
    if channel.can_leave {
        menu = menu.menu(l.desktop_channel_leave_menu(), item(ChannelCommand::Leave));
    }
    if channel.can_delete {
        menu = menu.menu(
            l.desktop_channel_delete_menu(),
            item(ChannelCommand::Delete),
        );
    }
    menu
}

/// Runs a channel menu's item, from any window that hosts the sidebar.
pub fn run_channel_command(
    stores: &Stores,
    menu: &ChannelMenu,
    shown: Option<ChannelSummary>,
    window: &mut Window,
    cx: &mut App,
) {
    let id = menu.channel_id.clone();
    let rpc = stores.connection.read(cx).rpc();
    // The list's, else the open pane's (a channel not listed yet).
    let channel = stores
        .areas
        .read(cx)
        .channel(&id)
        .cloned()
        .or(shown.filter(|c| c.id == id));
    let l = cx.l10n().clone();
    let failed = {
        let stores = stores.clone();
        move |cx: &mut App| {
            let text = cx.l10n().desktop_channel_change_failed();
            stores
                .toasts
                .update(cx, |t, cx| t.show(NoticeLevel::Error, text, cx));
        }
    };
    match &menu.command {
        ChannelCommand::MarkRead => {
            let call = rpc.call::<methods::ChannelsMarkRead>(&ChannelRef { id });
            let areas = stores.areas.clone();
            cx.spawn(async move |cx| {
                let ok = call.await.is_ok();
                cx.update(|cx| {
                    areas.update(cx, |a, cx| a.refresh(Area::Channels, cx));
                    if !ok {
                        failed(cx);
                    }
                });
            })
            .detach();
        }
        ChannelCommand::Notify { muted } => {
            let call = rpc.call::<methods::ChannelsSetMuted>(&ChannelMute { id, muted: *muted });
            let areas = stores.areas.clone();
            cx.spawn(async move |cx| {
                let ok = call.await.is_ok();
                cx.update(|cx| {
                    areas.update(cx, |a, cx| a.refresh(Area::Channels, cx));
                    if !ok {
                        failed(cx);
                    }
                });
            })
            .detach();
        }
        ChannelCommand::Members => members::open(stores.clone(), id, window, cx),
        ChannelCommand::Edit => {
            if let Some(channel) = channel {
                form::open_edit(stores.clone(), channel, window, cx);
            }
        }
        ChannelCommand::Leave | ChannelCommand::Delete => {
            let leave = menu.command == ChannelCommand::Leave;
            let name = channel
                .as_ref()
                .map(|c| display_title(c, &l))
                .unwrap_or_default();
            let spec = if leave {
                SheetSpec::new(
                    l.desktop_channel_leave_title(&name),
                    l.desktop_channel_leave_message(),
                    l.desktop_channel_leave(),
                    l.cancel(),
                )
            } else {
                SheetSpec::new(
                    l.desktop_channel_delete_title(&name),
                    l.desktop_channel_delete_message(),
                    l.channel_message_delete(),
                    l.cancel(),
                )
                .destructive()
            };
            let answer = present_sheet(window, spec, cx);
            let stores = stores.clone();
            let asked = active_account(&stores, cx);
            cx.spawn(async move |cx| {
                // Answered once another account is in use (Settings has its
                // own window): the question was about this one's channel.
                if !answer.await || cx.update(|cx| active_account(&stores, cx)) != asked {
                    return;
                }
                let result = if leave {
                    rpc.call::<methods::ChannelsLeave>(&ChannelRef { id: id.clone() })
                        .await
                } else {
                    rpc.call::<methods::ChannelsDelete>(&ChannelRef { id: id.clone() })
                        .await
                };
                cx.update(|cx| match result {
                    Ok(_) => {
                        stores
                            .areas
                            .update(cx, |a, cx| a.refresh(Area::Channels, cx));
                        // Its pane closes: a new chat takes its place, as
                        // when the open chat is deleted.
                        let shown = stores.navigation.read(cx).selected_item()
                            == Some(&AreaItem::Channel(id.clone()));
                        if shown {
                            stores.navigation.update(cx, |n, cx| n.new_chat(false, cx));
                        }
                    }
                    Err(e) => {
                        log::warn!("channel leave/delete: {e}");
                        failed(cx);
                    }
                });
            })
            .detach();
        }
    }
}

/// The account in use now, by id: what a question asked about.
fn active_account(stores: &Stores, cx: &App) -> Option<String> {
    stores.accounts.read(cx).active().map(|a| a.id.clone())
}

/// The channel pane the main window shows, if any.
pub fn current_pane(cx: &App) -> Option<Entity<ChannelPane>> {
    let view = cx.try_global::<crate::AppState>()?.main_view.clone()?;
    view.read(cx).area_pane.read(cx).channel.clone()
}

/// `content` with mention markup as `@Name` (Copy Text).
pub fn strip_mentions(content: &str) -> String {
    let mut out = String::with_capacity(content.len());
    let mut rest = content;
    while let Some(start) = rest.find("<@") {
        out.push_str(&rest[..start]);
        let tail = &rest[start..];
        let parsed = tail.find('>').and_then(|end| {
            let inner = &tail[2..end];
            let (kind_id, label) = inner.split_once('|')?;
            let kind = kind_id.split_once(':')?.0;
            (kind.len() == 1 && kind.chars().all(|c| c.is_ascii_uppercase()))
                .then(|| (end, label.to_string()))
        });
        match parsed {
            Some((end, label)) => {
                out.push('@');
                out.push_str(&label);
                rest = &tail[end + 1..];
            }
            None => {
                out.push_str("<@");
                rest = &tail[2..];
            }
        }
    }
    out.push_str(rest);
    out
}

fn dirs_downloads() -> std::path::PathBuf {
    std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .map(|h| h.join("Downloads"))
        .unwrap_or_else(std::env::temp_dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn summary(json: serde_json::Value) -> ChannelSummary {
        serde_json::from_value(json).unwrap()
    }

    #[test]
    fn mentions_copy_as_names() {
        assert_eq!(
            strip_mentions("Ask <@U:u2|Juniper> and <@M:fake|Kestrel 8B> <@nope"),
            "Ask @Juniper and @Kestrel 8B <@nope"
        );
        assert_eq!(strip_mentions("plain"), "plain");
    }

    #[test]
    fn a_channel_is_named_and_drawn_by_its_kind() {
        let l = L10n::new("en");
        let dm = summary(serde_json::json!({
            "id": "d", "name": "", "kind": "dm", "title": "Juniper",
        }));
        assert_eq!(display_title(&dm, &l), "Juniper");
        assert_eq!(channel_icon(&dm), IconName::User);
        let private = summary(serde_json::json!({"id": "p", "name": "ops", "private": true}));
        assert_eq!(display_title(&private, &l), "ops");
        assert_eq!(channel_icon(&private), IconName::Lock);
        let nameless = summary(serde_json::json!({"id": "x", "name": "", "kind": "dm"}));
        assert_eq!(display_title(&nameless, &l), l.channel_unknown_member());
    }

    /// A thread's words stay with the thread: another thread opens on an
    /// empty composer (its post would go to that thread), and the words come
    /// back when their thread does.
    #[gpui_kit::test]
    fn a_threads_draft_stays_with_its_thread(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::sheet::bench::bench;

        let (_daemon, stores, vcx) = bench(cx);
        let pane = vcx.update(|window, cx| {
            cx.new(|cx| ChannelPane::new(stores.clone(), "c1".into(), window, cx))
        });
        let thread_text = |vcx: &mut gpui_kit::VisualTestContext| {
            pane.read_with(vcx, |p, cx| p.thread_composer.read(cx).text(cx))
        };
        pane.update_in(vcx, |p, window, cx| p.open_thread("m1".into(), window, cx));
        vcx.run_until_parked();
        pane.update_in(vcx, |p, window, cx| {
            p.thread_composer
                .update(cx, |c, cx| c.set_text("Seedlings by Friday", window, cx))
        });
        pane.update_in(vcx, |p, window, cx| p.open_thread("m2".into(), window, cx));
        vcx.run_until_parked();
        assert_eq!(
            thread_text(vcx),
            "",
            "the last thread's words would post in this one"
        );
        pane.update_in(vcx, |p, window, cx| p.open_thread("m1".into(), window, cx));
        vcx.run_until_parked();
        assert_eq!(thread_text(vcx), "Seedlings by Friday");
    }

    /// A thread post that fails while another thread is open, its own thread
    /// holding words typed since: both are kept for the thread, the failed
    /// post's words and file with the newer words.
    #[gpui_kit::test]
    fn a_failed_thread_post_joins_the_threads_newer_draft(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::composer::Attachment;
        use crate::views::sheet::bench::bench;

        let (_daemon, stores, vcx) = bench(cx);
        let pane = vcx.update(|window, cx| {
            cx.new(|cx| ChannelPane::new(stores.clone(), "c1".into(), window, cx))
        });
        pane.update_in(vcx, |p, window, cx| p.open_thread("m1".into(), window, cx));
        vcx.run_until_parked();
        let mut used = pane.read_with(vcx, |p, cx| p.thread_store.read(cx).one_shot());
        used.attachments
            .push(Attachment::uploaded_for_test(99, "plan.pdf", "f99"));
        pane.update_in(vcx, |p, window, cx| {
            p.thread_composer
                .update(cx, |c, cx| c.set_text("Newer words", window, cx))
        });
        pane.update_in(vcx, |p, window, cx| p.open_thread("m2".into(), window, cx));
        vcx.run_until_parked();
        pane.update_in(vcx, |p, window, cx| {
            p.post_failed(
                Some("m1".into()),
                "Seedlings by Friday".into(),
                used,
                window,
                cx,
            )
        });
        pane.update_in(vcx, |p, window, cx| p.open_thread("m1".into(), window, cx));
        vcx.run_until_parked();
        let (text, files) = pane.read_with(vcx, |p, cx| {
            (
                p.thread_composer.read(cx).text(cx),
                p.thread_store
                    .read(cx)
                    .attachments
                    .iter()
                    .map(|a| a.name.clone())
                    .collect::<Vec<_>>(),
            )
        });
        assert!(
            text.contains("Seedlings by Friday") && text.contains("Newer words"),
            "a thread's words were dropped: {text:?}"
        );
        assert_eq!(
            files,
            vec!["plan.pdf".to_string()],
            "the failed post's file was dropped"
        );
    }

    /// New Channel, a channel's members and its Leave question belong to
    /// the account they opened under: another account signing in (Settings
    /// has its own window) closes the sheets, and a Leave answered after it
    /// leaves nothing under the next account.
    #[gpui_kit::test]
    fn channel_sheets_and_questions_stay_with_their_account(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::accounts::tests::{account, list};
        use crate::views::sheet::{
            self,
            bench::{bench, switch_account},
        };

        let (daemon, stores, vcx) = bench(cx);
        let back_to_avery = |vcx: &mut gpui_kit::VisualTestContext| {
            stores.accounts.update(vcx, |a, cx| {
                a.adopt(
                    list(vec![
                        account("a", "Avery", true, true),
                        account("b", "Blake", false, true),
                    ]),
                    cx,
                )
            });
            vcx.run_until_parked();
        };

        vcx.update(|window, cx| form::open_new(stores.clone(), window, cx));
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<form::ChannelForm>(cx))
                .is_some()
        );
        switch_account(&stores, vcx);
        assert!(
            vcx.update(|_, cx| sheet::current::<form::ChannelForm>(cx))
                .is_none(),
            "Avery's New Channel stayed open over Blake's account"
        );

        vcx.update(|window, cx| members::open(stores.clone(), "c1".into(), window, cx));
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<members::MembersSheet>(cx))
                .is_some()
        );
        back_to_avery(vcx);
        assert!(
            vcx.update(|_, cx| sheet::current::<members::MembersSheet>(cx))
                .is_none(),
            "Blake's channel members stayed open over Avery's account"
        );

        // Leave, asked under Avery and answered once Blake signs in.
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        let channel = summary(serde_json::json!({"id": "c1", "name": "garden-club"}));
        vcx.update(|window, cx| {
            let menu = ChannelMenu {
                channel_id: "c1".into(),
                command: ChannelCommand::Leave,
            };
            run_channel_command(&stores, &menu, Some(channel), window, cx)
        });
        switch_account(&stores, vcx);
        assert!(
            daemon.calls::<methods::ChannelsLeave>().is_empty(),
            "Avery's Leave went out under Blake's account"
        );
    }
}
