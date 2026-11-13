//! A changed file's coloured lines, as a sheet: the phone's
//! `HermesDiffSheet`. Added lines on green, removed on red, hunk headers
//! quiet, with the old and new line numbers Hermes' hunk headers give. A
//! pop-up names the file shown (its path from the chat's working directory)
//! and switches to the others the reply changed. The lines are a lazy list,
//! so a long diff (Hermes sends up to 2,000 lines) scrolls smoothly; a long
//! line scrolls sideways rather than wrapping.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::theme::{MONO_FONT, with_alpha};
use conduit_components::views::kit::{Button, heading};
use conduit_protocol::{ChangedFileDto, DiffLineDto, DiffLineKind};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Context, ElementId, FontWeight, ListHorizontalSizingBehavior, Role,
    SharedString, Window, div, px, uniform_list,
};

use crate::actions::SettingsChoice;
use crate::l10n::ActiveL10n as _;
use crate::views::chat::hermes_blocks::display_path;
use crate::views::forms;
use crate::views::settings::controls::{Choice, popup};
use crate::views::sheet::{self, SheetBody};

const WIDTH: f32 = 720.;
/// A line's height in the list.
const LINE: f32 = 20.;
/// The list's height.
const LIST: f32 = 440.;

/// Opens `files` at `index`, their paths shortened against `directory`.
pub fn open(
    files: Vec<ChangedFileDto>,
    index: usize,
    directory: Option<String>,
    window: &mut Window,
    cx: &mut App,
) {
    if files.is_empty() {
        return;
    }
    let _ = sheet::open(window, WIDTH, cx, move |_, _| DiffSheet {
        index: index.min(files.len() - 1),
        files: files.into_iter().map(Rc::new).collect(),
        directory,
    });
}

pub struct DiffSheet {
    files: Vec<Rc<ChangedFileDto>>,
    index: usize,
    directory: Option<String>,
}

impl DiffSheet {
    fn shown_path(&self, file: &ChangedFileDto, cx: &App) -> String {
        if file.path.is_empty() {
            cx.l10n().hermes_diff_unnamed_file()
        } else {
            display_path(&file.path, self.directory.as_deref())
        }
    }

    fn on_choice(&mut self, action: &SettingsChoice, cx: &mut Context<Self>) {
        if action.menu != "hermes-diff-file" {
            return;
        }
        if let Ok(i) = action.value.parse::<usize>()
            && i < self.files.len()
        {
            self.index = i;
            cx.notify();
        }
    }
}

/// One line: its numbers, its sign, its text.
fn line_row(i: usize, line: &DiffLineDto, t: &conduit_components::ConduitTheme) -> AnyElement {
    let r = t.roles;
    let m = t.metrics;
    let (fill, color, sign) = match line.kind {
        DiffLineKind::Added => (
            with_alpha(r.success, if t.dark { 0.18 } else { 0.11 }),
            r.text,
            "+",
        ),
        DiffLineKind::Removed => (
            with_alpha(r.danger, if t.dark { 0.18 } else { 0.10 }),
            r.text,
            "\u{2212}",
        ),
        DiffLineKind::Hunk => (
            with_alpha(r.text, if t.dark { 0.08 } else { 0.04 }),
            r.text_subtle,
            "",
        ),
        DiffLineKind::Note => (gpui_kit::Hsla::transparent_black(), r.text_faint, ""),
        _ => (gpui_kit::Hsla::transparent_black(), r.text, " "),
    };
    let number = |n: Option<i64>| {
        div()
            .w(px(40.))
            .flex_none()
            .pr(px(6.))
            .flex()
            .justify_end()
            .text_color(r.text_faint)
            .child(SharedString::from(
                n.map(|n| n.to_string()).unwrap_or_default(),
            ))
    };
    let aria = match line.kind {
        DiffLineKind::Added => format!("+ {}", line.text),
        DiffLineKind::Removed => format!("\u{2212} {}", line.text),
        _ => line.text.clone(),
    };
    div()
        .id(ElementId::NamedInteger("hermes-diff-line".into(), i as u64))
        .h(px(LINE))
        .min_w_full()
        .flex()
        .items_center()
        .bg(fill)
        .font_family(MONO_FONT)
        .text_size(px(m.code - 1.))
        .whitespace_nowrap()
        .role(Role::ListItem)
        .aria_label(SharedString::from(aria))
        .child(number(line.old_number))
        .child(number(line.new_number))
        .child(
            div()
                .w(px(14.))
                .flex_none()
                .text_color(match line.kind {
                    DiffLineKind::Added => r.success,
                    DiffLineKind::Removed => r.danger,
                    _ => r.text_faint,
                })
                .child(SharedString::from(sign)),
        )
        .child(
            div()
                .pr(px(12.))
                .text_color(color)
                .when(line.kind == DiffLineKind::Note, |d| d.italic())
                .child(SharedString::from(line.text.clone())),
        )
        .into_any_element()
}

impl SheetBody for DiffSheet {
    fn cancel(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        sheet::dismiss(cx);
    }

    fn label(&self, cx: &App) -> SharedString {
        cx.l10n()
            .hermes_changed_files(self.files.len() as i64)
            .into()
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l10n = cx.l10n().clone();
        Some(
            forms::form_buttons(vec![
                Button::new("hermes-diff-done", l10n.desktop_done())
                    .primary()
                    .on_click(Rc::new(|_, _, cx| sheet::dismiss(cx)))
                    .into_any_element(),
            ])
            .into_any_element(),
        )
    }
}

impl Render for DiffSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let l10n = cx.l10n().clone();
        let file = self.files[self.index].clone();
        let path = self.shown_path(&file, cx);
        let title: AnyElement = if self.files.len() > 1 {
            let choices: Vec<Choice> = self
                .files
                .iter()
                .enumerate()
                .map(|(i, f)| Choice::new(i.to_string(), self.shown_path(f, cx)))
                .collect();
            popup(
                "hermes-diff-file",
                &l10n.desktop_hermes_diff_file(),
                choices,
                &self.index.to_string(),
                false,
                window,
                cx,
            )
            .max_w(px(520.))
            .into_any_element()
        } else {
            heading(
                "hermes-diff-title",
                path.clone(),
                1,
                m.control + 1.,
                FontWeight::SEMIBOLD,
                r.text,
            )
            .truncate()
            .into_any_element()
        };
        let lines = Rc::new(file.lines.clone());
        // A short diff takes its lines' height; a long one scrolls.
        let height = (lines.len().max(1) as f32 * LINE).min(LIST);
        let theme = t.clone();
        let list = uniform_list(
            ElementId::Name(format!("hermes-diff-lines-{}", self.index).into()),
            lines.len(),
            move |range, _, _| {
                range
                    .map(|i| line_row(i, &lines[i], &theme))
                    .collect::<Vec<_>>()
            },
        )
        .with_horizontal_sizing_behavior(ListHorizontalSizingBehavior::Unconstrained)
        .h(px(height));
        div()
            .id("hermes-diff-sheet")
            .on_action(cx.listener(|this, a: &SettingsChoice, _, cx| this.on_choice(a, cx)))
            .flex()
            .flex_col()
            .gap(px(10.))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .child(div().flex_1().min_w_0().child(title))
                    .child(
                        div()
                            .flex_none()
                            .flex()
                            .gap(px(6.))
                            .font_family(MONO_FONT)
                            .text_size(px(m.small))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(
                                div()
                                    .text_color(r.success)
                                    .child(SharedString::from(format!("+{}", file.added))),
                            )
                            .child(
                                div()
                                    .text_color(r.danger)
                                    .child(SharedString::from(format!("\u{2212}{}", file.removed))),
                            ),
                    ),
            )
            .child(
                div()
                    .id("hermes-diff-frame")
                    .role(Role::List)
                    .aria_label(SharedString::from(path))
                    .rounded(t.card_radius())
                    .border_1()
                    .border_color(r.border)
                    .bg(r.content)
                    .overflow_hidden()
                    .py(px(4.))
                    .child(list),
            )
    }
}
