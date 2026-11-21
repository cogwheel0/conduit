//! `--fixture <mode>`: the sidebar and the ⌘K palette in a real window over
//! a canned daemon with synthetic chats, for checks that need AppKit but no
//! server.
//!
//! * `a11y`: reads the AccessKit tree GPUI hands to AppKit for the sidebar
//!   (plain, a row hovered, selection mode) and the palette (empty and with
//!   a query), and fails when a control has no label. Prints one
//!   `FIXTURE <screen> <json>` line per screen; `tests/a11y.rs` runs it.
//! * `perf [comfortable]`: 5,000 chats, the list scrolled a step every
//!   frame for 20 s (down, then back up); prints the frame intervals'
//!   percentiles as `FIXTURE perf …`.
//! * `shell [--shots <dir>]`: Settings › Desktop and the Quick Ask window,
//!   their AccessKit trees as `FIXTURE <screen> <json>` lines
//!   (`tests/shell_a11y.rs`), and screenshots light and dark when asked.
//!   No hotkey, menu-bar item or login item is touched.
//!
//! Nothing here touches the user's data: no daemon starts (the connection
//! has no master key), and preferences live in a temporary folder.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use chrono::{Duration as Days, Local};
use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::ConduitAssets;
use conduit_components::views::shell::MainWindowFrame;
use conduit_components::window as cw;
use conduit_daemon::paths::{AppPaths, Flavor};
use conduit_daemon::protocol::{codes, error};
use conduit_protocol::{
    Capabilities, ChatList, ChatSearchHit, ChatSearchResults, ChatSummary, FolderContents,
    FolderSummary, ServerReachability, ServerStatus,
};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyWindowHandle, App, AsyncApp, Bounds, Context, Entity, Window, div, point, px, size,
};
use serde_json::{Value, json};

use crate::l10n::locale;
use crate::prefs::DensityChoice;
use crate::stores::Stores;
use crate::stores::accounts::AccountsStore;
use crate::stores::chat_list::ChatListStore;
use crate::stores::connection::{ConnectionOptions, ConnectionStore};
use crate::stores::navigation::{Area, NavigationStore};
use crate::stores::palette::PaletteStore;
use crate::stores::router::RouterStore;
use crate::stores::rpc::{CallFuture, Daemon, Rpc};
use crate::stores::session::SessionStore;
use crate::stores::settings::SettingsStore;
use crate::stores::toasts::ToastStore;
use crate::stores::ui_requests::UiRequestsStore;
use crate::views::palette::PaletteView;
use crate::views::sidebar::SidebarView;

/// Synthetic chats: folders (one nested), pinned, archived, spread over two
/// years. Titles are made up.
pub fn synthetic(n: usize) -> ChatList {
    const TOPICS: &[&str] = &[
        "Sourdough starter schedule",
        "Orbital period of a moon",
        "Raised bed layout",
        "Rate limiter design",
        "Regex for ISO dates",
        "Quilt pattern maths",
        "Jazz chord voicings",
        "Why tides lag the moon",
        "Bike fit notes",
        "Trip budget for Lisbon",
        "Dialing in espresso",
        "Migration plan",
    ];
    let now = Local::now();
    let folders = vec![
        folder("f-garden", "Garden", None, true),
        folder("f-seeds", "Seeds", Some("f-garden"), false),
        folder("f-side", "Side project", None, false),
        folder("f-recipes", "Recipes", None, false),
    ];
    let chats = (0..n)
        .map(|i| {
            // Most recent first, as the daemon sorts them.
            let minutes = (i as i64) * (if n > 100 { 160 } else { 1100 }) + 3;
            let at = now - Days::minutes(minutes);
            let folder_id = match i % 9 {
                2 => Some("f-garden"),
                5 => Some("f-side"),
                7 => Some("f-seeds"),
                8 if i % 2 == 0 => Some("f-recipes"),
                _ => None,
            };
            ChatSummary {
                unread: false,
                read_only: false,
                id: format!("c{i:05}"),
                title: format!("{} {}", TOPICS[i % TOPICS.len()], i / TOPICS.len() + 1),
                updated_at_ms: at.timestamp_millis(),
                pinned: i == 4 || i == 17,
                archived: i % 23 == 22,
                folder_id: folder_id.map(Into::into),
                model: None,
                tags: vec![],
                shared: false,
                menu: crate::fixture::owui_chat_menu(),
            }
        })
        .collect::<Vec<_>>();
    let archived = chats.iter().filter(|c| c.archived).count() as i64;
    ChatList {
        chats: chats.into_iter().filter(|c| !c.archived).collect(),
        has_more: false,
        archived_count: archived,
        archived_visible: false,
        folders,
        folders_enabled: true,
    }
}

fn folder(id: &str, name: &str, parent: Option<&str>, expanded: bool) -> FolderSummary {
    FolderSummary {
        id: id.into(),
        name: name.into(),
        parent_id: parent.map(Into::into),
        expanded,
        shared: false,
        owner_name: None,
        can_write: true,
        icon: None,
    }
}

/// Answers the sidebar's calls from [`synthetic`] data.
struct CannedDaemon {
    list: ChatList,
    /// How many items each other area lists (the perf pass's sections).
    areas: usize,
}

/// Every area on, every workspace section managed: the perf pass's
/// account.
pub fn all_areas() -> Capabilities {
    Capabilities {
        bulk_selection: true,
        notes: true,
        channels: true,
        hermes: true,
        terminal: true,
        workspace: true,
        workspace_models: true,
        workspace_knowledge: true,
        workspace_prompts: true,
        workspace_tools: true,
        workspace_skills: true,
        calendar: true,
        automations: true,
        scheduled_tasks: true,
        folders: true,
        ..Default::default()
    }
}

/// `n` synthetic items for each listed area: notes, channels, Hermes
/// sessions (a tenth archived) and two terminal servers.
fn area_answer(method: &str, n: usize) -> Option<Value> {
    let day = 86_400_000_i64;
    let base = 1_767_225_600_000_i64;
    Some(match method {
        "notes.list" => json!({"notes": (0..n).map(|i| json!({
            "id": format!("note-{i}"),
            "title": format!("Field note {i}"),
            "updatedAtMs": base - i as i64 * day / 3,
            "pinned": i < 3,
            // The notes list's groups, spread as dates spread them.
            "section": match i {
                0..=5 => "today",
                6..=9 => "yesterday",
                10..=30 => "previous7Days",
                31..=90 => "previous30Days",
                _ => "older",
            },
            "preview": "- [ ] Water the **seedlings**\nCheck the [frost forecast](https://example.com).",
        })).collect::<Vec<_>>()}),
        "channels.list" => json!({"enabled": true, "channels": (0..n).map(|i| json!({
            "id": format!("channel-{i}"),
            "name": format!("channel-{i}"),
            "unread": if i % 4 == 0 { (i % 9) as i64 } else { 0 },
        })).collect::<Vec<_>>()}),
        "hermes.sessions" => json!({
            "sessions": (0..n).map(|i| json!({
                "id": format!("s{i}"), "chatId": format!("local:hermes_s{i}"),
                "title": format!("Session {i}"), "updatedAtMs": base - i as i64 * day,
                "pinned": i < 2,
            })).collect::<Vec<_>>(),
            "archived": (0..n / 10).map(|i| json!({
                "id": format!("a{i}"), "chatId": format!("local:hermes_a{i}"),
                "title": format!("Old session {i}"), "archived": true,
            })).collect::<Vec<_>>(),
        }),
        "terminal.servers" => json!({"servers": [
            {"id": "term-1", "name": "Build box", "kind": "system"},
            {"id": "term-2", "name": "Lab shell", "kind": "system"},
        ]}),
        _ => return None,
    })
}

impl Daemon for CannedDaemon {
    fn call_value(&self, method: &'static str, params: Value) -> CallFuture {
        let answer = match method {
            "chats.list" | "chats.loadMore" | "chats.setArchivedVisible" => {
                Ok(serde_json::to_value(&self.list).unwrap_or_default())
            }
            "sync.get" => Ok(json!({"running": false, "everCompleted": true, "online": true})),
            "chats.folder" => {
                let id = params["folderId"].as_str().unwrap_or_default();
                let folder = self.list.folders.iter().find(|f| f.id == id).cloned();
                match folder {
                    Some(folder) => Ok(serde_json::to_value(FolderContents {
                        chats: self
                            .list
                            .chats
                            .iter()
                            .filter(|c| c.folder_id.as_deref() == Some(id))
                            .cloned()
                            .collect(),
                        folder,
                    })
                    .unwrap_or_default()),
                    None => Err(error(codes::METHOD_NOT_FOUND, "no folder")),
                }
            }
            "chats.search" => {
                let q = params["query"].as_str().unwrap_or_default().to_lowercase();
                let limit = params["limit"].as_i64().unwrap_or(50) as usize;
                let hits = self
                    .list
                    .chats
                    .iter()
                    .filter(|c| {
                        q.split_whitespace()
                            .all(|w| c.title.to_lowercase().contains(w))
                    })
                    .take(limit)
                    .map(|c| ChatSearchHit {
                        chat_id: c.id.clone(),
                        title: c.title.clone(),
                        snippet: Some(format!(
                            "\u{2026}notes on \u{2068}{}\u{2069} from last week\u{2026}",
                            q.split_whitespace().next().unwrap_or_default()
                        )),
                        updated_at_ms: c.updated_at_ms,
                    })
                    .collect();
                Ok(serde_json::to_value(ChatSearchResults {
                    hits,
                    complete: true,
                })
                .unwrap_or_default())
            }
            "models.list" | "models.select" => Ok(json!({
                "models": [{"id": "fixture-model", "name": "Aster 2 Mini", "pinned": true, "capabilities": []}],
                "selectedId": "fixture-model"
            })),
            "composer.options" => Ok(
                json!({"webSearch": true, "imageGeneration": false, "tools": [], "mcpTools": []}),
            ),
            "accounts.list" => Ok(json!({
                "accounts": [{
                    "id": "acct-1",
                    "serverId": "srv-1",
                    "connection": {"id": "srv-1", "name": "Lab", "url": "https://chat.example.org", "isActive": true},
                    "user": {"name": "Avery Example", "email": "avery@example.org"},
                    "isActive": true,
                    "hasSession": true
                }],
                "activeAccountId": "acct-1",
                "addingAccount": false
            })),
            other => match area_answer(other, self.areas) {
                Some(value) if self.areas > 0 => Ok(value),
                _ => Err(error(codes::METHOD_NOT_FOUND, other)),
            },
        };
        Box::pin(async move { answer })
    }
}

/// The sidebar and palette in a frame, as the main window draws them.
struct FixtureView {
    sidebar: Entity<SidebarView>,
    palette: Entity<PaletteView>,
    /// `notes-perf`: All Notes' list pane, scrolled instead of the sidebar.
    notes: Option<Entity<crate::views::notes::list::NotesList>>,
    material: crate::shell::macos::SidebarMaterial,
    perf: Option<Perf>,
}

struct Perf {
    started: Instant,
    last: Option<Instant>,
    intervals: Vec<f64>,
    /// The sidebar's render time per frame.
    work: Vec<f64>,
    y: f32,
    down: bool,
}

impl Render for FixtureView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        self.material
            .sync(window, Some(f64::from(t.metrics.sidebar_width)));
        if let Some(perf) = &mut self.perf {
            let now = Instant::now();
            if let Some(last) = perf.last {
                perf.intervals.push((now - last).as_secs_f64() * 1000.);
            }
            perf.last = Some(now);
            perf.work
                .push(self.sidebar.read(cx).take_work().as_secs_f64() * 1000.);
            if let Some(notes) = &self.notes {
                // The notes list, by 90 pt a frame, down and back.
                let list = notes.read(cx).list_state().clone();
                let max = f32::from(list.max_offset_for_scrollbar().y);
                perf.y += if perf.down { 90. } else { -90. };
                if perf.y >= max {
                    perf.y = max;
                    perf.down = false;
                } else if perf.y <= 0. {
                    perf.y = 0.;
                    perf.down = true;
                }
                list.set_offset_from_scrollbar(point(px(0.), px(-perf.y)));
            } else {
                let handle = self.sidebar.read(cx).scroll_handle().clone();
                let max = f32::from(handle.max_offset().y);
                perf.y += if perf.down { 90. } else { -90. };
                if perf.y >= max {
                    perf.y = max;
                    perf.down = false;
                } else if perf.y <= 0. {
                    perf.y = 0.;
                    perf.down = true;
                }
                handle.set_offset(point(px(0.), px(-perf.y)));
            }
            if perf.started.elapsed() < Duration::from_secs(20) {
                window.request_animation_frame();
            }
        }
        let main = match &self.notes {
            Some(notes) => div().size_full().child(notes.clone()),
            None => div().size_full(),
        };
        let mut frame = MainWindowFrame::new(main).sidebar(self.sidebar.clone());
        if self.palette.read(cx).is_open(cx) {
            frame = frame.overlay(self.palette.clone());
        }
        frame
    }
}

/// What `--fixture` runs.
#[derive(Clone, Debug, PartialEq)]
pub enum Mode {
    A11y,
    Perf {
        comfortable: bool,
    },
    /// All Notes' list pane over 5,000 notes, scrolled while frames are
    /// timed.
    NotesPerf,
    Shell {
        shots: Option<PathBuf>,
    },
}

impl Mode {
    pub fn from_args(args: &[String]) -> Option<Self> {
        let i = args.iter().position(|a| a == "--fixture")?;
        match args.get(i + 1).map(String::as_str) {
            Some("a11y") => Some(Self::A11y),
            Some("notes-perf") => Some(Self::NotesPerf),
            Some("perf") => Some(Self::Perf {
                comfortable: args.get(i + 2).is_some_and(|a| a == "comfortable"),
            }),
            Some("shell") => Some(Self::Shell {
                shots: args
                    .iter()
                    .position(|a| a == "--shots")
                    .and_then(|j| args.get(j + 1))
                    .map(PathBuf::from),
            }),
            _ => None,
        }
    }
}

pub(crate) fn stores(rpc: Rpc, scratch: &std::path::Path, cx: &mut App) -> Stores {
    let paths = AppPaths {
        flavor: Flavor::Dev,
        user_data: scratch.join("user-data"),
        logs: scratch.join("logs"),
    };
    // No master key: the connection never starts a daemon.
    let connection = ConnectionStore::start(
        ConnectionOptions {
            paths,
            binary: PathBuf::from("/nonexistent/conduitd"),
            master_key: Err("fixture".into()),
            locale: "en".into(),
            client_version: crate::VERSION.into(),
        },
        cx,
    );
    let accounts = cx.new(|_| AccountsStore::new(rpc.clone()));
    let session = {
        let (rpc, accounts) = (rpc.clone(), accounts.clone());
        cx.new(|cx| SessionStore::new(rpc, accounts, cx))
    };
    // Selection mode needs the server's bulk capability.
    session.update(cx, |s, _| {
        s.server = Some(ServerStatus {
            active_server_id: Some("srv-1".into()),
            capabilities: Capabilities {
                bulk_selection: true,
                ..Default::default()
            },
            reachability: ServerReachability::Reachable,
            version: Some("0.13.2".into()),
            is_version_supported: true,
            max_supported_version: "0.13.2".into(),
            error_code: None,
        })
    });
    let speech = {
        let connection = connection.clone();
        let rpc = rpc.clone();
        cx.new(|cx| crate::stores::speech::SpeechStore::new(rpc, connection, cx))
    };
    let call = {
        let connection = connection.clone();
        let rpc = rpc.clone();
        cx.new(|cx| crate::stores::call::CallStore::new(rpc, connection, cx))
    };
    // A test's stores install no Apple engine: its report sink is
    // process-wide, so one test's engine would wake another test's tasks.
    #[cfg(test)]
    let apple = cx.new(|_| crate::stores::apple_models::AppleModelsStore::for_test(rpc.clone()));
    #[cfg(not(test))]
    let apple = {
        let rpc = rpc.clone();
        cx.new(|cx| crate::stores::apple_models::AppleModelsStore::new(rpc, cx))
    };
    Stores {
        connection,
        speech,
        call,
        apple,
        location: cx.new(|_| crate::stores::location::LocationStore::new(rpc.clone())),
        ui_requests: cx.new(|_| UiRequestsStore::new(rpc.clone())),
        router: cx.new(|_| RouterStore::new()),
        toasts: cx.new(|_| ToastStore::new()),
        navigation: cx.new(|_| NavigationStore::new()),
        chat_list: cx.new(|_| ChatListStore::new(rpc.clone())),
        palette: cx.new(|_| PaletteStore::new(rpc.clone())),
        areas: cx.new(|_| crate::stores::areas::AreasStore::new(rpc.clone())),
        hermes_admin: cx.new(|_| crate::stores::hermes_admin::HermesAdminStore::new(rpc.clone())),
        sections: cx.new(|_| crate::stores::sections::SectionsStore::load(None)),
        app_settings: cx.new(|_| crate::stores::app_settings::AppSettingsStore::new(rpc.clone())),
        calendar: cx.new(|_| crate::stores::calendar::CalendarStore::new(rpc.clone())),
        tasks: cx.new(|_| crate::stores::tasks::TasksStore::new(rpc.clone())),
        hermes_rooms: cx.new(|_| crate::stores::hermes_rooms::HermesRoomsStore::new(rpc.clone())),
        notifications: cx
            .new(|_| crate::stores::notifications::NotificationsStore::new(rpc.clone())),
        accounts,
        session,
    }
}

async fn settle(cx: &mut AsyncApp, ms: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(ms))
        .await;
}

/// Runs the fixture, then quits.
pub fn run(mode: Mode) {
    let scratch = std::env::temp_dir().join(format!("conduit-fixture-{}", std::process::id()));
    std::fs::create_dir_all(&scratch).ok();
    let app = gpui_kit::application().with_assets(ConduitAssets);
    app.run(move |cx: &mut App| {
        gpui_kit::init(cx);
        let settings = cx.new(|_| {
            SettingsStore::load(
                scratch.join("prefs.json"),
                false,
                locale::system_languages(),
            )
        });
        settings.update(cx, |s, cx| {
            s.set_locale(Some("en".into()), cx);
            if let Mode::Perf { comfortable: true } = mode {
                s.set_appearance(|a| a.density = DensityChoice::Comfortable, cx);
            }
            s.apply(cx);
        });
        crate::install_component_strings(cx);
        let n = if matches!(mode, Mode::Perf { .. }) {
            5_000
        } else {
            40
        };
        let notes_perf = mode == Mode::NotesPerf;
        // The perf pass's sidebar holds every area too, long ones listed in
        // full (Show All), below the 5,000 chats.
        let areas = if matches!(mode, Mode::Perf { .. }) {
            400
        } else if notes_perf {
            5_000
        } else {
            0
        };
        let rpc = Rpc::new(CannedDaemon {
            list: synthetic(n),
            areas,
        });
        let stores = stores(rpc, &scratch, cx);
        if areas > 0 {
            let capabilities = all_areas();
            stores.session.update(cx, |s, cx| {
                s.system_capabilities = Some(capabilities.clone());
                s.preview_route(Some(crate::stores::session::Route::Main), cx);
            });
            let shown = crate::stores::areas::visible_areas(&capabilities);
            stores.areas.update(cx, |a, cx| a.set_wanted(&shown, cx));
            stores.sections.update(cx, |s, cx| {
                // Under the canned account's scope, which the sidebar reads
                // once the account list is in.
                s.set_scope("account:acct-1".into(), cx);
                for area in [Area::Notes, Area::Channels, Area::Hermes] {
                    s.set_show_all(area.id(), true, cx);
                }
            });
        }
        if let Mode::Shell { shots } = mode.clone() {
            shell(stores, settings, scratch.clone(), shots, cx);
            return;
        }
        stores.accounts.update(cx, |a, cx| a.refresh(cx));
        stores.chat_list.update(cx, |c, cx| {
            c.refresh(cx);
            c.refresh_sync(cx);
        });
        let bounds = Bounds::centered(
            None,
            size(px(cw::MAIN_WINDOW_SIZE.0), px(cw::MAIN_WINDOW_SIZE.1)),
            cx,
        );
        let options = cw::window_options("Conduit fixture", bounds, true, true);
        let opened = cw::open_window_clear_root(options, cx, |window, cx| {
            let sidebar = cx.new(|cx| SidebarView::new(stores.clone(), window, cx));
            let palette = cx.new(|cx| PaletteView::new(stores.clone(), window, cx));
            let notes = notes_perf.then(|| {
                let stores = stores.clone();
                cx.new(|cx| crate::views::notes::list::NotesList::new(stores, window, cx))
            });
            cx.new(|_| FixtureView {
                sidebar,
                palette,
                notes,
                material: Default::default(),
                perf: None,
            })
        });
        let Ok((handle, view)) = opened else {
            println!("FIXTURE FAILED no window");
            cx.quit();
            return;
        };
        cx.activate(true);
        let stores = stores.clone();
        cx.spawn(async move |cx: &mut AsyncApp| {
            settle(cx, 800).await;
            let passed = match mode {
                // An unlabelled control anywhere fails the pass.
                Mode::A11y => {
                    a11y(handle, &view, &stores, &scratch, cx).await
                        && crate::e2e::unlabelled_seen() == 0
                }
                Mode::Perf { .. } | Mode::NotesPerf => perf(&view, cx).await,
                Mode::Shell { .. } => false,
            };
            println!("FIXTURE {}", if passed { "passed" } else { "FAILED" });
            cx.update(|cx| cx.quit());
        })
        .detach();
    });
}

async fn perf(view: &Entity<FixtureView>, cx: &mut AsyncApp) -> bool {
    let rows = cx.update(|cx| match &view.read(cx).notes {
        Some(notes) => notes.read(cx).rows().len(),
        None => view.read(cx).sidebar.read(cx).rows().len(),
    });
    view.update(cx, |v, cx| {
        v.perf = Some(Perf {
            started: Instant::now(),
            last: None,
            intervals: vec![],
            work: vec![],
            y: 0.,
            down: true,
        });
        cx.notify();
    });
    settle(cx, 21_000).await;
    let (mut v, mut w) = cx.update(|cx| {
        view.read(cx)
            .perf
            .as_ref()
            .map(|p| (p.intervals.clone(), p.work.clone()))
            .unwrap_or_default()
    });
    if v.is_empty() || w.is_empty() {
        println!("FIXTURE perf: no frames");
        return false;
    }
    v.sort_by(f64::total_cmp);
    w.sort_by(f64::total_cmp);
    let pct = |v: &[f64], p: f64| v[((v.len() as f64 - 1.) * p).round() as usize];
    let over = |t: f64| v.iter().filter(|x| **x > t).count() as f64 * 100. / v.len() as f64;
    let p95 = pct(&v, 0.95);
    println!(
        "FIXTURE perf rows={rows} frames={} interval p50={:.2}ms p95={p95:.2}ms p99={:.2}ms max={:.2}ms >16.7ms={:.1}% >33ms={:.1}% | sidebar work p50={:.2}ms p95={:.2}ms max={:.2}ms",
        v.len(),
        pct(&v, 0.5),
        pct(&v, 0.99),
        v[v.len() - 1],
        over(16.7),
        over(33.),
        pct(&w, 0.5),
        pct(&w, 0.95),
        w[w.len() - 1],
    );
    // One 60 Hz refresh, with the timer's jitter.
    p95 <= 16.8
}

async fn a11y(
    handle: AnyWindowHandle,
    view: &Entity<FixtureView>,
    stores: &Stores,
    scratch: &std::path::Path,
    cx: &mut AsyncApp,
) -> bool {
    let mut pass = true;
    let report = |name: &str, controls: &[String]| {
        println!(
            "FIXTURE {name} {}",
            serde_json::to_string(controls).unwrap_or_default()
        );
    };

    let plain = crate::e2e::ax(handle, "fixture-sidebar", scratch, cx).await;
    pass &= !plain.is_empty();
    report("sidebar", &plain);

    // A hovered row shows its actions; a context menu's commands are the
    // same, run through the same path.
    let first = cx.update(|cx| {
        view.read(cx)
            .sidebar
            .read(cx)
            .rows()
            .iter()
            .find_map(|r| r.chat_id().map(String::from))
    });
    if let Some(id) = first {
        let sidebar = cx.update(|cx| view.read(cx).sidebar.clone());
        sidebar.update(cx, |s, cx| s.hover(Some(&id), cx));
        let hovered = crate::e2e::ax(handle, "fixture-sidebar-hover", scratch, cx).await;
        report("sidebar-hover", &hovered);
        sidebar.update(cx, |s, cx| {
            s.hover(None, cx);
            s.toggle_selected(&id, cx);
        });
        let selecting = crate::e2e::ax(handle, "fixture-sidebar-select", scratch, cx).await;
        report("sidebar-select", &selecting);
        sidebar.update(cx, |s, cx| s.end_selection(cx));
    } else {
        pass = false;
    }

    // The list by keyboard: Tab's way in, then ↓ to the first folder,
    // which is selected (not opened) and is what VoiceOver hears.
    let sidebar = cx.update(|cx| view.read(cx).sidebar.clone());
    let _ = handle.update(cx, |_, window, cx| {
        sidebar.update(cx, |s, cx| s.focus_list(window, cx));
    });
    settle(cx, 200).await;
    for _ in 0..12 {
        let on_folder = cx.update(|cx| {
            matches!(
                sidebar.read(cx).cursor(),
                Some(crate::views::sidebar_keys::KeyRow::Folder(_))
            )
        });
        if on_folder {
            break;
        }
        sidebar.update(cx, |s, cx| {
            s.key(crate::views::sidebar_keys::ListKey::Down, cx)
        });
        settle(cx, 60).await;
    }
    let keys = crate::e2e::ax(handle, "fixture-sidebar-keys", scratch, cx).await;
    report("sidebar-keys", &keys);
    let _ = handle.update(cx, |_, window, cx| window.blur(cx));

    let palette = cx.update(|cx| view.read(cx).palette.clone());
    let _ = handle.update(cx, |_, window, cx| {
        palette.update(cx, |p, cx| p.open(window, cx));
    });
    let empty = crate::e2e::ax(handle, "fixture-palette", scratch, cx).await;
    report("palette", &empty);
    let _ = handle.update(cx, |_, window, cx| {
        palette.update(cx, |p, cx| p.type_query("moon", window, cx));
    });
    settle(cx, 400).await;
    let searched = crate::e2e::ax(handle, "fixture-palette-search", scratch, cx).await;
    report("palette-search", &searched);
    let hits = cx.update(|cx| stores.palette.read(cx).results.clone());
    pass &= hits.is_some_and(|h| !h.hits.is_empty());
    pass
}

/// `--fixture shell`: Settings › Desktop and Quick Ask, read and shot (one
/// after the other: Quick Ask floats above every window).
fn shell(
    stores: Stores,
    settings: Entity<SettingsStore>,
    scratch: PathBuf,
    shots: Option<PathBuf>,
    cx: &mut App,
) {
    use crate::views::quick_ask::QuickAskView;
    use crate::views::settings::{SETTINGS_SIZE, SettingsView, Tab};
    crate::desktop::install_without_services(cx);
    stores.accounts.update(cx, |a, cx| a.refresh(cx));
    let bounds = Bounds::centered(None, size(px(SETTINGS_SIZE.0), px(SETTINGS_SIZE.1)), cx);
    let options = cw::window_options("Settings", bounds, true, true);
    let opened = {
        let (settings, stores) = (settings.clone(), stores.clone());
        cw::open_window_clear_root(options, cx, |window, cx| {
            cx.new(|cx| SettingsView::new(settings, stores, Tab::Desktop, window, cx))
        })
    };
    let Ok((settings_window, _)) = opened else {
        println!("FIXTURE FAILED no Settings window");
        cx.quit();
        return;
    };
    cx.activate(true);
    cx.spawn(async move |cx: &mut AsyncApp| {
        let report = |name: &str, controls: &[String]| {
            println!(
                "FIXTURE {name} {}",
                serde_json::to_string(controls).unwrap_or_default()
            );
        };
        let set_dark = |dark: bool, cx: &mut AsyncApp| {
            settings.update(cx, |s, cx| {
                s.set_appearance(
                    |a| {
                        a.mode = if dark {
                            crate::prefs::ThemeMode::Dark
                        } else {
                            crate::prefs::ThemeMode::Light
                        }
                    },
                    cx,
                )
            })
        };
        settle(cx, 1200).await;
        let desktop =
            crate::e2e::ax(settings_window, "fixture-settings-desktop", &scratch, cx).await;
        report("settings-desktop", &desktop);
        if let Some(dir) = &shots {
            std::fs::create_dir_all(dir).ok();
            for (dark, mode) in [(false, "light"), (true, "dark")] {
                set_dark(dark, cx);
                settle(cx, 600).await;
                let path = dir.join(format!("fixture-settings-desktop-{mode}.png"));
                crate::smoke::shoot(settings_window, path, cx).await;
            }
            set_dark(false, cx);
        }
        let _ = settings_window.update(cx, |_, window, _| window.remove_window());

        let (w, h) = crate::shell::placement::QUICK_ASK_SIZE;
        let opened = cx.update(|cx| {
            let bounds = Bounds::centered(None, size(px(w as f32), px(h as f32)), cx);
            let (stores, settings) = (stores.clone(), settings.clone());
            cw::open_window_clear_root(cw::quick_ask_options(bounds, true), cx, |window, cx| {
                cx.new(|cx| QuickAskView::new(stores, settings, window, cx))
            })
        });
        let Ok((quick, _)) = opened else {
            println!("FIXTURE FAILED no Quick Ask window");
            cx.update(|cx| cx.quit());
            return;
        };
        let _ = quick.update(cx, |_, window, _| {
            cw::macos::add_effect_view(window, cw::Material::HudWindow, None, Some(16.))
        });
        settle(cx, 800).await;
        let quick_controls = crate::e2e::ax(quick, "fixture-quick-ask", &scratch, cx).await;
        report("quick-ask", &quick_controls);
        if let Some(dir) = &shots {
            for (dark, mode) in [(false, "light"), (true, "dark")] {
                set_dark(dark, cx);
                settle(cx, 600).await;
                let path = dir.join(format!("fixture-quick-ask-{mode}.png"));
                crate::smoke::shoot(quick, path, cx).await;
            }
        }
        let passed =
            !desktop.is_empty() && !quick_controls.is_empty() && crate::e2e::unlabelled_seen() == 0;
        println!("FIXTURE {}", if passed { "passed" } else { "FAILED" });
        cx.update(|cx| cx.quit());
    })
    .detach();
}

/// An Open WebUI chat's menus, as the core offers them, for the fixtures'
/// canned chats.
pub fn owui_chat_menu() -> conduit_protocol::ChatMenuAbilities {
    conduit_protocol::ChatMenuAbilities {
        share: true,
        duplicate: false,
        r#move: true,
        mark_unread: true,
        generate_title: true,
        export: true,
    }
}
