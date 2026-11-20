//! A Hermes Group Chat in the main pane, as the phone's room page
//! (`hermes_room_page.dart`, `hermes_room_timeline.dart`,
//! `hermes_room_composer.dart`) draws it: the bots' messages with their
//! names and faces, the user's own in bubbles, quiet lines for what
//! happened to the room's work and who a message went to, a paused
//! discussion with Continue and Stop, and the decisions the room waits on
//! as cards under the timeline. The toolbar names the room with its bots'
//! faces and who is at work (a click opens Room Info), with Stop All Work
//! while they work.
//!
//! The daemon reads the room every 2 s while it is shown and sends what
//! changed (`hermes.rooms.changed`); the timeline follows its end as a
//! chat's does. A working bot's time counts on here, a second at a time.
//!
//! The composer completes `@` mentions from the room's bots (and
//! `@everyone`), sends with Return (as the Send with Enter setting says),
//! and offers Stop in Send's place while the room works and nothing is
//! typed.

use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::time::{Duration, Instant};

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{ConduitTheme, with_alpha};
use conduit_components::views::approval::{ApprovalAction, ApprovalCard, ApprovalKind};
use conduit_components::views::kit::{Button, IconButton, field_fill, heading};
use conduit_protocol::{
    HermesRoomActionDto, HermesRoomAnswer, HermesRoomItemDto, HermesRoomItemKind,
    HermesRoomMemberDto, HermesRoomMemberState, HermesRoomMemberStatusDto, HermesRoomMessage,
    HermesRoomNoticeKind, HermesRoomRouteKind, HermesRoomView, NoticeLevel, methods,
};
use gpui_kit::component::input::{InputEvent, Textarea, TextareaState};
use gpui_kit::component::text::TextViewState;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, ClickEvent, Context, ElementId, Entity, EntityInputHandler as _,
    Focusable as _, FollowMode, FontWeight, ListAlignment, ListState, Role, SharedString,
    Subscription, Task, WeakEntity, Window, div, list, px, relative,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::stores::hermes_rooms::{HermesRoomsStore, RoomKey, SendOutcome, newest_seq};
use crate::views::hermes_faces::{self, Face};
use crate::views::hermes_rooms::{self, RoomCommand};

/// The most bots the mention list shows at once.
const MENTION_ROWS: usize = 5;

/// `45s`, `1m20s`, `1h05m`, as the phone writes a turn's time.
pub fn format_elapsed(ms: i64) -> String {
    let seconds = (ms / 1000).max(0);
    if seconds < 60 {
        return format!("{seconds}s");
    }
    if seconds < 3600 {
        return format!("{}m{:02}s", seconds / 60, seconds % 60);
    }
    format!("{}h{:02}m", seconds / 3600, (seconds % 3600) / 60)
}

/// How long `status`'s turn has run now: what the daemon said, counted on
/// from when it said it.
fn elapsed_now(status: &HermesRoomMemberStatusDto, received: Instant) -> Option<i64> {
    status
        .elapsed_ms
        .map(|ms| ms + received.elapsed().as_millis() as i64)
}

fn busy(state: HermesRoomMemberState) -> bool {
    matches!(
        state,
        HermesRoomMemberState::Working | HermesRoomMemberState::Stalled
    )
}

/// The line under the room's name: who waits on an answer, else who works
/// and in what, else who waits, else how many bots it has (the phone's
/// `_statusLine`).
pub fn status_line(view: &HermesRoomView, received: Instant, l: &L10n) -> Option<String> {
    let room = view.room.as_ref()?;
    if view.actions.iter().any(|a| a.kind == "approval") {
        return Some(l.hermes_room_needs_you());
    }
    let status = |id: &str| view.members.iter().find(|m| m.member_id == id);
    let describe = |member: &HermesRoomMemberDto| {
        let Some(s) = status(&member.member_id) else {
            return member.name.clone();
        };
        let elapsed = elapsed_now(s, received).map(format_elapsed);
        let mut parts = vec![member.name.clone()];
        if s.state == HermesRoomMemberState::Stalled {
            parts.push(l.hermes_room_quiet(&elapsed.unwrap_or_else(|| format_elapsed(0))));
        } else {
            parts.extend(s.tool.clone());
            parts.extend(elapsed);
        }
        parts.join(" · ")
    };
    let working: Vec<&HermesRoomMemberDto> = room
        .members
        .iter()
        .filter(|m| status(&m.member_id).is_some_and(|s| busy(s.state)))
        .collect();
    if let Some(first) = working.first() {
        let more = working.len() - 1;
        return Some(if more > 0 {
            format!("{} +{more}", describe(first))
        } else {
            describe(first)
        });
    }
    if let Some(waiting) = room
        .members
        .iter()
        .find(|m| status(&m.member_id).is_some_and(|s| s.state == HermesRoomMemberState::Queued))
    {
        return Some(format!("{} · {}", waiting.name, l.hermes_room_waiting()));
    }
    Some(l.hermes_room_bot_count(room.members.len() as i64))
}

/// Whether Stop applies: the room's driver runs and its bots work.
pub fn can_stop(view: &HermesRoomView) -> bool {
    view.running && view.working && !view.gone
}

/// The room's toolbar title: its bots' faces, its name and its status;
/// a click opens Room Info.
pub fn toolbar_title(stores: &Stores, room_id: &str, t: &ConduitTheme, cx: &App) -> AnyElement {
    let r = t.roles;
    let l = cx.l10n().clone();
    let rooms = stores.hermes_rooms.read(cx);
    let Some(room) = rooms.room(room_id).cloned() else {
        return div().into_any_element();
    };
    let status = rooms
        .room
        .as_ref()
        .filter(|o| o.room_id == room_id)
        .and_then(|o| o.view.as_ref().and_then(|v| status_line(v, o.received, &l)))
        .unwrap_or_else(|| l.hermes_room_bot_count(room.members.len() as i64));
    let faces: Vec<Face> = HermesRoomsStore::faces(&room)
        .iter()
        .map(|m| hermes_faces::member_face(m, rooms))
        .collect();
    let spoken = format!("{}, {status}", room.name);
    let (stores, id) = (stores.clone(), room_id.to_string());
    div()
        .id("hermes-room-title")
        .role(Role::Button)
        .aria_label(SharedString::from(spoken))
        .max_w(px(420.))
        .min_w_0()
        .flex()
        .items_center()
        .gap(px(8.))
        .px(px(6.))
        .py(px(2.))
        .rounded(px(8.))
        .cursor_pointer()
        .hover(|s| s.bg(r.overlay_hover))
        .child(hermes_faces::stack(
            "hermes-room-title-faces",
            &faces,
            24.,
            true,
        ))
        .child(
            div()
                .min_w_0()
                .flex()
                .flex_col()
                .child(
                    div()
                        .id("hermes-room-title-name")
                        .truncate()
                        .text_size(px(t.metrics.control))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text)
                        .child(SharedString::from(room.name.clone())),
                )
                .child(
                    div()
                        .id("hermes-room-status")
                        .truncate()
                        .text_size(px(t.metrics.caption))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(status)),
                ),
        )
        .tooltip(move |window, cx| {
            gpui_kit::component::tooltip::Tooltip::new(cx.l10n().hermes_room_info_title())
                .build(window, cx)
        })
        .on_click(move |_, window, cx| {
            hermes_rooms::run(&stores, &id, RoomCommand::Info, window, cx);
        })
        .into_any_element()
}

/// The toolbar's buttons: Stop All Work while the bots work, Room Info.
pub fn toolbar_actions(stores: &Stores, room_id: &str, cx: &App) -> Vec<AnyElement> {
    let l = cx.l10n().clone();
    let rooms = stores.hermes_rooms.read(cx);
    let Some(view) = rooms.view(room_id).filter(|v| v.room.is_some()) else {
        return vec![];
    };
    let mut out = vec![];
    if can_stop(view) {
        let (stores, id) = (stores.clone(), room_id.to_string());
        out.push(
            IconButton::new(
                "hermes-room-toolbar-stop",
                IconName::Square,
                l.hermes_room_stop_work(),
            )
            .size(30., 14.)
            .round()
            .on_click(Rc::new(move |_, _, cx| {
                hermes_rooms::stop(&stores, &id, cx)
            }))
            .into_any_element(),
        );
    }
    let (stores, id) = (stores.clone(), room_id.to_string());
    out.push(
        IconButton::new(
            "hermes-room-toolbar-info",
            IconName::Info,
            l.desktop_hermes_room_info_menu(),
        )
        .size(30., 16.)
        .round()
        .on_click(Rc::new(move |_, window, cx| {
            hermes_rooms::run(&stores, &id, RoomCommand::Info, window, cx)
        }))
        .into_any_element(),
    );
    out
}

/// The `@` mention being typed before the caret: where its `@` is, and
/// what follows it (the core's `hermesRoomMentionQuery`).
pub fn mention_at(text: &str, caret: usize) -> Option<(usize, String)> {
    let before = text.get(..caret.min(text.len()))?;
    let at = before.rfind('@')?;
    let query = &before[at + 1..];
    let valid = query
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ':' | '-'));
    let boundary = before[..at]
        .chars()
        .next_back()
        .is_none_or(char::is_whitespace);
    (valid && boundary).then(|| (at, query.to_string()))
}

/// Members `query` could mean: handle or name prefixes first, then any
/// other that contains it (the core's `hermesRoomMentionCandidates`).
pub fn mention_candidates<'a>(
    members: &'a [HermesRoomMemberDto],
    query: &str,
) -> Vec<&'a HermesRoomMemberDto> {
    let needle = query.to_lowercase();
    let starts = |m: &HermesRoomMemberDto| {
        m.handle.to_lowercase().starts_with(&needle) || m.name.to_lowercase().starts_with(&needle)
    };
    let contains = |m: &HermesRoomMemberDto| {
        m.handle.to_lowercase().contains(&needle) || m.name.to_lowercase().contains(&needle)
    };
    members
        .iter()
        .filter(|m| starts(m))
        .chain(members.iter().filter(|m| !starts(m) && contains(m)))
        .collect()
}

/// `text` with the mention typed from `start` to `caret` replaced by
/// `@handle `, and where the caret goes (the core's
/// `insertHermesRoomMention`).
pub fn insert_mention(text: &str, start: usize, caret: usize, handle: &str) -> (String, usize) {
    let end = caret.clamp(start, text.len());
    let after = &text[end..];
    let spacer = if after.starts_with(' ') { "" } else { " " };
    let inserted = format!("@{handle}{spacer}");
    let caret = start + inserted.len() + usize::from(spacer.is_empty());
    (format!("{}{inserted}{after}", &text[..start]), caret)
}

/// One row of the timeline.
#[derive(Clone, Debug, PartialEq)]
enum Row {
    /// An empty room: its faces, name and purpose.
    Intro,
    Item(HermesRoomItemDto),
    Action(HermesRoomActionDto),
}

impl Row {
    fn key(&self) -> String {
        match self {
            Self::Intro => "intro".into(),
            Self::Item(item) => item.key.clone(),
            Self::Action(a) => {
                format!("action:{}:{}:{}", a.kind, a.task_id, a.execution_generation)
            }
        }
    }
}

/// An open mention list: where its `@` is, what follows, the row the
/// keyboard stands on.
#[derive(Clone, Debug, PartialEq)]
struct Mention {
    start: usize,
    query: String,
    index: usize,
}

pub struct HermesRoomPane {
    stores: Stores,
    pub room_id: String,
    /// Whose words this pane holds (account, gateway, room), fixed when it
    /// opened: it shows, keeps and sends only these, whatever takes charge
    /// later (a pane for another key replaces it).
    pub key: RoomKey,
    pub input: Entity<TextareaState>,
    mention: Option<Mention>,
    rows: Vec<Row>,
    list: ListState,
    texts: HashMap<String, (String, Entity<TextViewState>)>,
    /// A send under way: the words it took.
    sending: Option<String>,
    /// Decision cards being answered.
    answering: HashSet<String>,
    /// The room's view has been read once (words Hermes may have come back
    /// only then: the room opened again).
    seen_view: bool,

    tick: Option<Task<()>>,
    _subscriptions: Vec<Subscription>,
}

impl HermesRoomPane {
    pub fn new(
        stores: Stores,
        room_id: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let placeholder = cx.l10n().hermes_room_message_hint();
        let send_on_enter = stores.app_settings.read(cx).settings().send_on_enter;
        let input = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(1, 6)
                .placeholder(placeholder)
                .submit_on_enter(send_on_enter)
        });
        // Words typed for this key before and not sent come back.
        let key = stores.hermes_rooms.read(cx).room_key(&room_id);
        if let Some(draft) = stores.hermes_rooms.read(cx).draft(&key).map(str::to_string) {
            let at = draft.len();
            input.update(cx, |s, cx| {
                s.set_value(draft, window, cx);
                s.set_selected_range(at..at, cx);
            });
        }
        let list = ListState::new(0, ListAlignment::Top, px(600.));
        list.set_follow_mode(FollowMode::Tail);
        let weak = cx.entity().downgrade();
        let subscriptions = vec![
            cx.subscribe_in(
                &input,
                window,
                |this, state, e: &InputEvent, window, cx| match e {
                    InputEvent::PressEnter {
                        shift: false,
                        secondary: false,
                    } => {
                        let composing =
                            state.update(cx, |s, cx| s.marked_text_range(window, cx).is_some());
                        if !composing && this.mention.is_none() {
                            this.send(window, cx);
                        }
                    }
                    InputEvent::Change => this.text_changed(cx),
                    _ => {}
                },
            ),
            cx.observe_in(&stores.hermes_rooms, window, |this, _, window, cx| {
                this.sync(window, cx)
            }),
            cx.observe(&stores.app_settings, |this, store, cx| {
                let on_enter = store.read(cx).settings().send_on_enter;
                this.input
                    .update(cx, |s, cx| s.set_submit_on_enter(on_enter, cx));
            }),
            // The mention list's keys, ahead of the field's own.
            cx.intercept_keystrokes(move |event, window, cx| {
                let key = event.keystroke.key.as_str();
                let m = event.keystroke.modifiers;
                let Some(this) = weak.upgrade() else {
                    return;
                };
                if key == "enter" && m.platform && !m.shift && !m.alt && !m.control {
                    let handled = this.update(cx, |p, cx| {
                        let focused = p.input.read(cx).focus_handle(cx).is_focused(window);
                        if focused {
                            p.send(window, cx);
                        }
                        focused
                    });
                    if handled {
                        cx.stop_propagation();
                    }
                    return;
                }
                if m.modified() || !matches!(key, "up" | "down" | "enter" | "tab" | "escape") {
                    return;
                }
                if this.update(cx, |p, cx| p.mention_key(key, window, cx)) {
                    cx.stop_propagation();
                }
            }),
        ];
        let mut this = Self {
            stores,
            room_id,
            key,
            input,
            mention: None,
            rows: vec![],
            list,
            texts: HashMap::new(),
            sending: None,
            answering: HashSet::new(),
            seen_view: false,
            tick: None,
            _subscriptions: subscriptions,
        };
        this.sync(window, cx);
        this
    }

    fn view<'a>(&self, cx: &'a App) -> Option<&'a HermesRoomView> {
        self.stores.hermes_rooms.read(cx).view(&self.room_id)
    }

    /// The store changed: the timeline follows, the tick runs while a bot
    /// works, words the log shows posted leave the field, and words Hermes may
    /// have come back to an empty one (the room opened again).
    fn sync(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let view = self.view(cx).cloned();
        let rows: Vec<Row> = match &view {
            Some(v) if v.room.is_some() => {
                let mut rows: Vec<Row> = if v.items.is_empty() {
                    vec![Row::Intro]
                } else {
                    v.items.iter().cloned().map(Row::Item).collect()
                };
                rows.extend(v.actions.iter().cloned().map(Row::Action));
                rows
            }
            _ => vec![],
        };
        if rows != self.rows {
            let old: Vec<String> = self.rows.iter().map(Row::key).collect();
            let new: Vec<String> = rows.iter().map(Row::key).collect();
            // The rows both have in the same place stay (re-measured when
            // they changed, a pause that can no longer continue); the rest
            // is spliced in, so reading back up never jumps.
            let kept = old.iter().zip(&new).take_while(|(a, b)| a == b).count();
            for (ix, (was, now)) in self.rows.iter().zip(&rows).take(kept).enumerate() {
                if was != now {
                    self.list.remeasure_items(ix..ix + 1);
                }
            }
            self.list.splice(kept..old.len(), new.len() - kept);
            let live: HashSet<String> = new.into_iter().collect();
            self.texts.retain(|k, _| live.contains(k));
            self.rows = rows;
        }
        let working = view
            .as_ref()
            .is_some_and(|v| v.members.iter().any(|m| busy(m.state)));
        if working && self.tick.is_none() {
            self.tick = Some(
                cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                    loop {
                        cx.background_executor().timer(Duration::from_secs(1)).await;
                        if this.update(cx, |_, cx| cx.notify()).is_err() {
                            break;
                        }
                    }
                }),
            );
        } else if !working {
            self.tick = None;
        }
        // Words stay in the field until Hermes is known to have them: a
        // send it answered as sent, or the log showing them posted after the
        // send. Words the room lets go of without that (a refusal, a room
        // not read) stay. Words Hermes may have come back to an empty field
        // when the room is opened again.
        if let Some(v) = &view
            && !std::mem::replace(&mut self.seen_view, true)
            && let Some(words) = v.unsent_text.clone()
            && self.sending.is_none()
        {
            // Followed whatever the field holds (a restored draft too).
            let key = self.key.clone();
            let after = newest_seq(v);
            self.stores
                .hermes_rooms
                .update(cx, |h, _| h.adopt_unsent(&key, words.trim(), after));
            if self.text(cx).is_empty() {
                let at = words.len();
                self.input.update(cx, |s, cx| {
                    s.set_value(words, window, cx);
                    s.set_selected_range(at..at, cx);
                });
                self.text_changed(cx);
            }
        }
        // A send for this key answered as posted -- by this pane or by one
        // shown before it -- takes its words from the field, if it still
        // holds exactly them (words typed since stay).
        let key = self.key.clone();
        if let Some(words) = self
            .stores
            .hermes_rooms
            .update(cx, |h, _| h.take_confirmed(&key))
            && self.text(cx).trim() == words
        {
            self.input.update(cx, |s, cx| s.set_value("", window, cx));
            self.text_changed(cx);
        }
        self.settle_by_room(window, cx);
        cx.notify();
    }

    /// The room's log showing this key's unresolved send's exact words, as
    /// the user's own message newer than the send, confirms it posted: like a
    /// send answered as sent, the guard goes and the words leave the field --
    /// only if it still holds exactly them (words edited since stay). Nothing
    /// else the room shows settles it.
    fn settle_by_room(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.sending.is_some() {
            return;
        }
        let Some(unresolved) = self
            .stores
            .hermes_rooms
            .read(cx)
            .unresolved(&self.key)
            .cloned()
        else {
            return;
        };
        if unresolved.in_flight || !self.view(cx).is_some_and(|v| unresolved.posted_in(v)) {
            return;
        }
        let key = self.key.clone();
        self.stores.hermes_rooms.update(cx, |h, _| {
            h.settle_seen_posted(&key, unresolved.token);
            // Given up here and now, not again by the next look.
            h.take_confirmed(&key);
        });
        if self.text(cx).trim() == unresolved.text {
            self.input.update(cx, |s, cx| s.set_value("", window, cx));
            self.text_changed(cx);
        }
    }

    /// Discard: the user lets the unresolved send go; its words stay in the
    /// field, to send again or not.
    pub fn discard(&mut self, cx: &mut Context<Self>) {
        let key = self.key.clone();
        self.stores
            .hermes_rooms
            .update(cx, |h, cx| h.discard_unresolved(&key, cx));
    }

    /// Send waits: a send for this room is unresolved, and what would go now
    /// is not that same send again while the room still holds it (the one
    /// retry it posts at most once).
    pub fn send_waits(&self, cx: &App) -> bool {
        self.stores
            .hermes_rooms
            .read(cx)
            .unresolved(&self.key)
            .is_some()
    }

    /// Try Again is offered: the unresolved send has no attempt out and the
    /// room still holds its words, so it goes again as itself (posted at
    /// most once).
    pub fn can_try_again(&self, cx: &App) -> bool {
        self.sending.is_none()
            && self
                .stores
                .hermes_rooms
                .read(cx)
                .unresolved(&self.key)
                .is_some_and(|u| {
                    !u.in_flight
                        && self
                            .view(cx)
                            .and_then(|v| v.unsent_text.as_deref())
                            .map(str::trim)
                            == Some(u.text.as_str())
                })
    }

    /// Try Again: the unresolved send goes again, as itself.
    pub fn try_again(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.can_try_again(cx) {
            return;
        }
        let key = self.key.clone();
        let Some((token, text)) = self
            .stores
            .hermes_rooms
            .update(cx, |h, _| h.retry_send(&key))
        else {
            return;
        };
        self.dispatch(token, text.clone(), text, window, cx);
    }

    /// The timeline's list (the perf fixture scrolls it).
    pub fn list_state(&self) -> &ListState {
        &self.list
    }

    pub fn text(&self, cx: &App) -> String {
        self.input.read(cx).value().to_string()
    }

    /// Types `text` into the composer, as the user would (the E2E).
    pub fn type_text(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        let value = text.to_string();
        let at = value.len();
        self.input.update(cx, |s, cx| {
            s.set_value(value, window, cx);
            s.set_selected_range(at..at, cx);
        });
        self.text_changed(cx);
    }

    fn text_changed(&mut self, cx: &mut Context<Self>) {
        let state = self.input.read(cx);
        let value = state.value().to_string();
        let caret = state.cursor();
        let key = self.key.clone();
        self.stores
            .hermes_rooms
            .update(cx, |h, _| h.keep_draft(&key, &value));
        let members = self
            .view(cx)
            .and_then(|v| v.room.as_ref())
            .map(|r| r.members.clone())
            .unwrap_or_default();
        self.mention = mention_at(&value, caret).and_then(|(start, query)| {
            let any = !mention_candidates(&members, &query).is_empty()
                || "everyone".starts_with(&query.to_lowercase());
            any.then_some(Mention {
                start,
                query,
                index: 0,
            })
        });
        cx.notify();
    }

    /// The mention list's rows: members, then Everyone.
    fn mention_rows(&self, cx: &App) -> Vec<(String, Option<HermesRoomMemberDto>)> {
        let Some(mention) = &self.mention else {
            return vec![];
        };
        let members = self
            .view(cx)
            .and_then(|v| v.room.as_ref())
            .map(|r| r.members.clone())
            .unwrap_or_default();
        let mut out: Vec<(String, Option<HermesRoomMemberDto>)> =
            mention_candidates(&members, &mention.query)
                .into_iter()
                .take(MENTION_ROWS)
                .map(|m| (m.handle.clone(), Some(m.clone())))
                .collect();
        if "everyone".starts_with(&mention.query.to_lowercase()) {
            out.push(("everyone".into(), None));
        }
        out
    }

    /// Up, Down, Return, Tab and Esc while the mention list shows -- and
    /// the room's field has focus: keys typed into another sheet or window
    /// are theirs.
    fn mention_key(&mut self, key: &str, window: &mut Window, cx: &mut Context<Self>) -> bool {
        if !self.input.read(cx).focus_handle(cx).is_focused(window) {
            return false;
        }
        let Some(mention) = self.mention.clone() else {
            return false;
        };
        let count = self.mention_rows(cx).len();
        if count == 0 {
            return false;
        }
        match key {
            "up" | "down" => {
                let index = if key == "up" {
                    (mention.index + count - 1) % count
                } else {
                    (mention.index + 1) % count
                };
                self.mention = Some(Mention { index, ..mention });
                // Said aloud: the list is the field's sibling (crate::views::a11y).
                let row = match &self.mention_rows(cx)[index] {
                    (handle, Some(member)) if !member.name.trim().is_empty() => {
                        format!("{}, @{handle}", member.name)
                    }
                    (handle, _) => format!("@{handle}"),
                };
                crate::views::a11y::announce_row(&row, index, count, cx);
            }
            "enter" | "tab" => {
                let handle = self.mention_rows(cx)[mention.index.min(count - 1)]
                    .0
                    .clone();
                self.insert(&handle, window, cx);
            }
            "escape" => self.mention = None,
            _ => return false,
        }
        cx.notify();
        true
    }

    /// Puts `@handle ` where the mention being typed is.
    pub fn insert(&mut self, handle: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(mention) = self.mention.take() else {
            return;
        };
        let state = self.input.read(cx);
        let value = state.value().to_string();
        let caret = state.cursor();
        let (text, at) = insert_mention(&value, mention.start, caret, handle);
        self.input.update(cx, |s, cx| {
            s.set_value(text, window, cx);
            s.set_selected_range(at..at, cx);
        });
        self.text_changed(cx);
        self.input.read(cx).focus_handle(cx).focus(window, cx);
        cx.notify();
    }

    /// Sends what is typed. The field keeps the words until Hermes has
    /// them; words typed meanwhile stay.
    pub fn send(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let typed = self.text(cx);
        let text = typed.trim().to_string();
        let ready = self
            .view(cx)
            .is_some_and(|v| v.room.is_some() && v.running && !v.gone);
        if text.is_empty() || self.sending.is_some() || !ready {
            return;
        }
        // One send at a time per room: another message waits until the
        // unresolved one is settled.
        if self.send_waits(cx) {
            return;
        }
        let key = self.key.clone();
        let after = self.view(cx).map(newest_seq).unwrap_or(i64::MIN);
        let Some(token) = self
            .stores
            .hermes_rooms
            .update(cx, |h, _| h.begin_send(&key, &text, after))
        else {
            return;
        };
        self.dispatch(token, text, typed, window, cx);
    }

    /// Sends attempt `token` of the key's send (`text`; `typed`: the field's
    /// words as they went), and takes its answer.
    fn dispatch(
        &mut self,
        token: u64,
        text: String,
        typed: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(rpc) = self.stores.hermes_rooms.read(cx).rpc() else {
            return;
        };
        // Sent to the room as it is shown: on the connection it was read on.
        let connection = self.view(cx).and_then(|v| v.connection.clone());
        let key = self.key.clone();
        self.sending = Some(typed);
        self.mention = None;
        cx.notify();
        let call = rpc.call::<methods::HermesRoomsSend>(&HermesRoomMessage {
            room_id: self.room_id.clone(),
            text,
            connection,
        });
        let handle = window.window_handle();
        let stores = self.stores.clone();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            // The answer is the key's, whether or not this pane is still
            // there: sent, the words are posted; refused, nothing was.
            cx.update(|cx| {
                stores.hermes_rooms.update(cx, |h, cx| {
                    let outcome = match &result {
                        Ok(r) if r.sent => SendOutcome::Posted,
                        Ok(r) if r.refused => SendOutcome::Refused,
                        _ => SendOutcome::Unclear,
                    };
                    h.finish_send(&key, token, outcome, cx)
                })
            });
            let _ = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |p, cx| {
                    let sent_text = p.sending.take().unwrap_or_default();
                    let l = cx.l10n().clone();
                    match result {
                        Ok(r) if r.sent => {
                            if p.text(cx) == sent_text {
                                p.input.update(cx, |s, cx| s.set_value("", window, cx));
                                p.text_changed(cx);
                            }
                        }
                        // Nothing was posted: the words stay, to edit or send.
                        Ok(r) if r.refused => {
                            let text = match r.detail {
                                Some(d) if !d.trim().is_empty() => l.hermes_room_refused(&d),
                                _ => l.hermes_room_action_failed(),
                            };
                            stores
                                .toasts
                                .update(cx, |t, cx| t.show(NoticeLevel::Warning, text, cx));
                        }
                        // Unclear: the room says so above the field.
                        Ok(_) => {}
                        Err(e) => {
                            log::warn!("hermes.rooms.send: {e}");
                            let text = hermes_rooms::failure_text(&e, &l);
                            stores
                                .toasts
                                .update(cx, |t, cx| t.show(NoticeLevel::Warning, text, cx));
                        }
                    }
                    // The room's log may have shown the words posted while the
                    // answer was out.
                    p.settle_by_room(window, cx);
                    cx.notify();
                });
            });
        })
        .detach();
    }

    fn text_state(
        &mut self,
        key: &str,
        markdown: &str,
        cx: &mut Context<Self>,
    ) -> Entity<TextViewState> {
        match self.texts.get_mut(key) {
            Some((last, state)) => {
                if last != markdown {
                    *last = markdown.to_string();
                    state.update(cx, |s, cx| s.set_text(markdown, cx));
                }
                state.clone()
            }
            None => {
                let state = cx.new(|cx| TextViewState::markdown(markdown, cx).selectable(true));
                self.texts
                    .insert(key.to_string(), (markdown.to_string(), state.clone()));
                state
            }
        }
    }

    // ── Drawing ────────────────────────────────────────────────────────

    fn face_of(&self, member_id: Option<&str>, cx: &App) -> Option<(HermesRoomMemberDto, Face)> {
        let view = self.view(cx)?;
        let member = view
            .room
            .as_ref()?
            .members
            .iter()
            .find(|m| Some(m.member_id.as_str()) == member_id)?
            .clone();
        let face = hermes_faces::member_face(&member, self.stores.hermes_rooms.read(cx));
        Some((member, face))
    }

    fn render_row(&mut self, ix: usize, _: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let Some(row) = self.rows.get(ix).cloned() else {
            return div().into_any_element();
        };
        let body = match row {
            Row::Intro => self.intro(&t, &l, cx),
            Row::Item(item) => match item.kind {
                HermesRoomItemKind::Message if item.own => self.own_message(&item, &t),
                HermesRoomItemKind::Message => self.bot_message(&item, &t, &l, cx),
                HermesRoomItemKind::Notice => self.notice(&item, &t, &l, cx),
                HermesRoomItemKind::Route => quiet_line(
                    &item.key,
                    route_text(&item, &l),
                    true,
                    None,
                    t.roles.text_subtle,
                    &t,
                ),
                HermesRoomItemKind::Pause => self.pause(&item, &t, &l, cx),
                // A row a newer daemon draws: nothing here.
                _ => div().into_any_element(),
            },
            Row::Action(action) => self.decision(&action, &t, &l, cx),
        };
        div()
            .w_full()
            .flex()
            .justify_center()
            .px(px(20.))
            .child(div().w_full().max_w(px(760.)).child(body))
            .into_any_element()
    }

    fn intro(&self, t: &ConduitTheme, l: &L10n, cx: &App) -> AnyElement {
        let r = t.roles;
        let Some(view) = self.view(cx) else {
            return div().into_any_element();
        };
        let Some(room) = view.room.as_ref() else {
            return div().into_any_element();
        };
        let rooms = self.stores.hermes_rooms.read(cx);
        let faces: Vec<Face> = HermesRoomsStore::faces(room)
            .iter()
            .map(|m| hermes_faces::member_face(m, rooms))
            .collect();
        let purpose = view
            .context
            .as_ref()
            .map(|c| c.purpose.trim().to_string())
            .filter(|p| !p.is_empty())
            .unwrap_or_else(|| {
                room.members
                    .iter()
                    .map(|m| m.name.clone())
                    .collect::<Vec<_>>()
                    .join(", ")
            });
        div()
            .id("hermes-room-intro")
            .py(px(40.))
            .flex()
            .flex_col()
            .items_center()
            .gap(px(6.))
            .child(hermes_faces::stack(
                "hermes-room-intro-faces",
                &faces,
                56.,
                true,
            ))
            .child(heading(
                "hermes-room-intro-name",
                SharedString::from(room.name.clone()),
                1,
                18.,
                FontWeight::BOLD,
                r.text,
            ))
            .child(
                div()
                    .text_size(px(t.metrics.small + 1.))
                    .text_color(r.text_subtle)
                    .text_center()
                    .child(SharedString::from(purpose)),
            )
            .child(
                div()
                    .text_size(px(t.metrics.caption))
                    .text_color(r.text_faint)
                    .child(l.hermes_room_message_hint()),
            )
            .into_any_element()
    }

    fn own_message(&self, item: &HermesRoomItemDto, t: &ConduitTheme) -> AnyElement {
        let r = t.roles;
        let m = t.metrics;
        div()
            .id(ElementId::Name(
                format!("hermes-room-own-{}", item.seq).into(),
            ))
            .role(Role::Article)
            .aria_label(SharedString::from(item.text.clone()))
            .w_full()
            .pt(px(10.))
            .pb(px(4.))
            .pl(px(60.))
            .flex()
            .justify_end()
            .child(
                div()
                    .max_w(relative(0.78))
                    .px(px(14.))
                    .py(px(9.))
                    .rounded(px(18.))
                    .bg(r.bubble)
                    .text_size(px(m.body))
                    .line_height(relative(m.leading - 0.05))
                    .text_color(r.text)
                    .child(SharedString::from(item.text.clone())),
            )
            .into_any_element()
    }

    fn bot_message(
        &mut self,
        item: &HermesRoomItemDto,
        t: &ConduitTheme,
        l: &L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let r = t.roles;
        let m = t.metrics;
        const FACE: f32 = 28.;
        let face: AnyElement = if item.continued {
            div().flex_none().w(px(FACE)).into_any_element()
        } else if let Some((_, face)) = self.face_of(item.member_id.as_deref(), cx) {
            hermes_faces::face(
                ElementId::Name(format!("hermes-room-face-{}", item.seq).into()),
                &face,
                FACE,
                false,
                true,
            )
        } else {
            div()
                .flex_none()
                .size(px(FACE))
                .rounded_full()
                .bg(with_alpha(r.text, if t.dark { 0.16 } else { 0.08 }))
                .flex()
                .items_center()
                .justify_center()
                .child(icon(
                    if item.scheduled {
                        IconName::CalendarClock
                    } else {
                        IconName::User
                    },
                    14.,
                    r.text_subtle,
                ))
                .into_any_element()
        };
        let now = chrono::Local::now();
        let time = item
            .created_at_ms
            .map(|ms| crate::views::dates::stamp(ms, &now, l));
        let state =
            (!item.text.trim().is_empty()).then(|| self.text_state(&item.key, &item.text, cx));
        let author = item.author.clone();
        let label = format!("{author}: {}", item.text);
        div()
            .id(ElementId::Name(
                format!("hermes-room-message-{}", item.seq).into(),
            ))
            .role(Role::Article)
            .aria_label(SharedString::from(label))
            .w_full()
            .pt(px(if item.continued { 2. } else { 12. }))
            .pb(px(2.))
            .flex()
            .items_start()
            .gap(px(10.))
            .child(face)
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap(px(3.))
                    .when(!item.continued, |d| {
                        d.child(
                            div()
                                .flex()
                                .items_center()
                                .gap(px(8.))
                                .child(
                                    div()
                                        .id(ElementId::Name(
                                            format!("hermes-room-author-{}", item.seq).into(),
                                        ))
                                        .truncate()
                                        .text_size(px(m.small + 0.5))
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .text_color(r.text_subtle)
                                        .child(SharedString::from(author.clone())),
                                )
                                .when(item.scheduled, |d| {
                                    d.child(
                                        div()
                                            .px(px(6.))
                                            .rounded(px(4.))
                                            .bg(with_alpha(
                                                r.text,
                                                if t.dark { 0.12 } else { 0.06 },
                                            ))
                                            .text_size(px(m.caption))
                                            .text_color(r.text_subtle)
                                            .child(l.hermes_room_scheduled()),
                                    )
                                })
                                .when_some(time, |d, (stamp, _)| {
                                    d.child(
                                        div()
                                            .text_size(px(m.caption))
                                            .text_color(r.text_faint)
                                            .child(SharedString::from(stamp)),
                                    )
                                }),
                        )
                    })
                    .when_some(state, |d, state| {
                        d.child(
                            div()
                                .text_size(px(m.body))
                                .line_height(relative(m.leading))
                                .text_color(r.text)
                                .child(crate::views::chat::markdown::chat_text(
                                    &state,
                                    format!("hermes-room:{}:{}", self.room_id, item.seq).into(),
                                )),
                        )
                    }),
            )
            .into_any_element()
    }

    fn notice(&self, item: &HermesRoomItemDto, t: &ConduitTheme, l: &L10n, cx: &App) -> AnyElement {
        let r = t.roles;
        let failed = item.notice == Some(HermesRoomNoticeKind::TurnFailed);
        let mut text = String::new();
        if let Some(name) = &item.member_name {
            text.push_str(name);
            text.push_str(" · ");
        }
        text.push_str(&notice_label(item.notice, l));
        if let Some(detail) = &item.detail {
            text.push_str(": ");
            text.push_str(detail);
        }
        let face = self.face_of(item.member_id.as_deref(), cx).map(|(_, f)| {
            hermes_faces::face(
                ElementId::Name(format!("hermes-room-notice-face-{}", item.seq).into()),
                &f,
                16.,
                false,
                true,
            )
        });
        quiet_line(
            &item.key,
            text,
            false,
            face,
            if failed { r.danger } else { r.text_subtle },
            t,
        )
    }

    fn pause(
        &self,
        item: &HermesRoomItemDto,
        t: &ConduitTheme,
        l: &L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let r = t.roles;
        let label = l.hermes_room_paused(item.message_count);
        let usable = self.view(cx).is_some_and(|v| v.running && !v.gone);
        if !item.actionable {
            return quiet_line(&item.key, label, false, None, r.text_subtle, t);
        }
        let discussion = item.discussion_event_id.clone().unwrap_or_default();
        let (stores, room) = (self.stores.clone(), self.room_id.clone());
        let (stop_stores, stop_room) = (self.stores.clone(), self.room_id.clone());
        div()
            .id(ElementId::Name(
                format!("hermes-room-pause-{}", item.seq).into(),
            ))
            .role(Role::Group)
            .aria_label(SharedString::from(label.clone()))
            .w_full()
            .py(px(10.))
            .flex()
            .flex_col()
            .items_center()
            .gap(px(8.))
            .child(
                div()
                    .text_size(px(t.metrics.small))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(r.text_subtle)
                    .child(SharedString::from(label)),
            )
            .child(
                div()
                    .flex()
                    .gap(px(8.))
                    .child(
                        Button::new("hermes-room-continue", l.continue_action())
                            .primary()
                            .disabled(!usable)
                            .on_click(Rc::new(move |_, _, cx| {
                                hermes_rooms::continue_discussion(&stores, &room, &discussion, cx)
                            })),
                    )
                    .child(
                        Button::new("hermes-room-pause-stop", l.hermes_job_stop())
                            .disabled(!usable)
                            .on_click(Rc::new(move |_, _, cx| {
                                hermes_rooms::stop(&stop_stores, &stop_room, cx)
                            })),
                    ),
            )
            .into_any_element()
    }

    /// A decision the room waits on: an approval with the answers Hermes
    /// offers this app (the Hermes approval card), or uncertain work to retry.
    fn decision(
        &self,
        action: &HermesRoomActionDto,
        t: &ConduitTheme,
        l: &L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let r = t.roles;
        let key = Row::Action(action.clone()).key();
        let busy = self.answering.contains(&key);
        let member = self.face_of(Some(&action.member_id), cx);
        let name = member
            .as_ref()
            .map(|(m, _)| m.name.clone())
            .unwrap_or_else(|| action.member_id.clone());
        // Answered on the connection the card was read on.
        let connection = self.view(cx).and_then(|v| v.connection.clone());
        let answer = {
            let (stores, room, action) =
                (self.stores.clone(), self.room_id.clone(), action.clone());
            let weak = cx.entity().downgrade();
            let key = key.clone();
            move |choice: Option<&str>, cx: &mut App| {
                let _ = weak.update(cx, |p, cx| {
                    p.answering.insert(key.clone());
                    cx.notify();
                });
                let (weak, key) = (weak.clone(), key.clone());
                hermes_rooms::answer(
                    &stores,
                    HermesRoomAnswer {
                        room_id: room.clone(),
                        task_id: action.task_id.clone(),
                        execution_generation: action.execution_generation,
                        choice: choice.map(str::to_string),
                        connection: connection.clone(),
                    },
                    move |cx| {
                        let _ = weak.update(cx, |p, cx| {
                            p.answering.remove(&key);
                            cx.notify();
                        });
                    },
                    cx,
                );
            }
        };
        if action.kind == "retry" {
            let face = member.map(|(_, f)| {
                hermes_faces::face(
                    ElementId::Name(format!("hermes-room-retry-face-{}", action.task_id).into()),
                    &f,
                    20.,
                    false,
                    true,
                )
            });
            let text = l.hermes_room_retry_prompt(&name);
            return div()
                .id(ElementId::Name(
                    format!("hermes-room-retry-{}", action.task_id).into(),
                ))
                .role(Role::Group)
                .aria_label(SharedString::from(text.clone()))
                .w_full()
                .py(px(8.))
                .flex()
                .items_center()
                .gap(px(10.))
                .children(face)
                .child(
                    div()
                        .flex_1()
                        .text_size(px(t.metrics.small + 0.5))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(text)),
                )
                .child(
                    Button::new(
                        ElementId::Name(
                            format!("hermes-room-retry-button-{}", action.task_id).into(),
                        ),
                        l.retry(),
                    )
                    .disabled(busy)
                    .on_click(Rc::new(move |_, _, cx| answer(None, cx))),
                )
                .into_any_element();
        }
        let summary = action.summary.clone().unwrap_or_default();
        if action.choices.is_empty() {
            let text = if summary.is_empty() {
                format!("{} · {name}", l.hermes_room_needs_you())
            } else {
                format!("{} · {name}: {summary}", l.hermes_room_needs_you())
            };
            return quiet_line(&key, text, false, None, r.text_subtle, t);
        }
        let room_name = self
            .view(cx)
            .and_then(|v| v.room.as_ref())
            .map(|r| r.name.clone())
            .unwrap_or_default();
        let mut actions = vec![];
        if action.choices.iter().any(|c| c == "deny") {
            let answer = answer.clone();
            actions.push(
                ApprovalAction::new(
                    format!("hermes-room-deny-{}", action.task_id),
                    l.desktop_deny(),
                )
                .disabled(busy)
                .on_click(Rc::new(move |_, _, cx| answer(Some("deny"), cx))),
            );
        }
        if action.choices.iter().any(|c| c == "once") {
            let answer = answer.clone();
            actions.push(
                ApprovalAction::new(
                    format!("hermes-room-allow-{}", action.task_id),
                    l.desktop_allow_once(),
                )
                .primary()
                .disabled(busy)
                .on_click(Rc::new(move |_, _, cx| answer(Some("once"), cx))),
            );
        }
        div()
            .w_full()
            .py(px(8.))
            .child(
                ApprovalCard::new(
                    format!("hermes-room-approval-{}", action.task_id),
                    l.hermes_room_needs_you(),
                    SharedString::default(),
                    format!("{name} · {room_name}"),
                    ApprovalKind::Code {
                        caption: name.clone().into(),
                        code: summary.into(),
                    },
                )
                .tile(IconName::ShieldAlert)
                .actions(actions),
            )
            .into_any_element()
    }

    fn banners(&self, t: &ConduitTheme, l: &L10n, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let r = t.roles;
        let Some(view) = self.view(cx) else {
            return vec![];
        };
        let mut notes = vec![];
        if view.room.is_some() {
            if view.gone {
                notes.push(("gone", l.hermes_room_gone()));
            } else if view.loaded && !view.running {
                notes.push(("not-running", l.hermes_room_not_running()));
            }
            if !view.gone && view.read_failed {
                notes.push(("refresh-failed", l.hermes_room_refresh_failed()));
            }
        }
        // A send whose fate is unknown shows as pending until it is settled.
        let pending = self.sending.is_none()
            && self
                .stores
                .hermes_rooms
                .read(cx)
                .unresolved(&self.key)
                .is_some_and(|u| !u.in_flight);
        if (view.unsent_text.is_some() && !view.sending && self.sending.is_none()) || pending {
            notes.push(("unsent", l.hermes_room_send_unclear()));
        }
        // The user may let an unresolved send go (its words stay): nothing
        // else settles it without evidence.
        let discardable = self.sending.is_none()
            && self
                .stores
                .hermes_rooms
                .read(cx)
                .unresolved(&self.key)
                .is_some_and(|u| !u.in_flight);
        let (stores, key) = (self.stores.clone(), self.key.clone());
        let discard = Rc::new(move |_: &ClickEvent, _: &mut Window, cx: &mut App| {
            stores
                .hermes_rooms
                .update(cx, |h, cx| h.discard_unresolved(&key, cx));
        });
        // Try Again, while the room still holds the words (the same send
        // again: posted at most once).
        let retry_offered = self.can_try_again(cx);
        let pane = cx.entity().downgrade();
        let retry = Rc::new(move |_: &ClickEvent, w: &mut Window, cx: &mut App| {
            let _ = pane.update(cx, |p, cx| p.try_again(w, cx));
        });
        notes
            .into_iter()
            .map(|(id, text)| {
                let discard = discard.clone();
                div()
                    .id(ElementId::Name(format!("hermes-room-banner-{id}").into()))
                    .role(Role::Status)
                    .aria_label(SharedString::from(text.clone()))
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .px(px(4.))
                    .text_size(px(t.metrics.small))
                    .text_color(r.text_subtle)
                    .child(icon(IconName::Info, 13., r.text_subtle))
                    .child(div().flex_1().child(SharedString::from(text)))
                    .when(id == "unsent" && retry_offered, |d| {
                        let retry = retry.clone();
                        d.child(
                            Button::new("hermes-room-unsent-retry", l.desktop_try_again())
                                .on_click(Rc::new(move |e, w, cx| retry(e, w, cx))),
                        )
                    })
                    .when(id == "unsent" && discardable, |d| {
                        d.child(
                            Button::new("hermes-room-unsent-discard", l.desktop_discard())
                                .on_click(Rc::new(move |e, w, cx| discard(e, w, cx))),
                        )
                    })
                    .into_any_element()
            })
            .collect()
    }

    fn mention_list(
        &self,
        t: &ConduitTheme,
        l: &L10n,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let mention = self.mention.clone()?;
        let rows = self.mention_rows(cx);
        if rows.is_empty() {
            return None;
        }
        let r = t.roles;
        let rooms = self.stores.hermes_rooms.read(cx);
        let items: Vec<AnyElement> = rows
            .into_iter()
            .enumerate()
            .map(|(ix, (handle, member))| {
                let on = ix == mention.index;
                let (title, leading) = match &member {
                    Some(m) => (
                        m.name.clone(),
                        hermes_faces::face(
                            ElementId::Name(format!("hermes-room-mention-face-{handle}").into()),
                            &hermes_faces::member_face(m, rooms),
                            22.,
                            false,
                            true,
                        ),
                    ),
                    None => (
                        l.hermes_room_everyone(),
                        icon(IconName::Users, 18., r.text_subtle).into_any_element(),
                    ),
                };
                let pick = handle.clone();
                div()
                    .id(ElementId::Name(
                        format!("hermes-room-mention-{handle}").into(),
                    ))
                    .role(Role::MenuItem)
                    .aria_label(SharedString::from(format!("{title}, @{handle}")))
                    .aria_selected(on)
                    .px(px(10.))
                    .h(px(32.))
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .rounded(px(6.))
                    .cursor_pointer()
                    .when(on, |d| d.bg(r.selected))
                    .hover(|s| s.bg(r.overlay_hover))
                    .child(leading)
                    .child(
                        div()
                            .truncate()
                            .text_size(px(t.metrics.control))
                            .text_color(r.text)
                            .child(SharedString::from(title)),
                    )
                    .child(
                        div()
                            .text_size(px(t.metrics.small))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(format!("@{handle}"))),
                    )
                    .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                        this.insert(&pick, window, cx)
                    }))
                    .into_any_element()
            })
            .collect();
        Some(
            div()
                .id("hermes-room-mentions")
                .role(Role::Menu)
                .aria_label(l.hermes_room_message_hint())
                .mb(px(6.))
                .p(px(4.))
                .rounded(px(10.))
                .bg(r.overlay)
                .border_1()
                .border_color(r.border)
                .shadow(conduit_components::views::kit::overlay_shadow(t))
                .flex()
                .flex_col()
                .children(items)
                .into_any_element(),
        )
    }

    fn composer(&self, t: &ConduitTheme, l: &L10n, cx: &mut Context<Self>) -> AnyElement {
        let r = t.roles;
        let view = self.view(cx);
        let enabled = view.is_some_and(|v| v.room.is_some() && v.running && !v.gone);
        let stop = view.is_some_and(can_stop);
        let typed = !self.text(cx).trim().is_empty();
        let sending = self.sending.is_some();
        let button = if stop && !typed && !sending {
            let (stores, id) = (self.stores.clone(), self.room_id.clone());
            IconButton::new(
                "hermes-room-stop",
                IconName::Square,
                l.hermes_room_stop_work(),
            )
            .size(28., 13.)
            .round()
            .filled(r.text, r.content)
            .on_click(Rc::new(move |_, _, cx| {
                hermes_rooms::stop(&stores, &id, cx)
            }))
            .into_any_element()
        } else {
            let weak = cx.entity().downgrade();
            IconButton::new("hermes-room-send", IconName::ArrowUp, l.send())
                .size(28., 15.)
                .round()
                .disabled(!typed || !enabled || sending || self.send_waits(cx))
                .filled(
                    if typed && enabled {
                        r.text
                    } else {
                        with_alpha(r.text, 0.2)
                    },
                    r.content,
                )
                .on_click(Rc::new(move |_, window, cx| {
                    let _ = weak.update(cx, |p, cx| p.send(window, cx));
                }))
                .into_any_element()
        };
        div()
            .id("hermes-room-composer-frame")
            .w_full()
            .flex()
            .items_end()
            .gap(px(8.))
            .pl(px(14.))
            .pr(px(6.))
            .py(px(6.))
            .rounded(px(18.))
            .bg(field_fill(t))
            .border_1()
            .border_color(r.border)
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .py(px(4.))
                    .text_size(px(t.metrics.body))
                    .child(
                        Textarea::new(&self.input)
                            .appearance(false)
                            .bordered(false)
                            .disabled(!enabled)
                            .aria_label(l.hermes_room_message_hint()),
                    ),
            )
            .child(button)
            .into_any_element()
    }
}

/// A quiet centred line between messages.
fn quiet_line(
    key: &str,
    text: String,
    italic: bool,
    leading: Option<AnyElement>,
    color: gpui_kit::Hsla,
    t: &ConduitTheme,
) -> AnyElement {
    div()
        .id(ElementId::Name(format!("hermes-room-line-{key}").into()))
        .role(Role::Status)
        .aria_label(SharedString::from(text.clone()))
        .w_full()
        .py(px(6.))
        .flex()
        .justify_center()
        .items_center()
        .gap(px(6.))
        .children(leading)
        .child(
            div()
                .max_w(px(560.))
                .text_center()
                .text_size(px(t.metrics.small))
                .text_color(color)
                .when(italic, |d| d.italic())
                .child(SharedString::from(text)),
        )
        .into_any_element()
}

fn notice_label(kind: Option<HermesRoomNoticeKind>, l: &L10n) -> String {
    match kind {
        Some(HermesRoomNoticeKind::TurnFailed) => l.hermes_room_turn_failed(),
        Some(HermesRoomNoticeKind::TurnCancelled) => l.hermes_room_turn_cancelled(),
        Some(HermesRoomNoticeKind::TurnDeferred) => l.hermes_room_turn_deferred(),
        Some(HermesRoomNoticeKind::MemberUnavailable) => l.hermes_room_member_unavailable(),
        Some(HermesRoomNoticeKind::Stopped) => l.hermes_room_stopped(),
        Some(HermesRoomNoticeKind::Disbanded) => l.hermes_room_disbanded(),
        Some(HermesRoomNoticeKind::AuthorityLost) => l.hermes_room_authority_lost(),
        _ => l.hermes_room_work_limit(),
    }
}

fn route_text(item: &HermesRoomItemDto, l: &L10n) -> String {
    let names = item.names.join(", ");
    let lead = item.lead.clone().unwrap_or_default();
    match item.route {
        Some(HermesRoomRouteKind::RoutedTo) => l.hermes_room_routed_to(&names),
        Some(HermesRoomRouteKind::RoutedEveryone) => l.hermes_room_routed_everyone(),
        Some(HermesRoomRouteKind::RoutedFallback) => l.hermes_room_routed_fallback(),
        Some(HermesRoomRouteKind::Assigned) => l.hermes_room_assigned(&lead, &names),
        Some(HermesRoomRouteKind::LeadTaking) => l.hermes_room_lead_taking(&lead),
        Some(HermesRoomRouteKind::Continued) => l.hermes_room_continued(),
        _ => l.hermes_room_handoff(&lead, &names),
    }
}

impl Render for HermesRoomPane {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let r = t.roles;
        let view = self.view(cx).cloned();
        let open_failed = self
            .stores
            .hermes_rooms
            .read(cx)
            .room
            .as_ref()
            .is_some_and(|o| o.room_id == self.room_id && o.failed);
        // Ask once for the pictures of the room's bots.
        if let Some(room) = view.as_ref().and_then(|v| v.room.as_ref()) {
            let missing: Vec<&str> = room
                .members
                .iter()
                .filter(|m| {
                    let rooms = self.stores.hermes_rooms.read(cx);
                    rooms.bot(&m.profile).is_some_and(|b| b.has_avatar)
                        && rooms.known_avatar(&m.profile).is_none()
                })
                .map(|m| m.profile.as_str())
                .collect();
            if !missing.is_empty() {
                hermes_faces::request_avatars(missing, &self.stores.hermes_rooms, cx);
            }
        }
        let body: AnyElement = match &view {
            Some(v) if v.room.is_some() => list(
                self.list.clone(),
                cx.processor(|this, ix, window, cx| this.render_row(ix, window, cx)),
            )
            .size_full()
            .into_any_element(),
            _ => {
                let (text, retry) = match &view {
                    Some(v) if v.gone => (l.hermes_room_gone(), false),
                    Some(v) if v.loaded || open_failed => (l.hermes_room_load_failed(), true),
                    None if open_failed => (l.hermes_room_load_failed(), true),
                    _ => (l.loading_short(), false),
                };
                let stores = self.stores.clone();
                div()
                    .id("hermes-room-empty")
                    .role(Role::Status)
                    .aria_label(SharedString::from(text.clone()))
                    .size_full()
                    .flex()
                    .flex_col()
                    .items_center()
                    .justify_center()
                    .gap(px(12.))
                    .child(
                        div()
                            .text_size(px(t.metrics.small + 0.5))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(text)),
                    )
                    .when(retry, |d| {
                        d.child(
                            Button::new("hermes-room-retry", l.desktop_try_again()).on_click(
                                Rc::new(move |_, _, cx| {
                                    stores.hermes_rooms.update(cx, |h, cx| h.watch_open(cx))
                                }),
                            ),
                        )
                    })
                    .into_any_element()
            }
        };
        let mention = self.mention_list(&t, &l, cx);
        let banners = self.banners(&t, &l, cx);
        let composer = self.composer(&t, &l, cx);
        div()
            .id("hermes-room")
            .role(Role::Group)
            .aria_label(SharedString::from(
                view.as_ref()
                    .and_then(|v| v.room.as_ref())
                    .map(|r| r.name.clone())
                    .unwrap_or_default(),
            ))
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .child(
                div()
                    .id("hermes-room-timeline")
                    .role(Role::List)
                    .flex_1()
                    .min_h_0()
                    .child(body),
            )
            .child(
                div()
                    .w_full()
                    .flex()
                    .justify_center()
                    .px(px(20.))
                    .pb(px(14.))
                    .pt(px(6.))
                    .child(
                        div()
                            .w_full()
                            .max_w(px(760.))
                            .flex()
                            .flex_col()
                            .gap(px(6.))
                            .children(banners)
                            .children(mention)
                            .child(composer),
                    ),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn member(handle: &str, name: &str) -> HermesRoomMemberDto {
        HermesRoomMemberDto {
            member_id: handle.into(),
            profile: handle.into(),
            handle: handle.into(),
            name: name.into(),
        }
    }

    #[test]
    fn mentions_complete_as_the_phones_do() {
        assert_eq!(mention_at("Hi @re and more", 6), Some((3, "re".into())));
        assert_eq!(mention_at("mail@re", 7), None);
        assert_eq!(mention_at("@", 1), Some((0, String::new())));
        assert_eq!(mention_at("@a b", 4), None);
        let members = [member("research", "Research"), member("scout", "Scout")];
        let handles = |q: &str| -> Vec<String> {
            mention_candidates(&members, q)
                .into_iter()
                .map(|m| m.handle.clone())
                .collect()
        };
        assert_eq!(handles("re"), ["research"]);
        assert_eq!(handles("ou"), ["scout"]);
        assert_eq!(
            insert_mention("Hi @re and more", 3, 6, "research"),
            ("Hi @research and more".into(), 13)
        );
        assert_eq!(insert_mention("@sc", 0, 3, "scout"), ("@scout ".into(), 7));
    }

    #[test]
    fn elapsed_reads_as_the_phone_writes_it() {
        assert_eq!(format_elapsed(45_000), "45s");
        assert_eq!(format_elapsed(80_000), "1m20s");
        assert_eq!(format_elapsed(3_900_000), "1h05m");
        assert_eq!(format_elapsed(-5), "0s");
    }

    mod pane {
        use conduit_protocol::{Event, HermesRoomSendResult, methods};
        use gpui_kit::{
            AppContext as _, Entity, Focusable as _, TestAppContext, VisualTestContext,
        };
        use serde_json::json;

        use super::super::HermesRoomPane;
        use crate::stores::Stores;
        use crate::stores::rpc::fake::FakeDaemon;

        const G1: &str = "https://gateway-one.example#default";
        const G2: &str = "https://gateway-two.example#default";

        /// A new pane for r1 in the window, as navigating back to it makes.
        fn again(stores: &Stores, vcx: &mut VisualTestContext) -> Entity<HermesRoomPane> {
            let stores = stores.clone();
            let pane = vcx.update(|window, cx| {
                cx.new(|cx| HermesRoomPane::new(stores, "r1".into(), window, cx))
            });
            vcx.run_until_parked();
            pane
        }

        fn key(account: &str, gateway: &str) -> crate::stores::hermes_rooms::RoomKey {
            crate::stores::hermes_rooms::RoomKey {
                account: Some(account.into()),
                gateway: Some(gateway.into()),
                room: "r1".into(),
            }
        }

        fn room(unsent: Option<&str>) -> conduit_protocol::HermesRoomView {
            posted(unsent, &[])
        }

        /// The room with the user's own messages `own` (seq, words) in its
        /// timeline.
        fn posted(unsent: Option<&str>, own: &[(i64, &str)]) -> conduit_protocol::HermesRoomView {
            let items: Vec<_> = own
                .iter()
                .map(|(seq, text)| {
                    json!({"kind": "message", "key": format!("message:{seq}"), "seq": seq,
                           "own": true, "text": text})
                })
                .collect();
            serde_json::from_value(json!({
                "roomId": "r1", "loaded": true, "running": true,
                "room": {"id": "r1", "name": "Greenhouse crew", "members": [
                    {"memberId": "fern", "profile": "fern", "handle": "fern", "name": "Fern"},
                ]},
                "unsentText": unsent,
                "items": items,
            }))
            .unwrap()
        }

        fn open<'a>(
            cx: &'a mut TestAppContext,
            daemon: &FakeDaemon,
            tag: &str,
        ) -> (Stores, Entity<HermesRoomPane>, &'a mut VisualTestContext) {
            let scratch =
                std::env::temp_dir().join(format!("conduit-hroom-{tag}-{}", std::process::id()));
            let stores = cx.update(|cx| {
                crate::views::test_globals(cx);
                Stores::for_test(daemon.rpc(), &scratch, cx)
            });
            stores.hermes_rooms.update(cx, |h, cx| {
                h.set_account(Some("avery".into()));
                h.set_gateway(Some(G1.into()));
                h.show(Some("r1"), cx)
            });
            // The window's root is not the pane: a pane dropped here goes, as
            // the main window's area pane lets go of a room left.
            let (_, vcx) = cx.add_window_view(|_, _| Host);
            let pane = again(&stores, vcx);
            (stores, pane, vcx)
        }

        struct Host;

        impl gpui_kit::Render for Host {
            fn render(
                &mut self,
                _: &mut gpui_kit::Window,
                _: &mut gpui_kit::Context<Self>,
            ) -> impl gpui_kit::IntoElement {
                gpui_kit::div()
            }
        }

        fn changed(
            stores: &Stores,
            view: conduit_protocol::HermesRoomView,
            vcx: &mut VisualTestContext,
        ) {
            stores.hermes_rooms.update(vcx, |h, cx| {
                h.on_event(&Event::HermesRoomsChanged(view), cx)
            });
            vcx.run_until_parked();
        }

        #[gpui_kit::test]
        fn words_the_log_shows_posted_during_a_send_settle_it_when_it_ends(
            cx: &mut TestAppContext,
        ) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(room(None));
            // The send's answer is unclear and late.
            daemon.returns::<methods::HermesRoomsSend>(HermesRoomSendResult::default());
            let held = daemon.hold::<methods::HermesRoomsSend>();
            let (stores, pane, vcx) = open(cx, &daemon, "settle");
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("hello", window, cx);
                p.send(window, cx);
            });
            // Hermes posted them: the room holds the words, then its log
            // shows them posted, all before the send's answer comes back.
            changed(&stores, room(Some("hello")), vcx);
            changed(&stores, posted(None, &[(1, "hello")]), vcx);
            drop(held);
            vcx.run_until_parked();
            pane.read_with(vcx, |p, cx| {
                assert!(!p.send_waits(cx), "the log's confirmation was lost");
                assert_eq!(p.text(cx), "", "a second Send would post them twice");
            });
        }

        #[gpui_kit::test]
        fn words_hermes_refused_stay_even_when_the_room_lets_them_go_first(
            cx: &mut TestAppContext,
        ) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(posted(None, &[(1, "hello")]));
            daemon.returns::<methods::HermesRoomsSend>(HermesRoomSendResult {
                refused: true,
                ..Default::default()
            });
            let held = daemon.hold::<methods::HermesRoomsSend>();
            let (stores, pane, vcx) = open(cx, &daemon, "refused");
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("hello", window, cx);
                p.send(window, cx);
            });
            // The room drops the words on the refusal before its answer
            // comes back; the log shows nothing new (the earlier "hello" is
            // an older message).
            changed(&stores, posted(Some("hello"), &[(1, "hello")]), vcx);
            changed(&stores, posted(None, &[(1, "hello")]), vcx);
            drop(held);
            vcx.run_until_parked();
            pane.read_with(vcx, |p, cx| assert_eq!(p.text(cx), "hello"));
        }

        #[gpui_kit::test]
        fn words_left_unclear_stay_until_the_log_shows_them(cx: &mut TestAppContext) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(room(None));
            daemon.returns::<methods::HermesRoomsSend>(HermesRoomSendResult::default());
            let held = daemon.hold::<methods::HermesRoomsSend>();
            let (stores, pane, vcx) = open(cx, &daemon, "unclear");
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("hello", window, cx);
                p.send(window, cx);
            });
            // The room holds the words (an unclear answer follows).
            changed(&stores, room(Some("hello")), vcx);
            drop(held);
            vcx.run_until_parked();
            pane.read_with(vcx, |p, cx| assert_eq!(p.text(cx), "hello"));
            // Shown posted later (the user's own message, newer than the
            // send): a confirmed post, as a send answered as sent.
            changed(&stores, posted(None, &[(4, "hello")]), vcx);
            pane.read_with(vcx, |p, cx| {
                assert!(!p.send_waits(cx));
                assert_eq!(p.text(cx), "");
            });
        }

        #[gpui_kit::test]
        fn a_new_send_waits_while_an_earlier_one_is_unresolved(cx: &mut TestAppContext) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(room(None));
            daemon.returns::<methods::HermesRoomsSend>(HermesRoomSendResult::default());
            let held = daemon.hold::<methods::HermesRoomsSend>();
            let (stores, pane, vcx) = open(cx, &daemon, "one-at-a-time");
            let sends = || daemon.calls::<methods::HermesRoomsSend>().len();
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("plant the beans", window, cx);
                p.send(window, cx);
            });
            // Unclear: the room holds the words for a retry.
            changed(&stores, room(Some("plant the beans")), vcx);
            drop(held);
            vcx.run_until_parked();
            // Another message waits until that one is settled.
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("water the peas", window, cx);
                p.send(window, cx);
            });
            vcx.run_until_parked();
            assert_eq!(
                sends(),
                1,
                "a second message went out over an unresolved one"
            );
            pane.read_with(vcx, |p, cx| assert!(p.send_waits(cx)));
            // The same message again is its own retry (posted at most once).
            daemon.returns::<methods::HermesRoomsSend>(HermesRoomSendResult {
                refused: true,
                ..Default::default()
            });
            pane.update_in(vcx, |p, window, cx| {
                assert!(p.can_try_again(cx));
                p.try_again(window, cx);
            });
            vcx.run_until_parked();
            assert_eq!(sends(), 2);
            assert_eq!(
                daemon.calls::<methods::HermesRoomsSend>()[1]["text"],
                "plant the beans"
            );
            // Refused: settled, so the next message may go.
            changed(&stores, room(None), vcx);
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("water the peas", window, cx);
                p.send(window, cx);
            });
            vcx.run_until_parked();
            assert_eq!(sends(), 3);
        }

        #[gpui_kit::test]
        fn a_send_refused_before_it_reached_the_room_can_go_again_unchanged(
            cx: &mut TestAppContext,
        ) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(room(None));
            daemon.once::<methods::HermesRoomsSend>(Err(conduit_protocol::RpcError::internal(
                "no Hermes connection",
            )));
            daemon.returns::<methods::HermesRoomsSend>(HermesRoomSendResult {
                sent: true,
                ..Default::default()
            });
            let (_stores, pane, vcx) = open(cx, &daemon, "predispatch");
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("hello", window, cx);
                p.send(window, cx);
            });
            vcx.run_until_parked();
            pane.read_with(vcx, |p, cx| assert_eq!(p.text(cx), "hello"));
            // No answer: nothing settles it but the user (the room holds no
            // retry, so Discard, then Send).
            pane.update_in(vcx, |p, window, cx| {
                assert!(!p.can_try_again(cx));
                p.discard(cx);
                p.send(window, cx);
            });
            vcx.run_until_parked();
            assert_eq!(daemon.calls::<methods::HermesRoomsSend>().len(), 2);
        }

        #[gpui_kit::test]
        fn an_unclear_send_stays_unsettled_through_an_idle_room_until_its_words_show(
            cx: &mut TestAppContext,
        ) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(room(None));
            daemon.returns::<methods::HermesRoomsSend>(HermesRoomSendResult::default());
            let held = daemon.hold::<methods::HermesRoomsSend>();
            let (stores, pane, vcx) = open(cx, &daemon, "idle");
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("hello", window, cx);
                p.send(window, cx);
            });
            changed(&stores, room(Some("hello")), vcx);
            drop(held);
            vcx.run_until_parked();
            // The room goes idle without its log showing the words yet: not
            // evidence either way.
            changed(&stores, room(None), vcx);
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("something else", window, cx);
                p.send(window, cx);
            });
            vcx.run_until_parked();
            assert_eq!(daemon.calls::<methods::HermesRoomsSend>().len(), 1);
            pane.update_in(vcx, |p, window, cx| p.type_text("hello", window, cx));
            pane.read_with(vcx, |p, cx| {
                assert!(p.send_waits(cx), "the words went sendable")
            });
            changed(&stores, posted(None, &[(4, "hello")]), vcx);
            pane.read_with(vcx, |p, cx| {
                assert!(!p.send_waits(cx));
                assert_eq!(p.text(cx), "");
            });
        }

        #[gpui_kit::test]
        fn an_unclear_send_is_not_settled_by_a_view_read_before_it(cx: &mut TestAppContext) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(room(None));
            daemon.returns::<methods::HermesRoomsSend>(HermesRoomSendResult::default());
            let (_stores, pane, vcx) = open(cx, &daemon, "cached");
            // The answer is unclear before any room event; the room shown is
            // the one read before the send.
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("hello", window, cx);
                p.send(window, cx);
            });
            vcx.run_until_parked();
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("another one", window, cx);
                p.send(window, cx);
            });
            vcx.run_until_parked();
            assert_eq!(daemon.calls::<methods::HermesRoomsSend>().len(), 1);
        }

        #[gpui_kit::test]
        fn words_edited_since_the_send_survive_its_confirmation(cx: &mut TestAppContext) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(room(None));
            daemon.returns::<methods::HermesRoomsSend>(HermesRoomSendResult::default());
            let held = daemon.hold::<methods::HermesRoomsSend>();
            let (stores, pane, vcx) = open(cx, &daemon, "edited");
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("hello", window, cx);
                p.send(window, cx);
            });
            changed(&stores, room(Some("hello")), vcx);
            drop(held);
            vcx.run_until_parked();
            pane.update_in(vcx, |p, window, cx| p.type_text("hello again", window, cx));
            changed(&stores, posted(None, &[(4, "hello")]), vcx);
            pane.read_with(vcx, |p, cx| {
                assert!(!p.send_waits(cx));
                assert_eq!(p.text(cx), "hello again");
            });
        }

        #[gpui_kit::test]
        fn another_clients_refused_retry_settles_nothing(cx: &mut TestAppContext) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(room(None));
            daemon.returns::<methods::HermesRoomsSend>(HermesRoomSendResult::default());
            let held = daemon.hold::<methods::HermesRoomsSend>();
            let (stores, pane, vcx) = open(cx, &daemon, "other-retry");
            let sends = || daemon.calls::<methods::HermesRoomsSend>().len();
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("hello", window, cx);
                p.send(window, cx);
            });
            changed(&stores, room(Some("hello")), vcx);
            drop(held);
            vcx.run_until_parked();
            // Another client's retry of the words is refused: the room lets
            // them go, and its log shows nothing new. Nothing is known of
            // this send.
            changed(&stores, room(None), vcx);
            pane.read_with(vcx, |p, cx| {
                assert_eq!(p.text(cx), "hello", "the words were taken as posted");
                assert!(p.send_waits(cx));
            });
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("something else", window, cx);
                p.send(window, cx);
            });
            vcx.run_until_parked();
            assert_eq!(sends(), 1);
            // The user lets it go: the words stay, Send is free.
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("hello", window, cx);
                p.discard(cx);
            });
            pane.read_with(vcx, |p, cx| {
                assert_eq!(p.text(cx), "hello");
                assert!(!p.send_waits(cx));
            });
            pane.update_in(vcx, |p, window, cx| p.send(window, cx));
            vcx.run_until_parked();
            assert_eq!(sends(), 2);
        }

        #[gpui_kit::test]
        fn a_send_with_no_answer_stays_pending_until_the_user_acts(cx: &mut TestAppContext) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(room(None));
            daemon.once::<methods::HermesRoomsSend>(Err(conduit_protocol::RpcError::internal(
                "the connection dropped",
            )));
            daemon.returns::<methods::HermesRoomsSend>(HermesRoomSendResult {
                sent: true,
                ..Default::default()
            });
            let (_stores, pane, vcx) = open(cx, &daemon, "no-answer");
            let sends = || daemon.calls::<methods::HermesRoomsSend>().len();
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("hello", window, cx);
                p.send(window, cx);
            });
            vcx.run_until_parked();
            pane.read_with(vcx, |p, cx| {
                assert_eq!(p.text(cx), "hello");
                assert!(
                    p.send_waits(cx),
                    "a send with no answer was taken as never received"
                );
            });
            pane.update_in(vcx, |p, window, cx| p.send(window, cx));
            vcx.run_until_parked();
            assert_eq!(sends(), 1);
            pane.update_in(vcx, |p, _, cx| p.discard(cx));
            pane.update_in(vcx, |p, window, cx| p.send(window, cx));
            vcx.run_until_parked();
            assert_eq!(sends(), 2);
        }

        #[gpui_kit::test]
        fn words_typed_in_a_room_wait_for_it_while_another_shows(cx: &mut TestAppContext) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(room(None));
            let (stores, pane, vcx) = open(cx, &daemon, "draft");
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("half a thought", window, cx)
            });
            // Another room or area shows: the pane goes; r1 opens again.
            drop(pane);
            let back = again(&stores, vcx);
            back.read_with(vcx, |p, cx| assert_eq!(p.text(cx), "half a thought"));
            // Another account's r1 never shows them.
            stores
                .hermes_rooms
                .update(vcx, |h, _| h.set_account(Some("blake".into())));
            let other = again(&stores, vcx);
            other.read_with(vcx, |p, cx| assert_eq!(p.text(cx), ""));
        }

        #[gpui_kit::test]
        fn a_room_pane_keeps_its_words_for_the_account_it_opened_under(cx: &mut TestAppContext) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(room(None));
            let (stores, pane, vcx) = open(cx, &daemon, "owner");
            pane.update_in(vcx, |p, window, cx| p.type_text("for avery", window, cx));
            // Another account takes charge while Avery's pane is still there
            // (the same room id in both).
            stores
                .hermes_rooms
                .update(vcx, |h, _| h.set_account(Some("blake".into())));
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("for avery, more", window, cx)
            });
            stores.hermes_rooms.read_with(vcx, |h, _| {
                assert_eq!(
                    h.draft(&key("blake", G1)),
                    None,
                    "Avery's words went to Blake"
                );
                assert_eq!(h.draft(&key("avery", G1)), Some("for avery, more"));
            });
            let blakes = again(&stores, vcx);
            blakes.read_with(vcx, |p, cx| assert_eq!(p.text(cx), ""));
        }

        #[gpui_kit::test]
        fn an_unclear_send_still_waits_for_its_words_after_the_room_opens_again(
            cx: &mut TestAppContext,
        ) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(room(None));
            daemon.returns::<methods::HermesRoomsSend>(HermesRoomSendResult::default());
            let held = daemon.hold::<methods::HermesRoomsSend>();
            let (stores, pane, vcx) = open(cx, &daemon, "unclear-again");
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("hello", window, cx);
                p.send(window, cx);
            });
            changed(&stores, room(Some("hello")), vcx);
            drop(held);
            vcx.run_until_parked();
            // Another room shows, then r1 again: the words come back, and
            // another message still waits on them.
            drop(pane);
            let back = again(&stores, vcx);
            back.read_with(vcx, |p, cx| assert_eq!(p.text(cx), "hello"));
            back.update_in(vcx, |p, window, cx| {
                p.type_text("hello there", window, cx);
                p.send(window, cx);
            });
            vcx.run_until_parked();
            assert_eq!(daemon.calls::<methods::HermesRoomsSend>().len(), 1);
            back.update_in(vcx, |p, window, cx| p.type_text("hello", window, cx));
            // The log shows them posted: a confirmed post leaves the field.
            changed(&stores, posted(None, &[(4, "hello")]), vcx);
            back.read_with(vcx, |p, cx| {
                assert!(!p.send_waits(cx));
                assert_eq!(p.text(cx), "");
            });
        }

        #[gpui_kit::test]
        fn a_send_confirmed_after_the_room_opened_again_leaves_its_field(cx: &mut TestAppContext) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(room(None));
            daemon.returns::<methods::HermesRoomsSend>(HermesRoomSendResult {
                sent: true,
                ..Default::default()
            });
            let held = daemon.hold::<methods::HermesRoomsSend>();
            let (stores, pane, vcx) = open(cx, &daemon, "confirm-again");
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("hello", window, cx);
                p.send(window, cx);
            });
            // The room is left and opened again before Hermes answers.
            drop(pane);
            let back = again(&stores, vcx);
            back.read_with(vcx, |p, cx| assert_eq!(p.text(cx), "hello"));
            drop(held);
            vcx.run_until_parked();
            back.read_with(vcx, |p, cx| {
                assert_eq!(p.text(cx), "", "the posted words stay sendable")
            });
            back.update_in(vcx, |p, window, cx| p.send(window, cx));
            vcx.run_until_parked();
            assert_eq!(daemon.calls::<methods::HermesRoomsSend>().len(), 1);
        }

        #[gpui_kit::test]
        fn words_typed_for_a_room_stay_with_its_gateway(cx: &mut TestAppContext) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(room(None));
            let (stores, pane, vcx) = open(cx, &daemon, "gateway");
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("for the first", window, cx)
            });
            drop(pane);
            // Another gateway with a room of the same id.
            stores
                .hermes_rooms
                .update(vcx, |h, _| h.set_gateway(Some(G2.into())));
            let other = again(&stores, vcx);
            other.read_with(vcx, |p, cx| assert_eq!(p.text(cx), ""));
            drop(other);
            stores
                .hermes_rooms
                .update(vcx, |h, _| h.set_gateway(Some(G1.into())));
            let back = again(&stores, vcx);
            back.read_with(vcx, |p, cx| assert_eq!(p.text(cx), "for the first"));
        }

        #[gpui_kit::test]
        fn words_typed_for_a_room_survive_a_reconnect_to_its_gateway(cx: &mut TestAppContext) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(room(None));
            let (stores, pane, vcx) = open(cx, &daemon, "reconnect");
            pane.update_in(vcx, |p, window, cx| p.type_text("still here", window, cx));
            drop(pane);
            stores
                .hermes_rooms
                .update(vcx, |h, cx| h.connection_lost(cx));
            vcx.run_until_parked();
            let back = again(&stores, vcx);
            back.read_with(vcx, |p, cx| assert_eq!(p.text(cx), "still here"));
        }

        #[gpui_kit::test]
        fn a_room_opened_again_gives_back_words_hermes_may_have(cx: &mut TestAppContext) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(room(Some("plant the beans")));
            let (_stores, pane, vcx) = open(cx, &daemon, "reopen");
            pane.read_with(vcx, |p, cx| assert_eq!(p.text(cx), "plant the beans"));
        }

        #[gpui_kit::test]
        fn mention_keys_go_to_the_room_only_while_its_field_has_focus(cx: &mut TestAppContext) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::HermesRoomsWatch>(room(None));
            let (_stores, pane, vcx) = open(cx, &daemon, "keys");
            pane.update_in(vcx, |p, window, cx| {
                p.type_text("@fe", window, cx);
                // Focus is elsewhere (another sheet, another window): its
                // Return is its own.
                window.blur(cx);
                assert!(!p.mention_key("enter", window, cx));
                assert_eq!(p.text(cx), "@fe");
                p.input.read(cx).focus_handle(cx).focus(window, cx);
                assert!(p.mention_key("enter", window, cx));
                assert_eq!(p.text(cx), "@fern ");
            });
        }
    }
}
