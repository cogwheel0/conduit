//! Apple Push Notification service, over HTTP/2 with token (`.p8`) auth.
//!
//! The push is an alert carrying a localized placeholder plus
//! `mutable-content`, so the Notification Service Extension can decrypt
//! `cp.d` and replace the placeholder before anything is shown.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use jsonwebtoken::{Algorithm, EncodingKey, Header};
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE};
use serde::{Deserialize, Serialize};

use crate::config::ApnsConfig;
use crate::{now_unix, Message, Outcome};

/// Apple accepts a provider token for an hour and rejects refreshes more
/// often than every 20 minutes.
const TOKEN_LIFETIME: Duration = Duration::from_secs(50 * 60);

#[derive(Debug, thiserror::Error)]
pub enum ApnsError {
    #[error("the APNs key is not a PKCS#8 EC private key (.p8)")]
    BadKey,
    #[error("the APNs key cannot sign a provider token")]
    CannotSign,
    #[error("the HTTP client could not be built")]
    Client,
}

pub struct Apns {
    team_id: String,
    key_id: String,
    key: EncodingKey,
    apps: Vec<String>,
    host_prod: String,
    host_dev: String,
    client: reqwest::Client,
    token: Mutex<Option<CachedToken>>,
}

struct CachedToken {
    jwt: Arc<str>,
    minted: Instant,
}

#[derive(Serialize)]
struct TokenClaims<'a> {
    iss: &'a str,
    iat: u64,
}

/// The APNs body, field for field as PROTOCOL §5 has it.
#[derive(Serialize)]
struct Payload<'a> {
    aps: Aps,
    cp: Cp<'a>,
}

#[derive(Serialize)]
struct Aps {
    alert: Alert,
    #[serde(rename = "mutable-content")]
    mutable_content: u8,
    sound: &'static str,
}

#[derive(Serialize)]
struct Alert {
    #[serde(rename = "title-loc-key")]
    title_loc_key: &'static str,
    #[serde(rename = "loc-key")]
    loc_key: &'static str,
}

#[derive(Serialize)]
struct Cp<'a> {
    v: u8,
    s: &'a str,
    d: &'a str,
}

#[derive(Deserialize)]
struct ErrorBody {
    #[serde(default)]
    reason: Option<String>,
}

enum Attempt {
    Done(Outcome),
    ExpiredToken,
}

impl Apns {
    pub fn new(config: &ApnsConfig) -> Result<Self, ApnsError> {
        let key =
            EncodingKey::from_ec_pem(config.key_pem.as_bytes()).map_err(|_| ApnsError::BadKey)?;
        let apns = Self {
            team_id: config.team_id.clone(),
            key_id: config.key_id.clone(),
            key,
            apps: config.apps.clone(),
            host_prod: config.host_prod.clone(),
            host_dev: config.host_dev.clone(),
            client: crate::http_client(true).map_err(|_| ApnsError::Client)?,
            token: Mutex::new(None),
        };
        // A key that parses but cannot sign should stop startup, not pushes.
        apns.provider_token(None)
            .map_err(|_| ApnsError::CannotSign)?;
        Ok(apns)
    }

    pub fn allows(&self, app: &str) -> bool {
        self.apps.iter().any(|a| a == app)
    }

    /// Whether a provider token can be had, for `/readyz`.
    pub fn check(&self) -> bool {
        self.provider_token(None).is_ok()
    }

    fn mint(&self) -> jsonwebtoken::errors::Result<String> {
        let mut header = Header::new(Algorithm::ES256);
        header.typ = None;
        header.kid = Some(self.key_id.clone());
        let claims = TokenClaims {
            iss: &self.team_id,
            iat: now_unix(),
        };
        jsonwebtoken::encode(&header, &claims, &self.key)
    }

    /// The cached provider token, minted again when it is 50 minutes old or
    /// when it is `stale` (Apple called it expired). Comparing with `stale`
    /// means many pushes failing at once refresh it only once.
    fn provider_token(&self, stale: Option<&str>) -> jsonwebtoken::errors::Result<Arc<str>> {
        let mut cached = self.token.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(token) = cached.as_ref() {
            let is_stale = stale.is_some_and(|s| *token.jwt == *s);
            if token.minted.elapsed() < TOKEN_LIFETIME && !is_stale {
                return Ok(token.jwt.clone());
            }
        }
        let jwt: Arc<str> = self.mint()?.into();
        *cached = Some(CachedToken {
            jwt: jwt.clone(),
            minted: Instant::now(),
        });
        Ok(jwt)
    }

    pub async fn send(&self, message: &Message<'_>) -> Outcome {
        let Ok(jwt) = self.provider_token(None) else {
            tracing::error!(provider = "apns", "cannot sign a provider token");
            return Outcome::Unavailable;
        };
        match self.attempt(message, &jwt).await {
            Attempt::Done(outcome) => outcome,
            Attempt::ExpiredToken => {
                let Ok(fresh) = self.provider_token(Some(&jwt)) else {
                    tracing::error!(provider = "apns", "cannot sign a provider token");
                    return Outcome::Unavailable;
                };
                match self.attempt(message, &fresh).await {
                    Attempt::Done(outcome) => outcome,
                    Attempt::ExpiredToken => {
                        tracing::warn!(
                            provider = "apns",
                            status = 403,
                            "provider token rejected twice; check the clock and key"
                        );
                        Outcome::Rejected
                    }
                }
            }
        }
    }

    async fn attempt(&self, message: &Message<'_>, jwt: &str) -> Attempt {
        let host = if message.sandbox {
            &self.host_dev
        } else {
            &self.host_prod
        };
        let payload = Payload {
            aps: Aps {
                alert: Alert {
                    title_loc_key: "push.fallback.title",
                    loc_key: "push.fallback.body",
                },
                mutable_content: 1,
                sound: "default",
            },
            cp: Cp {
                v: 1,
                s: message.sid,
                d: message.data,
            },
        };
        let mut request = self
            .client
            .post(format!("{host}/3/device/{}", message.token))
            .header(AUTHORIZATION, format!("bearer {jwt}"))
            .header(CONTENT_TYPE, "application/json")
            .header("apns-push-type", "alert")
            .header("apns-topic", message.app)
            .header("apns-priority", priority(message.meta.high_priority))
            .header(
                "apns-expiration",
                expiration(message.meta.ttl, now_unix()).to_string(),
            )
            .json(&payload);
        if let Some(topic) = &message.meta.topic {
            request = request.header("apns-collapse-id", topic);
        }

        // Never log the error itself: its URL holds the device token.
        let response = match request.send().await {
            Ok(response) => response,
            Err(_) => {
                tracing::warn!(provider = "apns", category = "network", "APNs unreachable");
                return Attempt::Done(Outcome::Unavailable);
            }
        };
        let status = response.status().as_u16();
        if status == 200 {
            return Attempt::Done(Outcome::Sent);
        }
        let reason = response
            .bytes()
            .await
            .ok()
            .and_then(|body| serde_json::from_slice::<ErrorBody>(&body).ok())
            .and_then(|body| body.reason);
        if status == 403 && reason.as_deref() == Some("ExpiredProviderToken") {
            return Attempt::ExpiredToken;
        }
        let outcome = map_response(status, reason.as_deref());
        if matches!(outcome, Outcome::Rejected | Outcome::Unavailable) {
            tracing::warn!(
                provider = "apns",
                status,
                reason = reason_category(reason.as_deref()),
                "APNs refused a push"
            );
        }
        Attempt::Done(outcome)
    }
}

/// `apns-priority`: 10 sends now; 5 lets the device save power.
pub fn priority(high: bool) -> &'static str {
    if high {
        "10"
    } else {
        "5"
    }
}

/// `apns-expiration`: when Apple stops retrying. 0 means try once, now.
pub fn expiration(ttl: u64, now: u64) -> u64 {
    if ttl == 0 {
        0
    } else {
        now.saturating_add(ttl)
    }
}

/// Maps an APNs answer other than `403 ExpiredProviderToken`.
pub fn map_response(status: u16, reason: Option<&str>) -> Outcome {
    match status {
        200 => Outcome::Sent,
        410 => Outcome::Gone,
        400 if matches!(reason, Some("BadDeviceToken" | "DeviceTokenNotForTopic")) => Outcome::Gone,
        413 => Outcome::TooLarge,
        429 => Outcome::Throttled,
        500..=599 => Outcome::Unavailable,
        _ => Outcome::Rejected,
    }
}

/// APNs reasons are a fixed vocabulary; anything else is not logged as-is.
fn reason_category(reason: Option<&str>) -> &str {
    match reason {
        Some(r) if r.len() <= 40 && r.bytes().all(|b| b.is_ascii_alphanumeric()) => r,
        Some(_) => "other",
        None => "none",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urgency_maps_to_priority() {
        assert_eq!(priority(true), "10");
        assert_eq!(priority(false), "5");
    }

    #[test]
    fn ttl_maps_to_expiration() {
        assert_eq!(expiration(0, 1_760_000_000), 0);
        assert_eq!(expiration(300, 1_760_000_000), 1_760_000_300);
        assert_eq!(expiration(2_419_200, 1_760_000_000), 1_762_419_200);
    }

    #[test]
    fn responses_map_to_relay_outcomes() {
        let cases = [
            (200, None, Outcome::Sent),
            (410, Some("Unregistered"), Outcome::Gone),
            (410, None, Outcome::Gone),
            (400, Some("BadDeviceToken"), Outcome::Gone),
            (400, Some("DeviceTokenNotForTopic"), Outcome::Gone),
            (400, Some("TopicDisallowed"), Outcome::Rejected),
            (400, Some("BadCollapseId"), Outcome::Rejected),
            (400, None, Outcome::Rejected),
            (403, Some("InvalidProviderToken"), Outcome::Rejected),
            (404, Some("BadPath"), Outcome::Rejected),
            (413, Some("PayloadTooLarge"), Outcome::TooLarge),
            (429, Some("TooManyRequests"), Outcome::Throttled),
            (500, Some("InternalServerError"), Outcome::Unavailable),
            (503, Some("ServiceUnavailable"), Outcome::Unavailable),
        ];
        for (status, reason, expected) in cases {
            assert_eq!(
                map_response(status, reason),
                expected,
                "{status} {reason:?}"
            );
        }
    }

    #[test]
    fn payload_matches_the_protocol() {
        let payload = Payload {
            aps: Aps {
                alert: Alert {
                    title_loc_key: "push.fallback.title",
                    loc_key: "push.fallback.body",
                },
                mutable_content: 1,
                sound: "default",
            },
            cp: Cp {
                v: 1,
                s: "sid",
                d: "data",
            },
        };
        assert_eq!(
            serde_json::to_string(&payload).unwrap(),
            r#"{"aps":{"alert":{"title-loc-key":"push.fallback.title","loc-key":"push.fallback.body"},"mutable-content":1,"sound":"default"},"cp":{"v":1,"s":"sid","d":"data"}}"#
        );
    }

    #[test]
    fn reasons_are_logged_only_when_they_look_like_reasons() {
        assert_eq!(reason_category(Some("BadDeviceToken")), "BadDeviceToken");
        assert_eq!(reason_category(Some("abc/def")), "other");
        assert_eq!(reason_category(None), "none");
    }
}
