//! The main frame's chat side: the toolbar, the transcript and the composer
//! for whatever [`NavigationStore`](crate::stores::navigation::NavigationStore)
//! has selected (the sidebar and the palette set it).
//!
//! * **A stored chat** gets its own [`ChatStore`] (and transcript); opening
//!   another replaces both, and the store subscribes to the chat's event
//!   scope. Daemon events, reconnects and `route.remap` are forwarded to
//!   it.
//! * **A new chat** shows the greeting with the composer centred. Sending
//!   calls `turns.send` with no chat id; once the daemon answers, the
//!   chat's store is made (showing the message and the answer on its way)
//!   and `navigation.open(chatId)` selects it.
//! * **Approvals** (`ui.request` cards) dock above the composer.
//! * **Shortcuts:** focus the composer (⇧Esc), the model picker (⇧⌘M, and
//!   the palette's Choose model), stop generating (Esc), copy the last
//!   reply (⇧⌘C) and its last code block (⇧⌘;). They are registered on the
//!   app ([`register_actions`]) so they work wherever focus is in the main
//!   window.
//! * **Find in Chat** (⌘F): a find bar under the toolbar, as Safari's, with
//!   the match count, Find Previous and Next (⇧⌘G, ⌘G; ⇧↩ and ↩ in the
//!   field) and Done (Esc). The transcript finds and highlights; the bar
//!   stays open, searching again, when another chat opens.

use std::rc::Rc;
use std::sync::{Arc, Mutex};

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::views::kit::{Button, IconButton, bare_input};
use conduit_components::views::shell::{ChatToolbar, TitlePill};
use conduit_protocol::{ComposerMentionDto, Event, NoteSave, NoticeLevel, events, methods};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, ClipboardItem, Context, Entity, Focusable as _, Role, SharedString,
    Subscription, Window, div, px,
};

use crate::AppState;
use crate::actions::{
    ChooseModel, CopyLastCodeBlock, CopyLastResponse, FocusComposer, FocusModelPicker,
    StopGenerating, ToggleSidebar,
};
use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::stores::chat::{
    CHAT_EVENTS, ChatAction, ChatStore, ChatStoreEvent, PendingMessage, Subscribe,
};
use crate::stores::composer::{
    ComposerEvent, ComposerPrefs, ComposerStore, DraftKey, UploadError, UploadFuture,
    UploadRequest, Uploader,
};
use crate::stores::connection::{ConnectionEvent, ConnectionStore};
use crate::stores::layout::LayoutStore;
use crate::stores::navigation::Selection;
use crate::stores::router::RouterEvent;
use crate::views::approvals::ApprovalsView;
use crate::views::chat::composer::{ChatComposer, ChatComposerEvent};
use crate::views::chat::last_code_block;
use crate::views::chat::queue::{QueueEditing, queue_panel};
use crate::views::chat::rows::{RowHost, RowSink};
use crate::views::chat::transcript::Transcript;
use crate::views::main_window::SidebarReveal;

/// The open chat: its store and transcript.
pub struct OpenChat {
    pub store: Entity<ChatStore>,
    pub transcript: Entity<Transcript>,
    _subscriptions: Vec<Subscription>,
}

/// What [`ChatPane::compose_new_chat`] writes into a new chat.
#[derive(Default)]
pub struct NewChatContent {
    /// The message box's text.
    pub text: Option<String>,
    /// The new chat starts empty, its draft replaced (the phone's Send to
    /// Conduit, Send Link, Send Image and widget Clipboard reset it); else
    /// the text goes in and an unsent draft is kept, as New Chat keeps it.
    pub fresh: bool,
    /// Files, uploaded as the composer's Attach Files uploads them.
    pub paths: Vec<std::path::PathBuf>,
    /// Pictures, attached as a paste attaches them.
    pub images: Vec<gpui_kit::Image>,
    /// A web page's text or a video's transcript.
    pub context: Vec<conduit_protocol::ContextAttachmentDto>,
    /// Attachments already uploaded (Quick Ask's Open in Conduit).
    pub carried: Vec<crate::stores::composer::Attachment>,
    /// The account scope the content was read under, when it is that
    /// scope's: written only while that same scope is in charge.
    pub owner: Option<crate::shell::deep_link::ReadUnder>,
}

pub struct ChatPane {
    stores: Stores,
    layout: Entity<LayoutStore>,
    approvals: Entity<ApprovalsView>,
    /// Open WebUI's question or approval in the open chat.
    pub prompt_card: Entity<crate::views::chat::prompt::PromptCard>,
    /// The open chat's task checklist shows every task.
    tasks_open: bool,
    pub composer_store: Entity<ComposerStore>,
    pub composer: Entity<ChatComposer>,
    pub chat: Option<OpenChat>,
    /// A new chat's first message is on its way.
    /// The composition a new chat's first message was sent from, while it
    /// is on its way: it holds back another send (and Chat Settings) only
    /// while that composition is the one shown.
    starting: Option<crate::stores::composer::CompositionTicket>,
    /// The active account the composer's attachments belong to.
    account: Option<String>,
    /// The read-only notice's Continue Here or Continue in a Copy is on its
    /// way: its buttons wait.
    hermes_continuing: bool,
    /// A new chat's first send handing over to its transcript: when it
    /// began, and the greeting that fades out (see [`Handoff`]).
    handoff: Option<Handoff>,
    /// The handoff question showing now (its request) and what takes it
    /// away once another window answers it or it runs out of time.
    handoff_ask: Option<(String, crate::shell::sheet::SheetCloser)>,
    /// Handoff requests already settled (answered here or elsewhere, or out
    /// of time): a replay of one (another window subscribing, Quick Ask)
    /// never asks again.
    handoff_settled: std::collections::VecDeque<String>,
    /// Find in Chat's field, and whether its bar shows.
    find_input: Entity<InputState>,
    find_open: bool,
    /// The composer dock's focus scope (not a stop): "below the
    /// transcript", for Tab ([`Transcript::tab`]).
    dock_focus: gpui_kit::FocusHandle,
    /// The toolbar's title as last drawn (with its chat), and the one it
    /// is crossfading from (a chat named after its first answer).
    title_shown: Option<(String, String)>,
    title_change: Option<(String, std::time::Instant)>,
    /// A queued message being edited in place.
    queue_edit: Option<QueueEditing>,
    /// The first queued message of the session says the queue lives only
    /// while Conduit is open (once).
    queue_noted: bool,
    /// The temporary switch was moved by hand: the setting's default does
    /// not replace it.
    temporary_chosen: bool,
    /// The open new chat's temporary switch was moved by hand, so a later
    /// change to the default leaves it alone (until another chat opens).
    temporary_hand_chosen: bool,
    /// What the Chat and More menus offer for this chat: Chat Settings
    /// (Open WebUI chats with something to show or edit) and Tool Settings
    /// (the tools, filters and pipe with personal valves).
    pub settings_offer: SettingsOffer,
    /// Chat › Context & Usage… was last offered (the menus refresh when it
    /// changes).
    context_offered: std::cell::Cell<bool>,
    settings_key: Option<OfferKey>,
    _offer: Option<gpui_kit::Task<()>>,
    /// Whether the header offers Computer for the open chat, and what the
    /// answer was asked for (the chat, the setting, the selected terminal,
    /// a revision bumped by a reconnect).
    pub computer: Option<crate::views::terminal::chat::ComputerOffer>,
    computer_key: Option<(String, bool, Option<String>, u64)>,
    computer_revision: u64,
    _computer: Option<gpui_kit::Task<()>>,
    /// Live Updates: where its popover hangs from while open, since when
    /// the socket has been down, and the wait before its item shows.
    live_anchor: Option<gpui_kit::Point<gpui_kit::Pixels>>,
    live_down_since: Option<std::time::Instant>,
    _live_wait: Option<gpui_kit::Task<()>>,
    _subscriptions: Vec<Subscription>,
}

/// What [`ChatPane::settings_offer`] holds.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SettingsOffer {
    pub chat_settings: bool,
    /// Offered with Settings › Chat › Advanced on, as on the phone.
    pub tool_targets: Vec<conduit_protocol::ValveTarget>,
}

/// What the offer depends on: asked again when it changes.
#[derive(Clone, Debug, PartialEq)]
struct OfferKey {
    /// The account (the composer's scope): another one asks again, even
    /// for the same chat and model ids.
    scope: u64,
    chat_id: Option<String>,
    model_id: Option<String>,
    tool_ids: Vec<String>,
    filter_ids: Vec<String>,
    advanced: bool,
    has_draft: bool,
}

/// A new chat's first send, as Messages hands over: the greeting fades out
/// (120 ms) while the message (with the answer's first line under it) rises
/// 10 pt into place and fades in (200 ms). Under Reduce Motion only the
/// fades stay.
pub struct Handoff {
    pub start: std::time::Instant,
    pub greeting: String,
    pub temporary: bool,
}

impl Handoff {
    /// The greeting's opacity, and the transcript's opacity and how far it
    /// still has to rise, `elapsed` into the hand-off.
    pub fn at(elapsed: std::time::Duration, reduce_motion: bool) -> (f32, f32, f32) {
        use conduit_components::motion::{HANDOFF_RISE, specs};
        let out = elapsed.as_secs_f32() / specs::HANDOFF_OUT.duration.as_secs_f32();
        let inn = elapsed.as_secs_f32() / specs::HANDOFF_IN.duration.as_secs_f32();
        let greeting = 1. - specs::HANDOFF_OUT.curve.sample(out);
        let shown = specs::HANDOFF_IN.curve.sample(inn);
        let rise = if reduce_motion {
            0.
        } else {
            HANDOFF_RISE * (1. - shown)
        };
        (greeting, shown, rise)
    }

    /// Over once both have finished.
    pub fn done(elapsed: std::time::Duration) -> bool {
        use conduit_components::motion::specs;
        elapsed >= specs::HANDOFF_IN.duration.max(specs::HANDOFF_OUT.duration)
    }
}

/// `/upload` through the daemon's HTTP client, on its tokio runtime.
pub fn daemon_uploader() -> Uploader {
    Arc::new(|req: UploadRequest| -> UploadFuture {
        let (tx, rx) = futures::channel::oneshot::channel();
        let http = CURRENT_HTTP.lock().ok().and_then(|h| h.clone());
        Box::pin(async move {
            let Some(http) = http else {
                return Err(UploadError::manual("the daemon is not running"));
            };
            conduit_daemon::runtime::shared().spawn(async move {
                let progress = req.progress.clone();
                let result = http
                    .upload_to(
                        &req.name,
                        req.content_type.as_deref(),
                        bytes::Bytes::from(req.bytes),
                        Some(Arc::new(move |sent, total| progress(sent, total))),
                        req.attempt,
                        req.channel_id.as_deref(),
                    )
                    .await
                    .map_err(|e| UploadError::from_rpc(&e))
                    .and_then(|v| {
                        serde_json::from_value::<conduit_protocol::UploadedFile>(v)
                            .map_err(|e| UploadError::manual(e.to_string()))
                    });
                let _ = tx.send(result);
            });
            rx.await
                .unwrap_or_else(|_| Err(UploadError::manual("the upload was dropped")))
        })
    })
}

/// The daemon's HTTP client, as the connection store last published it
/// (uploads run off the UI thread and cannot read GPUI globals).
static CURRENT_HTTP: Mutex<Option<conduit_daemon::http::HttpClient>> = Mutex::new(None);

/// Publishes `connection`'s HTTP client for [`daemon_uploader`] now and on
/// every change. Each window with a composer keeps one, so uploads work
/// whichever window exists (Quick Ask with no main window, say).
pub fn follow_daemon_http(connection: &Entity<ConnectionStore>, cx: &mut App) -> Subscription {
    let publish = |connection: &Entity<ConnectionStore>, cx: &App| {
        let http = connection.read(cx).http().cloned();
        if let Ok(mut current) = CURRENT_HTTP.lock() {
            *current = http;
        }
    };
    publish(connection, cx);
    cx.observe(connection, move |connection, cx| publish(&connection, cx))
}

impl ChatPane {
    pub fn new(
        stores: Stores,
        layout: Entity<LayoutStore>,
        approvals: Entity<ApprovalsView>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let rpc = stores.connection.read(cx).rpc();
        let composer_store = cx.new(|_| ComposerStore::new(rpc, Some(daemon_uploader())));
        // Settings › Chat's choices, before the composer first draws.
        let prefs = ComposerPrefs::from_settings(stores.app_settings.read(cx).settings());
        composer_store.update(cx, |c, cx| c.set_prefs(prefs, cx));
        // Dictation into the composer (the mic, ⇧⌘L, saved recordings).
        let dictation = {
            let connection = stores.connection.clone();
            cx.new(|cx| crate::stores::dictation::DictationStore::for_connection(connection, cx))
        };
        let composer = cx.new(|cx| {
            let mut c = ChatComposer::new(composer_store.clone(), window, cx);
            // The model and the temporary switch are in the toolbar here.
            c.inline_model = false;
            c.set_dictation(dictation.clone(), window, cx);
            c
        });
        let find_input = cx.new(|cx| InputState::new(window, cx));
        let subscriptions = vec![
            cx.subscribe_in(
                &find_input,
                window,
                |this, input: &Entity<InputState>, e: &InputEvent, window, cx| match e {
                    InputEvent::Change => {
                        let query = input.read(cx).value().to_string();
                        this.find_query(query, cx);
                    }
                    InputEvent::PressEnter { shift, .. } => this.find_step(!*shift, window, cx),
                    _ => {}
                },
            ),
            cx.observe(&stores.navigation, |this, _, cx| this.sync_selection(cx)),
            cx.observe(&stores.accounts, |this, accounts, cx| {
                // Another account: nothing the composer holds for one
                // message (files, knowledge, an `@` model) carries over.
                let active = accounts.read(cx).scope_key();
                if active != this.account {
                    this.account = active;
                    // A first send of the last account's no longer holds
                    // this one's composer back.
                    this.starting = None;
                    this.composer_store.update(cx, |c, cx| c.reset(cx));
                    this.composer.update(cx, |c, cx| c.forget_account(cx));
                    // The new account's draft for what is shown.
                    this.sync_selection(cx);
                }
            }),
            // The Chat menu says Start or Stop Dictation.
            cx.observe(&dictation, {
                let mut was = false;
                move |_, store, cx| {
                    let now = store.read(cx).is_active();
                    if now != was {
                        was = now;
                        cx.defer(crate::menus::refresh_menus);
                    }
                }
            }),
            // A reading that starts, or goes on, while the composer
            // dictates ends the dictation as Stop does (what was said is
            // transcribed): the microphone would hear it. Dictating pauses
            // a reading in turn (`SpeechStore::yield_to_dictation`).
            cx.observe(&stores.speech, {
                let mut was_speaking = false;
                move |this, speech, cx| {
                    let speaking = speech.read(cx).is_speaking();
                    if speaking && !was_speaking {
                        let dictation = this.composer.read(cx).dictation.clone();
                        if let Some(d) = dictation.filter(|d| d.read(cx).is_listening()) {
                            d.update(cx, |d, cx| d.stop(cx));
                        }
                    }
                    was_speaking = speaking;
                    this.sync_speech(cx);
                }
            }),
            // Settings › Chat changes the composer as it changes.
            cx.observe(&stores.app_settings, |this, settings, cx| {
                this.adopt_prefs(cx);
                this.sync_settings_offer(cx);
                let prefs = settings.read(cx).settings().inline_message_actions.clone();
                if let Some(chat) = &this.chat {
                    chat.transcript
                        .update(cx, |t, cx| t.set_action_prefs(prefs, cx));
                }
                // The socket's health: Live Updates in the toolbar.
                cx.notify();
            }),
            cx.observe(&layout, |_, _, cx| cx.notify()),
            cx.observe(&approvals, |_, _, cx| cx.notify()),
            follow_daemon_http(&stores.connection, cx),
            cx.observe(&stores.connection, |this, _, cx| this.sync_offline(cx)),
            cx.subscribe(&stores.connection, |this, _, event, cx| {
                this.on_connection(event, cx)
            }),
            // Reload Skills: a Hermes chat's `/` lists the skills read again.
            cx.subscribe(
                &stores.hermes_admin,
                |this, admin, event: &crate::stores::hermes_admin::HermesAdminEvent, cx| {
                    if matches!(
                        event,
                        crate::stores::hermes_admin::HermesAdminEvent::SkillsReloaded
                    ) {
                        let connection = admin.read(cx).connection();
                        this.composer_store
                            .update(cx, |c, cx| c.reload_hermes_prompts(connection, cx));
                    }
                },
            ),
            cx.subscribe(&stores.router, |this, _, event: &RouterEvent, cx| {
                let RouterEvent::Remapped { from, to } = event;
                if let Some(chat) = &this.chat {
                    chat.store.update(cx, |s, cx| s.remap(from, to, cx));
                }
            }),
            cx.subscribe_in(
                &composer,
                window,
                |this, _, event, window, cx| match event {
                    ChatComposerEvent::Submit { text, mentions } => {
                        this.send_text(text.clone(), mentions.clone(), window, cx)
                    }
                    ChatComposerEvent::Queue { text, mentions } => {
                        this.queue_text(text.clone(), mentions.clone(), window, cx)
                    }
                    ChatComposerEvent::Steer {
                        text,
                        mentions,
                        steer,
                    } => this.steer_text(text.clone(), mentions.clone(), *steer, window, cx),
                    ChatComposerEvent::Stop => this.stop(cx),
                    ChatComposerEvent::Temporary(on) => {
                        let on = *on;
                        // Said aloud, as the phone says it when it turns on
                        // (and the counterpart when it turns off): the
                        // switch's own state is all VoiceOver reads else.
                        let said = if on {
                            cx.l10n().temporary_chat_tooltip()
                        } else {
                            cx.l10n().desktop_announce_temporary_off()
                        };
                        conduit_components::announce::announce(
                            said,
                            conduit_components::announce::Priority::Medium,
                            cx,
                        );
                        this.temporary_chosen = true;
                        this.temporary_hand_chosen = true;
                        // The same new chat, in its folder, with the
                        // settings saved on it.
                        this.stores
                            .navigation
                            .update(cx, |n, cx| n.set_new_chat_temporary(on, cx));
                    }
                    ChatComposerEvent::PickerChanged => cx.notify(),
                    ChatComposerEvent::SaveAsNote(text) => {
                        this.save_as_note(text.clone(), window, cx)
                    }
                    // The composer runs Compare Models itself, from its +
                    // menu (`choose_compare_model`).
                    ChatComposerEvent::CompareModels => {}
                    ChatComposerEvent::StartCall => this.start_call(cx),
                },
            ),
            // The voice call: its strip or capsule, the composer's call
            // button, and the new chat a call started, once it has an id.
            cx.subscribe(
                &stores.call,
                |this, _, _: &crate::stores::call::CallChanged, cx| this.on_call_changed(cx),
            ),
            cx.observe(&stores.call, |_, _, cx| cx.notify()),
            // The title capsule shows the selected model; the menus follow
            // what the chat's settings offer.
            cx.observe(&composer_store, |this, _, cx| {
                this.sync_settings_offer(cx);
                this.sync_call_offer(cx);
                cx.notify()
            }),
            // Toasts dock above the composer.
            cx.observe(&stores.toasts, |_, _, cx| cx.notify()),
            cx.subscribe(&composer_store, |this, _, event, cx| {
                let l10n = cx.l10n().clone();
                let text = match event {
                    ComposerEvent::AttachmentFailed { name } => {
                        l10n.desktop_attachment_failed(name)
                    }
                    ComposerEvent::ModelNotSelected(_) => l10n.desktop_model_not_selected(),
                    ComposerEvent::ControlNotSaved(_) => l10n.desktop_model_control_not_saved(),
                    // The composer shows its drafts itself.
                    ComposerEvent::DraftSwitched | ComposerEvent::DraftLoaded { .. } => return,
                };
                this.toast(NoticeLevel::Warning, text, cx);
            }),
        ];
        let account = stores.accounts.read(cx).scope_key();
        let prompt_card = cx.new(|cx| crate::views::chat::prompt::PromptCard::new(window, cx));
        let mut this = Self {
            stores,
            layout,
            approvals,
            prompt_card,
            tasks_open: false,
            composer_store,
            composer,
            chat: None,
            starting: None,
            account,
            hermes_continuing: false,
            handoff: None,
            handoff_ask: None,
            handoff_settled: Default::default(),
            find_input,
            find_open: false,
            dock_focus: cx.focus_handle(),
            title_shown: None,
            title_change: None,
            queue_edit: None,
            queue_noted: false,
            temporary_chosen: false,
            temporary_hand_chosen: false,
            settings_offer: SettingsOffer::default(),
            context_offered: std::cell::Cell::new(false),
            settings_key: None,
            _offer: None,
            computer: None,
            computer_key: None,
            computer_revision: 0,
            _computer: None,
            live_anchor: None,
            live_down_since: None,
            _live_wait: None,
            _subscriptions: subscriptions,
        };
        // The composer follows the models on offer and the network.
        this.stores.connection.update(cx, |c, _| {
            c.subscribe(
                "composer",
                &[
                    events::MODELS_CHANGED,
                    events::SYNC_STATUS,
                    events::HANDOFF_REQUESTED,
                    events::HANDOFF_SETTLED,
                ],
                vec![],
            )
        });
        this.composer_store.update(cx, |c, cx| c.refresh_models(cx));
        this.sync_selection(cx);
        this.sync_offline(cx);
        this
    }

    fn toast(&self, level: NoticeLevel, text: String, cx: &mut App) {
        self.stores
            .toasts
            .update(cx, |t, cx| t.show(level, text, cx));
    }

    /// Chat › Show Branches…, and the version list's Show All Branches…:
    /// the open chat's branches, as a sheet.
    pub fn show_branches(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<Entity<crate::views::chat::branches::BranchesSheet>> {
        let chat = self.chat.as_ref()?;
        let store = chat.store.downgrade();
        let chat_id = chat.store.read(cx).chat_id().to_string();
        let tree = self.stores.chat_list.read(cx).tree(&chat_id, cx);
        let names: std::collections::HashMap<String, String> = self
            .composer_store
            .read(cx)
            .models
            .as_ref()
            .map(|m| {
                m.models
                    .iter()
                    .map(|m| (m.id.clone(), m.name.clone()))
                    .collect()
            })
            .unwrap_or_default();
        crate::views::chat::sheets::open(
            window,
            crate::views::chat::branches::WIDTH,
            crate::views::chat::branches::HEIGHT,
            cx,
            move |window, cx| {
                crate::views::chat::branches::BranchesSheet::new(store, tree, names, window, cx)
            },
        )
    }

    /// The server suggests carrying on in a new chat with another model
    /// (`chat:handoff`): asks, as the phone does, in a sheet on the main
    /// window; agreeing opens a new chat on that model with the suggested
    /// message in the field, unsent.
    fn ask_handoff(&mut self, request: conduit_protocol::HandoffRequest, cx: &mut Context<Self>) {
        // Each request is asked once: a replay of the one on screen, or of
        // one already settled, presents nothing and keeps the alert it has.
        if !self.handoff_new(&request.request_id) {
            return;
        }
        let Some(window) = cx
            .try_global::<crate::AppState>()
            .and_then(|s| s.main_window)
        else {
            return;
        };
        let rpc = self.stores.connection.read(cx).rpc();
        let pane = cx.entity().downgrade();
        let asked_id = request.request_id.clone();
        // The account it was asked in: another one never gets its chat.
        let scope = self.composer_store.read(cx).scope();
        let closer = window.update(cx, move |_, window, cx| {
            let l10n = cx.l10n().clone();
            let spec = crate::shell::sheet::SheetSpec::new(
                l10n.chat_handoff_prompt_title(&request.model_name),
                l10n.chat_handoff_prompt_message(&request.model_name),
                l10n.chat_handoff_start_new_chat(),
                l10n.chat_handoff_stay_here(),
            );
            let (asked, closer) = crate::shell::sheet::present_sheet_closable(window, spec, cx);
            let request_id = request.request_id.clone();
            let settled = closer.clone();
            window
                .spawn(cx, async move |cx| {
                    let accept = asked.await;
                    // Settled elsewhere: nothing to answer.
                    if settled.is_closed() {
                        return;
                    }
                    let call =
                        rpc.call::<methods::HandoffAnswer>(&conduit_protocol::HandoffAnswer {
                            request_id,
                            accept,
                        });
                    let Ok(answered) = call.await else {
                        return;
                    };
                    if !answered.open {
                        return;
                    }
                    let _ = cx.update(|window, cx| {
                        let _ = pane.update(cx, |p, cx| {
                            p.open_handoff_in(scope, answered.model_id, answered.prompt, window, cx)
                        });
                    });
                })
                .detach();
            closer
        });
        if let Ok(closer) = closer {
            self.handoff_ask = Some((asked_id, closer));
        }
    }

    /// Whether handoff request `id` is neither on screen nor settled.
    fn handoff_new(&self, id: &str) -> bool {
        self.handoff_ask
            .as_ref()
            .is_none_or(|(asked, _)| asked != id)
            && !self.handoff_settled.iter().any(|s| s == id)
    }

    /// [`Self::open_handoff`], only while the account it was asked in
    /// (`scope`, the composer's) is still the active one.
    pub fn open_handoff_in(
        &mut self,
        scope: u64,
        model: Option<String>,
        prompt: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.composer_store.read(cx).scope() != scope {
            return;
        }
        self.open_handoff(model, prompt, window, cx);
    }

    /// A handoff the user agreed to: a new chat on `model`, `prompt` in the
    /// message field.
    pub fn open_handoff(
        &mut self,
        model: Option<String>,
        prompt: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // A chat that is kept, whatever "temporary by default" says: the
        // user chose it.
        self.temporary_chosen = true;
        self.stores
            .navigation
            .update(cx, |n, cx| n.new_chat(false, cx));
        if let Some(model) = model {
            self.composer_store
                .update(cx, |c, cx| c.select_model(&model, cx));
        }
        // Once the new chat's draft has taken the field (the switch, which
        // empties it, follows this update), the suggested message goes in.
        let prompt = prompt.filter(|p| !p.is_empty());
        cx.spawn_in(window, async move |this, cx| {
            let _ = this.update_in(cx, |this, window, cx| {
                if let Some(prompt) = prompt {
                    this.composer
                        .update(cx, |c, cx| c.restore(&prompt, window, cx));
                }
                this.composer.update(cx, |c, cx| c.focus_input(window, cx));
            });
        })
        .detach();
    }

    /// A temporary chat with messages is open: Save Chat applies.
    pub fn can_save_temporary(&self, cx: &App) -> bool {
        self.chat.as_ref().is_some_and(|c| {
            let s = c.store.read(cx);
            (s.temporary || s.detail.as_ref().is_some_and(|d| d.temporary))
                && !s.messages().is_empty()
                && !s.is_streaming()
        })
    }

    /// Save Chat: the open temporary chat becomes a stored one, and stays
    /// open under its new id.
    pub fn save_temporary(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        let Some(chat) = &self.chat else {
            return;
        };
        let task = chat.store.update(cx, |s, cx| s.save_temporary(cx));
        cx.spawn(async move |this, cx| {
            let Some(saved) = task.await else {
                return;
            };
            let _ = this.update(cx, |p, cx| {
                p.stores
                    .navigation
                    .update(cx, |n, cx| n.open(saved.chat_id.clone(), cx));
                p.stores.chat_list.update(cx, |c, cx| c.refresh(cx));
                let text = cx.l10n().desktop_chat_saved();
                p.toast(NoticeLevel::Success, text, cx);
                cx.notify();
            });
        })
        .detach();
    }

    /// Branch in New Chat made `chat_id`: it opens, and says so.
    pub fn open_forked(&mut self, chat_id: String, cx: &mut Context<Self>) {
        self.stores
            .navigation
            .update(cx, |n, cx| n.open(chat_id, cx));
        self.stores.chat_list.update(cx, |c, cx| c.refresh(cx));
        let text = cx.l10n().chat_branch_fork_opened();
        self.toast(NoticeLevel::Success, text, cx);
    }

    /// "Copied", after a copy action.
    pub fn notify_copied(&mut self, cx: &mut Context<Self>) {
        let text = cx.l10n().desktop_copied();
        self.toast(NoticeLevel::Info, text, cx);
    }

    fn subscribe_hook(&self) -> Subscribe {
        let connection = self.stores.connection.clone();
        Rc::new(move |chat_id: Option<&str>, cx: &mut App| {
            let scopes: Vec<String> = chat_id.into_iter().map(String::from).collect();
            connection.update(cx, |c, _| c.subscribe("chat", CHAT_EVENTS, scopes));
        })
    }

    /// What `/files` takes as the server: the active account's own id
    /// (its `connection.id`, the core's active server config), not the
    /// `server_id` it shares with other accounts on the same server, which
    /// the daemon refuses as "not the active server".
    fn server_id(&self, cx: &App) -> Option<String> {
        self.stores
            .accounts
            .read(cx)
            .active()
            .map(|a| a.connection.id.clone())
    }

    /// Follows the navigation store's selection.
    fn sync_selection(&mut self, cx: &mut Context<Self>) {
        let selection = self.stores.navigation.read(cx).selection().clone();
        // A Hermes session's chat opens in this pane as any chat does.
        let selection = match selection.chat_id() {
            Some(id) => Selection::Chat(id),
            None => selection,
        };
        match selection {
            Selection::Chat(id) => {
                self.temporary_hand_chosen = false;
                if let Some(chat) = &self.chat {
                    let current = chat.store.read(cx).chat_id().to_string();
                    let resolved = self.stores.router.read(cx).resolve(&current);
                    if current == id {
                        return;
                    }
                    if resolved == id {
                        chat.store.update(cx, |s, cx| s.remap(&current, &id, cx));
                        self.composer_store.update(cx, |c, _| {
                            c.rekey_draft(DraftKey {
                                chat_id: Some(id.clone()),
                                folder_id: None,
                            })
                        });
                        return;
                    }
                }
                self.switch_draft(
                    Some(DraftKey {
                        chat_id: Some(id.clone()),
                        folder_id: None,
                    }),
                    cx,
                );
                self.open_chat(id, cx);
                self.sync_call_offer(cx);
            }
            // Another area's item: the main window shows its pane, and the
            // chat stays loaded for when it comes back.
            Selection::Area(_) => return,
            Selection::New { temporary } => {
                // A new chat starts temporary when the setting says so,
                // unless the switch was just moved by hand.
                let chosen = std::mem::take(&mut self.temporary_chosen);
                self.temporary_hand_chosen = chosen;
                let temporary = if chosen {
                    temporary
                } else {
                    temporary || self.composer_store.read(cx).prefs.temporary_by_default
                };
                // A temporary chat keeps no draft, but starts in its folder
                // all the same.
                let folder = self
                    .stores
                    .navigation
                    .read(cx)
                    .new_chat_folder()
                    .map(str::to_string);
                let text = self.composer.read(cx).text(cx);
                self.composer_store
                    .update(cx, |c, cx| c.switch_new_chat(folder, temporary, &text, cx));
                self.chat = None;
                self.forget_context_offer(cx);
                // The menus were built for this selection before the pane
                // followed it: Read Aloud follows the chat now shown.
                cx.defer(crate::menus::refresh_menus);
                self.sync_speech(cx);
                self.sync_call_offer(cx);
                self.prompt_card.update(cx, |p, cx| p.set_store(None, cx));
                self.queue_edit = None;
                // Nothing to find in a new chat.
                self.find_open = false;
                (self.subscribe_hook())(None, cx);
                self.composer.update(cx, |c, cx| {
                    c.new_chat = true;
                    c.temporary = temporary;
                    c.streaming = false;
                    c.queue_offer = false;
                    cx.notify();
                });
            }
        }
        cx.notify();
    }

    /// A Hermes session another Hermes app owns, in place of the composer
    /// (the phone's `HermesReadOnlySessionNotice`): who owns it, what each
    /// way on does, and the two ways on.
    fn hermes_read_only_notice(
        &self,
        hermes: &conduit_protocol::HermesChatDto,
        t: &conduit_components::theme::ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let notice = if hermes.owner.trim().is_empty() {
            l10n.hermes_read_only_session_notice()
        } else {
            l10n.hermes_read_only_session_notice_from(&hermes.owner)
        };
        let explanation = l10n.hermes_continue_choice_explanation();
        let busy = self.hermes_continuing;
        let button = |id: &'static str, label: String, copy: bool| {
            let pane = cx.entity().downgrade();
            let mut b = conduit_components::views::kit::Button::new(id, label)
                .disabled(busy)
                .on_click(Rc::new(move |_, _, cx| {
                    let _ = pane.update(cx, |p, cx| p.continue_hermes(copy, cx));
                }));
            if copy {
                b = b.primary();
            }
            b
        };
        div()
            .id("hermes-read-only-notice")
            .role(Role::Group)
            .aria_label(SharedString::from(notice.clone()))
            .w_full()
            .px(px(14.))
            .py(px(12.))
            .rounded(px(12.))
            .bg(conduit_components::views::kit::raised_fill(t))
            .border_1()
            .border_color(r.border)
            .flex()
            .flex_col()
            .gap(px(10.))
            .child(
                div()
                    .flex()
                    .items_start()
                    .gap(px(10.))
                    .child(div().pt(px(1.)).child(conduit_components::assets::icon(
                        IconName::Eye,
                        15.,
                        r.text_subtle,
                    )))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap(px(4.))
                            .child(
                                div()
                                    .text_size(px(t.metrics.control))
                                    .text_color(r.text)
                                    .child(SharedString::from(notice)),
                            )
                            .child(
                                div()
                                    .text_size(px(t.metrics.small))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(explanation)),
                            ),
                    ),
            )
            .child(
                div()
                    .flex()
                    .justify_end()
                    .gap(px(8.))
                    .child(button(
                        "hermes-continue-here",
                        l10n.hermes_continue_here(),
                        false,
                    ))
                    .child(button(
                        "hermes-continue-in-copy",
                        l10n.hermes_continue_in_copy(),
                        true,
                    )),
            )
            .into_any_element()
    }

    /// Continue Here (`copy` false) or Continue in a Copy, from the open
    /// read-only Hermes chat: the session it goes on in opens.
    pub fn continue_hermes(&mut self, copy: bool, cx: &mut Context<Self>) {
        let Some(chat_id) = self.open_chat_id(cx) else {
            return;
        };
        if self.hermes_continuing {
            return;
        }
        self.hermes_continuing = true;
        cx.notify();
        let pane = cx.entity().downgrade();
        crate::views::hermes_sessions::continue_chat(
            &self.stores,
            &chat_id,
            copy,
            move |cx| {
                let _ = pane.update(cx, |p, cx| {
                    p.hermes_continuing = false;
                    cx.notify();
                });
            },
            cx,
        );
    }

    /// Opens or closes the open chat's task checklist.
    pub fn set_tasks_open(&mut self, open: bool, cx: &mut Context<Self>) {
        self.tasks_open = open;
        cx.notify();
    }

    /// Takes Settings › Chat's choices into the composer. A new chat nobody
    /// has touched follows a changed "temporary by default" too: the first
    /// one opens before the settings have arrived.
    fn adopt_prefs(&mut self, cx: &mut Context<Self>) {
        let prefs = ComposerPrefs::from_settings(self.stores.app_settings.read(cx).settings());
        let store = self.composer_store.read(cx);
        if store.prefs == prefs {
            return;
        }
        let default_moved = store.prefs.temporary_by_default != prefs.temporary_by_default;
        let untouched = store.attachments.is_empty()
            && store.context.is_empty()
            && self.composer.read(cx).text(cx).trim().is_empty();
        self.composer_store
            .update(cx, |c, cx| c.set_prefs(prefs, cx));
        let new_chat = matches!(
            self.stores.navigation.read(cx).selection(),
            Selection::New { .. }
        );
        if default_moved && untouched && new_chat && !self.temporary_hand_chosen {
            self.sync_selection(cx);
        }
    }

    /// Keeps what the composer holds for the chat it was typed in, and shows
    /// the next chat's draft once it is read.
    fn switch_draft(&mut self, key: Option<DraftKey>, cx: &mut Context<Self>) {
        if self.composer_store.read(cx).draft_key() == key.as_ref() {
            return;
        }
        let text = self.composer.read(cx).text(cx);
        self.composer_store
            .update(cx, |c, cx| c.switch_draft(key, &text, cx));
    }

    /// Opens `id` in a fresh store and transcript. Opening reads it, and
    /// the chat left is read up to now.
    /// The chat shown goes: Chat › Context & Usage… with it, and the next
    /// chat's detail offers it again (or not).
    fn forget_context_offer(&mut self, cx: &mut Context<Self>) {
        if self.context_offered.replace(false) {
            cx.defer(crate::menus::refresh_menus);
        }
    }

    fn open_chat(&mut self, id: String, cx: &mut Context<Self>) -> Entity<ChatStore> {
        self.forget_context_offer(cx);
        // The menus were built for this selection before the pane opened
        // the chat: Read Aloud follows it now.
        cx.defer(crate::menus::refresh_menus);
        let left = self
            .chat
            .as_ref()
            .map(|c| c.store.read(cx).chat_id().to_string())
            .filter(|left| *left != id);
        self.stores.chat_list.update(cx, |c, cx| {
            if let Some(left) = &left {
                c.mark_left(left, cx);
            }
            c.mark_read(&id, cx);
        });
        let rpc = self.stores.connection.read(cx).rpc();
        let subscribe = self.subscribe_hook();
        let store = cx.new(|cx| ChatStore::new(rpc, subscribe, id, cx));
        let host = RowHost {
            store: store.downgrade(),
            pane: RowSink::Pane(cx.entity().downgrade()),
            server_id: self.server_id(cx),
            composer: Some(self.composer_store.downgrade()),
        };
        let transcript = cx.new(|cx| Transcript::new(store.clone(), host, cx));
        // Settings › Chat › Message Actions lays out each answer's actions.
        let prefs = self
            .stores
            .app_settings
            .read(cx)
            .settings()
            .inline_message_actions
            .clone();
        let pane = cx.entity().downgrade();
        transcript.update(cx, |t, cx| {
            t.set_action_prefs(prefs, cx);
            t.set_on_branches(Rc::new(move |window, cx| {
                let _ = pane.update(cx, |p, cx| {
                    p.show_branches(window, cx);
                });
            }));
        });
        self.prompt_card
            .update(cx, |p, cx| p.set_store(Some(store.clone()), cx));
        self.tasks_open = false;
        // The find bar stays open over the next chat, finding the same text.
        let query = self.find_input.read(cx).value().to_string();
        if self.find_open && !query.is_empty() {
            transcript.update(cx, |t, cx| t.set_find(Some(query), cx));
        }
        let subscriptions = vec![
            cx.observe(&store, |this, store, cx| {
                // Chat › Context & Usage… comes with a Hermes chat.
                let context = store
                    .read(cx)
                    .detail
                    .as_ref()
                    .is_some_and(|d| d.abilities.hermes_context);
                if this.context_offered.replace(context) != context {
                    cx.defer(crate::menus::refresh_menus);
                }
                let streaming = store.read(cx).is_streaming();
                let offer = store.read(cx).queue_offered();
                this.composer.update(cx, |c, cx| {
                    if c.streaming != streaming || c.queue_offer != offer {
                        c.streaming = streaming;
                        c.queue_offer = offer;
                        cx.notify();
                    }
                });
                cx.notify();
            }),
            cx.subscribe(&store, |this, _, event: &ChatStoreEvent, cx| {
                let l10n = cx.l10n().clone();
                match event {
                    // The prompt card says so itself.
                    ChatStoreEvent::Failed {
                        action: ChatAction::Prompt,
                        ..
                    } => {}
                    ChatStoreEvent::Failed { action, reason, .. } => {
                        let text = failure_text(*action, reason.as_deref(), &l10n);
                        this.toast(NoticeLevel::Warning, text, cx);
                    }
                    ChatStoreEvent::Missing => cx.notify(),
                    // For the app's view in the transcript.
                    ChatStoreEvent::McpApp(_) => {}
                }
            }),
        ];
        self.composer.update(cx, |c, cx| {
            c.new_chat = false;
            c.temporary = false;
            c.streaming = false;
            cx.notify();
        });
        // The model label follows what the daemon has selected now (a first
        // send lets the daemon pick one).
        self.composer_store.update(cx, |c, cx| c.refresh_models(cx));
        self.chat = Some(OpenChat {
            store: store.clone(),
            transcript,
            _subscriptions: subscriptions,
        });
        self.sync_speech(cx);
        cx.notify();
        store
    }

    fn on_connection(&mut self, event: &ConnectionEvent, cx: &mut Context<Self>) {
        match event {
            ConnectionEvent::Connected { .. } => {
                if let Some(chat) = &self.chat {
                    chat.store.update(cx, |s, cx| s.on_reconnected(cx));
                }
                self.composer_store.update(cx, |c, cx| c.refresh_models(cx));
                // A new daemon session: handles and the Computer offer anew.
                crate::views::terminal::chat::forget_handles(cx);
                self.computer_revision += 1;
                cx.notify();
            }
            ConnectionEvent::Gap => {
                if let Some(chat) = &self.chat {
                    chat.store.update(cx, |s, cx| s.fetch(cx));
                }
            }
            ConnectionEvent::Daemon(event) => {
                match event.as_ref() {
                    Event::ModelsChanged | Event::AccountsChanged(_) => {
                        self.composer_store.update(cx, |c, cx| c.refresh_models(cx));
                    }
                    Event::SyncStatus(_) => self.sync_offline(cx),
                    Event::HandoffRequested(request) => self.ask_handoff(request.clone(), cx),
                    // Answered in another window, or out of time: its
                    // question here goes, unanswered.
                    Event::HandoffSettled(settled) => {
                        if self.handoff_settled.len() >= 32 {
                            self.handoff_settled.pop_front();
                        }
                        self.handoff_settled.push_back(settled.request_id.clone());
                        if let Some((id, closer)) = self.handoff_ask.take() {
                            if id == settled.request_id {
                                closer.close(cx);
                            } else {
                                self.handoff_ask = Some((id, closer));
                            }
                        }
                    }
                    Event::TerminalDisplayFile(request)
                        if self.open_chat_id(cx).as_deref() == Some(request.chat_id.as_str()) =>
                    {
                        if let Some(window) = cx
                            .try_global::<crate::AppState>()
                            .and_then(|s| s.main_window)
                        {
                            crate::views::terminal::chat::display_file(
                                self.stores.clone(),
                                window,
                                request.clone(),
                                cx,
                            );
                        }
                    }
                    _ => {}
                }
                if let Some(chat) = &self.chat {
                    chat.store.update(cx, |s, cx| s.on_event(event, cx));
                }
            }
            ConnectionEvent::LocalDataReset { .. } => {}
        }
    }

    fn sync_offline(&mut self, cx: &mut Context<Self>) {
        let connection = self.stores.connection.read(cx);
        let offline = !connection.is_connected() || connection.online() == Some(false);
        // The window's pill says the state once; Send, dimmed, says why in
        // its tooltip (no second word beside it).
        let reason = offline
            .then(|| crate::views::status::send_waits(&connection.status(true, None), cx.l10n()));
        if self.composer.read(cx).offline != offline {
            // Chat › Start Voice Call follows the window going offline and back.
            cx.defer(crate::menus::refresh_menus);
        }
        self.composer.update(cx, |c, cx| {
            if c.offline != offline || c.offline_reason != reason || c.offline_word.is_some() {
                c.offline = offline;
                c.offline_reason = reason;
                c.offline_word = None;
                cx.notify();
            }
        });
    }

    // ── Sending ─────────────────────────────────────────────────────────

    /// Sends `text` with the composer's options: in the open chat, or as a
    /// new chat.
    pub fn send_text(
        &mut self,
        text: String,
        mentions: Vec<ComposerMentionDto>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if text.trim().is_empty() && !self.composer_store.read(cx).has_attachments() {
            return;
        }
        // A new chat's first message is still on its way: keep this one in
        // the composer rather than starting a second chat.
        if self.chat.is_none() && self.first_send_pending(cx) {
            self.composer.update(cx, |c, cx| {
                // Not sent: its recordings stay with the draft too.
                let held = c.take_sent_recordings();
                c.recordings_kept(held, cx);
                c.restore_with(&text, &mentions, window, cx)
            });
            return;
        }
        let files = self.composer_store.read(cx).pending_files();
        let model = self
            .composer_store
            .read(cx)
            .next_model()
            .map(|m| m.name.clone());
        // Given back with the text if the send fails.
        let held = self.composer.update(cx, |c, _| c.take_sent_recordings());
        let used = self
            .composer_store
            .read(cx)
            .one_shot()
            .with_mentions(mentions.clone())
            .with_recordings(held);
        let options = self
            .composer_store
            .update(cx, |c, cx| c.take_turn(mentions, cx));
        let pending = PendingMessage {
            files,
            ..PendingMessage::new(text.clone())
        };
        // Whose settings the first message carries (not their values).
        let sent_params = self.composer_store.read(cx).params_owner();
        let compare = options.compare_models.clone();
        if let Some(chat) = &self.chat {
            let turn = options.into_turn(text.clone(), None, false);
            let task = chat.store.update(cx, |s, cx| {
                s.model_hint = model;
                s.compare_hint = compare;
                s.send(turn, pending, cx)
            });
            chat.transcript.update(cx, |t, cx| t.scroll_to_end(cx));
            let composer = self.composer.downgrade();
            let models = self.composer_store.downgrade();
            cx.spawn_in(window, async move |_, cx| {
                if task.await.is_err() {
                    let _ = composer
                        .update_in(cx, |c, window, cx| c.give_back(&text, used, window, cx));
                } else {
                    let _ = composer.update(cx, |c, cx| c.recordings_taken(held, cx));
                }
                // `turns.send` with no model lets the daemon pick (and keep)
                // one: the label shows it without opening the picker.
                let _ = models.update(cx, |m, cx| m.refresh_models(cx));
            })
            .detach();
            return;
        }
        let temporary = match self.stores.navigation.read(cx).selection() {
            Selection::New { temporary } => *temporary,
            Selection::Chat(_) | Selection::Area(_) => false,
        } || self.composer.read(cx).temporary;
        let turn = options.into_turn(text.clone(), None, temporary);
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::TurnsSend>(&turn);
        // "New Chat in Folder": the daemon makes the chat in the folder (the
        // composer keeps which, a temporary chat's too), so the folder's
        // prompt and knowledge apply to the first answer.
        // The composition it was sent from: replaced meanwhile (a fresh
        // Clipboard or Compose in the same new chat), it is not taken over,
        // nor does it hold the fresh one's send back.
        let ticket = self.composer_store.read(cx).ticket();
        self.starting = Some(ticket);
        // The new chat this send came from: if the user has gone elsewhere
        // by the reply, the chat is made but not opened over their choice.
        // A new chat in a folder is the same selection in another folder:
        // the folder counts too.
        let place = |n: &crate::stores::navigation::NavigationStore| {
            (
                n.selection().clone(),
                n.new_chat_folder().map(str::to_string),
            )
        };
        let origin = place(self.stores.navigation.read(cx));
        let account = self.account.clone();
        cx.notify();
        cx.spawn_in(window, async move |this, cx| {
            let result = call.await;
            let _ = this.update_in(cx, |this, window, cx| {
                // Another account since: this send is the last one's. It
                // opens, rekeys and clears nothing here (the account change
                // already ended its wait).
                if this.account != account {
                    return;
                }
                // Its own wait only: a later send owns it now otherwise.
                if this.starting == Some(ticket) {
                    this.starting = None;
                }
                let still_here = place(this.stores.navigation.read(cx)) == origin
                    && this.composer_store.read(cx).holds(ticket);
                match result {
                    // Made (in its folder, by the daemon), but not opened over
                    // where the user went since. Its settings went with it.
                    Ok(_) if !still_here => {
                        this.composer_store
                            .update(cx, |m, cx| m.forget_sent_params(sent_params.as_ref(), cx));
                        this.composer
                            .update(cx, |c, cx| c.recordings_taken(held, cx));
                    }
                    Ok(accepted) => {
                        this.composer
                            .update(cx, |c, cx| c.recordings_taken(held, cx));
                        // Its folder's model and its own settings went with it.
                        this.composer_store.update(cx, |m, cx| m.new_chat_sent(cx));
                        let greeting = this.greeting(cx);
                        let store = this.open_chat(accepted.chat_id.clone(), cx);
                        this.handoff = Some(Handoff {
                            start: cx.background_executor().now(),
                            greeting,
                            temporary,
                        });
                        store.update(cx, |s, cx| {
                            s.model_hint = model;
                            s.compare_hint = compare;
                            s.started(pending, &accepted, temporary, cx)
                        });
                        let id = accepted.chat_id.clone();
                        // What was typed while it waited, and what is typed
                        // next, is the new chat's draft (open first, so the
                        // selection finds it already open).
                        let text = this.composer.read(cx).text(cx);
                        this.composer_store.update(cx, |c, cx| {
                            c.adopt_draft(
                                DraftKey {
                                    chat_id: Some(id.clone()),
                                    folder_id: None,
                                },
                                &text,
                                cx,
                            )
                        });
                        this.stores.navigation.update(cx, |n, cx| n.open(id, cx));
                        this.composer.update(cx, |c, cx| c.focus_input(window, cx));
                    }
                    Err(e) => {
                        log::warn!("turns.send (new chat): {e}");
                        this.composer
                            .update(cx, |c, cx| c.give_back(&text, used, window, cx));
                        let msg = cx.l10n().desktop_action_failed();
                        this.toast(NoticeLevel::Warning, msg, cx);
                    }
                }
                this.composer_store.update(cx, |m, cx| m.refresh_models(cx));
                cx.notify();
            });
        })
        .detach();
    }

    /// Queues `text`, with the composer's files and context, behind the
    /// open chat's running answer. Refused: it goes back in the composer.
    fn queue_text(
        &mut self,
        text: String,
        mentions: Vec<ComposerMentionDto>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(chat) = &self.chat else {
            return;
        };
        let chat_id = chat.store.read(cx).chat_id().to_string();
        // Given back with the text if the queue refuses it.
        let held = self.composer.update(cx, |c, _| c.take_sent_recordings());
        let used = self
            .composer_store
            .read(cx)
            .one_shot()
            .with_mentions(mentions.clone())
            .with_recordings(held);
        let add = self
            .composer_store
            .update(cx, |c, cx| c.take_turn(mentions, cx))
            .into_queued(text.clone(), chat_id);
        let task = chat.store.update(cx, |s, cx| s.queue_add(add, cx));
        cx.spawn_in(window, async move |this, cx| {
            let queued = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                if queued {
                    this.composer
                        .update(cx, |c, cx| c.recordings_taken(held, cx));
                    // The queue lives only while Conduit is open: said once.
                    if !std::mem::replace(&mut this.queue_noted, true) {
                        let note = cx.l10n().queued_drafts_session_note();
                        this.toast(NoticeLevel::Info, note, cx);
                    }
                } else {
                    this.composer
                        .update(cx, |c, cx| c.give_back(&text, used, window, cx));
                }
            });
        })
        .detach();
    }

    /// Hands `text` to the running Hermes turn (`steer`), or as the next
    /// message. Hermes not saying whether the turn saw it keeps the text, and
    /// says so.
    fn steer_text(
        &mut self,
        text: String,
        mentions: Vec<ComposerMentionDto>,
        steer: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(chat) = &self.chat else {
            return;
        };
        let held = self.composer.update(cx, |c, _| c.take_sent_recordings());
        let used = self
            .composer_store
            .read(cx)
            .text_only()
            .with_mentions(mentions.clone())
            .with_recordings(held);
        let task = chat
            .store
            .update(cx, |s, cx| s.steer(text.clone(), mentions, steer, cx));
        cx.spawn_in(window, async move |this, cx| {
            let result = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                let l10n = cx.l10n().clone();
                let failure = match result {
                    Ok(r) if r.accepted => None,
                    Ok(r) if r.uncertain => Some(l10n.hermes_steer_uncertain()),
                    Ok(_) => Some(l10n.desktop_action_failed()),
                    Err(e) => {
                        log::warn!("turns.steer: {e}");
                        Some(l10n.desktop_action_failed())
                    }
                };
                if let Some(message) = failure {
                    this.composer
                        .update(cx, |c, cx| c.give_back(&text, used, window, cx));
                    this.toast(NoticeLevel::Warning, message, cx);
                } else {
                    this.composer
                        .update(cx, |c, cx| c.recordings_taken(held, cx));
                }
            });
        })
        .detach();
    }

    /// Save as Note (from the + menu): the text becomes a new note named for
    /// today, as on the phone, and leaves the composer.
    fn save_as_note(&mut self, text: String, window: &mut Window, cx: &mut Context<Self>) {
        let title = today_title();
        let note = NoteSave {
            id: None,
            title,
            // The text as one plain run: the note keeps its markdown as
            // typed, as mobile's does.
            ops: Some(vec![
                serde_json::json!({ "insert": format!("{}\n", text.trim_end()) }),
            ]),
            page_id: None,
            base_ops: None,
            // Made under the account the words were written under, or
            // refused (a switch conduitd heard of first).
            account_id: self.stores.accounts.read(cx).active().map(|a| a.id.clone()),
        };
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::NotesSave>(&note);
        let used = self.composer_store.read(cx).text_only();
        self.composer.update(cx, |c, cx| c.clear_text(window, cx));
        let held = self.composer.update(cx, |c, _| c.take_sent_recordings());
        let used = used.with_recordings(held);
        cx.spawn_in(window, async move |this, cx| {
            let result = call.await;
            let _ = this.update_in(cx, |this, window, cx| {
                let l10n = cx.l10n().clone();
                match result {
                    Ok(_) => {
                        this.composer
                            .update(cx, |c, cx| c.recordings_taken(held, cx));
                        this.toast(NoticeLevel::Info, l10n.desktop_saved_as_note(), cx)
                    }
                    Err(e) => {
                        log::warn!("notes.save: {e}");
                        this.composer
                            .update(cx, |c, cx| c.give_back(&text, used, window, cx));
                        this.toast(NoticeLevel::Warning, l10n.error_message(), cx);
                    }
                }
            });
        })
        .detach();
    }

    // ── The queue ───────────────────────────────────────────────────────

    pub fn edit_queued(
        &mut self,
        draft_id: &str,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let text = text.to_string();
        let input = cx.new(|cx| {
            let mut s = InputState::new(window, cx);
            s.set_value(text, window, cx);
            s
        });
        input.update(cx, |s, cx| s.focus(window, cx));
        self._subscriptions.push(cx.subscribe_in(
            &input,
            window,
            |this, _, e: &InputEvent, window, cx| {
                if matches!(e, InputEvent::PressEnter { .. }) {
                    this.save_queue_edit(window, cx);
                }
            },
        ));
        self.queue_edit = Some(QueueEditing {
            draft_id: draft_id.to_string(),
            input,
        });
        cx.notify();
    }

    /// Saves the inline edit. The editor, with what was typed, stays until
    /// `queue.edit` takes it; a refusal (a message already going out) is
    /// said by the chat's failure notice and leaves the text to try again.
    pub fn save_queue_edit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let (Some(edit), Some(chat)) = (&self.queue_edit, &self.chat) else {
            return;
        };
        let text = edit.input.read(cx).value().trim().to_string();
        if text.is_empty() {
            self.queue_edit = None;
            self.focus_composer(window, cx);
            cx.notify();
            return;
        }
        let draft_id = edit.draft_id.clone();
        let input = edit.input.entity_id();
        let task = chat
            .store
            .update(cx, |s, cx| s.queue_edit(&draft_id, &text, cx));
        cx.spawn_in(window, async move |this, cx| {
            let saved = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                // The editor that asked, still holding what was saved: text
                // typed while the save was out stays to be saved again.
                let same = this.queue_edit.as_ref().is_some_and(|e| {
                    e.draft_id == draft_id
                        && e.input.entity_id() == input
                        && e.input.read(cx).value().trim() == text
                });
                if saved && same {
                    this.queue_edit = None;
                    this.focus_composer(window, cx);
                    cx.notify();
                }
            });
        })
        .detach();
    }

    pub fn cancel_queue_edit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.queue_edit = None;
        self.focus_composer(window, cx);
        cx.notify();
    }

    pub fn remove_queued(&mut self, draft_id: &str, cx: &mut Context<Self>) {
        if let Some(chat) = &self.chat {
            chat.store
                .update(cx, |s, cx| s.queue_remove(draft_id, cx))
                .detach();
            let text = cx.l10n().queued_draft_removed();
            self.toast(NoticeLevel::Info, text, cx);
        }
    }

    /// Stop & Send: the answer stops and this message goes now.
    pub fn send_queued_now(&mut self, draft_id: &str, cx: &mut Context<Self>) {
        let Some(chat) = &self.chat else {
            return;
        };
        let task = chat
            .store
            .update(cx, |s, cx| s.queue_send_now(draft_id, cx));
        cx.spawn(async move |this, cx| {
            let outcome = task.await;
            let _ = this.update(cx, |this, cx| {
                let l10n = cx.l10n().clone();
                let message = match outcome.as_deref() {
                    Some("admitted") | None => return,
                    Some("stopFailed") => l10n.queued_draft_stop_failed(),
                    Some("blockedByUpload") => l10n.queued_draft_uploading(),
                    _ => l10n.queued_drafts_send_failed(),
                };
                this.toast(NoticeLevel::Warning, message, cx);
            });
        })
        .detach();
    }

    pub fn retry_queue(&mut self, cx: &mut Context<Self>) {
        if let Some(chat) = &self.chat {
            chat.store.update(cx, |s, cx| s.queue_retry(cx)).detach();
        }
    }

    /// Chat › Read Aloud has a chat to read from: a chat the window shows,
    /// whether it takes changes or not (read-only, temporary, Hermes); not
    /// the chat kept loaded behind another area's pane. Without an answer
    /// yet it reads nothing.
    pub fn can_read_aloud(&self, cx: &App) -> bool {
        self.chat.is_some()
            && self
                .stores
                .navigation
                .read(cx)
                .selection()
                .chat_id()
                .is_some()
    }

    /// Chat › Read Aloud: the newest answer, or Stop Speaking while it is
    /// read (Resume while paused), as its own Read Aloud does.
    pub fn read_aloud_last(&mut self, cx: &mut Context<Self>) {
        if !self.can_read_aloud(cx) {
            return;
        }
        let Some(chat) = &self.chat else { return };
        let store = chat.store.read(cx);
        let Some(answer) = store.last_answer_id() else {
            return;
        };
        let chat_id = store.chat_id().to_string();
        self.stores
            .speech
            .update(cx, |s, cx| s.toggle(chat_id, answer, cx));
    }

    // ── Voice calls ───────────────────────────────────────────────────

    /// Start Voice Call: in the open chat, or in the new chat this pane
    /// shows (its model, folder and temporary switch, as a send would).
    /// Dictation stops: the call owns the microphone.
    pub fn start_call(&mut self, cx: &mut Context<Self>) {
        if self.stores.call.read(cx).is_active() {
            return;
        }
        // ⌥⌘V as the button: only when the core admits a call, online.
        if !self.call_startable(cx) {
            return;
        }
        if self
            .chat
            .as_ref()
            .is_some_and(|c| c.store.read(cx).read_only())
        {
            return;
        }
        self.begin_call(cx);
    }

    /// Starts the call this pane shows the way to: in the open chat, or in
    /// the new chat with its model, folder and Temporary switch as shown.
    /// Every start of a call in the main window comes here, so a call never
    /// saves a chat the composer shows as temporary. Dictation stops: the
    /// call owns the microphone.
    fn begin_call(&mut self, cx: &mut Context<Self>) {
        if let Some(dictation) = self.composer.read(cx).dictation.clone()
            && dictation.read(cx).is_active()
        {
            dictation.update(cx, |d, cx| d.cancel(cx));
        }
        let chat_id = self.open_chat_id(cx);
        let model = self
            .composer_store
            .read(cx)
            .selected_model()
            .map(|m| m.id.clone());
        let navigation = self.stores.navigation.read(cx);
        let temporary = chat_id.is_none()
            && (matches!(navigation.selection(), Selection::New { temporary: true })
                || self.composer.read(cx).temporary);
        let folder = chat_id
            .is_none()
            .then(|| navigation.new_chat_folder().map(str::to_string))
            .flatten();
        self.stores
            .call
            .update(cx, |c, cx| c.start(chat_id, model, folder, temporary, cx));
    }

    /// The widget's Voice Call and Shortcuts' Start Voice Call, once this
    /// pane shows the new chat they opened: the call starts there as the
    /// composer's call button would start it (its Temporary switch, folder
    /// and model). When another chat took the pane's place first (a later
    /// link), no call starts: never one in a chat it was not asked for.
    /// The core's refusal shows on the call strip, so no readiness check.
    pub fn call_in_new_chat(&mut self, cx: &mut Context<Self>) {
        if self.stores.call.read(cx).is_active() || self.chat.is_some() {
            return;
        }
        if !matches!(
            self.stores.navigation.read(cx).selection(),
            Selection::New { .. }
        ) {
            return;
        }
        self.begin_call(cx);
    }

    /// A call can start here now, as the composer's call button would
    /// take it: the core admits one with the chosen model, and the window is
    /// online.
    pub fn call_startable(&self, cx: &App) -> bool {
        let composer = self.composer.read(cx);
        composer.call_ready && !composer.offline
    }

    /// Chat › Start Voice Call, or End Voice Call while one is on.
    pub fn toggle_call(&mut self, cx: &mut Context<Self>) {
        if self.stores.call.read(cx).is_active() {
            self.stores.call.update(cx, |c, cx| c.end(cx));
        } else {
            self.start_call(cx);
        }
    }

    /// Show Call: the call's chat, with its strip open.
    pub fn show_call(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.stores.call.read(cx).chat_id().map(str::to_string) else {
            return;
        };
        self.stores.call.update(cx, |c, cx| {
            if c.collapsed {
                c.toggle_collapsed(cx);
            }
        });
        if self.open_chat_id(cx).as_deref() != Some(id.as_str()) {
            self.stores.navigation.update(cx, |n, cx| n.open(id, cx));
        }
    }

    fn on_call_changed(&mut self, cx: &mut Context<Self>) {
        let call = self.stores.call.read(cx);
        let chat_id = call.chat_id().map(str::to_string);
        // A call started in a new chat (here, or from Quick Ask): once its
        // first turn has made the chat, the chat opens where a new chat is
        // shown; over another chat, the capsule offers Show Call.
        if call.follow_new
            && let Some(id) = chat_id
        {
            self.stores.call.update(cx, |c, _| c.follow_new = false);
            if self.chat.is_none() {
                self.stores.navigation.update(cx, |n, cx| n.open(id, cx));
            }
        }
        self.sync_call_offer(cx);
        cx.defer(crate::menus::refresh_menus);
        cx.notify();
    }

    /// The composer's call button: offered in a chat that takes answers,
    /// ready while no call is on and the core admits a call with the chosen
    /// model (`ComposerOptions::voice_call`, the phone's rule: a Hermes
    /// chat's call is a Standard one).
    fn sync_call_offer(&mut self, cx: &mut Context<Self>) {
        let offer = !self
            .chat
            .as_ref()
            .is_some_and(|c| c.store.read(cx).read_only());
        let on = self.stores.call.read(cx).is_active();
        let composer = self.composer_store.read(cx);
        let ready = !on && composer.selected_model().is_some() && composer.options.voice_call;
        self.composer.update(cx, |c, cx| {
            if c.call_offer != offer || c.call_ready != ready || c.call_on != on {
                c.call_offer = offer;
                c.call_ready = ready;
                c.call_on = on;
                cx.notify();
            }
        });
    }

    /// Whether a new chat's first message, sent from the composition shown
    /// now, is still on its way.
    fn first_send_pending(&self, cx: &App) -> bool {
        self.starting
            .is_some_and(|ticket| self.composer_store.read(cx).holds(ticket))
    }

    /// Whether the call's strip belongs in this pane now: the call is in
    /// the open chat, or it is starting the new chat this pane shows.
    fn call_here(&self, cx: &App) -> bool {
        let call = self.stores.call.read(cx);
        if !call.is_shown() {
            return false;
        }
        match call.chat_id() {
            Some(id) => self.open_chat_id(cx).as_deref() == Some(id),
            None => self.chat.is_none() && call.follow_new,
        }
    }

    /// Follows the reading: its answer's Read Aloud says Stop Speaking and
    /// its words are marked in place; a reading of another chat pauses when
    /// this one opens, as the phone's does when its chat goes.
    fn sync_speech(&mut self, cx: &mut Context<Self>) {
        let open = self.open_chat_id(cx);
        let (reading_chat, message, speaking) = {
            let s = self.stores.speech.read(cx);
            (
                s.chat_id().map(str::to_string),
                s.progress().message_id.clone(),
                s.is_speaking(),
            )
        };
        if let Some(chat) = &self.chat {
            let here = reading_chat.is_some() && reading_chat == open;
            let speech = self.stores.speech.clone();
            chat.transcript.update(cx, |t, cx| {
                t.set_reading(message.filter(|_| here), cx);
                t.follow_reading(here.then_some(&speech), cx);
            });
        }
        if speaking && reading_chat.is_some() && reading_chat != open {
            self.stores.speech.update(cx, |s, cx| s.pause(cx));
        }
        cx.notify();
    }

    /// A coding agent answers the open chat (`ComposerOptions.agentChat`):
    /// no answer is run again and no message edited.
    pub fn agent_chat(&self, cx: &App) -> bool {
        self.composer_store.read(cx).options.agent_chat
    }

    /// Chat › Regenerate: the newest answer again.
    pub fn regenerate_last(&mut self, cx: &mut Context<Self>) {
        if self.agent_chat(cx) {
            return;
        }
        if let Some(chat) = &self.chat {
            chat.store.update(cx, |s, cx| {
                if let Some(id) = s.last_answer_id() {
                    s.regenerate(&id, None, cx);
                }
            });
        }
    }

    /// Esc: stops the reading aloud while there is one (what is heard
    /// first), else the running answer.
    pub fn stop(&mut self, cx: &mut Context<Self>) {
        if self.stores.speech.read(cx).is_active() {
            self.stores.speech.update(cx, |s, cx| s.stop(cx));
            return;
        }
        if let Some(chat) = &self.chat {
            chat.store.update(cx, |s, cx| {
                if s.is_streaming() {
                    s.stop(cx)
                }
            });
        }
    }

    // ── Shortcuts ───────────────────────────────────────────────────────

    pub fn focus_composer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.composer.update(cx, |c, cx| c.focus_input(window, cx));
    }

    /// What is handed to the new chat just selected (a share's words and
    /// files, Open With, a Services selection, Quick Ask's Open in
    /// Conduit): the pane moves to that chat's draft now, and the words and
    /// files go in once the composer has switched to it (it clears for a
    /// new draft as the switch lands), so they never end up in the draft of
    /// the chat shown before, or cleared.
    pub fn hand_to_new_chat(
        &mut self,
        text: Option<String>,
        paths: Vec<std::path::PathBuf>,
        carried: Vec<crate::stores::composer::Attachment>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.sync_selection(cx);
        cx.defer_in(window, move |p, window, cx| {
            if let Some(text) = &text {
                p.composer.update(cx, |c, cx| c.set_text(text, window, cx));
            }
            if !paths.is_empty() {
                p.composer_store.update(cx, |c, cx| c.add_paths(&paths, cx));
            }
            if !carried.is_empty() {
                p.composer_store
                    .update(cx, |c, cx| c.adopt_attachments(carried, cx));
            }
            p.focus_composer(window, cx);
        });
    }

    /// What a new chat opened from outside starts with (Send to Conduit,
    /// Send Link, Send Image, the widget's links, Open With, Quick Ask's Open
    /// in Conduit), once the pane has followed it: written only while the
    /// new chat that request opened is still the one selected (`ticket`, the
    /// selection it made). A link handled right after it in the same batch
    /// (`conduit://chat/<id>`) keeps its own draft. Says whether it was
    /// written.
    pub fn compose_new_chat(
        &mut self,
        ticket: &Selection,
        content: NewChatContent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.stores.navigation.read(cx).selection() != ticket {
            return false;
        }
        // Read under one account scope, never written for another (a switch
        // while it was read, or while it waited for the main window).
        // "No account" is a scope too: a page read with none never lands
        // once an account signed in, nor one read under an account once none
        // is in charge.
        if content
            .owner
            .as_ref()
            .is_some_and(|crate::shell::deep_link::ReadUnder(scope)| {
                *scope != self.stores.accounts.read(cx).scope_key()
            })
        {
            log::info!("new chat: its content was read under another account; dropped");
            return false;
        }
        let NewChatContent {
            text,
            fresh,
            paths,
            images,
            context,
            carried,
            owner: _,
        } = content;
        if fresh {
            let text = text.as_deref().unwrap_or_default();
            self.composer
                .update(cx, |c, cx| c.start_fresh(text, window, cx));
        } else if let Some(text) = &text {
            self.composer
                .update(cx, |c, cx| c.set_text(text, window, cx));
        }
        if !paths.is_empty() {
            self.composer_store
                .update(cx, |c, cx| c.add_paths(&paths, cx));
        }
        for image in &images {
            self.composer_store
                .update(cx, |c, cx| c.add_image(image, cx));
        }
        for item in context {
            self.composer_store
                .update(cx, |c, cx| c.add_context(item, cx));
        }
        if !carried.is_empty() {
            self.composer_store
                .update(cx, |c, cx| c.adopt_attachments(carried, cx));
        }
        self.focus_composer(window, cx);
        true
    }

    /// The ticket a Continuity Camera photo asked for now would carry: this
    /// account scope, this composer's draft and its composition.
    pub fn import_target(&self, cx: &App) -> crate::shell::continuity_camera::ImportTarget {
        let composer = self.composer_store.read(cx);
        crate::shell::continuity_camera::ImportTarget {
            scope: self.stores.accounts.read(cx).scope_key(),
            draft: composer.draft_key().cloned(),
            round: composer.draft_round(),
        }
    }

    /// A Continuity Camera photo or scan saved at `path` (`name`, as the
    /// composer names it), with the ticket its + menu session took
    /// (`asked`): attached only while that account scope, composer and
    /// composition are still the ones shown. Otherwise it is dropped, and a
    /// toast says it couldn't be attached. Says whether it was attached.
    pub fn attach_import(
        &mut self,
        asked: &crate::shell::continuity_camera::ImportTarget,
        path: &std::path::Path,
        name: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if *asked != self.import_target(cx) {
            log::info!(
                "continuity camera: asked for another account, chat or composition; dropped"
            );
            let message = cx.l10n().desktop_attachment_failed(name);
            self.stores
                .toasts
                .update(cx, |t, cx| t.show(NoticeLevel::Warning, message, cx));
            return false;
        }
        self.composer_store
            .update(cx, |c, cx| c.add_paths(&[path.to_path_buf()], cx));
        self.focus_composer(window, cx);
        true
    }

    pub fn open_model_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.composer.update(cx, |c, cx| c.open_picker(window, cx));
    }

    // ── Chat Settings and Tool Settings ─────────────────────────────────

    /// The open chat's id (None for a new chat).
    fn open_chat_id(&self, cx: &App) -> Option<String> {
        self.chat
            .as_ref()
            .map(|c| c.store.read(cx).chat_id().to_string())
    }

    /// Asks the daemon again what the menus offer, when what that depends
    /// on changed.
    /// Asks again whether the header offers Computer, when what it
    /// depends on moved.
    fn sync_computer(&mut self, cx: &mut Context<Self>) {
        let Some(chat_id) = self.open_chat_id(cx) else {
            self.computer = None;
            self.computer_key = None;
            return;
        };
        let enabled = self
            .stores
            .app_settings
            .read(cx)
            .settings()
            .computer_enabled;
        let selected = self.stores.areas.read(cx).terminal_selected.clone();
        let key = (chat_id.clone(), enabled, selected, self.computer_revision);
        if self.computer_key.as_ref() == Some(&key) {
            return;
        }
        self.computer_key = Some(key.clone());
        if self.computer.as_ref().is_some_and(|c| c.chat_id != chat_id) {
            self.computer = None;
        }
        if !enabled {
            self.computer = None;
            return;
        }
        let rpc = self.stores.connection.read(cx).rpc();
        let asked = crate::views::terminal::chat::computer_status(&rpc, chat_id, cx);
        self._computer = Some(cx.spawn(async move |this: gpui_kit::WeakEntity<Self>, cx| {
            let offer = asked.await;
            let _ = this.update(cx, |this, cx| {
                if this.computer_key.as_ref() != Some(&key) {
                    return;
                }
                if this.computer != offer {
                    this.computer = offer;
                    cx.notify();
                }
            });
        }));
    }

    pub fn sync_settings_offer(&mut self, cx: &mut Context<Self>) {
        let composer = self.composer_store.read(cx);
        let key = OfferKey {
            scope: composer.scope(),
            chat_id: self.open_chat_id(cx),
            model_id: composer.selected_model().map(|m| m.id.clone()),
            tool_ids: composer.tool_ids.iter().cloned().collect(),
            filter_ids: composer.filter_ids.iter().cloned().collect(),
            advanced: self
                .stores
                .app_settings
                .read(cx)
                .settings()
                .advanced_features_enabled,
            has_draft: composer
                .draft_params
                .as_object()
                .is_some_and(|o| !o.is_empty()),
        };
        if self.settings_key.as_ref() == Some(&key) {
            return;
        }
        // Nothing to ask before the models are known, and nothing offered
        // meanwhile (not the last account's or model's).
        if key.model_id.is_none() {
            self.settings_key = None;
            self._offer = None;
            if self.settings_offer != SettingsOffer::default() {
                self.settings_offer = SettingsOffer::default();
                cx.defer(crate::menus::refresh_menus);
                cx.notify();
            }
            return;
        }
        self.settings_key = Some(key.clone());
        let rpc = self.stores.connection.read(cx).rpc();
        let draft = composer.draft_params.clone();
        let settings = rpc.call::<methods::ChatSettingsGet>(&conduit_protocol::ChatSettingsQuery {
            chat_id: key.chat_id.clone(),
            model_id: key.model_id.clone(),
            draft: if draft.is_null() {
                serde_json::json!({})
            } else {
                draft
            },
        });
        let targets = rpc.call::<methods::ValvesTargets>(&conduit_protocol::ValveTargetsQuery {
            model_id: key.model_id.clone(),
            tool_ids: key.tool_ids.clone(),
            filter_ids: key.filter_ids.clone(),
        });
        self._offer = Some(cx.spawn(async move |this: gpui_kit::WeakEntity<Self>, cx| {
            let settings = settings.await;
            let targets = targets.await;
            let _ = this.update(cx, |this, cx| {
                if this.settings_key.as_ref() != Some(&key) {
                    return;
                }
                // A failed question is asked again the next time the
                // composer changes (a reconnect lists the models again).
                if settings.is_err() || targets.is_err() {
                    this.settings_key = None;
                }
                let offer = SettingsOffer {
                    chat_settings: settings
                        .map(|s| s.entry != conduit_protocol::ChatSettingsEntry::None)
                        .unwrap_or(false),
                    tool_targets: targets
                        .ok()
                        .filter(|t| t.advanced)
                        .map(|t| t.targets)
                        .unwrap_or_default(),
                };
                if this.settings_offer != offer {
                    this.settings_offer = offer;
                    // After this update: the menus read the pane.
                    cx.defer(crate::menus::refresh_menus);
                    cx.notify();
                }
                let _ = cx;
            });
        }));
    }

    /// Chat › Chat Settings… (⌘I): the open chat's settings, or the new
    /// chat's (kept for its first message).
    pub fn open_chat_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.settings_offer.chat_settings {
            return;
        }
        // A new chat whose first message is on its way: its settings went
        // with it, and the chat it makes is not open yet.
        if self.first_send_pending(cx) && self.open_chat_id(cx).is_none() {
            return;
        }
        let composer = self.composer_store.read(cx);
        let mark = composer.draft_mark();
        let target = crate::views::chat_settings::ChatSettingsTarget {
            chat_id: self.open_chat_id(cx),
            model_id: composer.selected_model().map(|m| m.id.clone()),
            draft: if composer.draft_params.is_null() {
                serde_json::json!({})
            } else {
                composer.draft_params.clone()
            },
        };
        let store = self.composer_store.downgrade();
        // Saved to the draft it was opened for only: once that draft's chat
        // is made (or another opens), nothing lands on the next new chat.
        let sink: crate::views::chat_settings::DraftSink = Rc::new(move |params, cx| {
            let _ = store.update(cx, |s, cx| s.set_draft_params_for(&mark, params, cx));
        });
        let stores = self.stores.clone();
        crate::views::sheet::open(
            window,
            crate::views::chat_settings::WIDTH,
            cx,
            move |w, cx| {
                crate::views::chat_settings::ChatSettingsSheet::new(
                    stores,
                    target,
                    Some(sink),
                    w,
                    cx,
                )
            },
        );
    }

    /// Chat › Tool Settings…: the user's own settings for the tools,
    /// filters and pipe this chat uses.
    pub fn open_tool_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let targets = self.settings_offer.tool_targets.clone();
        if targets.is_empty() {
            return;
        }
        let stores = self.stores.clone();
        crate::views::sheet::open(window, crate::views::valves::WIDTH, cx, move |w, cx| {
            crate::views::valves::ValvesSheet::new(stores, targets, w, cx)
        });
    }

    /// The More menu's items for the open chat itself, before Delete…:
    /// Chat Settings…, Tool Settings… and Show Branches…
    pub fn more_menu_items(&self, cx: &App) -> Vec<(String, Box<dyn gpui_kit::Action>)> {
        let l10n = cx.l10n();
        let mut items: Vec<(String, Box<dyn gpui_kit::Action>)> = vec![];
        if self.settings_offer.chat_settings {
            items.push((
                l10n.desktop_chat_settings_menu(),
                Box::new(crate::actions::ChatSettings),
            ));
        }
        if !self.settings_offer.tool_targets.is_empty() {
            items.push((
                l10n.desktop_tool_settings_menu(),
                Box::new(crate::actions::ToolSettings),
            ));
        }
        // Branches are an Open WebUI chat's; a Hermes chat branches from a
        // reply (Branch from Here).
        if self
            .chat
            .as_ref()
            .is_some_and(|c| c.store.read(cx).hermes().is_none())
        {
            items.push((
                l10n.desktop_menu_show_branches(),
                Box::new(crate::actions::ShowBranches),
            ));
        }
        if self.hermes_context(cx) {
            items.push((
                l10n.desktop_hermes_context_usage_menu(),
                Box::new(crate::actions::ShowContextUsage),
            ));
        }
        items
    }

    /// The open chat is a Hermes session whose context window can be read.
    pub fn hermes_context(&self, cx: &App) -> bool {
        self.chat.as_ref().is_some_and(|chat| {
            chat.store
                .read(cx)
                .detail
                .as_ref()
                .is_some_and(|d| d.abilities.hermes_context)
        })
    }

    /// Chat › Context & Usage…: the open Hermes chat's context window,
    /// usage and Compact Now.
    pub fn show_context_usage(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.hermes_context(cx) {
            return;
        }
        let Some(chat) = self.chat.as_ref() else {
            return;
        };
        let chat_id = chat.store.read(cx).chat_id().to_string();
        crate::views::hermes_context_sheet::open(chat_id, window, cx);
    }

    /// Ask Conduit: the text selected in an answer goes into the composer,
    /// at the caret, to edit and send (as on the phone).
    pub fn ask_conduit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(text) = self
            .chat
            .as_ref()
            .and_then(|c| c.transcript.read(cx).selected_reply_text(cx))
        else {
            return;
        };
        self.composer
            .update(cx, |c, cx| c.insert_at_caret(&text, window, cx));
    }

    /// Copy, from an answer's menu: the selected text.
    pub fn copy_selection(&mut self, cx: &mut Context<Self>) {
        if let Some(text) = self
            .chat
            .as_ref()
            .and_then(|c| c.transcript.read(cx).selected_reply_text(cx))
        {
            cx.write_to_clipboard(ClipboardItem::new_string(text));
        }
    }

    fn last_reply(&self, cx: &App) -> Option<String> {
        self.chat.as_ref()?.store.read(cx).last_reply()
    }

    pub fn copy_last_response(&mut self, cx: &mut Context<Self>) {
        match self.last_reply(cx) {
            Some(text) => {
                cx.write_to_clipboard(ClipboardItem::new_string(text));
                self.notify_copied(cx);
            }
            None => {
                let text = cx.l10n().desktop_nothing_to_copy();
                self.toast(NoticeLevel::Info, text, cx);
            }
        }
    }

    pub fn copy_last_code_block(&mut self, cx: &mut Context<Self>) {
        match self.last_reply(cx).as_deref().and_then(last_code_block) {
            Some(code) => {
                cx.write_to_clipboard(ClipboardItem::new_string(code));
                let text = cx.l10n().desktop_code_copied();
                self.toast(NoticeLevel::Info, text, cx);
            }
            None => {
                let text = cx.l10n().desktop_nothing_to_copy();
                self.toast(NoticeLevel::Info, text, cx);
            }
        }
    }

    // ── Find in Chat ────────────────────────────────────────────────────

    /// Whether the find bar shows.
    pub fn find_open(&self) -> bool {
        self.find_open
    }

    /// Edit › Find › Find… (⌘F): the find bar, its field focused with its
    /// text selected (finding it again at once). Only over a chat.
    pub fn open_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(chat) = &self.chat else {
            return;
        };
        self.find_open = true;
        self.find_input.update(cx, |s, cx| {
            s.focus(window, cx);
            s.select_all(window, cx);
        });
        let query = self.find_input.read(cx).value().to_string();
        if !query.is_empty() {
            chat.transcript
                .update(cx, |t, cx| t.set_find(Some(query), cx));
        }
        cx.notify();
    }

    /// Done (Esc): the bar goes, with every highlight, and the message field
    /// takes focus back.
    pub fn close_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.find_open {
            return;
        }
        self.find_open = false;
        if let Some(chat) = &self.chat {
            chat.transcript.update(cx, |t, cx| t.set_find(None, cx));
        }
        self.focus_composer(window, cx);
        cx.notify();
    }

    /// Find Next or Previous (⌘G, ⇧⌘G): with the bar closed, it opens on the
    /// last text found.
    pub fn find_step(&mut self, forward: bool, window: &mut Window, cx: &mut Context<Self>) {
        if !self.find_open {
            self.open_find(window, cx);
            if self.find_input.read(cx).value().is_empty() {
                return;
            }
        }
        if let Some(chat) = &self.chat {
            chat.transcript.update(cx, |t, cx| t.find_step(forward, cx));
        }
        cx.notify();
    }

    /// Puts `text` in the find field (opening the bar) and finds it: as
    /// typing it would, for the capture harness and E2E.
    pub fn type_find(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        if !self.find_open {
            self.open_find(window, cx);
        }
        let value = text.to_string();
        self.find_input
            .update(cx, |s, cx| s.set_value(value, window, cx));
        self.find_query(text.to_string(), cx);
    }

    fn find_query(&mut self, query: String, cx: &mut Context<Self>) {
        if let Some(chat) = &self.chat {
            chat.transcript
                .update(cx, |t, cx| t.set_find(Some(query), cx));
        }
        cx.notify();
    }

    /// The find bar: the match count, Find Previous and Next, the field and
    /// Done, at the trailing edge as Safari's.
    fn find_bar(
        &self,
        transcript: &Entity<Transcript>,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let mac = cfg!(target_os = "macos");
        let next_keys = crate::keymap::describe(&crate::keymap::KeyStroke::new("g").primary(), mac);
        let previous_keys =
            crate::keymap::describe(&crate::keymap::KeyStroke::new("g").primary().shift(), mac);
        let status = transcript.read(cx).find_status();
        let count = status.map_or(0, |(_, n)| n);
        let label = match status {
            None => String::new(),
            Some((_, 0)) => l10n.desktop_find_no_matches(),
            Some((Some(i), n)) => l10n.desktop_position_of(&i.to_string(), &n.to_string()),
            Some((None, n)) => l10n.desktop_position_of("0", &n.to_string()),
        };
        let this = cx.entity().downgrade();
        let step = move |forward: bool| {
            let this = this.clone();
            Rc::new(
                move |_: &gpui_kit::ClickEvent, window: &mut Window, cx: &mut App| {
                    let _ = this.update(cx, |p, cx| p.find_step(forward, window, cx));
                },
            )
        };
        let done = {
            let this = cx.entity().downgrade();
            Rc::new(
                move |_: &gpui_kit::ClickEvent, window: &mut Window, cx: &mut App| {
                    let _ = this.update(cx, |p, cx| p.close_find(window, cx));
                },
            )
        };
        let focused = self.find_input.focus_handle(cx).is_focused(window);
        div()
            .id("find-bar")
            .role(Role::Search)
            .aria_label(SharedString::from(l10n.desktop_find_in_chat()))
            .key_context("ConduitFindBar")
            // Esc closes it: the field and the app's Esc (Stop) would take
            // the key first, and the capture phase reaches the bar before
            // either.
            .capture_action(cx.listener(
                |this, _: &gpui_kit::component::input::Escape, window, cx| {
                    this.close_find(window, cx);
                    cx.stop_propagation();
                },
            ))
            .capture_action(cx.listener(|this, _: &StopGenerating, window, cx| {
                this.close_find(window, cx);
                cx.stop_propagation();
            }))
            .flex_none()
            .w_full()
            .h(px(40.))
            .px(px(14.))
            .flex()
            .items_center()
            .justify_end()
            .gap(px(8.))
            .border_b_1()
            .border_color(r.divider)
            .child(
                div()
                    .id("find-count")
                    .role(Role::Status)
                    .aria_label(SharedString::from(label.clone()))
                    .text_size(px(m.small))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(label)),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .child(
                        IconButton::new(
                            "find-previous",
                            IconName::ChevronUp,
                            l10n.desktop_find_previous(),
                        )
                        .size(26., 14.)
                        .shortcut(Some(previous_keys.into()))
                        .disabled(count == 0)
                        .on_click(step(false)),
                    )
                    .child(
                        IconButton::new(
                            "find-next",
                            IconName::ChevronDown,
                            l10n.desktop_find_next(),
                        )
                        .size(26., 14.)
                        .shortcut(Some(next_keys.into()))
                        .disabled(count == 0)
                        .on_click(step(true)),
                    ),
            )
            .child(
                div().w(px(240.)).child(
                    conduit_components::views::kit::field_frame(focused, 28., cx)
                        .rounded_full()
                        .child(conduit_components::assets::icon(
                            IconName::Search,
                            13.,
                            r.text_subtle,
                        ))
                        .child(
                            div().flex_1().min_w_0().child(
                                bare_input(
                                    &self.find_input,
                                    l10n.desktop_find_in_chat(),
                                    m.control,
                                )
                                .accessibility_id("find-query"),
                            ),
                        ),
                ),
            )
            .child(Button::new("find-done", l10n.done()).on_click(done))
            .into_any_element()
    }

    fn greeting(&self, cx: &App) -> String {
        let l10n = cx.l10n().clone();
        let name = self
            .stores
            .accounts
            .read(cx)
            .active()
            .and_then(|a| a.user.as_ref())
            .and_then(|u| u.name.clone())
            .and_then(|n| n.split_whitespace().next().map(str::to_string));
        match name {
            Some(n) => l10n.greeting_title(&crate::views::privacy::name(&n, cx)),
            None => l10n.desktop_new_conversation(),
        }
    }

    /// The approval card's dock: always drawn, since the card opens and
    /// closes its own height (and draws nothing without a request).
    /// The new chat's transcript while its first send hands over to it
    /// ([`Handoff`]): rising into place and fading in, with the greeting
    /// fading out where it was. Just the transcript otherwise.
    fn handed_over(
        &mut self,
        transcript: AnyElement,
        t: &conduit_components::theme::ConduitTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(h) = &self.handoff else {
            return transcript;
        };
        let elapsed = cx
            .background_executor()
            .now()
            .saturating_duration_since(h.start);
        if Handoff::done(elapsed) {
            self.handoff = None;
            return transcript;
        }
        window.request_animation_frame();
        let (greeting, shown, rise) = Handoff::at(elapsed, cx.reduce_motion());
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let leaving = (greeting > 0.001).then(|| {
            div()
                .absolute()
                .inset_0()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(px(10.))
                .px(px(32.))
                .opacity(greeting)
                .child(
                    div()
                        .text_size(px(28.))
                        .font_weight(gpui_kit::FontWeight::BOLD)
                        .text_color(r.text)
                        .child(SharedString::from(h.greeting.clone())),
                )
                .when(h.temporary, |d| {
                    d.child(
                        div()
                            .max_w(px(420.))
                            .text_center()
                            .text_size(px(t.metrics.control))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(l10n.desktop_temporary_hint())),
                    )
                })
        });
        div()
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .relative()
            .children(leaving)
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .flex_col()
                    .relative()
                    .top(px(rise))
                    .opacity(shown)
                    .child(transcript),
            )
            .into_any_element()
    }

    /// A Hermes agent's work over the composer: the chip naming what runs
    /// (it opens the background work sheet), then the plan.
    fn hermes_docked(&self, window: &mut Window, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let Some(chat) = self.chat.as_ref() else {
            return vec![];
        };
        let hermes = chat.store.read(cx).hermes.clone();
        let (agents, processes) = hermes.read(cx).running();
        let plan = hermes.read(cx).work.as_ref().and_then(|w| w.plan.clone());
        let chat_id = hermes.read(cx).chat_id().to_string();
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        let open_work: crate::views::chat::hermes_work::Action = {
            let hermes = hermes.clone();
            std::rc::Rc::new(move |window, cx| {
                crate::views::hermes_work_sheet::open(hermes.clone(), window, cx)
            })
        };
        let chip = crate::views::chat::hermes_work::work_chip(
            agents, processes, open_work, &l10n, &t, window, cx,
        );
        let plan = plan.and_then(|plan| {
            let folded = crate::stores::hermes_work::plan_folded(&chat_id, plan.active, cx);
            let pane = cx.entity().downgrade();
            let toggle: crate::views::chat::hermes_work::Action = {
                let chat_id = chat_id.clone();
                std::rc::Rc::new(move |_, cx| {
                    crate::stores::hermes_work::set_plan_folded(&chat_id, !folded, cx);
                    let _ = pane.update(cx, |_, cx| cx.notify());
                })
            };
            crate::views::chat::hermes_work::plan_card(&plan, folded, toggle, &l10n, &t, window, cx)
        });
        chip.into_iter().chain(plan).collect()
    }

    /// What docks above the composer: the messages queued behind the
    /// answer, and an approval card.
    fn docked(&self, window: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let hermes = self.hermes_docked(window, cx);
        let queue = self.chat.as_ref().and_then(|chat| {
            let t = cx.conduit().clone();
            let queue = chat.store.read(cx).queue.clone();
            let pane = cx.entity().downgrade();
            queue_panel(&queue, self.queue_edit.as_ref(), pane, &t, window, cx)
        });
        // Open WebUI's task checklist, over everything else, as on the
        // phone.
        let tasks = self.chat.as_ref().and_then(|chat| {
            let t = cx.conduit().clone();
            let tasks = chat.store.read(cx).tasks.clone();
            let pane = cx.entity().downgrade();
            crate::views::chat::tasks::task_list(
                &tasks,
                self.tasks_open,
                std::rc::Rc::new(move |_, cx| {
                    let _ = pane.update(cx, |p, cx| {
                        p.tasks_open = !p.tasks_open;
                        cx.notify();
                    });
                }),
                &t,
                cx,
            )
        });
        let t = cx.conduit().clone();
        let chat_id = self.open_chat_id(cx);
        let speech = crate::views::chat::speech_bar::speech_bar(
            &self.stores.speech,
            &self.stores.app_settings,
            chat_id.as_deref(),
            &t,
            cx,
        );
        // The call, minimised or on in another chat: its capsule.
        let call = self.stores.call.read(cx);
        let here = self.call_here(cx);
        let capsule = (call.is_active() && (!here || call.collapsed)).then(|| {
            div()
                .flex()
                .justify_center()
                .pb(px(6.))
                .child(crate::views::chat::call::capsule(
                    &self.stores.call,
                    !here,
                    cx,
                ))
        });
        Some(
            div()
                .flex()
                .flex_col()
                .children(hermes)
                .children(tasks)
                .children(queue)
                .children(speech)
                .child(self.approvals.clone())
                .when(self.chat.is_some(), |d| d.child(self.prompt_card.clone()))
                .children(capsule)
                .into_any_element(),
        )
    }
}

/// Runs `f` on the main window's chat pane.
///
/// Deferred: a key binding dispatches the action from inside the window's
/// own update, where the window cannot be updated again (the call would
/// fail quietly).
fn with_pane(
    cx: &mut App,
    f: impl FnOnce(&mut ChatPane, &mut Window, &mut Context<ChatPane>) + 'static,
) {
    cx.defer(move |cx| with_pane_now(cx, f));
}

fn with_pane_now(cx: &mut App, f: impl FnOnce(&mut ChatPane, &mut Window, &mut Context<ChatPane>)) {
    let Some(state) = cx.try_global::<AppState>() else {
        return;
    };
    let (Some(handle), Some(view)) = (state.main_window, state.main_view.clone()) else {
        return;
    };
    // Only for the main window (Settings and the SSO window have their own
    // keys). A window that has just closed may still read as active.
    if let Some(active) = cx.active_window()
        && active != handle
        && cx.windows().contains(&active)
    {
        return;
    }
    let pane = view.read(cx).chat_pane.clone();
    let _ = handle.update(cx, |_, window, cx| {
        pane.update(cx, |p, cx| f(p, window, cx))
    });
}

/// The chat shortcuts, on the app so they work wherever focus is.
pub fn register_actions(cx: &mut App) {
    cx.on_action(|_: &FocusComposer, cx| with_pane(cx, |p, w, cx| p.focus_composer(w, cx)));
    cx.on_action(|_: &FocusModelPicker, cx| with_pane(cx, |p, w, cx| p.open_model_picker(w, cx)));
    cx.on_action(|_: &ChooseModel, cx| with_pane(cx, |p, w, cx| p.open_model_picker(w, cx)));
    cx.on_action(|_: &StopGenerating, cx| with_pane(cx, |p, _, cx| p.stop(cx)));
    cx.on_action(|_: &crate::actions::ReadAloud, cx| {
        with_pane(cx, |p, _, cx| p.read_aloud_last(cx))
    });
    cx.on_action(|_: &crate::actions::VoiceCall, cx| with_pane(cx, |p, _, cx| p.toggle_call(cx)));
    cx.on_action(|_: &crate::actions::ShowCall, cx| {
        crate::open_main_window(cx);
        cx.defer(|cx| with_pane_now(cx, |p, _, cx| p.show_call(cx)));
    });
    cx.on_action(|_: &crate::actions::EndCall, cx| {
        if let Some(call) = cx.try_global::<AppState>().map(|s| s.stores.call.clone()) {
            call.update(cx, |c, cx| c.end(cx));
        }
    });
    // ⌘. ends the reading from anywhere (Settings' preview too).
    cx.on_action(|_: &crate::actions::StopSpeaking, cx| {
        if let Some(speech) = cx.try_global::<AppState>().map(|s| s.stores.speech.clone()) {
            speech.update(cx, |s, cx| s.stop(cx));
        }
    });
    cx.on_action(|_: &CopyLastResponse, cx| with_pane(cx, |p, _, cx| p.copy_last_response(cx)));
    cx.on_action(|_: &CopyLastCodeBlock, cx| with_pane(cx, |p, _, cx| p.copy_last_code_block(cx)));
    cx.on_action(|_: &crate::actions::AskConduit, cx| {
        with_pane(cx, |p, w, cx| p.ask_conduit(w, cx))
    });
    cx.on_action(|_: &crate::actions::CopySelection, cx| {
        with_pane(cx, |p, _, cx| p.copy_selection(cx))
    });
    // ⌘I is Get Info: the chat's settings (the sidebar's list takes it
    // first for a folder its keyboard is on).
    cx.on_action(|_: &crate::actions::ChatSettings, cx| {
        with_pane(cx, |p, w, cx| p.open_chat_settings(w, cx))
    });
    cx.on_action(|_: &crate::actions::ToolSettings, cx| {
        with_pane(cx, |p, w, cx| p.open_tool_settings(w, cx))
    });
    cx.on_action(|_: &crate::actions::Dictate, cx| {
        with_pane(cx, |p, w, cx| {
            p.composer.update(cx, |c, cx| c.toggle_dictation(w, cx))
        })
    });
    cx.on_action(|_: &crate::actions::ExpandEditor, cx| {
        with_pane(cx, |p, w, cx| {
            p.composer.update(cx, |c, cx| {
                let on = !c.expanded;
                c.set_expanded(on, w, cx)
            })
        })
    });
}

impl Render for ChatPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.sync_computer(cx);
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let r = t.roles;
        let (title, temporary, missing, read_only, hermes) = match &self.chat {
            Some(chat) => {
                let s = chat.store.read(cx);
                (
                    s.title()
                        .map(str::to_string)
                        .filter(|t| !t.is_empty())
                        .unwrap_or_else(|| l10n.desktop_new_conversation()),
                    s.temporary,
                    s.missing,
                    s.read_only(),
                    s.hermes().cloned(),
                )
            }
            None => (
                String::new(),
                self.composer.read(cx).temporary,
                false,
                false,
                None,
            ),
        };
        let hermes_read_only = hermes.as_ref().is_some_and(|h| h.read_only);
        // The phone's header: a capsule with the chat's title over the
        // model, which opens the model picker.
        let model_name = self.composer.read(cx).model_name(cx);
        let picker_open = self.composer.read(cx).picker_open();
        let pill_title = self
            .chat
            .as_ref()
            .map(|_| SharedString::from(title.clone()));
        let pill_label = l10n.desktop_model_chip(&model_name);
        let composer = self.composer.downgrade();
        let previous = self.title_crossfade(pill_title.as_ref(), window, cx);
        let pill = match hermes.as_ref().and_then(|h| h.bot.clone()) {
            // A Bot Chat runs as its bot, on the bot's own model: the
            // header names the bot, with its face (it bobs while it
            // answers), as the phone's does.
            Some(bot) => {
                let streaming = self
                    .chat
                    .as_ref()
                    .is_some_and(|c| c.store.read(cx).is_streaming());
                let rooms = self.stores.hermes_rooms.read(cx);
                let face = crate::views::hermes_faces::bot_face(&bot, rooms);
                if bot.has_avatar && face.image.is_none() {
                    crate::views::hermes_faces::request_avatars(
                        [bot.name.as_str()],
                        &self.stores.hermes_rooms,
                        cx,
                    );
                }
                TitlePill::new(bot.title.clone(), bot.title.clone()).face(
                    crate::views::hermes_faces::face(
                        "bot-title-face",
                        &face,
                        22.,
                        streaming,
                        cx.reduce_motion(),
                    ),
                )
            }
            None => TitlePill::new(model_name.clone(), pill_label)
                .title(pill_title)
                .previous(previous)
                .open(picker_open)
                .on_click(Rc::new(move |_, window, cx| {
                    let _ = composer.update(cx, |c, cx| c.toggle_picker(window, cx));
                })),
        };
        let sidebar_visible = self.layout.read(cx).state.sidebar_visible;
        let mut toolbar = ChatToolbar::new(title, SharedString::default())
            .temporary(temporary)
            .bare()
            .pill(pill);
        // Another user's chat, shared through a folder: read, never answered.
        // So is a Hermes session another Hermes app owns, until continued.
        if read_only || hermes_read_only {
            toolbar = toolbar.note(l10n.read_only());
        }
        // With the sidebar hidden the toolbar starts under the traffic
        // lights, so it makes room for them, and offers the sidebar back
        // (View › Show Sidebar and ⌃⌘S do too) and New Chat, which the
        // sidebar's header has otherwise: one New Chat button on screen.
        // While the sidebar slides, the room follows it; the button comes
        // in over the last stretch, once the sidebar's own toggle has gone
        // under the traffic lights (never two on screen at once).
        let keys = conduit_components::views::focus::hints(cx);
        let reveal = SidebarReveal::of(sidebar_visible, cx);
        let shown = ((0.3 - reveal) / 0.25).clamp(0., 1.);
        if reveal < 1. {
            let covered = t.metrics.sidebar_width * reveal;
            let inset = (conduit_components::window::TRAFFIC_LIGHTS_WIDTH + 8. - covered).max(10.);
            toolbar = toolbar.leading_reveal(inset, shown).leading(
                IconButton::new(
                    "show-sidebar",
                    IconName::PanelLeft,
                    l10n.desktop_menu_show_sidebar(),
                )
                .size(30., 16.)
                .round()
                .shortcut(keys.toggle_sidebar.clone())
                .on_click(Rc::new(|_, window, cx| {
                    window.dispatch_action(Box::new(ToggleSidebar), cx)
                })),
            );
        }
        // New Chat joins the toolbar the same way, once the sidebar's own
        // New Chat has slid away.
        if !sidebar_visible && shown > 0. {
            toolbar = toolbar.trailing(
                div().opacity(shown).child(
                    IconButton::new("toolbar-new-chat", IconName::SquarePen, l10n.new_chat())
                        .size(30., 16.)
                        .round()
                        .shortcut(keys.new_chat.clone())
                        .on_click(Rc::new(|_, window, cx| {
                            window.dispatch_action(Box::new(crate::actions::NewChat), cx)
                        })),
                ),
            );
        }
        // Live Updates, while the realtime socket is down (never in a
        // Hermes chat, which does not use it).
        let health = self.stores.app_settings.read(cx).health.clone();
        let live_down =
            hermes.is_none() && health.as_ref().is_some_and(|h| h.available && !h.connected);
        let live_shown = self.track_live(live_down, cx);
        if live_shown {
            let pane = cx.entity().downgrade();
            toolbar = toolbar.trailing(
                IconButton::new(
                    "live-connection",
                    IconName::CloudOff,
                    l10n.live_connection_details(),
                )
                .size(30., 16.)
                .round()
                .color(r.danger)
                .tooltip(l10n.live_connection_details_title())
                .active(self.live_anchor.is_some())
                .on_click(Rc::new(move |e, _, cx| {
                    let at = e.position();
                    let _ = pane.update(cx, |p, cx| p.toggle_live(at, cx));
                })),
            );
        }
        let live_popover = self.live_popover(live_shown, health.as_ref(), cx);
        let saveable = self.can_save_temporary(cx);
        match &self.chat {
            // A temporary chat (as opened, or as the server says it is):
            // Save Chat in place of More, as on the phone.
            Some(chat)
                if {
                    let s = chat.store.read(cx);
                    s.temporary || s.detail.as_ref().is_some_and(|d| d.temporary)
                } =>
            {
                let pane = cx.entity().downgrade();
                toolbar = toolbar.trailing(
                    IconButton::new("save-chat", IconName::Save, l10n.save_chat())
                        .size(30., 16.)
                        .round()
                        .disabled(!saveable)
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = pane.update(cx, |p, cx| p.save_temporary(window, cx));
                        })),
                );
            }
            // The chat's commands, as the sidebar's context menu has them;
            // Computer before them when the chat's terminal has one.
            Some(chat) if !read_only => {
                let chat_id = chat.store.read(cx).chat_id().to_string();
                if self
                    .computer
                    .as_ref()
                    .is_some_and(|c| c.available() && c.chat_id == chat_id)
                {
                    let offer = self.computer.clone();
                    let stores = self.stores.clone();
                    toolbar = toolbar.trailing(
                        IconButton::new("chat-computer", IconName::Monitor, l10n.computer_title())
                            .size(30., 16.)
                            .round()
                            .on_click(Rc::new(move |_, _, cx| {
                                if let Some(offer) = &offer {
                                    crate::views::terminal::computer::open(
                                        stores.clone(),
                                        offer.chat_id.clone(),
                                        offer.status.clone(),
                                        cx,
                                    );
                                }
                            })),
                    );
                }
                toolbar = toolbar.trailing(
                    IconButton::new("chat-more", IconName::Ellipsis, l10n.more())
                        .size(30., 16.)
                        .round()
                        .on_click(Rc::new(move |e, window, cx| {
                            let position = e.position();
                            let id = chat_id.clone();
                            show_chat_menu(id, position, window, cx);
                        })),
                );
            }
            Some(_) => {}
            // A new chat: the phone's temporary-chat switch in place of
            // More. The phone's dashed circle reads as nothing at 16 pt on
            // a Mac; a clock with a dashed rim (Lucide clock-fading) keeps
            // the dashes and says "for a while".
            None => {
                let composer = self.composer.downgrade();
                toolbar = toolbar.trailing(
                    IconButton::new(
                        "temporary-chat",
                        IconName::ClockFading,
                        l10n.temporary_chat(),
                    )
                    .size(30., 16.)
                    .round()
                    .shortcut(keys.temporary_chat.clone())
                    .active(temporary)
                    .on_click(Rc::new(move |_, _, cx| {
                        let _ = composer.update(cx, |c, cx| {
                            c.temporary = !c.temporary;
                            cx.emit(ChatComposerEvent::Temporary(c.temporary));
                            cx.notify();
                        });
                    })),
                );
            }
        }
        // The picker hangs under the title capsule.
        let picker = self
            .composer
            .update(cx, |c, cx| c.picker_view(&t, window, cx))
            .map(|p| {
                div()
                    .absolute()
                    .top(px(conduit_components::window::TOOLBAR_HEIGHT - 2.))
                    .left_0()
                    .right_0()
                    .flex()
                    .justify_center()
                    .child(p)
                    .into_any_element()
            });
        let docked = self.docked(window, cx);
        let toasts = crate::views::toasts::toast_dock(&self.stores.toasts, window, cx)
            .map(IntoElement::into_any_element);
        // The voice call in this chat, open: its strip where the composer is.
        let mut call_strip = (self.call_here(cx) && !self.stores.call.read(cx).collapsed)
            .then(|| crate::views::chat::call::strip(&self.stores.call, cx));
        let body: AnyElement = match &self.chat {
            // The phone's new chat: the greeting in the middle of the page,
            // the composer at the bottom where every chat has it.
            None => div()
                .flex_1()
                .min_h_0()
                .flex()
                .flex_col()
                .child(
                    div()
                        .flex_1()
                        .min_h_0()
                        .flex()
                        .flex_col()
                        .items_center()
                        .justify_center()
                        .gap(px(10.))
                        .px(px(32.))
                        .child(conduit_components::views::kit::heading(
                            "greeting",
                            self.greeting(cx),
                            1,
                            28.,
                            gpui_kit::FontWeight::BOLD,
                            r.text,
                        ))
                        .when(temporary, |d| {
                            d.child(
                                div()
                                    .max_w(px(420.))
                                    .text_center()
                                    .text_size(px(t.metrics.control))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(l10n.desktop_temporary_hint())),
                            )
                        }),
                )
                .child(
                    div().track_focus(&self.dock_focus).child(composer_dock(
                        toasts,
                        docked,
                        call_strip
                            .take()
                            .unwrap_or_else(|| self.composer.clone().into_any_element()),
                    )),
                )
                .into_any_element(),
            Some(chat) => div()
                .flex_1()
                .min_h_0()
                .flex()
                .flex_col()
                .relative()
                .child(if missing {
                    div()
                        .flex_1()
                        .flex()
                        .items_center()
                        .justify_center()
                        .text_size(px(t.metrics.body))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(l10n.desktop_chat_missing()))
                        .into_any_element()
                } else {
                    self.handed_over(chat.transcript.clone().into_any_element(), &t, window, cx)
                })
                .child(div().track_focus(&self.dock_focus).child(composer_dock(
                    toasts,
                    docked,
                    if let Some(hermes) = hermes.as_ref().filter(|h| h.read_only) {
                        self.hermes_read_only_notice(hermes, &t, cx)
                    } else if read_only {
                        div()
                            .id("read-only-notice")
                            .role(Role::Status)
                            .aria_label(SharedString::from(l10n.read_only_shared_chat()))
                            .w_full()
                            .py(px(10.))
                            .flex()
                            .justify_center()
                            .text_size(px(t.metrics.small))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(l10n.read_only_shared_chat()))
                            .into_any_element()
                    } else {
                        call_strip
                            .take()
                            .unwrap_or_else(|| self.composer.clone().into_any_element())
                    },
                )))
                .into_any_element(),
        };
        let find_bar = match &self.chat {
            Some(chat) if self.find_open => {
                Some(self.find_bar(&chat.transcript.clone(), window, cx))
            }
            _ => None,
        };
        div()
            .key_context(CHAT_PANE_CONTEXT)
            .on_action(
                cx.listener(|this, _: &crate::actions::FocusNextControl, window, cx| {
                    this.tab(false, window, cx)
                }),
            )
            .on_action(cx.listener(
                |this, _: &crate::actions::FocusPreviousControl, window, cx| {
                    this.tab(true, window, cx)
                },
            ))
            .relative()
            .size_full()
            .flex()
            .flex_col()
            .child(toolbar)
            .children(find_bar)
            .child(body)
            .children(picker)
            .children(live_popover)
    }
}

impl ChatPane {
    /// Keeps time while the socket is down: whether Live Updates shows yet
    /// (after [`live_connection::SHOW_AFTER`]); its popover closes once the
    /// socket is back.
    fn track_live(&mut self, down: bool, cx: &mut Context<Self>) -> bool {
        use crate::views::chat::live_connection::SHOW_AFTER;
        if !down {
            self.live_down_since = None;
            self._live_wait = None;
            self.live_anchor = None;
            return false;
        }
        let since = *self
            .live_down_since
            .get_or_insert_with(std::time::Instant::now);
        let elapsed = since.elapsed();
        if elapsed >= SHOW_AFTER {
            return true;
        }
        if self._live_wait.is_none() {
            let wait = SHOW_AFTER - elapsed;
            self._live_wait = Some(cx.spawn(async move |this, cx| {
                cx.background_executor()
                    .timer(wait + std::time::Duration::from_millis(20))
                    .await;
                let _ = this.update(cx, |p, cx| {
                    p._live_wait = None;
                    cx.notify();
                });
            }));
        }
        false
    }

    /// Opens or closes the Live Updates popover, hanging from `at`.
    fn toggle_live(&mut self, at: gpui_kit::Point<gpui_kit::Pixels>, cx: &mut Context<Self>) {
        self.live_anchor = match self.live_anchor {
            Some(_) => None,
            None => Some(at),
        };
        cx.notify();
    }

    /// The Live Updates popover, under its toolbar item, while open.
    fn live_popover(
        &self,
        shown: bool,
        health: Option<&conduit_protocol::ConnectionHealth>,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        use crate::views::chat::live_connection::{self as live, handler};
        let at = self.live_anchor.filter(|_| shown)?;
        let health = health?;
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        let store = self.stores.app_settings.read(cx);
        let (reconnecting, failed) = (store.reconnecting, store.reconnect_failed);
        let settings = self.stores.app_settings.clone();
        let pane = cx.entity().downgrade();
        let close = pane.clone();
        let card = live::card(
            health,
            reconnecting,
            failed,
            handler(move |_, cx| settings.update(cx, |s, cx| s.reconnect(cx))),
            handler(move |_, cx| {
                let _ = pane.update(cx, |p, cx| {
                    p.live_anchor = None;
                    cx.notify();
                });
                crate::open_settings(Some(crate::views::settings::Tab::Connection), cx);
            }),
            &l10n,
            &t,
        )
        .on_mouse_down_out(move |_, _, cx| {
            let _ = close.update(cx, |p, cx| {
                p.live_anchor = None;
                cx.notify();
            });
        });
        // Hangs from its item by a tail, as the transcript's popovers do:
        // the card's right edge a little past the item, the tail's tip
        // under the item's middle.
        use crate::views::chat::transcript::{TAIL_HEIGHT, popover_tail};
        const PAST: f32 = 18.;
        let r = t.roles;
        let hung = div()
            .relative()
            .pt(px(TAIL_HEIGHT))
            .child(card)
            .child(popover_tail(
                px(live::CARD_WIDTH - PAST),
                true,
                r.overlay,
                r.border_strong,
            ));
        Some(
            gpui_kit::deferred(
                gpui_kit::anchored()
                    .anchor(gpui_kit::Anchor::TopRight)
                    .position(gpui_kit::point(
                        at.x + px(PAST),
                        px(conduit_components::window::TOOLBAR_HEIGHT - 6.),
                    ))
                    .snap_to_window_with_margin(px(8.))
                    .child(hung),
            )
            .with_priority(3)
            .into_any_element(),
        )
    }
}

impl ChatPane {
    /// The open chat's new title (named after its first answer) crossfades
    /// in over the old one (150 ms), rather than cutting; another chat, or
    /// a first title, shows at once. Returns the old title and how far the
    /// crossfade is.
    fn title_crossfade(
        &mut self,
        title: Option<&SharedString>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<(SharedString, f32)> {
        let chat = self
            .chat
            .as_ref()
            .map(|c| c.store.read(cx).chat_id().to_string());
        let now = cx.background_executor().now();
        let shown = chat.zip(title.map(|t| t.to_string()));
        if shown != self.title_shown {
            self.title_change = retitled(&self.title_shown, &shown).map(|was| (was, now));
            self.title_shown = shown;
        }
        let (old, start) = self.title_change.clone()?;
        let spec = conduit_components::motion::specs::REGEN_CROSSFADE;
        let p = now.saturating_duration_since(start).as_secs_f32() / spec.duration.as_secs_f32();
        if p >= 1. {
            self.title_change = None;
            return None;
        }
        window.request_animation_frame();
        Some((SharedString::from(old), spec.curve.sample(p)))
    }
}

/// The title a toolbar showing `now` (chat id, title) crossfades from, after
/// showing `was`: the same chat renamed. Another chat, or a first title,
/// shows at once.
fn retitled(was: &Option<(String, String)>, now: &Option<(String, String)>) -> Option<String> {
    match (was, now) {
        (Some((was_chat, was)), Some((chat, title))) if was_chat == chat && was != title => {
            Some(was.clone())
        }
        _ => None,
    }
}

#[cfg(test)]
mod title_tests {
    use super::retitled;

    fn shown(chat: &str, title: &str) -> Option<(String, String)> {
        Some((chat.into(), title.into()))
    }

    #[test]
    fn a_chat_named_after_its_first_answer_crossfades_its_title() {
        assert_eq!(
            retitled(
                &shown("c1", "Some math, please"),
                &shown("c1", "Orbital speed")
            ),
            Some("Some math, please".into())
        );
        // Another chat, or none before: at once.
        assert_eq!(retitled(&shown("c1", "A"), &shown("c2", "B")), None);
        assert_eq!(retitled(&None, &shown("c1", "A")), None);
        assert_eq!(retitled(&shown("c1", "A"), &None), None);
    }
}

/// The chat pane's key context: Tab and Shift-Tab follow the messages
/// ([`crate::actions::FocusNextControl`]).
pub const CHAT_PANE_CONTEXT: &str = "ConduitChatPane";

impl ChatPane {
    /// Tab and Shift-Tab: in the transcript's rows (and from the composer
    /// back into them) the order of the messages, scrolling rows off screen
    /// in ([`Transcript::tab`]); anywhere else the window's own order.
    fn tab(&mut self, back: bool, window: &mut Window, cx: &mut Context<Self>) {
        let below = self.dock_focus.clone();
        let handled = self.chat.as_ref().is_some_and(|chat| {
            chat.transcript
                .update(cx, |t, cx| t.tab(back, below, window, cx))
        });
        if !handled {
            // Not ours: the window's Tab (and any focus trap) has it.
            cx.propagate();
        }
    }
}

/// The composer's place at the bottom of the chat column, with toasts and
/// a card (an approval) docked above it.
fn composer_dock(
    toasts: Option<AnyElement>,
    docked: Option<AnyElement>,
    composer: AnyElement,
) -> impl IntoElement {
    div()
        .relative()
        .flex_none()
        .flex()
        .flex_col()
        .items_center()
        .px(px(32.))
        .pb(px(16.))
        .child(
            div()
                .w_full()
                .max_w(px(conduit_components::views::shell::CHAT_COLUMN + 40.))
                .flex()
                .flex_col()
                // The card brings its own gap (it opens and closes with it),
                // as each toast does.
                .children(toasts)
                .children(docked)
                .child(composer),
        )
}

/// What the window says when the daemon refused `action`, in the phone's
/// words for a branch, a fork or a merge (`reason` is the core's failure:
/// `ChatBranchFailure` or `ComparisonMergeFailure`).
pub fn failure_text(action: ChatAction, reason: Option<&str>, l10n: &crate::l10n::L10n) -> String {
    match (action, reason) {
        (ChatAction::Load, _) => l10n.desktop_chat_load_failed(),
        (ChatAction::Send, Some("libreChatTemporaryChat")) => l10n.libre_chat_temporary_chat_off(),
        (ChatAction::Rate, _) => l10n.desktop_rating_not_saved(),
        (ChatAction::Branch | ChatAction::Fork, Some("responseRunning" | "forkConflict")) => {
            l10n.chat_branch_wait_for_response()
        }
        (ChatAction::Branch | ChatAction::Fork, Some("unavailable")) => {
            l10n.chat_branch_unavailable()
        }
        (ChatAction::Branch | ChatAction::Fork, Some("ownerChanged")) => {
            l10n.chat_branch_owner_changed()
        }
        (ChatAction::Branch | ChatAction::Fork, Some("messageNotFound" | "notAnAlternative")) => {
            l10n.chat_branch_message_missing()
        }
        (ChatAction::Fork, Some("offline")) => l10n.chat_fork_offline(),
        (ChatAction::Fork, Some("forkForbidden")) => l10n.chat_fork_forbidden(),
        (ChatAction::Fork, Some("forkSourceMissing")) => l10n.chat_fork_source_missing(),
        (ChatAction::Fork, Some("forkUnsupported")) => l10n.chat_fork_unsupported(),
        (ChatAction::Fork, _) => l10n.chat_fork_failed(),
        (ChatAction::Merge, Some("unavailable")) => l10n.chat_merge_error_unavailable(),
        (ChatAction::Merge, Some("notMergeable" | "busy")) => l10n.chat_merge_error_not_mergeable(),
        (ChatAction::Merge, Some("ownerChanged")) => l10n.chat_merge_error_owner_changed(),
        (ChatAction::Merge, _) => l10n.chat_merge_error_failed(),
        _ => l10n.desktop_action_failed(),
    }
}

/// The sidebar's native menu for `chat_id`, from the toolbar's More button.
fn show_chat_menu(
    chat_id: String,
    position: gpui_kit::Point<gpui_kit::Pixels>,
    window: &mut Window,
    cx: &mut App,
) {
    let Some(view) = cx
        .try_global::<AppState>()
        .and_then(|s| s.main_view.clone())
    else {
        return;
    };
    let sidebar = view.read(cx).sidebar.clone();
    let leading = view.read(cx).chat_pane.read(cx).more_menu_items(cx);
    // A Hermes session's chat: its session's commands.
    if let Some(session) = crate::stores::navigation::hermes_session_of(&chat_id) {
        let session = session.to_string();
        sidebar.update(cx, |s, cx| {
            s.hermes_context_menu(&session, leading, position, window, cx)
        });
        return;
    }
    sidebar.update(cx, |s, cx| {
        s.context_menu_with(&chat_id, leading, position, window, cx)
    });
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::Handoff;

    #[test]
    fn a_first_send_hands_over_in_about_two_hundred_ms() {
        let at = |ms: u64, reduce| Handoff::at(Duration::from_millis(ms), reduce);
        // At the press: the greeting fully there, the message not yet, 10 pt
        // below its place.
        let (greeting, shown, rise) = at(0, false);
        assert_eq!((greeting, shown), (1., 0.));
        assert!((8. ..=12.).contains(&rise), "{rise}");
        // The greeting is gone by 120 ms, while the message is still rising.
        let (greeting, shown, rise) = at(120, false);
        assert!(greeting < 0.01, "{greeting}");
        assert!(shown > 0.5 && shown < 1. && rise > 0., "{shown} {rise}");
        // All in place by 200 ms, and over then.
        let (_, shown, rise) = at(200, false);
        assert!(shown > 0.999 && rise < 0.01, "{shown} {rise}");
        assert!(!Handoff::done(Duration::from_millis(190)));
        assert!(Handoff::done(Duration::from_millis(200)));
        // Every frame in between moves on (no hold), the rise never back.
        let frames: Vec<_> = (0..=12).map(|k| at(k * 16, false)).collect();
        assert!(
            frames
                .windows(2)
                .all(|w| w[1].1 > w[0].1 && w[1].2 <= w[0].2)
        );
        // Reduce Motion: the fades, no travel.
        assert!((0..=12).all(|k| at(k * 16, true).2 == 0.));
        assert_eq!(at(60, true).1, at(60, false).1);
    }

    mod pane {
        use conduit_protocol::methods;
        use gpui_kit::{AppContext as _, Entity, TestAppContext, VisualTestContext};

        use crate::stores::Stores;
        use crate::stores::accounts::tests::{account, list};
        use crate::stores::composer::Attachment;
        use crate::stores::layout::LayoutStore;
        use crate::stores::rpc::fake::FakeDaemon;
        use crate::views::approvals::ApprovalsView;
        use crate::views::chat_pane::ChatPane;

        fn bench(
            cx: &mut TestAppContext,
        ) -> (FakeDaemon, Stores, Entity<ChatPane>, &mut VisualTestContext) {
            let daemon = FakeDaemon::new();
            let scratch = std::env::temp_dir().join(format!("conduit-pane-{}", std::process::id()));
            let stores = cx.update(|cx| {
                crate::views::test_globals(cx);
                Stores::for_test(daemon.rpc(), &scratch, cx)
            });
            stores.accounts.update(cx, |a, cx| {
                a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
            });
            let layout = cx.new(|_| LayoutStore::load(scratch.join("window-state.json")));
            let s = stores.clone();
            let (pane, vcx) = cx.add_window_view(move |window, cx| {
                let approvals = cx.new(|cx| ApprovalsView::new(s.clone(), window, cx));
                ChatPane::new(s, layout, approvals, window, cx)
            });
            (daemon, stores, pane, vcx)
        }

        fn uploaded(name: &str) -> Attachment {
            Attachment::uploaded_for_test(1, name, &format!("file-{name}"))
        }

        fn attachment_names(pane: &Entity<ChatPane>, vcx: &mut VisualTestContext) -> Vec<String> {
            pane.read_with(vcx, |p, cx| {
                p.composer_store
                    .read(cx)
                    .attachments
                    .iter()
                    .map(|a| a.name.clone())
                    .collect()
            })
        }

        /// A chat saved with a coding agent, opened while another model is
        /// selected, shows "This chat used …" with Switch above the message
        /// box, and Switch picks that agent for the chat.
        #[gpui_kit::test]
        fn a_chat_saved_with_an_agent_shows_switch(cx: &mut TestAppContext) {
            let (daemon, stores, _pane, vcx) = bench(cx);
            let agent = "agent:north:codex:gpt-test";
            daemon.on::<methods::ModelsList>(move |_| {
                Ok(serde_json::json!({
                    "models": [{"id": "k", "name": "Kestrel", "pinned": false, "capabilities": []}],
                    "selectedId": "k",
                    "agentNames": {agent: "Codex · gpt-test"},
                    "chatAgent": agent
                }))
            });
            daemon.on::<methods::ModelsSelect>(move |_| {
                Ok(serde_json::json!({
                    "models": [{"id": "k", "name": "Kestrel", "pinned": false, "capabilities": []}],
                    "selectedId": agent
                }))
            });
            stores.navigation.update(vcx, |n, cx| n.open("c-agent", cx));
            vcx.run_until_parked();
            vcx.update(|window, cx| window.draw(cx).clear(cx));
            let switch = vcx
                .debug_bounds("chat-agent-switch")
                .expect("Switch is offered for the chat's agent");
            assert!(daemon.calls::<methods::ModelsSelect>().is_empty());
            vcx.simulate_click(switch.center(), gpui_kit::Modifiers::none());
            vcx.run_until_parked();
            let picks = daemon.calls::<methods::ModelsSelect>();
            assert_eq!(picks.len(), 1);
            assert_eq!(picks[0]["id"], agent);
            assert_eq!(picks[0]["chatId"], "c-agent");
            vcx.update(|window, cx| window.draw(cx).clear(cx));
            assert!(vcx.debug_bounds("chat-agent-switch").is_none());
        }

        /// A link handled right after a new chat's in the same batch
        /// (`conduit://clipboard`, then `conduit://chat/<id>`) keeps its own
        /// draft: what the new chat brought is written only while that new
        /// chat is still the one selected.
        #[gpui_kit::test]
        fn a_new_chats_words_never_land_in_a_chat_opened_after_it(cx: &mut TestAppContext) {
            use crate::views::chat_pane::NewChatContent;
            let (_daemon, stores, pane, vcx) = bench(cx);
            let content = || NewChatContent {
                text: Some("Copied packing list".into()),
                fresh: true,
                ..NewChatContent::default()
            };
            stores.navigation.update(vcx, |n, cx| n.new_chat(false, cx));
            let ticket = stores
                .navigation
                .read_with(vcx, |n, _| n.selection().clone());
            stores.navigation.update(vcx, |n, cx| n.open("c2", cx));
            vcx.run_until_parked();
            let wrote = pane.update_in(vcx, |p, window, cx| {
                p.compose_new_chat(&ticket, content(), window, cx)
            });
            vcx.run_until_parked();
            assert!(!wrote, "written into the chat opened after it");
            assert_eq!(
                pane.read_with(vcx, |p, cx| p.composer.read(cx).text(cx)),
                ""
            );

            // Still on the new chat it opened: written.
            stores.navigation.update(vcx, |n, cx| n.new_chat(false, cx));
            vcx.run_until_parked();
            let ticket = stores
                .navigation
                .read_with(vcx, |n, _| n.selection().clone());
            let wrote = pane.update_in(vcx, |p, window, cx| {
                p.compose_new_chat(&ticket, content(), window, cx)
            });
            vcx.run_until_parked();
            assert!(wrote);
            assert_eq!(
                pane.read_with(vcx, |p, cx| p.composer.read(cx).text(cx)),
                "Copied packing list"
            );
        }

        /// Send Link's page, read under one account, is never written into
        /// a new chat once another account is in charge.
        #[gpui_kit::test]
        fn a_page_read_under_one_account_never_reaches_anothers_new_chat(cx: &mut TestAppContext) {
            use crate::views::chat_pane::NewChatContent;
            let (_daemon, stores, pane, vcx) = bench(cx);
            stores.navigation.update(vcx, |n, cx| n.new_chat(false, cx));
            vcx.run_until_parked();
            let ticket = stores
                .navigation
                .read_with(vcx, |n, _| n.selection().clone());
            let page = |owner: &str| NewChatContent {
                text: Some("Summarize this page".into()),
                fresh: true,
                owner: Some(crate::shell::deep_link::ReadUnder(Some(owner.into()))),
                ..NewChatContent::default()
            };
            let wrote = pane.update_in(vcx, |p, window, cx| {
                p.compose_new_chat(&ticket, page("b"), window, cx)
            });
            assert!(!wrote, "account b's page written while a is in charge");
            assert_eq!(
                pane.read_with(vcx, |p, cx| p.composer.read(cx).text(cx)),
                ""
            );
            let wrote = pane.update_in(vcx, |p, window, cx| {
                p.compose_new_chat(&ticket, page("a"), window, cx)
            });
            assert!(wrote);
            assert_eq!(
                pane.read_with(vcx, |p, cx| p.composer.read(cx).text(cx)),
                "Summarize this page"
            );
        }

        /// "No account" is a scope too (Direct only, Hermes only): a page
        /// read with no account opens there, and never lands once an
        /// account has signed in.
        #[gpui_kit::test]
        fn a_page_read_with_no_account_lands_only_while_there_is_none(cx: &mut TestAppContext) {
            use crate::shell::deep_link::ReadUnder;
            use crate::views::chat_pane::NewChatContent;
            let (_daemon, stores, pane, vcx) = bench(cx);
            let page = || NewChatContent {
                text: Some("Summarize this page".into()),
                fresh: true,
                owner: Some(ReadUnder(None)),
                ..NewChatContent::default()
            };
            let ticket = |vcx: &mut VisualTestContext| {
                stores.navigation.update(vcx, |n, cx| n.new_chat(false, cx));
                vcx.run_until_parked();
                stores
                    .navigation
                    .read_with(vcx, |n, _| n.selection().clone())
            };
            // An account is in charge: a page read with none is refused.
            let t = ticket(vcx);
            let wrote = pane.update_in(vcx, |p, window, cx| {
                p.compose_new_chat(&t, page(), window, cx)
            });
            assert!(
                !wrote,
                "a page read with no account landed under an account"
            );
            // No account now: it opens.
            stores
                .accounts
                .update(vcx, |a, cx| a.adopt(list(vec![]), cx));
            vcx.run_until_parked();
            assert_eq!(stores.accounts.read_with(vcx, |a, _| a.scope_key()), None);
            let t = ticket(vcx);
            let wrote = pane.update_in(vcx, |p, window, cx| {
                p.compose_new_chat(&t, page(), window, cx)
            });
            assert!(wrote, "a page read with no account was refused with none");
            assert_eq!(
                pane.read_with(vcx, |p, cx| p.composer.read(cx).text(cx)),
                "Summarize this page"
            );
        }

        /// A Continuity Camera photo carries the ticket its + menu took:
        /// it is attached only while that composer, that composition and
        /// that account scope are still the ones shown. A later menu (another
        /// account's) never stands in for it, and replacing the composition
        /// (Send Text) drops it; otherwise it attaches.
        #[gpui_kit::test]
        fn a_continuity_photo_lands_only_in_the_composition_that_asked(cx: &mut TestAppContext) {
            let (_daemon, stores, pane, vcx) = bench(cx);
            let dir = std::env::temp_dir().join(format!("conduit-import-{}", std::process::id()));
            let _ = std::fs::create_dir_all(&dir);
            let photo = dir.join("Photo.jpeg");
            let _ = std::fs::write(&photo, [0xFF, 0xD8, 0xFF, 0xD9]);
            let attach = |ticket, vcx: &mut VisualTestContext| {
                pane.update_in(vcx, |p, window, cx| {
                    p.attach_import(&ticket, &photo, "Photo.jpeg", window, cx)
                })
            };
            let toasts = |vcx: &mut VisualTestContext| -> usize {
                stores.toasts.read_with(vcx, |t, _| t.toasts.len())
            };
            stores.navigation.update(vcx, |n, cx| n.new_chat(false, cx));
            vcx.run_until_parked();

            // (1) Asked in account a's chat; account b's + menu opens before
            // the photo lands: it is judged by its own ticket, not b's.
            let asked_in_a = pane.read_with(vcx, |p, cx| p.import_target(cx));
            stores.accounts.update(vcx, |a, cx| {
                a.adopt(
                    list(vec![
                        account("a", "Avery", false, true),
                        account("b", "Blake", true, true),
                    ]),
                    cx,
                )
            });
            vcx.run_until_parked();
            let _menu_in_b = pane.read_with(vcx, |p, cx| p.import_target(cx));
            assert!(
                !attach(asked_in_a, vcx),
                "account a's photo landed in b's composer"
            );
            assert!(attachment_names(&pane, vcx).is_empty());
            assert_eq!(toasts(vcx), 1);
            stores.toasts.update(vcx, |t, _| t.toasts.clear());

            // (2) Asked, then Send Text replaces the composition (same draft
            // slot): dropped.
            let asked = pane.read_with(vcx, |p, cx| p.import_target(cx));
            pane.update_in(vcx, |p, window, cx| {
                p.composer.update(cx, |c, cx| {
                    c.start_fresh("Shared from Shortcuts", window, cx)
                })
            });
            assert!(!attach(asked, vcx), "a replaced composition took the photo");
            assert!(attachment_names(&pane, vcx).is_empty());
            assert_eq!(toasts(vcx), 1);

            // Asked in this composition: attached.
            let asked = pane.read_with(vcx, |p, cx| p.import_target(cx));
            assert!(attach(asked, vcx));
            vcx.run_until_parked();
            assert_eq!(attachment_names(&pane, vcx), vec!["Photo.jpeg".to_string()]);
        }

        /// The widget's and Shortcuts' calls start in the new chat as it
        /// shows: temporary when Temporary by Default makes it so, in its
        /// folder, as the composer's call button would start them.
        #[gpui_kit::test]
        fn a_call_from_outside_keeps_the_new_chats_temporary_and_folder(cx: &mut TestAppContext) {
            let (daemon, stores, pane, vcx) = bench(cx);
            // Each start is answered as refused at once (idle), so the next
            // one is not taken for a call already on.
            let starting = || -> conduit_protocol::CallState {
                serde_json::from_value(serde_json::json!({"phase": "idle", "call": 0})).unwrap()
            };
            pane.update(vcx, |p, cx| {
                p.composer_store
                    .update(cx, |c, _| c.prefs.temporary_by_default = true)
            });
            // A chat was open: the link's New Chat replaces it.
            stores.navigation.update(vcx, |n, cx| n.open("c0", cx));
            vcx.run_until_parked();
            stores.navigation.update(vcx, |n, cx| n.new_chat(false, cx));
            vcx.run_until_parked();
            assert!(pane.read_with(vcx, |p, cx| p.composer.read(cx).temporary));
            daemon.returns::<methods::CallsStart>(starting());
            pane.update(vcx, |p, cx| p.call_in_new_chat(cx));
            vcx.run_until_parked();
            let started = daemon.calls::<methods::CallsStart>();
            assert_eq!(started.len(), 1);
            assert_eq!(
                started[0]["temporary"], true,
                "the call saved a chat the composer showed as temporary"
            );

            // A folder's new chat, not temporary: the call starts in it.
            pane.update(vcx, |p, cx| {
                p.composer_store
                    .update(cx, |c, _| c.prefs.temporary_by_default = false)
            });
            stores
                .navigation
                .update(vcx, |n, cx| n.new_chat_in_folder("f1".into(), cx));
            vcx.run_until_parked();
            daemon.returns::<methods::CallsStart>(starting());
            pane.update(vcx, |p, cx| p.call_in_new_chat(cx));
            vcx.run_until_parked();
            let started = daemon.calls::<methods::CallsStart>();
            assert_eq!(started.len(), 2);
            assert_eq!(started[1]["temporary"], false);
            assert_eq!(started[1]["folderId"], "f1", "the call left its folder");

            // Another chat opened before the call could start (a later link
            // in the same batch): no call starts, and none in that chat.
            stores.navigation.update(vcx, |n, cx| n.open("c9", cx));
            vcx.run_until_parked();
            pane.update(vcx, |p, cx| p.call_in_new_chat(cx));
            vcx.run_until_parked();
            assert_eq!(
                daemon.calls::<methods::CallsStart>().len(),
                2,
                "a call meant for a new chat started in another one"
            );
        }

        /// Offline, Chat › Start Voice Call and ⌥⌘V start no call, as the
        /// composer's call button (disabled offline) starts none.
        #[gpui_kit::test]
        fn no_call_starts_while_offline(cx: &mut TestAppContext) {
            let (daemon, _stores, pane, vcx) = bench(cx);
            pane.update(vcx, |p, cx| {
                p.composer.update(cx, |c, _| {
                    c.call_ready = true;
                    c.offline = true;
                })
            });
            pane.update(vcx, |p, cx| p.toggle_call(cx));
            vcx.run_until_parked();
            assert!(
                daemon.calls::<methods::CallsStart>().is_empty(),
                "a call started while offline"
            );
        }

        /// Chat › Read Aloud reads only a chat the window shows: with Notes
        /// shown over it, the chat kept loaded behind is not read.
        #[gpui_kit::test]
        fn read_aloud_needs_the_chat_on_screen(cx: &mut TestAppContext) {
            let (_daemon, stores, pane, vcx) = bench(cx);
            stores.navigation.update(vcx, |n, cx| n.open("c1", cx));
            vcx.run_until_parked();
            assert!(
                pane.read_with(vcx, |p, cx| p.can_read_aloud(cx)),
                "the shown chat is not read"
            );
            stores.navigation.update(vcx, |n, cx| {
                n.open_item(crate::stores::navigation::AreaItem::Note("n1".into()), cx)
            });
            vcx.run_until_parked();
            assert!(
                !pane.read_with(vcx, |p, cx| p.can_read_aloud(cx)),
                "a chat behind Notes is read aloud"
            );
        }

        /// New Chat forgets that the last chat offered Context & Usage, so
        /// the next Hermes chat puts it back in the Chat menu.
        #[gpui_kit::test]
        fn new_chat_forgets_the_last_chats_context_item(cx: &mut TestAppContext) {
            let (_daemon, stores, pane, vcx) = bench(cx);
            pane.update(vcx, |p, _| p.context_offered.set(true));
            stores.navigation.update(vcx, |n, cx| n.new_chat(true, cx));
            vcx.run_until_parked();
            assert!(
                !pane.read_with(vcx, |p, _| p.context_offered.get()),
                "a new chat still counts the last chat's Context & Usage as offered"
            );
        }

        /// Save as Note names the account the words were written under, so
        /// conduitd makes the note under no other (an account switch it hears
        /// of first refuses it).
        #[gpui_kit::test]
        fn save_as_note_names_the_account_it_was_written_under(cx: &mut TestAppContext) {
            let (daemon, _stores, pane, vcx) = bench(cx);
            pane.update_in(vcx, |p, window, cx| {
                p.save_as_note("Glaze ratios for the next firing".into(), window, cx)
            });
            vcx.run_until_parked();
            let saves = daemon.calls::<methods::NotesSave>();
            assert_eq!(saves.len(), 1);
            assert_eq!(
                saves[0]["accountId"], "a",
                "the note was asked for under no account"
            );
        }

        #[gpui_kit::test]
        fn another_account_starts_with_an_empty_composer(cx: &mut TestAppContext) {
            let (_daemon, stores, pane, vcx) = bench(cx);
            pane.update(vcx, |p, cx| {
                p.composer_store
                    .update(cx, |c, _| c.attachments.push(uploaded("a.txt")))
            });
            stores.accounts.update(vcx, |a, cx| {
                a.adopt(
                    list(vec![
                        account("a", "Avery", false, true),
                        account("b", "Blake", true, true),
                    ]),
                    cx,
                )
            });
            vcx.run_until_parked();
            assert!(attachment_names(&pane, vcx).is_empty());
        }

        #[gpui_kit::test]
        fn another_account_never_gets_the_last_ones_prompt_form(cx: &mut TestAppContext) {
            let (daemon, stores, pane, vcx) = bench(cx);
            daemon.returns::<methods::PromptsList>(
                serde_json::from_value(serde_json::json!({
                    "prompts": [{"command": "/greet", "title": "Greet"}]
                }))
                .unwrap(),
            );
            daemon.returns::<methods::PromptsRender>(
                serde_json::from_value(serde_json::json!({
                    "content": "Hello {{name}}",
                    "inputs": [{"name": "name", "label": "Name", "type": "text", "required": false}]
                }))
                .unwrap(),
            );
            pane.update_in(vcx, |p, window, cx| {
                p.composer.update(cx, |c, cx| c.focus_input(window, cx))
            });
            vcx.simulate_input("/gr");
            vcx.run_until_parked();
            pane.update_in(vcx, |p, window, cx| {
                p.composer
                    .update(cx, |c, cx| c.choose_menu_item(0, window, cx))
            });
            vcx.run_until_parked();
            assert!(pane.read_with(vcx, |p, cx| p.composer.read(cx).has_popup()));
            let renders = daemon.calls::<methods::PromptsRender>().len();
            stores.accounts.update(vcx, |a, cx| {
                a.adopt(
                    list(vec![
                        account("a", "Avery", false, true),
                        account("b", "Blake", true, true),
                    ]),
                    cx,
                )
            });
            vcx.run_until_parked();
            pane.update_in(vcx, |p, window, cx| {
                assert!(!p.composer.read(cx).has_popup(), "the form stayed open");
                // Insert, as if the form were still there: nothing is sent.
                p.composer.update(cx, |c, cx| c.submit_form(window, cx));
            });
            vcx.run_until_parked();
            assert_eq!(daemon.calls::<methods::PromptsRender>().len(), renders);
        }

        #[gpui_kit::test]
        fn a_failed_first_send_keeps_its_files(cx: &mut TestAppContext) {
            let (daemon, _stores, pane, vcx) = bench(cx);
            daemon.on::<methods::TurnsSend>(|_| {
                Err(conduit_daemon::protocol::error("rpc.timeout", "slow"))
            });
            pane.update_in(vcx, |p, window, cx| {
                p.composer_store
                    .update(cx, |c, _| c.attachments.push(uploaded("plan.pdf")));
                p.send_text("Read this".into(), vec![], window, cx);
            });
            assert!(
                attachment_names(&pane, vcx).is_empty(),
                "taken for the send"
            );
            vcx.run_until_parked();
            assert_eq!(attachment_names(&pane, vcx), vec!["plan.pdf".to_string()]);
        }

        #[gpui_kit::test]
        fn the_settings_offer_is_asked_again_after_a_failure_and_per_account(
            cx: &mut TestAppContext,
        ) {
            let (daemon, stores, pane, vcx) = bench(cx);
            daemon.returns::<methods::ModelsList>(
                serde_json::from_value(serde_json::json!({
                    "models": [{"id": "m", "name": "M"}], "selectedId": "m"
                }))
                .unwrap(),
            );
            daemon.returns::<methods::ComposerOptions>(Default::default());
            daemon.once::<methods::ChatSettingsGet>(Err(conduit_daemon::protocol::error(
                "rpc.daemonUnavailable",
                "reconnecting",
            )));
            daemon.returns::<methods::ChatSettingsGet>(
                serde_json::from_value(serde_json::json!({
                    "entry": "editor",
                    "systemPrompt": {"key": "system", "kind": "text"}
                }))
                .unwrap(),
            );
            daemon.returns::<methods::ValvesTargets>(Default::default());
            pane.update(vcx, |p, cx| {
                p.composer_store.update(cx, |c, cx| c.refresh_models(cx))
            });
            vcx.run_until_parked();
            assert!(!pane.read_with(vcx, |p, _| p.settings_offer.chat_settings));
            // The composer changes again (a reconnect lists the models): the
            // failed question is asked again.
            pane.update(vcx, |p, cx| {
                p.composer_store.update(cx, |_, cx| cx.notify())
            });
            vcx.run_until_parked();
            assert!(pane.read_with(vcx, |p, _| p.settings_offer.chat_settings));
            let asked = daemon.calls::<methods::ChatSettingsGet>().len();
            // Another account with the same model id: asked again, for it.
            switch_account(&stores, vcx);
            vcx.run_until_parked();
            assert!(daemon.calls::<methods::ChatSettingsGet>().len() > asked);
        }

        #[gpui_kit::test]
        fn a_first_send_made_after_moving_on_takes_its_settings_with_it(cx: &mut TestAppContext) {
            let (daemon, stores, pane, vcx) = bench(cx);
            daemon.returns::<methods::TurnsSend>(
                serde_json::from_value(serde_json::json!({
                    "chatId": "c1", "userMessageId": "m1", "assistantMessageId": "a1"
                }))
                .unwrap(),
            );
            let held = daemon.hold::<methods::TurnsSend>();
            pane.update_in(vcx, |p, window, cx| {
                p.composer_store.update(cx, |c, cx| {
                    c.set_draft_params(serde_json::json!({"temperature": 0.3}), cx)
                });
                p.send_text("Plan the trip".into(), vec![], window, cx);
            });
            // The user goes to a temporary chat before the chat is made.
            stores.navigation.update(vcx, |n, cx| n.new_chat(true, cx));
            vcx.run_until_parked();
            drop(held);
            vcx.run_until_parked();
            assert!(
                pane.read_with(vcx, |p, cx| p
                    .composer_store
                    .read(cx)
                    .draft_params
                    .is_null()),
                "the next new chat takes the made one's settings"
            );
        }

        #[gpui_kit::test]
        fn a_temporary_chats_settings_saved_after_it_was_made_reach_no_next_chat(
            cx: &mut TestAppContext,
        ) {
            use crate::views::chat_settings::ChatSettingsSheet;
            let (daemon, stores, pane, vcx) = bench(cx);
            daemon.returns::<methods::ModelsList>(
                serde_json::from_value(serde_json::json!({
                    "models": [{"id": "m", "name": "M"}], "selectedId": "m"
                }))
                .unwrap(),
            );
            daemon.returns::<methods::ComposerOptions>(Default::default());
            daemon.returns::<methods::ValvesTargets>(Default::default());
            let state: conduit_protocol::ChatSettingsState =
                serde_json::from_value(serde_json::json!({
                    "entry": "editor", "advanced": true,
                    "canEditSystemPrompt": true, "canEditParameters": true,
                    "systemPrompt": {"key": "system", "kind": "text", "mode": "inherit"},
                    "parameters": [{"key": "temperature", "kind": "decimal", "mode": "custom",
                                    "text": "0.3", "min": 0.0, "max": 2.0}],
                    "saved": true, "params": {"top_k": 5}
                }))
                .unwrap();
            daemon.returns::<methods::ChatSettingsGet>(state.clone());
            daemon.returns::<methods::ChatSettingsCheck>(state.clone());
            daemon.returns::<methods::ChatSettingsSave>(state);
            daemon.returns::<methods::TurnsSend>(
                serde_json::from_value(serde_json::json!({
                    "chatId": "local:t1", "userMessageId": "m1", "assistantMessageId": "a1"
                }))
                .unwrap(),
            );
            pane.update(vcx, |p, cx| {
                p.composer_store.update(cx, |c, cx| c.refresh_models(cx))
            });
            stores.navigation.update(vcx, |n, cx| n.new_chat(true, cx));
            vcx.run_until_parked();
            pane.update_in(vcx, |p, window, cx| p.open_chat_settings(window, cx));
            vcx.run_until_parked();
            let sheet = vcx
                .update(|_, cx| crate::views::sheet::current::<ChatSettingsSheet>(cx))
                .expect("Chat Settings opens on a temporary new chat");
            vcx.update(|window, cx| sheet.update(cx, |s, cx| s.inherit("temperature", window, cx)));
            vcx.executor()
                .advance_clock(std::time::Duration::from_millis(200));
            vcx.run_until_parked();
            // Its first message goes and the temporary chat is made.
            let held = daemon.hold::<methods::TurnsSend>();
            pane.update_in(vcx, |p, window, cx| {
                p.send_text("Plan the trip".into(), vec![], window, cx)
            });
            drop(held);
            vcx.run_until_parked();
            // Saved now, then another temporary new chat.
            vcx.update(|window, cx| sheet.update(cx, |s, cx| s.save(window, cx)));
            vcx.run_until_parked();
            vcx.update(|_, cx| crate::views::sheet::dismiss(cx));
            stores.navigation.update(vcx, |n, cx| n.new_chat(true, cx));
            vcx.run_until_parked();
            assert!(
                pane.read_with(vcx, |p, cx| p
                    .composer_store
                    .read(cx)
                    .draft_params
                    .is_null()),
                "the made chat's settings went out with the next new chat"
            );
        }

        #[gpui_kit::test]
        fn chat_settings_saved_after_the_chat_was_made_land_on_no_other_draft(
            cx: &mut TestAppContext,
        ) {
            use crate::views::chat_settings::ChatSettingsSheet;
            let (daemon, stores, pane, vcx) = bench(cx);
            daemon.returns::<methods::ModelsList>(
                serde_json::from_value(serde_json::json!({
                    "models": [{"id": "m", "name": "M"}], "selectedId": "m"
                }))
                .unwrap(),
            );
            daemon.returns::<methods::ComposerOptions>(Default::default());
            daemon.returns::<methods::ValvesTargets>(Default::default());
            let state: conduit_protocol::ChatSettingsState =
                serde_json::from_value(serde_json::json!({
                    "entry": "editor", "advanced": true,
                    "canEditSystemPrompt": true, "canEditParameters": true,
                    "systemPrompt": {"key": "system", "kind": "text", "mode": "inherit"},
                    "parameters": [{"key": "temperature", "kind": "decimal", "mode": "custom",
                                    "text": "0.3", "min": 0.0, "max": 2.0}],
                    "saved": true, "params": {"top_k": 5}
                }))
                .unwrap();
            daemon.returns::<methods::ChatSettingsGet>(state.clone());
            daemon.returns::<methods::ChatSettingsCheck>(state.clone());
            daemon.returns::<methods::ChatSettingsSave>(state);
            daemon.returns::<methods::TurnsSend>(
                serde_json::from_value(serde_json::json!({
                    "chatId": "c1", "userMessageId": "m1", "assistantMessageId": "a1"
                }))
                .unwrap(),
            );
            pane.update(vcx, |p, cx| {
                p.composer_store.update(cx, |c, cx| c.refresh_models(cx))
            });
            vcx.run_until_parked();
            let open_sheet = |vcx: &mut VisualTestContext| {
                pane.update_in(vcx, |p, window, cx| p.open_chat_settings(window, cx));
                vcx.run_until_parked();
                vcx.update(|_, cx| crate::views::sheet::current::<ChatSettingsSheet>(cx))
            };
            // Chat Settings on the new chat, with an edit to save.
            let sheet = open_sheet(vcx).expect("Chat Settings opens on a new chat");
            vcx.update(|window, cx| sheet.update(cx, |s, cx| s.inherit("temperature", window, cx)));
            vcx.executor()
                .advance_clock(std::time::Duration::from_millis(200));
            vcx.run_until_parked();
            // The first message goes and its chat is made and opened.
            let held = daemon.hold::<methods::TurnsSend>();
            pane.update_in(vcx, |p, window, cx| {
                p.send_text("Plan the trip".into(), vec![], window, cx)
            });
            drop(held);
            vcx.run_until_parked();
            // Saved now: the draft it was opened for is gone.
            vcx.update(|window, cx| sheet.update(cx, |s, cx| s.save(window, cx)));
            vcx.run_until_parked();
            vcx.update(|_, cx| crate::views::sheet::dismiss(cx));
            stores.navigation.update(vcx, |n, cx| n.new_chat(false, cx));
            vcx.run_until_parked();
            assert!(
                pane.read_with(vcx, |p, cx| p
                    .composer_store
                    .read(cx)
                    .draft_params
                    .is_null()),
                "the settings went out with the next, unrelated new chat"
            );
            // While a first send is starting, Chat Settings does not open on
            // its draft.
            let held = daemon.hold::<methods::TurnsSend>();
            pane.update_in(vcx, |p, window, cx| {
                p.send_text("Pack the bags".into(), vec![], window, cx)
            });
            assert!(
                open_sheet(vcx).is_none(),
                "opened while the first send was starting"
            );
            drop(held);
            vcx.run_until_parked();
        }

        #[gpui_kit::test]
        fn a_temporary_new_chat_in_a_folder_is_sent_to_the_folder(cx: &mut TestAppContext) {
            let (daemon, stores, pane, vcx) = bench(cx);
            daemon.returns::<methods::FoldersDraftModel>(
                serde_json::from_value(
                    serde_json::json!({"folderId": "f1", "modelIds": ["trip-model"]}),
                )
                .unwrap(),
            );
            daemon.returns::<methods::ModelsList>(conduit_protocol::ModelList {
                models: vec![
                    serde_json::from_value(serde_json::json!({"id": "base", "name": "Base"}))
                        .unwrap(),
                    serde_json::from_value(
                        serde_json::json!({"id": "trip-model", "name": "Trip Model"}),
                    )
                    .unwrap(),
                ],
                selected_id: Some("base".into()),
                ..Default::default()
            });
            daemon.returns::<methods::TurnsSend>(
                serde_json::from_value(serde_json::json!({
                    "chatId": "c1", "userMessageId": "m1", "assistantMessageId": "a1"
                }))
                .unwrap(),
            );
            pane.update(vcx, |p, cx| {
                p.composer_store.update(cx, |c, cx| {
                    c.prefs.temporary_by_default = true;
                    c.refresh_models(cx);
                })
            });
            stores
                .navigation
                .update(vcx, |n, cx| n.new_chat_in_folder("f1".into(), cx));
            vcx.run_until_parked();
            assert!(pane.read_with(vcx, |p, cx| p.composer.read(cx).temporary));
            pane.update_in(vcx, |p, window, cx| {
                p.send_text("Plan the trip".into(), vec![], window, cx)
            });
            vcx.run_until_parked();
            let sent = daemon.calls::<methods::TurnsSend>();
            assert_eq!(sent.len(), 1);
            assert_eq!(sent[0]["temporary"], true);
            assert_eq!(
                sent[0]["folderId"], "f1",
                "the folder's prompt and knowledge were left out"
            );
            assert_eq!(sent[0]["model"], "trip-model", "not the folder's model");
        }

        /// The composer's Temporary switch on a folder's new chat keeps the
        /// folder and the Chat Settings saved on it.
        #[gpui_kit::test]
        fn the_temporary_switch_keeps_a_folders_new_chat_and_its_settings(cx: &mut TestAppContext) {
            let (daemon, stores, pane, vcx) = bench(cx);
            daemon.returns::<methods::ModelsList>(
                serde_json::from_value(serde_json::json!({
                    "models": [{"id": "m", "name": "M"}], "selectedId": "m"
                }))
                .unwrap(),
            );
            daemon.returns::<methods::TurnsSend>(
                serde_json::from_value(serde_json::json!({
                    "chatId": "local:t1", "userMessageId": "m1", "assistantMessageId": "a1"
                }))
                .unwrap(),
            );
            pane.update(vcx, |p, cx| {
                p.composer_store.update(cx, |c, cx| c.refresh_models(cx))
            });
            stores
                .navigation
                .update(vcx, |n, cx| n.new_chat_in_folder("f1".into(), cx));
            vcx.run_until_parked();
            let saved = serde_json::json!({"temperature": 0.3});
            pane.update(vcx, |p, cx| {
                p.composer_store
                    .update(cx, |c, cx| c.set_draft_params(saved.clone(), cx))
            });
            pane.update(vcx, |p, cx| {
                p.composer.update(cx, |_, cx| {
                    cx.emit(crate::views::chat::composer::ChatComposerEvent::Temporary(
                        true,
                    ))
                })
            });
            vcx.run_until_parked();
            assert!(pane.read_with(vcx, |p, cx| p.composer.read(cx).temporary));
            pane.update_in(vcx, |p, window, cx| {
                p.send_text("Plan the trip".into(), vec![], window, cx)
            });
            vcx.run_until_parked();
            let sent = daemon.calls::<methods::TurnsSend>();
            assert_eq!(sent.len(), 1);
            assert_eq!(sent[0]["temporary"], true);
            assert_eq!(sent[0]["folderId"], "f1", "the switch lost the folder");
            assert_eq!(
                sent[0]["chatParams"], saved,
                "the switch dropped the settings saved on this new chat"
            );
        }

        #[gpui_kit::test]
        fn a_first_send_from_one_folder_leaves_anothers_draft_alone(cx: &mut TestAppContext) {
            let (daemon, stores, pane, vcx) = bench(cx);
            daemon.returns::<methods::TurnsSend>(
                serde_json::from_value(serde_json::json!({
                    "chatId": "c1", "userMessageId": "m1", "assistantMessageId": "a1"
                }))
                .unwrap(),
            );
            let settings = serde_json::json!({"temperature": 0.3});
            stores
                .navigation
                .update(vcx, |n, cx| n.new_chat_in_folder("f1".into(), cx));
            vcx.run_until_parked();
            let held = daemon.hold::<methods::TurnsSend>();
            pane.update_in(vcx, |p, window, cx| {
                p.composer_store
                    .update(cx, |c, cx| c.set_draft_params(settings.clone(), cx));
                p.send_text("Plan the trip".into(), vec![], window, cx);
            });
            // Another folder's new chat, given the same settings, before
            // the first one is made.
            stores
                .navigation
                .update(vcx, |n, cx| n.new_chat_in_folder("f2".into(), cx));
            vcx.run_until_parked();
            pane.update(vcx, |p, cx| {
                p.composer_store
                    .update(cx, |c, cx| c.set_draft_params(settings.clone(), cx))
            });
            drop(held);
            vcx.run_until_parked();
            assert_eq!(
                stores
                    .navigation
                    .read_with(vcx, |n, _| n.new_chat_folder().map(str::to_string)),
                Some("f2".to_string()),
                "the chat made in Trips opened over the new chat in the other folder"
            );
            assert_eq!(
                pane.read_with(vcx, |p, cx| p.composer_store.read(cx).draft_params.clone()),
                settings,
                "the other folder's settings went with the first chat"
            );
        }

        #[gpui_kit::test]
        fn an_agreed_handoff_opens_a_kept_chat_with_its_message(cx: &mut TestAppContext) {
            let (_daemon, stores, pane, vcx) = bench(cx);
            pane.update(vcx, |p, cx| {
                p.composer_store
                    .update(cx, |c, _| c.prefs.temporary_by_default = true)
            });
            stores.navigation.update(vcx, |n, cx| n.open("chat-a", cx));
            vcx.run_until_parked();
            pane.update_in(vcx, |p, window, cx| {
                p.composer
                    .update(cx, |c, cx| c.restore("Notes for chat A", window, cx));
                p.open_handoff(None, Some("Compare the two plans".into()), window, cx);
            });
            vcx.run_until_parked();
            assert_eq!(composer_text(&pane, vcx), "Compare the two plans");
            assert_eq!(
                stores
                    .navigation
                    .read_with(vcx, |n, _| n.selection().clone()),
                crate::stores::navigation::Selection::New { temporary: false }
            );
            assert!(
                !pane.read_with(vcx, |p, cx| p.composer.read(cx).temporary),
                "the handoff's chat started temporary"
            );
        }

        #[gpui_kit::test]
        fn a_handoff_settled_elsewhere_takes_its_question_away(cx: &mut TestAppContext) {
            let (_daemon, _stores, pane, vcx) = bench(cx);
            let closer = crate::shell::sheet::SheetCloser::default();
            pane.update(vcx, |p, _| {
                p.handoff_ask = Some(("r1".into(), closer.clone()))
            });
            let settled = |id: &str| {
                crate::stores::connection::ConnectionEvent::Daemon(Box::new(
                    conduit_protocol::Event::HandoffSettled(conduit_protocol::HandoffSettled {
                        request_id: id.into(),
                    }),
                ))
            };
            // Another request's settling leaves this one.
            pane.update(vcx, |p, cx| p.on_connection(&settled("r0"), cx));
            assert!(!closer.is_closed());
            pane.update(vcx, |p, cx| p.on_connection(&settled("r1"), cx));
            assert!(closer.is_closed(), "the settled question stayed up");
            assert!(pane.read_with(vcx, |p, _| p.handoff_ask.is_none()));
        }

        #[gpui_kit::test]
        fn a_replayed_handoff_is_asked_once_and_its_settling_closes_it(cx: &mut TestAppContext) {
            let (_daemon, _stores, pane, vcx) = bench(cx);
            let request = conduit_protocol::HandoffRequest {
                request_id: "r1".into(),
                chat_id: "chat-a".into(),
                model_id: "m2".into(),
                model_name: "Model Two".into(),
                prompt: String::new(),
            };
            let closer = crate::shell::sheet::SheetCloser::default();
            pane.update(vcx, |p, _| {
                p.handoff_ask = Some(("r1".into(), closer.clone()))
            });
            // Replayed twice (another window subscribed): still the one alert.
            pane.update(vcx, |p, cx| {
                assert!(!p.handoff_new("r1"));
                p.ask_handoff(request.clone(), cx);
                p.ask_handoff(request.clone(), cx);
            });
            let settled = crate::stores::connection::ConnectionEvent::Daemon(Box::new(
                conduit_protocol::Event::HandoffSettled(conduit_protocol::HandoffSettled {
                    request_id: "r1".into(),
                }),
            ));
            pane.update(vcx, |p, cx| p.on_connection(&settled, cx));
            assert!(closer.is_closed(), "settling left the alert up");
            // Replayed after it settled: never asked again.
            pane.update(vcx, |p, cx| {
                assert!(
                    !p.handoff_new("r1"),
                    "a settled request would be asked again"
                );
                p.ask_handoff(request, cx);
                assert!(p.handoff_ask.is_none());
                assert!(p.handoff_new("r2"));
            });
        }

        #[gpui_kit::test]
        fn a_handoff_answered_after_an_account_switch_opens_nothing(cx: &mut TestAppContext) {
            let (_daemon, stores, pane, vcx) = bench(cx);
            stores.navigation.update(vcx, |n, cx| n.open("chat-a", cx));
            vcx.run_until_parked();
            let scope = pane.read_with(vcx, |p, cx| p.composer_store.read(cx).scope());
            switch_account(&stores, vcx);
            let before = stores
                .navigation
                .read_with(vcx, |n, _| n.selection().clone());
            pane.update_in(vcx, |p, window, cx| {
                p.open_handoff_in(
                    scope,
                    None,
                    Some("Compare the two plans".into()),
                    window,
                    cx,
                )
            });
            vcx.run_until_parked();
            assert_eq!(
                stores
                    .navigation
                    .read_with(vcx, |n, _| n.selection().clone()),
                before,
                "the last account's handoff opened a chat"
            );
            assert!(composer_text(&pane, vcx).is_empty());
        }

        fn switch_account(stores: &Stores, vcx: &mut VisualTestContext) {
            stores.accounts.update(vcx, |a, cx| {
                a.adopt(
                    list(vec![
                        account("a", "Avery", false, true),
                        account("b", "Blake", true, true),
                    ]),
                    cx,
                )
            });
        }

        fn composer_text(pane: &Entity<ChatPane>, vcx: &mut VisualTestContext) -> String {
            pane.read_with(vcx, |p, cx| p.composer.read(cx).text(cx))
        }

        #[gpui_kit::test]
        fn a_first_send_failing_after_an_account_switch_gives_nothing_back(
            cx: &mut TestAppContext,
        ) {
            let (daemon, stores, pane, vcx) = bench(cx);
            daemon.on::<methods::TurnsSend>(|_| {
                Err(conduit_daemon::protocol::error("rpc.timeout", "slow"))
            });
            let held = daemon.hold::<methods::TurnsSend>();
            pane.update_in(vcx, |p, window, cx| {
                p.composer_store
                    .update(cx, |c, _| c.attachments.push(uploaded("a-plan.pdf")));
                p.send_text("For account A".into(), vec![], window, cx);
            });
            switch_account(&stores, vcx);
            vcx.run_until_parked();
            held.release();
            vcx.run_until_parked();
            assert!(attachment_names(&pane, vcx).is_empty());
            assert_eq!(composer_text(&pane, vcx), "");
        }

        #[gpui_kit::test]
        fn a_send_in_a_chat_failing_after_an_account_switch_gives_nothing_back(
            cx: &mut TestAppContext,
        ) {
            let (daemon, stores, pane, vcx) = bench(cx);
            daemon.returns::<methods::ChatsGet>(
                serde_json::from_value(serde_json::json!({"chat": {
                    "summary": {"id": "chat-a", "title": "A chat", "updatedAtMs": 1,
                        "pinned": false, "archived": false, "tags": [], "shared": false,
                        "readOnly": false},
                    "messages": [], "readOnly": false
                }}))
                .unwrap(),
            );
            daemon.on::<methods::TurnsSend>(|_| {
                Err(conduit_daemon::protocol::error("rpc.timeout", "slow"))
            });
            stores.navigation.update(vcx, |n, cx| n.open("chat-a", cx));
            vcx.run_until_parked();
            assert!(pane.read_with(vcx, |p, _| p.chat.is_some()));
            let held = daemon.hold::<methods::TurnsSend>();
            pane.update_in(vcx, |p, window, cx| {
                p.composer_store
                    .update(cx, |c, _| c.attachments.push(uploaded("a-notes.md")));
                p.send_text("Also for A".into(), vec![], window, cx);
            });
            switch_account(&stores, vcx);
            vcx.run_until_parked();
            held.release();
            vcx.run_until_parked();
            assert!(attachment_names(&pane, vcx).is_empty());
            assert_eq!(composer_text(&pane, vcx), "");
        }

        #[gpui_kit::test]
        fn a_first_send_makes_the_new_chat_the_drafts_owner(cx: &mut TestAppContext) {
            let (daemon, stores, pane, vcx) = bench(cx);
            daemon.returns::<methods::TurnsSend>(
                serde_json::from_value(serde_json::json!({
                    "chatId": "chat-new",
                    "userMessageId": "m",
                    "assistantMessageId": "a",
                }))
                .unwrap(),
            );
            pane.update_in(vcx, |p, window, cx| {
                p.send_text("Hello".into(), vec![], window, cx)
            });
            vcx.run_until_parked();
            assert_eq!(
                stores
                    .navigation
                    .read_with(vcx, |n, _| n.selected_chat().map(String::from)),
                Some("chat-new".to_string())
            );
            let key = pane.read_with(vcx, |p, cx| p.composer_store.read(cx).draft_key().cloned());
            assert_eq!(
                key.and_then(|k| k.chat_id),
                Some("chat-new".to_string()),
                "a follow-up typed now is kept as the new chat's draft"
            );
        }

        /// A first send whose composition is replaced while it waits (a
        /// fresh Clipboard or Send Text in the same new chat): the chat is
        /// made, but neither opened over the fresh composition nor handed
        /// its text as a draft.
        #[gpui_kit::test]
        fn a_first_send_never_takes_over_a_composition_that_replaced_it(cx: &mut TestAppContext) {
            let (daemon, stores, pane, vcx) = bench(cx);
            // The first send makes chat-old, the next one chat-new.
            let sent = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
            let count = sent.clone();
            daemon.on::<methods::TurnsSend>(move |_| {
                let n = count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Ok(serde_json::json!({
                    "chatId": if n == 0 { "chat-old" } else { "chat-new" },
                    "userMessageId": "m",
                    "assistantMessageId": "a",
                }))
            });
            let held = daemon.hold::<methods::TurnsSend>();
            pane.update_in(vcx, |p, window, cx| {
                p.send_text("Hello".into(), vec![], window, cx)
            });
            vcx.run_until_parked();
            pane.update_in(vcx, |p, window, cx| {
                p.composer
                    .update(cx, |c, cx| c.start_fresh("Copied packing list", window, cx))
            });
            // The fresh composition is not held back by the first send.
            pane.update_in(vcx, |p, window, cx| {
                p.send_text("Copied packing list".into(), vec![], window, cx)
            });
            vcx.run_until_parked();
            assert_eq!(
                daemon.calls::<methods::TurnsSend>().len(),
                2,
                "the fresh composition's send waited for the replaced one"
            );
            held.release();
            vcx.run_until_parked();
            // Only the fresh composition's own send opened its chat and
            // became its draft's owner; the replaced one's took over nothing.
            assert_eq!(
                stores
                    .navigation
                    .read_with(vcx, |n, _| n.selected_chat().map(String::from)),
                Some("chat-new".to_string()),
                "the replaced first send opened its chat over the fresh composition"
            );
            let key = pane.read_with(vcx, |p, cx| p.composer_store.read(cx).draft_key().cloned());
            assert_eq!(key.and_then(|k| k.chat_id), Some("chat-new".to_string()));
        }

        /// A daemon that keeps drafts by chat (`""` for New Chat).
        fn keep_drafts(daemon: &FakeDaemon) {
            let drafts: std::sync::Arc<
                std::sync::Mutex<std::collections::HashMap<String, String>>,
            > = Default::default();
            let saved = drafts.clone();
            daemon.on::<methods::DraftsSave>(move |p| {
                let key = p["chatId"].as_str().unwrap_or_default().to_string();
                let text = p["text"].as_str().unwrap_or_default().to_string();
                saved.lock().unwrap().insert(key, text);
                Ok(serde_json::json!({"text": "", "stored": true}))
            });
            daemon.on::<methods::DraftsGet>(move |p| {
                let key = p["chatId"].as_str().unwrap_or_default();
                let text = drafts.lock().unwrap().get(key).cloned().unwrap_or_default();
                Ok(serde_json::json!({"text": text, "stored": true}))
            });
        }

        /// Words handed to a new chat opened from another chat land in the
        /// new chat, not in the draft of the chat shown before.
        #[gpui_kit::test]
        fn words_handed_to_a_new_chat_land_in_it(cx: &mut TestAppContext) {
            let (daemon, stores, pane, vcx) = bench(cx);
            keep_drafts(&daemon);
            stores.navigation.update(vcx, |n, cx| n.open("c1", cx));
            vcx.run_until_parked();
            pane.update_in(vcx, |p, window, cx| {
                p.stores
                    .navigation
                    .update(cx, |n, cx| n.new_chat(false, cx));
                p.hand_to_new_chat(
                    Some("> Moss on a north wall\n\n".into()),
                    vec![],
                    vec![],
                    window,
                    cx,
                );
            });
            vcx.executor()
                .advance_clock(std::time::Duration::from_millis(450));
            vcx.run_until_parked();
            assert!(matches!(
                stores
                    .navigation
                    .read_with(vcx, |n, _| n.selection().clone()),
                crate::stores::navigation::Selection::New { .. }
            ));
            pane.read_with(vcx, |p, cx| {
                assert_eq!(p.composer.read(cx).text(cx), "> Moss on a north wall\n\n");
            });
            let saved: Vec<String> = daemon
                .calls::<methods::DraftsSave>()
                .iter()
                .filter(|c| c["chatId"] == "c1")
                .map(|c| c["text"].as_str().unwrap_or_default().to_string())
                .collect();
            assert!(
                saved.iter().all(|t| !t.contains("Moss")),
                "the words went to the last chat's draft: {saved:?}"
            );
        }

        #[gpui_kit::test]
        fn a_follow_up_typed_while_the_first_send_waits_moves_with_its_chat(
            cx: &mut TestAppContext,
        ) {
            // Accepted before the 400 ms save, and after it.
            for saved_first in [false, true] {
                let (daemon, stores, pane, vcx) = bench(cx);
                keep_drafts(&daemon);
                daemon.returns::<methods::TurnsSend>(
                    serde_json::from_value(serde_json::json!({
                        "chatId": "chat-new",
                        "userMessageId": "m",
                        "assistantMessageId": "a",
                    }))
                    .unwrap(),
                );
                let held = daemon.hold::<methods::TurnsSend>();
                pane.update_in(vcx, |p, window, cx| {
                    p.send_text("Hello".into(), vec![], window, cx);
                    p.composer
                        .update(cx, |c, cx| c.set_text("And another thing", window, cx));
                });
                if saved_first {
                    vcx.executor()
                        .advance_clock(std::time::Duration::from_millis(450));
                }
                vcx.run_until_parked();
                held.release();
                vcx.run_until_parked();
                vcx.executor()
                    .advance_clock(std::time::Duration::from_millis(450));
                vcx.run_until_parked();
                // Away to New Chat: it holds nothing of the follow-up.
                stores.navigation.update(vcx, |n, cx| n.new_chat(false, cx));
                vcx.run_until_parked();
                assert_eq!(composer_text(&pane, vcx), "", "saved first: {saved_first}");
                // Back: the accepted chat shows it.
                stores
                    .navigation
                    .update(vcx, |n, cx| n.open("chat-new", cx));
                vcx.run_until_parked();
                assert_eq!(
                    composer_text(&pane, vcx),
                    "And another thing",
                    "saved first: {saved_first}"
                );
            }
        }

        #[gpui_kit::test]
        fn a_first_send_from_the_last_account_opens_nothing_in_this_one(cx: &mut TestAppContext) {
            let (daemon, stores, pane, vcx) = bench(cx);
            daemon.returns::<methods::TurnsSend>(
                serde_json::from_value(serde_json::json!({
                    "chatId": "chat-of-a",
                    "userMessageId": "m",
                    "assistantMessageId": "a",
                }))
                .unwrap(),
            );
            let held = daemon.hold::<methods::TurnsSend>();
            pane.update_in(vcx, |p, window, cx| {
                p.send_text("For Avery".into(), vec![], window, cx)
            });
            switch_account(&stores, vcx);
            vcx.run_until_parked();
            pane.update_in(vcx, |p, window, cx| {
                p.composer
                    .update(cx, |c, cx| c.set_text("Blake's own words", window, cx))
            });
            let key = pane.read_with(vcx, |p, cx| p.composer_store.read(cx).draft_key().cloned());
            held.release();
            vcx.run_until_parked();
            assert_eq!(
                stores
                    .navigation
                    .read_with(vcx, |n, _| n.selected_chat().map(String::from)),
                None,
                "A's chat opened in B"
            );
            assert!(pane.read_with(vcx, |p, _| p.chat.is_none()));
            assert_eq!(composer_text(&pane, vcx), "Blake's own words");
            assert_eq!(
                pane.read_with(vcx, |p, cx| p.composer_store.read(cx).draft_key().cloned()),
                key,
                "B's draft was rekeyed to A's chat"
            );
        }

        #[gpui_kit::test]
        fn a_refused_queue_edit_keeps_its_editor_and_text(cx: &mut TestAppContext) {
            let (daemon, stores, pane, vcx) = bench(cx);
            daemon.returns::<methods::ChatsGet>(
                serde_json::from_value(serde_json::json!({"chat": {
                    "summary": {"id": "chat-q", "title": "Queued", "updatedAtMs": 1,
                        "pinned": false, "archived": false, "tags": [], "shared": false,
                        "readOnly": false},
                    "messages": [], "readOnly": false
                }}))
                .unwrap(),
            );
            stores.navigation.update(vcx, |n, cx| n.open("chat-q", cx));
            vcx.run_until_parked();
            daemon.once::<methods::QueueEdit>(Err(conduit_daemon::protocol::error(
                "rpc.invalidParams",
                "frozen",
            )));
            pane.update_in(vcx, |p, window, cx| {
                p.edit_queued("q1", "Then this", window, cx);
                if let Some(edit) = &p.queue_edit {
                    edit.input
                        .update(cx, |i, cx| i.set_value("Then this instead", window, cx));
                }
                p.save_queue_edit(window, cx);
            });
            vcx.run_until_parked();
            let editing = |pane: &Entity<ChatPane>, vcx: &mut VisualTestContext| {
                pane.read_with(vcx, |p, cx| {
                    p.queue_edit
                        .as_ref()
                        .map(|e| e.input.read(cx).value().to_string())
                })
            };
            assert_eq!(
                editing(&pane, vcx),
                Some("Then this instead".to_string()),
                "a refused edit lost what was typed"
            );
            daemon.returns::<methods::QueueEdit>(
                serde_json::from_value(serde_json::json!({"chatId": "chat-q"})).unwrap(),
            );
            // Typed on while the save is out: the editor stays with it.
            let held = daemon.hold::<methods::QueueEdit>();
            pane.update_in(vcx, |p, window, cx| {
                p.save_queue_edit(window, cx);
                if let Some(edit) = &p.queue_edit {
                    edit.input.update(cx, |i, cx| {
                        i.set_value("Then this instead, later", window, cx)
                    });
                }
            });
            vcx.run_until_parked();
            drop(held);
            vcx.run_until_parked();
            assert_eq!(
                editing(&pane, vcx),
                Some("Then this instead, later".to_string()),
                "what was typed while saving was dropped"
            );
            pane.update_in(vcx, |p, window, cx| p.save_queue_edit(window, cx));
            vcx.run_until_parked();
            assert_eq!(editing(&pane, vcx), None);
            let sent = daemon.calls::<methods::QueueEdit>();
            assert_eq!(sent.len(), 3);
            assert_eq!(sent[1]["text"], "Then this instead");
            assert_eq!(sent[2]["text"], "Then this instead, later");
        }

        #[gpui_kit::test]
        fn another_account_never_sees_the_last_ones_draft(cx: &mut TestAppContext) {
            let (_daemon, stores, pane, vcx) = bench(cx);
            pane.update_in(vcx, |p, window, cx| {
                p.composer
                    .update(cx, |c, cx| c.set_text("Typed for Avery", window, cx))
            });
            switch_account(&stores, vcx);
            vcx.run_until_parked();
            assert_eq!(composer_text(&pane, vcx), "", "A's draft stayed for B");
            assert!(
                pane.read_with(vcx, |p, cx| p.composer_store.read(cx).draft_key().is_some()),
                "B's new chat keeps no draft"
            );
        }

        /// A draft's recordings go with its message only once the message
        /// is taken: a refused send keeps them with the draft it gives back.
        #[gpui_kit::test]
        fn a_refused_send_keeps_the_drafts_recordings(cx: &mut TestAppContext) {
            let (daemon, _stores, pane, vcx) = bench(cx);
            daemon.returns::<methods::RecordingsList>(
                serde_json::from_value(serde_json::json!({
                    "stored": true,
                    "recordings": [{"id": "r1", "createdAt": 0, "byteCount": 64000,
                                    "durationMs": 2000}]
                }))
                .unwrap(),
            );
            daemon.returns::<methods::RecordingsDiscard>(
                serde_json::from_value(serde_json::json!({"stored": true, "recordings": []}))
                    .unwrap(),
            );
            pane.update(vcx, |p, cx| {
                let dictation = p.composer.read(cx).dictation.clone().unwrap();
                dictation.update(cx, |d, cx| d.refresh_recordings(cx))
            });
            vcx.run_until_parked();
            let submit = |vcx: &mut VisualTestContext| {
                pane.update_in(vcx, |p, window, cx| {
                    p.composer.update(cx, |c, cx| {
                        // The bench has no connection to say it is online.
                        c.offline = false;
                        c.set_text("Plan the trip", window, cx);
                        c.submit(window, cx);
                    })
                });
                vcx.run_until_parked();
            };
            // No `turns.send` answer: refused.
            submit(vcx);
            assert_eq!(composer_text(&pane, vcx), "Plan the trip", "not given back");
            assert!(
                daemon.calls::<methods::RecordingsDiscard>().is_empty(),
                "a refused send discarded the draft's recording"
            );
            assert_eq!(
                pane.read_with(vcx, |p, cx| p
                    .composer
                    .read(cx)
                    .dictation
                    .as_ref()
                    .map(|d| d.read(cx).recordings.len())),
                Some(1),
                "the recording is no longer listed with the draft"
            );
            // Taken: the recording goes with it.
            daemon.returns::<methods::TurnsSend>(
                serde_json::from_value(serde_json::json!({
                    "chatId": "c1", "userMessageId": "m1", "assistantMessageId": "a1"
                }))
                .unwrap(),
            );
            pane.update_in(vcx, |p, window, cx| {
                p.composer.update(cx, |c, cx| {
                    c.input.update(cx, |s, cx| s.set_value("", window, cx))
                })
            });
            submit(vcx);
            let discarded = daemon.calls::<methods::RecordingsDiscard>();
            assert_eq!(discarded.len(), 1);
            assert_eq!(discarded[0]["id"], "r1");
        }

        /// A second message refused while the first new chat is still being
        /// made keeps its recordings with the draft it gives back.
        #[gpui_kit::test]
        fn a_send_refused_while_a_new_chat_starts_keeps_its_recordings(cx: &mut TestAppContext) {
            let (daemon, _stores, pane, vcx) = bench(cx);
            let listed = |id: &str| -> conduit_protocol::RecordingList {
                serde_json::from_value(serde_json::json!({
                    "stored": true,
                    "recordings": [{"id": id, "createdAt": 0, "byteCount": 64000,
                                    "durationMs": 2000}]
                }))
                .unwrap()
            };
            daemon.once::<methods::RecordingsList>(Ok(listed("r1")));
            daemon.returns::<methods::RecordingsList>(listed("r2"));
            daemon.returns::<methods::RecordingsDiscard>(listed("r2"));
            daemon.returns::<methods::TurnsSend>(
                serde_json::from_value(serde_json::json!({
                    "chatId": "c1", "userMessageId": "m1", "assistantMessageId": "a1"
                }))
                .unwrap(),
            );
            let dictation =
                pane.read_with(vcx, |p, cx| p.composer.read(cx).dictation.clone().unwrap());
            dictation.update(vcx, |d, cx| d.refresh_recordings(cx));
            vcx.run_until_parked();
            let submit = |text: &str, vcx: &mut VisualTestContext| {
                pane.update_in(vcx, |p, window, cx| {
                    p.composer.update(cx, |c, cx| {
                        c.offline = false;
                        c.set_text(text, window, cx);
                        c.submit(window, cx);
                    })
                });
                vcx.run_until_parked();
            };
            // The first message is on its way, its new chat not made yet.
            let held = daemon.hold::<methods::TurnsSend>();
            submit("Plan the trip", vcx);
            // Another recording, then a second message: refused for now.
            dictation.update(vcx, |d, cx| d.refresh_recordings(cx));
            vcx.run_until_parked();
            submit("And the packing list", vcx);
            assert_eq!(composer_text(&pane, vcx), "And the packing list");
            assert_eq!(
                dictation.read_with(vcx, |d, _| d.recordings.len()),
                1,
                "the refused message's recording is no longer listed"
            );
            held.release();
            vcx.run_until_parked();
            let discarded = daemon.calls::<methods::RecordingsDiscard>();
            assert_eq!(discarded.len(), 1);
            assert_eq!(
                discarded[0]["id"], "r1",
                "only the sent message's recording goes"
            );
        }

        /// A saved recording's words that come back after another account
        /// took the window go into no composer of that account's.
        #[gpui_kit::test]
        fn a_recordings_words_never_reach_another_accounts_composer(cx: &mut TestAppContext) {
            let (daemon, stores, pane, vcx) = bench(cx);
            daemon.returns::<methods::RecordingsList>(
                serde_json::from_value(serde_json::json!({
                    "stored": true,
                    "recordings": [{"id": "r1", "createdAt": 0, "byteCount": 64000,
                                    "durationMs": 2000}]
                }))
                .unwrap(),
            );
            daemon.returns::<methods::DictationStatus>(
                serde_json::from_value(serde_json::json!({
                    "engine": "server", "serverAvailable": true
                }))
                .unwrap(),
            );
            daemon.returns::<methods::RecordingsTranscribe>(conduit_protocol::VoiceTranscript {
                text: "Words for Avery".into(),
            });
            vcx.run_until_parked();
            let held = daemon.hold::<methods::RecordingsTranscribe>();
            pane.update_in(vcx, |p, window, cx| {
                p.composer
                    .update(cx, |c, cx| c.transcribe_recording("r1", false, window, cx))
            });
            vcx.run_until_parked();
            assert_eq!(daemon.calls::<methods::RecordingsTranscribe>().len(), 1);
            switch_account(&stores, vcx);
            vcx.run_until_parked();
            held.release();
            vcx.run_until_parked();
            assert_eq!(
                composer_text(&pane, vcx),
                "",
                "Avery's recording was written into Blake's composer"
            );
        }

        #[gpui_kit::test]
        fn a_late_first_send_does_not_take_over_another_chat(cx: &mut TestAppContext) {
            let (daemon, stores, pane, vcx) = bench(cx);
            daemon.returns::<methods::TurnsSend>(
                serde_json::from_value(serde_json::json!({
                    "chatId": "chat-new",
                    "userMessageId": "m",
                    "assistantMessageId": "a",
                }))
                .unwrap(),
            );
            let held = daemon.hold::<methods::TurnsSend>();
            pane.update_in(vcx, |p, window, cx| {
                p.send_text("Hello".into(), vec![], window, cx)
            });
            stores.navigation.update(vcx, |n, cx| n.open("chat-b", cx));
            held.release();
            vcx.run_until_parked();
            assert_eq!(
                stores
                    .navigation
                    .read_with(vcx, |n, _| n.selected_chat().map(String::from)),
                Some("chat-b".to_string())
            );
        }
    }
}

/// Today as `yyyy-MM-dd` in local time, the title a draft saved as a note
/// gets (mobile's `DateFormat('yyyy-MM-dd')`).
fn today_title() -> String {
    chrono::Local::now().format("%Y-%m-%d").to_string()
}
