//! The components' own words ([`conduit_components::Strings`]), from the
//! app's catalogs. Installed with the locale, so a language change reaches
//! the sidebar, the composer, the approval cards and every accessibility
//! label the components draw.

use conduit_components::Strings;
use gpui_kit::SharedString;

use super::L10n;

/// A template's placeholder, kept for the components to fill.
const NAME: &str = "{name}";
const INDEX: &str = "{index}";
const COUNT: &str = "{count}";

pub fn component_strings(l: &L10n) -> Strings {
    let s = |v: String| SharedString::from(v);
    Strings {
        sidebar: s(l.desktop_sidebar()),
        hide_sidebar: s(l.desktop_menu_hide_sidebar()),
        search: s(l.desktop_search()),
        search_chats: s(l.desktop_search_chats()),
        settings: s(l.desktop_settings_title()),
        pinned: s(l.pinned()),
        folders: s(l.folders()),
        pin: s(l.desktop_pin_chat()),
        unpin: s(l.desktop_unpin_chat()),
        new_folder: s(l.desktop_new_folder()),
        palette: s(l.desktop_palette_label()),
        palette_placeholder: s(l.desktop_palette_placeholder()),
        palette_results: s(l.desktop_palette_results()),
        palette_navigate: s(l.desktop_palette_navigate()),
        palette_open: s(l.desktop_palette_open()),
        palette_open_in_background: s(l.desktop_palette_open_in_background()),
        composer: s(l.desktop_composer_label()),
        message_field: s(l.desktop_message_field()),
        attach_files: s(l.desktop_attach_files()),
        conversation: s(l.desktop_conversation()),
        chat_toolbar: s(l.desktop_chat_toolbar()),
        messages: s(l.desktop_messages()),
        new_chat: s(l.new_chat()),
        disclaimer: s(l.desktop_models_can_make_mistakes()),
        tool_result: s(l.desktop_tool_result()),
        output: s(l.output()),
        preview: s(l.preview()),
        temporary_chat: s(l.temporary_chat()),
        sources: s(l.desktop_sources()),
        previous_version: s(l.desktop_previous_answer()),
        next_version: s(l.desktop_next_answer()),
        copy: s(l.copy()),
        code_copied: s(l.desktop_code_copied()),
        code_block: s(l.desktop_code_block_label(NAME)),
        edit: s(l.edit()),
        regenerate: s(l.regenerate()),
        good_response: s(l.desktop_good_response()),
        bad_response: s(l.desktop_bad_response()),
        more: s(l.more()),
        dismiss: s(l.desktop_release_dismiss()),
        models: s(l.desktop_model_menu()),
        search_models: s(l.desktop_search_models()),
        all_models: s(l.desktop_all_models()),
        quick_ask: s(l.desktop_quick_ask_title()),
        ask: s(l.desktop_quick_ask_ask()),
        recent: s(l.recent()),
        recent_questions: s(l.desktop_recent_questions()),
        continue_in_conduit: s(l.desktop_quick_ask_continue()),
        close: s(l.desktop_close()),
        settings_sections: s(l.desktop_settings_sections()),
        palette_choice: s(l.desktop_palette()),
        accounts: s(l.accounts_title()),
        active: s(l.accounts_active()),
        switch: s(l.accounts_switch()),
        sign_in_again: s(l.desktop_sign_in_again()),
        session_expired: s(l.desktop_session_expired()),
        more_actions_for: s(l.desktop_more_actions_for(NAME)),
        allow: s(l.desktop_allow()),
        allow_once: s(l.desktop_allow_once()),
        allow_session: s(l.desktop_allow_for_session()),
        always_allow: s(l.desktop_always_allow()),
        deny: s(l.desktop_deny()),
        cancel: s(l.cancel()),
        submit: s(l.open_web_ui_prompt_submit()),
        position: s(l.desktop_position_of(INDEX, COUNT)),
        set_up_conduit: s(l.desktop_set_up_conduit()),
        welcome_title: s(l.desktop_choose_how_to_connect()),
        welcome_subtitle: s(l.backend_chooser_footer()),
        backend: s(l.desktop_backend()),
        open_webui: s(l.backend_chooser_open_web_ui_title()),
        open_webui_detail: s(l.backend_chooser_open_web_ui_subtitle()),
        direct: s(l.desktop_connect_directly()),
        direct_detail: s(l.backend_chooser_direct_subtitle()),
        hermes: s(l.desktop_hermes_agent()),
        hermes_detail: s(l.desktop_hermes_subtitle()),
        librechat: s(l.libre_chat_title()),
        librechat_detail: s(l.libre_chat_chooser_subtitle()),
        beta: s(l.libre_chat_beta_label()),
        self_hosted_section: s(l.desktop_self_hosted_services()),
        model_apis_section: s(l.backend_chooser_model_apis_section_title()),
        continue_label: s(l.continue_action()),
        back: s(l.back()),
        connect_title: s(l.desktop_connect_to_server()),
        connect_subtitle: s(l.desktop_sign_in_subtitle()),
        server_url: s(l.desktop_server_address()),
        server_url_hint: s(l.server_url_hint()),
        server_url_help: s(l.desktop_server_url_help()),
        display_name: s(l.desktop_server_name()),
        display_name_help: s(l.desktop_server_name_help()),
        advanced: s(l.desktop_advanced_settings()),
        self_signed: s(l.desktop_allow_unverified_certificate()),
        self_signed_help: s(l.desktop_self_signed_help()),
        client_certificate: s(l.mutual_tls_select_certificate()),
        client_certificate_help: s(l.desktop_client_certificate_help()),
        custom_headers: s(l.desktop_custom_headers()),
        custom_headers_help: s(l.desktop_custom_headers_help()),
        add: s(l.desktop_add()),
        choose_file: s(l.desktop_choose_file()),
        connect: s(l.desktop_connect()),
        sign_in: s(l.desktop_sign_in()),
        sign_in_subtitle: s(l.desktop_sign_in_subtitle()),
        email: s(l.desktop_email_or_username()),
        password: s(l.password()),
        or: s(l.desktop_or()),
        sso: s(l.desktop_sign_in_with_sso()),
        ldap: s(l.desktop_sign_in_with_ldap()),
        token: s(l.jwt()),
        change: s(l.desktop_change_server()),
        server_chip: s(l.desktop_server_chip(NAME)),
        sync_now: s(l.desktop_sync_now()),
        clear_search: s(l.desktop_clear_search()),
        suggestions: s(l.desktop_suggestions_heading()),
        share_chat: s(l.desktop_share_chat()),
        server_name_placeholder: s(l.desktop_server_name_placeholder()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::l10n::LOCALES;

    #[test]
    fn every_locale_fills_every_component_string() {
        for locale in LOCALES {
            let s = component_strings(&L10n::new(locale));
            let english = Strings::default();
            // Templates keep their placeholders for the components.
            assert!(s.more_actions_for.contains(NAME), "{locale}");
            assert!(s.server_chip.contains(NAME), "{locale}");
            assert!(s.code_block.contains(NAME), "{locale}");
            assert!(
                s.position.contains(INDEX) && s.position.contains(COUNT),
                "{locale}"
            );
            assert!(!s.search.is_empty() && !s.sidebar.is_empty(), "{locale}");
            if *locale != "en" {
                assert_ne!(
                    s.welcome_title, english.welcome_title,
                    "{locale} chooser title"
                );
                assert_ne!(s.hide_sidebar, english.hide_sidebar, "{locale}");
            }
        }
    }
}
