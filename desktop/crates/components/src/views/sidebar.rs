//! The main window's sidebar: header controls inline with the traffic
//! lights, search, pinned chats, folders with nested chats, date groups and
//! the account/sync footer.
//!
//! [`Sidebar`] draws a whole [`SidebarModel`] (the gallery). The app draws a
//! virtualized body instead, from the same pieces: [`SidebarFrame`] (header,
//! search, footer around any body), [`chat_row`], [`folder_row`] and
//! [`section_header`].

use gpui_kit::prelude::*;
use gpui_kit::{
    Animation, AnimationExt as _, AnyElement, App, Div, ElementId, FontWeight, Hsla, Role,
    SharedString, Stateful, Transformation, Window, div, percentage, px,
};

use crate::assets::{IconName, icon};
use crate::strings::{ActiveStrings as _, Strings, fill};
use crate::theme::{ActiveConduitTheme, ConduitTheme, with_alpha};
use crate::views::focus::{
    ControlExt as _, Ring, hints, on_selection, pressed_fill, ring_overlay, selection_fill,
    selection_ink,
};
use crate::views::kit::{ClickHandler, IconButton, on_click_or_noop};
use crate::views::model::{Account, ChatRow, FolderRow, SidebarModel, SyncState};
use crate::window::{TOOLBAR_HEIGHT, TRAFFIC_LIGHTS_WIDTH, drag_region};

/// How a row draws.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RowState {
    /// The list's selection: the open chat, or the row the arrows moved to
    /// (a folder can be selected without opening).
    pub selected: bool,
    pub hovered: bool,
    /// A context menu is open for it (drawn with a focus outline).
    pub context: bool,
    /// Something dragged over it would drop here.
    pub drop_target: bool,
    /// In selection mode: whether it is chosen (`None` outside it).
    pub checked: Option<bool>,
    /// The list is key (has keyboard focus): its selection is drawn in the
    /// darker fill, as AppKit emphasizes a focused list's selection (no
    /// ring on top of it).
    pub keyboard: bool,
}

/// A hover action on a chat row.
#[derive(Clone)]
pub struct RowAction {
    pub id: SharedString,
    pub icon: IconName,
    pub label: SharedString,
    /// The tooltip, when shorter than the label ("Pin" for "Pin “Title”").
    pub tooltip: Option<SharedString>,
    pub on_click: Option<ClickHandler>,
}

impl RowAction {
    pub fn new(
        id: impl Into<SharedString>,
        icon: IconName,
        label: impl Into<SharedString>,
    ) -> Self {
        Self {
            id: id.into(),
            icon,
            label: label.into(),
            tooltip: None,
            on_click: None,
        }
    }
    pub fn tooltip(mut self, text: impl Into<SharedString>) -> Self {
        self.tooltip = Some(text.into());
        self
    }
    pub fn on_click(mut self, handler: ClickHandler) -> Self {
        self.on_click = Some(handler);
        self
    }
}

/// The gallery's hover action: "more" alone, as the app's rows (the rest
/// is in the context menu, as in Mail and Notes).
fn default_actions(chat: &ChatRow, st: &Strings) -> Vec<RowAction> {
    vec![RowAction::new(
        format!("more-{}", chat.id),
        IconName::Ellipsis,
        fill(
            &st.more_actions_for,
            &[("name", &format!("\u{201c}{}\u{201d}", chat.title))],
        ),
    )]
}

/// Where a row's text starts inside its highlight, and where section
/// headers start: the sidebar's leading content edge (the phone's 16 pt list
/// margin, at the desktop's scale).
pub const ROW_CONTENT_INSET: f32 = 8.;

/// A folder row's glyph and the gap after it.
pub const FOLDER_GLYPH: f32 = 15.;
pub const FOLDER_GLYPH_GAP: f32 = 7.;

/// The column a chat row keeps before its title for a status dot (the
/// phone's unread column; here an answer being written): as wide as a
/// folder's glyph and its gap, so a chat's title starts where a folder's
/// name does at the same level, one text edge per level (as Notes and
/// Mail keep one), and the dot sits under the folder glyphs.
pub const ROW_STATUS_GUTTER: f32 = FOLDER_GLYPH + FOLDER_GLYPH_GAP;

/// `title` split before a trailing count such as " (2)", which the row
/// keeps whole when it truncates the rest ("Why tides lag the m… (2)"), as
/// Finder truncates a long name in the middle and keeps its end. `None`
/// when there is no such count, or nothing before it.
pub fn title_suffix(title: &str) -> Option<(&str, &str)> {
    let open = title.strip_suffix(')')?.rfind(" (")?;
    let digits = &title[open + 2..title.len() - 1];
    if digits.is_empty() || digits.len() > 4 || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let base = &title[..open];
    (!base.trim().is_empty()).then(|| (base, &title[open..]))
}

/// A row title on one line that, when it is too long, keeps a trailing
/// count (see [`title_suffix`]) and truncates what comes before it: the
/// title truncates with "…" and the count as its ellipsis, so the cut text
/// and the count are one run (no gap after the "…").
pub fn row_title(title: &SharedString, size: f32, color: Hsla) -> Div {
    let line = div()
        .flex_1()
        .min_w_0()
        .text_size(px(size))
        .text_color(color)
        .truncate();
    match title_suffix(title) {
        Some((_, count)) => line
            .text_overflow(gpui_kit::TextOverflow::Truncate(
                format!("\u{2026}{count}").into(),
            ))
            .child(title.clone()),
        None => line.child(title.clone()),
    }
}

/// A row's hover button ("…"): its size, and how far its edge sits from
/// the row's end.
pub const ROW_ACTION_SIZE: f32 = 22.;
pub const ROW_ACTION_INSET: f32 = 3.;

/// The narrowest the date's slot gets: room for the hover button, so a
/// short date ("Mon") never lets the button cover the title.
pub const ROW_ACTION_SLOT: f32 = ROW_ACTION_SIZE - (ROW_CONTENT_INSET - ROW_ACTION_INSET);

/// The fill a row has under the pointer (what pressing darkens).
fn row_bg_hovered(state: RowState, t: &ConduitTheme) -> Hsla {
    row_bg(
        RowState {
            hovered: true,
            ..state
        },
        t,
    )
}

/// A row's background for its state: a wash of the text colour, never an
/// accent, as the phone's rows.
fn row_bg(state: RowState, t: &ConduitTheme) -> Hsla {
    let r = t.roles;
    // A row ticked in selection mode is filled as a selected row is, so
    // the chosen rows read at a glance (as Mail's multiple selection); the
    // cursor row's fill darkens while the list is key.
    if state.drop_target || state.selected || state.checked == Some(true) {
        selection_fill(t, state.selected && state.keyboard)
    } else if state.hovered {
        r.hover
    } else {
        with_alpha(r.text, 0.)
    }
}

/// A chat row: a status column, the title on one line and the date stamp
/// at its end, as the phone draws them. With `actions`, hovering shows them
/// in place of the stamp; `title` replaces the title (the inline rename
/// field).
/// What VoiceOver hears for chat row `chat` drawn in `state`: its title,
/// then its note, its Unread mark or what its answer is doing.
pub fn chat_row_label(chat: &ChatRow, state: RowState) -> String {
    let mut label = chat.title.to_string();
    if let Some(note) = &chat.note {
        label.push_str(", ");
        label.push_str(note);
    }
    if chat.unread && !chat.streaming && !state.selected {
        label.push_str(", ");
        label.push_str(chat.unread_spoken.as_ref().map_or("unread", |s| s.as_ref()));
    }
    if chat.streaming {
        label.push_str(", ");
        label.push_str(
            chat.status
                .as_ref()
                .map_or("writing an answer", |s| s.as_ref()),
        );
    }
    label
}

pub fn chat_row(
    chat: &ChatRow,
    state: RowState,
    indent: f32,
    actions: Vec<RowAction>,
    title: Option<AnyElement>,
    t: &ConduitTheme,
) -> Stateful<Div> {
    let r = t.roles;
    let m = t.metrics;
    let renaming = title.is_some();
    // On a key list's darker selection, text keeps AA.
    let key = state.selected && state.keyboard;
    let show_actions = state.hovered && !actions.is_empty() && state.checked.is_none();
    // The date's slot, which the hover buttons take over in place: it is
    // never narrower than they are and the row's padding never changes, so
    // hovering moves neither the date nor where the title truncates (a
    // read-only row, with no buttons, keeps its date exactly where it was).
    let trailing: Option<AnyElement> = (!renaming).then(|| {
        let stamp_id = format!("row-time-{}", chat.id);
        let time = div()
            .debug_selector(move || stamp_id)
            .text_size(px(m.small))
            .text_color(
                if state.selected || state.drop_target || state.checked == Some(true) {
                    on_selection(r.selected_text_subtle, t, key)
                } else {
                    r.sidebar_text_subtle
                },
            )
            .when(show_actions, |d| d.invisible())
            .child(chat.time.clone());
        div()
            .relative()
            .flex_none()
            .h(px(m.row_height))
            .min_w(px(ROW_ACTION_SLOT))
            .flex()
            .items_center()
            .justify_end()
            .child(time)
            .when(show_actions, |d| {
                d.child(
                    div()
                        .absolute()
                        .top_0()
                        .bottom_0()
                        // Out into the row's end padding, as far as the
                        // button's own inset.
                        .right(px(-(ROW_CONTENT_INSET - ROW_ACTION_INSET)))
                        .flex()
                        .items_center()
                        .gap(px(2.))
                        .children(actions.into_iter().map(|a| {
                            let mut b = IconButton::new(ElementId::Name(a.id), a.icon, a.label)
                                .size(ROW_ACTION_SIZE, 14.);
                            if let Some(tip) = a.tooltip {
                                b = b.tooltip(tip);
                            }
                            if let Some(h) = a.on_click {
                                b = b.on_click(h);
                            }
                            b
                        })),
                )
            })
            .into_any_element()
    });
    let label = chat_row_label(chat, state);
    let title: AnyElement = title.unwrap_or_else(|| {
        // The open chat is marked by its fill alone, at the regular weight
        // (as Finder's and Mail's source lists do), so selecting a row never
        // moves where its title truncates.
        row_title(&chat.title, m.control, on_selection(r.sidebar_text, t, key)).into_any_element()
    });
    // The status column: a dot while an answer is written, as the phone
    // marks an unread chat, centred where a folder's glyph sits; empty
    // otherwise, so titles line up with folder names.
    let status = div()
        .flex_none()
        .w(px(ROW_STATUS_GUTTER))
        .flex()
        .items_center()
        .child(
            div()
                .w(px(FOLDER_GLYPH))
                .flex()
                .justify_center()
                .when(
                    chat.streaming && !chat.working && state.checked.is_none(),
                    |d| {
                        d.child(div().size(px(6.)).rounded_full().bg(on_selection(
                            r.sidebar_text,
                            t,
                            key,
                        )))
                    },
                )
                // A Hermes session at work: the phone's spinner, still
                // under Reduce Motion.
                .when(chat.working && state.checked.is_none(), |d| {
                    let glyph = icon(
                        IconName::LoaderCircle,
                        12.,
                        on_selection(r.sidebar_text_subtle, t, key),
                    );
                    d.child(if chat.reduce_motion {
                        glyph.into_any_element()
                    } else {
                        glyph
                            .with_animation(
                                ElementId::Name(format!("working-{}", chat.id).into()),
                                Animation::new(std::time::Duration::from_millis(900)).repeat(),
                                |svg, delta| {
                                    svg.with_transformation(Transformation::rotate(percentage(
                                        delta,
                                    )))
                                },
                            )
                            .into_any_element()
                    })
                })
                // Unread: a slightly larger dot, as Mail's, until it is read
                // (none on the open chat, which is being read).
                .when(
                    chat.unread && !chat.streaming && !state.selected && state.checked.is_none(),
                    |d| {
                        d.child(
                            div()
                                .id(ElementId::Name(format!("unread-{}", chat.id).into()))
                                .size(px(8.))
                                .rounded_full()
                                .bg(r.sidebar_text),
                        )
                    },
                ),
        );
    div()
        .id(ElementId::Name(format!("chat-{}", chat.id).into()))
        // A row of the sidebar's outline (Finder's and Mail's source lists).
        .role(Role::TreeItem)
        .aria_label(SharedString::from(label))
        .aria_description(chat.time_spoken.clone())
        .aria_selected(state.selected)
        .h(px(m.row_height))
        .pl(px(ROW_CONTENT_INSET + indent))
        .pr(px(ROW_CONTENT_INSET))
        .flex()
        .flex_none()
        .items_center()
        .gap(px(8.))
        .rounded(t.row_radius())
        .bg(row_bg(state, t))
        .active(|s| s.bg(pressed_fill(row_bg_hovered(state, t), t)))
        .when(state.context, |d| d.border_2().border_color(r.focus))
        .relative()
        .cursor_pointer()
        .when_some(state.checked, |d, on| {
            d.child(
                div()
                    .flex_none()
                    .size(px(14.))
                    .rounded(px(4.))
                    .border_1()
                    // On a key list's inverted selection the box inverts
                    // too, so it still reads.
                    .border_color(match (on, key) {
                        (true, false) => r.selected_icon,
                        (true, true) => selection_ink(t),
                        (false, false) => with_alpha(r.sidebar_text, 0.45),
                        (false, true) => with_alpha(selection_ink(t), 0.6),
                    })
                    .when(on, |d| {
                        d.bg(if key {
                            selection_ink(t)
                        } else {
                            r.selected_icon
                        })
                    })
                    .flex()
                    .items_center()
                    .justify_center()
                    .when(on, |d| {
                        d.child(icon(
                            IconName::Check,
                            10.,
                            if key {
                                selection_fill(t, true)
                            } else {
                                r.content
                            },
                        ))
                    }),
            )
        })
        .when(state.checked.is_none(), |d| d.child(status))
        .child(
            div()
                .when(state.checked.is_none(), |d| d.ml(px(-8.)))
                .flex_1()
                .min_w_0()
                .flex()
                .child(title),
        )
        .children(trailing)
}

/// A folder as its row shows it.
#[derive(Clone, Debug, PartialEq)]
pub struct FolderLine {
    pub id: SharedString,
    pub name: SharedString,
    /// Chats inside, subfolders included; `None` while not known (a shared
    /// folder's chats load when it opens).
    pub count: Option<usize>,
    /// The count spoken ("3 conversations").
    pub count_label: SharedString,
    pub expanded: bool,
    /// A short badge after the name, also spoken after it ("Shared").
    pub badge: Option<SharedString>,
    /// The folder's own icon (an emoji, from its settings), drawn in place
    /// of the folder glyph.
    pub emoji: Option<SharedString>,
}

/// A folder row as the phone draws it: the outline folder glyph in the
/// secondary tone, the name in the primary one (as Finder's sidebar, so a
/// folder never reads as disabled beside its chats), an optional badge,
/// and a disclosure chevron at the trailing edge (› closed, ⌄ open). How
/// many chats it holds is spoken, not drawn. `name_field` replaces the name
/// (the inline rename field, or a new folder's), as Finder edits a name in
/// place.
pub fn folder_row(
    folder: &FolderLine,
    indent: f32,
    state: RowState,
    name_field: Option<AnyElement>,
    t: &ConduitTheme,
) -> Stateful<Div> {
    let FolderLine {
        id,
        name,
        count,
        count_label,
        expanded,
        badge,
        emoji,
    } = folder.clone();
    let r = t.roles;
    let m = t.metrics;
    // On a key list's inverted selection, its glyphs and badge invert too.
    let key = state.selected && state.keyboard;
    let glyph = on_selection(r.sidebar_text_subtle, t, key);
    let label = match &badge {
        Some(b) => SharedString::from(format!("{name}, {b}")),
        None => name.clone(),
    };
    div()
        .id(ElementId::Name(format!("folder-{id}").into()))
        .role(Role::TreeItem)
        .aria_label(label)
        .when(count.is_some(), |d| d.aria_description(count_label))
        .aria_expanded(expanded)
        .aria_selected(state.selected)
        .h(px(m.row_height))
        .pl(px(ROW_CONTENT_INSET + indent))
        .pr(px(ROW_CONTENT_INSET))
        .flex()
        .flex_none()
        .items_center()
        .gap(px(FOLDER_GLYPH_GAP))
        .rounded(t.row_radius())
        .bg(row_bg(state, t))
        .relative()
        // Where a dragged chat would go: outlined, as Finder and Mail
        // outline a drop target (drawn over the row, so nothing moves).
        .when(state.drop_target, |d| {
            d.child(
                ring_overlay(Ring::Inset(f32::from(t.row_radius())), t)
                    .debug_selector(|| "drop-target".into()),
            )
        })
        .cursor_pointer()
        .when(!state.selected && !state.drop_target, |d| {
            d.hover(|s| s.bg(r.hover))
        })
        .active(|s| s.bg(pressed_fill(row_bg_hovered(state, t), t)))
        .child(match emoji {
            // The same box as the glyph, so names line up either way.
            Some(e) => div()
                .size(px(FOLDER_GLYPH))
                .flex()
                .flex_none()
                .items_center()
                .justify_center()
                .text_size(px(FOLDER_GLYPH - 1.))
                .line_height(px(FOLDER_GLYPH))
                .child(e)
                .into_any_element(),
            None => icon(IconName::Folder, FOLDER_GLYPH, glyph).into_any_element(),
        })
        .child(match name_field {
            Some(field) => div()
                .flex_1()
                .min_w_0()
                .flex()
                .child(field)
                .into_any_element(),
            None => div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_size(px(m.control))
                .text_color(on_selection(r.sidebar_text, t, key))
                .child(name.clone())
                .into_any_element(),
        })
        .when_some(badge, |d, b| {
            d.child(
                div()
                    .flex_none()
                    .px(px(5.))
                    .py(px(1.))
                    .rounded(px(4.))
                    .bg(if key {
                        with_alpha(selection_ink(t), 0.2)
                    } else {
                        r.selected
                    })
                    .text_size(px(m.caption - 1.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(if key {
                        selection_ink(t)
                    } else {
                        r.selected_text_subtle
                    })
                    .child(b),
            )
        })
        .child(icon(
            if expanded {
                IconName::ChevronDown
            } else {
                IconName::ChevronRight
            },
            12.,
            glyph,
        ))
}

/// The height of a [`section_header`] (its top gap included).
pub const SECTION_HEADER_HEIGHT: f32 = 28.;

/// A section heading ("Pinned", "Today") as the phone draws one: semibold
/// in the secondary tone, starting where row text starts, an optional
/// trailing control, and for a section that can close a disclosure chevron
/// that turns down while it is open (`expanded`).
pub fn section_header(
    id: &str,
    label: &SharedString,
    trailing: Option<AnyElement>,
    expanded: Option<bool>,
    t: &ConduitTheme,
) -> Stateful<Div> {
    let r = t.roles;
    // The secondary tone at full strength in both modes: it is already as
    // light as AA allows.
    let tone = r.sidebar_text_subtle;
    div()
        .id(ElementId::Name(format!("section-{id}").into()))
        // Every section title is a heading; one that opens and closes says
        // so (VoiceOver's rotor lists them all).
        .role(Role::Heading)
        .aria_level(2)
        .aria_label(label.clone())
        .when_some(expanded, |d, e| d.aria_expanded(e).cursor_pointer())
        .h(px(SECTION_HEADER_HEIGHT))
        .pl(px(ROW_CONTENT_INSET))
        .pr(px(ROW_CONTENT_INSET))
        .pt(px(6.))
        .flex()
        .flex_none()
        .items_center()
        .gap(px(6.))
        .rounded(t.row_radius())
        .child(
            div()
                .flex_1()
                .truncate()
                .text_size(px(t.metrics.small))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(tone)
                .child(label.clone()),
        )
        .children(trailing)
        .when_some(expanded, |d, e| {
            d.child(icon(
                if e {
                    IconName::ChevronDown
                } else {
                    IconName::ChevronRight
                },
                12.,
                tone,
            ))
        })
}

/// A [`section_header`] for a section that closes but shows its chevron
/// only while the header is hovered or the section closed (a date section:
/// the phone draws none, and Finder's and Mail's sidebars reveal theirs on
/// hover). VoiceOver hears it as a heading that is open or closed.
pub fn quiet_section_header(
    id: &str,
    label: &SharedString,
    expanded: bool,
    t: &ConduitTheme,
) -> Stateful<Div> {
    let group = SharedString::from(format!("section-{id}-hover"));
    let chevron = div()
        .flex_none()
        .when(expanded, |d| d.invisible())
        .group_hover(group.clone(), |s| s.visible())
        .child(icon(
            if expanded {
                IconName::ChevronDown
            } else {
                IconName::ChevronRight
            },
            12.,
            t.roles.sidebar_text_subtle,
        ));
    section_header(id, label, Some(chevron.into_any_element()), None, t)
        .group(group)
        .aria_expanded(expanded)
        .cursor_pointer()
}

/// How far an area's heading sits below the area above it: the gap
/// Finder's and Mail's sidebars leave between their groups.
pub const AREA_GAP: f32 = 14.;

/// An area's heading ("Notes", "Channels"), as Finder's and Mail's
/// sidebars head their groups: bold in the secondary tone at the rows'
/// leading edge, its disclosure chevron showing while hovered, closed or
/// stood on by the keyboard. VoiceOver hears a heading that is open or
/// closed. `selected` draws it as the keyboard's selection.
pub fn area_header(
    id: &str,
    label: &SharedString,
    expanded: bool,
    state: RowState,
    t: &ConduitTheme,
) -> Stateful<Div> {
    let r = t.roles;
    let key = state.selected && state.keyboard;
    let tone = on_selection(r.sidebar_text_subtle, t, key);
    let group = SharedString::from(format!("area-{id}-hover"));
    let chevron = div()
        .flex_none()
        .when(expanded && !state.selected, |d| d.invisible())
        .group_hover(group.clone(), |s| s.visible())
        .child(icon(
            if expanded {
                IconName::ChevronDown
            } else {
                IconName::ChevronRight
            },
            12.,
            tone,
        ));
    div()
        .id(ElementId::Name(format!("area-{id}").into()))
        .group(group)
        .role(Role::Heading)
        .aria_level(2)
        .aria_label(label.clone())
        .aria_expanded(expanded)
        .aria_selected(state.selected)
        .h(px(SECTION_HEADER_HEIGHT))
        .pl(px(ROW_CONTENT_INSET))
        .pr(px(ROW_CONTENT_INSET))
        .flex()
        .flex_none()
        .items_center()
        .gap(px(6.))
        .rounded(t.row_radius())
        .cursor_pointer()
        .when(state.selected, |d| d.bg(selection_fill(t, key)))
        .child(
            div()
                .flex_1()
                .truncate()
                .text_size(px(t.metrics.small))
                .font_weight(FontWeight::BOLD)
                .text_color(tone)
                .child(label.clone()),
        )
        .child(chevron)
}

/// An item of an area as its row shows it: a note, a channel, a Hermes
/// session, a workspace section, a terminal server.
#[derive(Clone, Debug, PartialEq)]
pub struct ItemLine {
    pub id: SharedString,
    pub icon: IconName,
    pub title: SharedString,
    /// At the trailing edge: a date, or a channel's unread count.
    pub trailing: Option<SharedString>,
    /// Spoken after the title ("Yesterday", "3 unread").
    pub description: Option<SharedString>,
    /// A pin before the trailing text (a pinned note or session).
    pub pinned: bool,
    /// The trailing text is a count to notice (unread messages): drawn in
    /// the primary tone.
    pub emphasized: bool,
}

/// An area item's row: its glyph where a folder's sits, the title where a
/// chat's starts, and the date or count at the trailing edge, as Mail draws
/// a mailbox's unread count.
pub fn item_row(line: &ItemLine, state: RowState, t: &ConduitTheme) -> Stateful<Div> {
    let r = t.roles;
    let m = t.metrics;
    let key = state.selected && state.keyboard;
    let glyph = on_selection(r.sidebar_text_subtle, t, key);
    let subtle = if state.selected {
        on_selection(r.selected_text_subtle, t, key)
    } else {
        r.sidebar_text_subtle
    };
    let mut label = line.title.to_string();
    if let Some(d) = &line.description {
        label.push_str(", ");
        label.push_str(d);
    }
    div()
        .id(ElementId::Name(format!("item-{}", line.id).into()))
        .role(Role::TreeItem)
        .aria_label(SharedString::from(label))
        .aria_selected(state.selected)
        .h(px(m.row_height))
        .pl(px(ROW_CONTENT_INSET))
        .pr(px(ROW_CONTENT_INSET))
        .flex()
        .flex_none()
        .items_center()
        .gap(px(FOLDER_GLYPH_GAP))
        .rounded(t.row_radius())
        .bg(row_bg(state, t))
        .when(!state.selected, |d| d.hover(|s| s.bg(r.hover)))
        .active(|s| s.bg(pressed_fill(row_bg_hovered(state, t), t)))
        .cursor_pointer()
        .child(icon(line.icon, FOLDER_GLYPH, glyph))
        .child(row_title(
            &line.title,
            m.control,
            on_selection(r.sidebar_text, t, key),
        ))
        .when(line.pinned, |d| d.child(icon(IconName::Pin, 11., subtle)))
        .when_some(line.trailing.clone(), |d, text| {
            d.child(
                div()
                    .flex_none()
                    .min_w(px(ROW_ACTION_SLOT))
                    .flex()
                    .justify_end()
                    .text_size(px(m.small))
                    .when(line.emphasized, |d| d.font_weight(FontWeight::SEMIBOLD))
                    .text_color(if line.emphasized {
                        on_selection(r.sidebar_text, t, key)
                    } else {
                        subtle
                    })
                    .child(text),
            )
        })
}

/// A bot or a room as its row shows it: its face where a glyph sits.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FaceLine {
    pub id: SharedString,
    pub title: SharedString,
    /// At the trailing edge: when it was last active.
    pub trailing: Option<SharedString>,
    /// Spoken after the title.
    pub description: Option<SharedString>,
    /// Something was said since it was last shown: a dot, as Mail marks
    /// an unread mailbox, and the title in the stronger weight.
    pub unread: bool,
    /// Its bots are at work (or its chat is opening): a spinner in place
    /// of the date, still under Reduce Motion.
    pub working: bool,
    pub reduce_motion: bool,
    /// Spoken when `unread`.
    pub unread_spoken: Option<SharedString>,
    /// Spoken when `working`.
    pub working_spoken: Option<SharedString>,
}

/// A row with a face (a bot's, a room's stack) where an item's glyph sits,
/// the title where a chat's starts, and at the trailing edge the date, a
/// spinner while it works or the unread dot; hovering shows `actions` in
/// the date's place, as a chat row does.
pub fn face_row(
    line: &FaceLine,
    face: AnyElement,
    state: RowState,
    actions: Vec<RowAction>,
    t: &ConduitTheme,
) -> Stateful<Div> {
    let r = t.roles;
    let m = t.metrics;
    let key = state.selected && state.keyboard;
    let subtle = if state.selected {
        on_selection(r.selected_text_subtle, t, key)
    } else {
        r.sidebar_text_subtle
    };
    let mut label = line.title.to_string();
    if let Some(d) = &line.description {
        label.push_str(", ");
        label.push_str(d);
    }
    if line.unread && !state.selected {
        label.push_str(", ");
        label.push_str(line.unread_spoken.as_ref().map_or("unread", |s| s.as_ref()));
    }
    if line.working {
        label.push_str(", ");
        label.push_str(
            line.working_spoken
                .as_ref()
                .map_or("working", |s| s.as_ref()),
        );
    }
    let show_actions = state.hovered && !actions.is_empty();
    let spinner = || {
        let glyph = icon(IconName::LoaderCircle, 12., subtle);
        if line.reduce_motion {
            glyph.into_any_element()
        } else {
            glyph
                .with_animation(
                    ElementId::Name(format!("working-{}", line.id).into()),
                    Animation::new(std::time::Duration::from_millis(900)).repeat(),
                    |svg, delta| svg.with_transformation(Transformation::rotate(percentage(delta))),
                )
                .into_any_element()
        }
    };
    let mark: Option<AnyElement> = if line.working {
        Some(spinner())
    } else if line.unread && !state.selected {
        Some(
            div()
                .id(ElementId::Name(format!("unread-{}", line.id).into()))
                .size(px(8.))
                .rounded_full()
                .bg(on_selection(r.sidebar_text, t, key))
                .into_any_element(),
        )
    } else {
        line.trailing.clone().map(|text| {
            div()
                .text_size(px(m.small))
                .text_color(subtle)
                .child(text)
                .into_any_element()
        })
    };
    let trailing = div()
        .relative()
        .flex_none()
        .h(px(m.row_height))
        .min_w(px(ROW_ACTION_SLOT))
        .flex()
        .items_center()
        .justify_end()
        .children(mark.map(|m| div().when(show_actions, |d| d.invisible()).child(m)))
        .when(show_actions, |d| {
            d.child(
                div()
                    .absolute()
                    .top_0()
                    .bottom_0()
                    .right(px(-(ROW_CONTENT_INSET - ROW_ACTION_INSET)))
                    .flex()
                    .items_center()
                    .gap(px(2.))
                    .children(actions.into_iter().map(|a| {
                        let mut b = IconButton::new(ElementId::Name(a.id), a.icon, a.label)
                            .size(ROW_ACTION_SIZE, 14.);
                        if let Some(tip) = a.tooltip {
                            b = b.tooltip(tip);
                        }
                        if let Some(h) = a.on_click {
                            b = b.on_click(h);
                        }
                        b
                    })),
            )
        });
    let title_color = on_selection(r.sidebar_text, t, key);
    div()
        .id(ElementId::Name(format!("item-{}", line.id).into()))
        .role(Role::TreeItem)
        .aria_label(SharedString::from(label))
        .aria_selected(state.selected)
        .h(px(m.row_height))
        .pl(px(ROW_CONTENT_INSET))
        .pr(px(ROW_CONTENT_INSET))
        .flex()
        .flex_none()
        .items_center()
        .gap(px(FOLDER_GLYPH_GAP))
        .rounded(t.row_radius())
        .bg(row_bg(state, t))
        .when(!state.selected, |d| d.hover(|s| s.bg(r.hover)))
        .active(|s| s.bg(pressed_fill(row_bg_hovered(state, t), t)))
        .when(state.context, |d| d.border_2().border_color(r.focus))
        .cursor_pointer()
        .child(
            div()
                .flex_none()
                .w(px(FOLDER_GLYPH))
                .flex()
                .justify_center()
                .child(face),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .child(if line.unread && !state.selected {
                    row_title(&line.title, m.control, title_color).font_weight(FontWeight::SEMIBOLD)
                } else {
                    row_title(&line.title, m.control, title_color)
                }),
        )
        .child(trailing)
}

/// A quiet row of secondary text at the title column: an area's Show All
/// (or Show Less).
pub fn more_row(
    id: &str,
    label: &SharedString,
    state: RowState,
    t: &ConduitTheme,
) -> Stateful<Div> {
    let r = t.roles;
    let key = state.selected && state.keyboard;
    div()
        .id(ElementId::Name(format!("more-{id}").into()))
        .role(Role::TreeItem)
        .aria_label(label.clone())
        .aria_selected(state.selected)
        .h(px(t.metrics.row_height))
        .pl(px(ROW_CONTENT_INSET + ROW_STATUS_GUTTER))
        .pr(px(ROW_CONTENT_INSET))
        .flex()
        .flex_none()
        .items_center()
        .rounded(t.row_radius())
        .bg(row_bg(state, t))
        .when(!state.selected, |d| d.hover(|s| s.bg(r.hover)))
        .active(|s| s.bg(pressed_fill(row_bg_hovered(state, t), t)))
        .cursor_pointer()
        .text_size(px(t.metrics.small))
        .text_color(on_selection(r.sidebar_text_subtle, t, key))
        .child(label.clone())
}

fn section(
    id: &str,
    label: &str,
    trailing: Option<AnyElement>,
    rows: Vec<AnyElement>,
    t: &ConduitTheme,
) -> Stateful<Div> {
    div()
        .id(ElementId::Name(format!("section-list-{id}").into()))
        .role(Role::Tree)
        .aria_label(SharedString::from(label.to_string()))
        .flex()
        .flex_col()
        .gap(px(1.))
        .child(section_header(
            id,
            &SharedString::from(label.to_string()),
            trailing,
            None,
            t,
        ))
        .children(rows)
}

/// The sidebar's chrome around a body: the header (traffic-light inset,
/// toggle and New Chat), the search field, the sync caption and the
/// account footer. Without handlers the controls do nothing (the gallery).
#[derive(IntoElement)]
pub struct SidebarFrame {
    body: AnyElement,
    search: Option<AnyElement>,
    /// Drawn between search and the body (the selection bar).
    banner: Option<AnyElement>,
    sync: SyncState,
    account: Account,
    on_toggle: Option<ClickHandler>,
    on_new_chat: Option<ClickHandler>,
    on_search: Option<ClickHandler>,
    /// The search field holds a query: an ⓧ that clears it takes the
    /// shortcut hint's place (NSSearchField's cancel button).
    on_clear_search: Option<ClickHandler>,
    on_account: Option<ClickHandler>,
    on_sync: Option<ClickHandler>,
    on_settings: Option<ClickHandler>,
    /// Rows run under the footer (the list is taller than its space): the
    /// footer gets a full-width rule, as a scrolled source list's bottom
    /// bar does.
    overflows: bool,
}

impl SidebarFrame {
    pub fn new(body: impl IntoElement, sync: SyncState, account: Account) -> Self {
        Self {
            body: body.into_any_element(),
            search: None,
            banner: None,
            sync,
            account,
            on_toggle: None,
            on_new_chat: None,
            on_search: None,
            on_clear_search: None,
            on_account: None,
            on_sync: None,
            on_settings: None,
            overflows: false,
        }
    }
    /// A real search field in place of the gallery's search button.
    pub fn search(mut self, field: impl IntoElement) -> Self {
        self.search = Some(field.into_any_element());
        self
    }
    pub fn banner(mut self, banner: Option<AnyElement>) -> Self {
        self.banner = banner;
        self
    }
    pub fn on_toggle(mut self, h: ClickHandler) -> Self {
        self.on_toggle = Some(h);
        self
    }
    pub fn on_new_chat(mut self, h: ClickHandler) -> Self {
        self.on_new_chat = Some(h);
        self
    }
    pub fn on_search(mut self, h: ClickHandler) -> Self {
        self.on_search = Some(h);
        self
    }
    /// While the field holds a query: its ⓧ, in place of the ⌥⌘F hint.
    pub fn on_clear_search(mut self, h: Option<ClickHandler>) -> Self {
        self.on_clear_search = h;
        self
    }
    pub fn on_account(mut self, h: ClickHandler) -> Self {
        self.on_account = Some(h);
        self
    }
    pub fn on_sync(mut self, h: ClickHandler) -> Self {
        self.on_sync = Some(h);
        self
    }
    /// The list is taller than the space it has (see `overflows`).
    pub fn overflows(mut self, overflows: bool) -> Self {
        self.overflows = overflows;
        self
    }
    pub fn on_settings(mut self, h: ClickHandler) -> Self {
        self.on_settings = Some(h);
        self
    }
}

/// The search capsule: a glyph, the field (or the word "Search") and the
/// shortcut that reaches it (Edit › Find, ⌘F; ⌘K without one), on a quiet
/// fill as the phone's search field.
pub fn search_pill(
    field: Option<AnyElement>,
    t: &ConduitTheme,
    st: &Strings,
    keys: Option<SharedString>,
    clear: Option<ClickHandler>,
) -> Div {
    let r = t.roles;
    let m = t.metrics;
    // NSSearchField's cancel button: a filled grey disc with a white ×,
    // only while there is something to clear (the hint goes meanwhile).
    let trailing: AnyElement = match clear {
        Some(h) => div()
            .id("sidebar-search-clear")
            .debug_selector(|| "sidebar-search-clear".into())
            .role(Role::Button)
            .aria_label(st.clear_search.clone())
            .flex_none()
            .size(px(16.))
            .flex()
            .items_center()
            .justify_center()
            .rounded_full()
            .cursor_pointer()
            .bg(with_alpha(r.sidebar_text_subtle, 0.55))
            .hover(|s| s.bg(with_alpha(r.sidebar_text_subtle, 0.8)))
            .child(icon(
                IconName::X,
                10.,
                if t.dark { r.text } else { r.content },
            ))
            .tip(st.clear_search.clone(), None)
            // Not the field's own mouse handling (which would focus it).
            .on_mouse_down(gpui_kit::MouseButton::Left, |_, window, cx| {
                window.prevent_default();
                cx.stop_propagation();
            })
            .on_click(move |e, window, cx| h(e, window, cx))
            .into_any_element(),
        None => div()
            .flex_none()
            .text_size(px(m.small))
            .text_color(r.sidebar_text_subtle)
            .child(keys.unwrap_or_else(|| "\u{2318}K".into()))
            .into_any_element(),
    };
    div()
        .h(px(m.control_height))
        .px(px(10.))
        .flex()
        .items_center()
        .gap(px(6.))
        .rounded_full()
        .bg(with_alpha(r.text, if t.dark { 0.09 } else { 0.055 }))
        .child(icon(IconName::Search, 14., r.sidebar_text_subtle))
        .child(match field {
            Some(f) => div().flex_1().min_w_0().child(f).into_any_element(),
            None => div()
                .flex_1()
                .text_size(px(m.control))
                .text_color(r.sidebar_text_subtle)
                .child(st.search.clone())
                .into_any_element(),
        })
        .child(trailing)
}

impl RenderOnce for SidebarFrame {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let st = cx.strings().clone();
        let keys = hints(cx);
        let r = t.roles;
        let m = t.metrics;
        let pressed = pressed_fill(r.hover, &t);
        let (sync_icon, sync_color, sync_label) = match &self.sync {
            SyncState::Synced { detail } => (IconName::RefreshCw, r.sidebar_text_subtle, detail),
            SyncState::Syncing { detail } => (IconName::RefreshCw, r.selected_icon, detail),
            SyncState::Offline { detail } => (IconName::CloudOff, r.warning, detail),
        };
        let account = self.account.clone();
        let syncing = matches!(self.sync, SyncState::Syncing { .. });
        let caption = sync_caption(&self.sync, cx);
        let search: AnyElement = match self.search {
            Some(field) => search_pill(
                Some(field),
                &t,
                &st,
                keys.find.clone(),
                self.on_clear_search,
            )
            .id("sidebar-search")
            .into_any_element(),
            None => search_pill(None, &t, &st, keys.palette.clone(), None)
                .id("sidebar-search")
                .role(Role::Button)
                .aria_label(st.search_chats.clone())
                .aria_keyshortcuts("Meta+K")
                .cursor_pointer()
                .on_click(on_click_or_noop(self.on_search))
                .into_any_element(),
        };
        let mut toggle = IconButton::new(
            "toggle-sidebar",
            IconName::PanelLeft,
            st.hide_sidebar.clone(),
        )
        .shortcut(keys.toggle_sidebar.clone());
        if let Some(h) = self.on_toggle {
            toggle = toggle.on_click(h);
        }
        let mut new_chat = IconButton::new("new-chat", IconName::SquarePen, st.new_chat.clone())
            .shortcut(keys.new_chat.clone());
        if let Some(h) = self.on_new_chat {
            new_chat = new_chat.on_click(h);
        }
        let mut settings =
            IconButton::new("open-settings", IconName::Settings, st.settings.clone())
                .shortcut(keys.settings.clone());
        if let Some(h) = self.on_settings {
            settings = settings.on_click(h);
        }

        div()
            .id("sidebar")
            .role(Role::Navigation)
            .aria_label(st.sidebar.clone())
            .w(px(m.sidebar_width))
            .h_full()
            .flex_none()
            .flex()
            .flex_col()
            .bg(r.sidebar)
            // Header: traffic lights live at the leading edge; drag anywhere.
            .child(
                drag_region("sidebar-titlebar")
                    .h(px(TOOLBAR_HEIGHT))
                    .flex_none()
                    .flex()
                    .items_center()
                    .pl(px(TRAFFIC_LIGHTS_WIDTH))
                    .pr(px(10.))
                    .gap(px(2.))
                    .child(div().flex_1())
                    .child(toggle)
                    .child(new_chat),
            )
            .child(div().flex_none().px(px(10.)).pb(px(6.)).child(search))
            .children(self.banner)
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .overflow_hidden()
                    .flex()
                    .flex_col()
                    .child(self.body),
            )
            .when(syncing, |d| {
                d.child(
                    div()
                        .id("sync-progress")
                        .role(Role::Status)
                        .aria_label(sync_label.clone())
                        .flex_none()
                        .px(px(18.))
                        .pb(px(8.))
                        .child(caption),
                )
            })
            // Where rows run under the footer, a full-width rule marks the
            // edge (the system separator: the sidebar's ink at 10–16%, which
            // reads on the material and on a solid surface alike, where the
            // content's border tone is lighter than a light sidebar); with
            // room to spare the footer sits on the list's own surface, as
            // Mail's and Notes' sidebars do.
            .child(div().flex_none().h(px(1.)).when(self.overflows, |d| {
                d.bg(with_alpha(r.sidebar_text, if t.dark { 0.16 } else { 0.10 }))
            }))
            .child(
                div()
                    .flex_none()
                    .h(px(52.))
                    .px(px(10.))
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .child(
                        div()
                            .id("account-switcher")
                            .role(Role::Button)
                            .aria_label(SharedString::from(format!(
                                "{}, {}",
                                account.name, account.server
                            )))
                            .aria_description(st.accounts.clone())
                            .flex_1()
                            .min_w_0()
                            .h(px(40.))
                            .px(px(6.))
                            .rounded(t.control_radius())
                            .flex()
                            .items_center()
                            .gap(px(8.))
                            .cursor_pointer()
                            .hover(|s| s.bg(r.hover))
                            .active(|s| s.bg(pressed))
                            .tip(st.accounts.clone(), None)
                            .child(monogram(&account.initials(), 28., &t))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .flex()
                                    .flex_col()
                                    .child(
                                        div()
                                            .truncate()
                                            .text_size(px(m.control))
                                            .font_weight(FontWeight::SEMIBOLD)
                                            .text_color(r.sidebar_text)
                                            .child(account.name.clone()),
                                    )
                                    .child(
                                        div()
                                            .truncate()
                                            .text_size(px(m.caption))
                                            .text_color(r.sidebar_text_subtle)
                                            .child(if account.email.is_empty() {
                                                account.server.clone()
                                            } else {
                                                account.email.clone()
                                            }),
                                    ),
                            )
                            .on_click(on_click_or_noop(self.on_account))
                            .keyboard_control(
                                Ring::Outset(f32::from(t.control_radius())),
                                window,
                                cx,
                            ),
                    )
                    .child(
                        // Named for what a click does; the status follows in
                        // the tooltip and the description.
                        div()
                            .id("sync-status")
                            .role(Role::Button)
                            .aria_label(st.sync_now.clone())
                            .aria_description(sync_label.clone())
                            .size(px(28.))
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(t.control_radius())
                            .hover(|s| s.bg(r.hover))
                            .active(|s| s.bg(pressed))
                            .cursor_pointer()
                            .child(icon(sync_icon, 15., sync_color))
                            .tip(st.sync_now.clone(), Some(sync_label.clone()))
                            .on_click(on_click_or_noop(self.on_sync))
                            .keyboard_control(
                                Ring::Outset(f32::from(t.control_radius())),
                                window,
                                cx,
                            ),
                    )
                    .child(settings),
            )
    }
}

/// The account's monogram as the phone draws it: white initials on a mid
/// grey disc, the same in every palette.
pub fn monogram(initials: &str, size: f32, t: &ConduitTheme) -> Div {
    let r = t.roles;
    let fill = crate::theme::mix(r.text, r.content, if t.dark { 0.55 } else { 0.45 });
    div()
        .flex_none()
        .size(px(size))
        .rounded_full()
        .bg(fill)
        .flex()
        .items_center()
        .justify_center()
        .text_size(px(size * 0.4))
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(gpui_kit::white())
        .child(SharedString::from(initials.to_string()))
}

/// The sidebar for a whole [`SidebarModel`] (not virtualized: the gallery's
/// fixed screens).
#[derive(IntoElement)]
pub struct Sidebar {
    model: SidebarModel,
    on_select: Option<ClickHandler>,
}

impl Sidebar {
    pub fn new(model: SidebarModel) -> Self {
        Self {
            model,
            on_select: None,
        }
    }
    pub fn on_select(mut self, handler: ClickHandler) -> Self {
        self.on_select = Some(handler);
        self
    }
}

impl RenderOnce for Sidebar {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let st = cx.strings().clone();
        let model = self.model;
        let state = |id: &SharedString| RowState {
            selected: model.selected.as_ref() == Some(id),
            hovered: model.hovered.as_ref() == Some(id),
            context: model.context_target.as_ref() == Some(id),
            ..Default::default()
        };
        let on_select = self.on_select.clone();
        let row = |chat: &ChatRow, indent: f32| -> AnyElement {
            chat_row(
                chat,
                state(&chat.id),
                indent,
                default_actions(chat, &st),
                None,
                &t,
            )
            .on_click(on_click_or_noop(on_select.clone()))
            .into_any_element()
        };

        let mut sections: Vec<AnyElement> = vec![];
        if !model.pinned.is_empty() {
            sections.push(
                section(
                    "pinned",
                    &st.pinned,
                    None,
                    model.pinned.iter().map(|c| row(c, 0.)).collect(),
                    &t,
                )
                .into_any_element(),
            );
        }
        if !model.folders.is_empty() {
            let mut rows = vec![];
            for folder in &model.folders {
                rows.push(gallery_folder_row(folder, &t).into_any_element());
                if folder.expanded {
                    for chat in &folder.chats {
                        rows.push(row(chat, 22.));
                    }
                }
            }
            sections.push(
                section(
                    "folders",
                    &st.folders,
                    Some(
                        IconButton::new("new-folder", IconName::Plus, st.new_folder.clone())
                            .size(20., 13.)
                            .into_any_element(),
                    ),
                    rows,
                    &t,
                )
                .into_any_element(),
            );
        }
        for group in &model.groups {
            sections.push(
                section(
                    &group.label.to_lowercase().replace(' ', "-"),
                    &group.label,
                    None,
                    group.chats.iter().map(|c| row(c, 0.)).collect(),
                    &t,
                )
                .into_any_element(),
            );
        }
        let body = div()
            .id("sidebar-scroll")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .px(px(10.))
            .pb(px(10.))
            .flex()
            .flex_col()
            .gap(px(6.))
            .children(sections);
        SidebarFrame::new(body, model.sync.clone(), model.account.clone())
    }
}

fn gallery_folder_row(folder: &FolderRow, t: &ConduitTheme) -> Stateful<Div> {
    folder_row(
        &FolderLine {
            id: folder.id.clone(),
            name: folder.name.clone(),
            count: Some(folder.chats.len()),
            count_label: SharedString::from(format!("{} chats", folder.chats.len())),
            expanded: folder.expanded,
            badge: None,
            emoji: None,
        },
        0.,
        RowState::default(),
        None,
        t,
    )
}

/// A one-line sync caption ("Syncing 214 chats…") the sidebar shows above
/// the footer.
pub fn sync_caption(sync: &SyncState, cx: &App) -> Div {
    let t = cx.conduit();
    let r = t.roles;
    let (ic, color, text): (IconName, Hsla, &SharedString) = match sync {
        SyncState::Synced { detail } => (IconName::RefreshCw, r.sidebar_text_subtle, detail),
        SyncState::Syncing { detail } => (IconName::RefreshCw, r.selected_icon, detail),
        SyncState::Offline { detail } => (IconName::CloudOff, r.warning, detail),
    };
    div()
        .flex()
        .items_center()
        .gap(px(6.))
        .text_size(px(t.metrics.caption))
        .text_color(r.sidebar_text_subtle)
        .child(icon(ic, 12., color))
        .child(text.clone())
}

#[cfg(test)]
mod tests {
    use super::title_suffix;

    #[test]
    fn a_trailing_count_is_kept_apart_from_the_title() {
        assert_eq!(
            title_suffix("Why tides lag the moon (2)"),
            Some(("Why tides lag the moon", " (2)"))
        );
        assert_eq!(title_suffix("Draft (12)"), Some(("Draft", " (12)")));
        // Not a count: words, no space, nothing before it, or no digits.
        assert_eq!(title_suffix("Notes (draft)"), None);
        assert_eq!(title_suffix("Version(2)"), None);
        assert_eq!(title_suffix(" (2)"), None);
        assert_eq!(title_suffix("Empty ()"), None);
        assert_eq!(title_suffix("Plain title"), None);
    }
}
