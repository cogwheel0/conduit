//! Checks an incoming Web Push request (PROTOCOL §3 and §4).
//!
//! The relay holds no decryption key, so it checks only what it can see: the
//! headers, the padded size class, and the `aes128gcm` header block. Anything
//! that passes those checks is forwarded; the device does the rest.

use axum::http::header::CONTENT_ENCODING;
use axum::http::{HeaderMap, HeaderValue, StatusCode};

/// The three padded body sizes: 86-byte header plus 512, 1024 or 2048 bytes.
pub const BODY_SIZES: [usize; 3] = [598, 1110, 2134];
pub const MAX_BODY: usize = 2134;
/// 28 days, the most APNs and FCM will hold a message.
pub const MAX_TTL: u64 = 2_419_200;
/// `salt (16) ‖ rs (4) ‖ idlen (1)`; the key id follows.
const FIXED_HEADER_LEN: usize = 21;
const KEY_ID_LEN: u8 = 65;
const MIN_RECORD_SIZE: u32 = 18;
const MAX_TOPIC_LEN: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reject {
    /// `Content-Encoding` is not `aes128gcm`.
    UnsupportedEncoding,
    /// `TTL` is missing or not a non-negative integer.
    InvalidTtl,
    /// The body is over 2134 bytes.
    TooLarge,
    /// The body is not one of the padded sizes.
    Unpadded,
    /// The `aes128gcm` header is malformed.
    InvalidHeader,
}

impl Reject {
    pub fn status(self) -> StatusCode {
        match self {
            Self::UnsupportedEncoding => StatusCode::UNSUPPORTED_MEDIA_TYPE,
            Self::TooLarge => StatusCode::PAYLOAD_TOO_LARGE,
            Self::InvalidTtl | Self::Unpadded | Self::InvalidHeader => StatusCode::BAD_REQUEST,
        }
    }

    pub fn code(self) -> &'static str {
        match self {
            Self::UnsupportedEncoding => "unsupported_encoding",
            Self::InvalidTtl => "invalid_ttl",
            Self::TooLarge => "too_large",
            Self::Unpadded => "unpadded",
            Self::InvalidHeader => "invalid_header",
        }
    }
}

/// What the relay takes from the request headers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushMeta {
    /// Seconds, clamped to [`MAX_TTL`].
    pub ttl: u64,
    /// `Urgency: high`, or no `Urgency` at all.
    pub high_priority: bool,
    /// `Topic`, kept only when it is at most 64 URL-safe characters.
    pub topic: Option<String>,
}

pub fn check_headers(headers: &HeaderMap) -> Result<PushMeta, Reject> {
    let encoding = headers.get(CONTENT_ENCODING).and_then(|v| v.to_str().ok());
    if !encoding.is_some_and(|e| e.trim().eq_ignore_ascii_case("aes128gcm")) {
        return Err(Reject::UnsupportedEncoding);
    }
    Ok(PushMeta {
        ttl: parse_ttl(headers.get("ttl"))?,
        high_priority: is_high_urgency(headers.get("urgency")),
        topic: parse_topic(headers.get("topic")),
    })
}

pub fn parse_ttl(value: Option<&HeaderValue>) -> Result<u64, Reject> {
    let value = value
        .and_then(|v| v.to_str().ok())
        .map(str::trim)
        .ok_or(Reject::InvalidTtl)?;
    if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
        return Err(Reject::InvalidTtl);
    }
    // All digits, so the only way to fail is overflow: clamp that too.
    Ok(value.parse::<u64>().unwrap_or(u64::MAX).min(MAX_TTL))
}

pub fn is_high_urgency(value: Option<&HeaderValue>) -> bool {
    match value {
        None => true,
        Some(v) => v
            .to_str()
            .is_ok_and(|v| v.trim().eq_ignore_ascii_case("high")),
    }
}

pub fn parse_topic(value: Option<&HeaderValue>) -> Option<String> {
    let topic = value?.to_str().ok()?.trim();
    let url_safe = topic
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    (!topic.is_empty() && topic.len() <= MAX_TOPIC_LEN && url_safe).then(|| topic.to_owned())
}

/// Checks the size class and the `aes128gcm` header:
/// `salt (16) ‖ rs (4, BE) ‖ idlen (1) ‖ keyid (idlen) ‖ ciphertext`.
pub fn check_body(body: &[u8]) -> Result<(), Reject> {
    if body.len() > MAX_BODY {
        return Err(Reject::TooLarge);
    }
    if !BODY_SIZES.contains(&body.len()) {
        return Err(Reject::Unpadded);
    }
    let rs = u32::from_be_bytes([body[16], body[17], body[18], body[19]]);
    let idlen = body[20];
    if idlen != KEY_ID_LEN || rs < MIN_RECORD_SIZE {
        return Err(Reject::InvalidHeader);
    }
    // Exactly one record: the ciphertext must fit in the record size.
    let ciphertext_len = body.len() - FIXED_HEADER_LEN - usize::from(KEY_ID_LEN);
    if ciphertext_len as u64 > u64::from(rs) {
        return Err(Reject::InvalidHeader);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use base64::Engine;
    use serde_json::Value;

    fn vectors() -> Value {
        serde_json::from_str(include_str!("../../push/test-vectors/cp1_vectors.json")).unwrap()
    }

    fn b64(value: &Value) -> Vec<u8> {
        URL_SAFE_NO_PAD.decode(value.as_str().unwrap()).unwrap()
    }

    fn headers(pairs: &[(&'static str, &str)]) -> HeaderMap {
        let mut map = HeaderMap::new();
        for (name, value) in pairs {
            map.append(*name, HeaderValue::from_str(value).unwrap());
        }
        map
    }

    /// A body of any length with a valid `aes128gcm` header block and filler
    /// where the ciphertext goes.
    fn synthetic_body(len: usize) -> Vec<u8> {
        let mut body = vec![0xA5; len];
        body[16..20].copy_from_slice(&4096u32.to_be_bytes());
        body[20] = 65;
        body[21] = 0x04;
        body
    }

    #[test]
    fn every_vector_case_is_accepted() {
        let vectors = vectors();
        let cases = vectors["cases"].as_array().unwrap();
        assert!(!cases.is_empty());
        let mut sizes = Vec::new();
        for case in cases {
            let body = b64(&case["body"]);
            assert_eq!(check_body(&body), Ok(()), "{}", case["name"]);
            sizes.push(body.len());
        }
        for size in BODY_SIZES {
            assert!(sizes.contains(&size), "no {size}-byte case in {sizes:?}");
        }
    }

    #[test]
    fn header_level_rejects_are_rejected() {
        let vectors = vectors();
        let bodies = &vectors["reject"]["bodies"];
        assert_eq!(
            check_body(&b64(&bodies["keyid_not_65"])),
            Err(Reject::InvalidHeader)
        );
        assert_eq!(
            check_body(&b64(&bodies["record_size_too_small"])),
            Err(Reject::InvalidHeader)
        );
        assert_eq!(
            check_body(&b64(&bodies["too_large"])),
            Err(Reject::TooLarge)
        );
        assert_eq!(
            check_body(&b64(&bodies["truncated"])),
            Err(Reject::Unpadded)
        );
    }

    #[test]
    fn cryptographic_rejects_pass_through() {
        // Only the device can tell these apart from good bodies.
        let vectors = vectors();
        let bodies = &vectors["reject"]["bodies"];
        for name in ["wrong_auth", "not_last_record_delimiter", "flipped_tag_bit"] {
            assert_eq!(check_body(&b64(&bodies[name])), Ok(()), "{name}");
        }
    }

    #[test]
    fn size_classes_are_exact() {
        for len in [0, 85, 86, 597, 599, 1109, 1111, 2133] {
            assert_eq!(check_body(&vec![0; len]), Err(Reject::Unpadded), "{len}");
        }
        assert_eq!(check_body(&synthetic_body(2135)), Err(Reject::TooLarge));
        assert_eq!(check_body(&vec![0; 4096]), Err(Reject::TooLarge));
    }

    #[test]
    fn record_size_must_hold_the_whole_ciphertext() {
        // A 2134-byte body carries 2048 bytes of ciphertext.
        let mut body = synthetic_body(2134);
        body[16..20].copy_from_slice(&2048u32.to_be_bytes());
        assert_eq!(check_body(&body), Ok(()));
        body[16..20].copy_from_slice(&2047u32.to_be_bytes());
        assert_eq!(check_body(&body), Err(Reject::InvalidHeader));
        body[16..20].copy_from_slice(&18u32.to_be_bytes());
        assert_eq!(check_body(&body), Err(Reject::InvalidHeader));
    }

    #[test]
    fn content_encoding_must_be_aes128gcm() {
        let base = [("ttl", "60")];
        assert_eq!(
            check_headers(&headers(&base)),
            Err(Reject::UnsupportedEncoding)
        );
        for bad in ["aesgcm", "gzip", "aes128gcm, gzip", ""] {
            let mut h = headers(&base);
            h.insert(CONTENT_ENCODING, HeaderValue::from_str(bad).unwrap());
            assert_eq!(check_headers(&h), Err(Reject::UnsupportedEncoding), "{bad}");
        }
        let mut h = headers(&base);
        h.insert(CONTENT_ENCODING, HeaderValue::from_static("AES128GCM"));
        assert!(check_headers(&h).is_ok());
    }

    #[test]
    fn ttl_is_required_and_clamped() {
        let ttl = |v: &str| parse_ttl(Some(&HeaderValue::from_str(v).unwrap()));
        assert_eq!(parse_ttl(None), Err(Reject::InvalidTtl));
        assert_eq!(ttl("0"), Ok(0));
        assert_eq!(ttl("86400"), Ok(86400));
        assert_eq!(ttl(" 300 "), Ok(300));
        assert_eq!(ttl("2419200"), Ok(MAX_TTL));
        assert_eq!(ttl("2419201"), Ok(MAX_TTL));
        assert_eq!(ttl("99999999999999999999999999"), Ok(MAX_TTL));
        for bad in ["", "-1", "+5", "1.5", "1e3", "abc", "60s", "0x10"] {
            assert_eq!(ttl(bad), Err(Reject::InvalidTtl), "{bad:?}");
        }
    }

    #[test]
    fn urgency_maps_to_high_or_normal() {
        let urgent = |v: &str| is_high_urgency(Some(&HeaderValue::from_str(v).unwrap()));
        assert!(is_high_urgency(None));
        assert!(urgent("high"));
        assert!(urgent("HIGH"));
        assert!(!urgent("normal"));
        assert!(!urgent("low"));
        assert!(!urgent("very-low"));
        assert!(!urgent("whatever"));
    }

    #[test]
    fn topic_must_be_short_and_url_safe() {
        let topic = |v: &str| parse_topic(Some(&HeaderValue::from_str(v).unwrap()));
        assert_eq!(parse_topic(None), None);
        assert_eq!(
            topic("lIs5gmFDzleXLxWAvzVdVk").as_deref(),
            Some("lIs5gmFDzleXLxWAvzVdVk")
        );
        assert_eq!(topic(&"a".repeat(64)).map(|t| t.len()), Some(64));
        assert_eq!(topic(&"a".repeat(65)), None);
        assert_eq!(topic("has space"), None);
        assert_eq!(topic("slash/y"), None);
        assert_eq!(topic("plus+"), None);
        assert_eq!(topic(""), None);
    }

    #[test]
    fn full_header_check() {
        let h = headers(&[
            ("content-encoding", "aes128gcm"),
            ("ttl", "259200"),
            ("urgency", "normal"),
            ("topic", "abc_DEF-123"),
        ]);
        assert_eq!(
            check_headers(&h),
            Ok(PushMeta {
                ttl: 259200,
                high_priority: false,
                topic: Some("abc_DEF-123".into()),
            })
        );
        let h = headers(&[("content-encoding", "aes128gcm")]);
        assert_eq!(check_headers(&h), Err(Reject::InvalidTtl));
    }
}
