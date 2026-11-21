//! Which window fronts the app: the setup window or the main window.
//!
//! * **The setup window** ([`SetupWindow`], 640 pt wide, as tall as its
//!   chooser, not resizable) holds everything before a session: the
//!   first-run chooser and its three paths, and sign-in, whether it follows
//!   the server form on first run, an account added from Settings, or a
//!   session that expired. It is compact, as Setup Assistant and Mail's
//!   account sheet are, instead of a column floating in the main window.
//! * **The main window** opens once there is a session (routed to Main),
//!   and closes when there no longer is; it reopens at its saved frame.
//!
//! The route is known only after the daemon answers. Until then the app
//! opens what it fronted last time (`WindowState::last_main`), so a set-up
//! Mac opens straight onto the main window; [`sync`] swaps the two when the
//! route disagrees, and while a server is being checked (the setup form's
//! Connect, Settings' Add Account sheet) it waits: the new account is
//! active before the server answers, and a refusal undoes it.

use conduit_components::window as cw;
use gpui_kit::{
    AnyWindowHandle, App, AppContext as _, Bounds, WindowBounds, WindowOptions, px, size,
};

use crate::AppState;
use crate::l10n::ActiveL10n as _;
use crate::stores::session::Route;
use crate::views::setup_window::SetupWindow;

/// The setup window's width.
pub const SETUP_WIDTH: f32 = 640.;
/// Its height until the chooser has been measured: what a page other than
/// the chooser keeps when the window opens on one.
pub const SETUP_FIRST_HEIGHT: f32 = 640.;

/// The window the app fronts with.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Front {
    Setup,
    Main,
}

/// The window `route` asks for; `None` while it is unknown.
pub fn wanted(route: Route) -> Option<Front> {
    match route {
        Route::Main => Some(Front::Main),
        Route::Onboarding | Route::SignIn | Route::ConnectionIssue => Some(Front::Setup),
        Route::Unknown => None,
    }
}

/// The window to open now: the route's, or before it is known, the one
/// the app fronted last (`last_main`).
pub fn front_for(route: Route, last_main: bool) -> Front {
    wanted(route).unwrap_or(if last_main { Front::Main } else { Front::Setup })
}

fn route(cx: &App) -> Route {
    cx.try_global::<AppState>()
        .map_or(Route::Unknown, |s| s.stores.session.read(cx).route(cx))
}

/// The window the app fronts with now.
pub fn front(cx: &App) -> Front {
    let last_main = cx
        .try_global::<AppState>()
        .is_some_and(|s| s.layout.read(cx).last_main());
    front_for(route(cx), last_main)
}

/// Whether a server is being checked: the route swings while it is.
fn checking(cx: &App) -> bool {
    let Some(state) = cx.try_global::<AppState>() else {
        return false;
    };
    let setup = state
        .setup_window
        .as_ref()
        .is_some_and(|(_, v)| v.read(cx).onboarding.read(cx).holds(cx));
    let sheet = state
        .settings_window
        .as_ref()
        .and_then(|(_, v)| v.read(cx).add_sheet.clone())
        .is_some_and(|s| s.form(cx).read(cx).busy);
    setup || sheet
}

/// Follows the route: closes the main window when a session ends (the
/// setup window takes over if it was on screen) and swaps the setup
/// window for the main one once there is a session again.
pub fn sync(cx: &mut App) {
    let Some(want) = wanted(route(cx)) else {
        return;
    };
    if checking(cx) {
        return;
    }
    if let Some(layout) = cx.try_global::<AppState>().map(|s| s.layout.clone()) {
        layout.update(cx, |l, cx| l.set_last_main(want == Front::Main, cx));
    }
    match want {
        Front::Main if setup_alive(cx) => {
            log::info!("windows: a session; the main window takes over");
            crate::open_main(cx);
            crate::activate_main_window(cx);
            close_setup(cx);
        }
        Front::Setup if crate::main_window_alive(cx) => {
            // Closed to the menu bar, it stays there: the setup window
            // waits for the menu-bar item, the Dock or a link.
            let shown = crate::desktop::main_visible(cx);
            log::info!("windows: no session; the setup window takes over (shown: {shown})");
            close_main(cx);
            if shown {
                open_setup(cx);
            }
        }
        _ => {}
    }
}

/// Opens (or raises) the window the app fronts with now.
pub fn open_front(cx: &mut App) {
    match front(cx) {
        Front::Main => crate::open_main(cx),
        Front::Setup => open_setup(cx),
    }
}

/// [`open_front`], with the app brought forward.
pub fn show_front(cx: &mut App) {
    open_front(cx);
    cx.activate(true);
}

/// The window the app fronts with, if it is open.
pub fn front_window(cx: &mut App) -> Option<AnyWindowHandle> {
    let state = cx.try_global::<AppState>()?;
    let main = state.main_window;
    let setup = state.setup_window.as_ref().map(|(h, _)| *h);
    let alive =
        |h: Option<AnyWindowHandle>, cx: &mut App| h.filter(|h| h.update(cx, |_, _, _| ()).is_ok());
    match front(cx) {
        Front::Main => alive(main, cx).or_else(|| alive(setup, cx)),
        Front::Setup => alive(setup, cx).or_else(|| alive(main, cx)),
    }
}

pub(crate) fn setup_alive(cx: &mut App) -> bool {
    let Some(handle) = cx
        .try_global::<AppState>()
        .and_then(|s| s.setup_window.as_ref().map(|(h, _)| *h))
    else {
        return false;
    };
    handle.update(cx, |_, _, _| ()).is_ok()
}

/// The setup window's options: centred, not resizable, a plain title bar
/// (AppKit drags it), titled for what it holds. It opens hidden: the
/// window shows itself once it is as tall as its chooser
/// ([`SetupWindow`]), so it never changes size as it appears.
pub fn setup_options(title: &str, cx: &App) -> WindowOptions {
    let bounds = Bounds::centered(None, size(px(SETUP_WIDTH), px(SETUP_FIRST_HEIGHT)), cx);
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: Some(gpui_kit::TitlebarOptions {
            title: Some(title.to_string().into()),
            appears_transparent: true,
            traffic_light_position: None,
        }),
        focus: false,
        show: false,
        is_movable: true,
        is_resizable: false,
        is_minimizable: true,
        app_owns_titlebar_drag: false,
        window_background: gpui_kit::WindowBackgroundAppearance::Opaque,
        window_min_size: None,
        ..Default::default()
    }
}

/// Opens (or raises) the setup window.
pub fn open_setup(cx: &mut App) {
    if let Some((handle, view)) = cx
        .try_global::<AppState>()
        .and_then(|s| s.setup_window.clone())
        && handle
            .update(cx, |_, window, cx| {
                // Still being sized, it shows itself.
                if view.read(cx).shown() {
                    window.activate_window();
                }
            })
            .is_ok()
    {
        return;
    }
    let Some(stores) = cx.try_global::<AppState>().map(|s| s.stores.clone()) else {
        return;
    };
    let title = cx.l10n().desktop_set_up_conduit();
    let options = setup_options(&title, cx);
    match cw::open_window_clear_root(options, cx, |window, cx| {
        cx.new(|cx| SetupWindow::new(stores, window, cx))
    }) {
        Ok((handle, view)) => {
            cx.global_mut::<AppState>().setup_window = Some((handle, view));
            log::info!("windows: setup window open");
        }
        Err(e) => log::error!("could not open the setup window: {e}"),
    }
}

/// Closes the setup window (once the main window is up).
fn close_setup(cx: &mut App) {
    let Some((handle, _)) = cx
        .try_global::<AppState>()
        .and_then(|s| s.setup_window.clone())
    else {
        return;
    };
    cx.global_mut::<AppState>().setup_window = None;
    // Outside this update: the window may be the one updating.
    cx.defer(move |cx| {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    });
}

/// Closes the main window (no session to show); it reopens at its saved
/// frame once there is one.
fn close_main(cx: &mut App) {
    let Some(handle) = cx.try_global::<AppState>().and_then(|s| s.main_window) else {
        return;
    };
    if let Some(layout) = cx.try_global::<AppState>().map(|s| s.layout.clone()) {
        layout.read(cx).save_now();
    }
    let state = cx.global_mut::<AppState>();
    state.main_window = None;
    state.main_view = None;
    cx.defer(move |cx| {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    });
}

/// Follows the session from launch on.
pub fn install(cx: &mut App) {
    let Some(state) = cx.try_global::<AppState>() else {
        return;
    };
    let (session, accounts, connection) = (
        state.stores.session.clone(),
        state.stores.accounts.clone(),
        state.connection.clone(),
    );
    cx.observe(&session, |_, cx| cx.defer(sync)).detach();
    cx.observe(&accounts, |_, cx| cx.defer(sync)).detach();
    cx.observe(&connection, |_, cx| cx.defer(sync)).detach();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_session_fronts_the_main_window_and_anything_else_setup() {
        assert_eq!(wanted(Route::Main), Some(Front::Main));
        assert_eq!(wanted(Route::Onboarding), Some(Front::Setup));
        // A session that expired signs in again in the compact window.
        assert_eq!(wanted(Route::SignIn), Some(Front::Setup));
        assert_eq!(wanted(Route::Unknown), None);
    }

    #[test]
    fn before_the_daemon_answers_the_app_opens_what_it_fronted_last() {
        assert_eq!(front_for(Route::Unknown, true), Front::Main);
        assert_eq!(front_for(Route::Unknown, false), Front::Setup);
        // Once the route is known, it decides.
        assert_eq!(front_for(Route::Onboarding, true), Front::Setup);
        assert_eq!(front_for(Route::Main, false), Front::Main);
    }

    #[gpui_kit::test]
    fn the_setup_window_is_compact_fixed_and_dragged_by_appkit(cx: &mut gpui_kit::TestAppContext) {
        cx.update(|cx| {
            let o = setup_options("Set Up Conduit", cx);
            assert!(!o.is_resizable && o.is_movable && !o.app_owns_titlebar_drag);
            // Shown by the window once it is sized.
            assert!(!o.show && !o.focus);
            // Not the main window's minimum (720×480).
            assert!(o.window_min_size.is_none());
            match o.window_bounds {
                Some(WindowBounds::Windowed(b)) => assert_eq!(
                    (f32::from(b.size.width), f32::from(b.size.height)),
                    (SETUP_WIDTH, SETUP_FIRST_HEIGHT)
                ),
                other => panic!("{other:?}"),
            }
        });
    }
}
