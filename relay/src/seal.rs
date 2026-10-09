//! Sealed endpoints (PROTOCOL §5).
//!
//! An endpoint carries everything the relay needs to deliver a push, sealed
//! under the relay's own key, so the relay can stay stateless:
//!
//! ```text
//! base64url(0x01 ‖ kid ‖ nonce24 ‖ XChaCha20-Poly1305(K[kid], nonce, "cp-relay/1" ‖ kid, json))
//! ```

use std::collections::BTreeMap;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chacha20poly1305::aead::{Aead, AeadCore, KeyInit, OsRng, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use serde::{Deserialize, Serialize};

pub const VERSION: u8 = 0x01;
const AAD_PREFIX: &[u8; 10] = b"cp-relay/1";
const NONCE_LEN: usize = 24;
const TAG_LEN: usize = 16;
/// Longer than any endpoint the relay issues (an FCM token is at most 4096).
pub const MAX_SEALED_LEN: usize = 8192;

/// The sealed JSON: `{"p", "e", "a", "s", "t", "i"}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Claims {
    /// Provider: `apns` or `fcm`.
    pub p: String,
    /// Environment: `prod` or `dev`.
    pub e: String,
    /// App: bundle id or package name.
    pub a: String,
    /// Subscription id.
    pub s: String,
    /// Device token.
    pub t: String,
    /// Issued at, Unix seconds.
    pub i: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum OpenError {
    /// Bad base64, unknown version, or failed authentication: answer 404.
    #[error("the endpoint cannot be opened")]
    NotFound,
    /// The key id is not one the relay holds any more: answer 410.
    #[error("the endpoint's key id is retired")]
    Retired,
}

pub struct Sealer {
    ciphers: BTreeMap<u8, XChaCha20Poly1305>,
    active: u8,
}

impl Sealer {
    /// `active` must be one of `keys`; the configuration checks this.
    pub fn new(keys: &BTreeMap<u8, [u8; 32]>, active: u8) -> Self {
        assert!(keys.contains_key(&active), "active key id has no key");
        let ciphers = keys
            .iter()
            .map(|(kid, key)| (*kid, XChaCha20Poly1305::new(key.into())))
            .collect();
        Self { ciphers, active }
    }

    pub fn active_kid(&self) -> u8 {
        self.active
    }

    pub fn seal(&self, claims: &Claims) -> String {
        let kid = self.active;
        let cipher = &self.ciphers[&kid];
        let nonce = XChaCha20Poly1305::generate_nonce(&mut OsRng);
        let json = serde_json::to_vec(claims).expect("claims always serialize");
        let sealed = cipher
            .encrypt(
                &nonce,
                Payload {
                    msg: &json,
                    aad: &aad(kid),
                },
            )
            .expect("encryption into a Vec cannot fail");

        let mut out = Vec::with_capacity(2 + NONCE_LEN + sealed.len());
        out.push(VERSION);
        out.push(kid);
        out.extend_from_slice(&nonce);
        out.extend_from_slice(&sealed);
        URL_SAFE_NO_PAD.encode(out)
    }

    pub fn open(&self, sealed: &str) -> Result<Claims, OpenError> {
        if sealed.len() > MAX_SEALED_LEN {
            return Err(OpenError::NotFound);
        }
        let raw = URL_SAFE_NO_PAD
            .decode(sealed)
            .map_err(|_| OpenError::NotFound)?;
        if raw.first() != Some(&VERSION) || raw.len() < 2 + NONCE_LEN + TAG_LEN {
            return Err(OpenError::NotFound);
        }
        let kid = raw[1];
        let cipher = self.ciphers.get(&kid).ok_or(OpenError::Retired)?;
        let (nonce, ciphertext) = raw[2..].split_at(NONCE_LEN);
        let json = cipher
            .decrypt(
                XNonce::from_slice(nonce),
                Payload {
                    msg: ciphertext,
                    aad: &aad(kid),
                },
            )
            .map_err(|_| OpenError::NotFound)?;
        serde_json::from_slice(&json).map_err(|_| OpenError::NotFound)
    }
}

fn aad(kid: u8) -> [u8; 11] {
    let mut aad = [0u8; 11];
    aad[..10].copy_from_slice(AAD_PREFIX);
    aad[10] = kid;
    aad
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keys(kids: &[u8]) -> BTreeMap<u8, [u8; 32]> {
        kids.iter().map(|&kid| (kid, [kid; 32])).collect()
    }

    fn claims() -> Claims {
        Claims {
            p: "apns".into(),
            e: "prod".into(),
            a: "app.cogwheel.conduit".into(),
            s: "QFvhBRA6vVgC_oPGR5mrpA".into(),
            t: "ab".repeat(32),
            i: 1_760_000_000,
        }
    }

    #[test]
    fn round_trip() {
        let sealer = Sealer::new(&keys(&[1]), 1);
        let sealed = sealer.seal(&claims());
        assert!(!sealed.contains('='));
        let raw = URL_SAFE_NO_PAD.decode(&sealed).unwrap();
        assert_eq!(raw[0], VERSION);
        assert_eq!(raw[1], 1);
        assert_eq!(sealer.open(&sealed), Ok(claims()));
        // Fresh nonce every time.
        assert_ne!(sealer.seal(&claims()), sealed);
    }

    #[test]
    fn sealed_json_has_protocol_field_order() {
        let json = serde_json::to_string(&claims()).unwrap();
        assert!(json.starts_with(r#"{"p":"apns","e":"prod","a":"#), "{json}");
    }

    #[test]
    fn opens_with_the_documented_construction() {
        // Built by hand from PROTOCOL §5, independently of `seal`.
        let key = [7u8; 32];
        let nonce = [9u8; 24];
        let json = serde_json::to_vec(&claims()).unwrap();
        let cipher = XChaCha20Poly1305::new((&key).into());
        let mut aad = b"cp-relay/1".to_vec();
        aad.push(3);
        let ct = cipher
            .encrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: &json,
                    aad: &aad,
                },
            )
            .unwrap();
        let mut raw = vec![0x01, 3];
        raw.extend_from_slice(&nonce);
        raw.extend_from_slice(&ct);

        let sealer = Sealer::new(&BTreeMap::from([(3, key)]), 3);
        assert_eq!(sealer.open(&URL_SAFE_NO_PAD.encode(raw)), Ok(claims()));
    }

    #[test]
    fn tampering_is_not_found() {
        let sealer = Sealer::new(&keys(&[1]), 1);
        let raw = URL_SAFE_NO_PAD.decode(sealer.seal(&claims())).unwrap();
        for i in [2, 20, 30, raw.len() - 1] {
            let mut bad = raw.clone();
            bad[i] ^= 0x01;
            assert_eq!(
                sealer.open(&URL_SAFE_NO_PAD.encode(&bad)),
                Err(OpenError::NotFound),
                "byte {i}"
            );
        }
    }

    #[test]
    fn kid_is_bound_into_the_aad() {
        // Same key under two ids: moving a ciphertext to the other id fails.
        let sealer = Sealer::new(&BTreeMap::from([(1, [5; 32]), (2, [5; 32])]), 1);
        let mut raw = URL_SAFE_NO_PAD.decode(sealer.seal(&claims())).unwrap();
        raw[1] = 2;
        assert_eq!(
            sealer.open(&URL_SAFE_NO_PAD.encode(raw)),
            Err(OpenError::NotFound)
        );
    }

    #[test]
    fn unknown_kid_is_retired() {
        let old = Sealer::new(&keys(&[1]), 1);
        let new = Sealer::new(&keys(&[2]), 2);
        assert_eq!(new.open(&old.seal(&claims())), Err(OpenError::Retired));
    }

    #[test]
    fn rotation_keeps_old_endpoints_working() {
        let before = Sealer::new(&keys(&[1]), 1);
        let after = Sealer::new(&keys(&[1, 2]), 2);
        assert_eq!(after.open(&before.seal(&claims())), Ok(claims()));
        let fresh = after.seal(&claims());
        assert_eq!(URL_SAFE_NO_PAD.decode(&fresh).unwrap()[1], 2);
        assert_eq!(before.open(&fresh), Err(OpenError::Retired));
    }

    #[test]
    fn malformed_input_is_not_found() {
        let sealer = Sealer::new(&keys(&[1]), 1);
        let good = sealer.seal(&claims());
        let mut wrong_version = URL_SAFE_NO_PAD.decode(&good).unwrap();
        wrong_version[0] = 0x02;
        let cases = [
            String::new(),
            "not base64!".into(),
            format!("{good}="),
            good[..good.len() - 1].replace(|c: char| c.is_ascii_digit(), "+"),
            URL_SAFE_NO_PAD.encode(wrong_version),
            URL_SAFE_NO_PAD.encode([0x01, 0x01]),
            URL_SAFE_NO_PAD.encode([0x01, 0x09]),
            "A".repeat(MAX_SEALED_LEN + 4),
        ];
        for case in cases {
            assert_eq!(sealer.open(&case), Err(OpenError::NotFound), "{case:.40}");
        }
    }
}
