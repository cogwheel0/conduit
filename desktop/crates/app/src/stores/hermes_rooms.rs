//! Hermes Bot Mode and Group Chats: the bots (`hermes.bots.list`), their
//! pictures (`hermes.bots.avatar`, decoded once), the rooms
//! (`hermes.rooms.list`, kept by `hermes.rooms.listChanged`), and the room
//! the main window shows, watched while it is shown (`hermes.rooms.watch`,
//! kept by `hermes.rooms.changed` under the room's scope).
//!
//! The daemon reads an open room every 2 s, as the phone's room page does,
//! and projects it as the page draws it; here it is only kept and drawn.
//! Everything is read again after a reconnect or an event gap, on
//! `hermes.changed` (the connection changed), and forgotten when the
//! account changes. A bot's Bot Chat opens as any Hermes session does: the
//! store only remembers which session is which bot's, for the sidebar's
//! selection.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;

use conduit_protocol::{
    Event, HermesBotDto, HermesBotRef, HermesBots, HermesRoomDto, HermesRoomMemberDto,
    HermesRoomRef, HermesRoomView, HermesRooms, NoParams, events, methods,
};
use gpui_kit::{App, AsyncApp, Context, Image, Task, WeakEntity};

use super::Stores;
use super::connection::ConnectionEvent;
use super::navigation::{AreaItem, NavigationEvent, Selection};
use super::rpc::Rpc;
use super::session::Route;

/// The window's bots and rooms, for views far from the stores (a reply in a
/// Bot Chat draws its bot's face).
pub struct HermesRoomsGlobal(pub gpui_kit::Entity<HermesRoomsStore>);

impl gpui_kit::Global for HermesRoomsGlobal {}

/// The scope a room's `hermes.rooms.changed` comes under.
pub fn room_scope(room_id: &str) -> String {
    format!("hermes-room:{room_id}")
}

/// Whose a room's words are: the account, the Hermes gateway (its address
/// and profile -- the same across reconnects, unlike the daemon's name for
/// a connection) and the room. A pane shows and sends only its own key's.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct RoomKey {
    pub account: Option<String>,
    pub gateway: Option<String>,
    pub room: String,
}

/// A send to a room whose fate is not known yet. While one is kept for a
/// key, no other message goes to that room from this app: only the same
/// send again, which the room posts at most once.
#[derive(Clone, Debug, PartialEq)]
pub struct Unresolved {
    /// The send's identity: an answer settles only its own send.
    pub token: u64,
    /// As sent (trimmed).
    pub text: String,
    /// The newest event the room showed when they went out: only a message
    /// after it can be them.
    pub after: i64,
    /// An attempt is out (its answer not in yet).
    pub in_flight: bool,
}

impl Unresolved {
    /// Whether `view`'s log shows these words posted: the user's own
    /// message with them, newer than the send.
    pub fn posted_in(&self, view: &HermesRoomView) -> bool {
        view.items.iter().any(|item| {
            item.kind == conduit_protocol::HermesRoomItemKind::Message
                && item.own
                && item.seq > self.after
                && item.text.trim() == self.text
        })
    }
}

/// What a send's answer says.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SendOutcome {
    /// Hermes has the words.
    Posted,
    /// Nothing was posted.
    Refused,
    /// Unknown (an unclear answer, or no answer).
    Unclear,
}

/// The newest event `view` shows.
pub fn newest_seq(view: &HermesRoomView) -> i64 {
    view.items.iter().map(|i| i.seq).max().unwrap_or(i64::MIN)
}

/// The room the main window shows.
#[derive(Clone, Debug)]
pub struct OpenRoom {
    pub room_id: String,
    /// The daemon's last word on it; None until the first read.
    pub view: Option<HermesRoomView>,
    /// When `view` arrived: a working bot's time counts on from there.
    pub received: Instant,
    /// The watch itself failed (the daemon or the connection).
    pub failed: bool,
}

#[derive(Default)]
pub struct HermesRoomsStore {
    rpc: Option<Rpc>,
    /// None until listed (for this account and connection).
    pub bots: Option<HermesBots>,
    pub rooms: Option<HermesRooms>,
    /// Bots' pictures, by bot: None while asked, or when it has none.
    avatars: HashMap<String, Option<Arc<Image>>>,
    /// The bot whose chat is opening (its row shows a spinner).
    pub opening_bot: Option<String>,
    /// Bot Chat sessions opened here, by session: the bot's name.
    bot_sessions: HashMap<String, String>,
    pub room: Option<OpenRoom>,
    /// The Hermes area is shown.
    wanted: bool,
    /// Bumped per account and per Hermes connection: answers asked before
    /// are dropped.
    generation: u64,
    /// The Hermes connection everything here was read on, as the daemon
    /// names it (`hermes.changed`, and every list and view): requests go out
    /// under it, and an answer read on another one is dropped. None until
    /// the daemon says (after a reconnect: a new daemon names anew).
    connection: Option<String>,
    /// The bot open under way, by the generation it was asked in.
    opening_token: u64,
    /// The account in charge, as the accounts store names it.
    account: Option<String>,
    /// The Hermes gateway in use (address and profile), as settings say.
    gateway: Option<String>,
    /// Words typed in a room's field and not sent, by [`RoomKey`]: they
    /// wait for the room while another shows (the user's own, so a
    /// reconnect drops none of them).
    drafts: HashMap<RoomKey, String>,
    /// Sends whose fate is not known yet, by [`RoomKey`]: kept apart from
    /// the field's words, which a restored draft never replaces.
    unresolved: HashMap<RoomKey, Unresolved>,
    /// Words a send for the key was answered as having posted, until the
    /// pane showing that key gives them up (one opened since included).
    confirmed: HashMap<RoomKey, String>,
    /// The last send identity given out.
    last_token: u64,
    revision: u64,
    fetches: Vec<Task<()>>,
    watch: Option<Task<()>>,
}

impl HermesRoomsStore {
    pub fn new(rpc: Rpc) -> Self {
        Self {
            rpc: Some(rpc),
            ..Self::default()
        }
    }

    pub fn rpc(&self) -> Option<Rpc> {
        self.rpc.clone()
    }

    /// The account in charge: room drafts are its own.
    pub fn set_account(&mut self, account: Option<String>) {
        self.account = account;
    }

    /// The Hermes gateway in use: room drafts are its own.
    pub fn set_gateway(&mut self, gateway: Option<String>) {
        self.gateway = gateway;
    }

    /// The key room `room_id`'s words go under now.
    pub fn room_key(&self, room_id: &str) -> RoomKey {
        RoomKey {
            account: self.account.clone(),
            gateway: self.gateway.clone(),
            room: room_id.to_string(),
        }
    }

    /// Words typed for `key` and not sent.
    pub fn draft(&self, key: &RoomKey) -> Option<&str> {
        self.drafts.get(key).map(String::as_str)
    }

    /// Keeps what `key`'s field holds while its room is not shown (empty:
    /// nothing to keep).
    pub fn keep_draft(&mut self, key: &RoomKey, text: &str) {
        if text.trim().is_empty() {
            self.drafts.remove(key);
        } else {
            self.drafts.insert(key.clone(), text.to_string());
        }
    }

    /// The send for `key` whose fate is not known yet.
    pub fn unresolved(&self, key: &RoomKey) -> Option<&Unresolved> {
        self.unresolved.get(key)
    }

    /// Starts a new send of `text` for `key`: its identity, or None while
    /// another send for the key is unresolved -- nothing else goes to that
    /// room until it is settled (its answer, its words in the log, or the
    /// user's Discard or Try Again).
    pub fn begin_send(&mut self, key: &RoomKey, text: &str, after: i64) -> Option<u64> {
        if self.unresolved.contains_key(key) {
            return None;
        }
        self.last_token += 1;
        let token = self.last_token;
        self.unresolved.insert(
            key.clone(),
            Unresolved {
                token,
                text: text.to_string(),
                after,
                in_flight: true,
            },
        );
        Some(token)
    }

    /// Try Again: `key`'s unresolved send goes again as itself, when no
    /// attempt is out: its identity and words.
    pub fn retry_send(&mut self, key: &RoomKey) -> Option<(u64, String)> {
        let u = self.unresolved.get_mut(key).filter(|u| !u.in_flight)?;
        u.in_flight = true;
        Some((u.token, u.text.clone()))
    }

    /// A send's answer: it settles only its own send. Posted, its words are
    /// posted: a draft still holding exactly them goes, and whatever pane
    /// shows the key now (the one that sent, or one opened since) gives
    /// them up. Refused, nothing was posted. Unclear, the send stays,
    /// waiting on the room.
    pub fn finish_send(
        &mut self,
        key: &RoomKey,
        token: u64,
        outcome: SendOutcome,
        cx: &mut Context<Self>,
    ) {
        let Some(u) = self.unresolved.get_mut(key).filter(|u| u.token == token) else {
            return;
        };
        match outcome {
            // The answer did not say: the send stays unresolved until its
            // words show in the room's log or the user acts.
            SendOutcome::Unclear => u.in_flight = false,
            SendOutcome::Refused => {
                self.unresolved.remove(key);
            }
            SendOutcome::Posted => self.settle_posted(key),
        }
        cx.notify();
    }

    /// The send for `key` is posted: it goes, a draft still holding exactly
    /// its words goes, and whatever pane shows the key gives them up.
    fn settle_posted(&mut self, key: &RoomKey) {
        let Some(u) = self.unresolved.remove(key) else {
            return;
        };
        if self.drafts.get(key).is_some_and(|d| d.trim() == u.text) {
            self.drafts.remove(key);
        }
        self.confirmed.insert(key.clone(), u.text);
    }

    /// The user lets `key`'s unresolved send go: its words stay in the
    /// field, to send again or not.
    pub fn discard_unresolved(&mut self, key: &RoomKey, cx: &mut Context<Self>) {
        if self.unresolved.get(key).is_some_and(|u| !u.in_flight) {
            self.unresolved.remove(key);
            cx.notify();
        }
    }

    /// Words the room still holds for a retry, with no send of ours kept:
    /// followed as an unresolved send of their own (a room opened again).
    pub fn adopt_unsent(&mut self, key: &RoomKey, text: &str, after: i64) {
        if self.unresolved.contains_key(key) {
            return;
        }
        self.last_token += 1;
        self.unresolved.insert(
            key.clone(),
            Unresolved {
                token: self.last_token,
                text: text.to_string(),
                after,
                in_flight: false,
            },
        );
    }

    /// The room's log shows send `token`'s exact words, as the user's own
    /// message, newer than the send: a confirmed post, settled as a send
    /// answered as sent (a draft still holding exactly them goes, and the
    /// pane showing the key gives them up if its field holds exactly them).
    pub fn settle_seen_posted(&mut self, key: &RoomKey, token: u64) {
        if self.unresolved.get(key).is_some_and(|u| u.token == token) {
            self.settle_posted(key);
        }
    }

    /// The words confirmed posted for `key` since its pane last looked.
    pub fn take_confirmed(&mut self, key: &RoomKey) -> Option<String> {
        self.confirmed.remove(key)
    }

    /// The Hermes connection requests go out under.
    pub fn connection(&self) -> Option<String> {
        self.connection.clone()
    }

    /// Whether an answer read on `connection` belongs here: the one in use,
    /// or the first one heard of (taken as in use). An answer that names
    /// none (an older daemon) is kept.
    ///
    /// Answers and events come in the order the daemon sent them (one
    /// socket), and each names the connection in use when it was sent: one
    /// naming another connection than the last answer did is newer, so the
    /// connection changed since -- everything read before goes (only what
    /// was asked before now) and is read again on it. Ordering by when a
    /// request was asked would be wrong: a read asked earlier can be
    /// answered later, on the newer connection.
    fn belongs(&mut self, connection: Option<&str>, cx: &mut Context<Self>) -> bool {
        match (connection, self.connection.as_deref()) {
            (None, _) => true,
            (Some(c), None) => {
                self.connection = Some(c.to_string());
                true
            }
            (Some(c), Some(current)) if c == current => true,
            (Some(c), Some(_)) => {
                self.drop_connection(Some(c.to_string()), cx);
                false
            }
        }
    }

    /// The daemon names the Hermes connection in use: another one than
    /// what was shown so far drops everything read on the last one.
    fn follow_connection(&mut self, now: Option<&str>, cx: &mut Context<Self>) {
        let Some(now) = now else {
            self.refresh(cx);
            return;
        };
        let shown = self
            .room
            .as_ref()
            .and_then(|r| r.view.as_ref())
            .and_then(|v| v.connection.clone());
        let last = self.connection.clone().or(shown);
        if last.as_deref().is_none_or(|last| last == now) {
            self.connection = Some(now.to_string());
            self.refresh(cx);
            return;
        }
        self.drop_connection(Some(now.to_string()), cx);
    }

    /// The one place the store lets go of a Hermes connection: whenever
    /// what names it is lost or changes (a connection edit, a reconnect, an
    /// event gap, another account or none), everything read on it goes at
    /// once -- the lists, the open room's transcript and state, faces, Bot
    /// Chats, any open under way -- and every answer asked before is
    /// dropped, so nothing shown can act on another connection. It is all
    /// read again, the open room watched anew; `now` names the connection in
    /// use when known (else the next answer names it).
    fn drop_connection(&mut self, now: Option<String>, cx: &mut Context<Self>) {
        self.connection = now;
        self.generation += 1;
        self.bots = None;
        self.rooms = None;
        self.avatars.clear();
        self.bot_sessions.clear();
        self.opening_bot = None;
        self.fetches.clear();
        self.watch = None;
        if let Some(room) = &mut self.room {
            room.view = None;
            room.failed = false;
            room.received = Instant::now();
        }
        self.refresh(cx);
        self.watch_open(cx);
        self.changed(cx);
    }

    /// The daemon connection was made again (a new daemon names its
    /// connections anew), or events were lost: what names the Hermes
    /// connection is gone.
    pub fn connection_lost(&mut self, cx: &mut Context<Self>) {
        self.drop_connection(None, cx);
    }

    /// Bumped whenever something listed changed (the sidebar's rows cache).
    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// The bots, when the gateway has Bot Mode.
    pub fn bot_list(&self) -> &[HermesBotDto] {
        match &self.bots {
            Some(bots) if bots.available => &bots.bots,
            _ => &[],
        }
    }

    pub fn bot(&self, name: &str) -> Option<&HermesBotDto> {
        self.bot_list().iter().find(|b| b.name == name)
    }

    /// The bot whose Bot Chat session `session_id` is, as this window
    /// knows it: opened here, or named by the roster.
    pub fn bot_of_session(&self, session_id: &str) -> Option<&HermesBotDto> {
        if let Some(name) = self.bot_sessions.get(session_id) {
            return self.bot(name);
        }
        self.bot_list()
            .iter()
            .find(|b| b.session_id.as_deref() == Some(session_id))
    }

    /// The rooms listed, when the gateway hosts Group Chats.
    pub fn room_list(&self) -> &[HermesRoomDto] {
        match &self.rooms {
            Some(rooms) if rooms.available => &rooms.rooms,
            _ => &[],
        }
    }

    pub fn listed_room(&self, room_id: &str) -> Option<&HermesRoomDto> {
        self.room_list().iter().find(|r| r.id == room_id)
    }

    /// Room `room_id` as best known: the open room's own read, else the
    /// list's row.
    pub fn room(&self, room_id: &str) -> Option<&HermesRoomDto> {
        self.room
            .as_ref()
            .filter(|r| r.room_id == room_id)
            .and_then(|r| r.view.as_ref())
            .and_then(|v| v.room.as_ref())
            .or_else(|| self.listed_room(room_id))
    }

    /// A new room can be made here.
    pub fn can_create(&self) -> bool {
        self.rooms
            .as_ref()
            .is_some_and(|r| r.available && r.can_create)
    }

    /// The open room's view, if it is `room_id`.
    pub fn view(&self, room_id: &str) -> Option<&HermesRoomView> {
        self.room
            .as_ref()
            .filter(|r| r.room_id == room_id)
            .and_then(|r| r.view.as_ref())
    }

    /// Bot `name`'s picture, asked for once; None until it arrives (and for
    /// a bot without one).
    pub fn avatar(&mut self, name: &str, cx: &mut Context<Self>) -> Option<Arc<Image>> {
        if let Some(known) = self.avatars.get(name) {
            return known.clone();
        }
        if !self.bot(name).is_some_and(|b| b.has_avatar) {
            return None;
        }
        let rpc = self.rpc.clone()?;
        self.avatars.insert(name.to_string(), None);
        let generation = self.generation;
        let call = rpc.call::<methods::HermesBotsAvatar>(&HermesBotRef {
            name: name.to_string(),
            connection: self.connection.clone(),
        });
        let name = name.to_string();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                if s.generation != generation {
                    return;
                }
                let image = result
                    .ok()
                    .and_then(|a| a.image)
                    .and_then(|uri| crate::views::chat::markdown::decode_data_image(&uri))
                    .map(Arc::new);
                if image.is_some() {
                    s.avatars.insert(name, image);
                    s.changed(cx);
                }
            });
        })
        .detach();
        None
    }

    /// The picture already read for `name`, without asking.
    pub fn known_avatar(&self, name: &str) -> Option<Arc<Image>> {
        self.avatars.get(name).cloned().flatten()
    }

    /// Bot `name`'s chat is session `session_id`.
    pub fn note_bot_session(&mut self, session_id: &str, name: &str, cx: &mut Context<Self>) {
        self.bot_sessions
            .insert(session_id.to_string(), name.to_string());
        self.changed(cx);
    }

    /// Starts opening bot `name`'s chat (its row shows a spinner): a token
    /// for [`Self::finish_opening_bot`], or None while another opens.
    pub fn begin_opening_bot(&mut self, name: &str, cx: &mut Context<Self>) -> Option<u64> {
        if self.opening_bot.is_some() {
            return None;
        }
        self.opening_token = self.generation;
        self.set_opening_bot(Some(name.to_string()), cx);
        Some(self.opening_token)
    }

    /// The open begun with `token` answered (with its session when it
    /// opened). False when the account or the connection changed since:
    /// nothing of it is kept, and an open begun after keeps its spinner.
    pub fn finish_opening_bot(
        &mut self,
        token: u64,
        session: Option<&str>,
        cx: &mut Context<Self>,
    ) -> bool {
        if token != self.generation || self.opening_token != token {
            return false;
        }
        let Some(name) = self.opening_bot.take() else {
            return false;
        };
        if let Some(session) = session {
            self.bot_sessions.insert(session.to_string(), name);
        }
        self.changed(cx);
        true
    }

    pub fn set_opening_bot(&mut self, name: Option<String>, cx: &mut Context<Self>) {
        self.opening_bot = name;
        self.changed(cx);
    }

    /// The list as an action answered it.
    pub fn adopt_rooms(&mut self, rooms: HermesRooms, cx: &mut Context<Self>) {
        self.rooms = Some(rooms);
        self.changed(cx);
    }

    /// Shows the Hermes area from now on (lists it), or not (forgets).
    pub fn set_wanted(&mut self, wanted: bool, cx: &mut Context<Self>) {
        if wanted == self.wanted {
            return;
        }
        self.wanted = wanted;
        if wanted {
            self.refresh(cx);
        } else {
            self.bots = None;
            self.rooms = None;
            self.fetches.clear();
            self.changed(cx);
        }
    }

    /// Another account (or none): everything goes.
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.drop_connection(None, cx);
    }

    /// Lists the bots and the rooms again (while the area is shown).
    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        if !self.wanted {
            return;
        }
        let Some(rpc) = self.rpc.clone() else {
            return;
        };
        let generation = self.generation;
        let bots = rpc.call::<methods::HermesBotsList>(&NoParams);
        let rooms = rpc.call::<methods::HermesRoomsList>(&NoParams);
        self.fetches = vec![
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = bots.await;
                let _ = this.update(cx, |s, cx| {
                    if s.generation != generation {
                        return;
                    }
                    match result {
                        Ok(bots) if !s.belongs(bots.connection.as_deref(), cx) => return,
                        Ok(bots) => {
                            // A picture changed with the roster is read again.
                            s.avatars.retain(|name, _| {
                                bots.bots.iter().any(|b| b.name == *name && b.has_avatar)
                            });
                            s.bots = Some(bots);
                        }
                        Err(e) => log::warn!("hermes.bots.list: {e}"),
                    }
                    s.changed(cx);
                });
            }),
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = rooms.await;
                let _ = this.update(cx, |s, cx| {
                    if s.generation != generation {
                        return;
                    }
                    match result {
                        Ok(rooms) if !s.belongs(rooms.connection.as_deref(), cx) => return,
                        Ok(rooms) => s.rooms = Some(rooms),
                        Err(e) => {
                            log::warn!("hermes.rooms.list: {e}");
                            if let Some(rooms) = &mut s.rooms {
                                rooms.failed = true;
                            }
                        }
                    }
                    s.changed(cx);
                });
            }),
        ];
    }

    /// Shows room `room_id` (None: no room): watches it, and stops watching
    /// the one shown before.
    pub fn show(&mut self, room_id: Option<&str>, cx: &mut Context<Self>) {
        let current = self.room.as_ref().map(|r| r.room_id.as_str());
        if current == room_id {
            return;
        }
        if let (Some(old), Some(rpc)) = (current, self.rpc.as_ref()) {
            // Sent at once; nothing waits for it.
            drop(rpc.call::<methods::HermesRoomsUnwatch>(&HermesRoomRef {
                room_id: old.to_string(),
                connection: self.connection.clone(),
            }));
        }
        self.watch = None;
        self.room = room_id.map(|id| OpenRoom {
            room_id: id.to_string(),
            view: None,
            received: Instant::now(),
            failed: false,
        });
        self.watch_open(cx);
        self.changed(cx);
    }

    /// Asks for the open room again (a reconnect, Try Again).
    pub fn watch_open(&mut self, cx: &mut Context<Self>) {
        let (Some(room), Some(rpc)) = (self.room.as_ref(), self.rpc.clone()) else {
            return;
        };
        let room_id = room.room_id.clone();
        let generation = self.generation;
        let call = rpc.call::<methods::HermesRoomsWatch>(&HermesRoomRef {
            room_id: room_id.clone(),
            connection: self.connection.clone(),
        });
        self.watch = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    // Asked under the last account or connection.
                    if s.generation != generation {
                        return;
                    }
                    if let Ok(view) = &result
                        && !s.belongs(view.connection.as_deref(), cx)
                    {
                        return;
                    }
                    let Some(open) = s.room.as_mut().filter(|r| r.room_id == room_id) else {
                        return;
                    };
                    match result {
                        Ok(view) => {
                            open.view = Some(view);
                            open.received = Instant::now();
                            open.failed = false;
                        }
                        Err(e) => {
                            log::warn!("hermes.rooms.watch: {e}");
                            open.failed = true;
                        }
                    }
                    s.changed(cx);
                });
            }),
        );
    }

    /// The room `room_id` changed outside a read (an action answered with
    /// it, a rename): the list says so until it is read again.
    /// Which account and connection the store's answers are for now: an
    /// action captures it when asked and hands it back with its answer.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// `asked_in`: [`Self::generation`] when the action was asked; an answer
    /// from before an account or connection change lists nothing.
    pub fn patch_listed(&mut self, room: HermesRoomDto, asked_in: u64, cx: &mut Context<Self>) {
        if asked_in != self.generation {
            return;
        }
        if let Some(rooms) = &mut self.rooms {
            match rooms.rooms.iter_mut().find(|r| r.id == room.id) {
                Some(row) => *row = room,
                None => rooms.rooms.insert(0, room),
            }
            self.changed(cx);
        }
    }

    /// A daemon event.
    pub fn on_event(&mut self, event: &Event, cx: &mut Context<Self>) {
        match event {
            Event::HermesRoomsChanged(view) => {
                if !self.belongs(view.connection.as_deref(), cx) {
                    return;
                }
                if let Some(open) = self.room.as_mut().filter(|r| r.room_id == view.room_id) {
                    open.view = Some(view.clone());
                    open.received = Instant::now();
                    open.failed = false;
                    self.changed(cx);
                }
            }
            Event::HermesRoomsListChanged(rooms) => {
                if self.wanted && self.belongs(rooms.connection.as_deref(), cx) {
                    self.rooms = Some(rooms.clone());
                    self.changed(cx);
                }
            }
            Event::HermesChanged(changed) => {
                self.follow_connection(changed.connection.as_deref(), cx)
            }
            _ => {}
        }
    }

    fn changed(&mut self, cx: &mut Context<Self>) {
        self.revision += 1;
        cx.notify();
    }

    /// The members' faces a room shows, up to three (a room's picture).
    pub fn faces(room: &HermesRoomDto) -> &[HermesRoomMemberDto] {
        &room.members[..room.members.len().min(3)]
    }
}

/// The events the store follows, with the open room's scope.
fn subscribe(stores: &Stores, room: Option<&str>, cx: &mut App) {
    let scopes = room.map(room_scope).into_iter().collect();
    stores.connection.update(cx, |c, _| {
        c.subscribe(
            "hermes-rooms",
            &[
                events::HERMES_CHANGED,
                events::HERMES_ROOMS_CHANGED,
                events::HERMES_ROOMS_LIST_CHANGED,
            ],
            scopes,
        )
    });
}

/// The room a selection shows.
fn shown_room(selection: &Selection) -> Option<&str> {
    match selection {
        Selection::Area(AreaItem::HermesRoom(id)) => Some(id),
        _ => None,
    }
}

/// Follows the daemon's events, the session and the navigation for
/// `stores.hermes_rooms`.
pub fn wire(stores: &Stores, cx: &mut App) {
    cx.set_global(HermesRoomsGlobal(stores.hermes_rooms.clone()));
    subscribe(stores, None, cx);
    {
        let s = stores.clone();
        cx.subscribe(&stores.connection, move |_, event, cx| match event {
            ConnectionEvent::Connected { .. } | ConnectionEvent::Gap => {
                // The bot whose Bot Chat is on screen, before its binding goes
                // with the rest.
                let bot = match s.navigation.read(cx).selection() {
                    Selection::Area(AreaItem::HermesSession(session)) => {
                        s.hermes_rooms.read(cx).bot_sessions.get(session).cloned()
                    }
                    _ => None,
                };
                s.hermes_rooms.update(cx, |h, cx| h.connection_lost(cx));
                // A Bot Chat on screen is bound to its bot again: a new
                // daemon knows nothing of the binding.
                if let Some(name) = bot {
                    crate::views::hermes_rooms::open_bot(&s, &name, cx);
                }
            }
            ConnectionEvent::Daemon(event) => {
                let event = event.clone();
                s.hermes_rooms.update(cx, |h, cx| h.on_event(&event, cx));
            }
            _ => {}
        })
        .detach();
    }
    {
        let s = stores.clone();
        cx.subscribe(&stores.navigation, move |_, event, cx| {
            let NavigationEvent::Changed(selection) = event;
            let room = shown_room(selection).map(str::to_string);
            subscribe(&s, room.as_deref(), cx);
            s.hermes_rooms
                .update(cx, |h, cx| h.show(room.as_deref(), cx));
        })
        .detach();
    }
    let last_account: std::rc::Rc<std::cell::RefCell<Option<Option<String>>>> = Default::default();
    let check = {
        let s = stores.clone();
        move |cx: &mut App| {
            let account = s
                .accounts
                .read(cx)
                .list
                .as_ref()
                .and_then(|l| l.active_account_id.clone());
            let changed = last_account
                .borrow()
                .as_ref()
                .is_some_and(|last| *last != account);
            *last_account.borrow_mut() = Some(account.clone());
            s.hermes_rooms.update(cx, |h, _| h.set_account(account));
            if changed {
                s.hermes_rooms.update(cx, |h, cx| h.reset(cx));
            }
            let session = s.session.read(cx);
            let wanted = session.route(cx) == Route::Main && session.capabilities().hermes;
            // The gateway room drafts belong to: its address and profile,
            // the same across reconnects.
            let gateway = session
                .hermes
                .as_ref()
                .map(|h| format!("{}#{}", h.base_url.trim_end_matches('/'), h.desktop_profile));
            s.hermes_rooms.update(cx, |h, cx| {
                h.set_gateway(gateway);
                h.set_wanted(wanted, cx);
                if changed && wanted {
                    h.refresh(cx);
                }
            });
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
    use gpui_kit::{AppContext as _, TestAppContext};
    use serde_json::json;

    use super::*;
    use crate::stores::Stores;
    use crate::stores::rpc::fake::FakeDaemon;

    fn view(room_id: &str, name: &str, items: usize) -> HermesRoomView {
        let items: Vec<_> = (1..=items)
            .map(|seq| json!({"kind": "message", "key": format!("message:{seq}"), "seq": seq, "text": "hello"}))
            .collect();
        serde_json::from_value(json!({
            "roomId": room_id, "loaded": true,
            "room": {"id": room_id, "name": name},
            "items": items,
        }))
        .unwrap()
    }

    #[gpui_kit::test]
    fn the_shown_room_is_watched_and_its_changes_kept(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::HermesBotsList>(
            serde_json::from_value::<HermesBots>(json!({
                "available": true,
                "bots": [{"name": "fern", "title": "Fern", "sessionId": "bc-1"}],
            }))
            .unwrap(),
        );
        daemon.returns::<methods::HermesRoomsList>(
            serde_json::from_value::<HermesRooms>(json!({
                "available": true, "canCreate": true,
                "rooms": [{"id": "r1", "name": "Greenhouse crew"}],
            }))
            .unwrap(),
        );
        daemon.returns::<methods::HermesRoomsWatch>(view("r1", "Greenhouse crew", 0));
        let store = cx.new(|_| HermesRoomsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.set_wanted(true, cx);
            s.show(Some("r1"), cx);
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.bot_list().len(), 1);
            assert_eq!(s.bot_of_session("bc-1").unwrap().title, "Fern");
            assert!(s.can_create());
            assert_eq!(
                s.view("r1").unwrap().room.as_ref().unwrap().name,
                "Greenhouse crew"
            );
        });
        // A change for the shown room is kept; one for another is not.
        store.update(cx, |s, cx| {
            s.on_event(&Event::HermesRoomsChanged(view("r1", "Seed swap", 1)), cx);
            s.on_event(&Event::HermesRoomsChanged(view("r2", "Other", 3)), cx);
        });
        store.read_with(cx, |s, _| {
            assert_eq!(s.view("r1").unwrap().items.len(), 1);
            assert_eq!(s.room("r1").unwrap().name, "Seed swap");
        });
        // Nothing shown: the room is no longer watched.
        store.update(cx, |s, cx| s.show(None, cx));
        assert_eq!(daemon.calls::<methods::HermesRoomsUnwatch>().len(), 1);
        store.update(cx, |s, cx| s.reset(cx));
        store.read_with(cx, |s, _| assert!(s.bots.is_none() && s.rooms.is_none()));
    }

    fn view_on(room_id: &str, name: &str, items: usize, connection: &str) -> HermesRoomView {
        HermesRoomView {
            connection: Some(connection.into()),
            ..view(room_id, name, items)
        }
    }

    fn changed_to(connection: &str) -> Event {
        Event::HermesChanged(conduit_protocol::HermesChanged {
            connection: Some(connection.into()),
        })
    }

    fn lists(daemon: &FakeDaemon) {
        daemon.returns::<methods::HermesBotsList>(HermesBots::default());
        daemon.returns::<methods::HermesRoomsList>(HermesRooms::default());
    }

    #[gpui_kit::test]
    fn a_connection_edit_drops_the_open_room_and_watches_it_on_the_next(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        lists(&daemon);
        daemon.once::<methods::HermesRoomsWatch>(Ok(view_on("r1", "Greenhouse crew", 3, "c1")));
        let store = cx.new(|_| HermesRoomsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.set_wanted(true, cx);
            s.show(Some("r1"), cx);
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| assert_eq!(s.view("r1").unwrap().items.len(), 3));

        // The edit: what the last connection showed goes at once (no Send
        // against the next one on the last one's transcript), and the room
        // is watched again, asked under the next connection.
        let hold = daemon.hold::<methods::HermesRoomsWatch>();
        daemon.returns::<methods::HermesRoomsWatch>(view_on("r1", "Greenhouse crew", 0, "c2"));
        store.update(cx, |s, cx| s.on_event(&changed_to("c2"), cx));
        store.read_with(cx, |s, _| assert!(s.view("r1").is_none()));
        let watches = daemon.calls::<methods::HermesRoomsWatch>();
        assert_eq!(watches.len(), 2);
        assert_eq!(watches[1]["connection"], "c2");
        drop(hold);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            let view = s.view("r1").unwrap();
            assert_eq!(view.connection.as_deref(), Some("c2"));
            assert!(view.items.is_empty());
        });

        // Requests go out under the connection in use.
        store.update(cx, |s, cx| s.show(None, cx));
        assert_eq!(
            daemon.calls::<methods::HermesRoomsUnwatch>()[0]["connection"],
            "c2"
        );
    }

    #[gpui_kit::test]
    fn a_watch_answered_after_an_account_change_is_not_shown(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        lists(&daemon);
        daemon.once::<methods::HermesRoomsWatch>(Ok(view_on("r1", "Last account", 2, "c1")));
        daemon.returns::<methods::HermesRoomsWatch>(view_on("r1", "This account", 0, "c1"));
        let first = daemon.hold_one::<methods::HermesRoomsWatch>(0);
        let store = cx.new(|_| HermesRoomsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.show(Some("r1"), cx));
        cx.run_until_parked();
        store.update(cx, |s, cx| s.reset(cx));
        cx.run_until_parked();
        drop(first);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(
                s.view("r1").unwrap().room.as_ref().unwrap().name,
                "This account"
            )
        });
    }

    #[gpui_kit::test]
    fn a_bot_chat_opened_before_an_account_change_is_not_opened_after(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let store = cx.new(|_| HermesRoomsStore::new(daemon.rpc()));
        let before = store
            .update(cx, |s, cx| s.begin_opening_bot("fern", cx))
            .unwrap();
        store.update(cx, |s, cx| s.reset(cx));
        let after = store
            .update(cx, |s, cx| s.begin_opening_bot("fern", cx))
            .unwrap();
        // The first open's answer neither records its session nor clears the
        // second open's spinner.
        let took = store.update(cx, |s, cx| s.finish_opening_bot(before, Some("bc-old"), cx));
        assert!(!took);
        store.read_with(cx, |s, _| {
            assert_eq!(s.opening_bot.as_deref(), Some("fern"));
            assert!(s.bot_of_session("bc-old").is_none());
        });
        assert!(store.update(cx, |s, cx| s.finish_opening_bot(after, Some("bc-new"), cx)));
        store.read_with(cx, |s, _| {
            assert!(s.opening_bot.is_none());
            assert_eq!(
                s.bot_sessions.get("bc-new").map(String::as_str),
                Some("fern")
            );
        });
    }

    fn bots_on(connection: &str) -> HermesBots {
        serde_json::from_value(json!({
            "available": true, "connection": connection,
            "bots": [{"name": "fern", "title": "Fern", "sessionId": "bc-1"}],
        }))
        .unwrap()
    }

    fn rooms_on(connection: &str, name: &str) -> HermesRooms {
        serde_json::from_value(json!({
            "available": true, "canCreate": true, "connection": connection,
            "rooms": [{"id": "r1", "name": name}],
        }))
        .unwrap()
    }

    /// The connection is lost (`connected`: a reconnect, else an event gap)
    /// while room r1 and the bots read on c1 show; the next list, read on
    /// c2, comes before the room's own watch.
    fn connection_lost(cx: &mut TestAppContext, connected: bool) {
        use crate::stores::connection::ConnectionEvent;
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::HermesBotsList>(bots_on("c1"));
        daemon.returns::<methods::HermesRoomsList>(rooms_on("c1", "Greenhouse crew"));
        daemon.returns::<methods::HermesRoomsWatch>(view_on("r1", "Greenhouse crew", 3, "c1"));
        let scratch = std::env::temp_dir().join(format!(
            "conduit-hrooms-lost-{connected}-{}",
            std::process::id()
        ));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            let stores = Stores::for_test(daemon.rpc(), &scratch, cx);
            wire(&stores, cx);
            stores
        });
        let store = stores.hermes_rooms.clone();
        store.update(cx, |s, cx| {
            s.set_wanted(true, cx);
            s.show(Some("r1"), cx);
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.view("r1").unwrap().items.len(), 3);
            assert_eq!(s.bot_list().len(), 1);
        });

        // The replacement reads are slow; c2's list event comes first.
        let watches = daemon.hold::<methods::HermesRoomsWatch>();
        let bots = daemon.hold::<methods::HermesBotsList>();
        let lists = daemon.hold::<methods::HermesRoomsList>();
        daemon.returns::<methods::HermesRoomsWatch>(view_on("r1", "Seed swap", 0, "c2"));
        daemon.returns::<methods::HermesBotsList>(bots_on("c2"));
        daemon.returns::<methods::HermesRoomsList>(rooms_on("c2", "Seed swap"));
        stores.connection.update(cx, |_, cx| {
            if connected {
                cx.emit(ConnectionEvent::Connected {
                    handshake: Box::new(conduit_daemon::rpc::Handshake::from_value(json!({}))),
                    request: serde_json::from_value(json!({
                        "protocolVersion": "1", "clientName": "test", "clientVersion": "1",
                        "windowKind": "main", "locale": "en"
                    }))
                    .unwrap(),
                })
            } else {
                cx.emit(ConnectionEvent::Gap)
            }
        });
        let gone = |s: &HermesRoomsStore| {
            s.view("r1").is_none()
                && s.bots.is_none()
                && s.room("r1").is_none_or(|r| r.name != "Greenhouse crew")
        };
        store.read_with(cx, |s, _| {
            assert!(gone(s), "c1's room and bots stay actionable")
        });
        store.update(cx, |s, cx| {
            s.on_event(
                &Event::HermesRoomsListChanged(rooms_on("c2", "Seed swap")),
                cx,
            );
            s.on_event(&changed_to("c2"), cx);
        });
        store.read_with(cx, |s, _| {
            assert!(gone(s), "c1's room shows under c2");
            assert_eq!(s.connection().as_deref(), Some("c2"));
        });
        drop((watches, bots, lists));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.view("r1").unwrap().connection.as_deref(), Some("c2"));
            assert_eq!(s.bots.as_ref().unwrap().connection.as_deref(), Some("c2"));
        });
        // The requests went out after the loss under no stale name.
        let last = daemon.calls::<methods::HermesRoomsWatch>();
        assert_ne!(last.last().unwrap()["connection"], "c1");
    }

    #[gpui_kit::test]
    fn a_reconnect_drops_everything_the_last_connection_showed(cx: &mut TestAppContext) {
        connection_lost(cx, true);
    }

    #[gpui_kit::test]
    fn an_event_gap_drops_everything_the_last_connection_showed(cx: &mut TestAppContext) {
        connection_lost(cx, false);
    }

    #[gpui_kit::test]
    fn a_connection_edit_drops_the_last_connections_lists(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::HermesBotsList>(bots_on("c1"));
        daemon.returns::<methods::HermesRoomsList>(rooms_on("c1", "Greenhouse crew"));
        let store = cx.new(|_| HermesRoomsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.set_wanted(true, cx));
        cx.run_until_parked();
        let _held = (
            daemon.hold::<methods::HermesBotsList>(),
            daemon.hold::<methods::HermesRoomsList>(),
        );
        store.update(cx, |s, cx| s.on_event(&changed_to("c2"), cx));
        store.read_with(cx, |s, _| {
            assert!(s.bots.is_none() && s.rooms.is_none() && !s.can_create());
        });
    }

    #[gpui_kit::test]
    fn an_answer_read_on_a_newer_connection_wins_over_the_one_named_before(
        cx: &mut TestAppContext,
    ) {
        let daemon = FakeDaemon::new();
        // Two reads in flight; the connection changes between their answers
        // and nothing else says so (no hermes.changed).
        daemon.once::<methods::HermesBotsList>(Ok(bots_on("c1")));
        daemon.once::<methods::HermesRoomsList>(Ok(rooms_on("c2", "Seed swap")));
        daemon.returns::<methods::HermesBotsList>(bots_on("c2"));
        daemon.returns::<methods::HermesRoomsList>(rooms_on("c2", "Seed swap"));
        let rooms = daemon.hold_one::<methods::HermesRoomsList>(0);
        let store = cx.new(|_| HermesRoomsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.set_wanted(true, cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| assert_eq!(s.connection().as_deref(), Some("c1")));
        drop(rooms);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(
                s.connection().as_deref(),
                Some("c2"),
                "the newer answer was dropped"
            );
            assert_eq!(s.room("r1").unwrap().name, "Seed swap");
            assert_eq!(s.bots.as_ref().unwrap().connection.as_deref(), Some("c2"));
        });
    }

    #[gpui_kit::test]
    fn a_room_saved_before_an_account_change_is_not_listed_after(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::HermesBotsList>(bots_on("c1"));
        daemon.returns::<methods::HermesRoomsList>(rooms_on("c1", "Greenhouse crew"));
        let store = cx.new(|_| HermesRoomsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.set_wanted(true, cx));
        cx.run_until_parked();
        // A rename asked under the last account answers after the next
        // account's list is in.
        let asked = store.read_with(cx, |s, _| s.generation());
        store.update(cx, |s, cx| s.reset(cx));
        cx.run_until_parked();
        let renamed: HermesRoomDto =
            serde_json::from_value(json!({"id": "r9", "name": "Last account's room"})).unwrap();
        store.update(cx, |s, cx| s.patch_listed(renamed, asked, cx));
        store.read_with(cx, |s, _| assert!(s.listed_room("r9").is_none()));
    }

    #[gpui_kit::test]
    fn an_old_sends_answer_never_settles_a_newer_one(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let store = cx.new(|_| HermesRoomsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            let key = s.room_key("r1");
            let first = s.begin_send(&key, "plant the beans", 0).unwrap();
            s.finish_send(&key, first, SendOutcome::Refused, cx);
            let second = s.begin_send(&key, "water the peas", 0).unwrap();
            // The first send answers again, late (another pane's).
            s.finish_send(&key, first, SendOutcome::Refused, cx);
            assert_eq!(s.unresolved(&key).map(|u| u.token), Some(second));
            assert!(s.begin_send(&key, "pick the beans", 0).is_none());
        });
    }
}
