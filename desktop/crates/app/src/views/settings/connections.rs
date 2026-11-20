//! Settings › Personal Connections, the phone's page behind Advanced: the
//! account's own tool servers (OpenAPI) and terminals, kept in its Open
//! WebUI settings (`integrations.*`). Each has its switch and Edit…; Add
//! Tool Server… and Add Terminal… open the editor sheet. A chat that
//! chooses a personal tool server (the composer's tools) has its calls run
//! on this Mac, by the daemon.

use std::collections::BTreeMap;
use std::rc::Rc;

use conduit_components::views::kit::{Button, Switch, setting_row};
use conduit_components::views::settings::settings_section;
use conduit_daemon::RpcError;
use conduit_protocol::{
    NoParams, PersonalAccess, PersonalConnectionDto, PersonalConnectionSave, PersonalConnections,
    PersonalEditOp, PersonalKind, methods,
};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, ElementId, SharedString, WeakEntity, Window, div, px,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::views::forms;

use super::connection_editor::{ConnectionEditorSheet, OnChange};
use super::controls;

pub struct PersonalConnectionsPane {
    stores: Stores,
    pub list: Option<PersonalConnections>,
    pub loading: bool,
    /// The newest list read or change answered: an older read's answer,
    /// landing after it, is not shown.
    ticket: u64,
    /// Switches moved and not yet answered, by identity.
    pending: BTreeMap<String, bool>,
    /// Why the last switch was refused.
    pub error: Option<String>,
}

/// The main window's composer reads its tools again, so a personal tool
/// server added, switched or deleted here is offered (or not) at once, as on
/// the phone. Deferred: this runs inside a Settings update.
fn refresh_composer_tools(cx: &mut App) {
    cx.defer(|cx| {
        let Some(view) = cx
            .try_global::<crate::AppState>()
            .and_then(|s| s.main_view.clone())
        else {
            return;
        };
        let pane = view.read(cx).chat_pane.clone();
        let store = pane.read(cx).composer_store.clone();
        store.update(cx, |c, cx| c.refresh_options(cx));
    });
}

/// A save's refusal in the phone's words.
pub fn save_error(e: &RpcError, l10n: &L10n) -> String {
    match e.args.get("reason").map(String::as_str) {
        // Gone, or changed since the editor opened it: the same words.
        Some("notFound" | "changed") => l10n.personal_connections_not_found(),
        Some("duplicate") => l10n.personal_connections_duplicate(),
        Some("rejected") => l10n.personal_connections_save_rejected(),
        Some("accountChanged") => l10n.personal_connections_owner_changed(),
        _ => l10n.personal_connections_save_failed(),
    }
}

impl PersonalConnectionsPane {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let mut this = Self {
            stores,
            list: None,
            loading: false,
            ticket: 0,
            pending: BTreeMap::new(),
            error: None,
        };
        this.refresh(cx);
        let _ = window;
        this
    }

    fn rpc(&self, cx: &App) -> crate::stores::rpc::Rpc {
        self.stores.connection.read(cx).rpc()
    }

    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        self.ticket += 1;
        let ticket = self.ticket;
        self.loading = true;
        cx.notify();
        let call = self.rpc(cx).call::<methods::IntegrationsList>(&NoParams);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                if s.ticket != ticket {
                    return;
                }
                s.loading = false;
                match result {
                    Ok(list) => s.list = Some(list),
                    Err(e) => {
                        log::warn!("integrations.list: {e}");
                        s.list = Some(PersonalConnections {
                            access: PersonalAccess::Allowed,
                            failed: true,
                            ..Default::default()
                        });
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub fn adopt(&mut self, list: PersonalConnections, cx: &mut Context<Self>) {
        // Newer than any read still out.
        self.ticket += 1;
        self.loading = false;
        self.list = Some(list);
        refresh_composer_tools(cx);
        cx.notify();
    }

    /// A row's switch, as it is pressed.
    pub fn press_switch(
        &mut self,
        entry: &PersonalConnectionDto,
        on: bool,
        cx: &mut Context<Self>,
    ) {
        self.set_enabled(entry, on, cx);
    }

    /// Moves the switch at once and saves; a refusal puts it back and says
    /// why.
    fn set_enabled(&mut self, entry: &PersonalConnectionDto, on: bool, cx: &mut Context<Self>) {
        let Some(list) = &self.list else {
            return;
        };
        if self.pending.contains_key(&entry.identity) {
            return;
        }
        self.pending.insert(entry.identity.clone(), on);
        self.error = None;
        cx.notify();
        let identity = entry.identity.clone();
        let call = self
            .rpc(cx)
            .call::<methods::IntegrationsSave>(&PersonalConnectionSave {
                owner: list.owner.clone(),
                kind: entry.kind,
                op: PersonalEditOp::SetEnabled,
                identity: Some(identity.clone()),
                draft: None,
                enabled: Some(on),
                fingerprint: None,
            });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.pending.remove(&identity);
                match result {
                    Ok(list) => {
                        if list.saved_for_previous_account {
                            s.error =
                                Some(cx.l10n().personal_connections_saved_for_previous_account());
                        }
                        s.ticket += 1;
                        s.loading = false;
                        s.list = Some(list);
                        refresh_composer_tools(cx);
                    }
                    Err(e) => {
                        log::warn!("integrations.save: {e}");
                        s.error = Some(save_error(&e, &cx.l10n().clone()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn clear_notice(&mut self, cx: &mut Context<Self>) {
        let call = self
            .rpc(cx)
            .call::<methods::IntegrationsClearNotice>(&NoParams);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if let Ok(list) = call.await {
                let _ = this.update(cx, |s, cx| s.adopt(list, cx));
            }
        })
        .detach();
    }

    /// Add Tool Server… / Add Terminal… (no entry) or Edit… on one.
    pub fn open_editor(
        &mut self,
        kind: PersonalKind,
        entry: Option<PersonalConnectionDto>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(list) = &self.list else {
            return;
        };
        // A switch still saving: the editor would open on the entry as it
        // was and save that back.
        if entry
            .as_ref()
            .is_some_and(|e| self.pending.contains_key(&e.identity))
        {
            return;
        }
        let pane = cx.entity().downgrade();
        let on_change: OnChange = Rc::new(move |list, cx| {
            let _ = pane.update(cx, |p, cx| p.adopt(list, cx));
        });
        ConnectionEditorSheet::open(
            self.stores.clone(),
            list.owner.clone(),
            kind,
            entry,
            on_change,
            window,
            cx,
        );
    }

    fn section(
        &self,
        kind: PersonalKind,
        entries: &[PersonalConnectionDto],
        l10n: &L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tool = kind == PersonalKind::ToolServer;
        let prefix = if tool {
            "personal-tool"
        } else {
            "personal-terminal"
        };
        let view = cx.entity().downgrade();
        let mut rows: Vec<AnyElement> = vec![];
        if entries.is_empty() {
            rows.push(
                setting_row(
                    if tool {
                        l10n.personal_connections_empty_tool_servers()
                    } else {
                        l10n.personal_connections_empty_terminals()
                    },
                    Some(
                        if tool {
                            l10n.personal_connections_empty_tool_servers_hint()
                        } else {
                            l10n.personal_connections_empty_terminals_hint()
                        }
                        .into(),
                    ),
                    div(),
                    cx,
                )
                .into_any_element(),
            );
        }
        for (i, entry) in entries.iter().enumerate() {
            let pending = self.pending.get(&entry.identity).copied();
            let on = pending.unwrap_or(entry.enabled);
            let switch = {
                let view = view.clone();
                let entry = entry.clone();
                Switch::new(
                    ElementId::NamedInteger(format!("{prefix}-switch").into(), i as u64),
                    entry.name.clone(),
                    on,
                )
                .disabled(pending.is_some())
                .on_click(Rc::new(move |_, _, cx| {
                    let entry = entry.clone();
                    let _ = view.update(cx, |v, cx| v.set_enabled(&entry, !on, cx));
                }))
            };
            let edit = {
                let view = view.clone();
                let entry = entry.clone();
                Button::new(
                    ElementId::NamedInteger(format!("{prefix}-edit").into(), i as u64),
                    l10n.desktop_edit_ellipsis(),
                )
                .disabled(pending.is_some())
                .on_click(Rc::new(move |_, window, cx| {
                    let entry = entry.clone();
                    let _ = view.update(cx, |v, cx| {
                        v.open_editor(entry.kind, Some(entry), window, cx)
                    });
                }))
            };
            let subtitle: SharedString = if entry.editable {
                entry.endpoint.clone().into()
            } else {
                l10n.personal_connections_unsupported().into()
            };
            let name = if entry.name.trim().is_empty() {
                l10n.tool_server()
            } else {
                entry.name.clone()
            };
            rows.push(
                setting_row(
                    name,
                    Some(subtitle),
                    div()
                        .flex()
                        .items_center()
                        .gap(px(10.))
                        .child(edit)
                        .child(switch),
                    cx,
                )
                .into_any_element(),
            );
        }
        let add = {
            let view = view.clone();
            Button::new(
                format!("{prefix}-add"),
                if tool {
                    l10n.desktop_add_tool_server_ellipsis()
                } else {
                    l10n.desktop_add_terminal_ellipsis()
                },
            )
            .on_click(Rc::new(move |_, window, cx| {
                let _ = view.update(cx, |v, cx| v.open_editor(kind, None, window, cx));
            }))
        };
        rows.push(
            controls::buttons(vec![add.into_any_element()])
                .p(px(10.))
                .into_any_element(),
        );
        let footer = (!tool && entries.len() > 1)
            .then(|| SharedString::from(l10n.personal_connections_terminal_one_active()));
        settings_section(
            if tool {
                l10n.tool_servers()
            } else {
                l10n.personal_connections_terminals()
            },
            footer,
            rows,
            cx,
        )
        .into_any_element()
    }
}

impl Render for PersonalConnectionsPane {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let Some(list) = self.list.clone() else {
            return div().child(controls::lead(l10n.desktop_loading(), cx));
        };
        let blocked = match list.access {
            PersonalAccess::Allowed | PersonalAccess::MovedToTether | PersonalAccess::Unknown => {
                None
            }
            PersonalAccess::NoAccount => Some(l10n.personal_connections_no_account()),
            PersonalAccess::ServerDisabled => Some(l10n.personal_connections_unavailable_server()),
            PersonalAccess::NoPermission => {
                Some(l10n.personal_connections_unavailable_permission())
            }
        };
        if let Some(text) = blocked {
            return div().child(controls::lead(text, cx));
        }
        let view = cx.entity().downgrade();
        if list.failed {
            return div()
                .flex()
                .flex_col()
                .gap(px(12.))
                .child(controls::lead(l10n.personal_connections_load_failed(), cx))
                .child(controls::buttons(vec![
                    Button::new("personal-connections-retry", l10n.retry())
                        .on_click(Rc::new(move |_, _, cx| {
                            let _ = view.update(cx, |v, cx| v.refresh(cx));
                        }))
                        .into_any_element(),
                ]));
        }
        if list.access == PersonalAccess::MovedToTether {
            return moved(&list, &l10n, cx);
        }
        let account = crate::views::privacy::name(&list.account_name, cx);
        let server = crate::views::privacy::host(&list.server_name, cx);
        let mut sections: Vec<AnyElement> = vec![
            div()
                .flex()
                .flex_col()
                .gap(px(4.))
                .child(controls::lead(
                    l10n.personal_connections_stored_on(&account, &server),
                    cx,
                ))
                .child(controls::lead(
                    l10n.personal_connections_key_storage_note(),
                    cx,
                ))
                .into_any_element(),
        ];
        if !list.cleared.is_empty() {
            let names = list
                .cleared
                .iter()
                .map(|n| {
                    if n.is_empty() {
                        l10n.tool_server()
                    } else {
                        n.clone()
                    }
                })
                .collect::<Vec<_>>()
                .join(", ");
            let view = view.clone();
            sections.push(
                settings_section(
                    SharedString::default(),
                    None,
                    vec![
                        setting_row(
                            l10n.personal_connections_selection_cleared(&names),
                            None,
                            Button::new("personal-connections-cleared-ok", l10n.ok()).on_click(
                                Rc::new(move |_, _, cx| {
                                    let _ = view.update(cx, |v, cx| v.clear_notice(cx));
                                }),
                            ),
                            cx,
                        )
                        .into_any_element(),
                    ],
                    cx,
                )
                .into_any_element(),
            );
        }
        sections.push(self.section(PersonalKind::ToolServer, &list.tool_servers, &l10n, cx));
        sections.push(self.section(PersonalKind::Terminal, &list.terminals, &l10n, cx));
        if let Some(error) = &self.error {
            sections.push(
                forms::form_error("personal-connections-error", error.clone(), cx)
                    .into_any_element(),
            );
        }
        div().flex().flex_col().gap(px(22.)).children(sections)
    }
}

/// A server that moved personal connections to Tether (Open WebUI 0.13.4):
/// why they no longer apply, and the saved ones as they are, to read only.
fn moved(list: &PersonalConnections, l10n: &L10n, cx: &App) -> gpui_kit::Div {
    let mut sections: Vec<AnyElement> = vec![
        controls::lead(l10n.personal_connections_moved_to_tether(), cx)
            .debug_selector(|| "personal-connections-moved".into())
            .into_any_element(),
    ];
    if !list.tool_servers.is_empty() || !list.terminals.is_empty() {
        sections.push(
            controls::lead(l10n.personal_connections_saved_list_unused(), cx).into_any_element(),
        );
    }
    for (title, entries) in [
        (l10n.tool_servers(), &list.tool_servers),
        (l10n.personal_connections_terminals(), &list.terminals),
    ] {
        if entries.is_empty() {
            continue;
        }
        let rows = entries
            .iter()
            .map(|entry| {
                let name = if entry.name.trim().is_empty() {
                    l10n.tool_server()
                } else {
                    entry.name.clone()
                };
                let place = if entry.editable {
                    entry.endpoint.clone()
                } else {
                    l10n.personal_connections_unsupported()
                };
                let subtitle = if entry.enabled {
                    place
                } else {
                    format!("{place} \u{b7} {}", l10n.disabled())
                };
                setting_row(name, Some(subtitle.into()), div(), cx).into_any_element()
            })
            .collect();
        sections.push(settings_section(title, None, rows, cx).into_any_element());
    }
    div().flex().flex_col().gap(px(22.)).children(sections)
}

#[cfg(test)]
mod tests {
    use conduit_protocol::{PersonalConnectionDto, PersonalConnections, PersonalKind, methods};
    use gpui_kit::{AppContext as _, Entity, VisualTestContext};
    use serde_json::json;

    use super::PersonalConnectionsPane;
    use crate::stores::Stores;
    use crate::views::settings::connection_editor::ConnectionEditorSheet;
    use crate::views::sheet::{self, bench::bench};

    fn named(name: &str) -> PersonalConnections {
        let entry: PersonalConnectionDto = serde_json::from_value(json!({
            "kind": "toolServer",
            "identity": "conduit-1",
            "name": name,
            "url": "https://tools.example.com",
            "enabled": true,
        }))
        .unwrap();
        PersonalConnections {
            owner: "p1".into(),
            tool_servers: vec![entry],
            ..Default::default()
        }
    }

    fn pane(stores: &Stores, vcx: &mut VisualTestContext) -> Entity<PersonalConnectionsPane> {
        let stores = stores.clone();
        vcx.update(|window, cx| cx.new(|cx| PersonalConnectionsPane::new(stores, window, cx)))
    }

    /// A server that moved them to Tether says so, and lists the saved ones
    /// with no way to change them: no owner was handed out.
    #[gpui_kit::test]
    fn a_server_that_moved_them_to_tether_says_so(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        let mut moved = named("Tide tables");
        moved.access = conduit_protocol::PersonalAccess::MovedToTether;
        moved.owner = String::new();
        daemon.returns::<methods::IntegrationsList>(moved);
        let (_pane, vcx) =
            vcx.add_window_view(move |window, cx| PersonalConnectionsPane::new(stores, window, cx));
        vcx.run_until_parked();
        vcx.update(|window, cx| window.draw(cx).clear(cx));
        assert!(vcx.debug_bounds("personal-connections-moved").is_some());
    }

    /// A read that lands after a newer one is not shown over it.
    #[gpui_kit::test]
    fn an_older_read_never_replaces_a_newer_list(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.once::<methods::IntegrationsList>(Ok(named("Seed catalogue")));
        daemon.once::<methods::IntegrationsList>(Ok(named("Seed swap")));
        let held = daemon.hold_one::<methods::IntegrationsList>(0);
        let pane = pane(&stores, vcx);
        vcx.run_until_parked();
        pane.update(vcx, |p, cx| p.refresh(cx));
        vcx.run_until_parked();
        drop(held);
        vcx.run_until_parked();
        let shown = pane.read_with(vcx, |p, _| {
            p.list.as_ref().map(|l| l.tool_servers[0].name.clone())
        });
        assert_eq!(shown.as_deref(), Some("Seed swap"));
    }

    /// Edit waits for a switch still saving: the editor would open on the
    /// entry as it was and save that back.
    #[gpui_kit::test]
    fn edit_waits_for_a_switch_still_saving(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::IntegrationsList>(named("Seed catalogue"));
        let pane = pane(&stores, vcx);
        vcx.run_until_parked();
        let entry = pane.read_with(vcx, |p, _| p.list.as_ref().unwrap().tool_servers[0].clone());
        let _held = daemon.hold::<methods::IntegrationsSave>();
        pane.update(vcx, |p, cx| p.press_switch(&entry, false, cx));
        vcx.update(|window, cx| {
            pane.update(cx, |p, cx| {
                p.open_editor(PersonalKind::ToolServer, Some(entry.clone()), window, cx)
            })
        });
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<ConnectionEditorSheet>(cx))
                .is_none(),
            "the editor opened on the entry its switch was still saving"
        );
    }
}
