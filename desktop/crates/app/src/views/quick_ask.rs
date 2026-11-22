//! Quick Ask: the 720×320 panel the global shortcut (⇧⌘Space by default),
//! the menu-bar item and Window › Quick Ask open over whatever app is in
//! front.
//!
//! * **Contents:** the chat view's [`ChatComposer`] and a compact [`Transcript`] for
//!   one new chat, over the window's own [`ChatStore`] and
//!   [`ComposerStore`]. Its events come through the process's one daemon
//!   connection under the subscription key `quick-ask` (the main window's
//!   chat pane uses `chat`), so both can follow a turn at once.
//! * **Open in Conduit** shows the main window on this chat (or, before the
//!   first message, a new chat with the draft). **New chat** starts over.
//! * **Hiding:** Esc, or the panel losing key status to another app or to
//!   the main window ([`crate::desktop`] places, shows and hides the
//!   window). Hiding keeps the exchange; the answer keeps streaming and a
//!   notification says when it is ready.
//!
//! Before the account is set up (not routed to Main) it says to open
//! Conduit first.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{UI_FONT, with_alpha};
use conduit_components::views::kit::{Button, ESC_KEYCAP, IconButton, keycap};
use conduit_protocol::{ChatView, Event, events, methods};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Context, Entity, FocusHandle, Focusable, KeyDownEvent, Role, SharedString,
    Subscription, Window, div, px,
};

use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::stores::chat::{CHAT_EVENTS, ChatStore, ChatStoreEvent, PendingMessage, Subscribe};
use crate::stores::composer::{ComposerEvent, ComposerPrefs, ComposerStore};
use crate::stores::connection::ConnectionEvent;
use crate::stores::router::RouterEvent;
use crate::stores::session::Route;
use crate::stores::settings::SettingsStore;
use crate::views::chat::composer::{ChatComposer, ChatComposerEvent};
use crate::views::chat::rows::{RowHost, RowSink};
use crate::views::chat::transcript::Transcript;
use crate::views::chat_pane::{daemon_uploader, follow_daemon_http};

/// The connection subscription key for the Quick Ask window's chat.
pub const SUBSCRIPTION_KEY: &str = "quick-ask";

/// The window's chat once the first message is sent.
pub struct QuickChat {
    pub store: Entity<ChatStore>,
    pub transcript: Entity<Transcript>,
    _subscriptions: Vec<Subscription>,
}

/// What the Quick Ask window asks the shell to do.
#[derive(Clone, Debug)]
pub enum QuickAskEvent {
    /// Esc: hide the panel.
    Hide,
    /// The panel stopped being the key window.
    Blurred,
    /// Show the main window on this chat.
    OpenChat(String),
    /// Show the main window on a new chat with this draft and its uploaded
    /// attachments.
    OpenDraft {
        text: String,
        attachments: Vec<crate::stores::composer::Attachment>,
    },
    /// A voice call in a new chat with this model, in the main window.
    StartCall(Option<String>),
}

impl gpui_kit::EventEmitter<QuickAskEvent> for QuickAskView {}

pub struct QuickAskView {
    stores: Stores,
    /// The text size View › Zoom In and the rest step.
    settings: Entity<SettingsStore>,
    pub composer_store: Entity<ComposerStore>,
    pub composer: Entity<ChatComposer>,
    pub chat: Option<QuickChat>,
    /// The panel is on screen ([`Self::set_shown`]).
    shown: bool,
    /// The platform shows the panel's window: not while the app is hidden
    /// (⌘H), nor minimized or fully covered.
    window_visible: bool,
    /// The chat on screen as the daemon heard it ([`Self::report_shown`]).
    shown_report: crate::stores::chat_list::ShownReport,
    /// The first message is on its way.
    starting: bool,
    /// Bumped by New Chat and by another account: a first message sent
    /// before it never opens its chat here.
    generation: u64,
    /// The account (and whether it has a session) this exchange belongs to.
    scope: (Option<String>, bool),
    /// A short notice in the footer ("Copied", a failed send).
    notice: Option<String>,
    /// The panel's tint and hairline, and the mask that fades the
    /// transcript's edges into them (made on first draw).
    #[cfg(target_os = "macos")]
    chrome: Rc<std::cell::RefCell<Option<crate::shell::macos::PanelChrome>>>,
    focus: FocusHandle,
    _subscriptions: Vec<Subscription>,
}

/// The panel's corner radius (its material, tint and content share it).
const PANEL_RADIUS: f32 = 16.;
/// The answer's top fade once it has scrolled under the header.
#[cfg(target_os = "macos")]
const SCROLLED_TOP_FADE: f32 = 28.;

impl QuickAskView {
    pub fn new(
        stores: Stores,
        settings: Entity<SettingsStore>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let rpc = stores.connection.read(cx).rpc();
        let composer_store = cx.new(|_| ComposerStore::new(rpc, Some(daemon_uploader())));
        // Settings › Chat's choices (Send with Enter, quick pills, Save as
        // Note), kept as they change.
        let prefs = ComposerPrefs::from_settings(stores.app_settings.read(cx).settings());
        composer_store.update(cx, |c, cx| {
            c.set_prefs(prefs, cx);
            // Quick Ask's chats are ordinary chats, not temporary ones.
            c.saves_without_draft = true;
        });
        let placeholder = cx.l10n().message_hint_text();
        let composer = cx.new(|cx| {
            let mut c = ChatComposer::new(composer_store.clone(), window, cx);
            c.set_placeholder(&placeholder, window, cx);
            // No queue, steering or Save as Note here: Enter on a running
            // answer leaves the text in the field.
            c.follow_ups = false;
            // No temporary switch: Quick Ask chats are ordinary chats, so
            // "Open in Conduit" can show them.
            c.new_chat = false;
            // Two answers side by side need the main window's room.
            c.compare_ui = false;
            // A call: its strip lives in the main window.
            c.call_offer = true;
            c
        });
        let subscriptions = vec![
            follow_daemon_http(&stores.connection, cx),
            cx.observe_in(&stores.accounts, window, |this, _, window, cx| {
                // Another account, or signed out: nothing of the last one's
                // stays (its chat, the draft, its attachments).
                let scope = scope_of(&this.stores, cx);
                if scope != this.scope {
                    this.scope = scope;
                    this.forget(window, cx);
                }
            }),
            cx.observe(&stores.session, |_, _, cx| cx.notify()),
            {
                let composer_store = composer_store.clone();
                cx.observe(&stores.app_settings, move |_, settings, cx| {
                    let prefs = ComposerPrefs::from_settings(settings.read(cx).settings());
                    composer_store.update(cx, |c, cx| c.set_prefs(prefs, cx));
                })
            },
            cx.observe_window_activation(window, |_, window, cx| {
                if !window.is_window_active() {
                    cx.emit(QuickAskEvent::Blurred);
                }
            }),
            // ⌘H hides the app, panel included, without hiding Quick Ask
            // (`hide_quick_ask`); minimized or fully covered, it shows
            // nothing either.
            cx.observe_window_visibility(window, |this, visibility, _, cx| {
                this.window_visible = visibility.is_visible();
                this.report_shown(cx);
            }),
            cx.observe(&stores.connection, |this, _, cx| this.sync_offline(cx)),
            // The call button: ready while no call is on and a model is
            // chosen.
            cx.observe(&stores.call, |this, _, cx| this.sync_call(cx)),
            cx.observe(&composer_store, |this, _, cx| this.sync_call(cx)),
            cx.subscribe(&stores.connection, |this, _, event, cx| {
                this.on_connection(event, cx)
            }),
            cx.subscribe(&stores.router, |this, _, event: &RouterEvent, cx| {
                let RouterEvent::Remapped { from, to } = event;
                if let Some(chat) = &this.chat {
                    chat.store.update(cx, |s, cx| s.remap(from, to, cx));
                }
                // The composer follows the chat under its new id.
                this.composer_store
                    .update(cx, |c, cx| c.rekey_chat(from, to, cx));
            }),
            cx.subscribe_in(
                &composer,
                window,
                |this, _, event, window, cx| match event {
                    ChatComposerEvent::Submit { text, mentions } => {
                        this.send_text(text.clone(), mentions.clone(), window, cx)
                    }
                    ChatComposerEvent::Stop => this.stop(cx),
                    // Quick Ask asks and answers: no queue, no Hermes steering,
                    // no notes or comparisons from its small panel.
                    ChatComposerEvent::Temporary(_)
                    | ChatComposerEvent::PickerChanged
                    | ChatComposerEvent::Queue { .. }
                    | ChatComposerEvent::Steer { .. }
                    | ChatComposerEvent::SaveAsNote(_)
                    | ChatComposerEvent::CompareModels => {}
                    // A call goes on in the main window, in a new chat.
                    ChatComposerEvent::StartCall => {
                        let model = this
                            .composer_store
                            .read(cx)
                            .selected_model()
                            .map(|m| m.id.clone());
                        cx.emit(QuickAskEvent::StartCall(model));
                    }
                },
            ),
            cx.subscribe(&composer_store, |this, _, event, cx| {
                let l10n = cx.l10n().clone();
                this.notice = Some(match event {
                    ComposerEvent::AttachmentFailed { name } => {
                        l10n.desktop_attachment_failed(name)
                    }
                    ComposerEvent::ModelNotSelected(_) => l10n.desktop_model_not_selected(),
                    ComposerEvent::ControlNotSaved(_) => l10n.desktop_model_control_not_saved(),
                    // Quick Ask keeps no drafts.
                    ComposerEvent::DraftSwitched
                    | ComposerEvent::DraftLoaded { .. }
                    | ComposerEvent::DraftReadEnded => return,
                });
                cx.notify();
            }),
        ];
        let scope = scope_of(&stores, cx);
        let mut this = Self {
            stores,
            settings,
            composer_store,
            composer,
            chat: None,
            shown: false,
            window_visible: true,
            shown_report: crate::stores::chat_list::ShownReport::new(ChatView::QuickAsk),
            starting: false,
            generation: 0,
            scope,
            notice: None,
            #[cfg(target_os = "macos")]
            chrome: Rc::default(),
            focus: cx.focus_handle(),
            _subscriptions: subscriptions,
        };
        (this.subscribe_hook())(None, cx);
        this.composer_store.update(cx, |c, cx| c.refresh_models(cx));
        this.sync_offline(cx);
        this
    }

    fn subscribe_hook(&self) -> Subscribe {
        let connection = self.stores.connection.clone();
        Rc::new(move |chat_id: Option<&str>, cx: &mut App| {
            let scopes: Vec<String> = chat_id.into_iter().map(String::from).collect();
            let mut names: Vec<&'static str> = CHAT_EVENTS.to_vec();
            names.push(events::MODELS_CHANGED);
            connection.update(cx, |c, _| c.subscribe(SUBSCRIPTION_KEY, &names, scopes));
        })
    }

    /// The chat on screen, once started.
    pub fn chat_id(&self, cx: &App) -> Option<String> {
        self.chat
            .as_ref()
            .map(|c| c.store.read(cx).chat_id().to_string())
    }

    /// Whether the account is set up (Quick Ask can ask).
    pub fn ready(&self, cx: &App) -> bool {
        self.stores.session.read(cx).route(cx) == Route::Main
            && self.stores.connection.read(cx).is_connected()
    }

    /// Puts the caret in the composer (each time the panel shows).
    pub fn focus_composer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.composer.update(cx, |c, cx| c.focus_input(window, cx));
    }

    /// "Copied", after a copy in the transcript.
    pub fn notify_copied(&mut self, cx: &mut Context<Self>) {
        self.notice = Some(cx.l10n().desktop_copied());
        cx.notify();
    }

    /// The panel comes on screen, or goes: going, it leaves its chat, which
    /// is read up to now; coming back, its chat is shown again.
    pub fn set_shown(&mut self, shown: bool, cx: &mut Context<Self>) {
        if !shown {
            self.leave_chat(cx);
        } else if !self.shown
            && let Some(id) = self.chat_id(cx)
        {
            self.stores
                .chat_list
                .update(cx, |c, cx| c.mark_read(&id, cx));
        }
        self.shown = shown;
        self.report_shown(cx);
    }

    /// Tells the daemon which chat the panel shows on screen, when that
    /// changed (a first message's chat gets its id as it is saved): the core
    /// reads each change of its stored copy while it shows.
    fn report_shown(&mut self, cx: &mut Context<Self>) {
        let shown = self
            .chat_id(cx)
            .filter(|_| self.shown && self.window_visible);
        let rpc = self.stores.connection.read(cx).rpc();
        self.shown_report
            .report(shown, &rpc, cx, |panel| &mut panel.shown_report);
    }

    /// The app quits: the chat the panel shows is left, by a read the quit
    /// waits for.
    pub fn leave_on_quit(
        &mut self,
        cx: &mut Context<Self>,
    ) -> Option<(String, crate::stores::chat_list::QuitRead)> {
        if !std::mem::take(&mut self.shown) {
            return None;
        }
        let left = self.chat_id(cx)?;
        let read = self
            .stores
            .chat_list
            .update(cx, |c, _| c.mark_left_on_quit(&left))?;
        Some((left, read))
    }

    fn leave_chat(&mut self, cx: &mut Context<Self>) {
        if !self.shown {
            return;
        }
        if let Some(left) = self.chat_id(cx) {
            self.stores
                .chat_list
                .update(cx, |c, cx| c.mark_left(&left, cx));
        }
    }

    /// New chat: drops this exchange (the chat stays in the sidebar, read
    /// up to now), the draft and its attachments.
    pub fn new_chat(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.leave_chat(cx);
        self.clear(window, cx);
        self.composer_store.update(cx, |c, cx| {
            c.start_over(cx);
            c.follow_chat(None, cx);
        });
        self.composer.update(cx, |c, cx| c.focus_input(window, cx));
    }

    /// Another account: drops everything of the last one's, the composer's
    /// models, options and attachments included. Its chat is not read:
    /// the daemon now answers for the new account.
    fn forget(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.clear(window, cx);
        self.composer_store.update(cx, |c, cx| c.reset(cx));
        self.composer.update(cx, |c, cx| c.forget_account(cx));
    }

    fn clear(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.generation += 1;
        self.chat = None;
        self.report_shown(cx);
        self.starting = false;
        self.notice = None;
        (self.subscribe_hook())(None, cx);
        self.composer.update(cx, |c, cx| {
            c.streaming = false;
            c.set_text("", window, cx);
        });
        cx.notify();
    }

    /// "Ask Conduit" from another app's Services menu: a fresh exchange
    /// with `text` (the quoted selection), and nothing else, in the
    /// composer and the caret after it, for the question. An exchange on
    /// screen stays in the sidebar. `false`, and Quick Ask stays as it is,
    /// while it holds something of the user's ([`Self::holds_a_draft`]):
    /// the selection then goes to a new chat of its own.
    pub fn ask_about(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) -> bool {
        if self.holds_a_draft(cx) {
            return false;
        }
        self.new_chat(window, cx);
        self.composer
            .update(cx, |c, cx| c.set_text(text, window, cx));
        cx.notify();
        true
    }

    /// Words in the composer, a file (sent up, on its way or failed) or
    /// context beside it, or a send still on its way.
    fn holds_a_draft(&self, cx: &App) -> bool {
        let store = self.composer_store.read(cx);
        self.starting
            || !self.composer.read(cx).text(cx).trim().is_empty()
            || !store.attachments.is_empty()
            || !store.context.is_empty()
    }

    /// Open in Conduit: the main window on this chat, or on a new chat with
    /// the draft.
    pub fn open_in_conduit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(id) = self.chat_id(cx) {
            cx.emit(QuickAskEvent::OpenChat(id));
            return;
        }
        // Files still uploading would be left behind here.
        if self.composer_store.read(cx).uploading() {
            return;
        }
        let text = self.composer.read(cx).text(cx);
        self.composer.update(cx, |c, cx| c.set_text("", window, cx));
        let attachments = self.composer_store.update(cx, |c, cx| c.take_uploaded(cx));
        cx.emit(QuickAskEvent::OpenDraft { text, attachments });
    }

    fn on_connection(&mut self, event: &ConnectionEvent, cx: &mut Context<Self>) {
        match event {
            ConnectionEvent::Connected { .. } => {
                if let Some(chat) = &self.chat {
                    chat.store.update(cx, |s, cx| s.on_reconnected(cx));
                }
                // A new daemon session: the order of model answers starts
                // again (the open chat, draft and attachments stay).
                self.composer_store.update(cx, |c, cx| c.reconnected(cx));
                self.shown_report.reconnected();
                self.report_shown(cx);
            }
            ConnectionEvent::Gap => {
                if let Some(chat) = &self.chat {
                    chat.store.update(cx, |s, cx| s.fetch(cx));
                }
            }
            ConnectionEvent::Daemon(event) => {
                if matches!(
                    event.as_ref(),
                    Event::ModelsChanged | Event::AccountsChanged(_)
                ) {
                    self.composer_store.update(cx, |c, cx| c.refresh_models(cx));
                }
                if let Some(chat) = &self.chat {
                    chat.store.update(cx, |s, cx| s.on_event(event, cx));
                }
            }
            ConnectionEvent::LocalDataReset { .. } => {}
        }
    }

    fn sync_call(&mut self, cx: &mut Context<Self>) {
        let on = self.stores.call.read(cx).is_active();
        let ready = !on && self.composer_store.read(cx).call_ready();
        self.composer.update(cx, |c, cx| {
            if c.call_ready != ready || c.call_on != on {
                c.call_ready = ready;
                c.call_on = on;
                cx.notify();
            }
        });
    }

    fn sync_offline(&mut self, cx: &mut Context<Self>) {
        let connection = self.stores.connection.read(cx);
        let offline = !connection.is_connected() || connection.online() == Some(false);
        let status = connection.status(true, None);
        // No pill over Quick Ask: the banner's word stays beside Send, and
        // its tooltip says why.
        let word = offline.then(|| crate::views::status::send_state(&status, cx.l10n()));
        let reason = offline.then(|| crate::views::status::send_waits(&status, cx.l10n()));
        self.composer.update(cx, |c, cx| {
            if c.offline != offline || c.offline_word != word || c.offline_reason != reason {
                c.offline = offline;
                c.offline_word = word;
                c.offline_reason = reason;
                cx.notify();
            }
        });
    }

    fn open_chat(
        &mut self,
        id: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<ChatStore> {
        // The composer follows the chat: its lists, options and next turns
        // are the chat's (a first send's pick moved there with it).
        self.composer_store
            .update(cx, |c, cx| c.follow_chat(Some(id.clone()), cx));
        let rpc = self.stores.connection.read(cx).rpc();
        let subscribe = self.subscribe_hook();
        let store = cx.new(|cx| ChatStore::new(rpc, subscribe, id, cx));
        let server_id = self
            .stores
            .accounts
            .read(cx)
            .active()
            // The account's own id, as `/files` takes it (see ChatPane).
            .map(|a| a.connection.id.clone());
        let host = RowHost {
            store: store.downgrade(),
            pane: RowSink::QuickAsk(cx.entity().downgrade()),
            server_id,
            composer: Some(self.composer_store.downgrade()),
        };
        // On the Mac the panel masks its own layer at the transcript's edges
        // (see `body`): the transcript paints no fades of its own, which on
        // the translucent panel would never match what is beneath.
        let transcript = cx.new(|cx| {
            let t = Transcript::new(store.clone(), host, cx);
            if cfg!(target_os = "macos") {
                t.without_painted_fades()
            } else {
                t
            }
        });
        let subscriptions = vec![
            cx.observe(&store, |this, store, cx| {
                this.report_shown(cx);
                let streaming = store.read(cx).is_streaming();
                if streaming {
                    let id = store.read(cx).chat_id().to_string();
                    this.stores
                        .chat_list
                        .update(cx, |c, _| c.note_answered(&id));
                }
                this.composer.update(cx, |c, cx| {
                    if c.streaming != streaming {
                        c.streaming = streaming;
                        cx.notify();
                    }
                });
                cx.notify();
            }),
            // Words the core gave this chat's composer (Hermes' prefill):
            // this panel's, while it holds the chat.
            cx.subscribe_in(
                &store,
                window,
                |this, _, event: &ChatStoreEvent, window, cx| {
                    if let ChatStoreEvent::InsertText { text } = event {
                        this.composer
                            .update(cx, |c, cx| c.give_text(text, window, cx));
                    }
                },
            ),
        ];
        self.chat = Some(QuickChat {
            store: store.clone(),
            transcript,
            _subscriptions: subscriptions,
        });
        self.report_shown(cx);
        cx.notify();
        store
    }

    /// Sends `text` (with the composer's options and attachments): in this
    /// chat, or as its first message.
    pub fn send_text(
        &mut self,
        text: String,
        mentions: Vec<conduit_protocol::ComposerMentionDto>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if text.trim().is_empty() && !self.composer_store.read(cx).has_attachments() {
            return;
        }
        // A follow-up from the transcript while a file still uploads would
        // go without it, and one before the chat's own list answers would
        // name another chat's model: it waits in the field instead.
        let composer = self.composer_store.read(cx);
        if (self.chat.is_none() && self.starting)
            || composer.uploading()
            || !composer.can_name_model()
        {
            self.composer_store.update(cx, |c, cx| c.ask_list_again(cx));
            self.composer
                .update(cx, |c, cx| c.restore_with(&text, &mentions, window, cx));
            return;
        }
        self.notice = None;
        let files = self.composer_store.read(cx).pending_files();
        let model = self
            .composer_store
            .read(cx)
            .next_model()
            .map(|m| m.name.clone());
        // Given back with the text if the send fails.
        let used = self
            .composer_store
            .read(cx)
            .one_shot()
            .with_mentions(mentions.clone());
        let options = self
            .composer_store
            .update(cx, |c, cx| c.take_turn(mentions, cx));
        let pending = PendingMessage {
            files,
            ..PendingMessage::new(text.clone())
        };
        if let Some(chat) = &self.chat {
            let turn = options.into_turn(text.clone(), None, false);
            let task = chat.store.update(cx, |s, cx| {
                s.model_hint = model;
                s.send(turn, pending, cx)
            });
            chat.transcript.update(cx, |t, cx| t.scroll_to_end(cx));
            let composer = self.composer.downgrade();
            let models = self.composer_store.downgrade();
            cx.spawn_in(window, async move |_, cx| {
                let result = task.await;
                if result.is_err() {
                    // Not after New Chat or another account (give_back).
                    let _ = composer
                        .update_in(cx, |c, window, cx| c.give_back(&text, used, window, cx));
                }
                // The daemon may have picked the model just now.
                let _ = models.update(cx, |m, cx| m.refresh_models(cx));
            })
            .detach();
            return;
        }
        let turn = options.into_turn(text.clone(), None, false);
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::TurnsSend>(&turn);
        self.starting = true;
        let generation = self.generation;
        cx.notify();
        cx.spawn_in(window, async move |this, cx| {
            let result = call.await;
            let _ = this.update_in(cx, |this, window, cx| {
                // New Chat or another account since: this send is no longer
                // the panel's (the chat stays in the sidebar).
                if this.generation != generation {
                    return;
                }
                this.starting = false;
                match result {
                    Ok(accepted) => {
                        let store = this.open_chat(accepted.chat_id.clone(), window, cx);
                        store.update(cx, |s, cx| {
                            s.model_hint = model;
                            s.started(pending, &accepted, false, cx)
                        });
                        this.composer.update(cx, |c, cx| c.focus_input(window, cx));
                    }
                    Err(e) => {
                        log::warn!("turns.send (quick ask): {e}");
                        this.composer
                            .update(cx, |c, cx| c.give_back(&text, used, window, cx));
                        this.notice = Some(cx.l10n().desktop_action_failed());
                        // The daemon may have picked the model just now. A
                        // chat that opened lists itself (`follow_chat`).
                        this.composer_store.update(cx, |m, cx| m.refresh_models(cx));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub fn stop(&mut self, cx: &mut Context<Self>) {
        if let Some(chat) = &self.chat {
            chat.store.update(cx, |s, cx| {
                if s.is_streaming() {
                    s.stop(cx)
                }
            });
        }
    }

    fn on_key_down(&mut self, event: &KeyDownEvent, _: &mut Window, cx: &mut Context<Self>) {
        let k = &event.keystroke;
        if k.key == "escape" && !k.modifiers.modified() && !self.composer.read(cx).has_popup() {
            cx.emit(QuickAskEvent::Hide);
            cx.stop_propagation();
        }
    }

    /// Whether the answer has scrolled from its start (some of it is under
    /// the header).
    fn scrolled(&self, cx: &App) -> bool {
        self.chat.as_ref().is_some_and(|chat| {
            let top = chat.transcript.read(cx).list_state().logical_scroll_top();
            top.item_ix > 0 || top.offset_in_item > px(0.)
        })
    }

    fn body(&self, cx: &mut Context<Self>) -> AnyElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let r = t.roles;
        let scrolled = self.scrolled(cx);
        if let Some(chat) = &self.chat {
            // Clipped: once the answer outgrows the panel, the list keeps
            // its end in view and would otherwise paint older rows under
            // the header. Its edges fade by the window's mask on GPUI's
            // layer, into the panel's real surface: the bottom always (over
            // the composer), the top once the answer has scrolled under the
            // header, over a longer 28 pt so a line cut there is a trace.
            #[cfg(target_os = "macos")]
            let edges = {
                let chrome = self.chrome.clone();
                let top_fade = if scrolled { SCROLLED_TOP_FADE } else { 0. };
                gpui_kit::canvas(
                    |_, _, _| {},
                    move |b, _, _, _| {
                        if let Some(chrome) = chrome.borrow_mut().as_mut() {
                            chrome.sync_fade(
                                Some((f32::from(b.top()), f32::from(b.bottom()))),
                                top_fade,
                                Transcript::EDGE_FADE,
                            );
                        }
                    },
                )
                .absolute()
                .top_0()
                .left_0()
                .size_full()
            };
            #[cfg(not(target_os = "macos"))]
            let edges = {
                let _ = scrolled;
                div()
            };
            return div()
                .relative()
                .flex_1()
                .min_h_0()
                .overflow_hidden()
                .flex()
                .flex_col()
                .child(chat.transcript.clone())
                .child(edges)
                .into_any_element();
        }
        #[cfg(target_os = "macos")]
        if let Some(chrome) = self.chrome.borrow_mut().as_mut() {
            chrome.sync_fade(None, 0., 0.);
        }
        let ready = self.ready(cx);
        let text = if ready {
            l10n.desktop_quick_ask_empty()
        } else {
            l10n.desktop_quick_ask_needs_setup()
        };
        div()
            .id("quick-ask-empty")
            .role(Role::Status)
            .aria_label(SharedString::from(text.clone()))
            .flex_1()
            .min_h_0()
            .flex()
            .items_center()
            .justify_center()
            .px(px(24.))
            .text_size(px(t.metrics.control))
            .text_color(r.text_subtle)
            .child(SharedString::from(text))
            .into_any_element()
    }
}

/// The panel's tint over its material. Dark: the ramp's raised tone
/// (#181818, the main window's composer and cards), nearly opaque, so the
/// HUD material's blue never tints it (it read #1C1F26 beside the neutral
/// greys); light keeps a translucent wash of the menu tone.
pub fn panel_tint(t: &conduit_components::theme::ConduitTheme) -> gpui_kit::Hsla {
    if t.dark {
        with_alpha(t.roles.raised, PANEL_TINT_DARK)
    } else {
        with_alpha(t.roles.overlay, 0.62)
    }
}

/// How opaque the dark tint is: what shows of the material through it
/// moves no channel more than a level or two.
pub const PANEL_TINT_DARK: f32 = 0.94;

impl Focusable for QuickAskView {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for QuickAskView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let tint = panel_tint(&t);
        let hairline = with_alpha(r.text, if t.dark { 0.16 } else { 0.10 });
        // The tint and hairline are a native layer under GPUI's (see
        // PanelChrome), so the transcript can fade into them.
        #[cfg(target_os = "macos")]
        let native_chrome = {
            let mut chrome = self.chrome.borrow_mut();
            if chrome.is_none() {
                *chrome = crate::shell::macos::PanelChrome::new(window, f64::from(PANEL_RADIUS));
            }
            if let Some(chrome) = chrome.as_mut() {
                chrome.sync_tint(tint, hairline);
            }
            chrome.is_some()
        };
        #[cfg(not(target_os = "macos"))]
        let native_chrome = {
            let _ = window;
            false
        };
        let ready = self.ready(cx);
        let has_chat = self.chat.is_some();
        let draft = (!self.composer.read(cx).text(cx).trim().is_empty()
            || self.composer_store.read(cx).has_attachments())
            && !self.composer_store.read(cx).uploading();
        // Key caps as the palette's footer draws them ("esc" in words).
        let hint = |keys: &'static str, label: String| {
            div()
                .flex()
                .items_center()
                .gap(px(5.))
                .child(keycap(keys, &t))
                .child(SharedString::from(label))
        };
        let view = cx.entity().downgrade();
        let new_chat = IconButton::new("quick-ask-new-chat", IconName::SquarePen, l10n.new_chat())
            .size(26., 14.)
            .on_click(Rc::new({
                let view = view.clone();
                move |_, window, cx| {
                    let _ = view.update(cx, |v, cx| v.new_chat(window, cx));
                }
            }));
        let open = Button::new("quick-ask-open", l10n.desktop_open_in_conduit())
            .icon(IconName::ArrowUpRight)
            .disabled(!ready || !(has_chat || draft))
            .on_click(Rc::new({
                let view = view.clone();
                move |_, window, cx| {
                    let _ = view.update(cx, |v, cx| v.open_in_conduit(window, cx));
                }
            }));
        let close = IconButton::new("quick-ask-close", IconName::X, l10n.close())
            .size(26., 14.)
            // Esc closes it too: written "esc", as the footer under it
            // writes it (the ⎋ glyph reads as refresh at this size).
            .shortcut(Some(ESC_KEYCAP.into()))
            .on_click(Rc::new({
                let view = view.clone();
                move |_, _, cx| {
                    let _ = view.update(cx, |_, cx| cx.emit(QuickAskEvent::Hide));
                }
            }));
        let footer_note = self.notice.clone();
        div()
            .id("quick-ask")
            .role(Role::Dialog)
            .aria_label(SharedString::from(l10n.desktop_quick_ask_title()))
            .key_context("ConduitQuickAsk")
            .track_focus(&self.focus)
            .capture_key_down(cx.listener(Self::on_key_down))
            .on_action(cx.listener(|_, _: &crate::actions::StopGenerating, _, cx| {
                cx.emit(QuickAskEvent::Hide)
            }))
            .on_action(
                cx.listener(|_, _: &crate::actions::CloseWindow, _, cx| {
                    cx.emit(QuickAskEvent::Hide)
                }),
            )
            .map(|d| crate::menus::app_commands(d, &self.settings, &self.stores.speech, cx))
            .size_full()
            .flex()
            .flex_col()
            .child(crate::views::chat::inline_web::frame_start())
            .font_family(UI_FONT)
            .text_color(r.text)
            .rounded(px(PANEL_RADIUS))
            .when(!native_chrome, |d| {
                d.bg(tint).border_1().border_color(hairline)
            })
            .overflow_hidden()
            .child(
                div()
                    .h(px(40.))
                    .flex_none()
                    .px(px(14.))
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    // Once the answer has scrolled under it, a hairline
                    // closes the header off (as a window's title bar shows
                    // its separator when content scrolls beneath it); the
                    // answer's top edge fades out below it either way. Always
                    // drawn, clear until then, so nothing moves.
                    .border_b_1()
                    .border_color(if self.scrolled(cx) {
                        hairline
                    } else {
                        with_alpha(hairline, 0.)
                    })
                    .child(icon(IconName::Sparkles, 16., r.text_subtle))
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(m.control))
                            .font_weight(gpui_kit::FontWeight::SEMIBOLD)
                            .text_color(r.text_subtle)
                            .child(SharedString::from(l10n.desktop_quick_ask_title())),
                    )
                    .child(new_chat)
                    .child(open)
                    .child(close),
            )
            .child(self.body(cx))
            .child(
                div()
                    .flex_none()
                    .px(px(12.))
                    .pt(px(6.))
                    .child(self.composer.clone()),
            )
            .child(
                div()
                    .h(px(28.))
                    .flex_none()
                    .px(px(16.))
                    .flex()
                    .items_center()
                    .gap(px(16.))
                    .text_size(px(m.small))
                    .text_color(r.text_subtle)
                    .child(hint("\u{21a9}", l10n.desktop_quick_ask_ask()))
                    .child(hint(ESC_KEYCAP, l10n.close()))
                    .child(div().flex_1())
                    .children(footer_note.map(|n| {
                        div()
                            .id("quick-ask-notice")
                            .role(Role::Status)
                            .aria_label(SharedString::from(n.clone()))
                            .truncate()
                            .child(SharedString::from(n))
                    })),
            )
            .child(crate::views::chat::inline_web::frame_end())
    }
}

/// The account in charge of the chats and whether it has a session.
fn scope_of(stores: &Stores, cx: &App) -> (Option<String>, bool) {
    let accounts = stores.accounts.read(cx);
    let session = if accounts.libre_chat_in_charge() {
        accounts.libre_chat_active().is_some() && accounts.libre_chat_needs_sign_in().is_none()
    } else {
        accounts.active().is_some_and(|a| a.has_session)
    };
    (accounts.scope_key(), session)
}

#[cfg(test)]
mod tests {
    use super::*;
    use conduit_components::theme::{ConduitTheme, DesignPrefs, composite};

    #[test]
    fn the_dark_panel_is_the_ramps_neutral_grey_over_any_material() {
        let t = ConduitTheme::new("conduit", true, DesignPrefs::default(), gpui_kit::black());
        // The HUD material over a blue desktop (what r3's #1C1F26 showed).
        for material in [0x2A3040, 0x1C2230, 0x404040] {
            let shown: gpui_kit::Rgba =
                composite(panel_tint(&t), gpui_kit::rgb(material).into()).into();
            let level = |v: f32| (v * 255.).round();
            let (red, green, blue) = (level(shown.r), level(shown.g), level(shown.b));
            assert!(
                blue - red <= 2. && (red - 24.).abs() <= 3.,
                "{material:06x}: {red} {green} {blue}"
            );
        }
    }

    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    use conduit_protocol::methods;
    use gpui_kit::{TestAppContext, VisualTestContext};

    use crate::stores::accounts::tests::{account, list};
    use crate::stores::composer::{Attachment, UploadState};
    use crate::stores::rpc::fake::FakeDaemon;

    fn bench(
        cx: &mut TestAppContext,
    ) -> (
        FakeDaemon,
        Stores,
        Entity<QuickAskView>,
        &mut VisualTestContext,
    ) {
        let daemon = FakeDaemon::new();
        // Each chat's list answers with a model to name.
        daemon.on::<methods::ModelsList>(|_| {
            Ok(serde_json::json!({
                "models": [{"id": "k", "name": "Kestrel", "pinned": false, "capabilities": []}],
                "selectedId": "k",
            }))
        });
        let scratch =
            std::env::temp_dir().join(format!("conduit-quick-ask-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
        });
        let settings =
            cx.new(|_| SettingsStore::load(scratch.join("prefs.json"), false, vec!["en".into()]));
        let s = stores.clone();
        let (view, vcx) =
            cx.add_window_view(move |window, cx| QuickAskView::new(s, settings, window, cx));
        (daemon, stores, view, vcx)
    }

    fn uploaded(name: &str) -> Attachment {
        Attachment::uploaded_for_test(0, name, &format!("file-{name}"))
    }

    /// The panel's text follows the text size and its answers are read
    /// aloud: ⌘+ and ⌘. reach it while they would act (no handler on the
    /// app answers them). A change made elsewhere while it stays open
    /// (Settings, the main window, a reading that starts or ends) is
    /// followed at once.
    #[gpui_kit::test]
    fn the_zoom_keys_and_stop_speaking_reach_quick_ask_while_they_act(cx: &mut TestAppContext) {
        use conduit_protocol::{SpeechProgress, SpeechState, SpeechStatus};

        use crate::actions::{ActualSize, StopSpeaking, ZoomIn, ZoomOut};
        use crate::menus::appkit_enables;
        use crate::prefs::TEXT_SIZE_MAX;
        let (daemon, stores, view, vcx) = bench(cx);
        vcx.cx.update(crate::register_actions);
        // Shown: the caret in the composer.
        view.update_in(vcx, |v, window, cx| v.focus_composer(window, cx));
        vcx.run_until_parked();
        assert!(appkit_enables(vcx, &ZoomIn), "⌘+ is off in Quick Ask");
        assert!(
            !appkit_enables(vcx, &ActualSize),
            "⌘0 is on at the actual size"
        );

        // Elsewhere: the largest size.
        let settings = view.read_with(vcx, |v, _| v.settings.clone());
        settings.update(vcx, |s, cx| {
            s.set_appearance(|a| a.text_size = Some(TEXT_SIZE_MAX), cx)
        });
        vcx.run_until_parked();
        assert!(
            !appkit_enables(vcx, &ZoomIn),
            "⌘+ is on at the largest size, set elsewhere"
        );
        assert!(
            appkit_enables(vcx, &ActualSize),
            "⌘0 is off, the size set elsewhere"
        );
        vcx.dispatch_action(ZoomOut);
        vcx.run_until_parked();
        assert_eq!(
            settings.read_with(vcx, |s, _| s.prefs.appearance.text_size),
            Some(TEXT_SIZE_MAX - 1.),
            "⌘− did not step the text size"
        );

        // Elsewhere: a reading starts, then ends.
        assert!(
            !appkit_enables(vcx, &StopSpeaking),
            "⌘. is on with nothing read"
        );
        let state = |status, message: Option<&str>, reading| SpeechState {
            progress: SpeechProgress {
                status,
                reading,
                message_id: message.map(String::from),
                ..Default::default()
            },
            sentences: vec![],
        };
        daemon.returns::<methods::SpeechGet>(state(SpeechStatus::Speaking, Some("answer-1"), 1));
        stores.speech.update(vcx, |s, cx| s.refresh(cx));
        vcx.run_until_parked();
        assert!(
            appkit_enables(vcx, &StopSpeaking),
            "⌘. is off while a reading started elsewhere"
        );
        daemon.returns::<methods::SpeechGet>(state(SpeechStatus::Idle, None, 1));
        stores.speech.update(vcx, |s, cx| s.refresh(cx));
        vcx.run_until_parked();
        assert!(
            !appkit_enables(vcx, &StopSpeaking),
            "⌘. is on after the reading ended elsewhere"
        );
    }

    #[gpui_kit::test]
    fn a_file_still_uploading_is_never_left_behind(cx: &mut TestAppContext) {
        let (daemon, _stores, view, vcx) = bench(cx);
        let mut uploading = uploaded("big.pdf");
        uploading.state = UploadState::Uploading { sent: 1, total: 3 };
        let opened = Rc::new(std::cell::Cell::new(false));
        let seen = opened.clone();
        let _sub = vcx.update(|_, cx| {
            cx.subscribe(&view, move |_, e: &QuickAskEvent, _| {
                if matches!(e, QuickAskEvent::OpenDraft { .. }) {
                    seen.set(true);
                }
            })
        });
        view.update_in(vcx, |v, window, cx| {
            v.composer_store
                .update(cx, |c, cx| c.adopt_attachments(vec![uploading], cx));
            v.composer
                .update(cx, |c, cx| c.set_text("Read this", window, cx));
            // Open in Conduit while it uploads: nothing moves.
            v.open_in_conduit(window, cx);
            // A follow-up from the transcript waits in the field.
            v.composer.update(cx, |c, cx| c.set_text("", window, cx));
            v.send_text("Follow up".into(), vec![], window, cx);
        });
        vcx.run_until_parked();
        assert!(!opened.get(), "the draft left without its file");
        assert!(daemon.calls::<methods::TurnsSend>().is_empty());
        view.read_with(vcx, |v, cx| {
            assert_eq!(v.composer_store.read(cx).attachments.len(), 1);
            assert_eq!(v.composer.read(cx).text(cx), "Follow up");
        });
    }

    #[gpui_kit::test]
    fn another_account_or_a_sign_out_leaves_nothing_of_the_last_one(cx: &mut TestAppContext) {
        let (_daemon, stores, view, vcx) = bench(cx);
        let fill = |view: &Entity<QuickAskView>, vcx: &mut VisualTestContext| {
            view.update_in(vcx, |v, window, cx| {
                v.open_chat("chat-a".into(), window, cx);
                v.composer
                    .update(cx, |c, cx| c.set_text("draft for A", window, cx));
                v.composer_store
                    .update(cx, |c, cx| c.adopt_attachments(vec![uploaded("a.txt")], cx));
            });
        };
        let empty = |view: &Entity<QuickAskView>, vcx: &mut VisualTestContext| {
            view.read_with(vcx, |v, cx| {
                assert!(v.chat.is_none());
                assert_eq!(v.composer.read(cx).text(cx), "");
                assert!(v.composer_store.read(cx).attachments.is_empty());
            });
        };
        fill(&view, vcx);
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
        empty(&view, vcx);
        // Signed out of B.
        fill(&view, vcx);
        stores.accounts.update(vcx, |a, cx| {
            a.adopt(
                list(vec![
                    account("a", "Avery", false, true),
                    account("b", "Blake", true, false),
                ]),
                cx,
            )
        });
        vcx.run_until_parked();
        empty(&view, vcx);
    }

    /// New Chat's agent, shown in Quick Ask, taken by the main window's first
    /// send: the daemon says the models changed, and New Chat's next list
    /// (a newer revision, never 0) is shown, so Quick Ask no longer names
    /// the pick that went.
    #[gpui_kit::test]
    fn a_new_chat_pick_taken_elsewhere_leaves_quick_ask(cx: &mut TestAppContext) {
        let (daemon, _stores, view, vcx) = bench(cx);
        let agent = "agent:north:codex:gpt-test";
        let list = move |selected: &str, revision: i64| {
            serde_json::json!({
                "models": [{"id": "k", "name": "Kestrel", "pinned": false, "capabilities": []}],
                "agents": [{"id": agent, "name": "Codex", "pinned": false, "capabilities": []}],
                "selectedId": selected,
                "revision": revision,
            })
        };
        let taken = Arc::new(AtomicBool::new(false));
        let seen = taken.clone();
        daemon.on::<methods::ModelsList>(move |_| {
            Ok(if seen.load(Ordering::SeqCst) {
                list("k", 6)
            } else {
                list(agent, 4)
            })
        });
        daemon.on::<methods::ComposerOptions>(|_| Ok(serde_json::json!({})));
        view.update(vcx, |v, cx| {
            v.composer_store.update(cx, |c, cx| c.refresh_models(cx))
        });
        vcx.run_until_parked();
        let next = |view: &Entity<QuickAskView>, vcx: &mut VisualTestContext| {
            view.read_with(vcx, |v, cx| {
                v.composer_store.read(cx).next_model().map(|m| m.id.clone())
            })
        };
        assert_eq!(next(&view, vcx).as_deref(), Some(agent));
        // The main window's first send took it.
        taken.store(true, Ordering::SeqCst);
        view.update(vcx, |v, cx| {
            v.on_connection(&ConnectionEvent::Daemon(Box::new(Event::ModelsChanged)), cx)
        });
        vcx.run_until_parked();
        assert_eq!(next(&view, vcx).as_deref(), Some("k"));
    }

    /// Quick Ask's first message made a chat: its composer follows that
    /// chat, so the next message names the agent the chat was started with
    /// (the daemon's answer for the chat), never New Chat's regular model.
    /// The chat's list is asked for once, and until it answers a follow-up
    /// from the transcript waits in the field.
    #[gpui_kit::test]
    fn a_follow_up_names_the_agent_its_chat_started_with(cx: &mut TestAppContext) {
        let (daemon, _stores, view, vcx) = bench(cx);
        let agent = "agent:north:codex:gpt-test";
        let list = move |selected: &str| {
            serde_json::json!({
                "models": [{"id": "k", "name": "Kestrel", "pinned": false, "capabilities": []}],
                "agents": [{"id": agent, "name": "Codex", "pinned": false, "capabilities": []}],
                "selectedId": selected,
            })
        };
        // New Chat's pick went to the chat the first message made.
        daemon.on::<methods::ModelsList>(move |q| {
            Ok(list(if q["chatId"] == "chat-q" { agent } else { "k" }))
        });
        daemon.on::<methods::ModelsSelect>(move |_| Ok(list(agent)));
        daemon.on::<methods::ComposerOptions>(|_| Ok(serde_json::json!({})));
        daemon.returns::<methods::ChatsGet>(
            serde_json::from_value(serde_json::json!({"chat": {
                "summary": {"id": "chat-q", "title": "Quick", "updatedAtMs": 1,
                    "pinned": false, "archived": false, "tags": [], "shared": false,
                    "readOnly": false},
                "messages": [], "readOnly": false
            }}))
            .unwrap(),
        );
        daemon.on::<methods::TurnsSend>(|_| {
            Ok(serde_json::json!({
                "chatId": "chat-q", "userMessageId": "u1", "assistantMessageId": "a1"
            }))
        });
        view.update(vcx, |v, cx| {
            v.composer_store.update(cx, |c, cx| c.refresh_models(cx))
        });
        vcx.run_until_parked();
        view.update(vcx, |v, cx| {
            v.composer_store
                .update(cx, |c, cx| c.select_model(agent, cx))
        });
        vcx.run_until_parked();
        let listing = daemon.hold::<methods::ModelsList>();
        view.update_in(vcx, |v, window, cx| {
            v.send_text("First".into(), vec![], window, cx)
        });
        vcx.run_until_parked();
        view.update_in(vcx, |v, window, cx| {
            v.send_text("Then this".into(), vec![], window, cx)
        });
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::TurnsSend>().len(), 1);
        view.read_with(vcx, |v, cx| {
            assert_eq!(v.composer.read(cx).text(cx), "Then this")
        });
        listing.release();
        vcx.run_until_parked();
        let lists = daemon.calls::<methods::ModelsList>();
        let chat_lists = lists.iter().filter(|q| q["chatId"] == "chat-q").count();
        assert_eq!(chat_lists, 1, "{lists:?}");
        view.update_in(vcx, |v, window, cx| {
            v.composer.update(cx, |c, cx| c.set_text("", window, cx));
            v.send_text("Then this".into(), vec![], window, cx)
        });
        vcx.run_until_parked();
        let sends = daemon.calls::<methods::TurnsSend>();
        assert_eq!(sends.len(), 2, "{sends:?}");
        assert_eq!(sends[0]["model"], agent);
        assert_eq!(
            sends[1]["model"], agent,
            "the follow-up left the chat's agent"
        );
    }

    #[gpui_kit::test]
    fn a_failed_send_in_its_chat_gives_nothing_back_after_new_chat(cx: &mut TestAppContext) {
        let (daemon, _stores, view, vcx) = bench(cx);
        daemon.returns::<methods::ChatsGet>(
            serde_json::from_value(serde_json::json!({"chat": {
                "summary": {"id": "chat-q", "title": "Quick", "updatedAtMs": 1,
                    "pinned": false, "archived": false, "tags": [], "shared": false,
                    "readOnly": false},
                "messages": [], "readOnly": false
            }}))
            .unwrap(),
        );
        daemon.on::<methods::TurnsSend>(|_| {
            Err(conduit_daemon::protocol::error("rpc.timeout", "slow"))
        });
        view.update_in(vcx, |v, window, cx| {
            v.open_chat("chat-q".into(), window, cx);
        });
        vcx.run_until_parked();
        let held = daemon.hold::<methods::TurnsSend>();
        view.update_in(vcx, |v, window, cx| {
            v.composer_store
                .update(cx, |c, cx| c.adopt_attachments(vec![uploaded("q.txt")], cx));
            v.send_text("In the chat".into(), vec![], window, cx);
            v.new_chat(window, cx);
        });
        held.release();
        vcx.run_until_parked();
        view.read_with(vcx, |v, cx| {
            assert!(v.composer_store.read(cx).attachments.is_empty());
            assert_eq!(v.composer.read(cx).text(cx), "");
        });
    }

    #[gpui_kit::test]
    fn a_failed_first_send_gives_nothing_back_after_another_account(cx: &mut TestAppContext) {
        let (daemon, stores, view, vcx) = bench(cx);
        daemon.on::<methods::TurnsSend>(|_| {
            Err(conduit_daemon::protocol::error("rpc.timeout", "slow"))
        });
        let held = daemon.hold::<methods::TurnsSend>();
        view.update_in(vcx, |v, window, cx| {
            v.composer_store.update(cx, |c, cx| {
                c.adopt_attachments(vec![uploaded("first.txt")], cx)
            });
            v.send_text("First".into(), vec![], window, cx);
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
        held.release();
        vcx.run_until_parked();
        view.read_with(vcx, |v, cx| {
            assert!(v.composer_store.read(cx).attachments.is_empty());
            assert_eq!(v.composer.read(cx).text(cx), "");
        });
    }

    #[gpui_kit::test]
    fn new_chat_drops_a_first_send_still_on_its_way(cx: &mut TestAppContext) {
        let (daemon, _stores, view, vcx) = bench(cx);
        daemon.returns::<methods::TurnsSend>(
            serde_json::from_value(serde_json::json!({
                "chatId": "chat-late",
                "userMessageId": "m",
                "assistantMessageId": "a",
            }))
            .unwrap(),
        );
        let held = daemon.hold::<methods::TurnsSend>();
        view.update_in(vcx, |v, window, cx| {
            v.composer_store.update(cx, |c, cx| {
                c.adopt_attachments(vec![uploaded("old.txt")], cx)
            });
            v.send_text("hello".into(), vec![], window, cx);
            v.composer_store.update(cx, |c, cx| {
                c.adopt_attachments(vec![uploaded("next.txt")], cx)
            });
            v.new_chat(window, cx);
        });
        held.release();
        vcx.run_until_parked();
        view.read_with(vcx, |v, cx| {
            assert!(v.chat.is_none(), "the late reply opened its chat");
            assert!(v.composer_store.read(cx).attachments.is_empty());
        });
    }

    /// Another account while the panel shows a chat: that chat goes with
    /// the account it belongs to, and nothing of it is read in the new one.
    #[gpui_kit::test]
    fn another_account_reads_nothing_of_the_last_ones_chat(cx: &mut TestAppContext) {
        let (daemon, stores, view, vcx) = bench(cx);
        let listed: conduit_protocol::ChatList = serde_json::from_value(serde_json::json!({
            "chats": [{"id": "chat-q", "title": "Tide times", "updatedAtMs": 1, "unread": true}],
        }))
        .unwrap();
        daemon.returns::<methods::ChatsList>(listed.clone());
        daemon.returns::<methods::ChatsMarkUnread>(listed);
        stores.chat_list.update(vcx, |c, cx| c.refresh(cx));
        view.update_in(vcx, |v, window, cx| {
            v.set_shown(true, cx);
            v.open_chat("chat-q".into(), window, cx);
        });
        vcx.run_until_parked();

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
        assert!(
            daemon.calls::<methods::ChatsMarkUnread>().is_empty(),
            "the last account's chat was read in the new one"
        );
    }

    /// An answer read in the panel leaves its chat read: the panel reads
    /// the chat it shows as it hides, as it is shown again, as it starts a
    /// new chat, and as the app quits. Hidden, it reads nothing.
    #[gpui_kit::test]
    fn the_panel_reads_its_chat_as_it_stops_showing_it(cx: &mut TestAppContext) {
        let (daemon, stores, view, vcx) = bench(cx);
        // Their answers finished in the panel: the sidebar has their dots.
        let listed: conduit_protocol::ChatList = serde_json::from_value(serde_json::json!({
            "chats": [
                {"id": "chat-q", "title": "Tide times", "updatedAtMs": 1, "unread": true},
                {"id": "chat-r", "title": "Moon phases", "updatedAtMs": 1, "unread": true},
            ],
        }))
        .unwrap();
        daemon.returns::<methods::ChatsList>(listed.clone());
        daemon.returns::<methods::ChatsMarkUnread>(listed);
        stores.chat_list.update(vcx, |c, cx| c.refresh(cx));
        let reads = || daemon.calls::<methods::ChatsMarkUnread>();
        let read_q = serde_json::json!({"chatId": "chat-q", "unread": false});

        view.update_in(vcx, |v, window, cx| {
            v.set_shown(true, cx);
            v.open_chat("chat-q".into(), window, cx);
        });
        vcx.run_until_parked();
        view.update(vcx, |v, cx| v.set_shown(false, cx));
        vcx.run_until_parked();
        assert_eq!(
            reads(),
            vec![read_q.clone()],
            "hiding did not read the chat"
        );
        view.update(vcx, |v, cx| v.set_shown(false, cx));
        assert!(view.update(vcx, |v, cx| v.leave_on_quit(cx)).is_none());
        vcx.run_until_parked();
        assert_eq!(reads().len(), 1, "the hidden panel read its chat");

        // Its next answer finishes while the panel is hidden: shown again,
        // the chat is read as an opened one is.
        stores.chat_list.update(vcx, |c, cx| c.refresh(cx));
        vcx.run_until_parked();
        view.update(vcx, |v, cx| v.set_shown(true, cx));
        vcx.run_until_parked();
        assert_eq!(reads().len(), 2, "the chat shown again was not read");

        // Another finishes while it shows, then a new chat starts there.
        stores.chat_list.update(vcx, |c, cx| c.refresh(cx));
        vcx.run_until_parked();
        view.update_in(vcx, |v, window, cx| v.new_chat(window, cx));
        vcx.run_until_parked();
        assert_eq!(reads().len(), 3, "a new chat did not read the chat left");

        view.update_in(vcx, |v, window, cx| {
            v.open_chat("chat-r".into(), window, cx)
        });
        vcx.run_until_parked();
        let (id, read) = view
            .update(vcx, |v, cx| v.leave_on_quit(cx))
            .expect("quitting did not read the chat on screen");
        assert_eq!(id, "chat-r");
        assert!(vcx.foreground_executor().block_test(read).is_ok());
        assert_eq!(
            reads().last(),
            Some(&serde_json::json!({"chatId": "chat-r", "unread": false}))
        );
    }

    /// The daemon hears which chat the panel shows on screen, each time
    /// that changes, so the core reads what changes in it meanwhile: none
    /// while it is hidden, or once a new chat starts there.
    #[gpui_kit::test]
    fn the_daemon_hears_which_chat_the_panel_shows(cx: &mut TestAppContext) {
        let (daemon, stores, view, vcx) = bench(cx);
        daemon.returns::<methods::ChatsSetShown>(conduit_protocol::OkResult { ok: true });
        stores.chat_list.update(vcx, |c, cx| c.refresh(cx));
        let shows_q = serde_json::json!({"view": "quickAsk", "chatId": "chat-q"});
        let shows_none = serde_json::json!({"view": "quickAsk"});

        view.update_in(vcx, |v, window, cx| {
            v.set_shown(true, cx);
            v.open_chat("chat-q".into(), window, cx);
        });
        vcx.run_until_parked();
        view.update(vcx, |v, cx| v.set_shown(false, cx));
        view.update(vcx, |v, cx| v.set_shown(true, cx));
        vcx.run_until_parked();
        view.update_in(vcx, |v, window, cx| v.new_chat(window, cx));
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::ChatsSetShown>(),
            vec![
                shows_q.clone(),
                shows_none.clone(),
                shows_q.clone(),
                shows_none.clone()
            ],
            "the daemon heard another chat on screen than the panel shows"
        );
    }

    /// The panel hidden with the app (⌘H), minimized or fully covered shows
    /// nothing: the daemon hears no chat on screen until the panel is
    /// visible again. #1220's reads on hiding and showing it are its own.
    #[gpui_kit::test]
    fn a_panel_the_platform_hides_shows_no_chat(cx: &mut TestAppContext) {
        let (daemon, stores, view, vcx) = bench(cx);
        daemon.returns::<methods::ChatsSetShown>(conduit_protocol::OkResult { ok: true });
        stores.chat_list.update(vcx, |c, cx| c.refresh(cx));
        view.update_in(vcx, |v, window, cx| {
            v.set_shown(true, cx);
            v.open_chat("chat-q".into(), window, cx);
        });
        vcx.run_until_parked();
        let reads = daemon.calls::<methods::ChatsMarkUnread>().len();

        vcx.simulate_visibility_change(gpui_kit::WindowVisibility::Hidden);
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::ChatsSetShown>().last(),
            Some(&serde_json::json!({"view": "quickAsk"})),
            "the hidden panel's chat stayed on screen"
        );
        vcx.simulate_visibility_change(gpui_kit::WindowVisibility::Visible);
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::ChatsSetShown>().last(),
            Some(&serde_json::json!({"view": "quickAsk", "chatId": "chat-q"})),
            "the panel visible again did not show its chat"
        );
        assert_eq!(daemon.calls::<methods::ChatsMarkUnread>().len(), reads);
    }

    /// A Services selection never takes the place of what the user left in
    /// Quick Ask, and never joins it: words, files (sent up or still on
    /// their way) all stay as they were, with no selection among them.
    #[gpui_kit::test]
    fn a_services_selection_leaves_an_unsent_draft_as_it_is(cx: &mut TestAppContext) {
        let (_daemon, _stores, view, vcx) = bench(cx);
        view.update_in(vcx, |v, window, cx| {
            v.composer
                .update(cx, |c, cx| c.set_text("Draft for later", window, cx));
            let _ = v.ask_about("> Prune in late winter.", window, cx);
        });
        view.read_with(vcx, |v, cx| {
            assert_eq!(v.composer.read(cx).text(cx), "Draft for later");
        });
        let mut on_its_way = uploaded("orchard.pdf");
        on_its_way.state = UploadState::Uploading { sent: 1, total: 3 };
        for file in [uploaded("plan.pdf"), on_its_way] {
            view.update_in(vcx, |v, window, cx| {
                v.composer.update(cx, |c, cx| c.set_text("", window, cx));
                v.composer_store
                    .update(cx, |c, cx| c.adopt_attachments(vec![file], cx));
                let _ = v.ask_about("> Prune in late winter.", window, cx);
            });
            view.read_with(vcx, |v, cx| {
                assert_eq!(
                    v.composer.read(cx).text(cx),
                    "",
                    "the selection joined old files"
                );
                assert_eq!(v.composer_store.read(cx).attachments.len(), 1);
            });
            view.update_in(vcx, |v, _, cx| {
                v.composer_store.update(cx, |c, cx| c.reset(cx))
            });
        }
    }

    /// While a first send is on its way the panel is the user's: the
    /// selection doesn't wait in its composer for that send's chat.
    #[gpui_kit::test]
    fn a_services_selection_during_a_first_send_stays_out_of_its_chat(cx: &mut TestAppContext) {
        let (daemon, _stores, view, vcx) = bench(cx);
        daemon.returns::<methods::TurnsSend>(
            serde_json::from_value(serde_json::json!({
                "chatId": "chat-first",
                "userMessageId": "m",
                "assistantMessageId": "a",
            }))
            .unwrap(),
        );
        vcx.run_until_parked();
        let held = daemon.hold::<methods::TurnsSend>();
        view.update_in(vcx, |v, window, cx| {
            v.send_text("First question".into(), vec![], window, cx);
            let _ = v.ask_about("> Prune in late winter.", window, cx);
        });
        held.release();
        vcx.run_until_parked();
        view.read_with(vcx, |v, cx| {
            assert_eq!(v.composer.read(cx).text(cx), "");
        });
    }

    /// An idle panel (an exchange on screen, nothing typed) takes the
    /// selection in a fresh exchange, with nothing else in it.
    #[gpui_kit::test]
    fn a_services_selection_in_an_idle_panel_starts_a_fresh_exchange(cx: &mut TestAppContext) {
        let (_daemon, _stores, view, vcx) = bench(cx);
        view.update_in(vcx, |v, window, cx| {
            v.open_chat("chat-q".into(), window, cx);
            let _ = v.ask_about("> Prune in late winter.", window, cx);
        });
        view.read_with(vcx, |v, cx| {
            assert!(v.chat.is_none());
            assert_eq!(v.composer.read(cx).text(cx), "> Prune in late winter.");
            assert!(v.composer_store.read(cx).attachments.is_empty());
        });
    }

    /// Its model list fails on a new daemon session: the panel says so,
    /// and Send or the model picker asks for the list again, keeping the
    /// words typed.
    #[gpui_kit::test]
    fn a_failed_model_list_says_so_and_send_asks_again(cx: &mut TestAppContext) {
        let (daemon, _stores, view, vcx) = bench(cx);
        vcx.run_until_parked();
        let fail = |daemon: &FakeDaemon| {
            daemon.once::<methods::ModelsList>(Err(conduit_daemon::protocol::error(
                "rpc.daemonUnavailable",
                "busy",
            )));
        };
        fail(&daemon);
        view.update(vcx, |v, cx| {
            v.composer_store.update(cx, |c, cx| c.reconnected(cx))
        });
        vcx.run_until_parked();
        let failed = vcx.update(|_, cx| cx.l10n().desktop_model_not_selected());
        view.read_with(vcx, |v, _| {
            assert_eq!(v.notice.as_deref(), Some(failed.as_str()))
        });
        let asked = || daemon.calls::<methods::ModelsList>().len();
        let before = asked();
        // Send while it fails again, then the picker.
        fail(&daemon);
        view.update_in(vcx, |v, window, cx| {
            v.composer.update(cx, |c, cx| {
                c.set_text("Pack the bags", window, cx);
                c.submit(window, cx)
            })
        });
        vcx.run_until_parked();
        assert_eq!(asked(), before + 1);
        view.update_in(vcx, |v, window, cx| {
            v.composer.update(cx, |c, cx| c.open_picker(window, cx))
        });
        vcx.run_until_parked();
        assert_eq!(asked(), before + 2);
        assert!(daemon.calls::<methods::TurnsSend>().is_empty());
        view.read_with(vcx, |v, cx| {
            assert_eq!(v.composer.read(cx).text(cx), "Pack the bags");
            assert!(v.composer_store.read(cx).can_name_model());
        });
    }

    /// Words the core gives the chat Quick Ask holds (Hermes' prefill) land
    /// in its field; another chat's do not.
    #[gpui_kit::test]
    fn a_prefill_for_its_chat_lands_in_the_panel(cx: &mut TestAppContext) {
        let (_daemon, _stores, view, vcx) = bench(cx);
        let given = |chat: &str, text: &str| {
            ConnectionEvent::Daemon(Box::new(Event::ComposerInsertText(
                conduit_protocol::ComposerInsertText {
                    chat_id: chat.into(),
                    text: text.into(),
                },
            )))
        };
        view.update_in(vcx, |v, window, cx| {
            v.open_chat("chat-q".into(), window, cx)
        });
        vcx.run_until_parked();
        view.update(vcx, |v, cx| {
            v.on_connection(&given("chat-other", "/skip "), cx);
            v.on_connection(&given("chat-q", "/plan "), cx);
        });
        vcx.run_until_parked();
        view.read_with(vcx, |v, cx| {
            assert_eq!(v.composer.read(cx).text(cx), "/plan ")
        });
    }
}
