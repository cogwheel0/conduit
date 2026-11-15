//! `shell.openUrl`: the daemon asks a window to open a page in the system
//! browser (Hermes PKCE sign-in, MCP OAuth). Only http(s) URLs with a host
//! are opened; anything else (file:, javascript:, custom schemes) is
//! refused, because the payload comes over the wire.

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
