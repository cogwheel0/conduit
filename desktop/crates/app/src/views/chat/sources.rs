//! What an answer cites, as the phone shows it:
//!
//! * **Inline citations** read as the source's site, or its own title with
//!   Settings › Chat › Show Citation Titles, shortened as the phone does
//!   (the daemon sends both, [`ChatSourceDto::inline_label`] and
//!   [`ChatSourceDto::inline_title`]); several sources read as the first
//!   with "+2". Settings › Chat › Citation Background puts them on a
//!   filled badge. [`inline_label`] decides.
//! * **The preview** of a citation (hovered, or clicked): its title, its
//!   site, a short excerpt, its address and Open ([`preview`], the phone's
//!   `citationPreview`).
//! * **The Sources sheet** from the sources pill under the answer: every
//!   source with its number, title, address (or kind) and excerpt; a
//!   source with an address opens in the browser.

use std::cell::Cell;
use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{UI_FONT, with_alpha};
use conduit_components::views::focus::{ControlExt as _, Ring};
use conduit_components::views::kit::{Button, grouped_tones};
use conduit_protocol::ChatSourceDto;
use gpui_kit::prelude::*;
use gpui_kit::{
    App, Bounds, Context, ElementId, FocusHandle, Focusable, FontWeight, Pixels, Role,
    SharedString, Window, div, px, relative,
};

use crate::actions::CloseWindow;
use crate::l10n::ActiveL10n as _;

/// The longest excerpt a preview shows, in characters (the phone's).
const PREVIEW_EXCERPT: usize = 240;

/// What an inline citation of `numbers` (1-based) reads, from the answer's
/// `sources`: the first source's site (or title, with `show_titles`), then
/// "+N" for the others. `None` when a number names no source, or the
/// daemon sent no label (the pill then shows the numbers).
pub fn inline_label(
    sources: &[ChatSourceDto],
    numbers: &[usize],
    show_titles: bool,
) -> Option<(String, Option<usize>)> {
    let first = *numbers.first()?;
    let source = sources.get(first.checked_sub(1)?)?;
    let label = if show_titles {
        source.inline_title.clone().or(source.inline_label.clone())
    } else {
        source.inline_label.clone()
    }?;
    let label = label.trim().to_string();
    if label.is_empty() {
        return None;
    }
    // The other sources it names, each once (`[1, 1]` is one source).
    let mut others: Vec<usize> = numbers
        .iter()
        .copied()
        .filter(|n| *n != first && *n >= 1 && *n <= sources.len())
        .collect();
    others.sort_unstable();
    others.dedup();
    let more = others.len();
    Some((label, (more > 0).then_some(more)))
}

/// A source's site: its address's host, without `www.`.
pub fn host(source: &ChatSourceDto) -> Option<String> {
    let url = url::Url::parse(source.url.as_deref()?).ok()?;
    let host = url.host_str()?.trim_start_matches("www.").to_string();
    (!host.is_empty()).then_some(host)
}

/// A citation's preview, as the phone's `citationPreview` words it: the
/// source's name (its site when the name is an address), its site when
/// that differs, and an excerpt of at most 240 characters ending on a word
/// when one ends close to the limit.
pub fn preview(source: &ChatSourceDto) -> (String, Option<String>, Option<String>) {
    let host = host(source);
    let label = source.label.trim().to_string();
    let label_is_link = label.starts_with("http://") || label.starts_with("https://");
    let title = match (&host, label_is_link || label.is_empty()) {
        (Some(h), true) => h.clone(),
        _ => label,
    };
    let site = host.filter(|h| *h != title);
    let excerpt = source
        .snippet
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(short_excerpt);
    (title, site, excerpt)
}

fn short_excerpt(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    if chars.len() <= PREVIEW_EXCERPT {
        return text.to_string();
    }
    let cut: String = chars[..PREVIEW_EXCERPT].iter().collect();
    let end = match cut.rfind(' ') {
        Some(space) if space as f32 > cut.len() as f32 * 0.6 => space,
        _ => cut.len(),
    };
    format!("{}…", cut[..end].trim_end())
}

/// Opens the answer's sources as a sheet on `window`, through the main
/// window's sheet host ([`crate::views::sheet`]): none while another sheet
/// is down, and quitting ends it first.
pub fn open_sheet(sources: Vec<ChatSourceDto>, window: &mut Window, cx: &mut App) {
    if sources.is_empty() || crate::views::sheet::refuse_another(cx) {
        return;
    }
    let opened = conduit_components::window::open_window_clear_root(
        crate::views::add_account::window_options(),
        cx,
        move |window, cx| cx.new(|cx| SourcesSheet::new(sources, window, cx)),
    );
    let (handle, view) = match opened {
        Ok(opened) => opened,
        Err(e) => {
            log::error!("could not open the sources: {e}");
            return;
        }
    };
    crate::views::sheet::adopt(handle, view.into_any(), cx);
    crate::views::sheet::begin(window, handle, cx);
}

pub struct SourcesSheet {
    sources: Vec<ChatSourceDto>,
    focus: FocusHandle,
    requested: Rc<Cell<Option<f32>>>,
}

impl SourcesSheet {
    pub fn new(sources: Vec<ChatSourceDto>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        Self {
            sources,
            focus,
            requested: Rc::new(Cell::new(None)),
        }
    }

    pub fn sources(&self) -> &[ChatSourceDto] {
        &self.sources
    }

    pub fn done(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let handle = window.window_handle();
        cx.defer(move |cx| crate::views::settings::end_sheet_window(handle, cx));
    }
}

impl Focusable for SourcesSheet {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for SourcesSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let l10n = cx.l10n().clone();
        let (page, _) = grouped_tones(&t);
        let requested = self.requested.clone();
        // The sheet fits its rows, up to the window it hangs from.
        let probe = gpui_kit::canvas(
            |bounds: Bounds<Pixels>, _, _| f32::from(bounds.size.height),
            move |_, height, window, cx| {
                let before = requested.get();
                if crate::views::add_account::needs_fit(before, height) {
                    requested.set(Some(height));
                    #[cfg(target_os = "macos")]
                    if let Some(ns) = crate::shell::macos::ns_window(window) {
                        let animate = before.is_some() && !cx.reduce_motion();
                        cx.foreground_executor()
                            .spawn(async move {
                                crate::shell::macos::fit_sheet(
                                    &ns,
                                    f64::from(height),
                                    crate::views::add_account::PARENT_MARGIN,
                                    animate,
                                )
                            })
                            .detach();
                    }
                    #[cfg(not(target_os = "macos"))]
                    let _ = (window, cx);
                }
            },
        )
        .absolute()
        .top_0()
        .left_0()
        .size_full();
        let total = self.sources.len();
        let title = l10n.desktop_sources_count(total as i64);
        let rows = self.sources.iter().enumerate().map(|(i, s)| {
            let (name, _, excerpt) = preview(s);
            let url = s.url.clone();
            let second = url.clone().or_else(|| s.r#type.clone());
            div()
                .id(ElementId::NamedInteger("source".into(), i as u64))
                .role(if url.is_some() {
                    Role::Link
                } else {
                    Role::ListItem
                })
                .aria_label(SharedString::from(
                    l10n.desktop_source_label((i + 1) as i64, &name),
                ))
                .aria_position_in_set(i + 1)
                .aria_size_of_set(total)
                .p(px(12.))
                .flex()
                .items_start()
                .gap(px(10.))
                .rounded(px(10.))
                .border_1()
                .border_color(with_alpha(r.text, 0.10))
                .bg(with_alpha(r.text, if t.dark { 0.05 } else { 0.025 }))
                .when(url.is_some(), |d| {
                    d.cursor_pointer().hover(|s| s.bg(r.hover))
                })
                .child(
                    div()
                        .flex_none()
                        .min_w(px(20.))
                        .h(px(20.))
                        .px(px(5.))
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded_full()
                        .bg(with_alpha(r.text, 0.08))
                        .text_size(px(m.caption))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text_subtle)
                        .child(SharedString::from((i + 1).to_string())),
                )
                .child(div().pt(px(2.)).child(icon(
                    if url.is_some() {
                        IconName::Globe
                    } else {
                        IconName::FileText
                    },
                    14.,
                    r.text_subtle,
                )))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(px(m.control))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(r.text)
                                .child(SharedString::from(name)),
                        )
                        .when_some(second, |d, line| {
                            d.child(
                                div()
                                    .truncate()
                                    .text_size(px(m.small))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(line)),
                            )
                        })
                        .when_some(excerpt, |d, e| {
                            d.child(
                                div()
                                    .pt(px(4.))
                                    .text_size(px(m.small))
                                    .line_height(relative(1.4))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(e)),
                            )
                        }),
                )
                .when(url.is_some(), |d| {
                    d.child(icon(IconName::ArrowUpRight, 12., r.text_faint))
                })
                .on_click(move |_, _, cx| {
                    if let Some(u) = &url {
                        super::markdown::open_web_link(u, cx);
                    }
                })
        });
        // A source with an address is a link: a Tab stop (with Full
        // Keyboard Access) that Return or Space opens, as a click does.
        let links: Vec<bool> = self.sources.iter().map(|s| s.url.is_some()).collect();
        let rows: Vec<_> = rows
            .zip(links)
            .map(|(row, link)| {
                if link {
                    row.keyboard_control(Ring::Inset(10.), window, cx)
                } else {
                    row
                }
            })
            .collect();
        let view = cx.entity().downgrade();
        div()
            .id("sources-sheet")
            .role(Role::Dialog)
            .aria_label(SharedString::from(title.clone()))
            .key_context("ConduitSheet")
            .track_focus(&self.focus)
            .size_full()
            .overflow_y_scroll()
            .font_family(UI_FONT)
            .bg(page)
            .text_color(r.text)
            .on_key_down(cx.listener(|this, e: &gpui_kit::KeyDownEvent, window, cx| {
                let k = &e.keystroke;
                let plain = !(k.modifiers.platform || k.modifiers.alt || k.modifiers.control);
                // Return on a source opens it (its own key); elsewhere, as
                // Esc, it closes the sheet.
                let on_sheet = this.focus.is_focused(window);
                if plain && (k.key == "escape" || (k.key == "enter" && on_sheet)) {
                    this.done(window, cx);
                    cx.stop_propagation();
                }
            }))
            .on_action(cx.listener(|this, _: &CloseWindow, window, cx| this.done(window, cx)))
            .child(
                div()
                    .relative()
                    .w_full()
                    .p(px(24.))
                    .flex()
                    .flex_col()
                    .gap(px(12.))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(8.))
                            .child(icon(IconName::Link, 16., r.text))
                            .child(
                                div()
                                    .id("sources-sheet-title")
                                    .role(Role::Heading)
                                    .text_size(px(m.control + 5.))
                                    .font_weight(FontWeight::BOLD)
                                    .child(SharedString::from(title)),
                            ),
                    )
                    .child(
                        div()
                            .id("sources-sheet-list")
                            .role(Role::List)
                            .flex()
                            .flex_col()
                            .gap(px(8.))
                            .children(rows),
                    )
                    .child(
                        div().flex().justify_end().child(
                            Button::new("sources-sheet-done", l10n.release_notes_done_button())
                                .primary()
                                .on_click(Rc::new(move |_, window, cx| {
                                    let _ = view.update(cx, |v, cx| v.done(window, cx));
                                })),
                        ),
                    )
                    .child(probe),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn source(label: &str, url: Option<&str>) -> ChatSourceDto {
        ChatSourceDto {
            label: label.into(),
            url: url.map(Into::into),
            snippet: None,
            inline_label: Some("example.com".into()),
            inline_title: Some("Spring tides".into()),
            r#type: None,
        }
    }

    #[test]
    fn citations_read_as_their_site_or_title_with_a_count() {
        let sources = vec![
            source("Spring tides", Some("https://www.example.com/a")),
            source("Neap tides", Some("https://example.org/b")),
        ];
        assert_eq!(
            inline_label(&sources, &[1], false),
            Some(("example.com".into(), None))
        );
        assert_eq!(
            inline_label(&sources, &[1, 2], true),
            Some(("Spring tides".into(), Some(1)))
        );
        // A number past the sources is not counted; none named, no label.
        assert_eq!(
            inline_label(&sources, &[1, 9], false),
            Some(("example.com".into(), None))
        );
        assert_eq!(inline_label(&sources, &[3], false), None);
        // A number named twice is one source.
        assert_eq!(
            inline_label(&sources, &[1, 1], false).map(|l| l.1),
            Some(None)
        );
        assert_eq!(
            inline_label(&sources, &[1, 2, 2], false).map(|l| l.1),
            Some(Some(1))
        );
    }

    #[test]
    fn a_preview_names_the_source_its_site_and_an_excerpt() {
        let mut s = source(
            "https://www.example.com/a",
            Some("https://www.example.com/a"),
        );
        s.snippet = Some(format!("{} end", "word ".repeat(60)));
        let (title, site, excerpt) = preview(&s);
        assert_eq!(title, "example.com");
        assert_eq!(site, None);
        let excerpt = excerpt.unwrap();
        assert!(excerpt.ends_with('…') && excerpt.chars().count() <= 241);
        let named = source("Spring tides", Some("https://example.com/a"));
        assert_eq!(
            preview(&named),
            ("Spring tides".into(), Some("example.com".into()), None)
        );
    }

    #[gpui_kit::test]
    fn a_source_opens_from_the_keyboard(cx: &mut gpui_kit::TestAppContext) {
        use conduit_components::views::focus::KeyboardAccess;

        cx.update(|cx| {
            crate::views::test_globals(cx);
            cx.set_global(KeyboardAccess { all_controls: true });
        });
        let sources = vec![
            source("Spring tides", Some("https://www.example.com/a")),
            source("Field notes", None),
        ];
        let (_sheet, vcx) =
            cx.add_window_view(move |window, cx| SourcesSheet::new(sources, window, cx));
        vcx.run_until_parked();
        // Tab reaches the link (the one source with an address), and Space
        // or Return opens it as a click does.
        vcx.update(|window, cx| window.focus_next(cx));
        vcx.run_until_parked();
        vcx.simulate_keystrokes("space");
        vcx.simulate_event(gpui_kit::KeyUpEvent {
            keystroke: gpui_kit::Keystroke::parse("space").unwrap(),
        });
        vcx.run_until_parked();
        assert_eq!(
            vcx.opened_url().as_deref(),
            Some("https://www.example.com/a"),
            "the keyboard never reached the source"
        );
    }
}
