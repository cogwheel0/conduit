//! Settings › Data Controls, the phone's page behind Advanced: what the
//! account-wide actions reach (chats only on this Mac, changes the server
//! hasn't received, and Sync Now), the whole library exported as Open
//! WebUI's JSON and imported back, and Archive, Unarchive, Remove Share
//! Links and Delete for every chat. Each asks first with a native sheet.

use std::path::PathBuf;
use std::rc::Rc;

use conduit_components::views::kit::{Button, setting_row};
use conduit_components::views::settings::settings_section;
use conduit_protocol::{
    ChatDataSummary, DataActionResult, DataDeleteAll, DataExportRequest, DataImportRequest,
    NoParams, methods,
};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncWindowContext, Context, PathPromptOptions, SharedString, WeakEntity,
    Window, div, px,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::views::forms;

use super::controls;

/// The account-wide actions.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Bulk {
    Archive,
    Unarchive,
    Unshare,
    Delete,
}

/// What the last action said.
#[derive(Clone, Debug, PartialEq)]
pub struct Outcome {
    pub ok: bool,
    pub text: String,
}

pub struct DataControlsPane {
    stores: Stores,
    pub summary: Option<ChatDataSummary>,
    /// The first summary could not be read: Try Again, not "Loading".
    pub load_failed: bool,
    pub busy: bool,
    pub outcome: Option<Outcome>,
}

impl DataControlsPane {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let mut this = Self {
            stores,
            summary: None,
            load_failed: false,
            busy: false,
            outcome: None,
        };
        this.refresh(window, cx);
        this
    }

    fn rpc(&self, cx: &App) -> crate::stores::rpc::Rpc {
        self.stores.connection.read(cx).rpc()
    }

    /// The active account: a confirmed action goes ahead only while it is
    /// still the one the confirmation named.
    fn account(&self, cx: &App) -> Option<String> {
        self.stores.accounts.read(cx).active().map(|a| a.id.clone())
    }

    /// The account and server the confirmations name.
    fn owner(&self, cx: &App) -> (String, String) {
        self.stores
            .accounts
            .read(cx)
            .active()
            .map(|a| {
                (
                    crate::views::privacy::name(&crate::stores::accounts::display_name(a), cx),
                    crate::views::privacy::host(&a.connection.name, cx),
                )
            })
            .unwrap_or_default()
    }

    pub fn refresh(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let call = self.rpc(cx).call::<methods::DataSummary>(&NoParams);
        self.load(call, window, cx);
    }

    fn load(
        &mut self,
        call: impl std::future::Future<Output = Result<ChatDataSummary, conduit_daemon::RpcError>>
        + Send
        + 'static,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    s.busy = false;
                    match result {
                        Ok(summary) => {
                            s.summary = Some(summary);
                            s.load_failed = false;
                        }
                        Err(e) => {
                            log::warn!("data.summary: {e}");
                            s.load_failed = true;
                            // Sync Now (or a refresh) failed with the page up.
                            if s.summary.is_some() {
                                s.outcome = Some(Outcome {
                                    ok: false,
                                    text: cx.l10n().desktop_action_failed(),
                                });
                            }
                        }
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    pub fn sync(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.busy = true;
        cx.notify();
        let call = self.rpc(cx).call::<methods::DataSync>(&NoParams);
        self.load(call, window, cx);
    }

    /// A failure's sentence, in the phone's words.
    pub fn failure_text(result: &DataActionResult, importing: bool, l10n: &L10n) -> String {
        match result.failure.as_deref() {
            None => String::new(),
            Some("malformedExport") => l10n.chat_data_controls_export_failed(),
            Some("cancelled") => l10n.chat_data_controls_export_stopped(),
            Some("unrecognizedChat") if result.index.is_some() => {
                l10n.chat_data_controls_import_bad_entry(result.index.unwrap_or(0) + 1)
            }
            Some("notJson" | "notAList" | "unrecognizedChat" | "invalidField") => {
                l10n.chat_data_controls_import_invalid()
            }
            Some("emptyImport") => l10n.chat_data_controls_import_empty(),
            Some("fileTooLarge") => l10n.chat_data_controls_import_too_large(),
            Some("forbidden") => l10n.chat_data_controls_forbidden(),
            Some("pendingWork") => l10n.chat_data_controls_work_changed(),
            Some("responseRunning") => l10n.chat_data_controls_response_running(),
            Some("localWorkChanged") => l10n.chat_data_controls_local_changed(),
            Some("serverRefused") => l10n.chat_data_controls_refused(),
            Some("outcomeUnknown") if importing => l10n.chat_data_controls_import_unknown(),
            Some("outcomeUnknown") => l10n.chat_data_controls_unknown(),
            Some("ownerChanged") => l10n.chat_data_controls_owner_changed(),
            Some("accountUnknown") => l10n.chat_data_controls_account_unknown(),
            Some(_) => l10n.desktop_action_failed(),
        }
    }

    fn finish(&mut self, outcome: Outcome, window: &mut Window, cx: &mut Context<Self>) {
        self.outcome = Some(outcome);
        self.refresh(window, cx);
    }

    /// Export…: asks, then where to save, then writes the library there.
    pub fn export(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let l10n = cx.l10n().clone();
        let (account, server) = self.owner(cx);
        let spec = SheetSpec::new(
            l10n.chat_data_controls_export_confirm_title(),
            l10n.chat_data_controls_export_confirm_message(&account, &server),
            l10n.chat_data_controls_export_action(),
            l10n.cancel(),
        );
        let ask = present_sheet(window, spec, cx);
        let name = format!("chat-export-{}.json", chrono::Utc::now().timestamp_millis());
        let confirmed_for = self.account(cx);
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                if !ask.await {
                    return;
                }
                let asked = cx.update(|_, cx| cx.prompt_for_new_path(&downloads(), Some(&name)));
                let Ok(asked) = asked else { return };
                let Ok(Ok(Some(path))) = asked.await else {
                    return;
                };
                let _ = this.update_in(cx, |s, window, cx| {
                    if s.account(cx) == confirmed_for {
                        s.export_to(path, window, cx);
                    }
                });
            },
        )
        .detach();
    }

    /// Writes the library to `path` (the E2E pass calls this directly).
    pub fn export_to(&mut self, path: PathBuf, window: &mut Window, cx: &mut Context<Self>) {
        let call = self
            .rpc(cx)
            .call::<methods::DataExport>(&DataExportRequest {
                path: path.to_string_lossy().to_string(),
            });
        self.busy = true;
        self.outcome = None;
        cx.notify();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update_in(cx, |s, window, cx| {
                    let l10n = cx.l10n().clone();
                    let outcome = match result {
                        Ok(r) if r.failure.is_none() && r.count == 0 => Outcome {
                            ok: true,
                            text: l10n.chat_data_controls_export_empty(),
                        },
                        Ok(r) if r.failure.is_none() => Outcome {
                            ok: true,
                            text: l10n.chat_data_controls_export_ready(r.count),
                        },
                        Ok(r) => Outcome {
                            ok: false,
                            text: Self::failure_text(&r, false, &l10n),
                        },
                        Err(e) => {
                            log::warn!("data.export: {e}");
                            Outcome {
                                ok: false,
                                text: l10n.desktop_action_failed(),
                            }
                        }
                    };
                    s.finish(outcome, window, cx);
                });
            },
        )
        .detach();
    }

    /// Import…: the file, its counts, a confirmation, then the import.
    pub fn import(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let paths = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: None,
        });
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let Ok(Ok(Some(mut picked))) = paths.await else {
                    return;
                };
                let Some(path) = picked.pop() else { return };
                let _ = this.update_in(cx, |s, window, cx| s.import_from(path, window, cx));
            },
        )
        .detach();
    }

    pub fn import_from(&mut self, path: PathBuf, window: &mut Window, cx: &mut Context<Self>) {
        let request = DataImportRequest {
            path: path.to_string_lossy().to_string(),
        };
        let rpc = self.rpc(cx);
        let preview = rpc.call::<methods::DataPreviewImport>(&request);
        let confirmed_for = self.account(cx);
        self.busy = true;
        self.outcome = None;
        cx.notify();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let preview = preview.await;
                let ask = this.update_in(cx, |s, window, cx| {
                    let l10n = cx.l10n().clone();
                    match &preview {
                        Ok(p) if p.failure.is_none() => {
                            let (account, server) = s.owner(cx);
                            let spec = SheetSpec::new(
                                l10n.chat_data_controls_import_confirm_title(),
                                l10n.chat_data_controls_import_confirm_message(
                                    &account, &server, p.count, p.messages,
                                ),
                                l10n.chat_data_controls_import_action(),
                                l10n.cancel(),
                            );
                            Some(present_sheet(window, spec, cx))
                        }
                        Ok(p) => {
                            s.busy = false;
                            s.outcome = Some(Outcome {
                                ok: false,
                                text: Self::failure_text(p, true, &l10n),
                            });
                            cx.notify();
                            None
                        }
                        Err(e) => {
                            log::warn!("data.previewImport: {e}");
                            s.busy = false;
                            s.outcome = Some(Outcome {
                                ok: false,
                                text: l10n.desktop_action_failed(),
                            });
                            cx.notify();
                            None
                        }
                    }
                });
                let Ok(Some(ask)) = ask else { return };
                let confirmed = ask.await;
                // Another account by now: nothing goes into it.
                let same = this
                    .update(cx, |s, cx| {
                        let same = s.account(cx) == confirmed_for;
                        if !confirmed || !same {
                            s.busy = false;
                            cx.notify();
                        }
                        same
                    })
                    .unwrap_or(false);
                if !confirmed || !same {
                    return;
                }
                let result = rpc.call::<methods::DataImport>(&request).await;
                let _ = this.update_in(cx, |s, window, cx| {
                    let l10n = cx.l10n().clone();
                    let outcome = match result {
                        Ok(r) if r.failure.is_none() => {
                            let mut text = l10n.chat_data_controls_imported(r.count);
                            if r.stored < r.count {
                                text = format!(
                                    "{text} {}",
                                    l10n.chat_data_controls_imported_sync_note()
                                );
                            }
                            Outcome { ok: true, text }
                        }
                        Ok(r) => Outcome {
                            ok: false,
                            text: Self::failure_text(&r, true, &l10n),
                        },
                        Err(e) => {
                            log::warn!("data.import: {e}");
                            Outcome {
                                ok: false,
                                text: l10n.desktop_action_failed(),
                            }
                        }
                    };
                    s.finish(outcome, window, cx);
                });
            },
        )
        .detach();
    }

    /// An account-wide action, after its sheet.
    pub fn bulk(&mut self, action: Bulk, window: &mut Window, cx: &mut Context<Self>) {
        let l10n = cx.l10n().clone();
        let (account, server) = self.owner(cx);
        let unsent = self.summary.as_ref().map_or(0, |s| s.unsent);
        let spec = match action {
            Bulk::Archive => SheetSpec::new(
                l10n.chat_data_controls_archive_all(),
                l10n.chat_data_controls_archive_all_message(),
                l10n.chat_data_controls_archive_all_confirm(),
                l10n.cancel(),
            ),
            Bulk::Unarchive => SheetSpec::new(
                l10n.chat_data_controls_unarchive_all(),
                l10n.chat_data_controls_unarchive_all_message(),
                l10n.chat_data_controls_unarchive_all_confirm(),
                l10n.cancel(),
            ),
            Bulk::Unshare => SheetSpec::new(
                l10n.chat_data_controls_unshare_all(),
                l10n.chat_data_controls_unshare_all_message(),
                l10n.chat_data_controls_unshare_all_confirm(),
                l10n.cancel(),
            )
            .destructive(),
            Bulk::Delete => {
                let mut message = l10n.chat_data_controls_delete_all_message(&account, &server);
                if unsent > 0 {
                    message = format!(
                        "{message}\n\n{}",
                        l10n.chat_data_controls_delete_unsent_message(unsent, 0)
                    );
                }
                SheetSpec::new(
                    l10n.chat_data_controls_delete_all(),
                    message,
                    if unsent > 0 {
                        l10n.chat_data_controls_discard_and_delete_confirm()
                    } else {
                        l10n.chat_data_controls_delete_all_confirm()
                    },
                    l10n.cancel(),
                )
                .destructive()
            }
        };
        let ask = present_sheet(window, spec, cx);
        let rpc = self.rpc(cx);
        let confirmed_for = self.account(cx);
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                if !ask.await {
                    return;
                }
                // Confirmed for one account, never run on another.
                let same = this
                    .update(cx, |s, cx| {
                        let same = s.account(cx) == confirmed_for;
                        if same {
                            s.busy = true;
                            s.outcome = None;
                            cx.notify();
                        }
                        same
                    })
                    .unwrap_or(false);
                if !same {
                    return;
                }
                let result = match action {
                    Bulk::Archive => rpc.call::<methods::DataArchiveAll>(&NoParams).await,
                    Bulk::Unarchive => rpc.call::<methods::DataUnarchiveAll>(&NoParams).await,
                    Bulk::Unshare => rpc.call::<methods::DataUnshareAll>(&NoParams).await,
                    Bulk::Delete => {
                        rpc.call::<methods::DataDeleteAll>(&DataDeleteAll {
                            discard_unsent: unsent > 0,
                        })
                        .await
                    }
                };
                let _ = this.update_in(cx, |s, window, cx| {
                    let l10n = cx.l10n().clone();
                    let outcome = match result {
                        Ok(r) if r.failure.is_none() => Outcome {
                            ok: true,
                            text: l10n.desktop_chats_changed(r.count),
                        },
                        Ok(r) => Outcome {
                            ok: false,
                            text: Self::failure_text(&r, false, &l10n),
                        },
                        Err(e) => {
                            log::warn!("data: {e}");
                            Outcome {
                                ok: false,
                                text: l10n.desktop_action_failed(),
                            }
                        }
                    };
                    s.finish(outcome, window, cx);
                });
            },
        )
        .detach();
    }

    fn action_row(
        &self,
        id: &'static str,
        title: String,
        button: String,
        danger: bool,
        run: Run,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let view = cx.entity().downgrade();
        let mut b = Button::new(id, button).disabled(self.busy);
        if danger {
            b = b.danger();
        }
        let b = b.on_click(Rc::new(move |_, window, cx| {
            let run = run.clone();
            let _ = view.update(cx, |v, cx| run(v, window, cx));
        }));
        setting_row(title, None, b, cx).into_any_element()
    }
}

/// What a row's button runs.
type Run = Rc<dyn Fn(&mut DataControlsPane, &mut Window, &mut Context<DataControlsPane>)>;

/// `~/Downloads`, or home.
fn downloads() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"));
    let downloads = home.join("Downloads");
    if downloads.is_dir() { downloads } else { home }
}

impl Render for DataControlsPane {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let Some(summary) = self.summary.clone() else {
            if self.load_failed {
                let retry = Button::new("data-retry", l10n.desktop_try_again())
                    .disabled(self.busy)
                    .on_click(Rc::new({
                        let this = cx.entity().downgrade();
                        move |_, window, cx| {
                            let _ = this.update(cx, |s, cx| {
                                s.busy = true;
                                s.refresh(window, cx);
                            });
                        }
                    }));
                return div()
                    .flex()
                    .flex_col()
                    .gap(px(10.))
                    .child(controls::lead(l10n.desktop_action_failed(), cx))
                    .child(div().child(retry));
            }
            return div().child(controls::lead(l10n.desktop_loading(), cx));
        };
        if !summary.available {
            return div().child(controls::lead(l10n.chat_data_controls_no_account(), cx));
        }
        let (account, server) = self.owner(cx);
        let mut sections: Vec<AnyElement> = vec![
            controls::lead(l10n.chat_data_controls_stored_on(&account, &server), cx)
                .into_any_element(),
        ];
        if summary.local_only > 0 || summary.unsent > 0 {
            let mut rows = vec![];
            if summary.local_only > 0 {
                rows.push(
                    setting_row(
                        l10n.chat_data_controls_local_only(summary.local_only),
                        None,
                        div(),
                        cx,
                    )
                    .into_any_element(),
                );
            }
            let view = cx.entity().downgrade();
            let sync = Button::new("data-sync", l10n.chat_data_controls_sync_now())
                .disabled(self.busy)
                .on_click(Rc::new(move |_, window, cx| {
                    let _ = view.update(cx, |v, cx| v.sync(window, cx));
                }));
            rows.push(
                setting_row(
                    if summary.unsent > 0 {
                        l10n.chat_data_controls_unsent(summary.unsent)
                    } else {
                        l10n.chat_data_controls_unsynced_note()
                    },
                    None,
                    sync,
                    cx,
                )
                .into_any_element(),
            );
            sections.push(
                settings_section(
                    SharedString::default(),
                    Some(l10n.chat_data_controls_unsynced_note().into()),
                    rows,
                    cx,
                )
                .into_any_element(),
            );
        }
        let mut backup = vec![];
        if summary.can_export {
            backup.push(self.action_row(
                "data-export",
                l10n.chat_data_controls_export_library(),
                l10n.desktop_export_ellipsis(),
                false,
                Rc::new(|v, w, cx| v.export(w, cx)),
                cx,
            ));
        }
        if summary.can_import {
            backup.push(self.action_row(
                "data-import",
                l10n.chat_data_controls_import(),
                l10n.desktop_import_ellipsis(),
                false,
                Rc::new(|v, w, cx| v.import(w, cx)),
                cx,
            ));
        }
        if !backup.is_empty() {
            sections.push(
                settings_section(
                    l10n.chat_data_controls_backup_section(),
                    Some(
                        format!(
                            "{}\n\n{}",
                            l10n.chat_data_controls_media_note(),
                            l10n.chat_data_controls_import_footer()
                        )
                        .into(),
                    ),
                    backup,
                    cx,
                )
                .into_any_element(),
            );
        }
        let mut manage = vec![
            self.action_row(
                "data-archive-all",
                l10n.chat_data_controls_archive_all(),
                l10n.desktop_archive_ellipsis(),
                false,
                Rc::new(|v, w, cx| v.bulk(Bulk::Archive, w, cx)),
                cx,
            ),
            self.action_row(
                "data-unarchive-all",
                l10n.chat_data_controls_unarchive_all(),
                l10n.desktop_unarchive_ellipsis(),
                false,
                Rc::new(|v, w, cx| v.bulk(Bulk::Unarchive, w, cx)),
                cx,
            ),
            self.action_row(
                "data-unshare-all",
                l10n.chat_data_controls_unshare_all(),
                l10n.desktop_remove_ellipsis(),
                false,
                Rc::new(|v, w, cx| v.bulk(Bulk::Unshare, w, cx)),
                cx,
            ),
        ];
        if summary.can_delete {
            manage.push(self.action_row(
                "data-delete-all",
                l10n.chat_data_controls_delete_all(),
                l10n.desktop_delete_ellipsis(),
                true,
                Rc::new(|v, w, cx| v.bulk(Bulk::Delete, w, cx)),
                cx,
            ));
        }
        sections.push(
            settings_section(
                l10n.chat_data_controls_manage_section(),
                Some(
                    l10n.chat_data_controls_delete_footer(&account, &server)
                        .into(),
                ),
                manage,
                cx,
            )
            .into_any_element(),
        );
        if let Some(outcome) = &self.outcome {
            sections
                .push(forms::form_note(outcome.text.clone(), outcome.ok, cx).into_any_element());
        }
        div().flex().flex_col().gap(px(22.)).children(sections)
    }
}

#[cfg(test)]
mod tests {
    use gpui_kit::TestAppContext;

    use super::*;
    use crate::shell::sheet::AutoAnswer;
    use crate::stores::accounts::tests::{account, list};
    use crate::stores::rpc::fake::FakeDaemon;

    fn summary() -> ChatDataSummary {
        serde_json::from_value(serde_json::json!({
            "available": true, "canExport": true, "canImport": true, "canDelete": true,
        }))
        .unwrap()
    }

    #[gpui_kit::test]
    fn delete_all_confirmed_for_one_account_never_runs_on_another(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.once::<methods::DataSummary>(Err(conduit_daemon::protocol::error(
            "rpc.timeout",
            "slow",
        )));
        daemon.returns::<methods::DataSummary>(summary());
        let scratch = std::env::temp_dir().join(format!("conduit-data-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            cx.set_global(AutoAnswer(Some(true)));
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
        });
        let s = stores.clone();
        let (view, vcx) =
            cx.add_window_view(move |window, cx| DataControlsPane::new(s, window, cx));
        vcx.run_until_parked();
        // The first summary failed: Try Again, never "Loading" for ever.
        view.read_with(vcx, |p, _| assert!(p.summary.is_none() && p.load_failed));
        view.update_in(vcx, |p, window, cx| p.refresh(window, cx));
        vcx.run_until_parked();
        view.read_with(vcx, |p, _| assert!(p.summary.is_some() && !p.load_failed));
        // Confirmed for Avery; Blake is active before it runs.
        view.update_in(vcx, |p, window, cx| p.bulk(Bulk::Delete, window, cx));
        stores.accounts.update(vcx, |a, cx| {
            a.adopt(
                list(vec![
                    account("a", "Avery", false, true),
                    account("b", "Blake", true, true),
                ]),
                cx,
            )
        });
        vcx.run_until_parked();
        assert!(
            daemon.calls::<methods::DataDeleteAll>().is_empty(),
            "Avery's Delete All ran on Blake"
        );
        // Confirmed and still the same account: it runs.
        view.update_in(vcx, |p, window, cx| p.bulk(Bulk::Delete, window, cx));
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::DataDeleteAll>().len(), 1);
    }
}
