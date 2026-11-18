//! How the window words what the daemon reports: error codes (the daemon
//! sends codes, never prose) and account-change notices.

use conduit_daemon::RpcError;
use conduit_protocol::{
    ErrorCode, NoticeLevel, ServerAddressCheckResult, ServerAddressProblemCode, ServerReachability,
    ServerStatus,
};

use crate::l10n::L10n;
use crate::stores::accounts::AccountNotice;

/// A failed connect or server check.
pub fn connect_error(error: &RpcError, l10n: &L10n) -> String {
    match &error.code {
        ErrorCode::InvalidParams => l10n.desktop_invalid_server_address(),
        ErrorCode::ConnectionFailed | ErrorCode::Offline | ErrorCode::ServerError => {
            l10n.desktop_couldnt_reach_server()
        }
        ErrorCode::Timeout => l10n.connection_timed_out(),
        ErrorCode::TlsUntrusted => l10n.desktop_certificate_untrusted(),
        _ => l10n.could_not_connect_generic(),
    }
}

/// Whether a failed connect was the credentials' fault (a refused key),
/// not the address's: the form puts focus on the key then.
pub fn is_unauthorized(error: &RpcError) -> bool {
    matches!(
        error.code,
        ErrorCode::Unauthorized | ErrorCode::Unauthenticated | ErrorCode::InvalidCredentials
    )
}

/// Why a server the user entered cannot be used, if it cannot.
pub fn server_problem(status: &ServerStatus, l10n: &L10n) -> Option<String> {
    match status.reachability {
        ServerReachability::Reachable if !status.is_version_supported => {
            Some(l10n.server_incompatible_connect_blocked(&status.max_supported_version))
        }
        ServerReachability::Reachable => None,
        ServerReachability::NotOpenWebUi => Some(l10n.desktop_not_open_web_ui()),
        ServerReachability::Unreachable => Some(match status.error_code.as_deref() {
            Some("net.tlsUntrusted") => l10n.desktop_certificate_untrusted(),
            Some("rpc.timeout") => l10n.connection_timed_out(),
            _ => l10n.desktop_couldnt_reach_server(),
        }),
        ServerReachability::Unknown => Some(l10n.could_not_connect_generic()),
    }
}

/// A failed sign-in (or second step), from the call's error or the
/// snapshot's code, in the phone's words where it has specific ones.
pub fn sign_in_error(code: &str, l10n: &L10n) -> String {
    match code {
        "auth.invalidCredentials" => l10n.desktop_wrong_credentials(),
        "auth.sessionExpired" => l10n.desktop_sign_in_again_body(),
        "auth.pendingApproval" => l10n.sign_in_account_pending_approval(),
        "auth.apiKeyNotSupported" => l10n.api_key_not_supported(),
        "auth.apiKeyNoLongerSupported" => l10n.api_key_no_longer_supported(),
        "auth.tokenTooShort" => l10n.token_too_short(),
        "auth.ldapNotEnabled" | "capability.unsupported" => l10n.desktop_ldap_not_enabled(),
        "auth.twoStepRequired" => l10n.sign_in_two_step_verification_required(),
        "auth.twoStepInvalidCode" => l10n.two_step_invalid_code(),
        "auth.twoStepExpired" => l10n.two_step_expired(),
        "auth.twoStepTooManyAttempts" => l10n.two_step_too_many_attempts(),
        "auth.twoStepFailed" => l10n.two_step_failed(),
        "net.serverRedirect" => l10n.server_redirecting_https(),
        "net.connectionFailed" | "net.offline" | "net.serverError" => {
            l10n.desktop_couldnt_reach_server()
        }
        "net.tlsUntrusted" => l10n.desktop_certificate_untrusted(),
        "rpc.timeout" => l10n.connection_timed_out(),
        _ => l10n.desktop_sign_in_failed(),
    }
}

/// An account notice as a toast, or `None` for one that needs no toast.
pub fn account_notice(notice: &AccountNotice, l10n: &L10n) -> Option<(NoticeLevel, String)> {
    use AccountNotice as N;
    Some(match notice {
        N::AddedNeedsSignIn => (
            NoticeLevel::Info,
            l10n.desktop_account_added_needs_sign_in(),
        ),
        N::SwitchedTo { name } => (NoticeLevel::Success, l10n.desktop_account_switched_to(name)),
        N::SwitchedNeedsSignIn { name } => (
            NoticeLevel::Warning,
            l10n.desktop_account_switched_needs_sign_in(name),
        ),
        N::AlreadyActive { name } => (NoticeLevel::Info, l10n.desktop_account_already_active(name)),
        N::SignedOut { name, next: None } => {
            (NoticeLevel::Success, l10n.desktop_account_signed_out(name))
        }
        N::SignedOut {
            name,
            next: Some(next),
        } => (
            NoticeLevel::Success,
            l10n.desktop_account_signed_out_next(name, next),
        ),
        N::SignedOutNextNeedsSignIn { name, next } => (
            NoticeLevel::Warning,
            l10n.desktop_account_signed_out_next_needs_sign_in(name, next),
        ),
        N::Added | N::AddCancelled { .. } => return None,
        N::NothingToCancel => (NoticeLevel::Info, l10n.desktop_account_nothing_to_cancel()),
        N::UnknownOutcome => (NoticeLevel::Warning, l10n.desktop_account_unknown_outcome()),
        N::Failed { error } => (
            NoticeLevel::Error,
            match error.code {
                ErrorCode::ConnectionFailed | ErrorCode::Offline => {
                    l10n.desktop_couldnt_reach_server()
                }
                _ => l10n.desktop_account_change_failed(),
            },
        ),
    })
}

/// What the window says for an address `problem` of a saved server (the
/// core's `ServerAddressProblem`): the phone's words for each
/// (`server_address_wording.dart`). `header` is the header a reserved or
/// repeated name is about.
pub fn server_address_problem(
    problem: ServerAddressProblemCode,
    header: Option<&str>,
    l10n: &L10n,
) -> String {
    use ServerAddressProblemCode as P;
    let header = header.unwrap_or_default();
    match problem {
        P::AddressEmpty => l10n.server_url_empty(),
        P::InvalidAddress => l10n.invalid_url_format(),
        P::UnsupportedScheme => l10n.only_http_https(),
        P::MissingHost => l10n.server_address_required(),
        P::PortOutOfRange => l10n.port_range(),
        P::InvalidIpAddress => l10n.invalid_ip_format(),
        P::HeaderFieldMissing => l10n.auth_field_required(),
        P::HeaderNameTooLong => l10n.header_name_too_long(),
        P::HeaderNameInvalidCharacters => l10n.header_name_invalid_chars(),
        P::HeaderNameReserved => l10n.header_name_reserved(header),
        P::HeaderValueTooLong => l10n.header_value_too_long(),
        P::HeaderValueInvalidCharacters => l10n.header_value_invalid_chars(),
        P::HeaderValueUnsafe => l10n.header_value_unsafe(),
        P::HeaderAlreadyAdded => l10n.header_already_exists(header),
        P::TooManyHeaders => l10n.max_headers_reached_detail(),
        P::MutualTlsIncomplete => l10n.mutual_tls_missing_credential_pair(),
        P::CertificatePemRequired => l10n.mutual_tls_certificate_pem_required(),
        P::PrivateKeyPemRequired => l10n.mutual_tls_private_key_pem_required(),
        P::PemFileUnreadable => l10n.mutual_tls_file_read_failed(),
        P::MutualTlsRefused => l10n.mutual_tls_handshake_failed(),
        P::MutualTlsConnectionClosed => l10n.mutual_tls_connection_closed(),
        P::Unreachable => l10n.could_not_connect_generic(),
        P::NotOpenWebUi => l10n.server_not_open_web_ui(),
        P::ServerUnavailable => l10n.server_error_unavailable(),
        P::ServerError => l10n.server_error_generic(),
        P::CertificateRejected => l10n.security_certificate_error(),
        P::DifferentServer => l10n.accounts_address_different_server(),
        P::NeedsSignIn => l10n.accounts_address_needs_sign_in(),
        P::ProxySessionRevoked => l10n.proxy_auth_failed(),
        P::ProxyVerificationFailed => l10n.proxy_server_verification_failed(),
        P::ServerMissing | P::Unknown => l10n.error_message(),
    }
}

/// What the window says for a refused address check: its problem's words,
/// else the error's own (sanitized) text.
pub fn server_address_refusal(found: &ServerAddressCheckResult, l10n: &L10n) -> String {
    match (&found.problem, &found.error_text) {
        (Some(problem), _) => server_address_problem(*problem, found.header_name.as_deref(), l10n),
        (None, Some(text)) => text.clone(),
        (None, None) => l10n.error_message(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use conduit_daemon::protocol::error;

    #[test]
    fn every_notice_but_a_cancelled_addition_is_worded() {
        let l10n = L10n::new("en");
        let notices = [
            AccountNotice::AddedNeedsSignIn,
            AccountNotice::SwitchedTo { name: "A".into() },
            AccountNotice::SwitchedNeedsSignIn { name: "A".into() },
            AccountNotice::AlreadyActive { name: "A".into() },
            AccountNotice::SignedOut {
                name: "A".into(),
                next: None,
            },
            AccountNotice::SignedOut {
                name: "A".into(),
                next: Some("B".into()),
            },
            AccountNotice::SignedOutNextNeedsSignIn {
                name: "A".into(),
                next: "B".into(),
            },
            AccountNotice::NothingToCancel,
            AccountNotice::UnknownOutcome,
            AccountNotice::Failed {
                error: error("rpc.internal", "x"),
            },
        ];
        for n in &notices {
            let (_, text) = account_notice(n, &l10n).expect("worded");
            assert!(!text.is_empty() && !text.contains('{'), "{n:?}: {text}");
        }
        assert_eq!(
            account_notice(&AccountNotice::AddCancelled { name: None }, &l10n),
            None
        );
        assert_eq!(account_notice(&AccountNotice::Added, &l10n), None);
        let (_, t) = account_notice(
            &AccountNotice::SignedOut {
                name: "Avery".into(),
                next: Some("Blake".into()),
            },
            &l10n,
        )
        .unwrap();
        assert!(t.contains("Avery") && t.contains("Blake"), "{t}");
    }

    #[test]
    fn every_address_problem_is_worded_as_on_the_phone() {
        use ServerAddressProblemCode as P;
        let l10n = L10n::new("en");
        let all = [
            P::AddressEmpty,
            P::InvalidAddress,
            P::UnsupportedScheme,
            P::MissingHost,
            P::PortOutOfRange,
            P::InvalidIpAddress,
            P::HeaderFieldMissing,
            P::HeaderNameTooLong,
            P::HeaderNameInvalidCharacters,
            P::HeaderNameReserved,
            P::HeaderValueTooLong,
            P::HeaderValueInvalidCharacters,
            P::HeaderValueUnsafe,
            P::HeaderAlreadyAdded,
            P::TooManyHeaders,
            P::MutualTlsIncomplete,
            P::CertificatePemRequired,
            P::PrivateKeyPemRequired,
            P::PemFileUnreadable,
            P::MutualTlsRefused,
            P::MutualTlsConnectionClosed,
            P::Unreachable,
            P::NotOpenWebUi,
            P::ServerUnavailable,
            P::ServerError,
            P::CertificateRejected,
            P::ServerMissing,
            P::DifferentServer,
            P::NeedsSignIn,
            P::ProxySessionRevoked,
            P::ProxyVerificationFailed,
        ];
        for p in all {
            let text = server_address_problem(p, Some("X-Lab"), &l10n);
            assert!(!text.is_empty() && !text.contains('{'), "{p:?}: {text}");
        }
        assert!(
            server_address_problem(P::HeaderNameReserved, Some("Authorization"), &l10n)
                .contains("Authorization")
        );
        assert_eq!(
            server_address_problem(P::DifferentServer, None, &l10n),
            "This address reaches a different server, or a different account on it."
        );
        // An error the server put in words keeps them.
        let found = ServerAddressCheckResult {
            outcome: conduit_protocol::ServerAddressCheckOutcome::Unusable,
            check_id: None,
            url: None,
            problem: None,
            error_text: Some("TLS alert 42".into()),
            header_name: None,
        };
        assert_eq!(server_address_refusal(&found, &l10n), "TLS alert 42");
    }

    #[test]
    fn sign_in_codes_map_to_specific_wording() {
        let l10n = L10n::new("en");
        assert_eq!(
            sign_in_error("auth.invalidCredentials", &l10n),
            "The email or password didn't match. Try again."
        );
        assert_eq!(
            connect_error(&error("rpc.invalidParams", "x"), &l10n),
            "Enter an address that starts with http:// or https://."
        );
        assert_eq!(sign_in_error("weird", &l10n), l10n.desktop_sign_in_failed());
        assert_eq!(
            sign_in_error("auth.signInFailed", &l10n),
            l10n.desktop_sign_in_failed()
        );
        // The phone's words, never the generic failure, where it has them.
        for code in [
            "auth.pendingApproval",
            "auth.apiKeyNotSupported",
            "auth.apiKeyNoLongerSupported",
            "auth.tokenTooShort",
            "auth.ldapNotEnabled",
            "auth.twoStepRequired",
            "auth.twoStepInvalidCode",
            "auth.twoStepExpired",
            "auth.twoStepTooManyAttempts",
            "auth.twoStepFailed",
            "net.serverRedirect",
        ] {
            let text = sign_in_error(code, &l10n);
            assert_ne!(text, l10n.desktop_sign_in_failed(), "{code}");
            assert!(!text.is_empty() && !text.contains('{'), "{code}: {text}");
        }
        assert_eq!(
            sign_in_error("auth.pendingApproval", &l10n),
            "Your account is waiting for an administrator to approve it. Try again once it's approved."
        );
        assert_eq!(
            sign_in_error("auth.apiKeyNotSupported", &l10n),
            l10n.api_key_not_supported()
        );
    }
}
