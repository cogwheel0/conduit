//! The seam every store calls the daemon through.
//!
//! Stores hold an [`Rpc`], not the socket client: in the app it wraps the
//! process's one [`RpcClient`]; in tests a [`fake::FakeDaemon`] answers from
//! a script and records what it was asked. Calls are typed by the generated
//! method markers (`rpc.call::<methods::AccountsList>(&NoParams)`), and the
//! futures borrow nothing, so a store can await them in `cx.spawn`.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use conduit_daemon::protocol::{RpcMethod, codes, error};
use conduit_daemon::{RpcClient, RpcError};
use serde_json::Value;

/// A boxed, `'static` call.
pub type CallFuture = Pin<Box<dyn Future<Output = Result<Value, RpcError>> + Send>>;

/// Something that answers JSON-RPC calls by name.
pub trait Daemon: Send + Sync + 'static {
    fn call_value(&self, method: &'static str, params: Value) -> CallFuture;

    /// [`Daemon::call_value`], waiting up to `timeout` instead of the
    /// client's usual call timeout: a sign-in the user finishes in the
    /// browser, or a call that waits for an answer, as `intents.ask` does.
    /// Answers that have no clock of their own (the test fakes) ignore it.
    fn call_value_with_timeout(
        &self,
        method: &'static str,
        params: Value,
        timeout: Duration,
    ) -> CallFuture {
        let _ = timeout;
        self.call_value(method, params)
    }
}

impl Daemon for RpcClient {
    fn call_value(&self, method: &'static str, params: Value) -> CallFuture {
        Box::pin(RpcClient::call_value(self, method, params))
    }

    fn call_value_with_timeout(
        &self,
        method: &'static str,
        params: Value,
        timeout: Duration,
    ) -> CallFuture {
        Box::pin(RpcClient::call_value_with_timeout(
            self, method, params, timeout,
        ))
    }
}

/// A cheap, cloneable handle to the daemon.
#[derive(Clone)]
pub struct Rpc(Arc<dyn Daemon>);

impl Rpc {
    pub fn new(daemon: impl Daemon) -> Self {
        Self(Arc::new(daemon))
    }

    /// Calls `M` with `params` and decodes its result.
    pub fn call<M: RpcMethod>(
        &self,
        params: &M::Params,
    ) -> impl Future<Output = Result<M::Result, RpcError>> + Send + 'static + use<M>
    where
        M::Result: Send + 'static,
    {
        let call = serde_json::to_value(params)
            .map(|p| self.0.call_value(M::NAME, p))
            .map_err(|e| error(codes::INVALID_PARAMS, format!("{}: {e}", M::NAME)));
        async move {
            let value = call?.await?;
            serde_json::from_value::<M::Result>(value)
                .map_err(|e| error(codes::DECODE, format!("{}: {e}", M::NAME)))
        }
    }

    /// [`Rpc::call`] with its own deadline.
    pub fn call_with_timeout<M: RpcMethod>(
        &self,
        params: &M::Params,
        timeout: Duration,
    ) -> impl Future<Output = Result<M::Result, RpcError>> + Send + 'static + use<M>
    where
        M::Result: Send + 'static,
    {
        let call = serde_json::to_value(params)
            .map(|p| self.0.call_value_with_timeout(M::NAME, p, timeout))
            .map_err(|e| error(codes::INVALID_PARAMS, format!("{}: {e}", M::NAME)));
        async move {
            let value = call?.await?;
            serde_json::from_value::<M::Result>(value)
                .map_err(|e| error(codes::DECODE, format!("{}: {e}", M::NAME)))
        }
    }
}

/// A scripted daemon for store tests.
#[cfg(test)]
pub mod fake {
    use std::collections::{HashMap, VecDeque};
    use std::sync::Mutex;

    use super::*;

    type Handler = Box<dyn Fn(&Value) -> Result<Value, RpcError> + Send + Sync>;

    #[derive(Default)]
    struct State {
        /// One-shot answers, used before the standing handler.
        queued: HashMap<&'static str, VecDeque<Result<Value, RpcError>>>,
        handlers: HashMap<&'static str, Handler>,
        calls: Vec<(&'static str, Value)>,
        /// Methods whose calls wait for [`Hold::release`], and their waiters.
        held: HashMap<&'static str, Vec<futures::channel::oneshot::Sender<()>>>,
        /// Methods with one call held ([`FakeDaemon::hold_one`]): the calls
        /// still to pass first, then that call's waiter.
        held_one: HashMap<&'static str, (usize, Option<futures::channel::oneshot::Sender<()>>)>,
    }

    /// Keeps a method's calls unanswered until released (or dropped).
    pub struct Hold {
        daemon: FakeDaemon,
        method: &'static str,
    }

    impl Hold {
        /// Answers the held calls, and every later call at once.
        pub fn release(self) {}

        /// Answers only the oldest call held so far ([`FakeDaemon::hold`]);
        /// later ones stay held.
        pub fn release_one(&self) {
            let mut state = self.daemon.0.lock().unwrap();
            if let Some(waiters) = state.held.get_mut(self.method)
                && !waiters.is_empty()
            {
                let _ = waiters.remove(0).send(());
            }
        }
    }

    impl Drop for Hold {
        fn drop(&mut self) {
            let mut state = self.daemon.0.lock().unwrap();
            let waiters = state.held.remove(self.method);
            let one = state.held_one.remove(self.method).and_then(|(_, w)| w);
            for w in waiters.into_iter().flatten().chain(one) {
                let _ = w.send(());
            }
        }
    }

    /// Answers each method from its queue, else its handler, else
    /// `rpc.methodNotFound`. Every call is recorded.
    #[derive(Clone, Default)]
    pub struct FakeDaemon(Arc<Mutex<State>>);

    impl FakeDaemon {
        pub fn new() -> Self {
            Self::default()
        }

        pub fn rpc(&self) -> Rpc {
            Rpc::new(self.clone())
        }

        /// Answers every `method` call with `f(params)`.
        pub fn on<M: RpcMethod>(
            &self,
            f: impl Fn(&Value) -> Result<Value, RpcError> + Send + Sync + 'static,
        ) -> &Self {
            self.0.lock().unwrap().handlers.insert(M::NAME, Box::new(f));
            self
        }

        /// Answers every `method` call with `result`.
        pub fn returns<M: RpcMethod>(&self, result: M::Result) -> &Self {
            let value = serde_json::to_value(result).unwrap();
            self.on::<M>(move |_| Ok(value.clone()))
        }

        /// Answers the next `method` call with `result`, once.
        pub fn once<M: RpcMethod>(&self, result: Result<M::Result, RpcError>) -> &Self {
            let value = result.map(|r| serde_json::to_value(r).unwrap());
            self.0
                .lock()
                .unwrap()
                .queued
                .entry(M::NAME)
                .or_default()
                .push_back(value);
            self
        }

        /// Holds every `method` call, answered (as it would be now) only
        /// once the returned [`Hold`] is released.
        pub fn hold<M: RpcMethod>(&self) -> Hold {
            self.0.lock().unwrap().held.insert(M::NAME, vec![]);
            Hold {
                daemon: self.clone(),
                method: M::NAME,
            }
        }

        /// Holds only one `method` call, the one after the next `skip`, until
        /// the returned [`Hold`] is released; the others answer at once.
        pub fn hold_one<M: RpcMethod>(&self, skip: usize) -> Hold {
            self.0
                .lock()
                .unwrap()
                .held_one
                .insert(M::NAME, (skip, None));
            Hold {
                daemon: self.clone(),
                method: M::NAME,
            }
        }

        /// The params of every `method` call so far.
        pub fn calls<M: RpcMethod>(&self) -> Vec<Value> {
            self.0
                .lock()
                .unwrap()
                .calls
                .iter()
                .filter(|(m, _)| *m == M::NAME)
                .map(|(_, p)| p.clone())
                .collect()
        }

        /// Method names in call order.
        pub fn log(&self) -> Vec<&'static str> {
            self.0
                .lock()
                .unwrap()
                .calls
                .iter()
                .map(|(m, _)| *m)
                .collect()
        }
    }

    impl Daemon for FakeDaemon {
        fn call_value(&self, method: &'static str, params: Value) -> CallFuture {
            let mut state = self.0.lock().unwrap();
            state.calls.push((method, params.clone()));
            let answer = match state.queued.get_mut(method).and_then(VecDeque::pop_front) {
                Some(answer) => answer,
                None => match state.handlers.get(method) {
                    Some(handler) => handler(&params),
                    None => Err(error(codes::METHOD_NOT_FOUND, method)),
                },
            };
            let mut wait = state.held.get_mut(method).map(|waiters| {
                let (tx, rx) = futures::channel::oneshot::channel();
                waiters.push(tx);
                rx
            });
            if let Some((skip, waiter)) = state.held_one.get_mut(method) {
                if *skip > 0 {
                    *skip -= 1;
                } else if waiter.is_none() {
                    let (tx, rx) = futures::channel::oneshot::channel();
                    *waiter = Some(tx);
                    wait = Some(rx);
                }
            }
            Box::pin(async move {
                if let Some(wait) = wait {
                    let _ = wait.await;
                }
                answer
            })
        }
    }
}
