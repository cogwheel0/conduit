//! Conduit Desktop: the native macOS app over the Dart daemon `conduitd`.
//!
//! [`run`] bootstraps the app: logging and the crash hook, preferences, the
//! Keychain master key, the daemon connection and the session layer
//! ([`stores`]), menus and key bindings ([`menus`], [`keymap`]), strings
//! ([`l10n`]), the main window ([`views::main_window`]) and Settings
//! ([`views::settings`]), and the macOS shell extras ([`desktop`]: links,
//! "Open with", notifications, Quick Ask, the menu-bar item, open at
//! login), and Sparkle updates ([`updates`]). `--shots <dir>` runs the
//! scripted smoke pass in [`smoke`].
//!
//! The test harness is behind the `harness` feature, which dev and test
//! builds turn on (`crates/app/run.sh`, `perf.sh`, `hc-capture.sh`, and
//! `cargo test` through the crate's dev-dependency on itself) and release
//! bundles leave off (`packaging/macos/bundle.sh`): the `--e2e` passes
//! ([`e2e`]), the screenshot and motion capture (`--capture`, `capture`),
//! `--probe`, and the `--fixture` runs over canned data. A build without
//! it refuses those flags.

pub mod actions;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod calendar_fixture;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod capture;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod channel_fixture;
#[cfg(feature = "harness")]
pub mod chat_fixture;
pub mod desktop;
#[cfg(feature = "harness")]
pub mod diagram_fixture;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod e2e;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod fixture;
pub mod intents;
pub mod keymap;
pub mod l10n;
pub mod menus;
pub mod prefs;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod rooms_fixture;
pub mod scripted;
pub mod shell;
#[cfg(target_os = "macos")]
pub mod smoke;
pub mod stores;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod terminal_fixture;
pub mod updates;
pub mod views;
pub mod voice;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod web_media_fixture;
pub mod windows;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod workspace_fixture;

use std::path::PathBuf;

use conduit_components::window as cw;
use conduit_daemon::paths::{self, AppPaths, Flavor};
use gpui_kit::{
    AnyWindowHandle, App, AppContext as _, Bounds, Entity, Global, WindowAppearance, px, size,
};

use crate::actions::*;
use crate::l10n::{ActiveL10n as _, L10n, locale};
use crate::stores::Stores;
use crate::stores::connection::{ConnectionEvent, ConnectionOptions, ConnectionStore};
use crate::stores::layout::LayoutStore;
use crate::stores::settings::{SettingsEvent, SettingsStore};
use crate::views::main_window::MainWindow;
use crate::views::settings::{SETTINGS_SIZE, SettingsView, Tab};

/// The app's version: `CONDUIT_VERSION` at build time (the release
/// bundle's `CFBundleShortVersionString`, e.g. `1.2.0`;
/// see packaging/macos/bundle.sh), else the crate version.
pub const VERSION: &str = match option_env!("CONDUIT_VERSION") {
    Some(v) => v,
    None => env!("CARGO_PKG_VERSION"),
};

/// The bundle's `CFBundleVersion` (`CONDUIT_BUILD` at build time); `None`
/// for builds outside the release script.
pub const BUILD: Option<&str> = option_env!("CONDUIT_BUILD");

/// Where the Help menu points.
pub const HELP_URL: &str = "https://github.com/cogwheel0/conduit#readme";

/// The app's long-lived state.
pub struct AppState {
    pub paths: AppPaths,
    pub connection: Entity<ConnectionStore>,
    /// The session layer: accounts, session, ui requests, router, toasts.
    pub stores: Stores,
    pub settings: Entity<SettingsStore>,
    pub layout: Entity<LayoutStore>,
    pub main_window: Option<AnyWindowHandle>,
    pub main_view: Option<Entity<MainWindow>>,
    /// First run and sign-in ([`windows`]), while there is no session.
    pub setup_window: Option<(AnyWindowHandle, Entity<views::setup_window::SetupWindow>)>,
    pub settings_window: Option<(AnyWindowHandle, Entity<SettingsView>)>,
    #[cfg(target_os = "macos")]
    _network: Option<shell::macos::NetworkMonitor>,
}

impl Global for AppState {}

fn arg(args: &[String], key: &str) -> Option<String> {
    args.iter()
        .position(|a| a == key)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

/// Whether `args` ask for a scripted run (`--shots`, `--e2e`, `--capture`,
/// or a fixture: `--fixture`, `--chat-fixture` and the rest) that drives,
/// resets and photographs its profile, or saves settings to it (a
/// fixture's screenshot theme): a profile of its own, never the user's.
pub fn is_scripted(args: &[String]) -> bool {
    args.iter().any(|a| {
        a == "--shots"
            || a.starts_with("--e2e")
            || a.starts_with("--capture")
            || (a.starts_with("--") && a.ends_with("fixture"))
    })
}

/// The profile a scripted run uses: the one named by `named`
/// (`CONDUIT_USER_DATA`), which must not be the app's ordinary profile
/// (`ordinary`), or else a fresh folder under `scratch`. A scripted run
/// never touches a profile the caller did not name, or the user's own.
pub fn harness_profile(
    named: Option<PathBuf>,
    ordinary: &std::path::Path,
    scratch: &std::path::Path,
) -> Result<PathBuf, String> {
    match named {
        Some(named) => {
            if same_folder(&named, ordinary) {
                Err(format!(
                    "{} is the app's own profile; name a test profile in CONDUIT_USER_DATA",
                    named.display()
                ))
            } else {
                Ok(named)
            }
        }
        None => Ok(scratch.join("user-data")),
    }
}

/// Whether `a` and `b` name one folder.
fn same_folder(a: &std::path::Path, b: &std::path::Path) -> bool {
    let canon = |p: &std::path::Path| p.canonicalize().unwrap_or_else(|_| p.to_path_buf());
    canon(a) == canon(b)
}

/// The app's own profile for `flavor` (`~/Library/Application Support/
/// Conduit Dev`, or `Conduit`), which no scripted run may use.
pub fn app_profile(flavor: Flavor) -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    home.join("Library/Application Support")
        .join(flavor.app_name())
}

/// Whether a scripted pass (E2E, capture) may reset the profile at
/// `paths`: never the app's own. The passes check it before every reset,
/// on top of `run()` never giving them that profile.
pub fn may_reset_profile(paths: &AppPaths) -> bool {
    !same_folder(&paths.user_data, &app_profile(paths.flavor))
}

/// The Keychain service of a scripted run's master key: never the app's own.
fn harness_service(flavor: Flavor) -> String {
    format!("{}.harness", flavor.keychain_service())
}

/// The master key from the Keychain (created on first run).
fn master_key(paths: &AppPaths, scripted: bool) -> Result<String, String> {
    #[cfg(target_os = "macos")]
    {
        use conduit_daemon::secrets::{
            Keychain, MasterKeyStore, SecurityCli, load_or_create_master_key,
        };
        let service = if scripted {
            harness_service(paths.flavor)
        } else {
            paths.flavor.keychain_service()
        };
        // Dev builds go through /usr/bin/security so a rebuilt (re-hashed)
        // binary never meets a Keychain prompt; see conduit_daemon::secrets.
        let store: Box<dyn MasterKeyStore> = match paths.flavor {
            Flavor::Dev => Box::new(SecurityCli::new(service)),
            Flavor::Production => Box::new(Keychain::new(service)),
        };
        load_or_create_master_key(store.as_ref()).map_err(|e| e.to_string())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (paths, scripted);
        Err("no secret store on this platform yet".into())
    }
}

pub fn run() {
    let args: Vec<String> = std::env::args().collect();
    // A build without the test harness refuses its flags rather than
    // starting normally, so a script can never drive a real profile.
    #[cfg(not(feature = "harness"))]
    if let Some(flag) = scripted::harness_flag(&args) {
        eprintln!("conduit-desktop: {flag} needs a build with the `harness` feature");
        std::process::exit(64);
    }
    // An E2E pass runs inside the smoke pass (`--shots <dir>`): alone it
    // would open the app normally and report nothing.
    if args.iter().any(|a| a == "--e2e") && arg(&args, "--shots").is_none() {
        eprintln!("conduit-desktop: --e2e runs with --shots <dir>");
        std::process::exit(64);
    }
    // The smoke wrapper launches through `open`, which starts apps in `/`.
    if let Some(dir) = arg(&args, "--cwd") {
        std::env::set_current_dir(dir).ok();
    }
    // A scripted launch (a pass, the capture, a fixture) never asks for a
    // permission: see `scripted`.
    scripted::set(scripted::requested(&args));
    // The web views' media policy in real web views (tests/web_media.rs).
    #[cfg(all(target_os = "macos", feature = "harness"))]
    if web_media_fixture::requested(&args) {
        web_media_fixture::run();
        return;
    }
    // The sidebar and palette over canned data (tests/a11y.rs, perf).
    #[cfg(all(target_os = "macos", feature = "harness"))]
    if let Some(mode) = fixture::Mode::from_args(&args) {
        fixture::run(mode);
        return;
    }
    // The workspace's list over 2,000 canned prompts (perf).
    #[cfg(all(target_os = "macos", feature = "harness"))]
    if workspace_fixture::requested(&args) {
        workspace_fixture::run();
        return;
    }
    // The agenda and the task list over canned data (perf).
    #[cfg(all(target_os = "macos", feature = "harness"))]
    if let Some(which) = calendar_fixture::requested(&args) {
        calendar_fixture::run(which);
        return;
    }
    let flavor = Flavor::detect();
    let mut app_paths = AppPaths::for_flavor(flavor);
    // A scripted run gets its own profile, logs and Keychain item.
    let scripted_run = is_scripted(&args);
    if scripted_run {
        let ordinary = app_profile(flavor);
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        let scratch =
            std::env::temp_dir().join(format!("conduit-harness-{}-{stamp}", std::process::id()));
        let named = std::env::var_os("CONDUIT_USER_DATA").map(PathBuf::from);
        let fresh = named.is_none();
        match harness_profile(named, &ordinary, &scratch) {
            Ok(user_data) => app_paths.user_data = user_data,
            Err(e) => {
                eprintln!("conduit-desktop: {e}");
                std::process::exit(64);
            }
        }
        if fresh && std::env::var_os("CONDUIT_LOGS").is_none() {
            app_paths.logs = scratch.join("logs");
        }
    }
    shell::logger::install(&app_paths.logs);
    shell::crash::install(app_paths.logs.clone(), VERSION);
    log::info!(
        "Conduit Desktop {VERSION} ({flavor:?}), userData {}",
        app_paths.user_data.display()
    );
    let shots = arg(&args, "--shots").map(PathBuf::from);
    #[cfg(all(target_os = "macos", feature = "harness"))]
    let probe = arg(&args, "--probe").map(PathBuf::from);
    #[cfg(all(target_os = "macos", feature = "harness"))]
    if let Some(path) = &probe
        && e2e::shell::probe_files(path).is_none()
    {
        eprintln!(
            "conduit-desktop: --probe {}: name a file whose .cmd and .quit files are others (say, state.json)",
            path.display()
        );
        std::process::exit(64);
    }
    #[cfg(target_os = "macos")]
    let smoke_options = smoke::SmokeOptions::from_args(&args);
    #[cfg(all(target_os = "macos", feature = "harness"))]
    let chat_fixture = chat_fixture::requested(&args);
    #[cfg(all(target_os = "macos", feature = "harness"))]
    let channel_fixture = channel_fixture::requested(&args);
    #[cfg(all(target_os = "macos", feature = "harness"))]
    let terminal_fixture = terminal_fixture::requested(&args);
    #[cfg(all(target_os = "macos", feature = "harness"))]
    let rooms_fixture = rooms_fixture::requested(&args);
    // `--capture <dir>`: screenshots and motion strips of every screen,
    // for design review (capture/).
    #[cfg(all(target_os = "macos", feature = "harness"))]
    let capture = capture::CaptureOptions::from_args(&args);
    #[cfg(all(target_os = "macos", feature = "harness"))]
    let scripted = shots.is_some() || capture.is_some();
    #[cfg(not(all(target_os = "macos", feature = "harness")))]
    let scripted = shots.is_some();
    // `{{USER_LOCATION}}`: a scripted run (any pass, the capture, a probe
    // or a fixture: `scripted::active`) answers with a stand-in and never
    // reaches CoreLocation (no test may raise the system's prompt).
    shell::location::choose(
        scripted::active(),
        std::env::var("CONDUIT_LOCATION_STANDIN").ok(),
    );

    let app = gpui_kit::application().with_assets(crate::views::model_logo::AppAssets);
    // `conduit://` links and "Open with" files, cold launch included: they
    // can come before the app state exists, so they wait in a channel.
    let (urls_tx, urls_rx) = desktop::url_channel();
    app.on_open_urls(move |urls| {
        let _ = urls_tx.unbounded_send(urls);
    });
    // The Dock icon: the main window, made again or shown again (it may
    // have been closed to the menu bar).
    app.on_reopen(|cx| {
        if cx.has_global::<AppState>() {
            desktop::show_main(cx);
        }
    });
    let hidden_arg = args.iter().any(|a| a == "--hidden");
    app.run(move |cx: &mut App| {
        // The open-application Apple event is current only now.
        #[cfg(target_os = "macos")]
        let hidden = hidden_arg || shell::login_item::launched_as_login_item();
        #[cfg(not(target_os = "macos"))]
        let hidden = hidden_arg;
        // The Services menu's provider, before anything else: a launch made
        // for "Ask Conduit" delivers its request right after this.
        #[cfg(target_os = "macos")]
        let services = shell::services::install();
        gpui_kit::init(cx);
        menus::KitBindings::capture(cx);
        conduit_components::views::markdown::preload_grammars(&["python", "rust", "bash"]);

        let system_dark = matches!(
            cx.window_appearance(),
            WindowAppearance::Dark | WindowAppearance::VibrantDark
        );
        let settings = cx.new(|_| {
            SettingsStore::load(
                app_paths.prefs_file(),
                system_dark,
                locale::system_languages(),
            )
        });
        settings.update(cx, |s, cx| s.apply(cx));
        install_component_strings(cx);
        // The chat view over a fixture daemon (perf and AccessKit checks).
        #[cfg(all(target_os = "macos", feature = "harness"))]
        if let Some((mode, shots)) = chat_fixture.clone() {
            chat_fixture::run(mode, shots, settings.clone(), cx);
            return;
        }
        // A channel's timeline over a fixture daemon (perf).
        #[cfg(all(target_os = "macos", feature = "harness"))]
        if let Some((mode, shots)) = channel_fixture.clone() {
            channel_fixture::run(mode, shots, cx);
            return;
        }
        // The console under a flood of output (perf).
        #[cfg(all(target_os = "macos", feature = "harness"))]
        if terminal_fixture {
            terminal_fixture::run(cx);
            return;
        }
        // A Group Chat's pane over a fixture daemon (perf).
        #[cfg(all(target_os = "macos", feature = "harness"))]
        if rooms_fixture {
            rooms_fixture::run(cx);
            return;
        }
        let layout = cx.new(|_| LayoutStore::load(app_paths.window_state_file()));

        let connection = ConnectionStore::start(
            ConnectionOptions {
                paths: app_paths.clone(),
                binary: paths::locate_daemon(),
                master_key: master_key(&app_paths, scripted_run),
                locale: locale::bcp47(settings.read(cx).locale()),
                client_version: VERSION.into(),
            },
            cx,
        );
        {
            let (settings, layout) = (settings.clone(), layout.clone());
            cx.subscribe(&connection, move |_, event, cx| match event {
                ConnectionEvent::LocalDataReset { .. } => {
                    settings.read(cx).save();
                    layout.read(cx).save_now();
                }
                ConnectionEvent::Connected { .. } => {
                    // The daemon keeps the app preferences mobile shares
                    // (theme, palette, text size, language): read them, and
                    // take them when this Mac has no preferences file of
                    // its own yet; else tell the daemon ours.
                    read_app_preferences(&settings, cx);
                }
                _ => {}
            })
            .detach();
        }
        let stores = Stores::install(connection.clone(), cx);
        views::release_notes::install(&stores, cx);
        stores.toast_account_notices(
            |notice, cx| {
                views::words::account_notice(&views::privacy::notice(notice, cx), cx.l10n())
            },
            cx,
        );
        cx.subscribe(&settings, |settings, event, cx| match event {
            SettingsEvent::LocaleChanged => {
                install_component_strings(cx);
                menus::set_menus(cx);
            }
            SettingsEvent::AppPreferencesChanged => push_app_preferences(&settings, cx),
            SettingsEvent::KeymapChanged => {
                let keymap = settings.read(cx).keymap();
                menus::bind_keys(&keymap, cx);
                menus::set_menus(cx);
            }
            // The shell extras follow it themselves (desktop::install); the
            // menus show Quick Ask's chord.
            SettingsEvent::DesktopChanged => {
                let keymap = settings.read(cx).keymap();
                menus::bind_keys(&keymap, cx);
                menus::set_menus(cx);
            }
        })
        .detach();

        // Before any window opens: transitions read it on their first frame.
        shell::reduce_motion::install(cx);

        #[cfg(target_os = "macos")]
        let network = {
            let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
            let monitor = shell::macos::NetworkMonitor::start(move |online| {
                let _ = tx.send(online);
            });
            let connection = connection.clone();
            cx.spawn(async move |cx| {
                while let Some(online) = rx.recv().await {
                    connection.update(cx, |c, cx| c.set_online(online, cx));
                }
            })
            .detach();
            monitor
        };

        cx.set_global(AppState {
            paths: app_paths.clone(),
            connection: connection.clone(),
            stores,
            settings: settings.clone(),
            layout,
            main_window: None,
            main_view: None,
            setup_window: None,
            settings_window: None,
            #[cfg(target_os = "macos")]
            _network: network,
        });

        let keymap = settings.read(cx).keymap();
        sync_keyboard_access(cx);
        menus::bind_keys(&keymap, cx);
        menus::set_menus(cx);
        install_menu_observers(cx);
        register_actions(cx);
        desktop::install(urls_rx, hidden, cx);
        #[cfg(target_os = "macos")]
        desktop::install_services(services, cx);
        // Shortcuts, Siri and Spotlight: requests that came with the launch
        // and those that follow.
        intents::install(cx);
        updates::install(cx);
        // The setup window and the main window follow the session.
        windows::install(cx);
        // Settings › Keyboard records chords before bindings see them.
        cx.intercept_keystrokes(|event, _, cx| {
            let Some(settings) = cx.try_global::<AppState>().map(|s| s.settings.clone()) else {
                return;
            };
            if settings.update(cx, |s, cx| s.record(&event.keystroke, cx)) {
                cx.stop_propagation();
            }
        })
        .detach();
        cx.on_app_quit(|cx| {
            if let Some(state) = cx.try_global::<AppState>() {
                let (connection, settings, layout) = (
                    state.connection.clone(),
                    state.settings.clone(),
                    state.layout.clone(),
                );
                layout.read(cx).save_now();
                settings.read(cx).save();
                connection.update(cx, |c, _| c.shutdown());
            }
            async {}
        })
        .detach();

        // A login launch with "Close to menu bar" on starts in the menu bar.
        // Otherwise the window the app fronted last: the main window on a
        // Mac that is set up, the setup window on first run (the route,
        // known once the daemon answers, swaps them if it disagrees).
        if hidden && desktop::closes_to_menu_bar(cx) && !scripted {
            log::info!("hidden start: menu-bar item only");
        } else {
            windows::show_front(cx);
        }

        #[cfg(target_os = "macos")]
        if let Some(dir) = shots {
            smoke::run(dir, smoke_options, cx);
        }
        #[cfg(all(target_os = "macos", feature = "harness"))]
        if let Some(options) = capture {
            capture::run(options, cx);
        }
        // The state a shell driver checks after `open -a` (links, files).
        #[cfg(all(target_os = "macos", feature = "harness"))]
        if let Some(path) = probe {
            e2e::shell::probe(path, cx);
        }
        #[cfg(not(target_os = "macos"))]
        let _ = shots;
    });
}

/// Follows System Settings › Keyboard Navigation (re-read whenever a window
/// of ours becomes active); `CONDUIT_FULL_KEYBOARD_ACCESS=1` or `0`
/// overrides it (the capture harness turns it on).
pub fn sync_keyboard_access(cx: &mut App) {
    use conduit_components::views::focus::KeyboardAccess;
    let all_controls = match std::env::var("CONDUIT_FULL_KEYBOARD_ACCESS").as_deref() {
        Ok("1") | Ok("true") => true,
        Ok("0") | Ok("false") => false,
        _ => {
            #[cfg(target_os = "macos")]
            {
                shell::macos::full_keyboard_access()
            }
            #[cfg(not(target_os = "macos"))]
            {
                true
            }
        }
    };
    let next = KeyboardAccess { all_controls };
    if cx.try_global::<KeyboardAccess>() != Some(&next) {
        cx.set_global(next);
        cx.refresh_windows();
    }
}

/// The menu bar follows the sidebar, the open chat, the folders, the
/// account (sharing) and the text size (zoom).
fn install_menu_observers(cx: &mut App) {
    let Some(state) = cx.try_global::<AppState>() else {
        return;
    };
    let (layout, navigation, chat_list, settings, accounts, session, speech) = (
        state.layout.clone(),
        state.stores.navigation.clone(),
        state.stores.chat_list.clone(),
        state.settings.clone(),
        state.stores.accounts.clone(),
        state.stores.session.clone(),
        state.stores.speech.clone(),
    );
    cx.observe(&settings, |_, cx| menus::refresh_menus(cx))
        .detach();
    cx.observe(&accounts, |_, cx| menus::refresh_menus(cx))
        .detach();
    cx.observe(&layout, |_, cx| menus::refresh_menus(cx))
        .detach();
    cx.observe(&navigation, |_, cx| menus::refresh_menus(cx))
        .detach();
    cx.observe(&chat_list, |_, cx| menus::refresh_menus(cx))
        .detach();
    // The Go menu's sections follow the account's capabilities and route.
    cx.observe(&session, |_, cx| menus::refresh_menus(cx))
        .detach();
    // Chat › Stop Speaking follows whether anything is read: not every word.
    let mut reading = false;
    cx.observe(&speech, move |speech, cx| {
        let now = speech.read(cx).is_active();
        if now != reading {
            reading = now;
            menus::refresh_menus(cx);
        }
    })
    .detach();
}

fn register_actions(cx: &mut App) {
    views::chat::remote_image::register(cx);
    cx.on_action(|_: &Quit, cx| crate::views::sheet::quit(cx));
    cx.on_action(|_: &About, cx| open_settings(Some(Tab::About), cx));
    cx.on_action(|_: &Hide, cx| cx.hide());
    cx.on_action(|_: &HideOthers, cx| cx.hide_other_apps());
    cx.on_action(|_: &ShowAll, cx| cx.unhide_other_apps());
    // ⌘W when no element took it (the main window and Quick Ask handle it
    // themselves when they have focus).
    cx.on_action(|_: &CloseWindow, cx| {
        let Some(w) = cx.active_window() else {
            log::info!("close window: no active window");
            return;
        };
        // A window with Add Account's sheet down: ⌘W cancels the sheet.
        if let Some((handle, view)) = cx
            .try_global::<AppState>()
            .and_then(|s| s.settings_window.clone())
            && let Some(sheet) = view.read(cx).add_sheet.clone()
            && (handle == w || sheet.handle == w)
        {
            sheet.view.update(cx, |s, cx| s.cancel(cx));
            return;
        }
        // The main window with "Close to menu bar" on only hides.
        let main = cx.try_global::<AppState>().and_then(|s| s.main_window);
        if main == Some(w) && desktop::closes_to_menu_bar(cx) {
            log::info!("close window: hiding the main window");
            desktop::hide_main(cx);
            return;
        }
        // Quick Ask hides; its exchange stays for next time.
        if desktop::is_quick_ask_window(w, cx) {
            desktop::hide_quick_ask(cx);
            return;
        }
        let _ = w.update(cx, |_, window, _| window.remove_window());
    });
    cx.on_action(|_: &ToggleQuickAsk, cx| {
        cx.defer(desktop::toggle_quick_ask);
    });
    cx.on_action(|_: &Minimize, cx| {
        if let Some(w) = cx.active_window() {
            let _ = w.update(cx, |_, window, _| window.minimize_window());
        }
    });
    cx.on_action(|_: &Zoom, cx| {
        if let Some(w) = cx.active_window() {
            let _ = w.update(cx, |_, window, _| window.zoom_window());
        }
    });
    cx.on_action(|_: &ToggleFullScreen, cx| {
        if let Some(w) = cx.active_window() {
            let _ = w.update(cx, |_, window, _| window.toggle_fullscreen());
        }
    });
    cx.on_action(|_: &BringAllToFront, _| {
        #[cfg(target_os = "macos")]
        shell::macos::bring_all_to_front();
    });
    cx.on_action(|_: &OpenHelp, cx| cx.open_url(HELP_URL));
    views::chat_pane::register_actions(cx);
    views::chat::rows::register_actions(cx);
    cx.on_action(|_: &OpenSettings, cx| open_settings(None, cx));
    cx.on_action(|_: &ShowShortcuts, cx| open_settings(Some(Tab::Keyboard), cx));
    // New Chat and ⌘K from another window (Settings): the main window's.
    cx.on_action(|_: &NewChat, cx| {
        open_main_window(cx);
        with_main_view(cx, |view, window, cx| view.new_chat(false, window, cx));
    });
    cx.on_action(|_: &OpenPalette, cx| {
        open_main_window(cx);
        with_main_view(cx, |view, window, cx| view.toggle_palette(window, cx));
    });
    cx.on_action(|_: &NewTemporaryChat, cx| {
        open_main_window(cx);
        with_main_view(cx, |view, window, cx| view.new_chat(true, window, cx));
    });
    // View › Actual Size, Zoom In and Zoom Out: the message text size, from
    // any window (Settings shows it change).
    cx.on_action(|_: &ActualSize, cx| zoom_text(menus::ZoomStep::Actual, cx));
    cx.on_action(|_: &ZoomIn, cx| zoom_text(menus::ZoomStep::In, cx));
    cx.on_action(|_: &ZoomOut, cx| zoom_text(menus::ZoomStep::Out, cx));
    // The sidebar's menu commands, when nothing in the main window has
    // focus (the path from the root then misses its handlers).
    cx.on_action(|a: &views::sidebar::ChatMenu, cx| {
        let (id, command) = (a.chat_id.clone(), a.command.clone());
        with_main_view(cx, |view, window, cx| {
            view.sidebar
                .update(cx, |s, cx| s.run(&id, command, window, cx))
        });
    });
    cx.on_action(|a: &views::hermes_sessions::HermesMenu, cx| {
        let (id, command) = (a.session_id.clone(), a.command);
        with_main_view(cx, |view, window, cx| {
            view.run_hermes(&id, command, window, cx)
        });
    });
    // Notes: a note's menu, New Note, and the note pane's toolbar
    // menus, wherever the focus is.
    cx.on_action(|a: &views::notes::NoteMenu, cx| {
        let (id, command) = (a.note_id.clone(), a.command);
        with_main_view(cx, |view, window, cx| {
            let stores = view.stores.clone();
            views::notes::run(&stores, &id, command, window, cx)
        });
    });
    cx.on_action(|_: &views::notes::NewNote, cx| {
        let Some(stores) = cx.try_global::<AppState>().map(|s| s.stores.clone()) else {
            return;
        };
        // Only where the account has notes.
        if stores.session.read(cx).capabilities().notes {
            views::notes::new_note(&stores, cx);
        }
    });
    cx.on_action(|a: &views::notes::pane::PaneCommand, cx| {
        let (id, command) = (a.note_id.clone(), a.command.clone());
        with_main_view(cx, |view, window, cx| {
            let pane = view.area_pane.read(cx).notes.read(cx).note_pane().cloned();
            if let Some(pane) = pane
                && pane.read(cx).shows(&id)
            {
                pane.update(cx, |p, cx| p.run(command, window, cx));
            }
        });
    });
    cx.on_action(|a: &views::sidebar::FolderMenu, cx| {
        let (id, command) = (a.folder_id.clone(), a.command.clone());
        with_main_view(cx, |view, window, cx| {
            view.sidebar
                .update(cx, |s, cx| s.run_folder(&id, command, window, cx))
        });
    });
    cx.on_action(|a: &views::sidebar::ActOnSelected, cx| {
        let action = a.action;
        with_main_view(cx, |view, window, cx| {
            view.sidebar
                .update(cx, |s, cx| s.bulk(action, None, window, cx))
        });
    });
    cx.on_action(|a: &views::sidebar::MoveSelected, cx| {
        let folder = a.folder_id.clone();
        with_main_view(cx, |view, window, cx| {
            view.sidebar.update(cx, |s, cx| {
                s.bulk(conduit_protocol::BulkChatAction::Move, folder, window, cx)
            })
        });
    });
    cx.on_action(|_: &ToggleSidebar, cx| {
        if let Some(layout) = cx.try_global::<AppState>().map(|s| s.layout.clone()) {
            layout.update(cx, |l, cx| l.toggle_sidebar(cx));
        }
    });
    // ⌥⌘↩ / ⌥⌘⌫ when the main window does not have focus (Settings, the
    // SSO window): the main window's card answers.
    cx.on_action(|_: &AllowRequest, cx| {
        if let Some(view) = cx
            .try_global::<AppState>()
            .and_then(|s| s.main_view.clone())
        {
            view.update(cx, |v, cx| v.answer_request(true, cx));
        }
    });
    cx.on_action(|_: &DenyRequest, cx| {
        if let Some(view) = cx
            .try_global::<AppState>()
            .and_then(|s| s.main_view.clone())
        {
            view.update(cx, |v, cx| v.answer_request(false, cx));
        }
    });
    cx.on_action(|action: &SetLocale, cx| {
        if let Some(settings) = cx.try_global::<AppState>().map(|s| s.settings.clone()) {
            let locale = action.locale.clone();
            settings.update(cx, |s, cx| s.set_locale(locale, cx));
        }
    });
}

/// Steps Settings › Appearance › Text Size (View › Zoom In and the rest).
fn zoom_text(step: menus::ZoomStep, cx: &mut App) {
    let Some(settings) = cx.try_global::<AppState>().map(|s| s.settings.clone()) else {
        return;
    };
    settings.update(cx, |s, cx| {
        s.set_appearance(
            |a| {
                menus::zoom(a, step);
            },
            cx,
        )
    });
}

pub(crate) fn main_window_alive(cx: &mut App) -> bool {
    let Some(handle) = cx.try_global::<AppState>().and_then(|s| s.main_window) else {
        return false;
    };
    handle.update(cx, |_, _, _| ()).is_ok()
}

/// Opens (or raises) the window the app fronts with: the main window while
/// there is a session, else the setup window ([`windows`]). The Dock, the
/// menu-bar item, links and New Chat from another window come here.
pub fn open_main_window(cx: &mut App) {
    windows::open_front(cx);
}

/// Opens (or raises) the main window at the saved geometry.
pub(crate) fn open_main(cx: &mut App) {
    if main_window_alive(cx) {
        if let Some(h) = cx.global::<AppState>().main_window {
            let _ = h.update(cx, |_, window, _| window.activate_window());
        }
        return;
    }
    let state = cx.global::<AppState>();
    let (stores, settings, layout) = (
        state.stores.clone(),
        state.settings.clone(),
        state.layout.clone(),
    );
    let bounds = layout.read(cx).initial_bounds(cx);
    let rect = match bounds {
        gpui_kit::WindowBounds::Windowed(b)
        | gpui_kit::WindowBounds::Maximized(b)
        | gpui_kit::WindowBounds::Fullscreen(b) => b,
    };
    let mut options = cw::window_options("Conduit", rect, true, true);
    options.window_bounds = Some(bounds);
    match cw::open_window_clear_root(options, cx, |window, cx| {
        cx.new(|cx| MainWindow::new(stores, settings, layout, window, cx))
    }) {
        Ok((handle, view)) => {
            let state = cx.global_mut::<AppState>();
            state.main_window = Some(handle);
            state.main_view = Some(view);
            // "Close to menu bar": closing hides the window instead.
            let _ = handle.update(cx, |_, window, cx| {
                window.on_window_should_close(cx, |_, cx| desktop::main_should_close(cx));
            });
            // Links that waited for the window.
            cx.defer(desktop::drain);
        }
        Err(e) => log::error!("could not open the main window: {e}"),
    }
}

/// Runs `f` on the main window's view, with its window.
pub(crate) fn with_main_view(
    cx: &mut App,
    f: impl FnOnce(&mut MainWindow, &mut gpui_kit::Window, &mut gpui_kit::Context<MainWindow>),
) {
    let Some(state) = cx.try_global::<AppState>() else {
        return;
    };
    let (Some(handle), Some(view)) = (state.main_window, state.main_view.clone()) else {
        return;
    };
    let _ = handle.update(cx, |_, window, cx| {
        window.activate_window();
        view.update(cx, |v, cx| f(v, window, cx));
    });
}

/// "Add account" (Settings › Accounts): a window sheet on Settings, as
/// Mail and System Settings › Internet Accounts add an account; sign-in
/// for it follows in the setup window.
pub fn start_adding_account(cx: &mut App) {
    open_settings(Some(Tab::Accounts), cx);
    let Some((handle, view)) = cx
        .try_global::<AppState>()
        .and_then(|s| s.settings_window.clone())
    else {
        return;
    };
    let _ = handle.update(cx, |_, window, cx| {
        window.activate_window();
        view.update(cx, |v, cx| v.open_add_sheet(window, cx));
    });
}

/// Brings the main window to the front.
pub fn activate_main_window(cx: &mut App) {
    if let Some(handle) = cx.try_global::<AppState>().and_then(|s| s.main_window) {
        let _ = handle.update(cx, |_, window, _| window.activate_window());
    }
}

/// `settings.getApp` at connect: a profile with no preferences file yet (a
/// first run, or the file was lost) takes the daemon's stored theme,
/// palette, text size and language; one with a file keeps its own and
/// sends them (`settings.setApp`), as before.
fn read_app_preferences(settings: &Entity<SettingsStore>, cx: &mut App) {
    let Some(state) = cx.try_global::<AppState>() else {
        return;
    };
    let connection = state.connection.read(cx);
    if !connection.is_connected() {
        return;
    }
    if settings.read(cx).has_file() {
        push_app_preferences(settings, cx);
        return;
    }
    let call = connection
        .rpc()
        .call::<conduit_protocol::methods::SettingsGetApp>(&conduit_protocol::NoParams);
    let settings = settings.clone();
    cx.spawn(async move |cx| {
        match call.await {
            Ok(stored) => {
                // A choice made on this Mac while the read was out wins.
                settings.update(cx, |s, cx| {
                    if !s.has_file() {
                        s.adopt_app_preferences(&stored, cx);
                    }
                });
                cx.update(|cx| push_app_preferences(&settings, cx));
            }
            // Unread, the account's own stay as they are: this Mac's
            // defaults never go over them (the next connect asks again).
            Err(e) => log::debug!("settings.getApp: {e}"),
        }
    })
    .detach();
}

/// `settings.setApp` with this window's appearance and language.
fn push_app_preferences(settings: &Entity<SettingsStore>, cx: &mut App) {
    let Some(state) = cx.try_global::<AppState>() else {
        // Before the app state exists: the first connect sends them.
        return;
    };
    let connection = state.connection.read(cx);
    if !connection.is_connected() {
        return;
    }
    let patch = stores::settings::app_preferences(&settings.read(cx).prefs);
    let call = connection
        .rpc()
        .call::<conduit_protocol::methods::SettingsSetApp>(&patch);
    cx.background_spawn(async move {
        if let Err(e) = call.await {
            log::debug!("settings.setApp: {e}");
        }
    })
    .detach();
}

/// The components' strings for the current locale.
pub(crate) fn install_component_strings(cx: &mut App) {
    let strings = cx
        .try_global::<L10n>()
        .map(l10n::components::component_strings)
        .unwrap_or_default();
    cx.set_global(strings);
}

/// Opens (or raises) Settings, on `tab` when given.
pub fn open_settings(tab: Option<Tab>, cx: &mut App) {
    if let Some((handle, view)) = cx.global::<AppState>().settings_window.clone()
        && handle
            .update(cx, |_, window, _| window.activate_window())
            .is_ok()
    {
        if let Some(tab) = tab {
            view.update(cx, |v, cx| v.show_tab(tab, cx));
        }
        return;
    }
    let state = cx.global::<AppState>();
    let (settings, stores) = (state.settings.clone(), state.stores.clone());
    let title = cx.l10n().desktop_settings_title();
    let bounds = Bounds::centered(None, size(px(SETTINGS_SIZE.0), px(SETTINGS_SIZE.1)), cx);
    let options = cw::window_options(&title, bounds, true, true);
    let tab = tab.unwrap_or(Tab::FIRST);
    match cw::open_window_clear_root(options, cx, |window, cx| {
        cx.new(|cx| SettingsView::new(settings, stores, tab, window, cx))
    }) {
        Ok((handle, view)) => {
            cx.global_mut::<AppState>().settings_window = Some((handle, view));
            // A chord being recorded is the window's: once it closes, keys go
            // back to the app (the view itself lives on in AppState until
            // this lets it go).
            let _ = handle.update(cx, |_, window, cx| {
                window.on_window_should_close(cx, |_, cx| {
                    let settings = cx.global::<AppState>().settings.clone();
                    settings.update(cx, |s, cx| s.stop_recording(cx));
                    cx.global_mut::<AppState>().settings_window = None;
                    true
                });
            });
        }
        Err(e) => log::error!("could not open Settings: {e}"),
    }
}

#[cfg(test)]
mod harness_profile_tests {
    use super::*;

    #[test]
    fn a_scripted_run_never_uses_a_profile_it_was_not_given() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(is_scripted(&args(&[
            "app", "--shots", "/tmp/s", "--e2e", "chat"
        ])));
        assert!(is_scripted(&args(&["app", "--e2e", "chat"])));
        assert!(is_scripted(&args(&["app", "--capture", "/tmp/c"])));
        // A fixture saves its own settings (the shots' theme), with or
        // without `--shots`.
        assert!(is_scripted(&args(&["app", "--chat-fixture", "shots"])));
        assert!(is_scripted(&args(&["app", "--fixture", "web-media"])));
        assert!(!is_scripted(&args(&["app", "--hidden"])));
        assert!(!is_scripted(&args(&["app", "--cwd", "/tmp/fixture"])));

        let ordinary =
            std::path::Path::new("/Users/example/Library/Application Support/Conduit Dev");
        let scratch = std::path::Path::new("/tmp/conduit-harness-1");
        // None named: a fresh one, never the app's own.
        assert_eq!(
            harness_profile(None, ordinary, scratch).unwrap(),
            scratch.join("user-data")
        );
        // The app's own profile, named: refused.
        assert!(harness_profile(Some(ordinary.to_path_buf()), ordinary, scratch).is_err());
        // Another profile the caller named: that one.
        let named = std::path::PathBuf::from("/tmp/e2e-profile-7");
        assert_eq!(
            harness_profile(Some(named.clone()), ordinary, scratch).unwrap(),
            named
        );
        assert_eq!(
            harness_service(Flavor::Dev),
            "app.cogwheel.conduit.desktop.dev.harness"
        );
        // The passes' own check before a reset.
        let paths = |user_data: PathBuf| AppPaths {
            flavor: Flavor::Dev,
            user_data,
            logs: PathBuf::from("/tmp/logs"),
        };
        assert!(!may_reset_profile(&paths(app_profile(Flavor::Dev))));
        assert!(may_reset_profile(&paths(scratch.join("user-data"))));
    }
}
