//! Scheduled tasks (`automations.*`), as the Scheduled Tasks pane shows
//! them: the list (search, filter, Load More), the selected task with its
//! history, and each task's Run Now.
//!
//! The daemon holds the list (core's `Automations`) and watches Run Now;
//! this store keeps its last answers. It lists when the pane is shown (from
//! the server again, as the phone does when its page reopens), on
//! `automations.changed`, and after a reconnect; a Run Now moves on with
//! `automations.runProgress`. Everything goes when the account changes.

use std::collections::HashMap;

use conduit_protocol::{
    AutomationDetail, AutomationList, AutomationQuery, AutomationRef, AutomationRunDto,
    AutomationRunProgress, AutomationRunsQuery, AutomationToggle, Event, NoParams, RpcError,
    events, methods,
};
use gpui_kit::{App, AsyncApp, Context, Task, WeakEntity};

use super::Stores;
use super::connection::ConnectionEvent;
use super::rpc::Rpc;

#[derive(Default)]
pub struct TasksStore {
    rpc: Option<Rpc>,
    pub list: Option<AutomationList>,
    pub loading: bool,
    pub loading_more: bool,
    /// The list's last call was refused.
    pub error: Option<RpcError>,
    /// The search and filter last asked for, shown while their list loads.
    pub query: String,
    pub status: String,
    pub selected: Option<String>,
    pub detail: Option<AutomationDetail>,
    /// Reading the selected task failed.
    pub detail_error: Option<RpcError>,
    pub runs: Vec<AutomationRunDto>,
    pub runs_more: bool,
    pub runs_loading: bool,
    pub runs_failed: bool,
    /// Run Now per task.
    pub progress: HashMap<String, AutomationRunProgress>,
    /// A switch, Run Now request or delete is on its way.
    pub busy: bool,
    /// The last change was refused (shown under the task).
    pub change_error: Option<RpcError>,
    wanted: bool,
    generation: u64,
    request: u64,
    detail_request: u64,
    fetch: Option<Task<()>>,
}

impl TasksStore {
    pub fn new(rpc: Rpc) -> Self {
        Self {
            rpc: Some(rpc),
            status: "all".into(),
            ..Self::default()
        }
    }

    /// The pane is showing: lists (from the server again after the first
    /// time), and reads the selected task again.
    pub fn show(&mut self, cx: &mut Context<Self>) {
        self.wanted = true;
        let refresh = self.list.is_some();
        self.fetch_list(
            AutomationQuery {
                refresh,
                ..Default::default()
            },
            cx,
        );
        if let Some(id) = self.selected.clone() {
            self.load_detail(&id, true, cx);
        }
    }

    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        self.fetch_list(
            AutomationQuery {
                refresh: true,
                ..Default::default()
            },
            cx,
        );
    }

    /// Lists the tasks matching `query`.
    pub fn search(&mut self, query: &str, cx: &mut Context<Self>) {
        self.query = query.to_string();
        self.fetch_list(
            AutomationQuery {
                query: Some(query.trim().to_string()),
                ..Default::default()
            },
            cx,
        );
    }

    /// Lists `all`, `active` or `paused` tasks.
    pub fn filter(&mut self, status: &str, cx: &mut Context<Self>) {
        self.status = status.to_string();
        self.fetch_list(
            AutomationQuery {
                status: Some(status.to_string()),
                ..Default::default()
            },
            cx,
        );
    }

    /// Show All Tasks: no search, every status.
    pub fn show_all(&mut self, cx: &mut Context<Self>) {
        self.query.clear();
        self.status = "all".into();
        self.fetch_list(
            AutomationQuery {
                query: Some(String::new()),
                status: Some("all".into()),
                refresh: false,
            },
            cx,
        );
    }

    fn fetch_list(&mut self, query: AutomationQuery, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc.clone() else {
            return;
        };
        self.request += 1;
        let (request, generation) = (self.request, self.generation);
        self.loading = true;
        cx.notify();
        let call = rpc.call::<methods::AutomationsList>(&query);
        self.fetch = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                this.update(cx, |s, cx| {
                    if s.generation != generation || s.request != request {
                        return;
                    }
                    s.loading = false;
                    match result {
                        Ok(list) => s.adopt(list, cx),
                        Err(e) => {
                            log::warn!("automations.list: {e}");
                            s.error = Some(e);
                        }
                    }
                    cx.notify();
                })
                .ok();
            }),
        );
    }

    pub fn adopt(&mut self, list: AutomationList, cx: &mut Context<Self>) {
        self.error = None;
        self.list = Some(list);
        cx.notify();
    }

    pub fn load_more(&mut self, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc.clone() else {
            return;
        };
        if self.loading_more {
            return;
        }
        self.loading_more = true;
        cx.notify();
        let generation = self.generation;
        let call = rpc.call::<methods::AutomationsLoadMore>(&NoParams);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            this.update(cx, |s, cx| {
                if s.generation != generation {
                    return;
                }
                s.loading_more = false;
                match result {
                    Ok(list) => s.adopt(list, cx),
                    Err(e) => log::warn!("automations.loadMore: {e}"),
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// Shows `id` beside the list, with its history and Run Now.
    pub fn select(&mut self, id: Option<String>, cx: &mut Context<Self>) {
        if self.selected == id {
            return;
        }
        self.selected = id.clone();
        self.detail = None;
        self.detail_error = None;
        self.change_error = None;
        self.runs.clear();
        self.runs_more = false;
        self.runs_failed = false;
        cx.notify();
        if let Some(id) = id {
            self.load_detail(&id, true, cx);
        }
    }

    /// Reads the task (and, with `runs`, its newest history page and where
    /// its Run Now stands).
    pub fn load_detail(&mut self, id: &str, runs: bool, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc.clone() else {
            return;
        };
        self.detail_request += 1;
        let (request, generation) = (self.detail_request, self.generation);
        let target = id.to_string();
        let get = rpc.call::<methods::AutomationsGet>(&AutomationRef { id: target.clone() });
        let state = rpc.call::<methods::AutomationsRunState>(&AutomationRef { id: target.clone() });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = get.await;
            let state = state.await;
            this.update(cx, |s, cx| {
                if s.generation != generation
                    || s.detail_request != request
                    || s.selected.as_deref() != Some(target.as_str())
                {
                    return;
                }
                match result {
                    Ok(detail) => {
                        s.detail = Some(detail);
                        s.detail_error = None;
                    }
                    Err(e) => {
                        log::warn!("automations.get: {e}");
                        s.detail_error = Some(e);
                    }
                }
                if let Ok(progress) = state {
                    s.progress.insert(target.clone(), progress);
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
        if runs {
            self.load_runs(id, false, cx);
        }
    }

    /// The newest page of history, or (with `more`) the next one.
    pub fn load_runs(&mut self, id: &str, more: bool, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc.clone() else {
            return;
        };
        if self.runs_loading && more {
            return;
        }
        self.runs_loading = true;
        cx.notify();
        let generation = self.generation;
        let target = id.to_string();
        let skip = if more { self.runs.len() as i64 } else { 0 };
        let call = rpc.call::<methods::AutomationsRuns>(&AutomationRunsQuery {
            id: target.clone(),
            skip,
        });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            this.update(cx, |s, cx| {
                if s.generation != generation || s.selected.as_deref() != Some(target.as_str()) {
                    return;
                }
                s.runs_loading = false;
                match result {
                    Ok(page) => {
                        s.runs_failed = false;
                        if more {
                            for run in page.items {
                                if !s.runs.iter().any(|r| r.id == run.id) {
                                    s.runs.push(run);
                                }
                            }
                        } else {
                            // The newest page in front of anything older
                            // already shown, each run once.
                            let mut merged = page.items;
                            for run in std::mem::take(&mut s.runs) {
                                if !merged.iter().any(|r| r.id == run.id) {
                                    merged.push(run);
                                }
                            }
                            s.runs = merged;
                        }
                        s.runs_more = page.has_more;
                    }
                    Err(e) => {
                        log::warn!("automations.runs: {e}");
                        s.runs_failed = true;
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// Makes `id` active or paused.
    pub fn set_active(&mut self, id: &str, active: bool, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc.clone() else {
            return;
        };
        self.busy = true;
        self.change_error = None;
        cx.notify();
        let generation = self.generation;
        let call = rpc.call::<methods::AutomationsSetActive>(&AutomationToggle {
            id: id.to_string(),
            active,
        });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            this.update(cx, |s, cx| {
                if s.generation != generation {
                    return;
                }
                s.busy = false;
                match result {
                    Ok(detail) => {
                        if s.selected.as_deref() == Some(detail.summary.id.as_str()) {
                            s.detail = Some(detail);
                        }
                    }
                    Err(e) => {
                        log::warn!("automations.setActive: {e}");
                        s.change_error = Some(e);
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// Run Now for `id`.
    pub fn run(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc.clone() else {
            return;
        };
        self.progress.insert(
            id.to_string(),
            AutomationRunProgress {
                id: id.to_string(),
                phase: "requesting".into(),
                run: None,
                failure: None,
            },
        );
        cx.notify();
        let generation = self.generation;
        let call = rpc.call::<methods::AutomationsRun>(&AutomationRef { id: id.to_string() });
        let target = id.to_string();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            this.update(cx, |s, cx| {
                if s.generation != generation {
                    return;
                }
                match result {
                    Ok(progress) => s.on_progress(progress, cx),
                    Err(e) => {
                        log::warn!("automations.run: {e}");
                        s.progress.insert(
                            target.clone(),
                            AutomationRunProgress {
                                id: target.clone(),
                                phase: "idle".into(),
                                run: None,
                                failure: Some("failed".into()),
                            },
                        );
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn on_progress(&mut self, progress: AutomationRunProgress, cx: &mut Context<Self>) {
        let id = progress.id.clone();
        let ended = matches!(progress.phase.as_str(), "finished" | "failed");
        let before = self.progress.get(&id).map(|p| p.phase.clone());
        self.progress.insert(id.clone(), progress);
        if ended
            && before.as_deref() != self.progress.get(&id).map(|p| p.phase.as_str())
            && self.selected.as_deref() == Some(id.as_str())
        {
            self.load_detail(&id, true, cx);
        }
        cx.notify();
    }

    /// Deletes `id`; the list comes back without it.
    pub fn delete(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc.clone() else {
            return;
        };
        self.busy = true;
        self.change_error = None;
        cx.notify();
        let generation = self.generation;
        let target = id.to_string();
        let call = rpc.call::<methods::AutomationsDelete>(&AutomationRef { id: id.to_string() });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            this.update(cx, |s, cx| {
                if s.generation != generation {
                    return;
                }
                s.busy = false;
                match result {
                    Ok(list) => {
                        s.progress.remove(&target);
                        if s.selected.as_deref() == Some(target.as_str()) {
                            s.select(None, cx);
                        }
                        s.adopt(list, cx);
                    }
                    Err(e) => {
                        log::warn!("automations.delete: {e}");
                        s.change_error = Some(e);
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// `automations.changed`: the list as the daemon now holds it, and the
    /// selected task read again.
    fn changed(&mut self, cx: &mut Context<Self>) {
        if !self.wanted {
            return;
        }
        self.fetch_list(AutomationQuery::default(), cx);
        if let Some(id) = self.selected.clone() {
            self.load_detail(&id, false, cx);
        }
    }

    /// Another account (or none): everything goes.
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.generation += 1;
        *self = Self {
            rpc: self.rpc.take(),
            generation: self.generation,
            wanted: self.wanted,
            status: "all".into(),
            ..Self::default()
        };
        cx.notify();
        // A pane still showing lists the new account's tasks.
        if self.wanted {
            self.fetch_list(AutomationQuery::default(), cx);
        }
    }
}

/// Follows the daemon's events and the account for `stores.tasks`.
pub fn wire(stores: &Stores, cx: &mut App) {
    stores.connection.update(cx, |c, _| {
        c.subscribe(
            "tasks",
            &[
                events::AUTOMATIONS_CHANGED,
                events::AUTOMATIONS_RUN_PROGRESS,
            ],
            vec![],
        )
    });
    {
        let s = stores.clone();
        cx.subscribe(&stores.connection, move |_, event, cx| match event {
            ConnectionEvent::Connected { .. } | ConnectionEvent::Gap => {
                s.tasks.update(cx, |t, cx| {
                    if t.wanted {
                        t.show(cx);
                    }
                });
            }
            ConnectionEvent::Daemon(event) => match event.as_ref() {
                Event::AutomationsChanged => s.tasks.update(cx, |t, cx| t.changed(cx)),
                Event::AutomationsRunProgress(progress) => {
                    let progress = progress.clone();
                    s.tasks.update(cx, |t, cx| t.on_progress(progress, cx));
                }
                _ => {}
            },
            _ => {}
        })
        .detach();
    }
    let last: std::rc::Rc<std::cell::RefCell<Option<Option<String>>>> = Default::default();
    let s = stores.clone();
    cx.observe(&stores.accounts, move |accounts, cx| {
        let account = accounts
            .read(cx)
            .list
            .as_ref()
            .and_then(|l| l.active_account_id.clone());
        let changed = last
            .borrow()
            .as_ref()
            .is_some_and(|before| *before != account);
        *last.borrow_mut() = Some(account);
        if changed {
            s.tasks.update(cx, |t, cx| t.reset(cx));
        }
    })
    .detach();
}

#[cfg(test)]
mod tests {
    use conduit_protocol::{AutomationRuns, AutomationScheduleDto, AutomationSummary};
    use gpui_kit::{AppContext as _, TestAppContext};

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    fn detail(id: &str) -> AutomationDetail {
        AutomationDetail {
            summary: AutomationSummary {
                id: id.into(),
                name: "Digest".into(),
                active: true,
                schedule: AutomationScheduleDto {
                    kind: "daily".into(),
                    year: 0,
                    month: 0,
                    day: 0,
                    hour: 9,
                    minute: 0,
                    days: vec![],
                    rrule: "RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0".into(),
                },
                next_run_at: None,
                last_run_at: None,
                last_run_failed: false,
                agent: None,
            },
            prompt: String::new(),
            model_id: String::new(),
            model_name: None,
            target: "chat".into(),
            channel_id: None,
            channel_name: None,
            folder_id: None,
            folder_name: None,
            terminal: false,
            terminal_id: None,
            terminal_name: None,
            working_directory: None,
            agent: None,
            next_runs: vec![],
        }
    }

    fn progress(id: &str, phase: &str) -> AutomationRunProgress {
        AutomationRunProgress {
            id: id.into(),
            phase: phase.into(),
            run: None,
            failure: None,
        }
    }

    #[gpui_kit::test]
    fn a_finished_run_reads_the_task_and_its_history_again(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AutomationsGet>(detail("t1"));
        daemon.returns::<methods::AutomationsRunState>(progress("t1", "idle"));
        daemon.returns::<methods::AutomationsRuns>(AutomationRuns::default());
        daemon.returns::<methods::AutomationsRun>(progress("t1", "waiting"));
        let store = cx.new(|_| TasksStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.select(Some("t1".into()), cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| assert!(s.detail.is_some()));
        store.update(cx, |s, cx| s.run("t1", cx));
        store.read_with(cx, |s, _| assert_eq!(s.progress["t1"].phase, "requesting"));
        cx.run_until_parked();
        store.read_with(cx, |s, _| assert_eq!(s.progress["t1"].phase, "waiting"));
        let gets = daemon.calls::<methods::AutomationsGet>().len();
        // The daemon keeps where the run stands.
        daemon.returns::<methods::AutomationsRunState>(progress("t1", "finished"));
        store.update(cx, |s, cx| s.on_progress(progress("t1", "finished"), cx));
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::AutomationsGet>().len(), gets + 1);
        assert_eq!(daemon.calls::<methods::AutomationsRuns>().len(), 2);
        // The same step again changes nothing.
        store.update(cx, |s, cx| s.on_progress(progress("t1", "finished"), cx));
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::AutomationsGet>().len(), gets + 1);
    }

    #[gpui_kit::test]
    fn search_and_filter_list_again_and_show_all_clears_both(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AutomationsList>(AutomationList {
            available: true,
            ..Default::default()
        });
        let store = cx.new(|_| TasksStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.search(" digest ", cx);
            s.filter("paused", cx);
            s.show_all(cx);
        });
        cx.run_until_parked();
        let calls = daemon.calls::<methods::AutomationsList>();
        assert_eq!(calls[0]["query"], "digest");
        assert_eq!(calls[1]["status"], "paused");
        assert_eq!(calls[2]["query"], "");
        assert_eq!(calls[2]["status"], "all");
        store.read_with(cx, |s, _| {
            assert!(s.query.is_empty() && s.status == "all");
            assert!(s.list.is_some() && !s.loading);
        });
    }
}
