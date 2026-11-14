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
use conduit_protocol::{Event, events, methods};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Context, Entity, FocusHandle, Focusable, KeyDownEvent, Role, SharedString,
    Subscription, Window, div, px,
};

use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::stores::chat::{CHAT_EVENTS, ChatStore, PendingMessage, Subscribe};
use crate::stores::composer::{ComposerEvent, ComposerPrefs, ComposerStore};
use crate::stores::connection::ConnectionEvent;
use crate::stores::router::RouterEvent;
use crate::stores::session::Route;
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
    pub composer_store: Entity<ComposerStore>,
    pub composer: Entity<ChatComposer>,
    pub chat: Option<QuickChat>,
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
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let rpc = stores.connection.read(cx).rpc();
        let composer_store = cx.new(|_| ComposerStore::new(rpc, Some(daemon_uploader())));
        // Settings › Chat's choices (Send with Enter, quick pills, Save as
        // Note), kept as they change.
        let prefs = ComposerPrefs::from_settings(stores.app_settings.read(cx).settings());
        composer_store.update(cx, |c, cx| c.set_prefs(prefs, cx));
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
                    ComposerEvent::DraftSwitched | ComposerEvent::DraftLoaded { .. } => return,
                });
                cx.notify();
            }),
        ];
        let scope = scope_of(&stores, cx);
        let mut this = Self {
            stores,
            composer_store,
            composer,
            chat: None,
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

    /// New chat: drops this exchange (the chat stays in the sidebar), the
    /// draft and its attachments.
    pub fn new_chat(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.clear(window, cx);
        self.composer_store.update(cx, |c, cx| c.start_over(cx));
        self.composer.update(cx, |c, cx| c.focus_input(window, cx));
    }

    /// Another account: drops everything of the last one's, the composer's
    /// models, options and attachments included.
    fn forget(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.clear(window, cx);
        self.composer_store.update(cx, |c, cx| c.reset(cx));
        self.composer.update(cx, |c, cx| c.forget_account(cx));
    }

    fn clear(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.generation += 1;
        self.chat = None;
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
                self.composer_store.update(cx, |c, cx| c.refresh_models(cx));
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
        let composer = self.composer_store.read(cx);
        let ready = !on && composer.selected_model().is_some() && composer.options.voice_call;
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

    fn open_chat(&mut self, id: String, cx: &mut Context<Self>) -> Entity<ChatStore> {
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
        let subscriptions = vec![cx.observe(&store, |this, store, cx| {
            let streaming = store.read(cx).is_streaming();
            this.composer.update(cx, |c, cx| {
                if c.streaming != streaming {
                    c.streaming = streaming;
                    cx.notify();
                }
            });
            cx.notify();
        })];
        self.chat = Some(QuickChat {
            store: store.clone(),
            transcript,
            _subscriptions: subscriptions,
        });
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
        // go without it: it waits in the field instead.
        if (self.chat.is_none() && self.starting) || self.composer_store.read(cx).uploading() {
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
                        let store = this.open_chat(accepted.chat_id.clone(), cx);
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
                    }
                }
                this.composer_store.update(cx, |m, cx| m.refresh_models(cx));
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
            let edges = div();
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
        let scratch =
            std::env::temp_dir().join(format!("conduit-quick-ask-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
        });
        let s = stores.clone();
        let (view, vcx) = cx.add_window_view(move |window, cx| QuickAskView::new(s, window, cx));
        (daemon, stores, view, vcx)
    }

    fn uploaded(name: &str) -> Attachment {
        Attachment::uploaded_for_test(0, name, &format!("file-{name}"))
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
                v.open_chat("chat-a".into(), cx);
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
        view.update(vcx, |v, cx| {
            v.open_chat("chat-q".into(), cx);
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
            v.open_chat("chat-q".into(), cx);
            let _ = v.ask_about("> Prune in late winter.", window, cx);
        });
        view.read_with(vcx, |v, cx| {
            assert!(v.chat.is_none());
            assert_eq!(v.composer.read(cx).text(cx), "> Prune in late winter.");
            assert!(v.composer_store.read(cx).attachments.is_empty());
        });
    }
}
