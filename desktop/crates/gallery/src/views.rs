//! Builds each screen's root view.

use gpui_kit::prelude::*;
use gpui_kit::{AnyView, App, Window, div};

use crate::screens::Screen;
use crate::screens::main_window::MainScreen;
use crate::screens::other::{FirstRunScreen, MenuBarScene, QuickAskScreen, SettingsScreen};

/// Width of the Settings window's sidebar.
pub const SETTINGS_SIDEBAR: f32 = 210.;

pub fn build(screen: Screen, window: &mut Window, cx: &mut App) -> gpui_kit::Entity<Root> {
    let view: AnyView = match screen {
        Screen::OnboardingBackend | Screen::OnboardingServer | Screen::SignIn => {
            cx.new(|cx| FirstRunScreen::new(screen, window, cx)).into()
        }
        Screen::Accounts | Screen::SettingsAppearance => {
            cx.new(|_| SettingsScreen::new(screen)).into()
        }
        Screen::QuickAsk | Screen::QuickAskEmpty => {
            cx.new(|cx| QuickAskScreen::new(screen, window, cx)).into()
        }
        Screen::MenuBar => cx.new(|_| MenuBarScene).into(),
        Screen::Chrome(shot) => cx
            .new(|cx| crate::screens::chrome::ChromeScreen::new(shot, window, cx))
            .into(),
        Screen::MainEmpty
        | Screen::MainStreaming
        | Screen::MainLong
        | Screen::Sidebar
        | Screen::PaletteRecent
        | Screen::PaletteSearch
        | Screen::ApprovalTool
        | Screen::ApprovalSelect
        | Screen::ContextMenu
        | Screen::ModelPicker => cx.new(|cx| MainScreen::new(screen, window, cx)).into(),
    };
    cx.new(|_| Root(view))
}

/// Wraps a screen so every window has one root type.
pub struct Root(AnyView);

impl Render for Root {
    fn render(&mut self, _: &mut Window, _: &mut gpui_kit::Context<Self>) -> impl IntoElement {
        div().size_full().child(self.0.clone())
    }
}

/// Hides the standard window buttons (drawn scenes and the Quick Ask panel).
pub fn hide_window_buttons(window: &Window) {
    use objc2::msg_send;
    use objc2::runtime::AnyObject;
    let Some(ns) = conduit_components::window::macos::ns_window(window) else {
        return;
    };
    for kind in 0usize..3 {
        // SAFETY: standardWindowButton: returns nil or a live NSButton.
        unsafe {
            let button: *mut AnyObject = msg_send![&*ns, standardWindowButton: kind];
            if !button.is_null() {
                let _: () = msg_send![button, setHidden: true];
            }
        }
    }
}

/// Makes a window borderless and clear, its content clipped to `radius`
/// (none at 0), for the chrome screens: the image is the drawn window alone,
/// with no Mac frame, shadow or corners.
pub fn make_chrome_window(window: &Window, radius: f32) {
    use objc2::msg_send;
    use objc2::runtime::AnyObject;
    let Some(ns) = conduit_components::window::macos::ns_window(window) else {
        return;
    };
    // SAFETY: AppKit and Core Animation messages on the gallery's own live
    // NSWindow, its content view and that view's layer, on the main thread.
    unsafe {
        let _: () = msg_send![&*ns, setHasShadow: false];
        let _: () = msg_send![&*ns, setOpaque: false];
        let clear: *mut AnyObject = msg_send![objc2::class!(NSColor), clearColor];
        let _: () = msg_send![&*ns, setBackgroundColor: clear];
        if radius <= 0. {
            return;
        }
        let view: *mut AnyObject = msg_send![&*ns, contentView];
        if view.is_null() {
            return;
        }
        let _: () = msg_send![view, setWantsLayer: true];
        let layer: *mut AnyObject = msg_send![view, layer];
        if layer.is_null() {
            return;
        }
        let _: () = msg_send![layer, setCornerRadius: radius as f64];
        let _: () = msg_send![layer, setMasksToBounds: true];
    }
}

/// Asks AppKit to make the gallery the active app, so windows render with
/// key-window chrome (coloured traffic lights, active selection colours).
pub fn force_activate(window: &Window) {
    use objc2::msg_send;
    use objc2::runtime::AnyObject;
    // SAFETY: plain AppKit messages on the main thread.
    unsafe {
        let app: *mut AnyObject = msg_send![objc2::class!(NSApplication), sharedApplication];
        let _: () = msg_send![app, activateIgnoringOtherApps: true];
        let current: *mut AnyObject =
            msg_send![objc2::class!(NSRunningApplication), currentApplication];
        // NSApplicationActivateAllWindows | IgnoringOtherApps (deprecated but honoured).
        let _: bool = msg_send![current, activateWithOptions: 3usize];
    }
    if let Some(ns) = conduit_components::window::macos::ns_window(window) {
        // SAFETY: a live NSWindow.
        unsafe {
            let _: () = msg_send![&*ns, makeKeyAndOrderFront: std::ptr::null::<AnyObject>()];
        }
    }
}
