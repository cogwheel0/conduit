//! Conduit's push relay.
//!
//! The user's own server encrypts each notification to a key that exists only
//! on the device, then sends it here as standard Web Push. The relay opens the
//! sealed endpoint to learn the device token, forwards the ciphertext to APNs
//! or FCM, and forgets it. It keeps no database and writes no access logs. See
//! `docs/push/PROTOCOL.md` for the contract.

use std::future::Future;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::http::StatusCode;
use tokio::net::TcpListener;

pub mod apns;
pub mod config;
pub mod fcm;
pub mod metrics;
pub mod ratelimit;
pub mod routes;
pub mod seal;
pub mod webpush;

pub use routes::{AppState, StartupError};

/// One push, ready to hand to a provider.
#[derive(Debug, Clone, Copy)]
pub struct Message<'a> {
    pub token: &'a str,
    /// Bundle id (APNs topic) or package name.
    pub app: &'a str,
    /// APNs only: use the sandbox host.
    pub sandbox: bool,
    pub sid: &'a str,
    /// The Web Push body, base64url without padding.
    pub data: &'a str,
    pub meta: &'a webpush::PushMeta,
}

/// How a provider handled a push, already in the relay's terms.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// Apple or Google accepted it.
    Sent,
    /// The device token is dead: the sender should delete the subscription.
    Gone,
    TooLarge,
    /// The provider is throttling this device.
    Throttled,
    /// The provider refused the request for a reason that is not the token.
    Rejected,
    /// The provider is down or unreachable.
    Unavailable,
}

impl Outcome {
    pub fn status(self) -> StatusCode {
        match self {
            Self::Sent => StatusCode::CREATED,
            Self::Gone => StatusCode::GONE,
            Self::TooLarge => StatusCode::PAYLOAD_TOO_LARGE,
            Self::Throttled => StatusCode::TOO_MANY_REQUESTS,
            Self::Rejected => StatusCode::BAD_GATEWAY,
            Self::Unavailable => StatusCode::SERVICE_UNAVAILABLE,
        }
    }

    pub fn code(self) -> &'static str {
        match self {
            Self::Sent => "sent",
            Self::Gone => "unregistered",
            Self::TooLarge => "too_large",
            Self::Throttled => "provider_throttled",
            Self::Rejected => "provider_rejected",
            Self::Unavailable => "provider_unavailable",
        }
    }
}

pub(crate) fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Outbound HTTP settings shared by both providers. Redirects are off so a
/// device token in a URL can never be sent anywhere else.
pub(crate) fn http_client(http2_only: bool) -> reqwest::Result<reqwest::Client> {
    let builder = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::none());
    if http2_only {
        builder.http2_prior_knowledge().build()
    } else {
        builder.build()
    }
}

/// Serves the public API until `shutdown` resolves.
pub async fn serve(
    listener: TcpListener,
    state: Arc<AppState>,
    shutdown: impl Future<Output = ()> + Send + 'static,
) -> std::io::Result<()> {
    let app = routes::router(state).into_make_service_with_connect_info::<SocketAddr>();
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown)
        .await
}

/// Serves `/metrics` until `shutdown` resolves.
pub async fn serve_metrics(
    listener: TcpListener,
    state: Arc<AppState>,
    shutdown: impl Future<Output = ()> + Send + 'static,
) -> std::io::Result<()> {
    axum::serve(listener, routes::metrics_router(state))
        .with_graceful_shutdown(shutdown)
        .await
}

/// Drops rate-limit state that has fully recovered, once a minute.
pub fn spawn_eviction(state: Arc<AppState>) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(60));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tick.tick().await;
            state.limits.evict(std::time::Instant::now());
        }
    })
}
