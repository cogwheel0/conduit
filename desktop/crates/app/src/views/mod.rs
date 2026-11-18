//! The app's views, built from `conduit-components`.

pub mod a11y;
pub mod access_sheet;
pub mod accounts;
pub mod add_account;
pub mod approvals;
pub mod calendar;
pub mod channels;
pub mod chat;
pub mod chat_pane;
pub mod chat_settings;
pub mod connection_issue;
#[cfg(test)]
mod controls_tests;
pub mod dates;
pub mod direct;
pub mod folder_settings;
pub mod forms;
pub mod hermes;
pub mod hermes_cards;
pub mod hermes_connection;
pub mod hermes_context_sheet;
pub mod hermes_diff_sheet;
pub mod hermes_faces;
pub mod hermes_job;
pub mod hermes_mcp;
pub mod hermes_room;
pub mod hermes_room_sheets;
pub mod hermes_rooms;
pub mod hermes_sessions;
pub mod hermes_work_sheet;
pub mod image_viewer;
pub mod librechat_sign_in;
pub mod main_window;
pub mod model_logo;
pub mod notes;
pub mod onboarding;
pub mod palette;
pub mod panes;
pub mod privacy;
pub mod quick_ask;
pub mod release_notes;
pub mod server_files;
pub mod server_form;
pub mod settings;
pub mod setup_window;
pub mod sheet;
pub mod sidebar;
pub mod sidebar_keys;
pub mod sidebar_model;
pub mod sign_in;
pub mod status;
pub mod tasks;
pub mod terminal;
pub mod toasts;
pub mod two_step;
pub mod valves;
pub mod words;
pub mod workspace;

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

/// Whether a pane's list commands (the arrows, Return, ⌘⌫) take the keys
/// now: the pane or anything in it has focus (a row Tab reached), but not
/// one of its text `fields`, whose keys are typed.
pub fn list_has_keys(
    pane: &gpui_kit::FocusHandle,
    fields: &[gpui_kit::FocusHandle],
    window: &gpui_kit::Window,
    cx: &gpui_kit::App,
) -> bool {
    pane.contains_focused(window, cx) && !fields.iter().any(|f| f.contains_focused(window, cx))
}
