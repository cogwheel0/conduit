//! Settings › Direct Connections, mobile's Direct Connections page in the
//! Settings window's groups:
//!
//! * **Apple Intelligence**: Apple's on-device model, whether this Mac can
//!   run it now and why not (`apple.status`), and Check Again
//!   (`apple.refresh`), as the phone's Apple rows. Private Cloud Compute is
//!   never offered: this build has no entitlement for it.
//! * **Open WebUI History**: keep direct chats on this Mac or save them to
//!   the account (`direct.setHistory`), when the server allows it.
//! * **Open WebUI Server**: the connections kept in the account
//!   (`ui.directConnections`), listed, edited and switched like this Mac's;
//!   read again each time the pane opens (`direct.reload`).
//! * **On This Mac**: this Mac's own connections.
//! * **MCP Servers**: Streamable HTTP servers whose tools direct models
//!   may call (`mcp.*`).
//! * **Context Compaction**: a context limit for each model that reports
//!   none (`direct.setContextLimit`).
//! * **Attachments**: images per request (`direct.setImagesPerRequest`).
//! * **Web Search**: the engine, safe search and region of the search the
//!   app runs itself (`webSearch.*`).
//!
//! Each connection and server opens in a sheet ([`DirectEditorSheet`],
//! [`McpServerSheet`]); its switch turns it on or off in place.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::with_alpha;
use conduit_components::views::kit::{Button, ClickHandler, Switch, setting_row};
use conduit_components::views::settings::settings_section;
use conduit_protocol::{
    AppleAvailability, AppleModelKind, AppleModelStatus, AppleModels, AppleUnavailableReason,
    DirectConnectionList, DirectConnectionSummary, DirectContextLimit, DirectEnable, DirectHistory,
    DirectImagesPerRequest, DirectKind, DirectOptions, McpAuth, McpEnable, McpServerList,
    McpServerSummary, NoParams, WebSearchSettings, WebSearchSettingsPatch, methods,
};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncWindowContext, ClickEvent, Context, ElementId, Role, SharedString,
    WeakEntity, Window, div, px,
};

use super::editor::{DirectEditorSheet, OnChange};
use super::mcp::McpServerSheet;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::views::forms;
use crate::views::model_logo;
use crate::views::settings::controls::{self, Choice};

/// The pop-ups' menus, routed here by the Settings window.
pub const MENU_IMAGES: &str = "direct-images";
pub const MENU_CONTEXT: &str = "direct-context:";
pub const MENU_ENGINE: &str = "web-search-engine";
pub const MENU_SAFE: &str = "web-search-safe";
pub const MENU_REGION: &str = "web-search-region";

/// Up to this many models, the context-limit rows are part of the pane;
/// more scroll in a list of their own, this many rows tall.
const CONTEXT_ROWS: usize = 5;
const CONTEXT_VISIBLE: f32 = 6.5;
const REGION_AUTO: &str = "auto";

pub struct DirectPane {
    stores: Stores,
    pub list: Option<DirectConnectionList>,
    pub mcp: Option<McpServerList>,
    pub mcp_failed: bool,
    pub options: Option<DirectOptions>,
    pub search: Option<WebSearchSettings>,
    pub reloading: bool,
    /// Where chats went as the daemon last said, before the history
    /// switches still out: what a refused switch goes back to.
    history_confirmed: Option<bool>,
    /// History switches sent and not yet answered.
    history_out: u32,
    /// Apple Intelligence on this Mac, once asked; and whether it is being
    /// asked (again) now. An ask that failed reads as unknown, which keeps
    /// Check Again on screen.
    pub apple: Option<AppleModels>,
    pub apple_checking: bool,
    /// The latest Apple ask: only its answer is taken.
    apple_ask: u64,
}

impl DirectPane {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let mut this = Self {
            stores,
            list: None,
            mcp: None,
            mcp_failed: false,
            options: None,
            search: None,
            reloading: false,
            history_confirmed: None,
            history_out: 0,
            apple: None,
            apple_checking: false,
            apple_ask: 0,
        };
        this.refresh(window, cx);
        this
    }

    fn rpc(&self, cx: &App) -> crate::stores::rpc::Rpc {
        self.stores.connection.read(cx).rpc()
    }

    /// Everything again: the account's connections read anew, as mobile
    /// does whenever its page opens.
    pub fn refresh(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let rpc = self.rpc(cx);
        let list = rpc.call::<methods::DirectReload>(&NoParams);
        let mcp = rpc.call::<methods::McpList>(&NoParams);
        let options = rpc.call::<methods::DirectOptions>(&NoParams);
        let search = rpc.call::<methods::WebSearchGet>(&NoParams);
        let apple = cfg!(target_os = "macos").then(|| rpc.call::<methods::AppleStatus>(&NoParams));
        let ask = self.ask_apple(apple.is_some());
        self.reloading = true;
        // Each answer lands on its own: a slow one (Apple's, or the models
        // of every connection) holds back none of the others.
        self.land(list, window, cx, |s, list, _| {
            s.reloading = false;
            match list {
                Ok(l) => s.adopt_list(l),
                Err(e) => log::warn!("direct.reload: {e}"),
            }
        });
        if let Some(apple) = apple {
            self.land(apple, window, cx, move |s, apple, cx| {
                s.take_apple(ask, apple, cx)
            });
        }
        self.land(mcp, window, cx, |s, mcp, _| match mcp {
            Ok(m) => {
                s.mcp = Some(m);
                s.mcp_failed = false;
            }
            Err(e) => {
                log::warn!("mcp.list: {e}");
                s.mcp_failed = true;
            }
        });
        self.land(search, window, cx, |s, search, _| match search {
            Ok(w) => s.search = Some(w),
            Err(e) => log::warn!("webSearch.get: {e}"),
        });
        self.land(options, window, cx, |s, options, _| match options {
            Ok(o) => s.options = Some(o),
            Err(e) => log::warn!("direct.options: {e}"),
        });
    }

    /// Takes `call`'s answer with `apply` when it lands, then redraws.
    fn land<T: 'static>(
        &self,
        call: impl std::future::Future<Output = T> + 'static,
        window: &mut Window,
        cx: &mut Context<Self>,
        apply: impl FnOnce(&mut Self, T, &mut Context<Self>) + 'static,
    ) {
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let answer = call.await;
                let _ = this.update(cx, |s, cx| {
                    apply(s, answer, cx);
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// Asks the Mac again whether Apple's model can answer: the phone's
    /// refresh on its Apple row. A model that became ready is listed in the
    /// model picker from then on.
    pub fn check_apple(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.apple_checking {
            return;
        }
        let ask = self.ask_apple(true);
        cx.notify();
        let call = self.rpc(cx).call::<methods::AppleRefresh>(&NoParams);
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| s.take_apple(ask, result, cx));
            },
        )
        .detach();
    }

    /// Starts an Apple ask (when `asking`): earlier ones are no longer
    /// taken.
    fn ask_apple(&mut self, asking: bool) -> u64 {
        if asking {
            self.apple_ask += 1;
            self.apple_checking = true;
        }
        self.apple_ask
    }

    /// The answer to Apple ask `ask`, if it is still the latest. A failed
    /// ask leaves the model unknown, never absent: the row and its Check
    /// Again stay.
    fn take_apple(
        &mut self,
        ask: u64,
        answer: Result<AppleModels, conduit_daemon::RpcError>,
        cx: &mut Context<Self>,
    ) {
        if ask != self.apple_ask {
            return;
        }
        self.apple_checking = false;
        self.apple = Some(match answer {
            Ok(a) => a,
            Err(e) => {
                log::warn!("apple: {e}");
                unknown_apple()
            }
        });
        cx.notify();
    }

    /// What a sheet runs after a save or a delete.
    fn on_change(&self, cx: &Context<Self>) -> OnChange {
        let this = cx.entity().downgrade();
        let session = self.stores.session.clone();
        Rc::new(move |cx: &mut App| {
            session.update(cx, |s, cx| s.refresh(cx));
            let this = this.clone();
            // The sheet is ending: refresh from the Settings window's turn.
            cx.defer(move |cx| {
                let _ = this.update(cx, |s, cx| s.refresh_quietly(cx));
            });
        })
    }

    /// [`Self::refresh`] without a window at hand (after a sheet).
    /// A list the daemon read out: where chats go, as it says, is what a
    /// refused history switch goes back to; a switch still out keeps
    /// showing its own setting until it is answered.
    fn adopt_list(&mut self, mut list: DirectConnectionList) {
        self.history_confirmed = Some(list.local_history);
        if self.history_out > 0
            && let Some(shown) = self.list.as_ref().map(|l| l.local_history)
        {
            list.local_history = shown;
        }
        self.list = Some(list);
    }

    pub fn refresh_quietly(&mut self, cx: &mut Context<Self>) {
        let rpc = self.rpc(cx);
        let list = rpc.call::<methods::DirectList>(&NoParams);
        let mcp = rpc.call::<methods::McpList>(&NoParams);
        let options = rpc.call::<methods::DirectOptions>(&NoParams);
        cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut gpui_kit::AsyncApp| {
                let (list, mcp) = (list.await, mcp.await);
                let _ = this.update(cx, |s, cx| {
                    if let Ok(l) = list {
                        s.adopt_list(l);
                    }
                    if let Ok(m) = mcp {
                        s.mcp = Some(m);
                        s.mcp_failed = false;
                    }
                    cx.notify();
                });
                if let Ok(o) = options.await {
                    let _ = this.update(cx, |s, cx| {
                        s.options = Some(o);
                        cx.notify();
                    });
                }
            },
        )
        .detach();
    }

    pub fn open_editor(
        &mut self,
        summary: Option<DirectConnectionSummary>,
        open_web_ui: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let on_change = self.on_change(cx);
        let stores = self.stores.clone();
        DirectEditorSheet::open(stores, summary, open_web_ui, on_change, window, cx);
    }

    pub fn open_mcp(
        &mut self,
        summary: Option<McpServerSummary>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let on_change = self.on_change(cx);
        let stores = self.stores.clone();
        McpServerSheet::open(stores, summary, on_change, window, cx);
    }

    pub fn set_history(&mut self, sync: bool, window: &mut Window, cx: &mut Context<Self>) {
        let call = self
            .rpc(cx)
            .call::<methods::DirectSetHistory>(&DirectHistory { local_only: !sync });
        if self.history_out == 0 {
            self.history_confirmed = self.list.as_ref().map(|l| l.local_history);
        }
        self.history_out += 1;
        if let Some(l) = self.list.as_mut() {
            l.local_history = !sync;
        }
        cx.notify();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    s.history_out = s.history_out.saturating_sub(1);
                    match result {
                        Ok(l) => s.adopt_list(l),
                        Err(e) => {
                            // Where chats go is what the daemon says: the
                            // setting it last confirmed once no other switch
                            // is out (a later one shows its own until it is
                            // answered), then read again (the switch may
                            // have gone through all the same).
                            log::warn!("direct.setHistory: {e}");
                            if s.history_out == 0
                                && let (Some(l), Some(confirmed)) =
                                    (s.list.as_mut(), s.history_confirmed)
                            {
                                l.local_history = confirmed;
                            }
                            s.refresh_quietly(cx);
                        }
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    pub fn set_enabled(
        &mut self,
        id: String,
        on: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let call = self
            .rpc(cx)
            .call::<methods::DirectSetEnabled>(&DirectEnable { id, enabled: on });
        let session = self.stores.session.clone();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                session.update(cx, |s, cx| s.refresh(cx));
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(l) => s.list = Some(l),
                        Err(e) => log::warn!("direct.setEnabled: {e}"),
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    pub fn set_mcp_enabled(
        &mut self,
        id: String,
        on: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let call = self
            .rpc(cx)
            .call::<methods::McpSetEnabled>(&McpEnable { id, enabled: on });
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(m) => s.mcp = Some(m),
                        Err(e) => log::warn!("mcp.setEnabled: {e}"),
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// A pop-up's pick, from the Settings window.
    pub fn choose(&mut self, menu: &str, value: &str, window: &mut Window, cx: &mut Context<Self>) {
        let rpc = self.rpc(cx);
        if menu == MENU_IMAGES {
            let Ok(count) = value.parse::<i64>() else {
                return;
            };
            let call =
                rpc.call::<methods::DirectSetImagesPerRequest>(&DirectImagesPerRequest { count });
            self.adopt_options(call, window, cx);
        } else if let Some(model_id) = menu.strip_prefix(MENU_CONTEXT) {
            let Ok(tokens) = value.parse::<i64>() else {
                return;
            };
            let call = rpc.call::<methods::DirectSetContextLimit>(&DirectContextLimit {
                model_id: model_id.to_string(),
                tokens,
            });
            self.adopt_options(call, window, cx);
        } else if [MENU_ENGINE, MENU_SAFE, MENU_REGION].contains(&menu) {
            let mut patch = WebSearchSettingsPatch::default();
            match menu {
                MENU_ENGINE => patch.engine = Some(value.to_string()),
                MENU_SAFE => patch.safe_search = Some(value.to_string()),
                _ => patch.region = Some(value.to_string()),
            }
            let call = rpc.call::<methods::WebSearchSet>(&patch);
            cx.spawn_in(
                window,
                async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                    let result = call.await;
                    let _ = this.update(cx, |s, cx| {
                        match result {
                            Ok(w) => s.search = Some(w),
                            Err(e) => log::warn!("webSearch.set: {e}"),
                        }
                        cx.notify();
                    });
                },
            )
            .detach();
        }
    }

    fn adopt_options(
        &mut self,
        call: impl std::future::Future<Output = Result<DirectOptions, conduit_daemon::RpcError>>
        + 'static,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(o) => s.options = Some(o),
                        Err(e) => log::warn!("direct options: {e}"),
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    fn listener(
        &self,
        cx: &Context<Self>,
        f: impl Fn(&mut Self, &mut Window, &mut Context<Self>) + 'static,
    ) -> ClickHandler {
        let this = cx.entity().downgrade();
        let f = Rc::new(f);
        Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
            let f = f.clone();
            let _ = this.update(cx, |s, cx| f(s, window, cx));
        })
    }

    /// A connection's leading mark: its provider's logo, or a cloud.
    fn connection_mark(c: &DirectConnectionSummary, cx: &App) -> AnyElement {
        let t = cx.conduit();
        let r = t.roles;
        let logo = if c.kind == DirectKind::Ollama {
            Some("ollama-cloud")
        } else if c.open_router {
            Some("openrouter")
        } else {
            None
        };
        let fg = if c.enabled && c.compatible {
            r.text
        } else {
            r.text_faint
        };
        let inner: AnyElement = match logo.and_then(|id| model_logo::logo(id, 16., fg)) {
            Some(svg) => svg.into_any_element(),
            None => icon(IconName::Cloud, 15., fg).into_any_element(),
        };
        div()
            .size(px(28.))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(7.))
            .bg(with_alpha(r.text, if t.dark { 0.12 } else { 0.06 }))
            .child(inner)
            .into_any_element()
    }

    fn connection_row(
        &self,
        c: &DirectConnectionSummary,
        l10n: &L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let provider = if c.kind == DirectKind::Ollama {
            if c.ollama_cloud {
                l10n.ollama_cloud_default_name()
            } else {
                l10n.ollama()
            }
        } else if c.open_router {
            l10n.open_router_provider_name()
        } else {
            l10n.desktop_open_ai_compatible()
        };
        let mut subtitle = format!("{provider} \u{b7} {}", forms::host_of(&c.base_url));
        if !c.compatible {
            subtitle = format!(
                "{} \u{b7} {subtitle}",
                l10n.direct_connection_unavailable_label()
            );
        }
        let edit = {
            let c = c.clone();
            self.listener(cx, move |s, window, cx| {
                let open_web_ui = c.open_web_ui;
                s.open_editor(Some(c.clone()), open_web_ui, window, cx)
            })
        };
        let toggle = {
            let (id, on) = (c.id.clone(), c.enabled);
            self.listener(cx, move |s, window, cx| {
                s.set_enabled(id.clone(), !on, window, cx)
            })
        };
        div()
            .id(ElementId::Name(format!("direct-row-{}", c.id).into()))
            .w_full()
            .min_h(px(t.metrics.row_height + 20.))
            .px(px(12.))
            .py(px(8.))
            .flex()
            .items_center()
            .gap(px(12.))
            .child(Self::connection_mark(c, cx))
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
            .child(
                Button::new(
                    ElementId::Name(format!("direct-edit-{}", c.id).into()),
                    l10n.desktop_edit_ellipsis(),
                )
                .on_click(edit),
            )
            .child(
                Switch::new(
                    ElementId::Name(format!("direct-enabled-{}", c.id).into()),
                    l10n.desktop_direct_enable(&c.name),
                    c.enabled,
                )
                .disabled(!c.compatible)
                .on_click(toggle),
            )
            .into_any_element()
    }

    /// Apple's on-device model: where it runs, whether it can answer now or
    /// why not, and Check Again.
    fn apple_row(&self, m: &AppleModelStatus, l10n: &L10n, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let title = l10n.backend_chooser_apple_on_device_title();
        let detail = if self.apple_checking {
            l10n.desktop_apple_checking()
        } else {
            apple_detail(m, l10n)
        };
        let available = m.availability == AppleAvailability::Available;
        let check = self.listener(cx, |s, window, cx| s.check_apple(window, cx));
        div()
            .id("apple-on-device-row")
            .role(Role::Group)
            .aria_label(SharedString::from(format!("{title}, {detail}")))
            .w_full()
            .min_h(px(t.metrics.row_height + 20.))
            .px(px(12.))
            .py(px(8.))
            .flex()
            .items_center()
            .gap(px(12.))
            .child(
                div()
                    .size(px(28.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(7.))
                    .bg(with_alpha(r.text, if t.dark { 0.12 } else { 0.06 }))
                    .child(icon(
                        IconName::Cpu,
                        15.,
                        if available { r.text } else { r.text_faint },
                    )),
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
                            .child(SharedString::from(title.clone())),
                    )
                    .child(
                        div()
                            .text_size(px(t.metrics.small))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(detail)),
                    ),
            )
            .child(
                div()
                    .id("apple-check-tip")
                    .flex_none()
                    .tooltip(conduit_components::views::focus::tooltip_builder(
                        l10n.desktop_apple_check_again_tooltip().into(),
                        None,
                    ))
                    .child(
                        Button::new("apple-check", l10n.desktop_apple_check_again())
                            .icon(IconName::RefreshCw)
                            .disabled(self.apple_checking)
                            .on_click(check),
                    ),
            )
            .into_any_element()
    }

    /// Apple Intelligence: the models this Mac may offer (Apple On-Device
    /// only), with the phone's notes in the footer.
    fn apple_section(
        &self,
        apple: &AppleModels,
        l10n: &L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let rows: Vec<AnyElement> = apple
            .models
            .iter()
            .filter(|m| m.model == AppleModelKind::OnDevice)
            .map(|m| self.apple_row(m, l10n, cx))
            .collect();
        let mut footer = l10n.desktop_apple_footer();
        if !self.apple_checking
            && apple
                .models
                .iter()
                .any(|m| m.supports_current_locale == Some(false))
        {
            footer = format!("{}\n\n{footer}", l10n.desktop_apple_language_unsupported());
        }
        settings_section(
            l10n.backend_chooser_apple_section_title(),
            Some(footer.into()),
            rows,
            cx,
        )
        .into_any_element()
    }

    /// A list of connections, or the sentence for none with Add beside it.
    fn connections(&self, section: Connections, l10n: &L10n, cx: &mut Context<Self>) -> AnyElement {
        let Connections {
            title,
            footer,
            connections,
            empty,
            open_web_ui,
        } = section;
        let add = self.listener(cx, move |s, window, cx| {
            s.open_editor(None, open_web_ui, window, cx)
        });
        let add_id = if open_web_ui {
            "direct-add-owui"
        } else {
            "direct-add"
        };
        let add_button = Button::new(add_id, l10n.desktop_add_connection_ellipsis())
            .icon(IconName::Plus)
            .on_click(add);
        let rows: Vec<AnyElement> = if connections.is_empty() {
            vec![setting_row(empty.0, Some(empty.1.into()), add_button, cx).into_any_element()]
        } else {
            connections
                .iter()
                .map(|c| self.connection_row(c, l10n, cx))
                .collect()
        };
        let listed = !connections.is_empty();
        let add_again = listed.then(|| {
            let add = self.listener(cx, move |s, window, cx| {
                s.open_editor(None, open_web_ui, window, cx)
            });
            controls::buttons(vec![
                Button::new(
                    SharedString::from(format!("{add_id}-more")),
                    l10n.desktop_add_connection_ellipsis(),
                )
                .icon(IconName::Plus)
                .on_click(add)
                .into_any_element(),
            ])
        });
        div()
            .flex()
            .flex_col()
            .gap(px(8.))
            .child(settings_section(
                title.unwrap_or_default(),
                footer.map(Into::into),
                rows,
                cx,
            ))
            .children(add_again)
            .into_any_element()
    }

    fn mcp_section(&self, l10n: &L10n, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let add = self.listener(cx, |s, window, cx| s.open_mcp(None, window, cx));
        let servers = self
            .mcp
            .as_ref()
            .map(|m| m.servers.clone())
            .unwrap_or_default();
        let rows: Vec<AnyElement> = if self.mcp_failed {
            vec![
                setting_row(
                    l10n.desktop_mcp_load_failed(),
                    None,
                    Button::new("mcp-retry", l10n.retry())
                        .on_click(self.listener(cx, |s, w, cx| s.refresh(w, cx))),
                    cx,
                )
                .into_any_element(),
            ]
        } else if servers.is_empty() {
            vec![
                setting_row(
                    l10n.direct_mcp_empty_title(),
                    Some(l10n.desktop_mcp_reachability_help().into()),
                    Button::new("mcp-add", l10n.desktop_mcp_add_ellipsis())
                        .icon(IconName::Plus)
                        .on_click(add.clone()),
                    cx,
                )
                .into_any_element(),
            ]
        } else {
            servers
                .iter()
                .map(|s| {
                    let mut subtitle = endpoint_label(&s.endpoint);
                    if s.auth == McpAuth::Oauth {
                        subtitle = format!(
                            "{subtitle} \u{b7} {}",
                            if s.oauth_connected {
                                l10n.desktop_mcp_signed_in()
                            } else {
                                l10n.desktop_mcp_not_signed_in()
                            }
                        );
                    }
                    let edit = {
                        let s = s.clone();
                        self.listener(cx, move |p, w, cx| p.open_mcp(Some(s.clone()), w, cx))
                    };
                    let toggle = {
                        let (id, on) = (s.id.clone(), s.enabled);
                        self.listener(cx, move |p, w, cx| {
                            p.set_mcp_enabled(id.clone(), !on, w, cx)
                        })
                    };
                    div()
                        .id(ElementId::Name(format!("mcp-row-{}", s.id).into()))
                        .w_full()
                        .min_h(px(t.metrics.row_height + 20.))
                        .px(px(12.))
                        .py(px(8.))
                        .flex()
                        .items_center()
                        .gap(px(12.))
                        .child(
                            div()
                                .size(px(28.))
                                .flex_none()
                                .flex()
                                .items_center()
                                .justify_center()
                                .rounded(px(7.))
                                .bg(with_alpha(t.roles.text, if t.dark { 0.12 } else { 0.06 }))
                                .child(icon(
                                    IconName::Wrench,
                                    14.,
                                    if s.enabled {
                                        t.roles.text
                                    } else {
                                        t.roles.text_faint
                                    },
                                )),
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
                                        .text_color(t.roles.text)
                                        .child(SharedString::from(s.name.clone())),
                                )
                                .child(
                                    div()
                                        .truncate()
                                        .text_size(px(t.metrics.small))
                                        .text_color(t.roles.text_subtle)
                                        .child(SharedString::from(subtitle)),
                                ),
                        )
                        .child(
                            Button::new(
                                ElementId::Name(format!("mcp-edit-{}", s.id).into()),
                                l10n.desktop_edit_ellipsis(),
                            )
                            .on_click(edit),
                        )
                        .child(
                            Switch::new(
                                ElementId::Name(format!("mcp-enabled-{}", s.id).into()),
                                l10n.desktop_direct_enable(&s.name),
                                s.enabled,
                            )
                            .on_click(toggle),
                        )
                        .into_any_element()
                })
                .collect()
        };
        let add_again = (!servers.is_empty() && !self.mcp_failed).then(|| {
            controls::buttons(vec![
                Button::new("mcp-add-more", l10n.desktop_mcp_add_ellipsis())
                    .icon(IconName::Plus)
                    .on_click(add)
                    .into_any_element(),
            ])
        });
        div()
            .flex()
            .flex_col()
            .gap(px(8.))
            // The empty row says what a server is; the footer, once there
            // are some, what becomes of their tools.
            .child(settings_section(
                l10n.direct_mcp_servers_title(),
                (!servers.is_empty() && !self.mcp_failed)
                    .then(|| l10n.desktop_mcp_section_help().into()),
                rows,
                cx,
            ))
            .children(add_again)
            .into_any_element()
    }

    /// One model's context-limit row.
    fn context_row(
        options: &DirectOptions,
        index: usize,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut App,
    ) -> Option<AnyElement> {
        let m = options.context_models.get(index)?;
        let mut choices: Vec<Choice> = options
            .context_limit_choices
            .iter()
            .map(|n| Choice::new(n.to_string(), tokens_label(*n)))
            .collect();
        if !options.context_limit_choices.contains(&m.limit) {
            choices.push(Choice::new(m.limit.to_string(), tokens_label(m.limit)).separated());
        }
        let popup = controls::popup(
            &format!("{MENU_CONTEXT}{}", m.id),
            &l10n.desktop_context_limit_for(&m.name),
            choices,
            &m.limit.to_string(),
            false,
            window,
            cx,
        );
        let divider = cx.conduit().roles.divider;
        Some(
            model_logo::model_row(
                m.logo.as_deref(),
                m.name.clone(),
                m.connection.clone().map(Into::into),
                popup,
                cx,
            )
            .when(index > 0, |d| d.border_t_1().border_color(divider))
            .into_any_element(),
        )
    }

    fn context_section(
        &self,
        options: &DirectOptions,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if options.context_models.is_empty() {
            return None;
        }
        let total = options.context_models.len();
        // A gateway can list hundreds of models: past a few, they scroll in
        // a list of their own that draws only the rows in view.
        let rows: Vec<AnyElement> = if total <= CONTEXT_ROWS {
            vec![
                div()
                    .flex()
                    .flex_col()
                    .children(
                        (0..total).filter_map(|i| Self::context_row(options, i, l10n, window, cx)),
                    )
                    .into_any_element(),
            ]
        } else {
            let row = cx.conduit().metrics.row_height + 24.;
            vec![
                gpui_kit::uniform_list(
                    "direct-context-models",
                    total,
                    cx.processor(
                        |this: &mut Self, range: std::ops::Range<usize>, window, cx| {
                            let Some(options) = this.options.clone() else {
                                return vec![];
                            };
                            let l10n = cx.l10n().clone();
                            range
                                .filter_map(|i| Self::context_row(&options, i, &l10n, window, cx))
                                .collect::<Vec<_>>()
                        },
                    ),
                )
                .w_full()
                .h(px(row * CONTEXT_VISIBLE))
                .into_any_element(),
            ]
        };
        let mut footer = l10n.direct_context_compaction_description();
        if options.context_models.iter().any(|m| m.ollama) {
            footer = format!("{footer}\n\n{}", l10n.direct_context_limit_ollama_note());
        }
        Some(
            settings_section(
                l10n.direct_context_compaction_title(),
                Some(footer.into()),
                rows,
                cx,
            )
            .into_any_element(),
        )
    }

    fn web_search_section(
        &self,
        w: &WebSearchSettings,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let engine_label = |id: &str, name: &str| {
            if id == "auto" || name.is_empty() {
                l10n.web_search_engine_auto()
            } else {
                name.to_string()
            }
        };
        let engines: Vec<Choice> = w
            .engines
            .iter()
            .enumerate()
            .map(|(i, e)| {
                let c = Choice::new(e.id.clone(), engine_label(&e.id, &e.name));
                if i == 1 { c.separated() } else { c }
            })
            .collect();
        let region_name = |code: &str| -> String {
            if code == "wt-wt" {
                return l10n.web_search_region_worldwide();
            }
            w.regions
                .iter()
                .find(|r| r.code == code)
                .map(|r| r.name.clone())
                .filter(|n| !n.is_empty())
                .unwrap_or_else(|| code.to_string())
        };
        let mut regions = vec![Choice::new(
            REGION_AUTO,
            format!(
                "{} ({})",
                l10n.desktop_web_search_region_this_mac(),
                region_name(&w.effective_region)
            ),
        )];
        regions.extend(w.regions.iter().enumerate().map(|(i, r)| {
            let c = Choice::new(r.code.clone(), region_name(&r.code));
            if i <= 1 { c.separated() } else { c }
        }));
        let safe = vec![
            Choice::new("strict", l10n.web_search_safe_search_strict()),
            Choice::new("moderate", l10n.web_search_safe_search_moderate()),
            Choice::new("off", l10n.web_search_safe_search_off()),
        ];
        let chosen_engine = w.engines.iter().find(|e| e.id == w.engine);
        let footer = match chosen_engine.filter(|e| e.id != "auto" && !e.name.is_empty()) {
            Some(e) => l10n.desktop_web_search_footer_engine(&e.name),
            None => l10n.desktop_web_search_footer_auto(),
        };
        let rows = vec![
            setting_row(
                l10n.web_search_engine_label(),
                None,
                controls::popup(
                    MENU_ENGINE,
                    &l10n.web_search_engine_label(),
                    engines,
                    &w.engine,
                    false,
                    window,
                    cx,
                ),
                cx,
            )
            .into_any_element(),
            setting_row(
                l10n.web_search_safe_search_label(),
                None,
                controls::popup(
                    MENU_SAFE,
                    &l10n.web_search_safe_search_label(),
                    safe,
                    &w.safe_search,
                    false,
                    window,
                    cx,
                ),
                cx,
            )
            .into_any_element(),
            setting_row(
                l10n.desktop_web_search_region(),
                None,
                controls::popup(
                    MENU_REGION,
                    &l10n.desktop_web_search_region(),
                    regions,
                    w.region.as_deref().unwrap_or(REGION_AUTO),
                    false,
                    window,
                    cx,
                ),
                cx,
            )
            .into_any_element(),
        ];
        settings_section(l10n.web_search(), Some(footer.into()), rows, cx).into_any_element()
    }
}

/// One list of connections in the pane, and what it says when empty.
struct Connections {
    title: Option<String>,
    footer: Option<String>,
    connections: Vec<DirectConnectionSummary>,
    empty: (String, String),
    /// Kept in the Open WebUI account (Add adds one there).
    open_web_ui: bool,
}

/// An MCP endpoint without its query (a token can hide there).
pub fn endpoint_label(endpoint: &str) -> String {
    match url::Url::parse(endpoint) {
        Ok(mut u) => {
            u.set_query(None);
            u.set_fragment(None);
            let _ = u.set_username("");
            let _ = u.set_password(None);
            u.to_string().trim_end_matches('/').to_string()
        }
        Err(_) => endpoint.to_string(),
    }
}

/// The line under Apple On-Device: "Available" with its context limit, or
/// why it cannot answer now.
/// Apple's on-device model when this Mac could not be asked: unavailable
/// for now, with no reason known.
fn unknown_apple() -> AppleModels {
    AppleModels {
        models: vec![AppleModelStatus {
            model: AppleModelKind::OnDevice,
            availability: AppleAvailability::Unavailable,
            reason: Some(AppleUnavailableReason::Other),
            context_size: None,
            supports_current_locale: None,
        }],
    }
}

pub fn apple_detail(m: &AppleModelStatus, l10n: &L10n) -> String {
    if m.availability == AppleAvailability::Available {
        let available = l10n.apple_pcc_status_available();
        return match m.context_size {
            Some(tokens) if tokens > 0 => format!(
                "{available} \u{b7} {}",
                l10n.direct_context_limit(&tokens_label(tokens))
            ),
            _ => available,
        };
    }
    match m.reason {
        Some(AppleUnavailableReason::SystemTooOld) => l10n.desktop_apple_needs_macos26(),
        Some(AppleUnavailableReason::DeviceNotEligible) => l10n.desktop_apple_mac_not_eligible(),
        Some(AppleUnavailableReason::AppleIntelligenceNotEnabled) => {
            l10n.desktop_apple_intelligence_off()
        }
        Some(AppleUnavailableReason::ModelNotReady) => l10n.desktop_apple_model_not_ready(),
        _ => l10n.desktop_apple_unavailable_now(),
    }
}

/// A token count as the phone writes it: `8K`, `1M`.
pub fn tokens_label(tokens: i64) -> String {
    const K: i64 = 1024;
    if tokens > 0 && tokens % (K * K) == 0 {
        format!("{}M", tokens / (K * K))
    } else if tokens > 0 && tokens % K == 0 {
        format!("{}K", tokens / K)
    } else {
        tokens.to_string()
    }
}

impl Render for DirectPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let mut sections: Vec<AnyElement> = vec![];
        let Some(list) = self.list.clone() else {
            return div().child(controls::lead(l10n.desktop_loading(), cx));
        };
        let (account, mac): (Vec<_>, Vec<_>) = list
            .connections
            .iter()
            .cloned()
            .partition(|c| c.open_web_ui);
        // Apple's models first, as on the phone.
        if let Some(apple) = self.apple.clone()
            && !apple.models.is_empty()
        {
            sections.push(self.apple_section(&apple, &l10n, cx));
        }
        if list.open_web_ui_available {
            let sync = !list.local_history;
            sections.push(
                settings_section(
                    "",
                    Some(
                        if sync {
                            l10n.sync_direct_history_subtitle()
                        } else {
                            l10n.desktop_direct_history_local_help()
                        }
                        .into(),
                    ),
                    vec![
                        setting_row(
                            l10n.sync_direct_history(),
                            None,
                            Switch::new("direct-history", l10n.sync_direct_history(), sync)
                                .on_click(
                                    self.listener(cx, move |s, w, cx| s.set_history(!sync, w, cx)),
                                ),
                            cx,
                        )
                        .into_any_element(),
                    ],
                    cx,
                )
                .into_any_element(),
            );
            let mut owui = vec![self.connections(
                Connections {
                    title: Some(l10n.open_web_ui_direct_connections_section_title()),
                    footer: Some(l10n.open_web_ui_direct_connections_section_description()),
                    connections: account,
                    empty: (
                        l10n.open_web_ui_direct_profiles_empty_title(),
                        l10n.open_web_ui_direct_profiles_empty_subtitle(),
                    ),
                    open_web_ui: true,
                },
                &l10n,
                cx,
            )];
            if list.open_web_ui_load_failed {
                owui.push(
                    controls::buttons(vec![
                        div()
                            .flex_1()
                            .text_size(px(cx.conduit().metrics.small))
                            .text_color(cx.conduit().roles.text_subtle)
                            .child(l10n.open_web_ui_direct_connections_load_failed())
                            .into_any_element(),
                        Button::new("direct-owui-retry", l10n.retry())
                            .on_click(self.listener(cx, |s, w, cx| s.refresh(w, cx)))
                            .into_any_element(),
                    ])
                    .into_any_element(),
                );
            }
            sections.push(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(8.))
                    .children(owui)
                    .into_any_element(),
            );
        }
        // A server that moved its users' connections to Tether says so where
        // they were.
        if !list.open_web_ui_available && list.open_web_ui_moved_to_tether {
            sections.push(
                settings_section(
                    l10n.open_web_ui_direct_connections_section_title(),
                    None,
                    vec![
                        controls::lead(l10n.open_web_ui_direct_connections_moved_to_tether(), cx)
                            .debug_selector(|| "direct-owui-moved".into())
                            .p(px(10.))
                            .into_any_element(),
                    ],
                    cx,
                )
                .into_any_element(),
            );
        }
        sections.push(
            self.connections(
                Connections {
                    title: list
                        .open_web_ui_available
                        .then(|| l10n.desktop_on_this_mac()),
                    footer: Some(l10n.desktop_direct_connections_help()),
                    connections: mac,
                    empty: (
                        l10n.direct_profiles_empty_title(),
                        l10n.direct_profiles_empty_subtitle(),
                    ),
                    open_web_ui: false,
                },
                &l10n,
                cx,
            ),
        );
        sections.push(self.mcp_section(&l10n, cx));
        if let Some(options) = self.options.clone() {
            if let Some(s) = self.context_section(&options, &l10n, window, cx) {
                sections.push(s);
            }
            let images: Vec<Choice> = options
                .images_per_request_choices
                .iter()
                .map(|n| Choice::new(n.to_string(), n.to_string()))
                .collect();
            sections.push(
                settings_section(
                    l10n.attachments(),
                    Some(l10n.direct_images_per_request_footer().into()),
                    vec![
                        setting_row(
                            l10n.desktop_images_per_request(),
                            None,
                            controls::popup(
                                MENU_IMAGES,
                                &l10n.desktop_images_per_request(),
                                images,
                                &options.images_per_request.to_string(),
                                false,
                                window,
                                cx,
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
        if let Some(w) = self.search.clone() {
            sections.push(self.web_search_section(&w, &l10n, window, cx));
        }
        div().flex().flex_col().gap(px(22.)).children(sections)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use conduit_components::theme::{ConduitTheme, DesignPrefs, install};
    use conduit_protocol::DirectContextModel;
    use gpui_kit::{ScrollStrategy, TestAppContext, UniformListScrollHandle};

    /// The context-limit list as the pane draws it past a few models.
    /// `built`: the rows each frame built, first and last index.
    struct LongList {
        options: DirectOptions,
        scroll: UniformListScrollHandle,
        built: std::rc::Rc<std::cell::RefCell<Vec<std::ops::Range<usize>>>>,
    }

    impl Render for LongList {
        fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            let total = self.options.context_models.len();
            div().size_full().child(
                gpui_kit::uniform_list(
                    "direct-context-models",
                    total,
                    cx.processor(
                        |this: &mut Self, range: std::ops::Range<usize>, window, cx| {
                            let l10n = cx.l10n().clone();
                            let options = this.options.clone();
                            this.built.borrow_mut().push(range.clone());
                            range
                                .filter_map(|i| {
                                    DirectPane::context_row(&options, i, &l10n, window, cx)
                                })
                                .collect::<Vec<_>>()
                        },
                    ),
                )
                .track_scroll(&self.scroll)
                .w_full()
                .h(px(340.)),
            )
        }
    }

    /// A gateway's hundreds of models scroll in a list that builds only the
    /// rows in view each frame (what keeps it within a frame), whatever the
    /// machine's speed.
    #[gpui_kit::test]
    fn a_gateways_hundreds_of_models_build_only_the_rows_in_view(cx: &mut TestAppContext) {
        cx.update(|cx| {
            gpui_kit::init(cx);
            install(
                ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
                cx,
            );
            cx.set_global(crate::l10n::L10n::new("en"));
        });
        let options = DirectOptions {
            images_per_request: 10,
            images_per_request_choices: vec![1, 10],
            context_models: (0..500)
                .map(|i| DirectContextModel {
                    id: format!("direct:gateway:model-{i}"),
                    name: format!("gateway-model-{i}"),
                    connection: Some("Harbour gateway".into()),
                    limit: 4096,
                    ollama: false,
                    logo: (i % 3 == 0).then(|| "openai".to_string()),
                })
                .collect(),
            context_limit_choices: vec![4096, 8192, 16384, 32768],
        };
        let scroll = UniformListScrollHandle::new();
        let built = std::rc::Rc::<std::cell::RefCell<Vec<std::ops::Range<usize>>>>::default();
        let seen = built.clone();
        let (_, vcx) = cx.add_window_view(|_, _| LongList {
            options,
            scroll: scroll.clone(),
            built: seen,
        });
        vcx.update(|window, cx| window.draw(cx).clear(cx));
        // A frame per step down the list, as a scroll draws them.
        for step in 0..125 {
            scroll.scroll_to_item(step * 4, ScrollStrategy::Top);
            vcx.update(|window, cx| {
                window.refresh();
                window.draw(cx).clear(cx);
            });
        }
        let built = built.borrow();
        // 340 pt of rows at least 44 pt tall: a screenful, never the 500.
        let most = built.iter().map(|r| r.len()).max().unwrap_or(0);
        assert!(
            (1..=12).contains(&most),
            "a frame built {most} of the 500 rows"
        );
        assert!(
            built.iter().any(|r| r.end == 500),
            "the scroll never reached the last model"
        );
    }

    /// A server that moved its users' connections to Tether says so where
    /// they were listed; one that keeps them does not.
    #[gpui_kit::test]
    fn a_server_that_moved_its_connections_to_tether_says_so(cx: &mut TestAppContext) {
        use conduit_protocol::methods;

        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-dmoved-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let moved = DirectConnectionList {
            open_web_ui_moved_to_tether: true,
            ..Default::default()
        };
        daemon.returns::<methods::DirectReload>(moved.clone());
        daemon.returns::<methods::DirectList>(moved);
        let (_pane, vcx) =
            cx.add_window_view(move |window, cx| DirectPane::new(stores, window, cx));
        vcx.run_until_parked();
        vcx.update(|window, cx| window.draw(cx).clear(cx));
        assert!(vcx.debug_bounds("direct-owui-moved").is_some());
    }

    /// A history switch the daemon did not take shows where chats really
    /// go: the pane never says "on this Mac" while they still sync.
    #[gpui_kit::test]
    fn a_refused_history_switch_shows_the_setting_kept(cx: &mut TestAppContext) {
        use conduit_protocol::methods;

        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-dpane-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let syncing = DirectConnectionList {
            local_history: false,
            ..Default::default()
        };
        daemon.returns::<methods::DirectReload>(syncing.clone());
        daemon.returns::<methods::DirectList>(syncing);
        daemon.on::<methods::DirectSetHistory>(|_| {
            Err(conduit_daemon::protocol::error("rpc.timeout", "slow"))
        });
        let (pane, vcx) = cx.add_window_view(move |window, cx| DirectPane::new(stores, window, cx));
        vcx.run_until_parked();
        pane.update_in(vcx, |p, window, cx| p.set_history(false, window, cx));
        vcx.run_until_parked();
        pane.read_with(vcx, |p, _| {
            assert_eq!(
                p.list.as_ref().map(|l| l.local_history),
                Some(false),
                "the pane says chats stay on this Mac; they still sync"
            );
        });
    }

    #[cfg(target_os = "macos")]
    fn apple_pane<'a>(
        cx: &'a mut TestAppContext,
        daemon: &crate::stores::rpc::fake::FakeDaemon,
    ) -> (
        gpui_kit::Entity<DirectPane>,
        &'a mut gpui_kit::VisualTestContext,
    ) {
        use conduit_protocol::methods;
        let scratch =
            std::env::temp_dir().join(format!("conduit-dpane-apple-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        daemon.returns::<methods::DirectReload>(DirectConnectionList::default());
        daemon.returns::<methods::DirectList>(DirectConnectionList::default());
        cx.add_window_view(move |window, cx| DirectPane::new(stores, window, cx))
    }

    #[cfg(target_os = "macos")]
    fn on_device(availability: AppleAvailability) -> AppleModels {
        AppleModels {
            models: vec![AppleModelStatus {
                model: AppleModelKind::OnDevice,
                availability,
                reason: None,
                context_size: None,
                supports_current_locale: None,
            }],
        }
    }

    /// The first Apple ask fails: the row stays, unknown, with Check Again,
    /// rather than the section going away.
    #[cfg(target_os = "macos")]
    #[gpui_kit::test]
    fn a_failed_first_apple_ask_keeps_the_row_and_check_again(cx: &mut TestAppContext) {
        use conduit_protocol::methods;

        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        daemon.on::<methods::AppleStatus>(|_| {
            Err(conduit_daemon::protocol::error("rpc.timeout", "slow"))
        });
        daemon.returns::<methods::AppleRefresh>(on_device(AppleAvailability::Available));
        let (pane, vcx) = apple_pane(cx, &daemon);
        vcx.run_until_parked();
        pane.read_with(vcx, |p, _| {
            let apple = p.apple.as_ref().expect("the Apple row is shown");
            assert_eq!(apple.models[0].availability, AppleAvailability::Unavailable);
            assert!(!p.apple_checking);
        });
        pane.update_in(vcx, |p, window, cx| p.check_apple(window, cx));
        vcx.run_until_parked();
        pane.read_with(vcx, |p, _| {
            assert_eq!(
                p.apple.as_ref().map(|a| a.models[0].availability),
                Some(AppleAvailability::Available)
            );
        });
    }

    /// An older Apple ask answering after a newer one is not taken.
    #[cfg(target_os = "macos")]
    #[gpui_kit::test]
    fn an_older_apple_answer_never_replaces_a_newer_one(cx: &mut TestAppContext) {
        use std::sync::atomic::{AtomicUsize, Ordering};

        use conduit_protocol::methods;

        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        // The first ask (held) finds the model not ready; the second, ready.
        let asks = std::sync::Arc::new(AtomicUsize::new(0));
        daemon.on::<methods::AppleStatus>(move |_| {
            let first = asks.fetch_add(1, Ordering::SeqCst) == 0;
            Ok(serde_json::to_value(on_device(if first {
                AppleAvailability::Unavailable
            } else {
                AppleAvailability::Available
            }))
            .unwrap())
        });
        let held = daemon.hold_one::<methods::AppleStatus>(0);
        let (pane, vcx) = apple_pane(cx, &daemon);
        vcx.run_until_parked();
        pane.update_in(vcx, |p, window, cx| p.refresh(window, cx));
        vcx.run_until_parked();
        held.release();
        vcx.run_until_parked();
        pane.read_with(vcx, |p, _| {
            assert_eq!(
                p.apple.as_ref().map(|a| a.models[0].availability),
                Some(AppleAvailability::Available)
            );
            assert!(!p.apple_checking);
        });
    }

    /// An Apple ask still out holds back none of the other answers.
    #[cfg(target_os = "macos")]
    #[gpui_kit::test]
    fn the_other_settings_land_while_apple_is_still_asked(cx: &mut TestAppContext) {
        use conduit_protocol::{McpServerList, methods};

        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AppleStatus>(on_device(AppleAvailability::Available));
        let held = daemon.hold::<methods::AppleStatus>();
        daemon.returns::<methods::McpList>(McpServerList::default());
        daemon.on::<methods::WebSearchGet>(|_| Ok(serde_json::json!({})));
        daemon.on::<methods::DirectOptions>(|_| Ok(serde_json::json!({})));
        let (pane, vcx) = apple_pane(cx, &daemon);
        vcx.run_until_parked();
        pane.read_with(vcx, |p, _| {
            assert!(p.apple_checking, "Apple is still being asked");
            assert!(p.mcp.is_some(), "MCP servers");
            assert!(p.search.is_some(), "web search");
            assert!(p.options.is_some(), "Direct options");
            assert!(p.list.is_some(), "connections");
        });
        held.release();
        vcx.run_until_parked();
        pane.read_with(vcx, |p, _| assert!(p.apple.is_some()));
    }

    /// Two history switches out at once, both refused: the pane goes back
    /// to the setting the daemon last confirmed, not to the first switch's
    /// own guess.
    #[gpui_kit::test]
    fn overlapping_refused_history_switches_show_the_confirmed_setting(cx: &mut TestAppContext) {
        use conduit_protocol::methods;

        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-dhist-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        daemon.returns::<methods::DirectReload>(DirectConnectionList {
            local_history: false,
            ..Default::default()
        });
        // Nothing reads the list again: only the pane's own rule is left.
        daemon.on::<methods::DirectList>(|_| {
            Err(conduit_daemon::protocol::error(
                "rpc.daemonUnavailable",
                "offline",
            ))
        });
        daemon.on::<methods::DirectSetHistory>(|_| {
            Err(conduit_daemon::protocol::error("rpc.timeout", "slow"))
        });
        let (pane, vcx) = cx.add_window_view(move |window, cx| DirectPane::new(stores, window, cx));
        vcx.run_until_parked();
        let held = daemon.hold::<methods::DirectSetHistory>();
        pane.update_in(vcx, |p, window, cx| p.set_history(false, window, cx));
        pane.update_in(vcx, |p, window, cx| p.set_history(true, window, cx));
        vcx.run_until_parked();
        held.release();
        vcx.run_until_parked();
        pane.read_with(vcx, |p, _| {
            assert_eq!(
                p.list.as_ref().map(|l| l.local_history),
                Some(false),
                "the pane says chats stay on this Mac; they still sync"
            );
        });

        // A read after the first refusal finds the daemon keeping chats on
        // this Mac: that is what the second refusal goes back to, though
        // the read after it fails.
        daemon.once::<methods::DirectList>(Ok(DirectConnectionList {
            local_history: true,
            ..Default::default()
        }));
        let second = daemon.hold_one::<methods::DirectSetHistory>(1);
        pane.update_in(vcx, |p, window, cx| p.set_history(false, window, cx));
        pane.update_in(vcx, |p, window, cx| p.set_history(true, window, cx));
        vcx.run_until_parked();
        second.release();
        vcx.run_until_parked();
        pane.read_with(vcx, |p, _| {
            assert_eq!(
                p.list.as_ref().map(|l| l.local_history),
                Some(true),
                "the pane went back past the setting the daemon read out since"
            );
        });
    }

    #[test]
    fn apple_on_device_says_its_context_or_why_it_cannot_answer() {
        let l10n = crate::l10n::L10n::new("en");
        let status = |availability, reason, context_size| AppleModelStatus {
            model: AppleModelKind::OnDevice,
            availability,
            reason,
            context_size,
            supports_current_locale: Some(true),
        };
        assert_eq!(
            apple_detail(
                &status(AppleAvailability::Available, None, Some(4096)),
                &l10n
            ),
            "Available \u{b7} Context limit: 4K"
        );
        assert_eq!(
            apple_detail(&status(AppleAvailability::Available, None, None), &l10n),
            "Available"
        );
        let why = |reason| {
            apple_detail(
                &status(AppleAvailability::Unavailable, Some(reason), None),
                &l10n,
            )
        };
        assert_eq!(
            why(AppleUnavailableReason::ModelNotReady),
            "The model is still downloading or isn't ready yet."
        );
        assert_eq!(
            why(AppleUnavailableReason::AppleIntelligenceNotEnabled),
            "Turn on Apple Intelligence in System Settings to use it."
        );
        assert_eq!(
            why(AppleUnavailableReason::DeviceNotEligible),
            "This Mac can't run Apple Intelligence."
        );
        assert_eq!(
            why(AppleUnavailableReason::SystemTooOld),
            "Requires macOS 26 or later."
        );
        assert_eq!(
            why(AppleUnavailableReason::NoEngine),
            "Not available right now."
        );
    }

    #[test]
    fn token_counts_read_as_the_phone_writes_them() {
        assert_eq!(tokens_label(4096), "4K");
        assert_eq!(tokens_label(131072), "128K");
        assert_eq!(tokens_label(1048576), "1M");
        assert_eq!(tokens_label(5000), "5000");
    }

    #[test]
    fn an_endpoint_is_shown_without_its_query_or_user() {
        assert_eq!(
            endpoint_label("https://user:pw@mcp.example.com/mcp?token=abc#x"),
            "https://mcp.example.com/mcp"
        );
        assert_eq!(endpoint_label("not a url"), "not a url");
    }
}
