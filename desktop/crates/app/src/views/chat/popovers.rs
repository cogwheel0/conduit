//! What the transcript's small popovers say: an answer's usage (Info) and a
//! message's versions. The transcript hangs them from the button that asked
//! ([`super::transcript`]); this draws their content.
//!
//! The usage figures are mobile's `UsageStatsModal`'s, in its order: how
//! full the context window was, generation, prompt processing, reasoning
//! and total tokens, then the durations. The numbers are the core's
//! (`UsageSummary`, through the daemon); this only words them.

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::ConduitTheme;
use conduit_protocol::ChatUsageDto;
use gpui_kit::prelude::*;
use gpui_kit::{AnyElement, App, ElementId, FontWeight, Role, SharedString, div, px, relative};

use crate::l10n::{ActiveL10n as _, L10n};

/// One line of the usage popover: what, how much, and a detail under it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UsageLine {
    pub label: String,
    pub value: String,
    pub detail: Option<String>,
}

/// A token count as the context window line names it: `512`, `8K`, `1.5M`.
/// A length of whole 1,024-token blocks is named by their number, as models
/// advertise it (32,768 is 32K; 128,000 stays 128K).
pub fn compact_count(n: i64, window_length: bool) -> String {
    let n = if window_length && n % 1000 != 0 && n % 1024 == 0 {
        n / 1024 * 1000
    } else {
        n
    };
    let trim = |v: f64| {
        let s = format!("{v:.1}");
        s.strip_suffix(".0").map(str::to_string).unwrap_or(s)
    };
    match n {
        n if n >= 1_000_000 => format!("{}M", trim(n as f64 / 1_000_000.)),
        n if n >= 10_000 => format!("{}K", (n as f64 / 1000.).round() as i64),
        n if n >= 1000 => format!("{}K", trim(n as f64 / 1000.)),
        n => n.to_string(),
    }
}

/// `v` with `digits` decimals, halves rounded away from zero, as Dart's
/// `toStringAsFixed` (the phone's figures) rounds them.
fn fixed(v: f64, digits: i32) -> String {
    let scale = 10f64.powi(digits);
    format!("{:.*}", digits as usize, (v * scale).round() / scale)
}

/// The usage figures `u` reports, worded, in the phone's order.
pub fn usage_lines(u: &ChatUsageDto, l10n: &L10n) -> Vec<UsageLine> {
    let mut lines = vec![];
    let mut add = |label: String, value: String, detail: Option<String>| {
        lines.push(UsageLine {
            label,
            value,
            detail,
        })
    };
    let count = |n: Option<i64>| n.map(|n| l10n.usage_token_count(n));
    if let (Some(tokens), Some(length)) = (u.context_tokens, u.context_length)
        && length > 0
    {
        let percent = format!("{}%", (tokens as f64 / length as f64 * 100.).round() as i64);
        add(
            l10n.usage_context_window(),
            l10n.usage_context_window_value(
                &percent,
                &compact_count(tokens, false),
                &compact_count(length, true),
            ),
            None,
        );
    }
    match (u.generation_per_second, u.generation_tokens) {
        (Some(rate), tokens) => add(
            l10n.usage_token_generation(),
            l10n.usage_tokens_per_second(&fixed(rate, 1)),
            count(tokens),
        ),
        (None, Some(tokens)) => add(
            l10n.usage_token_generation(),
            l10n.usage_token_count(tokens),
            None,
        ),
        _ => {}
    }
    match (u.prompt_per_second, u.prompt_tokens) {
        (Some(rate), tokens) => add(
            l10n.usage_prompt_eval(),
            l10n.usage_tokens_per_second(&fixed(rate, 1)),
            count(tokens),
        ),
        (None, Some(tokens)) => add(
            l10n.usage_prompt_eval(),
            l10n.usage_token_count(tokens),
            None,
        ),
        _ => {}
    }
    if let Some(tokens) = u.reasoning_tokens {
        add(
            l10n.usage_reasoning_tokens(),
            l10n.usage_token_count(tokens),
            None,
        );
    }
    if let Some(tokens) = u.total_tokens {
        add(
            l10n.usage_total_tokens(),
            l10n.usage_token_count(tokens),
            None,
        );
    }
    if let Some(s) = u.total_seconds {
        add(
            l10n.usage_total_duration(),
            l10n.usage_seconds_format(&fixed(s, 2)),
            None,
        );
    }
    if let Some(s) = u.queue_seconds {
        add(
            l10n.usage_queue_time(),
            l10n.usage_seconds_format(&fixed(s, 3)),
            None,
        );
    }
    if let Some(s) = u.load_seconds {
        add(
            l10n.usage_load_duration(),
            l10n.usage_seconds_format(&fixed(s, 2)),
            None,
        );
    }
    lines
}

/// Whether `u` has anything to show (Info is offered only then).
pub fn has_usage(u: Option<&ChatUsageDto>) -> bool {
    u.is_some_and(|u| {
        u.generation_per_second.is_some()
            || u.generation_tokens.is_some()
            || u.prompt_per_second.is_some()
            || u.prompt_tokens.is_some()
            || u.reasoning_tokens.is_some()
            || u.total_tokens.is_some()
            || u.total_seconds.is_some()
            || u.queue_seconds.is_some()
            || u.load_seconds.is_some()
            // The context window alone is a row too.
            || (u.context_tokens.is_some() && u.context_length.is_some_and(|l| l > 0))
    })
}

/// The popover's heading.
fn heading(id: &str, text: String, t: &ConduitTheme) -> AnyElement {
    div()
        .id(ElementId::Name(format!("{id}-heading").into()))
        .role(Role::Heading)
        .aria_label(SharedString::from(text.clone()))
        .px(px(8.))
        .pt(px(4.))
        .pb(px(4.))
        .text_size(px(t.metrics.small))
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(t.roles.text_subtle)
        .child(SharedString::from(text))
        .into_any_element()
}

/// The usage popover's content.
pub fn usage_card(key: &str, u: &ChatUsageDto, cx: &App) -> AnyElement {
    let t = cx.conduit().clone();
    let l10n = cx.l10n().clone();
    let (r, m) = (t.roles, t.metrics);
    let lines = usage_lines(u, &l10n);
    div()
        .flex()
        .flex_col()
        .gap(px(2.))
        .child(heading(
            &format!("usage-{key}"),
            l10n.usage_info_title(),
            &t,
        ))
        .child(
            div()
                .id(ElementId::Name(format!("usage-{key}-list").into()))
                .role(Role::List)
                .aria_label(SharedString::from(l10n.usage_info_title()))
                .flex()
                .flex_col()
                .children(lines.into_iter().enumerate().map(|(i, line)| {
                    let spoken = match &line.detail {
                        Some(d) => format!("{}: {}, {d}", line.label, line.value),
                        None => format!("{}: {}", line.label, line.value),
                    };
                    div()
                        .id(ElementId::Name(format!("usage-{key}-{i}").into()))
                        .role(Role::ListItem)
                        .aria_label(SharedString::from(spoken))
                        .px(px(8.))
                        .py(px(4.))
                        .flex()
                        .items_start()
                        .justify_between()
                        .gap(px(16.))
                        .child(
                            div()
                                .text_size(px(m.control))
                                .text_color(r.text_subtle)
                                .child(SharedString::from(line.label)),
                        )
                        .child(
                            div()
                                .flex()
                                .flex_col()
                                .items_end()
                                .child(
                                    div()
                                        .text_size(px(m.control))
                                        .font_weight(FontWeight::MEDIUM)
                                        .text_color(r.text)
                                        .child(SharedString::from(line.value)),
                                )
                                .when_some(line.detail, |d, detail| {
                                    d.child(
                                        div()
                                            .text_size(px(m.caption))
                                            .text_color(r.text_subtle)
                                            .child(SharedString::from(detail)),
                                    )
                                }),
                        )
                })),
        )
        .when(u.incomplete, |d| {
            d.child(
                div()
                    .px(px(8.))
                    .pt(px(4.))
                    .pb(px(2.))
                    .text_size(px(m.caption))
                    .line_height(relative(1.35))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(l10n.usage_incomplete())),
            )
        })
        .into_any_element()
}

/// What choosing a version does (its id).
pub type PickVersion = std::rc::Rc<dyn Fn(String, &mut gpui_kit::Window, &mut App)>;
/// What Show All Branches… does.
pub type ShowBranches = std::rc::Rc<dyn Fn(&mut gpui_kit::Window, &mut App)>;

/// One version in the version list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VersionEntry {
    pub id: String,
    pub title: String,
    /// The start of its text, on one line.
    pub preview: String,
    /// The version the chat is on.
    pub current: bool,
}

/// `text` on one line, at most `max` characters, without reasoning and tool
/// markup.
pub fn one_line(text: &str, max: usize) -> String {
    let mut out = String::new();
    let mut rest = text;
    // Reasoning and tool details are not what a version says.
    while let Some(start) = rest.find("<details") {
        out.push_str(&rest[..start]);
        match rest[start..].find("</details>") {
            Some(end) => rest = &rest[start + end + "</details>".len()..],
            None => {
                rest = "";
                break;
            }
        }
    }
    out.push_str(rest);
    let flat = out.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() <= max {
        flat
    } else {
        let cut: String = flat.chars().take(max.saturating_sub(1)).collect();
        format!("{}…", cut.trim_end())
    }
}

/// The version list's entries for `siblings` (in the server's order), the
/// one `shown` marked current.
pub fn version_entries(
    siblings: &[String],
    shown: &str,
    text_of: impl Fn(&str) -> Option<String>,
    l10n: &L10n,
) -> Vec<VersionEntry> {
    siblings
        .iter()
        .enumerate()
        .map(|(n, id)| VersionEntry {
            id: id.clone(),
            title: l10n.chat_branch_version_title(n as i64 + 1),
            preview: text_of(id).map(|t| one_line(&t, 120)).unwrap_or_default(),
            current: id == shown,
        })
        .collect()
}

/// The version list's content: a heading, what choosing does, the versions
/// (a click continues from one), and Show All Branches….
pub fn versions_card(
    key: &str,
    entries: Vec<VersionEntry>,
    on_pick: PickVersion,
    on_branches: Option<ShowBranches>,
    cx: &App,
) -> AnyElement {
    let t = cx.conduit().clone();
    let l10n = cx.l10n().clone();
    let (r, m) = (t.roles, t.metrics);
    div()
        .flex()
        .flex_col()
        .gap(px(2.))
        .child(heading(
            &format!("versions-{key}"),
            l10n.chat_branch_sheet_title(),
            &t,
        ))
        .child(
            div()
                .px(px(8.))
                .pb(px(4.))
                .text_size(px(m.caption))
                .line_height(relative(1.35))
                .text_color(r.text_subtle)
                .child(SharedString::from(l10n.chat_branch_sheet_description())),
        )
        .child(
            div()
                .id(ElementId::Name(format!("versions-{key}-list").into()))
                .role(Role::List)
                .aria_label(SharedString::from(l10n.chat_branch_sheet_title()))
                .flex()
                .flex_col()
                .gap(px(1.))
                .children(entries.into_iter().map(|e| {
                    let pick = on_pick.clone();
                    let id = e.id.clone();
                    let spoken = if e.current {
                        format!(
                            "{}. {}. {}",
                            e.title,
                            l10n.chat_branch_version_current(),
                            e.preview
                        )
                    } else {
                        format!("{}. {}", e.title, e.preview)
                    };
                    div()
                        .id(ElementId::Name(format!("version-{key}-{}", e.id).into()))
                        .role(Role::Button)
                        .aria_label(SharedString::from(spoken))
                        .aria_selected(e.current)
                        .px(px(8.))
                        .py(px(5.))
                        .flex()
                        .items_start()
                        .gap(px(8.))
                        .rounded(px(7.))
                        .cursor_pointer()
                        .hover(|s| s.bg(r.overlay_hover))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .flex()
                                .flex_col()
                                .gap(px(1.))
                                .child(
                                    div()
                                        .flex()
                                        .items_center()
                                        .gap(px(6.))
                                        .child(
                                            div()
                                                .text_size(px(m.control))
                                                .font_weight(FontWeight::MEDIUM)
                                                .text_color(r.text)
                                                .child(SharedString::from(e.title.clone())),
                                        )
                                        .when(e.current, |d| {
                                            d.child(
                                                div()
                                                    .text_size(px(m.caption))
                                                    .text_color(r.text_subtle)
                                                    .child(SharedString::from(
                                                        l10n.chat_branch_version_current(),
                                                    )),
                                            )
                                        }),
                                )
                                .when(!e.preview.is_empty(), |d| {
                                    d.child(
                                        div()
                                            .text_size(px(m.small))
                                            .line_height(relative(1.3))
                                            .text_color(r.text_subtle)
                                            .line_clamp(2)
                                            .child(SharedString::from(e.preview.clone())),
                                    )
                                }),
                        )
                        .child(
                            div()
                                .w(px(14.))
                                .pt(px(2.))
                                .flex_none()
                                .when(e.current, |d| d.child(icon(IconName::Check, 13., r.text))),
                        )
                        .on_click(move |_, window, cx| pick(id.clone(), window, cx))
                })),
        )
        .when_some(on_branches, |d, branches| {
            d.child(div().mx(px(8.)).my(px(4.)).h(px(1.)).bg(r.border))
                .child(
                    div()
                        .id(ElementId::Name(format!("versions-{key}-branches").into()))
                        .role(Role::Button)
                        .aria_label(SharedString::from(l10n.desktop_show_branches()))
                        .px(px(8.))
                        .py(px(5.))
                        .flex()
                        .items_center()
                        .gap(px(6.))
                        .rounded(px(7.))
                        .cursor_pointer()
                        .hover(|s| s.bg(r.overlay_hover))
                        .text_size(px(m.control))
                        .text_color(r.text)
                        .child(icon(IconName::ListTree, 13., r.text_subtle))
                        .child(SharedString::from(l10n.desktop_show_branches()))
                        .on_click(move |_, window, cx| branches(window, cx)),
                )
        })
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn usage() -> ChatUsageDto {
        ChatUsageDto {
            generation_per_second: Some(42.25),
            generation_tokens: Some(120),
            prompt_per_second: None,
            prompt_tokens: Some(30),
            reasoning_tokens: None,
            total_tokens: Some(150),
            total_seconds: Some(3.14259),
            queue_seconds: None,
            load_seconds: Some(0.5),
            context_length: Some(32768),
            context_tokens: Some(150),
            incomplete: false,
        }
    }

    #[test]
    fn usage_reads_in_the_phones_order() {
        let l10n = L10n::new("en");
        let lines = usage_lines(&usage(), &l10n);
        let got: Vec<_> = lines
            .iter()
            .map(|l| (l.label.as_str(), l.value.as_str(), l.detail.as_deref()))
            .collect();
        assert_eq!(
            got,
            vec![
                ("Context Window", "0% · 150 of 32K", None),
                ("Token Generation", "42.3 t/s", Some("120 tokens")),
                ("Prompt Processing", "30 tokens", None),
                ("Total Tokens", "150 tokens", None),
                ("Total Duration", "3.14s", None),
                ("Model Load Time", "0.50s", None),
            ]
        );
        assert!(has_usage(Some(&usage())));
        let empty = ChatUsageDto {
            generation_per_second: None,
            generation_tokens: None,
            prompt_per_second: None,
            prompt_tokens: None,
            reasoning_tokens: None,
            total_tokens: None,
            total_seconds: None,
            queue_seconds: None,
            load_seconds: None,
            context_length: Some(4096),
            context_tokens: None,
            incomplete: true,
        };
        assert!(!has_usage(Some(&empty)) && !has_usage(None));
        // Only the context window: Info shows it.
        let window_only = ChatUsageDto {
            context_tokens: Some(1024),
            ..empty
        };
        assert!(has_usage(Some(&window_only)));
    }

    #[test]
    fn counts_are_compact_and_windows_count_kibitokens() {
        assert_eq!(compact_count(512, false), "512");
        assert_eq!(compact_count(1500, false), "1.5K");
        assert_eq!(compact_count(8000, false), "8K");
        assert_eq!(compact_count(32768, true), "32K");
        assert_eq!(compact_count(131072, true), "128K");
        assert_eq!(compact_count(128000, true), "128K");
        assert_eq!(compact_count(1_500_000, false), "1.5M");
    }

    #[test]
    fn a_version_preview_is_one_line_without_reasoning() {
        let text = "<details type=\"reasoning\">thinking\nhard</details>\nTwo  coats\nof paint.";
        assert_eq!(one_line(text, 80), "Two coats of paint.");
        assert_eq!(one_line("abcdefghij", 5), "abcd…");
    }
}
