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
//! `teamid:` partition.

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
}

impl std::fmt::Display for SecretError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Store(e) if cfg!(target_os = "macos") => write!(f, "keychain: {e}"),
            Self::Store(e) => write!(f, "secret store: {e}"),
            Self::Unavailable(e) => write!(f, "no secret store: {e}"),
            Self::Corrupt => f.write_str("the stored master key is not 32 bytes of base64"),
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
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(locked)?;
    }
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
pub use keychain::Keychain;

#[cfg(target_os = "macos")]
mod keychain {
    use super::{MASTER_KEY_ACCOUNT, MasterKeyStore, SecretError};
    use core_foundation::data::CFData;
    use security_framework::item::{ItemAddOptions, ItemAddValue, ItemClass};
    use security_framework::passwords::get_generic_password;

    /// `errSecItemNotFound`.
    const ITEM_NOT_FOUND: i32 = -25300;
    /// `errSecDuplicateItem`.
    const DUPLICATE_ITEM: i32 = -25299;

    /// A generic-password item: service = the flavour's, account
    /// [`MASTER_KEY_ACCOUNT`], default ACL (the signed app).
    pub struct Keychain {
        pub service: String,
    }

    impl Keychain {
        pub fn new(service: impl Into<String>) -> Self {
            Self {
                service: service.into(),
            }
        }
    }

    impl MasterKeyStore for Keychain {
        fn load(&self) -> Result<Option<String>, SecretError> {
            match get_generic_password(&self.service, MASTER_KEY_ACCOUNT) {
                Ok(bytes) => String::from_utf8(bytes)
                    .map(Some)
                    .map_err(|_| SecretError::Corrupt),
                Err(e) if e.code() == ITEM_NOT_FOUND => Ok(None),
                Err(e) => Err(SecretError::Store(format!("{} ({})", e, e.code()))),
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
                .set_account_name(MASTER_KEY_ACCOUNT);
            match options.add() {
                Ok(()) => Ok(true),
                Err(e) if e.code() == DUPLICATE_ITEM => Ok(false),
                Err(e) => Err(SecretError::Store(format!("{} ({})", e, e.code()))),
            }
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
}
