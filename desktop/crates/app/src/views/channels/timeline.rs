//! A channel's timeline, or the thread beside it: a virtualized GPUI
//! `list` over [`super::model`]'s rows.
//!
//! * **Bottom-anchored**, as a chat log (the phone's reversed list,
//!   Messages, Slack): a short channel sits on the composer, and while the
//!   end is in view new messages keep it there. Scrolled up, the view
//!   stays put as messages arrive, and Jump to Latest brings it back.
//! * **Changes** reach the list as splices by row key (the rows kept at
//!   either end stay measured, so the scroll position holds); a row whose
//!   message changed (an edit, a reaction) is measured again alone.
//! * **Older messages** load a page at a time when the top row is drawn.
//! * **Rows** draw lazily: each message's markdown keeps one TextView state
//!   while the row is near the screen.
//! * **Actions:** hover shows React, Reply, Reply in Thread, Pin, Edit and
//!   Delete; a right-click opens the same as a native menu; reactions
//!   toggle with a click and name who reacted in their tooltip; an own
//!   message is edited in place (Return saves, Esc cancels).

use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use chrono::{Datelike as _, Local, NaiveDate, TimeZone as _};
use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{ConduitTheme, with_alpha};
use conduit_components::views::focus::ControlExt as _;
use conduit_components::views::kit::{IconButton, avatar, icon_tile, overlay_shadow, raised_fill};
use conduit_protocol::{
    ChannelAppReplyEvent, ChannelMessageDto, ChannelReaction, ChannelSenderKind, ChatFileDto,
};
use gpui_kit::EntityInputHandler as _;
use gpui_kit::component::input::{InputEvent, Textarea, TextareaState};
use gpui_kit::component::text::TextViewState;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, ClickEvent, Context, ElementId, Entity, FontWeight, ListAlignment, ListState,
    MouseButton, MouseDownEvent, Role, SharedString, Subscription, WeakEntity, Window, div, list,
    px,
};

use super::ChannelPane;
use super::apps;
use super::model::{TimelineRow, channel_rows, initials, splice_range, thread_rows};
use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::channel::ChannelStore;
use crate::views::dates::{self, Form};

/// The avatar's size, and the gutter it sits in.
pub const AVATAR: f32 = 32.;
pub const GUTTER: f32 = 44.;
/// The widest the text column reads, as the chat's.
pub const COLUMN: f32 = 860.;
/// How many rows' TextView states are kept beyond those drawn.
const KEEP_TEXTS: usize = 300;

/// Which list a timeline shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    Channel,
    /// The thread of this message.
    Thread(String),
}

pub struct ChannelTimeline {
    store: Entity<ChannelStore>,
    pane: WeakEntity<ChannelPane>,
    pub source: Source,
    list: ListState,
    rows: Vec<TimelineRow>,
    keys: Vec<String>,
    /// The message version each row was measured at.
    versions: Vec<u64>,
    seen: u64,
    texts: HashMap<String, (String, Entity<TextViewState>)>,
    drawn: HashSet<String>,
    hovered: Option<String>,
    /// The field an own message is edited in, by message id.
    edit: Option<(String, Entity<TextareaState>, Subscription)>,
    /// Scrolled away from the end: Jump to Latest shows.
    pub away: bool,
    _subscriptions: Vec<Subscription>,
}

impl ChannelTimeline {
    pub fn new(
        store: Entity<ChannelStore>,
        pane: WeakEntity<ChannelPane>,
        source: Source,
        cx: &mut Context<Self>,
    ) -> Self {
        // A channel is a log anchored on its composer; a thread reads from
        // its parent down, following its end once it is taller than the
        // panel.
        let list = match source {
            Source::Channel => ListState::new(0, ListAlignment::Bottom, px(900.)),
            Source::Thread(_) => {
                let list = ListState::new(0, ListAlignment::Top, px(900.));
                list.set_follow_mode(gpui_kit::FollowMode::Tail);
                list
            }
        };
        let weak = cx.entity().downgrade();
        list.set_scroll_handler(move |event, _, cx| {
            let near_top = event.visible_range.start <= 1;
            let at_end = event.visible_range.end >= event.count;
            let _ = weak.update(cx, |t, cx| {
                if t.away == at_end {
                    t.away = !at_end;
                    cx.notify();
                }
                if near_top {
                    t.load_older(cx);
                }
            });
        });
        let this_view = cx.entity().downgrade();
        let subscriptions = vec![
            cx.observe(&store, |this, _, cx| this.sync(cx)),
            // Esc in the edit field cancels the edit, ahead of the window's
            // own Esc (Stop Generating), which would take it first.
            cx.intercept_keystrokes({
                let weak = this_view;
                move |event, window, cx| {
                    let k = &event.keystroke;
                    if k.key != "escape" || k.modifiers.modified() {
                        return;
                    }
                    let Some(this) = weak.upgrade() else {
                        return;
                    };
                    let handled = this.update(cx, |t, cx| {
                        let Some((_, field, _)) = &t.edit else {
                            return false;
                        };
                        let focused = gpui_kit::Focusable::focus_handle(field.read(cx), cx)
                            .is_focused(window);
                        if focused {
                            t.cancel_edit(cx);
                        }
                        focused
                    });
                    if handled {
                        cx.stop_propagation();
                    }
                }
            }),
        ];
        let mut this = Self {
            store,
            pane,
            source,
            list,
            rows: vec![],
            keys: vec![],
            versions: vec![],
            seen: u64::MAX,
            texts: HashMap::new(),
            drawn: HashSet::new(),
            hovered: None,
            edit: None,
            away: false,
            _subscriptions: subscriptions,
        };
        this.sync(cx);
        this
    }

    pub fn list_state(&self) -> &ListState {
        &self.list
    }

    pub fn rows(&self) -> &[TimelineRow] {
        &self.rows
    }

    fn load_older(&mut self, cx: &mut Context<Self>) {
        let source = self.source.clone();
        self.store.update(cx, |s, cx| match source {
            Source::Channel => s.load_older(cx),
            Source::Thread(_) => s.load_older_replies(cx),
        });
    }

    /// The earlier page failed for this list.
    fn older_failed(&self, cx: &App) -> bool {
        let store = self.store.read(cx);
        match &self.source {
            Source::Channel => store.older_failed,
            Source::Thread(_) => store.thread.as_ref().is_some_and(|t| t.older_failed),
        }
    }

    /// Try Again on the failed earlier page.
    fn retry_older(&mut self, cx: &mut Context<Self>) {
        let source = self.source.clone();
        self.store.update(cx, |s, cx| match source {
            Source::Channel => s.retry_older(cx),
            Source::Thread(_) => s.retry_older_replies(cx),
        });
    }

    /// The newest message into view.
    pub fn jump_to_latest(&mut self, cx: &mut Context<Self>) {
        self.list.scroll_to_end();
        self.away = false;
        cx.notify();
    }

    /// The rows the store's state makes, spliced into the list by key.
    fn sync(&mut self, cx: &mut Context<Self>) {
        let store = self.store.read(cx);
        if store.revision() == self.seen {
            return;
        }
        self.seen = store.revision();
        let rows = match &self.source {
            Source::Channel => channel_rows(
                store.list.messages(),
                &store.app_replies,
                store.list.has_older,
                store.loaded,
            ),
            Source::Thread(parent) => match &store.thread {
                Some(thread) if &thread.parent_id == parent => thread_rows(
                    store.message(parent),
                    thread.list.messages(),
                    &store.app_replies,
                    thread.list.has_older,
                ),
                _ => vec![],
            },
        };
        let version = |row: &TimelineRow| -> u64 {
            match row {
                TimelineRow::Message { id, .. } => match &self.source {
                    Source::Channel => store.list.version(id),
                    Source::Thread(_) => store
                        .thread
                        .as_ref()
                        .map(|t| t.list.version(id))
                        .unwrap_or(0),
                },
                TimelineRow::Parent(id) => store.list.version(id),
                TimelineRow::AppReply {
                    message_id, app_id, ..
                } => store
                    .app_replies
                    .iter()
                    .position(|r| &r.message_id == message_id && &r.app_id == app_id)
                    .map(|p| p as u64 + store.revision())
                    .unwrap_or(0),
                // A row that draws state of its own (Loading…, the reply
                // count) is measured again with the store.
                TimelineRow::Older | TimelineRow::RepliesDivider => store.revision(),
                _ => 0,
            }
        };
        let keys: Vec<String> = rows.iter().map(TimelineRow::key).collect();
        let versions: Vec<u64> = rows.iter().map(version).collect();
        let editing = store.editing.clone();
        let _ = store;
        let (prefix, suffix) = splice_range(&self.keys, &keys);
        let old_mid = prefix..self.keys.len() - suffix;
        let new_mid = keys.len() - suffix - prefix;
        if self.keys.is_empty() {
            self.list.reset(keys.len());
        } else if !old_mid.is_empty() || new_mid > 0 {
            self.list.splice(old_mid, new_mid);
        }
        // Rows kept whose content changed are measured again.
        for (i, v) in versions.iter().enumerate() {
            let kept = i < prefix || i >= keys.len() - suffix;
            if !kept {
                continue;
            }
            let old_i = if i < prefix {
                i
            } else {
                i + self.keys.len() - keys.len()
            };
            if self.versions.get(old_i) != Some(v) {
                self.list.remeasure_items(i..i + 1);
            }
        }
        self.rows = rows;
        self.keys = keys;
        self.versions = versions;
        // The edit field follows the store's choice of message.
        let editing_here = editing.filter(|id| {
            self.rows.iter().any(|r| match r {
                TimelineRow::Message { id: m, .. } | TimelineRow::Parent(m) => m == id,
                _ => false,
            })
        });
        if self.edit.as_ref().map(|(id, ..)| id) != editing_here.as_ref() {
            self.edit = None;
            if let Some(id) = &editing_here {
                self.remeasure_message(id);
            }
        }
        cx.notify();
    }

    fn remeasure_message(&self, id: &str) {
        let key = format!("m-{id}");
        let parent = format!("p-{id}");
        if let Some(i) = self.keys.iter().position(|k| *k == key || *k == parent) {
            self.list.remeasure_items(i..i + 1);
        }
    }

    /// The edit field for message `id`, made on first draw with its text.
    fn edit_field(
        &mut self,
        id: &str,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<TextareaState> {
        if let Some((current, field, _)) = &self.edit
            && current == id
        {
            return field.clone();
        }
        let field = cx.new(|cx| {
            let mut s = TextareaState::new(window, cx).auto_grow(1, 12);
            s.set_value(text, window, cx);
            s.submit_on_enter(true)
        });
        let message_id = id.to_string();
        let subscription = cx.subscribe_in(
            &field,
            window,
            move |this, state, e: &InputEvent, window, cx| {
                if let InputEvent::PressEnter {
                    shift: false,
                    secondary: false,
                } = e
                {
                    let composing =
                        state.update(cx, |s, cx| s.marked_text_range(window, cx).is_some());
                    if !composing {
                        let text = state.read(cx).value().to_string();
                        this.save_edit(&message_id, text, cx);
                    }
                }
            },
        );
        field.update(cx, |s, cx| s.focus(window, cx));
        self.edit = Some((id.to_string(), field.clone(), subscription));
        field
    }

    fn save_edit(&mut self, id: &str, text: String, cx: &mut Context<Self>) {
        self.edit = None;
        self.remeasure_message(id);
        let id = id.to_string();
        self.store.update(cx, |s, cx| s.save_edit(&id, text, cx));
    }

    fn cancel_edit(&mut self, cx: &mut Context<Self>) {
        if let Some((id, ..)) = self.edit.take() {
            self.remeasure_message(&id);
        }
        self.store.update(cx, |s, cx| s.start_editing(None, cx));
    }

    /// The TextView state for `key`'s markdown, kept while it is drawn.
    fn text_state(
        &mut self,
        key: &str,
        markdown: &str,
        cx: &mut Context<Self>,
    ) -> Entity<TextViewState> {
        self.drawn.insert(key.to_string());
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

    /// Forgets the TextView states of rows long out of view.
    fn prune(&mut self) {
        if self.texts.len() <= KEEP_TEXTS + self.drawn.len() {
            self.drawn.clear();
            return;
        }
        let drawn = std::mem::take(&mut self.drawn);
        self.texts.retain(|k, _| drawn.contains(k));
    }

    fn set_hovered(&mut self, id: &str, on: bool, cx: &mut Context<Self>) {
        if on {
            if self.hovered.as_deref() != Some(id) {
                self.hovered = Some(id.to_string());
                cx.notify();
            }
        } else if self.hovered.as_deref() == Some(id) {
            self.hovered = None;
            cx.notify();
        }
    }

    // ── Rows ────────────────────────────────────────────────────────────

    fn render_row(&mut self, ix: usize, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let Some(row) = self.rows.get(ix).cloned() else {
            return div().into_any_element();
        };
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let body = match &row {
            // A failed earlier page waits for Try Again: drawing its row
            // asks for nothing.
            TimelineRow::Older if self.older_failed(cx) => {
                let weak = cx.entity().downgrade();
                older_failed_row(
                    &l,
                    &t,
                    Rc::new(move |_, _, cx| {
                        let _ = weak.update(cx, |t, cx| t.retry_older(cx));
                    }),
                )
            }
            TimelineRow::Older => {
                // Drawing the top row loads the page before it.
                let weak = cx.entity().downgrade();
                cx.defer(move |cx| {
                    let _ = weak.update(cx, |t, cx| t.load_older(cx));
                });
                older_row(&l, &t)
            }
            TimelineRow::Day(day) => day_row(*day, &l, &t),
            TimelineRow::Empty => empty_row(&l, &t),
            TimelineRow::RepliesDivider => self.replies_divider(&l, &t, cx),
            TimelineRow::Message { id, group_start } => {
                self.message_row(id, *group_start, false, window, cx)
            }
            TimelineRow::Parent(id) => self.message_row(id, true, true, window, cx),
            TimelineRow::AppReply { message_id, app_id } => {
                let reply = self
                    .store
                    .read(cx)
                    .app_replies
                    .iter()
                    .find(|r| &r.message_id == message_id && &r.app_id == app_id)
                    .cloned();
                match reply {
                    Some(reply) => self.app_reply_row(reply, window, cx),
                    None => div().into_any_element(),
                }
            }
        };
        div()
            .w_full()
            .flex()
            .justify_center()
            .child(div().w_full().max_w(px(COLUMN)).child(body))
            .into_any_element()
    }

    fn replies_divider(&self, l: &L10n, t: &ConduitTheme, cx: &App) -> AnyElement {
        let count = match &self.source {
            Source::Thread(parent) => {
                let store = self.store.read(cx);
                let loaded = store.thread.as_ref().map(|t| t.list.len()).unwrap_or(0) as i64;
                store
                    .message(parent)
                    .map(|m| m.reply_count)
                    .unwrap_or(0)
                    .max(loaded)
            }
            Source::Channel => 0,
        };
        let r = t.roles;
        div()
            .id("replies-divider")
            .role(Role::Heading)
            .aria_label(SharedString::from(l.desktop_channel_replies(count)))
            .px(px(16.))
            .py(px(8.))
            .flex()
            .items_center()
            .gap(px(10.))
            .child(
                div()
                    .flex_none()
                    .text_size(px(t.metrics.caption))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(l.desktop_channel_replies(count))),
            )
            .child(div().flex_1().h(px(1.)).bg(r.divider))
            .into_any_element()
    }

    fn message_row(
        &mut self,
        id: &str,
        group_start: bool,
        parent: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let store = self.store.read(cx);
        let Some(message) = store.message(id).cloned() else {
            return div().into_any_element();
        };
        let details = store.details.clone();
        let editing = store.editing.as_deref() == Some(id);
        let edit_draft = store.edit_draft.clone().filter(|_| editing);
        let pending_app = store.pending_actions.iter().any(|m| m == id);
        let in_thread = matches!(self.source, Source::Thread(_));
        let _ = store;
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let r = t.roles;
        let m = t.metrics;
        let moderator = details.as_ref().is_some_and(|d| d.moderator);
        let can_post = details.as_ref().is_none_or(|d| d.channel.can_post);
        let name = sender_name(&message, &l);
        let time = dates::format(message.created_at_ms, Form::Time, l.locale());
        let key = format!("{}-{}", if parent { "p" } else { "m" }, message.id);
        let row_id = ElementId::Name(key.clone().into());
        // A row Tab has reached shows its actions as hovering does.
        let focused = conduit_components::views::focus::control_focus_handle(&row_id, window, cx)
            .contains_focused(window, cx);
        let hovered = self.hovered.as_deref() == Some(key.as_str()) || focused;

        // ── Gutter: the avatar, or the time on hover in a run ──
        let gutter = div().w(px(GUTTER)).flex_none().flex().justify_start();
        let gutter = if group_start {
            gutter.pt(px(2.)).child(sender_avatar(&message, &name, &t))
        } else {
            gutter.h(px(m.body * m.leading)).items_center().child(
                div()
                    .text_size(px(m.caption))
                    .text_color(if hovered {
                        r.text_faint
                    } else {
                        with_alpha(r.text_faint, 0.)
                    })
                    .child(SharedString::from(time.clone())),
            )
        };

        // ── The column ──
        let mut column = div().flex_1().min_w_0().flex().flex_col().gap(px(3.));
        if group_start {
            column = column.child(
                div()
                    .flex()
                    .items_baseline()
                    .gap(px(6.))
                    .min_w_0()
                    .child(
                        div()
                            .truncate()
                            .text_size(px(m.body))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(r.text)
                            .child(SharedString::from(name.clone())),
                    )
                    .when(message.sender_kind == ChannelSenderKind::App, |d| {
                        d.child(apps::app_badge(&l, &t))
                    })
                    .child(
                        div()
                            .flex_none()
                            .text_size(px(m.caption))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(time.clone())),
                    )
                    .when(message.edited_at_ms.is_some(), |d| {
                        d.child(
                            div()
                                .flex_none()
                                .text_size(px(m.caption))
                                .text_color(r.text_faint)
                                .child(SharedString::from(l.desktop_channel_edited())),
                        )
                    }),
            );
        }
        if let Some(reply) = &message.reply_to {
            column = column.child(reply_quote(&reply.name, &reply.text, &t));
        }
        if message.pinned {
            column = column.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(4.))
                    .text_size(px(m.caption))
                    .text_color(r.text_subtle)
                    .child(icon(IconName::Pin, 12., r.text_subtle))
                    .child(SharedString::from(l.pinned())),
            );
        }
        if editing && message.mine {
            // A refused edit's words, else the message's.
            let text = edit_draft.unwrap_or_else(|| message.content.clone());
            let field = self.edit_field(id, &text, window, cx);
            let weak = cx.entity().downgrade();
            let cancel = weak.clone();
            let id_save = id.to_string();
            column = column.child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .on_key_down(cx.listener(|this, e: &gpui_kit::KeyDownEvent, _, cx| {
                        if e.keystroke.key == "escape" && !e.keystroke.modifiers.modified() {
                            this.cancel_edit(cx);
                            cx.stop_propagation();
                        }
                    }))
                    .child(
                        div()
                            .rounded(t.control_radius())
                            .border_1()
                            .border_color(r.border_strong)
                            .bg(r.content)
                            .px(px(8.))
                            .py(px(4.))
                            .child(
                                Textarea::new(&field)
                                    .appearance(false)
                                    .text_size(px(m.body)),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(8.))
                            .child(
                                div()
                                    .flex_1()
                                    .text_size(px(m.caption))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(l.desktop_channel_edit_hint())),
                            )
                            .child(
                                conduit_components::views::kit::Button::new(
                                    format!("edit-cancel-{id}"),
                                    l.cancel(),
                                )
                                .on_click(Rc::new(
                                    move |_, _, cx| {
                                        let _ = cancel.update(cx, |t, cx| t.cancel_edit(cx));
                                    },
                                )),
                            )
                            .child(
                                conduit_components::views::kit::Button::new(
                                    format!("edit-save-{id}"),
                                    l.save(),
                                )
                                .primary()
                                .on_click(Rc::new({
                                    let field = field.clone();
                                    move |_, _, cx| {
                                        let text = field.read(cx).value().to_string();
                                        let id = id_save.clone();
                                        let _ = weak.update(cx, |t, cx| t.save_edit(&id, text, cx));
                                    }
                                })),
                            ),
                    ),
            );
        } else if !message.display.trim().is_empty() {
            let state = self.text_state(&key, &message.display, cx);
            column = column.child(div().text_size(px(m.body)).text_color(r.text).child(
                crate::views::chat::markdown::chat_text(&state, key.clone().into()),
            ));
        }
        if !message.files.is_empty() {
            let files: Vec<ChatFileDto> = message
                .files
                .iter()
                .map(|f| ChatFileDto {
                    id: Some(f.id.clone()),
                    name: f.name.clone(),
                    image: f.image,
                    content_type: f.content_type.clone(),
                    data_url: None,
                })
                .collect();
            let server = self.pane.upgrade().and_then(|p| p.read(cx).server_id(cx));
            column = column.child(crate::views::chat::blocks::file_list(
                &key,
                &files,
                server.as_deref(),
                &l,
                &t,
                window,
                cx,
            ));
        }
        if let Some(app) = &message.app {
            let store = self.store.downgrade();
            let message_id = message.id.clone();
            let parent_id = match &self.source {
                Source::Thread(p) => Some(p.clone()),
                Source::Channel => None,
            };
            column = column.child(apps::app_content(
                &key,
                &message.id,
                app,
                pending_app,
                Rc::new(move |action_id: &str, cx: &mut App| {
                    let (mid, pid, aid) =
                        (message_id.clone(), parent_id.clone(), action_id.to_string());
                    let _ = store.update(cx, |s, cx| s.press_app_action(&mid, &aid, pid, cx));
                }),
                &mut |k: &str, md: &str, cx: &mut Context<Self>| self.text_state(k, md, cx),
                &l,
                &t,
                cx,
            ));
        }
        if !in_thread && !parent && message.reply_count > 0 {
            let pane = self.pane.clone();
            let mid = message.id.clone();
            let label = l.desktop_channel_replies(message.reply_count);
            column = column.child(
                div()
                    .id(ElementId::Name(format!("thread-{}", message.id).into()))
                    .role(Role::Link)
                    .aria_label(SharedString::from(label.clone()))
                    .flex()
                    .items_center()
                    .gap(px(2.))
                    .cursor_pointer()
                    .text_size(px(m.small))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(r.text_subtle)
                    .hover(|s| s.text_color(r.text))
                    .child(icon(IconName::MessagesSquare, 13., r.text_subtle))
                    .child(div().pl(px(3.)).child(SharedString::from(label)))
                    .child(icon(IconName::ChevronRight, 12., r.text_faint))
                    .tip(l.desktop_channel_reply_in_thread(), None)
                    .on_click(move |_, window, cx| {
                        let mid = mid.clone();
                        let _ = pane.update(cx, |p, cx| p.open_thread(mid, window, cx));
                    }),
            );
        }
        if !message.reactions.is_empty() {
            column = column.child(self.reactions(&message, can_post, &l, &t));
        }

        // ── Hover actions ──
        let actions = (hovered && !editing).then(|| {
            self.hover_actions(&message, parent, in_thread, can_post, moderator, &l, &t, cx)
        });

        let aria = format!("{name}, {time}: {}", message.content);
        let pane = self.pane.clone();
        let menu_id = message.id.clone();
        let key_pane = self.pane.clone();
        let key_id = message.id.clone();
        let list = self.list.clone();
        let row_index = self.keys.iter().position(|k| *k == key);
        let hover_key = key.clone();
        div()
            .id(row_id)
            .role(Role::Article)
            .aria_label(SharedString::from(aria))
            .keyboard_list_item(
                conduit_components::views::focus::Ring::Inset(0.),
                window,
                cx,
            )
            // Return (or Space) on a row Tab has reached opens its menu.
            .on_key_down(move |e: &gpui_kit::KeyDownEvent, window, cx| {
                let key = e.keystroke.key.as_str();
                if e.keystroke.modifiers.modified() || !matches!(key, "enter" | "space") {
                    return;
                }
                // Under the row's first line, as a right-click there would.
                let position = row_index
                    .and_then(|ix| list.bounds_for_item(ix))
                    .map(|b| b.origin + gpui_kit::point(px(GUTTER + 16.), px(24.)))
                    .unwrap_or_else(|| window.mouse_position());
                let id = key_id.clone();
                let _ = key_pane.update(cx, |p, cx| {
                    p.message_menu(id, in_thread || parent, position, window, cx)
                });
                cx.stop_propagation();
            })
            .relative()
            .px(px(16.))
            .pt(px(if group_start { 10. } else { 2. }))
            .pb(px(2.))
            .when(parent, |d| d.pt(px(12.)).pb(px(6.)))
            .flex()
            .bg(if hovered || editing {
                r.hover
            } else {
                r.content
            })
            .on_hover(
                cx.listener(move |this, on: &bool, _, cx| this.set_hovered(&hover_key, *on, cx)),
            )
            .on_mouse_down(MouseButton::Right, move |e: &MouseDownEvent, window, cx| {
                let id = menu_id.clone();
                let position = e.position;
                let _ = pane.update(cx, |p, cx| {
                    p.message_menu(id, in_thread || parent, position, window, cx)
                });
            })
            .child(gutter)
            .child(column)
            .children(actions)
            .into_any_element()
    }

    fn reactions(
        &self,
        message: &ChannelMessageDto,
        can_post: bool,
        l: &L10n,
        t: &ConduitTheme,
    ) -> AnyElement {
        let r = t.roles;
        let m = t.metrics;
        let mut row = div().flex().flex_wrap().gap(px(6.)).pt(px(2.));
        for (n, reaction) in message.reactions.iter().enumerate() {
            row = row.child(self.reaction_chip(message, n, reaction, can_post, l, t));
        }
        if can_post {
            let pane = self.pane.clone();
            let id = message.id.clone();
            row = row.child(
                div()
                    .id(ElementId::Name(format!("react-more-{}", message.id).into()))
                    .role(Role::Button)
                    .aria_label(SharedString::from(l.desktop_channel_add_reaction()))
                    .h(px(24.))
                    .px(px(7.))
                    .rounded_full()
                    .border_1()
                    .border_color(r.border)
                    .flex()
                    .items_center()
                    .cursor_pointer()
                    .hover(|s| s.bg(r.hover))
                    .child(icon(IconName::FaceSlightlySmilingPlus, 14., r.text_subtle))
                    .tip(l.desktop_channel_add_reaction(), None)
                    .on_click(move |e: &ClickEvent, window, cx| {
                        let id = id.clone();
                        let position = e.position();
                        let _ = pane
                            .update(cx, |p, cx| p.show_reaction_picker(id, position, window, cx));
                    }),
            );
        }
        let _ = m;
        row.into_any_element()
    }

    #[allow(clippy::too_many_arguments)]
    fn reaction_chip(
        &self,
        message: &ChannelMessageDto,
        n: usize,
        reaction: &ChannelReaction,
        can_post: bool,
        l: &L10n,
        t: &ConduitTheme,
    ) -> AnyElement {
        let r = t.roles;
        let m = t.metrics;
        let names = if reaction.names.is_empty() {
            reaction.count.to_string()
        } else {
            reaction.names.join(", ")
        };
        let tip = l.desktop_channel_reacted_by(&names, &reaction.name);
        let store = self.store.downgrade();
        let id = message.id.clone();
        let emoji = reaction.name.clone();
        let mine = reaction.mine;
        div()
            .id(ElementId::Name(
                format!("reaction-{}-{n}", message.id).into(),
            ))
            .role(Role::Button)
            .aria_label(SharedString::from(format!(
                "{} {}",
                reaction.name, reaction.count
            )))
            .aria_description(SharedString::from(tip.clone()))
            .aria_toggled(if mine {
                gpui_kit::Toggled::True
            } else {
                gpui_kit::Toggled::False
            })
            .h(px(24.))
            .px(px(8.))
            .rounded_full()
            .border_1()
            .border_color(if mine { r.border_strong } else { r.border })
            .bg(if mine {
                with_alpha(r.text, 0.08)
            } else {
                raised_fill(t)
            })
            .flex()
            .items_center()
            .gap(px(4.))
            .when(can_post, |d| d.cursor_pointer().hover(|s| s.bg(r.hover)))
            .child(
                div()
                    .text_size(px(m.body))
                    .child(SharedString::from(reaction.name.clone())),
            )
            .child(
                div()
                    .text_size(px(m.caption))
                    .font_weight(if mine {
                        FontWeight::SEMIBOLD
                    } else {
                        FontWeight::MEDIUM
                    })
                    .text_color(if mine { r.text } else { r.text_subtle })
                    .child(SharedString::from(reaction.count.to_string())),
            )
            .tip(tip, None)
            .when(can_post, |d| {
                d.on_click(move |_, _, cx| {
                    let (id, emoji) = (id.clone(), emoji.clone());
                    let _ = store.update(cx, |s, cx| s.toggle_reaction(&id, &emoji, cx));
                })
            })
            .into_any_element()
    }

    #[allow(clippy::too_many_arguments)]
    fn hover_actions(
        &self,
        message: &ChannelMessageDto,
        parent: bool,
        in_thread: bool,
        can_post: bool,
        moderator: bool,
        l: &L10n,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let r = t.roles;
        let id = message.id.clone();
        let pane = self.pane.clone();
        let store = self.store.downgrade();
        let button = |name: &str, icon: IconName, label: String| {
            IconButton::new(
                ElementId::Name(format!("{name}-{}", message.id).into()),
                icon,
                label,
            )
            .size(26., 15.)
        };
        let mut bar = div()
            .absolute()
            .top(px(-12.))
            .right(px(16.))
            .flex()
            .items_center()
            .gap(px(1.))
            .p(px(2.))
            .rounded(t.control_radius())
            .border_1()
            .border_color(r.border)
            .bg(r.overlay)
            .shadow(overlay_shadow(t));
        if can_post {
            let (p, i) = (pane.clone(), id.clone());
            bar = bar.child(
                button(
                    "react",
                    IconName::FaceSlightlySmilingPlus,
                    l.desktop_channel_add_reaction(),
                )
                .on_click(Rc::new(move |e: &ClickEvent, window, cx| {
                    let (i, position) = (i.clone(), e.position());
                    let _ = p.update(cx, |p, cx| p.show_reaction_picker(i, position, window, cx));
                })),
            );
            if !in_thread && !parent {
                let (p, i) = (pane.clone(), id.clone());
                bar = bar.child(
                    button("reply", IconName::Reply, l.channel_message_reply()).on_click(Rc::new(
                        move |_, window, cx| {
                            let i = i.clone();
                            let _ = p.update(cx, |p, cx| p.reply_to(i, window, cx));
                        },
                    )),
                );
                let (p, i) = (pane.clone(), id.clone());
                bar = bar.child(
                    button(
                        "thread",
                        IconName::MessagesSquare,
                        l.desktop_channel_reply_in_thread(),
                    )
                    .on_click(Rc::new(move |_, window, cx| {
                        let i = i.clone();
                        let _ = p.update(cx, |p, cx| p.open_thread(i, window, cx));
                    })),
                );
            }
            let (s, i, pinned) = (store.clone(), id.clone(), message.pinned);
            bar = bar.child(
                button(
                    "pin",
                    if pinned {
                        IconName::PinOff
                    } else {
                        IconName::Pin
                    },
                    if pinned { l.unpin() } else { l.pin() },
                )
                .on_click(Rc::new(move |_, _, cx| {
                    let i = i.clone();
                    let _ = s.update(cx, |s, cx| s.set_pinned(&i, !pinned, cx));
                })),
            );
        }
        if message.mine {
            let (s, i) = (store.clone(), id.clone());
            bar = bar.child(
                button("edit", IconName::Pencil, l.channel_message_edit()).on_click(Rc::new(
                    move |_, _, cx| {
                        let i = i.clone();
                        let _ = s.update(cx, |s, cx| s.start_editing(Some(i), cx));
                    },
                )),
            );
        }
        if message.mine || moderator {
            let (p, i) = (pane.clone(), id.clone());
            bar = bar.child(
                button("delete", IconName::Trash, l.channel_message_delete()).on_click(Rc::new(
                    move |_, window, cx| {
                        let i = i.clone();
                        let _ = p.update(cx, |p, cx| p.confirm_delete(i, window, cx));
                    },
                )),
            );
        }
        let _ = cx;
        bar.into_any_element()
    }

    fn app_reply_row(
        &mut self,
        reply: ChannelAppReplyEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let key = format!("r-{}-{}", reply.message_id, reply.app_id);
        let store = self.store.downgrade();
        let pane = self.pane.clone();
        let (mid, aid) = (reply.message_id.clone(), reply.app_id.clone());
        apps::private_reply(
            &key,
            &reply,
            Rc::new(move |cx: &mut App| {
                let _ = store.update(cx, |s, cx| s.dismiss_app_reply(&mid, &aid, cx));
            }),
            Rc::new(
                move |dto: conduit_protocol::ChannelAppReplyDto,
                      window: &mut Window,
                      cx: &mut App| {
                    let _ = pane.update(cx, |p, cx| p.save_report(dto, window, cx));
                },
            ),
            &mut |k: &str, md: &str, cx: &mut Context<Self>| self.text_state(k, md, cx),
            &l,
            &t,
            cx,
        )
    }
}

impl Render for ChannelTimeline {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.prune();
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let r = t.roles;
        let content = r.content;
        let jump = (self.away && self.source == Source::Channel).then(|| {
            let weak = cx.entity().downgrade();
            div()
                .absolute()
                .bottom(px(12.))
                .left_0()
                .right_0()
                .flex()
                .justify_center()
                .child(
                    div()
                        .id("jump-to-latest")
                        .role(Role::Button)
                        .aria_label(SharedString::from(l.desktop_channel_jump_to_latest()))
                        .h(px(28.))
                        .px(px(12.))
                        .rounded_full()
                        .border_1()
                        .border_color(r.border)
                        .bg(r.overlay)
                        .shadow(overlay_shadow(&t))
                        .flex()
                        .items_center()
                        .gap(px(6.))
                        .cursor_pointer()
                        .hover(|s| s.bg(r.overlay_hover))
                        .text_size(px(t.metrics.small))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(r.text)
                        .child(icon(IconName::ArrowDown, 13., r.text))
                        .child(SharedString::from(l.desktop_channel_jump_to_latest()))
                        .on_click(move |_, _, cx| {
                            let _ = weak.update(cx, |t, cx| t.jump_to_latest(cx));
                        }),
                )
        });
        div()
            .id(match &self.source {
                Source::Channel => "channel-timeline",
                Source::Thread(_) => "channel-thread-timeline",
            })
            .role(Role::Log)
            .aria_label(SharedString::from(l.desktop_messages()))
            .relative()
            .flex_1()
            .min_h_0()
            .w_full()
            .bg(content)
            .child(
                list(
                    self.list.clone(),
                    cx.processor(|this, ix, window, cx| this.render_row(ix, window, cx)),
                )
                .size_full()
                .pt(px(8.))
                .pb(px(8.)),
            )
            // Earlier messages slide under the toolbar through a fade.
            .child(div().absolute().top_0().left_0().right_0().h(px(16.)).bg(
                gpui_kit::linear_gradient(
                    180.,
                    gpui_kit::linear_color_stop(content, 0.),
                    gpui_kit::linear_color_stop(with_alpha(content, 0.), 1.),
                ),
            ))
            .children(jump)
    }
}

// ── Pieces ───────────────────────────────────────────────────────────────

/// Who wrote `message`, as its heading names them.
pub fn sender_name(message: &ChannelMessageDto, l: &L10n) -> String {
    message
        .user
        .as_ref()
        .map(|u| u.name.trim().to_string())
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| l.channel_unknown_member())
}

/// A sender's avatar: a model's sparkles, an app's grid, else initials.
pub fn sender_avatar(message: &ChannelMessageDto, name: &str, t: &ConduitTheme) -> AnyElement {
    let r = t.roles;
    let bg = with_alpha(r.text, 0.08);
    match message.sender_kind {
        ChannelSenderKind::Model => {
            icon_tile(IconName::Sparkles, AVATAR, bg, r.text_subtle, AVATAR / 2.).into_any_element()
        }
        ChannelSenderKind::App => {
            icon_tile(IconName::LayoutGrid, AVATAR, bg, r.text_subtle, 8.).into_any_element()
        }
        _ => avatar(&initials(name), AVATAR, bg, r.text_subtle).into_any_element(),
    }
}

fn reply_quote(name: &str, text: &str, t: &ConduitTheme) -> AnyElement {
    let r = t.roles;
    let m = t.metrics;
    let line: String = text
        .lines()
        .next()
        .unwrap_or_default()
        .chars()
        .take(140)
        .collect();
    div()
        .flex()
        .gap(px(8.))
        .child(
            div()
                .w(px(2.))
                .flex_none()
                .rounded_full()
                .bg(r.border_strong),
        )
        .child(
            div()
                .min_w_0()
                .flex()
                .gap(px(6.))
                .text_size(px(m.small))
                .child(
                    div()
                        .flex_none()
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text_subtle)
                        .child(SharedString::from(name.to_string())),
                )
                .child(
                    div()
                        .truncate()
                        .text_color(r.text_subtle)
                        .child(SharedString::from(line)),
                ),
        )
        .into_any_element()
}

fn older_row(l: &L10n, t: &ConduitTheme) -> AnyElement {
    div()
        .id("older")
        .role(Role::Status)
        .aria_label(SharedString::from(l.desktop_channel_loading_older()))
        .h(px(40.))
        .flex()
        .items_center()
        .justify_center()
        .text_size(px(t.metrics.small))
        .text_color(t.roles.text_faint)
        .child(SharedString::from(l.desktop_channel_loading_older()))
        .into_any_element()
}

/// The earlier page failed: why, and Try Again.
fn older_failed_row(
    l: &L10n,
    t: &ConduitTheme,
    retry: conduit_components::views::kit::ClickHandler,
) -> AnyElement {
    div()
        .id("older-failed")
        .min_h(px(40.))
        .py(px(6.))
        .flex()
        .items_center()
        .justify_center()
        .gap(px(10.))
        .child(
            div()
                .id("older-failed-text")
                .role(Role::Status)
                .text_size(px(t.metrics.small))
                .text_color(t.roles.text_subtle)
                .child(SharedString::from(l.desktop_channel_older_failed())),
        )
        .child(
            conduit_components::views::kit::Button::new("older-retry", l.desktop_try_again())
                .on_click(retry),
        )
        .into_any_element()
}

fn empty_row(l: &L10n, t: &ConduitTheme) -> AnyElement {
    div()
        .id("empty")
        .role(Role::Status)
        .aria_label(SharedString::from(l.channel_no_messages()))
        .py(px(48.))
        .flex()
        .flex_col()
        .items_center()
        .gap(px(10.))
        .child(icon(IconName::MessageSquare, 28., t.roles.text_faint))
        .child(
            div()
                .text_size(px(t.metrics.body))
                .text_color(t.roles.text_subtle)
                .child(SharedString::from(l.channel_no_messages())),
        )
        .into_any_element()
}

/// What a day heading says: Today, Yesterday, the weekday within the week,
/// then the long date.
pub fn day_title(day: NaiveDate, l: &L10n) -> String {
    let today = Local::now().date_naive();
    let ago = (today - day).num_days();
    match ago {
        0 => l.today(),
        1 => l.yesterday(),
        2..=6 => l.desktop_weekday_long(&day.weekday().number_from_monday().to_string()),
        _ => {
            let noon = day.and_hms_opt(12, 0, 0).unwrap_or_default();
            let ms = Local
                .from_local_datetime(&noon)
                .earliest()
                .map(|t| t.timestamp_millis())
                .unwrap_or(0);
            dates::format(ms, Form::LongDate, l.locale())
        }
    }
}

fn day_row(day: NaiveDate, l: &L10n, t: &ConduitTheme) -> AnyElement {
    let r = t.roles;
    let title = day_title(day, l);
    div()
        .id(ElementId::Name(format!("day-{day}").into()))
        .role(Role::Heading)
        .aria_level(2)
        .aria_label(SharedString::from(title.clone()))
        .px(px(16.))
        .pt(px(14.))
        .pb(px(4.))
        .flex()
        .items_center()
        .gap(px(12.))
        .child(div().flex_1().h(px(1.)).bg(r.divider))
        .child(
            div()
                .flex_none()
                .text_size(px(t.metrics.caption))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(r.text_subtle)
                .child(SharedString::from(title)),
        )
        .child(div().flex_1().h(px(1.)).bg(r.divider))
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use std::rc::Rc;

    use conduit_components::theme::{ConduitTheme, DesignPrefs, install};
    use conduit_protocol::{ChannelMessagesChanged, Event, methods};
    use gpui_kit::{TestAppContext, VisualTestContext};

    use super::*;
    use crate::l10n::L10n;
    use crate::stores::channel::Subscribe;
    use crate::stores::channel::tests::{details, message, page};
    use crate::stores::rpc::fake::FakeDaemon;

    struct Hosted(Entity<ChannelTimeline>);

    impl Render for Hosted {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div()
                .w(px(800.))
                .h(px(600.))
                .flex()
                .flex_col()
                .child(self.0.clone())
        }
    }

    fn frame(cx: &mut VisualTestContext) {
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(16));
        cx.update(|window, cx| window.draw(cx).clear(cx));
        cx.run_until_parked();
    }

    #[gpui_kit::test]
    fn the_list_follows_the_stores_messages_by_key(cx: &mut TestAppContext) {
        cx.update(|cx| {
            gpui_kit::init(cx);
            install(
                ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
                cx,
            );
            cx.set_global(L10n::new("en"));
            cx.set_global(conduit_components::Strings::default());
        });
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChannelsOpen>(details("c1"));
        let t0 = 1_790_000_000_000;
        daemon.returns::<methods::ChannelsMessages>(page(
            (0..30)
                .rev()
                .map(|n| message(&format!("m{n}"), t0 + n * 60_000, "Seedlings are up"))
                .collect(),
            false,
        ));
        let subscribe: Subscribe = Rc::new(|_, _| {});
        let rpc = daemon.rpc();
        let store = cx.new(|cx| ChannelStore::new(rpc, subscribe, "c1".into(), cx));
        cx.run_until_parked();
        let timeline = {
            let store = store.clone();
            cx.new(|cx| ChannelTimeline::new(store, WeakEntity::new_invalid(), Source::Channel, cx))
        };
        let host = timeline.clone();
        let (_, cx) = cx.add_window_view(move |_, _| Hosted(host));
        frame(cx);
        let count = |cx: &mut VisualTestContext| {
            timeline.read_with(cx, |t, _| (t.rows().len(), t.list_state().item_count()))
        };
        // One day heading, thirty messages; the list holds as many rows.
        let (rows, items) = count(cx);
        assert_eq!((rows, items), (31, 31));
        // A post spliced in at the end; an edit and a removal in place.
        store.update(cx, |s, cx| {
            let change = ChannelMessagesChanged {
                channel_id: "c1".into(),
                parent_id: None,
                upserts: vec![
                    message("new", t0 + 31 * 60_000, "Water stop at the ridge"),
                    message("m5", t0 + 5 * 60_000, "Edited"),
                ],
                removed: vec!["m7".into()],
                full: false,
                has_older: None,
            };
            s.on_event(&Event::ChannelsMessage(change), cx);
        });
        frame(cx);
        let (rows, items) = count(cx);
        assert_eq!((rows, items), (31, 31));
        let keys: Vec<String> =
            timeline.read_with(cx, |t, _| t.rows().iter().map(TimelineRow::key).collect());
        assert_eq!(keys.last().map(String::as_str), Some("m-new"));
        assert!(!keys.iter().any(|k| k == "m-m7"));
        // The end stays in view as the post arrives.
        let at_end = timeline.read_with(cx, |t, _| !t.away);
        assert!(at_end);
    }

    /// An earlier page that fails is asked for once, however often its row
    /// is drawn: no request after request while the server is away.
    #[gpui_kit::test]
    fn a_failed_earlier_page_is_asked_for_once(cx: &mut TestAppContext) {
        cx.update(|cx| {
            gpui_kit::init(cx);
            install(
                ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
                cx,
            );
            cx.set_global(L10n::new("en"));
            cx.set_global(conduit_components::Strings::default());
        });
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChannelsOpen>(details("c1"));
        let t0 = 1_790_000_000_000;
        let newest = serde_json::to_value(page(
            (0..3)
                .rev()
                .map(|n| message(&format!("m{n}"), t0 + n * 60_000, "Seedlings are up"))
                .collect(),
            true,
        ))
        .unwrap();
        // The earlier page fails; after five tries the server would say
        // there is none, so a test of a loop ends.
        let tries = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let oldest = serde_json::to_value(page(vec![], false)).unwrap();
        daemon.on::<methods::ChannelsMessages>(move |params| {
            if params["older"] != true {
                return Ok(newest.clone());
            }
            if tries.fetch_add(1, std::sync::atomic::Ordering::SeqCst) < 5 {
                Err(conduit_daemon::protocol::error(
                    "rpc.daemonUnavailable",
                    "away",
                ))
            } else {
                Ok(oldest.clone())
            }
        });
        let older_asked = |daemon: &FakeDaemon| {
            daemon
                .calls::<methods::ChannelsMessages>()
                .iter()
                .filter(|c| c["older"] == true)
                .count()
        };
        let subscribe: Subscribe = Rc::new(|_, _| {});
        let rpc = daemon.rpc();
        let store = cx.new(|cx| ChannelStore::new(rpc, subscribe, "c1".into(), cx));
        cx.run_until_parked();
        let timeline = {
            let store = store.clone();
            cx.new(|cx| ChannelTimeline::new(store, WeakEntity::new_invalid(), Source::Channel, cx))
        };
        let host = timeline.clone();
        let (_, cx) = cx.add_window_view(move |_, _| Hosted(host));
        for _ in 0..6 {
            frame(cx);
        }
        assert_eq!(
            older_asked(&daemon),
            1,
            "a failed earlier page was asked for again"
        );
        // Try Again asks once more; failing again, it waits again.
        timeline.update(cx, |t, cx| t.retry_older(cx));
        for _ in 0..6 {
            frame(cx);
        }
        assert_eq!(older_asked(&daemon), 2, "Try Again asked other than once");
    }
}
