//! The HTTP API (PROTOCOL §5).
//!
//! No handler logs anything about a request: not the endpoint, the token, the
//! body or the sender's address. Errors are `{"error": "<code>"}`.

use std::convert::Infallible;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::body::{Body, Bytes};
use axum::extract::rejection::PathRejection;
use axum::extract::{ConnectInfo, FromRequestParts, Path, State};
use axum::http::header::{CACHE_CONTROL, CONTENT_LENGTH, CONTENT_TYPE, LOCATION, RETRY_AFTER};
use axum::http::request::Parts;
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chacha20poly1305::aead::rand_core::RngCore;
use chacha20poly1305::aead::OsRng;
use serde::{Deserialize, Serialize};

use crate::apns::{Apns, ApnsError};
use crate::config::Config;
use crate::fcm::{Fcm, FcmError};
use crate::metrics::{Metrics, Provider, PushResult, RegisterResult};
use crate::ratelimit::{endpoint_key, ip_key, RateLimits};
use crate::seal::{Claims, OpenError, Sealer};
use crate::webpush::{self, Reject, MAX_BODY};
use crate::{now_unix, Message, Outcome};

const REGISTER_MAX_BODY: usize = 16 * 1024;
const BODY_TIMEOUT: Duration = Duration::from_secs(10);
const READY_FOR: Duration = Duration::from_secs(5 * 60);
const NOT_READY_FOR: Duration = Duration::from_secs(30);

#[derive(Debug, thiserror::Error)]
pub enum StartupError {
    #[error(transparent)]
    Apns(#[from] ApnsError),
    #[error(transparent)]
    Fcm(#[from] FcmError),
}

pub struct AppState {
    pub public_url: String,
    pub sealer: Sealer,
    pub apns: Option<Apns>,
    pub fcm: Option<Fcm>,
    pub limits: RateLimits,
    pub metrics: Metrics,
    pub trust_forwarded_for: bool,
    readiness: tokio::sync::Mutex<Option<(Instant, bool)>>,
}

impl AppState {
    pub fn new(config: &Config) -> Result<Self, StartupError> {
        Ok(Self {
            public_url: config.public_url.clone(),
            sealer: Sealer::new(&config.seal_keys, config.active_kid),
            apns: config.apns.as_ref().map(Apns::new).transpose()?,
            fcm: config.fcm.as_ref().map(Fcm::new).transpose()?,
            limits: RateLimits::new(&config.limits),
            metrics: Metrics::default(),
            trust_forwarded_for: config.trust_forwarded_for,
            readiness: tokio::sync::Mutex::new(None),
        })
    }

    pub fn providers(&self) -> Vec<&'static str> {
        let mut providers = Vec::new();
        if self.apns.is_some() {
            providers.push("apns");
        }
        if self.fcm.is_some() {
            providers.push("fcm");
        }
        providers
    }

    /// Whether every configured provider can get its credential. A good
    /// answer is kept for five minutes, a bad one for 30 seconds.
    pub async fn ready(&self) -> bool {
        let mut cached = self.readiness.lock().await;
        if let Some((at, ready)) = *cached {
            let keep = if ready { READY_FOR } else { NOT_READY_FOR };
            if at.elapsed() < keep {
                return ready;
            }
        }
        let apns = self.apns.as_ref().is_none_or(Apns::check);
        let fcm = match &self.fcm {
            Some(fcm) => fcm.check().await,
            None => true,
        };
        let ready = apns && fcm;
        *cached = Some((Instant::now(), ready));
        ready
    }
}

pub fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/v1/info", get(info))
        .route("/v1/register", post(register))
        .route("/v1/push/{sealed}", post(push))
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .fallback(|| async { error(StatusCode::NOT_FOUND, "not_found") })
        .method_not_allowed_fallback(|| async {
            error(StatusCode::METHOD_NOT_ALLOWED, "method_not_allowed")
        })
        .with_state(state)
}

pub fn metrics_router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/metrics", get(metrics))
        .with_state(state)
}

fn error(status: StatusCode, code: &'static str) -> Response {
    #[derive(Serialize)]
    struct ErrorBody {
        error: &'static str,
    }
    (status, Json(ErrorBody { error: code })).into_response()
}

fn rate_limited(retry_after: u64) -> Response {
    let mut response = error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    response
        .headers_mut()
        .insert(RETRY_AFTER, HeaderValue::from(retry_after));
    response
}

/// The address rate limits are keyed on: the peer, or with
/// `RELAY_TRUST_FORWARDED_FOR` the last `X-Forwarded-For` entry, which is the
/// one the relay's own proxy added.
pub struct ClientIp(pub IpAddr);

impl FromRequestParts<Arc<AppState>> for ClientIp {
    type Rejection = Infallible;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &Arc<AppState>,
    ) -> Result<Self, Self::Rejection> {
        let forwarded = if state.trust_forwarded_for {
            forwarded_for(&parts.headers)
        } else {
            None
        };
        let peer = parts
            .extensions
            .get::<ConnectInfo<SocketAddr>>()
            .map(|info| info.0.ip());
        let ip = forwarded
            .or(peer)
            .unwrap_or(IpAddr::V4(Ipv4Addr::UNSPECIFIED));
        Ok(Self(ip_key(ip)))
    }
}

fn forwarded_for(headers: &HeaderMap) -> Option<IpAddr> {
    let last = headers
        .get_all("x-forwarded-for")
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(','))
        .map(str::trim)
        .rfind(|entry| !entry.is_empty())?;
    last.parse::<IpAddr>()
        .ok()
        .or_else(|| last.parse::<SocketAddr>().ok().map(|addr| addr.ip()))
}

async fn read_body(body: Body, limit: usize) -> Option<Bytes> {
    match tokio::time::timeout(BODY_TIMEOUT, axum::body::to_bytes(body, limit)).await {
        Ok(Ok(bytes)) => Some(bytes),
        _ => None,
    }
}

fn metric_provider(name: &str) -> Provider {
    match name {
        "apns" => Provider::Apns,
        "fcm" => Provider::Fcm,
        _ => Provider::None,
    }
}

#[derive(Serialize)]
struct Info {
    proto: u8,
    active_kid: u8,
    max_body: usize,
    providers: Vec<&'static str>,
}

async fn info(State(state): State<Arc<AppState>>) -> Response {
    Json(Info {
        proto: 1,
        active_kid: state.sealer.active_kid(),
        max_body: MAX_BODY,
        providers: state.providers(),
    })
    .into_response()
}

async fn healthz() -> &'static str {
    "ok"
}

async fn readyz(State(state): State<Arc<AppState>>) -> Response {
    if state.ready().await {
        "ready".into_response()
    } else {
        error(StatusCode::SERVICE_UNAVAILABLE, "not_ready")
    }
}

async fn metrics(State(state): State<Arc<AppState>>) -> Response {
    (
        [(CONTENT_TYPE, "text/plain; version=0.0.4; charset=utf-8")],
        state.metrics.render(),
    )
        .into_response()
}

#[derive(Deserialize)]
struct RegisterRequest {
    provider: String,
    token: String,
    app: String,
    env: String,
    sid: String,
}

#[derive(Serialize)]
struct Registered {
    endpoint: String,
    kid: u8,
}

/// APNs device tokens are hex; today they are 64 characters.
pub fn valid_apns_token(token: &str) -> bool {
    (64..=200).contains(&token.len()) && token.bytes().all(|b| b.is_ascii_hexdigit())
}

pub fn valid_fcm_token(token: &str) -> bool {
    (20..=4096).contains(&token.len())
        && token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b':' | b'-' | b'.'))
}

/// A sid is 16 bytes, base64url without padding.
pub fn valid_sid(sid: &str) -> bool {
    URL_SAFE_NO_PAD
        .decode(sid)
        .is_ok_and(|bytes| bytes.len() == 16)
}

async fn register(
    State(state): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    body: Body,
) -> Response {
    let metrics = &state.metrics;
    if let Err(wait) = state.limits.register.check(ip) {
        metrics.register(Provider::None, RegisterResult::RateLimited);
        return rate_limited(wait);
    }
    let invalid = |provider| {
        metrics.register(provider, RegisterResult::Invalid);
        error(StatusCode::BAD_REQUEST, "invalid_request")
    };

    let Some(bytes) = read_body(body, REGISTER_MAX_BODY).await else {
        return invalid(Provider::None);
    };
    let Ok(request) = serde_json::from_slice::<RegisterRequest>(&bytes) else {
        return invalid(Provider::None);
    };

    let provider = metric_provider(&request.provider);
    let allowed = match provider {
        Provider::Apns => state.apns.as_ref().map(|apns| apns.allows(&request.app)),
        Provider::Fcm => state.fcm.as_ref().map(|fcm| fcm.allows(&request.app)),
        Provider::None => None,
    };
    match allowed {
        None => {
            metrics.register(provider, RegisterResult::Unconfigured);
            return error(StatusCode::SERVICE_UNAVAILABLE, "provider_unconfigured");
        }
        Some(false) => {
            metrics.register(provider, RegisterResult::AppNotAllowed);
            return error(StatusCode::FORBIDDEN, "app_not_allowed");
        }
        Some(true) => {}
    }

    if !matches!(request.env.as_str(), "prod" | "dev") || !valid_sid(&request.sid) {
        return invalid(provider);
    }
    let token = match provider {
        Provider::Apns if valid_apns_token(&request.token) => request.token.to_ascii_lowercase(),
        Provider::Fcm if valid_fcm_token(&request.token) => request.token,
        _ => return invalid(provider),
    };

    let sealed = state.sealer.seal(&Claims {
        p: request.provider,
        e: request.env,
        a: request.app,
        s: request.sid,
        t: token,
        i: now_unix(),
    });
    metrics.register(provider, RegisterResult::Ok);
    let mut response = Json(Registered {
        endpoint: format!("{}/v1/push/{sealed}", state.public_url),
        kid: state.sealer.active_kid(),
    })
    .into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}

enum Target<'a> {
    Apns(&'a Apns),
    Fcm(&'a Fcm),
}

async fn push(
    State(state): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    sealed: Result<Path<String>, PathRejection>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    let metrics = &state.metrics;
    if let Err(wait) = state.limits.ip.check(ip) {
        metrics.push(Provider::None, PushResult::RateLimited);
        return rate_limited(wait);
    }

    let not_found = || {
        metrics.push(Provider::None, PushResult::NotFound);
        error(StatusCode::NOT_FOUND, "not_found")
    };
    let Ok(Path(sealed)) = sealed else {
        return not_found();
    };
    let claims = match state.sealer.open(&sealed) {
        Ok(claims) => claims,
        Err(OpenError::NotFound) => return not_found(),
        Err(OpenError::Retired) => {
            metrics.push(Provider::None, PushResult::Gone);
            return error(StatusCode::GONE, "key_retired");
        }
    };
    let provider = metric_provider(&claims.p);
    let reject = |reason: Reject| {
        let result = if reason == Reject::TooLarge {
            PushResult::TooLarge
        } else {
            PushResult::Invalid
        };
        metrics.push(provider, result);
        error(reason.status(), reason.code())
    };

    let meta = match webpush::check_headers(&headers) {
        Ok(meta) => meta,
        Err(reason) => return reject(reason),
    };
    let declared = headers
        .get(CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok());
    if declared.is_some_and(|len| len > MAX_BODY as u64) {
        return reject(Reject::TooLarge);
    }
    let Some(body) = read_body(body, MAX_BODY).await else {
        return reject(Reject::TooLarge);
    };
    if let Err(reason) = webpush::check_body(&body) {
        return reject(reason);
    }

    let target = match (provider, &state.apns, &state.fcm) {
        (Provider::Apns, Some(apns), _) => Target::Apns(apns),
        (Provider::Fcm, _, Some(fcm)) => Target::Fcm(fcm),
        _ => {
            metrics.push(provider, PushResult::Unconfigured);
            return error(StatusCode::SERVICE_UNAVAILABLE, "provider_unconfigured");
        }
    };
    let allowed = match target {
        Target::Apns(apns) => apns.allows(&claims.a),
        Target::Fcm(fcm) => fcm.allows(&claims.a),
    };
    if !allowed {
        metrics.push(provider, PushResult::AppNotAllowed);
        return error(StatusCode::FORBIDDEN, "app_not_allowed");
    }
    if let Err(wait) = state.limits.endpoint.check(endpoint_key(&sealed)) {
        metrics.push(provider, PushResult::RateLimited);
        return rate_limited(wait);
    }

    let data = URL_SAFE_NO_PAD.encode(&body);
    let message = Message {
        token: &claims.t,
        app: &claims.a,
        sandbox: claims.e == "dev",
        sid: &claims.s,
        data: &data,
        meta: &meta,
    };
    let outcome = match target {
        Target::Apns(apns) => apns.send(&message).await,
        Target::Fcm(fcm) => fcm.send(&message).await,
    };
    metrics.push(provider, outcome.into());
    if outcome != Outcome::Sent {
        let mut response = error(outcome.status(), outcome.code());
        if let Some(seconds) = outcome.retry_after() {
            response
                .headers_mut()
                .insert(RETRY_AFTER, HeaderValue::from(seconds));
        }
        return response;
    }

    // An opaque message id: the relay keeps nothing to look it up by.
    let mut id = [0u8; 16];
    OsRng.fill_bytes(&mut id);
    let location = format!(
        "{}/v1/message/{}",
        state.public_url,
        URL_SAFE_NO_PAD.encode(id)
    );
    let mut response = StatusCode::CREATED.into_response();
    let headers = response.headers_mut();
    if let Ok(location) = HeaderValue::from_str(&location) {
        headers.insert(LOCATION, location);
    }
    headers.insert("ttl", HeaderValue::from(meta.ttl));
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_and_sid_formats() {
        assert!(valid_apns_token(&"a1".repeat(32)));
        assert!(valid_apns_token(&"A1".repeat(100)));
        assert!(!valid_apns_token(&"a1".repeat(31)));
        assert!(!valid_apns_token(&"a".repeat(201)));
        assert!(!valid_apns_token(&"g1".repeat(32)));

        assert!(valid_fcm_token("cXyZ-12_ab:APA91b.Hello"));
        assert!(!valid_fcm_token("short:token"));
        assert!(!valid_fcm_token(&"a".repeat(4097)));
        assert!(!valid_fcm_token("has spaces in the token here"));
        assert!(!valid_fcm_token("slash/slash/slash/slash"));

        assert!(valid_sid("QFvhBRA6vVgC_oPGR5mrpA"));
        assert!(!valid_sid("QFvhBRA6vVgC_oPGR5mrpA=="));
        assert!(!valid_sid("QFvhBRA6vVgC_oPGR5mrp"));
        assert!(!valid_sid("QFvhBRA6vVgC/oPGR5mrpA"));
        assert!(!valid_sid("QFvhBRA6vVgC_oPGR5mrpAAA"));
    }

    #[test]
    fn forwarded_for_takes_the_last_entry() {
        let mut headers = HeaderMap::new();
        assert_eq!(forwarded_for(&headers), None);
        headers.append(
            "x-forwarded-for",
            HeaderValue::from_static("203.0.113.9, 198.51.100.2"),
        );
        assert_eq!(
            forwarded_for(&headers),
            Some("198.51.100.2".parse().unwrap())
        );
        headers.append(
            "x-forwarded-for",
            HeaderValue::from_static("192.0.2.1:4711"),
        );
        assert_eq!(forwarded_for(&headers), Some("192.0.2.1".parse().unwrap()));
        headers.append("x-forwarded-for", HeaderValue::from_static("2001:db8::1"));
        assert_eq!(
            forwarded_for(&headers),
            Some("2001:db8::1".parse().unwrap())
        );
        headers.append("x-forwarded-for", HeaderValue::from_static("garbage"));
        assert_eq!(forwarded_for(&headers), None);
    }
}
