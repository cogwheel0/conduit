//! The macOS shell extras, wired into the app:
//!
//! * **Links and "Open with"**: `on_open_urls` hands over `conduit://`
//!   links and `file://` URLs (cold launch included). They queue in the
//!   [`ShellStore`] until the main window exists and the session routes to
//!   Main, then [`dispatch`] opens them: a chat (`navigation.open`), a new
//!   chat with the composer prefilled (text, or files attached through the
//!   composer's upload path; at most 10, each up to 256 MB), a Settings
//!   tab, a note or a channel.
//! * **The Share menu** (`conduit://share/<id>` from the Share extension):
//!   the share the extension staged ([`share_inbox`]) opens as a new chat,
//!   as "Open with" does, with its message and text in the composer.
//! * **The Services menu**: "Ask Conduit" opens Quick Ask with the
//!   selected text quoted (a new chat when Quick Ask is off or not ready);
//!   "New Conduit Chat With Selection" opens a new chat with it
//!   ([`crate::shell::services`]).
//! * **Notifications** on `turn.finished` and `channels.posted`, as the
//!   core decides them (`notifications.route`, Settings › Notifications):
//!   an in-app banner while the app is in front, a system notification
//!   behind it, with the cue or the system's sound, or nothing for what is
//!   on screen. An answer a shortcut waits for gets none. Permission is
//!   asked the first time notifications are turned on or a system
//!   notification would go out. A click on either shows the main window on
//!   that chat or channel.
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
use conduit_protocol::{
    ChannelKind, Event, NoticeLevel, NotificationRoute, NotificationRouteParams,
    NotificationSettingsPatch, NotifyKind, NotifySurface, TurnFinished, events, methods,
};
use futures::StreamExt as _;
use futures::channel::mpsc;
use gpui_kit::{AnyWindowHandle, App, AppContext as _, Bounds, Entity, Global, px, size};

use crate::AppState;
use crate::l10n::ActiveL10n as _;
use crate::shell::deep_link::{self, Compose, OpenRequest};
use crate::shell::notify::{self, NotificationKind, OnScreen};
use crate::shell::open_files;
use crate::shell::services::{self, ServiceRequest};
use crate::shell::share_inbox;
use crate::shell::widget::{self, Snapshot};
use crate::stores::connection::{ConnectionEvent, ConnectionStore};
use crate::stores::navigation::{Area, AreaItem};
use crate::stores::session::Route;
use crate::stores::settings::SettingsEvent;
use crate::stores::shell::ShellStore;
#[cfg(target_os = "macos")]
use crate::stores::shell::{HotkeyState, LoginState, NotificationAccess};
use crate::views::chat_pane::NewChatContent;
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
    /// The notifications switch as last seen: permission is asked when it
    /// turns on, not on every change in Settings › Notifications.
    notifications_on: bool,
    /// E2E: the app counts as behind other apps, so the core picks system
    /// notifications (a run can't send the app to the back reliably).
    e2e_background: bool,
    /// E2E: what each notification did, newest last.
    routed: Vec<Routed>,
    pub widget: WidgetFeed,
    #[cfg(target_os = "macos")]
    platform: Platform,
}

#[cfg(target_os = "macos")]
#[derive(Default)]
struct Platform {
    /// What Continuity Camera's requestor hands over (made with the first
    /// + menu that offers it).
    continuity: Option<mpsc::UnboundedSender<crate::shell::continuity_camera::Imported>>,
    notifier: Option<crate::shell::notifications::Notifier>,
    hotkey: Option<crate::shell::hotkey::Hotkey>,
    tray: Option<crate::shell::tray::MenuBarItem>,
    /// The Services menu's provider (set while the app launched).
    services: Option<objc2::rc::Retained<services::Provider>>,
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
        notifications_on: false,
        e2e_background: false,
        routed: vec![],
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
    let notifications_on = cx
        .try_global::<AppState>()
        .is_some_and(|s| s.stores.notifications.read(cx).settings().enabled);
    cx.set_global(Desktop {
        shell: shell.clone(),
        quick_ask: None,
        notifications_on,
        e2e_background: false,
        routed: vec![],
        widget: WidgetFeed::open(),
        #[cfg(target_os = "macos")]
        platform: Platform::default(),
    });
    #[cfg(target_os = "macos")]
    install_platform(cx);
    apply_settings(cx);
    install_dock_menu(cx);

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
            let _ = &settings;
            apply_settings(cx);
            // The Quick Ask chord beside its item.
            relabel_tray(cx);
        }
        // New words, or new chords beside New Chat.
        SettingsEvent::LocaleChanged | SettingsEvent::KeymapChanged => {
            relabel_tray(cx);
            set_dock_menu(cx);
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
    // Turning notifications on asks for permission (if the system hasn't
    // asked yet); other changes don't.
    cx.observe(&stores.notifications, |store, cx| {
        let now = store.read(cx).settings().enabled;
        let before = std::mem::replace(&mut cx.global_mut::<Desktop>().notifications_on, now);
        if now && !before && store.read(cx).loaded {
            ensure_permission(false, cx);
        }
    })
    .detach();
    // The two switches Settings › General had before Settings ›
    // Notifications: a choice turned off there moves to the core once.
    cx.subscribe(&connection, |_, event, cx| {
        if matches!(event, ConnectionEvent::Connected { .. }) {
            move_old_switches(cx);
        }
    })
    .detach();
    follow_alerts(&connection, cx);
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
            // An Open WebUI answer this Mac did not run (another device, a
            // scheduled task): notified as an answer of its own would be.
            Event::NotificationsAnswered(notice) => {
                let finished = TurnFinished {
                    chat_id: notice.chat_id.clone(),
                    message_id: notice.message_id.clone(),
                    ok: true,
                    code: None,
                    queued: false,
                    held: false,
                };
                cx.defer(move |cx| on_turn_finished(&finished, cx));
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
    prune_shares(cx);

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

/// Opens `request` as a link would (an App Intent's New Chat or Open
/// Chat): queued until the main frame shows, which comes forward.
pub fn open_request(request: OpenRequest, cx: &mut App) {
    let Some(shell) = shell(cx) else {
        return;
    };
    log::info!("intent opens: {}", describe(&request));
    shell.update(cx, |s, cx| s.push(request, cx));
    if shell.read(cx).waits_for_main() {
        show_main(cx);
    }
    drain(cx);
}

/// A request for the log: its kind, never ids, text or file names.
fn describe(request: &OpenRequest) -> &'static str {
    match request {
        OpenRequest::Share { .. } => "share",
        OpenRequest::Clipboard => "clipboard",
        OpenRequest::Compose(_) => "new chat with content",
        OpenRequest::Chat { .. } => "chat",
        OpenRequest::NewChat { files, .. } if !files.is_empty() => "new chat with files",
        OpenRequest::NewChat { .. } => "new chat",
        OpenRequest::Channel { .. } => "channel",
        OpenRequest::Note { .. } => "note",
        OpenRequest::Settings { .. } => "settings",
        OpenRequest::QuickAskDraft { .. } => "quick ask draft",
        OpenRequest::QuickAsk { .. } => "quick ask",
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
            open_new_chat(
                Compose {
                    text,
                    ..Compose::default()
                },
                attachments,
                false,
                cx,
            );
        }
        OpenRequest::NewChat { text, files } => open_new_chat(
            Compose {
                text,
                files,
                ..Compose::default()
            },
            vec![],
            false,
            cx,
        ),
        OpenRequest::Compose(compose) => open_new_chat(*compose, vec![], true, cx),
        OpenRequest::Clipboard => open_clipboard(cx),
        OpenRequest::Share { id } => open_share(&id, cx),
        OpenRequest::Channel { id } => open_item(AreaItem::Channel(id), cx),
        OpenRequest::Note { id } => open_item(AreaItem::Note(id), cx),
        OpenRequest::QuickAsk { text } => quick_ask_with(text, cx),
        OpenRequest::VoiceCall => start_voice_call(cx),
    }
}

/// The Quick Ask panel, as the menu-bar item and the hotkey show it; with
/// `text`, a new question with the text in its message box.
fn quick_ask_with(text: Option<String>, cx: &mut App) {
    show_quick_ask(cx);
    let Some(text) = text.filter(|t| !t.trim().is_empty()) else {
        return;
    };
    let text: String = text.chars().take(deep_link::MAX_TEXT).collect();
    let Some((handle, view)) = cx.try_global::<Desktop>().and_then(|d| d.quick_ask.clone()) else {
        return;
    };
    let _ = handle.update(cx, |_, window, cx| {
        view.update(cx, |v, cx| {
            v.new_chat(window, cx);
            v.composer.update(cx, |c, cx| c.set_text(&text, window, cx));
            v.focus_composer(window, cx);
        })
    });
}

/// `conduit://call` (the widget's Voice Call, mobile's `mic`) and
/// Shortcuts' Start Voice Call ([`crate::intents`]): a voice call in a new
/// chat, as the phone's widget starts one. The main window shows a new chat
/// and the call starts there with [`CallStore::start`], so its strip shows
/// in that chat, with the core's reason when it refuses the call (no model,
/// a backend that takes no calls, ...). Never the `VoiceCall` action: it
/// toggles, so it would end a call that is on. A call that is already on is
/// shown instead.
///
/// [`CallStore::start`]: crate::stores::call::CallStore::start
fn start_voice_call(cx: &mut App) {
    let Some(call) = cx.try_global::<AppState>().map(|s| s.stores.call.clone()) else {
        return;
    };
    if call.read(cx).is_active() {
        show_main(cx);
        crate::with_main_view(cx, |view, _, cx| {
            view.chat_pane.update(cx, |p, cx| p.show_call(cx))
        });
        return;
    }
    open_new_chat(Compose::default(), vec![], false, cx);
    // After open_new_chat's own task: the pane shows the new chat by then,
    // and the call takes that chat's Temporary switch and folder.
    crate::with_main_view(cx, |view, window, cx| {
        let pane = view.chat_pane.clone();
        cx.spawn_in(window, async move |_, cx| {
            pane.update(cx, |p, cx| p.call_in_new_chat(cx));
        })
        .detach();
    });
}

/// A new chat in the main window with the text in the composer and the
/// files, pictures and page text attached, with `carried` attachments
/// already uploaded (Quick Ask's Open in Conduit), never sent; toasts for
/// files left out. `fresh`: the new chat starts empty, as the phone's Send
/// to Conduit, Send Link, Send Image and widget Clipboard reset it (a new
/// chat keeps an unsent draft otherwise, as New Chat does).
fn open_new_chat(
    compose: Compose,
    carried: Vec<crate::stores::composer::Attachment>,
    fresh: bool,
    cx: &mut App,
) {
    let Compose {
        text,
        files,
        images,
        context,
        owner,
    } = compose;
    show_main(cx);
    let plan = open_files::plan(&files, open_files::file_size);
    for path in &plan.skipped {
        log::info!("open with: skipped a folder or missing file");
        let _ = path;
    }
    let (too_many, too_large) = (plan.too_many, plan.too_large.clone());
    crate::with_main_view(cx, move |view, window, cx| {
        view.new_chat(false, window, cx);
        // The new chat this request opened: what follows in the same batch
        // (another link) may select something else before the write below.
        let ticket = view.stores.navigation.read(cx).selection().clone();
        let pane = view.chat_pane.clone();
        let content = NewChatContent {
            text,
            fresh,
            paths: plan.accepted,
            images,
            context,
            carried,
            owner,
        };
        // After this update: the pane follows the new selection as it ends,
        // and its draft switch empties the message box (a chat was open
        // before), so the text goes in after that.
        cx.spawn_in(window, async move |_, cx| {
            let _ = pane.update_in(cx, |p, window, cx| {
                p.compose_new_chat(&ticket, content, window, cx)
            });
        })
        .detach();
    });
    refused_files(too_many, &too_large, cx);
}

/// `conduit://clipboard` (the widget's Clipboard): a new chat with the
/// copied text in the message box, as the phone's widget opens one. Only
/// text: any page or app can open the link, and a copied picture or copied
/// files would be uploaded the moment they were attached, so they stay on
/// the clipboard (⌘V in the new chat attaches them). An empty clipboard
/// still opens the new chat.
fn open_clipboard(cx: &mut App) {
    let item = cx.read_from_clipboard();
    let compose = clipboard_compose(item.as_ref());
    log::info!("clipboard: text {}", compose.text.is_some());
    open_new_chat(compose, vec![], true, cx);
}

/// What a copied item starts a new chat with from the link: its text
/// (trimmed, as the phone trims it, cut to [`deep_link::MAX_TEXT`]), and
/// nothing else.
pub fn clipboard_compose(item: Option<&gpui_kit::ClipboardItem>) -> Compose {
    use gpui_kit::ClipboardEntry;
    let Some(item) = item else {
        return Compose::default();
    };
    let text: String = item
        .entries()
        .iter()
        .filter_map(|e| match e {
            ClipboardEntry::String(s) => Some(s.text().as_str()),
            _ => None,
        })
        .collect();
    let text = text.trim();
    Compose {
        text: (!text.is_empty()).then(|| text.chars().take(deep_link::MAX_TEXT).collect()),
        ..Compose::default()
    }
}

/// The toasts for files a new chat could not take: past the count limit,
/// or over the size limit.
fn refused_files(too_many: usize, too_large: &[String], cx: &mut App) {
    let l10n = cx.l10n().clone();
    if too_many > 0 {
        toast(
            NoticeLevel::Warning,
            l10n.desktop_open_files_too_many(too_many as i64, open_files::MAX_FILES as i64),
            cx,
        );
    }
    for name in too_large {
        toast(
            NoticeLevel::Warning,
            l10n.desktop_open_file_too_large(name),
            cx,
        );
    }
}

/// A share from the Share menu: the new chat the extension staged, with
/// what it left out said as "Open with" says it.
fn open_share(id: &str, cx: &mut App) {
    let taken = match share_inbox::app_root() {
        Some(root) => share_inbox::take(&root, id),
        None => Err(share_inbox::TakeError::Missing),
    };
    prune_shares(cx);
    match taken {
        Ok(shared) => {
            log::info!(
                "share: {} file(s), text: {}",
                shared.files.len(),
                shared.text.is_some()
            );
            open_new_chat(
                Compose {
                    text: shared.text,
                    files: shared.files,
                    ..Compose::default()
                },
                vec![],
                false,
                cx,
            );
            refused_files(shared.too_many, &shared.too_large, cx);
        }
        Err(error) => {
            log::warn!("share: not opened ({error:?})");
            show_main(cx);
            let text = cx.l10n().desktop_share_sheet_unavailable();
            toast(NoticeLevel::Warning, text, cx);
        }
    }
}

/// Clears old shares from the inbox, off the main thread.
fn prune_shares(cx: &mut App) {
    let Some(root) = share_inbox::app_root() else {
        return;
    };
    cx.background_executor()
        .spawn(async move {
            let removed = share_inbox::prune(&root, std::time::SystemTime::now());
            if removed > 0 {
                log::info!("share: cleared {removed} old share(s)");
            }
        })
        .detach();
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
/// A failed write is tried again this many times (2 s, 4 s, … apart),
/// each time with what the app holds then.
pub const WIDGET_RETRIES: u32 = 5;

/// The widget's snapshot as the app last wrote it ([`crate::shell::widget`]).
#[derive(Default)]
pub struct WidgetFeed {
    /// Where the snapshot goes; `None` when this bundle has no widget.
    path: Option<PathBuf>,
    bridge: Option<widget::Bridge>,
    /// What was last written: an unchanged snapshot isn't written again.
    written: Option<Vec<u8>>,
    /// Whose chats the snapshot on disk holds ([`widget::owner_tag`]), as
    /// last written or as read at launch; `None` when unknown (nothing on
    /// disk worth keeping).
    owner: Option<String>,
    pending: Option<gpui_kit::Task<()>>,
    /// A write failed (the system refused the container): logged once.
    failed: bool,
    /// Writes failed in a row, and the next try ([`WIDGET_RETRIES`]).
    failures: u32,
    retry: Option<gpui_kit::Task<()>>,
    /// Snapshots written, and reloads WidgetKit took (the E2E pass).
    pub writes: u32,
    pub reloads: u32,
    /// Reloads asked for: one per change to what the file holds.
    reloads_asked: u32,
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
        Self::at(path, Some(bridge))
    }

    /// The feed for `path`, owned by whoever the snapshot already there
    /// was written for: a list still loading at launch keeps its chats.
    fn at(path: Option<PathBuf>, bridge: Option<widget::Bridge>) -> Self {
        Self {
            owner: path.as_deref().and_then(widget::read_owner),
            path,
            bridge,
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
        let bridge = self.bridge.take();
        *self = Self {
            writes: self.writes,
            reloads: self.reloads,
            ..Self::at(Some(path), bridge)
        };
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

/// Whose chats the widget shows: the account in charge of the chats (the
/// LibreChat account while LibreChat owns them), as a one-way tag.
fn widget_owner(accounts: &crate::stores::accounts::AccountsStore) -> String {
    widget::owner_tag(accounts.scope_key().as_deref())
}

/// The snapshot for what the app holds now; `None` while that isn't known
/// (the route, or a list still loading for the owner of what is on disk).
fn widget_snapshot(last_owner: Option<&str>, cx: &App) -> Option<Snapshot> {
    let state = cx.try_global::<AppState>()?;
    let stores = &state.stores;
    let l10n = cx.l10n();
    let owner = widget_owner(stores.accounts.read(cx));
    let list = stores.chat_list.read(cx);
    // A few more than shown: a chat a link can't name is left out.
    let recent = list
        .list
        .is_some()
        .then(|| list.recent(widget::MAX_CHATS + 4));
    snapshot_for(
        stores.session.read(cx).route(cx),
        recent.as_deref(),
        owner,
        last_owner,
        l10n.locale(),
        &l10n.new_chat(),
    )
}

/// The snapshot for `route` and the list (`None` while it loads), owned by
/// `owner`; `last_owner` owns what is on disk.
fn snapshot_for(
    route: Route,
    recent: Option<&[conduit_protocol::ChatSummary]>,
    owner: String,
    last_owner: Option<&str>,
    locale: &str,
    untitled: &str,
) -> Option<Snapshot> {
    let snapshot = match route {
        Route::Unknown => return None,
        Route::Onboarding | Route::SignIn | Route::ConnectionIssue => Snapshot::signed_out(locale),
        Route::Main => match recent {
            Some(recent) => Snapshot::signed_in(recent, locale, untitled),
            // Loading again for the same account: what the widget shows
            // still stands.
            None if last_owner == Some(owner.as_str()) => return None,
            // Another account (or nobody known): none of the last one's
            // chats.
            None => Snapshot::signed_in(&[], locale, untitled),
        },
    };
    Some(snapshot.owned_by(owner))
}

/// Writes the snapshot if it changed, then asks WidgetKit to read it.
pub fn write_widget(cx: &mut App) {
    let Some(feed) = cx.try_global::<Desktop>().map(|d| &d.widget) else {
        return;
    };
    if feed.path.is_none() {
        return;
    }
    let Some(snapshot) = widget_snapshot(feed.owner.as_deref(), cx) else {
        return;
    };
    write_snapshot(snapshot, cx);
}

/// Writes `snapshot` (unless it is on disk already). A failed write is
/// tried again ([`WIDGET_RETRIES`]) with what the app holds then; and when
/// what is on disk must not stand (signed out, or another account's
/// chats), the old file is taken away meanwhile.
fn write_snapshot(snapshot: Snapshot, cx: &mut App) {
    let feed = &mut cx.global_mut::<Desktop>().widget;
    let Some(path) = feed.path.clone() else {
        return;
    };
    let bytes = snapshot.to_json();
    if feed.written.as_ref() == Some(&bytes) {
        feed.owner = snapshot.owner;
        return;
    }
    match widget::write(&path, &bytes) {
        Ok(()) => {
            feed.written = Some(bytes);
            feed.owner = snapshot.owner.clone();
            feed.writes += 1;
            feed.failed = false;
            feed.failures = 0;
            feed.retry = None;
            widget_file_changed(feed);
            log::debug!(
                "widget: snapshot written ({} chats, signed in: {})",
                snapshot.chats.len(),
                snapshot.signed_in
            );
        }
        Err(e) => {
            if !feed.failed {
                log::warn!("widget: the snapshot could not be written: {}", e.kind());
            }
            feed.failed = true;
            let stale = !snapshot.signed_in || feed.owner != snapshot.owner;
            if stale && widget::remove(&path).is_ok() {
                feed.written = None;
                feed.owner = None;
                widget_file_changed(feed);
            }
            feed.failures += 1;
            schedule_widget_retry(cx);
        }
    }
}

/// What the widget's file holds changed (written, or taken away): WidgetKit
/// reads it again now, not at its timeline's next entry. Every change to
/// the file goes through here.
fn widget_file_changed(feed: &mut WidgetFeed) {
    feed.reloads_asked += 1;
    if feed.bridge.as_ref().is_some_and(|b| b.reload_all()) {
        feed.reloads += 1;
    }
}

/// How long the `failures`th failed write in a row waits before the next
/// try; `None` past [`WIDGET_RETRIES`].
fn widget_retry_delay(failures: u32) -> Option<Duration> {
    (1..=WIDGET_RETRIES)
        .contains(&failures)
        .then(|| Duration::from_secs(1 << failures))
}

fn schedule_widget_retry(cx: &mut App) {
    let delay = widget_retry_delay(cx.global::<Desktop>().widget.failures);
    let task = delay.map(|delay| {
        cx.spawn(async move |cx| {
            cx.background_executor().timer(delay).await;
            cx.update(|cx| {
                if cx.has_global::<Desktop>() {
                    cx.global_mut::<Desktop>().widget.retry = None;
                }
                write_widget(cx);
            });
        })
    });
    cx.global_mut::<Desktop>().widget.retry = task;
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
    main_window_leaving(cx);
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
    #[cfg(not(target_os = "macos"))]
    let _ = cx;
}

/// The main window leaves the screen: hidden to the menu bar or closed,
/// by its close button, ⌘W or Window › Close Window. Every one of those
/// comes here, so the chat it shows is left once and nothing reads it
/// while the window is away.
pub fn main_window_leaving(cx: &mut App) {
    if let Some(view) = cx
        .try_global::<AppState>()
        .and_then(|s| s.main_view.clone())
    {
        cx.defer(move |cx| view.update(cx, |m, cx| m.leaving_screen(cx)));
    }
}

fn main_chat_pane(cx: &App) -> Option<Entity<crate::views::chat_pane::ChatPane>> {
    let view = cx.try_global::<AppState>()?.main_view.clone()?;
    Some(view.read(cx).chat_pane.clone())
}

/// How long a quit waits for the daemon to store the reads below.
const QUIT_READ_LIMIT: Duration = Duration::from_secs(2);

/// As the app quits, the chats on screen (the main window's, Quick Ask's)
/// are left, and read up to now. The daemon stops right after, so the
/// reads are waited for, and one that failed or was not answered in time
/// is logged by its chat's id.
pub fn read_shown_chats_on_quit(cx: &mut App) {
    let mut reads = Vec::new();
    if let Some(pane) = main_chat_pane(cx) {
        reads.extend(pane.update(cx, |p, cx| p.leave_on_quit(cx)));
    }
    if let Some((_, view)) = cx.try_global::<Desktop>().and_then(|d| d.quick_ask.clone()) {
        reads.extend(view.update(cx, |v, cx| v.leave_on_quit(cx)));
    }
    if reads.is_empty() {
        return;
    }
    let waiting = std::rc::Rc::new(std::cell::RefCell::new(
        reads.iter().map(|(id, _)| id.clone()).collect::<Vec<_>>(),
    ));
    let reads = futures::future::join_all(reads.into_iter().map(|(id, read)| {
        let waiting = waiting.clone();
        async move {
            let result = read.await;
            waiting.borrow_mut().retain(|w| *w != id);
            if let Err(error) = result {
                log::warn!("quit: chat {id} was not read ({:?})", error.code);
            }
        }
    }));
    if cx
        .foreground_executor()
        .block_with_timeout(QUIT_READ_LIMIT, reads)
        .is_err()
    {
        log::warn!(
            "quit: chats {:?} were not read within {QUIT_READ_LIMIT:?}",
            waiting.borrow()
        );
    }
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
    main_window_leaving(cx);
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
    #[cfg(not(target_os = "macos"))]
    let _ = cx;
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

/// What notifies: `turn.finished` is unscoped (it comes for chats that are
/// not open), `channels.posted` too (someone else posted in a channel not in
/// front), and `notifications.answered` (an answer finished on another
/// device).
pub(crate) fn follow_alerts(connection: &Entity<ConnectionStore>, cx: &mut App) {
    connection.update(cx, |c, _| {
        c.subscribe(
            NOTIFICATIONS_KEY,
            &[
                events::TURN_FINISHED,
                events::CHANNELS_POSTED,
                events::NOTIFICATIONS_ANSWERED,
            ],
            vec![],
        )
    });
}

/// Settings › General's "Notify When an Answer Finishes" and "Notify About
/// Channel Messages" (before the Notifications pane): one turned off there
/// is turned off in the core's settings, once.
fn move_old_switches(cx: &mut App) {
    let Some(state) = cx.try_global::<AppState>() else {
        return;
    };
    let desktop = state.settings.read(cx).prefs.desktop.clone();
    if desktop.notifications_moved {
        return;
    }
    let patch = NotificationSettingsPatch {
        answers: (!desktop.notify_answers).then_some(false),
        channels: (!desktop.notify_channels).then_some(false),
        ..Default::default()
    };
    let settings = state.settings.clone();
    if patch == NotificationSettingsPatch::default() {
        settings.update(cx, |s, cx| {
            s.set_desktop(|d| d.notifications_moved = true, cx)
        });
        return;
    }
    let notifications = state.stores.notifications.clone();
    let rpc = state.connection.read(cx).rpc();
    let call = rpc.call::<methods::NotificationsSet>(&patch);
    cx.spawn(async move |cx| {
        if let Err(e) = call.await {
            log::warn!("moving the old notification switches: {e}");
            return;
        }
        log::info!("notifications: the old General switches moved to the core");
        cx.update(|cx| {
            settings.update(cx, |s, cx| {
                s.set_desktop(|d| d.notifications_moved = true, cx)
            });
            notifications.update(cx, |s, cx| s.refresh(cx));
        });
    })
    .detach();
}

fn on_turn_finished(finished: &TurnFinished, cx: &mut App) {
    let asked = notification_scope(cx);
    // An answer Shortcuts is waiting for gets no notification: the shortcut
    // has it (crate::intents holds it until the shortcut's question ends).
    if crate::intents::hold_notification(finished, asked.clone(), cx) {
        return;
    }
    notify_turn_finished(finished, asked, cx);
}

/// The account in charge, as a notification raised now records it: it is
/// shown only while that account still is ([`route_via`], [`post`]).
pub(crate) fn notification_scope(cx: &App) -> Option<String> {
    cx.try_global::<AppState>()?
        .stores
        .accounts
        .read(cx)
        .scope_key()
}

/// The answer notification for `finished`, raised while `asked` was the
/// account in charge, as the core routes it.
pub(crate) fn notify_turn_finished(finished: &TurnFinished, asked: Option<String>, cx: &mut App) {
    let Some(kind) = notify::kind_for(notify::Outcome::of(
        finished.ok,
        finished.queued || finished.held,
    )) else {
        return;
    };
    let on_screen = on_screen(cx);
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
    let level = match kind {
        NotificationKind::Ready => NoticeLevel::Info,
        NotificationKind::Failed => NoticeLevel::Warning,
    };
    route(
        NotificationRouteParams {
            kind: NotifyKind::Answer,
            foreground: on_screen.app_active,
            viewing: on_screen.shows(&finished.chat_id),
            alert: true,
            mention: false,
            direct: false,
        },
        n,
        level,
        OpenRequest::Chat {
            id: finished.chat_id.clone(),
        },
        asked,
        cx,
    );
}

/// Someone else posted in a channel: the core decides by the settings and
/// the channel's own (the daemon's `alert`), mobile's rules.
fn on_channel_posted(posted: &conduit_protocol::ChannelPosted, cx: &mut App) {
    let on_screen = on_screen(cx);
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
    route(
        NotificationRouteParams {
            kind: NotifyKind::ChannelMessage,
            foreground: on_screen.app_active,
            viewing: on_screen.shows_channel(&posted.channel_id),
            alert: posted.alert,
            mention: posted.mention,
            direct: posted.kind == ChannelKind::Dm,
        },
        n,
        NoticeLevel::Info,
        OpenRequest::Channel {
            id: posted.channel_id.clone(),
        },
        notification_scope(cx),
        cx,
    );
}

/// Asks the core what `n`, raised while `asked` was the account in
/// charge ([`notification_scope`]), does, then does it.
fn route(
    params: NotificationRouteParams,
    n: notify::Notification,
    level: NoticeLevel,
    open: OpenRequest,
    asked: Option<String>,
    cx: &mut App,
) {
    let Some(state) = cx.try_global::<AppState>() else {
        return;
    };
    let rpc = state.connection.read(cx).rpc();
    let accounts = state.stores.accounts.clone();
    route_via(rpc, (accounts, asked), params, n, level, open, cx);
}

/// Whether `asked`, the account in charge when a notification was raised,
/// still is: once another one is, the notification (of the last one's chat
/// or channel) is dropped. Checked when the core's answer lands, and again
/// right before a system notification is posted.
fn still_in_charge(
    accounts: &Entity<crate::stores::accounts::AccountsStore>,
    asked: &Option<String>,
    cx: &App,
) -> bool {
    let same = accounts.read(cx).scope_key() == *asked;
    if !same {
        log::info!("notification: dropped, another account is in charge now");
    }
    same
}

/// [`route`] over `rpc`.
fn route_via(
    rpc: crate::stores::rpc::Rpc,
    (accounts, asked): RaisedFor,
    params: NotificationRouteParams,
    n: notify::Notification,
    level: NoticeLevel,
    open: OpenRequest,
    cx: &mut App,
) {
    let call = rpc.call::<methods::NotificationsRoute>(&params);
    cx.spawn(async move |cx| match call.await {
        Ok(route) => cx.update(|cx| {
            if still_in_charge(&accounts, &asked, cx) {
                present(route, n, level, open, (accounts, asked), cx)
            }
        }),
        Err(e) => log::warn!("notifications.route: {e}"),
    })
    .detach();
}

/// The account a notification was raised for, and where to read the one in
/// charge, for the check right before it is posted.
type RaisedFor = (
    Entity<crate::stores::accounts::AccountsStore>,
    Option<String>,
);

fn present(
    route: NotificationRoute,
    mut n: notify::Notification,
    level: NoticeLevel,
    open: OpenRequest,
    raised_for: RaisedFor,
    cx: &mut App,
) {
    log::info!(
        "notification: {}{}",
        match route.surface {
            NotifySurface::Banner => "banner",
            NotifySurface::System => "system",
            NotifySurface::Silent => "silent",
            NotifySurface::Suppressed | NotifySurface::Unknown => "none",
        },
        if route.cue { " with the cue" } else { "" }
    );
    if cx.has_global::<Desktop>() {
        let routed = &mut cx.global_mut::<Desktop>().routed;
        routed.push(Routed {
            id: n.id.clone(),
            surface: route.surface,
            cue: route.cue,
            system_sound: route.system_sound,
        });
        let excess = routed.len().saturating_sub(64);
        routed.drain(..excess);
    }
    match route.surface {
        NotifySurface::Banner => {
            if route.cue {
                play_cue();
            }
            banner(&n, level, open, cx);
        }
        // The system notification makes its own sound.
        NotifySurface::System => {
            n.sound = route.system_sound;
            post(n, raised_for, cx);
        }
        NotifySurface::Silent => {
            if route.cue {
                play_cue();
            }
        }
        NotifySurface::Suppressed | NotifySurface::Unknown => {}
    }
}

/// The in-app banner: a toast with the notification's words and Open.
fn banner(n: &notify::Notification, level: NoticeLevel, open: OpenRequest, cx: &mut App) {
    let Some(state) = cx.try_global::<AppState>() else {
        return;
    };
    let toasts = state.stores.toasts.clone();
    let l10n = cx.l10n().clone();
    let message = format!("{} \u{2014} {}", n.title, n.body);
    let run = crate::stores::toasts::Retry::new(move |cx| {
        log::info!("banner: opening its {}", describe(&open));
        if let Some(shell) = shell(cx) {
            shell.update(cx, |s, cx| s.push(open.clone(), cx));
        }
        show_main(cx);
        drain(cx);
    });
    toasts.update(cx, |t, cx| {
        t.show_with_action(level, message, l10n.notification_view_action(), run, cx)
    });
}

/// The notification cue ("Sound Always"): the system's Glass sound.
fn play_cue() {
    #[cfg(target_os = "macos")]
    crate::shell::macos::play_sound("Glass");
}

/// E2E: the app counts as behind other apps (true) or as it is (false).
pub fn set_e2e_background(on: bool, cx: &mut App) {
    if cx.has_global::<Desktop>() {
        cx.global_mut::<Desktop>().e2e_background = on;
    }
}

/// What one notification did (E2E).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Routed {
    /// The notification's identifier (`chat:…`, `channel:…`).
    pub id: String,
    pub surface: NotifySurface,
    pub cue: bool,
    pub system_sound: bool,
}

/// E2E: what each notification did, newest last.
pub fn routed_notifications(cx: &App) -> Vec<Routed> {
    cx.try_global::<Desktop>()
        .map(|d| d.routed.clone())
        .unwrap_or_default()
}

/// What the user can see now, for the core's decision.
pub fn on_screen(cx: &mut App) -> OnScreen {
    let mut out = OnScreen::default();
    let Some(state) = cx.try_global::<AppState>() else {
        return out;
    };
    if cx.try_global::<Desktop>().is_some_and(|d| d.e2e_background) {
        return out;
    }
    let navigation = state.stores.navigation.clone();
    #[cfg(target_os = "macos")]
    {
        let active = crate::shell::macos::app_is_active();
        out.app_active = active;
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

/// Delivers `n`, asking for permission first if the system hasn't asked;
/// not once another account than the one it was raised for is in charge,
/// which the first prompt can leave time for.
fn post(n: notify::Notification, raised_for: RaisedFor, cx: &mut App) {
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
            let (accounts, asked) = raised_for;
            let sent = cx.update(|cx| {
                if !still_in_charge(&accounts, &asked, cx) {
                    return None;
                }
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
    let _ = (n, raised_for, cx);
}

/// A notification was clicked: the main window on that chat.
#[cfg(target_os = "macos")]
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
    let state = cx.try_global::<AppState>()?;
    let (stores, settings) = (state.stores.clone(), state.settings.clone());
    let (w, h) = crate::shell::placement::QUICK_ASK_SIZE;
    let bounds = Bounds::centered(None, size(px(w as f32), px(h as f32)), cx);
    let options = cw::quick_ask_options(bounds, true);
    let (handle, view) = match cw::open_window_clear_root(options, cx, |window, cx| {
        cx.new(|cx| QuickAskView::new(stores, settings, window, cx))
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
        view.update(cx, |v, cx| {
            v.set_shown(true, cx);
            v.focus_composer(window, cx);
        })
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
    if let Some((_, view)) = cx.try_global::<Desktop>().and_then(|d| d.quick_ask.clone()) {
        cx.defer(move |cx| view.update(cx, |v, cx| v.set_shown(false, cx)));
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
            if quick_ask_visible(cx) && !quick_ask_key(cx) && focus_left_quick_ask(cx) {
                hide_quick_ask(cx);
            }
        });
    })
    .detach();
}

/// Whether focus left the panel for another app (no key window of ours),
/// or for the main window or Settings; not for one of our own panels (a
/// file picker, an alert), which keep it up.
#[cfg(target_os = "macos")]
fn focus_left_quick_ask(cx: &mut App) -> bool {
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
    let same = |a: &Option<objc2::rc::Retained<objc2_app_kit::NSWindow>>| match (&key, a) {
        (Some(k), Some(w)) => objc2::rc::Retained::as_ptr(k) == objc2::rc::Retained::as_ptr(w),
        _ => false,
    };
    key.is_none() || same(&main) || same(&settings)
}

/// Off the Mac the panel stays up (its focus handling is a later phase's).
#[cfg(not(target_os = "macos"))]
fn focus_left_quick_ask(_: &mut App) -> bool {
    false
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
            // Quick Ask's chats are ordinary chats, as its sends are (no
            // folder, no Temporary switch shown there).
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

// ── The Services menu ──────────────────────────────────────────────────────

/// Keeps the Services provider [`services::install`] set while the app
/// launched, and acts on what it receives.
#[cfg(target_os = "macos")]
pub fn install_services(
    installed: Option<(
        objc2::rc::Retained<services::Provider>,
        mpsc::UnboundedReceiver<ServiceRequest>,
    )>,
    cx: &mut App,
) {
    let Some((provider, mut requests)) = installed else {
        return;
    };
    if cx.has_global::<Desktop>() {
        cx.global_mut::<Desktop>().platform.services = Some(provider);
    }
    cx.spawn(async move |cx| {
        while let Some(request) = requests.next().await {
            cx.update(|cx| cx.defer(move |cx| on_service(request, cx)));
        }
    })
    .detach();
}

/// The Services provider (the E2E pass calls it as the Services menu does).
#[cfg(target_os = "macos")]
pub fn services_provider(cx: &App) -> Option<objc2::rc::Retained<services::Provider>> {
    cx.try_global::<Desktop>()?.platform.services.clone()
}

/// What a Services item asked for: "Ask Conduit" quotes the selection in
/// Quick Ask, or in a new chat when Quick Ask is off, can't ask yet (no
/// account, not connected) or holds an unsent draft; "New Conduit Chat With Selection" puts it in a
/// new chat as it is. Nothing is sent.
pub fn on_service(request: ServiceRequest, cx: &mut App) {
    match request {
        ServiceRequest::Ask(text) => {
            let quoted = services::quote(&text);
            let quick_ask = cx
                .try_global::<AppState>()
                .is_some_and(|s| s.settings.read(cx).prefs.desktop.quick_ask);
            if !(quick_ask && ask_in_quick_ask(&quoted, cx)) {
                new_chat_with(quoted, cx);
            }
        }
        ServiceRequest::NewChat(text) => new_chat_with(text, cx),
    }
}

/// Quick Ask with `text` in a new exchange's composer, when it can ask
/// and holds nothing of the user's (an unsent draft stays as it is).
fn ask_in_quick_ask(text: &str, cx: &mut App) -> bool {
    let Some((handle, view)) = quick_ask_window(cx) else {
        return false;
    };
    if !view.read(cx).ready(cx) {
        return false;
    }
    let text = text.to_string();
    let asked = handle
        .update(cx, |_, window, cx| {
            view.update(cx, |v, cx| v.ask_about(&text, window, cx))
        })
        .unwrap_or(false);
    if asked {
        show_quick_ask(cx);
    }
    asked
}

/// A new chat in the main window with `text` in the composer.
fn new_chat_with(text: String, cx: &mut App) {
    if let Some(shell) = shell(cx) {
        shell.update(cx, |s, cx| {
            s.push(
                OpenRequest::NewChat {
                    text: Some(text),
                    files: vec![],
                },
                cx,
            )
        });
    }
    show_main(cx);
    drain(cx);
}

// ── Continuity Camera ──────────────────────────────────────────────────────

/// Puts Continuity Camera's requestor after the main window (once per
/// window) and takes what it reads: a photo or a scan from a nearby iPhone
/// or iPad, attached to the main window's composer.
#[cfg(target_os = "macos")]
pub fn install_continuity_camera(
    window: &objc2_app_kit::NSWindow,
    target: crate::shell::continuity_camera::ImportTarget,
    cx: &mut App,
) {
    let Some(desktop) = cx.try_global::<Desktop>() else {
        return;
    };
    let sender = match &desktop.platform.continuity {
        Some(sender) => sender.clone(),
        None => {
            let (sender, mut imports) = mpsc::unbounded();
            cx.spawn(async move |cx| {
                while let Some(imported) = imports.next().await {
                    // Written off the main thread (a scan can be large), then
                    // attached on it, its ticket checked there.
                    let staged = cx
                        .background_executor()
                        .spawn(async move { stage_import(imported) })
                        .await;
                    if let Some(staged) = staged {
                        cx.update(|cx| attach_staged_import(staged, cx));
                    }
                }
            })
            .detach();
            cx.global_mut::<Desktop>().platform.continuity = Some(sender.clone());
            sender
        }
    };
    crate::shell::continuity_camera::install(window, sender, target);
}

/// A photo or scan from Continuity Camera, staged where the composer reads
/// files from: its file, its name and the ticket of the + menu session it
/// was asked in.
#[cfg(target_os = "macos")]
pub(crate) struct StagedImport {
    pub path: std::path::PathBuf,
    pub name: String,
    pub target: crate::shell::continuity_camera::ImportTarget,
}

/// Saves `imported` where the composer reads files from (on the background
/// executor: a scan can be large), one folder each, named by the time it
/// came (nanoseconds), so a second photo never replaces the first before
/// the composer read it. `None` when it could not be saved.
#[cfg(target_os = "macos")]
pub(crate) fn stage_import(
    imported: crate::shell::continuity_camera::Imported,
) -> Option<StagedImport> {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    let folder = std::env::temp_dir()
        .join(crate::shell::continuity_camera::IMPORT_FOLDER)
        .join(stamp.to_string());
    let name = imported.file_name();
    let path = folder.join(&name);
    if let Err(e) =
        std::fs::create_dir_all(&folder).and_then(|()| std::fs::write(&path, &imported.bytes))
    {
        log::warn!("continuity camera: not saved ({e})");
        return None;
    }
    Some(StagedImport {
        path,
        name,
        target: imported.target,
    })
}

/// A staged photo or scan, attached to the main window's composer only
/// while its own ticket ([`Imported::target`], taken by the + menu session
/// it was asked in) still matches it, checked now, after staging (a HEIC or
/// TIFF photo goes as a JPEG, as a dropped one does).
///
/// [`Imported::target`]: crate::shell::continuity_camera::Imported::target
#[cfg(target_os = "macos")]
fn attach_staged_import(staged: StagedImport, cx: &mut App) {
    show_main(cx);
    crate::with_main_view(cx, move |view, window, cx| {
        view.chat_pane.update(cx, |p, cx| {
            p.attach_import(&staged.target, &staged.path, &staged.name, window, cx);
        })
    });
}

// ── The Dock icon's menu ───────────────────────────────────────────────────

/// The Dock icon's menu and what its items do: the phone's home-screen
/// quick actions (New Chat, Voice Call) and Quick Ask, each the way the
/// app's own link of that kind goes ([`open_request`]): a new chat in the
/// main window; a voice call in a new chat ([`start_voice_call`], never the
/// toggling Voice Call action); the Quick Ask panel.
fn install_dock_menu(cx: &mut App) {
    use crate::actions::{DockNewChat, DockQuickAsk, DockVoiceCall};
    cx.on_action(|_: &DockNewChat, cx| {
        log::info!("dock menu: new chat");
        cx.defer(|cx| {
            open_request(
                OpenRequest::NewChat {
                    text: None,
                    files: vec![],
                },
                cx,
            )
        });
    });
    cx.on_action(|_: &DockVoiceCall, cx| {
        log::info!("dock menu: voice call");
        cx.defer(|cx| open_request(OpenRequest::VoiceCall, cx));
    });
    cx.on_action(|_: &DockQuickAsk, cx| {
        log::info!("dock menu: quick ask");
        cx.defer(|cx| open_request(OpenRequest::QuickAsk { text: None }, cx));
    });
    set_dock_menu(cx);
}

/// The Dock menu's items, in the app's language (again when it changes).
pub fn set_dock_menu(cx: &mut App) {
    use crate::actions::{DockNewChat, DockQuickAsk, DockVoiceCall};
    let l10n = cx.l10n().clone();
    cx.set_dock_menu(dock_menu_items(
        &l10n,
        DockNewChat,
        DockVoiceCall,
        DockQuickAsk,
    ));
}

/// The Dock menu's titles and actions, in order.
pub fn dock_menu_items(
    l10n: &crate::l10n::L10n,
    new_chat: impl gpui_kit::Action,
    voice_call: impl gpui_kit::Action,
    quick_ask: impl gpui_kit::Action,
) -> Vec<gpui_kit::MenuItem> {
    vec![
        gpui_kit::MenuItem::action(l10n.new_chat(), new_chat),
        gpui_kit::MenuItem::action(l10n.voice_call_title(), voice_call),
        gpui_kit::MenuItem::action(l10n.desktop_tray_quick_ask(), quick_ask),
    ]
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
mod route_tests {
    use gpui_kit::TestAppContext;

    use super::*;
    use crate::stores::accounts::tests::{account, list};
    use crate::stores::rpc::fake::FakeDaemon;

    fn ready(chat: &str) -> notify::Notification {
        notify::notification(
            NotificationKind::Ready,
            chat,
            Some("Seed swap notes"),
            &notify::Words {
                untitled: "New Chat",
                ready: "Answer ready",
                failed: "Answer failed",
            },
        )
    }

    fn params() -> NotificationRouteParams {
        NotificationRouteParams {
            kind: NotifyKind::Answer,
            foreground: false,
            viewing: false,
            alert: true,
            mention: false,
            direct: false,
        }
    }

    /// The core's answer is for the account it was asked under: once
    /// another account is in charge, the notification of the last one's
    /// chat is not shown (nor recorded as routed); under the same account
    /// it is.
    #[gpui_kit::test]
    fn a_route_answered_after_an_account_switch_is_dropped(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::NotificationsRoute>(NotificationRoute {
            surface: NotifySurface::Silent,
            cue: false,
            system_sound: false,
        });
        let scratch = std::env::temp_dir().join(format!("conduit-route-{}", std::process::id()));
        let stores = cx.update(|cx| {
            install_without_services(cx);
            crate::stores::Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
        });
        let accounts = stores.accounts.clone();
        let rpc = daemon.rpc();
        let open = || OpenRequest::Chat { id: "c1".into() };

        let held = daemon.hold::<methods::NotificationsRoute>();
        cx.update(|cx| {
            let asked = accounts.read(cx).scope_key();
            route_via(
                rpc.clone(),
                (accounts.clone(), asked),
                params(),
                ready("c1"),
                NoticeLevel::Info,
                open(),
                cx,
            )
        });
        cx.run_until_parked();
        stores.accounts.update(cx, |a, cx| {
            a.adopt(
                list(vec![
                    account("a", "Avery", false, true),
                    account("b", "Blake", true, true),
                ]),
                cx,
            )
        });
        drop(held);
        cx.run_until_parked();
        assert!(
            cx.update(|cx| routed_notifications(cx)).is_empty(),
            "Avery's answer was shown under Blake"
        );

        cx.update(|cx| {
            let asked = accounts.read(cx).scope_key();
            route_via(
                rpc.clone(),
                (accounts.clone(), asked),
                params(),
                ready("c2"),
                NoticeLevel::Info,
                open(),
                cx,
            )
        });
        cx.run_until_parked();
        let routed = cx.update(|cx| routed_notifications(cx));
        assert_eq!(routed.len(), 1);
        assert_eq!(routed[0].surface, NotifySurface::Silent);
    }

    /// An answer that finished while Ask Conduit waited is held with the
    /// account it finished under: released once another account is in
    /// charge, it is not shown under that one.
    #[gpui_kit::test]
    fn a_held_answer_released_after_an_account_switch_is_dropped(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::NotificationsRoute>(NotificationRoute {
            surface: NotifySurface::Silent,
            cue: false,
            system_sound: false,
        });
        let scratch = std::env::temp_dir().join(format!("conduit-held-{}", std::process::id()));
        let stores = cx.update(|cx| {
            install_without_services(cx);
            crate::stores::Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
        });
        let accounts = stores.accounts.clone();
        let finished = TurnFinished {
            chat_id: "c1".into(),
            message_id: "c1-answer".into(),
            ok: true,
            code: None,
            queued: false,
            held: false,
        };
        let mut held = crate::intents::HeldNotifications::default();
        held.begin();
        let asked = cx.update(|cx| accounts.read(cx).scope_key());
        assert!(held.hold(&finished, asked));

        stores.accounts.update(cx, |a, cx| {
            a.adopt(
                list(vec![
                    account("a", "Avery", false, true),
                    account("b", "Blake", true, true),
                ]),
                cx,
            )
        });
        let due = held.end(None);
        assert_eq!(due.len(), 1);
        for (finished, asked) in due {
            cx.update(|cx| {
                route_via(
                    daemon.rpc(),
                    (accounts.clone(), asked),
                    params(),
                    ready(&finished.chat_id),
                    NoticeLevel::Info,
                    OpenRequest::Chat {
                        id: finished.chat_id.clone(),
                    },
                    cx,
                )
            });
        }
        cx.run_until_parked();
        assert!(
            cx.update(|cx| routed_notifications(cx)).is_empty(),
            "Avery's answer was shown under Blake"
        );
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

#[cfg(test)]
mod widget_tests {
    use conduit_protocol::{ChatSummary, PrimaryAccount};
    use gpui_kit::TestAppContext;

    use super::*;
    use crate::stores::accounts::AccountsStore;
    use crate::stores::accounts::tests::two;
    use crate::stores::rpc::fake::FakeDaemon;

    fn chat(id: &str, title: &str) -> ChatSummary {
        ChatSummary {
            id: id.into(),
            title: title.into(),
            updated_at_ms: 1,
            pinned: false,
            archived: false,
            folder_id: None,
            model: None,
            tags: vec![],
            shared: false,
            read_only: false,
            unread: false,
            menu: Default::default(),
        }
    }

    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("conduit-widget-feed-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// LibreChat owns the chats: another LibreChat account is another
    /// owner, though the parked Open WebUI account stays the same.
    #[test]
    fn the_widget_belongs_to_the_account_in_charge_of_the_chats() {
        let mut store = AccountsStore::new(FakeDaemon::new().rpc());
        let mut list = two();
        list.primary = PrimaryAccount::LibreChat;
        list.active_libre_chat_account_id = Some("lc-river".into());
        store.list = Some(list.clone());
        let first = widget_owner(&store);
        list.active_libre_chat_account_id = Some("lc-meadow".into());
        store.list = Some(list);
        assert_ne!(widget_owner(&store), first);
    }

    #[test]
    fn a_list_loading_keeps_only_its_own_owners_chats() {
        let snap = |last: Option<&str>| {
            snapshot_for(Route::Main, None, "b".into(), last, "en", "New Chat")
        };
        // The same owner's list loading again: what is shown stands.
        assert_eq!(snap(Some("b")), None);
        // Another owner, or nobody known: no chats of the last one.
        for last in [Some("a"), None] {
            let s = snap(last).unwrap();
            assert!(s.signed_in && s.chats.is_empty());
            assert_eq!(s.owner.as_deref(), Some("b"));
        }
        let loaded = snapshot_for(
            Route::Main,
            Some(&[chat("c1", "Seed swap notes")]),
            "b".into(),
            Some("a"),
            "en",
            "New Chat",
        )
        .unwrap();
        assert_eq!(loaded.chats.len(), 1);
    }

    /// At launch the feed knows whose snapshot is on disk: the same
    /// account's list loading keeps it, instead of "No chats yet".
    #[test]
    fn the_snapshot_on_disk_keeps_its_owner_across_a_launch() {
        let dir = scratch("launch");
        let path = dir.join(widget::FILE_NAME);
        let owner = widget::owner_tag(Some("a"));
        let old = Snapshot::signed_in(&[chat("c1", "Seed swap notes")], "en", "New Chat")
            .owned_by(owner.clone());
        widget::write(&path, &old.to_json()).unwrap();
        let feed = WidgetFeed::at(Some(path), None);
        assert_eq!(feed.owner.as_deref(), Some(owner.as_str()));
        assert_eq!(
            snapshot_for(Route::Main, None, owner, feed.owner.as_deref(), "en", "x"),
            None
        );
    }

    /// Signing out while the container refuses the write: the old titles
    /// don't stay on disk, and the write is tried again (a few times).
    #[gpui_kit::test]
    fn a_refused_sign_out_write_takes_the_titles_away_and_tries_again(cx: &mut TestAppContext) {
        let dir = scratch("refused");
        let path = dir.join(widget::FILE_NAME);
        let owner = widget::owner_tag(Some("a"));
        let old = Snapshot::signed_in(&[chat("c1", "Seed swap notes")], "en", "New Chat")
            .owned_by(owner.clone());
        widget::write(&path, &old.to_json()).unwrap();
        // The temporary file can't be made: every write fails.
        let tmp = dir.join(format!(".{}.{}.tmp", widget::FILE_NAME, std::process::id()));
        std::fs::create_dir_all(tmp.join("inner")).unwrap();
        cx.update(|cx| {
            install_without_services(cx);
            cx.global_mut::<Desktop>().widget.redirect(path.clone());
            write_snapshot(Snapshot::signed_out("en").owned_by(owner.clone()), cx);
        });
        assert!(!path.exists(), "the last account's titles are gone");
        cx.update(|cx| {
            let feed = &cx.global::<Desktop>().widget;
            assert_eq!(
                feed.reloads_asked, 1,
                "WidgetKit drops the timeline it built"
            );
            assert_eq!(feed.failures, 1);
            assert!(feed.retry.is_some(), "tried again");
        });
        cx.update(|cx| {
            for _ in 0..WIDGET_RETRIES {
                write_snapshot(Snapshot::signed_out("en").owned_by(owner.clone()), cx);
            }
            let feed = &cx.global::<Desktop>().widget;
            assert!(feed.retry.is_none(), "but not forever");
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui_kit::{ClipboardItem, Image, ImageFormat};

    #[test]
    fn the_clipboard_link_takes_only_text() {
        let text = clipboard_compose(Some(&ClipboardItem::new_string(
            "  Packing list for the ferry \n".into(),
        )));
        assert_eq!(text.text.as_deref(), Some("Packing list for the ferry"));
        assert!(text.images.is_empty() && text.files.is_empty());

        // A copied picture or copied files are never attached from a link:
        // any page or app can open conduit://clipboard, and attaching
        // uploads at once. The new chat opens empty (⌘V attaches them).
        let picture = Image::from_bytes(ImageFormat::Png, vec![0x89, b'P', b'N', b'G']);
        let image = clipboard_compose(Some(&ClipboardItem::new_image(&picture)));
        assert_eq!(image, Compose::default());
        let files = clipboard_compose(Some(&ClipboardItem {
            entries: vec![gpui_kit::ClipboardEntry::ExternalPaths(
                gpui_kit::ExternalPaths(vec!["/tmp/synthetic-notes.txt".into()].into()),
            )],
        }));
        assert_eq!(files, Compose::default());

        // Blank text is no text; nothing copied still opens a new chat.
        let blank = clipboard_compose(Some(&ClipboardItem::new_string(" \n ".into())));
        assert_eq!(blank, Compose::default());
        assert_eq!(clipboard_compose(None), Compose::default());

        let long = "x".repeat(deep_link::MAX_TEXT + 10);
        let cut = clipboard_compose(Some(&ClipboardItem::new_string(long)));
        assert_eq!(
            cut.text.map(|t| t.chars().count()),
            Some(deep_link::MAX_TEXT)
        );
    }

    /// A photo is staged (off the main thread) with its own ticket, to be
    /// checked when it is attached.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_continuity_photo_is_staged_with_its_ticket() {
        use crate::shell::continuity_camera::{ImportTarget, Imported};
        let target = ImportTarget {
            scope: Some("a".into()),
            draft: None,
            round: 3,
        };
        let staged = stage_import(Imported {
            bytes: vec![0x89, b'P', b'N', b'G'],
            extension: "png",
            target: target.clone(),
        })
        .expect("staged");
        assert_eq!(staged.name, "Photo.png");
        assert_eq!(staged.target, target);
        assert_eq!(
            std::fs::read(&staged.path).unwrap(),
            vec![0x89, b'P', b'N', b'G']
        );
    }

    #[test]
    fn the_dock_menu_has_the_phones_quick_actions_and_quick_ask_in_every_language() {
        use crate::actions::{DockNewChat, DockQuickAsk, DockVoiceCall};
        let titles = |locale: &str| -> Vec<String> {
            let l = crate::l10n::L10n::new(locale);
            dock_menu_items(&l, DockNewChat, DockVoiceCall, DockQuickAsk)
                .into_iter()
                .map(|item| match item {
                    gpui_kit::MenuItem::Action { name, .. } => name.to_string(),
                    _ => String::new(),
                })
                .collect()
        };
        assert_eq!(titles("en"), vec!["New Chat", "Voice Call", "Quick Ask"]);
        for locale in crate::l10n::LOCALES {
            let words = titles(locale);
            assert_eq!(words.len(), 3, "{locale}");
            assert!(words.iter().all(|w| !w.is_empty()), "{locale}: {words:?}");
        }
        assert_ne!(titles("de"), titles("en"));
    }
}
