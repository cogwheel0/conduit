//! The composer.
//!
//! * **Text:** a GPUI Kit Textarea. Enter sends and Shift+Enter breaks the
//!   line (or, with Send on Enter off, Enter breaks it and ⌘↩ sends; ⌘↩
//!   always sends); nothing sends while an input method is composing
//!   (`marked_text_range()`). ⇧⌘E grows it into a larger
//!   editor for a long prompt, and back.
//! * **While an answer is written:** in an Open WebUI chat a message is
//!   queued behind it (Queue); with Hermes on a Desktop Gateway it goes to
//!   the running turn as the next message, or steers it (Steer).
//! * **Attachments:** from +, a drop onto the composer, or a paste (images
//!   and copied files), each uploading with its own progress; files already
//!   on the server (Server Files…), a web page or a YouTube transcript (Web
//!   Page…), and a Direct MCP server's prompts and resources (MCP
//!   Content…).
//! * **Menus at the caret:** `/` saved prompts (with the fill-in form for
//!   their fields, select fields included), `@` a model for this message
//!   only, or a person or channel to mention, `#` notes, knowledge bases and
//!   their files, `$` skills. Up/Down move, Enter or Tab choose, Esc closes;
//!   the keys go to the menu, not the text, while one is open. Mentions and
//!   skills are atomic tokens in the text.
//! * **Footer:** + (attachments, then the switches `composer.options`
//!   allows: web search, image generation, the code interpreter, Compare
//!   Models, Save as Note, then tools and filters), the quick pills chosen in
//!   Settings, the temporary-chat switch before the first message, the model
//!   picker (`models.list` / `models.select`), and Send, which becomes Stop
//!   while an answer is written. Send waits while offline or while files
//!   upload.
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
    ComposerMentionDto, ContextAttachmentDto, ContextAttachmentKind, ContextSuggestion,
    ContextSuggestionKind, KnowledgeSummary, MentionTarget as Person, ModelSummary, PromptInput,
    PromptSummary, RenderPrompt, RenderedPrompt, SkillSummary,
};
use gpui_kit::component::input::{
    InlineToken, Input, InputContent, InputEvent, InputState, Textarea, TextareaState,
};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, ClipboardEntry, Context, ElementId, Entity, EntityInputHandler as _,
    EventEmitter, ExternalPaths, FocusHandle, Focusable, FontWeight, PathPromptOptions, Role,
    SharedString, Subscription, Window, div, img, px,
};

use super::dictation::{self as dictation_view, RecordingMenu};
use crate::l10n::ActiveL10n as _;
use crate::stores::composer::LibreChatTool;
use crate::stores::composer::{
    Attachment, ComposerEvent, ComposerStore, MentionTarget, Trigger, TriggerKind, UploadState,
    match_models, match_prompts, mentions_in, model_label, trigger_at,
};
use crate::stores::dictation::{DictationEvent, DictationStore, Target as DictationTarget};

/// How many entries a `/`, `@` or `#` menu shows.
const MENU_LIMIT: usize = 8;

#[derive(Clone, Debug, PartialEq)]
pub enum ChatComposerEvent {
    /// Send this text, with the mentions in it (the composer has already
    /// cleared itself).
    Submit {
        text: String,
        mentions: Vec<ComposerMentionDto>,
    },
    /// Queue this text behind the running answer.
    Queue {
        text: String,
        mentions: Vec<ComposerMentionDto>,
    },
    /// Hand this text to the running Hermes turn: to steer it (`steer`), or
    /// as the next message.
    Steer {
        text: String,
        mentions: Vec<ComposerMentionDto>,
        steer: bool,
    },
    Stop,
    /// The temporary-chat switch moved.
    Temporary(bool),
    /// The model picker opened or closed (the chat pane draws it under its
    /// toolbar).
    PickerChanged,
    /// + › Save as Note: keep this text as a new note instead of sending it.
    SaveAsNote(String),
    /// + › Compare Models.
    CompareModels,
    /// The call button: a voice call in this chat.
    StartCall,
}

/// What the + menu's items do. The menu is native (NSMenu), as the panel
/// the phone's + opens: attachments first, then the features, then tools
/// and filters, each group under its own separator.
#[derive(Clone, Debug, PartialEq, gpui_kit::Action)]
#[action(namespace = conduit_composer, no_json)]
pub enum ComposerMenu {
    AttachFiles,
    ServerFiles,
    WebPage,
    McpContent,
    WebSearch,
    ImageGeneration,
    CodeInterpreter,
    CompareModels,
    SaveAsNote,
    Tool(String),
    Filter(String),
    /// A LibreChat MCP server to sign in to: its web app opens.
    ConnectInLibreChat,
    /// A terminal server for the chat's terminal tool: selects it, or
    /// (selected already) none.
    Terminal(String),
    /// A heading (disabled).
    Heading,
}

/// A menu's rows as drawn: each one's group heading and title.
pub type MenuRows = Vec<(Option<String>, String)>;

/// One row of the + menu.
pub(crate) enum PlusRow {
    Item {
        label: String,
        disabled: bool,
        /// A switch's state (`None`: not a switch).
        checked: Option<bool>,
        action: ComposerMenu,
    },
    Separator,
    /// Continuity Camera's items (AppKit's), when a device is near.
    ImportFromDevice,
}

/// A `/`, `@`, `#` or `$` menu open over the composer.
struct Menu {
    trigger: Trigger,
    highlighted: usize,
}

/// What choosing a menu entry does.
#[derive(Clone)]
enum Pick {
    Prompt(PromptSummary),
    Model(ModelSummary),
    Person(Person),
    Channel(Person),
    Skill(SkillSummary),
    Context(ContextSuggestion),
}

/// One row of a `/`, `@`, `#` or `$` menu, under its group's heading.
struct Entry {
    group: Option<String>,
    icon: IconName,
    title: String,
    detail: String,
    pick: Pick,
}

/// A panel over the composer: the server's files, a web page to read, or a
/// Direct MCP server's content.
pub(crate) enum Panel {
    ServerFiles(super::composer_panels::ServerFilesPanel),
    WebPage(super::composer_panels::WebPagePanel),
    Mcp(Box<super::composer_panels::McpPanel>),
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
    /// More Models: every model, past the featured ones.
    more: bool,
    /// Custom… under Reasoning Effort: the field a value is typed in.
    custom: Option<Entity<InputState>>,
}

/// What the picker's native menus and rows do.
#[derive(Clone, Debug, PartialEq, gpui_kit::Action)]
#[action(namespace = conduit_composer, no_json)]
pub enum PickerAction {
    /// A reasoning effort preset (`automatic`, `low`, ...).
    Effort(String),
    /// Custom…: type an effort.
    CustomEffort,
    /// Pin or unpin a model.
    Pin(String, bool),
    /// An option of the selected model's control: `(key, value)`.
    Control(String, String),
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
    /// A message typed now would be queued behind the running answer (the
    /// open chat's `queue.offer`).
    pub queue_offer: bool,
    /// With nothing to send, Send's place holds Start Voice Call (the main
    /// window's composer, a chat that takes answers); `call_ready`: one can
    /// start now (no call is on, a model is chosen, the server answers).
    pub call_offer: bool,
    pub call_ready: bool,
    /// A voice call is on: it has the microphone, so no mic here.
    pub call_on: bool,
    /// The field grown into a larger editor (⇧⌘E).
    pub expanded: bool,
    /// Enter sends (the Chats setting, as the field was last told).
    send_on_enter: bool,
    /// The + menu offers Compare Models (where the daemon says it can run
    /// one); a window that cannot draw two answers turns it off.
    pub compare_ui: bool,
    /// Queue, Steer, Send Next and Save as Note: the main window's. Quick
    /// Ask, which only asks and answers, turns them off.
    pub follow_ups: bool,
    pub(crate) panel: Option<Panel>,
    /// Dictation into this field (the chat pane gives it one).
    pub dictation: Option<Entity<DictationStore>>,
    /// The recordings the last message took ([`Self::take_sent_recordings`]).
    sent_recordings: Option<u64>,
    /// The text before the dictation under way; its words follow it.
    dictation_base: Option<String>,
    /// The composition a saved recording's transcription was asked for in:
    /// its words are added only while that composition is shown.
    transcribing: Option<crate::stores::composer::CompositionTicket>,
    /// The field's placeholder, put back after "Listening…".
    placeholder: String,
    /// A host chose the placeholder (Quick Ask's "Ask Conduit…"): the
    /// selected model never names it.
    custom_placeholder: bool,
    /// The placeholder the field shows now (not "Listening…").
    shown_placeholder: String,
    /// The window this composer is in: Esc cancels dictation there only.
    window_handle: gpui_kit::AnyWindowHandle,
    /// A channel's composer: `@` is the only menu, and a model chosen there
    /// is a mention in the text (`<@M:id|Name>`), which answers in the
    /// channel, rather than the model for the next message.
    pub channel_mode: bool,
    _dictation: Vec<Subscription>,
    focus: FocusHandle,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<ChatComposerEvent> for ChatComposer {}

/// Compare Models' menu chose `model` to answer beside the first.
#[derive(Clone, Debug, PartialEq, gpui_kit::Action)]
#[action(namespace = conduit_composer, no_json)]
pub struct CompareWith {
    pub composer: gpui_kit::WeakEntity<ComposerStore>,
    pub model: ModelSummary,
}

/// Registers the composer's menu actions on the app.
pub fn register_actions(cx: &mut App) {
    cx.on_action(|a: &CompareWith, cx: &mut App| {
        let model = a.model.clone();
        let _ = a
            .composer
            .update(cx, |c, cx| c.set_compare_with(Some(model), cx));
    });
}

impl Focusable for ChatComposer {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

/// What a quick pill turns on (the daemon's `QuickPillOption::kind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PillKind {
    Web,
    Image,
    Filter,
    Tool,
}

impl ChatComposer {
    pub fn new(
        composer: Entity<ComposerStore>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let placeholder = cx.l10n().message_hint_text();
        // Send with Enter as the store already has it (the settings may have
        // arrived before this view was made).
        let send_on_enter = composer.read(cx).prefs.send_on_enter;
        let input = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(1, 10)
                .placeholder(placeholder.clone())
                .submit_on_enter(send_on_enter)
        });
        let weak = cx.entity().downgrade();
        let mut subscriptions = vec![
            cx.subscribe_in(
                &input,
                window,
                |this, state, e: &InputEvent, window, cx| match e {
                    InputEvent::PressEnter {
                        shift: false,
                        secondary: false,
                    } => {
                        // With Send on Enter off the field took Enter as a
                        // new line (⌘↩ sends). An input method may hand
                        // Enter back while composing.
                        let composing =
                            state.update(cx, |s, cx| s.marked_text_range(window, cx).is_some());
                        if this.send_on_enter && !composing {
                            this.submit(window, cx);
                        }
                    }
                    InputEvent::Change => this.text_changed(cx),
                    _ => {}
                },
            ),
            // Drafts: another chat's replaces what was shown; a draft read
            // shows unless something was typed meanwhile.
            cx.subscribe_in(
                &composer,
                window,
                |this, store, e: &ComposerEvent, window, cx| match e {
                    ComposerEvent::DraftSwitched => {
                        this.input.update(cx, |s, cx| s.set_value("", window, cx));
                        this.menu = None;
                        // The last draft's prompt form and panel go with it:
                        // nothing they bring back lands in this one.
                        this.form = None;
                        this.prompt_request += 1;
                        this.panel = None;
                        // Dictation for the last draft (or account) ends
                        // now: its words never reach this one.
                        this.sync_dictation_target(cx);
                        cx.notify();
                    }
                    // The draft read landed: shown, joined with what was
                    // typed meanwhile (the draft first), then kept.
                    ComposerEvent::DraftLoaded { key, text } => {
                        let current = store.read(cx).draft_key() == Some(key);
                        if current && !text.is_empty() {
                            let typed = this.text(cx);
                            let joined = crate::stores::composer::joined_draft(text, &typed);
                            if joined != typed {
                                this.set_text(&joined, window, cx);
                            }
                        }
                    }
                    _ => {}
                },
            ),
            cx.observe(&composer, |this, store, cx| {
                // Send on Enter follows the Chats setting.
                let on_enter = store.read(cx).prefs.send_on_enter;
                if this.send_on_enter != on_enter {
                    this.send_on_enter = on_enter;
                    this.input
                        .update(cx, |s, cx| s.set_submit_on_enter(on_enter, cx));
                }
                // Dictation follows the draft and its model.
                this.sync_dictation_target(cx);
                cx.notify()
            }),
            // The menu and picker keys, ahead of the text field's own; ⌘↩
            // sends whatever Enter does.
            cx.intercept_keystrokes(move |event, window, cx| {
                let key = event.keystroke.key.as_str();
                let m = event.keystroke.modifiers;
                let Some(this) = weak.upgrade() else {
                    return;
                };
                if key == "enter" && m.platform && !m.shift && !m.alt && !m.control {
                    let handled = this.update(cx, |c, cx| {
                        let focused = c.input.read(cx).focus_handle(cx).is_focused(window);
                        // An input method composing keeps its keys (as Enter).
                        let composing = focused
                            && c.input
                                .update(cx, |s, cx| s.marked_text_range(window, cx).is_some());
                        if focused && !composing {
                            c.submit(window, cx);
                        }
                        focused && !composing
                    });
                    if handled {
                        cx.stop_propagation();
                    }
                    return;
                }
                // Esc while dictating cancels it, in this composer's window.
                if key == "escape" && !m.modified() {
                    let cancelled = this.update(cx, |c, cx| {
                        if window.window_handle() != c.window_handle || !c.dictating(cx) {
                            return false;
                        }
                        c.cancel_dictation(window, cx);
                        true
                    });
                    if cancelled {
                        cx.stop_propagation();
                        return;
                    }
                }
                if m.modified() || !matches!(key, "up" | "down" | "enter" | "tab" | "escape") {
                    return;
                }
                let handled = this.update(cx, |c, cx| {
                    // The input method's own keys while it composes (Enter
                    // confirms, arrows pick, Esc cancels), as for PressEnter.
                    let composing = c
                        .input
                        .update(cx, |s, cx| s.marked_text_range(window, cx).is_some());
                    !composing && c.menu_key(key, window, cx)
                });
                if handled {
                    cx.stop_propagation();
                }
            }),
        ];
        // The placeholder names the selected model when Settings say so.
        subscriptions.push(cx.observe_in(&composer, window, |this, _, window, cx| {
            this.sync_placeholder(window, cx)
        }));
        Self {
            composer,
            input,
            menu: None,
            form: None,
            prompt_request: 0,
            picker: None,
            leaving_picker: None,
            streaming: false,
            follow_ups: true,
            offline: false,
            offline_word: None,
            offline_reason: None,
            new_chat: true,
            temporary: false,
            inline_model: true,
            picker_closed_at: None,
            plus_bounds: Rc::default(),
            frame_bounds: Rc::default(),
            queue_offer: false,
            call_offer: false,
            call_ready: false,
            call_on: false,
            expanded: false,
            send_on_enter,
            compare_ui: true,
            panel: None,
            dictation: None,
            sent_recordings: None,
            dictation_base: None,
            transcribing: None,
            placeholder: placeholder.to_string(),
            custom_placeholder: false,
            shown_placeholder: placeholder.to_string(),
            window_handle: window.window_handle(),
            channel_mode: false,
            _dictation: vec![],
            focus: cx.focus_handle(),
            _subscriptions: subscriptions,
        }
    }

    pub fn focus_input(&self, window: &mut Window, cx: &mut Context<Self>) {
        self.input.update(cx, |s, cx| s.focus(window, cx));
    }

    /// Enter sends, as the field was last told (Settings › Chat).
    pub fn sends_on_enter(&self) -> bool {
        self.send_on_enter
    }

    /// The text field's placeholder (Quick Ask says "Ask Conduit…").
    pub fn set_placeholder(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.placeholder = text.to_string();
        self.custom_placeholder = true;
        self.shown_placeholder = text.to_string();
        let text = text.to_string();
        self.input
            .update(cx, |s, cx| s.set_placeholder(text, window, cx));
    }

    /// What the empty field says: with Settings › Chats › Show Model Name
    /// in Message Box on, "Ask" and the selected model's name (mobile's
    /// `chatComposerPlaceholder`); else the app's own words.
    fn placeholder_now(&self, cx: &App) -> String {
        let store = self.composer.read(cx);
        if self.custom_placeholder || self.channel_mode || !store.prefs.show_model_name {
            return self.placeholder.clone();
        }
        store
            .selected_model()
            .and_then(|m| crate::stores::composer::placeholder_model_name(&m.name))
            .map(|name| cx.l10n().message_hint_text_for_model(&name))
            .unwrap_or_else(|| self.placeholder.clone())
    }

    /// Puts [`Self::placeholder_now`] in the field when it changed (not
    /// while dictation says "Listening…").
    fn sync_placeholder(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.dictation_base.is_some() {
            return;
        }
        let now = self.placeholder_now(cx);
        if now != self.shown_placeholder {
            self.shown_placeholder = now.clone();
            self.input
                .update(cx, |s, cx| s.set_placeholder(now, window, cx));
        }
    }

    /// The placeholder the field shows (the E2E pass reads it).
    pub fn shown_placeholder(&self) -> &str {
        &self.shown_placeholder
    }

    // ── Dictation ──────────────────────────────────────────────────────

    /// Dictation for this field: the mic, ⇧⌘L, and the draft's saved
    /// recordings.
    pub fn set_dictation(
        &mut self,
        store: Entity<DictationStore>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self._dictation = vec![
            cx.subscribe_in(&store, window, |this, _, e: &DictationEvent, window, cx| {
                this.on_dictation(e, window, cx)
            }),
            cx.observe(&store, |_, _, cx| cx.notify()),
        ];
        self.dictation = Some(store);
        self.sync_dictation_target(cx);
    }

    /// Listening, starting, or transcribing what was said.
    pub fn dictating(&self, cx: &App) -> bool {
        self.dictation
            .as_ref()
            .is_some_and(|d| d.read(cx).is_active())
    }

    fn sync_dictation_target(&mut self, cx: &mut Context<Self>) {
        let Some(store) = self.dictation.clone() else {
            return;
        };
        let composer = self.composer.read(cx);
        let key = composer.draft_key().cloned();
        let target = DictationTarget {
            chat_id: key.as_ref().and_then(|k| k.chat_id.clone()),
            folder_id: key.as_ref().and_then(|k| k.folder_id.clone()),
            model_id: composer.selected_model().map(|m| m.id.clone()),
            keeps_recordings: key.is_some(),
        };
        let scope = composer.scope();
        store.update(cx, |s, cx| s.set_target_in(scope, target, cx));
    }

    /// ⇧⌘L and the mic: starts dictating after what is typed, or stops.
    pub fn toggle_dictation(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(store) = self.dictation.clone() else {
            return;
        };
        if !store.read(cx).is_active() {
            if self.streaming {
                return;
            }
            // A voice call has the microphone.
            if cx
                .try_global::<crate::AppState>()
                .is_some_and(|s| s.stores.call.read(cx).is_active())
            {
                return;
            }
            self.dictation_base = Some(self.text(cx));
            self.menu = None;
            let listening = cx.l10n().desktop_listening();
            self.input
                .update(cx, |s, cx| s.set_placeholder(listening, window, cx));
            self.focus_input(window, cx);
        }
        store.update(cx, |s, cx| s.toggle(cx));
        cx.notify();
    }

    /// Stop: what was said is transcribed.
    pub fn stop_dictation(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        if let Some(store) = self.dictation.clone() {
            store.update(cx, |s, cx| s.stop(cx));
        }
    }

    /// Cancel (Esc): what was said is dropped and the text put back.
    pub fn cancel_dictation(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        if let Some(store) = self.dictation.clone() {
            store.update(cx, |s, cx| s.cancel(cx));
        }
    }

    fn on_dictation(
        &mut self,
        event: &DictationEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match event {
            DictationEvent::Text { text, .. } => {
                if let Some(base) = self.dictation_base.clone() {
                    self.set_text(&join_dictated(&base, text), window, cx);
                }
            }
            DictationEvent::Transcribed(text) => {
                // Only into the composition it was asked for in.
                match self.transcribing.take() {
                    Some(ticket) if self.composer.read(cx).holds(ticket) => {
                        let current = self.text(cx);
                        self.set_text(&join_dictated(&current, text), window, cx);
                        self.focus_input(window, cx);
                    }
                    _ => log::info!("dictation: a transcription for another composition; dropped"),
                }
            }
            DictationEvent::Heard => {
                let placeholder = self.placeholder_now(cx);
                self.input
                    .update(cx, |s, cx| s.set_placeholder(placeholder, window, cx));
            }
            DictationEvent::Ended { restore } => {
                if let Some(base) = self.dictation_base.take()
                    && *restore
                {
                    self.set_text(&base, window, cx);
                }
                let placeholder = self.placeholder_now(cx);
                self.shown_placeholder = placeholder.clone();
                self.input
                    .update(cx, |s, cx| s.set_placeholder(placeholder, window, cx));
                self.focus_input(window, cx);
                cx.notify();
            }
        }
    }

    /// Transcribes saved recording `id` on the server or on this Mac.
    pub fn transcribe_recording(
        &mut self,
        id: &str,
        on_this_mac: bool,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(store) = self.dictation.clone() {
            // One at a time: a request while one runs is not taken.
            let free = store.read(cx).busy.is_none() && !store.read(cx).is_active();
            store.update(cx, |s, cx| s.transcribe_saved(id, on_this_mac, cx));
            if free && store.read(cx).busy.is_some() {
                self.transcribing = Some(self.composer.read(cx).ticket());
            }
        }
    }

    /// A saved recording's menu, under its button.
    pub fn show_recording_menu(
        &mut self,
        id: &str,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        use gpui_kit::component::native_menu::NativeMenu;
        let l10n = cx.l10n().clone();
        let id = id.to_string();
        let menu = NativeMenu::new()
            .menu_with_disabled(
                l10n.transcribe_on_server(),
                false,
                Box::new(RecordingMenu::TranscribeOnServer(id.clone())),
            )
            .menu_with_disabled(
                l10n.desktop_transcribe_on_this_mac(),
                false,
                Box::new(RecordingMenu::TranscribeOnThisMac(id.clone())),
            )
            .separator()
            .menu_with_disabled(
                l10n.desktop_export_recording(),
                false,
                Box::new(RecordingMenu::Export(id.clone())),
            )
            .separator()
            .menu_with_disabled(
                l10n.desktop_discard_recording_menu(),
                false,
                Box::new(RecordingMenu::Discard(id)),
            );
        // The menu's action goes to the focused element's path.
        self.focus_input(window, cx);
        menu.show(position, window, cx);
    }

    pub fn on_recording_menu(
        &mut self,
        action: &RecordingMenu,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match action {
            RecordingMenu::TranscribeOnServer(id) => {
                self.transcribe_recording(id, false, window, cx)
            }
            RecordingMenu::TranscribeOnThisMac(id) => {
                self.transcribe_recording(id, true, window, cx)
            }
            RecordingMenu::Export(id) => self.export_recording(id, window, cx),
            RecordingMenu::Discard(id) => self.confirm_discard_recording(id, window, cx),
        }
    }

    /// Export…: a save panel (in Downloads), then the recording as WAV.
    fn export_recording(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(store) = self.dictation.clone() else {
            return;
        };
        let home = std::env::var_os("HOME")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| std::path::PathBuf::from("/"));
        let downloads = home.join("Downloads");
        let dir = if downloads.is_dir() { downloads } else { home };
        let name = format!("{}.wav", cx.l10n().saved_recording());
        let asked = cx.prompt_for_new_path(&dir, Some(&name));
        let id = id.to_string();
        window
            .spawn(cx, async move |cx| {
                let Ok(Ok(Some(path))) = asked.await else {
                    return;
                };
                let _ = cx.update(|_, cx| {
                    store
                        .update(cx, |s, cx| s.export_to(&id, path, cx))
                        .detach()
                });
            })
            .detach();
    }

    /// Discard Recording…: asks first, as the phone does.
    fn confirm_discard_recording(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        use crate::shell::sheet::{SheetSpec, present_sheet};
        let Some(store) = self.dictation.clone() else {
            return;
        };
        let l = cx.l10n().clone();
        let spec = SheetSpec::new(
            l.desktop_discard_recording_title(),
            l.desktop_discard_recording_body(),
            l.desktop_discard(),
            l.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        let id = id.to_string();
        cx.spawn(async move |_, cx| {
            if ask.await {
                store.update(cx, |s, cx| s.discard(&id, cx));
            }
        })
        .detach();
    }

    /// A `/`, `@`, `#` or `$` menu, a prompt's form, a panel or the model
    /// picker is open, or the editor is expanded (Esc closes that first).
    pub fn has_popup(&self) -> bool {
        self.menu.is_some()
            || self.form.is_some()
            || self.picker.is_some()
            || self.panel.is_some()
            || self.expanded
    }

    /// Esc: closes what is open over the composer, the innermost first.
    /// True when something was.
    pub fn close_popup(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        if self.menu.take().is_some() {
        } else if self.picker.is_some() {
            self.close_picker(window, cx);
        } else if self.form.is_some() {
            self.cancel_form(window, cx);
        } else if self.panel.take().is_some() {
            self.focus_input(window, cx);
        } else if self.expanded {
            self.set_expanded(false, window, cx);
        } else {
            return false;
        }
        cx.notify();
        true
    }

    /// ⇧⌘E: the larger editor for a long prompt, or back.
    pub fn set_expanded(&mut self, expanded: bool, window: &mut Window, cx: &mut Context<Self>) {
        self.expanded = expanded;
        let (min, max) = if expanded { (12, 36) } else { (1, 10) };
        self.input.update(cx, |s, cx| s.set_auto_grow(min, max, cx));
        self.focus_input(window, cx);
        cx.notify();
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
        !self.streaming && self.ready(cx)
    }

    /// A new turn to start: something to send, a model the open chat's own
    /// list names, and nothing holding it back but a running answer.
    fn ready(&self, cx: &App) -> bool {
        self.has_message(cx) && self.composer.read(cx).can_name_model()
    }

    /// Something to send now, the connection up and no file still being
    /// read. Queue, Steer and Send Next need no more: they go to the turn
    /// or chat already running, not to a model the list names.
    fn has_message(&self, cx: &App) -> bool {
        let composer = self.composer.read(cx);
        let has_text = !self.text(cx).trim().is_empty();
        !self.offline && !composer.uploading() && (has_text || composer.has_attachments())
    }

    /// The call button stands where Send would: nothing to send.
    fn offers_call(&self, cx: &App) -> bool {
        // Not "not ready": a message waiting on an upload or the connection
        // keeps its Send.
        self.call_offer
            && self.text(cx).trim().is_empty()
            && !self.composer.read(cx).has_attachments()
    }

    /// Hermes on a Desktop Gateway takes a message while it works.
    pub fn steers(&self, cx: &App) -> bool {
        self.follow_ups && self.composer.read(cx).options.steer
    }

    /// What Enter does while an answer is written: queue (Open WebUI), hand
    /// to Hermes (a Desktop Gateway), or nothing.
    fn busy_action(&self, cx: &App) -> Option<bool> {
        // The queue is offered behind a running answer, and behind one that
        // waits in the outbox (nothing streams, Send shows).
        if !(self.streaming || self.queue_offer)
            || !self.has_message(cx)
            || self.text(cx).trim().is_empty()
        {
            return None;
        }
        if self.queue_offer && self.follow_ups {
            Some(true)
        } else if self.steers(cx) {
            Some(false)
        } else {
            None
        }
    }

    /// The text as it goes out, and its mentions (UTF-16 ranges into it),
    /// with the field cleared.
    fn take_text(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> (String, Vec<ComposerMentionDto>) {
        let state = self.input.read(cx);
        let raw = state.value().to_string();
        let tokens: Vec<_> = state
            .tokens()
            .iter()
            .map(|span| {
                (
                    span.range(),
                    span.token().id().to_string(),
                    span.token().label().to_string(),
                )
            })
            .collect();
        // Trimmed, with the mentions moved to match.
        let lead = raw.len() - raw.trim_start().len();
        let text = raw.trim().to_string();
        let tokens = tokens
            .into_iter()
            .filter(|(r, _, _)| r.start >= lead && r.end <= lead + text.len())
            .map(|(r, id, label)| (r.start - lead..r.end - lead, id, label));
        let mentions = mentions_in(&text, tokens);
        // A prompt still being rendered belongs to the draft that just went.
        self.prompt_request += 1;
        self.input.update(cx, |s, cx| s.set_value("", window, cx));
        self.menu = None;
        self.composer.update(cx, |c, cx| c.clear_draft(cx));
        // The draft's recordings go with it, as on the phone, once it is
        // taken ([`Self::take_sent_recordings`]).
        if let Some(store) = self.dictation.clone() {
            self.sent_recordings = store.update(cx, |s, cx| s.sent(cx));
        }
        (text, mentions)
    }

    /// Enter or Send: emits the text and clears the field. While an answer
    /// is written: queues it, or hands it to Hermes as the next message.
    pub fn submit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // A trigger menu with nothing in it is no menu: Send sends.
        if self.menu.is_some() && self.menu_len(cx) == 0 {
            self.menu = None;
        }
        if self.menu.is_some() || self.form.is_some() || self.panel.is_some() {
            return;
        }
        // Enter while dictating does nothing; Stop ends it first.
        if self.dictating(cx) {
            return;
        }
        if let Some(queue) = self.busy_action(cx) {
            let (text, mentions) = self.take_text(window, cx);
            cx.emit(if queue {
                ChatComposerEvent::Queue { text, mentions }
            } else {
                ChatComposerEvent::Steer {
                    text,
                    mentions,
                    steer: false,
                }
            });
            cx.notify();
            return;
        }
        if !self.can_send(cx) {
            return;
        }
        let (text, mentions) = self.take_text(window, cx);
        if self.expanded {
            self.set_expanded(false, window, cx);
        }
        cx.emit(ChatComposerEvent::Submit { text, mentions });
        cx.notify();
    }

    /// Steer: the text goes to the running Hermes turn now.
    pub fn steer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy_action(cx) != Some(false) {
            return;
        }
        let (text, mentions) = self.take_text(window, cx);
        cx.emit(ChatComposerEvent::Steer {
            text,
            mentions,
            steer: true,
        });
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
        let mentions = used.mentions.clone();
        // Not sent: the draft's recordings stay, whoever's draft it is now.
        if let (Some(held), Some(store)) = (used.recordings, self.dictation.clone()) {
            store.update(cx, |s, cx| s.send_settled(held, false, cx));
        }
        if self.composer.update(cx, |c, cx| c.give_back(used, cx)) {
            self.restore_with(text, &mentions, window, cx);
        }
    }

    /// The recordings the last message took from the draft, held until its
    /// send says how it went (into its [`OneShot`], for [`Self::give_back`]).
    pub fn take_sent_recordings(&mut self) -> Option<u64> {
        self.sent_recordings.take()
    }

    /// The message holding recordings `held` was taken: they go.
    pub fn recordings_taken(&mut self, held: Option<u64>, cx: &mut Context<Self>) {
        if let (Some(held), Some(store)) = (held, self.dictation.clone()) {
            store.update(cx, |s, cx| s.send_settled(held, true, cx));
        }
    }

    /// The message holding recordings `held` was not sent: they stay with
    /// their draft.
    pub fn recordings_kept(&mut self, held: Option<u64>, cx: &mut Context<Self>) {
        if let (Some(held), Some(store)) = (held, self.dictation.clone()) {
            store.update(cx, |s, cx| s.send_settled(held, false, cx));
        }
    }

    /// Puts text back after a refused send.
    pub fn restore(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.restore_with(text, &[], window, cx);
    }

    /// Puts text back with its `@`/`$` mentions as tokens again, so the
    /// next send carries them. Words typed since stay after it, with theirs
    /// (as [`OneShot::merge`](crate::stores::composer::OneShot::merge) keeps
    /// two unsent messages).
    pub fn restore_with(
        &mut self,
        text: &str,
        mentions: &[ComposerMentionDto],
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let typed = self.text(cx);
        let (text, mentions) = if typed.trim().is_empty() {
            // Dictation going on rebuilds the field from its base: the
            // refused words are that base now.
            if let Some(base) = self.dictation_base.as_mut() {
                *base = text.to_string();
            }
            (text.to_string(), mentions.to_vec())
        } else if text.trim().is_empty() {
            return;
        } else {
            let head = format!("{text}\n\n");
            let shift = head.encode_utf16().count() as i64;
            let mut all = mentions.to_vec();
            all.extend(self.mentions(cx).into_iter().map(|mut m| {
                m.start += shift;
                m.end += shift;
                m
            }));
            // What sits where the newer words are moves with them: an open
            // prompt form's place (bytes), and dictation's base, which the
            // next words heard (or a cancel) rebuild the field from.
            if let Some(form) = self.form.as_mut() {
                form.at += head.len();
            }
            if let Some(base) = self.dictation_base.as_mut() {
                base.insert_str(0, &head);
            }
            (format!("{head}{typed}"), all)
        };
        let content = content_with_mentions(&text, &mentions);
        let end = text.len();
        self.input.update(cx, |s, cx| {
            s.set_value(content, window, cx);
            s.set_selected_range(end..end, cx);
        });
        self.text_changed(cx);
    }

    fn text_changed(&mut self, cx: &mut Context<Self>) {
        let state = self.input.read(cx);
        let value = state.value().to_string();
        let cursor = state.cursor();
        self.composer
            .update(cx, |c, cx| c.draft_changed(&value, cx));
        let options = self.composer.read(cx).options.clone();
        // A trigger the model cannot take is plain text: `$` without Open
        // WebUI skills, `#` with Hermes.
        let channel_mode = self.channel_mode;
        let trigger = trigger_at(&value, cursor).filter(|t| match t.kind {
            _ if channel_mode => t.kind == TriggerKind::Model,
            TriggerKind::Skill => options.skills,
            TriggerKind::Knowledge => options.context,
            _ => true,
        });
        match &trigger {
            Some(t) if t.kind == TriggerKind::Prompt => {
                // A Hermes chat's commands are the connection in use's.
                let hermes = cx
                    .try_global::<crate::AppState>()
                    .and_then(|s| s.stores.hermes_admin.read(cx).connection());
                self.composer.update(cx, |c, cx| c.load_prompts(hermes, cx));
            }
            Some(t) if t.kind == TriggerKind::Knowledge => {
                let q = t.query.clone();
                self.composer.update(cx, |c, cx| c.search_context(&q, cx));
            }
            Some(t) if t.kind == TriggerKind::Model => {
                let q = t.query.clone();
                self.composer.update(cx, |c, cx| c.search_mentions(&q, cx));
            }
            Some(t) if t.kind == TriggerKind::Skill => {
                let q = t.query.clone();
                self.composer.update(cx, |c, cx| c.search_skills(&q, cx));
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
        self.entries(cx).len()
    }

    /// The open menu's rows, in their groups.
    fn entries(&self, cx: &App) -> Vec<Entry> {
        let Some(menu) = &self.menu else {
            return vec![];
        };
        let l10n = cx.l10n();
        let c = self.composer.read(cx);
        let query = &menu.trigger.query;
        let mut entries = vec![];
        match menu.trigger.kind {
            TriggerKind::Prompt => {
                for p in c
                    .prompts
                    .as_deref()
                    .map(|p| match_prompts(query, p, MENU_LIMIT))
                    .unwrap_or_default()
                {
                    entries.push(Entry {
                        group: None,
                        icon: IconName::SquareTerminal,
                        title: p.command.clone(),
                        detail: p.title.clone(),
                        pick: Pick::Prompt(p.clone()),
                    });
                }
            }
            TriggerKind::Model => {
                let models = c
                    .models
                    .as_ref()
                    .map(|m| match_models(query, &m.models, MENU_LIMIT))
                    .unwrap_or_default();
                let grouped = c.options.mentions
                    && (!c.mention_results.users.is_empty()
                        || !c.mention_results.channels.is_empty());
                for m in models {
                    entries.push(Entry {
                        group: grouped.then(|| l10n.desktop_mention_models()),
                        icon: IconName::Sparkles,
                        title: model_label(m),
                        detail: m.description.clone().unwrap_or_default(),
                        pick: Pick::Model(m.clone()),
                    });
                }
                if c.options.mentions {
                    for u in &c.mention_results.users {
                        entries.push(Entry {
                            group: Some(l10n.desktop_mention_people()),
                            icon: IconName::User,
                            title: u.name.clone(),
                            detail: u.detail.clone().unwrap_or_default(),
                            pick: Pick::Person(u.clone()),
                        });
                    }
                    for ch in &c.mention_results.channels {
                        entries.push(Entry {
                            group: Some(l10n.sidebar_channels_tab()),
                            icon: IconName::Hash,
                            title: ch.name.clone(),
                            detail: ch.detail.clone().unwrap_or_default(),
                            pick: Pick::Channel(ch.clone()),
                        });
                    }
                }
            }
            TriggerKind::Knowledge => {
                for k in &c.context_results {
                    let (group, icon, fallback) = match k.kind {
                        ContextSuggestionKind::Note => (
                            l10n.notes(),
                            IconName::NotebookPen,
                            l10n.desktop_untitled_note(),
                        ),
                        ContextSuggestionKind::KnowledgeBase => (
                            l10n.workspace_knowledge(),
                            IconName::BookOpen,
                            l10n.knowledge_base(),
                        ),
                        ContextSuggestionKind::KnowledgeFile | ContextSuggestionKind::Unknown => (
                            l10n.desktop_context_files(),
                            IconName::FileText,
                            l10n.desktop_context_file(),
                        ),
                    };
                    entries.push(Entry {
                        group: Some(group),
                        icon,
                        title: if k.name.trim().is_empty() {
                            fallback
                        } else {
                            k.name.clone()
                        },
                        detail: k.subtitle.clone().unwrap_or_default(),
                        pick: Pick::Context(k.clone()),
                    });
                }
            }
            TriggerKind::Skill => {
                for skill in c.skill_results.iter().take(MENU_LIMIT) {
                    entries.push(Entry {
                        group: None,
                        icon: IconName::Zap,
                        title: skill.name.clone(),
                        detail: skill.description.clone().unwrap_or_default(),
                        pick: Pick::Skill(skill.clone()),
                    });
                }
            }
        }
        entries
    }

    /// A key while a menu or the picker is open. True when it was used.
    pub(crate) fn menu_key(
        &mut self,
        key: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.panel.is_some() {
            return self.panel_key(key, window, cx);
        }
        if key == "escape" && self.expanded && self.menu.is_none() && self.picker.is_none() {
            self.set_expanded(false, window, cx);
            return true;
        }
        if let Some(picker) = &mut self.picker {
            // Esc in Custom…'s field puts the picker back.
            if let Some(custom) = &picker.custom
                && custom.read(cx).focus_handle(cx).is_focused(window)
            {
                if key == "escape" {
                    picker.custom = None;
                    picker.search.update(cx, |s, cx| s.focus(window, cx));
                    cx.notify();
                    return true;
                }
                return false;
            }
            let focused = picker.search.read(cx).focus_handle(cx).is_focused(window);
            if !focused {
                return false;
            }
            let models = self.picker_models(cx);
            let len = models.len();
            let picker = self.picker.as_mut().expect("checked");
            match key {
                "up" | "down" => {
                    picker.highlighted = menu_step(key, picker.highlighted, len);
                    if let Some(m) = models.get(picker.highlighted) {
                        let label = crate::stores::composer::model_label(m);
                        crate::views::a11y::announce_row(&label, picker.highlighted, len, cx);
                    }
                }
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
            "up" | "down" => {
                menu.highlighted = menu_step(key, menu.highlighted, len);
                self.announce_menu_row(cx);
            }
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

    /// Speaks the open `/`, `@`, `#` or `$` menu's highlighted row and its
    /// place ([`crate::views::a11y`]: the menu is the field's sibling, so
    /// its selection alone is never heard).
    fn announce_menu_row(&self, cx: &mut Context<Self>) {
        let Some(menu) = &self.menu else {
            return;
        };
        let entries = self.entries(cx);
        let total = entries.len();
        if let Some(entry) = entries.get(menu.highlighted.min(total.saturating_sub(1))) {
            let label = entry_label(entry);
            crate::views::a11y::announce_row(&label, menu.highlighted, total, cx);
        }
    }

    /// The open menu's trigger and rows as `(group, title)`, as drawn (the
    /// E2E pass reads them).
    pub fn menu_rows(&self, cx: &App) -> Option<(TriggerKind, MenuRows)> {
        let kind = self.menu.as_ref()?.trigger.kind;
        Some((
            kind,
            self.entries(cx)
                .into_iter()
                .map(|e| (e.group, e.title))
                .collect(),
        ))
    }

    /// The mentions the field holds now, as they would go out.
    pub fn mentions(&self, cx: &App) -> Vec<ComposerMentionDto> {
        let state = self.input.read(cx);
        let text = state.value().to_string();
        mentions_in(
            &text,
            state.tokens().iter().map(|span| {
                (
                    span.range(),
                    span.token().id().to_string(),
                    span.token().label().to_string(),
                )
            }),
        )
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
        // The mentions already in the field stay tokens.
        let new = cut_content(&state.content(), start..cursor);
        self.input.update(cx, |s, cx| {
            s.set_value(new, window, cx);
            s.set_selected_range(start..start, cx);
        });
        Some(start)
    }

    fn choose(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(pick) = self.entries(cx).into_iter().nth(index).map(|e| e.pick) else {
            return;
        };
        match pick {
            Pick::Prompt(prompt) => {
                let Some(at) = self.take_trigger(window, cx) else {
                    return;
                };
                // A Hermes command goes as typed: the agent runs it.
                if self.composer.read(cx).prompts_hermes {
                    let text = format!("{} ", prompt.command);
                    self.insert_at(at, &text, window, cx);
                    return;
                }
                self.render_prompt(prompt, at, BTreeMap::new(), window, cx);
            }
            Pick::Model(model) if self.channel_mode => {
                self.insert_mention(MentionTarget::Model(model.id), &model.name, window, cx)
            }
            Pick::Model(model) => {
                self.take_trigger(window, cx);
                self.composer
                    .update(cx, |c, cx| c.set_mention(Some(model), cx));
            }
            Pick::Person(p) => self.insert_mention(MentionTarget::User(p.id), &p.name, window, cx),
            Pick::Channel(p) => {
                self.insert_mention(MentionTarget::Channel(p.id), &p.name, window, cx)
            }
            Pick::Skill(skill) => {
                self.insert_mention(MentionTarget::Skill(skill.id), &skill.name, window, cx)
            }
            Pick::Context(item) => {
                self.take_trigger(window, cx);
                self.composer.update(cx, |c, cx| match item.kind {
                    ContextSuggestionKind::KnowledgeBase => c.add_knowledge(
                        KnowledgeSummary {
                            id: item.id,
                            name: item.name,
                            description: item.subtitle,
                        },
                        cx,
                    ),
                    ContextSuggestionKind::Note => c.add_context(
                        ContextAttachmentDto {
                            id: item.id,
                            kind: ContextAttachmentKind::Note,
                            name: item.name,
                            url: None,
                            content: None,
                            collection_name: None,
                            file_id: None,
                        },
                        cx,
                    ),
                    ContextSuggestionKind::KnowledgeFile | ContextSuggestionKind::Unknown => c
                        .add_context(
                            ContextAttachmentDto {
                                id: format!("file-{}", item.id),
                                kind: ContextAttachmentKind::Knowledge,
                                name: item.name,
                                url: None,
                                content: None,
                                collection_name: item.collection_name,
                                file_id: Some(item.id),
                            },
                            cx,
                        ),
                });
            }
        }
        self.focus_input(window, cx);
        cx.notify();
    }

    /// Replaces the trigger word with an atomic `@Name` or `$Name` token and
    /// a space, as Open WebUI and the phone show a mention.
    fn insert_mention(
        &mut self,
        target: MentionTarget,
        name: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(start) = self.take_trigger(window, cx) else {
            return;
        };
        let token = InlineToken::new(target.token_id(), format!("{}{name}", target.sigil()))
            .with_label(name.to_string());
        self.input.update(cx, |s, cx| {
            if s.replace_range_with_token(start..start, token, window, cx)
                .is_ok()
            {
                let at = s.cursor();
                s.set_selected_range(at..at, cx);
                s.insert(" ", window, cx);
            }
        });
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

    /// A fresh composition starts with `text` alone, even in the new chat
    /// already shown (the same draft, so no draft switch): the last
    /// composition's prompt form, panel and menu go, a prompt still being
    /// rendered for it, a send still out and its dictation land nowhere, and
    /// what applied to the last message is cleared. (Writing the text replaces a draft read still on its way:
    /// [`ComposerStore::draft_changed`].)
    pub fn start_fresh(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        // The draft starts over: a send still out from the last composition
        // gives nothing back to this one.
        self.composer.update(cx, |c, cx| c.start_over(cx));
        self.form = None;
        self.prompt_request += 1;
        self.panel = None;
        self.menu = None;
        // Dictation for the last composition ends: with no base left, its
        // later words and its cancel write nothing.
        self.dictation_base = None;
        self.cancel_dictation(window, cx);
        self.set_text(text, window, cx);
        cx.notify();
    }

    /// Another account: drops a prompt form filled for the last one, and
    /// any render still on its way. (A refresh of the same account keeps it.)
    pub fn forget_account(&mut self, cx: &mut Context<Self>) {
        self.form = None;
        self.prompt_request += 1;
        // A panel's list or page is the last account's.
        self.panel = None;
        cx.notify();
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

    /// The picker's rows as drawn ([`crate::stores::composer::picker_rows`]).
    fn picker_rows(&self, cx: &App) -> Vec<crate::stores::composer::PickerRow> {
        let Some(picker) = self.picker.as_ref().or(self.leaving_picker.as_ref()) else {
            return vec![];
        };
        let query = picker.search.read(cx).value().to_string();
        let Some(list) = &self.composer.read(cx).models else {
            return vec![];
        };
        crate::stores::composer::picker_rows(
            list,
            &query,
            picker.more,
            &cx.l10n().model_picker_coding_agents(),
        )
    }

    /// The models the arrows step through, in the order drawn.
    fn picker_models(&self, cx: &App) -> Vec<ModelSummary> {
        self.picker_rows(cx)
            .into_iter()
            .filter_map(|r| match r {
                crate::stores::composer::PickerRow::Model(m) => Some(m),
                crate::stores::composer::PickerRow::Heading(_) => None,
            })
            .collect()
    }

    /// More Models, and back to the short list.
    pub fn toggle_more_models(&mut self, cx: &mut Context<Self>) {
        if let Some(p) = &mut self.picker {
            p.more = !p.more;
            cx.notify();
        }
    }

    /// The reasoning effort menu (a native menu): the presets, the current
    /// one checked, then Custom… when the model takes another value.
    fn show_effort_menu(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        use gpui_kit::component::native_menu::NativeMenu;
        let Some(options) = self.composer.read(cx).model_options.clone() else {
            return;
        };
        let l10n = cx.l10n().clone();
        let reasoning = options.reasoning;
        let mut menu = NativeMenu::new();
        let current = reasoning.current.clone();
        let mut custom = !reasoning.options.contains(&current);
        for option in &reasoning.options {
            menu = menu.menu_with_check(
                crate::views::chat_settings::effort_label(option, &l10n),
                *option == current,
                Box::new(PickerAction::Effort(option.clone())),
            );
        }
        if reasoning.allows_custom {
            menu = menu.separator();
            if custom {
                menu = menu.menu_with_check(
                    current.clone(),
                    true,
                    Box::new(PickerAction::CustomEffort),
                );
                custom = false;
            }
            menu = menu.menu(
                l10n.desktop_custom_ellipsis(),
                Box::new(PickerAction::CustomEffort),
            );
        }
        let _ = custom;
        menu.show(window.mouse_position(), window, cx);
    }

    /// A control's menu (a native menu): its options, the one in force
    /// checked, as mobile's selection sheet lists them.
    fn show_control_menu(&mut self, key: &str, window: &mut Window, cx: &mut Context<Self>) {
        use gpui_kit::component::native_menu::NativeMenu;
        let Some(control) = self
            .composer
            .read(cx)
            .model_controls
            .as_ref()
            .and_then(|l| l.controls.iter().find(|c| c.key == key).cloned())
        else {
            return;
        };
        let l10n = cx.l10n().clone();
        let mut menu = NativeMenu::new();
        for option in &control.options {
            menu = menu.menu_with_check(
                model_control_option_label(&control, Some(&option.value), &l10n),
                control.value.as_deref() == Some(option.value.as_str()),
                Box::new(PickerAction::Control(
                    control.key.clone(),
                    option.value.clone(),
                )),
            );
        }
        menu.show(window.mouse_position(), window, cx);
    }

    fn on_picker_action(
        &mut self,
        action: &PickerAction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match action {
            PickerAction::Effort(effort) => {
                let effort = effort.clone();
                self.composer
                    .update(cx, |c, cx| c.set_reasoning_effort(&effort, cx));
                if let Some(p) = &mut self.picker {
                    p.custom = None;
                }
            }
            PickerAction::CustomEffort => self.start_custom_effort(window, cx),
            PickerAction::Pin(id, pinned) => {
                let (id, pinned) = (id.clone(), *pinned);
                self.composer
                    .update(cx, |c, cx| c.set_pinned(&id, pinned, cx));
            }
            PickerAction::Control(key, value) => {
                let (key, value) = (key.clone(), value.clone());
                self.composer
                    .update(cx, |c, cx| c.set_model_control(&key, &value, cx));
            }
        }
        cx.notify();
    }

    /// Custom…: a field under Reasoning Effort; Return saves what is typed,
    /// Esc puts the picker back.
    fn start_custom_effort(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let placeholder = cx.l10n().desktop_custom_effort_hint();
        let current = self
            .composer
            .read(cx)
            .model_options
            .as_ref()
            .map(|o| o.reasoning.current.clone())
            .filter(|c| c != "automatic")
            .unwrap_or_default();
        let input = cx.new(|cx| {
            let mut s = InputState::new(window, cx).placeholder(placeholder);
            s.set_value(current, window, cx);
            s
        });
        self._subscriptions.push(cx.subscribe_in(
            &input,
            window,
            |this, state, e: &InputEvent, window, cx| {
                if let InputEvent::PressEnter { .. } = e {
                    let text = state.read(cx).value().trim().to_string();
                    if !text.is_empty() {
                        this.composer
                            .update(cx, |c, cx| c.set_reasoning_effort(&text, cx));
                    }
                    if let Some(p) = &mut this.picker {
                        p.custom = None;
                        p.search.update(cx, |s, cx| s.focus(window, cx));
                    }
                    cx.notify();
                }
            },
        ));
        input.update(cx, |s, cx| {
            s.focus(window, cx);
            s.select_all(window, cx);
        });
        if let Some(p) = &mut self.picker {
            p.custom = Some(input);
        }
        cx.notify();
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
            more: false,
            custom: None,
        });
        if let Some(id) = selected
            && let Some(i) = self.picker_models(cx).iter().position(|m| m.id == id)
            && let Some(p) = &mut self.picker
        {
            p.highlighted = i;
        }
        self.composer.update(cx, |c, cx| {
            c.refresh_models(cx);
            c.refresh_model_options(cx);
        });
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

    /// The + menu, in mobile's sections: attachments (Attach Files…,
    /// Continuity Camera's place, Server Files…, Web Page…, MCP
    /// Content…), the features (Web Search, Image Generation, Code
    /// Interpreter, Compare Models…, Save as Note), then Tools (the
    /// server's, the personal tool servers, the Direct MCP servers,
    /// LibreChat's), Filters and Terminal under their headings. Switches
    /// show a check while on. AppKit shows it on macOS (with Continuity
    /// Camera's items), GPUI Kit's native menu elsewhere: both from
    /// [`Self::plus_rows`].
    pub(crate) fn show_plus_menu(
        &mut self,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let rows = self.plus_rows(window, cx);
        // The menu's action goes to the focused element's path: keep focus
        // in the composer so its handler hears it.
        self.focus_input(window, cx);
        // The entries as drawn, to measure the menu (`None`: a separator).
        let entries: Vec<Option<String>> = rows
            .iter()
            .filter_map(|r| match r {
                PlusRow::Item { label, .. } => Some(Some(label.clone())),
                PlusRow::Separator => Some(None),
                PlusRow::ImportFromDevice => None,
            })
            .collect();
        let origin = self.plus_menu_origin(&entries, position);
        #[cfg(target_os = "macos")]
        self.show_plus_rows(rows, origin, window, cx);
        #[cfg(not(target_os = "macos"))]
        {
            use gpui_kit::component::native_menu::NativeMenu;
            let mut menu = NativeMenu::new();
            for row in rows {
                menu = match row {
                    PlusRow::Item {
                        label,
                        disabled,
                        checked: Some(on),
                        action,
                    } if !disabled => menu.menu_with_check(label, on, Box::new(action)),
                    PlusRow::Item {
                        label,
                        disabled,
                        action,
                        ..
                    } => menu.menu_with_disabled(label, disabled, Box::new(action)),
                    PlusRow::Separator => menu.separator(),
                    PlusRow::ImportFromDevice => menu,
                };
            }
            menu.show(origin, window, cx);
        }
    }

    /// The + menu's rows, in order (see [`Self::show_plus_menu`]).
    pub(crate) fn plus_rows(&self, window: &Window, cx: &App) -> Vec<PlusRow> {
        let l10n = cx.l10n().clone();
        let has_text = !self.text(cx).trim().is_empty();
        let store = self.composer.read(cx);
        let options = store.options.clone();
        let (web, image, code) = (
            store.web_search,
            store.image_generation,
            store.code_interpreter,
        );
        let tool_ids = store.tool_ids.clone();
        let filter_ids = store.filter_ids.clone();
        // Save as Note is the main window's (not Quick Ask's).
        let notes_button = self.follow_ups && store.prefs.show_notes_button;
        // The rows in order; shown by AppKit (with Continuity Camera's
        // items) or GPUI Kit's native menu.
        let mut rows: Vec<PlusRow> = vec![];
        let item = |rows: &mut Vec<PlusRow>,
                    label: String,
                    disabled: bool,
                    checked: Option<bool>,
                    action: ComposerMenu| {
            rows.push(PlusRow::Item {
                label,
                disabled,
                checked,
                action,
            });
        };
        let a = &options.attachments;
        let ellipsis = |s: String| format!("{s}\u{2026}");
        item(
            &mut rows,
            ellipsis(l10n.desktop_attach_files()),
            !(a.files || a.images),
            None,
            ComposerMenu::AttachFiles,
        );
        // Take Photo and Scan Documents with a nearby iPhone or iPad
        // (Continuity Camera): AppKit's own items, in the main window's
        // composer while it takes pictures.
        let in_main = cx
            .try_global::<crate::AppState>()
            .and_then(|s| s.main_window)
            == Some(window.window_handle());
        if a.images && in_main {
            rows.push(PlusRow::ImportFromDevice);
        }
        if a.server_files {
            item(
                &mut rows,
                ellipsis(l10n.composer_attach_server_files()),
                false,
                None,
                ComposerMenu::ServerFiles,
            );
        }
        if a.web_page {
            item(
                &mut rows,
                ellipsis(l10n.web_page()),
                false,
                None,
                ComposerMenu::WebPage,
            );
        }
        if a.mcp_content {
            item(
                &mut rows,
                ellipsis(l10n.direct_mcp_content_action()),
                false,
                None,
                ComposerMenu::McpContent,
            );
        }
        // Features.
        let code_shown = options.code_interpreter || code;
        let draft_note = notes_button && options.notes && has_text && !self.streaming;
        // Not for a temporary chat, which the server never stores.
        let compare = options.compare_models && self.compare_ui && !self.temporary;
        if options.web_search || options.image_generation || code_shown || compare || draft_note {
            rows.push(PlusRow::Separator);
        }
        if options.web_search {
            item(
                &mut rows,
                l10n.web_search(),
                false,
                Some(web),
                ComposerMenu::WebSearch,
            );
        }
        if options.image_generation {
            item(
                &mut rows,
                l10n.desktop_image_generation(),
                false,
                Some(image),
                ComposerMenu::ImageGeneration,
            );
        }
        if code_shown {
            // One that will not run stays visible, off, to say so; one chosen
            // can always be turned off.
            let blocked = options.code_interpreter_block.is_some();
            item(
                &mut rows,
                l10n.code_interpreter(),
                blocked && !code,
                Some(code),
                ComposerMenu::CodeInterpreter,
            );
        }
        if compare {
            item(
                &mut rows,
                ellipsis(l10n.chat_compare_models_action()),
                !has_text,
                None,
                ComposerMenu::CompareModels,
            );
        }
        if draft_note {
            item(
                &mut rows,
                l10n.composer_save_draft_as_note(),
                false,
                None,
                ComposerMenu::SaveAsNote,
            );
        }
        // Tools, then filters, each under its heading. A LibreChat model's
        // own switches (web search, code, file search, the user's MCP
        // servers) are tools here too.
        let tools: Vec<_> = options.tools.iter().chain(&options.mcp_tools).collect();
        let librechat = store.librechat_tools();
        if !tools.is_empty() || !librechat.is_empty() {
            rows.push(PlusRow::Separator);
            item(&mut rows, l10n.tools(), true, None, ComposerMenu::Heading);
            for tool in tools {
                item(
                    &mut rows,
                    tool.name.clone(),
                    false,
                    Some(tool_ids.contains(&tool.id)),
                    ComposerMenu::Tool(tool.id.clone()),
                );
            }
            for (id, tool) in librechat {
                let (label, action) = match tool {
                    LibreChatTool::WebSearch => (l10n.web_search(), ComposerMenu::Tool(id.clone())),
                    LibreChatTool::CodeInterpreter => {
                        (l10n.code_interpreter(), ComposerMenu::Tool(id.clone()))
                    }
                    LibreChatTool::FileSearch => (
                        l10n.libre_chat_file_search(),
                        ComposerMenu::Tool(id.clone()),
                    ),
                    // Signed in to in LibreChat's web app: the item opens it.
                    LibreChatTool::Mcp {
                        name,
                        needs_connection: true,
                    } => (
                        format!("{name} — {}", l10n.libre_chat_mcp_connect()),
                        ComposerMenu::ConnectInLibreChat,
                    ),
                    LibreChatTool::Mcp { name, .. } => (name, ComposerMenu::Tool(id.clone())),
                };
                let checked =
                    matches!(action, ComposerMenu::Tool(_)).then(|| tool_ids.contains(&id));
                item(&mut rows, label, false, checked, action);
            }
        }
        if !options.filters.is_empty() {
            rows.push(PlusRow::Separator);
            item(&mut rows, l10n.filters(), true, None, ComposerMenu::Heading);
            for filter in &options.filters {
                item(
                    &mut rows,
                    filter.name.clone(),
                    false,
                    Some(filter_ids.contains(&filter.id)),
                    ComposerMenu::Filter(filter.id.clone()),
                );
            }
        }
        // The terminal its tool uses, as mobile's Tools section offers it
        // (Open WebUI turns only; a server that needs a saved chat waits
        // for one).
        let chat_saved = self
            .composer
            .read(cx)
            .draft_key()
            .is_some_and(|k| k.chat_id.is_some());
        let terminals: Vec<(String, String, bool)> = cx
            .try_global::<crate::AppState>()
            .map(|s| s.stores.areas.read(cx))
            .filter(|_| options.context)
            .map(|areas| {
                areas
                    .terminals
                    .iter()
                    .flatten()
                    .filter(|t| chat_saved || !t.requires_saved_chat)
                    .map(|t| {
                        let name = if t.name.trim().is_empty() {
                            t.id.clone()
                        } else {
                            t.name.clone()
                        };
                        (
                            t.id.clone(),
                            name,
                            areas.terminal_selected.as_deref() == Some(t.id.as_str()),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default();
        if !terminals.is_empty() {
            rows.push(PlusRow::Separator);
            item(
                &mut rows,
                l10n.terminal(),
                true,
                None,
                ComposerMenu::Heading,
            );
            for (id, name, selected) in terminals {
                item(
                    &mut rows,
                    name,
                    false,
                    Some(selected),
                    ComposerMenu::Terminal(id),
                );
            }
        }
        rows
    }

    /// The + menu built by the app (AppKit's NSMenu), with Continuity
    /// Camera's placeholder ([`crate::shell::continuity_camera`]); the item
    /// chosen does what GPUI Kit's menu would dispatch. AppKit's tracking
    /// loop runs from a task, outside any GPUI borrow.
    #[cfg(target_os = "macos")]
    fn show_plus_rows(
        &mut self,
        rows: Vec<PlusRow>,
        origin: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        use crate::shell::continuity_camera::{self as camera, Entry};
        let mut actions: Vec<ComposerMenu> = vec![];
        let mut import = false;
        let entries: Vec<Entry> = rows
            .into_iter()
            .map(|row| match row {
                PlusRow::Item {
                    label,
                    disabled,
                    checked,
                    action,
                } => {
                    let index = (!disabled).then(|| {
                        actions.push(action);
                        actions.len() - 1
                    });
                    Entry::Item {
                        label,
                        disabled,
                        checked: checked.unwrap_or(false) && !disabled,
                        action: index,
                    }
                }
                PlusRow::Separator => Entry::Separator,
                PlusRow::ImportFromDevice => {
                    import = true;
                    Entry::ImportFromDevice
                }
            })
            .collect();
        let Some(ns_window) = crate::shell::macos::ns_window(window) else {
            return;
        };
        if import {
            // This menu session's ticket: what a device sends through it is
            // for this composer, this composition and this account scope
            // alone.
            let composer = self.composer.read(cx);
            let target = crate::shell::continuity_camera::ImportTarget {
                scope: cx
                    .try_global::<crate::AppState>()
                    .and_then(|s| s.stores.accounts.read(cx).scope_key()),
                draft: composer.draft_key().cloned(),
                round: composer.draft_round(),
            };
            crate::desktop::install_continuity_camera(&ns_window, target, cx);
        }
        // The menu's choice acts on this composition only.
        let ticket = self.composer.read(cx).ticket();
        cx.spawn_in(window, async move |this, cx| {
            let Some(view) = ns_window.contentView() else {
                return;
            };
            // `origin` is window-relative, top-left; AppKit's view
            // coordinates start at the bottom-left.
            let location = objc2_foundation::NSPoint::new(
                f32::from(origin.x) as f64,
                view.bounds().size.height - f32::from(origin.y) as f64,
            );
            // The requestor answers only while this menu is open.
            let report =
                camera::while_menu_tracks(import, || camera::popup(&view, &entries, location));
            let _ = this.update_in(cx, |this, window, cx| {
                if let Some(action) = report.chosen.and_then(|i| actions.get(i))
                    && this.composer.read(cx).holds(ticket)
                {
                    this.on_menu(action, window, cx);
                }
                // As GPUI Kit's menu does: wake the window after AppKit's
                // tracking loop.
                window.refresh();
                cx.notify();
            });
        })
        .detach();
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

    pub fn on_menu(&mut self, action: &ComposerMenu, window: &mut Window, cx: &mut Context<Self>) {
        let composer = self.composer.clone();
        match action {
            ComposerMenu::AttachFiles => self.pick_files(window, cx),
            ComposerMenu::ServerFiles => self.open_server_files(window, cx),
            ComposerMenu::WebPage => self.open_web_page(window, cx),
            ComposerMenu::McpContent => self.open_mcp(window, cx),
            ComposerMenu::WebSearch => composer.update(cx, |c, cx| c.toggle_web_search(cx)),
            ComposerMenu::ImageGeneration => {
                composer.update(cx, |c, cx| c.toggle_image_generation(cx))
            }
            ComposerMenu::CodeInterpreter => {
                composer.update(cx, |c, cx| c.toggle_code_interpreter(cx))
            }
            ComposerMenu::CompareModels => self.choose_compare_model(window, cx),
            ComposerMenu::SaveAsNote => {
                let text = self.text(cx);
                if !text.trim().is_empty() {
                    cx.emit(ChatComposerEvent::SaveAsNote(text));
                }
            }
            ComposerMenu::Tool(id) => composer.update(cx, |c, cx| c.toggle_tool(id, cx)),
            ComposerMenu::ConnectInLibreChat => {
                let url = composer.read(cx).librechat.web_url.clone();
                if let Some(url) = url.as_deref().and_then(crate::shell::open_url::validate) {
                    cx.open_url(url.as_str());
                }
            }
            ComposerMenu::Filter(id) => composer.update(cx, |c, cx| c.toggle_filter(id, cx)),
            ComposerMenu::Terminal(id) => {
                crate::views::terminal::chat::toggle_terminal(id.clone(), cx)
            }
            ComposerMenu::Heading => {}
        }
    }

    /// Compare Models…: a menu of the other models, from the + button; the
    /// one chosen answers the next message too, side by side.
    fn choose_compare_model(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let store = self.composer.read(cx);
        let first = store.next_model().map(|m| m.id.clone());
        let others: Vec<ModelSummary> = store
            .models
            .as_ref()
            .map(|l| {
                l.models
                    .iter()
                    .filter(|m| Some(&m.id) != first.as_ref())
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        if others.is_empty() {
            return;
        }
        let chosen = store.compare_with.as_ref().map(|m| m.id.clone());
        let weak = self.composer.downgrade();
        let mut menu = gpui_kit::component::native_menu::NativeMenu::new();
        for m in others {
            menu = menu.menu_with_check(
                model_label(&m),
                chosen.as_deref() == Some(m.id.as_str()),
                Box::new(CompareWith {
                    composer: weak.clone(),
                    model: m.clone(),
                }),
            );
        }
        let at = self
            .plus_bounds
            .get()
            .map(|b| gpui_kit::point(b.left(), b.top() - px(4.)))
            .unwrap_or_default();
        menu.show(at, window, cx);
    }

    /// Clears the field after its text was kept as a note.
    pub fn clear_text(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.take_text(window, cx);
        cx.notify();
    }

    // ── Panels ──────────────────────────────────────────────────────────

    fn open_server_files(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        use crate::views::server_files::{ServerFilesEvent, ServerFilesPicker};
        let rpc = self.composer.read(cx).rpc();
        let picker = cx.new(|cx| ServerFilesPicker::new(rpc, window, cx));
        let subscription = cx.subscribe_in(&picker, window, |this, _, e, window, cx| match e {
            ServerFilesEvent::Picked(file) => this.attach_server_file(file.clone(), window, cx),
            ServerFilesEvent::Dismissed => this.close_panel(window, cx),
        });
        self.panel = Some(Panel::ServerFiles(
            super::composer_panels::ServerFilesPanel::new(picker, subscription),
        ));
        cx.notify();
    }

    /// The server-file picker's choice: attached as it is.
    pub(crate) fn attach_server_file(
        &mut self,
        file: conduit_protocol::ServerFile,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.composer
            .update(cx, |c, cx| c.add_server_file(&file, cx));
        self.panel = None;
        self.focus_input(window, cx);
        cx.notify();
    }

    fn open_web_page(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let panel = super::composer_panels::WebPagePanel::new(window, cx);
        self.panel = Some(Panel::WebPage(panel));
        cx.notify();
    }

    /// Web Page › Attach: the server reads it; the panel says why when it
    /// cannot.
    pub(crate) fn fetch_web_page(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(Panel::WebPage(panel)) = &mut self.panel else {
            return;
        };
        let url = panel.url.read(cx).value().trim().to_string();
        let l10n = cx.l10n().clone();
        if !url.starts_with("http://") && !url.starts_with("https://") {
            panel.error = Some(l10n.invalid_http_url());
            cx.notify();
            return;
        }
        panel.busy = true;
        panel.error = None;
        let id = panel.id;
        let task = self.composer.update(cx, |c, cx| c.fetch_url(&url, cx));
        cx.spawn_in(window, async move |this, cx| {
            let result = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                // Only the panel that asked takes the page: closed, or
                // another account or chat since, it is dropped.
                if !matches!(&this.panel, Some(Panel::WebPage(p)) if p.id == id) {
                    return;
                }
                let error = match result {
                    Ok(fetched) => match (fetched.attachment, fetched.error.as_deref()) {
                        (Some(attachment), _) => {
                            this.composer
                                .update(cx, |c, cx| c.add_context(attachment, cx));
                            this.panel = None;
                            this.focus_input(window, cx);
                            None
                        }
                        (None, Some("invalidUrl")) => Some(l10n.invalid_http_url()),
                        (None, Some("noContent")) => {
                            Some(if super::composer_panels::is_youtube(&url) {
                                l10n.youtube_transcript_fetch_failed()
                            } else {
                                l10n.webpage_no_readable_content()
                            })
                        }
                        _ => Some(l10n.failed_to_attach_content()),
                    },
                    Err(e) => {
                        log::warn!("context.fetchUrl: {e}");
                        Some(l10n.failed_to_attach_content())
                    }
                };
                if let Some(Panel::WebPage(panel)) = &mut this.panel {
                    panel.busy = false;
                    panel.error = error;
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn open_mcp(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let rpc = self.composer.read(cx).rpc();
        let panel = super::composer_panels::McpPanel::new(rpc, window, cx);
        self.panel = Some(Panel::Mcp(Box::new(panel)));
        cx.notify();
    }

    /// Puts `text` at the caret (Ask Conduit) and focuses the field.
    pub fn insert_at_caret(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        let at = self.input.read(cx).cursor();
        self.insert_at(at, text, window, cx);
        self.text_changed(cx);
    }

    /// Words the core gives this chat (`composer.insertText`: Hermes'
    /// prefill), at the caret.
    pub fn take_given_text(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        if text.is_empty() {
            return;
        }
        self.insert_at_caret(text, window, cx);
    }

    /// MCP Content › Insert: the prompt's or resource's text, at the caret.
    pub(crate) fn insert_text(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        let at = self.input.read(cx).cursor();
        self.panel = None;
        self.insert_at(at, text, window, cx);
        self.text_changed(cx);
    }

    pub(crate) fn close_panel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.panel = None;
        self.focus_input(window, cx);
        cx.notify();
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
        // Chosen for this composition: not attached to one that replaced it.
        let ticket = composer.read(cx).ticket();
        cx.spawn_in(window, async move |_, cx| {
            if let Ok(Ok(Some(paths))) = paths.await {
                composer.update(cx, |c, cx| {
                    if c.holds(ticket) {
                        c.add_paths(&paths, cx);
                    }
                });
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

/// Why a chosen code interpreter will not run, by the core's
/// `CodeInterpreterBlock` name, in mobile's words.
/// Dictated `words` after `base`: a space between, as the phone joins them.
pub fn join_dictated(base: &str, words: &str) -> String {
    let base = base.trim_end();
    if base.is_empty() {
        words.to_string()
    } else if words.is_empty() {
        base.to_string()
    } else {
        format!("{base} {words}")
    }
}

fn code_interpreter_reason(block: &str, l10n: &crate::l10n::L10n) -> String {
    match block {
        "unsupportedEngine" => l10n.code_interpreter_browser_engine(),
        _ => l10n.code_interpreter_unavailable(),
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

/// A chip for context that goes with the message: a note, a knowledge file,
/// a web page or a transcript.
fn context_chip(
    c: &ContextAttachmentDto,
    composer: &Entity<ComposerStore>,
    t: &ConduitTheme,
    cx: &App,
) -> AnyElement {
    let r = t.roles;
    let l10n = cx.l10n();
    let ic = match c.kind {
        ContextAttachmentKind::Note => IconName::NotebookPen,
        ContextAttachmentKind::Knowledge => IconName::FileText,
        ContextAttachmentKind::Web => IconName::Globe,
        ContextAttachmentKind::Youtube => IconName::Captions,
        ContextAttachmentKind::Unknown => IconName::FileText,
    };
    let kind = match c.kind {
        ContextAttachmentKind::Note => l10n.alert_note(),
        ContextAttachmentKind::Knowledge => l10n.desktop_context_file(),
        ContextAttachmentKind::Web => l10n.web_page(),
        ContextAttachmentKind::Youtube => l10n.desktop_youtube_transcript(),
        ContextAttachmentKind::Unknown => l10n.desktop_context_file(),
    };
    let composer = composer.clone();
    let id = c.id.clone();
    div()
        .id(ElementId::Name(format!("context-{}", c.id).into()))
        .role(Role::Group)
        .aria_label(SharedString::from(format!("{kind}: {}", c.name)))
        .h(px(26.))
        .max_w(px(260.))
        .pl(px(8.))
        .pr(px(3.))
        .flex()
        .items_center()
        .gap(px(5.))
        .rounded_full()
        .bg(r.selected)
        .text_size(px(t.metrics.small))
        .text_color(r.text)
        .child(icon(ic, 12., r.text_subtle))
        .child(
            div()
                .min_w_0()
                .truncate()
                .child(SharedString::from(c.name.clone())),
        )
        .child(
            IconButton::new(
                ElementId::Name(format!("context-{}-remove", c.id).into()),
                IconName::X,
                l10n.desktop_remove_attachment(&c.name),
            )
            .size(20., 11.)
            .on_click(Rc::new(move |_, _, cx| {
                composer.update(cx, |c, cx| c.remove_context(&id, cx))
            })),
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
    let failed = a.failed();
    let detail = match (&a.state, progress) {
        (UploadState::Failed { .. }, _) => l10n.desktop_attachment_failed(&a.name),
        (UploadState::Converting, _) => l10n.desktop_attachment_converting(),
        (UploadState::Waiting, _) => l10n.desktop_attachment_retrying(),
        (_, Some(p)) => l10n.desktop_uploading_percent((p * 100.) as i64),
        _ if a.server_file => l10n.composer_attach_server_files(),
        _ => human_size(a.size),
    };
    let id = a.local_id;
    let retry = a.can_retry().then(|| {
        let composer = composer.clone();
        IconButton::new(
            ElementId::NamedInteger("retry-attachment".into(), id),
            IconName::RotateCcw,
            l10n.desktop_try_again(),
        )
        .size(20., 12.)
        .tooltip(l10n.desktop_try_again())
        .on_click(Rc::new(move |_, _, cx| {
            composer.update(cx, |c, cx| c.retry_attachment(id, cx));
        }))
    });
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
        .children(retry)
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
    /// Where the open menu hangs, from the composer's top-left: over the
    /// trigger's sigil, its bottom 6 pt above that line (above the whole
    /// composer when the field is not laid out yet), kept inside the frame.
    fn menu_anchor(&self, width: f32, cx: &App) -> (f32, f32) {
        let (Some(menu), Some(frame)) = (&self.menu, self.frame_bounds.get()) else {
            return (0., 0.);
        };
        let start = menu.trigger.start;
        let Some(caret) = self.input.read(cx).range_to_bounds(&(start..start)) else {
            return (0., f32::from(frame.size.height) + 6.);
        };
        let max_left = (f32::from(frame.size.width) - width).max(0.);
        let left = (f32::from(caret.left() - frame.left()) - 8.).clamp(0., max_left);
        let bottom = f32::from(frame.bottom() - caret.top()) + 6.;
        (left, bottom)
    }

    fn menu_view(&self, t: &ConduitTheme, cx: &mut Context<Self>) -> Option<AnyElement> {
        let menu = self.menu.as_ref()?;
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let m = t.metrics;
        // A Hermes chat's `/` lists the agent's skills, as on a phone.
        let hermes = self.composer.read(cx).prompts_hermes;
        let label = match menu.trigger.kind {
            TriggerKind::Prompt if hermes => l10n.hermes_capability_skills(),
            TriggerKind::Prompt => l10n.desktop_prompt_menu(),
            TriggerKind::Model => l10n.desktop_mention_menu(),
            TriggerKind::Knowledge => l10n.desktop_knowledge_menu(),
            TriggerKind::Skill => l10n.workspace_skills(),
        };
        let empty = match menu.trigger.kind {
            TriggerKind::Prompt if hermes => l10n.desktop_no_skills_match(),
            TriggerKind::Prompt => l10n.desktop_no_prompts_match(),
            TriggerKind::Model => l10n.desktop_no_models_available(),
            TriggerKind::Knowledge => l10n.desktop_no_knowledge_match(),
            TriggerKind::Skill => l10n.desktop_no_skills_match(),
        };
        let entries = self.entries(cx);
        let total = entries.len();
        let grouped = entries.iter().any(|e| e.group.is_some());
        let highlighted = menu.highlighted.min(total.saturating_sub(1));
        const WIDTH: f32 = 360.;
        let (left, bottom) = self.menu_anchor(WIDTH, cx);
        let mut rows: Vec<AnyElement> = vec![];
        let mut group: Option<String> = None;
        for (i, entry) in entries.into_iter().enumerate() {
            if entry.group.is_some() && entry.group != group {
                group = entry.group.clone();
                rows.push(
                    div()
                        .px(px(8.))
                        .pt(px(if i == 0 { 2. } else { 8. }))
                        .pb(px(3.))
                        .text_size(px(m.caption))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text_subtle)
                        .child(SharedString::from(group.clone().unwrap_or_default()))
                        .into_any_element(),
                );
            }
            let hot = i == highlighted;
            rows.push(
                div()
                    .id(ElementId::NamedInteger(
                        "composer-menu-item".into(),
                        i as u64,
                    ))
                    .role(Role::MenuItem)
                    .aria_label(SharedString::from(entry_label(&entry)))
                    .aria_selected(hot)
                    .aria_position_in_set(i + 1)
                    .aria_size_of_set(total)
                    .min_h(px(m.row_height + 6.))
                    .px(px(8.))
                    .py(px(3.))
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .rounded(px(7.))
                    .when(hot, |d| d.bg(r.overlay_hover))
                    .hover(|s| s.bg(r.overlay_hover))
                    .cursor_pointer()
                    .child(icon(entry.icon, 14., r.text_subtle))
                    .child(
                        div()
                            .flex_none()
                            .max_w(px(200.))
                            .truncate()
                            .text_size(px(m.control))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(r.text)
                            .child(SharedString::from(entry.title)),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(px(m.small))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(entry.detail)),
                    )
                    .on_click(cx.listener(move |this, _, window, cx| this.choose(i, window, cx)))
                    .into_any_element(),
            );
        }
        Some(
            div()
                .id("composer-menu")
                .role(Role::Menu)
                .aria_label(SharedString::from(label.clone()))
                .absolute()
                .bottom(px(bottom))
                .left(px(left))
                .w(px(WIDTH))
                .max_h(px(340.))
                .overflow_y_scroll()
                .p(px(6.))
                .flex()
                .flex_col()
                .rounded(t.overlay_radius())
                .border_1()
                .border_color(r.border_strong)
                .bg(r.overlay)
                .shadow(overlay_shadow(t))
                .occlude()
                .when(!grouped, |d| {
                    d.child(
                        div()
                            .px(px(8.))
                            .pt(px(4.))
                            .pb(px(4.))
                            .text_size(px(m.caption))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(r.text_subtle)
                            .child(SharedString::from(label)),
                    )
                })
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
                .children(rows)
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
        use crate::stores::composer::PickerRow;
        let picker = self.picker.as_ref().or(self.leaving_picker.as_ref())?;
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let m = t.metrics;
        let rows = self.picker_rows(cx);
        let store = self.composer.read(cx);
        let selected = store.selected_model().map(|m| m.id.clone());
        let can_pin = store.models.as_ref().is_some_and(|l| l.can_pin);
        let searching = !picker.search.read(cx).value().trim().is_empty();
        let has_more = store
            .models
            .as_ref()
            .is_some_and(crate::stores::composer::has_more_models);
        let options = store.model_options.clone();
        // A model with an effort control of its own (a coding agent's)
        // takes it from that control, below; the app's would contradict it.
        // Unknown until the options for the chat and model on screen answer.
        let own_effort = !store.options_answered() || store.options.own_effort_control;
        let controls = store
            .model_controls
            .as_ref()
            .filter(|c| c.model_id == selected)
            .map(|c| c.controls.clone())
            .unwrap_or_default();
        let total = rows
            .iter()
            .filter(|r| matches!(r, PickerRow::Model(_)))
            .count();
        let weak = cx.entity().downgrade();
        let mut index = 0usize;
        let list_rows: Vec<AnyElement> = rows
            .into_iter()
            .map(|row| match row {
                PickerRow::Heading(label) => div()
                    .px(px(8.))
                    .pt(px(8.))
                    .pb(px(2.))
                    .text_size(px(m.caption))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(r.text_subtle)
                    .child(SharedString::from(label))
                    .into_any_element(),
                PickerRow::Model(model) => {
                    let i = index;
                    index += 1;
                    self.picker_row(
                        i,
                        total,
                        &model,
                        selected.as_deref(),
                        can_pin,
                        picker,
                        t,
                        &l10n,
                        cx,
                    )
                }
            })
            .collect();
        // The footer: More Models, then the selected model's extras.
        let mut footer: Vec<AnyElement> = vec![];
        if has_more && !searching {
            let more = picker.more;
            footer.push(self.picker_footer_row(
                "model-menu-more",
                if more {
                    l10n.desktop_fewer_models()
                } else {
                    l10n.desktop_more_models()
                },
                None,
                if more {
                    IconName::ChevronUp
                } else {
                    IconName::ChevronDown
                },
                t,
                cx.listener(|this, _, _, cx| this.toggle_more_models(cx)),
            ));
        }
        if let Some(options) = options.as_ref() {
            if options.reasoning.visible && !own_effort {
                let label = if options.reasoning.ollama {
                    l10n.desktop_thinking()
                } else {
                    l10n.desktop_reasoning_effort()
                };
                let value =
                    crate::views::chat_settings::effort_label(&options.reasoning.current, &l10n);
                footer.push(self.picker_footer_row(
                    "model-menu-effort",
                    label,
                    Some(value),
                    IconName::ChevronsUpDown,
                    t,
                    cx.listener(|this, _, window, cx| this.show_effort_menu(window, cx)),
                ));
                if let Some(custom) = &picker.custom {
                    footer.push(
                        div()
                            .id("model-menu-custom-effort")
                            .mx(px(2.))
                            .px(px(8.))
                            .h(px(m.control_height + 2.))
                            .flex()
                            .items_center()
                            .rounded(px(7.))
                            .bg(with_alpha(r.text, if t.dark { 0.08 } else { 0.05 }))
                            .child(
                                Input::new(custom)
                                    .appearance(false)
                                    .bordered(false)
                                    .px_0()
                                    .text_size(px(m.control))
                                    .aria_label(SharedString::from(
                                        l10n.desktop_custom_effort_hint(),
                                    )),
                            )
                            .into_any_element(),
                    );
                }
            }
            if let Some(on) = options.fast_tier {
                footer.push(
                    div()
                        .id("model-menu-fast-tier")
                        .min_h(px(m.row_height + 6.))
                        .px(px(8.))
                        .flex()
                        .items_center()
                        .justify_between()
                        .child(SharedString::from(l10n.hermes_fast_tier()))
                        .child(
                            conduit_components::views::kit::Switch::new(
                                "model-menu-fast-tier-switch",
                                l10n.hermes_fast_tier(),
                                on,
                            )
                            .on_click(Rc::new({
                                let weak = weak.clone();
                                move |_, _, cx| {
                                    let _ = weak.update(cx, |c, cx| {
                                        c.composer.update(cx, |s, cx| s.set_fast_tier(!on, cx))
                                    });
                                }
                            })),
                        )
                        .into_any_element(),
                );
            }
        }
        // The model's own controls, one row each, as mobile's sheet lists
        // them under its models.
        for control in controls {
            let key = control.key.clone();
            footer.push(self.picker_footer_row(
                SharedString::from(format!("model-menu-control-{}", control.key)),
                model_control_title(&control, &l10n),
                Some(model_control_option_label(
                    &control,
                    control.value.as_deref(),
                    &l10n,
                )),
                IconName::ChevronsUpDown,
                t,
                cx.listener(move |this, _, window, cx| this.show_control_menu(&key, window, cx)),
            ));
        }
        Some(
            div()
                .id("model-menu")
                .role(Role::Dialog)
                .aria_label(SharedString::from(l10n.desktop_model_menu()))
                .w(px(320.))
                .max_h(px(460.))
                .p(px(6.))
                .flex()
                .flex_col()
                .rounded(t.overlay_radius())
                .border_1()
                .border_color(r.border_strong)
                .bg(r.overlay)
                .shadow(overlay_shadow(t))
                .occlude()
                .on_action(cx.listener(|this, a: &PickerAction, window, cx| {
                    this.on_picker_action(a, window, cx)
                }))
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
                        .flex_none()
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
                        .flex_shrink(1.)
                        .min_h_0()
                        .overflow_y_scroll()
                        .children(list_rows),
                )
                .when(!footer.is_empty(), |d| {
                    d.child(
                        div()
                            .my(px(4.))
                            .mx(px(6.))
                            .h(px(1.))
                            .flex_none()
                            .bg(r.divider),
                    )
                    .child(div().flex().flex_none().flex_col().children(footer))
                })
                .into_any_element(),
        )
    }

    /// One model in the picker: its name and connection, the model in use
    /// checked, and a pin button (shown on hover, or when pinned). A right
    /// click offers Pin or Unpin.
    #[allow(clippy::too_many_arguments)]
    fn picker_row(
        &self,
        i: usize,
        total: usize,
        model: &ModelSummary,
        selected: Option<&str>,
        can_pin: bool,
        picker: &Picker,
        t: &ConduitTheme,
        l10n: &crate::l10n::L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let r = t.roles;
        let m = t.metrics;
        let on = selected == Some(model.id.as_str());
        let hot = i == picker.highlighted;
        let id = model.id.clone();
        // Apple's model says where it runs, as on the phone.
        let apple = crate::stores::composer::is_apple_on_device(model);
        // A coding agent says where it runs: its terminal, as on the phone.
        let provider = if apple {
            l10n.desktop_apple_on_this_mac()
        } else if let Some(agent) = &model.agent {
            agent
                .terminal_name
                .clone()
                .unwrap_or_else(|| format!("{}/{}", agent.agent, agent.model))
        } else {
            model.connection.clone().unwrap_or_default()
        };
        let label = model_label(model);
        let group = SharedString::from(format!("model-row-{}", model.id));
        let pinned = model.pinned;
        let pin_label = if pinned {
            l10n.desktop_unpin_model(&model.name)
        } else {
            l10n.desktop_pin_model(&model.name)
        };
        let (pin_id, menu_id) = (model.id.clone(), model.id.clone());
        let (pin_text, unpin_text) = (l10n.pin(), l10n.unpin());
        // As the palette's rows: the highlighted one is the selected option
        // (VoiceOver follows it as the arrows move), the model in use is
        // checked.
        div()
            .id(ElementId::Name(format!("model-{}", model.id).into()))
            .group(group.clone())
            .role(Role::ListBoxOption)
            .aria_label(SharedString::from(label))
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
            // A direct model's maker, as the phone's picker shows it; the
            // pin button says whether it is pinned.
            .child(
                match model
                    .logo
                    .as_deref()
                    .and_then(|id| crate::views::model_logo::logo(id, 14., r.text))
                {
                    Some(logo) => logo.into_any_element(),
                    None => icon(
                        if pinned {
                            IconName::Pin
                        } else if model.agent.is_some() {
                            IconName::SquareTerminal
                        } else if apple {
                            IconName::Cpu
                        } else {
                            IconName::Sparkles
                        },
                        14.,
                        r.text_subtle,
                    )
                    .into_any_element(),
                },
            )
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
            .when(can_pin, |d| {
                d.child(
                    div()
                        .opacity(if pinned { 1. } else { 0. })
                        .group_hover(group.clone(), |s| s.opacity(1.))
                        .child(
                            IconButton::new(
                                ElementId::Name(format!("model-pin-{}", model.id).into()),
                                if pinned {
                                    IconName::PinOff
                                } else {
                                    IconName::Pin
                                },
                                pin_label,
                            )
                            .size(24., 13.)
                            .on_click(Rc::new({
                                let weak = cx.entity().downgrade();
                                move |_, _, cx| {
                                    // Pinning leaves the row unchosen (its
                                    // own click would select the model).
                                    cx.stop_propagation();
                                    let id = pin_id.clone();
                                    let _ = weak.update(cx, |c, cx| {
                                        c.composer
                                            .update(cx, |s, cx| s.set_pinned(&id, !pinned, cx))
                                    });
                                }
                            })),
                        ),
                )
            })
            .when(on, |d| d.child(icon(IconName::Check, 15., r.selected_icon)))
            .on_mouse_down(gpui_kit::MouseButton::Right, move |e, window, cx| {
                if !can_pin {
                    return;
                }
                let menu = gpui_kit::component::native_menu::NativeMenu::new().menu(
                    if pinned {
                        unpin_text.clone()
                    } else {
                        pin_text.clone()
                    },
                    Box::new(PickerAction::Pin(menu_id.clone(), !pinned)),
                );
                menu.show(e.position, window, cx);
                cx.stop_propagation();
            })
            .on_click(cx.listener(move |this, _, window, cx| this.choose_model(&id, window, cx)))
            .into_any_element()
    }

    /// A row under the picker's list: a label, its value, a trailing glyph.
    fn picker_footer_row(
        &self,
        id: impl Into<ElementId>,
        label: String,
        value: Option<String>,
        glyph: IconName,
        t: &ConduitTheme,
        on_click: impl Fn(&gpui_kit::ClickEvent, &mut Window, &mut App) + 'static,
    ) -> AnyElement {
        let r = t.roles;
        let m = t.metrics;
        let name = match &value {
            Some(v) => format!("{label}: {v}"),
            None => label.clone(),
        };
        div()
            .id(id)
            .role(Role::Button)
            .aria_label(SharedString::from(name))
            .min_h(px(m.row_height + 6.))
            .px(px(8.))
            .flex()
            .flex_none()
            .items_center()
            .gap(px(8.))
            .rounded(px(7.))
            .cursor_pointer()
            .hover(|s| s.bg(r.overlay_hover))
            .child(
                div()
                    .flex_1()
                    .text_size(px(m.control))
                    .text_color(r.text)
                    .child(SharedString::from(label)),
            )
            .when_some(value, |d, v| {
                d.child(
                    div()
                        .text_size(px(m.control))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(v)),
                )
            })
            .child(icon(glyph, 13., r.text_subtle))
            .on_click(on_click)
            .into_any_element()
    }
}

/// A model control's name, in the app's language for the two Open WebUI's
/// coding agents use (mobile's `modelControlTitle`); any other keeps the
/// server's.
pub fn model_control_title(
    control: &conduit_protocol::ModelControlDto,
    l10n: &crate::l10n::L10n,
) -> String {
    match control.key.as_str() {
        "reasoning_effort" => l10n.desktop_reasoning_effort(),
        "service_tier" => l10n.model_control_service_tier(),
        _ if control.label.trim().is_empty() => control.key.clone(),
        _ => control.label.clone(),
    }
}

/// The option `value` of `control` (mobile's `modelControlOptionLabel`): a
/// reasoning effort the app names in its own language, else the server's
/// label; "Default" when nothing is picked and the control has no default.
pub fn model_control_option_label(
    control: &conduit_protocol::ModelControlDto,
    value: Option<&str>,
    l10n: &crate::l10n::L10n,
) -> String {
    let Some(option) = value.and_then(|v| control.options.iter().find(|o| o.value == v)) else {
        return l10n.default_label();
    };
    if control.key == "reasoning_effort" {
        let known = crate::views::chat_settings::effort_label(&option.value, l10n);
        if known != option.value {
            return known;
        }
    }
    if option.label.trim().is_empty() {
        option.value.clone()
    } else {
        option.label.clone()
    }
}

/// A `/`, `@`, `#` or `$` menu row's name for VoiceOver: its title, then
/// its group when the menu has groups.
fn entry_label(entry: &Entry) -> String {
    match &entry.group {
        Some(g) => format!("{}, {g}", entry.title),
        None => entry.title.clone(),
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
        let context: Vec<AnyElement> = store
            .context
            .iter()
            .map(|c| context_chip(c, &composer, &t, cx))
            .collect();
        let options = store.options.clone();
        let (web_search, image_generation) = (store.web_search, store.image_generation);
        let code_interpreter = store.code_interpreter;
        let tool_ids = store.tool_ids.clone();
        let filter_ids = store.filter_ids.clone();
        let busy = self.busy_action(cx);
        let model_name = store
            .selected_model()
            .map(model_label)
            .unwrap_or_else(|| l10n.desktop_shortcut_focus_model_picker());
        // The coding agent this chat was saved with, when another model is
        // selected: offered, never chosen for the user.
        let chat_agent = store.chat_agent();

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
            let stop = IconButton::new("stop", IconName::Square, l10n.desktop_stop_generating())
                .size(32., 13.)
                .filled(r.primary, r.primary_foreground)
                .shortcut(conduit_components::views::focus::hints(cx).stop)
                .on_click(Rc::new({
                    let weak = cx.entity().downgrade();
                    move |_, _, cx| {
                        let _ = weak.update(cx, |_, cx| cx.emit(ChatComposerEvent::Stop));
                    }
                }));
            // A message typed meanwhile: Queue (Open WebUI) or Steer and
            // Send Next (Hermes), beside Stop, as on the phone.
            let tip = |id: &'static str,
                       button: conduit_components::views::kit::Button,
                       label: String,
                       keys: Option<&str>| {
                div()
                    .id(id)
                    .tooltip(conduit_components::views::focus::tooltip_builder(
                        label.into(),
                        keys.map(SharedString::from),
                    ))
                    .tooltip_show_delay(std::time::Duration::from_millis(800))
                    .child(button)
                    .into_any_element()
            };
            let submit = |weak: gpui_kit::WeakEntity<Self>| {
                Rc::new(
                    move |_: &gpui_kit::ClickEvent, window: &mut Window, cx: &mut App| {
                        let _ = weak.update(cx, |c, cx| c.submit(window, cx));
                    },
                )
            };
            let busy_buttons: Vec<AnyElement> = match busy {
                Some(true) => vec![tip(
                    "queue-tip",
                    conduit_components::views::kit::Button::new("queue", l10n.queue_draft_action())
                        .on_click(submit(cx.entity().downgrade())),
                    l10n.desktop_queue_message(),
                    Some("\u{21a9}"),
                )],
                Some(false) => vec![
                    tip(
                        "steer-tip",
                        conduit_components::views::kit::Button::new(
                            "steer",
                            l10n.hermes_turn_steer(),
                        )
                        .on_click(Rc::new({
                            let weak = cx.entity().downgrade();
                            move |_, window, cx| {
                                let _ = weak.update(cx, |c, cx| c.steer(window, cx));
                            }
                        })),
                        l10n.desktop_steer_tooltip(),
                        None,
                    ),
                    tip(
                        "send-next-tip",
                        conduit_components::views::kit::Button::new(
                            "send-next",
                            l10n.hermes_turn_send_next(),
                        )
                        .on_click(submit(cx.entity().downgrade())),
                        l10n.hermes_turn_send_next(),
                        Some("\u{21a9}"),
                    ),
                ],
                None => vec![],
            };
            div()
                .flex()
                .items_center()
                .gap(px(6.))
                .children(busy_buttons)
                .child(div().debug_selector(|| "composer-stop".into()).child(stop))
                .into_any_element()
        } else if self.offers_call(cx) {
            // Nothing to send: a voice call, as on the phone.
            let weak = cx.entity().downgrade();
            super::call::call_button(
                self.call_ready && !self.offline,
                Rc::new(move |_, cx| {
                    let _ = weak.update(cx, |_, cx| cx.emit(ChatComposerEvent::StartCall));
                }),
                cx,
            )
        } else {
            // Waiting on the connection: dimmed, its tooltip saying why
            // (the state itself shows once, in the window's pill).
            let waits = self.offline_reason.clone().filter(|_| self.offline);
            // Behind an answer that waits in the outbox, Send queues.
            let label = if self.queue_offer {
                l10n.desktop_queue_message()
            } else {
                l10n.send()
            };
            IconButton::new("send", IconName::ArrowUp, label)
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

        // Chips for this message's `@` model, its Compare Models model and
        // `#` knowledge.
        let mut chips: Vec<AnyElement> = vec![];
        // Not in a temporary chat, which is never compared.
        if let Some(other) = composer
            .read(cx)
            .compare_with
            .clone()
            .filter(|_| !self.temporary)
        {
            let composer = composer.clone();
            chips.push(chip(
                "compare-with".into(),
                l10n.desktop_compare_with_chip(&model_label(&other)),
                &t,
                Rc::new(move |_, cx| composer.update(cx, |c, cx| c.set_compare_with(None, cx))),
                l10n.desktop_stop_comparing(),
            ));
        }
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

        // Dictation: the mic beside Send; while it listens, its mark where
        // + was, its controls where Send was, and the field read-only.
        let me = cx.entity();
        let dictation = self.dictation.clone();
        let dictating = self.dictating(cx);
        let listening_mark = dictation
            .as_ref()
            .filter(|_| dictating)
            .map(|d| dictation_view::listening_mark(d.read(cx), cx));
        let listening_controls = dictation
            .as_ref()
            .filter(|_| dictating)
            .map(|d| dictation_view::listening_controls(&me, d.read(cx), cx));
        let mic = dictation
            .as_ref()
            .filter(|_| !dictating && !self.streaming && !self.call_on)
            .map(|_| dictation_view::mic_button(&me, cx));
        let recordings = dictation
            .as_ref()
            .and_then(|d| dictation_view::recordings_list(&me, d.read(cx), cx));
        let notice = dictation
            .as_ref()
            .and_then(|d| d.read(cx).notice.clone().map(|n| (d.clone(), n)))
            .map(|(d, n)| dictation_view::notice_banner(&me, &d, &n, cx));

        let paste_store = composer.clone();
        let textarea = Textarea::new(&self.input)
            .appearance(false)
            .bordered(false)
            .readonly(dictating)
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

        // Quick pills, chosen in Settings: one-click switches for an Open
        // WebUI model, on or off, as the phone's. The daemon sends the ones
        // this model can turn on (the core's `composerQuickPills`).
        let mut pilled: Vec<(PillKind, String)> = vec![];
        for pill in &options.quick_pills {
            let target = pill.target_id.clone();
            let (element, ic, label, on, kind) = match pill.kind.as_str() {
                "web" => (
                    "pill-web".to_string(),
                    IconName::Globe,
                    l10n.web(),
                    web_search,
                    PillKind::Web,
                ),
                "image" => (
                    "pill-image".to_string(),
                    IconName::Image,
                    l10n.image_gen(),
                    image_generation,
                    PillKind::Image,
                ),
                "filter" => (
                    format!("pill-filter-{target}"),
                    IconName::Funnel,
                    pill.name.clone(),
                    filter_ids.contains(&target),
                    PillKind::Filter,
                ),
                "tool" => (
                    format!("pill-tool-{target}"),
                    IconName::Wrench,
                    pill.name.clone(),
                    tool_ids.contains(&target),
                    PillKind::Tool,
                ),
                _ => continue,
            };
            pilled.push((kind, target.clone()));
            let composer = composer.clone();
            chips.push(
                toggle_chip(ElementId::Name(element.into()), ic, label.into(), on, &t)
                    .on_click(move |_, _, cx| {
                        composer.update(cx, |c, cx| match kind {
                            PillKind::Web => c.toggle_web_search(cx),
                            PillKind::Image => c.toggle_image_generation(cx),
                            PillKind::Filter => c.toggle_filter(&target, cx),
                            PillKind::Tool => c.toggle_tool(&target, cx),
                        })
                    })
                    .keyboard_control(Ring::Outset(14.), window, cx)
                    .into_any_element(),
            );
        }
        // A chosen code interpreter stays in view, to turn off; when it will
        // not run for this model, it says why.
        if code_interpreter {
            let block = options.code_interpreter_block.clone();
            let why = block.as_deref().map(|b| code_interpreter_reason(b, &l10n));
            let composer = composer.clone();
            chips.push(
                toggle_chip(
                    "toggle-code-interpreter",
                    if why.is_some() {
                        IconName::CircleAlert
                    } else {
                        IconName::Code
                    },
                    l10n.code_interpreter().into(),
                    why.is_none(),
                    &t,
                )
                .when_some(why, |d, why| {
                    d.tooltip(conduit_components::views::focus::tooltip_builder(
                        why.into(),
                        None,
                    ))
                })
                .on_click(move |_, _, cx| {
                    composer.update(cx, |c, cx| c.toggle_code_interpreter(cx))
                })
                .keyboard_control(Ring::Outset(14.), window, cx)
                .into_any_element(),
            );
        }
        chips.extend(context);
        // Switches that are on show as chips, which turn them off; the +
        // menu holds them all, as the phone's attach panel does.
        let pilled =
            |kind: PillKind, target: &str| pilled.iter().any(|p| p.0 == kind && p.1 == target);
        if options.web_search && web_search && !pilled(PillKind::Web, "") {
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
        if options.image_generation && image_generation && !pilled(PillKind::Image, "") {
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
        for filter in options
            .filters
            .iter()
            .filter(|f| filter_ids.contains(&f.id) && !pilled(PillKind::Filter, &f.id))
        {
            let composer = composer.clone();
            let id = filter.id.clone();
            chips.push(
                toggle_chip(
                    ElementId::Name(format!("filter-{}", filter.id).into()),
                    IconName::Funnel,
                    filter.name.clone().into(),
                    true,
                    &t,
                )
                .on_click(move |_, _, cx| composer.update(cx, |c, cx| c.toggle_filter(&id, cx)))
                .keyboard_control(Ring::Outset(14.), window, cx)
                .into_any_element(),
            );
        }
        for tool in options
            .tools
            .iter()
            .chain(&options.mcp_tools)
            .filter(|tool| tool_ids.contains(&tool.id) && !pilled(PillKind::Tool, &tool.id))
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

        let panel = self.panel_view(&t, window, cx);
        // ⇧⌘E: the larger editor, from the field's top corner once it holds
        // more than a line.
        let multiline = self.text(cx).contains('\n') || self.expanded;
        let expand = (multiline && !self.inline_model).then(|| {
            IconButton::new(
                "expand-editor",
                if self.expanded {
                    IconName::Minimize2
                } else {
                    IconName::Maximize2
                },
                if self.expanded {
                    l10n.desktop_collapse_editor()
                } else {
                    l10n.desktop_expand_editor()
                },
            )
            .size(24., 12.)
            .color(r.text_subtle)
            .shortcut(Some("\u{21e7}\u{2318}E".into()))
            .on_click(Rc::new({
                let weak = cx.entity().downgrade();
                move |_, window, cx| {
                    let _ = weak.update(cx, |c, cx| {
                        let on = !c.expanded;
                        c.set_expanded(on, window, cx)
                    });
                }
            }))
        });
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
            .on_action(cx.listener(|this, a: &RecordingMenu, window, cx| {
                this.on_recording_menu(a, window, cx)
            }))
            .children(form)
            .children(panel)
            .children(notice)
            .children(chat_agent.map(|(id, name)| chat_agent_offer(&composer, id, name, cx)))
            .children(recordings)
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
                            // The larger editor keeps + and Send at its
                            // bottom edge, under the text.
                            .when(self.expanded, |d| d.items_end())
                            .gap(px(4.))
                            .when_some(listening_mark, |d, mark| d.child(mark))
                            .when(!dictating, |d| {
                                d.child(div().relative().child(plus).child({
                                    let at = self.plus_bounds.clone();
                                    // Pinned to the corner: in a block wrapper
                                    // an absolute child's static place is below
                                    // the button.
                                    gpui_kit::canvas(
                                        move |b, _, _| at.set(Some(b)),
                                        |_, _, _, _| {},
                                    )
                                    .absolute()
                                    .top_0()
                                    .left_0()
                                    .size_full()
                                }))
                            })
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
                            .children(mic)
                            .children(expand)
                            .when_some(listening_controls, |d, c| d.child(c))
                            .when(!dictating, |d| d.child(send)),
                    )
                    .children(menu)
                    .children(picker),
            )
    }
}

/// "This chat used <agent>" with Switch, above the message box of a chat
/// saved with a coding agent while another model is selected. Switch picks
/// it (`models.select`), as choosing it in the picker would.
fn chat_agent_offer(
    composer: &Entity<ComposerStore>,
    id: String,
    name: String,
    cx: &mut Context<ChatComposer>,
) -> AnyElement {
    let l10n = cx.l10n().clone();
    let t = cx.conduit().clone();
    let r = t.roles;
    let m = t.metrics;
    let words = l10n.desktop_chat_used_agent(&name);
    let composer = composer.clone();
    div()
        .id("chat-agent-offer")
        .debug_selector(|| "chat-agent-offer".into())
        .role(Role::Group)
        .aria_label(SharedString::from(words.clone()))
        .mx(px(6.))
        .px(px(10.))
        .py(px(6.))
        .flex()
        .items_center()
        .gap(px(8.))
        .rounded(t.card_radius())
        .border_1()
        .border_color(r.border)
        .bg(conduit_components::views::kit::on_raised_fill(&t))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .text_size(px(m.small))
                .text_color(r.text_subtle)
                .child(SharedString::from(words)),
        )
        .child(
            div().debug_selector(|| "chat-agent-switch".into()).child(
                conduit_components::views::kit::Button::new(
                    "chat-agent-switch",
                    l10n.desktop_settings_switch_server(),
                )
                .on_click(Rc::new(move |_, _, cx| {
                    composer.update(cx, |s, cx| s.switch_to_chat_agent(&id, cx))
                })),
            ),
        )
        .into_any_element()
}

/// `content` without the bytes in `cut` (a trigger word): the tokens after
/// it move back, one inside it goes, the rest stay tokens.
fn cut_content(content: &InputContent, cut: std::ops::Range<usize>) -> InputContent {
    let text = content.text();
    let mut out = InputContent::new(format!("{}{}", &text[..cut.start], &text[cut.end..]));
    let len = cut.end - cut.start;
    for span in content.tokens() {
        let range = span.range();
        let moved = if range.end <= cut.start {
            range
        } else if range.start >= cut.end {
            range.start - len..range.end - len
        } else {
            continue;
        };
        out = match out.clone().with_token(moved, span.token().clone()) {
            Ok(next) => next,
            Err(_) => out,
        };
    }
    out
}

/// `text` with its mentions (UTF-16 ranges, as sent) as the field's tokens.
fn content_with_mentions(text: &str, mentions: &[ComposerMentionDto]) -> InputContent {
    let byte = |utf16: i64| -> Option<usize> {
        let mut units = 0i64;
        for (at, ch) in text.char_indices() {
            if units == utf16 {
                return Some(at);
            }
            units += ch.len_utf16() as i64;
        }
        (units == utf16).then_some(text.len())
    };
    let mut out = InputContent::new(text.to_string());
    for m in mentions {
        let target = match (m.kind, m.id_type.as_str()) {
            (conduit_protocol::MentionKind::Skill, _) => MentionTarget::Skill(m.id.clone()),
            (_, "U") => MentionTarget::User(m.id.clone()),
            (_, "C") => MentionTarget::Channel(m.id.clone()),
            // A model asked in a channel.
            (_, "M") => MentionTarget::Model(m.id.clone()),
            _ => continue,
        };
        let (Some(start), Some(end)) = (byte(m.start), byte(m.end)) else {
            continue;
        };
        if start >= end {
            continue;
        }
        let token = InlineToken::new(target.token_id(), text[start..end].to_string())
            .with_label(m.label.clone());
        out = match out.clone().with_token(start..end, token) {
            Ok(next) => next,
            Err(_) => out,
        };
    }
    out
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use conduit_components::theme::{ConduitTheme, DesignPrefs, install};
    use gpui_kit::{TestAppContext, VisualTestContext};

    use super::*;
    use crate::l10n::L10n;
    use crate::stores::rpc::fake::FakeDaemon;
    use conduit_protocol::ComposerOptions;

    type Seen = Rc<RefCell<Vec<ChatComposerEvent>>>;

    fn composer(cx: &mut TestAppContext) -> (Entity<ChatComposer>, &mut VisualTestContext, Seen) {
        composer_on(FakeDaemon::new(), cx)
    }

    fn composer_on(
        daemon: FakeDaemon,
        cx: &mut TestAppContext,
    ) -> (Entity<ChatComposer>, &mut VisualTestContext, Seen) {
        cx.update(|cx| {
            gpui_kit::init(cx);
            install(
                ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
                cx,
            );
            cx.set_global(L10n::new("en"));
            cx.set_global(conduit_components::Strings::default());
        });
        // The composer's own list has answered: it has a model to name.
        lists_a_model(&daemon);
        let rpc = daemon.rpc();
        let store = cx.new(|_| ComposerStore::new(rpc, None));
        let seen: Seen = Rc::default();
        let listed = store.clone();
        let (view, vcx) = cx.add_window_view(|window, cx| ChatComposer::new(store, window, cx));
        listed.update(vcx, |s, cx| s.refresh_models(cx));
        vcx.run_until_parked();
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

    /// [daemon] answers `models.list` with one model to name.
    fn lists_a_model(daemon: &FakeDaemon) {
        daemon.returns::<conduit_protocol::methods::ModelsList>(conduit_protocol::ModelList {
            models: vec![conduit_protocol::ModelSummary {
                id: "k".into(),
                name: "Kestrel".into(),
                description: None,
                pinned: false,
                capabilities: vec![],
                connection: None,
                logo: None,
                agent: None,
            }],
            selected_id: Some("k".into()),
            ..Default::default()
        });
    }

    fn value(view: &Entity<ChatComposer>, cx: &mut VisualTestContext) -> String {
        view.read_with(cx, |c, cx| c.text(cx))
    }

    #[test]
    fn dictated_words_follow_the_text_with_one_space() {
        assert_eq!(join_dictated("", "Hello there"), "Hello there");
        assert_eq!(join_dictated("Note:  ", "buy milk"), "Note: buy milk");
        assert_eq!(join_dictated("Kept", ""), "Kept");
    }

    #[gpui_kit::test]
    fn dictation_writes_after_the_text_and_cancel_puts_it_back(cx: &mut TestAppContext) {
        use crate::stores::dictation::{DictationEvent, DictationStore};
        let (view, cx, _) = composer(cx);
        let dictation = cx.new(|_| DictationStore::new(FakeDaemon::new().rpc(), None));
        cx.update(|window, cx| {
            view.update(cx, |c, cx| {
                c.set_dictation(dictation.clone(), window, cx);
                c.set_text("Draft:", window, cx);
                // As toggle_dictation does before the store starts.
                c.dictation_base = Some(c.text(cx));
            })
        });
        let emit = |e: DictationEvent, cx: &mut VisualTestContext| {
            dictation.update(cx, |_, cx| cx.emit(e));
            cx.run_until_parked();
        };
        // Words so far replace the last words so far.
        emit(
            DictationEvent::Text {
                text: "plant the".into(),
                done: false,
            },
            cx,
        );
        assert_eq!(value(&view, cx), "Draft: plant the");
        emit(
            DictationEvent::Text {
                text: "plant the beans".into(),
                done: true,
            },
            cx,
        );
        assert_eq!(value(&view, cx), "Draft: plant the beans");
        emit(DictationEvent::Ended { restore: false }, cx);
        assert_eq!(value(&view, cx), "Draft: plant the beans");
        // Cancel: back to what was typed before.
        cx.update(|_, cx| view.update(cx, |c, cx| c.dictation_base = Some(c.text(cx))));
        emit(
            DictationEvent::Text {
                text: "and water".into(),
                done: false,
            },
            cx,
        );
        emit(DictationEvent::Ended { restore: true }, cx);
        assert_eq!(value(&view, cx), "Draft: plant the beans");
        // A saved recording's words, asked for in this composition (as
        // transcribe_recording records it), are added at the end.
        cx.update(|_, cx| {
            view.update(cx, |c, cx| {
                c.transcribing = Some(c.composer.read(cx).ticket())
            })
        });
        emit(DictationEvent::Transcribed("Then rest.".into()), cx);
        assert_eq!(value(&view, cx), "Draft: plant the beans Then rest.");
    }

    /// The call button takes Send's place only with nothing to send: a
    /// message waiting on its file keeps its Send.
    #[gpui_kit::test]
    fn a_message_waiting_on_its_upload_keeps_send(cx: &mut TestAppContext) {
        use crate::stores::composer::{Attachment, UploadState};
        let (view, cx, _) = composer(cx);
        cx.update(|_, cx| view.update(cx, |c, _| c.call_offer = true));
        assert!(view.read_with(cx, |c, cx| c.offers_call(cx)));
        let mut uploading = Attachment::uploaded_for_test(0, "map.pdf", "file-map");
        uploading.state = UploadState::Uploading { sent: 1, total: 3 };
        cx.update(|window, cx| {
            view.update(cx, |c, cx| {
                c.composer
                    .update(cx, |s, cx| s.adopt_attachments(vec![uploading], cx));
                c.set_text("Read this", window, cx);
            })
        });
        assert!(
            !view.read_with(cx, |c, cx| c.offers_call(cx)),
            "a call stood where the waiting message's Send was"
        );
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
            vec![ChatComposerEvent::Submit {
                text: "first line\nsecond".into(),
                mentions: vec![],
            }]
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

    /// Send to Conduit, Send Link, Send Image or the widget's Clipboard in
    /// the new chat already shown (the same draft, so no draft switch):
    /// neither the last composition's prompt render nor the draft read
    /// still on its way lands in what it brought.
    #[gpui_kit::test]
    fn a_fresh_composition_takes_nothing_the_last_one_had_coming(cx: &mut TestAppContext) {
        use conduit_protocol::methods::{DraftsGet, PromptsRender};
        let daemon = FakeDaemon::new();
        daemon.returns::<DraftsGet>(
            serde_json::from_value(serde_json::json!({"text": "Old unsent words"})).unwrap(),
        );
        let read = daemon.hold::<DraftsGet>();
        daemon.returns::<PromptsRender>(
            serde_json::from_value(serde_json::json!({"content": "LATE", "inputs": []})).unwrap(),
        );
        let render = daemon.hold::<PromptsRender>();
        let (view, cx, _) = composer_on(daemon, cx);
        // The new chat's draft is being read, and a prompt rendered in it.
        view.update(cx, |c, cx| {
            c.composer
                .update(cx, |s, cx| s.switch_new_chat(None, false, "", cx))
        });
        view.update_in(cx, |c, window, cx| {
            let prompt = serde_json::from_value(serde_json::json!({
                "command": "/greet", "title": "Greet"
            }))
            .unwrap();
            c.render_prompt(prompt, 0, BTreeMap::new(), window, cx);
        });
        // A picture arrives from Shortcuts: no text of its own.
        view.update_in(cx, |c, window, cx| c.start_fresh("", window, cx));
        render.release();
        read.release();
        cx.run_until_parked();
        assert_eq!(value(&view, cx), "");
        assert!(view.read_with(cx, |c, _| c.form.is_none()));
    }

    /// Shared text that starts a fresh composition while the chat's draft is
    /// still being read stands alone: the draft read then is the last
    /// composition's, so it lands nowhere, and nothing is written over the
    /// stored draft nobody saw.
    #[gpui_kit::test]
    fn shared_text_started_fresh_during_a_draft_read_stands_alone(cx: &mut TestAppContext) {
        use conduit_protocol::methods::{DraftsGet, DraftsSave};
        let daemon = FakeDaemon::new();
        daemon.returns::<DraftsGet>(
            serde_json::from_value(serde_json::json!({"text": "Old unsent words"})).unwrap(),
        );
        daemon.returns::<DraftsSave>(
            serde_json::from_value(serde_json::json!({"text": ""})).unwrap(),
        );
        let read = daemon.hold::<DraftsGet>();
        let probe = daemon.clone();
        let (view, cx, _) = composer_on(daemon, cx);
        view.update(cx, |c, cx| {
            c.composer
                .update(cx, |s, cx| s.switch_new_chat(None, false, "", cx))
        });
        view.update_in(cx, |c, window, cx| c.start_fresh("Shared text", window, cx));
        read.release();
        for _ in 0..2 {
            cx.executor()
                .advance_clock(std::time::Duration::from_millis(500));
            cx.run_until_parked();
        }
        assert_eq!(value(&view, cx), "Shared text");
        assert!(
            probe.calls::<DraftsSave>().is_empty(),
            "a draft nobody saw was written over"
        );
    }

    /// A fresh composition while dictation runs and a send is still out:
    /// neither the dictation's words (nor its cancel) nor the refused send's
    /// text lands in what it brought.
    #[gpui_kit::test]
    fn a_fresh_composition_takes_nothing_from_dictation_or_a_send_in_flight(
        cx: &mut TestAppContext,
    ) {
        use crate::stores::dictation::{DictationEvent, DictationStore};
        let (view, cx, _) = composer(cx);
        let dictation = cx.new(|_| DictationStore::new(FakeDaemon::new().rpc(), None));
        cx.update(|window, cx| {
            view.update(cx, |c, cx| {
                c.set_dictation(dictation.clone(), window, cx);
                c.set_text("Draft:", window, cx);
                // As toggle_dictation does before the store starts.
                c.dictation_base = Some(c.text(cx));
            })
        });
        // A send still on its way, from before.
        let used = view.read_with(cx, |c, cx| c.composer.read(cx).one_shot());
        view.update_in(cx, |c, window, cx| {
            c.start_fresh("Copied packing list", window, cx)
        });
        let emit = |e: DictationEvent, cx: &mut VisualTestContext| {
            dictation.update(cx, |_, cx| cx.emit(e));
            cx.run_until_parked();
        };
        emit(
            DictationEvent::Text {
                text: "plant the".into(),
                done: false,
            },
            cx,
        );
        view.update_in(cx, |c, window, cx| {
            c.give_back("Old words", used, window, cx)
        });
        emit(DictationEvent::Ended { restore: true }, cx);
        assert_eq!(value(&view, cx), "Copied packing list");
    }

    /// A saved recording's words, still being transcribed when a fresh
    /// composition replaces the last one, land nowhere.
    #[gpui_kit::test]
    fn a_transcription_asked_for_the_last_composition_lands_nowhere(cx: &mut TestAppContext) {
        use crate::stores::dictation::DictationStore;
        use conduit_protocol::methods::{DictationStatus, RecordingsTranscribe};
        let (view, cx, _) = composer(cx);
        let daemon = FakeDaemon::new();
        daemon.returns::<DictationStatus>(
            serde_json::from_value(serde_json::json!({"engine": "server"})).unwrap(),
        );
        daemon.returns::<RecordingsTranscribe>(
            serde_json::from_value(serde_json::json!({"text": "plant the beans"})).unwrap(),
        );
        let held = daemon.hold::<RecordingsTranscribe>();
        let dictation = cx.new(|_| DictationStore::new(daemon.rpc(), None));
        view.update_in(cx, |c, window, cx| {
            c.set_dictation(dictation.clone(), window, cx);
            c.set_text("Draft:", window, cx);
            c.transcribe_recording("rec-1", false, window, cx);
        });
        cx.run_until_parked();
        view.update_in(cx, |c, window, cx| {
            c.start_fresh("Copied packing list", window, cx)
        });
        held.release();
        cx.run_until_parked();
        assert_eq!(value(&view, cx), "Copied packing list");

        // Asked in this composition: its words are added.
        view.update_in(cx, |c, window, cx| {
            c.transcribe_recording("rec-1", false, window, cx)
        });
        cx.run_until_parked();
        assert_eq!(value(&view, cx), "Copied packing list plant the beans");
    }

    /// Files chosen in Attach Files after a fresh composition replaced the
    /// one that asked are not attached to it.
    #[gpui_kit::test]
    fn files_picked_for_the_last_composition_are_not_attached(cx: &mut TestAppContext) {
        let (view, cx, _) = composer(cx);
        let dir = std::env::temp_dir().join(format!("conduit-pick-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let notes = dir.join("notes.txt");
        let _ = std::fs::write(&notes, "Synthetic notes");
        view.update_in(cx, |c, window, cx| c.pick_files(window, cx));
        assert!(cx.did_prompt_for_paths());
        view.update_in(cx, |c, window, cx| {
            c.start_fresh("Copied packing list", window, cx)
        });
        let picked = notes.clone();
        cx.simulate_path_prompt_response(move |_| Some(vec![picked]));
        cx.run_until_parked();
        assert!(
            view.read_with(cx, |c, cx| c.composer.read(cx).attachments.is_empty()),
            "files picked for the last composition were attached"
        );
        // Picked for this composition: attached.
        view.update_in(cx, |c, window, cx| c.pick_files(window, cx));
        cx.simulate_path_prompt_response(move |_| Some(vec![notes]));
        cx.run_until_parked();
        assert_eq!(
            view.read_with(cx, |c, cx| c.composer.read(cx).attachments.len()),
            1
        );
    }

    #[gpui_kit::test]
    fn a_prompt_rendered_after_send_stays_out_of_the_next_draft(cx: &mut TestAppContext) {
        let (view, cx, _) = composer(cx);
        let daemon = FakeDaemon::new();
        daemon.returns::<conduit_protocol::methods::PromptsRender>(
            serde_json::from_value(serde_json::json!({"content": "LATE", "inputs": []})).unwrap(),
        );
        let held = daemon.hold::<conduit_protocol::methods::PromptsRender>();
        lists_a_model(&daemon);
        let store = cx.new(|_| ComposerStore::new(daemon.rpc(), None));
        store.update(cx, |s, cx| s.refresh_models(cx));
        cx.run_until_parked();
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
            vec![ChatComposerEvent::Submit {
                text: "explain /nonexistent".into(),
                mentions: vec![],
            }]
        );
    }

    #[gpui_kit::test]
    fn menu_keys_wait_while_an_input_method_composes(cx: &mut TestAppContext) {
        let (view, cx, _) = composer(cx);
        let daemon = FakeDaemon::new();
        daemon.returns::<conduit_protocol::methods::PromptsList>(
            serde_json::from_value(serde_json::json!({
                "prompts": [{"command": "/かな", "title": "Kana"}]
            }))
            .unwrap(),
        );
        let store = cx.new(|_| ComposerStore::new(daemon.rpc(), None));
        view.update(cx, |c, _| c.composer = store);
        cx.simulate_input("/");
        let input = view.read_with(cx, |c, _| c.input.clone());
        cx.update(|window, cx| {
            input.update(cx, |s, cx| {
                s.replace_and_mark_text_in_range(None, "か", None, window, cx)
            });
        });
        view.update(cx, |c, cx| c.text_changed(cx));
        cx.run_until_parked();
        assert!(
            view.read_with(cx, |c, _| c.menu.is_some()),
            "the menu is open"
        );
        // Enter confirms the composition: the menu's item is not chosen.
        cx.simulate_keystrokes("enter");
        cx.run_until_parked();
        assert!(
            daemon
                .calls::<conduit_protocol::methods::PromptsRender>()
                .is_empty(),
            "Enter chose the menu item while composing"
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
        cx.simulate_keystrokes("cmd-enter");
        assert!(seen.borrow().is_empty(), "⌘↩ while composing does not send");
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
            vec![ChatComposerEvent::Submit {
                text: "かな".into(),
                mentions: vec![],
            }]
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

    #[gpui_kit::test]
    fn each_arrow_in_the_slash_menu_says_the_row_and_its_place(cx: &mut TestAppContext) {
        use conduit_components::announce::AnnouncementLog;
        let (view, cx, _) = composer(cx);
        cx.update(|_, cx| AnnouncementLog::install(cx));
        let store = view.read_with(cx, |c, _| c.composer.clone());
        let prompt = |command: &str, title: &str| PromptSummary {
            command: command.into(),
            title: title.into(),
            description: None,
            uses_clipboard: false,
        };
        cx.update(|_, cx| {
            store.update(cx, |s, cx| {
                s.prompts = Some(vec![
                    prompt("/summarize", "Summarize"),
                    prompt("/sow", "Sowing dates"),
                    prompt("/soil", "Soil check"),
                ]);
                cx.notify()
            })
        });
        cx.simulate_input("/s");
        let rows = view
            .read_with(cx, |c, cx| c.menu_rows(cx))
            .expect("a / menu");
        assert_eq!(rows.1.len(), 3);
        let titles: Vec<String> = rows.1.iter().map(|(_, t)| t.clone()).collect();
        let key = |k: &'static str, cx: &mut VisualTestContext| {
            cx.update(|window, cx| view.update(cx, |c, cx| assert!(c.menu_key(k, window, cx))));
        };
        // Opening and typing say nothing; each arrow says where it landed,
        // wrapping as the highlight does.
        assert_eq!(cx.update(|_, cx| AnnouncementLog::len(cx)), 0);
        key("down", cx);
        key("down", cx);
        key("down", cx);
        key("up", cx);
        let heard = cx.update(|_, cx| AnnouncementLog::texts(cx));
        assert_eq!(
            heard,
            [
                format!("{}, 2 of 3", titles[1]),
                format!("{}, 3 of 3", titles[2]),
                format!("{}, 1 of 3", titles[0]),
                format!("{}, 3 of 3", titles[2]),
            ]
            .map(SharedString::from)
        );
        // As drawn: the highlighted row is the one heard last.
        let highlighted = view.read_with(cx, |c, _| c.menu.as_ref().map(|m| m.highlighted));
        assert_eq!(highlighted, Some(2));
    }

    /// A composer over `daemon` (so its searches answer), focused.
    fn composer_with<'a>(
        daemon: &FakeDaemon,
        cx: &'a mut TestAppContext,
    ) -> (Entity<ChatComposer>, &'a mut VisualTestContext, Seen) {
        cx.update(|cx| {
            gpui_kit::init(cx);
            install(
                ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
                cx,
            );
            cx.set_global(L10n::new("en"));
            cx.set_global(conduit_components::Strings::default());
        });
        lists_a_model(daemon);
        let rpc = daemon.rpc();
        let store = cx.new(|_| ComposerStore::new(rpc, None));
        let seen: Seen = Rc::default();
        let listed = store.clone();
        let (view, vcx) = cx.add_window_view(|window, cx| ChatComposer::new(store, window, cx));
        listed.update(vcx, |s, cx| s.refresh_models(cx));
        vcx.run_until_parked();
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

    fn set_options(
        view: &Entity<ChatComposer>,
        options: ComposerOptions,
        cx: &mut VisualTestContext,
    ) {
        let store = view.read_with(cx, |c, _| c.composer.clone());
        cx.update(|_, cx| {
            store.update(cx, |s, cx| {
                s.options = options;
                cx.notify()
            })
        });
    }

    /// The open chat's model list failed while an answer is written: only
    /// a new turn needs it. The queue still takes the message, and Stop
    /// still stops.
    #[gpui_kit::test]
    fn a_failed_model_list_leaves_the_queue_and_stop(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<conduit_protocol::methods::DraftsGet>(Default::default());
        let (view, cx, seen) = composer_with(&daemon, cx);
        let store = view.read_with(cx, |c, _| c.composer.clone());
        daemon.once::<conduit_protocol::methods::ModelsList>(Err(conduit_daemon::protocol::error(
            "rpc.daemonUnavailable",
            "busy",
        )));
        cx.update(|_, cx| {
            store.update(cx, |s, cx| {
                s.switch_draft(
                    Some(crate::stores::composer::DraftKey {
                        chat_id: Some("chat-9".into()),
                        folder_id: None,
                    }),
                    "",
                    cx,
                )
            })
        });
        cx.run_until_parked();
        assert!(
            !store.read_with(cx, |s, _| s.can_name_model()),
            "the chat's list did not fail"
        );
        view.update(cx, |c, _| {
            c.streaming = true;
            c.queue_offer = true;
        });
        cx.simulate_input("And the north side?");
        cx.simulate_keystrokes("enter");
        assert_eq!(
            *seen.borrow(),
            vec![ChatComposerEvent::Queue {
                text: "And the north side?".into(),
                mentions: vec![],
            }]
        );
        seen.borrow_mut().clear();
        cx.update(|window, cx| window.draw(cx).clear(cx));
        let stop = cx.debug_bounds("composer-stop").expect("Stop is offered");
        cx.simulate_click(stop.center(), gpui_kit::Modifiers::none());
        assert_eq!(*seen.borrow(), vec![ChatComposerEvent::Stop]);
    }

    #[gpui_kit::test]
    fn while_an_answer_streams_enter_queues_or_goes_to_hermes(cx: &mut TestAppContext) {
        let (view, cx, seen) = composer(cx);
        view.update(cx, |c, _| {
            c.streaming = true;
            c.queue_offer = true;
        });
        cx.simulate_input("And the north side?");
        cx.simulate_keystrokes("enter");
        assert_eq!(
            *seen.borrow(),
            vec![ChatComposerEvent::Queue {
                text: "And the north side?".into(),
                mentions: vec![],
            }]
        );
        assert_eq!(value(&view, cx), "", "queued, the field clears");
        // Behind an answer that waits in the outbox nothing streams, and
        // the queue is still offered: Enter queues.
        seen.borrow_mut().clear();
        view.update(cx, |c, _| c.streaming = false);
        cx.simulate_input("And the east side?");
        cx.simulate_keystrokes("enter");
        assert_eq!(
            *seen.borrow(),
            vec![ChatComposerEvent::Queue {
                text: "And the east side?".into(),
                mentions: vec![],
            }]
        );
        view.update(cx, |c, _| c.streaming = true);
        // Hermes on a Desktop Gateway: Enter sends it next; Steer steers.
        view.update(cx, |c, _| c.queue_offer = false);
        set_options(
            &view,
            ComposerOptions {
                steer: true,
                ..Default::default()
            },
            cx,
        );
        cx.simulate_input("Use the smaller set");
        cx.simulate_keystrokes("enter");
        cx.simulate_input("Stop at three");
        cx.update(|window, cx| view.update(cx, |c, cx| c.steer(window, cx)));
        assert_eq!(
            seen.borrow()[1..],
            [
                ChatComposerEvent::Steer {
                    text: "Use the smaller set".into(),
                    mentions: vec![],
                    steer: false,
                },
                ChatComposerEvent::Steer {
                    text: "Stop at three".into(),
                    mentions: vec![],
                    steer: true,
                },
            ]
        );
        // Neither: Enter keeps the text for after the answer.
        set_options(&view, ComposerOptions::default(), cx);
        cx.simulate_input("Later");
        cx.simulate_keystrokes("enter");
        assert_eq!(seen.borrow().len(), 3);
        // (The test platform types an Enter nothing took as a new line.)
        assert_eq!(value(&view, cx).trim(), "Later");
    }

    #[gpui_kit::test]
    fn with_send_on_enter_off_enter_breaks_the_line_and_cmd_enter_sends(cx: &mut TestAppContext) {
        let (view, cx, seen) = composer(cx);
        let store = view.read_with(cx, |c, _| c.composer.clone());
        cx.update(|_, cx| {
            store.update(cx, |s, cx| {
                s.set_prefs(
                    crate::stores::composer::ComposerPrefs {
                        send_on_enter: false,
                        ..Default::default()
                    },
                    cx,
                )
            })
        });
        cx.run_until_parked();
        cx.simulate_input("one");
        cx.simulate_keystrokes("enter");
        cx.simulate_input("two");
        assert!(seen.borrow().is_empty());
        assert_eq!(value(&view, cx), "one\ntwo");
        cx.simulate_keystrokes("cmd-enter");
        assert_eq!(
            *seen.borrow(),
            vec![ChatComposerEvent::Submit {
                text: "one\ntwo".into(),
                mentions: vec![],
            }]
        );
    }

    #[gpui_kit::test]
    fn a_picked_skill_is_a_token_and_goes_out_as_a_mention(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<conduit_protocol::methods::SkillsSearch>(conduit_protocol::SkillList {
            items: vec![SkillSummary {
                id: "plain-english".into(),
                name: "Plain English".into(),
                description: None,
            }],
        });
        let (view, cx, seen) = composer_with(&daemon, cx);
        set_options(
            &view,
            ComposerOptions {
                skills: true,
                ..Default::default()
            },
            cx,
        );
        cx.simulate_input("Say hi $pla");
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(200));
        cx.run_until_parked();
        let rows = view.read_with(cx, |c, cx| c.menu_rows(cx));
        assert_eq!(
            rows,
            Some((
                TriggerKind::Skill,
                vec![(None, "Plain English".to_string())]
            ))
        );
        cx.simulate_keystrokes("enter");
        assert_eq!(value(&view, cx), "Say hi $Plain English ");
        cx.simulate_keystrokes("enter");
        let sent = seen.borrow();
        let ChatComposerEvent::Submit { text, mentions } = &sent[0] else {
            panic!("{sent:?}")
        };
        assert_eq!(text, "Say hi $Plain English");
        assert_eq!(mentions.len(), 1);
        assert_eq!((mentions[0].start, mentions[0].end), (7, 21));
        assert_eq!(mentions[0].id, "plain-english");
        assert_eq!(mentions[0].kind, conduit_protocol::MentionKind::Skill);
    }

    fn web_page(id: &str) -> conduit_protocol::FetchedUrl {
        serde_json::from_value(serde_json::json!({
            "attachment": {"id": id, "kind": "web", "name": "A page", "url": "https://example.com/a"}
        }))
        .unwrap()
    }

    fn context_names(view: &Entity<ChatComposer>, cx: &mut VisualTestContext) -> Vec<String> {
        view.read_with(cx, |c, cx| {
            c.composer
                .read(cx)
                .context
                .iter()
                .map(|a| a.name.clone())
                .collect()
        })
    }

    #[gpui_kit::test]
    fn a_page_read_for_a_closed_panel_or_another_draft_is_dropped(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<conduit_protocol::methods::ContextFetchUrl>(web_page("w1"));
        let (view, cx, _) = composer_on(daemon.clone(), cx);
        let fetch = |view: &Entity<ChatComposer>, cx: &mut VisualTestContext| {
            view.update_in(cx, |c, window, cx| {
                c.open_web_page(window, cx);
                if let Some(Panel::WebPage(p)) = &c.panel {
                    p.url
                        .update(cx, |i, cx| i.set_value("https://example.com/a", window, cx));
                }
                c.fetch_web_page(window, cx);
            });
        };
        // Closed before the page came: it never attaches.
        let held = daemon.hold::<conduit_protocol::methods::ContextFetchUrl>();
        fetch(&view, cx);
        view.update_in(cx, |c, window, cx| c.close_panel(window, cx));
        held.release();
        cx.run_until_parked();
        assert!(
            context_names(&view, cx).is_empty(),
            "a closed panel's page attached"
        );
        // Another chat (or account) since: neither.
        let held = daemon.hold::<conduit_protocol::methods::ContextFetchUrl>();
        fetch(&view, cx);
        let store = view.read_with(cx, |c, _| c.composer.clone());
        store.update(cx, |s, cx| {
            s.switch_draft(
                Some(crate::stores::composer::DraftKey {
                    chat_id: Some("chat-b".into()),
                    folder_id: None,
                }),
                "",
                cx,
            )
        });
        cx.run_until_parked();
        held.release();
        cx.run_until_parked();
        assert!(
            context_names(&view, cx).is_empty(),
            "another draft took the page"
        );
        // The panel still open: it attaches.
        fetch(&view, cx);
        cx.run_until_parked();
        assert_eq!(context_names(&view, cx), vec!["A page".to_string()]);
    }

    #[gpui_kit::test]
    fn an_mcp_item_read_before_another_was_chosen_never_shows(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<conduit_protocol::methods::McpList>(
            serde_json::from_value(serde_json::json!({"servers": [
                {"id": "s1", "name": "Notes server", "endpoint": "https://mcp.example.com", "enabled": true}
            ]}))
            .unwrap(),
        );
        daemon.returns::<conduit_protocol::methods::McpContent>(
            serde_json::from_value(serde_json::json!({
                "serverId": "s1", "serverName": "Notes server",
                "prompts": [
                    {"name": "first", "displayName": "First"},
                    {"name": "second", "displayName": "Second"}
                ]
            }))
            .unwrap(),
        );
        daemon.on::<conduit_protocol::methods::McpGetPrompt>(|p| {
            let name = p["name"].as_str().unwrap_or_default().to_string();
            Ok(serde_json::json!({"messages": [{"role": "user", "text": format!("Text of {name}")}]}))
        });
        let (view, cx, _) = composer_on(daemon.clone(), cx);
        view.update_in(cx, |c, window, cx| c.open_mcp(window, cx));
        cx.run_until_parked();
        let held = daemon.hold_one::<conduit_protocol::methods::McpGetPrompt>(0);
        view.update(cx, |c, cx| {
            let Some(Panel::Mcp(p)) = &mut c.panel else {
                panic!("no MCP panel");
            };
            let items = p.items(cx);
            assert_eq!(items.len(), 2);
            p.read(items[0].clone(), cx);
            p.read(items[1].clone(), cx);
        });
        cx.run_until_parked();
        held.release();
        cx.run_until_parked();
        let preview = view.read_with(cx, |c, _| match &c.panel {
            Some(Panel::Mcp(p)) => p.preview.as_ref().map(|(text, _)| text.clone()),
            _ => None,
        });
        assert!(
            preview
                .as_deref()
                .is_some_and(|t| t.contains("Text of second")),
            "{preview:?}"
        );
    }

    #[gpui_kit::test]
    fn mcp_content_with_no_servers_stops_loading(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<conduit_protocol::methods::McpList>(
            serde_json::from_value(serde_json::json!({"servers": []})).unwrap(),
        );
        let (view, cx, _) = composer_on(daemon, cx);
        view.update_in(cx, |c, window, cx| c.open_mcp(window, cx));
        cx.run_until_parked();
        assert!(view.read_with(
            cx,
            |c, _| matches!(&c.panel, Some(Panel::Mcp(p)) if !p.loading)
        ));
    }

    #[gpui_kit::test]
    fn a_prompt_rendered_for_another_draft_never_lands(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<conduit_protocol::methods::PromptsRender>(
            serde_json::from_value(serde_json::json!({"content": "LATE", "inputs": []})).unwrap(),
        );
        let held = daemon.hold::<conduit_protocol::methods::PromptsRender>();
        let (view, cx, _) = composer_on(daemon, cx);
        view.update_in(cx, |c, window, cx| {
            let prompt = serde_json::from_value(serde_json::json!({
                "command": "/greet", "title": "Greet"
            }))
            .unwrap();
            c.render_prompt(prompt, 0, BTreeMap::new(), window, cx);
        });
        let store = view.read_with(cx, |c, _| c.composer.clone());
        store.update(cx, |s, cx| {
            s.switch_draft(
                Some(crate::stores::composer::DraftKey {
                    chat_id: Some("chat-b".into()),
                    folder_id: None,
                }),
                "",
                cx,
            )
        });
        cx.run_until_parked();
        held.release();
        cx.run_until_parked();
        assert_eq!(value(&view, cx), "", "chat A's prompt landed in chat B");
    }

    fn token_ids(view: &Entity<ChatComposer>, cx: &mut VisualTestContext) -> Vec<String> {
        view.read_with(cx, |c, cx| {
            c.input
                .read(cx)
                .tokens()
                .iter()
                .map(|t| t.token().id().to_string())
                .collect()
        })
    }

    #[gpui_kit::test]
    fn a_second_mention_keeps_the_first(cx: &mut TestAppContext) {
        let (view, cx, _) = composer(cx);
        cx.simulate_input("Ask @Av");
        view.update_in(cx, |c, window, cx| {
            c.text_changed(cx);
            c.insert_mention(MentionTarget::User("u-1".into()), "Avery", window, cx);
        });
        cx.simulate_input("and @Bl");
        view.update_in(cx, |c, window, cx| {
            c.text_changed(cx);
            c.insert_mention(MentionTarget::User("u-2".into()), "Blake", window, cx);
        });
        assert_eq!(value(&view, cx), "Ask @Avery and @Blake ");
        assert_eq!(token_ids(&view, cx), vec!["U:u-1", "U:u-2"]);
    }

    /// A model asked in a channel comes back with a refused post as the
    /// model's mention, so the post sent again still asks it.
    #[gpui_kit::test]
    fn a_refused_post_keeps_its_model_mention(cx: &mut TestAppContext) {
        let (view, cx, seen) = composer(cx);
        cx.simulate_input("Ask @Ke");
        view.update_in(cx, |c, window, cx| {
            c.text_changed(cx);
            c.insert_mention(
                MentionTarget::Model("kestrel-8b".into()),
                "Kestrel 8B",
                window,
                cx,
            );
        });
        cx.simulate_keystrokes("enter");
        let ChatComposerEvent::Submit { text, mentions } = seen.borrow()[0].clone() else {
            panic!("not sent");
        };
        view.update_in(cx, |c, window, cx| {
            let used = c
                .composer
                .read(cx)
                .one_shot()
                .with_mentions(mentions.clone());
            c.give_back(&text, used, window, cx);
        });
        assert_eq!(
            token_ids(&view, cx),
            vec!["M:kestrel-8b"],
            "the model's mention came back as plain text"
        );
    }

    #[gpui_kit::test]
    fn a_refused_send_comes_back_with_its_mentions(cx: &mut TestAppContext) {
        let (view, cx, seen) = composer(cx);
        cx.simulate_input("Ask @Av");
        view.update_in(cx, |c, window, cx| {
            c.text_changed(cx);
            c.insert_mention(MentionTarget::User("u-1".into()), "Avery", window, cx);
        });
        cx.simulate_keystrokes("enter");
        let ChatComposerEvent::Submit { text, mentions } = seen.borrow()[0].clone() else {
            panic!("not sent");
        };
        assert_eq!(mentions.len(), 1);
        view.update_in(cx, |c, window, cx| {
            let used = c
                .composer
                .read(cx)
                .one_shot()
                .with_mentions(mentions.clone());
            c.give_back(&text, used, window, cx);
        });
        assert_eq!(value(&view, cx), "Ask @Avery");
        assert_eq!(token_ids(&view, cx), vec!["U:u-1"]);
        // Sent again: the same mention goes with it.
        cx.simulate_keystrokes("enter");
        let ChatComposerEvent::Submit {
            mentions: again, ..
        } = seen.borrow()[1].clone()
        else {
            panic!("not sent again");
        };
        assert_eq!(again, mentions);
    }

    /// Words typed while a send was on its way stay when it is refused:
    /// the refused words come back first, then the newer ones, each with
    /// its mentions.
    #[gpui_kit::test]
    fn a_refused_send_keeps_the_words_typed_since(cx: &mut TestAppContext) {
        let (view, cx, seen) = composer(cx);
        cx.simulate_input("Ask @Av");
        view.update_in(cx, |c, window, cx| {
            c.text_changed(cx);
            c.insert_mention(MentionTarget::User("u-1".into()), "Avery", window, cx);
        });
        cx.simulate_keystrokes("enter");
        let ChatComposerEvent::Submit { text, mentions } = seen.borrow()[0].clone() else {
            panic!("not sent");
        };
        cx.simulate_input("then @Bl");
        view.update_in(cx, |c, window, cx| {
            c.text_changed(cx);
            c.insert_mention(MentionTarget::User("u-2".into()), "Blake", window, cx);
        });
        view.update_in(cx, |c, window, cx| {
            let used = c
                .composer
                .read(cx)
                .one_shot()
                .with_mentions(mentions.clone());
            c.give_back(&text, used, window, cx);
        });
        assert_eq!(
            value(&view, cx),
            "Ask @Avery\n\nthen @Blake ",
            "the refused send's words were lost"
        );
        assert_eq!(token_ids(&view, cx), vec!["U:u-1", "U:u-2"]);
    }

    /// Refused words put back ahead of newer ones move what sits where the
    /// newer words are: an open prompt form's place, and dictation's base
    /// (the next words heard, or a cancel, rebuild the field from it).
    #[gpui_kit::test]
    fn refused_words_put_first_move_the_form_and_dictation_along(cx: &mut TestAppContext) {
        let (view, cx, _) = composer(cx);
        view.update_in(cx, |c, window, cx| {
            c.set_text("Hi ", window, cx);
            c.dictation_base = Some(c.text(cx));
        });
        select_form(&view, cx);
        view.update(cx, |c, _| c.form.as_mut().unwrap().at = 3);
        view.update_in(cx, |c, window, cx| c.restore("First", window, cx));
        assert_eq!(value(&view, cx), "First\n\nHi ");
        view.read_with(cx, |c, _| {
            assert_eq!(
                c.form.as_ref().map(|f| f.at),
                Some(10),
                "the form's text would land inside the refused words"
            );
            assert_eq!(
                c.dictation_base.as_deref(),
                Some("First\n\nHi "),
                "dictation would drop the refused words"
            );
        });
    }

    #[gpui_kit::test]
    fn without_follow_ups_a_running_answer_keeps_the_text(cx: &mut TestAppContext) {
        let (view, cx, seen) = composer(cx);
        view.update(cx, |c, cx| {
            c.follow_ups = false;
            c.streaming = true;
            c.queue_offer = true;
            c.composer.update(cx, |s, _| s.options.steer = true);
        });
        cx.simulate_input("Next one");
        cx.simulate_keystrokes("enter");
        view.update_in(cx, |c, window, cx| c.steer(window, cx));
        assert!(seen.borrow().is_empty(), "{:?}", seen.borrow());
        // (The test platform hands the unused Enter to the field as a newline.)
        assert_eq!(
            value(&view, cx).trim_end(),
            "Next one",
            "the text was taken and lost"
        );
    }
}
