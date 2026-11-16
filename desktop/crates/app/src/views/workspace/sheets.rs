//! The workspace's small forms, as window sheets on the main window: New
//! Knowledge Base (a name and a description), the knowledge browser's New
//! Folder, Rename and Add Text File, a tool's Import from URL, and a
//! prompt version's comparison with production.
//!
//! [`FormSheet`] is one sheet for all the small forms: a title, labelled
//! fields (one may be a text area), and a default button whose work runs
//! in the caller's closure; a refusal shows inside the sheet, which stays.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::theme::{MONO_FONT, with_alpha};
use conduit_components::views::kit::Button;
use conduit_protocol::{
    NoticeLevel, WorkspaceDetail, WorkspaceKind, WorkspaceKnowledgeDto, WorkspacePromptDiff,
    WorkspaceSave, methods,
};
use gpui_kit::component::input::{InputEvent, InputState, Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, ElementId, Entity, FontWeight, Role, SharedString,
    Subscription, Task, WeakEntity, Window, div, px, relative,
};

use super::{WorkspacePane, editor};
use crate::l10n::ActiveL10n as _;
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::navigation::WorkspaceSection;
use crate::views::forms;
use crate::views::sheet::{self, SheetBody};

/// The sheets' width.
pub const WIDTH: f32 = 460.;

/// One field of a [`FormSheet`].
pub struct SheetField {
    pub label: String,
    pub value: String,
    pub placeholder: String,
    /// A text area rather than a one-line field.
    pub multiline: bool,
    /// The default button waits for it.
    pub required: bool,
}

impl SheetField {
    pub fn line(label: impl Into<String>, value: impl Into<String>) -> Self {
        Self {
            label: label.into(),
            value: value.into(),
            placeholder: String::new(),
            multiline: false,
            required: true,
        }
    }

    pub fn placeholder(mut self, text: impl Into<String>) -> Self {
        self.placeholder = text.into();
        self
    }

    pub fn optional(mut self) -> Self {
        self.required = false;
        self
    }

    pub fn multiline(mut self) -> Self {
        self.multiline = true;
        self
    }
}

/// What the default button does with the fields' text: Ok closes the
/// sheet, Err shows why it did not go through.
pub type SheetRun = Rc<dyn Fn(Vec<String>, &mut App) -> Task<Result<(), String>>>;

enum FieldInput {
    Line(Entity<InputState>),
    Area(Entity<TextareaState>),
}

impl FieldInput {
    fn text(&self, cx: &App) -> String {
        match self {
            Self::Line(s) => s.read(cx).value().to_string(),
            Self::Area(s) => s.read(cx).value().to_string(),
        }
    }
}

pub struct FormSheet {
    title: String,
    note: Option<String>,
    confirm: String,
    fields: Vec<(SheetField, FieldInput)>,
    initial: Vec<String>,
    run: SheetRun,
    busy: bool,
    pub failure: Option<String>,
    _subscriptions: Vec<Subscription>,
}

impl FormSheet {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        stores: &Stores,
        title: String,
        note: Option<String>,
        confirm: String,
        fields: Vec<SheetField>,
        run: SheetRun,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        // Opened for one account: another's sign-in closes it, its words
        // with it, so nothing in it is made under the next.
        let mut subscriptions = vec![sheet::close_with_account(stores, cx)];
        let mut built = vec![];
        let mut initial = vec![];
        for field in fields {
            initial.push(field.value.clone());
            let input = if field.multiline {
                let placeholder = field.placeholder.clone();
                let value = field.value.clone();
                let state = cx.new(|cx| {
                    TextareaState::new(window, cx)
                        .auto_grow(6, 14)
                        .placeholder(placeholder)
                        .default_value(value)
                });
                subscriptions.push(cx.subscribe_in(
                    &state,
                    window,
                    |this, _, e: &InputEvent, _, cx| {
                        if matches!(e, InputEvent::Change) {
                            this.failure = None;
                            cx.notify();
                        }
                    },
                ));
                FieldInput::Area(state)
            } else {
                let state = forms::input(field.placeholder.clone(), false, window, cx);
                let value = field.value.clone();
                state.update(cx, |s, cx| s.set_value(value, window, cx));
                subscriptions.push(cx.subscribe_in(
                    &state,
                    window,
                    |this, _, e: &InputEvent, window, cx| match e {
                        InputEvent::Change => {
                            this.failure = None;
                            cx.notify();
                        }
                        InputEvent::PressEnter { .. } => this.confirm(window, cx),
                        _ => {}
                    },
                ));
                FieldInput::Line(state)
            };
            built.push((field, input));
        }
        if let Some((_, FieldInput::Line(first))) = built.first() {
            first.update(cx, |s, cx| {
                s.focus(window, cx);
                s.select_all(window, cx);
            });
        }
        Self {
            title,
            note,
            confirm,
            fields: built,
            initial,
            run,
            busy: false,
            failure: None,
            _subscriptions: subscriptions,
        }
    }

    pub fn values(&self, cx: &App) -> Vec<String> {
        self.fields.iter().map(|(_, i)| i.text(cx)).collect()
    }

    /// Fills field `index` (the E2E pass).
    pub fn set_value(
        &mut self,
        index: usize,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match self.fields.get(index).map(|(_, i)| i) {
            Some(FieldInput::Line(s)) => {
                s.update(cx, |s, cx| s.set_value(text.to_string(), window, cx))
            }
            Some(FieldInput::Area(s)) => {
                s.update(cx, |s, cx| s.set_value(text.to_string(), window, cx))
            }
            None => {}
        }
        cx.notify();
    }

    fn filled(&self, cx: &App) -> bool {
        self.fields
            .iter()
            .all(|(f, i)| !f.required || !i.text(cx).trim().is_empty())
    }

    pub fn confirm(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy || !self.filled(cx) {
            return;
        }
        self.busy = true;
        self.failure = None;
        cx.notify();
        let task = (self.run)(self.values(cx), cx);
        let handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = task.await;
            let _ = handle.update(cx, |_, _, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.busy = false;
                    match result {
                        Ok(()) => sheet::dismiss(cx),
                        Err(text) => s.failure = Some(text),
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }
}

impl SheetBody for FormSheet {
    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        if self.values(cx) == self.initial {
            sheet::dismiss(cx);
            return;
        }
        let l = cx.l10n().clone();
        let spec = SheetSpec::new(
            l.desktop_discard_changes_title(),
            l.desktop_discard_changes_message(),
            l.desktop_discard(),
            l.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        cx.spawn(async move |_, cx: &mut AsyncApp| {
            if ask.await {
                cx.update(sheet::dismiss);
            }
        })
        .detach();
    }

    fn label(&self, _: &App) -> SharedString {
        self.title.clone().into()
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l = cx.l10n().clone();
        let cancel = cx.entity().downgrade();
        let confirm = cx.entity().downgrade();
        Some(
            forms::form_buttons(vec![
                Button::new("workspace-sheet-cancel", l.cancel())
                    .disabled(self.busy)
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = cancel.update(cx, |v, cx| v.cancel(window, cx));
                    }))
                    .into_any_element(),
                Button::new("workspace-sheet-confirm", self.confirm.clone())
                    .primary()
                    .disabled(self.busy || !self.filled(cx))
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = confirm.update(cx, |v, cx| v.confirm(window, cx));
                    }))
                    .into_any_element(),
            ])
            .into_any_element(),
        )
    }
}

impl Render for FormSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let mut rows: Vec<AnyElement> = vec![];
        for (field, input) in &self.fields {
            rows.push(match input {
                FieldInput::Line(state) => {
                    forms::field(field.label.clone(), state, None, None, window, cx)
                        .into_any_element()
                }
                FieldInput::Area(state) => {
                    editor::stacked_row(field.label.clone(), Textarea::new(state), None, cx)
                        .into_any_element()
                }
            });
        }
        div()
            .id("workspace-form-sheet")
            .w_full()
            .flex()
            .flex_col()
            .gap(px(14.))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(4.))
                    .child(
                        div()
                            .id("sheet-title")
                            .role(Role::Heading)
                            .text_size(px(t.metrics.body + 2.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(self.title.clone()),
                    )
                    .when_some(self.note.clone(), |d, note| {
                        d.child(
                            div()
                                .text_size(px(t.metrics.small + 0.5))
                                .line_height(relative(1.4))
                                .text_color(t.roles.text_subtle)
                                .child(note),
                        )
                    }),
            )
            .child(forms::form_group(rows, cx))
            .when_some(self.failure.clone(), |d, f| {
                d.child(forms::form_error("workspace-sheet-failure", f, cx))
            })
    }
}

/// Opens a [`FormSheet`] on the main window.
#[allow(clippy::too_many_arguments)]
pub fn open_form(
    stores: Stores,
    title: String,
    note: Option<String>,
    confirm: String,
    fields: Vec<SheetField>,
    run: SheetRun,
    window: &mut Window,
    cx: &mut App,
) -> Option<Entity<FormSheet>> {
    sheet::open(window, WIDTH, cx, move |w, cx| {
        FormSheet::new(&stores, title, note, confirm, fields, run, w, cx)
    })
}

/// New Knowledge Base…: a name and a description; once made it opens.
pub fn new_knowledge(
    pane: WeakEntity<WorkspacePane>,
    stores: Stores,
    rpc: crate::stores::rpc::Rpc,
    window: &mut Window,
    cx: &mut App,
) {
    let l = cx.l10n().clone();
    let window_handle = window.window_handle();
    let run_stores = stores.clone();
    let run: SheetRun = Rc::new(move |values, cx| {
        let account = super::active_account(&run_stores, cx);
        let name = values
            .first()
            .cloned()
            .unwrap_or_default()
            .trim()
            .to_string();
        let description = values
            .get(1)
            .cloned()
            .unwrap_or_default()
            .trim()
            .to_string();
        let call = rpc.call::<methods::WorkspaceSave>(&WorkspaceSave {
            detail: WorkspaceDetail {
                kind: WorkspaceKind::Knowledge,
                model: None,
                knowledge: Some(WorkspaceKnowledgeDto {
                    id: String::new(),
                    name,
                    description,
                    file_count: 0,
                    external: false,
                    max_file_count: None,
                    max_file_size: None,
                }),
                prompt: None,
                tool: None,
                skill: None,
                grants: vec![],
                write_access: true,
                owner_name: None,
                updated_at_ms: None,
            },
            create: true,
            metadata_only: false,
        });
        let pane = pane.clone();
        cx.spawn(async move |cx: &mut AsyncApp| match call.await {
            Ok(detail) => {
                let id = editor::detail_id(&detail);
                let _ = window_handle.update(cx, |_, window, cx| {
                    let _ = pane.update(cx, |p, cx| {
                        // Made under one account: never opened in the next
                        // one's workspace, over what it shows.
                        if super::active_account(p.stores(), cx) != account {
                            return;
                        }
                        let l = cx.l10n().clone();
                        let toasts = p.stores().toasts.clone();
                        toasts.update(cx, |t, cx| {
                            t.show(
                                NoticeLevel::Success,
                                l.desktop_workspace_knowledge_saved(),
                                cx,
                            )
                        });
                        p.load(WorkspaceSection::Knowledge, false, cx);
                        if let Some(id) = id {
                            p.open_now(WorkspaceSection::Knowledge, Some(id), window, cx);
                        }
                    });
                });
                Ok(())
            }
            Err(e) => {
                log::warn!("workspace.save knowledge: {e}");
                Err(cx.update(|cx| editor::failure_text(&e, &cx.l10n().clone())))
            }
        })
    });
    open_form(
        stores,
        l.workspace_knowledge_create_title(),
        None,
        l.create(),
        vec![
            SheetField::line(l.desktop_workspace_knowledge_name(), ""),
            SheetField::line(l.desktop_workspace_knowledge_description(), "").optional(),
        ],
        run,
        window,
        cx,
    );
}

/// The comparison of a version with production, line by line.
pub struct DiffSheet {
    diff: WorkspacePromptDiff,
}

impl SheetBody for DiffSheet {
    fn cancel(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        sheet::dismiss(cx);
    }

    fn label(&self, cx: &App) -> SharedString {
        cx.l10n().workspace_prompt_history_diff_title().into()
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l = cx.l10n().clone();
        Some(
            forms::form_buttons(vec![
                Button::new("workspace-diff-done", l.desktop_done())
                    .primary()
                    .on_click(Rc::new(|_, _, cx| sheet::dismiss(cx)))
                    .into_any_element(),
            ])
            .into_any_element(),
        )
    }
}

impl Render for DiffSheet {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        // The file headers (`---`, `+++`) say nothing here; a hunk's
        // `@@` line is a quiet separator.
        let shown: Vec<&String> = self
            .diff
            .lines
            .iter()
            .filter(|l| !l.starts_with("--- ") && !l.starts_with("+++ "))
            .collect();
        let lines: Vec<AnyElement> = shown
            .iter()
            .enumerate()
            .map(|(i, line)| {
                let hunk = line.starts_with("@@");
                let (bg, sign) = match line.chars().next() {
                    _ if hunk => (None, " "),
                    Some('+') => (
                        Some(with_alpha(r.success, if t.dark { 0.18 } else { 0.12 })),
                        "+",
                    ),
                    Some('-') => (
                        Some(with_alpha(r.danger, if t.dark { 0.18 } else { 0.10 })),
                        "−",
                    ),
                    _ => (None, " "),
                };
                let text = if hunk {
                    line.to_string()
                } else {
                    line.get(1..).unwrap_or_default().to_string()
                };
                div()
                    .id(ElementId::NamedInteger("diff-line".into(), i as u64))
                    .px(px(8.))
                    .flex()
                    .gap(px(8.))
                    .when_some(bg, |d, bg| d.bg(bg))
                    .when(hunk, |d| d.text_color(r.text_faint))
                    .child(div().w(px(10.)).text_color(r.text_subtle).child(sign))
                    .child(div().flex_1().min_w_0().child(text))
                    .into_any_element()
            })
            .collect();
        let empty = shown
            .iter()
            .all(|l| !l.starts_with(['+', '-']) || l.starts_with("@@"));
        div()
            .id("workspace-diff-sheet")
            .w_full()
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(
                div()
                    .id("sheet-title")
                    .role(Role::Heading)
                    .text_size(px(t.metrics.body + 2.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(l.workspace_prompt_history_diff_title()),
            )
            .when(self.diff.name_changed, |d| {
                d.child(
                    div()
                        .text_size(px(t.metrics.small + 0.5))
                        .text_color(r.text_subtle)
                        .child(l.desktop_workspace_prompt_history_diff_name_changed()),
                )
            })
            .child(if empty {
                div()
                    .text_color(r.text_subtle)
                    .child(l.desktop_workspace_prompt_history_diff_empty())
                    .into_any_element()
            } else {
                div()
                    .id("workspace-diff-lines")
                    .role(Role::Group)
                    .rounded(px(8.))
                    .border_1()
                    .border_color(r.divider)
                    .py(px(6.))
                    .font_family(MONO_FONT)
                    .text_size(px(t.metrics.small + 0.5))
                    .line_height(relative(1.45))
                    .children(lines)
                    .into_any_element()
            })
    }
}

/// Opens the comparison sheet.
pub fn open_diff(diff: WorkspacePromptDiff, window: &mut Window, cx: &mut App) {
    sheet::open(window, 560., cx, move |_, _| DiffSheet { diff });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::views::sheet::bench::{bench, switch_account};

    /// A small form opened for one account closes when another signs in:
    /// nothing typed in it is made under the next.
    #[gpui_kit::test]
    fn a_form_closes_on_another_account(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        let rpc = stores.connection.read_with(vcx, |c, _| c.rpc());
        vcx.update(|window, cx| {
            new_knowledge(WeakEntity::new_invalid(), stores.clone(), rpc, window, cx)
        });
        vcx.run_until_parked();
        let form = vcx
            .update(|_, cx| sheet::current::<FormSheet>(cx))
            .expect("New Knowledge Base opens");
        vcx.update(|window, cx| form.update(cx, |f, cx| f.set_value(0, "Trail notes", window, cx)));
        switch_account(&stores, vcx);
        assert!(
            vcx.update(|_, cx| sheet::current::<FormSheet>(cx))
                .is_none(),
            "Avery's form stayed open over Blake's account"
        );
        assert!(daemon.calls::<methods::WorkspaceSave>().is_empty());
    }
}
