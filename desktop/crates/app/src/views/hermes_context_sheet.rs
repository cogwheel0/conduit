//! Context & Usage: a Hermes chat's context window, what fills it, its
//! token totals and the plan's allowances, with Compact Now, as the
//! phone's `HermesContextUsageSheet` shows them (`hermes.context.get`,
//! `hermes.context.compact`).
//!
//! * **Context Window:** a bar filled to how much of the window the chat
//!   takes, "18,400 of 131,072 tokens", the share, and what one request
//!   costs (Hermes' estimate, marked so).
//! * **What fills it:** the system prompt, tool definitions, subagent
//!   definitions, the conversation and whatever else Hermes counts, each
//!   with its tokens and its share of the window.
//! * **This chat so far:** input, output and reasoning tokens, the cache
//!   (read, written, hits), model calls, compactions and the cost.
//! * **Plan Usage:** the plan's allowances (today, this week, this month)
//!   and when each resets, a rate limit, how much the model draws on the
//!   plan, and the account's balance, when the connection reports them.
//! * **Compaction:** an optional focus and Compact Now; the outcome is said
//!   under it, and the report is read again.
//!
//! Opened from the chat's More menu, the Chat menu, and an error card's
//! Compact Chat.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::theme::with_alpha;
use conduit_components::views::kit::{
    Button, bare_input, field_frame, grouped_section, grouped_tones, heading,
};
use conduit_protocol::{
    HermesCompact, HermesCompactOutcome, HermesCompactResultDto, HermesContextRef,
    HermesContextReportDto, HermesPlanGaugeDto, methods,
};
use gpui_kit::component::input::InputState;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Context, FontWeight, Role, SharedString, Task, Window, div, px, relative,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::rpc::Rpc;
use crate::views::chat::hermes_blocks::reset_time;
use crate::views::forms;
use crate::views::sheet::{self, SheetBody};

const WIDTH: f32 = 520.;

/// Opens Context & Usage for Hermes chat `chat_id`.
pub fn open(chat_id: String, window: &mut Window, cx: &mut App) {
    let Some(rpc) = cx
        .try_global::<crate::AppState>()
        .map(|s| s.stores.connection.read(cx).rpc())
    else {
        return;
    };
    let _ = sheet::open(window, WIDTH, cx, move |window, cx| {
        ContextSheet::new(rpc, chat_id, window, cx)
    });
}

pub struct ContextSheet {
    rpc: Rpc,
    chat_id: String,
    pub report: Option<HermesContextReportDto>,
    pub failed: bool,
    focus: gpui_kit::Entity<InputState>,
    pub compacting: bool,
    /// What the last Compact Now came to: its words, and whether it failed.
    pub outcome: Option<(Vec<String>, bool)>,
    _load: Option<Task<()>>,
}

/// `n` with the locale's thousands separator.
pub fn grouped_number(n: i64, locale: &str) -> String {
    let separator = match locale {
        "de" | "es" | "it" | "nl" => ".",
        "fr" => "\u{202f}",
        "cs" | "sk" | "pl" | "ru" => "\u{a0}",
        _ => ",",
    };
    let digits = n.unsigned_abs().to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push_str(separator);
        }
        out.push(c);
    }
    if n < 0 { format!("-{out}") } else { out }
}

/// A cost in US dollars, as the phone writes it.
pub fn dollars(usd: f64) -> String {
    if usd > 0. && usd < 0.01 {
        "<$0.01".into()
    } else {
        format!("${usd:.2}")
    }
}

impl ContextSheet {
    fn new(rpc: Rpc, chat_id: String, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let hint = cx.l10n().hermes_context_compact_focus();
        let focus = forms::input(hint.clone(), false, window, cx);
        focus.update(cx, |i, cx| i.set_placeholder(hint, window, cx));
        let mut sheet = Self {
            rpc,
            chat_id,
            report: None,
            failed: false,
            focus,
            compacting: false,
            outcome: None,
            _load: None,
        };
        sheet.load(cx);
        sheet
    }

    fn load(&mut self, cx: &mut Context<Self>) {
        let call = self
            .rpc
            .call::<methods::HermesContextGet>(&HermesContextRef {
                chat_id: self.chat_id.clone(),
            });
        self._load = Some(cx.spawn(async move |this, cx| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                match result {
                    Ok(report) => {
                        s.report = Some(report);
                        s.failed = false;
                    }
                    Err(e) => {
                        log::warn!("hermes.context.get: {e}");
                        s.failed = s.report.is_none();
                    }
                }
                cx.notify();
            });
        }));
    }

    /// Compact Now, with what the focus field holds.
    pub fn compact(&mut self, cx: &mut Context<Self>) {
        if self.compacting {
            return;
        }
        let focus = forms::text(&self.focus, cx);
        let call = self
            .rpc
            .call::<methods::HermesContextCompact>(&HermesCompact {
                chat_id: self.chat_id.clone(),
                focus: (!focus.is_empty()).then_some(focus),
            });
        self.compacting = true;
        self.outcome = None;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.compacting = false;
                let l = cx.l10n().clone();
                s.outcome = Some(match result {
                    Ok(r) => outcome_words(&r, &l),
                    Err(_) => (vec![l.hermes_context_compact_failed()], true),
                });
                s.load(cx);
                cx.notify();
            });
        })
        .detach();
    }
}

/// What a compaction came to, in the phone's words.
pub fn outcome_words(result: &HermesCompactResultDto, l: &L10n) -> (Vec<String>, bool) {
    let locale = l.locale();
    match result.outcome {
        HermesCompactOutcome::Compacted => {
            let mut lines = vec![l.hermes_context_compacted()];
            if let (Some(before), Some(after)) = (result.before_tokens, result.after_tokens) {
                lines.push(l.hermes_context_compacted_tokens(
                    &grouped_number(before, locale),
                    &grouped_number(after, locale),
                ));
            }
            if let (Some(before), Some(after)) = (result.before_messages, result.after_messages) {
                lines.push(l.hermes_context_compacted_messages(before, after));
            }
            (lines, false)
        }
        HermesCompactOutcome::Unchanged => (vec![l.hermes_context_compact_unchanged()], false),
        HermesCompactOutcome::Refused => (vec![l.hermes_context_compact_refused()], false),
        HermesCompactOutcome::Aborted => (vec![l.hermes_context_compact_aborted()], true),
        HermesCompactOutcome::Pending => (vec![l.hermes_context_compact_pending()], false),
        HermesCompactOutcome::Busy => (vec![l.hermes_context_compact_busy()], true),
        _ => (vec![l.hermes_context_compact_failed()], true),
    }
}

/// A gauge's name: today, this week, this month, top-tier models, or
/// Hermes' own words.
fn gauge_name(gauge: &HermesPlanGaugeDto, l: &L10n) -> String {
    match gauge.id.as_str() {
        "day" => l.hermes_context_gauge_day(),
        "week" => l.hermes_context_gauge_week(),
        "month" => l.hermes_context_gauge_month(),
        "top_tier" => l.hermes_context_gauge_top_tier(),
        _ => gauge.title.clone().unwrap_or_else(|| gauge.id.clone()),
    }
}

/// A category's name, in the phone's words for the ones it knows.
fn category_name(id: &str, label: &str, l: &L10n) -> String {
    match id {
        "system_prompt" => l.hermes_context_system_prompt(),
        "tool_definitions" => l.hermes_context_tool_definitions(),
        "subagent_definitions" => l.hermes_context_subagent_definitions(),
        "conversation" => l.hermes_context_conversation(),
        _ if !label.is_empty() => label.to_string(),
        _ => id.to_string(),
    }
}

/// A thin bar filled to `fraction`.
fn bar(fraction: f32, t: &conduit_components::ConduitTheme) -> gpui_kit::Div {
    let r = t.roles;
    div()
        .w_full()
        .h(px(6.))
        .rounded_full()
        .bg(with_alpha(r.text, if t.dark { 0.14 } else { 0.08 }))
        .child(
            div()
                .h_full()
                .w(gpui_kit::relative(fraction.clamp(0., 1.)))
                .rounded_full()
                .bg(r.text),
        )
}

/// A row: a label and its value, with an optional bar under them.
fn row(
    label: String,
    value: String,
    fill: Option<f32>,
    t: &conduit_components::ConduitTheme,
) -> AnyElement {
    let r = t.roles;
    let m = t.metrics;
    div()
        .id(gpui_kit::ElementId::Name(
            format!("hermes-context-{label}").into(),
        ))
        .role(Role::ListItem)
        .aria_label(SharedString::from(format!("{label}: {value}")))
        .px(px(12.))
        .py(px(8.))
        .flex()
        .flex_col()
        .gap(px(5.))
        .child(
            div()
                .flex()
                .items_center()
                .gap(px(8.))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_size(px(m.control))
                        .text_color(r.text)
                        .child(SharedString::from(label)),
                )
                .child(
                    div()
                        .flex_none()
                        .text_size(px(m.control))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(value)),
                ),
        )
        .when_some(fill, |d, f| d.child(bar(f, t)))
        .into_any_element()
}

impl SheetBody for ContextSheet {
    fn cancel(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        sheet::dismiss(cx);
    }

    fn label(&self, cx: &App) -> SharedString {
        cx.l10n().hermes_context_usage().into()
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l10n = cx.l10n().clone();
        Some(
            forms::form_buttons(vec![
                Button::new("hermes-context-done", l10n.desktop_done())
                    .primary()
                    .on_click(Rc::new(|_, _, cx| sheet::dismiss(cx)))
                    .into_any_element(),
            ])
            .into_any_element(),
        )
    }
}

impl Render for ContextSheet {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let (r, m) = (t.roles, t.metrics);
        let l = cx.l10n().clone();
        let locale = l.locale();
        let n = |v: i64| grouped_number(v, locale);
        let mut sections: Vec<AnyElement> = vec![];
        match &self.report {
            None => sections.push(
                div()
                    .py(px(12.))
                    .text_size(px(m.control))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(if self.failed {
                        l.hermes_context_load_failed()
                    } else {
                        l.desktop_loading()
                    }))
                    .into_any_element(),
            ),
            Some(report) => {
                let max = report.context_max.filter(|m| *m > 0);
                // The window.
                let window_rows: Vec<AnyElement> = match (report.context_used, max) {
                    (Some(used), Some(max)) => {
                        let fraction = used as f32 / max as f32;
                        let percent = (fraction * 100.).round() as i64;
                        let mut value = l.hermes_context_percent_full(percent);
                        if report.context_estimated {
                            value = format!("{value} \u{b7} {}", l.hermes_context_estimated_note());
                        }
                        let mut rows = vec![row(
                            l.hermes_context_used(&n(used), &n(max)),
                            value,
                            Some(fraction),
                            &t,
                        )];
                        if let Some(total) = report.estimated_total {
                            rows.push(row(
                                l.hermes_context_request_estimate(&n(total)),
                                String::new(),
                                None,
                                &t,
                            ));
                        }
                        rows
                    }
                    _ => vec![row(l.hermes_context_no_window(), String::new(), None, &t)],
                };
                let title = match &report.model {
                    Some(model) => format!("{} \u{b7} {model}", l.hermes_context_window()),
                    None => l.hermes_context_window(),
                };
                sections.push(
                    grouped_section(Some(title.into()), window_rows, None, cx).into_any_element(),
                );
                // What fills it.
                if !report.categories.is_empty() {
                    let rows = report
                        .categories
                        .iter()
                        .map(|c| {
                            row(
                                category_name(&c.id, &c.label, &l),
                                n(c.tokens),
                                max.map(|max| c.tokens as f32 / max as f32),
                                &t,
                            )
                        })
                        .collect();
                    sections.push(
                        grouped_section(Some(l.hermes_context_breakdown().into()), rows, None, cx)
                            .into_any_element(),
                    );
                }
                // This chat so far.
                let totals = &report.totals;
                let mut rows: Vec<AnyElement> = vec![];
                for (label, value) in [
                    (l.hermes_context_input(), totals.input),
                    (l.hermes_context_output(), totals.output),
                    (l.hermes_context_reasoning(), totals.reasoning),
                    (l.hermes_context_cache_read(), totals.cache_read),
                    (l.hermes_context_cache_write(), totals.cache_write),
                ] {
                    if let Some(v) = value {
                        rows.push(row(label, n(v), None, &t));
                    }
                }
                if let Some(hits) = totals.cache_hit_percent {
                    rows.push(row(
                        l.hermes_context_cache_hits(),
                        format!("{hits}%"),
                        Some(hits as f32 / 100.),
                        &t,
                    ));
                }
                for (label, value) in [
                    (l.hermes_context_calls(), totals.calls),
                    (l.hermes_context_compactions(), totals.compressions),
                ] {
                    if let Some(v) = value {
                        rows.push(row(label, n(v), None, &t));
                    }
                }
                if let Some(cost) = totals.cost_usd {
                    rows.push(row(
                        if totals.cost_estimated {
                            l.hermes_context_cost_estimated()
                        } else {
                            l.hermes_context_cost()
                        },
                        dollars(cost),
                        None,
                        &t,
                    ));
                }
                if !rows.is_empty() {
                    sections.push(
                        grouped_section(Some(l.hermes_context_totals().into()), rows, None, cx)
                            .into_any_element(),
                    );
                }
                // Plan usage.
                let mut rows: Vec<AnyElement> = vec![];
                let gauges = report
                    .plan_gauges
                    .iter()
                    .chain(report.provider_plan.iter().flat_map(|p| p.gauges.iter()));
                for gauge in gauges {
                    let percent = (gauge.used_fraction * 100.).round() as i64;
                    let mut value = l.hermes_context_used_percent(percent);
                    if let Some(ms) = gauge.resets_at_ms {
                        value = format!(
                            "{value} \u{b7} {}",
                            l.hermes_context_resets(&reset_time(ms, &l))
                        );
                    }
                    rows.push(row(
                        gauge_name(gauge, &l),
                        value,
                        Some(gauge.used_fraction as f32),
                        &t,
                    ));
                }
                if let Some(plan) = &report.provider_plan {
                    if plan.rate_limited {
                        let text = match plan.rate_limited_until_ms {
                            Some(ms) => l.hermes_context_rate_limited_until(&reset_time(ms, &l)),
                            None => l.hermes_context_rate_limited(),
                        };
                        rows.push(row(text, String::new(), None, &t));
                    }
                    if let Some(level) = &plan.usage_level {
                        let word = match level.as_str() {
                            "free" => l.hermes_context_level_free(),
                            "low" => l.hermes_context_level_low(),
                            "medium" => l.hermes_context_level_medium(),
                            "top_tier" => l.hermes_context_level_top_tier(),
                            other => other.to_string(),
                        };
                        rows.push(row(
                            l.hermes_context_usage_level(&word),
                            String::new(),
                            None,
                            &t,
                        ));
                    }
                }
                if let Some(bars) = &report.usage_bars {
                    for (name, bar_dto) in [
                        (bars.plan_name.clone(), bars.plan.as_ref()),
                        (Some(l.hermes_context_top_up()), bars.topup.as_ref()),
                    ] {
                        let Some(b) = bar_dto else { continue };
                        let value = match (&b.remaining, &b.total) {
                            (Some(rem), Some(total)) => l.hermes_context_left_of(rem, total),
                            _ => b.spent.clone().unwrap_or_default(),
                        };
                        rows.push(row(
                            name.unwrap_or_else(|| l.hermes_context_plan()),
                            value,
                            Some(b.fill as f32),
                            &t,
                        ));
                    }
                    if let Some(renews) = &bars.renews {
                        rows.push(row(
                            l.hermes_context_renews(renews),
                            String::new(),
                            None,
                            &t,
                        ));
                    }
                }
                for line in &report.credits_lines {
                    rows.push(row(line.clone(), String::new(), None, &t));
                }
                if !rows.is_empty() {
                    sections.push(
                        grouped_section(Some(l.hermes_context_plan().into()), rows, None, cx)
                            .into_any_element(),
                    );
                }
                // Compaction.
                if report.can_compact {
                    let view = cx.entity().downgrade();
                    let busy = self.compacting || report.compacting;
                    let outcome = self.outcome.clone();
                    sections.push(
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(8.))
                            .child(
                                div()
                                    .px(px(12.))
                                    .text_size(px(m.small))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(l.hermes_context_compact_section())),
                            )
                            .child(
                                div()
                                    .px(px(12.))
                                    .text_size(px(m.small))
                                    .line_height(relative(1.4))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(l.hermes_context_compact_hint())),
                            )
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap(px(8.))
                                    .child(
                                        field_frame(false, m.control_height + 2., cx)
                                            .flex_1()
                                            .child(div().flex_1().child(bare_input(
                                                &self.focus,
                                                l.hermes_context_compact_focus(),
                                                m.control,
                                            ))),
                                    )
                                    .child(
                                        Button::new(
                                            "hermes-compact-now",
                                            l.hermes_context_compact_now(),
                                        )
                                        .disabled(busy)
                                        .on_click(Rc::new(
                                            move |_, _, cx| {
                                                let _ = view.update(cx, |v, cx| v.compact(cx));
                                            },
                                        )),
                                    ),
                            )
                            .when(report.compacting && !self.compacting, |d| {
                                d.child(
                                    div()
                                        .px(px(12.))
                                        .text_size(px(m.small))
                                        .text_color(r.text_subtle)
                                        .child(SharedString::from(
                                            l.hermes_context_compact_pending(),
                                        )),
                                )
                            })
                            .when_some(outcome, |d, (lines, error)| {
                                d.child(
                                    div()
                                        .id("hermes-compact-outcome")
                                        .role(Role::Status)
                                        .aria_label(SharedString::from(lines.join(". ")))
                                        .px(px(12.))
                                        .flex()
                                        .flex_col()
                                        .gap(px(2.))
                                        .text_size(px(m.small))
                                        .text_color(if error { r.danger } else { r.text_subtle })
                                        .children(
                                            lines
                                                .into_iter()
                                                .map(|line| div().child(SharedString::from(line))),
                                        ),
                                )
                            })
                            .into_any_element(),
                    );
                }
            }
        }
        let (page, _) = grouped_tones(&t);
        let _ = page;
        div()
            .id("hermes-context-sheet")
            .flex()
            .flex_col()
            .gap(px(16.))
            .child(heading(
                "hermes-context-title",
                l.hermes_context_usage(),
                1,
                m.control + 2.,
                FontWeight::BOLD,
                r.text,
            ))
            .children(sections)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_group_as_the_locale_writes_them() {
        assert_eq!(grouped_number(131072, "en"), "131,072");
        assert_eq!(grouped_number(131072, "de"), "131.072");
        assert_eq!(grouped_number(999, "fr"), "999");
        assert_eq!(grouped_number(1_000_000, "ru"), "1\u{a0}000\u{a0}000");
    }

    #[test]
    fn a_cost_reads_in_dollars() {
        assert_eq!(dollars(0.42), "$0.42");
        assert_eq!(dollars(0.001), "<$0.01");
        assert_eq!(dollars(0.), "$0.00");
    }

    #[test]
    fn a_compaction_says_what_it_did() {
        let l = L10n::new("en");
        let (lines, error) = outcome_words(
            &HermesCompactResultDto {
                outcome: HermesCompactOutcome::Compacted,
                before_tokens: Some(18400),
                after_tokens: Some(6100),
                before_messages: Some(24),
                after_messages: Some(6),
            },
            &l,
        );
        assert!(!error);
        assert_eq!(lines[0], "Chat compacted.");
        assert!(lines[1].contains("18,400"));
        let (lines, error) = outcome_words(
            &HermesCompactResultDto {
                outcome: HermesCompactOutcome::Busy,
                before_tokens: None,
                after_tokens: None,
                before_messages: None,
                after_messages: None,
            },
            &l,
        );
        assert!(error);
        assert_eq!(lines.len(), 1);
    }
}
