//! The MCP server sheets of Settings › Hermes: Add MCP Server (a server of
//! the user's own, at a web address or run as a command, with an optional
//! API key), an existing server's API key, and a catalog server's values
//! (each one it asks for, typed hidden, the optional ones marked). The
//! phone's pages ask the same; a key or value is sent once and never kept
//! on this Mac.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::views::kit::{Button, Segment, Segmented, grouped_section};
use conduit_protocol::{
    HermesMcpAdd, HermesMcpApiKey, HermesMcpCatalogAdd, HermesMcpCatalogEntryDto, NoticeLevel,
    methods,
};
use gpui_kit::component::input::{InputEvent, InputState, Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, Entity, FontWeight, Role, SharedString, Subscription,
    WeakEntity, Window, div, px, relative,
};

use crate::l10n::ActiveL10n as _;
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::hermes_admin::Opened;
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

/// Opens catalog entry `entry`'s values sheet on `window` (Settings).
pub fn open_catalog(
    stores: &Stores,
    entry: HermesMcpCatalogEntryDto,
    window: &mut Window,
    cx: &mut App,
) {
    let stores = stores.clone();
    sheet::open(window, WIDTH, cx, move |w, cx| {
        CatalogSheet::new(stores, entry, w, cx)
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
    /// The connection in use when the sheet opened: the server is added
    /// to it, or to none.
    opened: Opened,
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
        let opened = stores.hermes_admin.read(cx).opened();
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
            opened,
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

    /// What the form holds now, to tell words typed during an Add.
    fn snapshot(&self, cx: &App) -> (Vec<String>, String, bool) {
        (
            [&self.name, &self.url, &self.command, &self.key]
                .iter()
                .map(|i| forms::raw(i, cx))
                .collect(),
            self.args.read(cx).value().to_string(),
            self.by_command,
        )
    }

    pub fn add(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        if !self.can_add(cx) {
            return;
        }
        let admin = self.stores.hermes_admin.read(cx);
        if !admin.still_in_use(&self.opened) {
            self.error = Some(cx.l10n().desktop_hermes_mcp_action_failed());
            cx.notify();
            return;
        }
        let sent = self.snapshot(cx);
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
            connection: self.opened.connection.clone(),
        };
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::HermesMcpAdd>(&request);
        // Its answer is taken in the order it was asked.
        let ticket = self.stores.hermes_admin.update(cx, |a, _| a.ask_mcp());
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
                        s.stores.hermes_admin.update(cx, |a, cx| {
                            a.answer_mcp(ticket, servers, cx);
                        });
                        let text = l.desktop_hermes_mcp_added(&name);
                        s.stores
                            .toasts
                            .update(cx, |t, cx| t.show(NoticeLevel::Success, text, cx));
                        // Words typed while the Add was out stay.
                        if s.snapshot(cx) == sent {
                            sheet::dismiss(cx);
                        }
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
    fn busy(&self, _: &App) -> bool {
        self.busy
    }

    /// A form typed, or an Add still out: Quit asks first.
    fn unsaved(&self, cx: &App) -> bool {
        self.busy || self.typed(cx)
    }

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
    /// The connection in use when the sheet opened: the key goes to its
    /// server, or nowhere.
    opened: Opened,
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
        let opened = stores.hermes_admin.read(cx).opened();
        Self {
            stores,
            server,
            key,
            busy: false,
            error: None,
            opened,
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
        let admin = self.stores.hermes_admin.read(cx);
        if !admin.still_in_use(&self.opened) {
            self.error = Some(cx.l10n().desktop_hermes_mcp_action_failed());
            cx.notify();
            return;
        }
        let sent = forms::raw(&self.key, cx);
        let name = self.server.clone();
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::HermesMcpSetApiKey>(&HermesMcpApiKey {
                name: name.clone(),
                api_key: forms::raw(&self.key, cx),
                connection: self.opened.connection.clone(),
            });
        let ticket = self.stores.hermes_admin.update(cx, |a, _| a.ask_mcp());
        self.busy = true;
        cx.notify();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.busy = false;
                let l = cx.l10n().clone();
                match result {
                    Ok(servers) => {
                        s.stores.hermes_admin.update(cx, |a, cx| {
                            a.answer_mcp(ticket, servers, cx);
                        });
                        let text = l.desktop_hermes_mcp_key_saved(&name);
                        s.stores
                            .toasts
                            .update(cx, |t, cx| t.show(NoticeLevel::Success, text, cx));
                        // Another key typed while this one was saved stays.
                        if forms::raw(&s.key, cx) == sent {
                            sheet::dismiss(cx);
                        }
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
    fn busy(&self, _: &App) -> bool {
        self.busy
    }

    /// A key typed, or a Save still out: Quit asks first.
    fn unsaved(&self, cx: &App) -> bool {
        self.busy || !forms::raw(&self.key, cx).is_empty()
    }

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

/// A catalog server's values: one hidden field for each it asks for, the
/// required ones needed before Add.
pub struct CatalogSheet {
    stores: Stores,
    pub entry: HermesMcpCatalogEntryDto,
    pub fields: Vec<Entity<InputState>>,
    pub busy: bool,
    pub error: Option<String>,
    /// The connection in use when the sheet opened: the values go to its
    /// server, or nowhere.
    opened: Opened,
    _subscriptions: Vec<Subscription>,
}

impl CatalogSheet {
    pub fn new(
        stores: Stores,
        entry: HermesMcpCatalogEntryDto,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l = cx.l10n().clone();
        let fields: Vec<Entity<InputState>> = entry
            .credentials
            .iter()
            .map(|c| {
                let hint = if c.required {
                    l.desktop_required_placeholder()
                } else {
                    l.desktop_optional()
                };
                forms::input(hint, true, window, cx)
            })
            .collect();
        let subscriptions = fields
            .iter()
            .map(|input| {
                cx.subscribe_in(
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
                )
            })
            .collect();
        if let Some(first) = fields.first() {
            first.update(cx, |i, cx| i.focus(window, cx));
        }
        let opened = stores.hermes_admin.read(cx).opened();
        Self {
            stores,
            entry,
            fields,
            busy: false,
            error: None,
            opened,
            _subscriptions: subscriptions,
        }
    }

    /// Every required value is given.
    pub fn can_add(&self, cx: &App) -> bool {
        !self.busy
            && self
                .entry
                .credentials
                .iter()
                .zip(&self.fields)
                .all(|(c, f)| !c.required || !forms::raw(f, cx).trim().is_empty())
    }

    fn typed(&self, cx: &App) -> bool {
        self.fields.iter().any(|f| !forms::raw(f, cx).is_empty())
    }

    fn clear(&self, window: &mut Window, cx: &mut Context<Self>) {
        for field in &self.fields {
            field.update(cx, |i, cx| i.set_value("", window, cx));
        }
    }

    pub fn add(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        if !self.can_add(cx) {
            self.error = Some(cx.l10n().hermes_mcp_fill_required());
            cx.notify();
            return;
        }
        if !self.stores.hermes_admin.read(cx).still_in_use(&self.opened) {
            self.error = Some(cx.l10n().hermes_mcp_action_failed());
            cx.notify();
            return;
        }
        let name = self.entry.name.clone();
        let oauth = self.entry.oauth;
        // Each value as typed: the daemon trims them and leaves out the
        // empty optional ones, as the phone does.
        let credentials = self
            .entry
            .credentials
            .iter()
            .zip(&self.fields)
            .map(|(c, f)| (c.name.clone(), forms::raw(f, cx)))
            .collect();
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::HermesMcpAddFromCatalog>(&HermesMcpCatalogAdd {
                name: name.clone(),
                credentials,
                connection: self.opened.connection.clone(),
            });
        // Its answer is taken in the order it was asked.
        let ticket = self.stores.hermes_admin.update(cx, |a, _| a.ask_mcp());
        self.busy = true;
        self.error = None;
        cx.notify();
        let _ = window;
        cx.spawn_in(window, async move |this: WeakEntity<Self>, cx| {
            let result = call.await;
            let _ = this.update_in(cx, |s, window, cx| {
                s.busy = false;
                match result {
                    Ok(added) => {
                        s.clear(window, cx);
                        sheet::dismiss(cx);
                        crate::views::settings::hermes::catalog_added(
                            &s.stores, &name, oauth, added, ticket, cx,
                        );
                    }
                    Err(e) => {
                        log::info!("hermes.mcp.addFromCatalog: {e}");
                        let l = cx.l10n().clone();
                        s.error = Some(
                            if e.args.get("reason").map(String::as_str) == Some("missingCredential")
                            {
                                l.hermes_mcp_fill_required()
                            } else {
                                l.hermes_mcp_action_failed()
                            },
                        );
                        // Asked again from the start, as on a phone; and
                        // listed again even when a step after the install
                        // failed.
                        s.clear(window, cx);
                        s.stores.hermes_admin.update(cx, |a, cx| a.refresh_mcp(cx));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
}

impl SheetBody for CatalogSheet {
    /// The Add out (set when it is asked, cleared when it lands).
    fn busy(&self, _: &App) -> bool {
        self.busy
    }

    /// Values typed, or an Add still out: Quit asks first.
    fn unsaved(&self, cx: &App) -> bool {
        self.busy || self.typed(cx)
    }

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
        let _ = cx;
        self.entry.name.clone().into()
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let cancel = view.clone();
        Some(
            forms::form_buttons(vec![
                Button::new("hermes-mcp-catalog-cancel", l.cancel())
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = cancel.update(cx, |v, cx| v.cancel(window, cx));
                    }))
                    .into_any_element(),
                Button::new("hermes-mcp-catalog-add", l.hermes_mcp_add())
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

impl Render for CatalogSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l = cx.l10n().clone();
        let t = cx.conduit().clone();
        let rows: Vec<AnyElement> = self
            .entry
            .credentials
            .iter()
            .zip(&self.fields)
            .map(|(c, f)| {
                let label = c.prompt.clone().unwrap_or_else(|| c.name.clone());
                let help = if c.required {
                    l.hermes_mcp_value_required(&c.name)
                } else {
                    l.hermes_mcp_value_optional(&c.name)
                };
                forms::field(label, f, Some(help.into()), None, window, cx).into_any_element()
            })
            .collect();
        div()
            .id("hermes-mcp-catalog-sheet")
            .role(Role::Form)
            .aria_label(SharedString::from(self.entry.name.clone()))
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
            .child(title(self.entry.name.clone(), cx))
            .when(!self.entry.description.trim().is_empty(), |d| {
                d.child(
                    div()
                        .id("hermes-mcp-catalog-description")
                        .text_size(px(t.metrics.control))
                        .line_height(relative(1.35))
                        .text_color(t.roles.text_subtle)
                        .child(SharedString::from(self.entry.description.clone())),
                )
            })
            .child(grouped_section(
                None,
                rows,
                Some(l.hermes_mcp_keeps_values(&self.entry.name).into()),
                cx,
            ))
            .when_some(self.error.clone(), |d, e| {
                d.child(forms::form_error("hermes-mcp-catalog-error", e, cx))
            })
    }
}

#[cfg(test)]
mod tests {
    use gpui_kit::VisualTestContext;
    use serde_json::json;

    use super::*;
    use crate::views::sheet::bench::bench;

    fn list(active: &str) -> conduit_protocol::HermesConnections {
        serde_json::from_value(json!({
            "enabled": true,
            "activeId": active,
            "connection": format!("0a1b2c3d:{active}"),
            "connections": [
                {"id": "a", "name": "Potting shed", "baseUrl": "http://127.0.0.1:20401",
                 "mode": "desktop", "active": active == "a"},
                {"id": "b", "name": "Greenhouse", "baseUrl": "http://127.0.0.1:20402",
                 "mode": "desktop", "active": active == "b"},
            ],
        }))
        .unwrap()
    }

    fn use_connection(stores: &Stores, vcx: &mut VisualTestContext, id: &str) {
        stores
            .hermes_admin
            .update(vcx, |a, cx| a.adopt_connections(list(id), cx));
        vcx.run_until_parked();
    }

    fn on_sheet<V: SheetBody>(
        vcx: &mut VisualTestContext,
        f: impl FnOnce(&mut V, &mut Window, &mut Context<V>),
    ) {
        vcx.update(|_, cx| {
            let body = sheet::current::<V>(cx).expect("the sheet is down");
            let window = sheet::current_window(cx).expect("the sheet's window");
            let _ = window.update(cx, |_, window, cx| {
                body.update(cx, |s, cx| f(s, window, cx))
            });
        });
    }

    /// A key typed into the sheet opened for one connection is never sent
    /// once another is in use: it would reach the other gateway's server.
    #[gpui_kit::test]
    fn a_key_goes_only_to_the_connection_it_was_typed_for(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        use_connection(&stores, vcx, "a");
        let s = stores.clone();
        vcx.update(|window, cx| open_key(&s, "seed-catalogue", window, cx));
        vcx.run_until_parked();
        on_sheet::<McpKeySheet>(vcx, |s, w, cx| {
            s.key
                .update(cx, |i, cx| i.set_value("sk-test-not-a-real-key", w, cx))
        });
        vcx.update(|_, cx| assert!(sheet::has_unsaved(cx), "Quit would drop the typed key"));
        use_connection(&stores, vcx, "b");
        on_sheet::<McpKeySheet>(vcx, |s, w, cx| s.save(w, cx));
        vcx.run_until_parked();
        assert!(
            daemon.calls::<methods::HermesMcpSetApiKey>().is_empty(),
            "the key went to the connection in use now"
        );
    }

    /// Values typed into a catalog server's sheet opened for one
    /// connection are never sent once another is in use.
    #[gpui_kit::test]
    fn catalog_values_go_only_to_the_connection_they_were_typed_for(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        let (daemon, stores, vcx) = bench(cx);
        use_connection(&stores, vcx, "a");
        let entry: HermesMcpCatalogEntryDto = serde_json::from_value(json!({
            "name": "seed-catalogue",
            "credentials": [{"name": "SEED_TOKEN", "required": true}],
        }))
        .unwrap();
        let s = stores.clone();
        vcx.update(|window, cx| open_catalog(&s, entry, window, cx));
        vcx.run_until_parked();
        on_sheet::<CatalogSheet>(vcx, |s, w, cx| {
            s.fields[0].update(cx, |i, cx| i.set_value("demo-token", w, cx))
        });
        vcx.update(|_, cx| assert!(sheet::has_unsaved(cx), "Quit would drop the typed value"));
        use_connection(&stores, vcx, "b");
        on_sheet::<CatalogSheet>(vcx, |s, w, cx| s.add(w, cx));
        vcx.run_until_parked();
        assert!(
            daemon
                .calls::<methods::HermesMcpAddFromCatalog>()
                .is_empty(),
            "the values went to the connection in use now"
        );
    }

    /// Quit while a catalog server's Add is out queues nothing: a beep, no
    /// question (the bench would answer it No) and no quit; the sheet
    /// stays until the Add lands.
    #[gpui_kit::test]
    fn quit_during_a_catalog_add_beeps_and_stays(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        use_connection(&stores, vcx, "a");
        let entry: HermesMcpCatalogEntryDto = serde_json::from_value(json!({
            "name": "seed-catalogue",
            "credentials": [{"name": "SEED_TOKEN", "required": true}],
        }))
        .unwrap();
        let s = stores.clone();
        vcx.update(|window, cx| open_catalog(&s, entry, window, cx));
        vcx.run_until_parked();
        on_sheet::<CatalogSheet>(vcx, |s, w, cx| {
            s.fields[0].update(cx, |i, cx| i.set_value("demo-token", w, cx))
        });
        let held = daemon.hold::<methods::HermesMcpAddFromCatalog>();
        on_sheet::<CatalogSheet>(vcx, |s, w, cx| s.add(w, cx));
        vcx.run_until_parked();
        let quits = Rc::new(std::cell::Cell::new(0));
        let q = quits.clone();
        vcx.update(|_, cx| sheet::quit_with(cx, Rc::new(move |_| q.set(q.get() + 1))));
        vcx.run_until_parked();
        assert_eq!(
            vcx.update(|_, cx| cx.global::<crate::shell::sheet::Beeps>().0),
            1,
            "Quit during the Add did not beep"
        );
        assert_eq!(quits.get(), 0);
        assert!(
            vcx.update(|_, cx| sheet::current::<CatalogSheet>(cx))
                .is_some()
        );
        drop(held);
        vcx.run_until_parked();
    }

    /// Remove… confirmed after another connection came into use removes
    /// nothing: a server of the same name there is not the one asked about.
    #[gpui_kit::test]
    fn a_removal_confirmed_after_a_switch_sends_nothing(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        use_connection(&stores, vcx, "a");
        let s = stores.clone();
        vcx.update(|window, cx| {
            crate::views::settings::hermes::choose(&s, "mcp", "remove:seed-catalogue", window, cx);
            // Another window puts B in use while the question is up.
            s.hermes_admin
                .update(cx, |a, cx| a.adopt_connections(list("b"), cx));
        });
        vcx.run_until_parked();
        assert!(
            daemon.calls::<methods::HermesMcpRemove>().is_empty(),
            "the removal went to the connection in use now"
        );
    }

    /// The key goes with the daemon's name for the connection the sheet
    /// opened under, so the daemon refuses it once another is in use.
    #[gpui_kit::test]
    fn a_key_names_the_connection_it_was_typed_for(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::HermesMcpSetApiKey>(
            serde_json::from_value(json!({"available": true})).unwrap(),
        );
        let mut named = list("a");
        named.connection = Some("0a1b2c3d:1".into());
        stores
            .hermes_admin
            .update(vcx, |a, cx| a.adopt_connections(named, cx));
        let s = stores.clone();
        vcx.update(|window, cx| open_key(&s, "seed-catalogue", window, cx));
        vcx.run_until_parked();
        on_sheet::<McpKeySheet>(vcx, |s, w, cx| {
            s.key
                .update(cx, |i, cx| i.set_value("sk-test-not-a-real-key", w, cx));
            s.save(w, cx);
        });
        vcx.run_until_parked();
        let calls = daemon.calls::<methods::HermesMcpSetApiKey>();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0]["connection"], json!("0a1b2c3d:1"));
    }

    /// An activation answered after a newer one is not taken, and leaves
    /// the page the user opened since alone.
    #[gpui_kit::test]
    fn a_dropped_activation_answer_leaves_the_page_alone(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| crate::stores::hermes_admin::follow_pages(&stores, cx));
        use_connection(&stores, vcx, "a");
        let n = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let count = n.clone();
        daemon.on::<methods::HermesConnectionsActivate>(move |_| {
            let first = count.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0;
            Ok(serde_json::to_value(list(if first { "b" } else { "a" })).unwrap())
        });
        let older = daemon.hold_one::<methods::HermesConnectionsActivate>(0);
        vcx.update(|_, cx| {
            crate::stores::hermes_admin::activate(&stores, "b", cx);
            crate::stores::hermes_admin::activate(&stores, "a", cx);
        });
        vcx.run_until_parked();
        stores.navigation.update(vcx, |n, cx| {
            n.open_item(
                crate::stores::navigation::AreaItem::HermesSession("sess-1".into()),
                cx,
            )
        });
        drop(older);
        vcx.run_until_parked();
        stores.navigation.read_with(vcx, |n, _| {
            assert_eq!(
                n.selection(),
                &crate::stores::navigation::Selection::Area(
                    crate::stores::navigation::AreaItem::HermesSession("sess-1".into())
                ),
                "a dropped answer closed the session opened since"
            );
        });
        stores.hermes_admin.read_with(vcx, |a, _| {
            assert_eq!(
                a.connections.as_ref().and_then(|l| l.active_id.as_deref()),
                Some("a")
            );
        });
    }

    fn on_hermes_page(stores: &Stores, vcx: &mut VisualTestContext) {
        stores.navigation.update(vcx, |n, cx| {
            n.open_item(
                crate::stores::navigation::AreaItem::HermesSession("sess-1".into()),
                cx,
            )
        });
    }

    fn left_hermes_page(stores: &Stores, vcx: &mut VisualTestContext) -> bool {
        stores.navigation.read_with(vcx, |n, _| {
            matches!(
                n.selection(),
                crate::stores::navigation::Selection::New { .. }
            )
        })
    }

    fn open_session(stores: &Stores, vcx: &mut VisualTestContext, id: &str) {
        stores.navigation.update(vcx, |n, cx| {
            n.open_item(
                crate::stores::navigation::AreaItem::HermesSession(id.into()),
                cx,
            )
        });
        vcx.run_until_parked();
    }

    fn shows_session(stores: &Stores, vcx: &mut VisualTestContext, id: &str) -> bool {
        stores.navigation.read_with(vcx, |n, _| {
            *n.selection()
                == crate::stores::navigation::Selection::Area(
                    crate::stores::navigation::AreaItem::HermesSession(id.into()),
                )
        })
    }

    /// Ordering 1: the refresh hermes.changed asked for lands first, the
    /// user opens one of B's chats, then the activation's own answer comes:
    /// B's chat stays (only a page of another connection than the one in
    /// use is closed).
    #[gpui_kit::test]
    fn a_late_activation_answer_leaves_the_new_connections_chat(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| crate::stores::hermes_admin::follow_pages(&stores, cx));
        use_connection(&stores, vcx, "a");
        open_session(&stores, vcx, "sess-a");
        daemon.returns::<methods::HermesConnectionsActivate>(list("b"));
        daemon.returns::<methods::HermesConnectionsList>(list("b"));
        let held = daemon.hold::<methods::HermesConnectionsActivate>();
        vcx.update(|_, cx| crate::stores::hermes_admin::activate(&stores, "b", cx));
        stores
            .hermes_admin
            .update(vcx, |a, cx| a.refresh_connections(cx));
        vcx.run_until_parked();
        open_session(&stores, vcx, "sess-b");
        drop(held);
        vcx.run_until_parked();
        assert!(shows_session(&stores, vcx, "sess-b"), "B's chat was closed");
    }

    /// Ordering 2: the activation's answer lands first and closes A's chat;
    /// the user opens one of B's; the same clean-up running again (Use This
    /// Connection asked again) leaves it.
    #[gpui_kit::test]
    fn the_switch_clean_up_runs_again_without_closing_bs_chat(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| crate::stores::hermes_admin::follow_pages(&stores, cx));
        use_connection(&stores, vcx, "a");
        open_session(&stores, vcx, "sess-a");
        daemon.returns::<methods::HermesConnectionsActivate>(list("b"));
        vcx.update(|_, cx| crate::stores::hermes_admin::activate(&stores, "b", cx));
        vcx.run_until_parked();
        assert!(left_hermes_page(&stores, vcx), "A's chat stayed open");
        open_session(&stores, vcx, "sess-b");
        vcx.update(|_, cx| crate::stores::hermes_admin::activate(&stores, "b", cx));
        vcx.run_until_parked();
        assert!(shows_session(&stores, vcx, "sess-b"), "B's chat was closed");
    }

    /// Another window puts B in use: this window's list follows (its
    /// hermes.changed refresh), and A's chat closes here too.
    #[gpui_kit::test]
    fn a_switch_made_in_another_window_closes_the_old_chat(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| crate::stores::hermes_admin::follow_pages(&stores, cx));
        use_connection(&stores, vcx, "a");
        open_session(&stores, vcx, "sess-a");
        daemon.returns::<methods::HermesConnectionsList>(list("b"));
        stores
            .hermes_admin
            .update(vcx, |a, cx| a.refresh_connections(cx));
        vcx.run_until_parked();
        assert!(
            left_hermes_page(&stores, vcx),
            "A's chat stayed open with B in use"
        );
    }

    /// A Hermes chat shown before this window read the connections (a
    /// launch, a reconnect) is the one the first list names: it stays.
    #[gpui_kit::test]
    fn a_chat_shown_before_the_list_is_read_stays(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| crate::stores::hermes_admin::follow_pages(&stores, cx));
        open_session(&stores, vcx, "sess-a");
        use_connection(&stores, vcx, "a");
        assert!(shows_session(&stores, vcx, "sess-a"), "the chat was closed");
    }

    /// A saved connection edited to another gateway (the daemon names it
    /// anew under the same saved id) is another connection: the old
    /// gateway's chat closes on the switch's clean-up.
    #[gpui_kit::test]
    fn a_chat_of_the_gateway_a_connection_was_edited_away_from_closes(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| crate::stores::hermes_admin::follow_pages(&stores, cx));
        let named = |key: &str| {
            let mut l = list("a");
            l.connection = Some(key.to_string());
            l
        };
        stores
            .hermes_admin
            .update(vcx, |a, cx| a.adopt_connections(named("0a1b2c3d:1"), cx));
        vcx.run_until_parked();
        open_session(&stores, vcx, "sess-old-gateway");
        daemon.returns::<methods::HermesConnectionsActivate>(named("0a1b2c3d:2"));
        vcx.update(|_, cx| crate::stores::hermes_admin::activate(&stores, "a", cx));
        vcx.run_until_parked();
        assert!(
            left_hermes_page(&stores, vcx),
            "the old gateway's chat stayed open under the new one"
        );
    }

    /// The clean-up reads whose page is shown, and which connection is in
    /// use, when it runs, not when its action was sent: a switch to C whose
    /// answer comes after a newer list that still has B in use leaves B's
    /// chat.
    #[gpui_kit::test]
    fn the_clean_up_reads_the_connection_in_use_when_it_runs(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| crate::stores::hermes_admin::follow_pages(&stores, cx));
        use_connection(&stores, vcx, "b");
        open_session(&stores, vcx, "sess-b");
        daemon.returns::<methods::HermesConnectionsActivate>(list("c"));
        let held = daemon.hold::<methods::HermesConnectionsActivate>();
        vcx.update(|_, cx| crate::stores::hermes_admin::activate(&stores, "c", cx));
        vcx.run_until_parked();
        // A newer list, read after, still has B in use: the switch to C's
        // answer is dropped, and its clean-up finds B's chat B's.
        daemon.returns::<methods::HermesConnectionsList>(list("b"));
        stores
            .hermes_admin
            .update(vcx, |a, cx| a.refresh_connections(cx));
        vcx.run_until_parked();
        drop(held);
        vcx.run_until_parked();
        assert!(shows_session(&stores, vcx, "sess-b"), "B's chat was closed");
    }

    /// Ordering 3: Hermes turned off while A's chat is open, and on again
    /// with B (another window) before the off answer comes: A's chat goes,
    /// as a page of a connection not in use; one of B's opened then stays
    /// through another such answer.
    #[gpui_kit::test]
    fn turning_hermes_off_closes_only_the_last_connections_page(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| crate::stores::hermes_admin::follow_pages(&stores, cx));
        use_connection(&stores, vcx, "a");
        open_session(&stores, vcx, "sess-a");
        let mut off = list("a");
        off.enabled = false;
        daemon.returns::<methods::HermesConnectionsSetEnabled>(off);
        let held = daemon.hold::<methods::HermesConnectionsSetEnabled>();
        vcx.update(|_, cx| crate::stores::hermes_admin::set_enabled(&stores, false, cx));
        vcx.run_until_parked();
        stores
            .hermes_admin
            .update(vcx, |a, cx| a.adopt_connections(list("b"), cx));
        drop(held);
        vcx.run_until_parked();
        assert!(
            left_hermes_page(&stores, vcx),
            "A's chat stayed open under B"
        );
        open_session(&stores, vcx, "sess-b");
        let held = daemon.hold::<methods::HermesConnectionsSetEnabled>();
        vcx.update(|_, cx| crate::stores::hermes_admin::set_enabled(&stores, false, cx));
        vcx.run_until_parked();
        stores
            .hermes_admin
            .update(vcx, |a, cx| a.adopt_connections(list("b"), cx));
        drop(held);
        vcx.run_until_parked();
        assert!(shows_session(&stores, vcx, "sess-b"), "B's chat was closed");
    }

    /// Use This Connection closes the last connection's Hermes chat when it
    /// succeeded, even when the refresh its hermes.changed asked for lands
    /// first and its own list is not the one taken.
    #[gpui_kit::test]
    fn a_switch_closes_the_old_chat_when_its_refresh_lands_first(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| crate::stores::hermes_admin::follow_pages(&stores, cx));
        use_connection(&stores, vcx, "a");
        on_hermes_page(&stores, vcx);
        daemon.returns::<methods::HermesConnectionsActivate>(list("b"));
        daemon.returns::<methods::HermesConnectionsList>(list("b"));
        let held = daemon.hold::<methods::HermesConnectionsActivate>();
        vcx.update(|_, cx| crate::stores::hermes_admin::activate(&stores, "b", cx));
        // The daemon's hermes.changed: the window reads the list again.
        stores
            .hermes_admin
            .update(vcx, |a, cx| a.refresh_connections(cx));
        vcx.run_until_parked();
        drop(held);
        vcx.run_until_parked();
        assert!(
            left_hermes_page(&stores, vcx),
            "the last connection's chat stayed open"
        );
    }

    /// The same when the action's own list lands first.
    #[gpui_kit::test]
    fn a_switch_closes_the_old_chat_when_its_own_list_lands_first(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| crate::stores::hermes_admin::follow_pages(&stores, cx));
        use_connection(&stores, vcx, "a");
        on_hermes_page(&stores, vcx);
        daemon.returns::<methods::HermesConnectionsActivate>(list("b"));
        daemon.returns::<methods::HermesConnectionsList>(list("b"));
        let held = daemon.hold::<methods::HermesConnectionsList>();
        vcx.update(|_, cx| crate::stores::hermes_admin::activate(&stores, "b", cx));
        stores
            .hermes_admin
            .update(vcx, |a, cx| a.refresh_connections(cx));
        vcx.run_until_parked();
        drop(held);
        vcx.run_until_parked();
        assert!(
            left_hermes_page(&stores, vcx),
            "the last connection's chat stayed open"
        );
    }

    /// Turning Hermes off leaves its section, whichever list lands first.
    #[gpui_kit::test]
    fn turning_hermes_off_leaves_its_page_when_the_refresh_lands_first(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| crate::stores::hermes_admin::follow_pages(&stores, cx));
        use_connection(&stores, vcx, "a");
        on_hermes_page(&stores, vcx);
        let mut off = list("a");
        off.enabled = false;
        daemon.returns::<methods::HermesConnectionsSetEnabled>(off.clone());
        daemon.returns::<methods::HermesConnectionsList>(off);
        let held = daemon.hold::<methods::HermesConnectionsSetEnabled>();
        vcx.update(|_, cx| crate::stores::hermes_admin::set_enabled(&stores, false, cx));
        stores
            .hermes_admin
            .update(vcx, |a, cx| a.refresh_connections(cx));
        vcx.run_until_parked();
        drop(held);
        vcx.run_until_parked();
        assert!(
            left_hermes_page(&stores, vcx),
            "Hermes's page stayed open with Hermes off"
        );
    }

    #[gpui_kit::test]
    fn turning_hermes_off_leaves_its_page_when_its_own_list_lands_first(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| crate::stores::hermes_admin::follow_pages(&stores, cx));
        use_connection(&stores, vcx, "a");
        on_hermes_page(&stores, vcx);
        let mut off = list("a");
        off.enabled = false;
        daemon.returns::<methods::HermesConnectionsSetEnabled>(off.clone());
        daemon.returns::<methods::HermesConnectionsList>(off);
        let held = daemon.hold::<methods::HermesConnectionsList>();
        vcx.update(|_, cx| crate::stores::hermes_admin::set_enabled(&stores, false, cx));
        stores
            .hermes_admin
            .update(vcx, |a, cx| a.refresh_connections(cx));
        vcx.run_until_parked();
        drop(held);
        vcx.run_until_parked();
        assert!(
            left_hermes_page(&stores, vcx),
            "Hermes's page stayed open with Hermes off"
        );
    }

    /// A key sheet that opened before this window knew the connection in
    /// use sends nothing: a key that names no connection could reach
    /// whichever gateway is in use when it arrives.
    #[gpui_kit::test]
    fn a_key_sheet_that_knows_no_connection_sends_nothing(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::HermesMcpSetApiKey>(
            serde_json::from_value(json!({"available": true})).unwrap(),
        );
        let s = stores.clone();
        vcx.update(|window, cx| open_key(&s, "seed-catalogue", window, cx));
        vcx.run_until_parked();
        on_sheet::<McpKeySheet>(vcx, |s, w, cx| {
            s.key
                .update(cx, |i, cx| i.set_value("sk-test-not-a-real-key", w, cx));
            s.save(w, cx);
        });
        vcx.run_until_parked();
        assert!(
            daemon.calls::<methods::HermesMcpSetApiKey>().is_empty(),
            "a key naming no connection was sent"
        );
    }

    /// Add MCP Server opened for one connection adds nothing to another.
    #[gpui_kit::test]
    fn a_server_is_added_only_to_the_connection_it_was_typed_for(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        let (daemon, stores, vcx) = bench(cx);
        use_connection(&stores, vcx, "a");
        let s = stores.clone();
        vcx.update(|window, cx| open_add(&s, window, cx));
        vcx.run_until_parked();
        on_sheet::<AddMcpSheet>(vcx, |s, w, cx| {
            s.name
                .update(cx, |i, cx| i.set_value("seed-catalogue", w, cx));
            s.url
                .update(cx, |i, cx| i.set_value("http://127.0.0.1:20403/mcp", w, cx));
        });
        vcx.update(|_, cx| assert!(sheet::has_unsaved(cx), "Quit would drop the typed server"));
        use_connection(&stores, vcx, "b");
        on_sheet::<AddMcpSheet>(vcx, |s, w, cx| s.add(w, cx));
        vcx.run_until_parked();
        assert!(
            daemon.calls::<methods::HermesMcpAdd>().is_empty(),
            "the server was added to the connection in use now"
        );
    }
}
