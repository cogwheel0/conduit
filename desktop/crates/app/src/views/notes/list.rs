//! All Notes: every note, searchable, pinned first, then in the phone's
//! time groups (Today, Yesterday, Previous 7 Days, Previous 30 Days,
//! Older), each group closable as the phone's are. A row shows the note's
//! title, its date and the start of its text, a pin, and who shared it.
//!
//! * **Search** asks the daemon (`notes.list` with the query: the core's
//!   own search, titles and text) as the user types.
//! * **Rows** open the note; a right click (or the row's More button) is
//!   the note's menu (Open, Copy, Pin, Share Access…, Delete…). ↑ and ↓
//!   move through the rows, Return opens one, ⌘⌫ deletes it.
//! * **New Note** (⌘N here) makes a note named for today and opens it.
//! * The list is virtualized ([`gpui_kit::list`]), so thousands of notes
//!   scroll at the display's rate.

use std::collections::HashSet;
use std::rc::Rc;
use std::time::Duration;

use chrono::Local;
use conduit_components::ActiveConduitTheme as _;
use conduit_components::announce::{Priority, live_text};
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::ConduitTheme;
use conduit_components::views::kit::{Button, ClickHandler, IconButton, bare_input, field_frame};
use conduit_protocol::{NoteQuery, NoteSection, NoteSummary, methods};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    App, ClickEvent, Context, Entity, FocusHandle, Focusable as _, FontWeight, KeyBinding,
    ListAlignment, ListState, MouseButton, MouseDownEvent, Role, SharedString, Subscription, Task,
    Window, actions, div, list, px,
};

use super::{NewNote, NoteCommand};
use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::stores::navigation::AreaItem;
use crate::views::dates;

pub const NOTES_LIST_CONTEXT: &str = "NotesList";

actions!(
    notes_list,
    [SelectPrevious, SelectNext, OpenSelected, DeleteSelected]
);

pub fn bindings() -> Vec<KeyBinding> {
    let c = Some(NOTES_LIST_CONTEXT);
    vec![
        KeyBinding::new("up", SelectPrevious, c),
        KeyBinding::new("down", SelectNext, c),
        KeyBinding::new("enter", OpenSelected, c),
        KeyBinding::new("cmd-backspace", DeleteSelected, c),
    ]
}

/// A row of the list.
#[derive(Clone, Debug, PartialEq)]
pub enum Row {
    /// A group's heading, with how many it holds and whether it is open.
    Heading {
        group: Group,
        count: usize,
        open: bool,
    },
    Note(NoteSummary),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Group {
    Pinned,
    Section(NoteSection),
}

/// The rows for `notes` (pinned first, as `notes.list` orders them): the
/// pinned ones, then each time group, a heading before each group that has
/// notes; a closed group shows only its heading. While searching, the
/// matches are one plain list.
pub fn rows(notes: &[NoteSummary], closed: &HashSet<Group>, searching: bool) -> Vec<Row> {
    if searching {
        return notes.iter().cloned().map(Row::Note).collect();
    }
    let mut out = vec![];
    let mut push = |group: Group, members: Vec<&NoteSummary>| {
        if members.is_empty() {
            return;
        }
        let open = !closed.contains(&group);
        out.push(Row::Heading {
            group,
            count: members.len(),
            open,
        });
        if open {
            out.extend(members.into_iter().cloned().map(Row::Note));
        }
    };
    push(Group::Pinned, notes.iter().filter(|n| n.pinned).collect());
    for section in [
        NoteSection::Today,
        NoteSection::Yesterday,
        NoteSection::Previous7Days,
        NoteSection::Previous30Days,
        NoteSection::Older,
    ] {
        push(
            Group::Section(section),
            notes
                .iter()
                // One from a newer conduitd's unknown group goes with the
                // oldest.
                .filter(|n| {
                    !n.pinned
                        && (n.section == section
                            || section == NoteSection::Older && n.section == NoteSection::Unknown)
                })
                .collect(),
        );
    }
    out
}

pub fn group_label(group: Group, l: &L10n) -> String {
    match group {
        Group::Pinned => l.pinned(),
        Group::Section(NoteSection::Today) => l.today(),
        Group::Section(NoteSection::Yesterday) => l.yesterday(),
        Group::Section(NoteSection::Previous7Days) => l.previous7_days(),
        Group::Section(NoteSection::Previous30Days) => l.previous30_days(),
        Group::Section(NoteSection::Older | NoteSection::Unknown) => l.older(),
    }
}

/// `preview` without the note's title at its start (a note whose text
/// opens with its title, as Notes leaves it out of the row).
pub fn without_title(preview: &str, title: &str) -> String {
    let title = title.trim();
    if !title.is_empty()
        && let Some(rest) = preview.get(..title.len())
        && rest.eq_ignore_ascii_case(title)
    {
        return preview[title.len()..].trim_start().to_string();
    }
    preview.to_string()
}

/// The start of a note's text without its markdown, on one line.
pub fn plain_preview(markdown: &str) -> String {
    let mut out = String::new();
    for line in markdown.lines() {
        let mut line = line.trim();
        for prefix in [
            "- [ ] ", "- [x] ", "* [ ] ", "* [x] ", "- ", "* ", "+ ", "> ",
        ] {
            if let Some(rest) = line.strip_prefix(prefix) {
                line = rest;
                break;
            }
        }
        line = line.trim_start_matches('#').trim_start();
        if let Some((n, rest)) = line.split_once(". ")
            && !n.is_empty()
            && n.chars().all(|c| c.is_ascii_digit())
        {
            line = rest;
        }
        if line.starts_with("```") || line.is_empty() {
            continue;
        }
        // [text](url) → text; emphasis and code marks go.
        let mut text = String::with_capacity(line.len());
        let mut rest = line;
        while let Some(open) = rest.find('[') {
            text.push_str(&rest[..open]);
            let after = &rest[open + 1..];
            match (after.find(']'), after.find("](")) {
                (Some(close), Some(link)) if close == link => {
                    text.push_str(&after[..close]);
                    let tail = &after[close + 2..];
                    rest = tail.find(')').map_or("", |e| &tail[e + 1..]);
                }
                _ => {
                    text.push('[');
                    rest = after;
                }
            }
        }
        text.push_str(rest);
        let text: String = text
            .chars()
            .filter(|c| !matches!(c, '*' | '_' | '`' | '~'))
            .collect();
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(text.trim());
        if out.len() > 160 {
            break;
        }
    }
    out
}

pub struct NotesList {
    stores: Stores,
    search: Entity<InputState>,
    query: String,
    /// The search's matches (None: not searching, or not answered yet).
    results: Option<Vec<NoteSummary>>,
    closed: HashSet<Group>,
    rows: Vec<Row>,
    list: ListState,
    /// The row the arrows are on (a note's id).
    cursor: Option<String>,
    hovered: Option<String>,
    focus: FocusHandle,
    revision: u64,
    _search: Option<Task<()>>,
    _subscriptions: Vec<Subscription>,
}

impl NotesList {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let placeholder = cx.l10n().desktop_search();
        let search = cx.new(|cx| InputState::new(window, cx).placeholder(placeholder));
        let subscriptions = vec![
            cx.observe(&stores.areas, |this, _, cx| {
                this.refresh_search(cx);
                this.rebuild(cx);
            }),
            cx.subscribe_in(&search, window, |this, input, e: &InputEvent, _, cx| {
                match e {
                    InputEvent::Change => {
                        let query = input.read(cx).value().to_string();
                        this.set_query(query, cx);
                    }
                    // Return in the field opens the note the arrows are on
                    // (↓ from the field moves to the first match).
                    InputEvent::PressEnter { .. } => {
                        if let Some(id) = this.cursor.clone() {
                            this.open(&id, cx);
                        }
                    }
                    _ => {}
                }
            }),
        ];
        let mut this = Self {
            stores,
            search,
            query: String::new(),
            results: None,
            closed: HashSet::new(),
            rows: vec![],
            list: ListState::new(0, ListAlignment::Top, px(600.)),
            cursor: None,
            hovered: None,
            focus: cx.focus_handle(),
            revision: 0,
            _search: None,
            _subscriptions: subscriptions,
        };
        this.rebuild(cx);
        this
    }

    /// The pane came into view: the list is fresh.
    pub fn shown(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        self.stores.areas.update(cx, |a, cx| {
            a.refresh(crate::stores::navigation::Area::Notes, cx)
        });
    }

    pub fn rows(&self) -> &[Row] {
        &self.rows
    }

    /// The list's scroll state (the perf fixture scrolls it).
    pub fn list_state(&self) -> &ListState {
        &self.list
    }

    pub fn is_searching(&self) -> bool {
        !self.query.trim().is_empty()
    }

    /// Searches for `query` (the E2E types it into the field instead).
    pub fn set_query(&mut self, query: String, cx: &mut Context<Self>) {
        self.query = query;
        if !self.is_searching() {
            self.results = None;
            self._search = None;
            self.rebuild(cx);
            return;
        }
        self.refresh_search(cx);
    }

    /// The search field, for the E2E.
    pub fn search_field(&self) -> &Entity<InputState> {
        &self.search
    }

    fn refresh_search(&mut self, cx: &mut Context<Self>) {
        if !self.is_searching() {
            return;
        }
        let rpc = self.stores.connection.read(cx).rpc();
        let query = self.query.clone();
        let task = cx.spawn(async move |this, cx| {
            // A pause while typing, then the search.
            cx.background_executor()
                .timer(Duration::from_millis(150))
                .await;
            let result = rpc
                .call::<methods::NotesList>(&NoteQuery {
                    query: query.clone(),
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.query != query {
                    return;
                }
                match result {
                    Ok(list) => this.results = Some(list.notes),
                    Err(e) => log::warn!("notes.list (search): {e}"),
                }
                this.rebuild(cx);
            });
        });
        self._search = Some(task);
    }

    fn rebuild(&mut self, cx: &mut Context<Self>) {
        let searching = self.is_searching();
        let notes: Vec<NoteSummary> = if searching {
            self.results.clone().unwrap_or_default()
        } else {
            self.stores.areas.read(cx).notes.clone().unwrap_or_default()
        };
        let rows = rows(&notes, &self.closed, searching);
        if rows != self.rows {
            self.rows = rows;
            self.list.reset(self.rows.len());
            self.revision += 1;
        }
        cx.notify();
    }

    fn toggle_group(&mut self, group: Group, cx: &mut Context<Self>) {
        if !self.closed.remove(&group) {
            self.closed.insert(group);
        }
        self.rebuild(cx);
    }

    fn note_ids(&self) -> Vec<String> {
        self.rows
            .iter()
            .filter_map(|r| match r {
                Row::Note(n) => Some(n.id.clone()),
                Row::Heading { .. } => None,
            })
            .collect()
    }

    fn step(&mut self, forward: bool, cx: &mut Context<Self>) {
        let ids = self.note_ids();
        if ids.is_empty() {
            return;
        }
        let at = self
            .cursor
            .as_ref()
            .and_then(|c| ids.iter().position(|i| i == c));
        let next = match (at, forward) {
            (None, true) => 0,
            (None, false) => ids.len() - 1,
            (Some(i), true) => (i + 1).min(ids.len() - 1),
            (Some(i), false) => i.saturating_sub(1),
        };
        self.cursor = Some(ids[next].clone());
        if let Some(ix) = self
            .rows
            .iter()
            .position(|r| matches!(r, Row::Note(n) if n.id == ids[next]))
        {
            self.list.scroll_to_reveal_item(ix);
        }
        cx.notify();
    }

    fn open(&mut self, id: &str, cx: &mut Context<Self>) {
        self.cursor = Some(id.to_string());
        let item = AreaItem::Note(id.to_string());
        self.stores
            .navigation
            .update(cx, |n, cx| n.open_item(item, cx));
    }

    fn menu(
        &mut self,
        note: &NoteSummary,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.cursor = Some(note.id.clone());
        let l = cx.l10n().clone();
        super::note_menu(note, &l).show(position, window, cx);
        cx.notify();
    }

    fn render_row(&mut self, ix: usize, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let Some(row) = self.rows.get(ix).cloned() else {
            return div().into_any_element();
        };
        match row {
            Row::Heading { group, count, open } => {
                heading_row(group, count, open, &t, &l, cx).into_any_element()
            }
            Row::Note(note) => self.note_row(&note, &t, &l, cx).into_any_element(),
        }
    }

    fn note_row(
        &mut self,
        note: &NoteSummary,
        t: &ConduitTheme,
        l: &L10n,
        cx: &mut Context<Self>,
    ) -> gpui_kit::Stateful<gpui_kit::Div> {
        let r = t.roles;
        let selected = self.cursor.as_deref() == Some(note.id.as_str());
        let hovered = self.hovered.as_deref() == Some(note.id.as_str());
        let title = if note.title.trim().is_empty() {
            l.untitled()
        } else {
            note.title.clone()
        };
        let (date, spoken_date) = dates::stamp(note.updated_at_ms, &Local::now(), l);
        let preview = without_title(&plain_preview(&note.preview), &note.title);
        let mut label = format!("{title}, {spoken_date}");
        if note.pinned {
            label.push_str(&format!(", {}", l.pinned()));
        }
        if let Some(owner) = &note.owner {
            label.push_str(&format!(", {}", l.shared_folder_owner(owner)));
        }
        if !note.can_edit {
            label.push_str(&format!(", {}", l.read_only()));
        }
        if !preview.is_empty() {
            label.push_str(&format!(", {preview}"));
        }
        let (id, hover_id, menu_note, open_id) = (
            note.id.clone(),
            note.id.clone(),
            note.clone(),
            note.id.clone(),
        );
        let more_note = note.clone();
        let more: ClickHandler = {
            let this = cx.entity().downgrade();
            Rc::new(move |e: &ClickEvent, window: &mut Window, cx: &mut App| {
                cx.stop_propagation();
                let (note, position) = (more_note.clone(), e.position());
                this.update(cx, |s, cx| s.menu(&note, position, window, cx))
                    .ok();
            })
        };
        div()
            .id(SharedString::from(format!("notes-row-{id}")))
            .role(Role::ListBoxOption)
            .aria_label(SharedString::from(label))
            .aria_selected(selected)
            .w_full()
            .px(px(16.))
            .child(
                div()
                    .w_full()
                    .flex()
                    .items_start()
                    .gap(px(10.))
                    .px(px(12.))
                    .py(px(9.))
                    .rounded(px(10.))
                    .when(selected, |d| d.bg(r.selected))
                    .when(hovered && !selected, |d| d.bg(r.hover))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap(px(2.))
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap(px(6.))
                                    .when(note.pinned, |d| {
                                        d.child(icon(IconName::Pin, 12., r.text_subtle))
                                    })
                                    .child(
                                        div()
                                            .flex_1()
                                            .min_w_0()
                                            .truncate()
                                            .text_size(px(t.metrics.body))
                                            .font_weight(FontWeight::SEMIBOLD)
                                            .text_color(r.text)
                                            .child(title),
                                    ),
                            )
                            .child(
                                div()
                                    .flex()
                                    .gap(px(8.))
                                    .text_size(px(t.metrics.small + 0.5))
                                    .child(div().flex_none().text_color(r.text).child(date))
                                    .child(
                                        div()
                                            .flex_1()
                                            .min_w_0()
                                            .truncate()
                                            .text_color(r.text_subtle)
                                            .child(if preview.is_empty() {
                                                l.desktop_note_no_text()
                                            } else {
                                                preview
                                            }),
                                    ),
                            )
                            .when(note.owner.is_some() || !note.can_edit, |d| {
                                // Who shared it, and that it only reads, as
                                // the phone's row badges it.
                                let mut line = note
                                    .owner
                                    .as_ref()
                                    .map(|o| l.shared_folder_owner(o))
                                    .unwrap_or_default();
                                if !note.can_edit {
                                    if !line.is_empty() {
                                        line.push_str(" \u{00b7} ");
                                    }
                                    line.push_str(&l.read_only());
                                }
                                d.child(
                                    div()
                                        .flex()
                                        .items_center()
                                        .gap(px(4.))
                                        .text_size(px(t.metrics.small))
                                        .text_color(r.text_subtle)
                                        .child(icon(IconName::Users, 11., r.text_subtle))
                                        .child(line),
                                )
                            })
                            .when(note.conflict_copy, |d| {
                                d.child(
                                    div()
                                        .text_size(px(t.metrics.small))
                                        .text_color(r.warning)
                                        .child(l.note_conflict_copy_badge()),
                                )
                            }),
                    )
                    .child(
                        div()
                            .flex_none()
                            .opacity(if hovered || selected { 1. } else { 0. })
                            .child(
                                IconButton::new(
                                    SharedString::from(format!("notes-row-more-{}", note.id)),
                                    IconName::Ellipsis,
                                    l.desktop_more_actions_for(&format!(
                                        "\u{201c}{}\u{201d}",
                                        note.title
                                    )),
                                )
                                .size(24., 14.)
                                .tooltip(l.more())
                                .on_click(more),
                            ),
                    ),
            )
            .on_hover(cx.listener(move |this, on: &bool, _, cx| {
                let id = hover_id.clone();
                if *on {
                    this.hovered = Some(id);
                } else if this.hovered.as_deref() == Some(id.as_str()) {
                    this.hovered = None;
                }
                cx.notify();
            }))
            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.open(&open_id, cx)))
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(move |this, e: &MouseDownEvent, window, cx| {
                    cx.stop_propagation();
                    this.menu(&menu_note, e.position, window, cx)
                }),
            )
    }
}

fn heading_row(
    group: Group,
    count: usize,
    open: bool,
    t: &ConduitTheme,
    l: &L10n,
    cx: &mut Context<NotesList>,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    let r = t.roles;
    let label = group_label(group, l);
    let key = match group {
        Group::Pinned => "pinned".to_string(),
        Group::Section(s) => format!("{s:?}").to_lowercase(),
    };
    div()
        .id(SharedString::from(format!("notes-group-{key}")))
        .role(Role::Heading)
        .aria_level(2)
        .aria_expanded(open)
        .aria_label(SharedString::from(format!("{label}, {count}")))
        .w_full()
        .px(px(28.))
        .pt(px(14.))
        .pb(px(4.))
        .flex()
        .items_center()
        .gap(px(6.))
        .cursor_pointer()
        .child(
            div()
                .text_size(px(t.metrics.small + 0.5))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(r.text_subtle)
                .child(label),
        )
        .child(
            div()
                .text_size(px(t.metrics.small))
                .text_color(r.text_faint)
                .child(count.to_string()),
        )
        .child(icon(
            if open {
                IconName::ChevronDown
            } else {
                IconName::ChevronRight
            },
            11.,
            r.text_faint,
        ))
        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.toggle_group(group, cx)))
}

impl gpui_kit::Focusable for NotesList {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for NotesList {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let r = t.roles;
        let loaded = self.stores.areas.read(cx).notes.is_some();
        let searching = self.is_searching();
        let empty = self.rows.is_empty();
        let new_note: ClickHandler =
            Rc::new(|_, window, cx| window.dispatch_action(Box::new(NewNote), cx));
        let focused = self.search.read(cx).focus_handle(cx).is_focused(window);
        let clear: Option<ClickHandler> = (!self.query.is_empty()).then(|| {
            let this = cx.entity().downgrade();
            Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                this.update(cx, |s, cx| {
                    s.search.update(cx, |i, cx| i.set_value("", window, cx));
                    s.set_query(String::new(), cx);
                })
                .ok();
            }) as ClickHandler
        });
        let header = div()
            .w_full()
            .flex()
            .items_center()
            .gap(px(10.))
            .px(px(28.))
            .pt(px(6.))
            .pb(px(10.))
            .child(
                div().flex_1().min_w_0().child(
                    field_frame(focused, t.metrics.control_height, cx)
                        .child(icon(IconName::Search, 14., r.text_subtle))
                        .child(
                            div().flex_1().min_w_0().child(
                                bare_input(
                                    &self.search,
                                    l.desktop_search_notes(),
                                    t.metrics.control,
                                )
                                .accessibility_id("notes-search-field"),
                            ),
                        )
                        .when_some(clear, |d, clear| {
                            d.child(
                                IconButton::new(
                                    "notes-search-clear",
                                    IconName::CircleX,
                                    l.desktop_clear_search(),
                                )
                                .size(20., 13.)
                                .on_click(clear),
                            )
                        }),
                ),
            )
            .child(
                Button::new("notes-new", l.desktop_new_note())
                    .icon(IconName::SquarePen)
                    .shortcut("⌘N")
                    .on_click(new_note.clone()),
            );
        let body = if !loaded {
            div()
                .flex_1()
                .flex()
                .items_center()
                .justify_center()
                .text_color(r.text_subtle)
                .child(l.loading_notes())
                // Said aloud, as the phone's loading state is.
                .child(live_text(
                    "notes-loading",
                    Some(l.loading_notes().into()),
                    Priority::Medium,
                ))
                .into_any_element()
        } else if empty {
            let (title, hint) = if searching {
                (l.no_notes_found(), l.desktop_search_no_notes())
            } else {
                (l.no_notes_yet(), l.create_first_note_hint())
            };
            div()
                .id("notes-empty")
                .flex_1()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(px(8.))
                .pb(px(60.))
                .child(icon(IconName::NotebookPen, 32., r.text_faint))
                .child(
                    div()
                        .text_size(px(t.metrics.body + 4.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text)
                        .child(title),
                )
                .child(div().text_color(r.text_subtle).child(hint))
                .when(!searching, |d| {
                    d.child(
                        div().pt(px(8.)).child(
                            Button::new("notes-empty-new", l.desktop_new_note())
                                .primary()
                                .on_click(new_note.clone()),
                        ),
                    )
                })
                .into_any_element()
        } else {
            list(
                self.list.clone(),
                cx.processor(|this, ix, _, cx| this.render_row(ix, cx)),
            )
            .size_full()
            .pb(px(16.))
            .into_any_element()
        };
        div()
            .id("notes-list")
            .key_context(NOTES_LIST_CONTEXT)
            .track_focus(&self.focus)
            .role(Role::ListBox)
            .aria_label(l.desktop_all_notes())
            .size_full()
            .flex()
            .flex_col()
            .bg(r.content)
            .on_action(cx.listener(|this, _: &SelectPrevious, _, cx| this.step(false, cx)))
            .on_action(cx.listener(|this, _: &SelectNext, _, cx| this.step(true, cx)))
            .on_action(cx.listener(|this, _: &OpenSelected, _, cx| {
                if let Some(id) = this.cursor.clone() {
                    this.open(&id, cx)
                }
            }))
            .on_action(cx.listener(|this, _: &DeleteSelected, window, cx| {
                if let Some(id) = this.cursor.clone() {
                    let stores = this.stores.clone();
                    super::run(&stores, &id, NoteCommand::Delete, window, cx);
                }
            }))
            .child(header)
            .child(div().flex_1().min_h_0().flex().flex_col().child(body))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(id: &str, section: NoteSection, pinned: bool) -> NoteSummary {
        serde_json::from_value(serde_json::json!({
            "id": id, "title": id, "updatedAtMs": 1, "pinned": pinned,
            "section": section,
        }))
        .unwrap()
    }

    /// A note in a time group this build does not know (from a newer
    /// conduitd) is listed under Older, not left out.
    #[test]
    fn a_note_in_an_unknown_time_group_is_listed_as_older() {
        let notes = vec![
            note("o", NoteSection::Older, false),
            note("u", NoteSection::Unknown, false),
        ];
        let ids: Vec<String> = rows(&notes, &HashSet::new(), false)
            .iter()
            .filter_map(|r| match r {
                Row::Note(n) => Some(n.id.clone()),
                Row::Heading { .. } => None,
            })
            .collect();
        assert_eq!(ids, ["o", "u"], "the note in an unknown group was left out");
    }

    #[test]
    fn notes_group_pinned_first_then_by_time_and_a_closed_group_keeps_its_heading() {
        let notes = vec![
            note("p", NoteSection::Older, true),
            note("t1", NoteSection::Today, false),
            note("t2", NoteSection::Today, false),
            note("o", NoteSection::Older, false),
        ];
        let shown = rows(&notes, &HashSet::new(), false);
        let labels: Vec<String> = shown
            .iter()
            .map(|r| match r {
                Row::Heading { group, count, .. } => format!("{group:?} {count}"),
                Row::Note(n) => n.id.clone(),
            })
            .collect();
        assert_eq!(
            labels,
            [
                "Pinned 1",
                "p",
                "Section(Today) 2",
                "t1",
                "t2",
                "Section(Older) 1",
                "o"
            ]
        );
        let closed = HashSet::from([Group::Section(NoteSection::Today)]);
        assert_eq!(rows(&notes, &closed, false).len(), 5);
        // A search is one plain list.
        assert_eq!(rows(&notes, &closed, true).len(), 4);
    }

    #[test]
    fn previews_drop_their_markdown() {
        assert_eq!(
            plain_preview(
                "# Plan\n- [ ] **Sow** beans\n1. see [the guide](https://a.example)\n```\ncode"
            ),
            "Plan Sow beans see the guide code"
        );
        assert_eq!(plain_preview(""), "");
        assert_eq!(
            without_title("Garden plan Beans along the fence", "Garden plan"),
            "Beans along the fence"
        );
        assert_eq!(without_title("Beans", "Garden plan"), "Beans");
    }
}
