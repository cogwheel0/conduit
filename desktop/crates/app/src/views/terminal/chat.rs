//! The terminal inside a chat, as mobile's chat page has it:
//!
//! * a model's terminal tool showing a file (`terminal.displayFile`, Open
//!   WebUI 0.13's `terminal:display_file`) opens it over the chat, read
//!   through the chat's own terminal session;
//! * the header's Computer button, offered when the Computer setting is on
//!   and the chat's terminal has a Desktop or a Browser (`computer.status`);
//! * the composer's Terminal section: which server the chat's tool uses.

use std::collections::HashMap;

use conduit_protocol::{
    ComputerScope, ComputerStatus, TerminalAttach, TerminalDisplayFile, TerminalScope,
    TerminalSelect, TerminalServerDto, TerminalServers, methods,
};
use gpui_kit::{AnyWindowHandle, App, Global, Task};

use crate::stores::Stores;
use crate::stores::rpc::Rpc;

/// Handles attached for showing files, by chat and server: a chat's file
/// requests reuse its session.
#[derive(Default)]
struct ShowHandles(HashMap<(String, String), String>);

impl Global for ShowHandles {}

/// The server a chat's terminal tool uses: the selected one if the chat
/// may use it, else none.
pub fn chat_server(servers: &TerminalServers) -> Option<&TerminalServerDto> {
    let selected = servers.selected_id.as_deref()?;
    servers.servers.iter().find(|s| s.id == selected)
}

/// Opens `request`'s file over the chat in `window`.
pub fn display_file(
    stores: Stores,
    window: AnyWindowHandle,
    request: TerminalDisplayFile,
    cx: &mut App,
) {
    let rpc = stores.connection.read(cx).rpc();
    cx.spawn(async move |cx| {
        let chat = request.chat_id.clone();
        let servers = match rpc
            .call::<methods::TerminalServers>(&TerminalScope {
                scope_id: chat.clone(),
            })
            .await
        {
            Ok(servers) => servers,
            Err(e) => {
                log::warn!("terminal.servers for a shown file: {e}");
                return;
            }
        };
        let Some(server) = chat_server(&servers).map(|s| s.id.clone()) else {
            log::info!("a shown file, but the chat has no terminal selected");
            return;
        };
        let key = (chat.clone(), server.clone());
        let cached = cx.update(|cx| cx.default_global::<ShowHandles>().0.get(&key).cloned());
        let handle = match cached {
            Some(handle) => handle,
            None => match attach(&rpc, &server, &chat).await {
                Some(handle) => {
                    cx.update(|cx| {
                        cx.default_global::<ShowHandles>()
                            .0
                            .insert(key.clone(), handle.clone())
                    });
                    handle
                }
                None => return,
            },
        };
        let path = request.path.clone();
        let page = request.page;
        let _ = window.update(cx, |_, window, cx| {
            super::viewer::show(stores, handle, path, page, window, cx);
        });
    })
    .detach();
}

async fn attach(rpc: &Rpc, server: &str, chat: &str) -> Option<String> {
    match rpc
        .call::<methods::TerminalAttach>(&TerminalAttach {
            server_id: server.to_string(),
            scope_id: chat.to_string(),
        })
        .await
    {
        Ok(attached) => Some(attached.handle),
        Err(e) => {
            log::warn!("terminal.attach for a shown file: {e}");
            None
        }
    }
}

/// Forgets every handle kept for showing files (a new daemon session).
pub fn forget_handles(cx: &mut App) {
    cx.default_global::<ShowHandles>().0.clear();
}

/// What the header offers for a chat.
#[derive(Clone, Debug, PartialEq)]
pub struct ComputerOffer {
    pub chat_id: String,
    pub status: ComputerStatus,
}

impl ComputerOffer {
    /// The header shows Computer.
    pub fn available(&self) -> bool {
        self.status.enabled && (self.status.desktop || self.status.browser)
    }
}

/// Asks whether `chat_id`'s header offers Computer.
pub fn computer_status(rpc: &Rpc, chat_id: String, cx: &mut App) -> Task<Option<ComputerOffer>> {
    let call = rpc.call::<methods::ComputerStatus>(&ComputerScope {
        chat_id: chat_id.clone(),
    });
    cx.background_executor().spawn(async move {
        match call.await {
            Ok(status) => Some(ComputerOffer { chat_id, status }),
            Err(e) => {
                log::warn!("computer.status: {e}");
                None
            }
        }
    })
}

/// Selects `server` for chats (None: no terminal), as the composer's
/// Terminal section toggles it. Answers the servers as they now stand.
pub fn select_server(
    rpc: &Rpc,
    server: Option<String>,
    cx: &mut App,
) -> Task<Option<TerminalServers>> {
    let call = rpc.call::<methods::TerminalSelect>(&TerminalSelect { server_id: server });
    cx.background_executor().spawn(async move {
        match call.await {
            Ok(servers) => Some(servers),
            Err(e) => {
                log::warn!("terminal.select: {e}");
                None
            }
        }
    })
}

/// The composer's Terminal section: `id` becomes the terminal chats use,
/// or (it was already) none, as mobile's toggle does.
pub fn toggle_terminal(id: String, cx: &mut App) {
    let Some(stores) = cx.try_global::<crate::AppState>().map(|s| s.stores.clone()) else {
        return;
    };
    let selected = stores.areas.read(cx).terminal_selected.clone();
    let next = (selected.as_deref() != Some(id.as_str())).then_some(id);
    let rpc = stores.connection.read(cx).rpc();
    let asked = select_server(&rpc, next, cx);
    cx.spawn(async move |cx| {
        if let Some(servers) = asked.await {
            cx.update(|cx| {
                stores
                    .areas
                    .update(cx, |a, cx| a.set_terminals(servers, cx))
            });
        }
    })
    .detach();
}
