//! One open channel: its details, its messages, who is typing, an app's
//! private answers, and the thread open beside it.
//!
//! * **Messages** are kept oldest first, as the timeline draws them. The
//!   daemon answers `channels.messages` newest first; after that it sends
//!   `channels.message` with what changed (new and changed messages, ids
//!   that went), which is patched in by id and creation time, so a long
//!   history is never fetched again for one post. A change marked `full`,
//!   a reconnect and an event gap fetch the newest page again.
//! * **Older messages** load a page at a time (`older`), when the timeline
//!   reaches its top.
//! * **Typing:** who is typing comes on `channels.typing`; the user's own
//!   typing goes out at most every few seconds while they type, and stops
//!   when they send or clear the field ([`TypingPace`]).
//! * **Private app answers** (`channels.appReply`, or a button's own
//!   answer) show under their message until dismissed or the channel
//!   closes; they are never stored, as on the phone and the web.
//! * **The thread** beside the timeline has its own list, patched the same
//!   way by the changes that name its parent.
//!
//! Every action is the daemon's (`channels.*`); the store shows the
//! answer, and a failure becomes a [`ChannelStoreEvent::Failed`] for the
//! pane to say.

use std::collections::HashMap;
use std::rc::Rc;
use std::time::{Duration, Instant};

use conduit_protocol::{
    ChannelAppAction, ChannelAppReplyEvent, ChannelDetails, ChannelFocus, ChannelMessageDto,
    ChannelMessageEdit, ChannelMessageRef, ChannelMessages, ChannelMessagesChanged,
    ChannelMessagesQuery, ChannelPin, ChannelPost, ChannelReact, ChannelRef, ChannelTyping,
    ComposerMentionDto, Event, events, methods,
};
use gpui_kit::{App, AppContext as _, AsyncApp, Context, EventEmitter, Task, WeakEntity};

use super::rpc::Rpc;

/// What the channel pane listens to, scoped to `channel:<id>`.
pub const CHANNEL_EVENTS: &[&str] = &[
    events::CHANNELS_MESSAGE,
    events::CHANNELS_TYPING,
    events::CHANNELS_APP_REPLY,
];

/// The event scope of channel `id`.
pub fn scope(id: &str) -> String {
    format!("channel:{id}")
}

/// Subscribes the window to a channel's events (`None`: to none).
pub type Subscribe = Rc<dyn Fn(Option<&str>, &mut App)>;

/// How long a pause in typing keeps "typing" said, and how often it is
/// said again while the user keeps typing.
pub const TYPING_EVERY: Duration = Duration::from_secs(3);

/// When the user's typing goes out: at the first key, then at most every
/// [`TYPING_EVERY`] while keys keep coming; "stopped" once, when the field
/// empties or the message is sent.
#[derive(Debug, Default)]
pub struct TypingPace {
    said: Option<Instant>,
}

impl TypingPace {
    /// The field changed at `now`, holding text or not: what to say, if
    /// anything (`Some(true)` typing, `Some(false)` stopped).
    pub fn changed(&mut self, has_text: bool, now: Instant) -> Option<bool> {
        if !has_text {
            return self.said.take().map(|_| false);
        }
        match self.said {
            Some(at) if now.duration_since(at) < TYPING_EVERY => None,
            _ => {
                self.said = Some(now);
                Some(true)
            }
        }
    }

    /// The message went: "stopped", if "typing" was said.
    pub fn sent(&mut self) -> Option<bool> {
        self.said.take().map(|_| false)
    }
}

/// A list of messages oldest first, patched by id.
#[derive(Clone, Debug, Default)]
pub struct MessageList {
    messages: Vec<ChannelMessageDto>,
    /// Bumped per message whenever it changes, so a row redraws only when
    /// its own message did.
    versions: HashMap<String, u64>,
    next_version: u64,
    pub has_older: bool,
}

impl MessageList {
    pub fn messages(&self) -> &[ChannelMessageDto] {
        &self.messages
    }

    pub fn len(&self) -> usize {
        self.messages.len()
    }

    pub fn is_empty(&self) -> bool {
        self.messages.is_empty()
    }

    pub fn get(&self, id: &str) -> Option<&ChannelMessageDto> {
        self.messages.iter().find(|m| m.id == id)
    }

    /// The version of message `id`, which changes whenever it does.
    pub fn version(&self, id: &str) -> u64 {
        self.versions.get(id).copied().unwrap_or(0)
    }

    fn bump(&mut self, id: &str) {
        self.next_version += 1;
        self.versions.insert(id.to_string(), self.next_version);
    }

    /// The newest page, as `channels.messages` answers (newest first).
    pub fn replace(&mut self, newest_first: Vec<ChannelMessageDto>, has_older: bool) {
        let mut messages = newest_first;
        messages.reverse();
        let keep: HashMap<String, ChannelMessageDto> =
            self.messages.drain(..).map(|m| (m.id.clone(), m)).collect();
        for m in &messages {
            if keep.get(&m.id) != Some(m) {
                self.next_version += 1;
                self.versions.insert(m.id.clone(), self.next_version);
            }
        }
        self.versions
            .retain(|id, _| messages.iter().any(|m| &m.id == id));
        self.messages = messages;
        self.has_older = has_older;
    }

    /// A page of older messages (newest first), above what is held.
    pub fn prepend_older(&mut self, newest_first: Vec<ChannelMessageDto>, has_older: bool) {
        for message in newest_first {
            self.upsert(message);
        }
        self.has_older = has_older;
    }

    /// Puts `message` in by creation time, or replaces the one with its id.
    pub fn upsert(&mut self, message: ChannelMessageDto) {
        if let Some(i) = self.messages.iter().position(|m| m.id == message.id) {
            if self.messages[i] != message {
                self.bump(&message.id);
                self.messages[i] = message;
            }
            return;
        }
        self.bump(&message.id);
        let at = self
            .messages
            .partition_point(|m| m.created_at_ms <= message.created_at_ms);
        self.messages.insert(at, message);
    }

    pub fn remove(&mut self, id: &str) -> bool {
        let before = self.messages.len();
        self.messages.retain(|m| m.id != id);
        self.versions.remove(id);
        before != self.messages.len()
    }

    /// Applies a `channels.message` change. False when it asks for the
    /// whole list again.
    pub fn apply(&mut self, change: &ChannelMessagesChanged) -> bool {
        if change.full || (change.upserts.is_empty() && change.removed.is_empty()) {
            return false;
        }
        for id in &change.removed {
            self.remove(id);
        }
        for message in &change.upserts {
            self.upsert(message.clone());
        }
        if let Some(older) = change.has_older {
            self.has_older = older;
        }
        true
    }
}

/// The thread open beside the timeline.
#[derive(Clone, Debug)]
pub struct Thread {
    pub parent_id: String,
    pub list: MessageList,
    pub loading: bool,
    pub loading_older: bool,
    /// Its earlier page failed: asked for again only on Try Again or after
    /// the thread is read afresh.
    pub older_failed: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ChannelStoreEvent {
    /// The channel could not be shown (gone, or the user may not see it).
    Unavailable,
    /// An action failed: the pane says so.
    Failed(Failure),
    /// A message was posted by the user: the timeline goes to the end.
    Posted,
}

/// What failed, for the words the pane uses.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Failure {
    Send,
    Edit,
    Delete,
    React,
    Pin,
    LoadOlder,
    /// An app's button, with the server's own reason when it gave one.
    AppAction {
        message_id: String,
        detail: Option<String>,
    },
}

pub struct ChannelStore {
    rpc: Rpc,
    subscribe: Subscribe,
    channel_id: String,
    pub details: Option<ChannelDetails>,
    pub list: MessageList,
    /// The first page has arrived.
    pub loaded: bool,
    pub loading_older: bool,
    /// The earlier page failed: asked for again only on Try Again or after
    /// the newest page is read afresh, never on every draw of its row.
    pub older_failed: bool,
    pub typing: Vec<String>,
    /// An app's private answers, under their messages, in arrival order.
    pub app_replies: Vec<ChannelAppReplyEvent>,
    /// App buttons waiting on their answer, by message id.
    pub pending_actions: Vec<String>,
    pub thread: Option<Thread>,
    /// The message being edited in place.
    pub editing: Option<String>,
    /// The words of an edit the daemon refused, for its editor to open with
    /// again (not the message's saved text).
    pub edit_draft: Option<String>,
    /// The message the next post answers (an inline reply).
    pub replying_to: Option<String>,
    pace: TypingPace,
    /// Bumped by every fetch of the whole list: a slower, older answer is
    /// dropped.
    generation: u64,
    revision: u64,
    _open: Option<Task<()>>,
    _fetch: Option<Task<()>>,
    _older: Option<Task<()>>,
    _thread: Option<Task<()>>,
    _actions: Vec<Task<()>>,
}

impl EventEmitter<ChannelStoreEvent> for ChannelStore {}

impl ChannelStore {
    pub fn new(rpc: Rpc, subscribe: Subscribe, channel_id: String, cx: &mut Context<Self>) -> Self {
        let mut store = Self {
            rpc,
            subscribe,
            channel_id,
            details: None,
            list: MessageList::default(),
            loaded: false,
            loading_older: false,
            older_failed: false,
            typing: vec![],
            app_replies: vec![],
            pending_actions: vec![],
            thread: None,
            editing: None,
            edit_draft: None,
            replying_to: None,
            pace: TypingPace::default(),
            generation: 0,
            revision: 0,
            _open: None,
            _fetch: None,
            _older: None,
            _thread: None,
            _actions: vec![],
        };
        (store.subscribe)(Some(&store.channel_id), cx);
        store.open(cx);
        store.fetch(cx);
        store
    }

    pub fn channel_id(&self) -> &str {
        &self.channel_id
    }

    /// Bumped whenever anything shown changes.
    pub fn revision(&self) -> u64 {
        self.revision
    }

    fn changed(&mut self, cx: &mut Context<Self>) {
        self.revision += 1;
        cx.notify();
    }

    /// The pane is going away: the window stops listening.
    pub fn close(&mut self, cx: &mut Context<Self>) {
        if let Some(stop) = self.pace.sent() {
            self.say_typing(stop, cx);
        }
        (self.subscribe)(None, cx);
    }

    /// `channels.open`: the channel's details, and it is read.
    pub fn open(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::ChannelsOpen>(&ChannelRef {
            id: self.channel_id.clone(),
        });
        self._open = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| match result {
                    Ok(details) => {
                        s.details = Some(details);
                        s.changed(cx);
                    }
                    Err(e) => {
                        log::warn!("channels.open: {e}");
                        if matches!(e.code.as_str(), "resource.notFound" | "net.serverError") {
                            cx.emit(ChannelStoreEvent::Unavailable);
                        }
                    }
                });
            }),
        );
    }

    /// The newest page again (first open, reconnect, a gap, `full`).
    pub fn fetch(&mut self, cx: &mut Context<Self>) {
        self.generation += 1;
        let generation = self.generation;
        let call = self
            .rpc
            .call::<methods::ChannelsMessages>(&ChannelMessagesQuery {
                channel_id: self.channel_id.clone(),
                parent_id: None,
                older: false,
            });
        self._fetch = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    if s.generation != generation {
                        return;
                    }
                    match result {
                        Ok(page) => {
                            s.list.replace(page.messages, page.has_older);
                            s.loaded = true;
                            s.older_failed = false;
                            s.changed(cx);
                        }
                        Err(e) => {
                            log::warn!("channels.messages: {e}");
                            s.loaded = true;
                            s.changed(cx);
                        }
                    }
                });
            }),
        );
        if self.thread.is_some() {
            self.fetch_thread(cx);
        }
    }

    /// The next page back, when the timeline reaches its top.
    pub fn load_older(&mut self, cx: &mut Context<Self>) {
        if self.loading_older || self.older_failed || !self.list.has_older || !self.loaded {
            return;
        }
        self.loading_older = true;
        let generation = self.generation;
        let call = self
            .rpc
            .call::<methods::ChannelsMessages>(&ChannelMessagesQuery {
                channel_id: self.channel_id.clone(),
                parent_id: None,
                older: true,
            });
        self._older = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    s.loading_older = false;
                    if s.generation != generation {
                        return;
                    }
                    match result {
                        // The daemon answers with everything it holds, the new
                        // page included.
                        Ok(page) => s.list.prepend_older(page.messages, page.has_older),
                        Err(e) => {
                            log::warn!("channels.messages (older): {e}");
                            s.older_failed = true;
                            cx.emit(ChannelStoreEvent::Failed(Failure::LoadOlder));
                        }
                    }
                    s.changed(cx);
                });
            }),
        );
        self.changed(cx);
    }

    /// Try Again on a failed earlier page.
    pub fn retry_older(&mut self, cx: &mut Context<Self>) {
        self.older_failed = false;
        self.load_older(cx);
    }

    /// A daemon event for this window.
    pub fn on_event(&mut self, event: &Event, cx: &mut Context<Self>) {
        match event {
            Event::ChannelsMessage(change) if change.channel_id == self.channel_id => {
                match &change.parent_id {
                    None => {
                        if self.list.apply(change) {
                            self.forget_gone_replies();
                            self.changed(cx);
                        } else {
                            self.fetch(cx);
                        }
                    }
                    Some(parent) => {
                        let Some(thread) = self.thread.as_mut().filter(|t| &t.parent_id == parent)
                        else {
                            return;
                        };
                        if thread.list.apply(change) {
                            self.changed(cx);
                        } else {
                            self.fetch_thread(cx);
                        }
                    }
                }
            }
            Event::ChannelsTyping(typing) if typing.channel_id == self.channel_id => {
                if self.typing != typing.names {
                    self.typing = typing.names.clone();
                    self.changed(cx);
                }
            }
            Event::ChannelsAppReply(reply) if reply.channel_id == self.channel_id => {
                self.add_app_reply(reply.clone(), cx);
            }
            _ => {}
        }
    }

    /// A reconnect or a gap: everything shown is fetched again.
    pub fn on_reconnected(&mut self, cx: &mut Context<Self>) {
        (self.subscribe)(Some(&self.channel_id), cx);
        self.open(cx);
        self.fetch(cx);
    }

    fn forget_gone_replies(&mut self) {
        let list = &self.list;
        let thread = self.thread.as_ref();
        self.app_replies.retain(|r| {
            list.get(&r.message_id).is_some()
                || thread.is_some_and(|t| t.list.get(&r.message_id).is_some())
        });
    }

    // ── Posting ─────────────────────────────────────────────────────────

    /// `channels.post`: `text` (with its `mentions`) and `files`, in the
    /// thread of `parent_id` when given, else as an answer to the message
    /// being replied to, if any. The answer says whether it went (`false`
    /// for a refused or never-sent message, whose composer takes it back).
    pub fn post(
        &mut self,
        text: String,
        mentions: Vec<ComposerMentionDto>,
        files: Vec<conduit_protocol::ChannelFileDto>,
        parent_id: Option<String>,
        cx: &mut Context<Self>,
    ) -> futures::channel::oneshot::Receiver<bool> {
        let (sent, answer) = futures::channel::oneshot::channel();
        if text.trim().is_empty() && files.is_empty() {
            let _ = sent.send(true);
            return answer;
        }
        if let Some(stop) = self.pace.sent() {
            self.say_typing(stop, cx);
        }
        let reply_to_id = if parent_id.is_none() {
            self.replying_to.take()
        } else {
            None
        };
        let call = self.rpc.call::<methods::ChannelsPost>(&ChannelPost {
            channel_id: self.channel_id.clone(),
            content: text,
            parent_id: parent_id.clone(),
            mentions,
            files,
            reply_to_id,
        });
        let task = cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| match result {
                Ok(message) => {
                    // The daemon's own change follows; showing the answer
                    // now spares a frame without it.
                    match &parent_id {
                        None => s.list.upsert(message),
                        Some(parent) => {
                            if let Some(t) = s.thread.as_mut().filter(|t| &t.parent_id == parent) {
                                t.list.upsert(message);
                            }
                        }
                    }
                    cx.emit(ChannelStoreEvent::Posted);
                    s.changed(cx);
                    let _ = sent.send(true);
                }
                Err(e) => {
                    log::warn!("channels.post: {e}");
                    cx.emit(ChannelStoreEvent::Failed(Failure::Send));
                    let _ = sent.send(false);
                }
            });
        });
        self.keep(task);
        cx.notify();
        answer
    }

    /// The user typed (`has_text`: the field holds something).
    pub fn typed(&mut self, has_text: bool, cx: &mut Context<Self>) {
        if let Some(typing) = self.pace.changed(has_text, Instant::now()) {
            self.say_typing(typing, cx);
        }
    }

    fn say_typing(&mut self, typing: bool, cx: &mut Context<Self>) {
        // Fire and forget: a lost "typing" is harmless.
        let call = self.rpc.call::<methods::ChannelsTyping>(&ChannelTyping {
            channel_id: self.channel_id.clone(),
            typing,
        });
        cx.background_spawn(async move {
            let _ = call.await;
        })
        .detach();
    }

    pub fn reply_to(&mut self, id: Option<String>, cx: &mut Context<Self>) {
        if self.replying_to != id {
            self.replying_to = id;
            self.changed(cx);
        }
    }

    // ── One message ─────────────────────────────────────────────────────

    /// A message the timeline or the open thread holds.
    pub fn message(&self, id: &str) -> Option<&ChannelMessageDto> {
        self.list
            .get(id)
            .or_else(|| self.thread.as_ref().and_then(|t| t.list.get(id)))
    }

    pub fn start_editing(&mut self, id: Option<String>, cx: &mut Context<Self>) {
        if self.editing != id {
            self.editing = id;
            self.edit_draft = None;
            self.changed(cx);
        }
    }

    /// `channels.editMessage`, unless the text is empty or unchanged.
    pub fn save_edit(&mut self, id: &str, text: String, cx: &mut Context<Self>) {
        self.editing = None;
        self.edit_draft = None;
        self.changed(cx);
        let text = text.trim().to_string();
        let unchanged = self.message(id).is_some_and(|m| m.content.trim() == text);
        if text.is_empty() || unchanged {
            return;
        }
        let call = self
            .rpc
            .call::<methods::ChannelsEditMessage>(&ChannelMessageEdit {
                channel_id: self.channel_id.clone(),
                message_id: id.to_string(),
                content: text.clone(),
            });
        let id = id.to_string();
        let task = cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| match result {
                Ok(message) => {
                    s.patch(message);
                    s.changed(cx);
                }
                Err(e) => {
                    log::warn!("channels.editMessage: {e}");
                    // The words typed stay: the editor opens on the message
                    // again with them, unless another edit has begun.
                    if s.editing.is_none() {
                        s.editing = Some(id);
                        s.edit_draft = Some(text);
                        s.changed(cx);
                    }
                    cx.emit(ChannelStoreEvent::Failed(Failure::Edit));
                }
            });
        });
        self.keep(task);
    }

    /// Puts a changed message in whichever list holds it.
    fn patch(&mut self, message: ChannelMessageDto) {
        if self.list.get(&message.id).is_some() {
            self.list.upsert(message);
        } else if let Some(t) = self.thread.as_mut()
            && t.list.get(&message.id).is_some()
        {
            t.list.upsert(message);
        }
    }

    pub fn delete(&mut self, id: &str, cx: &mut Context<Self>) {
        let call = self
            .rpc
            .call::<methods::ChannelsDeleteMessage>(&ChannelMessageRef {
                channel_id: self.channel_id.clone(),
                message_id: id.to_string(),
            });
        let id = id.to_string();
        let task = cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| match result {
                Ok(_) => {
                    let mut gone = s.list.remove(&id);
                    if let Some(t) = s.thread.as_mut() {
                        gone |= t.list.remove(&id);
                    }
                    if s.thread.as_ref().is_some_and(|t| t.parent_id == id) {
                        s.thread = None;
                        gone = true;
                    }
                    if gone {
                        s.forget_gone_replies();
                        s.changed(cx);
                    }
                }
                Err(e) => {
                    log::warn!("channels.deleteMessage: {e}");
                    cx.emit(ChannelStoreEvent::Failed(Failure::Delete));
                }
            });
        });
        self.keep(task);
    }

    /// Adds `emoji` to message `id`, or takes it back when the user's
    /// reaction is already there.
    pub fn toggle_reaction(&mut self, id: &str, emoji: &str, cx: &mut Context<Self>) {
        let add = !self
            .message(id)
            .is_some_and(|m| m.reactions.iter().any(|r| r.name == emoji && r.mine));
        let call = self.rpc.call::<methods::ChannelsReact>(&ChannelReact {
            channel_id: self.channel_id.clone(),
            message_id: id.to_string(),
            emoji: emoji.to_string(),
            add,
        });
        let task = cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if let Err(e) = call.await {
                log::warn!("channels.react: {e}");
                let _ = this.update(cx, |_, cx| {
                    cx.emit(ChannelStoreEvent::Failed(Failure::React))
                });
            }
        });
        self.keep(task);
    }

    pub fn set_pinned(&mut self, id: &str, pinned: bool, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::ChannelsPin>(&ChannelPin {
            channel_id: self.channel_id.clone(),
            message_id: id.to_string(),
            pinned,
        });
        let task = cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if let Err(e) = call.await {
                log::warn!("channels.pin: {e}");
                let _ = this.update(cx, |_, cx| cx.emit(ChannelStoreEvent::Failed(Failure::Pin)));
            }
        });
        self.keep(task);
    }

    // ── Apps ────────────────────────────────────────────────────────────

    /// Presses button `action_id` of app message `message_id`.
    pub fn press_app_action(
        &mut self,
        message_id: &str,
        action_id: &str,
        parent_id: Option<String>,
        cx: &mut Context<Self>,
    ) {
        if self.pending_actions.iter().any(|m| m == message_id) {
            return;
        }
        self.pending_actions.push(message_id.to_string());
        self.changed(cx);
        let call = self
            .rpc
            .call::<methods::ChannelsAppAction>(&ChannelAppAction {
                channel_id: self.channel_id.clone(),
                message_id: message_id.to_string(),
                action_id: action_id.to_string(),
                parent_id,
            });
        let message_id = message_id.to_string();
        let task = cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.pending_actions.retain(|m| m != &message_id);
                match result {
                    Ok(answer) => {
                        if let Some(reply) = answer.reply {
                            s.add_app_reply(reply, cx);
                        }
                    }
                    Err(e) => {
                        log::warn!("channels.appAction: {e}");
                        cx.emit(ChannelStoreEvent::Failed(Failure::AppAction {
                            message_id: message_id.clone(),
                            detail: e.args.get("detail").cloned(),
                        }));
                    }
                }
                s.changed(cx);
            });
        });
        self.keep(task);
    }

    /// One answer per message and app: a newer one replaces it.
    pub fn add_app_reply(&mut self, reply: ChannelAppReplyEvent, cx: &mut Context<Self>) {
        self.app_replies
            .retain(|r| !(r.message_id == reply.message_id && r.app_id == reply.app_id));
        self.app_replies.push(reply);
        self.changed(cx);
    }

    pub fn dismiss_app_reply(&mut self, message_id: &str, app_id: &str, cx: &mut Context<Self>) {
        let before = self.app_replies.len();
        self.app_replies
            .retain(|r| !(r.message_id == message_id && r.app_id == app_id));
        if before != self.app_replies.len() {
            self.changed(cx);
        }
    }

    // ── The thread ──────────────────────────────────────────────────────

    /// Opens the thread of message `parent_id` beside the timeline (or
    /// closes it: `None`).
    pub fn open_thread(&mut self, parent_id: Option<String>, cx: &mut Context<Self>) {
        if self.thread.as_ref().map(|t| &t.parent_id) == parent_id.as_ref() {
            return;
        }
        self.thread = parent_id.map(|parent_id| Thread {
            parent_id,
            list: MessageList::default(),
            loading: true,
            loading_older: false,
            older_failed: false,
        });
        if self.thread.is_some() {
            self.fetch_thread(cx);
        } else {
            self._thread = None;
        }
        self.changed(cx);
    }

    fn fetch_thread(&mut self, cx: &mut Context<Self>) {
        let Some(parent) = self.thread.as_ref().map(|t| t.parent_id.clone()) else {
            return;
        };
        self.thread_page(parent, false, cx);
    }

    pub fn load_older_replies(&mut self, cx: &mut Context<Self>) {
        let Some(thread) = self.thread.as_mut() else {
            return;
        };
        if thread.loading_older || thread.older_failed || !thread.list.has_older {
            return;
        }
        thread.loading_older = true;
        let parent = thread.parent_id.clone();
        self.thread_page(parent, true, cx);
    }

    /// Try Again on a thread's failed earlier page.
    pub fn retry_older_replies(&mut self, cx: &mut Context<Self>) {
        if let Some(thread) = self.thread.as_mut() {
            thread.older_failed = false;
        }
        self.load_older_replies(cx);
    }

    fn thread_page(&mut self, parent: String, older: bool, cx: &mut Context<Self>) {
        let call = self
            .rpc
            .call::<methods::ChannelsMessages>(&ChannelMessagesQuery {
                channel_id: self.channel_id.clone(),
                parent_id: Some(parent.clone()),
                older,
            });
        self._thread = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result: Result<ChannelMessages, _> = call.await;
                let _ = this.update(cx, |s, cx| {
                    let Some(t) = s.thread.as_mut().filter(|t| t.parent_id == parent) else {
                        return;
                    };
                    t.loading = false;
                    t.loading_older = false;
                    match result {
                        Ok(page) if older => t.list.prepend_older(page.messages, page.has_older),
                        Ok(page) => {
                            t.list.replace(page.messages, page.has_older);
                            t.older_failed = false;
                        }
                        Err(e) => {
                            log::warn!("channels.messages (thread): {e}");
                            t.older_failed |= older;
                        }
                    }
                    s.changed(cx);
                });
            }),
        );
    }

    fn keep(&mut self, task: Task<()>) {
        self._actions.retain(|t| !t.is_ready());
        self._actions.push(task);
    }
}

/// Tells the daemon which channel is in front of the user (`None`: none).
pub fn focus(rpc: &Rpc, id: Option<String>, cx: &mut App) {
    let call = rpc.call::<methods::ChannelsFocus>(&ChannelFocus { id });
    cx.background_spawn(async move {
        if let Err(e) = call.await {
            log::warn!("channels.focus: {e}");
        }
    })
    .detach();
}

#[cfg(test)]
pub mod tests {
    use std::cell::RefCell;

    use conduit_protocol::{ChannelSummary, OkResult};
    use gpui_kit::TestAppContext;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    pub fn message(id: &str, at: i64, text: &str) -> ChannelMessageDto {
        serde_json::from_value(serde_json::json!({
            "id": id, "channelId": "c1", "content": text, "display": text,
            "createdAtMs": at, "senderKey": "u2",
            "user": {"id": "u2", "name": "Juniper"},
        }))
        .unwrap()
    }

    pub fn details(id: &str) -> ChannelDetails {
        ChannelDetails {
            channel: serde_json::from_value::<ChannelSummary>(serde_json::json!({
                "id": id, "name": "garden-club", "title": "garden-club", "kind": "group",
            }))
            .unwrap(),
            can_manage_members: true,
            moderator: false,
        }
    }

    pub fn page(newest_first: Vec<ChannelMessageDto>, has_older: bool) -> ChannelMessages {
        ChannelMessages {
            channel_id: "c1".into(),
            parent_id: None,
            messages: newest_first,
            has_older,
        }
    }

    fn change(upserts: Vec<ChannelMessageDto>, removed: &[&str]) -> ChannelMessagesChanged {
        ChannelMessagesChanged {
            channel_id: "c1".into(),
            parent_id: None,
            upserts,
            removed: removed.iter().map(|s| s.to_string()).collect(),
            full: false,
            has_older: None,
        }
    }

    type Subscribed = Rc<RefCell<Vec<Option<String>>>>;

    fn open(
        daemon: &FakeDaemon,
        cx: &mut TestAppContext,
    ) -> (gpui_kit::Entity<ChannelStore>, Subscribed) {
        let subscribed: Subscribed = Rc::default();
        let subscribe: Subscribe = {
            let subscribed = subscribed.clone();
            Rc::new(move |id: Option<&str>, _: &mut App| {
                subscribed.borrow_mut().push(id.map(String::from))
            })
        };
        let rpc = daemon.rpc();
        let store = cx.new(|cx| ChannelStore::new(rpc, subscribe, "c1".into(), cx));
        cx.run_until_parked();
        (store, subscribed)
    }

    fn ids(list: &MessageList) -> Vec<&str> {
        list.messages().iter().map(|m| m.id.as_str()).collect()
    }

    #[test]
    fn a_list_is_patched_by_id_and_kept_in_time_order() {
        let mut list = MessageList::default();
        list.replace(vec![message("m3", 30, "c"), message("m2", 20, "b")], true);
        assert_eq!(ids(&list), ["m2", "m3"]);
        let v2 = list.version("m2");
        // A late arrival goes where its time says; an edit replaces in place
        // and changes only its own version.
        assert!(list.apply(&change(
            vec![message("m1", 10, "a"), message("m3", 30, "c!")],
            &[]
        )));
        assert_eq!(ids(&list), ["m1", "m2", "m3"]);
        assert_eq!(list.get("m3").unwrap().content, "c!");
        assert_eq!(list.version("m2"), v2);
        assert!(list.apply(&change(vec![], &["m2"])));
        assert_eq!(ids(&list), ["m1", "m3"]);
        // A full change asks for the list again.
        let mut full = change(vec![], &[]);
        full.full = true;
        assert!(!list.apply(&full));
        // An older page goes above.
        list.prepend_older(vec![message("m0", 5, "z")], false);
        assert_eq!(ids(&list), ["m0", "m1", "m3"]);
        assert!(!list.has_older);
    }

    #[test]
    fn typing_is_said_at_once_then_at_most_every_few_seconds() {
        let mut pace = TypingPace::default();
        let t0 = Instant::now();
        assert_eq!(pace.changed(true, t0), Some(true));
        assert_eq!(pace.changed(true, t0 + Duration::from_secs(1)), None);
        assert_eq!(pace.changed(true, t0 + TYPING_EVERY), Some(true));
        assert_eq!(pace.changed(false, t0 + TYPING_EVERY), Some(false));
        assert_eq!(pace.changed(false, t0 + TYPING_EVERY), None);
        assert_eq!(pace.sent(), None);
        pace.changed(true, t0);
        assert_eq!(pace.sent(), Some(false));
    }

    #[gpui_kit::test]
    fn opening_reads_the_channel_and_its_newest_page(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChannelsOpen>(details("c1"));
        daemon.returns::<methods::ChannelsMessages>(page(
            vec![message("m2", 20, "b"), message("m1", 10, "a")],
            true,
        ));
        let (store, subscribed) = open(&daemon, cx);
        store.read_with(cx, |s, _| {
            assert!(s.loaded && s.details.is_some());
            assert_eq!(ids(&s.list), ["m1", "m2"]);
            assert!(s.list.has_older);
        });
        assert_eq!(*subscribed.borrow(), [Some("c1".to_string())]);
        // A change for this channel is patched in; another channel's is not.
        store.update(cx, |s, cx| {
            s.on_event(
                &Event::ChannelsMessage(change(vec![message("m3", 30, "c")], &[])),
                cx,
            );
            let mut other = change(vec![message("x", 40, "x")], &[]);
            other.channel_id = "c2".into();
            s.on_event(&Event::ChannelsMessage(other), cx);
        });
        store.read_with(cx, |s, _| assert_eq!(ids(&s.list), ["m1", "m2", "m3"]));
        assert_eq!(daemon.calls::<methods::ChannelsMessages>().len(), 1);
        // Older messages: asked once while one page is on its way.
        daemon.returns::<methods::ChannelsMessages>(page(
            vec![
                message("m3", 30, "c"),
                message("m2", 20, "b"),
                message("m1", 10, "a"),
                message("m0", 5, "z"),
            ],
            false,
        ));
        store.update(cx, |s, cx| {
            s.load_older(cx);
            s.load_older(cx);
        });
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::ChannelsMessages>().len(), 2);
        store.read_with(cx, |s, _| {
            assert_eq!(ids(&s.list), ["m0", "m1", "m2", "m3"]);
            assert!(!s.list.has_older);
        });
        store.update(cx, |s, cx| s.close(cx));
        assert_eq!(subscribed.borrow().last(), Some(&None));
    }

    #[gpui_kit::test]
    fn posting_replies_and_reacting_go_to_the_daemon(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChannelsOpen>(details("c1"));
        daemon.returns::<methods::ChannelsMessages>(page(vec![message("m1", 10, "a")], false));
        daemon.returns::<methods::ChannelsPost>(message("m2", 20, "hello"));
        daemon.returns::<methods::ChannelsTyping>(OkResult { ok: true });
        daemon.returns::<methods::ChannelsReact>(OkResult { ok: true });
        let (store, _) = open(&daemon, cx);
        let events: Rc<RefCell<Vec<ChannelStoreEvent>>> = Rc::default();
        cx.update(|cx| {
            let events = events.clone();
            cx.subscribe(&store, move |_, e: &ChannelStoreEvent, _| {
                events.borrow_mut().push(e.clone())
            })
            .detach();
        });
        store.update(cx, |s, cx| {
            s.typed(true, cx);
            s.reply_to(Some("m1".into()), cx);
            drop(s.post("hello".into(), vec![], vec![], None, cx));
        });
        cx.run_until_parked();
        let post = daemon.calls::<methods::ChannelsPost>();
        assert_eq!(post[0]["replyToId"], "m1");
        // "Typing", then "stopped" once the message went.
        let typing: Vec<bool> = daemon
            .calls::<methods::ChannelsTyping>()
            .iter()
            .map(|c| c["typing"].as_bool().unwrap())
            .collect();
        assert_eq!(typing, [true, false]);
        store.read_with(cx, |s, _| {
            assert_eq!(ids(&s.list), ["m1", "m2"]);
            assert!(s.replying_to.is_none());
        });
        assert_eq!(*events.borrow(), [ChannelStoreEvent::Posted]);
        // A reaction already the user's is taken back.
        let mut mine = message("m1", 10, "a");
        mine.reactions = vec![
            serde_json::from_value(serde_json::json!({
                "name": "👍", "count": 1, "mine": true,
            }))
            .unwrap(),
        ];
        store.update(cx, |s, cx| {
            s.list.upsert(mine);
            s.toggle_reaction("m1", "👍", cx);
            s.toggle_reaction("m1", "🎉", cx);
        });
        cx.run_until_parked();
        let reacts = daemon.calls::<methods::ChannelsReact>();
        assert_eq!(reacts[0]["add"], false);
        assert_eq!(reacts[1]["add"], true);

        // An edit the daemon refuses keeps its words: the editor opens on
        // the message again, holding them.
        daemon.on::<methods::ChannelsEditMessage>(|_| {
            Err(conduit_daemon::protocol::error("rpc.timeout", "slow"))
        });
        store.update(cx, |s, cx| {
            s.start_editing(Some("m1".into()), cx);
            s.save_edit("m1", "a, then the beans".into(), cx);
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(
                s.editing.as_deref(),
                Some("m1"),
                "the refused edit's editor closed"
            );
            assert_eq!(s.edit_draft.as_deref(), Some("a, then the beans"));
        });
    }

    #[gpui_kit::test]
    fn app_answers_show_under_their_message_until_dismissed(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChannelsOpen>(details("c1"));
        daemon.returns::<methods::ChannelsMessages>(page(vec![message("m1", 10, "a")], false));
        let (store, _) = open(&daemon, cx);
        let reply = |title: &str| -> ChannelAppReplyEvent {
            serde_json::from_value(serde_json::json!({
                "channelId": "c1", "messageId": "m1", "appId": "a1",
                "reply": {"title": title},
            }))
            .unwrap()
        };
        store.update(cx, |s, cx| {
            s.on_event(&Event::ChannelsAppReply(reply("First")), cx);
            s.on_event(&Event::ChannelsAppReply(reply("Second")), cx);
        });
        store.read_with(cx, |s, _| {
            assert_eq!(s.app_replies.len(), 1);
            assert_eq!(s.app_replies[0].reply.title, "Second");
        });
        store.update(cx, |s, cx| s.dismiss_app_reply("m1", "a1", cx));
        store.read_with(cx, |s, _| assert!(s.app_replies.is_empty()));
        // A refused button says why, under its message.
        let mut refused = conduit_daemon::protocol::error("net.serverError", "app");
        refused
            .args
            .insert("detail".into(), "App is not connected".into());
        daemon.once::<methods::ChannelsAppAction>(Err(refused));
        let failures: Rc<RefCell<Vec<ChannelStoreEvent>>> = Rc::default();
        cx.update(|cx| {
            let failures = failures.clone();
            cx.subscribe(&store, move |_, e: &ChannelStoreEvent, _| {
                failures.borrow_mut().push(e.clone())
            })
            .detach();
        });
        store.update(cx, |s, cx| s.press_app_action("m1", "track", None, cx));
        store.read_with(cx, |s, _| assert_eq!(s.pending_actions, ["m1"]));
        cx.run_until_parked();
        store.read_with(cx, |s, _| assert!(s.pending_actions.is_empty()));
        assert_eq!(
            *failures.borrow(),
            [ChannelStoreEvent::Failed(Failure::AppAction {
                message_id: "m1".into(),
                detail: Some("App is not connected".into()),
            })]
        );
    }

    #[gpui_kit::test]
    fn a_thread_has_its_own_list(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChannelsOpen>(details("c1"));
        daemon.once::<methods::ChannelsMessages>(Ok(page(vec![message("m1", 10, "a")], false)));
        let (store, _) = open(&daemon, cx);
        let mut reply = message("r1", 15, "re");
        reply.parent_id = Some("m1".into());
        daemon.once::<methods::ChannelsMessages>(Ok(ChannelMessages {
            channel_id: "c1".into(),
            parent_id: Some("m1".into()),
            messages: vec![reply.clone()],
            has_older: false,
        }));
        store.update(cx, |s, cx| s.open_thread(Some("m1".into()), cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            let t = s.thread.as_ref().unwrap();
            assert!(!t.loading);
            assert_eq!(ids(&t.list), ["r1"]);
            // The timeline keeps its own messages.
            assert_eq!(ids(&s.list), ["m1"]);
        });
        let mut second = message("r2", 16, "again");
        second.parent_id = Some("m1".into());
        let mut thread_change = change(vec![second], &[]);
        thread_change.parent_id = Some("m1".into());
        store.update(cx, |s, cx| {
            s.on_event(&Event::ChannelsMessage(thread_change), cx)
        });
        store.read_with(cx, |s, _| {
            assert_eq!(ids(&s.thread.as_ref().unwrap().list), ["r1", "r2"]);
            assert_eq!(ids(&s.list), ["m1"]);
        });
        store.update(cx, |s, cx| s.open_thread(None, cx));
        store.read_with(cx, |s, _| assert!(s.thread.is_none()));
    }
}
