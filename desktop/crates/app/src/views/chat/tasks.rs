//! Open WebUI's task checklist for the open chat (`ChatDetail.tasks`, kept
//! current by `turn.blocks`), docked above the composer as the phone's
//! `OpenWebUiTaskList` shows it: one line, "Tasks: 2 of 3 completed",
//! that opens to every task with its state.

use std::rc::Rc;

use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{ConduitTheme, with_alpha};
use conduit_protocol::ChatTaskDto;
use gpui_kit::prelude::*;
use gpui_kit::{AnyElement, App, ElementId, FontWeight, Role, SharedString, Window, div, px};

use crate::l10n::{ActiveL10n as _, L10n};

/// A task's state, as the phone words it, and its glyph.
pub fn task_state(status: &str, l10n: &L10n) -> (String, IconName) {
    match status {
        "completed" => (l10n.chat_task_completed(), IconName::CircleCheck),
        "cancelled" => (l10n.chat_task_cancelled(), IconName::CircleX),
        "in_progress" => (l10n.chat_task_in_progress(), IconName::Timer),
        _ => (l10n.chat_task_pending(), IconName::Circle),
    }
}

/// How many tasks are done, of all.
pub fn progress(tasks: &[ChatTaskDto]) -> (usize, usize) {
    (
        tasks.iter().filter(|t| t.status == "completed").count(),
        tasks.len(),
    )
}

/// Opens or closes the checklist.
pub type Toggle = Rc<dyn Fn(&mut Window, &mut App)>;

/// The checklist card, or nothing for a chat without one. `open` shows
/// every task; `on_toggle` opens or closes it.
pub fn task_list(
    tasks: &[ChatTaskDto],
    open: bool,
    on_toggle: Toggle,
    t: &ConduitTheme,
    cx: &mut App,
) -> Option<AnyElement> {
    if tasks.is_empty() {
        return None;
    }
    let l10n = cx.l10n().clone();
    let r = t.roles;
    let m = t.metrics;
    let (done, total) = progress(tasks);
    let summary = l10n.chat_task_progress(done as i64, total as i64);
    let header = div()
        .id("task-list-header")
        .role(Role::Button)
        .aria_label(SharedString::from(summary.clone()))
        .aria_expanded(open)
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
                .flex_1()
                .min_w_0()
                .truncate()
                .text_size(px(m.small))
                .font_weight(FontWeight::MEDIUM)
                .text_color(r.text)
                .child(SharedString::from(summary)),
        )
        .child(icon(
            if open {
                IconName::ChevronUp
            } else {
                IconName::ChevronDown
            },
            12.,
            r.text_faint,
        ))
        .on_click(move |_, window, cx| on_toggle(window, cx));
    let rows: Vec<AnyElement> = if open {
        tasks
            .iter()
            .enumerate()
            .map(|(i, task)| {
                let (state, glyph) = task_state(&task.status, &l10n);
                let finished = task.status == "completed" || task.status == "cancelled";
                div()
                    .id(ElementId::NamedInteger("task".into(), i as u64))
                    .role(Role::ListItem)
                    .aria_label(SharedString::from(format!("{}, {state}", task.content)))
                    .aria_position_in_set(i + 1)
                    .aria_size_of_set(tasks.len())
                    .py(px(4.))
                    .px(px(4.))
                    .flex()
                    .items_start()
                    .gap(px(8.))
                    .child(div().pt(px(2.)).child(icon(glyph, 14., r.text_subtle)))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(
                                div()
                                    .text_size(px(m.small))
                                    .text_color(if finished { r.text_subtle } else { r.text })
                                    .when(task.status == "cancelled", |d| d.line_through())
                                    .child(SharedString::from(task.content.clone())),
                            )
                            .child(
                                div()
                                    .text_size(px(m.caption))
                                    .text_color(r.text_faint)
                                    .child(SharedString::from(state)),
                            ),
                    )
                    .into_any_element()
            })
            .collect()
    } else {
        vec![]
    };
    Some(
        div()
            .id("task-list")
            .role(Role::Group)
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
            .when(open, |d| {
                d.child(div().h(px(1.)).mx(px(4.)).bg(with_alpha(r.text, 0.06)))
                    .child(
                        div()
                            .id("task-list-items")
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

    fn task(status: &str) -> ChatTaskDto {
        ChatTaskDto {
            id: String::new(),
            content: "Check the tides".into(),
            status: status.into(),
        }
    }

    #[test]
    fn progress_counts_completed_tasks_only() {
        let tasks = vec![task("completed"), task("cancelled"), task("in_progress")];
        assert_eq!(progress(&tasks), (1, 3));
    }

    #[test]
    fn states_read_as_the_phone_words_them() {
        let l10n = L10n::new("en");
        assert_eq!(task_state("in_progress", &l10n).0, "In progress");
        assert_eq!(task_state("whatever", &l10n).0, "Pending");
        assert_eq!(task_state("completed", &l10n).1, IconName::CircleCheck);
    }
}
