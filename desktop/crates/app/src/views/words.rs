//! How the window words what the daemon reports: error codes (the daemon
//! sends codes, never prose) and account-change notices.

use conduit_daemon::RpcError;
use conduit_protocol::{ErrorCode, NoticeLevel, ServerReachability, ServerStatus};

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
