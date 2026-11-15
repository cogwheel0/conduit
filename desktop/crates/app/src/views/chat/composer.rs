//! The composer.
//!
//! * **Text:** a GPUI Kit Textarea. Enter sends and Shift+Enter breaks the
//!   line; nothing sends while an input method is composing
//!   (`marked_text_range()`).
//! * **Attachments:** from +, a drop onto the composer, or a paste (images
//!   and copied files), each uploading with its own progress.
//! * **Menus:** `/` saved prompts (with the fill-in form for their fields,
//!   select fields included), `@` a model for this message only, `#`
//!   knowledge. Up/Down move, Enter or Tab choose, Esc closes; the keys go
//!   to the menu, not the text, while one is open.
//! * **Footer:** + attach, the feature switches `composer.options` allows
//!   (web search, image generation, tools), the temporary-chat switch
//!   before the first message, the model picker (`models.list` /
//!   `models.select`), and Send, which becomes Stop while an answer is
//!   written. Send waits while offline or while files upload.
//!
//! The composer emits [`ChatComposerEvent`]s; the chat pane sends.

use std::collections::BTreeMap;
use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::motion::{self, specs};
use conduit_components::theme::{ConduitTheme, with_alpha};
use conduit_components::views::focus::{
    ControlExt as _, RadioGroupExt as _, Ring, pressed_fill, radio_option_id,
};
use conduit_components::views::kit::{IconButton, icon_tile, overlay_shadow};
use conduit_components::views::shell::ModelPickerButton;
use conduit_protocol::{
    KnowledgeSummary, ModelSummary, PromptInput, PromptSummary, RenderPrompt, RenderedPrompt,
};
use gpui_kit::component::input::{Input, InputEvent, InputState, Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, ClipboardEntry, Context, ElementId, Entity, EntityInputHandler as _,
    EventEmitter, ExternalPaths, FocusHandle, Focusable, FontWeight, PathPromptOptions, Role,
    SharedString, Subscription, Window, div, img, px,
};

use crate::l10n::ActiveL10n as _;
use crate::stores::composer::{
    Attachment, ComposerStore, Trigger, TriggerKind, UploadState, match_models, match_prompts,
    model_label, trigger_at,
};

/// How many entries a `/`, `@` or `#` menu shows.
const MENU_LIMIT: usize = 8;

#[derive(Clone, Debug, PartialEq)]
pub enum ChatComposerEvent {
    /// Send this text (the composer has already cleared itself).
    Submit(String),
    Stop,
    /// The temporary-chat switch moved.
    Temporary(bool),
    /// The model picker opened or closed (the chat pane draws it under its
    /// toolbar).
    PickerChanged,
}

/// What the + menu's items do. The menu is native (NSMenu), as the phone's
/// + opens its attach panel: files first, then the feature switches.
#[derive(Clone, Debug, PartialEq, gpui_kit::Action)]
#[action(namespace = conduit_composer, no_json)]
pub enum ComposerMenu {
    AttachFiles,
    WebSearch,
    ImageGeneration,
    Tool(String),
}

/// A `/`, `@` or `#` menu open over the composer.
struct Menu {
    trigger: Trigger,
    highlighted: usize,
}

/// One field of a prompt's fill-in form.
enum FieldInput {
    Text(Entity<InputState>),
    Area(Entity<TextareaState>),
    Select(usize),
}

struct PromptField {
    input: PromptInput,
    value: FieldInput,
}

/// A saved prompt that needs its fields filled in.
struct PromptForm {
    prompt: PromptSummary,
    /// Where the `/command` was, so the text goes there.
    at: usize,
    fields: Vec<PromptField>,
    error: Option<String>,
    busy: bool,
}

/// The model picker's dropdown.
struct Picker {
    search: Entity<InputState>,
    highlighted: usize,
}

pub struct ChatComposer {
    pub composer: Entity<ComposerStore>,
    pub input: Entity<TextareaState>,
    menu: Option<Menu>,
    form: Option<PromptForm>,
    /// Bumped by each `prompts.render` and by Cancel: only the latest
    /// request, while it is not cancelled, changes the draft or the form.
    prompt_request: u64,
    picker: Option<Picker>,
    /// The picker just closed, drawn while it fades out.
    leaving_picker: Option<Picker>,
    /// An answer is being written: Stop instead of Send.
    pub streaming: bool,
    /// No network: Send waits.
    pub offline: bool,
    /// What it says beside Send meanwhile
    /// ([`crate::views::status::send_state`]): only where no banner says it
    /// (Quick Ask); the main window's pill says it once.
    pub offline_word: Option<String>,
    /// Why Send waits, its tooltip while dimmed
    /// ([`crate::views::status::send_waits`]).
    pub offline_reason: Option<String>,
    /// A chat not started yet: the temporary switch shows.
    pub new_chat: bool,
    pub temporary: bool,
    /// The model chip, the temporary switch and the picker live in the
    /// composer (Quick Ask). The main window's chat pane draws them in its
    /// toolbar instead, as the phone's header does.
    pub inline_model: bool,
    /// When the picker last closed, so a click on its trigger that first
    /// closed it (mouse down outside) does not open it again.
    picker_closed_at: Option<std::time::Instant>,
    /// Where the + button was last drawn: its menu opens upward from it.
    plus_bounds: Rc<std::cell::Cell<Option<gpui_kit::Bounds<gpui_kit::Pixels>>>>,
    /// Where the composer's frame was last drawn: the menu clears its top,
    /// whatever chips or attachments it holds above the field.
    frame_bounds: Rc<std::cell::Cell<Option<gpui_kit::Bounds<gpui_kit::Pixels>>>>,
    focus: FocusHandle,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<ChatComposerEvent> for ChatComposer {}

impl Focusable for ChatComposer {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl ChatComposer {
    pub fn new(
        composer: Entity<ComposerStore>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let placeholder = cx.l10n().message_hint_text();
        let input = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(1, 10)
                .placeholder(placeholder)
                .submit_on_enter(true)
        });
        let weak = cx.entity().downgrade();
        let subscriptions = vec![
            cx.subscribe_in(
                &input,
                window,
                |this, state, e: &InputEvent, window, cx| match e {
                    InputEvent::PressEnter {
                        shift: false,
                        secondary: false,
                    } => {
                        // An input method may hand Enter back while composing.
                        let composing =
                            state.update(cx, |s, cx| s.marked_text_range(window, cx).is_some());
                        if !composing {
                            this.submit(window, cx);
                        }
                    }
                    InputEvent::Change => this.text_changed(cx),
                    _ => {}
                },
            ),
            cx.observe(&composer, |_, _, cx| cx.notify()),
            // The menu and picker keys, ahead of the text field's own.
            cx.intercept_keystrokes(move |event, window, cx| {
                let key = event.keystroke.key.as_str();
                let modified = event.keystroke.modifiers.modified();
                if modified || !matches!(key, "up" | "down" | "enter" | "tab" | "escape") {
                    return;
                }
                let Some(this) = weak.upgrade() else {
                    return;
                };
                let handled = this.update(cx, |c, cx| c.menu_key(key, window, cx));
                if handled {
                    cx.stop_propagation();
                }
            }),
        ];
        Self {
            composer,
            input,
            menu: None,
            form: None,
            prompt_request: 0,
            picker: None,
            leaving_picker: None,
            streaming: false,
            offline: false,
            offline_word: None,
            offline_reason: None,
            new_chat: true,
            temporary: false,
            inline_model: true,
            picker_closed_at: None,
            plus_bounds: Rc::default(),
            frame_bounds: Rc::default(),
            focus: cx.focus_handle(),
            _subscriptions: subscriptions,
        }
    }

    pub fn focus_input(&self, window: &mut Window, cx: &mut Context<Self>) {
        self.input.update(cx, |s, cx| s.focus(window, cx));
    }

    /// The text field's placeholder (Quick Ask says "Ask Conduit…").
    pub fn set_placeholder(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        let text = text.to_string();
        self.input
            .update(cx, |s, cx| s.set_placeholder(text, window, cx));
    }

    /// A `/`, `@` or `#` menu, a prompt's form or the model picker is open
    /// (Esc closes that first).
    pub fn has_popup(&self) -> bool {
        self.menu.is_some() || self.form.is_some() || self.picker.is_some()
    }

    pub fn text(&self, cx: &App) -> String {
        self.input.read(cx).value().to_string()
    }

    pub fn set_text(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        let text = text.to_string();
        let end = text.len();
        self.input.update(cx, |s, cx| {
            s.set_value(text, window, cx);
            s.set_selected_range(end..end, cx);
        });
        self.text_changed(cx);
    }

    /// Whether Send would send now.
    pub fn can_send(&self, cx: &App) -> bool {
        let composer = self.composer.read(cx);
        let has_text = !self.text(cx).trim().is_empty();
        !self.streaming
            && !self.offline
            && !composer.uploading()
            && (has_text || composer.has_attachments())
    }

    /// Enter or Send: emits the text and clears the field.
    pub fn submit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // A trigger menu with nothing in it is no menu: Send sends.
        if self.menu.is_some() && self.menu_len(cx) == 0 {
            self.menu = None;
        }
        if self.menu.is_some() || self.form.is_some() {
            return;
        }
        if !self.can_send(cx) {
            return;
        }
        let text = self.text(cx).trim().to_string();
        // A prompt still being rendered belongs to the draft that just went.
        self.prompt_request += 1;
        self.input.update(cx, |s, cx| s.set_value("", window, cx));
        self.menu = None;
        cx.emit(ChatComposerEvent::Submit(text));
        cx.notify();
    }

    /// A refused send: its text and what it used (`used`, from
    /// [`ComposerStore::one_shot`]) come back, but only to the account and
    /// draft it was sent from; after another account or a new draft they are
    /// dropped. Every send path goes through here.
    pub fn give_back(
        &mut self,
        text: &str,
        used: crate::stores::composer::OneShot,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.composer.update(cx, |c, cx| c.give_back(used, cx)) {
            self.restore(text, window, cx);
        }
    }

    /// Puts text back after a refused send.
    pub fn restore(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        if self.text(cx).trim().is_empty() {
            self.set_text(text, window, cx);
        }
    }

    fn text_changed(&mut self, cx: &mut Context<Self>) {
        let state = self.input.read(cx);
        let value = state.value().to_string();
        let cursor = state.cursor();
        let trigger = trigger_at(&value, cursor);
        match &trigger {
            Some(t) if t.kind == TriggerKind::Prompt => {
                self.composer.update(cx, |c, cx| c.load_prompts(cx));
            }
            Some(t) if t.kind == TriggerKind::Knowledge => {
                let q = t.query.clone();
                self.composer.update(cx, |c, cx| c.search_knowledge(&q, cx));
            }
            _ => {}
        }
        self.menu = trigger.map(|trigger| Menu {
            highlighted: self
                .menu
                .as_ref()
                .filter(|m| m.trigger.kind == trigger.kind && m.trigger.query == trigger.query)
                .map_or(0, |m| m.highlighted),
            trigger,
        });
        cx.notify();
    }

    fn menu_len(&self, cx: &App) -> usize {
        let Some(menu) = &self.menu else {
            return 0;
        };
        let c = self.composer.read(cx);
        match menu.trigger.kind {
            TriggerKind::Prompt => c.prompts.as_deref().map_or(0, |p| {
                match_prompts(&menu.trigger.query, p, MENU_LIMIT).len()
            }),
            TriggerKind::Model => c.models.as_ref().map_or(0, |m| {
                match_models(&menu.trigger.query, &m.models, MENU_LIMIT).len()
            }),
            TriggerKind::Knowledge => c.knowledge_results.len().min(MENU_LIMIT),
        }
    }

    /// A key while a menu or the picker is open. True when it was used.
    pub(crate) fn menu_key(
        &mut self,
        key: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if let Some(picker) = &mut self.picker {
            let focused = picker.search.read(cx).focus_handle(cx).is_focused(window);
            if !focused {
                return false;
            }
            let models = self.picker_models(cx);
            let len = models.len();
            let picker = self.picker.as_mut().expect("checked");
            match key {
                "up" | "down" => picker.highlighted = menu_step(key, picker.highlighted, len),
                "enter" | "tab" => {
                    if let Some(m) = models.get(picker.highlighted).cloned() {
                        self.choose_model(&m.id, window, cx);
                    }
                }
                "escape" => self.close_picker(window, cx),
                _ => return false,
            }
            cx.notify();
            return true;
        }
        if self.menu.is_none() {
            return false;
        }
        let focused = self.input.read(cx).focus_handle(cx).is_focused(window);
        if !focused {
            return false;
        }
        let len = self.menu_len(cx);
        let menu = self.menu.as_mut().expect("checked");
        match key {
            "up" | "down" => menu.highlighted = menu_step(key, menu.highlighted, len),
            "enter" | "tab" => {
                if len == 0 {
                    // Nothing to choose: Enter sends as usual.
                    self.menu = None;
                    return key == "tab";
                }
                let index = menu.highlighted;
                self.choose(index, window, cx);
            }
            "escape" => self.menu = None,
            _ => return false,
        }
        cx.notify();
        true
    }

    /// Chooses entry `index` of the open `/`, `@` or `#` menu (what a click
    /// or Enter does).
    pub fn choose_menu_item(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        if self.menu.is_some() {
            self.choose(index, window, cx);
        }
    }

    /// Fills the open prompt form: text fields by name, and option
    /// `select` of each select field; then submits it (the E2E pass).
    pub fn fill_and_submit_form(
        &mut self,
        texts: &[(&str, &str)],
        select: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(form) = &mut self.form else {
            return;
        };
        for field in &mut form.fields {
            match &field.value {
                FieldInput::Text(s) => {
                    if let Some((_, v)) = texts.iter().find(|(n, _)| *n == field.input.name) {
                        let v = v.to_string();
                        s.update(cx, |s, cx| s.set_value(v, window, cx));
                    }
                }
                FieldInput::Area(s) => {
                    if let Some((_, v)) = texts.iter().find(|(n, _)| *n == field.input.name) {
                        let v = v.to_string();
                        s.update(cx, |s, cx| s.set_value(v, window, cx));
                    }
                }
                FieldInput::Select(_) => field.value = FieldInput::Select(select),
            }
        }
        self.submit_form(window, cx);
    }

    /// Removes the trigger word and returns where it was.
    fn take_trigger(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Option<usize> {
        let menu = self.menu.take()?;
        let state = self.input.read(cx);
        let value = state.value().to_string();
        let cursor = state.cursor().min(value.len());
        // The caret may have moved since the menu opened (a move is no text
        // change): only the trigger still before it is removed, never other
        // text.
        if trigger_at(&value, cursor).as_ref() != Some(&menu.trigger) {
            return None;
        }
        let start = menu.trigger.start;
        let new = format!("{}{}", &value[..start], &value[cursor..]);
        self.input.update(cx, |s, cx| {
            s.set_value(new, window, cx);
            s.set_selected_range(start..start, cx);
        });
        Some(start)
    }

    fn choose(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(menu) = &self.menu else {
            return;
        };
        let query = menu.trigger.query.clone();
        match menu.trigger.kind {
            TriggerKind::Prompt => {
                let prompt = self.composer.read(cx).prompts.as_deref().and_then(|p| {
                    match_prompts(&query, p, MENU_LIMIT)
                        .get(index)
                        .map(|p| (*p).clone())
                });
                let Some(prompt) = prompt else {
                    return;
                };
                let Some(at) = self.take_trigger(window, cx) else {
                    return;
                };
                self.render_prompt(prompt, at, BTreeMap::new(), window, cx);
            }
            TriggerKind::Model => {
                let model = self.composer.read(cx).models.as_ref().and_then(|m| {
                    match_models(&query, &m.models, MENU_LIMIT)
                        .get(index)
                        .map(|m| (*m).clone())
                });
                self.take_trigger(window, cx);
                if let Some(model) = model {
                    self.composer
                        .update(cx, |c, cx| c.set_mention(Some(model), cx));
                }
            }
            TriggerKind::Knowledge => {
                let item = self.composer.read(cx).knowledge_results.get(index).cloned();
                self.take_trigger(window, cx);
                if let Some(item) = item {
                    self.composer.update(cx, |c, cx| c.add_knowledge(item, cx));
                }
            }
        }
        self.focus_input(window, cx);
        cx.notify();
    }

    /// `prompts.render`: inserts the text, or asks for the fields first.
    fn render_prompt(
        &mut self,
        prompt: PromptSummary,
        at: usize,
        values: BTreeMap<String, String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let clipboard = prompt
            .uses_clipboard
            .then(|| cx.read_from_clipboard().and_then(|c| c.text()))
            .flatten();
        let request = RenderPrompt {
            command: prompt.command.clone(),
            values,
            clipboard,
        };
        if let Some(form) = &mut self.form {
            form.busy = true;
        }
        self.prompt_request += 1;
        let request_id = self.prompt_request;
        let scope = self.composer.read(cx).scope();
        // The draft as it was: the text goes where the trigger was only if
        // the draft has not changed since, else at its end.
        let draft = self.text(cx);
        let task = self
            .composer
            .update(cx, |c, cx| c.render_prompt(request, cx));
        cx.spawn_in(window, async move |this, cx| {
            let result = task.await;
            let _ = this.update_in(cx, |this, window, cx| match result {
                // Cancelled, another prompt chosen since, or another account's.
                _ if this.prompt_request != request_id
                    || this.composer.read(cx).scope() != scope => {}
                Ok(rendered) => {
                    let at = if this.text(cx) == draft {
                        at
                    } else {
                        this.text(cx).len()
                    };
                    this.rendered(prompt, at, rendered, window, cx)
                }
                Err(e) => {
                    log::warn!("prompts.render: {e}");
                    match &mut this.form {
                        Some(form) => {
                            form.busy = false;
                            form.error = Some(cx.l10n().desktop_something_went_wrong());
                        }
                        None => {
                            this.form = Some(PromptForm {
                                prompt,
                                at,
                                fields: vec![],
                                error: Some(cx.l10n().desktop_something_went_wrong()),
                                busy: false,
                            })
                        }
                    }
                    cx.notify();
                }
            });
        })
        .detach();
    }

    fn rendered(
        &mut self,
        prompt: PromptSummary,
        at: usize,
        rendered: RenderedPrompt,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if rendered.inputs.is_empty() {
            self.form = None;
            self.insert_at(at, &rendered.content, window, cx);
            return;
        }
        let fields = rendered
            .inputs
            .into_iter()
            .map(|input| {
                let value = match input.r#type.as_str() {
                    "select" => FieldInput::Select(
                        input
                            .default_value
                            .as_ref()
                            .and_then(|d| input.options.iter().position(|o| o == d))
                            .unwrap_or(0),
                    ),
                    "textarea" => {
                        let default = input.default_value.clone().unwrap_or_default();
                        let placeholder = input.placeholder.clone().unwrap_or_default();
                        FieldInput::Area(cx.new(|cx| {
                            let mut s = TextareaState::new(window, cx)
                                .auto_grow(2, 6)
                                .placeholder(placeholder);
                            s.set_value(default, window, cx);
                            s
                        }))
                    }
                    _ => {
                        let default = input.default_value.clone().unwrap_or_default();
                        let placeholder = input.placeholder.clone().unwrap_or_default();
                        FieldInput::Text(cx.new(|cx| {
                            let mut s = InputState::new(window, cx).placeholder(placeholder);
                            s.set_value(default, window, cx);
                            s
                        }))
                    }
                };
                PromptField { input, value }
            })
            .collect::<Vec<_>>();
        if let Some(FieldInput::Text(s)) = fields.first().map(|f| &f.value) {
            s.update(cx, |s, cx| s.focus(window, cx));
        }
        self.form = Some(PromptForm {
            prompt,
            at,
            fields,
            error: None,
            busy: false,
        });
        cx.notify();
    }

    /// Submits the fill-in form.
    pub fn submit_form(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(form) = &mut self.form else {
            return;
        };
        let mut values = BTreeMap::new();
        for field in &form.fields {
            let value = match &field.value {
                FieldInput::Text(s) => s.read(cx).value().to_string(),
                FieldInput::Area(s) => s.read(cx).value().to_string(),
                FieldInput::Select(i) => field.input.options.get(*i).cloned().unwrap_or_default(),
            };
            if field.input.required && value.trim().is_empty() {
                form.error = Some(cx.l10n().desktop_field_required(&field.input.label));
                cx.notify();
                return;
            }
            values.insert(field.input.name.clone(), value);
        }
        let (prompt, at) = (form.prompt.clone(), form.at);
        self.render_prompt(prompt, at, values, window, cx);
    }

    pub fn cancel_form(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.form = None;
        self.prompt_request += 1;
        self.focus_input(window, cx);
        cx.notify();
    }

    fn insert_at(&mut self, at: usize, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        let value = self.text(cx);
        let mut at = at.min(value.len());
        while !value.is_char_boundary(at) {
            at -= 1;
        }
        let new = format!("{}{text}{}", &value[..at], &value[at..]);
        let caret = at + text.len();
        self.input.update(cx, |s, cx| {
            s.set_value(new, window, cx);
            s.set_selected_range(caret..caret, cx);
            s.focus(window, cx);
        });
        cx.notify();
    }

    // ── Model picker ────────────────────────────────────────────────────

    pub fn picker_open(&self) -> bool {
        self.picker.is_some()
    }

    fn picker_models(&self, cx: &App) -> Vec<ModelSummary> {
        let Some(picker) = self.picker.as_ref().or(self.leaving_picker.as_ref()) else {
            return vec![];
        };
        let query = picker.search.read(cx).value().to_string();
        let Some(list) = &self.composer.read(cx).models else {
            return vec![];
        };
        let mut models: Vec<ModelSummary> = match_models(&query, &list.models, usize::MAX)
            .into_iter()
            .cloned()
            .collect();
        // Pinned first, as the server orders them otherwise.
        models.sort_by_key(|m| !m.pinned);
        models
    }

    /// Opens the model picker (⇧⌘M, the palette's "Choose model").
    pub fn open_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.picker.is_some() {
            return;
        }
        self.leaving_picker = None;
        let placeholder = cx.l10n().desktop_search_models();
        let search = cx.new(|cx| InputState::new(window, cx).placeholder(placeholder));
        search.update(cx, |s, cx| s.focus(window, cx));
        let selected = self
            .composer
            .read(cx)
            .selected_model()
            .map(|m| m.id.clone());
        self._subscriptions
            .push(cx.subscribe(&search, |this, _, e: &InputEvent, cx| {
                if matches!(e, InputEvent::Change)
                    && let Some(p) = &mut this.picker
                {
                    p.highlighted = 0;
                    cx.notify();
                }
            }));
        self.picker = Some(Picker {
            search,
            highlighted: 0,
        });
        if let Some(id) = selected
            && let Some(i) = self.picker_models(cx).iter().position(|m| m.id == id)
            && let Some(p) = &mut self.picker
        {
            p.highlighted = i;
        }
        self.composer.update(cx, |c, cx| c.refresh_models(cx));
        cx.emit(ChatComposerEvent::PickerChanged);
        cx.notify();
    }

    pub fn close_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(picker) = self.picker.take() {
            self.leaving_picker = Some(picker);
            self.picker_closed_at = Some(std::time::Instant::now());
            self.focus_input(window, cx);
            cx.emit(ChatComposerEvent::PickerChanged);
            cx.notify();
        }
    }

    /// The picker's trigger was clicked: open it, unless that same click
    /// just closed it (its mouse down landed outside the open picker).
    pub fn toggle_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let just_closed = self
            .picker_closed_at
            .is_some_and(|t| t.elapsed() < std::time::Duration::from_millis(300));
        if self.picker.is_some() {
            self.close_picker(window, cx);
        } else if !just_closed {
            self.open_picker(window, cx);
        }
    }

    /// The selected model's name, as the picker's trigger shows it.
    pub fn model_name(&self, cx: &App) -> String {
        self.composer
            .read(cx)
            .selected_model()
            .map(model_label)
            .unwrap_or_else(|| cx.l10n().desktop_shortcut_focus_model_picker())
    }

    /// The + menu: Attach Files, then the switches the model allows, each
    /// with a check while on.
    fn show_plus_menu(
        &mut self,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        use gpui_kit::component::native_menu::NativeMenu;
        let l10n = cx.l10n().clone();
        let store = self.composer.read(cx);
        let options = store.options.clone();
        let (web, image) = (store.web_search, store.image_generation);
        let tool_ids = store.tool_ids.clone();
        // The entries as drawn, to measure the menu (`None`: a separator).
        let mut entries: Vec<Option<String>> = vec![];
        let attach = format!("{}\u{2026}", l10n.desktop_attach_files());
        entries.push(Some(attach.clone()));
        let mut menu = NativeMenu::new().menu(attach, Box::new(ComposerMenu::AttachFiles));
        let has_switches = options.web_search
            || options.image_generation
            || !options.tools.is_empty()
            || !options.mcp_tools.is_empty();
        if has_switches {
            entries.push(None);
            menu = menu.separator();
        }
        if options.web_search {
            entries.push(Some(l10n.web_search()));
            menu = menu.menu_with_check(l10n.web_search(), web, Box::new(ComposerMenu::WebSearch));
        }
        if options.image_generation {
            entries.push(Some(l10n.desktop_image_generation()));
            menu = menu.menu_with_check(
                l10n.desktop_image_generation(),
                image,
                Box::new(ComposerMenu::ImageGeneration),
            );
        }
        for tool in options.tools.iter().chain(&options.mcp_tools) {
            entries.push(Some(tool.name.to_string()));
            menu = menu.menu_with_check(
                tool.name.clone(),
                tool_ids.contains(&tool.id),
                Box::new(ComposerMenu::Tool(tool.id.clone())),
            );
        }
        // The menu's action goes to the focused element's path: keep focus
        // in the composer so its handler hears it.
        self.focus_input(window, cx);
        menu.show(self.plus_menu_origin(&entries, position), window, cx);
    }

    /// Where the + menu's top-left goes: over the button, its bottom edge
    /// ~6 pt above the composer's top (above its chips and attachments, so
    /// a switch's chip stays in view) and its leading edge on the button's,
    /// so it opens upward as a bottom bar's menus do (Messages), off the
    /// field and inside the window. Without the button's bounds or the menu's
    /// height, at the click.
    fn plus_menu_origin(
        &self,
        entries: &[Option<String>],
        click: gpui_kit::Point<gpui_kit::Pixels>,
    ) -> gpui_kit::Point<gpui_kit::Pixels> {
        #[cfg(target_os = "macos")]
        {
            let entries: Vec<Option<&str>> = entries.iter().map(|e| e.as_deref()).collect();
            if let (Some(b), Some(height)) = (
                self.plus_bounds.get(),
                crate::shell::macos::menu_height(&entries),
            ) {
                // AppKit draws the menu ~3 pt below the origin it is given:
                // 9 pt over the frame's top leaves it ~6 pt clear. (The
                // button sits 6 pt inside the frame when nothing is above
                // the field.)
                let top = self
                    .frame_bounds
                    .get()
                    .map(|f| f.top() - px(9.))
                    .unwrap_or(b.top() - px(15.));
                return gpui_kit::point(b.left(), top - px(height as f32));
            }
        }
        #[cfg(not(target_os = "macos"))]
        let _ = entries;
        click
    }

    fn on_menu(&mut self, action: &ComposerMenu, window: &mut Window, cx: &mut Context<Self>) {
        let composer = self.composer.clone();
        match action {
            ComposerMenu::AttachFiles => self.pick_files(window, cx),
            ComposerMenu::WebSearch => composer.update(cx, |c, cx| c.toggle_web_search(cx)),
            ComposerMenu::ImageGeneration => {
                composer.update(cx, |c, cx| c.toggle_image_generation(cx))
            }
            ComposerMenu::Tool(id) => composer.update(cx, |c, cx| c.toggle_tool(id, cx)),
        }
    }

    fn choose_model(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let id = id.to_string();
        self.composer.update(cx, |c, cx| {
            c.set_mention(None, cx);
            c.select_model(&id, cx);
        });
        self.close_picker(window, cx);
    }

    // ── Attachments ─────────────────────────────────────────────────────

    fn pick_files(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let prompt = cx.l10n().desktop_attach_files();
        let paths = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: true,
            prompt: Some(prompt.into()),
        });
        let composer = self.composer.clone();
        cx.spawn_in(window, async move |_, cx| {
            if let Ok(Ok(Some(paths))) = paths.await {
                composer.update(cx, |c, cx| c.add_paths(&paths, cx));
            }
        })
        .detach();
    }

    /// Files dropped onto the composer.
    pub fn drop_paths(&mut self, paths: &ExternalPaths, cx: &mut Context<Self>) {
        let paths: Vec<_> = paths.paths().to_vec();
        self.composer.update(cx, |c, cx| c.add_paths(&paths, cx));
    }
}

fn toggle_chip(
    id: impl Into<ElementId>,
    ic: IconName,
    label: SharedString,
    on: bool,
    t: &ConduitTheme,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    let r = t.roles;
    let fg = if on { r.text } else { r.text_subtle };
    div()
        .id(id)
        .role(Role::Switch)
        .aria_label(label.clone())
        .aria_toggled(if on {
            gpui_kit::Toggled::True
        } else {
            gpui_kit::Toggled::False
        })
        .h(px(28.))
        .px(px(9.))
        .flex()
        .flex_none()
        .items_center()
        .gap(px(5.))
        .rounded_full()
        .border_1()
        .border_color(if on { r.border_strong } else { r.border })
        .when(on, |d| d.bg(r.selected))
        .hover(|s| s.bg(r.hover))
        .active(|s| s.bg(pressed_fill(if on { r.selected } else { r.hover }, t)))
        .cursor_pointer()
        .text_size(px(t.metrics.small))
        .font_weight(FontWeight::MEDIUM)
        .text_color(fg)
        .child(icon(ic, 13., if on { r.selected_icon } else { fg }))
        .child(label)
}

/// What a chip's remove button does.
type RemoveFn = Rc<dyn Fn(&mut Window, &mut App)>;

fn chip(
    id: String,
    label: String,
    t: &ConduitTheme,
    on_remove: RemoveFn,
    remove_label: String,
) -> AnyElement {
    let r = t.roles;
    div()
        .id(ElementId::Name(id.clone().into()))
        .h(px(26.))
        .pl(px(9.))
        .pr(px(3.))
        .flex()
        .items_center()
        .gap(px(4.))
        .rounded_full()
        .bg(r.selected)
        .text_size(px(t.metrics.small))
        .text_color(r.text)
        .child(SharedString::from(label))
        .child(
            IconButton::new(
                ElementId::Name(format!("{id}-remove").into()),
                IconName::X,
                remove_label,
            )
            .size(20., 11.)
            .on_click(Rc::new(move |_, window, cx| on_remove(window, cx))),
        )
        .into_any_element()
}

fn attachment_view(
    a: &Attachment,
    composer: &Entity<ComposerStore>,
    t: &ConduitTheme,
    cx: &App,
) -> AnyElement {
    let r = t.roles;
    let l10n = cx.l10n().clone();
    let progress = a.progress();
    let failed = matches!(a.state, UploadState::Failed(_));
    let detail = match (&a.state, progress) {
        (UploadState::Failed(_), _) => l10n.desktop_attachment_failed(&a.name),
        (_, Some(p)) => l10n.desktop_uploading_percent((p * 100.) as i64),
        _ => human_size(a.size),
    };
    let id = a.local_id;
    let composer = composer.clone();
    let thumb: AnyElement = match &a.image {
        Some(image) => img(image.clone())
            .size(px(32.))
            .rounded(px(6.))
            .into_any_element(),
        None => icon_tile(
            IconName::FileText,
            32.,
            with_alpha(r.text, if t.dark { 0.12 } else { 0.06 }),
            r.text_subtle,
            6.,
        )
        .into_any_element(),
    };
    div()
        .id(ElementId::NamedInteger("composer-attachment".into(), id))
        .role(Role::Group)
        .aria_label(SharedString::from(format!("{}, {detail}", a.name)))
        .relative()
        .h(px(44.))
        .w(px(210.))
        .pl(px(5.))
        .pr(px(6.))
        .flex()
        .items_center()
        .gap(px(8.))
        .rounded(t.card_radius())
        .border_1()
        .border_color(if failed { r.danger } else { r.border })
        .bg(conduit_components::views::kit::on_raised_fill(t))
        .overflow_hidden()
        .child(thumb)
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .child(
                    div()
                        .truncate()
                        .text_size(px(t.metrics.small))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(r.text)
                        .child(SharedString::from(a.name.clone())),
                )
                .child(
                    div()
                        .truncate()
                        .text_size(px(t.metrics.caption))
                        .text_color(if failed { r.danger } else { r.text_subtle })
                        .child(SharedString::from(detail)),
                ),
        )
        .child(
            IconButton::new(
                ElementId::NamedInteger("remove-attachment".into(), id),
                IconName::X,
                l10n.desktop_remove_attachment(&a.name),
            )
            .size(20., 12.)
            .on_click(Rc::new(move |_, _, cx| {
                composer.update(cx, |c, cx| c.remove_attachment(id, cx));
            })),
        )
        .when_some(progress, |d, p| {
            d.child(
                div()
                    .absolute()
                    .left_0()
                    .bottom_0()
                    .h(px(2.))
                    .w(px(210. * p))
                    .bg(r.checked),
            )
        })
        .into_any_element()
}

fn human_size(bytes: u64) -> String {
    match bytes {
        b if b >= 1024 * 1024 => format!("{:.1} MB", b as f64 / (1024. * 1024.)),
        b if b >= 1024 => format!("{} KB", b / 1024),
        b => format!("{b} B"),
    }
}

impl ChatComposer {
    fn menu_view(&self, t: &ConduitTheme, cx: &mut Context<Self>) -> Option<AnyElement> {
        let menu = self.menu.as_ref()?;
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let m = t.metrics;
        let c = self.composer.read(cx);
        let (label, entries): (String, Vec<(String, String)>) = match menu.trigger.kind {
            TriggerKind::Prompt => (
                l10n.desktop_prompt_menu(),
                c.prompts
                    .as_deref()
                    .map(|p| {
                        match_prompts(&menu.trigger.query, p, MENU_LIMIT)
                            .into_iter()
                            .map(|p| (p.command.clone(), p.title.clone()))
                            .collect()
                    })
                    .unwrap_or_default(),
            ),
            TriggerKind::Model => (
                l10n.desktop_model_menu(),
                c.models
                    .as_ref()
                    .map(|list| {
                        match_models(&menu.trigger.query, &list.models, MENU_LIMIT)
                            .into_iter()
                            .map(|m| (model_label(m), m.description.clone().unwrap_or_default()))
                            .collect()
                    })
                    .unwrap_or_default(),
            ),
            TriggerKind::Knowledge => (
                l10n.desktop_knowledge_menu(),
                c.knowledge_results
                    .iter()
                    .take(MENU_LIMIT)
                    .map(|k| (k.name.clone(), k.description.clone().unwrap_or_default()))
                    .collect(),
            ),
        };
        let empty = match menu.trigger.kind {
            TriggerKind::Prompt => l10n.desktop_no_prompts_match(),
            TriggerKind::Model => l10n.desktop_no_models_available(),
            TriggerKind::Knowledge => l10n.desktop_no_knowledge_match(),
        };
        let total = entries.len();
        let highlighted = menu.highlighted;
        Some(
            div()
                .id("composer-menu")
                .role(Role::Menu)
                .aria_label(SharedString::from(label.clone()))
                .absolute()
                .bottom(gpui_kit::relative(1.))
                .left_0()
                .mb(px(6.))
                .w(px(360.))
                .p(px(6.))
                .flex()
                .flex_col()
                .rounded(t.overlay_radius())
                .border_1()
                .border_color(r.border_strong)
                .bg(r.overlay)
                .shadow(overlay_shadow(t))
                .occlude()
                .child(
                    div()
                        .px(px(8.))
                        .pt(px(4.))
                        .pb(px(4.))
                        .text_size(px(m.caption))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text_subtle)
                        .child(SharedString::from(label)),
                )
                .when(total == 0, |d| {
                    d.child(
                        div()
                            .px(px(8.))
                            .py(px(6.))
                            .text_size(px(m.control))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(empty)),
                    )
                })
                .children(entries.into_iter().enumerate().map(|(i, (title, detail))| {
                    div()
                        .id(ElementId::NamedInteger(
                            "composer-menu-item".into(),
                            i as u64,
                        ))
                        .role(Role::MenuItem)
                        .aria_label(SharedString::from(title.clone()))
                        .aria_selected(i == highlighted)
                        .aria_position_in_set(i + 1)
                        .aria_size_of_set(total)
                        .min_h(px(m.row_height + 6.))
                        .px(px(8.))
                        .py(px(3.))
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .rounded(px(7.))
                        .when(i == highlighted, |d| d.bg(r.overlay_hover))
                        .cursor_pointer()
                        .child(
                            div()
                                .flex_none()
                                .text_size(px(m.control))
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(r.text)
                                .child(SharedString::from(title)),
                        )
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .truncate()
                                .text_size(px(m.small))
                                .text_color(r.text_subtle)
                                .child(SharedString::from(detail)),
                        )
                        .on_click(
                            cx.listener(move |this, _, window, cx| this.choose(i, window, cx)),
                        )
                }))
                .into_any_element(),
        )
    }

    fn form_view(
        &self,
        t: &ConduitTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let form = self.form.as_ref()?;
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let m = t.metrics;
        let title = l10n.desktop_prompt_fill(&form.prompt.title);
        let fields: Vec<AnyElement> = form
            .fields
            .iter()
            .enumerate()
            .map(|(fi, f)| {
                let label = if f.input.required {
                    format!("{} *", f.input.label)
                } else {
                    f.input.label.clone()
                };
                let control: AnyElement = match &f.value {
                    FieldInput::Text(s) => conduit_components::views::kit::field_frame(
                        s.read(cx).focus_handle(cx).is_focused(window),
                        m.control_height + 4.,
                        cx,
                    )
                    .child(
                        Input::new(s)
                            .appearance(false)
                            .bordered(false)
                            .px_0()
                            .text_size(px(m.control))
                            .aria_label(SharedString::from(f.input.label.clone())),
                    )
                    .into_any_element(),
                    FieldInput::Area(s) => div()
                        .px(px(8.))
                        .py(px(4.))
                        .rounded(t.control_radius())
                        .border_1()
                        .border_color(r.border_strong)
                        .child(
                            Textarea::new(s)
                                .appearance(false)
                                .bordered(false)
                                .text_size(px(m.control))
                                .aria_label(SharedString::from(f.input.label.clone())),
                        )
                        .into_any_element(),
                    FieldInput::Select(selected) => {
                        // One key-view stop for the group, as AppKit's: the
                        // chosen option has focus, the arrows choose.
                        let count = f.input.options.len();
                        let group = format!("prompt-select-{fi}");
                        let this = cx.entity().downgrade();
                        let choose: conduit_components::views::kit::SelectHandler =
                            Rc::new(move |oi, _, cx| {
                                let _ = this.update(cx, |this, cx| {
                                    if let Some(form) = &mut this.form
                                        && let Some(field) = form.fields.get_mut(fi)
                                    {
                                        field.value = FieldInput::Select(oi);
                                        cx.notify();
                                    }
                                });
                            });
                        div()
                            .id(ElementId::NamedInteger("prompt-select".into(), fi as u64))
                            .role(Role::RadioGroup)
                            .aria_label(SharedString::from(f.input.label.clone()))
                            .radio_group(*selected, count, Some(choose.clone()), cx)
                            .flex()
                            .flex_wrap()
                            .gap(px(6.))
                            .children(f.input.options.iter().enumerate().map(|(oi, o)| {
                                let on = oi == *selected;
                                let choose = choose.clone();
                                div()
                                    .id(radio_option_id(&group, oi, on))
                                    .role(Role::RadioButton)
                                    .aria_label(SharedString::from(o.clone()))
                                    .aria_toggled(if on {
                                        gpui_kit::Toggled::True
                                    } else {
                                        gpui_kit::Toggled::False
                                    })
                                    .aria_position_in_set(oi + 1)
                                    .aria_size_of_set(count)
                                    .radio_option_outline(on, 14., cx)
                                    .cursor_pointer()
                                    .on_click(move |_, window, cx| choose(oi, window, cx))
                                    .child(
                                        div()
                                            .h(px(28.))
                                            .px(px(10.))
                                            .flex()
                                            .items_center()
                                            .rounded_full()
                                            .border_1()
                                            .border_color(if on {
                                                r.border_strong
                                            } else {
                                                r.border
                                            })
                                            .when(on, |d| d.bg(r.selected))
                                            .text_size(px(m.small))
                                            .text_color(if on { r.text } else { r.text_subtle })
                                            .child(SharedString::from(o.clone())),
                                    )
                            }))
                            .into_any_element()
                    }
                };
                div()
                    .flex()
                    .flex_col()
                    .gap(px(4.))
                    .child(
                        div()
                            .text_size(px(m.small))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(r.text)
                            .child(SharedString::from(label)),
                    )
                    .child(control)
                    .into_any_element()
            })
            .collect();
        Some(
            div()
                .id("prompt-form")
                .role(Role::Dialog)
                .aria_label(SharedString::from(title.clone()))
                .w_full()
                .p(px(12.))
                .flex()
                .flex_col()
                .gap(px(10.))
                .rounded(px(14.))
                .border_1()
                .border_color(r.border_strong)
                .bg(r.overlay)
                .shadow(overlay_shadow(t))
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(px(m.control + 1.))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(r.text)
                                .child(SharedString::from(title)),
                        )
                        .child(
                            div()
                                .text_size(px(m.small))
                                .text_color(r.text_subtle)
                                .child(SharedString::from(l10n.prompt_variables_description())),
                        ),
                )
                .children(fields)
                .when_some(form.error.clone(), |d, e| {
                    d.child(
                        div()
                            .text_size(px(m.small))
                            .text_color(r.danger)
                            .child(SharedString::from(e)),
                    )
                })
                .child(
                    div()
                        .flex()
                        .justify_end()
                        .gap(px(6.))
                        .child(
                            conduit_components::views::kit::Button::new(
                                "prompt-cancel",
                                l10n.cancel(),
                            )
                            .on_click(Rc::new({
                                let weak = cx.entity().downgrade();
                                move |_, window, cx| {
                                    let _ = weak.update(cx, |c, cx| c.cancel_form(window, cx));
                                }
                            })),
                        )
                        .child(
                            conduit_components::views::kit::Button::new(
                                "prompt-insert",
                                l10n.desktop_prompt_insert(),
                            )
                            .primary()
                            .disabled(form.busy)
                            .on_click(Rc::new({
                                let weak = cx.entity().downgrade();
                                move |_, window, cx| {
                                    let _ = weak.update(cx, |c, cx| c.submit_form(window, cx));
                                }
                            })),
                        ),
                )
                .into_any_element(),
        )
    }

    /// The model picker, hanging from its trigger: it fades in over 120 ms,
    /// dropping 4 pt from the trigger on a short-tailed ease-out, and out
    /// over an even 100 ms (taking nothing while it goes); under Reduce
    /// Motion it only crossfades.
    pub fn picker_view(
        &self,
        t: &ConduitTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let open = self.picker.is_some();
        let shown = motion::appear(
            "model-picker-motion",
            open,
            specs::POPOVER_IN,
            specs::POPOVER_OUT,
            window,
            cx,
        );
        if !shown.visible {
            return None;
        }
        let menu = self.picker_menu(t, cx)?;
        let drop = if self.inline_model { 4. } else { -4. };
        Some(
            div()
                .relative()
                .top(px(shown.offset(drop)))
                .opacity(shown.opacity)
                .child(menu)
                .when(!open, |d| {
                    d.child(
                        div()
                            .id("model-menu-leaving")
                            .absolute()
                            .inset_0()
                            .occlude(),
                    )
                })
                .into_any_element(),
        )
    }

    fn picker_menu(&self, t: &ConduitTheme, cx: &mut Context<Self>) -> Option<AnyElement> {
        let picker = self.picker.as_ref().or(self.leaving_picker.as_ref())?;
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let m = t.metrics;
        let models = self.picker_models(cx);
        let selected = self
            .composer
            .read(cx)
            .selected_model()
            .map(|m| m.id.clone());
        let total = models.len();
        let weak = cx.entity().downgrade();
        Some(
            div()
                .id("model-menu")
                .role(Role::Dialog)
                .aria_label(SharedString::from(l10n.desktop_model_menu()))
                .w(px(320.))
                .max_h(px(420.))
                .p(px(6.))
                .flex()
                .flex_col()
                .rounded(t.overlay_radius())
                .border_1()
                .border_color(r.border_strong)
                .bg(r.overlay)
                .shadow(overlay_shadow(t))
                .occlude()
                .on_mouse_down_out(move |_, window, cx| {
                    let _ = weak.update(cx, |c, cx| c.close_picker(window, cx));
                })
                .child(
                    div()
                        .h(px(m.control_height + 4.))
                        .mx(px(2.))
                        .mb(px(4.))
                        .px(px(8.))
                        .flex()
                        .items_center()
                        .gap(px(6.))
                        .rounded(px(7.))
                        .bg(with_alpha(r.text, if t.dark { 0.08 } else { 0.05 }))
                        .child(icon(IconName::Search, 13., r.text_faint))
                        .child(
                            div().flex_1().child(
                                Input::new(&picker.search)
                                    .appearance(false)
                                    .bordered(false)
                                    .px_0()
                                    .text_size(px(m.control))
                                    .aria_label(SharedString::from(l10n.desktop_search_models())),
                            ),
                        ),
                )
                .when(total == 0, |d| {
                    d.child(
                        div()
                            .px(px(8.))
                            .py(px(6.))
                            .text_size(px(m.control))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(l10n.desktop_no_models_available())),
                    )
                })
                .child(
                    div()
                        .id("model-menu-list")
                        .role(Role::ListBox)
                        .aria_label(SharedString::from(l10n.desktop_model_menu()))
                        .flex()
                        .flex_col()
                        .overflow_y_scroll()
                        .children(models.into_iter().enumerate().map(|(i, model)| {
                            let on = selected.as_deref() == Some(model.id.as_str());
                            let hot = i == picker.highlighted;
                            let id = model.id.clone();
                            let provider = model.connection.clone().unwrap_or_default();
                            // As the palette's rows: the highlighted one is
                            // the selected option (VoiceOver follows it as the
                            // arrows move), the model in use is checked.
                            div()
                                .id(ElementId::Name(format!("model-{}", model.id).into()))
                                .role(Role::ListBoxOption)
                                .aria_label(SharedString::from(model_label(&model)))
                                .aria_selected(hot)
                                .aria_toggled(if on {
                                    gpui_kit::Toggled::True
                                } else {
                                    gpui_kit::Toggled::False
                                })
                                .aria_position_in_set(i + 1)
                                .aria_size_of_set(total)
                                .min_h(px(m.row_height + 10.))
                                .px(px(8.))
                                .flex()
                                .flex_none()
                                .items_center()
                                .gap(px(10.))
                                .rounded(px(7.))
                                .when(hot, |d| d.bg(r.overlay_hover))
                                .hover(|s| s.bg(r.overlay_hover))
                                .cursor_pointer()
                                .child(icon(
                                    if model.pinned {
                                        IconName::Pin
                                    } else {
                                        IconName::Sparkles
                                    },
                                    14.,
                                    r.text_subtle,
                                ))
                                .child(
                                    div()
                                        .flex_1()
                                        .min_w_0()
                                        .flex()
                                        .flex_col()
                                        .child(
                                            div()
                                                .truncate()
                                                .text_size(px(m.control))
                                                .font_weight(FontWeight::MEDIUM)
                                                .text_color(r.text)
                                                .child(SharedString::from(model.name.clone())),
                                        )
                                        .when(!provider.is_empty(), |d| {
                                            d.child(
                                                div()
                                                    .truncate()
                                                    .text_size(px(m.caption))
                                                    .text_color(r.text_subtle)
                                                    .child(SharedString::from(provider)),
                                            )
                                        }),
                                )
                                .when(on, |d| d.child(icon(IconName::Check, 15., r.selected_icon)))
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    this.choose_model(&id, window, cx)
                                }))
                        })),
                )
                .into_any_element(),
        )
    }
}

/// Where ↑ or ↓ takes a menu's highlight from `highlighted` of `len` rows:
/// one row on, wrapping from the last to the first and back, as AppKit's
/// menus do.
pub fn menu_step(key: &str, highlighted: usize, len: usize) -> usize {
    if len == 0 {
        return 0;
    }
    let at = highlighted.min(len - 1);
    match key {
        "up" => (at + len - 1) % len,
        "down" => (at + 1) % len,
        _ => at,
    }
}

impl Render for ChatComposer {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let m = t.metrics;
        let focused = self.input.read(cx).focus_handle(cx).is_focused(window);
        let can_send = self.can_send(cx);
        let composer = self.composer.clone();
        let store = composer.read(cx);
        let attachments: Vec<AnyElement> = store
            .attachments
            .iter()
            .map(|a| attachment_view(a, &composer, &t, cx))
            .collect();
        let mention = store.mention.clone();
        let knowledge: Vec<KnowledgeSummary> = store.knowledge.clone();
        let options = store.options.clone();
        let (web_search, image_generation) = (store.web_search, store.image_generation);
        let tool_ids = store.tool_ids.clone();
        let model_name = store
            .selected_model()
            .map(model_label)
            .unwrap_or_else(|| l10n.desktop_shortcut_focus_model_picker());

        let frame = conduit_components::views::composer::composer_frame(&t);
        // In Quick Ask the panel is itself raised, so its composer sits a
        // step above it on the dark ramp (#232323 on #181818).
        let bg = if self.inline_model {
            conduit_components::views::kit::on_raised_fill(&t)
        } else {
            frame.fill
        };
        let shadows = frame.shadow;

        let send: AnyElement = if self.streaming {
            IconButton::new("stop", IconName::Square, l10n.desktop_stop_generating())
                .size(32., 13.)
                .filled(r.primary, r.primary_foreground)
                .shortcut(conduit_components::views::focus::hints(cx).stop)
                .on_click(Rc::new({
                    let weak = cx.entity().downgrade();
                    move |_, _, cx| {
                        let _ = weak.update(cx, |_, cx| cx.emit(ChatComposerEvent::Stop));
                    }
                }))
                .into_any_element()
        } else {
            // Waiting on the connection: dimmed, its tooltip saying why
            // (the state itself shows once, in the window's pill).
            let waits = self.offline_reason.clone().filter(|_| self.offline);
            IconButton::new("send", IconName::ArrowUp, l10n.send())
                .size(32., 17.)
                .when_some(waits.clone(), |b, why| b.tooltip(why))
                .shortcut(if waits.is_some() {
                    None
                } else {
                    conduit_components::views::focus::hints(cx).send
                })
                // Nothing to send: out of the key loop (Tab passes it).
                .disabled(!can_send)
                .filled(
                    if can_send {
                        r.primary
                    } else {
                        with_alpha(r.text, if t.dark { 0.16 } else { 0.10 })
                    },
                    if can_send {
                        r.primary_foreground
                    } else {
                        r.text_faint
                    },
                )
                .on_click(Rc::new({
                    let weak = cx.entity().downgrade();
                    move |_, window, cx| {
                        let _ = weak.update(cx, |c, cx| c.submit(window, cx));
                    }
                }))
                .into_any_element()
        };

        // Chips for this message's `@` model and `#` knowledge.
        let mut chips: Vec<AnyElement> = vec![];
        if let Some(model) = &mention {
            let composer = composer.clone();
            chips.push(chip(
                "mention".into(),
                l10n.desktop_answer_with(&model_label(model)),
                &t,
                Rc::new(move |_, cx| composer.update(cx, |c, cx| c.set_mention(None, cx))),
                l10n.desktop_clear_mention(),
            ));
        }
        for k in &knowledge {
            let composer = composer.clone();
            let id = k.id.clone();
            chips.push(chip(
                format!("knowledge-{}", k.id),
                l10n.desktop_knowledge_chip(&k.name),
                &t,
                Rc::new(move |_, cx| composer.update(cx, |c, cx| c.remove_knowledge(&id, cx))),
                l10n.desktop_remove_attachment(&k.name),
            ));
        }

        let paste_store = composer.clone();
        let textarea = Textarea::new(&self.input)
            .appearance(false)
            .bordered(false)
            .text_size(px(m.body))
            .aria_label(l10n.desktop_message_field())
            .accessibility_id("composer-input")
            .on_paste(move |item, _, cx| {
                let mut used = false;
                for entry in item.entries() {
                    match entry {
                        ClipboardEntry::Image(image) => {
                            let image = image.clone();
                            paste_store.update(cx, |c, cx| c.add_image(&image, cx));
                            used = true;
                        }
                        ClipboardEntry::ExternalPaths(paths) => {
                            let paths = paths.paths().to_vec();
                            paste_store.update(cx, |c, cx| c.add_paths(&paths, cx));
                            used = true;
                        }
                        ClipboardEntry::String(_) => {}
                    }
                }
                used
            });

        let menu = self.menu_view(&t, cx);
        let picker = if self.inline_model {
            self.picker_view(&t, window, cx).map(|p| {
                div()
                    .absolute()
                    .bottom(gpui_kit::relative(1.))
                    .right_0()
                    .mb(px(6.))
                    .child(p)
                    .into_any_element()
            })
        } else {
            None
        };
        let form = self.form_view(&t, window, cx);

        // Switches that are on show as chips, which turn them off; the +
        // menu holds them all, as the phone's attach panel does.
        if options.web_search && web_search {
            let composer = composer.clone();
            chips.push(
                toggle_chip(
                    "toggle-web-search",
                    IconName::Globe,
                    l10n.web_search().into(),
                    true,
                    &t,
                )
                .on_click(move |_, _, cx| composer.update(cx, |c, cx| c.toggle_web_search(cx)))
                .keyboard_control(Ring::Outset(14.), window, cx)
                .into_any_element(),
            );
        }
        if options.image_generation && image_generation {
            let composer = composer.clone();
            chips.push(
                toggle_chip(
                    "toggle-image-generation",
                    IconName::Image,
                    l10n.desktop_image_generation().into(),
                    true,
                    &t,
                )
                .on_click(move |_, _, cx| {
                    composer.update(cx, |c, cx| c.toggle_image_generation(cx))
                })
                .keyboard_control(Ring::Outset(14.), window, cx)
                .into_any_element(),
            );
        }
        for tool in options
            .tools
            .iter()
            .chain(&options.mcp_tools)
            .filter(|tool| tool_ids.contains(&tool.id))
        {
            let composer = composer.clone();
            let id = tool.id.clone();
            chips.push(
                toggle_chip(
                    ElementId::Name(format!("tool-{}", tool.id).into()),
                    IconName::Wrench,
                    tool.name.clone().into(),
                    true,
                    &t,
                )
                .on_click(move |_, _, cx| composer.update(cx, |c, cx| c.toggle_tool(&id, cx)))
                .keyboard_control(Ring::Outset(14.), window, cx)
                .into_any_element(),
            );
        }

        let plus = IconButton::new("attach", IconName::Plus, l10n.desktop_attach_files())
            .size(30., 17.)
            .color(r.text_subtle)
            .on_click(Rc::new({
                let weak = cx.entity().downgrade();
                move |e: &gpui_kit::ClickEvent, window, cx| {
                    let position = e.position();
                    let _ = weak.update(cx, |c, cx| c.show_plus_menu(position, window, cx));
                }
            }));

        div()
            .id("composer-area")
            .track_focus(&self.focus)
            .relative()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(8.))
            .on_action(
                cx.listener(|this, a: &ComposerMenu, window, cx| this.on_menu(a, window, cx)),
            )
            .children(form)
            .child(
                div()
                    .id("composer")
                    .role(Role::Group)
                    .aria_label(SharedString::from(l10n.desktop_composer_label()))
                    .relative()
                    .w_full()
                    .flex()
                    .flex_col()
                    .gap(px(4.))
                    // The phone's composer: a capsule that grows into a
                    // rounded card as lines and attachments are added.
                    .rounded(px(frame.radius))
                    .border_1()
                    .border_color(if focused {
                        r.border_strong
                    } else {
                        frame.border
                    })
                    .bg(bg)
                    .shadow(shadows)
                    .p(px(5.))
                    .child({
                        let at = self.frame_bounds.clone();
                        gpui_kit::canvas(move |b, _, _| at.set(Some(b)), |_, _, _, _| {})
                            .absolute()
                            .top_0()
                            .left_0()
                            .size_full()
                    })
                    .drag_over::<ExternalPaths>(move |style, _, _, _| style.border_color(r.focus))
                    .on_drop(cx.listener(|this, paths: &ExternalPaths, _, cx| {
                        this.drop_paths(paths, cx);
                    }))
                    .when(!attachments.is_empty(), |d| {
                        d.child(
                            div()
                                .flex()
                                .flex_wrap()
                                .gap(px(6.))
                                .px(px(4.))
                                .pt(px(3.))
                                .pb(px(2.))
                                .children(attachments),
                        )
                    })
                    .when(!chips.is_empty(), |d| {
                        d.child(
                            div()
                                .id("composer-features")
                                .role(Role::Group)
                                .aria_label(SharedString::from(l10n.desktop_features()))
                                .flex()
                                .flex_wrap()
                                .gap(px(6.))
                                .px(px(4.))
                                .pt(px(2.))
                                .children(chips),
                        )
                    })
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(4.))
                            .child(div().relative().child(plus).child({
                                let at = self.plus_bounds.clone();
                                // Pinned to the corner: in a block wrapper an
                                // absolute child's static place is below the
                                // button.
                                gpui_kit::canvas(move |b, _, _| at.set(Some(b)), |_, _, _, _| {})
                                    .absolute()
                                    .top_0()
                                    .left_0()
                                    .size_full()
                            }))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .min_h(px(32.))
                                    .px(px(4.))
                                    .py(px(6.))
                                    .flex()
                                    .flex_col()
                                    .justify_center()
                                    .text_size(px(m.body))
                                    .text_color(r.text)
                                    .child(textarea),
                            )
                            .when(self.inline_model && self.new_chat, |d| {
                                d.child(
                                    IconButton::new(
                                        "temporary-chat",
                                        IconName::ClockFading,
                                        l10n.temporary_chat(),
                                    )
                                    .size(30., 16.)
                                    .shortcut(
                                        conduit_components::views::focus::hints(cx).temporary_chat,
                                    )
                                    .active(self.temporary)
                                    .on_click(Rc::new({
                                        let weak = cx.entity().downgrade();
                                        move |_, _, cx| {
                                            let _ = weak.update(cx, |c, cx| {
                                                c.temporary = !c.temporary;
                                                cx.emit(ChatComposerEvent::Temporary(c.temporary));
                                                cx.notify();
                                            });
                                        }
                                    })),
                                )
                            })
                            .when(self.inline_model, |d| {
                                d.child(
                                    div().relative().child(
                                        ModelPickerButton::new(model_name.clone())
                                            .compact()
                                            .open(self.picker.is_some())
                                            .label(l10n.desktop_model_chip(&model_name))
                                            .on_click(Rc::new({
                                                let weak = cx.entity().downgrade();
                                                move |_, window, cx| {
                                                    let _ = weak.update(cx, |c, cx| {
                                                        c.toggle_picker(window, cx)
                                                    });
                                                }
                                            })),
                                    ),
                                )
                            })
                            .when_some(
                                self.offline_word
                                    .clone()
                                    .filter(|_| self.offline && !self.streaming),
                                |d, word| {
                                    // On the send button's centre line, as
                                    // the field's text is.
                                    d.child(
                                        div()
                                            .px(px(4.))
                                            .text_size(px(m.small))
                                            .text_color(r.text_subtle)
                                            .child(SharedString::from(word)),
                                    )
                                },
                            )
                            .child(send),
                    )
                    .children(menu)
                    .children(picker),
            )
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use conduit_components::theme::{ConduitTheme, DesignPrefs, install};
    use gpui_kit::{TestAppContext, VisualTestContext};

    use super::*;
    use crate::l10n::L10n;
    use crate::stores::rpc::fake::FakeDaemon;

    type Seen = Rc<RefCell<Vec<ChatComposerEvent>>>;

    fn composer(cx: &mut TestAppContext) -> (Entity<ChatComposer>, &mut VisualTestContext, Seen) {
        cx.update(|cx| {
            gpui_kit::init(cx);
            install(
                ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
                cx,
            );
            cx.set_global(L10n::new("en"));
            cx.set_global(conduit_components::Strings::default());
        });
        let rpc = FakeDaemon::new().rpc();
        let store = cx.new(|_| ComposerStore::new(rpc, None));
        let seen: Seen = Rc::default();
        let (view, vcx) = cx.add_window_view(|window, cx| ChatComposer::new(store, window, cx));
        vcx.update(|window, cx| {
            let seen = seen.clone();
            cx.subscribe(&view, move |_, e: &ChatComposerEvent, _| {
                seen.borrow_mut().push(e.clone())
            })
            .detach();
            view.update(cx, |c, cx| {
                c.offline = false;
                c.focus_input(window, cx)
            });
            window.draw(cx).clear(cx);
        });
        (view, vcx, seen)
    }

    fn value(view: &Entity<ChatComposer>, cx: &mut VisualTestContext) -> String {
        view.read_with(cx, |c, cx| c.text(cx))
    }

    #[gpui_kit::test]
    fn enter_sends_and_shift_enter_breaks_the_line(cx: &mut TestAppContext) {
        let (view, cx, seen) = composer(cx);
        cx.simulate_input("first line");
        cx.simulate_keystrokes("shift-enter");
        cx.simulate_input("second");
        assert!(seen.borrow().is_empty(), "Shift+Enter does not send");
        assert_eq!(value(&view, cx), "first line\nsecond");
        cx.simulate_keystrokes("enter");
        assert_eq!(
            *seen.borrow(),
            vec![ChatComposerEvent::Submit("first line\nsecond".into())]
        );
        assert_eq!(value(&view, cx), "", "the field clears after sending");
        // An empty field sends nothing.
        cx.simulate_keystrokes("enter");
        assert_eq!(seen.borrow().len(), 1);
    }

    fn select_form(view: &Entity<ChatComposer>, cx: &mut VisualTestContext) {
        view.update(cx, |c, cx| {
            c.form = Some(PromptForm {
                prompt: serde_json::from_value(serde_json::json!({
                    "command": "/tone", "title": "Tone"
                }))
                .unwrap(),
                at: 0,
                fields: vec![PromptField {
                    input: serde_json::from_value(serde_json::json!({
                        "name": "tone", "label": "Tone", "type": "select",
                        "options": ["Calm", "Brisk", "Warm"], "required": false
                    }))
                    .unwrap(),
                    value: FieldInput::Select(0),
                }],
                error: None,
                busy: false,
            });
            cx.notify();
        });
    }

    fn selected(view: &Entity<ChatComposer>, cx: &mut VisualTestContext) -> Option<usize> {
        view.read_with(cx, |c, _| match c.form.as_ref()?.fields[0].value {
            FieldInput::Select(i) => Some(i),
            _ => None,
        })
    }

    #[gpui_kit::test]
    fn a_prompts_choices_are_one_tab_stop_the_arrows_move(cx: &mut TestAppContext) {
        let (view, cx, _) = composer(cx);
        cx.update(|_, cx| {
            cx.set_global(conduit_components::views::focus::KeyboardAccess { all_controls: true })
        });
        select_form(&view, cx);
        cx.update(|window, cx| window.draw(cx).clear(cx));
        // Tab from the message field reaches the chosen option.
        let mut reached = false;
        for _ in 0..12 {
            cx.update(|window, cx| {
                window.focus_next(cx);
                window.draw(cx).clear(cx);
            });
            cx.simulate_keystrokes("right");
            if selected(&view, cx) == Some(1) {
                reached = true;
                break;
            }
        }
        assert!(reached, "Tab reaches the choices and → chooses the next");
        cx.simulate_keystrokes("right");
        assert_eq!(selected(&view, cx), Some(2));
        cx.simulate_keystrokes("left");
        assert_eq!(selected(&view, cx), Some(1));
    }

    #[gpui_kit::test]
    fn a_cancelled_prompt_never_lands_in_the_draft(cx: &mut TestAppContext) {
        let (view, cx, _) = composer(cx);
        let held = {
            let daemon = FakeDaemon::new();
            daemon.returns::<conduit_protocol::methods::PromptsRender>(
                serde_json::from_value(serde_json::json!({"content": "LATE", "inputs": []}))
                    .unwrap(),
            );
            let held = daemon.hold::<conduit_protocol::methods::PromptsRender>();
            let store = cx.new(|_| ComposerStore::new(daemon.rpc(), None));
            view.update(cx, |c, _| c.composer = store);
            held
        };
        select_form(&view, cx);
        view.update_in(cx, |c, window, cx| {
            c.submit_form(window, cx);
            c.cancel_form(window, cx);
        });
        held.release();
        cx.run_until_parked();
        assert_eq!(value(&view, cx), "");
        assert!(view.read_with(cx, |c, _| c.form.is_none()));
    }

    #[gpui_kit::test]
    fn a_prompt_rendered_after_send_stays_out_of_the_next_draft(cx: &mut TestAppContext) {
        let (view, cx, _) = composer(cx);
        let daemon = FakeDaemon::new();
        daemon.returns::<conduit_protocol::methods::PromptsRender>(
            serde_json::from_value(serde_json::json!({"content": "LATE", "inputs": []})).unwrap(),
        );
        let held = daemon.hold::<conduit_protocol::methods::PromptsRender>();
        let store = cx.new(|_| ComposerStore::new(daemon.rpc(), None));
        view.update(cx, |c, _| c.composer = store);
        cx.simulate_input("Hello");
        view.update_in(cx, |c, window, cx| {
            let prompt = serde_json::from_value(serde_json::json!({
                "command": "/greet", "title": "Greet"
            }))
            .unwrap();
            c.render_prompt(prompt, 5, BTreeMap::new(), window, cx);
            c.submit(window, cx);
        });
        held.release();
        cx.run_until_parked();
        assert_eq!(value(&view, cx), "");
    }

    #[gpui_kit::test]
    fn a_prompt_rendered_for_the_last_account_is_dropped(cx: &mut TestAppContext) {
        let (view, cx, _) = composer(cx);
        let daemon = FakeDaemon::new();
        daemon.returns::<conduit_protocol::methods::PromptsRender>(
            serde_json::from_value(serde_json::json!({"content": "LATE", "inputs": []})).unwrap(),
        );
        let held = daemon.hold::<conduit_protocol::methods::PromptsRender>();
        let store = cx.new(|_| ComposerStore::new(daemon.rpc(), None));
        view.update(cx, |c, _| c.composer = store.clone());
        cx.simulate_input("Hello");
        view.update_in(cx, |c, window, cx| {
            let prompt = serde_json::from_value(serde_json::json!({
                "command": "/greet", "title": "Greet"
            }))
            .unwrap();
            c.render_prompt(prompt, 5, BTreeMap::new(), window, cx);
        });
        // The account changes while the prompt renders.
        store.update(cx, |s, cx| s.reset(cx));
        held.release();
        cx.run_until_parked();
        assert_eq!(value(&view, cx), "Hello");
        view.read_with(cx, |c, _| assert!(c.form.is_none()));
    }

    #[gpui_kit::test]
    fn a_trigger_left_behind_the_caret_is_not_cut(cx: &mut TestAppContext) {
        let (view, cx, _) = composer(cx);
        cx.simulate_input("#k and more");
        view.update_in(cx, |c, window, cx| {
            // The menu for `#k`, then the caret moves to the end without an
            // edit.
            c.input.update(cx, |s, cx| s.set_selected_range(2..2, cx));
            c.text_changed(cx);
            c.input.update(cx, |s, cx| s.set_selected_range(11..11, cx));
            assert_eq!(c.take_trigger(window, cx), None);
        });
        assert_eq!(value(&view, cx), "#k and more");
    }

    #[gpui_kit::test]
    fn send_goes_when_a_trigger_matches_nothing(cx: &mut TestAppContext) {
        let (view, cx, seen) = composer(cx);
        cx.simulate_input("explain /nonexistent");
        view.update_in(cx, |c, window, cx| c.submit(window, cx));
        assert_eq!(
            *seen.borrow(),
            vec![ChatComposerEvent::Submit("explain /nonexistent".into())]
        );
    }

    #[gpui_kit::test]
    fn nothing_sends_while_an_input_method_composes(cx: &mut TestAppContext) {
        let (view, cx, seen) = composer(cx);
        let input = view.read_with(cx, |c, _| c.input.clone());
        cx.update(|window, cx| {
            input.update(cx, |s, cx| {
                s.replace_and_mark_text_in_range(None, "かな", None, window, cx)
            });
        });
        assert!(cx.update(|window, cx| {
            input.update(cx, |s, cx| s.marked_text_range(window, cx).is_some())
        }));
        cx.simulate_keystrokes("enter");
        assert!(
            seen.borrow().is_empty(),
            "Enter while composing does not send"
        );
        // The composition ends with the chosen text; Enter sends now. (The
        // test platform hands the guarded Enter to the field as a newline;
        // a real input method keeps it.)
        cx.update(|window, cx| {
            input.update(cx, |s, cx| {
                s.unmark_text(window, cx);
                s.set_value("かな", window, cx);
            })
        });
        cx.simulate_keystrokes("enter");
        assert_eq!(
            *seen.borrow(),
            vec![ChatComposerEvent::Submit("かな".into())]
        );
    }

    #[gpui_kit::test]
    fn send_waits_for_uploads_and_the_network(cx: &mut TestAppContext) {
        let (view, cx, seen) = composer(cx);
        cx.simulate_input("with a file");
        // A file still being read: Send waits.
        let store = view.read_with(cx, |c, _| c.composer.clone());
        let dir = std::env::temp_dir().join(format!("p7-composer-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("notes.txt");
        std::fs::write(&file, b"synthetic").unwrap();
        cx.update(|_, cx| store.update(cx, |s, cx| s.add_paths(&[file], cx)));
        assert!(!view.read_with(cx, |c, cx| c.can_send(cx)));
        cx.simulate_keystrokes("enter");
        assert!(seen.borrow().is_empty());
        cx.run_until_parked();
        // No uploader here: the file failed, so text alone may go…
        assert!(view.read_with(cx, |c, cx| c.can_send(cx)));
        // …unless the network is down.
        view.update(cx, |c, _| c.offline = true);
        cx.simulate_keystrokes("enter");
        assert!(seen.borrow().is_empty(), "Send waits while offline");
        view.update(cx, |c, _| c.offline = false);
        cx.simulate_keystrokes("enter");
        assert_eq!(seen.borrow().len(), 1);
        // While an answer is written, Enter does not send either.
        view.update(cx, |c, _| c.streaming = true);
        cx.simulate_input("next");
        cx.simulate_keystrokes("enter");
        assert_eq!(seen.borrow().len(), 1);
    }

    #[test]
    fn the_arrows_wrap_a_menu_from_its_last_row_to_its_first() {
        assert_eq!(menu_step("down", 0, 3), 1);
        assert_eq!(menu_step("down", 2, 3), 0, "↓ on the last wraps");
        assert_eq!(menu_step("up", 0, 3), 2, "↑ on the first wraps");
        assert_eq!(menu_step("up", 2, 3), 1);
        assert_eq!(menu_step("down", 0, 1), 0);
        assert_eq!(menu_step("down", 0, 0), 0, "nothing to move through");
        assert_eq!(menu_step("down", 7, 3), 0, "a list that shrank");
    }

    #[gpui_kit::test]
    fn the_slash_menu_follows_the_caret_and_escape_closes_it(cx: &mut TestAppContext) {
        let (view, cx, _) = composer(cx);
        cx.simulate_input("please /su");
        view.read_with(cx, |c, _| {
            let menu = c.menu.as_ref().expect("a / menu");
            assert_eq!(menu.trigger.kind, TriggerKind::Prompt);
            assert_eq!(menu.trigger.query, "su");
        });
        cx.update(|window, cx| view.update(cx, |c, cx| assert!(c.menu_key("escape", window, cx))));
        assert!(view.read_with(cx, |c, _| c.menu.is_none()));
        cx.simulate_input(" @gp");
        assert_eq!(
            view.read_with(cx, |c, _| c.menu.as_ref().map(|m| m.trigger.kind)),
            Some(TriggerKind::Model)
        );
    }
}
