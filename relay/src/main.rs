use std::process::ExitCode;
use std::sync::Arc;

use conduit_push_relay::config::Config;
use conduit_push_relay::AppState;
use tokio::net::TcpListener;
use tokio::sync::watch;
use tracing::Level;
use tracing_subscriber::filter::{filter_fn, EnvFilter};
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::Layer;

#[tokio::main]
async fn main() -> ExitCode {
    init_tracing();

    let config = match Config::from_env() {
        Ok(config) => config,
        Err(err) => {
            tracing::error!("configuration error: {err}");
            return ExitCode::FAILURE;
        }
    };
    let state = match AppState::new(&config) {
        Ok(state) => Arc::new(state),
        Err(err) => {
            tracing::error!("startup error: {err}");
            return ExitCode::FAILURE;
        }
    };
    if state.providers().is_empty() {
        tracing::warn!("neither APNs nor FCM is configured; every push will fail");
    }

    let listener = match TcpListener::bind(config.listen_addr).await {
        Ok(listener) => listener,
        Err(err) => {
            tracing::error!("cannot listen on {}: {err}", config.listen_addr);
            return ExitCode::FAILURE;
        }
    };

    let (stop, stopped) = watch::channel(false);
    let until_stopped = move || {
        let mut stopped = stopped.clone();
        async move {
            let _ = stopped.wait_for(|stop| *stop).await;
        }
    };

    if let Some(addr) = config.metrics_addr {
        match TcpListener::bind(addr).await {
            Ok(listener) => {
                let state = state.clone();
                let shutdown = until_stopped();
                tokio::spawn(async move {
                    if let Err(err) =
                        conduit_push_relay::serve_metrics(listener, state, shutdown).await
                    {
                        tracing::error!("metrics listener failed: {err}");
                    }
                });
            }
            Err(err) => {
                tracing::error!("cannot listen on {addr}: {err}");
                return ExitCode::FAILURE;
            }
        }
    }

    conduit_push_relay::spawn_eviction(state.clone());
    tokio::spawn(async move {
        shutdown_signal().await;
        let _ = stop.send(true);
    });

    tracing::info!(
        providers = ?state.providers(),
        active_kid = state.sealer.active_kid(),
        "listening on {}",
        config.listen_addr
    );
    match conduit_push_relay::serve(listener, state, until_stopped()).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            tracing::error!("server failed: {err}");
            ExitCode::FAILURE
        }
    }
}

/// `RUST_LOG` defaults to `warn`. The HTTP libraries underneath are held at
/// `warn` whatever it says, because at lower levels they can print URLs and
/// headers, and those carry device tokens and sealed endpoints.
fn init_tracing() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("warn"));
    let libraries_quiet = filter_fn(|meta| {
        meta.target().starts_with("conduit_push_relay") || *meta.level() <= Level::WARN
    });
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::fmt::layer()
                .with_target(false)
                .with_filter(filter)
                .with_filter(libraries_quiet),
        )
        .init();
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut signal) => {
                signal.recv().await;
            }
            Err(_) => std::future::pending::<()>().await,
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        () = ctrl_c => {}
        () = terminate => {}
    }
}
