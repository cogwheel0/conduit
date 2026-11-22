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
/// window can say so instead of opening nothing; `None` when that can't be
/// told (in time). On Windows, the scheme's registered open command, per
/// user or for the machine; on Linux, the desktop's default
/// `x-scheme-handler` from `xdg-mime`, which may be slow: it is given
/// [`XDG_MIME_WAIT`]. Blocking: [`ask_handler`] runs it off the UI thread.
pub fn has_handler(url: &str) -> Option<bool> {
    #[cfg(target_os = "macos")]
    {
        use objc2::runtime::AnyObject;
        use objc2::{class, msg_send};
        use objc2_foundation::{NSString, NSURL};
        let url = NSURL::URLWithString(&NSString::from_str(url))?;
        // SAFETY: a read-only query of the shared workspace.
        unsafe {
            let workspace: *mut AnyObject = msg_send![class!(NSWorkspace), sharedWorkspace];
            let app: *mut AnyObject = msg_send![workspace, URLForApplicationToOpenURL: &*url];
            Some(!app.is_null())
        }
    }
    #[cfg(windows)]
    {
        use windows::Win32::UI::Shell::{
            ASSOCF_INIT_IGNOREUNKNOWN, ASSOCF_IS_PROTOCOL, ASSOCSTR_COMMAND, AssocQueryStringW,
        };
        use windows::core::{PCWSTR, w};
        let scheme = url::Url::parse(url).ok()?.scheme().to_string();
        let wide: Vec<u16> = scheme.encode_utf16().chain(Some(0)).collect();
        let mut len = 0u32;
        // SAFETY: `wide` is NUL-terminated and outlives the call; with no
        // output buffer the call only writes the command's length to `len`.
        let found = unsafe {
            AssocQueryStringW(
                ASSOCF_IS_PROTOCOL | ASSOCF_INIT_IGNOREUNKNOWN,
                ASSOCSTR_COMMAND,
                PCWSTR::from_raw(wide.as_ptr()),
                w!("open"),
                None,
                &mut len,
            )
        };
        Some(found.is_ok() && len > 1)
    }
    #[cfg(target_os = "linux")]
    {
        let scheme = url::Url::parse(url).ok()?.scheme().to_string();
        let out = run_bounded(
            std::process::Command::new("xdg-mime").args([
                "query",
                "default",
                &format!("x-scheme-handler/{scheme}"),
            ]),
            XDG_MIME_WAIT,
        )?;
        out.status
            .success()
            .then(|| !out.stdout.trim_ascii().is_empty())
    }
}

/// How long `xdg-mime` may take before the answer counts as unknown.
#[cfg(target_os = "linux")]
pub const XDG_MIME_WAIT: std::time::Duration = std::time::Duration::from_secs(2);

/// `command`'s output, or `None` when it can't start or doesn't end within
/// `wait` (it is killed then).
#[cfg(target_os = "linux")]
fn run_bounded(
    command: &mut std::process::Command,
    wait: std::time::Duration,
) -> Option<std::process::Output> {
    use std::process::Stdio;
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let deadline = std::time::Instant::now() + wait;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return child.wait_with_output().ok(),
            Ok(None) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
}

/// [`has_handler`] off the UI thread on Windows and Linux (a desktop's
/// lookup can be slow); the Mac's NSWorkspace answers at once, on it.
pub fn ask_handler(url: String, cx: &gpui_kit::App) -> gpui_kit::Task<Option<bool>> {
    if cfg!(target_os = "macos") {
        gpui_kit::Task::ready(has_handler(&url))
    } else {
        cx.background_executor()
            .spawn(async move { has_handler(&url) })
    }
}

/// Whether to open the link, given what the lookup found: always, unless
/// it found that no app opens the scheme. A lookup that couldn't tell in
/// time opens it anyway (the desktop may still find an app).
pub fn opens(answer: Option<bool>) -> bool {
    answer != Some(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_link_opens_unless_no_app_was_found() {
        assert!(opens(Some(true)));
        assert!(!opens(Some(false)), "no app: say so instead");
        assert!(opens(None), "a lookup that ran out of time opens it anyway");
    }

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
