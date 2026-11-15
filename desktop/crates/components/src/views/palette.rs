//! The ⌘K palette: recent chats and commands with an empty query; chat
//! search hits with highlighted snippets otherwise (150 ms debounce, limit 8,
//! every word must match).

use std::ops::Range;
use std::rc::Rc;

use gpui_kit::component::input::{Input, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    App, Context, ElementId, Entity, FontWeight, HighlightStyle, Role, SharedString, StyledText,
    Window, div, px,
};

use crate::assets::{IconName, icon};
use crate::strings::ActiveStrings as _;
use crate::theme::{ActiveConduitTheme, ConduitTheme, with_alpha};
use crate::views::kit::{ESC_KEYCAP, keycap, overlay_shadow, shortcut};

/// One palette row.
#[derive(Clone, Debug, PartialEq)]
pub struct PaletteItem {
    pub id: SharedString,
    pub icon: IconName,
    pub title: SharedString,
    /// Byte ranges of `title` that matched the query.
    pub title_matches: Vec<Range<usize>>,
    /// A snippet of the matching message, for search hits.
    pub snippet: Option<SharedString>,
    pub snippet_matches: Vec<Range<usize>>,
    /// Time for chats, a shortcut for commands.
    pub trailing: Option<SharedString>,
}

impl PaletteItem {
    pub fn new(
        id: impl Into<SharedString>,
        icon: IconName,
        title: impl Into<SharedString>,
    ) -> Self {
        Self {
            id: id.into(),
            icon,
            title: title.into(),
            title_matches: vec![],
            snippet: None,
            snippet_matches: vec![],
            trailing: None,
        }
    }
    pub fn trailing(mut self, t: impl Into<SharedString>) -> Self {
        self.trailing = Some(t.into());
        self
    }
    /// Marks every case-insensitive occurrence of `query`'s words.
    pub fn matching(mut self, query: &str) -> Self {
        self.title_matches = find_words(&self.title, query);
        if let Some(s) = &self.snippet {
            self.snippet_matches = find_words(s, query);
        }
        self
    }
    pub fn snippet(mut self, s: impl Into<SharedString>) -> Self {
        self.snippet = Some(s.into());
        self
    }
}

/// Byte ranges of each query word in `text` (ASCII case-insensitive).
/// How a search marks what matched, in the palette and the sidebar alike:
/// semibold in `ink` on a quiet wash of the selection tone.
pub fn match_highlight(t: &ConduitTheme, ink: gpui_kit::Hsla) -> HighlightStyle {
    HighlightStyle {
        font_weight: Some(FontWeight::SEMIBOLD),
        color: Some(ink),
        background_color: Some(with_alpha(
            t.roles.selected_icon,
            if t.dark { 0.28 } else { 0.14 },
        )),
        ..Default::default()
    }
}

pub fn find_words(text: &str, query: &str) -> Vec<Range<usize>> {
    let lower = text.to_ascii_lowercase();
    let mut out = vec![];
    for word in query.split_whitespace() {
        let w = word.to_ascii_lowercase();
        let mut from = 0;
        while let Some(i) = lower[from..].find(&w) {
            out.push(from + i..from + i + w.len());
            from += i + w.len();
        }
    }
    out.sort_by_key(|r| r.start);
    // Words can overlap ("a ab", or one typed twice); styled text needs
    // disjoint runs, or its runs outgrow the text and a cut can land inside
    // a character.
    let mut merged: Vec<Range<usize>> = Vec::with_capacity(out.len());
    for r in out {
        match merged.last_mut() {
            Some(last) if r.start <= last.end => last.end = last.end.max(r.end),
            _ => merged.push(r),
        }
    }
    merged
}

/// A labelled group of rows.
#[derive(Clone, Debug, PartialEq)]
pub struct PaletteSection {
    pub label: SharedString,
    pub items: Vec<PaletteItem>,
}

/// A row callback: the index into the flattened rows.
pub type RowHandler = Rc<dyn Fn(usize, &mut Window, &mut App) + 'static>;

/// The palette overlay. Owns its query input.
pub struct CommandPalette {
    pub query: Entity<InputState>,
    pub sections: Vec<PaletteSection>,
    /// Index into the flattened rows.
    pub selected: usize,
    /// A row was clicked.
    pub on_choose: Option<RowHandler>,
    /// The pointer moved onto a row.
    pub on_hover: Option<RowHandler>,
    /// The footer's count ("4 results"); English when unset.
    pub results_label: Option<SharedString>,
    /// Shown in place of rows when there are none.
    pub empty: Option<SharedString>,
    /// Shows the "open in background" hint (the gallery's design).
    pub background_hint: bool,
}

impl CommandPalette {
    pub fn new(
        query: &str,
        sections: Vec<PaletteSection>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let query_text = query.to_string();
        let input = cx.new(|cx| {
            let mut s =
                InputState::new(window, cx).placeholder(cx.strings().palette_placeholder.clone());
            s.set_value(query_text, window, cx);
            s
        });
        Self {
            query: input,
            sections,
            selected: 0,
            on_choose: None,
            on_hover: None,
            results_label: None,
            empty: None,
            background_hint: true,
        }
    }
}

impl Render for CommandPalette {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let st = cx.strings().clone();
        let r = t.roles;
        let m = t.metrics;
        let mark = match_highlight(&t, r.text);
        let total: usize = self.sections.iter().map(|s| s.items.len()).sum();
        let mut index = 0usize;
        let mut list = div()
            .id("palette-results")
            .role(Role::ListBox)
            .aria_label(st.palette_results.clone())
            .max_h(px(440.))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .px(px(6.))
            .pb(px(6.));
        if total == 0
            && let Some(empty) = &self.empty
        {
            list = list.child(
                div()
                    .px(px(10.))
                    .py(px(14.))
                    .text_size(px(m.control))
                    .text_color(r.text_subtle)
                    .child(empty.clone()),
            );
        }
        for section in &self.sections {
            list = list.child(
                div()
                    .px(px(10.))
                    .pt(px(10.))
                    .pb(px(4.))
                    .text_size(px(m.caption))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(r.text_subtle)
                    .child(section.label.clone()),
            );
            for item in &section.items {
                let selected = index == self.selected;
                let row_h = if item.snippet.is_some() {
                    m.row_height + 26.
                } else {
                    m.row_height + 8.
                };
                let title = StyledText::new(item.title.clone()).with_highlights(
                    item.title_matches
                        .iter()
                        .map(|rg| (rg.clone(), mark))
                        .collect::<Vec<_>>(),
                );
                let label = match &item.snippet {
                    Some(s) => format!("{}, {s}", item.title),
                    None => item.title.to_string(),
                };
                let (choose, hover) = (self.on_choose.clone(), self.on_hover.clone());
                let row = index;
                list = list.child(
                    div()
                        .id(ElementId::Name(format!("palette-{}", item.id).into()))
                        .role(Role::ListBoxOption)
                        .aria_label(SharedString::from(label))
                        .aria_selected(selected)
                        .aria_position_in_set(index + 1)
                        .aria_size_of_set(total)
                        .when_some(item.trailing.clone(), |d, tr| d.aria_description(tr))
                        .h(px(row_h))
                        .px(px(10.))
                        .flex()
                        .items_center()
                        .gap(px(10.))
                        .rounded(px(7.))
                        .when(selected, |d| d.bg(r.selected))
                        .cursor_pointer()
                        .child(icon(
                            item.icon,
                            16.,
                            if selected {
                                r.selected_icon
                            } else {
                                r.text_subtle
                            },
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
                                        .truncate()
                                        .text_size(px(m.control + 1.))
                                        .text_color(r.text)
                                        .child(title),
                                )
                                .when_some(item.snippet.clone(), |d, s| {
                                    d.child(
                                        div()
                                            .truncate()
                                            .text_size(px(m.small))
                                            .text_color(r.text_subtle)
                                            .child(
                                                StyledText::new(s).with_highlights(
                                                    item.snippet_matches
                                                        .iter()
                                                        .map(|rg| (rg.clone(), mark))
                                                        .collect::<Vec<_>>(),
                                                ),
                                            ),
                                    )
                                }),
                        )
                        .when_some(item.trailing.clone(), |d, tr| {
                            d.child(shortcut(tr, r.text_subtle, m.small))
                        })
                        .on_hover(move |on, window, cx| {
                            if *on && let Some(h) = &hover {
                                h(row, window, cx)
                            }
                        })
                        .on_click(move |_, window, cx| {
                            if let Some(h) = &choose {
                                h(row, window, cx)
                            }
                        }),
                );
                index += 1;
            }
        }
        let hint = |keys: &'static str, label: SharedString| {
            div()
                .flex()
                .items_center()
                .gap(px(5.))
                .child(keycap(keys, &t))
                .child(label)
        };
        div()
            .id("command-palette")
            .role(Role::Dialog)
            .aria_label(st.palette.clone())
            .w(px(640.))
            .flex()
            .flex_col()
            .rounded(t.overlay_radius())
            .border_1()
            .border_color(r.border_strong)
            .bg(r.overlay)
            .shadow(overlay_shadow(&t))
            .overflow_hidden()
            .child(
                div()
                    .h(px(52.))
                    .px(px(16.))
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .border_b_1()
                    .border_color(r.border)
                    .child(icon(IconName::Search, 18., r.text_subtle))
                    .child(
                        div().flex_1().text_size(px(m.body + 3.)).child(
                            Input::new(&self.query)
                                .appearance(false)
                                .bordered(false)
                                .px_0()
                                .h(px(32.))
                                .text_size(px(m.body + 3.))
                                .aria_label(st.palette_placeholder.clone())
                                .accessibility_id("palette-query"),
                        ),
                    ),
            )
            .child(list)
            .child(
                div()
                    .h(px(36.))
                    .px(px(16.))
                    .flex()
                    .items_center()
                    .gap(px(16.))
                    .border_t_1()
                    .border_color(r.border)
                    .text_size(px(m.caption))
                    .text_color(r.text_subtle)
                    .child(hint("\u{2191}\u{2193}", st.palette_navigate.clone()))
                    .child(hint("\u{21a9}", st.palette_open.clone()))
                    .when(self.background_hint, |d| {
                        d.child(hint(
                            "\u{2318}\u{21a9}",
                            st.palette_open_in_background.clone(),
                        ))
                    })
                    // Esc closes it, taught with the others (in words: the
                    // ⎋ glyph read as refresh in the field's corner).
                    .child(hint(ESC_KEYCAP, st.close.clone()))
                    .child(div().flex_1())
                    .child(
                        self.results_label
                            .clone()
                            .unwrap_or_else(|| format!("{total} results").into()),
                    ),
            )
    }
}

/// Centres `panel` near the top of the window over a scrim.
pub fn palette_overlay(panel: impl IntoElement, cx: &App) -> gpui_kit::Div {
    let r = cx.conduit().roles;
    div()
        .absolute()
        .inset_0()
        .bg(r.scrim)
        .flex()
        .flex_col()
        .items_center()
        .pt(px(96.))
        .child(panel)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_every_word_case_insensitively() {
        assert_eq!(
            find_words("Sourdough starter", "sour START"),
            vec![0..4, 10..15]
        );
        assert_eq!(find_words("abcabc", "bc"), vec![1..3, 4..6]);
        assert!(find_words("abc", "").is_empty());
    }

    #[test]
    fn overlapping_words_give_one_range() {
        assert_eq!(find_words("abé", "a ab"), vec![0..2]);
        assert_eq!(find_words("ab ab", "ab ab"), vec![0..2, 3..5]);
        assert_eq!(find_words("abcd", "ab bc"), vec![0..3]);
        assert_eq!(find_words("abcd", "ab cd"), vec![0..4]);
    }
}
