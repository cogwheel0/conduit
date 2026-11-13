//! A Hermes agent's work, docked above the composer as the phone docks it:
//!
//! * **The chip** ([`work_chip`]): "2 agents · 1 process" while subagents or
//!   background processes run; it opens the background work sheet.
//! * **The plan** ([`plan_card`]): the agent's task list, "Plan  1 of 3 done";
//!   folded it shows the step under way, unfolded every item with its state.
//!   It folds on its own once nothing is left to do, unless the user chose
//!   otherwise for that chat.

use std::rc::Rc;

use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{ConduitTheme, with_alpha};
use conduit_components::views::focus::{ControlExt as _, Ring};
use conduit_protocol::HermesPlanDto;
use gpui_kit::prelude::*;
use gpui_kit::{AnyElement, App, ElementId, FontWeight, Role, SharedString, Window, div, px};

use crate::l10n::L10n;

/// Opens something: the sheet, the plan.
pub type Action = Rc<dyn Fn(&mut Window, &mut App)>;

/// "2 agents · 1 process", leaving out a kind with none running.
pub fn work_summary(agents: usize, processes: usize, l10n: &L10n) -> String {
    let mut parts = vec![];
    if agents > 0 {
        parts.push(l10n.hermes_background_agent_count(agents as i64));
    }
    if processes > 0 {
        parts.push(l10n.hermes_background_process_count(processes as i64));
    }
    parts.join(" \u{b7} ")
}

/// The chip, or nothing while nothing runs.
pub fn work_chip(
    agents: usize,
    processes: usize,
    on_open: Action,
    l10n: &L10n,
    t: &ConduitTheme,
    window: &mut Window,
    cx: &mut App,
) -> Option<AnyElement> {
    if agents == 0 && processes == 0 {
        return None;
    }
    let r = t.roles;
    let m = t.metrics;
    let label = work_summary(agents, processes, l10n);
    let chip = div()
        .id("hermes-work-chip")
        .role(Role::Button)
        .aria_label(SharedString::from(label.clone()))
        .h(px(26.))
        .px(px(10.))
        .flex()
        .items_center()
        .gap(px(6.))
        .rounded_full()
        .border_1()
        .border_color(r.border)
        .bg(conduit_components::views::kit::on_raised_fill(t))
        .cursor_pointer()
        .hover(|s| s.bg(r.hover))
        .child(icon(
            if agents > 0 {
                IconName::Network
            } else {
                IconName::SquareTerminal
            },
            13.,
            r.text_subtle,
        ))
        .child(
            div()
                .text_size(px(m.small))
                .font_weight(FontWeight::MEDIUM)
                .text_color(r.text)
                .child(SharedString::from(label)),
        )
        .child(icon(IconName::ChevronUp, 12., r.text_faint))
        .on_click(move |_, window, cx| on_open(window, cx))
        .tip(l10n.desktop_hermes_show_background_work(), None)
        .keyboard_control(Ring::Outset(3.), window, cx);
    Some(div().mb(px(8.)).flex().child(chip).into_any_element())
}

/// A plan item's state, as the phone words it, and its glyph.
pub fn item_state(status: &str, l10n: &L10n) -> (String, IconName) {
    crate::views::chat::tasks::task_state(status, l10n)
}

/// The plan card. `folded` shows one line with the step under way.
pub fn plan_card(
    plan: &HermesPlanDto,
    folded: bool,
    on_toggle: Action,
    l10n: &L10n,
    t: &ConduitTheme,
    window: &mut Window,
    cx: &mut App,
) -> Option<AnyElement> {
    if plan.items.is_empty() {
        return None;
    }
    let r = t.roles;
    let m = t.metrics;
    let total = plan.items.len();
    let progress = l10n.hermes_plan_progress(plan.done, total as i64);
    let current = plan
        .current_id
        .as_ref()
        .and_then(|id| plan.items.iter().find(|i| &i.id == id))
        .map(|i| i.content.clone());
    let header = div()
        .id("hermes-plan-header")
        .role(Role::Button)
        .aria_label(SharedString::from(format!(
            "{}, {progress}",
            if folded {
                l10n.hermes_plan_show()
            } else {
                l10n.hermes_plan_hide()
            }
        )))
        .aria_expanded(!folded)
        .min_h(px(m.row_height + 4.))
        .px(px(4.))
        .flex()
        .items_center()
        .gap(px(8.))
        .rounded(px(6.))
        .cursor_pointer()
        .hover(|s| s.bg(r.hover))
        .child(icon(IconName::ListChecks, 14., r.text_subtle))
        .child(
            div()
                .flex_none()
                .text_size(px(m.small))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(r.text)
                .child(SharedString::from(l10n.hermes_plan_title())),
        )
        .child(
            div()
                .flex_none()
                .text_size(px(m.small))
                .text_color(r.text_subtle)
                .child(SharedString::from(progress)),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_size(px(m.small))
                .text_color(r.text_subtle)
                .when_some(current.filter(|_| folded), |d, c| {
                    d.child(SharedString::from(c))
                }),
        )
        .child(icon(
            if folded {
                IconName::ChevronUp
            } else {
                IconName::ChevronDown
            },
            12.,
            r.text_faint,
        ))
        .on_click(move |_, window, cx| on_toggle(window, cx))
        .tip(
            if folded {
                l10n.hermes_plan_show()
            } else {
                l10n.hermes_plan_hide()
            },
            None,
        )
        .keyboard_control(Ring::Inset(6.), window, cx);
    let rows: Vec<AnyElement> = if folded {
        vec![]
    } else {
        plan.items
            .iter()
            .enumerate()
            .map(|(i, item)| {
                let (state, glyph) = item_state(&item.status, l10n);
                let finished = item.status == "completed" || item.status == "cancelled";
                let under_way = item.status == "in_progress";
                div()
                    .id(ElementId::NamedInteger("hermes-plan-item".into(), i as u64))
                    .role(Role::ListItem)
                    .aria_label(SharedString::from(format!("{}, {state}", item.content)))
                    .aria_position_in_set(i + 1)
                    .aria_size_of_set(total)
                    .py(px(3.))
                    .pl(px(4. + 14. * item.depth.clamp(0, 3) as f32))
                    .pr(px(4.))
                    .flex()
                    .items_start()
                    .gap(px(8.))
                    .child(div().pt(px(2.)).child(icon(
                        glyph,
                        14.,
                        if under_way { r.text } else { r.text_subtle },
                    )))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(px(m.small))
                            .when(under_way, |d| d.font_weight(FontWeight::SEMIBOLD))
                            .text_color(if finished { r.text_subtle } else { r.text })
                            .when(finished, |d| d.line_through())
                            .child(SharedString::from(item.content.clone())),
                    )
                    .into_any_element()
            })
            .collect()
    };
    Some(
        div()
            .id("hermes-plan")
            .role(Role::Group)
            .aria_label(SharedString::from(l10n.hermes_plan_title()))
            .w_full()
            .mb(px(8.))
            .px(px(8.))
            .py(px(4.))
            .flex()
            .flex_col()
            .rounded(t.card_radius())
            .border_1()
            .border_color(r.border)
            .bg(conduit_components::views::kit::on_raised_fill(t))
            .child(header)
            .when(!folded, |d| {
                d.child(div().h(px(1.)).mx(px(4.)).bg(with_alpha(r.text, 0.06)))
                    .child(
                        div()
                            .id("hermes-plan-items")
                            .role(Role::List)
                            .max_h(px(200.))
                            .overflow_y_scroll()
                            .py(px(2.))
                            .children(rows),
                    )
            })
            .into_any_element(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_chip_names_what_runs() {
        let l10n = L10n::new("en");
        assert_eq!(work_summary(2, 1, &l10n), "2 agents \u{b7} 1 process");
        assert_eq!(work_summary(0, 3, &l10n), "3 processes");
        assert_eq!(work_summary(1, 0, &l10n), "1 agent");
    }
}
