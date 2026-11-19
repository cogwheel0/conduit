//! What a Hermes agent asks, drawn inside the docked approvals card:
//!
//! * **A clarify form** ([`clarify_form`]): every question Hermes asked in
//!   one call (up to five), each with its choices (one, or several), an
//!   own-words field and Skip; one Send Response sends them all, as the
//!   phone's `HermesClarifyFormCard` does. A question answered on another
//!   device shows its answer, read-only.
//! * **A paid tool's cost** ([`cost_chips`]): what the call costs and what
//!   the chat has spent of its limit, with a warning when the call goes past
//!   it (the phone's `HermesApprovalCostChips`).
//!
//! The form's answers follow core's `HermesClarifyDraft`: a skipped question
//! answers nothing (null), a multi-select one its choices and own words as
//! a JSON array, any other its choice, else its own words.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::with_alpha;
use conduit_components::views::focus::{ControlExt as _, Ring, pressed_fill};
use conduit_components::views::kit::{badge, bare_input, field_frame, radio_dot};
use conduit_protocol::HermesClarifyAnswer;
use gpui_kit::component::input::InputState;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, ElementId, Entity, FontWeight, Role, SharedString, Toggled, Window, div, px,
    relative,
};

use crate::l10n::L10n;
use crate::stores::ui_requests::{ClarifyQuestion, HermesCost};
use crate::views::forms;

/// One question's answer so far: the choices picked (their values), and
/// whether it is skipped. Its own words live in its field.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ClarifyDraft {
    pub choices: Vec<String>,
    pub skipped: bool,
}

impl ClarifyDraft {
    /// What Hermes takes for `question`, with `typed` the own-words field:
    /// none when skipped or empty; a multi-select question's choices and
    /// words as a JSON array string; else the choice, or the words.
    pub fn answer(&self, question: &ClarifyQuestion, typed: &str) -> Option<String> {
        if self.skipped {
            return None;
        }
        let typed = typed.trim();
        if question.multi {
            let mut values = self.choices.clone();
            if !typed.is_empty() {
                values.push(typed.to_string());
            }
            return (!values.is_empty())
                .then(|| serde_json::to_string(&values).unwrap_or_default());
        }
        if let Some(choice) = self.choices.first() {
            return Some(choice.clone());
        }
        (!typed.is_empty()).then(|| typed.to_string())
    }

    /// Answered, or skipped on purpose.
    pub fn settles(&self, question: &ClarifyQuestion, typed: &str) -> bool {
        self.skipped || self.answer(question, typed).is_some()
    }

    /// `value` picked (or unpicked). Returns whether the own words should be
    /// cleared: one choice or one's own words, never both, on a
    /// single-choice question.
    pub fn pick(&mut self, question: &ClarifyQuestion, value: &str) -> bool {
        if question.multi {
            if let Some(i) = self.choices.iter().position(|c| c == value) {
                self.choices.remove(i);
            } else {
                self.choices.push(value.to_string());
            }
            return false;
        }
        if self.choices.first().map(String::as_str) == Some(value) {
            self.choices.clear();
        } else {
            self.choices = vec![value.to_string()];
        }
        true
    }

    /// Own words typed on a single-choice question replace its choice.
    pub fn typed(&mut self, question: &ClarifyQuestion, typed: &str) {
        if !question.multi && !typed.trim().is_empty() {
            self.choices.clear();
        }
    }
}

/// How many of `questions` are settled, and whether all the open ones are.
pub fn progress(
    questions: &[ClarifyQuestion],
    draft: impl Fn(&ClarifyQuestion) -> (ClarifyDraft, String),
) -> (usize, usize, bool) {
    let mut settled = 0;
    let mut open = 0;
    let mut ready = true;
    for q in questions {
        if q.locked {
            settled += 1;
            continue;
        }
        open += 1;
        let (d, typed) = draft(q);
        if d.settles(q, &typed) {
            settled += 1;
        } else {
            ready = false;
        }
    }
    (settled, questions.len(), ready && open > 0)
}

/// The answers a form sends: one per question still open (a skipped or
/// empty one as none); answered-elsewhere questions are left out so their
/// answer stands.
pub fn answers(
    questions: &[ClarifyQuestion],
    draft: impl Fn(&ClarifyQuestion) -> (ClarifyDraft, String),
) -> Vec<HermesClarifyAnswer> {
    questions
        .iter()
        .filter(|q| !q.locked)
        .map(|q| {
            let (d, typed) = draft(q);
            HermesClarifyAnswer {
                question_id: q.id.clone(),
                answer: d.answer(q, &typed),
            }
        })
        .collect()
}

/// Picks (or unpicks) a choice: question index, choice value.
pub type OnPick = Rc<dyn Fn(usize, String, &mut Window, &mut App)>;
/// Skips (or unskips) a question, by index.
pub type OnSkip = Rc<dyn Fn(usize, &mut Window, &mut App)>;
/// Turns a toggle on or off.
type Toggle = Rc<dyn Fn(&mut Window, &mut App)>;

/// One question of the form as drawn.
pub struct FormQuestion<'a> {
    pub question: &'a ClarifyQuestion,
    pub draft: ClarifyDraft,
    /// Its own-words field (none once answered elsewhere).
    pub input: Option<Entity<InputState>>,
}

/// Every question of a clarify form, scrolling past ~360 pt.
#[allow(clippy::too_many_arguments)]
pub fn clarify_form(
    id: &str,
    questions: Vec<FormQuestion<'_>>,
    enabled: bool,
    on_pick: OnPick,
    on_skip: OnSkip,
    l10n: &L10n,
    window: &mut Window,
    cx: &mut App,
) -> AnyElement {
    let t = cx.conduit().clone();
    let r = t.roles;
    let m = t.metrics;
    let count = questions.len();
    let blocks: Vec<AnyElement> = questions
        .into_iter()
        .enumerate()
        .map(|(qi, fq)| {
            let q = fq.question;
            let skipped = fq.draft.skipped;
            let label: SharedString = if q.text.is_empty() {
                l10n.hermes_response().into()
            } else {
                q.text.clone().into()
            };
            let header = div()
                .flex()
                .items_start()
                .gap(px(8.))
                .when(count > 1, |d| {
                    d.child(
                        div()
                            .flex_none()
                            .min_w(px(14.))
                            .text_size(px(m.small))
                            .text_color(r.text_faint)
                            .child(SharedString::from(format!("{}.", qi + 1))),
                    )
                })
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_size(px(m.control))
                        .line_height(relative(1.4))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(if skipped { r.text_subtle } else { r.text })
                        .child(if q.text.is_empty() {
                            SharedString::default()
                        } else {
                            label.clone()
                        }),
                )
                .when(!q.locked, |d| {
                    let on_skip = on_skip.clone();
                    d.child(skip_toggle(
                        format!("hermes-skip-{id}-{qi}"),
                        skipped,
                        enabled,
                        Rc::new(move |w: &mut Window, cx: &mut App| on_skip(qi, w, cx)),
                        l10n,
                        window,
                        cx,
                    ))
                });
            let body: AnyElement = if q.locked {
                div()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .child(icon(IconName::Check, 13., r.success))
                    .child(
                        div()
                            .text_size(px(m.small))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(
                                q.locked_answer
                                    .clone()
                                    .unwrap_or_else(|| l10n.hermes_clarify_skipped()),
                            )),
                    )
                    .into_any_element()
            } else {
                let choices = q.choices.len() + usize::from(fq.input.is_some());
                let rows: Vec<AnyElement> = q
                    .choices
                    .iter()
                    .enumerate()
                    .map(|(ci, choice)| {
                        let on = fq.draft.choices.contains(&choice.value);
                        let value = choice.value.clone();
                        let on_pick = on_pick.clone();
                        let row_id =
                            ElementId::Name(format!("hermes-choice-{id}-{qi}-{ci}").into());
                        let mark: AnyElement = if q.multi {
                            check_mark(on, &t).into_any_element()
                        } else {
                            radio_dot(on, &t).into_any_element()
                        };
                        div()
                            .id(row_id)
                            .role(if q.multi {
                                Role::CheckBox
                            } else {
                                Role::RadioButton
                            })
                            .aria_label(SharedString::from(if choice.recommended {
                                format!("{}, {}", choice.label, l10n.hermes_clarify_recommended())
                            } else {
                                choice.label.clone()
                            }))
                            .aria_toggled(if on { Toggled::True } else { Toggled::False })
                            .aria_position_in_set(ci + 1)
                            .aria_size_of_set(choices)
                            .min_h(px(m.row_height + 6.))
                            .px(px(8.))
                            .py(px(4.))
                            .flex()
                            .items_center()
                            .gap(px(10.))
                            .rounded(px(7.))
                            .when(skipped || !enabled, |d| d.opacity(0.5))
                            .when(on, |d| d.bg(r.selected))
                            .when(!on && enabled && !skipped, |d| {
                                d.hover(|s| s.bg(r.hover))
                                    .active(|s| s.bg(pressed_fill(r.hover, &t)))
                                    .cursor_pointer()
                            })
                            .child(mark)
                            .child(
                                div()
                                    .min_w_0()
                                    .text_size(px(m.control))
                                    .text_color(r.text)
                                    .child(SharedString::from(choice.label.clone())),
                            )
                            .when(choice.recommended, |d| {
                                d.child(badge(
                                    l10n.hermes_clarify_recommended(),
                                    with_alpha(r.text, if t.dark { 0.14 } else { 0.07 }),
                                    r.text_subtle,
                                    cx,
                                ))
                            })
                            .when(enabled && !skipped, |d| {
                                d.on_click(move |_, w, cx| on_pick(qi, value.clone(), w, cx))
                            })
                            .keyboard_control(Ring::Inset(7.), window, cx)
                            .into_any_element()
                    })
                    .collect();
                let field = fq.input.as_ref().map(|state| {
                    let hint: SharedString = if q.choices.is_empty() {
                        l10n.hermes_response().into()
                    } else {
                        l10n.hermes_clarify_other_answer().into()
                    };
                    field_frame(false, m.control_height + 2., cx)
                        .when(skipped || !enabled, |d| d.opacity(0.5))
                        .child(div().flex_1().child(bare_input(state, hint, m.control)))
                        .into_any_element()
                });
                div()
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .when(count > 1, |d| d.pl(px(22.)))
                    .child(
                        div()
                            .id(ElementId::Name(format!("hermes-question-{id}-{qi}").into()))
                            .role(if q.multi {
                                Role::Group
                            } else {
                                Role::RadioGroup
                            })
                            .aria_label(label.clone())
                            .flex()
                            .flex_col()
                            .gap(px(2.))
                            .children(rows),
                    )
                    .when_some(field, |d, f| d.child(div().pt(px(4.)).child(f)))
                    .into_any_element()
            };
            div()
                .flex()
                .flex_col()
                .gap(px(6.))
                .when(qi > 0, |d| {
                    d.pt(px(12.)).border_t_1().border_color(r.divider)
                })
                .child(header)
                .child(body)
                .into_any_element()
        })
        .collect();
    div()
        .id(ElementId::Name(format!("hermes-form-{id}").into()))
        .role(Role::Group)
        .max_h(px(360.))
        .overflow_y_scroll()
        .flex()
        .flex_col()
        .gap(px(12.))
        .children(blocks)
        .into_any_element()
}

/// A square check mark for a multi-select choice.
fn check_mark(on: bool, t: &conduit_components::ConduitTheme) -> gpui_kit::Div {
    let r = t.roles;
    div()
        .size(px(16.))
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .rounded(px(4.))
        .bg(if on {
            r.checked
        } else {
            conduit_components::views::kit::field_fill(t)
        })
        .when(!on, |d| d.border_1().border_color(r.control_edge))
        .when(on, |d| {
            d.child(icon(IconName::Check, 11., r.checked_foreground))
        })
}

/// Skip, a small toggle at the end of a question's line.
fn skip_toggle(
    id: String,
    on: bool,
    enabled: bool,
    toggle: Toggle,
    l10n: &L10n,
    window: &mut Window,
    cx: &mut App,
) -> AnyElement {
    let t = cx.conduit().clone();
    let r = t.roles;
    let m = t.metrics;
    let fill = if on {
        with_alpha(r.text, if t.dark { 0.16 } else { 0.08 })
    } else {
        gpui_kit::Hsla::transparent_black()
    };
    div()
        .id(ElementId::Name(id.into()))
        .role(Role::CheckBox)
        .aria_label(SharedString::from(l10n.hermes_clarify_skip()))
        .aria_toggled(if on { Toggled::True } else { Toggled::False })
        .flex_none()
        .h(px(22.))
        .px(px(8.))
        .flex()
        .items_center()
        .gap(px(4.))
        .rounded(px(6.))
        .border_1()
        .border_color(r.border)
        .bg(fill)
        .text_size(px(m.small))
        .text_color(if on { r.text } else { r.text_subtle })
        .when(on, |d| d.child(icon(IconName::Check, 11., r.text)))
        .child(SharedString::from(l10n.hermes_clarify_skip()))
        .when(!enabled, |d| d.opacity(0.5))
        .when(enabled, |d| {
            d.cursor_pointer()
                .hover(|s| s.bg(r.hover))
                .active(|s| s.bg(pressed_fill(fill, &t)))
                .on_click(move |_, w, cx| toggle(w, cx))
        })
        .keyboard_control(Ring::Outset(3.), window, cx)
        .into_any_element()
}

/// Its own words, as typed.
pub fn typed(input: Option<&Entity<InputState>>, cx: &App) -> String {
    input.map(|i| forms::raw(i, cx)).unwrap_or_default()
}

/// A paid tool's price and the chat's spend so far, as chips, with a
/// warning line when the call goes past the chat's limit.
pub fn cost_chips(cost: &HermesCost, l10n: &L10n, cx: &App) -> AnyElement {
    let t = cx.conduit();
    let r = t.roles;
    let m = t.metrics;
    let chip = |glyph: IconName, text: String, color: gpui_kit::Hsla, fill: gpui_kit::Hsla| {
        div()
            .flex_none()
            .h(px(22.))
            .px(px(8.))
            .flex()
            .items_center()
            .gap(px(5.))
            .rounded_full()
            .bg(fill)
            .text_size(px(m.small))
            .font_weight(FontWeight::MEDIUM)
            .text_color(color)
            .child(icon(glyph, 12., color))
            .child(SharedString::from(text))
    };
    let neutral = with_alpha(r.text, if t.dark { 0.12 } else { 0.06 });
    let spend = match (&cost.spent, &cost.limit) {
        (Some(spent), Some(limit)) => Some(l10n.hermes_approval_spent_of_limit(spent, limit)),
        (Some(spent), None) => Some(l10n.hermes_approval_spent(spent)),
        (None, Some(limit)) => Some(l10n.hermes_approval_spend_limit(limit)),
        (None, None) => None,
    };
    let price = cost.price.as_ref().map(|price| {
        let shown = if cost.approximate {
            format!("\u{2248} {price}")
        } else {
            price.clone()
        };
        match &cost.note {
            Some(note) => format!("{shown} \u{b7} {note}"),
            None => shown,
        }
    });
    div()
        .flex()
        .flex_col()
        .gap(px(6.))
        .child(
            div()
                .id("hermes-cost")
                .role(Role::Group)
                .aria_label(SharedString::from(
                    [
                        cost.price.as_ref().map(|p| l10n.hermes_approval_cost(p)),
                        spend.clone(),
                    ]
                    .into_iter()
                    .flatten()
                    .collect::<Vec<_>>()
                    .join(". "),
                ))
                .flex()
                .flex_wrap()
                .gap(px(6.))
                .when_some(price, |d, price| {
                    d.child(chip(IconName::Zap, price, r.text, neutral))
                })
                .when_some(spend, |d, spend| {
                    let text = match &cost.server {
                        Some(server) => format!("{spend} \u{b7} {server}"),
                        None => spend,
                    };
                    let (color, fill) = if cost.over_limit {
                        (r.warning, with_alpha(r.warning, 0.14))
                    } else {
                        (r.text_subtle, neutral)
                    };
                    d.child(chip(IconName::Database, text, color, fill))
                }),
        )
        .when(cost.over_limit, |d| {
            d.child(
                div()
                    .flex()
                    .items_start()
                    .gap(px(6.))
                    .child(icon(IconName::TriangleAlert, 13., r.warning))
                    .child(
                        div()
                            .text_size(px(m.small))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(r.warning)
                            .child(SharedString::from(l10n.hermes_approval_over_limit())),
                    ),
            )
        })
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stores::ui_requests::ClarifyChoice;

    fn question(id: &str, choices: &[&str], multi: bool) -> ClarifyQuestion {
        ClarifyQuestion {
            id: id.into(),
            text: format!("Question {id}?"),
            choices: choices
                .iter()
                .map(|c| ClarifyChoice {
                    value: c.to_string(),
                    label: c.to_string(),
                    recommended: false,
                })
                .collect(),
            multi,
            locked: false,
            locked_answer: None,
        }
    }

    #[test]
    fn a_single_choice_is_a_choice_or_own_words_never_both() {
        let q = question("q0", &["Teal", "Amber"], false);
        let mut d = ClarifyDraft::default();
        assert!(!d.settles(&q, ""));
        assert!(d.pick(&q, "Teal"), "picking clears the own words");
        assert_eq!(d.answer(&q, ""), Some("Teal".into()));
        d.typed(&q, "Coral");
        assert_eq!(d.answer(&q, "Coral"), Some("Coral".into()));
        // Picking the chosen one again unpicks it.
        d.pick(&q, "Amber");
        d.pick(&q, "Amber");
        assert_eq!(d.answer(&q, ""), None);
    }

    #[test]
    fn several_choices_and_own_words_go_as_one_list() {
        let q = question("q1", &["Starter", "Main", "Dessert"], true);
        let mut d = ClarifyDraft::default();
        assert!(!d.pick(&q, "Main"));
        d.pick(&q, "Dessert");
        assert_eq!(
            d.answer(&q, " Cheese "),
            Some(r#"["Main","Dessert","Cheese"]"#.into())
        );
        d.pick(&q, "Main");
        assert_eq!(d.answer(&q, ""), Some(r#"["Dessert"]"#.into()));
    }

    #[test]
    fn a_skipped_question_settles_and_answers_nothing() {
        let q = question("q2", &[], false);
        let d = ClarifyDraft {
            choices: vec![],
            skipped: true,
        };
        assert!(d.settles(&q, "words"));
        assert_eq!(d.answer(&q, "words"), None);
    }

    #[test]
    fn the_form_is_ready_once_every_open_question_settles() {
        let a = question("a", &["Yes", "No"], false);
        let mut locked = question("b", &[], false);
        locked.locked = true;
        let qs = vec![a.clone(), locked];
        let unanswered = |_: &ClarifyQuestion| (ClarifyDraft::default(), String::new());
        assert_eq!(progress(&qs, unanswered), (1, 2, false));
        let picked = |_: &ClarifyQuestion| {
            (
                ClarifyDraft {
                    choices: vec!["No".into()],
                    skipped: false,
                },
                String::new(),
            )
        };
        assert_eq!(progress(&qs, picked), (2, 2, true));
        // The answered-elsewhere question is left out of what is sent.
        assert_eq!(
            answers(&qs, picked),
            vec![HermesClarifyAnswer {
                question_id: "a".into(),
                answer: Some("No".into()),
            }]
        );
    }
}
