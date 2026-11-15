//! The app's views, built from `conduit-components`.

pub mod access_sheet;
pub mod accounts;
pub mod add_account;
pub mod approvals;
pub mod chat;
pub mod chat_pane;
pub mod chat_settings;
#[cfg(test)]
mod controls_tests;
pub mod dates;
pub mod direct;
pub mod folder_settings;
pub mod forms;
pub mod hermes;
pub mod image_viewer;
pub mod main_window;
pub mod onboarding;
pub mod palette;
pub mod panes;
pub mod privacy;
pub mod quick_ask;
pub mod release_notes;
pub mod server_form;
pub mod settings;
pub mod setup_window;
pub mod sheet;
pub mod sidebar;
pub mod sidebar_keys;
pub mod sidebar_model;
pub mod sign_in;
pub mod status;
pub mod toasts;
pub mod valves;
pub mod words;

/// The globals a view needs to draw in a test window: GPUI Kit, Conduit's
/// light theme, the components' strings and English.
#[cfg(test)]
pub(crate) fn test_globals(cx: &mut gpui_kit::App) {
    use conduit_components::theme::{ConduitTheme, DesignPrefs, install};
    gpui_kit::init(cx);
    install(
        ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
        cx,
    );
    cx.set_global(conduit_components::Strings::default());
    cx.set_global(crate::l10n::L10n::new("en"));
}
