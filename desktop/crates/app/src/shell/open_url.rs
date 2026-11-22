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
            ASSOCF_INIT_IGNOREUNKNOWN, ASSOCF_IS_PROTOCOL, ASSOCSTR, ASSOCSTR_COMMAND,
            ASSOCSTR_DELEGATEEXECUTE, AssocQueryStringW,
        };
        use windows::core::{PCWSTR, w};
        let scheme = url::Url::parse(url).ok()?.scheme().to_string();
        let wide: Vec<u16> = scheme.encode_utf16().chain(Some(0)).collect();
        // The length of the `open` verb's `what`, NUL included, if it has one.
        let lookup = |what: ASSOCSTR| {
            let mut len = 0u32;
            // SAFETY: `wide` is NUL-terminated and outlives the call; with no
            // output buffer the call only writes the length to `len`.
            let found = unsafe {
                AssocQueryStringW(
                    ASSOCF_IS_PROTOCOL | ASSOCF_INIT_IGNOREUNKNOWN,
                    what,
                    PCWSTR::from_raw(wide.as_ptr()),
                    w!("open"),
                    None,
                    &mut len,
                )
            };
            found.is_ok().then_some(len)
        };
        Some(opens_by_verb(lookup(ASSOCSTR_COMMAND), || {
            lookup(ASSOCSTR_DELEGATEEXECUTE)
        }))
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

/// Whether Windows has an app for a scheme's `open` verb, from the lengths
/// (NUL included) of its command and, only when that is missing or empty,
/// its `DelegateExecute` class: a handler may register either.
#[cfg_attr(not(windows), cfg(test))]
fn opens_by_verb(command: Option<u32>, delegate_execute: impl FnOnce() -> Option<u32>) -> bool {
    let set = |len: Option<u32>| len.is_some_and(|len| len > 1);
    set(command) || set(delegate_execute())
}

/// How long `xdg-mime` may take before the answer counts as unknown.
#[cfg(target_os = "linux")]
pub const XDG_MIME_WAIT: std::time::Duration = std::time::Duration::from_secs(2);

/// `command`'s exit status and stdout, or `None` when it can't start or
/// doesn't end, stdout included, within `wait`: then it is killed and
/// reaped. Stdout is read under the same deadline ([`read_to_end_by`]),
/// since a helper the command started can keep the pipe open after it
/// exits.
#[cfg(target_os = "linux")]
fn run_bounded(
    command: &mut std::process::Command,
    wait: std::time::Duration,
) -> Option<std::process::Output> {
    use std::process::Stdio;
    let deadline = std::time::Instant::now() + wait;
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let give_up = |child: &mut std::process::Child| {
        let _ = child.kill();
        let _ = child.wait();
        None
    };
    let stdout = child.stdout.take()?;
    let Some(stdout) = read_to_end_by(stdout, deadline) else {
        return give_up(&mut child);
    };
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            _ => return give_up(&mut child),
        }
    };
    Some(std::process::Output {
        status,
        stdout,
        stderr: Vec::new(),
    })
}

/// `pipe`'s bytes to its end, or `None` once `deadline` passes first. It is
/// read without blocking, only when `poll` says there is something, so
/// nothing waits past the deadline, and the pipe is closed when this
/// returns either way: no reader is left holding it for a helper that keeps
/// its other end open.
#[cfg(any(target_os = "linux", all(test, unix)))]
fn read_to_end_by(
    mut pipe: impl std::io::Read + std::os::fd::AsFd,
    deadline: std::time::Instant,
) -> Option<Vec<u8>> {
    use std::io::ErrorKind;
    use std::os::fd::AsRawFd as _;
    let fd = pipe.as_fd().as_raw_fd();
    // SAFETY: `fd` is open for as long as `pipe` is; these only read and set
    // its status flags.
    let nonblocking = unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        flags >= 0 && libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) >= 0
    };
    if !nonblocking {
        return None;
    }
    let mut out = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        if left.is_zero() {
            return None;
        }
        let mut ready = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        let millis = left.as_millis().clamp(1, i32::MAX as u128) as i32;
        // SAFETY: one valid pollfd, for the call.
        if unsafe { libc::poll(&mut ready, 1, millis) } < 0
            && std::io::Error::last_os_error().kind() != ErrorKind::Interrupted
        {
            return None;
        }
        loop {
            match pipe.read(&mut chunk) {
                Ok(0) => return Some(out),
                Ok(n) => out.extend_from_slice(&chunk[..n]),
                Err(e) if e.kind() == ErrorKind::Interrupted => {}
                Err(e) if e.kind() == ErrorKind::WouldBlock => break,
                Err(_) => return None,
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

    /// A scheme's `open` verb is handled by a command or, failing one, a
    /// `DelegateExecute` class; only with neither is there no app.
    #[test]
    fn a_delegate_execute_handler_counts_as_an_app() {
        let never = || -> Option<u32> { panic!("a command is enough") };
        assert!(opens_by_verb(Some(40), never));
        assert!(opens_by_verb(None, || Some(39)));
        assert!(opens_by_verb(Some(1), || Some(39)), "an empty command");
        assert!(!opens_by_verb(None, || None));
        assert!(!opens_by_verb(Some(1), || Some(1)));
    }

    /// A helper keeps stdout open past the deadline: the read gives up then,
    /// and lets the pipe go (a write finds nobody reading), leaving nothing
    /// blocked on it.
    #[cfg(unix)]
    #[test]
    fn a_read_past_its_deadline_lets_the_pipe_go() {
        use std::io::Write as _;
        use std::time::{Duration, Instant};
        let (reader, mut writer) = std::io::pipe().unwrap();
        writer.write_all(b"first").unwrap();
        let started = Instant::now();
        assert_eq!(
            read_to_end_by(reader, started + Duration::from_millis(50)),
            None
        );
        assert!(started.elapsed() < Duration::from_secs(5));
        let closed = writer.write_all(b"more").unwrap_err();
        assert_eq!(closed.kind(), std::io::ErrorKind::BrokenPipe);

        let (reader, mut writer) = std::io::pipe().unwrap();
        writer
            .write_all(b"org.example.Authenticator.desktop\n")
            .unwrap();
        drop(writer);
        assert_eq!(
            read_to_end_by(reader, Instant::now() + Duration::from_secs(5)).as_deref(),
            Some(&b"org.example.Authenticator.desktop\n"[..])
        );
    }

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
