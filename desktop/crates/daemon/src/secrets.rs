//! The two secrets the daemon is started with.
//!
//! * The **session token** authorizes every RPC and HTTP call. It is fresh on
//!   every launch (32 random bytes, base64url) and never stored.
//! * The **master key** encrypts the daemon's secure store. It is 32 random
//!   bytes (base64), created once and kept in the macOS Keychain under the
//!   flavour's service ([`crate::paths::Flavor::keychain_service`]). On
//!   Windows it is a Credential Manager credential ([`CredentialManager`]),
//!   on Linux a Secret Service item ([`SecretService`]).
//!
//! Dev builds reach the Keychain through `/usr/bin/security` ([`SecurityCli`]):
//! every rebuild changes an ad-hoc binary's code hash, and an item an ad-hoc
//! binary created carries a `cdhash:` partition, so the next build would
//! block on a Keychain prompt (an "any application" ACL does not help; the
//! partition list wins). Items the `security` tool creates sit in its
//! stable `apple-tool:` partition. The packaged app talks to the Keychain
//! directly ([`Keychain`]); its Developer ID signature gives a stable
//! `teamid:` partition. An item an earlier, differently signed build stored
//! would make macOS ask for the login keychain password, so the app reads
//! with user interaction off first ([`check_master_key`]) and asks the user
//! before macOS does. Its Start fresh ([`start_fresh`]) gives that profile
//! a key under a new account, recorded for the profile alone
//! ([`profile_key`]): other profiles keep theirs.

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use rand::RngCore as _;

use crate::paths::KeyLock;

/// The Keychain account the master key is stored under.
pub const MASTER_KEY_ACCOUNT: &str = "masterKey";

/// A new session token: 32 random bytes, base64url without padding (43
/// characters, which is what the daemon's length check expects).
pub fn new_session_token() -> String {
    let mut bytes = [0u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

/// The subprotocol entry that carries `token`: `tk.` + base64url-without-
/// padding of the token's UTF-8 (`buildSubprotocols` in Dart).
pub fn subprotocol_token(token: &str) -> String {
    format!("tk.{}", URL_SAFE_NO_PAD.encode(token.as_bytes()))
}

/// A new master key: base64 of 32 random bytes.
pub fn new_master_key() -> String {
    let mut bytes = [0u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    STANDARD.encode(bytes)
}

/// Whether `key` is base64 of exactly 32 bytes (the daemon's own check).
pub fn is_valid_master_key(key: &str) -> bool {
    STANDARD.decode(key).is_ok_and(|b| b.len() == 32)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SecretError {
    /// The store refused or failed (OSStatus and message on macOS).
    Store(String),
    /// There is no store to ask: a Linux session with no Secret Service
    /// (nothing answers for it on D-Bus). D12's opt-in key file is offered
    /// for this, never for a store that is only locked or refused.
    Unavailable(String),
    /// A stored key is not base64 of 32 bytes. It is never overwritten: the
    /// secure store it protects would become unreadable for good.
    Corrupt,
    /// Reading the key needs the user's approval, and the read may not ask.
    WouldPrompt,
    /// The login keychain is locked, and the read may not ask to unlock it.
    Locked,
    /// The account a profile records has no item: a key made now could not
    /// open what the old one sealed.
    Missing(String),
}

impl std::fmt::Display for SecretError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Store(e) if cfg!(target_os = "macos") => write!(f, "keychain: {e}"),
            Self::Store(e) => write!(f, "secret store: {e}"),
            Self::Unavailable(e) => write!(f, "no secret store: {e}"),
            Self::Corrupt => f.write_str("the stored master key is not 32 bytes of base64"),
            Self::WouldPrompt => f.write_str("reading the master key needs the user's approval"),
            Self::Locked => f.write_str("the login keychain is locked"),
            Self::Missing(account) => write!(f, "no master key under {account}"),
        }
    }
}

impl std::error::Error for SecretError {}

/// Where the master key lives.
pub trait MasterKeyStore {
    fn load(&self) -> Result<Option<String>, SecretError>;
    /// Stores `key` unless a key is stored already, and then answers
    /// `false` and replaces nothing: another launch stored its key first.
    fn add(&self, key: &str) -> Result<bool, SecretError>;
    /// [`Self::load`], never asking the user: [`SecretError::WouldPrompt`]
    /// when the read needs their approval. A store that never asks reads
    /// as usual.
    fn load_without_asking(&self) -> Result<Option<String>, SecretError> {
        self.load()
    }
    /// Asks the user to unlock the store, nothing more. A store that never
    /// locks has nothing to do.
    fn unlock(&self) -> Result<(), SecretError> {
        Ok(())
    }
}

/// A service's master-key items, one per account (the macOS Keychain).
pub trait MasterKeyItems {
    fn item(&self, account: &str) -> Box<dyn MasterKeyStore + '_>;
}

/// What the app finds before it starts conduitd.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MasterKeyCheck {
    /// The key, read or made without asking the user.
    Ready(String),
    /// Reading the stored key would make macOS ask for the login keychain
    /// password. The app asks first: Continue ([`read_master_key`]) or
    /// Start fresh ([`start_fresh`]).
    WouldPrompt,
    /// The account the profile records has no item, and none was made: a
    /// new key could not open what the old one sealed.
    Missing,
}

/// The account of a profile's key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileKey {
    pub account: String,
    /// Recorded for the profile (by Start fresh), so its item must exist;
    /// else the default, which a first run creates.
    pub recorded: bool,
}

/// The account of `user_data`'s key: the one recorded for the profile, else
/// [`MASTER_KEY_ACCOUNT`] (every profile before Start fresh). A record that
/// is there but can't be read, or names no account, is an error: the
/// default would open the profile with the wrong key. Reads a file, never
/// the Keychain.
pub fn profile_key(user_data: &std::path::Path) -> Result<ProfileKey, SecretError> {
    Ok(match recorded_account(user_data)? {
        Some(account) => ProfileKey {
            account,
            recorded: true,
        },
        None => ProfileKey {
            account: MASTER_KEY_ACCOUNT.into(),
            recorded: false,
        },
    })
}

/// Where a profile's account is recorded: beside its folder, not in it, so
/// Reset and Clear Local Data, which move the folder aside and start again
/// with the same key, keep it.
fn key_account_file(user_data: &std::path::Path) -> std::path::PathBuf {
    let name = user_data
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "userData".into());
    user_data.with_file_name(format!("{name}.master-key-account"))
}

fn recorded_account(user_data: &std::path::Path) -> Result<Option<String>, SecretError> {
    let file = key_account_file(user_data);
    let failed = |e: String| SecretError::Store(format!("{}: {e}", file.display()));
    match std::fs::read_to_string(&file) {
        Ok(text) if is_account(text.trim()) => Ok(Some(text.trim().to_string())),
        Ok(_) => Err(failed("names no master key account".into())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(failed(e.to_string())),
    }
}

/// [`MASTER_KEY_ACCOUNT`], or one Start fresh issued (`masterKey.` and a
/// suffix of letters and digits).
fn is_account(name: &str) -> bool {
    name == MASTER_KEY_ACCOUNT
        || name
            .strip_prefix(MASTER_KEY_ACCOUNT)
            .and_then(|rest| rest.strip_prefix('.'))
            .is_some_and(|s| {
                !s.is_empty() && s.len() <= 32 && s.chars().all(|c| c.is_ascii_alphanumeric())
            })
}

/// An account never issued before. Issued names are random rather than
/// counted, so the name of an item that went is never handed to another
/// profile, whose record would then find this key under it.
fn new_account() -> String {
    format!("{MASTER_KEY_ACCOUNT}.{:016x}", rand::random::<u64>())
}

/// The profile's key, read without asking the user, or made on first run.
/// Any other failure of that read is reported, never followed by a read
/// that may prompt.
pub fn check_master_key(
    items: &dyn MasterKeyItems,
    profile: &ProfileKey,
) -> Result<MasterKeyCheck, SecretError> {
    let item = items.item(&profile.account);
    match read_without_asking(item.as_ref()) {
        Ok(Some(key)) => checked(key).map(MasterKeyCheck::Ready),
        Ok(None) if profile.recorded => Ok(MasterKeyCheck::Missing),
        Ok(None) => create_without_asking(item.as_ref()),
        Err(SecretError::WouldPrompt) => Ok(MasterKeyCheck::WouldPrompt),
        Err(e) => Err(e),
    }
}

/// Continue: the profile's key, read even if macOS asks for it (once, if
/// the user answers "Always Allow").
pub fn read_master_key(
    items: &dyn MasterKeyItems,
    profile: &ProfileKey,
) -> Result<String, SecretError> {
    let item = items.item(&profile.account);
    if !profile.recorded {
        return load_or_create_master_key(item.as_ref());
    }
    match item.load()? {
        Some(key) => checked(key),
        None => Err(SecretError::Missing(profile.account.clone())),
    }
}

/// `store`'s key, read without asking. A locked login keychain is only
/// unlocked (macOS asks for its password, which users expect), then read
/// again without asking: an item another build stored still shows the
/// card, never its own prompt. A cancelled unlock leaves it locked.
fn read_without_asking(store: &dyn MasterKeyStore) -> Result<Option<String>, SecretError> {
    match store.load_without_asking() {
        Err(SecretError::Locked) => {
            if let Err(e) = store.unlock() {
                log::warn!("master key: the keychain stayed locked ({e})");
                return Err(SecretError::Locked);
            }
            store.load_without_asking()
        }
        read => read,
    }
}

/// A new key stored in `store`, or the key another launch stored first,
/// read without asking.
fn create_without_asking(store: &dyn MasterKeyStore) -> Result<MasterKeyCheck, SecretError> {
    let key = new_master_key();
    if store.add(&key)? {
        return Ok(MasterKeyCheck::Ready(key));
    }
    match read_without_asking(store) {
        Ok(Some(key)) => checked(key).map(MasterKeyCheck::Ready),
        Ok(None) => Err(SecretError::Store("the stored master key went away".into())),
        Err(SecretError::WouldPrompt) => Ok(MasterKeyCheck::WouldPrompt),
        Err(e) => Err(e),
    }
}

/// What Start fresh did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FreshStart {
    /// The profile's new key, and where its old folder went.
    Started {
        key: String,
        moved_to: Option<std::path::PathBuf>,
    },
    /// Another launch started this profile fresh first: its key.
    AlreadyFresh(String),
    /// Nothing changed: the profile could not be reached, read or moved
    /// aside.
    MoveFailed(String),
    /// The profile was moved aside (if it had a folder), but no key was
    /// stored and recorded for it.
    KeyFailed {
        error: SecretError,
        moved_to: Option<std::path::PathBuf>,
    },
}

/// Start fresh for the profile at `user_data`, whose key under `asked`
/// would prompt: its folder moved aside, keeping its account beside it,
/// then a key under a new account, recorded for the profile. The old item
/// is never read (that read is what prompts) and never deleted (another
/// build's item refuses this one's delete anyway).
///
/// The folder moves first: a key made first would be the profile's from
/// then on, and a launch after a failed move would open the old folder
/// with it. The new account is noted as pending before its key is stored,
/// so a retry after the record failed records that key rather than making
/// another. It all happens holding `lock`, so a second launch that chose
/// Start fresh for the profile finds it recorded under another account and
/// takes that key.
pub fn start_fresh(
    items: &dyn MasterKeyItems,
    user_data: &std::path::Path,
    asked: &str,
    lock: &KeyLock,
    now: std::time::SystemTime,
) -> FreshStart {
    match lock.hold() {
        Ok(_held) => fresh_holding_the_lock(items, user_data, asked, now),
        Err(e) => FreshStart::MoveFailed(e.to_string()),
    }
}

fn fresh_holding_the_lock(
    items: &dyn MasterKeyItems,
    user_data: &std::path::Path,
    asked: &str,
    now: std::time::SystemTime,
) -> FreshStart {
    let recorded = match recorded_account(user_data) {
        Ok(recorded) => recorded,
        Err(e) => return FreshStart::MoveFailed(e.to_string()),
    };
    if let Some(recorded) = recorded.as_deref().filter(|a| *a != asked) {
        let error = match read_without_asking(items.item(recorded).as_ref()) {
            // Taken up only once its record is on disk.
            Ok(Some(key)) => match checked(key).and_then(|key| {
                let dir = parent_dir(&key_account_file(user_data)).to_path_buf();
                sync_dir(&dir)
                    .map(|()| key)
                    .map_err(|e| SecretError::Store(format!("{}: {e}", dir.display())))
            }) {
                Ok(key) => return FreshStart::AlreadyFresh(key),
                Err(e) => e,
            },
            Ok(None) => SecretError::Missing(recorded.to_string()),
            Err(e) => e,
        };
        return FreshStart::KeyFailed {
            error,
            moved_to: None,
        };
    }
    let moved_to = match user_data.try_exists() {
        Ok(false) => None,
        Ok(true) => match move_with_its_account(user_data, recorded.as_deref(), now) {
            Ok(moved_to) => Some(moved_to),
            Err(e) => return FreshStart::MoveFailed(e),
        },
        Err(e) => return FreshStart::MoveFailed(format!("{}: {e}", user_data.display())),
    };
    match new_profile_key(items, user_data) {
        Ok(key) => FreshStart::Started { key, moved_to },
        Err(error) => FreshStart::KeyFailed { error, moved_to },
    }
}

/// Moves a profile's folder aside as Reset and Clear Local Data do, its
/// account recorded beside the archive when it has one, so the archive
/// still opens with its own key; the profile's record stays for the fresh
/// folder.
pub fn move_profile_aside(
    user_data: &std::path::Path,
    now: std::time::SystemTime,
) -> Result<std::path::PathBuf, String> {
    let recorded = recorded_account(user_data).map_err(|e| e.to_string())?;
    move_with_its_account(user_data, recorded.as_deref(), now)
}

/// Moves the profile aside, its account recorded beside the archive first
/// so the archive opens with its own key again (a profile without a record
/// needs none: the default). Recording first means a crash can't leave the
/// archive without its account; a record left beside a path that never got
/// its folder is harmless, since nothing opens it. If the move fails, the
/// record written ahead goes again.
fn move_with_its_account(
    user_data: &std::path::Path,
    recorded: Option<&str>,
    now: std::time::SystemTime,
) -> Result<std::path::PathBuf, String> {
    let archive = crate::paths::aside_path(user_data, now);
    let record = key_account_file(&archive);
    if let Some(account) = recorded {
        record_durably(&record, account)
            .map_err(|e| format!("recording {account} beside {}: {e}", archive.display()))?;
    }
    if let Err(e) = std::fs::rename(user_data, &archive) {
        if recorded.is_some() {
            let _ = std::fs::remove_file(&record);
        }
        return Err(format!("{}: {e}", user_data.display()));
    }
    Ok(archive)
}

/// The record's folders are made before the key is stored, so where the
/// record can't go no key is left unused.
fn new_profile_key(
    items: &dyn MasterKeyItems,
    user_data: &std::path::Path,
) -> Result<String, SecretError> {
    let file = key_account_file(user_data);
    let failed = |e: std::io::Error| SecretError::Store(format!("{}: {e}", file.display()));
    let dir = parent_dir(&file);
    let pending = file.with_file_name(format!(
        "{}.pending",
        file.file_name().unwrap_or_default().to_string_lossy()
    ));
    make_record_folders(dir).map_err(failed)?;
    let account = match std::fs::read_to_string(&pending) {
        // Reused only once its entry is on disk, before any key is stored.
        Ok(text) if is_account(text.trim()) => {
            sync_dir(dir).map_err(failed)?;
            text.trim().to_string()
        }
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(failed(e)),
        _ => {
            let account = new_account();
            record_durably(&pending, &account).map_err(failed)?;
            account
        }
    };
    let item = items.item(&account);
    let key = match read_without_asking(item.as_ref())? {
        Some(key) => checked(key)?,
        None => match create_without_asking(item.as_ref())? {
            MasterKeyCheck::Ready(key) => key,
            MasterKeyCheck::WouldPrompt | MasterKeyCheck::Missing => {
                return Err(SecretError::WouldPrompt);
            }
        },
    };
    std::fs::rename(&pending, &file).map_err(failed)?;
    sync_dir(dir).map_err(failed)?;
    Ok(key)
}

/// Makes the folders missing on the way to `dir`, each one's entry on disk
/// in its parent before the next is made.
fn make_record_folders(dir: &std::path::Path) -> std::io::Result<()> {
    for folder in missing_folders(dir).into_iter().rev() {
        match std::fs::create_dir(folder) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
        sync_dir(parent_dir(folder))?;
    }
    Ok(())
}

/// Writes `account` to `file` through a file of its own, on disk before it
/// is renamed into place, so a crash leaves the old record or the new one.
fn record_durably(file: &std::path::Path, account: &str) -> std::io::Result<()> {
    use std::io::Write as _;
    let dir = parent_dir(file);
    let name = file.file_name().unwrap_or_default().to_string_lossy();
    let staged = dir.join(format!(".{name}.{:016x}", rand::random::<u64>()));
    let written = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&staged)
        .and_then(|mut f| {
            f.write_all(account.as_bytes())?;
            f.sync_all()
        })
        .and_then(|()| std::fs::rename(&staged, file));
    if written.is_err() {
        let _ = std::fs::remove_file(&staged);
    }
    written?;
    sync_dir(dir)
}

/// The folders missing on the way to `dir`, nearest first. A relative
/// path's ancestors end with the empty path, which is the working folder,
/// never one to make.
fn missing_folders(dir: &std::path::Path) -> Vec<&std::path::Path> {
    dir.ancestors()
        .take_while(|d| !d.as_os_str().is_empty() && !d.exists())
        .collect()
}

/// `path`'s folder: `.` for a relative path of one part, whose parent is
/// the empty path (`CONDUIT_USER_DATA=Conduit`).
fn parent_dir(path: &std::path::Path) -> &std::path::Path {
    path.parent()
        .filter(|dir| !dir.as_os_str().is_empty())
        .unwrap_or(std::path::Path::new("."))
}

/// Writes `dir`'s entries to disk. Windows opens no folder to sync it.
fn sync_dir(dir: &std::path::Path) -> std::io::Result<()> {
    if cfg!(unix) {
        std::fs::File::open(dir)?.sync_all()
    } else {
        Ok(())
    }
}

/// The stored master key, creating and storing one on first run. Two first
/// launches at once both make a key, but only one is stored, and the other
/// launch takes that one: a second write would leave the data the first
/// launch encrypted under a key nobody has.
pub fn load_or_create_master_key(store: &dyn MasterKeyStore) -> Result<String, SecretError> {
    if let Some(key) = store.load()? {
        return checked(key);
    }
    let key = new_master_key();
    if store.add(&key)? {
        return Ok(key);
    }
    match store.load()? {
        Some(key) => checked(key),
        None => Err(SecretError::Store("the stored master key went away".into())),
    }
}

/// The master key on Linux, chosen the same way at start-up
/// (`make_file: false`) and when the user picks the key file (D12,
/// `make_file: true`): a key file that exists wins, as the user chose it;
/// else the Secret Service's key; and a new key goes to the keyring
/// whenever one answers, to the file only when there is none at all and
/// the user asked for it. A keyring that is locked or refuses keeps its
/// answer. The whole choice, and a new key, happen under the service's
/// lock, so two profiles (or launches) never end up with one key each.
#[cfg(unix)]
pub fn linux_master_key<S: ReplacingStore>(
    secret_service: &S,
    key_file: &KeyFile,
    lock: &KeyLock,
    make_file: bool,
) -> Result<String, SecretError> {
    // One lock per service around the whole choice: a launch looks at the
    // key file and the keyring, and makes a key, only while no other launch
    // of the service can, so none makes a key after another made one.
    let _held = lock.hold()?;
    if key_file.chosen()? {
        return file_key(key_file);
    }
    match secret_service.load() {
        Ok(Some(key)) => checked(key),
        Ok(None) => {
            let key = new_master_key();
            secret_service.replace(&key)?;
            Ok(key)
        }
        Err(SecretError::Unavailable(_)) if make_file => load_or_create_master_key(key_file),
        Err(e) => Err(e),
    }
}

#[cfg(unix)]
fn file_key(key_file: &KeyFile) -> Result<String, SecretError> {
    match key_file.load()? {
        Some(key) => checked(key),
        None => Err(SecretError::Store(format!(
            "{} went away",
            key_file.path.display()
        ))),
    }
}

/// A stored key, trimmed, unless it is not base64 of 32 bytes.
fn checked(key: String) -> Result<String, SecretError> {
    let key = key.trim().to_string();
    if is_valid_master_key(&key) {
        Ok(key)
    } else {
        Err(SecretError::Corrupt)
    }
}

/// A store whose write replaces what is there (Credential Manager, the
/// Secret Service), which [`LockedStore`] makes create-only.
pub trait ReplacingStore {
    fn load(&self) -> Result<Option<String>, SecretError>;
    fn replace(&self, key: &str) -> Result<(), SecretError>;
}

impl<S: ReplacingStore> ReplacingStore for &S {
    fn load(&self) -> Result<Option<String>, SecretError> {
        (**self).load()
    }
    fn replace(&self, key: &str) -> Result<(), SecretError> {
        (**self).replace(key)
    }
}

/// A [`ReplacingStore`] made create-only: it looks and writes holding
/// `lock`, which every launch using the same service shares whatever its
/// profile ([`crate::paths::master_key_lock`]). The key is the service's,
/// as the Keychain item is on the Mac.
pub struct LockedStore<S> {
    pub store: S,
    pub lock: KeyLock,
}

impl<S> LockedStore<S> {
    pub fn new(store: S, lock: KeyLock) -> Self {
        Self { store, lock }
    }
}

impl<S: ReplacingStore> MasterKeyStore for LockedStore<S> {
    fn load(&self) -> Result<Option<String>, SecretError> {
        self.store.load()
    }

    fn add(&self, key: &str) -> Result<bool, SecretError> {
        let _held = self.lock.hold()?;
        if self.store.load()?.is_some() {
            return Ok(false);
        }
        self.store.replace(key)?;
        Ok(true)
    }
}

/// A [`KeyLock`] while it is held; dropping it lets the next launch in.
pub enum HeldLock {
    File(std::fs::File),
    #[cfg(target_os = "linux")]
    Socket(std::os::unix::net::UnixListener),
}

/// How long a launch waits for another one to finish creating the key (it
/// may be waiting on the desktop's keyring prompt).
#[cfg(target_os = "linux")]
const KEY_LOCK_WAIT: std::time::Duration = std::time::Duration::from_secs(120);

impl KeyLock {
    /// Waits for the lock and holds it.
    pub fn hold(&self) -> Result<HeldLock, SecretError> {
        match self {
            Self::File(path) => {
                let file = open_lock_file(path)?;
                file.lock().map_err(|e| lock_error(self, e))?;
                Ok(HeldLock::File(file))
            }
            #[cfg(target_os = "linux")]
            Self::Abstract(name) => {
                let deadline = std::time::Instant::now() + KEY_LOCK_WAIT;
                let mut checked = false;
                loop {
                    if let Some(held) = self.try_hold()? {
                        return Ok(held);
                    }
                    // Any user can bind any name: a lock another user took
                    // first would never let this one in, so say so rather
                    // than wait. Once: each look queues a connection.
                    if !checked {
                        checked = true;
                        if crate::abstract_socket::holder_is_this_user(name) == Some(false) {
                            return Err(SecretError::Store(format!(
                                "the master key's lock ({name}) is held by another user"
                            )));
                        }
                    }
                    if std::time::Instant::now() >= deadline {
                        return Err(SecretError::Store(
                            "another launch is still creating the master key".into(),
                        ));
                    }
                    std::thread::sleep(std::time::Duration::from_millis(25));
                }
            }
            #[cfg(not(target_os = "linux"))]
            Self::Abstract(_) => Err(abstract_elsewhere()),
        }
    }

    /// Holds the lock if nobody else does; `None` while it is held.
    pub fn try_hold(&self) -> Result<Option<HeldLock>, SecretError> {
        match self {
            Self::File(path) => {
                let file = open_lock_file(path)?;
                match file.try_lock() {
                    Ok(()) => Ok(Some(HeldLock::File(file))),
                    Err(std::fs::TryLockError::WouldBlock) => Ok(None),
                    Err(std::fs::TryLockError::Error(e)) => Err(lock_error(self, e)),
                }
            }
            #[cfg(target_os = "linux")]
            Self::Abstract(name) => match crate::abstract_socket::bind(name) {
                Ok(listener) => Ok(Some(HeldLock::Socket(listener))),
                Err(e) if e.kind() == std::io::ErrorKind::AddrInUse => Ok(None),
                Err(e) => Err(lock_error(self, e)),
            },
            #[cfg(not(target_os = "linux"))]
            Self::Abstract(_) => Err(abstract_elsewhere()),
        }
    }
}

fn open_lock_file(path: &std::path::Path) -> Result<std::fs::File, SecretError> {
    let locked = |e: std::io::Error| SecretError::Store(format!("{}: {e}", path.display()));
    std::fs::create_dir_all(parent_dir(path)).map_err(locked)?;
    std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(path)
        .map_err(locked)
}

fn lock_error(lock: &KeyLock, e: std::io::Error) -> SecretError {
    match lock {
        KeyLock::File(path) => SecretError::Store(format!("{}: {e}", path.display())),
        KeyLock::Abstract(name) => SecretError::Store(format!("{name}: {e}")),
    }
}

#[cfg(not(target_os = "linux"))]
fn abstract_elsewhere() -> SecretError {
    SecretError::Store("abstract socket locks exist only on Linux".into())
}

/// An in-memory store, for tests.
#[derive(Default)]
pub struct MemoryStore(pub std::sync::Mutex<Option<String>>);

impl MasterKeyStore for MemoryStore {
    fn load(&self) -> Result<Option<String>, SecretError> {
        Ok(self
            .0
            .lock()
            .map_err(|e| SecretError::Store(e.to_string()))?
            .clone())
    }
    fn add(&self, key: &str) -> Result<bool, SecretError> {
        let mut stored = self
            .0
            .lock()
            .map_err(|e| SecretError::Store(e.to_string()))?;
        if stored.is_some() {
            return Ok(false);
        }
        *stored = Some(key.to_string());
        Ok(true)
    }
}

#[cfg(target_os = "macos")]
pub use keychain::{Keychain, KeychainItems};

#[cfg(target_os = "macos")]
mod keychain {
    use super::{MasterKeyItems, MasterKeyStore, SecretError};
    use core_foundation::data::CFData;
    use security_framework::base::Error;
    use security_framework::item::{ItemAddOptions, ItemAddValue, ItemClass};
    use security_framework::os::macos::keychain::SecKeychain;
    use security_framework::passwords::get_generic_password;

    /// `errSecItemNotFound`.
    const ITEM_NOT_FOUND: i32 = -25300;
    /// `errSecDuplicateItem`.
    const DUPLICATE_ITEM: i32 = -25299;
    /// `errSecAuthFailed`: with user interaction off, an item another build
    /// stored (measured on macOS 27, not the documented
    /// `errSecInteractionNotAllowed`).
    const AUTH_FAILED: i32 = -25293;
    /// `errSecInteractionNotAllowed`: with user interaction off, a locked
    /// keychain.
    const INTERACTION_NOT_ALLOWED: i32 = -25308;

    fn store_error(e: Error) -> SecretError {
        SecretError::Store(format!("{} ({})", e, e.code()))
    }

    fn text(bytes: Option<Vec<u8>>) -> Result<Option<String>, SecretError> {
        bytes
            .map(|b| String::from_utf8(b).map_err(|_| SecretError::Corrupt))
            .transpose()
    }

    /// A generic-password item: the flavour's service, the account a
    /// profile's key is under ([`super::profile_key`]), default ACL (the
    /// signed app).
    pub struct Keychain {
        pub service: String,
        pub account: String,
    }

    impl Keychain {
        pub fn new(service: impl Into<String>, account: impl Into<String>) -> Self {
            Self {
                service: service.into(),
                account: account.into(),
            }
        }

        fn read(&self) -> Result<Option<Vec<u8>>, Error> {
            match get_generic_password(&self.service, &self.account) {
                Ok(bytes) => Ok(Some(bytes)),
                Err(e) if e.code() == ITEM_NOT_FOUND => Ok(None),
                Err(e) => Err(e),
            }
        }
    }

    impl MasterKeyStore for Keychain {
        fn load(&self) -> Result<Option<String>, SecretError> {
            text(self.read().map_err(store_error)?)
        }

        /// The login keychain's own unlock prompt, outside the read's
        /// switch: asking is the point.
        fn unlock(&self) -> Result<(), SecretError> {
            SecKeychain::default()
                .and_then(|mut keychain| keychain.unlock(None))
                .map_err(store_error)
        }

        fn load_without_asking(&self) -> Result<Option<String>, SecretError> {
            // Process-wide: user interaction is off for this one read only.
            let _no_ui = SecKeychain::disable_user_interaction().map_err(store_error)?;
            match self.read() {
                Err(e) if e.code() == AUTH_FAILED => Err(SecretError::WouldPrompt),
                Err(e) if e.code() == INTERACTION_NOT_ALLOWED => Err(SecretError::Locked),
                read => text(read.map_err(store_error)?),
            }
        }

        /// `SecItemAdd` with the attributes `set_generic_password` gives
        /// (class, service, account, data), but never its update of an item
        /// that is already there.
        fn add(&self, key: &str) -> Result<bool, SecretError> {
            let mut options = ItemAddOptions::new(ItemAddValue::Data {
                class: ItemClass::generic_password(),
                data: CFData::from_buffer(key.as_bytes()),
            });
            options
                .set_service(&self.service)
                .set_account_name(&self.account);
            match options.add() {
                Ok(()) => Ok(true),
                Err(e) if e.code() == DUPLICATE_ITEM => Ok(false),
                Err(e) => Err(store_error(e)),
            }
        }
    }

    /// The service's items in the login keychain.
    pub struct KeychainItems {
        pub service: String,
    }

    impl KeychainItems {
        pub fn new(service: impl Into<String>) -> Self {
            Self {
                service: service.into(),
            }
        }
    }

    impl MasterKeyItems for KeychainItems {
        fn item(&self, account: &str) -> Box<dyn MasterKeyStore + '_> {
            Box::new(Keychain::new(self.service.as_str(), account))
        }
    }
}

#[cfg(windows)]
pub use credential_manager::CredentialManager;

#[cfg(windows)]
mod credential_manager {
    use super::{MASTER_KEY_ACCOUNT, ReplacingStore, SecretError};
    use windows::Win32::Foundation::ERROR_NOT_FOUND;
    use windows::Win32::Security::Credentials::{
        CRED_FLAGS, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC, CREDENTIALW, CredFree,
        CredReadW, CredWriteW,
    };
    use windows::core::{PCWSTR, PWSTR};

    /// A generic credential in the user's Credential Manager (DPAPI, this
    /// machine only, never roaming): target `<service>:masterKey`. A write
    /// replaces it, so the app stores through a [`super::LockedStore`].
    pub struct CredentialManager {
        pub service: String,
    }

    impl CredentialManager {
        pub fn new(service: impl Into<String>) -> Self {
            Self {
                service: service.into(),
            }
        }

        fn target(&self) -> Vec<u16> {
            wide(&format!("{}:{MASTER_KEY_ACCOUNT}", self.service))
        }
    }

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(Some(0)).collect()
    }

    impl ReplacingStore for CredentialManager {
        fn load(&self) -> Result<Option<String>, SecretError> {
            let target = self.target();
            let mut credential: *mut CREDENTIALW = std::ptr::null_mut();
            // SAFETY: `target` is NUL-terminated and outlives the call.
            let read = unsafe {
                CredReadW(
                    PCWSTR::from_raw(target.as_ptr()),
                    CRED_TYPE_GENERIC,
                    None,
                    &mut credential,
                )
            };
            if let Err(e) = read {
                return if e.code() == ERROR_NOT_FOUND.to_hresult() {
                    Ok(None)
                } else {
                    Err(SecretError::Store(e.to_string()))
                };
            }
            if credential.is_null() {
                return Ok(None);
            }
            // SAFETY: `CredReadW` succeeded, so `credential` is valid until
            // `CredFree`, and a non-null blob is `CredentialBlobSize` bytes.
            let bytes = unsafe {
                let c = &*credential;
                let bytes = if c.CredentialBlob.is_null() {
                    Vec::new()
                } else {
                    std::slice::from_raw_parts(c.CredentialBlob, c.CredentialBlobSize as usize)
                        .to_vec()
                };
                CredFree(credential as *const _);
                bytes
            };
            String::from_utf8(bytes)
                .map(Some)
                .map_err(|_| SecretError::Corrupt)
        }

        fn replace(&self, key: &str) -> Result<(), SecretError> {
            let mut target = self.target();
            let mut account = wide(MASTER_KEY_ACCOUNT);
            let blob = key.as_bytes();
            let credential = CREDENTIALW {
                Flags: CRED_FLAGS(0),
                Type: CRED_TYPE_GENERIC,
                TargetName: PWSTR::from_raw(target.as_mut_ptr()),
                CredentialBlobSize: blob.len() as u32,
                CredentialBlob: blob.as_ptr() as *mut u8,
                Persist: CRED_PERSIST_LOCAL_MACHINE,
                UserName: PWSTR::from_raw(account.as_mut_ptr()),
                ..CREDENTIALW::default()
            };
            // SAFETY: every pointer in `credential` outlives the call, which
            // only reads them.
            unsafe { CredWriteW(&credential, 0) }.map_err(|e| SecretError::Store(e.to_string()))
        }
    }

    #[cfg(test)]
    mod tests {
        use super::super::{
            LockedStore, MasterKeyStore as _, is_valid_master_key, load_or_create_master_key,
        };
        use super::*;
        use windows::Win32::Security::Credentials::CredDeleteW;

        /// Deletes the test's credential when it drops, the test failed or not.
        struct Cleanup(Vec<u16>);

        impl Drop for Cleanup {
            fn drop(&mut self) {
                // SAFETY: the target is NUL-terminated and outlives the call.
                let _ = unsafe {
                    CredDeleteW(PCWSTR::from_raw(self.0.as_ptr()), CRED_TYPE_GENERIC, None)
                };
            }
        }

        #[test]
        fn the_master_key_round_trips_through_the_credential_manager() {
            let folder = tempfile::Builder::new()
                .prefix("conduit-credentials-")
                .tempdir()
                .expect("a temporary folder");
            // A service of this run's own: never a credential an earlier
            // run (or another test process) left.
            let store = LockedStore::new(
                CredentialManager::new(format!(
                    "app.example.conduit-test.{:016x}",
                    rand::random::<u64>()
                )),
                crate::paths::KeyLock::File(folder.path().join("master-key.lock")),
            );
            let cleanup = Cleanup(store.store.target());
            assert_eq!(store.load(), Ok(None));
            let key = load_or_create_master_key(&store).unwrap();
            assert!(is_valid_master_key(&key));
            assert_eq!(load_or_create_master_key(&store).unwrap(), key);
            // A second key is refused, never written over the first.
            assert_eq!(store.add(&super::super::new_master_key()), Ok(false));
            assert_eq!(store.load(), Ok(Some(key)));
            drop(cleanup);
            assert_eq!(store.load(), Ok(None));
        }
    }
}

#[cfg(target_os = "linux")]
pub use secret_service::SecretService;

#[cfg(target_os = "linux")]
mod secret_service {
    use super::{MASTER_KEY_ACCOUNT, ReplacingStore, SecretError};

    /// An item in the user's Secret Service (GNOME Keyring, KWallet), or in
    /// a Flatpak the portal's keyring file, labelled with the service and
    /// found by its `service` and `account` attributes. Unlocking can show
    /// the desktop's own prompt. With no Secret Service at all this fails
    /// as [`SecretError::Unavailable`], and the key goes to a file only if
    /// the user chooses that ([`super::KeyFile`]). A create-only item would
    /// be a second one beside it, so the app stores through a
    /// [`super::LockedStore`].
    pub struct SecretService {
        pub service: String,
    }

    impl SecretService {
        pub fn new(service: impl Into<String>) -> Self {
            Self {
                service: service.into(),
            }
        }

        fn attributes(&self) -> [(&str, &str); 2] {
            [("service", &self.service), ("account", MASTER_KEY_ACCOUNT)]
        }
    }

    /// The keyring's failure as a [`SecretError`]: `Unavailable` only when
    /// there is no Secret Service to ask ([`no_secret_service`]). A dismissed
    /// prompt (declining to create the default keyring among them), a locked
    /// or refusing keyring and every other failure are the keyring's own
    /// answer, `Store`: Retry asks it again, and the key file is not offered
    /// over a keyring that works.
    pub(super) fn keyring_error(e: oo7::Error) -> SecretError {
        if no_secret_service(&e) {
            SecretError::Unavailable(e.to_string())
        } else {
            SecretError::Store(e.to_string())
        }
    }

    /// The D-Bus errors that say nothing provides `org.freedesktop.secrets`.
    const SERVICE_MISSING: [&str; 2] = [
        "org.freedesktop.DBus.Error.ServiceUnknown",
        "org.freedesktop.DBus.Error.NameHasNoOwner",
    ];

    /// No session bus to reach (no address, no socket, nobody listening on
    /// it), or nothing on it provides the Secret Service.
    fn no_secret_service(e: &oo7::Error) -> bool {
        use oo7::zbus;
        let oo7::Error::DBus(e) = e else {
            return false;
        };
        let (oo7::dbus::Error::ZBus(wire)
        | oo7::dbus::Error::Service(oo7::dbus::ServiceError::ZBus(wire))) = e
        else {
            return false;
        };
        match wire {
            zbus::Error::Address(_) | zbus::Error::Connection(..) => true,
            zbus::Error::InputOutput(e) => matches!(
                e.kind(),
                std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
            ),
            zbus::Error::MethodError(name, ..) => SERVICE_MISSING.contains(&name.as_str()),
            zbus::Error::FDO(e) => matches!(
                **e,
                zbus::fdo::Error::ServiceUnknown(_) | zbus::fdo::Error::NameHasNoOwner(_)
            ),
            _ => false,
        }
    }

    impl ReplacingStore for SecretService {
        fn load(&self) -> Result<Option<String>, SecretError> {
            futures_lite::future::block_on(async {
                let keyring = oo7::Keyring::new().await.map_err(keyring_error)?;
                keyring.unlock().await.map_err(keyring_error)?;
                let items = keyring
                    .search_items(&self.attributes())
                    .await
                    .map_err(keyring_error)?;
                let Some(item) = items.first() else {
                    return Ok(None);
                };
                item.unlock().await.map_err(keyring_error)?;
                let secret = item.secret().await.map_err(keyring_error)?;
                String::from_utf8(secret.to_vec())
                    .map(Some)
                    .map_err(|_| SecretError::Corrupt)
            })
        }

        fn replace(&self, key: &str) -> Result<(), SecretError> {
            futures_lite::future::block_on(async {
                let keyring = oo7::Keyring::new().await.map_err(keyring_error)?;
                keyring.unlock().await.map_err(keyring_error)?;
                keyring
                    .create_item(&self.service, &self.attributes(), key, true)
                    .await
                    .map_err(keyring_error)
            })
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use oo7::dbus::{Error as DBus, ServiceError};
        use oo7::zbus;

        fn kind(e: SecretError) -> &'static str {
            match e {
                SecretError::Unavailable(_) => "unavailable",
                SecretError::Store(_) => "store",
                SecretError::Corrupt => "corrupt",
                SecretError::WouldPrompt | SecretError::Locked | SecretError::Missing(_) => {
                    "keychain"
                }
            }
        }

        fn method_error(name: &str) -> zbus::Error {
            let call = zbus::Message::method_call("/org/freedesktop/secrets", "OpenSession")
                .unwrap()
                .build(&())
                .unwrap();
            zbus::Error::MethodError(name.try_into().unwrap(), None, call)
        }

        fn io(kind: std::io::ErrorKind) -> zbus::Error {
            zbus::Error::InputOutput(std::sync::Arc::new(std::io::Error::from(kind)))
        }

        /// Only a missing bus or a missing service offers the key file;
        /// declining the "create the default keyring" prompt, a locked
        /// keyring and other failures keep Retry.
        #[test]
        fn only_a_missing_bus_or_service_counts_as_no_secret_service() {
            use std::io::ErrorKind;
            let wire = |e: zbus::Error| oo7::Error::DBus(DBus::ZBus(e));
            let service = |e: ServiceError| oo7::Error::DBus(DBus::Service(e));
            for (error, expected) in [
                // No session bus.
                (
                    wire(zbus::Error::Address("no address".into())),
                    "unavailable",
                ),
                (wire(io(ErrorKind::NotFound)), "unavailable"),
                (wire(io(ErrorKind::ConnectionRefused)), "unavailable"),
                // Nothing provides org.freedesktop.secrets.
                (
                    wire(method_error("org.freedesktop.DBus.Error.ServiceUnknown")),
                    "unavailable",
                ),
                (
                    service(ServiceError::ZBus(method_error(
                        "org.freedesktop.DBus.Error.NameHasNoOwner",
                    ))),
                    "unavailable",
                ),
                (
                    wire(zbus::Error::FDO(Box::new(
                        zbus::fdo::Error::ServiceUnknown("org.freedesktop.secrets".into()),
                    ))),
                    "unavailable",
                ),
                // The keyring answered.
                (oo7::Error::DBus(DBus::Dismissed), "store"),
                (oo7::Error::DBus(DBus::Deleted), "store"),
                (oo7::Error::DBus(DBus::NotFound("default".into())), "store"),
                (service(ServiceError::IsLocked("locked".into())), "store"),
                (service(ServiceError::NoSession("gone".into())), "store"),
                (wire(io(ErrorKind::PermissionDenied)), "store"),
                (
                    wire(method_error("org.freedesktop.DBus.Error.AccessDenied")),
                    "store",
                ),
                (
                    wire(zbus::Error::FDO(Box::new(zbus::fdo::Error::AccessDenied(
                        "no".into(),
                    )))),
                    "store",
                ),
                (wire(zbus::Error::InvalidReply), "store"),
                (
                    oo7::Error::DBus(DBus::IO(std::io::Error::other("disk"))),
                    "store",
                ),
            ] {
                let shown = error.to_string();
                assert_eq!(kind(keyring_error(error)), expected, "{shown}");
            }
        }
    }
}

/// The master key in a file only its user can read (mode 0600), for a Linux
/// desktop with no Secret Service, and only once the user chose it over
/// the warning that any program running as them can read it (D12).
/// Create-only, as every store is: a second key never replaces the first.
#[cfg(unix)]
pub struct KeyFile {
    pub path: std::path::PathBuf,
}

#[cfg(unix)]
impl KeyFile {
    pub fn new(path: impl Into<std::path::PathBuf>) -> Self {
        Self { path: path.into() }
    }

    /// Whether the user chose the key file before: it is there. One that
    /// can't be looked at (its folder unreadable) is an error, never "not
    /// chosen": a new key made instead would leave the data the old one
    /// protects unreadable.
    pub fn chosen(&self) -> Result<bool, SecretError> {
        self.path
            .try_exists()
            .map_err(|e| SecretError::Store(format!("{}: {e}", self.path.display())))
    }
}

#[cfg(unix)]
impl MasterKeyStore for KeyFile {
    fn load(&self) -> Result<Option<String>, SecretError> {
        use std::os::unix::fs::PermissionsExt as _;
        let failed =
            |e: std::io::Error| SecretError::Store(format!("{}: {e}", self.path.display()));
        check_folders_above(&self.path)?;
        let metadata = match std::fs::metadata(&self.path) {
            Ok(m) => m,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(failed(e)),
        };
        if metadata.permissions().mode() & 0o077 != 0 {
            return Err(SecretError::Store(format!(
                "{} can be read by other users",
                self.path.display()
            )));
        }
        let key = std::fs::read_to_string(&self.path).map_err(failed)?;
        // Before the key is used, its name and the folders above it are on
        // disk, however it was found: the launch that made it may have
        // failed its sync, or still be syncing, or a folder it made may not
        // have reached its parent. A sync of an entry already on disk is
        // cheap.
        sync_folders_above(&self.path).map_err(failed)?;
        Ok(Some(key))
    }

    /// The key goes to a file of its own first and is linked into place, so
    /// a crash never leaves a half-written key, and the link refuses a file
    /// that is already there. Success is reported only once the key, its
    /// name and every folder made for it are on disk: the daemon encrypts
    /// with the key next, and a key lost to a power cut after that would
    /// leave that data unreadable.
    fn add(&self, key: &str) -> Result<bool, SecretError> {
        use std::io::Write as _;
        use std::os::unix::fs::OpenOptionsExt as _;
        let failed =
            |e: std::io::Error| SecretError::Store(format!("{}: {e}", self.path.display()));
        let dir = parent_or_here(&self.path);
        make_folders_durably(dir).map_err(failed)?;
        // After making them, so one another user made first is caught too.
        check_folders_above(&self.path)?;
        let name = self.path.file_name().unwrap_or_default().to_string_lossy();
        let staged = dir.join(format!(".{name}.{:016x}", rand::random::<u64>()));
        let written = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&staged)
            .and_then(|mut file| {
                file.write_all(key.as_bytes())?;
                file.sync_all()
            })
            .and_then(|()| std::fs::hard_link(&staged, &self.path));
        let _ = std::fs::remove_file(&staged);
        match written {
            // The key's name and every folder above it, not only the ones
            // made now: a crashed earlier try may have made one unsynced.
            Ok(()) => sync_folders_above(&self.path)
                .map(|()| true)
                .map_err(failed),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Ok(false),
            Err(e) => Err(failed(e)),
        }
    }
}

/// Makes the folders missing on the way to `dir` (only their owner can open
/// them), each written into its parent before the next is made.
#[cfg(unix)]
fn make_folders_durably(dir: &std::path::Path) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt as _;
    let missing: Vec<&std::path::Path> = dir.ancestors().take_while(|d| !d.exists()).collect();
    for folder in missing.into_iter().rev() {
        match std::fs::DirBuilder::new().mode(0o700).create(folder) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
        sync_folder(parent_or_here(folder))?;
    }
    Ok(())
}

/// Writes the entries of every folder above `path` to disk, from its own
/// folder up. A folder this user can't open holds nothing made here, and a
/// filesystem that can't sync folders (EINVAL) is taken as it is.
#[cfg(unix)]
fn sync_folders_above(path: &std::path::Path) -> std::io::Result<()> {
    for folder in path.ancestors().skip(1) {
        if folder.as_os_str().is_empty() {
            break;
        }
        let dir = match std::fs::File::open(folder) {
            Ok(dir) => dir,
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => continue,
            Err(e) => return Err(e),
        };
        match dir.sync_all() {
            Err(e) if e.raw_os_error() != Some(libc::EINVAL) => return Err(e),
            _ => {}
        }
    }
    Ok(())
}

/// Writes `dir`'s entries (a new name in it) to disk.
#[cfg(unix)]
fn sync_folder(dir: &std::path::Path) -> std::io::Result<()> {
    std::fs::File::open(dir)?.sync_all()
}

/// Refuses a key file under a folder another user could change, where they
/// could put their own key in its place or move this one: every folder
/// above it that is there must be this user's, or root's and closed to
/// others. Looked at as named (`symlink_metadata`), up to `/`.
#[cfg(unix)]
fn check_folders_above(path: &std::path::Path) -> Result<(), SecretError> {
    use std::os::unix::fs::MetadataExt as _;
    // SAFETY: geteuid has no preconditions and cannot fail.
    let me = unsafe { libc::geteuid() };
    for folder in path.ancestors().skip(1) {
        if folder.as_os_str().is_empty() {
            break;
        }
        let metadata = match std::fs::symlink_metadata(folder) {
            Ok(metadata) => metadata,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(SecretError::Store(format!("{}: {e}", folder.display()))),
        };
        let link = metadata.file_type().is_symlink();
        if let Some(why) = untrusted(metadata.uid(), metadata.mode(), link, me) {
            return Err(SecretError::Store(format!(
                "{} {why}, so it can't hold the key file {}",
                folder.display(),
                path.display()
            )));
        }
    }
    Ok(())
}

/// Why a folder (owned by `owner`, with `mode`) is no place above the key
/// file for user `me`, if it isn't. Another user's folder is refused
/// whatever its mode, as its owner can rename what is in it. Root's are
/// the system's, unless others can write to them without the sticky bit
/// (which keeps each entry in `/tmp` its owner's). A link is refused
/// unless it is root's, part of the system's layout (macOS's `/var`,
/// Fedora Atomic's `/home`).
#[cfg(unix)]
fn untrusted(owner: u32, mode: u32, link: bool, me: u32) -> Option<&'static str> {
    if link {
        return (owner != 0).then_some("is a link");
    }
    if owner == me {
        return None;
    }
    if owner != 0 {
        return Some("belongs to another user");
    }
    let open_to_others = mode & 0o022 != 0 && mode & 0o1000 == 0;
    open_to_others.then_some("can be changed by other users")
}

#[cfg(unix)]
fn parent_or_here(path: &std::path::Path) -> &std::path::Path {
    match path.parent() {
        Some(p) if !p.as_os_str().is_empty() => p,
        _ => std::path::Path::new("."),
    }
}

/// The Keychain through the `security` tool, for dev builds (see the module
/// docs). The key goes to the tool on stdin (`security -i`), never in argv.
/// A call that does not finish within `timeout` (a prompt nobody answers)
/// is killed and reported instead of hanging the launch.
pub struct SecurityCli {
    pub service: String,
    pub tool: std::path::PathBuf,
    pub timeout: std::time::Duration,
}

impl SecurityCli {
    pub fn new(service: impl Into<String>) -> Self {
        Self {
            service: service.into(),
            tool: "/usr/bin/security".into(),
            timeout: std::time::Duration::from_secs(15),
        }
    }

    fn run(
        &self,
        args: &[&str],
        stdin: Option<&str>,
    ) -> Result<(i32, String, String), SecretError> {
        use std::io::{Read as _, Write as _};
        use std::process::{Command, Stdio};
        let mut child = Command::new(&self.tool)
            .args(args)
            .stdin(if stdin.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| SecretError::Store(format!("{}: {e}", self.tool.display())))?;
        if let (Some(input), Some(mut pipe)) = (stdin, child.stdin.take()) {
            let _ = pipe.write_all(input.as_bytes());
        }
        let deadline = std::time::Instant::now() + self.timeout;
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break status,
                Ok(None) if std::time::Instant::now() < deadline => {
                    std::thread::sleep(std::time::Duration::from_millis(25));
                }
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(SecretError::Store(
                        "the Keychain did not answer (is a prompt waiting?)".into(),
                    ));
                }
            }
        };
        let mut out = String::new();
        let mut err = String::new();
        if let Some(mut o) = child.stdout.take() {
            let _ = o.read_to_string(&mut out);
        }
        if let Some(mut e) = child.stderr.take() {
            let _ = e.read_to_string(&mut err);
        }
        Ok((status.code().unwrap_or(-1), out, err))
    }
}

/// `security`'s exit code for "the specified item could not be found".
const SECURITY_ITEM_NOT_FOUND: i32 = 44;

impl MasterKeyStore for SecurityCli {
    fn load(&self) -> Result<Option<String>, SecretError> {
        let (code, out, err) = self.run(
            &[
                "find-generic-password",
                "-s",
                &self.service,
                "-a",
                MASTER_KEY_ACCOUNT,
                "-w",
            ],
            None,
        )?;
        match code {
            0 => Ok(Some(out.trim().to_string())),
            SECURITY_ITEM_NOT_FOUND => Ok(None),
            _ => Err(SecretError::Store(format!(
                "security exited {code}: {}",
                err.trim()
            ))),
        }
    }

    fn add(&self, key: &str) -> Result<bool, SecretError> {
        // Interactive mode reads the command from stdin, keeping the key out
        // of every process's argv. Service, account and key are plain tokens
        // (no spaces or quotes). Without -U, `security` refuses to replace
        // an item that is already there.
        let command = format!(
            "add-generic-password -s {s} -a {a} -l {s} -w {key}\n",
            s = self.service,
            a = MASTER_KEY_ACCOUNT,
        );
        self.run(&["-i"], Some(&command))?;
        // `security -i` exits 0 whatever its commands did; read it back.
        match self.load()? {
            Some(stored) => Ok(stored == key),
            None => Err(SecretError::Store(
                "the Keychain did not keep the key".into(),
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[test]
    fn session_token_shape() {
        let t = new_session_token();
        assert_eq!(t.len(), 43);
        assert!(
            t.chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        );
        assert_ne!(t, new_session_token());
    }

    #[test]
    fn subprotocol_matches_dart() {
        // buildSubprotocols('abc') == ['conduit.v1', 'tk.YWJj']
        assert_eq!(subprotocol_token("abc"), "tk.YWJj");
    }

    #[test]
    fn master_key_is_created_once() {
        let store = MemoryStore::default();
        let first = load_or_create_master_key(&store).unwrap();
        assert!(is_valid_master_key(&first));
        assert_eq!(load_or_create_master_key(&store).unwrap(), first);
    }

    #[cfg(unix)]
    #[test]
    fn the_security_cli_store_round_trips_through_a_fake_tool() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = tempfile::Builder::new()
            .prefix("conduit-seccli-")
            .tempdir()
            .expect("a temporary folder");
        let tool = dir.path().join("security");
        let store = dir.path().join("store.txt");
        // find-generic-password: print the stored key or exit 44;
        // -i: read "add-generic-password ... -w KEY" from stdin, and as
        // without -U, keep an item that is already there.
        let script = format!(
            "#!/bin/sh\nset -e\nif [ \"$1\" = \"-i\" ]; then\n  read -r cmd\n  case \"$*\" in *-w*) exit 9;; esac\n  [ -f '{s}' ] || echo \"$cmd\" | sed 's/.*-w //' > '{s}'\n  exit 0\nfi\nif [ -f '{s}' ]; then cat '{s}'; exit 0; fi\nexit 44\n",
            s = store.display()
        );
        std::fs::write(&tool, script).unwrap();
        std::fs::set_permissions(&tool, std::fs::Permissions::from_mode(0o755)).unwrap();
        let cli = SecurityCli {
            service: "app.example.test".into(),
            tool,
            timeout: std::time::Duration::from_secs(5),
        };
        assert_eq!(cli.load(), Ok(None));
        let key = load_or_create_master_key(&cli).unwrap();
        assert!(is_valid_master_key(&key));
        assert_eq!(std::fs::read_to_string(&store).unwrap().trim(), key);
        assert_eq!(load_or_create_master_key(&cli).unwrap(), key);
        // Another launch's key is refused, never written over this one.
        assert_eq!(cli.add(&new_master_key()), Ok(false));
        assert_eq!(cli.load(), Ok(Some(key)));
    }

    #[cfg(unix)]
    #[test]
    fn a_security_cli_that_hangs_is_reported() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = std::env::temp_dir().join(format!("conduit-seccli-hang-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let tool = dir.join("security");
        std::fs::write(&tool, "#!/bin/sh\nexec sleep 30\n").unwrap();
        std::fs::set_permissions(&tool, std::fs::Permissions::from_mode(0o755)).unwrap();
        let cli = SecurityCli {
            service: "x".into(),
            tool,
            timeout: std::time::Duration::from_millis(300),
        };
        assert!(matches!(cli.load(), Err(SecretError::Store(_))));
    }

    /// Two first launches at once both find no key and make one: the store
    /// keeps one of them and both use it. Two keys would leave the data one
    /// launch encrypted under a key nobody has.
    #[test]
    fn two_first_launches_end_with_one_key() {
        struct Racing {
            inner: MemoryStore,
            first_loads: std::sync::atomic::AtomicUsize,
            both_loaded: std::sync::Barrier,
        }
        impl MasterKeyStore for Racing {
            fn load(&self) -> Result<Option<String>, SecretError> {
                use std::sync::atomic::Ordering;
                let found = self.inner.load();
                // Neither writes before both have looked.
                if self.first_loads.fetch_add(1, Ordering::SeqCst) < 2 {
                    self.both_loaded.wait();
                }
                found
            }
            fn add(&self, key: &str) -> Result<bool, SecretError> {
                self.inner.add(key)
            }
        }
        let store = Racing {
            inner: MemoryStore::default(),
            first_loads: Default::default(),
            both_loaded: std::sync::Barrier::new(2),
        };
        let (a, b) = std::thread::scope(|s| {
            let a = s.spawn(|| load_or_create_master_key(&store));
            let b = s.spawn(|| load_or_create_master_key(&store));
            (a.join().unwrap().unwrap(), b.join().unwrap().unwrap())
        });
        assert_eq!(a, b, "both launches use one key");
        assert_eq!(store.inner.load().unwrap(), Some(a));
    }

    /// Two first launches on one service with different profiles: the key
    /// is the service's (as the Keychain item is on the Mac), so the second
    /// launch's lock is held while the first writes, and both use one key.
    #[test]
    fn launches_with_different_profiles_take_turns_on_the_services_key() {
        use crate::paths::tests::vars;
        use crate::paths::{Host as _, KnownFolder, Os, System, master_key_lock};
        struct Shared {
            key: std::sync::Mutex<Option<String>>,
            other_lock: KeyLock,
            other_held_while_writing: std::sync::Mutex<Option<bool>>,
        }
        struct View<'a>(&'a Shared);
        impl ReplacingStore for View<'_> {
            fn load(&self) -> Result<Option<String>, SecretError> {
                Ok(self.0.key.lock().unwrap().clone())
            }
            fn replace(&self, key: &str) -> Result<(), SecretError> {
                // Held: the other launch's try finds it taken (not an error).
                let held = matches!(self.0.other_lock.try_hold(), Ok(None));
                *self.0.other_held_while_writing.lock().unwrap() = Some(held);
                *self.0.key.lock().unwrap() = Some(key.to_string());
                Ok(())
            }
        }
        let home = tempfile::Builder::new()
            .prefix("conduit-home-")
            .tempdir()
            .expect("a temporary folder");
        let (profile_a, profile_b) = (home.path().join("a"), home.path().join("b"));
        std::fs::create_dir_all(&profile_a).unwrap();
        std::fs::create_dir_all(&profile_b).unwrap();
        // A service of this run's own: on Linux the lock is a name every
        // process of this user shares.
        let service = format!("app.example.conduit-test.{:016x}", rand::random::<u64>());
        // One user's environment; each launch names its own profile.
        let lock = |profile: &std::path::Path| {
            let home = home.path().to_str().unwrap();
            let host = vars(&[
                ("HOME", home),
                ("LOCALAPPDATA", home),
                ("CONDUIT_USER_DATA", profile.to_str().unwrap()),
            ])
            .known(KnownFolder::LocalAppData, home)
            .uid(System.uid());
            master_key_lock(Os::CURRENT, &service, &host)
        };
        let shared = Shared {
            key: Default::default(),
            other_lock: lock(&profile_b),
            other_held_while_writing: Default::default(),
        };
        let first = LockedStore::new(View(&shared), lock(&profile_a));
        let second = LockedStore::new(View(&shared), lock(&profile_b));
        let key = load_or_create_master_key(&first).unwrap();
        assert_eq!(
            *shared.other_held_while_writing.lock().unwrap(),
            Some(true),
            "the other profile's launch waits for this write"
        );
        assert_eq!(load_or_create_master_key(&second).unwrap(), key);
    }

    #[cfg(unix)]
    #[test]
    fn the_key_file_is_this_users_alone_and_never_replaced() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = tempfile::Builder::new()
            .prefix("conduit-keyfile-")
            .tempdir()
            .expect("a temporary folder");
        let path = dir
            .path()
            .join("data")
            .join("app.example.conduit.master-key");
        let store = KeyFile::new(&path);
        assert_eq!(store.load(), Ok(None));
        let key = load_or_create_master_key(&store).unwrap();
        assert!(is_valid_master_key(&key));
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "only its user reads it");
        let folder = std::fs::metadata(path.parent().unwrap()).unwrap();
        assert_eq!(folder.permissions().mode() & 0o777, 0o700, "nor its folder");
        assert_eq!(load_or_create_master_key(&store).unwrap(), key);
        // Another launch's key is refused, never written over this one.
        assert_eq!(store.add(&new_master_key()), Ok(false));
        assert_eq!(store.load(), Ok(Some(key)));
        // Nothing but the key is left beside it.
        let names: Vec<_> = std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(
            names,
            [std::ffi::OsString::from("app.example.conduit.master-key")]
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_key_file_that_cant_be_looked_at_is_an_error_never_absent() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = tempfile::Builder::new()
            .prefix("conduit-keyfile-")
            .tempdir()
            .expect("a temporary folder");
        let folder = dir.path().join("share");
        std::fs::create_dir(&folder).unwrap();
        let store = KeyFile::new(folder.join("app.example.conduit.master-key"));
        assert_eq!(store.chosen(), Ok(false));
        load_or_create_master_key(&store).unwrap();
        assert_eq!(store.chosen(), Ok(true));
        // Root reads a folder whatever its permissions (a container's
        // tests): there is no denial to see.
        // SAFETY: geteuid has no preconditions and cannot fail.
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o000)).unwrap();
        let unreadable = store.chosen();
        std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(
            matches!(unreadable, Err(SecretError::Store(_))),
            "{unreadable:?}"
        );
    }

    /// A key file others can read (copied, restored from a backup, chmod
    /// by hand) is refused, never read: it is no longer the user's alone.
    #[cfg(unix)]
    #[test]
    fn a_key_file_others_can_read_is_refused() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = tempfile::Builder::new()
            .prefix("conduit-keyfile-")
            .tempdir()
            .expect("a temporary folder");
        let path = dir.path().join("app.example.conduit.master-key");
        std::fs::write(&path, new_master_key()).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(matches!(
            KeyFile::new(&path).load(),
            Err(SecretError::Store(_))
        ));
    }

    /// The key file is kept only under folders no other user can change:
    /// this user's, or root's when closed to others (sticky like `/tmp`
    /// counts as closed). Another user's folder or a link is refused, but
    /// root's links (macOS's `/var`) are the system's.
    #[cfg(unix)]
    #[test]
    fn only_folders_no_other_user_can_change_hold_the_key_file() {
        let me = 501;
        let other = 502;
        let ok = [
            (me, 0o40700, false),
            (me, 0o40777, false),
            (0, 0o40755, false),
            (0, 0o41777, false),
            (0, 0o120755, true),
        ];
        for (owner, mode, link) in ok {
            assert_eq!(untrusted(owner, mode, link, me), None, "{owner} {mode:o}");
        }
        let refused = [
            (other, 0o40755, false),
            (other, 0o40700, false),
            (other, 0o41777, false),
            (0, 0o40777, false),
            (0, 0o40775, false),
            (me, 0o120755, true),
            (other, 0o120755, true),
        ];
        for (owner, mode, link) in refused {
            assert!(
                untrusted(owner, mode, link, me).is_some(),
                "{owner} {mode:o}"
            );
        }
        // Root's own folders are root's.
        assert_eq!(untrusted(0, 0o40777, false, 0), None);
    }

    /// A key file under a link is neither made nor read: a link under
    /// this user's own folder, as no test can make another user's folder.
    #[cfg(unix)]
    #[test]
    fn a_key_file_under_a_link_is_refused() {
        let dir = tempfile::Builder::new()
            .prefix("conduit-keyfile-")
            .tempdir()
            .expect("a temporary folder");
        let real = dir.path().join("real");
        std::fs::create_dir(&real).unwrap();
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let name = "app.example.conduit.master-key";
        let linked = KeyFile::new(link.join("share").join(name));
        assert!(
            matches!(linked.add(&new_master_key()), Err(SecretError::Store(_))),
            "made under a link"
        );
        assert!(!real.join("share").join(name).exists());
        // The same folder, named without the link, holds it.
        let key = load_or_create_master_key(&KeyFile::new(real.join("share").join(name))).unwrap();
        assert!(is_valid_master_key(&key));
        assert!(
            matches!(linked.load(), Err(SecretError::Store(_))),
            "read through a link"
        );
        // A launch that finds it there gets an error, never that key or a
        // new one in the keyring.
        let lock = KeyLock::File(dir.path().join(format!("{name}.lock")));
        let keyring = Keyring::up(true);
        assert!(matches!(
            linux_master_key(&keyring, &linked, &lock, false),
            Err(SecretError::Store(_))
        ));
        assert_eq!(*keyring.key.lock().unwrap(), None);
    }

    /// Something that happens in the middle of a launch's first look at
    /// the keyring (another launch, the keyring coming back).
    #[cfg(unix)]
    type Meanwhile = Box<dyn FnOnce(&Keyring) + Send>;

    /// A Secret Service that is there or not, for tests.
    #[cfg(unix)]
    #[derive(Default)]
    struct Keyring {
        up: std::sync::atomic::AtomicBool,
        locked: bool,
        key: std::sync::Mutex<Option<String>>,
        meanwhile: std::sync::Mutex<Option<Meanwhile>>,
    }

    #[cfg(unix)]
    impl Keyring {
        fn up(up: bool) -> Self {
            let keyring = Self::default();
            keyring.set_up(up);
            keyring
        }
        fn set_up(&self, up: bool) {
            self.up.store(up, std::sync::atomic::Ordering::SeqCst);
        }
        fn answer(&self) -> Result<(), SecretError> {
            if !self.up.load(std::sync::atomic::Ordering::SeqCst) {
                return Err(SecretError::Unavailable("no session bus".into()));
            }
            if self.locked {
                return Err(SecretError::Store("the keyring is locked".into()));
            }
            Ok(())
        }
    }

    #[cfg(unix)]
    impl ReplacingStore for Keyring {
        fn load(&self) -> Result<Option<String>, SecretError> {
            let meanwhile = self.meanwhile.lock().unwrap().take();
            if let Some(meanwhile) = meanwhile {
                meanwhile(self);
            }
            self.answer()?;
            Ok(self.key.lock().unwrap().clone())
        }
        fn replace(&self, key: &str) -> Result<(), SecretError> {
            self.answer()?;
            *self.key.lock().unwrap() = Some(key.to_string());
            Ok(())
        }
    }

    /// A key file and its lock in a folder of their own.
    #[cfg(unix)]
    fn key_file_and_lock() -> (tempfile::TempDir, KeyFile, KeyLock) {
        let dir = tempfile::Builder::new()
            .prefix("conduit-keychoice-")
            .tempdir()
            .expect("a temporary folder");
        let file = KeyFile::new(
            dir.path()
                .join("share")
                .join("app.example.conduit.master-key"),
        );
        let lock = KeyLock::File(dir.path().join("app.example.conduit.master-key.lock"));
        (dir, file, lock)
    }

    /// The key file is made only when there is no Secret Service at all: a
    /// keyring that holds the key, has room for one, or is locked keeps it.
    #[cfg(unix)]
    #[test]
    fn the_key_file_never_replaces_a_secret_service_that_answers() {
        let (_dir, file, lock) = key_file_and_lock();
        let holding = Keyring::up(true);
        let keyring_key = new_master_key();
        *holding.key.lock().unwrap() = Some(keyring_key.clone());
        assert_eq!(
            linux_master_key(&holding, &file, &lock, true),
            Ok(keyring_key)
        );
        assert_eq!(
            file.chosen(),
            Ok(false),
            "no key file beside the keyring's key"
        );

        let empty = Keyring::up(true);
        let made = linux_master_key(&empty, &file, &lock, true).unwrap();
        assert_eq!(
            *empty.key.lock().unwrap(),
            Some(made),
            "made in the keyring"
        );
        assert_eq!(file.chosen(), Ok(false));

        let locked = Keyring {
            locked: true,
            ..Keyring::up(true)
        };
        assert_eq!(
            linux_master_key(&locked, &file, &lock, true),
            Err(SecretError::Store("the keyring is locked".into()))
        );
        assert_eq!(file.chosen(), Ok(false));

        // No keyring: an error at start-up, the file once the user chose it.
        let none = Keyring::up(false);
        assert!(matches!(
            linux_master_key(&none, &file, &lock, false),
            Err(SecretError::Unavailable(_))
        ));
        let from_file = linux_master_key(&none, &file, &lock, true).unwrap();
        assert_eq!(file.load(), Ok(Some(from_file)));
    }

    /// Two profiles of one user, both on the key-file screen with no
    /// keyring. The first chooses the key file; the keyring then starts and
    /// the second confirms its still-open warning. Both take the key the
    /// first saved, and both open with it at their next launch.
    #[cfg(unix)]
    #[test]
    fn two_profiles_that_choose_the_key_file_meet_on_one_key() {
        let (_dir, file, lock) = key_file_and_lock();
        let keyring = Keyring::up(false);
        assert!(linux_master_key(&keyring, &file, &lock, false).is_err());
        let first = linux_master_key(&keyring, &file, &lock, true).unwrap();
        keyring.set_up(true);
        let second = linux_master_key(&keyring, &file, &lock, true).unwrap();
        assert_eq!(second, first, "the second profile takes the key file's key");
        for profile in ["first", "second"] {
            assert_eq!(
                linux_master_key(&keyring, &file, &lock, false),
                Ok(first.clone()),
                "the {profile} profile's next launch"
            );
        }
        assert_eq!(
            *keyring.key.lock().unwrap(),
            None,
            "no second key in the keyring"
        );
    }

    /// A launch looks at the key file and the keyring, and makes its key,
    /// as one step under the service's lock. So no other launch can publish
    /// a key between this one finding none and making its own (the
    /// interleaving that left two first launches with one key each).
    #[cfg(unix)]
    #[test]
    fn no_launch_makes_a_key_while_another_is_choosing() {
        let (_dir, file, lock) = key_file_and_lock();
        let keyring = Keyring::up(true);
        let held_meanwhile = std::sync::Arc::new(std::sync::Mutex::new(None));
        {
            let (lock, held) = (lock.clone(), held_meanwhile.clone());
            *keyring.meanwhile.lock().unwrap() = Some(Box::new(move |_: &Keyring| {
                *held.lock().unwrap() = Some(matches!(lock.try_hold(), Ok(None)));
            }));
        }
        let key = linux_master_key(&keyring, &file, &lock, false).unwrap();
        assert_eq!(
            *held_meanwhile.lock().unwrap(),
            Some(true),
            "another launch could publish a key while this one chose"
        );
        assert_eq!(*keyring.key.lock().unwrap(), Some(key));
    }

    #[test]
    fn a_corrupt_key_is_never_replaced() {
        let store = MemoryStore(std::sync::Mutex::new(Some("short".into())));
        assert_eq!(load_or_create_master_key(&store), Err(SecretError::Corrupt));
        assert_eq!(store.load().unwrap().as_deref(), Some("short"));
    }

    /// How an item answers a read.
    #[derive(Clone, Copy, PartialEq)]
    enum Reads {
        /// This build stored it: no prompt.
        Freely,
        /// Another build stored it: macOS asks for the login keychain
        /// password.
        WithPrompt,
        /// A read that may not ask fails with a status the check doesn't
        /// know, and the usual read asks.
        FailsWithoutUi,
    }

    /// A Keychain service: one item per account.
    #[derive(Default)]
    struct FakeKeychain {
        items: std::sync::Mutex<BTreeMap<String, (String, Reads)>>,
        /// The accounts read with macOS's prompt, in order.
        prompted: std::sync::Mutex<Vec<String>>,
        /// An item another launch stores just before this one's next add.
        stored_first_elsewhere: std::sync::Mutex<Option<(String, String, Reads)>>,
        /// Start fresh's lock, and whether each add found it held.
        lock: Option<std::path::PathBuf>,
        lock_held_while_adding: std::sync::Mutex<Vec<bool>>,
        /// Runs once, right after the next add (the disk failing then).
        after_add: std::sync::Mutex<Option<Box<dyn FnOnce()>>>,
        /// The login keychain is locked; `unlocks`: whether the user
        /// unlocks it when asked; `unlock_asked`: how often they were.
        locked: std::sync::Mutex<bool>,
        unlocks: bool,
        unlock_asked: std::sync::Mutex<u32>,
    }

    impl FakeKeychain {
        fn with(items: &[(&str, &str, Reads)]) -> Self {
            let keychain = Self::default();
            for (account, key, reads) in items {
                keychain
                    .items
                    .lock()
                    .unwrap()
                    .insert(account.to_string(), (key.to_string(), *reads));
            }
            keychain
        }

        fn key(&self, account: &str) -> Option<String> {
            self.items
                .lock()
                .unwrap()
                .get(account)
                .map(|(k, _)| k.clone())
        }

        fn prompted(&self) -> Vec<String> {
            self.prompted.lock().unwrap().clone()
        }

        fn accounts(&self) -> Vec<String> {
            self.items.lock().unwrap().keys().cloned().collect()
        }
    }

    struct FakeItem<'a> {
        keychain: &'a FakeKeychain,
        account: String,
    }

    impl MasterKeyStore for FakeItem<'_> {
        fn load(&self) -> Result<Option<String>, SecretError> {
            let items = self.keychain.items.lock().unwrap();
            let Some((key, reads)) = items.get(&self.account) else {
                return Ok(None);
            };
            if *reads != Reads::Freely {
                self.keychain
                    .prompted
                    .lock()
                    .unwrap()
                    .push(self.account.clone());
            }
            Ok(Some(key.clone()))
        }

        fn load_without_asking(&self) -> Result<Option<String>, SecretError> {
            if *self.keychain.locked.lock().unwrap() {
                return Err(SecretError::Locked);
            }
            match self.keychain.items.lock().unwrap().get(&self.account) {
                None => Ok(None),
                Some((key, Reads::Freely)) => Ok(Some(key.clone())),
                Some((_, Reads::WithPrompt)) => Err(SecretError::WouldPrompt),
                Some((_, Reads::FailsWithoutUi)) => {
                    Err(SecretError::Store("an unknown status (-1)".into()))
                }
            }
        }

        fn unlock(&self) -> Result<(), SecretError> {
            *self.keychain.unlock_asked.lock().unwrap() += 1;
            if !self.keychain.unlocks {
                return Err(SecretError::Store("the user cancelled (-128)".into()));
            }
            *self.keychain.locked.lock().unwrap() = false;
            Ok(())
        }

        fn add(&self, key: &str) -> Result<bool, SecretError> {
            if let Some(lock) = &self.keychain.lock {
                let held = std::fs::OpenOptions::new()
                    .create(true)
                    .write(true)
                    .truncate(false)
                    .open(lock)
                    .is_ok_and(|file| {
                        matches!(file.try_lock(), Err(std::fs::TryLockError::WouldBlock))
                    });
                self.keychain
                    .lock_held_while_adding
                    .lock()
                    .unwrap()
                    .push(held);
            }
            let added = {
                let mut items = self.keychain.items.lock().unwrap();
                if let Some((account, other, reads)) =
                    self.keychain.stored_first_elsewhere.lock().unwrap().take()
                {
                    items.insert(account, (other, reads));
                }
                if items.contains_key(&self.account) {
                    false
                } else {
                    items.insert(self.account.clone(), (key.to_string(), Reads::Freely));
                    true
                }
            };
            if let Some(then) = self.keychain.after_add.lock().unwrap().take() {
                then();
            }
            Ok(added)
        }
    }

    impl MasterKeyItems for FakeKeychain {
        fn item(&self, account: &str) -> Box<dyn MasterKeyStore + '_> {
            Box::new(FakeItem {
                keychain: self,
                account: account.to_string(),
            })
        }
    }

    fn a_key() -> String {
        new_master_key()
    }

    fn default_profile() -> ProfileKey {
        ProfileKey {
            account: MASTER_KEY_ACCOUNT.into(),
            recorded: false,
        }
    }

    /// A profile folder with one file sealed under its old key.
    fn profile(root: &std::path::Path, name: &str) -> std::path::PathBuf {
        let user_data = root.join(name);
        std::fs::create_dir_all(user_data.join("db")).unwrap();
        std::fs::write(
            user_data.join("db/secure.sqlite"),
            b"sealed with the old key",
        )
        .unwrap();
        user_data
    }

    fn record(user_data: &std::path::Path, account: &str) {
        std::fs::write(key_account_file(user_data), account).unwrap();
    }

    fn fresh(
        keychain: &FakeKeychain,
        user_data: &std::path::Path,
        asked: &str,
        root: &std::path::Path,
    ) -> FreshStart {
        start_fresh(
            keychain,
            user_data,
            asked,
            &KeyLock::File(root.join("master-key.lock")),
            std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_800_000_000),
        )
    }

    /// A fresh start's key, and the account it recorded for the profile: a
    /// new one, holding that key.
    fn started(
        fresh: FreshStart,
        keychain: &FakeKeychain,
        user_data: &std::path::Path,
    ) -> (String, String, Option<std::path::PathBuf>) {
        let FreshStart::Started { key, moved_to } = fresh else {
            panic!("a fresh start, not {fresh:?}");
        };
        let profile = profile_key(user_data).unwrap();
        assert!(profile.recorded);
        assert_ne!(profile.account, MASTER_KEY_ACCOUNT);
        assert_eq!(keychain.key(&profile.account), Some(key.clone()));
        (key, profile.account, moved_to)
    }

    /// The folders a profile was moved aside to.
    fn moved_aside(root: &std::path::Path, name: &str) -> Vec<std::path::PathBuf> {
        let mut found: Vec<_> = std::fs::read_dir(root)
            .unwrap()
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.is_dir())
            .filter(|p| {
                p.file_name()
                    .is_some_and(|n| n.to_string_lossy().starts_with(&format!("{name} (reset ")))
            })
            .collect();
        found.sort();
        found
    }

    #[test]
    fn a_first_launch_makes_its_key_without_asking() {
        let keychain = FakeKeychain::default();
        let MasterKeyCheck::Ready(key) = check_master_key(&keychain, &default_profile()).unwrap()
        else {
            panic!("a first launch has nothing to ask about");
        };
        assert!(is_valid_master_key(&key));
        assert_eq!(keychain.key(MASTER_KEY_ACCOUNT), Some(key));
        assert!(keychain.prompted().is_empty());
    }

    #[test]
    fn a_key_this_build_stored_starts_the_app_without_asking() {
        let key = a_key();
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &key, Reads::Freely)]);
        assert_eq!(
            check_master_key(&keychain, &default_profile()),
            Ok(MasterKeyCheck::Ready(key))
        );
        assert!(keychain.prompted().is_empty());
    }

    /// The pre-release build's key: the app asks before macOS does, and
    /// nothing is read or written until the user chooses.
    #[test]
    fn a_key_another_build_stored_is_never_read_before_the_app_asks() {
        let old = a_key();
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &old, Reads::WithPrompt)]);
        assert_eq!(
            check_master_key(&keychain, &default_profile()),
            Ok(MasterKeyCheck::WouldPrompt)
        );
        assert!(keychain.prompted().is_empty(), "macOS never asked");
        assert_eq!(keychain.accounts(), [MASTER_KEY_ACCOUNT]);
        assert_eq!(keychain.key(MASTER_KEY_ACCOUNT), Some(old));
    }

    /// A locked login keychain over another build's key: macOS asks only to
    /// unlock it, then the read without a prompt finds the key would
    /// prompt, and the card shows. The item's own prompt never comes.
    #[test]
    fn a_locked_keychain_is_only_unlocked_then_another_builds_key_shows_the_card() {
        let mut keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &a_key(), Reads::WithPrompt)]);
        keychain.unlocks = true;
        *keychain.locked.lock().unwrap() = true;
        assert_eq!(
            check_master_key(&keychain, &default_profile()),
            Ok(MasterKeyCheck::WouldPrompt)
        );
        assert_eq!(*keychain.unlock_asked.lock().unwrap(), 1);
        assert!(keychain.prompted().is_empty(), "the item never asked");
    }

    /// A locked login keychain over this build's key: unlocked, then read.
    #[test]
    fn a_locked_keychain_over_this_builds_key_starts_once_unlocked() {
        let key = a_key();
        let mut keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &key, Reads::Freely)]);
        keychain.unlocks = true;
        *keychain.locked.lock().unwrap() = true;
        assert_eq!(
            check_master_key(&keychain, &default_profile()),
            Ok(MasterKeyCheck::Ready(key))
        );
        assert_eq!(*keychain.unlock_asked.lock().unwrap(), 1);
    }

    /// The user cancels the unlock: the keychain stays locked, and that is
    /// the error. Nothing reads the item with its own prompt.
    #[test]
    fn a_cancelled_unlock_is_reported_as_locked() {
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &a_key(), Reads::WithPrompt)]);
        *keychain.locked.lock().unwrap() = true;
        assert_eq!(
            check_master_key(&keychain, &default_profile()),
            Err(SecretError::Locked)
        );
        assert!(keychain.prompted().is_empty(), "the item never asked");
    }

    /// A relative profile path of one part (`CONDUIT_USER_DATA=Conduit`):
    /// its record's folder is the working folder, never the empty path.
    #[test]
    fn a_one_part_relative_profile_keeps_its_record_in_the_working_folder() {
        let dot = std::path::Path::new(".");
        assert_eq!(parent_dir(std::path::Path::new("Conduit")), dot);
        assert_eq!(
            parent_dir(&key_account_file(std::path::Path::new("Conduit"))),
            dot
        );
        assert_eq!(
            parent_dir(std::path::Path::new("Profiles/Conduit")),
            std::path::Path::new("Profiles")
        );
        assert_eq!(
            parent_dir(std::path::Path::new("/Profiles/Conduit")),
            std::path::Path::new("/Profiles")
        );
    }

    /// The folders a relative path is missing stop at the working folder,
    /// never the empty path, which can't be made.
    #[test]
    fn the_missing_folders_of_a_relative_path_stop_at_the_working_folder() {
        let first = format!("conduit-test-missing-{:016x}", rand::random::<u64>());
        let path = std::path::Path::new(&first).join("Profiles");
        assert_eq!(
            missing_folders(&path),
            [path.as_path(), std::path::Path::new(&first)]
        );
    }

    /// Two first launches: this one's add finds the other's key, which
    /// another build's signature guards. It is read without asking, and
    /// the app asks first, as at the start.
    #[test]
    fn losing_the_first_key_race_never_reads_with_the_prompt() {
        let keychain = FakeKeychain::default();
        *keychain.stored_first_elsewhere.lock().unwrap() =
            Some((MASTER_KEY_ACCOUNT.into(), a_key(), Reads::WithPrompt));
        assert_eq!(
            check_master_key(&keychain, &default_profile()),
            Ok(MasterKeyCheck::WouldPrompt)
        );
        assert!(keychain.prompted().is_empty(), "macOS never asked");
    }

    #[test]
    fn continue_reads_the_key_in_use_and_macos_asks_once() {
        let old = a_key();
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &old, Reads::WithPrompt)]);
        assert_eq!(read_master_key(&keychain, &default_profile()), Ok(old));
        assert_eq!(keychain.prompted(), [MASTER_KEY_ACCOUNT]);
    }

    /// A record that is there but can't be read (here a folder in its
    /// place) or names no account is reported: the default key would open
    /// the profile with the wrong one.
    #[test]
    fn a_record_that_cannot_be_read_is_reported_not_taken_for_the_default() {
        let root = tempfile::tempdir().unwrap();
        let unreadable = profile(root.path(), "Unreadable");
        std::fs::create_dir(key_account_file(&unreadable)).unwrap();
        assert!(matches!(
            profile_key(&unreadable),
            Err(SecretError::Store(_))
        ));
        let garbled = profile(root.path(), "Garbled");
        record(&garbled, "someone else\n");
        assert!(matches!(profile_key(&garbled), Err(SecretError::Store(_))));
        let none = profile(root.path(), "None");
        assert_eq!(profile_key(&none), Ok(default_profile()));
    }

    /// The key a profile records went from the Keychain: nothing is made in
    /// its place (a new key couldn't open what the old one sealed), at the
    /// start or on Continue.
    #[test]
    fn a_recorded_key_that_went_is_reported_and_never_replaced() {
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &a_key(), Reads::Freely)]);
        let recorded = ProfileKey {
            account: "masterKey.2".into(),
            recorded: true,
        };
        assert_eq!(
            check_master_key(&keychain, &recorded),
            Ok(MasterKeyCheck::Missing)
        );
        assert_eq!(
            read_master_key(&keychain, &recorded),
            Err(SecretError::Missing("masterKey.2".into()))
        );
        assert_eq!(keychain.accounts(), [MASTER_KEY_ACCOUNT]);
    }

    /// Start fresh never reads the old key (that read is what prompts) and
    /// never deletes it: it moves the profile aside, adds a key under a new
    /// account, and records that account for the fresh profile.
    #[test]
    fn start_fresh_keeps_the_old_item_and_records_a_new_key_in_the_fresh_profile() {
        let root = tempfile::tempdir().unwrap();
        let user_data = profile(root.path(), "Conduit");
        let old = a_key();
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &old, Reads::WithPrompt)]);
        let (key, account, moved_to) = started(
            fresh(&keychain, &user_data, MASTER_KEY_ACCOUNT, root.path()),
            &keychain,
            &user_data,
        );
        assert_eq!(keychain.key(MASTER_KEY_ACCOUNT), Some(old), "left alone");
        let moved_to = moved_to.expect("the profile was moved aside");
        assert_eq!(
            std::fs::read(moved_to.join("db/secure.sqlite")).unwrap(),
            b"sealed with the old key"
        );
        assert_eq!(
            profile_key(&moved_to),
            Ok(default_profile()),
            "the archive keeps the default"
        );
        assert!(!user_data.join("db").exists());
        let profile = profile_key(&user_data).unwrap();
        assert_eq!(profile.account, account);
        assert_eq!(
            check_master_key(&keychain, &profile),
            Ok(MasterKeyCheck::Ready(key))
        );
        assert!(keychain.prompted().is_empty(), "macOS never asked");
    }

    /// Profiles on one service: starting one fresh leaves the others on the
    /// key they were made with. A profile with no record (every profile
    /// before Start fresh) uses `masterKey`.
    #[test]
    fn each_profile_keeps_the_key_it_was_made_with() {
        let root = tempfile::tempdir().unwrap();
        let first = profile(root.path(), "First");
        let second = profile(root.path(), "Second");
        let old = a_key();
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &old, Reads::Freely)]);
        let (key, ..) = started(
            fresh(&keychain, &first, MASTER_KEY_ACCOUNT, root.path()),
            &keychain,
            &first,
        );
        assert_eq!(
            check_master_key(&keychain, &profile_key(&first).unwrap()),
            Ok(MasterKeyCheck::Ready(key))
        );
        assert_eq!(profile_key(&second), Ok(default_profile()));
        assert_eq!(
            check_master_key(&keychain, &profile_key(&second).unwrap()),
            Ok(MasterKeyCheck::Ready(old))
        );
    }

    /// Start fresh on a profile already on a later key, which another
    /// build stored: the archive keeps that key's account, so it can be
    /// opened again; the fresh profile gets a new one.
    #[test]
    fn start_fresh_again_keeps_the_old_account_with_the_archive() {
        let root = tempfile::tempdir().unwrap();
        let user_data = profile(root.path(), "Conduit");
        record(&user_data, "masterKey.2");
        let keychain = FakeKeychain::with(&[
            (MASTER_KEY_ACCOUNT, &a_key(), Reads::Freely),
            ("masterKey.2", &a_key(), Reads::WithPrompt),
        ]);
        assert_eq!(
            check_master_key(&keychain, &profile_key(&user_data).unwrap()),
            Ok(MasterKeyCheck::WouldPrompt)
        );
        let (_, account, moved_to) = started(
            fresh(&keychain, &user_data, "masterKey.2", root.path()),
            &keychain,
            &user_data,
        );
        assert!(account != "masterKey.2");
        let archive = moved_to.expect("the profile was moved aside");
        assert_eq!(
            profile_key(&archive),
            Ok(ProfileKey {
                account: "masterKey.2".into(),
                recorded: true
            })
        );
    }

    /// An account another profile records is never issued again, even with
    /// its item gone from the Keychain: that profile would find this one's
    /// key under its own record.
    #[test]
    fn start_fresh_never_takes_an_account_another_profile_records() {
        let root = tempfile::tempdir().unwrap();
        let other = profile(root.path(), "Other");
        record(&other, "masterKey.2");
        let user_data = profile(root.path(), "Conduit");
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &a_key(), Reads::WithPrompt)]);
        let (_, account, _) = started(
            fresh(&keychain, &user_data, MASTER_KEY_ACCOUNT, root.path()),
            &keychain,
            &user_data,
        );
        assert!(account != "masterKey.2");
    }

    /// Two launches showed the card for one profile and both chose Start
    /// fresh: the second finds the profile already fresh and takes its key.
    /// The profile is moved once, and no third key is made.
    #[test]
    fn a_second_start_fresh_takes_the_key_the_first_recorded() {
        let root = tempfile::tempdir().unwrap();
        let user_data = profile(root.path(), "Conduit");
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &a_key(), Reads::WithPrompt)]);
        let (key, ..) = started(
            fresh(&keychain, &user_data, MASTER_KEY_ACCOUNT, root.path()),
            &keychain,
            &user_data,
        );
        assert_eq!(
            fresh(&keychain, &user_data, MASTER_KEY_ACCOUNT, root.path()),
            FreshStart::AlreadyFresh(key)
        );
        assert_eq!(keychain.accounts().len(), 2);
        assert_eq!(moved_aside(root.path(), "Conduit").len(), 1);
        assert!(keychain.prompted().is_empty());
    }

    /// The disk fails after the key is stored: the record can't be written.
    /// The next Start fresh finishes recording that same key rather than
    /// making another.
    #[test]
    fn a_retry_after_the_record_failed_records_the_key_already_made() {
        let root = tempfile::tempdir().unwrap();
        let user_data = profile(root.path(), "Conduit");
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &a_key(), Reads::WithPrompt)]);
        let in_the_way = key_account_file(&user_data).join("in-the-way");
        let blocker = in_the_way.clone();
        *keychain.after_add.lock().unwrap() =
            Some(Box::new(move || std::fs::create_dir_all(&blocker).unwrap()));
        assert!(matches!(
            fresh(&keychain, &user_data, MASTER_KEY_ACCOUNT, root.path()),
            FreshStart::KeyFailed { .. }
        ));
        let made = keychain.accounts();
        assert_eq!(made.len(), 2, "one key made");
        std::fs::remove_dir_all(key_account_file(&user_data)).unwrap();
        let (key, account, _) = started(
            fresh(&keychain, &user_data, MASTER_KEY_ACCOUNT, root.path()),
            &keychain,
            &user_data,
        );
        assert_eq!(keychain.accounts(), made, "no second key");
        assert_eq!(keychain.key(&account), Some(key));
    }

    /// A profile whose folder can't even be looked at (its parent denies
    /// access) is a move that failed: nothing changes, no key is made.
    #[cfg(unix)]
    #[test]
    fn a_profile_that_cannot_be_reached_is_a_failed_move() {
        use std::os::unix::fs::PermissionsExt as _;
        let root = tempfile::tempdir().unwrap();
        let shut = root.path().join("shut");
        let user_data = profile(&shut, "Conduit");
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &a_key(), Reads::WithPrompt)]);
        std::fs::set_permissions(&shut, std::fs::Permissions::from_mode(0o000)).unwrap();
        let fresh = fresh(&keychain, &user_data, MASTER_KEY_ACCOUNT, root.path());
        std::fs::set_permissions(&shut, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(matches!(fresh, FreshStart::MoveFailed(_)), "{fresh:?}");
        assert_eq!(keychain.accounts(), [MASTER_KEY_ACCOUNT]);
        assert!(user_data.join("db/secure.sqlite").exists());
    }

    /// Reset and Clear Local Data move the folder as Start fresh does: the
    /// archive keeps the account its data was sealed with, and the fresh
    /// folder keeps the profile's. A profile on the default account leaves
    /// no record.
    #[test]
    fn both_resets_keep_the_account_beside_the_archive() {
        let root = tempfile::tempdir().unwrap();
        let now = std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_800_000_000);
        let user_data = profile(root.path(), "Conduit");
        record(&user_data, "masterKey.2");
        let recorded = ProfileKey {
            account: "masterKey.2".into(),
            recorded: true,
        };
        let archive = move_profile_aside(&user_data, now).unwrap();
        assert_eq!(profile_key(&archive), Ok(recorded.clone()));
        assert_eq!(profile_key(&user_data), Ok(recorded), "the fresh folder's");
        let legacy = profile(root.path(), "Legacy");
        let archive = move_profile_aside(&legacy, now).unwrap();
        assert_eq!(profile_key(&archive), Ok(default_profile()));
        assert!(!key_account_file(&archive).exists());
    }

    /// A move that fails (here the folder is immutable, so it can't be
    /// renamed) leaves no record beside the archive path it would have
    /// taken, and the profile where it was.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_move_that_fails_leaves_no_record_beside_the_archive() {
        let root = tempfile::tempdir().unwrap();
        let now = std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_800_000_000);
        let user_data = profile(root.path(), "Conduit");
        record(&user_data, "masterKey.2");
        let flag = |f: &str| {
            let set = std::process::Command::new("/usr/bin/chflags")
                .arg(f)
                .arg(&user_data)
                .status()
                .unwrap();
            assert!(set.success());
        };
        flag("uchg");
        let moved = move_profile_aside(&user_data, now);
        flag("nouchg");
        assert!(moved.is_err(), "{moved:?}");
        let records: Vec<_> = std::fs::read_dir(root.path())
            .unwrap()
            .filter_map(|e| e.ok().map(|e| e.file_name().to_string_lossy().to_string()))
            .filter(|n| n.ends_with(".master-key-account"))
            .collect();
        assert_eq!(records, ["Conduit.master-key-account"]);
        assert!(user_data.join("db/secure.sqlite").exists());
    }

    /// A pending account from an attempt that failed is reused only once its
    /// folder is on disk: where that sync fails (a folder that can't be
    /// read), no key is stored.
    #[cfg(unix)]
    #[test]
    fn a_pending_account_is_reused_only_once_its_folder_is_synced() {
        use std::os::unix::fs::PermissionsExt as _;
        let root = tempfile::tempdir().unwrap();
        let shut = root.path().join("shut");
        std::fs::create_dir(&shut).unwrap();
        let user_data = shut.join("Conduit");
        std::fs::write(
            shut.join("Conduit.master-key-account.pending"),
            "masterKey.0123456789abcdef",
        )
        .unwrap();
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &a_key(), Reads::WithPrompt)]);
        std::fs::set_permissions(&shut, std::fs::Permissions::from_mode(0o300)).unwrap();
        let fresh = fresh(&keychain, &user_data, MASTER_KEY_ACCOUNT, root.path());
        std::fs::set_permissions(&shut, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(matches!(fresh, FreshStart::KeyFailed { .. }), "{fresh:?}");
        assert_eq!(keychain.accounts(), [MASTER_KEY_ACCOUNT], "no key stored");
    }

    /// A profile another launch started fresh is taken up only once its
    /// record's folder is on disk; until then conduitd stays stopped, and a
    /// later try takes the same key.
    #[cfg(unix)]
    #[test]
    fn an_already_fresh_profile_is_taken_up_only_once_its_record_is_synced() {
        use std::os::unix::fs::PermissionsExt as _;
        let root = tempfile::tempdir().unwrap();
        let shut = root.path().join("shut");
        let user_data = profile(&shut, "Conduit");
        record(&user_data, "masterKey.2");
        let key = a_key();
        let keychain = FakeKeychain::with(&[
            (MASTER_KEY_ACCOUNT, &a_key(), Reads::WithPrompt),
            ("masterKey.2", &key, Reads::Freely),
        ]);
        std::fs::set_permissions(&shut, std::fs::Permissions::from_mode(0o300)).unwrap();
        let fresh_while_shut = fresh(&keychain, &user_data, MASTER_KEY_ACCOUNT, root.path());
        std::fs::set_permissions(&shut, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(
            matches!(fresh_while_shut, FreshStart::KeyFailed { .. }),
            "{fresh_while_shut:?}"
        );
        assert_eq!(
            fresh(&keychain, &user_data, MASTER_KEY_ACCOUNT, root.path()),
            FreshStart::AlreadyFresh(key)
        );
    }

    /// A new profile (`CONDUIT_USER_DATA` naming a folder whose parent isn't
    /// there yet) reaches the card through another profile's key: Start
    /// fresh makes the folders for its record, records its account, and
    /// starts.
    #[test]
    fn start_fresh_for_a_new_profile_makes_the_folders_for_its_record() {
        let root = tempfile::tempdir().unwrap();
        let user_data = root.path().join("not/made/yet/Conduit");
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &a_key(), Reads::WithPrompt)]);
        let (key, _, moved_to) = started(
            fresh(&keychain, &user_data, MASTER_KEY_ACCOUNT, root.path()),
            &keychain,
            &user_data,
        );
        assert_eq!(moved_to, None, "nothing to move");
        assert_eq!(
            check_master_key(&keychain, &profile_key(&user_data).unwrap()),
            Ok(MasterKeyCheck::Ready(key))
        );
    }

    /// Folders that can't be made fail Start fresh before it stores a key,
    /// so a retry never leaves an unused item behind.
    #[cfg(unix)]
    #[test]
    fn start_fresh_stores_no_key_where_its_record_cannot_go() {
        use std::os::unix::fs::PermissionsExt as _;
        let root = tempfile::tempdir().unwrap();
        let shut = root.path().join("shut");
        std::fs::create_dir(&shut).unwrap();
        std::fs::set_permissions(&shut, std::fs::Permissions::from_mode(0o555)).unwrap();
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &a_key(), Reads::WithPrompt)]);
        let fresh = fresh(
            &keychain,
            &shut.join("new/Conduit"),
            MASTER_KEY_ACCOUNT,
            root.path(),
        );
        std::fs::set_permissions(&shut, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(
            matches!(
                fresh,
                FreshStart::KeyFailed { .. } | FreshStart::MoveFailed(_)
            ),
            "{fresh:?}"
        );
        assert_eq!(keychain.accounts(), [MASTER_KEY_ACCOUNT]);
    }

    /// Start fresh picks and stores the account holding the service's lock,
    /// which every launch takes turns on.
    #[test]
    fn start_fresh_stores_its_key_holding_the_lock() {
        let root = tempfile::tempdir().unwrap();
        let user_data = profile(root.path(), "Conduit");
        let mut keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &a_key(), Reads::WithPrompt)]);
        keychain.lock = Some(root.path().join("master-key.lock"));
        assert!(matches!(
            fresh(&keychain, &user_data, MASTER_KEY_ACCOUNT, root.path()),
            FreshStart::Started { .. }
        ));
        assert_eq!(*keychain.lock_held_while_adding.lock().unwrap(), [true]);
    }

    /// Another failure of the read that may not ask is reported, and the
    /// key is never read with the prompt behind the user's back: on the
    /// first live check, such a fallback read raised macOS's dialog.
    #[test]
    fn another_failure_without_ui_is_reported_and_never_read_with_the_prompt() {
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &a_key(), Reads::FailsWithoutUi)]);
        assert!(matches!(
            check_master_key(&keychain, &default_profile()),
            Err(SecretError::Store(_))
        ));
        assert!(keychain.prompted().is_empty(), "macOS never asked");
    }

    #[test]
    fn a_corrupt_key_in_use_is_reported_and_kept() {
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, "short", Reads::Freely)]);
        assert_eq!(
            check_master_key(&keychain, &default_profile()),
            Err(SecretError::Corrupt)
        );
        assert_eq!(keychain.key(MASTER_KEY_ACCOUNT).as_deref(), Some("short"));
    }
}
