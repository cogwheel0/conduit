//! The words the components draw themselves: labels, placeholders and
//! accessibility names.
//!
//! A GPUI global. The app installs one built from its localized catalogs
//! (and again when the language changes); without one, components use
//! English ([`Strings::default`]), which is what the gallery shows.
//! Templates keep `{name}`-style placeholders and are filled with
//! [`fill`].

use std::sync::OnceLock;

use gpui_kit::{App, Global, SharedString};

#[derive(Clone, Debug, PartialEq)]
pub struct Strings {
    // Sidebar
    pub sidebar: SharedString,
    pub hide_sidebar: SharedString,
    pub search: SharedString,
    pub search_chats: SharedString,
    pub settings: SharedString,
    pub pinned: SharedString,
    pub folders: SharedString,
    pub pin: SharedString,
    pub unpin: SharedString,
    pub new_folder: SharedString,
    // Command palette
    pub palette: SharedString,
    pub palette_placeholder: SharedString,
    pub palette_results: SharedString,
    pub palette_navigate: SharedString,
    pub palette_open: SharedString,
    pub palette_open_in_background: SharedString,
    // Composer and transcript
    pub composer: SharedString,
    pub message_field: SharedString,
    pub attach_files: SharedString,
    pub conversation: SharedString,
    pub chat_toolbar: SharedString,
    pub messages: SharedString,
    pub new_chat: SharedString,
    pub disclaimer: SharedString,
    pub tool_result: SharedString,
    pub output: SharedString,
    /// A code block's Preview button.
    pub preview: SharedString,
    pub temporary_chat: SharedString,
    pub sources: SharedString,
    pub previous_version: SharedString,
    pub next_version: SharedString,
    pub copy: SharedString,
    /// Said after a code block's Copy.
    pub code_copied: SharedString,
    /// A code block's accessible name; `{name}` is its language.
    pub code_block: SharedString,
    pub edit: SharedString,
    pub regenerate: SharedString,
    pub good_response: SharedString,
    pub bad_response: SharedString,
    pub more: SharedString,
    pub dismiss: SharedString,
    // Model picker and Quick Ask
    pub models: SharedString,
    pub search_models: SharedString,
    pub all_models: SharedString,
    pub quick_ask: SharedString,
    pub ask: SharedString,
    pub recent: SharedString,
    pub recent_questions: SharedString,
    pub continue_in_conduit: SharedString,
    pub close: SharedString,
    // Settings
    pub settings_sections: SharedString,
    pub palette_choice: SharedString,
    pub accounts: SharedString,
    pub active: SharedString,
    pub switch: SharedString,
    pub sign_in_again: SharedString,
    pub session_expired: SharedString,
    /// `{name}`
    pub more_actions_for: SharedString,
    // Approval cards
    pub allow: SharedString,
    pub allow_once: SharedString,
    pub allow_session: SharedString,
    pub always_allow: SharedString,
    pub deny: SharedString,
    pub cancel: SharedString,
    pub submit: SharedString,
    /// `{index}`, `{count}`
    pub position: SharedString,
    // First run
    pub set_up_conduit: SharedString,
    pub welcome_title: SharedString,
    pub welcome_subtitle: SharedString,
    pub backend: SharedString,
    pub open_webui: SharedString,
    pub open_webui_detail: SharedString,
    pub direct: SharedString,
    pub direct_detail: SharedString,
    pub hermes: SharedString,
    pub hermes_detail: SharedString,
    pub librechat: SharedString,
    pub librechat_detail: SharedString,
    /// The mark beside a backend still new ("Beta").
    pub beta: SharedString,
    /// The chooser's section titles, as the phone groups its backends.
    pub self_hosted_section: SharedString,
    pub model_apis_section: SharedString,
    pub continue_label: SharedString,
    pub back: SharedString,
    pub connect_title: SharedString,
    pub connect_subtitle: SharedString,
    pub server_url: SharedString,
    pub server_url_hint: SharedString,
    pub server_url_help: SharedString,
    pub display_name: SharedString,
    pub display_name_help: SharedString,
    pub advanced: SharedString,
    pub self_signed: SharedString,
    pub self_signed_help: SharedString,
    pub client_certificate: SharedString,
    pub client_certificate_help: SharedString,
    pub custom_headers: SharedString,
    pub custom_headers_help: SharedString,
    pub add: SharedString,
    pub choose_file: SharedString,
    pub connect: SharedString,
    pub sign_in: SharedString,
    pub sign_in_subtitle: SharedString,
    pub email: SharedString,
    pub password: SharedString,
    pub or: SharedString,
    pub sso: SharedString,
    pub ldap: SharedString,
    /// The sign-in method that takes a session token (the phone's Token).
    pub token: SharedString,
    pub change: SharedString,
    /// `{name}`
    pub server_chip: SharedString,
    /// The sidebar's sync button; its status follows in the tooltip.
    pub sync_now: SharedString,
    /// The sidebar search field's ⓧ button.
    pub clear_search: SharedString,
    /// The heading over an answer's follow-up suggestions.
    pub suggestions: SharedString,
    /// The chat toolbar's Share button.
    pub share_chat: SharedString,
    /// The server form's name placeholder.
    pub server_name_placeholder: SharedString,
}

impl Default for Strings {
    fn default() -> Self {
        let s = |v: &'static str| SharedString::from(v);
        Self {
            sidebar: s("Sidebar"),
            hide_sidebar: s("Hide Sidebar"),
            search: s("Search"),
            search_chats: s("Search chats"),
            settings: s("Settings"),
            pinned: s("Pinned"),
            folders: s("Folders"),
            pin: s("Pin"),
            unpin: s("Unpin"),
            new_folder: s("New Folder"),
            palette: s("Command Palette"),
            palette_placeholder: s("Search chats and commands"),
            palette_results: s("Results"),
            palette_navigate: s("Navigate"),
            palette_open: s("Open"),
            palette_open_in_background: s("Open in Background"),
            composer: s("Message Composer"),
            message_field: s("Message"),
            attach_files: s("Attach Files"),
            conversation: s("Chat"),
            chat_toolbar: s("Chat Toolbar"),
            messages: s("Messages"),
            new_chat: s("New Chat"),
            disclaimer: s("Models can make mistakes. Check important info."),
            tool_result: s("Result"),
            output: s("Output"),
            preview: s("Preview"),
            temporary_chat: s("Temporary Chat"),
            sources: s("Sources"),
            previous_version: s("Previous Answer"),
            next_version: s("Next Answer"),
            copy: s("Copy"),
            code_copied: s("Code copied to the clipboard."),
            code_block: s("{name} code"),
            edit: s("Edit"),
            regenerate: s("Regenerate"),
            good_response: s("Good Answer"),
            bad_response: s("Bad Answer"),
            more: s("More"),
            dismiss: s("Dismiss"),
            models: s("Models"),
            search_models: s("Search models"),
            all_models: s("All Models"),
            quick_ask: s("Quick Ask"),
            ask: s("Ask"),
            recent: s("Recent"),
            recent_questions: s("Recent Questions"),
            continue_in_conduit: s("Continue in Main Window"),
            close: s("Close"),
            settings_sections: s("Settings Sections"),
            palette_choice: s("Palette"),
            accounts: s("Accounts"),
            active: s("Active"),
            switch: s("Switch"),
            sign_in_again: s("Sign In Again…"),
            session_expired: s("Session expired. Sign in to sync this account."),
            more_actions_for: s("More Actions for {name}"),
            allow: s("Allow"),
            allow_once: s("Allow Once"),
            allow_session: s("Allow for This Session"),
            always_allow: s("Always Allow"),
            deny: s("Deny"),
            cancel: s("Cancel"),
            submit: s("Submit"),
            position: s("{index} of {count}"),
            set_up_conduit: s("Set Up Conduit"),
            welcome_title: s("Choose How to Connect"),
            welcome_subtitle: s("You can add more connections later in Settings."),
            backend: s("Connection Type"),
            open_webui: s("Open WebUI"),
            open_webui_detail: s("Sign in to your server for synced chats, notes, and more."),
            direct: s("Connect Directly"),
            direct_detail: s(
                "Chat through OpenAI, OpenRouter, or Ollama. Your key stays on this device.",
            ),
            hermes: s("Hermes Agent"),
            hermes_detail: s("Connect a self-hosted Hermes agent."),
            librechat: s("LibreChat"),
            librechat_detail: s(
                "Sign in to your LibreChat server for synced chats, agents, and more.",
            ),
            beta: s("Beta"),
            self_hosted_section: s("Self-Hosted Services"),
            model_apis_section: s("Model APIs"),
            continue_label: s("Continue"),
            back: s("Back"),
            connect_title: s("Connect to Server"),
            connect_subtitle: s("Use your Open WebUI account to sign in to the server below."),
            server_url: s("Server Address"),
            server_url_hint: s("https://openwebui.example.com"),
            server_url_help: s("Conduit checks the server before you sign in."),
            display_name: s("Server Name"),
            display_name_help: s("Optional. Shown in the sidebar and the account switcher."),
            advanced: s("Advanced Settings"),
            self_signed: s("Allow an Unverified Certificate"),
            self_signed_help: s("Only for servers you run yourself."),
            client_certificate: s("Certificate"),
            client_certificate_help: s("For servers that require mutual TLS."),
            custom_headers: s("Custom Headers"),
            custom_headers_help: s(
                "Sent with every request, for example to get through a sign-in proxy.",
            ),
            add: s("Add"),
            choose_file: s("Choose File…"),
            connect: s("Connect"),
            sign_in: s("Sign In"),
            sign_in_subtitle: s("Use your Open WebUI account to sign in to the server below."),
            email: s("Email or Username"),
            password: s("Password"),
            or: s("or"),
            sso: s("Sign In with SSO"),
            ldap: s("Sign In with LDAP"),
            token: s("Token"),
            change: s("Change"),
            server_chip: s("Server: {name}. Change"),
            sync_now: s("Sync Now"),
            clear_search: s("Clear Search"),
            suggestions: s("Suggestions"),
            share_chat: s("Share Chat"),
            server_name_placeholder: s("Home Server"),
        }
    }
}

impl Global for Strings {}

/// The installed strings, or English.
pub trait ActiveStrings {
    fn strings(&self) -> &Strings;
}

impl ActiveStrings for App {
    fn strings(&self) -> &Strings {
        static ENGLISH: OnceLock<Strings> = OnceLock::new();
        self.try_global::<Strings>()
            .unwrap_or_else(|| ENGLISH.get_or_init(Strings::default))
    }
}

/// `template` with each `{key}` replaced by its value.
pub fn fill(template: &str, args: &[(&str, &str)]) -> String {
    let mut out = template.to_string();
    for (key, value) in args {
        out = out.replace(&format!("{{{key}}}"), value);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn templates_fill_their_placeholders() {
        let s = Strings::default();
        assert_eq!(
            fill(&s.position, &[("index", "1"), ("count", "3")]),
            "1 of 3"
        );
        assert_eq!(
            fill(&s.more_actions_for, &[("name", "Avery")]),
            "More Actions for Avery"
        );
        assert_eq!(fill("no {x}", &[]), "no {x}");
    }
}
