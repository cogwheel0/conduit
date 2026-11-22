//! `shell.openUrl`: the daemon asks a window to open a page in the system
//! browser (Hermes PKCE sign-in, MCP OAuth). Only http(s) URLs with a host
//! are opened; anything else (file:, javascript:, custom schemes) is
//! refused, because the payload comes over the wire.

/// An end-to-end pass follows `shell.openUrl` pages itself (as a user's
/// browser would) instead of opening the system browser: the URL is only
/// recorded ([`crate::stores::connection::ConnectionStore::opened_urls`]).
#[derive(Clone, Copy, Debug, Default)]
pub struct Intercept(pub bool);

impl gpui_kit::Global for Intercept {}

/// The URL to open, if it is one the app should open.
pub fn validate(raw: &str) -> Option<url::Url> {
    let url = url::Url::parse(raw.trim()).ok()?;
    if !matches!(url.scheme(), "http" | "https") {
        return None;
    }
    url.host_str().filter(|h| !h.is_empty())?;
    Some(url)
}

/// The URL in a `shell.openUrl` payload (`{url}`), validated.
pub fn from_payload(payload: &serde_json::Value) -> Option<url::Url> {
    validate(payload.get("url")?.as_str()?)
}

/// Whether an app on this computer opens `url`'s scheme (an `otpauth://`
/// link needs one that adds verification codes, as Passwords does), so the
/// window can say so instead of opening nothing. On Windows, the scheme's
/// registered open command; on Linux, the desktop's default
/// `x-scheme-handler`, and yes when that can't be asked (no xdg-utils: the
/// portal may still open it).
pub fn has_handler(url: &str) -> bool {
    #[cfg(target_os = "macos")]
    {
        use objc2::runtime::AnyObject;
        use objc2::{class, msg_send};
        use objc2_foundation::{NSString, NSURL};
        let Some(url) = NSURL::URLWithString(&NSString::from_str(url)) else {
            return false;
        };
        // SAFETY: a read-only query of the shared workspace.
        unsafe {
            let workspace: *mut AnyObject = msg_send![class!(NSWorkspace), sharedWorkspace];
            let app: *mut AnyObject = msg_send![workspace, URLForApplicationToOpenURL: &*url];
            !app.is_null()
        }
    }
    #[cfg(windows)]
    {
        use windows::Win32::UI::Shell::{
            ASSOCF_INIT_IGNOREUNKNOWN, ASSOCSTR_COMMAND, AssocQueryStringW,
        };
        use windows::core::{PCWSTR, w};
        let Some(scheme) = url::Url::parse(url).ok().map(|u| u.scheme().to_string()) else {
            return false;
        };
        let wide: Vec<u16> = scheme.encode_utf16().chain(Some(0)).collect();
        let mut len = 0u32;
        // SAFETY: `wide` is NUL-terminated and outlives the call; with no
        // output buffer the call only writes the command's length to `len`.
        unsafe {
            AssocQueryStringW(
                ASSOCF_INIT_IGNOREUNKNOWN,
                ASSOCSTR_COMMAND,
                PCWSTR::from_raw(wide.as_ptr()),
                w!("open"),
                None,
                &mut len,
            )
        }
        .is_ok()
            && len > 1
    }
    #[cfg(target_os = "linux")]
    {
        let Some(scheme) = url::Url::parse(url).ok().map(|u| u.scheme().to_string()) else {
            return false;
        };
        match std::process::Command::new("xdg-mime")
            .args(["query", "default", &format!("x-scheme-handler/{scheme}")])
            .output()
        {
            Ok(out) if out.status.success() => !out.stdout.trim_ascii().is_empty(),
            _ => true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn opens_http_and_https_only() {
        assert!(validate("https://auth.example.org/authorize?state=x").is_some());
        assert!(validate("http://127.0.0.1:8642/callback").is_some());
        assert!(validate("HTTPS://Example.org").is_some());
        for bad in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "conduit://chat/1",
            "x-apple.systempreferences:com.apple.preference",
            "https://",
            "not a url",
            "",
        ] {
            assert!(validate(bad).is_none(), "{bad}");
        }
    }

    #[test]
    fn reads_the_payload() {
        assert!(from_payload(&json!({"url": "https://example.org"})).is_some());
        assert!(from_payload(&json!({"url": 5})).is_none());
        assert!(from_payload(&json!({})).is_none());
    }
}
