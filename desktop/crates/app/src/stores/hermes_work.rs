//! One open Hermes chat's agent at work: its subagents, background
//! processes and plan, as `hermes.work.watch` answers and
//! `hermes.work.changed` (scoped to the chat) keeps them.
//!
//! The chat store owns one per open chat and starts the watch once
//! `chats.get` says the chat has a Hermes agent (`abilities.hermesWork`);
//! dropping it (another chat opened, the window closed) unwatches, so the
//! daemon stops polling the gateway for a chat nobody sees. Watching again
//! with a subagent named makes that subagent's output come with the work,
//! for the background work sheet.

use std::collections::HashMap;

use conduit_daemon::RpcError;
use conduit_protocol::{
    Event, HermesProcessKill, HermesProcessRef, HermesSteerSubagent, HermesSubagentRef, HermesWork,
    HermesWorkChat, HermesWorkWatch, OkResult, methods,
};
use gpui_kit::{App, AsyncApp, Context, Global, Task, WeakEntity};

use super::rpc::Rpc;

pub struct HermesWorkStore {
    rpc: Rpc,
    chat_id: String,
    /// The chat's work, once the daemon has answered.
    pub work: Option<HermesWork>,
    watching: bool,
    /// The subagent whose output the sheet shows.
    pub output_for: Option<String>,
    _watch: Option<Task<()>>,
}

impl HermesWorkStore {
    pub fn new(rpc: Rpc, chat_id: String) -> Self {
        Self {
            rpc,
            chat_id,
            work: None,
            watching: false,
            output_for: None,
            _watch: None,
        }
    }

    pub fn chat_id(&self) -> &str {
        &self.chat_id
    }

    pub fn watching(&self) -> bool {
        self.watching
    }

    /// `hermes.work.watch`, with the subagent whose output is shown.
    pub fn watch(&mut self, cx: &mut Context<Self>) {
        self.watching = true;
        let chat_id = self.chat_id.clone();
        let call = self.rpc.call::<methods::HermesWorkWatch>(&HermesWorkWatch {
            chat_id: chat_id.clone(),
            subagent_id: self.output_for.clone(),
        });
        self._watch = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| match result {
                    Ok(work) if work.chat_id == s.chat_id => {
                        s.work = Some(work);
                        cx.notify();
                    }
                    Ok(_) => {}
                    Err(e) => log::warn!("hermes.work.watch: {e}"),
                });
            }),
        );
    }

    /// Shows `subagent`'s output with the work (none: no output).
    pub fn read_output(&mut self, subagent: Option<String>, cx: &mut Context<Self>) {
        if self.output_for == subagent {
            return;
        }
        self.output_for = subagent;
        if self.watching {
            self.watch(cx);
        }
    }

    /// A daemon event: this chat's work changed.
    pub fn on_event(&mut self, event: &Event, cx: &mut Context<Self>) {
        if let Event::HermesWorkChanged(work) = event
            && work.chat_id == self.chat_id
        {
            self.work = Some(work.clone());
            cx.notify();
        }
    }

    /// A reconnect: the daemon's watches went with its session.
    pub fn on_reconnected(&mut self, cx: &mut Context<Self>) {
        if self.watching {
            self.watch(cx);
        }
    }

    /// The chat has a new id.
    pub fn remap(&mut self, to: &str, cx: &mut Context<Self>) {
        if self.chat_id == to {
            return;
        }
        if self.watching {
            self.unwatch();
        }
        self.chat_id = to.to_string();
        self.work = None;
        if self.watching {
            self.watch(cx);
        }
    }

    fn unwatch(&self) {
        // Sent at once; nothing waits for it.
        drop(
            self.rpc
                .call::<methods::HermesWorkUnwatch>(&HermesWorkChat {
                    chat_id: self.chat_id.clone(),
                }),
        );
    }

    /// Running subagents and processes, for the chip.
    pub fn running(&self) -> (usize, usize) {
        self.work.as_ref().map_or((0, 0), |w| {
            (
                w.subagents.iter().filter(|s| s.running).count(),
                w.processes.iter().filter(|p| p.running).count(),
            )
        })
    }

    /// New instructions for a running subagent: queued or refused.
    pub fn steer(
        &self,
        subagent: &str,
        text: &str,
    ) -> impl Future<Output = Result<OkResult, RpcError>> + 'static + use<> {
        self.rpc
            .call::<methods::HermesWorkSteer>(&HermesSteerSubagent {
                chat_id: self.chat_id.clone(),
                subagent_id: subagent.to_string(),
                text: text.to_string(),
            })
    }

    /// Stops a subagent: whether it was still running.
    pub fn stop(
        &self,
        subagent: &str,
    ) -> impl Future<Output = Result<OkResult, RpcError>> + 'static + use<> {
        self.rpc
            .call::<methods::HermesWorkStop>(&HermesSubagentRef {
                chat_id: self.chat_id.clone(),
                subagent_id: subagent.to_string(),
            })
    }

    /// Kills a background process.
    pub fn kill(
        &self,
        process: &str,
    ) -> impl Future<Output = Result<HermesProcessKill, RpcError>> + 'static + use<> {
        self.rpc.call::<methods::HermesWorkKill>(&HermesProcessRef {
            chat_id: self.chat_id.clone(),
            process_id: process.to_string(),
        })
    }
}

impl Drop for HermesWorkStore {
    fn drop(&mut self) {
        if self.watching {
            self.unwatch();
        }
    }
}

/// Whether each chat's plan is folded, as the user left it, for this run of
/// the app (mobile keeps it the same way). Absent: folded once nothing is
/// left to do.
#[derive(Default)]
pub struct PlanFolds(pub HashMap<String, bool>);

impl Global for PlanFolds {}

/// Whether `chat_id`'s plan shows folded: as the user left it, else once
/// nothing is left to do.
pub fn plan_folded(chat_id: &str, active: bool, cx: &App) -> bool {
    cx.try_global::<PlanFolds>()
        .and_then(|f| f.0.get(chat_id).copied())
        .unwrap_or(!active)
}

/// Folds or unfolds `chat_id`'s plan.
pub fn set_plan_folded(chat_id: &str, folded: bool, cx: &mut App) {
    cx.default_global::<PlanFolds>()
        .0
        .insert(chat_id.to_string(), folded);
}

#[cfg(test)]
mod tests {
    use gpui_kit::{AppContext as _, TestAppContext};
    use serde_json::json;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    fn work(chat: &str, running: bool) -> HermesWork {
        serde_json::from_value(json!({
            "chatId": chat,
            "loaded": true,
            "subagents": [{"id": "sa-1", "goal": "Tidy notes", "running": running}],
            "processes": [{"id": "proc-1", "command": "sleep 300", "running": true}],
        }))
        .unwrap()
    }

    #[gpui_kit::test]
    fn watches_follows_and_unwatches(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::HermesWorkWatch>(work("local:hermes_a", true));
        daemon.returns::<methods::HermesWorkUnwatch>(OkResult { ok: true });
        let store = cx.new(|_| HermesWorkStore::new(daemon.rpc(), "local:hermes_a".into()));
        store.update(cx, |s, cx| s.watch(cx));
        cx.run_until_parked();
        assert_eq!(store.read_with(cx, |s, _| s.running()), (1, 1));

        // An event for this chat replaces the work; another chat's is not ours.
        store.update(cx, |s, cx| {
            s.on_event(&Event::HermesWorkChanged(work("local:hermes_a", false)), cx);
            s.on_event(&Event::HermesWorkChanged(work("local:hermes_b", true)), cx);
        });
        assert_eq!(store.read_with(cx, |s, _| s.running()), (0, 1));

        // Reading a subagent's output watches again, naming it.
        store.update(cx, |s, cx| s.read_output(Some("sa-1".into()), cx));
        cx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::HermesWorkWatch>().last().unwrap()["subagentId"],
            "sa-1"
        );

        // Gone: the daemon stops following the chat.
        drop(store);
        cx.update(|_| {});
        cx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::HermesWorkUnwatch>(),
            vec![json!({"chatId": "local:hermes_a"})]
        );
    }

    #[gpui_kit::test]
    fn a_plan_folds_once_done_unless_the_user_chose(cx: &mut TestAppContext) {
        cx.update(|cx| {
            assert!(!plan_folded("c", true, cx));
            assert!(plan_folded("c", false, cx));
            set_plan_folded("c", false, cx);
            assert!(!plan_folded("c", false, cx));
        });
    }
}
