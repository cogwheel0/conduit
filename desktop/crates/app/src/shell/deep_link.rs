//! `conduit://` links, and what the window is asked to open.
//!
//! A link comes from anywhere on the system (a web page, another app, a notification), so it
//! is parsed into one of a few shapes here, and only those shapes reach the
//! app. Nothing in a link becomes a path or a method call unchecked.
//!
//! Files the system hands the app ("Open with Conduit", a drop on the Dock
//! icon) arrive through the same `on_open_urls` call as `file://` URLs;
//! [`classify`] splits them from links.

use std::path::PathBuf;

/// The scheme the app registers (`CFBundleURLTypes`). The iOS app registers
/// it too; the user chose to keep the same links on both.
pub const SCHEME: &str = "conduit";

/// The longest text a `conduit://new?q=` link prefills.
pub const MAX_TEXT: usize = 8000;

/// What a link (or "Open with") asks the app to open.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OpenRequest {
    /// `conduit://chat/<id>`.
    Chat { id: String },
    /// `conduit://new?q=<text>`, or files from "Open with": a new chat with
    /// the composer prefilled (never sent).
    NewChat {
        text: Option<String>,
        files: Vec<PathBuf>,
    },
    /// `conduit://channel/<id>`: after v1.
    Channel { id: String },
    /// `conduit://note/<id>`: after v1.
    Note { id: String },
    /// `conduit://settings[/<tab>]`.
    Settings { tab: Option<String> },
    /// Quick Ask's Open in Conduit: a new chat with the draft kept under
    /// `id` (its text and uploaded files), which only this request takes.
    QuickAskDraft { id: u64 },
    /// `conduit://quick-ask`: the Quick Ask panel (the widget's Ask
    /// Conduit); Shortcuts' Show Quick Ask may bring a question's `text`,
    /// which starts a new question with it in the message box.
    QuickAsk { text: Option<String> },
    /// `conduit://call`, or mobile's `conduit://mic`: a voice call in a new
    /// chat (the widget's Voice Call).
    VoiceCall,
    /// `conduit://share/<id>`: what the Share extension staged in the
    /// inbox ([`super::share_inbox`]), as a new chat.
    Share { id: String },
    /// `conduit://clipboard` (the widget's Clipboard, the phone's too): a
    /// new chat with the copied text, read when the main window can show
    /// it (only text: any page or app can open the link).
    Clipboard,
    /// A new chat with more than a link can carry (Shortcuts' Send Link and
    /// Send Image): never from a link.
    Compose(Box<Compose>),
}

/// What a new chat starts with: never sent, the user reads it first.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Compose {
    /// The message box's text.
    pub text: Option<String>,
    /// Files attached through the composer's upload path.
    pub files: Vec<PathBuf>,
    /// Pictures attached as a paste attaches them.
    pub images: Vec<gpui_kit::Image>,
    /// A web page's text or a video's transcript (Web Page's attachment).
    pub context: Vec<conduit_protocol::ContextAttachmentDto>,
    /// The account scope the server read the content under, for content
    /// that is that scope's (Send Link's page): the new chat is written only
    /// while that same scope is in charge. None: the user's own words and
    /// files, for whichever account is in charge.
    pub owner: Option<ReadUnder>,
}

/// The account scope content was read under: [`AccountsStore::scope_key`]
/// then, `None` when no account was in charge (Direct only, Hermes only).
/// "No account" is a scope like any other: only a change (one account to
/// another, an account to none, none to an account) refuses.
///
/// [`AccountsStore::scope_key`]: crate::stores::accounts::AccountsStore::scope_key
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReadUnder(pub Option<String>);

// The protocol's DTOs derive `PartialEq` only; equality here is plain
// field equality (no floats).
impl Eq for Compose {}

impl OpenRequest {
    /// Whether the request needs the main frame (signed in, routed to
    /// Main). Settings opens in its own window whatever is routed, and
    /// Quick Ask in its panel (which says when setup isn't finished).
    pub fn needs_main(&self) -> bool {
        !matches!(self, Self::Settings { .. } | Self::QuickAsk { .. })
    }
}

/// A chat, channel or note id a link may carry: what the daemon and Open
/// WebUI hand out (uuids, `local:` ids), and nothing that could climb out
/// of a path.
pub fn valid_id(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b':' | b'_' | b'.' | b'-'))
}

fn valid_tab(tab: &str) -> bool {
    (1..=32).contains(&tab.len()) && tab.bytes().all(|b| b.is_ascii_lowercase())
}

/// What `url` asks for, or `None` when it is not a link this app opens.
pub fn parse(url: &str) -> Option<OpenRequest> {
    // A URL parser would resolve dot segments into some other, valid-looking
    // link; one that needs them is not one to open.
    let before_query = url.split(['?', '#']).next().unwrap_or_default();
    let is_dot = |segment: &str| {
        // `%2e` is a dot to the URL parser too (`.%2E`, `%2e%2e`).
        let decoded = segment.to_ascii_lowercase().replace("%2e", ".");
        decoded == "." || decoded == ".."
    };
    if before_query.split('/').any(is_dot) {
        return None;
    }
    let parsed = url::Url::parse(url).ok()?;
    if parsed.scheme() != SCHEME {
        return None;
    }
    // `conduit://chat/abc` puts `chat` in the host; `conduit:chat/abc` in
    // the path. Both are seen in the wild.
    let mut segments = vec![];
    for raw in parsed
        .host_str()
        .into_iter()
        .chain(parsed.path().split('/'))
    {
        if raw.is_empty() {
            continue;
        }
        let decoded = percent_decode(raw)?;
        if !decoded.is_empty() {
            segments.push(decoded);
        }
    }
    let mut parts = segments.into_iter();
    let kind = parts.next()?;
    let id = parts.next();
    if parts.next().is_some() {
        return None;
    }
    match kind.as_str() {
        "chat" => id
            .filter(|i| valid_id(i))
            .map(|id| OpenRequest::Chat { id }),
        // `new_chat` and `mic` are the phone widget's links
        // (`conduit://<action>?homeWidget=true`), so the same ones work here.
        "new" | "new_chat" => {
            if id.is_some() {
                return None;
            }
            let query = |key: &str| {
                parsed
                    .query_pairs()
                    .find(|(k, _)| k == key)
                    .map(|(_, v)| v.into_owned())
            };
            let text = query("q")
                .or_else(|| query("prompt"))
                .filter(|t| !t.trim().is_empty())
                .map(|t| t.chars().take(MAX_TEXT).collect());
            Some(OpenRequest::NewChat {
                text,
                files: vec![],
            })
        }
        "channel" | "channels" => id
            .filter(|i| valid_id(i))
            .map(|id| OpenRequest::Channel { id }),
        "note" | "notes" => id
            .filter(|i| valid_id(i))
            .map(|id| OpenRequest::Note { id }),
        "quick-ask" => id.is_none().then_some(OpenRequest::QuickAsk { text: None }),
        "clipboard" => id.is_none().then_some(OpenRequest::Clipboard),
        // The phone widget's Camera and Photos: the Mac has no picker a
        // link can open (Continuity Camera is in the composer's + menu), so
        // a new chat, as the phone does with an action it doesn't know.
        "camera" | "photos" => id.is_none().then_some(OpenRequest::NewChat {
            text: None,
            files: vec![],
        }),
        "call" | "mic" => id.is_none().then_some(OpenRequest::VoiceCall),
        "share" => id
            .filter(|i| super::share_inbox::valid_id(i))
            .map(|id| OpenRequest::Share { id }),
        "settings" => match id {
            None => Some(OpenRequest::Settings { tab: None }),
            Some(tab) if valid_tab(&tab) => Some(OpenRequest::Settings { tab: Some(tab) }),
            Some(_) => None,
        },
        _ => None,
    }
}

/// `%XX` escapes decoded; `None` when they don't make UTF-8 (a broken link
/// is refused rather than guessed at).
fn percent_decode(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = bytes.get(i + 1..i + 3)?;
            let hex = std::str::from_utf8(hex).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// What one `on_open_urls` call brought.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Incoming {
    /// The links this app opens, in order.
    pub requests: Vec<OpenRequest>,
    /// Local files ("Open with Conduit"), in order.
    pub files: Vec<PathBuf>,
    /// Everything else, for the log.
    pub ignored: Vec<String>,
}

/// Splits what the system handed the app into links, files and the rest.
pub fn classify(urls: &[String]) -> Incoming {
    let mut incoming = Incoming::default();
    for raw in urls {
        let file = url::Url::parse(raw)
            .ok()
            .filter(|u| u.scheme() == "file")
            .and_then(|u| u.to_file_path().ok());
        if let Some(path) = file {
            incoming.files.push(path);
        } else if let Some(request) = parse(raw) {
            incoming.requests.push(request);
        } else {
            incoming.ignored.push(raw.clone());
        }
    }
    incoming
}

/// A link for the log: the scheme and the kind, never ids or text.
pub fn redacted(url: &str) -> String {
    match url::Url::parse(url) {
        Ok(u) if u.scheme() == SCHEME => {
            // Only a kind this app knows is named; anything else in its place
            // could be private (`conduit://<some id>`).
            let kind = u
                .host_str()
                .map(str::to_string)
                .or_else(|| u.path().split('/').next().map(str::to_string))
                .filter(|k| {
                    matches!(
                        k.as_str(),
                        "chat"
                            | "new"
                            | "settings"
                            | "new_chat"
                            | "quick-ask"
                            | "call"
                            | "mic"
                            | "share"
                            | "clipboard"
                            | "camera"
                            | "photos"
                    )
                })
                .unwrap_or_else(|| "?".into());
            format!("{SCHEME}://{kind}/…")
        }
        Ok(u) => format!("{}:…", u.scheme()),
        Err(_) => "(not a URL)".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chat(id: &str) -> Option<OpenRequest> {
        Some(OpenRequest::Chat { id: id.into() })
    }

    fn new_chat(text: Option<&str>) -> Option<OpenRequest> {
        Some(OpenRequest::NewChat {
            text: text.map(String::from),
            files: vec![],
        })
    }

    #[test]
    fn opens_a_chat_a_channel_a_note_or_a_settings_tab() {
        assert_eq!(parse("conduit://chat/abc-123"), chat("abc-123"));
        assert_eq!(parse("conduit:chat/abc"), chat("abc"));
        assert_eq!(
            parse("conduit://channels/c1"),
            Some(OpenRequest::Channel { id: "c1".into() })
        );
        assert_eq!(
            parse("conduit://note/n1"),
            Some(OpenRequest::Note { id: "n1".into() })
        );
        assert_eq!(
            parse("conduit://settings/audio"),
            Some(OpenRequest::Settings {
                tab: Some("audio".into())
            })
        );
        assert_eq!(
            parse("conduit://settings"),
            Some(OpenRequest::Settings { tab: None })
        );
        // Ids the daemon hands out: uuids and local (temporary) ids.
        assert_eq!(
            parse("conduit://chat/local:6f1c2b9e-0d2a-4c1e-9a77-1b2c3d4e5f60"),
            chat("local:6f1c2b9e-0d2a-4c1e-9a77-1b2c3d4e5f60")
        );
        // A trailing slash is the same link.
        assert_eq!(parse("conduit://chat/abc/"), chat("abc"));
    }

    #[test]
    fn starts_a_new_chat_with_text_when_given() {
        assert_eq!(parse("conduit://new"), new_chat(None));
        assert_eq!(
            parse("conduit://new?q=Hello%20there"),
            new_chat(Some("Hello there"))
        );
        assert_eq!(parse("conduit://new?q=a+b"), new_chat(Some("a b")));
        assert_eq!(parse("conduit://new?prompt=Hi"), new_chat(Some("Hi")));
        assert_eq!(parse("conduit://new?q=%20%20"), new_chat(None));
        assert_eq!(
            parse("conduit://new?q=%E2%9C%93%20done"),
            new_chat(Some("\u{2713} done"))
        );
        // Long text is cut, by characters.
        let long = format!("conduit://new?q={}", "\u{e9}".repeat(MAX_TEXT + 5));
        match parse(&long) {
            Some(OpenRequest::NewChat { text: Some(t), .. }) => {
                assert_eq!(t.chars().count(), MAX_TEXT)
            }
            other => panic!("{other:?}"),
        }
        // `new` takes no id.
        assert_eq!(parse("conduit://new/abc"), None);
    }

    #[test]
    fn opens_quick_ask_or_a_voice_call_as_the_widget_asks() {
        let quick_ask = Some(OpenRequest::QuickAsk { text: None });
        assert_eq!(parse("conduit://quick-ask"), quick_ask);
        assert_eq!(parse("conduit://call"), Some(OpenRequest::VoiceCall));
        assert_eq!(parse("conduit://quick-ask/"), quick_ask);
        // The phone widget's links.
        assert_eq!(parse("conduit://new_chat?homeWidget=true"), new_chat(None));
        assert_eq!(
            parse("conduit://mic?homeWidget=true"),
            Some(OpenRequest::VoiceCall)
        );
        // Neither takes an id.
        assert_eq!(parse("conduit://quick-ask/x"), None);
        assert_eq!(parse("conduit://call/c1"), None);
    }

    #[test]
    fn opens_the_clipboard_or_a_new_chat_for_the_phone_widgets_other_buttons() {
        assert_eq!(parse("conduit://clipboard"), Some(OpenRequest::Clipboard));
        assert_eq!(
            parse("conduit://clipboard?homeWidget=true"),
            Some(OpenRequest::Clipboard)
        );
        assert_eq!(parse("conduit://clipboard/x"), None);
        // Camera and Photos: the Mac has no picker a link can open.
        assert_eq!(parse("conduit://camera?homeWidget=true"), new_chat(None));
        assert_eq!(parse("conduit://photos"), new_chat(None));
        assert_eq!(parse("conduit://camera/x"), None);
    }

    #[test]
    fn opens_a_share_from_the_share_menu() {
        assert_eq!(
            parse("conduit://share/6f1c2b9e-0d2a-4c1e-9a77-1b2c3d4e5f60"),
            Some(OpenRequest::Share {
                id: "6f1c2b9e-0d2a-4c1e-9a77-1b2c3d4e5f60".into()
            })
        );
        for rejected in [
            "conduit://share",
            "conduit://share/abc",
            "conduit://share/6F1C2B9E-0D2A-4C1E-9A77-1B2C3D4E5F60",
            "conduit://share/6f1c2b9e-0d2a-4c1e-9a77-1b2c3d4e5f60.part",
            "conduit://share/../6f1c2b9e-0d2a-4c1e-9a77-1b2c3d4e5f60",
        ] {
            assert_eq!(parse(rejected), None, "{rejected}");
        }
        assert!(
            OpenRequest::Share { id: "x".into() }.needs_main(),
            "a share opens in the main window"
        );
    }

    #[test]
    fn refuses_what_is_not_a_link_this_app_opens() {
        for rejected in [
            "https://example.com/chat/1",
            "app://conduit/settings",
            "conduit://chat",
            "conduit://chat/../../etc",
            "conduit://chat/a/b",
            "conduit://chat/%E0%A4%A",
            "conduit://settings/Audio<script>",
            "conduit://unknown/1",
            "not a url",
            "",
            "conduit://chat/./x",
            "conduit:chat/..",
            "conduit://chat/a%2Fb",
            "conduit://chat/has space",
            "conduit://settings/tab1",
            &format!("conduit://chat/{}", "a".repeat(129)),
        ] {
            assert_eq!(parse(rejected), None, "{rejected}");
        }
    }

    // A notification's target is re-checked with the same id rule.
    #[test]
    fn ids_are_checked() {
        assert!(valid_id("c1"));
        assert!(valid_id("local:abc_1.2-3"));
        assert!(!valid_id("../x"));
        assert!(!valid_id(""));
        assert!(!valid_id("a/b"));
        assert!(!valid_id("é"));
    }

    #[test]
    fn classifies_links_files_and_the_rest() {
        // Files come as this OS's file URLs: on Windows a drive or a share.
        #[cfg(windows)]
        let (files, paths) = (
            [
                "file:///C:/Users/someone/Documents/notes%20v2.md",
                "file://fileserver/photos/photo.png",
            ],
            [
                r"C:\Users\someone\Documents\notes v2.md",
                r"\\fileserver\photos\photo.png",
            ],
        );
        #[cfg(not(windows))]
        let (files, paths) = (
            [
                "file:///Users/someone/Documents/notes%20v2.md",
                "file:///tmp/photo.png",
            ],
            ["/Users/someone/Documents/notes v2.md", "/tmp/photo.png"],
        );
        let incoming = classify(&[
            "conduit://chat/c1".into(),
            files[0].into(),
            "https://example.org".into(),
            files[1].into(),
            "conduit://unknown".into(),
        ]);
        assert_eq!(incoming.requests, vec![chat("c1").unwrap()]);
        assert_eq!(incoming.files, paths.map(PathBuf::from).to_vec());
        assert_eq!(
            incoming.ignored,
            vec![
                "https://example.org".to_string(),
                "conduit://unknown".into()
            ]
        );
    }

    #[test]
    fn only_main_frame_requests_wait_for_main() {
        assert!(chat("c").unwrap().needs_main());
        assert!(new_chat(None).unwrap().needs_main());
        assert!(!OpenRequest::Settings { tab: None }.needs_main());
        assert!(OpenRequest::VoiceCall.needs_main());
        assert!(!OpenRequest::QuickAsk { text: None }.needs_main());
    }

    #[test]
    fn the_log_never_sees_ids_or_text() {
        assert_eq!(redacted("conduit://chat/secret-id"), "conduit://chat/…");
        assert_eq!(redacted("conduit://new?q=private"), "conduit://new/…");
        assert_eq!(
            redacted("conduit://share/6f1c2b9e-0d2a-4c1e-9a77-1b2c3d4e5f60"),
            "conduit://share/…"
        );
        assert_eq!(redacted("https://example.org/x"), "https:…");
        assert_eq!(redacted("nope"), "(not a URL)");
        assert_eq!(
            redacted("conduit://private-conversation-id"),
            "conduit://?/…"
        );
        assert_eq!(redacted("conduit:private-note/x"), "conduit://?/…");
        // Encoded dot segments are dot segments.
        for link in [
            "conduit://chat/old/%2e%2e/new",
            "conduit://chat/old/.%2E/new",
            "conduit://chat/%2E/new",
        ] {
            assert_eq!(parse(link), None, "{link}");
        }
    }
}
