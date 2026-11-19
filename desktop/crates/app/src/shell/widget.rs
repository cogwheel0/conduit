//! The desktop widget's snapshot (WidgetKit, `packaging/macos/widget`).
//!
//! The widget runs in its own sandboxed process and never talks to the
//! daemon: it reads one small file the app writes, `widget-snapshot.json`,
//! from the app group's container the two share. The app writes it again
//! when what it holds changes ([`crate::desktop`] follows the session, the
//! chat list and the language), then asks WidgetKit to read it again
//! ([`Bridge::reload_all`]).
//!
//! **Privacy.** The newest chats' ids, titles and times, and whether
//! anyone is signed in; never message text, models, folders or account
//! names. Signed out, the file holds no chats at all. It is written owner
//! read/write only, by replacing the old file in one rename; a write that
//! fails leaves no copy of what it carried beside it.
//!
//! **Whose.** The file carries an `owner`: a one-way tag of the account in
//! charge of the chats ([`owner_tag`]), never the account itself. The app
//! compares it with the account in charge now, so a list still loading
//! for the same account keeps the chats the widget shows (at launch too),
//! and another account's list never shows the last one's.
//!
//! **Where.** `~/Library/Group Containers/<group>/widget-snapshot.json`,
//! the group being the bundle's `ConduitAppGroup` (bundle.sh writes it from
//! release.env). `CONDUIT_WIDGET_SNAPSHOT` names another file (tests and
//! the E2E pass). Without either, and outside a bundle that carries the
//! widget, nothing is written.

use std::io::{self, Write as _};
use std::path::{Path, PathBuf};

use conduit_protocol::ChatSummary;
use serde::Serialize;

use super::deep_link;

/// The file in the group container (the widget's `WidgetSnapshot.fileName`).
pub const FILE_NAME: &str = "widget-snapshot.json";
/// The format the widget reads (`WidgetSnapshot.currentVersion`).
pub const VERSION: u32 = 1;
/// The most chats any widget family lists (the large one).
pub const MAX_CHATS: usize = 6;
/// Titles are cut to this many characters (the widget draws one or two
/// lines of them).
pub const MAX_TITLE: usize = 200;
/// Writes the snapshot to this file instead (tests, the E2E pass).
pub const PATH_ENV: &str = "CONDUIT_WIDGET_SNAPSHOT";
/// The Info.plist key naming the app group.
pub const GROUP_KEY: &str = "ConduitAppGroup";

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub version: u32,
    /// The app routes to its main window (an Open WebUI account signed
    /// in, or a Direct-only or Hermes-only setup).
    pub signed_in: bool,
    /// The app's language, so the widget speaks it too.
    pub locale: String,
    /// Newest first.
    pub chats: Vec<SnapshotChat>,
    /// Whose chats these are ([`owner_tag`]); the widget doesn't read it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotChat {
    pub id: String,
    pub title: String,
    pub updated_at_ms: i64,
}

impl Snapshot {
    /// Nobody signed in: no chats.
    pub fn signed_out(locale: &str) -> Self {
        Self {
            version: VERSION,
            signed_in: false,
            locale: locale.to_string(),
            chats: vec![],
            owner: None,
        }
    }

    /// The newest of `recent` (newest first, archived ones already left
    /// out, as [`crate::stores::chat_list::ChatListStore::recent`] gives
    /// them). An untitled chat is called `untitled`, as the sidebar calls
    /// it; a chat whose id a link can't carry is left out.
    pub fn signed_in(recent: &[ChatSummary], locale: &str, untitled: &str) -> Self {
        let chats = recent
            .iter()
            .filter(|c| !c.archived && deep_link::valid_id(&c.id))
            .take(MAX_CHATS)
            .map(|c| {
                let title = c.title.trim();
                let title = if title.is_empty() { untitled } else { title };
                SnapshotChat {
                    id: c.id.clone(),
                    title: title.chars().take(MAX_TITLE).collect(),
                    updated_at_ms: c.updated_at_ms,
                }
            })
            .collect();
        Self {
            version: VERSION,
            signed_in: true,
            locale: locale.to_string(),
            chats,
            owner: None,
        }
    }

    /// The same snapshot, for `owner` ([`owner_tag`]).
    pub fn owned_by(mut self, owner: String) -> Self {
        self.owner = Some(owner);
        self
    }

    pub fn to_json(&self) -> Vec<u8> {
        let mut bytes = serde_json::to_vec_pretty(self).unwrap_or_default();
        bytes.push(b'\n');
        bytes
    }
}

/// Replaces `path` with `bytes` in one rename, readable by its owner only:
/// the widget never reads half a file, and nothing else on the Mac reads
/// it at all.
pub fn write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let dir = path
        .parent()
        .filter(|d| !d.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir)?;
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(FILE_NAME);
    let tmp = dir.join(format!(".{name}.{}.tmp", std::process::id()));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }
    let result = options
        .open(&tmp)
        .and_then(|mut f| f.write_all(bytes).and_then(|()| f.sync_all()))
        .and_then(|()| std::fs::rename(&tmp, path));
    if result.is_err() {
        // What the failed write carried (chat titles) goes with it: a copy
        // left beside the file would outlive a later sign-out.
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

/// Takes the snapshot away altogether (a sign-out whose write failed):
/// the widget then shows no chats rather than the last account's.
pub fn remove(path: &Path) -> io::Result<()> {
    match std::fs::remove_file(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

/// The tag a snapshot carries for the account in charge of its chats
/// (`scope`, [`crate::stores::accounts::AccountsStore::scope_key`]): one
/// way, so the file never names the account. No account in charge (a
/// Direct-only or Hermes-only setup, or signed out) has its own tag.
pub fn owner_tag(scope: Option<&str>) -> String {
    let Some(scope) = scope else {
        return "none".to_string();
    };
    // FNV-1a over a salted scope: stable across builds, and short.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in format!("conduit-widget-owner\n{scope}").bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

/// The owner of the snapshot at `path`, as it was written; `None` when
/// there is none, or it doesn't say (nothing on disk to keep).
pub fn read_owner(path: &Path) -> Option<String> {
    let bytes = std::fs::read(path).ok()?;
    let value: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    value.get("owner")?.as_str().map(String::from)
}

/// Where the snapshot goes: [`PATH_ENV`] when set, else the app group's
/// container (`group_container` asks the system for it), else nowhere.
pub fn destination(
    env: Option<PathBuf>,
    group: Option<&str>,
    group_container: impl FnOnce(&str) -> Option<PathBuf>,
) -> Option<PathBuf> {
    if let Some(path) = env.filter(|p| !p.as_os_str().is_empty()) {
        return Some(path);
    }
    let group = group.map(str::trim).filter(|g| !g.is_empty())?;
    group_container(group).map(|dir| dir.join(FILE_NAME))
}

/// `libconduit_widget.dylib` (Contents/Frameworks), the Swift side of the
/// widget: WidgetKit's `WidgetCenter` and the app group's container. Dev
/// builds without the widget, tests and other platforms have none, and the
/// snapshot then has nowhere to go but [`PATH_ENV`].
pub struct Bridge {
    #[cfg(target_os = "macos")]
    inner: Option<mac::Library>,
}

impl Bridge {
    /// Opens the library from the bundle's Frameworks folder.
    pub fn load() -> Self {
        #[cfg(target_os = "macos")]
        {
            Self {
                inner: mac::Library::open(),
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            Self {}
        }
    }

    pub fn is_loaded(&self) -> bool {
        #[cfg(target_os = "macos")]
        {
            self.inner.is_some()
        }
        #[cfg(not(target_os = "macos"))]
        {
            false
        }
    }

    /// Asks WidgetKit to read every Conduit widget's timeline again.
    /// Whether the request went out.
    pub fn reload_all(&self) -> bool {
        #[cfg(target_os = "macos")]
        {
            self.inner.as_ref().is_some_and(|l| l.reload_all())
        }
        #[cfg(not(target_os = "macos"))]
        {
            false
        }
    }

    /// The app group's container, made if missing; `None` when the system
    /// gives this app none (no library, or no entitlement for `group`).
    pub fn group_container(&self, group: &str) -> Option<PathBuf> {
        #[cfg(target_os = "macos")]
        {
            self.inner.as_ref().and_then(|l| l.group_container(group))
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = group;
            None
        }
    }
}

/// The bundle's `ConduitAppGroup`, when it has one.
pub fn bundle_group() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        use objc2_foundation::{NSBundle, NSString};
        let value =
            NSBundle::mainBundle().objectForInfoDictionaryKey(&NSString::from_str(GROUP_KEY));
        value
            .and_then(|v| v.downcast::<NSString>().ok())
            .map(|s| s.to_string())
            .filter(|s| !s.trim().is_empty())
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

#[cfg(target_os = "macos")]
mod mac {
    use std::ffi::{CStr, CString, c_char, c_int, c_void};
    use std::path::PathBuf;

    use objc2_foundation::NSBundle;

    unsafe extern "C" {
        fn dlopen(path: *const c_char, mode: c_int) -> *mut c_void;
        fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    }
    const RTLD_NOW: c_int = 0x2;
    const RTLD_LOCAL: c_int = 0x4;

    type ReloadAll = unsafe extern "C" fn() -> i32;
    type GroupContainer = unsafe extern "C" fn(*const c_char, *mut c_char, isize) -> isize;

    /// The library's two functions. It stays loaded for the app's life.
    pub struct Library {
        reload_all: ReloadAll,
        group_container: GroupContainer,
    }

    impl Library {
        pub fn open() -> Option<Self> {
            let frameworks = NSBundle::mainBundle().privateFrameworksPath()?.to_string();
            let path = format!("{frameworks}/libconduit_widget.dylib");
            if !std::path::Path::new(&path).is_file() {
                return None;
            }
            let c_path = CString::new(path).ok()?;
            // SAFETY: loads the bundle's own library, signed with the app
            // (library validation holds it to the same team); dlsym looks
            // up the two `@_cdecl` functions Bridge/WidgetBridge.swift
            // exports, with the signatures declared there.
            unsafe {
                let handle = dlopen(c_path.as_ptr(), RTLD_NOW | RTLD_LOCAL);
                if handle.is_null() {
                    log::warn!("widget: libconduit_widget.dylib would not load");
                    return None;
                }
                let reload = dlsym(handle, c"conduit_widget_reload_all".as_ptr());
                let container = dlsym(handle, c"conduit_widget_group_container".as_ptr());
                if reload.is_null() || container.is_null() {
                    log::warn!("widget: libconduit_widget.dylib lacks its functions");
                    return None;
                }
                Some(Self {
                    reload_all: std::mem::transmute::<*mut c_void, ReloadAll>(reload),
                    group_container: std::mem::transmute::<*mut c_void, GroupContainer>(container),
                })
            }
        }

        pub fn reload_all(&self) -> bool {
            // SAFETY: the library's `conduit_widget_reload_all`.
            unsafe { (self.reload_all)() == 1 }
        }

        pub fn group_container(&self, group: &str) -> Option<PathBuf> {
            let group = CString::new(group).ok()?;
            let mut buffer = vec![0 as c_char; 1024];
            // SAFETY: the library's `conduit_widget_group_container` writes at
            // most `capacity` bytes (a NUL-terminated path) into `buffer`,
            // and returns the path's length (0: no container).
            let len = unsafe {
                (self.group_container)(group.as_ptr(), buffer.as_mut_ptr(), buffer.len() as isize)
            };
            if len <= 0 || len as usize >= buffer.len() {
                return None;
            }
            // SAFETY: the call wrote a NUL-terminated string into `buffer`.
            let path = unsafe { CStr::from_ptr(buffer.as_ptr()) };
            path.to_str().ok().map(PathBuf::from)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chat(id: &str, title: &str, at: i64) -> ChatSummary {
        ChatSummary {
            id: id.into(),
            title: title.into(),
            updated_at_ms: at,
            pinned: false,
            archived: false,
            folder_id: Some("folder-1".into()),
            model: Some("kestrel-8b".into()),
            tags: vec!["travel".into()],
            shared: true,
            read_only: false,
            unread: true,
            menu: Default::default(),
        }
    }

    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("conduit-widget-test-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn carries_the_newest_chats_titles_ids_and_times_only() {
        let recent: Vec<ChatSummary> = (0..9)
            .map(|i| chat(&format!("c{i}"), &format!("Trip plan {i}"), 1_000 - i))
            .collect();
        let s = Snapshot::signed_in(&recent, "de", "Neuer Chat");
        assert!(s.signed_in);
        assert_eq!(s.locale, "de");
        assert_eq!(s.chats.len(), MAX_CHATS);
        assert_eq!(s.chats[0].id, "c0");
        assert_eq!(s.chats[5].updated_at_ms, 995);
        let json = String::from_utf8(s.to_json()).unwrap();
        // Nothing but the four fields per chat: no folder, model, tags,
        // sharing or unread state.
        for absent in ["folder", "kestrel", "travel", "shared", "unread", "pinned"] {
            assert!(!json.contains(absent), "{absent} in {json}");
        }
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(
            value["chats"][0],
            serde_json::json!({"id": "c0", "title": "Trip plan 0", "updatedAtMs": 1000})
        );
        assert_eq!(value["version"], 1);
        assert_eq!(value["signedIn"], true);
    }

    #[test]
    fn signed_out_means_no_chats() {
        let s = Snapshot::signed_out("en");
        assert!(!s.signed_in);
        assert!(s.chats.is_empty());
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&s.to_json()).unwrap(),
            serde_json::json!({"version": 1, "signedIn": false, "locale": "en", "chats": []})
        );
    }

    #[test]
    fn names_untitled_chats_and_cuts_long_titles() {
        let long = "é".repeat(MAX_TITLE + 40);
        let s = Snapshot::signed_in(
            &[
                chat("a", "   ", 3),
                chat("b", &long, 2),
                chat("c", " Padded ", 1),
            ],
            "en",
            "New Chat",
        );
        assert_eq!(s.chats[0].title, "New Chat");
        assert_eq!(s.chats[1].title.chars().count(), MAX_TITLE);
        assert_eq!(s.chats[2].title, "Padded");
    }

    #[test]
    fn leaves_out_archived_chats_and_ids_a_link_cant_carry() {
        let mut archived = chat("old", "Archived plan", 9);
        archived.archived = true;
        let s = Snapshot::signed_in(
            &[
                archived,
                chat("../etc", "Odd", 8),
                chat("local:tmp-1", "Kept", 7),
            ],
            "en",
            "New Chat",
        );
        let ids: Vec<&str> = s.chats.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(ids, ["local:tmp-1"]);
    }

    // The widget decodes what the app writes: the fixture the widget's
    // render tool draws is exactly this writer's output.
    #[test]
    fn matches_the_widget_fixture() {
        let titles = [
            (
                "c0ffee00-0000-4000-8000-000000000001",
                "Weekend hike in the Alps",
                1_794_408_480_000,
            ),
            (
                "c0ffee00-0000-4000-8000-000000000002",
                "Sourdough starter schedule",
                1_794_396_000_000,
            ),
            (
                "c0ffee00-0000-4000-8000-000000000003",
                "Explain quantum tunnelling simply",
                1_794_315_600_000,
            ),
            (
                "c0ffee00-0000-4000-8000-000000000004",
                "Draft a polite follow-up email",
                1_794_150_000_000,
            ),
            (
                "c0ffee00-0000-4000-8000-000000000005",
                "Plan a small vegetable garden",
                1_793_372_400_000,
            ),
            (
                "c0ffee00-0000-4000-8000-000000000006",
                "Rust lifetimes, explained with examples",
                1_759_849_200_000,
            ),
        ];
        let recent: Vec<ChatSummary> = titles.iter().map(|(id, t, at)| chat(id, t, *at)).collect();
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../packaging/macos/widget/Fixtures/snapshot.json");
        let committed = std::fs::read_to_string(fixture).unwrap();
        let written =
            String::from_utf8(Snapshot::signed_in(&recent, "en", "New Chat").to_json()).unwrap();
        assert_eq!(committed, written);
    }

    #[test]
    fn writes_the_whole_file_for_its_owner_only() {
        let dir = scratch("write");
        let path = dir.join("nested").join(FILE_NAME);
        write(&path, b"{\"version\":1}\n").unwrap();
        write(&path, b"{\"version\":1,\"signedIn\":false}\n").unwrap();
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "{\"version\":1,\"signedIn\":false}\n"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        // No temporary file is left beside it.
        let names: Vec<String> = std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, [FILE_NAME]);
    }

    #[test]
    fn a_failed_write_keeps_the_old_file() {
        let dir = scratch("fail");
        let path = dir.join(FILE_NAME);
        write(&path, b"old\n").unwrap();
        // The target is a folder now: the rename fails.
        let blocked = dir.join("blocked");
        std::fs::create_dir_all(blocked.join("inner")).unwrap();
        assert!(write(&blocked, b"new\n").is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "old\n");
    }

    #[test]
    fn a_failed_write_leaves_no_copy_beside_it() {
        let dir = scratch("no-copy");
        // The target is a folder with something in it: the rename fails.
        let blocked = dir.join("blocked");
        std::fs::create_dir_all(blocked.join("inner")).unwrap();
        let err = write(&blocked, b"{\"chats\":[{\"title\":\"Seed swap notes\"}]}\n");
        assert!(err.is_err(), "the rename's own error comes back");
        let names: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, ["blocked"], "nothing it carried stays beside it");
    }

    #[test]
    fn the_owner_is_a_tag_that_never_names_the_account() {
        let dir = scratch("owner");
        let path = dir.join(FILE_NAME);
        let tag = owner_tag(Some("librechat:lc-river"));
        assert_ne!(tag, owner_tag(Some("librechat:lc-meadow")));
        assert_eq!(tag, owner_tag(Some("librechat:lc-river")));
        assert_ne!(owner_tag(None), tag);
        let s = Snapshot::signed_out("en").owned_by(tag.clone());
        write(&path, &s.to_json()).unwrap();
        assert_eq!(read_owner(&path), Some(tag));
        assert!(!std::fs::read_to_string(&path).unwrap().contains("lc-river"));
        // Nothing there, or no owner in it: nothing to keep.
        assert_eq!(read_owner(&dir.join("missing.json")), None);
        write(&path, b"{\"version\":1}\n").unwrap();
        assert_eq!(read_owner(&path), None);
        remove(&path).unwrap();
        assert!(!path.exists());
        remove(&path).unwrap();
    }

    #[test]
    fn goes_to_the_override_then_the_group_container() {
        let container = |g: &str| Some(PathBuf::from(format!("/containers/{g}")));
        assert_eq!(
            destination(Some("/tmp/w.json".into()), Some("grp"), container),
            Some(PathBuf::from("/tmp/w.json"))
        );
        assert_eq!(
            destination(None, Some(" grp "), container),
            Some(PathBuf::from("/containers/grp").join(FILE_NAME))
        );
        assert_eq!(destination(None, None, container), None);
        assert_eq!(destination(Some(PathBuf::new()), Some(""), container), None);
        // The system gave no container (no entitlement for the group).
        assert_eq!(destination(None, Some("grp"), |_| None), None);
    }

    #[test]
    fn has_no_bridge_outside_a_bundle() {
        let bridge = Bridge::load();
        assert!(!bridge.is_loaded());
        assert!(!bridge.reload_all());
        assert_eq!(bridge.group_container("grp"), None);
    }
}
