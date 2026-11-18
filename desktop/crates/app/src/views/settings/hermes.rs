//! Settings › Hermes, the phone's Hermes Agent pages in one pane:
//!
//! * **Enable Hermes Agent**, the switch (connections are kept off);
//! * **Connections**: the saved connections, the one in use checked.
//!   Clicking another puts it in use (Hermes's chats, jobs and servers
//!   follow); Edit… opens its editor ([`crate::views::hermes_connection`]),
//!   and Add Connection… a new one;
//! * for the connection in use: **Server Status** (reachable, what it can
//!   do, what it reports), **Scheduled Agents** (Review Schedules opens
//!   them in the main window), **Skills** and **Toolsets** (the catalog),
//!   and on a Desktop Gateway **MCP Servers**: test, sign in, an API key,
//!   tools on or off, remove (asked first), add one of the user's own or
//!   from Hermes's catalog.
//!
//! The pane reads what it shows when it first draws, and again on
//! `hermes.changed` ([`crate::stores::hermes_admin`]).

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::views::focus::{ControlExt as _, Ring, pressed_fill};
use conduit_components::views::kit::{Button, IconButton, Switch, setting_row};
use conduit_components::views::settings::settings_section;
use conduit_protocol::{
    AppSettingsPatch, HermesConnectionDto, HermesMcpCatalogAdd, HermesMcpCatalogAdded,
    HermesMcpRef, HermesMcpServerDto, HermesMcpToggle, HermesStatus, NoParams, NoticeLevel,
    methods,
};
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::prelude::*;
use gpui_kit::{AnyElement, App, AsyncApp, ElementId, Role, SharedString, Window, div, px};

use crate::actions::SettingsChoice;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::hermes_admin::{self, Loaded};

use super::controls::{buttons, value};

/// The `SettingsChoice` menu an MCP server's row menu sends.
pub const MCP_MENU: &str = "hermes-mcp";
/// The `SettingsChoice` menu Add from Catalog sends.
pub const CATALOG_MENU: &str = "hermes-mcp-catalog";
/// How many skills the Skills row names before "and N more".
const SKILLS_SHOWN: usize = 12;

/// The pane's sections.
pub fn sections(stores: &Stores, window: &mut Window, cx: &mut App) -> Vec<AnyElement> {
    load(stores, cx);
    let l = cx.l10n().clone();
    let (connections, active, status, catalog, mcp) = {
        let admin = stores.hermes_admin.read(cx);
        (
            admin.connections.clone(),
            admin.active().cloned(),
            admin.status.clone(),
            admin.catalog.clone(),
            admin.mcp.clone(),
        )
    };
    let Some(list) = connections else {
        return vec![
            settings_section(
                SharedString::default(),
                None,
                vec![note_row(l.loading_short(), cx)],
                cx,
            )
            .into_any_element(),
        ];
    };
    let mut out = vec![switch_section(stores, list.enabled, &l, cx)];
    out.push(connections_section(
        stores,
        &list.connections,
        &l,
        window,
        cx,
    ));
    let mut add = Button::new("hermes-add-connection", l.desktop_add_connection_ellipsis())
        .icon(IconName::Plus)
        .disabled(!list.can_add);
    {
        let stores = stores.clone();
        add = add.on_click(Rc::new(move |_, window, cx| {
            crate::views::hermes_connection::open(&stores, None, window, cx);
        }));
    }
    out.push(buttons(vec![add.into_any_element()]).into_any_element());

    let usable = list.enabled
        && active.as_ref().is_some_and(|c| {
            c.mode != "desktop"
                || match c.desktop_auth_kind.as_str() {
                    "nativePkce" => c.desktop_signed_in,
                    "dashboardCookie" => c.dashboard_signed_in,
                    _ => true,
                }
        });
    if !usable {
        return out;
    }
    // Reachable and what it can do; then what is managed on it (MCP
    // servers, schedules), what the agent brings (skills, toolsets), and
    // last, as on a phone, the server's own report.
    out.push(status_section(stores, status.as_ref(), &l, window, cx));
    let gateway = active.is_some_and(|c| c.mode == "desktop");
    if gateway {
        out.push(mcp_section(stores, mcp.as_ref(), &l, window, cx));
    }
    let jobs = status
        .as_ref()
        .and_then(Loaded::ready)
        .is_none_or(|s| s.capabilities.jobs);
    if jobs {
        out.push(schedules_section(stores, &l, cx));
    }
    out.push(conversations_section(stores, &l, cx));
    out.extend(catalog_sections(stores, catalog.as_ref(), gateway, &l, cx));
    if let Some(details) = status
        .as_ref()
        .and_then(Loaded::ready)
        .filter(|s| s.reachable)
        .map(detail_rows)
        .filter(|d| !d.is_empty())
    {
        let rows = details
            .into_iter()
            .map(|(key, shown)| setting_row(key, None, value(shown, cx), cx).into_any_element())
            .collect();
        out.push(
            settings_section(l.hermes_server_status_title(), None, rows, cx).into_any_element(),
        );
    }
    out
}

/// Reads what the pane shows that has not been read yet.
fn load(stores: &Stores, cx: &mut App) {
    let admin = stores.hermes_admin.read(cx);
    let want_connections = admin.connections.is_none();
    let usable = admin
        .connections
        .as_ref()
        .is_some_and(|l| l.enabled && l.active_id.is_some());
    let want_status = usable && admin.status.is_none();
    let want_catalog = usable && admin.catalog.is_none();
    let want_mcp =
        usable && admin.mcp.is_none() && admin.active().is_some_and(|c| c.mode == "desktop");
    if !(want_connections || want_status || want_catalog || want_mcp) {
        return;
    }
    let store = stores.hermes_admin.clone();
    cx.defer(move |cx| {
        store.update(cx, |a, cx| {
            if want_connections {
                a.refresh_connections(cx);
            }
            if want_status {
                a.refresh_status(cx);
            }
            if want_catalog {
                a.refresh_catalog(cx);
            }
            if want_mcp {
                a.refresh_mcp(cx);
            }
        })
    });
}

fn note_row(text: String, cx: &App) -> AnyElement {
    let t = cx.conduit();
    div()
        .px(px(12.))
        .py(px(10.))
        .text_size(px(t.metrics.control))
        .text_color(t.roles.text_subtle)
        .child(text)
        .into_any_element()
}

fn switch_section(stores: &Stores, enabled: bool, l: &L10n, cx: &mut App) -> AnyElement {
    let stores = stores.clone();
    let toggle = Switch::new("hermes-enabled", l.hermes_enable_title(), enabled).on_click(Rc::new(
        move |_, _, cx| hermes_admin::set_enabled(&stores, !enabled, cx),
    ));
    settings_section(
        SharedString::default(),
        Some(l.hermes_enable_subtitle().into()),
        vec![setting_row(l.hermes_enable_title(), None, toggle, cx).into_any_element()],
        cx,
    )
    .into_any_element()
}

/// "Desktop Gateway · 127.0.0.1", as the phone summarises a connection.
pub fn connection_summary(c: &HermesConnectionDto, l: &L10n) -> String {
    let mode = if c.mode == "desktop" {
        l.hermes_desktop_gateway()
    } else {
        l.desktop_hermes_mode_api()
    };
    let host = crate::views::forms::host_of(&c.base_url);
    let mut parts = vec![mode];
    if !host.is_empty() {
        parts.push(host);
    }
    if c.plain_http {
        parts.push(l.hermes_not_encrypted());
    }
    parts.join(" · ")
}

fn connections_section(
    stores: &Stores,
    connections: &[HermesConnectionDto],
    l: &L10n,
    window: &mut Window,
    cx: &mut App,
) -> AnyElement {
    let rows: Vec<AnyElement> = if connections.is_empty() {
        vec![
            setting_row(
                l.hermes_no_connections_title(),
                Some(l.hermes_no_connections_subtitle().into()),
                div(),
                cx,
            )
            .into_any_element(),
        ]
    } else {
        connections
            .iter()
            .map(|c| connection_row(stores, c, l, window, cx))
            .collect()
    };
    settings_section(
        l.hermes_connections_section_title(),
        (!connections.is_empty()).then(|| l.desktop_hermes_connections_footer().into()),
        rows,
        cx,
    )
    .into_any_element()
}

fn connection_row(
    stores: &Stores,
    c: &HermesConnectionDto,
    l: &L10n,
    window: &mut Window,
    cx: &mut App,
) -> AnyElement {
    let t = cx.conduit().clone();
    let r = t.roles;
    let summary = connection_summary(c, l);
    let subtitle = if c.active {
        format!("{} · {summary}", l.hermes_active_connection())
    } else {
        summary
    };
    let edit = {
        let stores = stores.clone();
        let id = c.id.clone();
        Button::new(
            ElementId::Name(format!("hermes-edit-connection-{}", c.id).into()),
            l.desktop_edit_ellipsis(),
        )
        .on_click(Rc::new(move |_, window, cx| {
            // Not the row's click too (which would switch to it).
            cx.stop_propagation();
            crate::views::hermes_connection::open(&stores, Some(id.clone()), window, cx);
        }))
    };
    let spoken = format!("{}, {subtitle}", c.name);
    let pressed = pressed_fill(r.hover, &t);
    let row = div()
        .id(ElementId::Name(
            format!("hermes-connection-{}", c.id).into(),
        ))
        .role(Role::Button)
        .aria_label(SharedString::from(spoken))
        .aria_selected(c.active)
        .w_full()
        .min_h(px(t.metrics.row_height + 16.))
        .px(px(12.))
        .py(px(8.))
        .flex()
        .items_center()
        .gap(px(10.))
        .child(
            div()
                .w(px(16.))
                .flex_none()
                .when(c.active, |d| d.child(icon(IconName::Check, 14., r.text))),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .gap(px(2.))
                .child(
                    div()
                        .truncate()
                        .text_size(px(t.metrics.control))
                        .text_color(r.text)
                        .child(SharedString::from(c.name.clone())),
                )
                .child(
                    div()
                        .truncate()
                        .text_size(px(t.metrics.small))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(subtitle)),
                ),
        )
        .child(edit);
    if c.active {
        return row.into_any_element();
    }
    let stores = stores.clone();
    let id = c.id.clone();
    let name = c.name.clone();
    row.cursor_pointer()
        .hover(|s| s.bg(r.hover))
        .active(|s| s.bg(pressed))
        .keyboard_shadow(cx)
        .tip(l.hermes_use_connection(), None)
        .on_click(move |_, _, cx| {
            hermes_admin::activate(&stores, &id, cx);
            let text = cx.l10n().desktop_hermes_using_connection(&name);
            stores
                .toasts
                .update(cx, |t, cx| t.show(NoticeLevel::Success, text, cx));
        })
        .keyboard_list_item(Ring::Inset(6.), window, cx)
        .into_any_element()
}

fn status_section(
    stores: &Stores,
    status: Option<&Loaded<HermesStatus>>,
    l: &L10n,
    window: &mut Window,
    cx: &mut App,
) -> AnyElement {
    let t = cx.conduit().clone();
    let refresh = {
        let store = stores.hermes_admin.clone();
        Button::new("hermes-status-refresh", l.desktop_hermes_refresh()).on_click(Rc::new(
            move |_, _, cx| store.update(cx, |a, cx| a.refresh_status(cx)),
        ))
    };
    let _ = window;
    let mut rows = vec![];
    match status {
        None | Some(Loaded::Loading) => rows.push(note_row(l.loading_short(), cx)),
        Some(Loaded::Failed(_)) => rows.push(
            setting_row(l.desktop_hermes_status_failed(), None, refresh, cx).into_any_element(),
        ),
        Some(Loaded::Ready(status)) => {
            let (dot, said) = if status.reachable {
                (t.roles.success, l.connected_to_server())
            } else {
                (t.roles.danger, l.desktop_hermes_unreachable())
            };
            let state = div()
                .id("hermes-status-value")
                .role(Role::Status)
                .aria_label(SharedString::from(said.clone()))
                .flex()
                .items_center()
                .gap(px(6.))
                .child(div().size(px(8.)).rounded_full().bg(dot))
                .child(value(said, cx));
            rows.push(
                setting_row(
                    l.desktop_hermes_status(),
                    None,
                    div()
                        .flex()
                        .items_center()
                        .gap(px(10.))
                        .child(state)
                        .child(refresh),
                    cx,
                )
                .into_any_element(),
            );
            if status.reachable {
                let c = &status.capabilities;
                let chips = [
                    (l.hermes_capability_approval(), c.run_approval),
                    (l.hermes_capability_skills(), c.skills),
                    (l.hermes_capability_toolsets(), c.toolsets),
                    (l.hermes_capability_jobs(), c.jobs),
                    (l.hermes_capability_sessions(), c.sessions),
                ];
                rows.push(
                    div()
                        .px(px(12.))
                        .py(px(10.))
                        .flex()
                        .flex_col()
                        .gap(px(8.))
                        .child(
                            div()
                                .text_size(px(t.metrics.control))
                                .text_color(t.roles.text)
                                .child(l.hermes_capabilities_title()),
                        )
                        .child(
                            div().flex().flex_wrap().gap(px(6.)).children(
                                chips
                                    .into_iter()
                                    .map(|(label, on)| capability_chip(label, on, l, cx)),
                            ),
                        )
                        .into_any_element(),
                );
            }
        }
    }
    settings_section(SharedString::default(), None, rows, cx).into_any_element()
}

fn capability_chip(label: String, on: bool, l: &L10n, cx: &App) -> AnyElement {
    let t = cx.conduit();
    let r = t.roles;
    let color = if on { r.success } else { r.text_subtle };
    let spoken = format!(
        "{label}, {}",
        if on {
            l.enabled_label()
        } else {
            l.disabled_label()
        }
    );
    div()
        .id(ElementId::Name(format!("hermes-capability-{label}").into()))
        .role(Role::Status)
        .aria_label(SharedString::from(spoken))
        .px(px(8.))
        .py(px(3.))
        .flex()
        .items_center()
        .gap(px(4.))
        .rounded_full()
        .bg(conduit_components::theme::with_alpha(color, 0.12))
        .text_size(px(t.metrics.small))
        .text_color(conduit_components::theme::legible_text(
            color,
            r.text,
            t.surfaces.window,
            4.5,
        ))
        .child(icon(
            if on { IconName::Check } else { IconName::Minus },
            11.,
            color,
        ))
        .child(SharedString::from(label))
        .into_any_element()
}

/// The server's own report, as the phone lists it: each text or number,
/// its key in words ("gateway_state" → "Gateway state"). Yes-or-no flags
/// are the server's internals and stay out.
pub fn detail_rows(status: &HermesStatus) -> Vec<(String, String)> {
    let mut out = vec![];
    let Some(details) = status.details.as_object() else {
        return out;
    };
    for (key, value) in details {
        let shown = match value {
            serde_json::Value::String(s) if !s.trim().is_empty() => s.clone(),
            serde_json::Value::Number(n) => n.to_string(),
            _ => continue,
        };
        let mut words = key.replace('_', " ");
        if let Some(first) = words.get(0..1) {
            words = first.to_uppercase() + &words[1..];
        }
        out.push((words, shown));
        if out.len() == 8 {
            break;
        }
    }
    out
}

fn schedules_section(stores: &Stores, l: &L10n, cx: &mut App) -> AnyElement {
    let navigation = stores.navigation.clone();
    let review = Button::new(
        "hermes-review-schedules",
        l.desktop_hermes_review_schedules(),
    )
    .on_click(Rc::new(move |_, _, cx| {
        navigation.update(cx, |n, cx| {
            n.open_item(crate::stores::navigation::AreaItem::HermesJobs, cx)
        });
        crate::desktop::show_main(cx);
    }));
    settings_section(
        l.hermes_scheduled_agents_title(),
        Some(l.desktop_hermes_scheduled_agents_footer().into()),
        vec![setting_row(l.hermes_scheduled_agents_title(), None, review, cx).into_any_element()],
        cx,
    )
    .into_any_element()
}

/// Conversations: Show Scheduled Runs, as on a phone (each run of a
/// scheduled agent starts its own chat; off, they leave the Hermes list,
/// pinned ones kept).
fn conversations_section(stores: &Stores, l: &L10n, cx: &mut App) -> AnyElement {
    let on = stores
        .app_settings
        .read(cx)
        .settings()
        .hermes_show_scheduled_sessions;
    let store = stores.app_settings.clone();
    let switch = Switch::new(
        "hermes-show-scheduled-runs",
        l.hermes_show_scheduled_runs(),
        on,
    )
    .on_click(Rc::new(move |_, _, cx| {
        store.update(cx, |s, cx| {
            s.set(
                AppSettingsPatch {
                    hermes_show_scheduled_sessions: Some(!on),
                    ..Default::default()
                },
                cx,
            )
        });
    }));
    settings_section(
        l.hermes_conversations_title(),
        Some(l.hermes_show_scheduled_runs_description().into()),
        vec![setting_row(l.hermes_show_scheduled_runs(), None, switch, cx).into_any_element()],
        cx,
    )
    .into_any_element()
}

/// The agent's skills and toolsets. On a Desktop Gateway, as on a phone,
/// its toolsets are switches (for new sessions) and Reload Skills has it
/// read its skills again; an API server's are only listed.
fn catalog_sections(
    stores: &Stores,
    catalog: Option<&Loaded<conduit_protocol::HermesCatalog>>,
    gateway: bool,
    l: &L10n,
    cx: &mut App,
) -> Vec<AnyElement> {
    let t = cx.conduit().clone();
    let catalog = match catalog {
        None | Some(Loaded::Loading) => {
            return vec![
                settings_section(
                    l.hermes_capability_skills(),
                    None,
                    vec![note_row(l.loading_short(), cx)],
                    cx,
                )
                .into_any_element(),
            ];
        }
        Some(Loaded::Failed(_)) => {
            return vec![
                settings_section(
                    l.hermes_capability_skills(),
                    None,
                    vec![note_row(l.desktop_hermes_catalog_failed(), cx)],
                    cx,
                )
                .into_any_element(),
            ];
        }
        Some(Loaded::Ready(catalog)) => catalog,
    };
    let skills = if catalog.skills.is_empty() {
        note_row(l.hermes_no_installed_skills(), cx)
    } else {
        let mut named: Vec<String> = catalog
            .skills
            .iter()
            .take(SKILLS_SHOWN)
            .map(|s| format!("/{}", s.name))
            .collect();
        let more = catalog.skills.len().saturating_sub(SKILLS_SHOWN);
        if more > 0 {
            named.push(l.desktop_hermes_skills_more(more as i64));
        }
        div()
            .id("hermes-skills")
            .role(Role::Group)
            .aria_label(SharedString::from(l.hermes_capability_skills()))
            .px(px(12.))
            .py(px(10.))
            .text_size(px(t.metrics.control))
            .line_height(gpui_kit::relative(1.45))
            .text_color(t.roles.text)
            .child(SharedString::from(named.join("  ")))
            .into_any_element()
    };
    let (busy, reloading) = {
        let admin = stores.hermes_admin.read(cx);
        (admin.toolsets_busy.clone(), admin.skills_reloading)
    };
    let toolset_rows: Vec<AnyElement> = if gateway && !catalog.toolsets.is_empty() {
        catalog
            .toolsets
            .iter()
            .map(|toolset| {
                let label = if toolset.label.trim().is_empty() {
                    toolset.name.clone()
                } else {
                    toolset.label.clone()
                };
                let name = toolset.name.clone();
                let on = toolset.enabled;
                let stores = stores.clone();
                setting_row(
                    label.clone(),
                    Some(l.hermes_tool_count(toolset.tools.len() as i64).into()),
                    Switch::new(
                        ElementId::Name(format!("hermes-toolset-{}", toolset.name).into()),
                        label,
                        on,
                    )
                    .disabled(busy.contains(&toolset.name))
                    .on_click(Rc::new(move |_, _, cx| {
                        let s = stores.clone();
                        stores
                            .hermes_admin
                            .update(cx, |a, cx| a.set_toolset(&s, &name, !on, cx));
                    })),
                    cx,
                )
                .into_any_element()
            })
            .collect()
    } else {
        vec![]
    };
    let toolsets = if catalog.toolsets.is_empty() {
        note_row(l.hermes_no_toolsets(), cx)
    } else if !toolset_rows.is_empty() {
        div().into_any_element()
    } else {
        div()
            .id("hermes-toolsets")
            .role(Role::List)
            .aria_label(SharedString::from(l.hermes_capability_toolsets()))
            .px(px(12.))
            .py(px(10.))
            .flex()
            .flex_wrap()
            .gap(px(6.))
            .children(catalog.toolsets.iter().map(|toolset| {
                let label = if toolset.label.trim().is_empty() {
                    toolset.name.clone()
                } else {
                    toolset.label.clone()
                };
                let count = l.hermes_tool_count(toolset.tools.len() as i64);
                let r = t.roles;
                let color = if toolset.enabled {
                    r.text
                } else {
                    r.text_faint
                };
                let spoken = format!(
                    "{label}, {count}, {}",
                    if toolset.enabled {
                        l.enabled_label()
                    } else {
                        l.disabled_label()
                    }
                );
                div()
                    .id(ElementId::Name(
                        format!("hermes-toolset-{}", toolset.name).into(),
                    ))
                    .role(Role::ListItem)
                    .aria_label(SharedString::from(spoken))
                    .px(px(8.))
                    .py(px(3.))
                    .rounded(px(6.))
                    .border_1()
                    .border_color(r.border)
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .text_size(px(t.metrics.small))
                    .child(div().text_color(color).child(SharedString::from(label)))
                    .child(
                        div()
                            .text_color(r.text_subtle)
                            .child(SharedString::from(count)),
                    )
            }))
            .into_any_element()
    };
    let mut out = vec![
        settings_section(
            l.hermes_capability_skills(),
            (!catalog.skills.is_empty()).then(|| l.desktop_hermes_skills_footer().into()),
            vec![skills],
            cx,
        )
        .into_any_element(),
    ];
    if gateway {
        let stores = stores.clone();
        out.push(
            buttons(vec![
                Button::new("hermes-reload-skills", l.hermes_reload_skills())
                    .icon(IconName::RotateCw)
                    .disabled(reloading)
                    .on_click(Rc::new(move |_, _, cx| {
                        let s = stores.clone();
                        stores
                            .hermes_admin
                            .update(cx, |a, cx| a.reload_skills(&s, cx));
                    }))
                    .into_any_element(),
            ])
            .into_any_element(),
        );
    }
    out.push(
        settings_section(
            l.hermes_capability_toolsets(),
            (!catalog.toolsets.is_empty()).then(|| l.hermes_toolsets_new_sessions().into()),
            if toolset_rows.is_empty() {
                vec![toolsets]
            } else {
                toolset_rows
            },
            cx,
        )
        .into_any_element(),
    );
    out
}

fn mcp_section(
    stores: &Stores,
    mcp: Option<&Loaded<conduit_protocol::HermesMcpServers>>,
    l: &L10n,
    window: &mut Window,
    cx: &mut App,
) -> AnyElement {
    let (busy, installing) = {
        let admin = stores.hermes_admin.read(cx);
        (admin.mcp_busy.clone(), admin.mcp_installing.clone())
    };
    let (mut rows, servers) = match mcp {
        None | Some(Loaded::Loading) => (vec![note_row(l.loading_short(), cx)], None),
        Some(Loaded::Failed(_)) => (vec![note_row(l.desktop_hermes_mcp_load_failed(), cx)], None),
        Some(Loaded::Ready(list)) if !list.available => {
            (vec![note_row(l.desktop_hermes_mcp_unavailable(), cx)], None)
        }
        Some(Loaded::Ready(list)) if list.servers.is_empty() => {
            (vec![note_row(l.desktop_hermes_mcp_empty(), cx)], Some(list))
        }
        Some(Loaded::Ready(list)) => (
            list.servers
                .iter()
                .map(|s| {
                    mcp_row(
                        s,
                        list.can_set_api_key,
                        busy.contains(&s.name),
                        l,
                        window,
                        cx,
                    )
                })
                .collect(),
            Some(list),
        ),
    };
    // A catalog server Hermes is still building: said until it is listed.
    for (i, (name, oauth)) in installing.iter().enumerate() {
        let text = if *oauth {
            l.hermes_mcp_still_installing_sign_in(name)
        } else {
            l.hermes_mcp_still_installing(name)
        };
        rows.insert(i, installing_row(name, text, cx));
    }
    let section = settings_section(
        l.hermes_mcp_servers(),
        Some(l.desktop_hermes_mcp_footer().into()),
        rows,
        cx,
    );
    let Some(_) = servers else {
        return section.into_any_element();
    };
    let catalog = {
        let stores = stores.clone();
        Button::new(
            "hermes-mcp-catalog",
            l.desktop_hermes_mcp_add_from_catalog(),
        )
        .icon(IconName::ChevronsUpDown)
        .on_click(Rc::new(move |_, window, cx| {
            show_catalog(&stores, window, cx)
        }))
    };
    let add = {
        let stores = stores.clone();
        Button::new("hermes-mcp-add", l.desktop_hermes_mcp_add_ellipsis())
            .icon(IconName::Plus)
            .on_click(Rc::new(move |_, window, cx| {
                crate::views::hermes_mcp::open_add(&stores, window, cx)
            }))
    };
    div()
        .w_full()
        .flex()
        .flex_col()
        .gap(px(10.))
        .child(section)
        .child(buttons(vec![
            catalog.into_any_element(),
            add.into_any_element(),
        ]))
        .into_any_element()
}

/// "Hermes is still installing …": a status row, announced as it appears.
fn installing_row(name: &str, text: String, cx: &App) -> AnyElement {
    let t = cx.conduit();
    div()
        .id(ElementId::Name(
            format!("hermes-mcp-installing-{name}").into(),
        ))
        .role(Role::Status)
        .aria_label(SharedString::from(text.clone()))
        .px(px(12.))
        .py(px(10.))
        .flex()
        .items_center()
        .gap(px(8.))
        .child(icon(IconName::ClockFading, 14., t.roles.text_subtle))
        .child(
            div()
                .flex_1()
                .text_size(px(t.metrics.control))
                .text_color(t.roles.text_subtle)
                .child(text),
        )
        .into_any_element()
}

fn mcp_row(
    s: &HermesMcpServerDto,
    can_set_key: bool,
    busy: bool,
    l: &L10n,
    window: &mut Window,
    cx: &mut App,
) -> AnyElement {
    let _ = window;
    let mut parts = vec![];
    if !s.description.trim().is_empty() {
        parts.push(s.description.clone());
    }
    parts.push(if s.enabled {
        l.desktop_hermes_mcp_tools_on()
    } else {
        l.desktop_hermes_mcp_tools_off()
    });
    if let Some(auth) = s.auth.as_ref().filter(|a| !a.trim().is_empty()) {
        parts.push(auth.clone());
    }
    let mut subtitle = parts.join(" · ");
    if !s.tools.is_empty() {
        subtitle.push('\n');
        subtitle.push_str(&l.desktop_hermes_mcp_tools_list(&s.tools.join(", ")));
    }
    let name = s.name.clone();
    let enabled = s.enabled;
    let menu = IconButton::new(
        ElementId::Name(format!("hermes-mcp-menu-{}", s.name).into()),
        IconName::Ellipsis,
        l.desktop_hermes_mcp_actions_named(&s.name),
    )
    .tooltip(l.desktop_hermes_mcp_actions_named(&s.name))
    .disabled(busy)
    .on_click(Rc::new(move |_, window, cx| {
        let l = cx.l10n().clone();
        let choice = |action: &str| {
            Box::new(SettingsChoice {
                menu: MCP_MENU.into(),
                value: format!("{action}:{name}"),
            })
        };
        let mut native = NativeMenu::new()
            .menu(l.desktop_test_connection(), choice("test"))
            .menu(l.desktop_hermes_mcp_sign_in(), choice("signIn"));
        if can_set_key {
            native = native.menu(l.desktop_hermes_mcp_set_api_key(), choice("key"));
        }
        native = if enabled {
            native.menu(l.desktop_hermes_mcp_disable_tools(), choice("disable"))
        } else {
            native.menu(l.desktop_hermes_mcp_enable_tools(), choice("enable"))
        };
        native
            .separator()
            .menu(l.desktop_hermes_mcp_remove_ellipsis(), choice("remove"))
            .show(window.mouse_position(), window, cx);
    }));
    setting_row(
        s.name.clone(),
        Some(subtitle.into()),
        if busy {
            value(l.loading_short(), cx).into_any_element()
        } else {
            menu.into_any_element()
        },
        cx,
    )
    .id(ElementId::Name(format!("hermes-mcp-{}", s.name).into()))
    .into_any_element()
}

/// Add from Catalog: a native menu of the servers Hermes offers.
fn show_catalog(stores: &Stores, window: &mut Window, cx: &mut App) {
    let rpc = stores.connection.read(cx).rpc();
    // The answer is shown only while the connection it was asked of is in use.
    let asked = stores.hermes_admin.read(cx).ask_catalog();
    let call = rpc.call::<methods::HermesMcpCatalog>(&NoParams);
    let toasts = stores.toasts.downgrade();
    let admin = stores.hermes_admin.downgrade();
    let handle = window.window_handle();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let result = call.await;
        let l = cx.update(|cx| cx.l10n().clone());
        let entries = match result {
            Ok(catalog) => catalog.entries,
            Err(e) => {
                log::info!("hermes.mcp.catalog: {e}");
                let _ = toasts.update(cx, |t, cx| {
                    t.show(
                        NoticeLevel::Error,
                        l.desktop_hermes_mcp_catalog_failed(),
                        cx,
                    )
                });
                return;
            }
        };
        if entries.is_empty() {
            let _ = toasts.update(cx, |t, cx| {
                t.show(NoticeLevel::Info, l.desktop_hermes_mcp_catalog_empty(), cx)
            });
            return;
        }
        if !admin
            .update(cx, |a, _| a.take_catalog(&asked, entries.clone()))
            .unwrap_or(false)
        {
            return;
        }
        let _ = handle.update(cx, |_, window, cx| {
            let mut native = NativeMenu::new();
            for entry in entries {
                let mut label = if entry.description.trim().is_empty() {
                    entry.name.clone()
                } else {
                    format!("{} — {}", entry.name, first_sentence(&entry.description))
                };
                // It asks for values first: a sheet follows.
                if !entry.credentials.is_empty() && entry.can_add {
                    label.push('…');
                }
                // One that needs what this connection cannot send is
                // listed, dimmed, as on a phone.
                native = native.menu_with_disabled(
                    label,
                    !entry.can_add,
                    Box::new(SettingsChoice {
                        menu: CATALOG_MENU.into(),
                        value: entry.name,
                    }),
                );
            }
            native.show(window.mouse_position(), window, cx);
        });
    })
    .detach();
}

fn first_sentence(text: &str) -> String {
    let text = text.trim();
    let cut = text.find(". ").map(|i| i + 1).unwrap_or(text.len()).min(90);
    let mut out: String = text.chars().take(cut).collect();
    if out.len() < text.len() && !out.ends_with('.') {
        out.push('…');
    }
    out
}

/// A pick from an MCP server's row menu or Add from Catalog.
pub fn choose(stores: &Stores, menu: &str, value: &str, window: &mut Window, cx: &mut App) {
    let l = cx.l10n().clone();
    let rpc = stores.connection.read(cx).rpc();
    // The connection in use, as the daemon names it: what is asked of one
    // server is refused once another is in use.
    let connection = stores.hermes_admin.read(cx).connection();
    let server = |name: &str| HermesMcpRef {
        name: name.to_string(),
        connection: connection.clone(),
    };
    if menu == CATALOG_MENU {
        // A pick from a menu of another connection's catalog (one came into
        // use since it was shown) adds nothing: the catalog in use now is
        // shown instead.
        let Some((entry, read_for)) = stores.hermes_admin.read(cx).catalog_entry(value) else {
            show_catalog(stores, window, cx);
            return;
        };
        // An entry that asks for values opens a sheet asking for them.
        if !entry.credentials.is_empty() {
            crate::views::hermes_mcp::open_catalog(stores, entry, window, cx);
            return;
        }
        let name = value.to_string();
        let oauth = entry.oauth;
        // Added to the connection the catalog was read for: the daemon
        // refuses it once another is in use.
        let call = rpc.call::<methods::HermesMcpAddFromCatalog>(&HermesMcpCatalogAdd {
            name: name.clone(),
            credentials: Default::default(),
            connection: read_for,
        });
        // Its answer is taken in the order it was asked.
        let ticket = stores.hermes_admin.update(cx, |a, _| a.ask_mcp());
        let stores_done = stores.clone();
        let admin = stores.hermes_admin.downgrade();
        cx.spawn(async move |cx: &mut AsyncApp| {
            let result = call.await;
            cx.update(|cx| match result {
                Ok(added) => catalog_added(&stores_done, &name, oauth, added, ticket, cx),
                Err(e) => {
                    log::info!("hermes.mcp.addFromCatalog: {e}");
                    let text = cx.l10n().desktop_hermes_mcp_action_failed();
                    stores_done
                        .toasts
                        .update(cx, |t, cx| t.show(NoticeLevel::Error, text, cx));
                    // Listed again even when a step after the install failed.
                    let _ = admin.update(cx, |a, cx| a.refresh_mcp(cx));
                }
            });
        })
        .detach();
        return;
    }
    let Some((action, name)) = value.split_once(':') else {
        return;
    };
    let name = name.to_string();
    let toasts = stores.toasts.clone();
    // A server's busy mark and list are the connection in use's: a test or
    // sign-in answered after a switch leaves them alone.
    let generation = stores.hermes_admin.read(cx).generation();
    let busy = |stores: &Stores, on: bool, cx: &mut App| {
        let name = name.clone();
        stores
            .hermes_admin
            .update(cx, |a, cx| a.set_mcp_busy(&name, on, cx));
    };
    match action {
        "test" => {
            busy(stores, true, cx);
            let call = rpc.call::<methods::HermesMcpTest>(&server(&name));
            let admin = stores.hermes_admin.downgrade();
            cx.spawn(async move |cx: &mut AsyncApp| {
                let result = call.await;
                let l = cx.update(|cx| cx.l10n().clone());
                let (level, text) = match result {
                    Ok(r) if r.ok => (NoticeLevel::Success, l.desktop_hermes_mcp_test_ok(&name)),
                    _ => (NoticeLevel::Error, l.desktop_hermes_mcp_test_failed(&name)),
                };
                toasts.update(cx, |t, cx| t.show(level, text, cx));
                let _ = admin.update(cx, |a, cx| {
                    if !a.is_current(generation) {
                        return;
                    }
                    a.set_mcp_busy(&name, false, cx);
                    // The tools a test found show in the row.
                    a.refresh_mcp(cx);
                });
            })
            .detach();
        }
        "signIn" => sign_in(stores, &name, false, cx),
        "key" => crate::views::hermes_mcp::open_key(stores, &name, window, cx),
        "enable" | "disable" => {
            let call = rpc.call::<methods::HermesMcpSetEnabled>(&HermesMcpToggle {
                name: name.clone(),
                enabled: action == "enable",
                connection: connection.clone(),
            });
            let ticket = stores.hermes_admin.update(cx, |a, _| a.ask_mcp());
            hermes_admin::act(
                stores,
                call,
                l.desktop_hermes_mcp_action_failed(),
                move |a, servers, cx| {
                    a.answer_mcp(ticket, servers, cx);
                },
                cx,
            );
        }
        "remove" => {
            let spec = SheetSpec::new(
                l.desktop_hermes_mcp_remove_title(&name),
                l.desktop_hermes_mcp_remove_message(),
                l.desktop_settings_remove_server(),
                l.cancel(),
            )
            .destructive();
            let ask = present_sheet(window, spec, cx);
            let stores = stores.clone();
            // The server asked about is the connection in use now's.
            let opened = stores.hermes_admin.read(cx).opened();
            cx.spawn(async move |cx: &mut AsyncApp| {
                if !ask.await {
                    return;
                }
                cx.update(|cx| {
                    if !stores.hermes_admin.read(cx).still_in_use(&opened) {
                        return;
                    }
                    let l = cx.l10n().clone();
                    let rpc = stores.connection.read(cx).rpc();
                    let call = rpc.call::<methods::HermesMcpRemove>(&HermesMcpRef {
                        name: name.clone(),
                        connection: opened.connection.clone(),
                    });
                    let toasts = stores.toasts.clone();
                    let ticket = stores.hermes_admin.update(cx, |a, _| a.ask_mcp());
                    hermes_admin::act(
                        &stores,
                        call,
                        l.desktop_hermes_mcp_action_failed(),
                        move |a, servers, cx| {
                            a.answer_mcp(ticket, servers, cx);
                            let text = cx.l10n().desktop_hermes_mcp_removed(&name);
                            toasts.update(cx, |t, cx| t.show(NoticeLevel::Success, text, cx));
                        },
                        cx,
                    );
                });
            })
            .detach();
        }
        _ => {}
    }
}

/// Signs in to MCP server `name` with OAuth in the browser (its row's Sign
/// In, or straight after a catalog add, `after_add`, whose failure says the
/// server was added all the same).
fn sign_in(stores: &Stores, name: &str, after_add: bool, cx: &mut App) {
    let l = cx.l10n().clone();
    let name = name.to_string();
    let rpc = stores.connection.read(cx).rpc();
    let toasts = stores.toasts.clone();
    // The connection in use: refused once another is; its busy mark and
    // list are left alone after a switch.
    let (connection, generation) = {
        let admin = stores.hermes_admin.read(cx);
        (admin.connection(), admin.generation())
    };
    stores
        .hermes_admin
        .update(cx, |a, cx| a.set_mcp_busy(&name, true, cx));
    stores.toasts.update(cx, |t, cx| {
        t.show(
            NoticeLevel::Info,
            l.desktop_hermes_mcp_signing_in(&name),
            cx,
        )
    });
    let call = rpc.call::<methods::HermesMcpAuthenticate>(&HermesMcpRef {
        name: name.clone(),
        connection,
    });
    let admin = stores.hermes_admin.downgrade();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let result = call.await;
        let l = cx.update(|cx| cx.l10n().clone());
        // Still waiting on the browser past the call's limit: the
        // list follows when the daemon says it is done.
        if let Err(e) = &result
            && e.code.as_str() == "rpc.timeout"
        {
            let _ = admin.update(cx, |a, cx| {
                if a.is_current(generation) {
                    a.set_mcp_busy(&name, false, cx);
                }
            });
            return;
        }
        let ok = result.is_ok();
        let text = match (ok, after_add) {
            (true, _) => l.desktop_hermes_mcp_signed_in(&name),
            (false, true) => l.hermes_mcp_added_sign_in_unfinished(&name),
            (false, false) => l.desktop_hermes_mcp_sign_in_failed(&name),
        };
        let level = if ok {
            NoticeLevel::Success
        } else {
            NoticeLevel::Error
        };
        toasts.update(cx, |t, cx| t.show(level, text, cx));
        let _ = admin.update(cx, |a, cx| {
            if !a.is_current(generation) {
                return;
            }
            a.set_mcp_busy(&name, false, cx);
            a.refresh_mcp(cx);
        });
    })
    .detach();
}

/// What follows a catalog add: the servers now; "still installing" said
/// until it is listed; or Added, then OAuth sign-in when it signs in so.
/// `ticket` is the add's, asked when it was sent: made under another
/// connection than the one in use now, nothing more of it happens here.
pub fn catalog_added(
    stores: &Stores,
    name: &str,
    oauth: bool,
    added: HermesMcpCatalogAdded,
    ticket: hermes_admin::Ticket,
    cx: &mut App,
) {
    let HermesMcpCatalogAdded {
        servers,
        still_installing,
        sign_in: signs_in,
    } = added;
    let current = stores.hermes_admin.update(cx, |a, cx| {
        let current = a.is_current(ticket.generation());
        a.answer_mcp(ticket, servers, cx);
        if current && still_installing {
            a.set_installing(name, oauth, cx);
        }
        current
    });
    if !current {
        return;
    }
    if still_installing {
        let text = if oauth {
            cx.l10n().hermes_mcp_still_installing_sign_in(name)
        } else {
            cx.l10n().hermes_mcp_still_installing(name)
        };
        stores
            .toasts
            .update(cx, |t, cx| t.show(NoticeLevel::Info, text, cx));
        return;
    }
    let text = cx.l10n().desktop_hermes_mcp_added(name);
    stores
        .toasts
        .update(cx, |t, cx| t.show(NoticeLevel::Success, text, cx));
    if signs_in {
        sign_in(stores, name, true, cx);
    }
}
