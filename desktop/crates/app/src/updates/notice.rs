//! Linux's [`Updater`]: a "new version available" notice. Once a day (as
//! the Mac checks), and on "Check Now", it reads the signed Linux feed
//! ([`super::feed`]); when that lists a release newer than this app,
//! Settings › About offers the release's page. It never installs anything:
//! the package manager does, or the user with the release's package.
//!
//! The feed comes over HTTPS, trusted through the system's certificate
//! store, from the one URL the build names; nothing else is fetched. A
//! feed not signed with the build's key, or not an appcast, counts as a
//! failed check, tried again an hour later ([`super::checks`]).

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use futures::channel::{mpsc, oneshot};
use futures::{FutureExt as _, StreamExt as _};
use gpui_kit::{App, AsyncApp};

use super::checks::{self, Checks};
use super::config::Config;
use super::feed::{self, Decision};
use super::{Found, Outcome, Updater};

/// The most a feed may be: a few kilobytes per release.
const MAX_FEED_BYTES: u64 = 1 << 20;
const TIMEOUT: Duration = Duration::from_secs(30);

enum Wake {
    /// "Check Now", or the `--smoke` pass's check.
    Check,
    /// The switch changed: work out the next check again.
    Reschedule,
}

struct State {
    checks: Checks,
    path: PathBuf,
    checking: bool,
    last_failure: Option<i64>,
    found: Option<Found>,
}

pub struct Notice {
    state: Rc<RefCell<State>>,
    wake: mpsc::UnboundedSender<Wake>,
}

impl Notice {
    /// Starts the daily check (the first is due at once, unless one ran in
    /// the last day).
    pub fn start(config: Config, key: [u8; 32], path: PathBuf, cx: &mut App) -> Self {
        let state = Rc::new(RefCell::new(State {
            checks: crate::prefs::load(&path),
            path,
            checking: false,
            last_failure: None,
            found: None,
        }));
        let (wake, woken) = mpsc::unbounded();
        let looping = state.clone();
        cx.spawn(async move |cx| run(config, key, looping, woken, cx).await)
            .detach();
        Self { state, wake }
    }
}

impl Updater for Notice {
    fn can_check(&self) -> bool {
        !self.state.borrow().checking
    }

    fn check_for_updates(&self) {
        let _ = self.wake.unbounded_send(Wake::Check);
    }

    fn automatic_checks(&self) -> bool {
        self.state.borrow().checks.automatic
    }

    fn set_automatic_checks(&self, on: bool) {
        let mut state = self.state.borrow_mut();
        state.checks.automatic = on;
        save(&state);
        let _ = self.wake.unbounded_send(Wake::Reschedule);
    }

    fn check_quietly(&self) -> bool {
        self.wake.unbounded_send(Wake::Check).is_ok()
    }

    fn found(&self) -> Option<Found> {
        self.state.borrow().found.clone()
    }
}

async fn run(
    config: Config,
    key: [u8; 32],
    state: Rc<RefCell<State>>,
    mut woken: mpsc::UnboundedReceiver<Wake>,
    cx: &mut AsyncApp,
) {
    loop {
        let next = {
            let s = state.borrow();
            checks::next_check(&s.checks, s.last_failure, now())
        };
        let due = match next {
            Some(wait) => {
                let timer = cx.background_executor().timer(wait).fuse();
                futures::pin_mut!(timer);
                futures::select! {
                    wake = woken.next() => wake,
                    () = timer => Some(Wake::Check),
                }
            }
            None => woken.next().await,
        };
        match due {
            Some(Wake::Check) => check(&config, &key, &state, cx).await,
            Some(Wake::Reschedule) => {}
            None => return,
        }
    }
}

async fn check(config: &Config, key: &[u8; 32], state: &Rc<RefCell<State>>, cx: &mut AsyncApp) {
    state.borrow_mut().checking = true;
    cx.update(|cx| cx.refresh_windows());
    let (tx, rx) = oneshot::channel();
    let url = config.feed_url.clone();
    // ureq blocks; a thread of its own keeps it off the app's executors.
    std::thread::spawn(move || {
        let _ = tx.send(fetch(&url));
    });
    let result = rx
        .await
        .unwrap_or_else(|_| Err("the check's thread ended without an answer".into()))
        .and_then(|bytes| feed::decide(&bytes, key, config.build).map_err(|e| e.to_string()));
    let outcome = {
        let mut s = state.borrow_mut();
        s.checking = false;
        match result {
            Ok(decision) => {
                s.last_failure = None;
                s.checks.last_check = Some(now());
                save(&s);
                s.found = match decision {
                    Decision::Newer(release) => Some(Found {
                        version: release.version,
                        page: release.page,
                    }),
                    Decision::UpToDate => None,
                };
                match &s.found {
                    Some(found) => Outcome::Found(Some(found.version.clone())),
                    None => Outcome::UpToDate,
                }
            }
            Err(why) => {
                s.last_failure = Some(now());
                Outcome::Failed(why)
            }
        }
    };
    cx.update(|cx| {
        super::report(outcome, cx);
        cx.refresh_windows();
    });
}

/// The feed's bytes, or why there are none.
fn fetch(url: &str) -> Result<Vec<u8>, String> {
    let roots = rustls_native_certs::load_native_certs();
    let certs: Vec<_> = roots
        .certs
        .iter()
        .map(|c| ureq::tls::Certificate::from_der(c.as_ref()).to_owned())
        .collect();
    if certs.is_empty() && url.starts_with("https://") {
        return Err(format!(
            "no certificates in the system's store ({} errors)",
            roots.errors.len()
        ));
    }
    let tls = ureq::tls::TlsConfig::builder()
        .provider(ureq::tls::TlsProvider::Rustls)
        .root_certs(ureq::tls::RootCerts::new_with_certs(&certs))
        .unversioned_rustls_crypto_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .build();
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .tls_config(tls)
        .timeout_global(Some(TIMEOUT))
        .user_agent(format!("Conduit/{}", crate::VERSION))
        .build()
        .into();
    agent
        .get(url)
        .call()
        .map_err(|e| e.to_string())?
        .body_mut()
        .with_config()
        .limit(MAX_FEED_BYTES)
        .read_to_vec()
        .map_err(|e| e.to_string())
}

fn save(state: &State) {
    if let Err(e) = crate::prefs::save(&state.path, &state.checks) {
        log::warn!("updates: {}: {e}", state.path.display());
    }
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}
