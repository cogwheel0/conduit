//! The MCP server sheets of Settings › Hermes: Add MCP Server (a server of
//! the user's own, at a web address or run as a command, with an optional
//! API key) and an existing server's API key. The phone's page asks the
//! same in dialogs; a key is sent once and never kept on this Mac.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::views::kit::{Button, Segment, Segmented, grouped_section};
use conduit_protocol::{HermesMcpAdd, HermesMcpApiKey, NoticeLevel, methods};
use gpui_kit::component::input::{InputEvent, InputState, Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, Entity, FontWeight, Role, SharedString, Subscription,
    WeakEntity, Window, div, px, relative,
};

use crate::l10n::ActiveL10n as _;
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::views::forms;
use crate::views::sheet::{self, SheetBody};

pub const WIDTH: f32 = 480.;

/// Opens Add MCP Server on `window` (Settings).
pub fn open_add(stores: &Stores, window: &mut Window, cx: &mut App) {
    let stores = stores.clone();
    sheet::open(window, WIDTH, cx, move |w, cx| {
        AddMcpSheet::new(stores, w, cx)
    });
}

/// Opens server `name`'s API key sheet on `window`.
pub fn open_key(stores: &Stores, name: &str, window: &mut Window, cx: &mut App) {
    let stores = stores.clone();
    let name = name.to_string();
    sheet::open(window, WIDTH, cx, move |w, cx| {
        McpKeySheet::new(stores, name, w, cx)
    });
}

fn title(text: String, cx: &App) -> AnyElement {
    let t = cx.conduit();
    div()
        .id("sheet-title")
        .role(Role::Heading)
        .text_size(px(t.metrics.body + 2.))
        .font_weight(FontWeight::SEMIBOLD)
        .child(SharedString::from(text))
        .into_any_element()
}

/// Asks before throwing a typed form away.
fn discard(window: &mut Window, cx: &mut App) {
    let l = cx.l10n().clone();
    let spec = SheetSpec::new(
        l.desktop_discard_changes_title(),
        l.desktop_discard_changes_message(),
        l.desktop_discard(),
        l.cancel(),
    )
    .destructive();
    let ask = present_sheet(window, spec, cx);
    cx.spawn(async move |cx: &mut AsyncApp| {
        if ask.await {
            cx.update(sheet::dismiss);
        }
    })
    .detach();
}

pub struct AddMcpSheet {
    stores: Stores,
    pub name: Entity<InputState>,
    pub url: Entity<InputState>,
    pub command: Entity<InputState>,
    pub args: Entity<TextareaState>,
    pub key: Entity<InputState>,
    /// Runs as a command, rather than at a web address.
    pub by_command: bool,
    pub busy: bool,
    pub error: Option<String>,
    _subscriptions: Vec<Subscription>,
}

impl AddMcpSheet {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let l = cx.l10n().clone();
        let name = forms::input(l.desktop_required_placeholder(), false, window, cx);
        let url = forms::input("https://example.com/mcp", false, window, cx);
        let command = forms::input("npx", false, window, cx);
        let args = cx.new(|cx| TextareaState::new(window, cx).auto_grow(2, 6));
        let key = forms::input(l.desktop_optional(), true, window, cx);
        let mut subscriptions = vec![];
        for input in [&name, &url, &command, &key] {
            subscriptions.push(cx.subscribe_in(
                input,
                window,
                |this: &mut Self, _, e: &InputEvent, window, cx| match e {
                    InputEvent::PressEnter { .. } if this.can_add(cx) => this.add(window, cx),
                    InputEvent::Change => {
                        this.error = None;
                        cx.notify();
                    }
                    _ => {}
                },
            ));
        }
        subscriptions.push(cx.subscribe(&args, |_, _, e: &InputEvent, cx| {
            if matches!(e, InputEvent::Change) {
                cx.notify();
            }
        }));
        name.update(cx, |i, cx| i.focus(window, cx));
        Self {
            stores,
            name,
            url,
            command,
            args,
            key,
            by_command: false,
            busy: false,
            error: None,
            _subscriptions: subscriptions,
        }
    }

    pub fn can_add(&self, cx: &App) -> bool {
        let target = if self.by_command {
            &self.command
        } else {
            &self.url
        };
        !self.busy && forms::filled(&[&self.name, target], cx)
    }

    fn typed(&self, cx: &App) -> bool {
        [&self.name, &self.url, &self.command, &self.key]
            .iter()
            .any(|i| !forms::raw(i, cx).trim().is_empty())
            || !self.args.read(cx).value().trim().is_empty()
    }

    pub fn add(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        if !self.can_add(cx) {
            return;
        }
        let name = forms::text(&self.name, cx);
        let key = forms::raw(&self.key, cx);
        let request = HermesMcpAdd {
            name: name.clone(),
            url: (!self.by_command).then(|| forms::text(&self.url, cx)),
            command: self.by_command.then(|| forms::text(&self.command, cx)),
            args: if self.by_command {
                self.args
                    .read(cx)
                    .value()
                    .lines()
                    .map(str::trim)
                    .filter(|a| !a.is_empty())
                    .map(String::from)
                    .collect()
            } else {
                vec![]
            },
            api_key: (!key.trim().is_empty()).then_some(key),
        };
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::HermesMcpAdd>(&request);
        self.busy = true;
        self.error = None;
        cx.notify();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.busy = false;
                let l = cx.l10n().clone();
                match result {
                    Ok(servers) => {
                        s.stores
                            .hermes_admin
                            .update(cx, |a, cx| a.adopt_mcp(servers, cx));
                        let text = l.desktop_hermes_mcp_added(&name);
                        s.stores
                            .toasts
                            .update(cx, |t, cx| t.show(NoticeLevel::Success, text, cx));
                        sheet::dismiss(cx);
                    }
                    Err(e) => {
                        log::info!("hermes.mcp.add: {e}");
                        s.error = Some(l.desktop_hermes_mcp_action_failed());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
}

impl SheetBody for AddMcpSheet {
    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        if self.typed(cx) {
            discard(window, cx);
        } else {
            sheet::dismiss(cx);
        }
    }

    fn label(&self, cx: &App) -> SharedString {
        cx.l10n().desktop_hermes_mcp_add_title().into()
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let cancel = view.clone();
        Some(
            forms::form_buttons(vec![
                Button::new("hermes-mcp-add-cancel", l.cancel())
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = cancel.update(cx, |v, cx| v.cancel(window, cx));
                    }))
                    .into_any_element(),
                Button::new("hermes-mcp-add-confirm", l.desktop_add())
                    .primary()
                    .disabled(!self.can_add(cx))
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = view.update(cx, |v, cx| v.add(window, cx));
                    }))
                    .into_any_element(),
            ])
            .into_any_element(),
        )
    }
}

impl Render for AddMcpSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l = cx.l10n().clone();
        let t = cx.conduit().clone();
        let this = cx.entity().downgrade();
        let kind = Segmented::new(
            "hermes-mcp-kind",
            l.desktop_hermes_mcp_connects_by(),
            vec![
                Segment::new(l.desktop_hermes_mcp_by_url()),
                Segment::new(l.desktop_hermes_mcp_by_command()),
            ],
            usize::from(self.by_command),
        )
        .on_select(Rc::new(move |i, _, cx| {
            let _ = this.update(cx, |s, cx| {
                s.by_command = i == 1;
                s.error = None;
                cx.notify();
            });
        }));
        let mut rows = vec![
            forms::field(l.name(), &self.name, None, None, window, cx).into_any_element(),
            forms::form_row(l.desktop_hermes_mcp_connects_by(), kind, cx).into_any_element(),
        ];
        if self.by_command {
            rows.push(
                forms::field(
                    l.desktop_hermes_mcp_by_command(),
                    &self.command,
                    None,
                    None,
                    window,
                    cx,
                )
                .into_any_element(),
            );
            rows.push(
                div()
                    .id("hermes-mcp-args")
                    .p(px(12.))
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .child(
                        div()
                            .text_size(px(t.metrics.control))
                            .text_color(t.roles.text)
                            .child(l.desktop_hermes_mcp_arguments()),
                    )
                    .child(Textarea::new(&self.args))
                    .child(
                        div()
                            .text_size(px(t.metrics.small))
                            .line_height(relative(1.35))
                            .text_color(t.roles.text_subtle)
                            .child(l.desktop_hermes_mcp_arguments_help()),
                    )
                    .into_any_element(),
            );
        } else {
            rows.push(
                forms::field(
                    l.desktop_hermes_mcp_url(),
                    &self.url,
                    None,
                    None,
                    window,
                    cx,
                )
                .into_any_element(),
            );
        }
        div()
            .id("hermes-mcp-add-sheet")
            .role(Role::Form)
            .aria_label(SharedString::from(l.desktop_hermes_mcp_add_title()))
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
            .child(title(l.desktop_hermes_mcp_add_title(), cx))
            .child(grouped_section(None, rows, None, cx))
            .child(grouped_section(
                None,
                vec![
                    forms::field(l.hermes_api_key_title(), &self.key, None, None, window, cx)
                        .into_any_element(),
                ],
                Some(l.desktop_hermes_mcp_key_help().into()),
                cx,
            ))
            .when_some(self.error.clone(), |d, e| {
                d.child(forms::form_error("hermes-mcp-add-error", e, cx))
            })
    }
}

pub struct McpKeySheet {
    stores: Stores,
    pub server: String,
    pub key: Entity<InputState>,
    pub busy: bool,
    pub error: Option<String>,
    _subscriptions: Vec<Subscription>,
}

impl McpKeySheet {
    pub fn new(
        stores: Stores,
        server: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l = cx.l10n().clone();
        let key = forms::input(l.hermes_api_key_placeholder(), true, window, cx);
        let subscriptions = vec![cx.subscribe_in(
            &key,
            window,
            |this: &mut Self, _, e: &InputEvent, window, cx| match e {
                InputEvent::PressEnter { .. } => this.save(window, cx),
                InputEvent::Change => {
                    this.error = None;
                    cx.notify();
                }
                _ => {}
            },
        )];
        key.update(cx, |i, cx| i.focus(window, cx));
        Self {
            stores,
            server,
            key,
            busy: false,
            error: None,
            _subscriptions: subscriptions,
        }
    }

    fn can_save(&self, cx: &App) -> bool {
        !self.busy && !forms::raw(&self.key, cx).is_empty()
    }

    pub fn save(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        if !self.can_save(cx) {
            return;
        }
        let name = self.server.clone();
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::HermesMcpSetApiKey>(&HermesMcpApiKey {
                name: name.clone(),
                api_key: forms::raw(&self.key, cx),
            });
        self.busy = true;
        cx.notify();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.busy = false;
                let l = cx.l10n().clone();
                match result {
                    Ok(servers) => {
                        s.stores
                            .hermes_admin
                            .update(cx, |a, cx| a.adopt_mcp(servers, cx));
                        let text = l.desktop_hermes_mcp_key_saved(&name);
                        s.stores
                            .toasts
                            .update(cx, |t, cx| t.show(NoticeLevel::Success, text, cx));
                        sheet::dismiss(cx);
                    }
                    Err(e) => {
                        log::info!("hermes.mcp.setApiKey: {e}");
                        s.error = Some(l.desktop_hermes_mcp_action_failed());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
}

impl SheetBody for McpKeySheet {
    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        if forms::raw(&self.key, cx).is_empty() {
            sheet::dismiss(cx);
        } else {
            discard(window, cx);
        }
    }

    fn label(&self, cx: &App) -> SharedString {
        cx.l10n()
            .desktop_hermes_mcp_api_key_title(&self.server)
            .into()
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let cancel = view.clone();
        Some(
            forms::form_buttons(vec![
                Button::new("hermes-mcp-key-cancel", l.cancel())
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = cancel.update(cx, |v, cx| v.cancel(window, cx));
                    }))
                    .into_any_element(),
                Button::new("hermes-mcp-key-save", l.save())
                    .primary()
                    .disabled(!self.can_save(cx))
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = view.update(cx, |v, cx| v.save(window, cx));
                    }))
                    .into_any_element(),
            ])
            .into_any_element(),
        )
    }
}

impl Render for McpKeySheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l = cx.l10n().clone();
        div()
            .id("hermes-mcp-key-sheet")
            .role(Role::Form)
            .aria_label(SharedString::from(
                l.desktop_hermes_mcp_api_key_title(&self.server),
            ))
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
            .child(title(l.desktop_hermes_mcp_api_key_title(&self.server), cx))
            .child(grouped_section(
                None,
                vec![
                    forms::field(l.hermes_api_key_title(), &self.key, None, None, window, cx)
                        .into_any_element(),
                ],
                Some(l.desktop_hermes_mcp_key_help().into()),
                cx,
            ))
            .when_some(self.error.clone(), |d, e| {
                d.child(forms::form_error("hermes-mcp-key-error", e, cx))
            })
    }
}
