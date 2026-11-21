//! `--shots <dir>`: a scripted smoke pass over the real app.
//!
//! * Default: waits for the connection, captures the routed window (named
//!   after its route) and Settings › Appearance, each in light and dark.
//! * `--preview-route main`: also captures the main-frame placeholder,
//!   which a fresh dev profile cannot reach before signing in.
//! * `--expect-failure`: waits for a failed, unreadable-data or mismatch
//!   state instead and captures it; with `--smoke-reset` it then presses
//!   "Reset local data" and waits for the fresh daemon to connect.
//!
//! Shots are taken over a synthetic backdrop window, in-process, of the
//! app's own on-screen windows named by id (no Screen Recording permission
//! needed): another app's window or the real desktop never ends up in one.
//! The backdrop is ordered directly below the window shot, so its materials
//! blur only the backdrop. `SMOKE` lines go to stdout, and the pass ends
//! with a quit, which stops the daemon.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use conduit_components::capture::{CGRect, capture_windows};
use conduit_components::window as cw;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyWindowHandle, App, AsyncApp, Bounds, Context, Window, WindowBackgroundAppearance,
    WindowBounds, WindowOptions, div, linear_color_stop, linear_gradient, point, px, rgb, size,
};
use objc2::rc::Retained;
use objc2_app_kit::NSWindow;

use conduit_protocol::{NoParams, methods::SystemExportDiagnostics};

use crate::AppState;
use crate::prefs::ThemeMode;
use crate::stores::connection::Status;
use crate::stores::session::Route;
use crate::views::settings::{SETTINGS_SIZE, Tab};

const MARGIN: f64 = 24.;
const SETTLE: Duration = Duration::from_millis(1200);

/// What the pass checks.
#[derive(Clone, Debug, Default)]
pub struct SmokeOptions {
    pub expect_failure: bool,
    pub reset: bool,
    pub preview_main: bool,
    /// `--e2e <scenario>`: a live end-to-end pass ([`crate::e2e`]).
    #[cfg(feature = "harness")]
    pub e2e: Option<crate::e2e::E2eInputs>,
}

impl SmokeOptions {
    pub fn from_args(args: &[String]) -> Self {
        let has = |f: &str| args.iter().any(|a| a == f);
        let preview = args
            .iter()
            .position(|a| a == "--preview-route")
            .and_then(|i| args.get(i + 1));
        Self {
            expect_failure: has("--expect-failure"),
            reset: has("--smoke-reset"),
            preview_main: preview.is_some_and(|r| r == "main"),
            #[cfg(feature = "harness")]
            e2e: crate::e2e::E2eInputs::from_args(args),
        }
    }
}

struct Backdrop;

impl Render for Backdrop {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let dark = cx.global::<conduit_components::ConduitTheme>().dark;
        let (a, b, c) = if dark {
            (0x1d2a4a, 0x3b2a52, 0x16323a)
        } else {
            (0x9fb8e6, 0xe7c3c9, 0xb9dccf)
        };
        div()
            .size_full()
            .bg(linear_gradient(
                135.,
                linear_color_stop(rgb(a), 0.),
                linear_color_stop(rgb(b), 1.),
            ))
            .child(
                div()
                    .absolute()
                    .left(px(700.))
                    .top(px(380.))
                    .size(px(900.))
                    .rounded_full()
                    .bg(gpui_kit::Hsla::from(rgb(c)).opacity(0.55)),
            )
    }
}

thread_local! {
    /// The pass's backdrop window, once open (main thread only).
    static BACKDROP: std::cell::Cell<Option<AnyWindowHandle>> = const { std::cell::Cell::new(None) };
}

fn open_backdrop(cx: &mut App) -> Option<AnyWindowHandle> {
    let bounds = Bounds::new(point(px(40.), px(40.)), size(px(1460.), px(1000.)));
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: None,
        focus: false,
        is_movable: false,
        window_background: WindowBackgroundAppearance::Opaque,
        ..Default::default()
    };
    let handle = cw::open_window_clear_root(options, cx, |_, cx| cx.new(|_| Backdrop))
        .ok()
        .map(|(h, _)| h);
    BACKDROP.with(|b| b.set(handle));
    handle
}

/// Orders the backdrop directly below `handle`, at its level, so nothing
/// else lies between them for a material to blur.
fn backdrop_below(handle: AnyWindowHandle, cx: &mut App) {
    let Some(backdrop) = BACKDROP.with(|b| b.get()) else {
        return;
    };
    let Some(number) = handle
        .update(cx, |_, window, _| cw::macos::window_number(window))
        .ok()
        .flatten()
    else {
        return;
    };
    let _ = backdrop.update(cx, |_, window, _| cw::macos::order_below(window, number));
}

pub(crate) fn ns_window(handle: AnyWindowHandle, cx: &mut App) -> Option<Retained<NSWindow>> {
    handle
        .update(cx, |_, window, _| cw::macos::ns_window(window))
        .ok()
        .flatten()
}

/// Places a window (top-left in screen points). AppKit calls back into GPUI
/// from `setFrame` (windowDidMove), so this must run while no GPUI borrow is
/// held: never inside `cx.update` or a window update.
pub(crate) fn place(ns: &NSWindow, origin: (f64, f64), size: (f32, f32)) {
    let screen_h = ns.screen().map(|s| s.frame().size.height).unwrap_or(1080.);
    let frame = objc2_foundation::NSRect::new(
        objc2_foundation::NSPoint::new(origin.0, screen_h - origin.1 - f64::from(size.1)),
        objc2_foundation::NSSize::new(f64::from(size.0), f64::from(size.1)),
    );
    ns.setFrame_display(frame, true);
}

/// Puts the Settings window where the shots expect it.
#[cfg(feature = "harness")]
pub(crate) fn place_settings(handle: AnyWindowHandle, cx: &mut AsyncApp) {
    if let Some(ns) = cx.update(|cx| ns_window(handle, cx)) {
        place(&ns, (300., 130.), SETTINGS_SIZE);
    }
}

/// Ends the sheet attached to `ns` with its second button (Cancel), as Esc
/// would. Call outside any GPUI borrow. `false` when none is attached.
#[cfg(feature = "harness")]
pub(crate) fn end_attached_sheet(ns: &NSWindow) -> bool {
    let Some(sheet) = ns.attachedSheet() else {
        return false;
    };
    ns.endSheet_returnCode(&sheet, objc2_app_kit::NSAlertSecondButtonReturn);
    true
}

fn force_activate(handle: AnyWindowHandle, cx: &mut App) {
    use objc2::msg_send;
    use objc2::runtime::AnyObject;
    let _ = handle.update(cx, |_, window, _| window.activate_window());
    // SAFETY: plain AppKit messages on the main thread, outside GPUI borrows.
    unsafe {
        let app: *mut AnyObject = msg_send![objc2::class!(NSApplication), sharedApplication];
        let _: () = msg_send![app, activateIgnoringOtherApps: true];
    }
    if let Some(ns) = ns_window(handle, cx) {
        ns.makeKeyAndOrderFront(None);
    }
}

fn window_rect(handle: AnyWindowHandle, cx: &mut App) -> Option<CGRect> {
    handle
        .update(cx, |_, window, _| {
            let b = window.bounds();
            CGRect {
                x: f64::from(f32::from(b.origin.x)) - MARGIN,
                y: f64::from(f32::from(b.origin.y)) - MARGIN,
                w: f64::from(f32::from(b.size.width)) + 2. * MARGIN,
                h: f64::from(f32::from(b.size.height)) + 2. * MARGIN,
            }
        })
        .ok()
}

pub(crate) async fn shoot(handle: AnyWindowHandle, out: PathBuf, cx: &mut AsyncApp) {
    cx.update(|cx| {
        // Every pass that shoots (the fixtures' too) has the backdrop, so a
        // material never samples another app's windows.
        if BACKDROP.with(|b| b.get()).is_none() {
            open_backdrop(cx);
        }
        force_activate(handle, cx);
        backdrop_below(handle, cx);
    });
    cx.background_executor().timer(SETTLE).await;
    // `CONDUIT_SHOT_WINDOW=1`: only the window's own pixels, for when
    // something else (a system alert) sits above it on screen.
    if std::env::var_os("CONDUIT_SHOT_WINDOW").is_some() {
        let number = handle
            .update(cx, |_, window, _| {
                conduit_components::window::macos::window_number(window)
            })
            .ok()
            .flatten();
        let path = out.to_string_lossy().to_string();
        match number.map(|n| conduit_components::capture::capture_window(n, &path)) {
            Some(Ok((w, h))) => println!("SMOKE shot {} ({w}x{h})", out.display()),
            Some(Err(e)) => println!("SMOKE FAILED shot {}: {e}", out.display()),
            None => println!("SMOKE FAILED shot {}: window gone", out.display()),
        }
        return;
    }
    // This process's windows only (the window, its sheets and menus, the
    // backdrop under it), front to back, within the window's rect.
    let rect = cx.update(|cx| window_rect(handle, cx));
    let windows = crate::shell::grab::own_window_ids();
    match rect.map(|r| capture_windows(&windows, Some(r), &out.to_string_lossy())) {
        Some(Ok((w, h))) => println!("SMOKE shot {} ({w}x{h})", out.display()),
        Some(Err(e)) => println!("SMOKE FAILED shot {}: {e}", out.display()),
        None => println!("SMOKE FAILED shot {}: window gone", out.display()),
    }
}

pub(crate) fn set_mode(mode: ThemeMode, cx: &mut App) {
    let settings = cx.global::<AppState>().settings.clone();
    settings.update(cx, |s, cx| s.set_appearance(|a| a.mode = mode, cx));
    for w in cx.windows() {
        let _ = w.update(cx, |_, window, _| window.refresh());
    }
}

pub(crate) fn mode_name(mode: ThemeMode) -> &'static str {
    match mode {
        ThemeMode::Light => "light",
        ThemeMode::Dark => "dark",
        ThemeMode::System => "system",
    }
}

fn status_name(status: &Status, route: Route) -> &'static str {
    match (status, route) {
        (Status::Connected, Route::Main) => "connected-main",
        (Status::Connected, Route::Onboarding) => "connected-onboarding",
        (Status::Connected, Route::SignIn) => "connected-sign-in",
        (Status::Connected, Route::ConnectionIssue) => "connected-connection-issue",
        (Status::Failed { .. }, _) => "connection-failed",
        (Status::StoreUnreadable, _) => "store-unreadable",
        (Status::VersionMismatch { .. }, _) => "version-mismatch",
        _ => "connecting",
    }
}

async fn wait_for(want: impl Fn(&Status) -> bool, timeout: Duration, cx: &mut AsyncApp) -> Status {
    let deadline = Instant::now() + timeout;
    loop {
        let status = cx.update(current_status);
        if want(&status) || Instant::now() > deadline {
            return status;
        }
        cx.background_executor()
            .timer(Duration::from_millis(200))
            .await;
    }
}

/// The window's status, as the main window derives it.
pub fn current_status(cx: &mut App) -> Status {
    let state = cx.global::<AppState>();
    let session = state.stores.session.read(cx);
    let routed = session.route(cx) != Route::Unknown;
    let error = session.error.as_ref().map(|e| e.to_string());
    state.connection.read(cx).status(routed, error.as_deref())
}

pub fn current_route(cx: &mut App) -> Route {
    let session = cx.global::<AppState>().stores.session.clone();
    session.read(cx).route(cx)
}

fn report(cx: &mut App) -> Route {
    let route = current_route(cx);
    let c = cx.global::<AppState>().connection.read(cx);
    if let Some(h) = &c.handshake {
        println!(
            "SMOKE handshake daemon={} protocol={} platform={} needsOnboarding={:?} session={}",
            h.daemon_version, h.protocol_version, h.platform, h.needs_onboarding, h.session_id
        );
    }
    println!("SMOKE route {:?} daemon {:?}", route, c.daemon);
    route
}

/// `SMOKE intents <n> types resolve` (packaging/macos/smoke.sh looks for
/// it), or says the bundle has no metadata (a bare binary) or what is
/// missing.
async fn intents_types() {
    let script = serde_json::json!({ "steps": [{ "intent": "types" }] });
    let Some(out) = crate::intents::self_test(&script).await else {
        println!("SMOKE FAILED intents self-test did not answer");
        return;
    };
    let step = &out[0];
    let missing = step["missing"].as_array().map(Vec::len).unwrap_or(0);
    match (step["ok"].as_bool(), step["named"].as_u64()) {
        (Some(true), Some(named)) if missing == 0 && named > 0 => {
            println!("SMOKE intents {named} types resolve")
        }
        (Some(true), _) => println!("SMOKE FAILED intents types missing: {}", step["missing"]),
        _ => println!("SMOKE intents: {}", step["error"].as_str().unwrap_or("?")),
    }
}

pub(crate) async fn shoot_both_modes(
    handle: AnyWindowHandle,
    dir: &std::path::Path,
    name: &str,
    cx: &mut AsyncApp,
) {
    for mode in [ThemeMode::Light, ThemeMode::Dark] {
        cx.update(|cx| set_mode(mode, cx));
        shoot(
            handle,
            dir.join(format!("{name}-{}.png", mode_name(mode))),
            cx,
        )
        .await;
    }
}

fn kept_folders(user_data: &std::path::Path) -> Vec<String> {
    let parent = user_data
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_default();
    let name = user_data
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    std::fs::read_dir(&parent)
        .map(|d| {
            d.filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().to_string())
                .filter(|n| n.starts_with(&format!("{name} (reset ")))
                .collect()
        })
        .unwrap_or_default()
}

/// The `--e2e` pass the options ask for, run to its end: `true` when
/// there was one.
#[cfg(feature = "harness")]
async fn run_e2e(options: &SmokeOptions, dir: &Path, started: Instant, cx: &mut AsyncApp) -> bool {
    let Some(inputs) = options.e2e.clone() else {
        return false;
    };
    let scenario = inputs.scenario.clone();
    let passed = crate::e2e::run(inputs, dir.to_path_buf(), cx).await;
    println!(
        "SMOKE e2e {scenario} {} after {:?}",
        if passed { "passed" } else { "FAILED" },
        started.elapsed()
    );
    true
}

/// Builds without the test harness have no `--e2e` passes.
#[cfg(not(feature = "harness"))]
async fn run_e2e(_: &SmokeOptions, _: &Path, _: Instant, _: &mut AsyncApp) -> bool {
    false
}

/// Runs the pass, then quits.
pub fn run(dir: PathBuf, options: SmokeOptions, cx: &mut App) {
    std::fs::create_dir_all(&dir).ok();
    open_backdrop(cx);
    let started = Instant::now();
    cx.spawn(async move |cx: &mut AsyncApp| {
        // The window the app opened with: the main window on a profile that
        // is set up, the setup window on a fresh one (each at its size).
        let front = cx.update(crate::windows::front_window);
        if let Some(handle) = front {
            let is_main = cx.update(|cx| cx.global::<AppState>().main_window == Some(handle));
            if let Some(ns) = cx.update(|cx| ns_window(handle, cx)) {
                // The setup window keeps the height it took.
                let size = if is_main {
                    cw::MAIN_WINDOW_SIZE
                } else {
                    let frame = ns.frame().size;
                    (frame.width as f32, frame.height as f32)
                };
                place(&ns, (120., 90.), size);
            }
        }
        let original = cx.update(|cx| {
            cx.global::<AppState>()
                .settings
                .read(cx)
                .prefs
                .appearance
                .mode
        });
        let Some(main) = front else {
            println!("SMOKE FAILED no window");
            cx.update(|cx| cx.quit());
            return;
        };

        if run_e2e(&options, &dir, started, cx).await {
            // The pass reported itself.
        } else if options.expect_failure {
            let status = wait_for(
                |s| {
                    matches!(
                        s,
                        Status::Failed { .. }
                            | Status::StoreUnreadable
                            | Status::VersionMismatch { .. }
                    )
                },
                Duration::from_secs(90),
                cx,
            )
            .await;
            println!("SMOKE status {status:?} after {:?}", started.elapsed());
            // The wait also ends at its timeout: a pass that never failed
            // is a failed negative pass.
            if !matches!(
                status,
                Status::Failed { .. } | Status::StoreUnreadable | Status::VersionMismatch { .. }
            ) {
                println!("SMOKE FAILED expected a failure, got {status:?}");
            }
            let route = cx.update(report);
            shoot_both_modes(main, &dir, status_name(&status, route), cx).await;
            if options.reset && status == Status::StoreUnreadable {
                let user_data = cx.update(|cx| cx.global::<AppState>().paths.user_data.clone());
                cx.update(|cx| {
                    let c = cx.global::<AppState>().connection.clone();
                    c.update(cx, |c, cx| c.reset_local_data(cx));
                });
                let status =
                    wait_for(|s| *s == Status::Connected, Duration::from_secs(60), cx).await;
                println!("SMOKE after reset: {status:?}");
                let route = cx.update(report);
                let kept = kept_folders(&user_data);
                println!("SMOKE kept old data as {kept:?}");
                if status != Status::Connected || kept.is_empty() {
                    println!("SMOKE FAILED reset did not recover");
                }
                let name = format!("after-reset-{}", status_name(&status, route));
                shoot_both_modes(main, &dir, &name, cx).await;
            }
        } else {
            let status = wait_for(|s| *s == Status::Connected, Duration::from_secs(90), cx).await;
            println!("SMOKE status {status:?} after {:?}", started.elapsed());
            if status != Status::Connected {
                println!("SMOKE FAILED never connected");
            }
            let route = cx.update(report);
            cx.update(|cx| {
                let menus: Vec<String> = cx
                    .get_menus()
                    .unwrap_or_default()
                    .iter()
                    .map(|m| m.name.to_string())
                    .collect();
                println!("SMOKE menus {menus:?}");
            });
            // The daemon's diagnostics export, without revealing it in
            // Finder (Settings › About does that).
            let export = cx.update(|cx| {
                cx.global::<AppState>()
                    .connection
                    .read(cx)
                    .client
                    .call::<SystemExportDiagnostics>(&NoParams)
            });
            match export.await {
                Ok(d) if std::path::Path::new(&d.path).is_file() => {
                    println!("SMOKE diagnostics {} bytes, zip exists", d.size_bytes)
                }
                Ok(d) => println!("SMOKE FAILED diagnostics zip missing: {}", d.path),
                Err(e) => println!("SMOKE FAILED diagnostics: {e}"),
            }
            // The App Intents: every type the bundle's Metadata.appintents
            // names (the runtime looks them up by name) is in this binary.
            intents_types().await;
            shoot_both_modes(main, &dir, status_name(&status, route), cx).await;
            if options.preview_main && route != Route::Main {
                cx.update(|cx| {
                    let s = cx.global::<AppState>().stores.session.clone();
                    s.update(cx, |s, cx| s.preview_route(Some(Route::Main), cx));
                });
                shoot_both_modes(main, &dir, "preview-main-placeholder", cx).await;
            }
            cx.update(|cx| crate::open_settings(Some(Tab::Appearance), cx));
            let settings_window = cx.update(|cx| {
                cx.global::<AppState>()
                    .settings_window
                    .as_ref()
                    .map(|(h, _)| *h)
            });
            match settings_window {
                Some(handle) => {
                    if let Some(ns) = cx.update(|cx| ns_window(handle, cx)) {
                        place(&ns, (300., 130.), SETTINGS_SIZE);
                    }
                    shoot_both_modes(handle, &dir, "settings-appearance", cx).await;
                    // About: the version and the Updates section.
                    cx.update(|cx| crate::open_settings(Some(Tab::About), cx));
                    println!(
                        "SMOKE version {} build {} updater {}",
                        crate::VERSION,
                        crate::BUILD.unwrap_or("-"),
                        cx.update(|cx| crate::updates::available(cx))
                    );
                    shoot_both_modes(handle, &dir, "settings-about", cx).await;
                }
                None => println!("SMOKE FAILED settings window did not open"),
            }
        }
        cx.update(|cx| set_mode(original, cx));
        println!("SMOKE quitting");
        cx.update(crate::views::sheet::quit);
    })
    .detach();
}
