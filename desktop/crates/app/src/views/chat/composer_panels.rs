//! Panels that open over the composer from its + menu, as the phone's
//! sheets do: the server's files (Server Files…, the shared picker in
//! [`crate::views::server_files`]), a web page or YouTube
//! video to read (Web Page…), and a Direct MCP server's prompts and
//! resources (MCP Content…). Each is a card above the field, Esc closes it,
//! and its rows are keyboard-driven.

use std::rc::Rc;

use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{ConduitTheme, with_alpha};
use conduit_components::views::kit::{Button, overlay_shadow};
use conduit_protocol::{
    McpContent, McpContentPreview, McpGetPrompt, McpReadResource, McpRef, McpServerSummary,
    NoParams, methods,
};
use gpui_kit::Focusable as _;
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Context, ElementId, Entity, FontWeight, Role, SharedString, Subscription,
    Window, div, px,
};

use super::composer::{ChatComposer, Panel};
use crate::l10n::ActiveL10n as _;
use crate::stores::rpc::Rpc;

/// Whether `url` is a YouTube video: its transcript is what the server reads,
/// and what an empty answer means is said that way. The daemon decides (the
/// core's `isYoutubeUrl`); this only picks the wording.
pub fn is_youtube(url: &str) -> bool {
    [
        "https://www.youtube.com",
        "https://youtu.be",
        "https://youtube.com",
        "https://m.youtube.com",
    ]
    .iter()
    .any(|p| url.starts_with(p))
}

/// A new panel's id ([`Panel::id`]).
fn next_panel_id() -> u64 {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
}

// ── Server Files ───────────────────────────────────────────────────────────

/// Server Files…: the shared picker (`crate::views::server_files`), drawn
/// in a card with Cancel, and the composer's ear on what it picks.
pub(crate) struct ServerFilesPanel {
    pub picker: Entity<crate::views::server_files::ServerFilesPicker>,
    _subscription: Subscription,
}

impl ServerFilesPanel {
    pub fn new(
        picker: Entity<crate::views::server_files::ServerFilesPicker>,
        subscription: Subscription,
    ) -> Self {
        Self {
            picker,
            _subscription: subscription,
        }
    }
}

// ── Web Page ───────────────────────────────────────────────────────────────

pub struct WebPagePanel {
    pub id: u64,
    pub url: Entity<InputState>,
    pub busy: bool,
    pub error: Option<String>,
    _subscription: Subscription,
}

impl WebPagePanel {
    pub fn new(window: &mut Window, cx: &mut Context<ChatComposer>) -> Self {
        let url = cx.new(|cx| InputState::new(window, cx).placeholder("https://"));
        url.update(cx, |s, cx| s.focus(window, cx));
        // Enter is the panel's key (`panel_key`), ahead of the field's.
        let subscription = cx.subscribe(&url, |this, _, e: &InputEvent, cx| {
            if matches!(e, InputEvent::Change)
                && let Some(Panel::WebPage(p)) = &mut this.panel
            {
                p.error = None;
                cx.notify();
            }
        });
        Self {
            id: next_panel_id(),
            url,
            busy: false,
            error: None,
            _subscription: subscription,
        }
    }
}

// ── MCP Content ────────────────────────────────────────────────────────────

/// One prompt or resource the MCP panel lists.
#[derive(Clone)]
pub enum McpItem {
    Prompt {
        name: String,
        title: String,
        detail: String,
    },
    Resource {
        uri: String,
        title: String,
        detail: String,
    },
}

pub struct McpPanel {
    pub id: u64,
    rpc: Rpc,
    /// Bumped per server chosen and item read: only the latest read's
    /// answer is shown.
    reads: u64,
    pub search: Entity<InputState>,
    /// The enabled servers, once listed.
    servers: Option<Vec<McpServerSummary>>,
    pub server: Option<McpServerSummary>,
    content: Option<McpContent>,
    pub highlighted: usize,
    pub loading: bool,
    pub error: Option<String>,
    /// The text to insert, and its preview, once an item is read.
    pub preview: Option<(String, McpContentPreview)>,
    _subscription: Subscription,
}

impl McpPanel {
    pub fn new(rpc: Rpc, window: &mut Window, cx: &mut Context<ChatComposer>) -> Self {
        let placeholder = cx.l10n().direct_mcp_content_search();
        let search = cx.new(|cx| InputState::new(window, cx).placeholder(placeholder));
        search.update(cx, |s, cx| s.focus(window, cx));
        let subscription = cx.subscribe(&search, |this, _, e: &InputEvent, cx| {
            if matches!(e, InputEvent::Change)
                && let Some(Panel::Mcp(p)) = &mut this.panel
            {
                p.highlighted = 0;
                cx.notify();
            }
        });
        let id = next_panel_id();
        let list = rpc.call::<methods::McpList>(&NoParams);
        cx.spawn(async move |this, cx| {
            let result = list.await;
            let _ = this.update(cx, |this, cx| {
                let Some(Panel::Mcp(p)) = &mut this.panel else {
                    return;
                };
                if p.id != id {
                    return;
                }
                match result {
                    Ok(list) => {
                        let servers: Vec<_> =
                            list.servers.into_iter().filter(|s| s.enabled).collect();
                        let first = servers.first().cloned();
                        p.servers = Some(servers);
                        match first {
                            Some(first) => p.choose_server(first, cx),
                            // Nothing to list: the empty state, not loading.
                            None => p.loading = false,
                        }
                    }
                    Err(e) => {
                        log::warn!("mcp.list: {e}");
                        p.loading = false;
                        p.error = Some(cx.l10n().direct_mcp_content_load_failed());
                    }
                }
                cx.notify();
            });
        })
        .detach();
        Self {
            id,
            rpc,
            reads: 0,
            search,
            servers: None,
            server: None,
            content: None,
            highlighted: 0,
            loading: true,
            error: None,
            preview: None,
            _subscription: subscription,
        }
    }

    pub fn servers(&self) -> &[McpServerSummary] {
        self.servers.as_deref().unwrap_or_default()
    }

    /// `mcp.content` for `server`: its prompts and resources.
    pub fn choose_server(&mut self, server: McpServerSummary, cx: &mut Context<ChatComposer>) {
        self.content = None;
        self.preview = None;
        self.error = None;
        self.loading = true;
        self.highlighted = 0;
        // A read of the last server's item is not this one's.
        self.reads += 1;
        let call = self.rpc.call::<methods::McpContent>(&McpRef {
            id: server.id.clone(),
        });
        let id = server.id.clone();
        let panel = self.id;
        self.server = Some(server);
        cx.spawn(async move |this, cx| {
            let result = call.await;
            let _ = this.update(cx, |this, cx| {
                let Some(Panel::Mcp(p)) = &mut this.panel else {
                    return;
                };
                if p.id != panel || p.server.as_ref().map(|s| s.id.as_str()) != Some(id.as_str()) {
                    return;
                }
                p.loading = false;
                match result {
                    Ok(content) => p.content = Some(content),
                    Err(e) => {
                        log::warn!("mcp.content: {e}");
                        p.error = Some(cx.l10n().direct_mcp_content_load_failed());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// The server's prompts, then its resources, matching the search.
    pub fn items(&self, cx: &App) -> Vec<McpItem> {
        let Some(content) = &self.content else {
            return vec![];
        };
        let query = self.search.read(cx).value().trim().to_lowercase();
        let hit = |a: &str, b: &str| {
            query.is_empty()
                || a.to_lowercase().contains(&query)
                || b.to_lowercase().contains(&query)
        };
        let mut items = vec![];
        for p in &content.prompts {
            if hit(&p.display_name, &p.description) {
                items.push(McpItem::Prompt {
                    name: p.name.clone(),
                    title: p.display_name.clone(),
                    detail: p.description.clone(),
                });
            }
        }
        for r in &content.resources {
            if hit(&r.display_name, &r.uri) {
                items.push(McpItem::Resource {
                    uri: r.uri.clone(),
                    title: r.display_name.clone(),
                    detail: if r.description.is_empty() {
                        r.uri.clone()
                    } else {
                        r.description.clone()
                    },
                });
            }
        }
        items
    }

    /// Reads `item` for its preview and the text to insert, formatted as the
    /// core's `formatDirectMcp…Insertion` does (a heading, then each message
    /// under its role).
    pub fn read(&mut self, item: McpItem, cx: &mut Context<ChatComposer>) {
        let (Some(server), Some(content)) = (self.server.clone(), self.content.clone()) else {
            return;
        };
        let l10n = cx.l10n().clone();
        self.loading = true;
        self.error = None;
        self.preview = None;
        self.reads += 1;
        let (panel, round) = (self.id, self.reads);
        let (call, heading, is_prompt) = match &item {
            McpItem::Prompt { name, title, .. } => (
                futures::future::Either::Left(self.rpc.call::<methods::McpGetPrompt>(
                    &McpGetPrompt {
                        server_id: server.id.clone(),
                        name: name.clone(),
                        arguments: Default::default(),
                    },
                )),
                l10n.direct_mcp_content_prompt_heading(&content.server_name, title),
                true,
            ),
            McpItem::Resource { uri, .. } => (
                futures::future::Either::Right(self.rpc.call::<methods::McpReadResource>(
                    &McpReadResource {
                        server_id: server.id.clone(),
                        uri: uri.clone(),
                    },
                )),
                l10n.direct_mcp_content_resource_heading(&content.server_name, uri),
                false,
            ),
        };
        cx.spawn(async move |this, cx| {
            let result = call.await;
            let _ = this.update(cx, |this, cx| {
                let Some(Panel::Mcp(p)) = &mut this.panel else {
                    return;
                };
                // Another item or server chosen since, or another panel.
                if p.id != panel || p.reads != round {
                    return;
                }
                p.loading = false;
                match result {
                    Ok(preview) => {
                        let text = insertion_text(&heading, &preview, is_prompt, &l10n);
                        p.preview = Some((text, preview));
                    }
                    Err(e) => {
                        log::warn!("mcp read: {e}");
                        p.error = Some(match e.args.get("reason").map(String::as_str) {
                            Some("changed") => l10n.direct_mcp_content_changed(),
                            Some("unsupported") => l10n.direct_mcp_content_unsupported(),
                            Some("tooLarge") => l10n.direct_mcp_content_too_large(),
                            _ => l10n.direct_mcp_content_request_failed(),
                        });
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
}

/// The core's insertion: the heading, then a prompt's messages each under
/// its role (`User:` and so on), or a resource's text.
fn insertion_text(
    heading: &str,
    preview: &McpContentPreview,
    prompt: bool,
    l10n: &crate::l10n::L10n,
) -> String {
    let mut parts = vec![heading.to_string()];
    for message in &preview.messages {
        if prompt {
            let role = match message.role.as_str() {
                "system" => l10n.system(),
                "assistant" => l10n.direct_mcp_content_role_assistant(),
                _ => l10n.direct_mcp_content_role_user(),
            };
            parts.push(format!("{role}:\n{}", message.text));
        } else {
            parts.push(message.text.clone());
        }
    }
    parts.join("\n\n")
}

// ── Drawing ────────────────────────────────────────────────────────────────

/// The card every panel is drawn in, above the composer.
pub(crate) fn card(
    id: &'static str,
    title: String,
    t: &ConduitTheme,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    let r = t.roles;
    div()
        .id(id)
        .role(Role::Dialog)
        .aria_label(SharedString::from(title.clone()))
        .w_full()
        .p(px(12.))
        .flex()
        .flex_col()
        .gap(px(8.))
        .rounded(px(14.))
        .border_1()
        .border_color(r.border_strong)
        .bg(r.overlay)
        .shadow(overlay_shadow(t))
        .occlude()
        .child(
            div()
                .text_size(px(t.metrics.control + 1.))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(r.text)
                .child(SharedString::from(title)),
        )
}

pub(crate) fn search_field(
    input: &Entity<InputState>,
    label: String,
    t: &ConduitTheme,
) -> impl IntoElement {
    let r = t.roles;
    div()
        .h(px(t.metrics.control_height + 4.))
        .px(px(8.))
        .flex()
        .items_center()
        .gap(px(6.))
        .rounded(px(7.))
        .bg(with_alpha(r.text, if t.dark { 0.08 } else { 0.05 }))
        .child(icon(IconName::Search, 13., r.text_faint))
        .child(
            div().flex_1().child(
                Input::new(input)
                    .appearance(false)
                    .bordered(false)
                    .px_0()
                    .text_size(px(t.metrics.control))
                    .aria_label(SharedString::from(label)),
            ),
        )
}

/// A list row: icon, title and a quieter second line; `at` is whether it is
/// highlighted, its index and the list's length.
pub(crate) fn row(
    id: ElementId,
    ic: IconName,
    title: String,
    detail: String,
    at: (bool, usize, usize),
    t: &ConduitTheme,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    let (hot, index, total) = at;
    let r = t.roles;
    let m = t.metrics;
    div()
        .id(id)
        .role(Role::ListBoxOption)
        .aria_label(SharedString::from(title.clone()))
        .aria_selected(hot)
        .aria_position_in_set(index + 1)
        .aria_size_of_set(total)
        .min_h(px(m.row_height + 10.))
        .px(px(8.))
        .flex()
        .flex_none()
        .items_center()
        .gap(px(10.))
        .rounded(px(7.))
        .when(hot, |d| d.bg(r.overlay_hover))
        .hover(|s| s.bg(r.overlay_hover))
        .cursor_pointer()
        .child(icon(ic, 14., r.text_subtle))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .child(
                    div()
                        .truncate()
                        .text_size(px(m.control))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(r.text)
                        .child(SharedString::from(title)),
                )
                .when(!detail.is_empty(), |d| {
                    d.child(
                        div()
                            .truncate()
                            .text_size(px(m.caption))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(detail)),
                    )
                }),
        )
}

pub(crate) fn note(text: String, t: &ConduitTheme, danger: bool) -> AnyElement {
    // An error is said when it appears (the phone's panel error is a live
    // region); loading and empty notes are not, and have no region: one
    // drawn beside the error would share its id, and its quiet frame would
    // make the error new again on every redraw.
    div()
        .relative()
        .when(danger, |d| {
            d.child(conduit_components::announce::live_text(
                "note-live",
                Some(SharedString::from(text.clone())),
                conduit_components::announce::Priority::High,
            ))
        })
        .px(px(8.))
        .py(px(6.))
        .text_size(px(t.metrics.control))
        .text_color(if danger {
            t.roles.danger
        } else {
            t.roles.text_subtle
        })
        .child(SharedString::from(text))
        .into_any_element()
}

pub(crate) fn when_size(size: Option<i64>) -> String {
    match size {
        Some(b) if b >= 1024 * 1024 => format!("{:.1} MB", b as f64 / (1024. * 1024.)),
        Some(b) if b >= 1024 => format!("{} KB", b / 1024),
        Some(b) => format!("{b} B"),
        None => String::new(),
    }
}

impl ChatComposer {
    /// A key while a panel is open (↑ ↓ Enter Esc). True when it was used.
    pub(crate) fn panel_key(
        &mut self,
        key: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        // Only while the panel's own field has the keys.
        let field = match &self.panel {
            Some(Panel::ServerFiles(p)) => p.picker.read(cx).focus_handle(cx),
            Some(Panel::WebPage(p)) => p.url.read(cx).focus_handle(cx),
            Some(Panel::Mcp(p)) => p.search.read(cx).focus_handle(cx),
            None => return false,
        };
        if !field.is_focused(window) {
            return false;
        }
        let len = match &self.panel {
            Some(Panel::ServerFiles(p)) => p.picker.read(cx).files().len(),
            Some(Panel::Mcp(p)) if p.preview.is_none() => p.items(cx).len(),
            Some(_) => 0,
            None => return false,
        };
        match key {
            "escape" => {
                if let Some(Panel::Mcp(p)) = &mut self.panel
                    && p.preview.is_some()
                {
                    p.preview = None;
                    cx.notify();
                    return true;
                }
                self.close_panel(window, cx);
            }
            "up" | "down" => {
                let step = |h: usize| super::composer::menu_step(key, h, len);
                match &mut self.panel {
                    Some(Panel::ServerFiles(p)) => {
                        p.picker.update(cx, |p, cx| p.step(key, cx));
                    }
                    Some(Panel::Mcp(p)) => {
                        p.highlighted = step(p.highlighted);
                        let items = p.items(cx);
                        if let Some(item) = items.get(p.highlighted) {
                            let title = match item {
                                McpItem::Prompt { title, .. } | McpItem::Resource { title, .. } => {
                                    title.clone()
                                }
                            };
                            crate::views::a11y::announce_row(&title, p.highlighted, len, cx);
                        }
                    }
                    _ => return false,
                }
                cx.notify();
            }
            "enter" => match &mut self.panel {
                Some(Panel::ServerFiles(p)) => {
                    let p = p.picker.read(cx);
                    if let Some(file) = p.files().get(p.highlighted).cloned() {
                        self.attach_server_file(file, window, cx);
                    }
                }
                Some(Panel::Mcp(p)) => {
                    if let Some((text, _)) = p.preview.clone() {
                        self.insert_text(&text, window, cx);
                    } else if let Some(item) = p.items(cx).get(p.highlighted).cloned() {
                        p.read(item, cx);
                    }
                }
                Some(Panel::WebPage(_)) => self.fetch_web_page(window, cx),
                None => return false,
            },
            _ => return false,
        }
        true
    }

    pub(crate) fn panel_view(
        &self,
        t: &ConduitTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let weak = cx.entity().downgrade();
        let cancel = {
            let weak = weak.clone();
            Button::new("panel-cancel", l10n.cancel()).on_click(Rc::new(move |_, window, cx| {
                let _ = weak.update(cx, |c, cx| c.close_panel(window, cx));
            }))
        };
        let footer = |primary: Option<AnyElement>| {
            div()
                .flex()
                .justify_end()
                .gap(px(6.))
                .child(cancel)
                .children(primary)
        };
        let _ = window;
        Some(match self.panel.as_ref()? {
            Panel::ServerFiles(p) => card("server-files", l10n.composer_attach_server_files(), t)
                .child(p.picker.clone())
                .child(footer(None))
                .into_any_element(),
            Panel::WebPage(p) => {
                let attach = {
                    let weak = weak.clone();
                    Button::new("web-page-attach", l10n.attach())
                        .primary()
                        .disabled(p.busy)
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = weak.update(cx, |c, cx| c.fetch_web_page(window, cx));
                        }))
                        .into_any_element()
                };
                card("web-page", l10n.web_page(), t)
                    .child(
                        div()
                            .text_size(px(t.metrics.small))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(l10n.desktop_web_page_help())),
                    )
                    .child(
                        conduit_components::views::kit::field_frame(
                            p.url.read(cx).focus_handle(cx).is_focused(window),
                            t.metrics.control_height + 4.,
                            cx,
                        )
                        .child(
                            Input::new(&p.url)
                                .appearance(false)
                                .bordered(false)
                                .px_0()
                                .text_size(px(t.metrics.control))
                                .aria_label(SharedString::from(l10n.desktop_web_page_address())),
                        ),
                    )
                    .when_some(p.error.clone(), |d, e| d.child(note(e, t, true)))
                    .when(p.busy, |d| {
                        d.child(note(l10n.desktop_reading_page(), t, false))
                    })
                    .child(footer(Some(attach)))
                    .into_any_element()
            }
            Panel::Mcp(p) => {
                let servers = p.servers().to_vec();
                let picker: Option<AnyElement> = (servers.len() > 1).then(|| {
                    div()
                        .id("mcp-servers")
                        .role(Role::RadioGroup)
                        .aria_label(SharedString::from(l10n.direct_mcp_content_server()))
                        .flex()
                        .flex_wrap()
                        .gap(px(6.))
                        .children(servers.into_iter().map(|s| {
                            let on = p.server.as_ref().map(|c| c.id == s.id).unwrap_or(false);
                            div()
                                .id(ElementId::Name(format!("mcp-server-{}", s.id).into()))
                                .role(Role::RadioButton)
                                .aria_label(SharedString::from(s.name.clone()))
                                .aria_toggled(if on {
                                    gpui_kit::Toggled::True
                                } else {
                                    gpui_kit::Toggled::False
                                })
                                .h(px(26.))
                                .px(px(10.))
                                .flex()
                                .items_center()
                                .rounded_full()
                                .border_1()
                                .border_color(if on { r.border_strong } else { r.border })
                                .when(on, |d| d.bg(r.selected))
                                .cursor_pointer()
                                .text_size(px(t.metrics.small))
                                .text_color(if on { r.text } else { r.text_subtle })
                                .child(SharedString::from(s.name.clone()))
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    if let Some(Panel::Mcp(p)) = &mut this.panel {
                                        p.choose_server(s.clone(), cx);
                                    }
                                }))
                        }))
                        .into_any_element()
                });
                let body: AnyElement = if let Some((text, _)) = &p.preview {
                    div()
                        .id("mcp-preview")
                        .role(Role::Document)
                        .aria_label(SharedString::from(l10n.direct_mcp_content_preview_title()))
                        .max_h(px(260.))
                        .overflow_y_scroll()
                        .p(px(8.))
                        .rounded(px(8.))
                        .bg(with_alpha(r.text, if t.dark { 0.06 } else { 0.04 }))
                        .text_size(px(t.metrics.small))
                        .text_color(r.text)
                        .child(SharedString::from(text.clone()))
                        .into_any_element()
                } else {
                    let items = p.items(cx);
                    let total = items.len();
                    let empty = if p.loading {
                        Some(note(l10n.direct_mcp_content_loading(), t, false))
                    } else if p.servers.as_ref().is_some_and(Vec::is_empty)
                        || p.content
                            .as_ref()
                            .is_some_and(|c| c.prompts.is_empty() && c.resources.is_empty())
                    {
                        // No server to list, or one with nothing in it.
                        Some(note(l10n.direct_mcp_content_empty(), t, false))
                    } else if total == 0 && p.content.is_some() {
                        Some(note(l10n.direct_mcp_content_no_matches(), t, false))
                    } else {
                        None
                    };
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(8.))
                        .child(search_field(&p.search, l10n.direct_mcp_content_search(), t))
                        .child(
                            div()
                                .id("mcp-items")
                                .role(Role::ListBox)
                                .aria_label(SharedString::from(l10n.direct_mcp_content_title()))
                                .max_h(px(240.))
                                .overflow_y_scroll()
                                .flex()
                                .flex_col()
                                .children(empty)
                                .children(items.into_iter().enumerate().map(|(i, item)| {
                                    let (ic, title, detail) = match &item {
                                        McpItem::Prompt { title, detail, .. } => {
                                            (IconName::MessageSquare, title.clone(), detail.clone())
                                        }
                                        McpItem::Resource { title, detail, .. } => {
                                            (IconName::FileText, title.clone(), detail.clone())
                                        }
                                    };
                                    row(
                                        ElementId::NamedInteger("mcp-item".into(), i as u64),
                                        ic,
                                        title,
                                        detail,
                                        (i == p.highlighted, i, total),
                                        t,
                                    )
                                    .on_click(cx.listener(
                                        move |this, _, _, cx| {
                                            if let Some(Panel::Mcp(p)) = &mut this.panel {
                                                p.read(item.clone(), cx);
                                            }
                                        },
                                    ))
                                })),
                        )
                        .into_any_element()
                };
                let insert = p.preview.as_ref().map(|(text, _)| {
                    let weak = weak.clone();
                    let text = text.clone();
                    Button::new("mcp-insert", l10n.direct_mcp_content_insert())
                        .primary()
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = weak.update(cx, |c, cx| c.insert_text(&text, window, cx));
                        }))
                        .into_any_element()
                });
                card("mcp-content", l10n.direct_mcp_content_title(), t)
                    .children(picker)
                    .child(body)
                    .when_some(p.error.clone(), |d, e| d.child(note(e, t, true)))
                    .child(footer(insert))
                    .into_any_element()
            }
        })
    }
}
