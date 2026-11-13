//! The macOS shell extras, wired into the app:
//!
//! * **Links and "Open with"**: `on_open_urls` hands over `conduit://`
//!   links and `file://` URLs (cold launch included). They queue in the
//!   [`ShellStore`] until the main window exists and the session routes to
//!   Main, then [`dispatch`] opens them: a chat (`navigation.open`), a new
//!   chat with the composer prefilled (text, or files attached through the
//!   composer's upload path; at most 10, each up to 256 MB), a Settings
//!   tab, or a toast for channels and notes (not opened here yet).
//! * **Answer notifications** on `turn.finished`, unless the chat is in
//!   front of the user ([`notify::decide`]). Permission is asked the first
//!   time the setting is turned on or a notification would go out. A
//!   click shows the main window on that chat.
//! * **Quick Ask**: a `PopUp` window ([`QuickAskView`]) placed on the
//!   display under the pointer, shown by the global shortcut, the menu-bar
//!   item or Window › Quick Ask, hidden on Esc or when it loses focus to
//!   another app or the main window.
//! * **Menu-bar item** while "Close to menu bar" is on; closing the main
//!   window then hides it, and the menu, the Dock or a link shows it again.
//! * **Open at login** (`SMAppService.mainApp`); a login launch (or
//!   `--hidden`) with "Close to menu bar" on starts with the menu-bar item
//!   only.
//! * **The desktop widget** (WidgetKit): its snapshot of the newest chats
//!   follows the session, the chat list and the language ([`WidgetFeed`]),
//!   and its links (`quick-ask`, `call`) arrive with the others.
//!
//! Everything here runs on the main thread; the platform calls live in
//! [`crate::shell`], and their outcomes go to the [`ShellStore`] for
//! Settings › Desktop to show.

use std::path::PathBuf;
use std::time::Duration;

use conduit_components::window as cw;
use conduit_protocol::{Event, NoticeLevel, TurnFinished, events};
use futures::StreamExt as _;
use futures::channel::mpsc;
use gpui_kit::{AnyWindowHandle, App, AppContext as _, Bounds, Entity, Global, px, size};

use crate::AppState;
use crate::l10n::ActiveL10n as _;
use crate::shell::deep_link::{self, OpenRequest};
use crate::shell::notify::{self, NotificationKind, OnScreen};
use crate::shell::open_files;
use crate::shell::widget::{self, Snapshot};
use crate::stores::connection::ConnectionEvent;
use crate::stores::navigation::{Area, AreaItem};
use crate::stores::session::Route;
use crate::stores::settings::SettingsEvent;
use crate::stores::shell::{HotkeyState, LoginState, NotificationAccess, ShellStore};
use crate::views::quick_ask::{QuickAskEvent, QuickAskView};
use crate::views::settings::Tab;
#[cfg(target_os = "macos")]
use conduit_components::motion::specs;

/// The connection subscription key for answer notifications.
pub const NOTIFICATIONS_KEY: &str = "notifications";

/// URLs from `on_open_urls`, which runs before the app (and its state)
/// may exist; the app drains them once it can act.
pub type UrlSender = mpsc::UnboundedSender<Vec<String>>;
pub type UrlReceiver = mpsc::UnboundedReceiver<Vec<String>>;

pub fn url_channel() -> (UrlSender, UrlReceiver) {
    mpsc::unbounded()
}

/// The shell extras' long-lived objects.
pub struct Desktop {
    pub shell: Entity<ShellStore>,
    pub quick_ask: Option<(AnyWindowHandle, Entity<QuickAskView>)>,
    /// "Notify when an answer finishes" as last applied: permission is
    /// asked when it turns on, not on every Settings › Desktop change.
    notify_answers: bool,
    pub widget: WidgetFeed,
    #[cfg(target_os = "macos")]
    platform: Platform,
}

#[cfg(target_os = "macos")]
#[derive(Default)]
struct Platform {
    notifier: Option<crate::shell::notifications::Notifier>,
    hotkey: Option<crate::shell::hotkey::Hotkey>,
    tray: Option<crate::shell::tray::MenuBarItem>,
}

impl Global for Desktop {}

fn shell(cx: &App) -> Option<Entity<ShellStore>> {
    cx.try_global::<Desktop>().map(|d| d.shell.clone())
}

/// The extras' state without any of the services (fixtures): Settings ›
/// Desktop reads the store; no hotkey, menu-bar item or notifier is made.
pub fn install_without_services(cx: &mut App) {
    let shell = cx.new(|_| ShellStore::new());
    cx.set_global(Desktop {
        shell,
        quick_ask: None,
        notify_answers: false,
        widget: WidgetFeed::default(),
        #[cfg(target_os = "macos")]
        platform: Platform::default(),
    });
}

/// Sets the extras up. `urls` carries what `on_open_urls` received;
/// `hidden` is a login launch (or `--hidden`).
pub fn install(urls: UrlReceiver, hidden: bool, cx: &mut App) {
    let shell = cx.new(|_| {
        let mut s = ShellStore::new();
        s.hidden_start = hidden;
        s
    });
    let notify_answers = cx
        .try_global::<AppState>()
        .is_some_and(|s| s.settings.read(cx).prefs.desktop.notify_answers);
    cx.set_global(Desktop {
        shell: shell.clone(),
        quick_ask: None,
        notify_answers,
        widget: WidgetFeed::open(),
        #[cfg(target_os = "macos")]
        platform: Platform::default(),
    });
    #[cfg(target_os = "macos")]
    install_platform(cx);
    apply_settings(cx);

    let Some(state) = cx.try_global::<AppState>() else {
        return;
    };
    let (settings, connection, stores) = (
        state.settings.clone(),
        state.connection.clone(),
        state.stores.clone(),
    );
    cx.subscribe(&settings, |settings, event, cx| match event {
        SettingsEvent::DesktopChanged => {
            apply_settings(cx);
            // The Quick Ask chord beside its item.
            relabel_tray(cx);
            // Turning notifications on asks for permission (if the system
            // hasn't asked yet); other changes don't.
            let now = settings.read(cx).prefs.desktop.notify_answers;
            let before = std::mem::replace(&mut cx.global_mut::<Desktop>().notify_answers, now);
            if now && !before {
                ensure_permission(false, cx);
            }
        }
        // New words, or new chords beside New Chat.
        SettingsEvent::LocaleChanged | SettingsEvent::KeymapChanged => {
            relabel_tray(cx);
            // The widget speaks the app's language.
            schedule_widget(cx);
        }
        _ => {}
    })
    .detach();
    // The menu-bar item shows a voice call.
    #[cfg(target_os = "macos")]
    cx.subscribe(
        &stores.call,
        |_, _: &crate::stores::call::CallChanged, cx| sync_call_tray(cx),
    )
    .detach();
    // The widget's snapshot follows who is signed in and their chats.
    cx.observe(&stores.session, |_, cx| schedule_widget(cx))
        .detach();
    cx.observe(&stores.accounts, |_, cx| schedule_widget(cx))
        .detach();
    cx.observe(&stores.chat_list, |_, cx| schedule_widget(cx))
        .detach();
    // `turn.finished` is unscoped: it comes for chats that are not open.
    // `channels.posted` too: someone else posted in a channel not in front.
    connection.update(cx, |c, _| {
        c.subscribe(
            NOTIFICATIONS_KEY,
            &[events::TURN_FINISHED, events::CHANNELS_POSTED],
            vec![],
        )
    });
    cx.subscribe(&connection, |_, event, cx| {
        let ConnectionEvent::Daemon(event) = event else {
            return;
        };
        match event.as_ref() {
            Event::TurnFinished(finished) => {
                let finished = finished.clone();
                cx.defer(move |cx| on_turn_finished(&finished, cx));
            }
            Event::ChannelsPosted(posted) => {
                let posted = posted.clone();
                cx.defer(move |cx| on_channel_posted(&posted, cx));
            }
            _ => {}
        }
    })
    .detach();
    // Queued links go once the session routes to Main.
    cx.observe(&stores.session, |_, cx| cx.defer(drain))
        .detach();
    cx.observe(&stores.connection, |_, cx| cx.defer(drain))
        .detach();
    refresh_statuses(cx);

    let mut urls = urls;
    cx.spawn(async move |cx| {
        while let Some(batch) = urls.next().await {
            cx.update(|cx| handle_urls(batch, cx));
        }
    })
    .detach();
}

// ── Links and "Open with" ──────────────────────────────────────────────────

/// What `on_open_urls` brought: links and files are queued, the rest is
/// logged and dropped.
pub fn handle_urls(urls: Vec<String>, cx: &mut App) {
    let incoming = deep_link::classify(&urls);
    for ignored in &incoming.ignored {
        log::info!("ignored a link: {}", deep_link::redacted(ignored));
    }
    let Some(shell) = shell(cx) else {
        return;
    };
    for request in incoming.requests {
        log::info!("link: {}", describe(&request));
        shell.update(cx, |s, cx| s.push(request, cx));
    }
    if !incoming.files.is_empty() {
        log::info!("open with: {} file(s)", incoming.files.len());
        shell.update(cx, |s, cx| {
            s.push(
                OpenRequest::NewChat {
                    text: None,
                    files: incoming.files,
                },
                cx,
            )
        });
    }
    // A link brings the main window forward (made again if it was closed,
    // shown if it was closed to the menu bar).
    if shell.read(cx).waits_for_main() {
        show_main(cx);
    }
    drain(cx);
}

/// A request for the log: its kind, never ids, text or file names.
fn describe(request: &OpenRequest) -> &'static str {
    match request {
        OpenRequest::Chat { .. } => "chat",
        OpenRequest::NewChat { files, .. } if !files.is_empty() => "new chat with files",
        OpenRequest::NewChat { .. } => "new chat",
        OpenRequest::Channel { .. } => "channel",
        OpenRequest::Note { .. } => "note",
        OpenRequest::Settings { .. } => "settings",
        OpenRequest::QuickAskDraft { .. } => "quick ask draft",
        OpenRequest::QuickAsk => "quick ask",
        OpenRequest::VoiceCall => "voice call",
    }
}

/// Whether the main window shows the main frame (signed in, routed to
/// Main, nothing blocking).
pub fn main_ready(cx: &App) -> bool {
    let Some(state) = cx.try_global::<AppState>() else {
        return false;
    };
    let (Some(handle), Some(view)) = (state.main_window, state.main_view.clone()) else {
        return false;
    };
    cx.windows().contains(&handle) && view.read(cx).shows_main(cx)
}

/// Acts on what can be acted on now.
pub fn drain(cx: &mut App) {
    let Some(shell) = shell(cx) else {
        return;
    };
    let ready = main_ready(cx);
    let requests = shell.update(cx, |s, _| s.take_ready(ready));
    for request in requests {
        dispatch(request, cx);
    }
}

/// Opens one request (the main frame shows, for those that need it).
fn dispatch(request: OpenRequest, cx: &mut App) {
    match request {
        OpenRequest::Settings { tab } => {
            let resolved = tab.as_deref().and_then(Tab::from_id);
            if tab.is_some() && resolved.is_none() {
                log::info!("link to an unknown Settings tab; opening Settings");
            }
            crate::open_settings(resolved, cx);
        }
        OpenRequest::Chat { id } => {
            show_main(cx);
            let Some(state) = cx.try_global::<AppState>() else {
                return;
            };
            let navigation = state.stores.navigation.clone();
            navigation.update(cx, |n, cx| n.open(id, cx));
            crate::with_main_view(cx, |view, window, cx| {
                view.chat_pane
                    .update(cx, |p, cx| p.focus_composer(window, cx))
            });
        }
        OpenRequest::QuickAskDraft { id } => {
            // Taken by the request it was kept for, and only once.
            let Some((text, attachments)) = take_quick_ask_draft(id, cx) else {
                return;
            };
            open_new_chat(text, vec![], attachments, cx);
        }
        OpenRequest::NewChat { text, files } => open_new_chat(text, files, vec![], cx),
        OpenRequest::Channel { id } => open_item(AreaItem::Channel(id), cx),
        OpenRequest::Note { id } => open_item(AreaItem::Note(id), cx),
        OpenRequest::QuickAsk => show_quick_ask(cx),
        OpenRequest::VoiceCall => start_voice_call(cx),
    }
}

/// The main window on a new chat with `text`, the files at `files` and
/// `attachments` (already uploaded) in its composer, never sent.
fn open_new_chat(
    text: Option<String>,
    files: Vec<std::path::PathBuf>,
    carried: Vec<crate::stores::composer::Attachment>,
    cx: &mut App,
) {
    show_main(cx);
    let plan = open_files::plan(&files, open_files::file_size);
    for path in &plan.skipped {
        log::info!("open with: skipped a folder or missing file");
        let _ = path;
    }
    crate::with_main_view(cx, move |view, window, cx| {
        view.new_chat(false, window, cx);
        let pane = view.chat_pane.clone();
        pane.update(cx, |p, cx| {
            if let Some(text) = &text {
                p.composer.update(cx, |c, cx| c.set_text(text, window, cx));
            }
            if !plan.accepted.is_empty() {
                p.composer_store
                    .update(cx, |c, cx| c.add_paths(&plan.accepted, cx));
            }
            if !carried.is_empty() {
                p.composer_store
                    .update(cx, |c, cx| c.adopt_attachments(carried, cx));
            }
            p.focus_composer(window, cx);
        });
    });
    let l10n = cx.l10n().clone();
    if plan.too_many > 0 {
        toast(
            NoticeLevel::Warning,
            l10n.desktop_open_files_too_many(plan.too_many as i64, open_files::MAX_FILES as i64),
            cx,
        );
    }
    for name in &plan.too_large {
        toast(
            NoticeLevel::Warning,
            l10n.desktop_open_file_too_large(name),
            cx,
        );
    }
}

/// `conduit://call` (the widget's Voice Call, mobile's `mic`): a voice call
/// in a new chat. Where no call can start, mobile opens a new chat with the
/// caret in the composer instead, and so does this.
///
/// The widget's call link isn't wired to calls yet, so it always takes
/// that way; with calls, `CallStore::start(None, None, None, false)` and
/// `show_main` go here, as Quick Ask's call button does, and the call's own
/// notices say when it can't start.
fn start_voice_call(cx: &mut App) {
    dispatch(
        OpenRequest::NewChat {
            text: None,
            files: vec![],
        },
        cx,
    );
}

/// Opens `item` in its area's pane, or says the account has no such area
/// (once its capabilities are known: before then the pane opens, as a chat
/// link opens a chat the list has not loaded yet).
fn open_item(item: AreaItem, cx: &mut App) {
    show_main(cx);
    let Some(state) = cx.try_global::<AppState>() else {
        return;
    };
    let session = state.stores.session.read(cx);
    let known = session.system_capabilities.is_some();
    let shown = crate::stores::areas::visible_areas(&session.capabilities()).contains(&item.area());
    if known && !shown {
        let l = cx.l10n().clone();
        let text = match item.area() {
            Area::Channels => l.desktop_channels_unavailable(),
            _ => l.desktop_notes_unavailable(),
        };
        toast(NoticeLevel::Info, text, cx);
        return;
    }
    let navigation = state.stores.navigation.clone();
    navigation.update(cx, |n, cx| n.open_item(item, cx));
}

fn toast(level: NoticeLevel, text: String, cx: &mut App) {
    if let Some(state) = cx.try_global::<AppState>() {
        let toasts = state.stores.toasts.clone();
        toasts.update(cx, |t, cx| t.show(level, text, cx));
    }
}

// ── The desktop widget ─────────────────────────────────────────────────────

/// How long a change waits before the snapshot is written: a burst (the
/// list, then its sync, then the session) makes one write.
pub const WIDGET_DELAY: Duration = Duration::from_millis(400);

/// The widget's snapshot as the app last wrote it ([`crate::shell::widget`]).
#[derive(Default)]
pub struct WidgetFeed {
    /// Where the snapshot goes; `None` when this bundle has no widget.
    path: Option<PathBuf>,
    bridge: Option<widget::Bridge>,
    /// What was last written: an unchanged snapshot isn't written again.
    written: Option<Vec<u8>>,
    /// The account the last snapshot was for.
    account: Option<Option<String>>,
    pending: Option<gpui_kit::Task<()>>,
    /// A write failed (the system refused the container): logged once.
    failed: bool,
    /// Snapshots written, and reloads WidgetKit took (the E2E pass).
    pub writes: u32,
    pub reloads: u32,
}

impl WidgetFeed {
    /// Finds where the snapshot goes: `CONDUIT_WIDGET_SNAPSHOT`, else the
    /// bundle's app group (through the widget's library).
    fn open() -> Self {
        let bridge = widget::Bridge::load();
        let env = std::env::var_os(widget::PATH_ENV).map(PathBuf::from);
        let from_env = env.is_some();
        let group = widget::bundle_group();
        let path = widget::destination(env, group.as_deref(), |g| bridge.group_container(g));
        log::info!(
            "widget: {}",
            match (&path, from_env, bridge.is_loaded()) {
                (Some(_), true, _) => "snapshot to CONDUIT_WIDGET_SNAPSHOT",
                (Some(_), false, _) => "snapshot to the app group's container",
                (None, _, true) => "no app group container: no snapshot",
                (None, _, false) => "no widget in this bundle",
            }
        );
        Self {
            path,
            bridge: Some(bridge),
            ..Self::default()
        }
    }

    /// Whether the widget's library loaded (the bundle carries the widget).
    pub fn bridge_loaded(&self) -> bool {
        self.bridge.as_ref().is_some_and(widget::Bridge::is_loaded)
    }

    /// Sends the snapshot to `path` from now on (E2E); the next change
    /// writes it.
    pub fn redirect(&mut self, path: PathBuf) {
        self.path = Some(path);
        self.written = None;
        self.account = None;
        self.failed = false;
    }
}

/// Writes the widget's snapshot a moment after something it shows changed.
pub fn schedule_widget(cx: &mut App) {
    let Some(feed) = cx.try_global::<Desktop>().map(|d| &d.widget) else {
        return;
    };
    // One write per burst: later changes in the window are read when it
    // fires.
    if feed.path.is_none() || feed.pending.is_some() {
        return;
    }
    let task = cx.spawn(async move |cx| {
        cx.background_executor().timer(WIDGET_DELAY).await;
        cx.update(|cx| {
            if cx.has_global::<Desktop>() {
                cx.global_mut::<Desktop>().widget.pending = None;
            }
            write_widget(cx);
        });
    });
    cx.global_mut::<Desktop>().widget.pending = Some(task);
}

/// The snapshot for what the app holds now, and the account it is for;
/// `None` while that isn't known (the route, or a list still loading for
/// the account the last snapshot showed).
fn widget_snapshot(
    last_account: Option<&Option<String>>,
    cx: &App,
) -> Option<(Snapshot, Option<String>)> {
    let state = cx.try_global::<AppState>()?;
    let stores = &state.stores;
    let l10n = cx.l10n();
    let locale = l10n.locale();
    let account = stores
        .accounts
        .read(cx)
        .list
        .as_ref()
        .and_then(|l| l.active_account_id.clone());
    let snapshot = match stores.session.read(cx).route(cx) {
        Route::Unknown => return None,
        Route::Onboarding | Route::SignIn => Snapshot::signed_out(locale),
        Route::Main => {
            let list = stores.chat_list.read(cx);
            if list.list.is_some() {
                // A few more than shown: a chat a link can't name is
                // left out.
                let recent = list.recent(widget::MAX_CHATS + 4);
                Snapshot::signed_in(&recent, locale, &l10n.new_chat())
            } else if last_account == Some(&account) {
                // Loading again for the same account: what the widget
                // shows still stands.
                return None;
            } else {
                // Another account: none of the last one's chats.
                Snapshot::signed_in(&[], locale, &l10n.new_chat())
            }
        }
    };
    Some((snapshot, account))
}

/// Writes the snapshot if it changed, then asks WidgetKit to read it.
pub fn write_widget(cx: &mut App) {
    let Some(feed) = cx.try_global::<Desktop>().map(|d| &d.widget) else {
        return;
    };
    let Some(path) = feed.path.clone() else {
        return;
    };
    let Some((snapshot, account)) = widget_snapshot(feed.account.as_ref(), cx) else {
        return;
    };
    let bytes = snapshot.to_json();
    if feed.written.as_ref() == Some(&bytes) {
        cx.global_mut::<Desktop>().widget.account = Some(account);
        return;
    }
    let result = widget::write(&path, &bytes);
    let feed = &mut cx.global_mut::<Desktop>().widget;
    match result {
        Ok(()) => {
            feed.written = Some(bytes);
            feed.account = Some(account);
            feed.writes += 1;
            feed.failed = false;
            if feed.bridge.as_ref().is_some_and(|b| b.reload_all()) {
                feed.reloads += 1;
            }
            log::debug!(
                "widget: snapshot written ({} chats, signed in: {})",
                snapshot.chats.len(),
                snapshot.signed_in
            );
        }
        Err(e) => {
            if !feed.failed {
                log::warn!("widget: the snapshot could not be written: {e}");
            }
            feed.failed = true;
        }
    }
}

// ── The main window ────────────────────────────────────────────────────────

/// Shows the main window: made if it was closed, brought back if it was
/// closed to the menu bar, and the app comes forward. With no session yet
/// (first run, signed out) the setup window shows instead.
pub fn show_main(cx: &mut App) {
    crate::open_main_window(cx);
    // Deferred: called from inside the window's own update (an action, the
    // close hook), the window can't be updated again until it returns.
    #[cfg(target_os = "macos")]
    cx.defer(|cx| {
        let ns = crate::windows::front_window(cx).and_then(|h| {
            h.update(cx, |_, window, _| crate::shell::macos::ns_window(window))
                .ok()
                .flatten()
        });
        if let Some(ns) = ns {
            cx.foreground_executor()
                .spawn(async move { crate::shell::macos::show(&ns, true) })
                .detach();
        }
    });
    #[cfg(not(target_os = "macos"))]
    cx.activate(true);
}

#[cfg(target_os = "macos")]
fn main_ns_window(cx: &mut App) -> Option<objc2::rc::Retained<objc2_app_kit::NSWindow>> {
    let handle = cx.try_global::<AppState>()?.main_window?;
    handle
        .update(cx, |_, window, _| crate::shell::macos::ns_window(window))
        .ok()
        .flatten()
}

/// Whether the main window is on screen (not closed to the menu bar).
pub fn main_visible(cx: &mut App) -> bool {
    #[cfg(target_os = "macos")]
    {
        main_ns_window(cx).is_some_and(|w| crate::shell::macos::is_visible(&w))
    }
    #[cfg(not(target_os = "macos"))]
    {
        crate::main_window_alive(cx)
    }
}

/// "Close to menu bar": whether closing the main window only hides it.
pub fn closes_to_menu_bar(cx: &App) -> bool {
    cx.try_global::<AppState>()
        .is_some_and(|s| s.settings.read(cx).prefs.desktop.close_to_menu_bar)
}

/// Hides the main window (closing it with "Close to menu bar" on). The
/// AppKit call waits for the current update to end: it calls back into
/// GPUI.
pub fn hide_main(cx: &mut App) {
    // Deferred, as in `show_main`: ⌘W and the close button run inside the
    // window's update, where looking the window up again fails quietly.
    #[cfg(target_os = "macos")]
    cx.defer(|cx| {
        if let Some(ns) = main_ns_window(cx) {
            cx.foreground_executor()
                .spawn(async move { crate::shell::macos::order_out(&ns) })
                .detach();
        }
    });
}

/// The main window's should-close hook: with "Close to menu bar" on, the
/// window hides and stays (the app keeps running in the menu bar).
pub fn main_should_close(cx: &mut App) -> bool {
    // A reading pauses with its window, as the phone's does when its chat
    // goes; Now Playing and the media keys can carry it on.
    if let Some(speech) = cx.try_global::<AppState>().map(|s| s.stores.speech.clone())
        && speech.read(cx).is_speaking()
    {
        speech.update(cx, |s, cx| s.pause(cx));
    }
    if closes_to_menu_bar(cx) {
        log::info!("close button: hiding the main window");
        hide_main(cx);
        return false;
    }
    true
}

// ── Settings › Desktop ─────────────────────────────────────────────────────

/// Applies Settings › Desktop: the menu-bar item and the Quick Ask hotkey.
pub fn apply_settings(cx: &mut App) {
    let Some(state) = cx.try_global::<AppState>() else {
        return;
    };
    let prefs = state.settings.read(cx).prefs.desktop.clone();
    #[cfg(target_os = "macos")]
    {
        let in_call = state.stores.call.read(cx).is_active();
        set_tray(prefs.close_to_menu_bar || in_call, cx);
        let stroke = prefs.quick_ask.then(|| prefs.quick_ask_stroke());
        let status = cx
            .try_global::<Desktop>()
            .is_some()
            .then(|| {
                let desktop = cx.global_mut::<Desktop>();
                desktop
                    .platform
                    .hotkey
                    .as_mut()
                    .map(|h| h.apply(stroke.as_ref()))
            })
            .flatten();
        use crate::shell::hotkey::HotkeyStatus as H;
        let state = match status {
            Some(H::Registered) => HotkeyState::Registered,
            Some(H::Taken) => HotkeyState::Taken,
            Some(H::Invalid) => HotkeyState::Invalid,
            Some(H::Unavailable) | None if prefs.quick_ask => HotkeyState::Unavailable,
            _ => HotkeyState::Off,
        };
        if let Some(shell) = shell(cx) {
            shell.update(cx, |s, cx| s.set_hotkey(state, cx));
        }
        // Turning "Close to menu bar" off while the window is hidden would
        // leave the app with no way back but the Dock: show it.
        if !prefs.close_to_menu_bar && crate::main_window_alive(cx) && !main_visible(cx) {
            show_main(cx);
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = prefs;
}

/// Asks the system again: the login item and the notification permission.
pub fn refresh_statuses(cx: &mut App) {
    #[cfg(target_os = "macos")]
    {
        use crate::shell::login_item::{self, LoginItemStatus as L};
        let login = match login_item::status() {
            L::Enabled => LoginState::On,
            L::RequiresApproval => LoginState::NeedsApproval,
            L::NotFound => LoginState::NotFound,
            L::NotRegistered => LoginState::Off,
        };
        if let Some(shell) = shell(cx) {
            let error = shell.read(cx).login_error.clone();
            shell.update(cx, |s, cx| s.set_login(login, error, cx));
        }
        refresh_notification_access(cx);
    }
}

/// Open at login on or off: `SMAppService.mainApp`, then what the system
/// says. The choice is kept in the prefs too.
pub fn set_launch_at_login(enabled: bool, cx: &mut App) {
    if let Some(state) = cx.try_global::<AppState>() {
        let settings = state.settings.clone();
        settings.update(cx, |s, cx| {
            s.set_desktop(|d| d.launch_at_login = enabled, cx)
        });
    }
    #[cfg(target_os = "macos")]
    {
        use crate::shell::login_item::{self, LoginItemStatus as L};
        log::info!(
            "login item: {} ({})",
            if enabled { "register" } else { "unregister" },
            login_item::describe()
        );
        let (state, error) = match login_item::set(enabled) {
            Ok(status) => (
                match status {
                    L::Enabled => LoginState::On,
                    L::RequiresApproval => LoginState::NeedsApproval,
                    L::NotFound => LoginState::NotFound,
                    L::NotRegistered => LoginState::Off,
                },
                None,
            ),
            Err(e) => {
                log::warn!("login item: {e}");
                let now = match login_item::status() {
                    L::Enabled => LoginState::On,
                    L::RequiresApproval => LoginState::NeedsApproval,
                    L::NotFound => LoginState::NotFound,
                    L::NotRegistered => LoginState::Off,
                };
                (now, Some(e))
            }
        };
        if let Some(shell) = shell(cx) {
            shell.update(cx, |s, cx| s.set_login(state, error, cx));
        }
    }
}

/// System Settings › General › Login Items.
pub fn open_login_items_settings() {
    #[cfg(target_os = "macos")]
    crate::shell::login_item::open_settings();
}

/// System Settings › Notifications.
pub fn open_notification_settings(cx: &mut App) {
    cx.open_url("x-apple.systempreferences:com.apple.Notifications-Settings.extension");
}

// ── Notifications ──────────────────────────────────────────────────────────

fn on_turn_finished(finished: &TurnFinished, cx: &mut App) {
    let Some(state) = cx.try_global::<AppState>() else {
        return;
    };
    let enabled = state.settings.read(cx).prefs.desktop.notify_answers;
    let on_screen = on_screen(cx);
    let Some(kind) = notify::decide(
        enabled,
        &finished.chat_id,
        notify::Outcome::of(finished.ok, finished.queued),
        &on_screen,
    ) else {
        return;
    };
    let title = chat_title(&finished.chat_id, cx);
    let l10n = cx.l10n().clone();
    let (untitled, ready, failed) = (
        l10n.desktop_new_conversation(),
        l10n.desktop_notification_answer_ready(),
        l10n.desktop_notification_answer_failed(),
    );
    let n = notify::notification(
        kind,
        &finished.chat_id,
        title.as_deref(),
        &notify::Words {
            untitled: &untitled,
            ready: &ready,
            failed: &failed,
        },
    );
    log::info!(
        "notification: {}",
        match kind {
            NotificationKind::Ready => "answer ready",
            NotificationKind::Failed => "answer failed",
        }
    );
    post(n, cx);
}

/// Someone else posted in a channel not in front of the user: a
/// notification, by mobile's rules (the daemon's `alert`) and the setting.
fn on_channel_posted(posted: &conduit_protocol::ChannelPosted, cx: &mut App) {
    let Some(state) = cx.try_global::<AppState>() else {
        return;
    };
    let enabled = state.settings.read(cx).prefs.desktop.notify_channels;
    let on_screen = on_screen(cx);
    if !notify::decide_channel(enabled, posted.alert, &posted.channel_id, &on_screen) {
        return;
    }
    let l10n = cx.l10n().clone();
    let title_in =
        |author: &str, channel: &str| l10n.desktop_channel_notification_title(author, channel);
    let (message, mention, unknown) = (
        l10n.desktop_channel_notification_message(),
        l10n.desktop_channel_notification_mention(),
        l10n.channel_unknown_member(),
    );
    let n = notify::channel_notification(
        &posted.channel_id,
        &posted.author,
        &posted.channel_title,
        posted.mention,
        &notify::ChannelWords {
            title_in: &title_in,
            message: &message,
            mention: &mention,
            unknown: &unknown,
        },
    );
    log::info!("notification: channel message");
    post(n, cx);
}

/// What the user can see now, for [`notify::decide`].
pub fn on_screen(cx: &mut App) -> OnScreen {
    let mut out = OnScreen::default();
    let Some(state) = cx.try_global::<AppState>() else {
        return out;
    };
    let navigation = state.stores.navigation.clone();
    #[cfg(target_os = "macos")]
    {
        let active = crate::shell::macos::app_is_active();
        out.main_key = active
            && main_ready(cx)
            && main_ns_window(cx).is_some_and(|w| crate::shell::macos::is_key(&w));
        if let Some((handle, view)) = cx.try_global::<Desktop>().and_then(|d| d.quick_ask.clone()) {
            out.quick_ask_key = handle
                .update(cx, |_, window, _| {
                    crate::shell::macos::ns_window(window)
                        .is_some_and(|w| crate::shell::macos::is_key(&w))
                })
                .unwrap_or(false);
            out.quick_ask_chat = view.read(cx).chat_id(cx);
        }
    }
    out.main_chat = main_chat(navigation.read(cx));
    out.main_channel = match navigation.read(cx).selected_item() {
        Some(crate::stores::navigation::AreaItem::Channel(id)) => Some(id.clone()),
        _ => None,
    };
    out
}

/// The chat the main window's chat pane shows, for [`on_screen`]: a stored
/// chat, or a Hermes session's chat.
fn main_chat(navigation: &crate::stores::navigation::NavigationStore) -> Option<String> {
    navigation.selection().chat_id()
}

/// A chat's title, from the sidebar's list or an open chat.
fn chat_title(chat_id: &str, cx: &App) -> Option<String> {
    let state = cx.try_global::<AppState>()?;
    if let Some(title) = state
        .stores
        .chat_list
        .read(cx)
        .find(chat_id)
        .map(|c| c.title.clone())
        .filter(|t| !t.trim().is_empty())
    {
        return Some(title);
    }
    let open = |store: &Entity<crate::stores::chat::ChatStore>| {
        let s = store.read(cx);
        (s.chat_id() == chat_id)
            .then(|| s.title().map(str::to_string))
            .flatten()
    };
    if let Some(view) = &state.main_view
        && let Some(chat) = &view.read(cx).chat_pane.read(cx).chat
        && let Some(title) = open(&chat.store)
    {
        return Some(title);
    }
    let (_, quick) = cx.try_global::<Desktop>()?.quick_ask.clone()?;
    let chat = quick.read(cx).chat.as_ref().map(|c| c.store.clone())?;
    open(&chat)
}

#[cfg(target_os = "macos")]
fn refresh_notification_access(cx: &mut App) {
    use crate::shell::notifications::Authorization as A;
    let Some(rx) = cx
        .try_global::<Desktop>()
        .and_then(|d| d.platform.notifier.as_ref())
        .map(|n| n.authorization())
    else {
        if let Some(shell) = shell(cx) {
            shell.update(cx, |s, cx| {
                s.set_notifications(NotificationAccess::Unavailable, cx)
            });
        }
        return;
    };
    cx.spawn(async move |cx| {
        let Ok(auth) = rx.await else {
            return;
        };
        let access = match auth {
            A::NotDetermined => NotificationAccess::NotDetermined,
            A::Denied => NotificationAccess::Denied,
            A::Authorized => NotificationAccess::Allowed,
            A::Provisional => NotificationAccess::Quiet,
        };
        log::info!("notifications: {access:?}");
        cx.update(|cx| {
            if let Some(shell) = shell(cx) {
                shell.update(cx, |s, cx| s.set_notifications(access, cx));
            }
        });
    })
    .detach();
}

/// Asks for permission when the system hasn't asked the user yet. With
/// `quiet`, asks for quiet delivery (no prompt; the E2E run uses it).
pub fn ensure_permission(quiet: bool, cx: &mut App) {
    #[cfg(target_os = "macos")]
    {
        let Some(rx) = cx
            .try_global::<Desktop>()
            .and_then(|d| d.platform.notifier.as_ref())
            .map(|n| n.authorization())
        else {
            return;
        };
        cx.spawn(async move |cx| {
            let Ok(auth) = rx.await else {
                return;
            };
            if auth != crate::shell::notifications::Authorization::NotDetermined {
                cx.update(refresh_notification_access);
                return;
            }
            let request = cx.update(|cx| {
                cx.try_global::<Desktop>()
                    .and_then(|d| d.platform.notifier.as_ref())
                    .map(|n| n.request(quiet))
            });
            if let Some(rx) = request {
                match rx.await {
                    Ok(Ok(granted)) => log::info!("notification permission granted={granted}"),
                    Ok(Err(e)) => log::warn!("notification permission: {e}"),
                    Err(_) => {}
                }
            }
            cx.update(refresh_notification_access);
        })
        .detach();
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (quiet, cx);
}

/// Delivers `n`, asking for permission first if the system hasn't asked.
fn post(n: notify::Notification, cx: &mut App) {
    #[cfg(target_os = "macos")]
    {
        use crate::shell::notifications::Authorization as A;
        let Some(rx) = cx
            .try_global::<Desktop>()
            .and_then(|d| d.platform.notifier.as_ref())
            .map(|n| n.authorization())
        else {
            log::info!("notification skipped: notifications are unavailable");
            return;
        };
        cx.spawn(async move |cx| {
            let Ok(mut auth) = rx.await else {
                return;
            };
            if auth == A::NotDetermined {
                let request = cx.update(|cx| {
                    cx.try_global::<Desktop>()
                        .and_then(|d| d.platform.notifier.as_ref())
                        .map(|n| n.request(false))
                });
                if let Some(rx) = request
                    && let Ok(Ok(true)) = rx.await
                {
                    auth = A::Authorized;
                }
                cx.update(refresh_notification_access);
            }
            if !auth.allows() {
                log::info!("notification skipped: not allowed ({auth:?})");
                return;
            }
            let sent = cx.update(|cx| {
                cx.try_global::<Desktop>()
                    .and_then(|d| d.platform.notifier.as_ref())
                    .map(|notifier| notifier.post(&n))
            });
            if let Some(rx) = sent
                && let Ok(Err(e)) = rx.await
            {
                log::warn!("notification not delivered: {e}");
            }
        })
        .detach();
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (n, cx);
}

/// A notification was clicked: the main window on that chat.
fn on_notification_click(identifier: String, cx: &mut App) {
    // A channel's: the main window on that channel.
    if let Some(channel_id) = notify::channel_for(&identifier) {
        #[cfg(target_os = "macos")]
        if let Some(n) = cx
            .try_global::<Desktop>()
            .and_then(|d| d.platform.notifier.as_ref())
        {
            n.remove(&identifier);
        }
        log::info!("notification click: opening its channel");
        if let Some(shell) = shell(cx) {
            shell.update(cx, |s, cx| {
                s.push(OpenRequest::Channel { id: channel_id }, cx)
            });
        }
        show_main(cx);
        drain(cx);
        return;
    }
    let Some(chat_id) = notify::chat_for(&identifier) else {
        log::info!("ignored a click on a notification this app did not post");
        return;
    };
    #[cfg(target_os = "macos")]
    if let Some(n) = cx
        .try_global::<Desktop>()
        .and_then(|d| d.platform.notifier.as_ref())
    {
        n.remove(&identifier);
    }
    log::info!("notification click: opening its chat");
    if let Some(shell) = shell(cx) {
        shell.update(cx, |s, cx| s.push(OpenRequest::Chat { id: chat_id }, cx));
    }
    show_main(cx);
    drain(cx);
}

/// The notifications the app has in Notification Center (E2E).
#[cfg(target_os = "macos")]
pub fn delivered_notifications(
    cx: &App,
) -> Option<futures::channel::oneshot::Receiver<Vec<crate::shell::notifications::Delivered>>> {
    cx.try_global::<Desktop>()?
        .platform
        .notifier
        .as_ref()
        .map(|n| n.delivered())
}

/// Clears the app's delivered notifications (E2E cleanup).
#[cfg(target_os = "macos")]
pub fn remove_all_notifications(cx: &App) {
    if let Some(n) = cx
        .try_global::<Desktop>()
        .and_then(|d| d.platform.notifier.as_ref())
    {
        n.remove_all();
    }
}

/// Clicks a notification through the delegate's path (E2E).
#[cfg(target_os = "macos")]
pub fn simulate_notification_click(identifier: &str, cx: &App) {
    if let Some(n) = cx
        .try_global::<Desktop>()
        .and_then(|d| d.platform.notifier.as_ref())
    {
        n.simulate_click(identifier);
    }
}

// ── Quick Ask ──────────────────────────────────────────────────────────────

/// The global shortcut, the menu-bar item, Window › Quick Ask: shows the
/// panel, or hides it when it is in front.
pub fn toggle_quick_ask(cx: &mut App) {
    if quick_ask_key(cx) {
        hide_quick_ask(cx);
    } else {
        show_quick_ask(cx);
    }
}

/// Whether `handle` is the Quick Ask window.
pub fn is_quick_ask_window(handle: AnyWindowHandle, cx: &App) -> bool {
    cx.try_global::<Desktop>()
        .and_then(|d| d.quick_ask.as_ref())
        .is_some_and(|(h, _)| *h == handle)
}

/// Whether the Quick Ask panel is on screen and has focus.
pub fn quick_ask_key(cx: &mut App) -> bool {
    #[cfg(target_os = "macos")]
    {
        quick_ask_ns_window(cx)
            .is_some_and(|w| crate::shell::macos::is_visible(&w) && crate::shell::macos::is_key(&w))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = cx;
        false
    }
}

/// Whether the Quick Ask panel is on screen.
pub fn quick_ask_visible(cx: &mut App) -> bool {
    #[cfg(target_os = "macos")]
    {
        quick_ask_ns_window(cx).is_some_and(|w| crate::shell::macos::is_visible(&w))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = cx;
        false
    }
}

#[cfg(target_os = "macos")]
fn quick_ask_ns_window(cx: &mut App) -> Option<objc2::rc::Retained<objc2_app_kit::NSWindow>> {
    let (handle, _) = cx.try_global::<Desktop>()?.quick_ask.clone()?;
    handle
        .update(cx, |_, window, _| crate::shell::macos::ns_window(window))
        .ok()
        .flatten()
}

/// The Quick Ask window, made on first use.
fn quick_ask_window(cx: &mut App) -> Option<(AnyWindowHandle, Entity<QuickAskView>)> {
    if let Some((handle, view)) = cx.try_global::<Desktop>().and_then(|d| d.quick_ask.clone())
        && cx.windows().contains(&handle)
    {
        return Some((handle, view));
    }
    let stores = cx.try_global::<AppState>()?.stores.clone();
    let (w, h) = crate::shell::placement::QUICK_ASK_SIZE;
    let bounds = Bounds::centered(None, size(px(w as f32), px(h as f32)), cx);
    let options = cw::quick_ask_options(bounds, true);
    let (handle, view) = match cw::open_window_clear_root(options, cx, |window, cx| {
        cx.new(|cx| QuickAskView::new(stores, window, cx))
    }) {
        Ok(v) => v,
        Err(e) => {
            log::error!("could not open Quick Ask: {e}");
            return None;
        }
    };
    #[cfg(target_os = "macos")]
    {
        let _ = handle.update(cx, |_, window, _| {
            cw::macos::add_effect_view(window, cw::Material::HudWindow, None, Some(16.))
        });
        // A new panel is on screen at once: start it transparent, so the
        // first Quick Ask fades in like every later one.
        if let Some(ns) = handle
            .update(cx, |_, window, _| crate::shell::macos::ns_window(window))
            .ok()
            .flatten()
        {
            ns.setAlphaValue(0.);
        }
    }
    cx.subscribe(&view, |_, event: &QuickAskEvent, cx| {
        let event = event.clone();
        cx.defer(move |cx| on_quick_ask_event(event, cx));
    })
    .detach();
    if cx.has_global::<Desktop>() {
        cx.global_mut::<Desktop>().quick_ask = Some((handle, view.clone()));
    }
    Some((handle, view))
}

/// Places Quick Ask on the display under the pointer and shows it, with
/// the caret in the composer. The app is not activated (the panel is
/// non-activating), so the app in front stays in front.
pub fn show_quick_ask(cx: &mut App) {
    let Some((handle, view)) = quick_ask_window(cx) else {
        return;
    };
    #[cfg(target_os = "macos")]
    {
        use crate::shell::{macos, placement};
        let screens = macos::screens();
        let frames: Vec<placement::Rect> = screens.iter().map(|s| s.0).collect();
        let frame = placement::display_under(&frames, macos::mouse_location())
            .map(|i| placement::quick_ask_frame(screens[i].1, placement::QUICK_ASK_SIZE));
        let ns = handle
            .update(cx, |_, window, _| macos::ns_window(window))
            .ok()
            .flatten();
        if let Some(ns) = ns {
            // After this update: AppKit calls back into GPUI on a move.
            cx.foreground_executor()
                .spawn(async move {
                    if let Some(frame) = frame {
                        macos::set_frame(&ns, frame);
                    }
                    // In over 150 ms (motion::specs::QUICK_ASK_IN).
                    macos::fade_in(&ns, false, specs::QUICK_ASK_IN.duration.as_secs_f64());
                })
                .detach();
        }
    }
    let _ = handle.update(cx, |_, window, cx| {
        view.update(cx, |v, cx| v.focus_composer(window, cx))
    });
    if let Some(shell) = shell(cx) {
        shell.update(cx, |s, cx| s.set_quick_ask_visible(true, cx));
    }
}

/// Hides Quick Ask (its exchange stays for next time).
pub fn hide_quick_ask(cx: &mut App) {
    // Deferred: Esc and ⌘W run inside the panel's own update.
    #[cfg(target_os = "macos")]
    cx.defer(|cx| {
        if let Some(ns) = quick_ask_ns_window(cx) {
            // Out over 120 ms (motion::specs::QUICK_ASK_OUT), then off
            // screen.
            let secs = specs::QUICK_ASK_OUT.duration.as_secs_f64();
            cx.foreground_executor()
                .spawn(async move { crate::shell::macos::fade_out(&ns, secs) })
                .detach();
        }
    });
    if let Some(shell) = shell(cx) {
        shell.update(cx, |s, cx| s.set_quick_ask_visible(false, cx));
    }
}

/// The panel lost focus: a moment later (focus settles), hide it unless it
/// went to one of the app's own sheets or panels (a file picker opened
/// from the composer, say).
fn schedule_quick_ask_blur(cx: &mut App) {
    cx.spawn(async move |cx| {
        cx.background_executor()
            .timer(Duration::from_millis(150))
            .await;
        cx.update(|cx| {
            if !quick_ask_visible(cx) || quick_ask_key(cx) {
                return;
            }
            #[cfg(target_os = "macos")]
            {
                let key = crate::shell::macos::key_window();
                let main = main_ns_window(cx);
                let settings = cx
                    .try_global::<AppState>()
                    .and_then(|s| s.settings_window.clone())
                    .and_then(|(h, _)| {
                        h.update(cx, |_, window, _| crate::shell::macos::ns_window(window))
                            .ok()
                            .flatten()
                    });
                let same =
                    |a: &Option<objc2::rc::Retained<objc2_app_kit::NSWindow>>| match (&key, a) {
                        (Some(k), Some(w)) => {
                            objc2::rc::Retained::as_ptr(k) == objc2::rc::Retained::as_ptr(w)
                        }
                        _ => false,
                    };
                // Another app took focus (no key window of ours), or the
                // main window or Settings did: hide. One of our own panels
                // (a file picker, an alert): keep.
                if key.is_none() || same(&main) || same(&settings) {
                    hide_quick_ask(cx);
                }
            }
        });
    })
    .detach();
}

/// Quick Ask drafts on their way to the main window, by id: the text and
/// uploaded files of each Open in Conduit.
#[derive(Default)]
struct QuickAskDrafts(
    std::collections::HashMap<u64, (Option<String>, Vec<crate::stores::composer::Attachment>)>,
    u64,
);

impl gpui_kit::Global for QuickAskDrafts {}

/// The draft kept under `id`, taken out (once).
fn take_quick_ask_draft(
    id: u64,
    cx: &mut App,
) -> Option<(Option<String>, Vec<crate::stores::composer::Attachment>)> {
    if !cx.has_global::<QuickAskDrafts>() {
        return None;
    }
    cx.global_mut::<QuickAskDrafts>().0.remove(&id)
}

/// Keeps a Quick Ask draft for its [`OpenRequest::QuickAskDraft`]; its id.
fn keep_quick_ask_draft(
    text: Option<String>,
    attachments: Vec<crate::stores::composer::Attachment>,
    cx: &mut App,
) -> u64 {
    let drafts = cx.default_global::<QuickAskDrafts>();
    drafts.1 += 1;
    let id = drafts.1;
    drafts.0.insert(id, (text, attachments));
    id
}

fn on_quick_ask_event(event: QuickAskEvent, cx: &mut App) {
    match event {
        QuickAskEvent::Hide => hide_quick_ask(cx),
        // Losing focus to another app or the main window hides it.
        QuickAskEvent::Blurred => schedule_quick_ask_blur(cx),
        QuickAskEvent::OpenChat(id) => {
            hide_quick_ask(cx);
            if let Some(shell) = shell(cx) {
                shell.update(cx, |s, cx| s.push(OpenRequest::Chat { id }, cx));
            }
            show_main(cx);
            drain(cx);
        }
        QuickAskEvent::StartCall(model) => {
            hide_quick_ask(cx);
            if let Some(call) = cx.try_global::<AppState>().map(|s| s.stores.call.clone()) {
                call.update(cx, |c, cx| c.start(None, model, None, false, cx));
            }
            show_main(cx);
        }
        QuickAskEvent::OpenDraft { text, attachments } => {
            hide_quick_ask(cx);
            let text = Some(text).filter(|t| !t.trim().is_empty());
            // Kept under its own id: only its request takes it, once the
            // main window shows a new chat.
            let id = keep_quick_ask_draft(text, attachments, cx);
            if let Some(shell) = shell(cx) {
                shell.update(cx, |s, cx| s.push(OpenRequest::QuickAskDraft { id }, cx));
            }
            show_main(cx);
            drain(cx);
        }
    }
}

// ── The menu-bar item, the hotkey and notification clicks ──────────────────

#[cfg(target_os = "macos")]
fn install_platform(cx: &mut App) {
    use crate::shell::{hotkey::Hotkey, notifications::Notifier, tray::TrayCommand};

    // Notification clicks.
    let (clicks_tx, mut clicks) = mpsc::unbounded::<String>();
    let notifier = Notifier::new(clicks_tx);
    cx.spawn(async move |cx| {
        while let Some(id) = clicks.next().await {
            cx.update(|cx| on_notification_click(id, cx));
        }
    })
    .detach();

    // Hotkey presses, from the hot key handler (main thread, Carbon).
    let (keys_tx, mut keys) = mpsc::unbounded::<global_hotkey::GlobalHotKeyEvent>();
    global_hotkey::GlobalHotKeyEvent::set_event_handler(Some(move |e| {
        let _ = keys_tx.unbounded_send(e);
    }));
    cx.spawn(async move |cx| {
        while let Some(event) = keys.next().await {
            if event.state != global_hotkey::HotKeyState::Pressed {
                continue;
            }
            cx.update(|cx| {
                let ours = cx
                    .try_global::<Desktop>()
                    .and_then(|d| d.platform.hotkey.as_ref())
                    .and_then(|h| h.id())
                    == Some(event.id);
                if ours {
                    toggle_quick_ask(cx);
                }
            });
        }
    })
    .detach();

    // Menu-bar item commands.
    let (menu_tx, mut menu) = mpsc::unbounded::<tray_icon::menu::MenuEvent>();
    tray_icon::menu::MenuEvent::set_event_handler(Some(move |e| {
        let _ = menu_tx.unbounded_send(e);
    }));
    cx.spawn(async move |cx| {
        while let Some(event) = menu.next().await {
            let Some(command) = TrayCommand::from_event(&event) else {
                continue;
            };
            cx.update(|cx| {
                cx.defer(move |cx| on_tray_command(command, cx));
            });
        }
    })
    .detach();

    let desktop = cx.global_mut::<Desktop>();
    desktop.platform.notifier = notifier;
    desktop.platform.hotkey = Some(Hotkey::new());
}

/// A menu-bar item command (the same paths as the app's own commands).
#[cfg(target_os = "macos")]
pub fn on_tray_command(command: crate::shell::tray::TrayCommand, cx: &mut App) {
    use crate::shell::tray::TrayCommand as T;
    log::info!("menu-bar item: {command:?}");
    match command {
        T::Open => show_main(cx),
        T::NewChat => {
            if let Some(shell) = shell(cx) {
                shell.update(cx, |s, cx| {
                    s.push(
                        OpenRequest::NewChat {
                            text: None,
                            files: vec![],
                        },
                        cx,
                    )
                });
            }
            show_main(cx);
            drain(cx);
        }
        T::QuickAsk => show_quick_ask(cx),
        T::Settings => crate::open_settings(None, cx),
        // As ⌘Q: a sheet down ends first, and unsaved notes are saved.
        T::Quit => crate::views::sheet::quit(cx),
        T::ShowCall => {
            show_main(cx);
            cx.dispatch_action(&crate::actions::ShowCall);
        }
        T::EndCall => cx.dispatch_action(&crate::actions::EndCall),
    }
}

/// The menu-bar item follows the voice call: installed while one is on
/// (whatever "Close to menu bar" says), showing its time and state.
#[cfg(target_os = "macos")]
fn sync_call_tray(cx: &mut App) {
    let Some(state) = cx.try_global::<AppState>() else {
        return;
    };
    let call = state.stores.call.read(cx);
    let shown = if call.is_active() {
        let l10n = cx.l10n();
        let time = crate::stores::dictation::clock(crate::views::chat::call::elapsed(
            call.state().started_at_ms,
        ));
        Some(crate::shell::tray::TrayCall {
            status: crate::views::chat::call::status_line(call, l10n),
            time,
            show: l10n.desktop_show_call(),
            end: l10n.voice_call_end(),
        })
    } else {
        None
    };
    if shown.is_some() {
        set_tray(true, cx);
    }
    if cx.has_global::<Desktop>()
        && let Some(tray) = cx.global_mut::<Desktop>().platform.tray.as_mut()
    {
        tray.set_call(shown.as_ref());
    }
    if shown.is_none() && !closes_to_menu_bar(cx) {
        set_tray(false, cx);
    }
}

/// Whether the menu-bar item shows a call (E2E).
#[cfg(target_os = "macos")]
pub fn menu_bar_shows_call(cx: &App) -> bool {
    cx.try_global::<Desktop>()
        .and_then(|d| d.platform.tray.as_ref())
        .is_some_and(|t| t.shows_call())
}

#[cfg(target_os = "macos")]
fn tray_labels(cx: &App) -> crate::shell::tray::TrayLabels {
    let l10n = cx.l10n();
    crate::shell::tray::TrayLabels {
        open: l10n.desktop_tray_open(),
        new_chat: l10n.new_chat(),
        quick_ask: l10n.desktop_tray_quick_ask(),
        settings: l10n.desktop_menu_settings(),
        quit: l10n.desktop_menu_quit(),
        tooltip: "Conduit".into(),
        new_chat_keys: cx.try_global::<crate::AppState>().map(|s| {
            s.settings
                .read(cx)
                .keymap()
                .stroke(crate::keymap::ShortcutAction::NewChat)
        }),
        quick_ask_keys: cx
            .try_global::<crate::AppState>()
            .map(|s| s.settings.read(cx).prefs.desktop.quick_ask_stroke()),
    }
}

/// Installs or removes the menu-bar item.
#[cfg(target_os = "macos")]
fn set_tray(on: bool, cx: &mut App) {
    let has = cx
        .try_global::<Desktop>()
        .is_some_and(|d| d.platform.tray.is_some());
    if on == has {
        return;
    }
    let tray = if on {
        match crate::shell::tray::MenuBarItem::new(&tray_labels(cx)) {
            Ok(t) => Some(t),
            Err(e) => {
                log::warn!("no menu-bar item: {e}");
                None
            }
        }
    } else {
        None
    };
    let installed = tray.is_some();
    if cx.has_global::<Desktop>() {
        cx.global_mut::<Desktop>().platform.tray = tray;
    }
    if let Some(shell) = shell(cx) {
        shell.update(cx, |s, cx| s.set_menu_bar_item(installed, cx));
    }
}

fn relabel_tray(cx: &mut App) {
    #[cfg(target_os = "macos")]
    {
        let labels = tray_labels(cx);
        if let Some(tray) = cx
            .try_global::<Desktop>()
            .and_then(|d| d.platform.tray.as_ref())
        {
            tray.relabel(&labels);
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = cx;
}

/// The menu-bar item, when it is installed (the capture harness opens its
/// menu).
#[cfg(target_os = "macos")]
pub fn menu_bar_item(cx: &App) -> Option<tray_icon::TrayIcon> {
    cx.try_global::<Desktop>()
        .and_then(|d| d.platform.tray.as_ref())
        .map(|t| t.icon())
}

/// Whether the menu-bar item is on screen (E2E).
#[cfg(target_os = "macos")]
pub fn menu_bar_item_visible(cx: &App) -> bool {
    cx.try_global::<Desktop>()
        .and_then(|d| d.platform.tray.as_ref())
        .is_some_and(|t| t.is_visible())
}

#[cfg(test)]
mod quick_ask_draft_tests {
    use super::*;

    #[gpui_kit::test]
    fn a_draft_goes_only_to_its_own_request(cx: &mut gpui_kit::TestAppContext) {
        cx.update(|cx| {
            let a = keep_quick_ask_draft(Some("first".into()), vec![], cx);
            let b = keep_quick_ask_draft(Some("second".into()), vec![], cx);
            assert_ne!(a, b);
            assert_eq!(
                take_quick_ask_draft(b, cx).map(|d| d.0),
                Some(Some("second".to_string()))
            );
            assert!(take_quick_ask_draft(b, cx).is_none(), "taken once");
            assert_eq!(
                take_quick_ask_draft(a, cx).map(|d| d.0),
                Some(Some("first".to_string()))
            );
        });
    }
}

#[cfg(test)]
mod on_screen_tests {
    use gpui_kit::TestAppContext;

    use super::*;
    use crate::stores::navigation::NavigationStore;

    /// A Hermes session's chat in the main window is in front of the user:
    /// its answers notify no more than a stored chat's do.
    #[gpui_kit::test]
    fn a_hermes_chat_in_the_main_window_counts_as_on_screen(cx: &mut TestAppContext) {
        let navigation = cx.new(|_| NavigationStore::new());
        navigation.update(cx, |n, cx| n.open("local:hermes_s1", cx));
        let screen = OnScreen {
            main_key: true,
            main_chat: navigation.read_with(cx, |n, _| main_chat(n)),
            ..OnScreen::default()
        };
        assert!(screen.shows("local:hermes_s1"));
        navigation.update(cx, |n, cx| n.open("c1", cx));
        let screen = OnScreen {
            main_key: true,
            main_chat: navigation.read_with(cx, |n, _| main_chat(n)),
            ..OnScreen::default()
        };
        assert!(screen.shows("c1") && !screen.shows("local:hermes_s1"));
    }
}
