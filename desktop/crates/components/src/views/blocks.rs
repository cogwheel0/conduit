//! Non-text message blocks: reasoning, tool-call and code-interpreter
//! disclosures, status lines, citation chips and follow-up suggestions.

use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Div, ElementId, FontWeight, Role, SharedString, Stateful, div, px, relative,
};

use crate::assets::{IconName, icon};
use crate::strings::ActiveStrings as _;
use crate::theme::{ActiveConduitTheme, ConduitTheme, MONO_FONT, with_alpha};
use crate::views::markdown::CodeBlock;
use crate::views::model::{RunStatus, Source};

fn chevron(expanded: bool, t: &ConduitTheme) -> gpui_kit::Svg {
    icon(
        if expanded {
            IconName::ChevronDown
        } else {
            IconName::ChevronRight
        },
        11.,
        t.roles.text_subtle,
    )
}

/// An opened disclosure's body, under its line: indented behind a rule.
fn disclosure_body(t: &ConduitTheme) -> Div {
    div()
        .ml(px(2.))
        .pl(px(12.))
        .border_l_2()
        .border_color(t.roles.border)
}

/// "Thought for 8 seconds ›": a quiet disclosure, body in secondary text
/// behind a rule.
pub fn reasoning(
    id: &str,
    summary: &SharedString,
    body: &SharedString,
    streaming: bool,
    expanded: bool,
    cx: &App,
) -> Stateful<Div> {
    let t = cx.conduit().clone();
    let r = t.roles;
    let m = t.metrics;
    div()
        .id(ElementId::Name(format!("reasoning-{id}").into()))
        .flex()
        .flex_col()
        .gap(px(6.))
        .child(
            div()
                .id(ElementId::Name(format!("reasoning-toggle-{id}").into()))
                .role(Role::Button)
                .aria_label(summary.clone())
                .aria_expanded(expanded)
                .flex()
                .items_center()
                .gap(px(5.))
                .h(px(24.))
                .cursor_pointer()
                .when(streaming, |d| {
                    d.child(icon(IconName::LoaderCircle, 12., r.text_subtle))
                })
                .child(
                    div()
                        .text_size(px(m.body))
                        .text_color(r.text_subtle)
                        .child(summary.clone()),
                )
                .child(chevron(expanded, &t))
                .on_click(|_, _, _| {}),
        )
        .when(expanded, |d| {
            d.child(
                disclosure_body(&t)
                    .text_size(px(m.control))
                    .line_height(relative(1.55))
                    .text_color(r.text_subtle)
                    .child(body.clone()),
            )
        })
}

fn status_icon(status: RunStatus, t: &ConduitTheme) -> AnyElement {
    let r = t.roles;
    match status {
        RunStatus::Running => icon(IconName::LoaderCircle, 12., r.text_subtle).into_any_element(),
        RunStatus::Done => icon(IconName::Check, 12., r.text_subtle).into_any_element(),
        RunStatus::Failed => icon(IconName::CircleAlert, 13., r.danger).into_any_element(),
    }
}

fn status_word(status: RunStatus) -> &'static str {
    match status {
        RunStatus::Running => "running",
        RunStatus::Done => "done",
        RunStatus::Failed => "failed",
    }
}

/// The phone's quiet disclosure line ("Used web_search ›"): a spinner
/// while running, red when failed; the body shows behind a rule when open.
#[allow(clippy::too_many_arguments)]
fn disclosure_card(
    id: String,
    _leading: IconName,
    title: &SharedString,
    detail: &SharedString,
    status: RunStatus,
    expanded: bool,
    body: Option<AnyElement>,
    t: &ConduitTheme,
) -> Stateful<Div> {
    let r = t.roles;
    let m = t.metrics;
    let label = format!("{title}, {detail}, {}", status_word(status));
    let tone = if status == RunStatus::Failed {
        r.danger
    } else {
        r.text_subtle
    };
    div()
        .id(ElementId::Name(id.clone().into()))
        .w_full()
        .flex()
        .flex_col()
        .gap(px(6.))
        .child(
            div()
                .id(ElementId::Name(format!("{id}-toggle").into()))
                .role(Role::Button)
                .aria_label(SharedString::from(label))
                .aria_expanded(expanded)
                .h(px(24.))
                .flex()
                .items_center()
                .gap(px(5.))
                .cursor_pointer()
                .when(status != RunStatus::Done, |d| {
                    d.child(status_icon(status, t))
                })
                .child(
                    div()
                        .flex_none()
                        .text_size(px(m.body))
                        .text_color(tone)
                        .child(title.clone()),
                )
                .when(!detail.is_empty(), |d| {
                    d.child(
                        div()
                            .min_w_0()
                            .truncate()
                            .text_size(px(m.body))
                            .text_color(r.text_subtle)
                            .child(detail.clone()),
                    )
                })
                .child(chevron(expanded, t))
                .on_click(|_, _, _| {}),
        )
        .when_some(body.filter(|_| expanded), |d, body| {
            d.child(disclosure_body(t).flex().flex_col().gap(px(8.)).child(body))
        })
}

fn mono_box(label: &str, content: &SharedString, t: &ConduitTheme) -> Div {
    let r = t.roles;
    div()
        .flex()
        .flex_col()
        .gap(px(4.))
        .child(
            div()
                .text_size(px(t.metrics.caption))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(r.text_subtle)
                .child(SharedString::from(label.to_string())),
        )
        .child(
            div()
                .px(px(10.))
                .py(px(8.))
                .rounded(px(6.))
                .bg(crate::theme::composite(r.raised, t.surfaces.panel))
                .border_1()
                .border_color(r.border)
                .font_family(MONO_FONT)
                .text_size(px(t.metrics.code - 0.5))
                .line_height(relative(1.5))
                .text_color(r.text)
                .child(content.clone()),
        )
}

/// A tool call: "Searched the web · “query” ✓ ›".
#[allow(clippy::too_many_arguments)]
pub fn tool_call(
    id: &str,
    title: &SharedString,
    detail: &SharedString,
    tool: &SharedString,
    arguments: Option<&SharedString>,
    result: Option<&SharedString>,
    status: RunStatus,
    expanded: bool,
    cx: &App,
) -> Stateful<Div> {
    let t = cx.conduit().clone();
    let st = cx.strings().clone();
    let body = div()
        .flex()
        .flex_col()
        .gap(px(8.))
        .when_some(arguments, |d, a| {
            d.child(mono_box(&format!("{tool} \u{b7} arguments"), a, &t))
        })
        .when_some(result, |d, res| d.child(mono_box(&st.tool_result, res, &t)))
        .into_any_element();
    disclosure_card(
        format!("tool-{id}"),
        if tool.contains("search") {
            IconName::Globe
        } else {
            IconName::Wrench
        },
        title,
        detail,
        status,
        expanded,
        Some(body),
        &t,
    )
}

/// A code-interpreter run: the code, then its output.
pub fn code_interpreter(
    id: &str,
    language: &SharedString,
    code: &SharedString,
    output: Option<&SharedString>,
    status: RunStatus,
    expanded: bool,
    cx: &App,
) -> Stateful<Div> {
    let t = cx.conduit().clone();
    let st = cx.strings().clone();
    let title: SharedString = format!("Ran {language}").into();
    let detail: SharedString = code.lines().next().unwrap_or_default().to_string().into();
    let body = div()
        .flex()
        .flex_col()
        .gap(px(8.))
        .child(CodeBlock::new(code.clone()).lang(Some(language.to_lowercase())))
        .when_some(output, |d, o| d.child(mono_box(&st.output, o, &t)))
        .into_any_element();
    disclosure_card(
        format!("code-run-{id}"),
        IconName::SquareTerminal,
        &title,
        &detail,
        status,
        expanded,
        Some(body),
        &t,
    )
}

/// A status line ("Searching the web…").
pub fn status_line(id: &str, text: &SharedString, done: bool, cx: &App) -> Stateful<Div> {
    let t = cx.conduit();
    let r = t.roles;
    div()
        .id(ElementId::Name(format!("status-{id}").into()))
        .role(Role::Status)
        .aria_label(text.clone())
        .flex()
        .items_center()
        .gap(px(6.))
        .h(px(22.))
        .text_size(px(t.metrics.control))
        .text_color(r.text_subtle)
        .child(icon(
            if done {
                IconName::Check
            } else {
                IconName::LoaderCircle
            },
            13.,
            r.text_faint,
        ))
        .child(text.clone())
}

/// Source chips under a reply.
pub fn citations(id: &str, sources: &[Source], cx: &App) -> Stateful<Div> {
    let t = cx.conduit().clone();
    let st = cx.strings().clone();
    let r = t.roles;
    let m = t.metrics;
    div()
        .id(ElementId::Name(format!("sources-{id}").into()))
        .role(Role::List)
        .aria_label(st.sources.clone())
        .flex()
        .flex_wrap()
        .gap(px(6.))
        .children(sources.iter().map(|s| {
            div()
                .id(ElementId::Name(format!("source-{id}-{}", s.n).into()))
                .role(Role::Link)
                .aria_label(format!("Source {}: {}, {}", s.n, s.title, s.host))
                .h(px(26.))
                .max_w(px(340.))
                .pl(px(4.))
                .pr(px(10.))
                .flex()
                .items_center()
                .gap(px(6.))
                .rounded_full()
                .border_1()
                .border_color(r.border)
                .bg(crate::views::kit::raised_fill(&t))
                .cursor_pointer()
                .hover(|st| st.bg(r.hover))
                .child(
                    div()
                        .size(px(18.))
                        .flex_none()
                        .rounded_full()
                        .bg(with_alpha(r.text, if t.dark { 0.14 } else { 0.07 }))
                        .flex()
                        .items_center()
                        .justify_center()
                        .text_size(px(10.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text_subtle)
                        .child(SharedString::from(s.n.to_string())),
                )
                .child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_size(px(m.small))
                        .text_color(r.text)
                        .child(s.title.clone()),
                )
                .child(
                    div()
                        .flex_none()
                        .text_size(px(m.small))
                        .text_color(r.text_subtle)
                        .child(s.host.clone()),
                )
                .on_click(|_, _, _| {})
        }))
}

/// Follow-up suggestions as quiet pills.
pub fn follow_ups(id: &str, items: &[SharedString], cx: &App) -> Stateful<Div> {
    let t = cx.conduit().clone();
    let r = t.roles;
    let m = t.metrics;
    let heading = crate::strings::ActiveStrings::strings(cx)
        .suggestions
        .clone();
    // The phone's suggestions: a heading, then an outlined row each.
    div()
        .id(ElementId::Name(format!("follow-ups-{id}").into()))
        .role(Role::List)
        .aria_label(heading.clone())
        .flex()
        .flex_col()
        .gap(px(6.))
        .child(
            div()
                .text_size(px(m.small))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(r.text_subtle)
                .child(heading),
        )
        .children(items.iter().enumerate().map(|(i, s)| {
            div()
                .id(ElementId::Name(format!("follow-up-{id}-{i}").into()))
                .role(Role::Button)
                .aria_label(s.clone())
                .w_full()
                .min_h(px(m.row_height + 6.))
                .px(px(12.))
                .py(px(6.))
                .flex()
                .items_center()
                .rounded(px(12.))
                .border_1()
                .border_color(r.border)
                .cursor_pointer()
                .hover(|st| st.bg(r.hover))
                .text_size(px(m.control))
                .text_color(r.text)
                .child(s.clone())
                .on_click(|_, _, _| {})
        }))
}
