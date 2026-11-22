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
//! ([`profile_key_account`]): other profiles keep theirs.

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use rand::RngCore as _;

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
    /// A stored key is not base64 of 32 bytes. It is never overwritten: the
    /// secure store it protects would become unreadable for good.
    Corrupt,
    /// Reading the key needs the user's approval, and the read may not ask.
    WouldPrompt,
}

impl std::fmt::Display for SecretError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Store(e) if cfg!(target_os = "macos") => write!(f, "keychain: {e}"),
            Self::Store(e) => write!(f, "secret store: {e}"),
            Self::Corrupt => f.write_str("the stored master key is not 32 bytes of base64"),
            Self::WouldPrompt => f.write_str("reading the master key needs the user's approval"),
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
}

/// A service's master-key items, one per account (the macOS Keychain).
pub trait MasterKeyItems {
    /// The accounts that have an item, found without reading any key.
    fn accounts(&self) -> Result<Vec<String>, SecretError>;
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
}

/// The account of `user_data`'s key: the one Start fresh recorded for that
/// profile, else [`MASTER_KEY_ACCOUNT`] (every profile before it). Reads a
/// file, never the Keychain.
pub fn profile_key_account(user_data: &std::path::Path) -> String {
    recorded_account(user_data).unwrap_or_else(|| MASTER_KEY_ACCOUNT.to_string())
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

fn recorded_account(user_data: &std::path::Path) -> Option<String> {
    let text = std::fs::read_to_string(key_account_file(user_data)).ok()?;
    let account = text.trim();
    generation(account).map(|_| account.to_string())
}

/// The key under `account`, read without asking the user, or made on first
/// run. Any other failure of that read is reported, never followed by a
/// read that may prompt.
pub fn check_master_key(
    items: &dyn MasterKeyItems,
    account: &str,
) -> Result<MasterKeyCheck, SecretError> {
    let item = items.item(account);
    match item.load_without_asking() {
        Ok(Some(key)) => checked(key).map(MasterKeyCheck::Ready),
        Ok(None) => create_without_asking(item.as_ref()),
        Err(SecretError::WouldPrompt) => Ok(MasterKeyCheck::WouldPrompt),
        Err(e) => Err(e),
    }
}

/// Continue: the key under `account`, read even if macOS asks for it
/// (once, if the user answers "Always Allow").
pub fn read_master_key(items: &dyn MasterKeyItems, account: &str) -> Result<String, SecretError> {
    load_or_create_master_key(items.item(account).as_ref())
}

/// A new key stored in `store`, or the key another launch stored first,
/// read without asking.
fn create_without_asking(store: &dyn MasterKeyStore) -> Result<MasterKeyCheck, SecretError> {
    let key = new_master_key();
    if store.add(&key)? {
        return Ok(MasterKeyCheck::Ready(key));
    }
    match store.load_without_asking() {
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
    /// The profile could not be moved aside, and nothing changed.
    MoveFailed(String),
    /// The profile was moved aside (if it had a folder), but no key was
    /// stored and recorded for it.
    KeyFailed {
        error: SecretError,
        moved_to: Option<std::path::PathBuf>,
    },
}

/// Start fresh for the profile at `user_data`, whose key under `asked`
/// would prompt: its folder moved aside, then a key under the next account,
/// recorded for the profile. The old item is never read (that read is what
/// prompts) and never deleted (another build's item refuses this one's
/// delete anyway).
///
/// The folder moves first: a key made first would be the profile's from
/// then on, and a launch after a failed move would open the old folder
/// with it. It all happens holding `lock`, so a second launch that chose
/// Start fresh for the profile finds it recorded under another account and
/// takes that key.
pub fn start_fresh(
    items: &dyn MasterKeyItems,
    user_data: &std::path::Path,
    asked: &str,
    lock: &std::path::Path,
    now: std::time::SystemTime,
) -> FreshStart {
    exclusively(lock, || {
        Ok(fresh_holding_the_lock(items, user_data, asked, now))
    })
    .unwrap_or_else(|error| FreshStart::KeyFailed {
        error,
        moved_to: None,
    })
}

fn fresh_holding_the_lock(
    items: &dyn MasterKeyItems,
    user_data: &std::path::Path,
    asked: &str,
    now: std::time::SystemTime,
) -> FreshStart {
    if let Some(recorded) = recorded_account(user_data).filter(|a| a != asked) {
        let error = match items.item(&recorded).load_without_asking() {
            Ok(Some(key)) => match checked(key) {
                Ok(key) => return FreshStart::AlreadyFresh(key),
                Err(e) => e,
            },
            Ok(None) => SecretError::Store(format!("no key under {recorded}")),
            Err(e) => e,
        };
        return FreshStart::KeyFailed {
            error,
            moved_to: None,
        };
    }
    let moved_to = if user_data.exists() {
        match crate::paths::move_aside(user_data, now) {
            Ok(moved_to) => Some(moved_to),
            Err(e) => return FreshStart::MoveFailed(e.to_string()),
        }
    } else {
        None
    };
    match new_profile_key(items, user_data) {
        Ok(key) => FreshStart::Started { key, moved_to },
        Err(error) => FreshStart::KeyFailed { error, moved_to },
    }
}

/// A key under the next account, recorded for the profile.
/// The record's folders are made before the key is stored, so where the
/// record can't go no key is left unused.
fn new_profile_key(
    items: &dyn MasterKeyItems,
    user_data: &std::path::Path,
) -> Result<String, SecretError> {
    let file = key_account_file(user_data);
    let failed = |e: std::io::Error| SecretError::Store(format!("{}: {e}", file.display()));
    let dir = file.parent().unwrap_or(std::path::Path::new("."));
    make_record_folders(dir).map_err(failed)?;
    let account = generation_account(generation_in_use(&items.accounts()?).saturating_add(1));
    let key = match create_without_asking(items.item(&account).as_ref())? {
        MasterKeyCheck::Ready(key) => key,
        MasterKeyCheck::WouldPrompt => return Err(SecretError::WouldPrompt),
    };
    record_durably(&file, &account).map_err(failed)?;
    Ok(key)
}

/// Makes the folders missing on the way to `dir`, each one's entry on disk
/// in its parent before the next is made.
fn make_record_folders(dir: &std::path::Path) -> std::io::Result<()> {
    let missing: Vec<&std::path::Path> = dir.ancestors().take_while(|d| !d.exists()).collect();
    for folder in missing.into_iter().rev() {
        match std::fs::create_dir(folder) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
        sync_dir(folder.parent().unwrap_or(std::path::Path::new(".")))?;
    }
    Ok(())
}

/// Writes `account` to `file` through a file of its own, on disk before it
/// is renamed into place, so a crash leaves the old record or the new one:
/// the key it names is the profile's from the moment conduitd uses it.
fn record_durably(file: &std::path::Path, account: &str) -> std::io::Result<()> {
    use std::io::Write as _;
    let dir = file.parent().unwrap_or(std::path::Path::new("."));
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

/// Writes `dir`'s entries to disk. Windows opens no folder to sync it.
fn sync_dir(dir: &std::path::Path) -> std::io::Result<()> {
    if cfg!(unix) {
        std::fs::File::open(dir)?.sync_all()
    } else {
        Ok(())
    }
}

/// The latest generation among `accounts`: [`MASTER_KEY_ACCOUNT`] is the
/// first, `masterKey.2` the second, and so on. 0 when there is none.
fn generation_in_use(accounts: &[String]) -> u32 {
    accounts
        .iter()
        .filter_map(|account| generation(account))
        .max()
        .unwrap_or(0)
}

fn generation(account: &str) -> Option<u32> {
    if account == MASTER_KEY_ACCOUNT {
        return Some(1);
    }
    let n: u32 = account
        .strip_prefix(MASTER_KEY_ACCOUNT)?
        .strip_prefix('.')?
        .parse()
        .ok()?;
    (n >= 2 && generation_account(n) == account).then_some(n)
}

fn generation_account(n: u32) -> String {
    match n {
        0 | 1 => MASTER_KEY_ACCOUNT.to_string(),
        n => format!("{MASTER_KEY_ACCOUNT}.{n}"),
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

/// A [`ReplacingStore`] made create-only: it looks and writes holding
/// `lock`, which every launch using the same service shares whatever its
/// profile ([`crate::paths::master_key_lock`]). The key is the service's,
/// as the Keychain item is on the Mac.
pub struct LockedStore<S> {
    pub store: S,
    pub lock: std::path::PathBuf,
}

impl<S> LockedStore<S> {
    pub fn new(store: S, lock: impl Into<std::path::PathBuf>) -> Self {
        Self {
            store,
            lock: lock.into(),
        }
    }
}

impl<S: ReplacingStore> MasterKeyStore for LockedStore<S> {
    fn load(&self) -> Result<Option<String>, SecretError> {
        self.store.load()
    }

    fn add(&self, key: &str) -> Result<bool, SecretError> {
        exclusively(&self.lock, || {
            if self.store.load()?.is_some() {
                return Ok(false);
            }
            self.store.replace(key)?;
            Ok(true)
        })
    }
}

/// Runs `f` holding an exclusive lock on the file at `path` (made if
/// missing).
fn exclusively<T>(
    path: &std::path::Path,
    f: impl FnOnce() -> Result<T, SecretError>,
) -> Result<T, SecretError> {
    let locked = |e: std::io::Error| SecretError::Store(format!("{}: {e}", path.display()));
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(locked)?;
    }
    let file = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(path)
        .map_err(locked)?;
    // Released when `file` closes.
    file.lock().map_err(locked)?;
    f()
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
    use security_framework::item::{
        ItemAddOptions, ItemAddValue, ItemClass, ItemSearchOptions, Limit,
    };
    use security_framework::os::macos::keychain::SecKeychain;
    use security_framework::passwords::get_generic_password;

    /// `errSecItemNotFound`.
    const ITEM_NOT_FOUND: i32 = -25300;
    /// `errSecDuplicateItem`.
    const DUPLICATE_ITEM: i32 = -25299;
    /// A read with user interaction off that needs the user's approval:
    /// `errSecAuthFailed` for an item another build stored (measured on
    /// macOS 27, not the documented `errSecInteractionNotAllowed`), and
    /// `errSecInteractionNotAllowed` (a locked keychain).
    const NEEDS_APPROVAL: [i32; 2] = [-25293, -25308];

    fn store_error(e: Error) -> SecretError {
        SecretError::Store(format!("{} ({})", e, e.code()))
    }

    fn text(bytes: Option<Vec<u8>>) -> Result<Option<String>, SecretError> {
        bytes
            .map(|b| String::from_utf8(b).map_err(|_| SecretError::Corrupt))
            .transpose()
    }

    /// A generic-password item: the flavour's service, one account of the
    /// key's generations ([`super::check_master_key`]), default ACL (the
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

        fn load_without_asking(&self) -> Result<Option<String>, SecretError> {
            // Process-wide: user interaction is off for this one read only.
            let _no_ui = SecKeychain::disable_user_interaction().map_err(store_error)?;
            match self.read() {
                Err(e) if NEEDS_APPROVAL.contains(&e.code()) => Err(SecretError::WouldPrompt),
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
        /// Attributes only: an item's data is never read, so nothing asks.
        fn accounts(&self) -> Result<Vec<String>, SecretError> {
            let found = ItemSearchOptions::new()
                .class(ItemClass::generic_password())
                .service(&self.service)
                .load_attributes(true)
                .limit(Limit::All)
                .search();
            match found {
                Ok(items) => Ok(items
                    .iter()
                    .filter_map(|item| item.simplify_dict()?.remove("acct"))
                    .collect()),
                Err(e) if e.code() == ITEM_NOT_FOUND => Ok(vec![]),
                Err(e) => Err(store_error(e)),
            }
        }

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
                folder.path().join("master-key.lock"),
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
    /// the desktop's own prompt. With no Secret Service at all this fails,
    /// and the app says so: the key is never written to a plain file. A
    /// create-only item would be a second one beside it, so the app stores
    /// through a [`super::LockedStore`].
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

    fn store_error(e: oo7::Error) -> SecretError {
        SecretError::Store(e.to_string())
    }

    impl ReplacingStore for SecretService {
        fn load(&self) -> Result<Option<String>, SecretError> {
            futures_lite::future::block_on(async {
                let keyring = oo7::Keyring::new().await.map_err(store_error)?;
                keyring.unlock().await.map_err(store_error)?;
                let items = keyring
                    .search_items(&self.attributes())
                    .await
                    .map_err(store_error)?;
                let Some(item) = items.first() else {
                    return Ok(None);
                };
                item.unlock().await.map_err(store_error)?;
                let secret = item.secret().await.map_err(store_error)?;
                String::from_utf8(secret.to_vec())
                    .map(Some)
                    .map_err(|_| SecretError::Corrupt)
            })
        }

        fn replace(&self, key: &str) -> Result<(), SecretError> {
            futures_lite::future::block_on(async {
                let keyring = oo7::Keyring::new().await.map_err(store_error)?;
                keyring.unlock().await.map_err(store_error)?;
                keyring
                    .create_item(&self.service, &self.attributes(), key, true)
                    .await
                    .map_err(store_error)
            })
        }
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
        use crate::paths::{Os, master_key_lock};
        struct Shared {
            key: std::sync::Mutex<Option<String>>,
            other_lock: std::path::PathBuf,
            other_held_while_writing: std::sync::Mutex<Option<bool>>,
        }
        struct View<'a>(&'a Shared);
        impl ReplacingStore for View<'_> {
            fn load(&self) -> Result<Option<String>, SecretError> {
                Ok(self.0.key.lock().unwrap().clone())
            }
            fn replace(&self, key: &str) -> Result<(), SecretError> {
                let held = std::fs::OpenOptions::new()
                    .create(true)
                    .write(true)
                    .truncate(false)
                    .open(&self.0.other_lock)
                    .is_ok_and(|file| {
                        matches!(file.try_lock(), Err(std::fs::TryLockError::WouldBlock))
                    });
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
        // One user's environment; each launch names its own profile.
        let lock = |profile: &std::path::Path| {
            let (home, profile) = (home.path().to_path_buf(), profile.to_path_buf());
            master_key_lock(Os::CURRENT, "app.example.conduit", &move |key| match key {
                "HOME" | "LOCALAPPDATA" | "XDG_RUNTIME_DIR" => Some(home.clone().into()),
                "CONDUIT_USER_DATA" => Some(profile.clone().into()),
                _ => None,
            })
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
            match self.keychain.items.lock().unwrap().get(&self.account) {
                None => Ok(None),
                Some((key, Reads::Freely)) => Ok(Some(key.clone())),
                Some((_, Reads::WithPrompt)) => Err(SecretError::WouldPrompt),
                Some((_, Reads::FailsWithoutUi)) => {
                    Err(SecretError::Store("an unknown status (-1)".into()))
                }
            }
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
            let mut items = self.keychain.items.lock().unwrap();
            if let Some((account, other, reads)) =
                self.keychain.stored_first_elsewhere.lock().unwrap().take()
            {
                items.insert(account, (other, reads));
            }
            if items.contains_key(&self.account) {
                return Ok(false);
            }
            items.insert(self.account.clone(), (key.to_string(), Reads::Freely));
            Ok(true)
        }
    }

    impl MasterKeyItems for FakeKeychain {
        fn accounts(&self) -> Result<Vec<String>, SecretError> {
            Ok(self.items.lock().unwrap().keys().cloned().collect())
        }

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
            &root.join("master-key.lock"),
            std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_800_000_000),
        )
    }

    /// The folders a profile was moved aside to.
    fn moved_aside(root: &std::path::Path, name: &str) -> Vec<std::path::PathBuf> {
        let mut found: Vec<_> = std::fs::read_dir(root)
            .unwrap()
            .filter_map(|e| e.ok().map(|e| e.path()))
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
        let MasterKeyCheck::Ready(key) = check_master_key(&keychain, MASTER_KEY_ACCOUNT).unwrap()
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
            check_master_key(&keychain, MASTER_KEY_ACCOUNT),
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
            check_master_key(&keychain, MASTER_KEY_ACCOUNT),
            Ok(MasterKeyCheck::WouldPrompt)
        );
        assert!(keychain.prompted().is_empty(), "macOS never asked");
        assert_eq!(keychain.accounts().unwrap(), [MASTER_KEY_ACCOUNT]);
        assert_eq!(keychain.key(MASTER_KEY_ACCOUNT), Some(old));
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
            check_master_key(&keychain, MASTER_KEY_ACCOUNT),
            Ok(MasterKeyCheck::WouldPrompt)
        );
        assert!(keychain.prompted().is_empty(), "macOS never asked");
    }

    #[test]
    fn continue_reads_the_key_in_use_and_macos_asks_once() {
        let old = a_key();
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &old, Reads::WithPrompt)]);
        assert_eq!(read_master_key(&keychain, MASTER_KEY_ACCOUNT), Ok(old));
        assert_eq!(keychain.prompted(), [MASTER_KEY_ACCOUNT]);
    }

    /// Start fresh never reads the old key (that read is what prompts) and
    /// never deletes it: it moves the profile aside, adds a key under the
    /// next account, and records that account in the fresh profile.
    #[test]
    fn start_fresh_keeps_the_old_item_and_records_a_new_key_in_the_fresh_profile() {
        let root = tempfile::tempdir().unwrap();
        let user_data = profile(root.path(), "Conduit");
        let old = a_key();
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &old, Reads::WithPrompt)]);
        let FreshStart::Started { key, moved_to } =
            fresh(&keychain, &user_data, MASTER_KEY_ACCOUNT, root.path())
        else {
            panic!("a fresh start");
        };
        assert!(is_valid_master_key(&key));
        assert_eq!(keychain.key("masterKey.2"), Some(key.clone()));
        assert_eq!(keychain.key(MASTER_KEY_ACCOUNT), Some(old), "left alone");
        let moved_to = moved_to.expect("the profile was moved aside");
        assert_eq!(
            std::fs::read(moved_to.join("db/secure.sqlite")).unwrap(),
            b"sealed with the old key"
        );
        assert!(!user_data.join("db").exists());
        assert_eq!(profile_key_account(&user_data), "masterKey.2");
        assert_eq!(
            check_master_key(&keychain, &profile_key_account(&user_data)),
            Ok(MasterKeyCheck::Ready(key))
        );
        assert!(keychain.prompted().is_empty(), "macOS never asked");
    }

    /// Profiles on one service: starting one fresh leaves the others on the
    /// key they were made with. A profile with no record (every profile
    /// before Start fresh), or a record outside the scheme, uses
    /// `masterKey`.
    #[test]
    fn each_profile_keeps_the_key_it_was_made_with() {
        let root = tempfile::tempdir().unwrap();
        let first = profile(root.path(), "First");
        let second = profile(root.path(), "Second");
        let old = a_key();
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &old, Reads::Freely)]);
        let FreshStart::Started { key, .. } =
            fresh(&keychain, &first, MASTER_KEY_ACCOUNT, root.path())
        else {
            panic!("a fresh start");
        };
        assert_eq!(
            check_master_key(&keychain, &profile_key_account(&first)),
            Ok(MasterKeyCheck::Ready(key))
        );
        assert_eq!(profile_key_account(&second), MASTER_KEY_ACCOUNT);
        assert_eq!(
            check_master_key(&keychain, &profile_key_account(&second)),
            Ok(MasterKeyCheck::Ready(old))
        );
        std::fs::write(key_account_file(&second), "someone else\n").unwrap();
        assert_eq!(profile_key_account(&second), MASTER_KEY_ACCOUNT);
    }

    /// Start fresh again on a profile whose second-generation key another
    /// build stored: the third, whatever other profiles hold.
    #[test]
    fn start_fresh_again_takes_the_generation_after_the_latest() {
        let root = tempfile::tempdir().unwrap();
        let user_data = profile(root.path(), "Conduit");
        std::fs::write(key_account_file(&user_data), "masterKey.2").unwrap();
        let keychain = FakeKeychain::with(&[
            (MASTER_KEY_ACCOUNT, &a_key(), Reads::Freely),
            ("masterKey.2", &a_key(), Reads::WithPrompt),
        ]);
        assert_eq!(
            check_master_key(&keychain, &profile_key_account(&user_data)),
            Ok(MasterKeyCheck::WouldPrompt)
        );
        let FreshStart::Started { key, .. } =
            fresh(&keychain, &user_data, "masterKey.2", root.path())
        else {
            panic!("a fresh start");
        };
        assert_eq!(keychain.key("masterKey.3"), Some(key));
        assert_eq!(profile_key_account(&user_data), "masterKey.3");
    }

    /// Two launches showed the card for one profile and both chose Start
    /// fresh: the second finds the profile already fresh and takes its key.
    /// The profile is moved once, and no third key is made.
    #[test]
    fn a_second_start_fresh_takes_the_key_the_first_recorded() {
        let root = tempfile::tempdir().unwrap();
        let user_data = profile(root.path(), "Conduit");
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, &a_key(), Reads::WithPrompt)]);
        let FreshStart::Started { key, .. } =
            fresh(&keychain, &user_data, MASTER_KEY_ACCOUNT, root.path())
        else {
            panic!("a fresh start");
        };
        assert_eq!(
            fresh(&keychain, &user_data, MASTER_KEY_ACCOUNT, root.path()),
            FreshStart::AlreadyFresh(key)
        );
        assert_eq!(
            keychain.accounts().unwrap(),
            [MASTER_KEY_ACCOUNT, "masterKey.2"]
        );
        assert_eq!(moved_aside(root.path(), "Conduit").len(), 1);
        assert!(keychain.prompted().is_empty());
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
        let FreshStart::Started { key, moved_to } =
            fresh(&keychain, &user_data, MASTER_KEY_ACCOUNT, root.path())
        else {
            panic!("a fresh start");
        };
        assert_eq!(moved_to, None, "nothing to move");
        assert_eq!(keychain.key("masterKey.2"), Some(key.clone()));
        assert_eq!(profile_key_account(&user_data), "masterKey.2");
        assert_eq!(
            check_master_key(&keychain, &profile_key_account(&user_data)),
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
        assert!(matches!(fresh, FreshStart::KeyFailed { .. }), "{fresh:?}");
        assert_eq!(keychain.accounts().unwrap(), [MASTER_KEY_ACCOUNT]);
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
            check_master_key(&keychain, MASTER_KEY_ACCOUNT),
            Err(SecretError::Store(_))
        ));
        assert!(keychain.prompted().is_empty(), "macOS never asked");
    }

    #[test]
    fn a_corrupt_key_in_use_is_reported_and_kept() {
        let keychain = FakeKeychain::with(&[(MASTER_KEY_ACCOUNT, "short", Reads::Freely)]);
        assert_eq!(
            check_master_key(&keychain, MASTER_KEY_ACCOUNT),
            Err(SecretError::Corrupt)
        );
        assert_eq!(keychain.key(MASTER_KEY_ACCOUNT).as_deref(), Some("short"));
    }
}
