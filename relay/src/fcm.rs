//! Firebase Cloud Messaging, HTTP v1 API, with service-account OAuth.
//!
//! Messages are data-only, so the app's own receiver decrypts them and decides
//! what to show.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use jsonwebtoken::{Algorithm, EncodingKey, Header};
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE};
use serde::{Deserialize, Serialize};

use crate::config::FcmConfig;
use crate::{now_unix, Message, Outcome};

pub const SCOPE: &str = "https://www.googleapis.com/auth/firebase.messaging";
const GRANT_TYPE: &str = "urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer";
const ASSERTION_LIFETIME: u64 = 3600;
/// Access tokens are replaced this long before Google says they expire.
const EARLY_REFRESH: Duration = Duration::from_secs(5 * 60);

#[derive(Debug, thiserror::Error)]
pub enum FcmError {
    #[error("the FCM service account's private_key is not an RSA key")]
    BadKey,
    #[error("the HTTP client could not be built")]
    Client,
}

/// Why no access token could be had. Nothing here carries request data.
#[derive(Debug)]
struct TokenUnavailable;

pub struct Fcm {
    project_id: String,
    client_email: String,
    key: EncodingKey,
    token_uri: String,
    api_base: String,
    apps: Vec<String>,
    client: reqwest::Client,
    token: Mutex<Option<CachedToken>>,
    /// One refresh at a time; the others wait and reuse its result.
    refresh: tokio::sync::Mutex<()>,
}

struct CachedToken {
    access: Arc<str>,
    refresh_at: Instant,
}

#[derive(Serialize)]
struct AssertionClaims<'a> {
    iss: &'a str,
    scope: &'a str,
    aud: &'a str,
    iat: u64,
    exp: u64,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    #[serde(default = "default_expires_in")]
    expires_in: u64,
}

fn default_expires_in() -> u64 {
    3600
}

#[derive(Serialize)]
struct SendRequest<'a> {
    message: FcmMessage<'a>,
}

#[derive(Serialize)]
struct FcmMessage<'a> {
    token: &'a str,
    data: Data<'a>,
    android: Android,
}

#[derive(Serialize)]
struct Data<'a> {
    cp_v: &'static str,
    cp_s: &'a str,
    cp_d: &'a str,
}

/// No `collapse_key`, although the sender's `Topic` would fit: FCM keeps only
/// four collapse keys per device while it is offline, and every Conduit
/// message has a `Topic` of its own, so the phone would get back an arbitrary
/// four. Without one, FCM stores each message.
#[derive(Serialize)]
struct Android {
    priority: &'static str,
    ttl: String,
}

enum Attempt {
    Done(Outcome),
    Unauthorized,
}

impl Fcm {
    pub fn new(config: &FcmConfig) -> Result<Self, FcmError> {
        let key = EncodingKey::from_rsa_pem(config.private_key_pem.as_bytes())
            .map_err(|_| FcmError::BadKey)?;
        let fcm = Self {
            project_id: config.project_id.clone(),
            client_email: config.client_email.clone(),
            key,
            token_uri: config.token_uri.clone(),
            api_base: config.api_base.clone(),
            apps: config.apps.clone(),
            client: crate::http_client(false).map_err(|_| FcmError::Client)?,
            token: Mutex::new(None),
            refresh: tokio::sync::Mutex::new(()),
        };
        fcm.assertion().map_err(|_| FcmError::BadKey)?;
        Ok(fcm)
    }

    pub fn allows(&self, app: &str) -> bool {
        self.apps.iter().any(|a| a == app)
    }

    /// Whether an access token can be had, for `/readyz`.
    pub async fn check(&self) -> bool {
        self.access_token(None).await.is_ok()
    }

    fn assertion(&self) -> jsonwebtoken::errors::Result<String> {
        let iat = now_unix();
        let claims = AssertionClaims {
            iss: &self.client_email,
            scope: SCOPE,
            aud: &self.token_uri,
            iat,
            exp: iat + ASSERTION_LIFETIME,
        };
        jsonwebtoken::encode(&Header::new(Algorithm::RS256), &claims, &self.key)
    }

    fn cached(&self, stale: Option<&str>) -> Option<Arc<str>> {
        let cached = self.token.lock().unwrap_or_else(|e| e.into_inner());
        let token = cached.as_ref()?;
        let is_stale = stale.is_some_and(|s| *token.access == *s);
        (Instant::now() < token.refresh_at && !is_stale).then(|| token.access.clone())
    }

    /// The cached access token, fetched again near expiry or when it is
    /// `stale` (FCM answered 401 to it).
    async fn access_token(&self, stale: Option<&str>) -> Result<Arc<str>, TokenUnavailable> {
        if let Some(token) = self.cached(stale) {
            return Ok(token);
        }
        let _refreshing = self.refresh.lock().await;
        if let Some(token) = self.cached(stale) {
            return Ok(token);
        }
        let fetched = self.fetch_token().await?;
        let access: Arc<str> = fetched.access_token.into();
        // Google's tokens last an hour; never trust a longer answer.
        let lifetime = Duration::from_secs(fetched.expires_in.min(ASSERTION_LIFETIME))
            .saturating_sub(EARLY_REFRESH);
        *self.token.lock().unwrap_or_else(|e| e.into_inner()) = Some(CachedToken {
            access: access.clone(),
            refresh_at: Instant::now() + lifetime,
        });
        Ok(access)
    }

    async fn fetch_token(&self) -> Result<TokenResponse, TokenUnavailable> {
        let assertion = self.assertion().map_err(|_| {
            tracing::error!(provider = "fcm", "cannot sign an OAuth assertion");
            TokenUnavailable
        })?;
        let response = self
            .client
            .post(&self.token_uri)
            .header(CONTENT_TYPE, "application/x-www-form-urlencoded")
            .body(format!("grant_type={GRANT_TYPE}&assertion={assertion}"))
            .send()
            .await
            .map_err(|_| {
                tracing::warn!(
                    provider = "fcm",
                    category = "oauth_network",
                    "token endpoint unreachable"
                );
                TokenUnavailable
            })?;
        let status = response.status().as_u16();
        if status != 200 {
            tracing::warn!(
                provider = "fcm",
                category = "oauth",
                status,
                "token request refused"
            );
            return Err(TokenUnavailable);
        }
        response.json::<TokenResponse>().await.map_err(|_| {
            tracing::warn!(
                provider = "fcm",
                category = "oauth",
                status,
                "token response unreadable"
            );
            TokenUnavailable
        })
    }

    pub async fn send(&self, message: &Message<'_>) -> Outcome {
        let Ok(token) = self.access_token(None).await else {
            return Outcome::Unavailable;
        };
        match self.attempt(message, &token).await {
            Attempt::Done(outcome) => outcome,
            Attempt::Unauthorized => {
                let Ok(fresh) = self.access_token(Some(&token)).await else {
                    return Outcome::Unavailable;
                };
                match self.attempt(message, &fresh).await {
                    Attempt::Done(outcome) => outcome,
                    Attempt::Unauthorized => {
                        tracing::warn!(
                            provider = "fcm",
                            status = 401,
                            "access token rejected twice"
                        );
                        Outcome::Rejected
                    }
                }
            }
        }
    }

    async fn attempt(&self, message: &Message<'_>, token: &str) -> Attempt {
        let body = SendRequest {
            message: FcmMessage {
                token: message.token,
                data: Data {
                    cp_v: "1",
                    cp_s: message.sid,
                    cp_d: message.data,
                },
                android: Android {
                    priority: priority(message.meta.high_priority),
                    ttl: ttl(message.meta.ttl),
                },
            },
        };
        let response = match self
            .client
            .post(format!(
                "{}/v1/projects/{}/messages:send",
                self.api_base, self.project_id
            ))
            .header(AUTHORIZATION, format!("Bearer {token}"))
            .json(&body)
            .send()
            .await
        {
            Ok(response) => response,
            Err(_) => {
                tracing::warn!(provider = "fcm", category = "network", "FCM unreachable");
                return Attempt::Done(Outcome::Unavailable);
            }
        };
        let status = response.status().as_u16();
        if status == 401 {
            return Attempt::Unauthorized;
        }
        if (200..300).contains(&status) {
            return Attempt::Done(Outcome::Sent);
        }
        let body = response.bytes().await.unwrap_or_default();
        let error = parse_error(&body);
        let outcome = map_response(status, &error);
        if matches!(outcome, Outcome::Rejected | Outcome::Unavailable) {
            tracing::warn!(
                provider = "fcm",
                status,
                error = code_category(error.code.as_deref()),
                "FCM refused a push"
            );
        }
        Attempt::Done(outcome)
    }
}

/// FCM error codes are a fixed vocabulary; anything else is not logged as-is.
fn code_category(code: Option<&str>) -> &str {
    match code {
        Some(c) if c.len() <= 40 && c.bytes().all(|b| b.is_ascii_uppercase() || b == b'_') => c,
        Some(_) => "other",
        None => "none",
    }
}

/// `android.priority`.
pub fn priority(high: bool) -> &'static str {
    if high {
        "HIGH"
    } else {
        "NORMAL"
    }
}

/// `android.ttl`, a protobuf Duration string.
pub fn ttl(seconds: u64) -> String {
    format!("{seconds}s")
}

/// The parts of an FCM error the relay acts on.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct FcmErrorInfo {
    /// `error.status`, such as `INVALID_ARGUMENT`.
    pub status: Option<String>,
    /// The `FcmError` detail's `errorCode`, such as `UNREGISTERED`.
    pub code: Option<String>,
    /// Whether the message or a field violation is about the device token.
    pub about_token: bool,
}

#[derive(Deserialize)]
struct ErrorEnvelope {
    error: ErrorBody,
}

#[derive(Deserialize)]
struct ErrorBody {
    #[serde(default)]
    message: String,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    details: Vec<ErrorDetail>,
}

#[derive(Deserialize)]
struct ErrorDetail {
    #[serde(rename = "errorCode", default)]
    error_code: Option<String>,
    #[serde(rename = "fieldViolations", default)]
    field_violations: Vec<FieldViolation>,
}

#[derive(Deserialize)]
struct FieldViolation {
    #[serde(default)]
    field: String,
    #[serde(default)]
    description: String,
}

pub fn parse_error(body: &[u8]) -> FcmErrorInfo {
    let Ok(ErrorEnvelope { error }) = serde_json::from_slice::<ErrorEnvelope>(body) else {
        return FcmErrorInfo::default();
    };
    let mentions_token = |text: &str| text.to_ascii_lowercase().contains("registration token");
    let about_token = mentions_token(&error.message)
        || error.details.iter().any(|d| {
            d.field_violations.iter().any(|v| {
                v.field == "message.token"
                    || mentions_token(&v.field)
                    || mentions_token(&v.description)
            })
        });
    FcmErrorInfo {
        status: error.status,
        code: error.details.into_iter().find_map(|d| d.error_code),
        about_token,
    }
}

/// Maps an FCM answer other than 401 (which refreshes the access token).
pub fn map_response(status: u16, error: &FcmErrorInfo) -> Outcome {
    let code = error.code.as_deref();
    let invalid_argument =
        error.status.as_deref() == Some("INVALID_ARGUMENT") || code == Some("INVALID_ARGUMENT");
    match status {
        200..=299 => Outcome::Sent,
        404 => Outcome::Gone,
        _ if code == Some("UNREGISTERED") => Outcome::Gone,
        403 if code == Some("SENDER_ID_MISMATCH") => Outcome::Gone,
        400 if invalid_argument && error.about_token => Outcome::Gone,
        429 => Outcome::Throttled,
        500..=599 => Outcome::Unavailable,
        _ => Outcome::Rejected,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn error(status: &str, code: Option<&str>, message: &str) -> Vec<u8> {
        let details = match code {
            Some(code) => format!(
                r#"[{{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError","errorCode":"{code}"}}]"#
            ),
            None => "[]".into(),
        };
        format!(r#"{{"error":{{"code":400,"message":"{message}","status":"{status}","details":{details}}}}}"#)
            .into_bytes()
    }

    #[test]
    fn urgency_and_ttl_map_to_android_fields() {
        assert_eq!(priority(true), "HIGH");
        assert_eq!(priority(false), "NORMAL");
        assert_eq!(ttl(0), "0s");
        assert_eq!(ttl(86400), "86400s");
    }

    #[test]
    fn codes_are_logged_only_when_they_look_like_codes() {
        assert_eq!(
            code_category(Some("SENDER_ID_MISMATCH")),
            "SENDER_ID_MISMATCH"
        );
        assert_eq!(code_category(Some("token abc:def")), "other");
        assert_eq!(code_category(None), "none");
    }

    #[test]
    fn errors_parse() {
        let info = parse_error(&error(
            "NOT_FOUND",
            Some("UNREGISTERED"),
            "Requested entity was not found.",
        ));
        assert_eq!(info.code.as_deref(), Some("UNREGISTERED"));
        assert_eq!(info.status.as_deref(), Some("NOT_FOUND"));
        assert!(!info.about_token);

        let violation = br#"{"error":{"code":400,"message":"Request contains an invalid argument.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.BadRequest","fieldViolations":[{"field":"message.token","description":"Invalid registration token"}]}]}}"#;
        assert!(parse_error(violation).about_token);
        assert_eq!(parse_error(b"not json"), FcmErrorInfo::default());
        assert_eq!(parse_error(b""), FcmErrorInfo::default());
    }

    #[test]
    fn responses_map_to_relay_outcomes() {
        let token_msg = "The registration token is not a valid FCM registration token";
        let cases: [(u16, Vec<u8>, Outcome); 12] = [
            (200, b"{}".to_vec(), Outcome::Sent),
            (
                404,
                error("NOT_FOUND", Some("UNREGISTERED"), "gone"),
                Outcome::Gone,
            ),
            (404, Vec::new(), Outcome::Gone),
            (
                400,
                error("INVALID_ARGUMENT", Some("UNREGISTERED"), "gone"),
                Outcome::Gone,
            ),
            (
                403,
                error("PERMISSION_DENIED", Some("SENDER_ID_MISMATCH"), "x"),
                Outcome::Gone,
            ),
            (
                403,
                error("PERMISSION_DENIED", None, "no permission"),
                Outcome::Rejected,
            ),
            (
                400,
                error("INVALID_ARGUMENT", Some("INVALID_ARGUMENT"), token_msg),
                Outcome::Gone,
            ),
            (
                400,
                error("INVALID_ARGUMENT", Some("INVALID_ARGUMENT"), "Invalid TTL"),
                Outcome::Rejected,
            ),
            (400, Vec::new(), Outcome::Rejected),
            (
                429,
                error("RESOURCE_EXHAUSTED", Some("QUOTA_EXCEEDED"), "q"),
                Outcome::Throttled,
            ),
            (
                500,
                error("INTERNAL", Some("INTERNAL"), "x"),
                Outcome::Unavailable,
            ),
            (
                503,
                error("UNAVAILABLE", Some("UNAVAILABLE"), "x"),
                Outcome::Unavailable,
            ),
        ];
        for (status, body, expected) in cases {
            assert_eq!(
                map_response(status, &parse_error(&body)),
                expected,
                "{status} {}",
                String::from_utf8_lossy(&body)
            );
        }
    }

    #[test]
    fn send_request_matches_the_protocol() {
        let body = SendRequest {
            message: FcmMessage {
                token: "tok",
                data: Data {
                    cp_v: "1",
                    cp_s: "sid",
                    cp_d: "data",
                },
                android: Android {
                    priority: "HIGH",
                    ttl: ttl(60),
                },
            },
        };
        assert_eq!(
            serde_json::to_string(&body).unwrap(),
            r#"{"message":{"token":"tok","data":{"cp_v":"1","cp_s":"sid","cp_d":"data"},"android":{"priority":"HIGH","ttl":"60s"}}}"#
        );
    }
}
