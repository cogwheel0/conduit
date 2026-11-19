//! The two secrets the daemon is started with.
//!
//! * The **session token** authorizes every RPC and HTTP call. It is fresh on
//!   every launch (32 random bytes, base64url) and never stored.
//! * The **master key** encrypts the daemon's secure store. It is 32 random
//!   bytes (base64), created once and kept in the macOS Keychain under the
//!   flavour's service ([`crate::paths::Flavor::keychain_service`]).
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
}

impl std::fmt::Display for SecretError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Store(e) => write!(f, "keychain: {e}"),
            Self::Corrupt => f.write_str("the stored master key is not 32 bytes of base64"),
        }
    }
}

impl std::error::Error for SecretError {}

/// Where the master key lives.
pub trait MasterKeyStore {
    fn load(&self) -> Result<Option<String>, SecretError>;
    fn save(&self, key: &str) -> Result<(), SecretError>;
}

/// The stored master key, creating and storing one on first run.
pub fn load_or_create_master_key(store: &dyn MasterKeyStore) -> Result<String, SecretError> {
    if let Some(key) = store.load()? {
        let key = key.trim().to_string();
        return if is_valid_master_key(&key) {
            Ok(key)
        } else {
            Err(SecretError::Corrupt)
        };
    }
    let key = new_master_key();
    store.save(&key)?;
    Ok(key)
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
    fn save(&self, key: &str) -> Result<(), SecretError> {
        *self
            .0
            .lock()
            .map_err(|e| SecretError::Store(e.to_string()))? = Some(key.to_string());
        Ok(())
    }
}

#[cfg(target_os = "macos")]
pub use keychain::Keychain;

#[cfg(target_os = "macos")]
mod keychain {
    use super::{MASTER_KEY_ACCOUNT, MasterKeyStore, SecretError};
    use security_framework::passwords::{get_generic_password, set_generic_password};

    /// `errSecItemNotFound`.
    const ITEM_NOT_FOUND: i32 = -25300;

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

        fn save(&self, key: &str) -> Result<(), SecretError> {
            set_generic_password(&self.service, MASTER_KEY_ACCOUNT, key.as_bytes())
                .map_err(|e| SecretError::Store(format!("{} ({})", e, e.code())))
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

    fn save(&self, key: &str) -> Result<(), SecretError> {
        // Interactive mode reads the command from stdin, keeping the key out
        // of every process's argv. Service, account and key are plain tokens
        // (no spaces or quotes).
        let command = format!(
            "add-generic-password -s {s} -a {a} -l {s} -w {key}\n",
            s = self.service,
            a = MASTER_KEY_ACCOUNT,
        );
        self.run(&["-i"], Some(&command))?;
        // `security -i` exits 0 whatever its commands did; read it back.
        match self.load()? {
            Some(stored) if stored == key => Ok(()),
            _ => Err(SecretError::Store(
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
        let dir = std::env::temp_dir().join(format!("conduit-seccli-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let tool = dir.join("security");
        let store = dir.join("store.txt");
        // find-generic-password: print the stored key or exit 44;
        // -i: read "add-generic-password ... -w KEY" from stdin.
        let script = format!(
            "#!/bin/sh\nset -e\nif [ \"$1\" = \"-i\" ]; then\n  read -r cmd\n  case \"$*\" in *-w*) exit 9;; esac\n  echo \"$cmd\" | sed 's/.*-w //' > '{s}'\n  exit 0\nfi\nif [ -f '{s}' ]; then cat '{s}'; exit 0; fi\nexit 44\n",
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

    #[test]
    fn a_corrupt_key_is_never_replaced() {
        let store = MemoryStore(std::sync::Mutex::new(Some("short".into())));
        assert_eq!(load_or_create_master_key(&store), Err(SecretError::Corrupt));
        assert_eq!(store.load().unwrap().as_deref(), Some("short"));
    }
}
