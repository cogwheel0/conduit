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

/// The composer's Terminal section for `chat` (None: a new chat): each
/// terminal's id, name, whether chats use it, and whether it is one of the
/// user's devices. One that needs a saved chat waits until the chat is
/// saved, as mobile's section does.
pub fn offered(
    servers: &[TerminalServerDto],
    selected: Option<&str>,
    chat: Option<&str>,
) -> Vec<(String, String, bool, bool)> {
    let saved = chat.is_some_and(is_saved_chat);
    servers
        .iter()
        // The selected one stays, so a chat that can't use it can still
        // clear it.
        .filter(|t| saved || !t.requires_saved_chat || selected == Some(t.id.as_str()))
        .map(|t| {
            let name = if t.name.trim().is_empty() {
                t.id.clone()
            } else {
                t.name.clone()
            };
            (
                t.id.clone(),
                name,
                selected == Some(t.id.as_str()),
                t.device,
            )
        })
        .collect()
}

/// Whether `chat` is one the server holds, by core's
/// `isSavedTerminalChatScopeId`, which conduitd's `terminal.select` applies:
/// a temporary chat keeps a local id and the server has no chat for it.
fn is_saved_chat(chat: &str) -> bool {
    let id = chat.trim();
    !id.is_empty()
        && id != "sidebar-terminal"
        && !["local:", "temporary:", "channel:"]
            .iter()
            .any(|prefix| id.starts_with(prefix))
}

/// Selects `server` for chats (None: no terminal) from `chat` (None: no
/// chat, or a new one), as the composer's Terminal section toggles it.
/// Answers the servers as they now stand.
pub fn select_server(
    rpc: &Rpc,
    server: Option<String>,
    chat: Option<String>,
    cx: &mut App,
) -> Task<Option<TerminalServers>> {
    let call = rpc.call::<methods::TerminalSelect>(&TerminalSelect {
        server_id: server,
        scope_id: chat.unwrap_or_default(),
    });
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

/// The composer's Terminal section in `chat` (None: a new chat): `id`
/// becomes the terminal chats use, or (it was already) none, as mobile's
/// toggle does.
pub fn toggle_terminal(id: String, chat: Option<String>, cx: &mut App) {
    let Some(stores) = cx.try_global::<crate::AppState>().map(|s| s.stores.clone()) else {
        return;
    };
    let selected = stores.areas.read(cx).terminal_selected.clone();
    let next = (selected.as_deref() != Some(id.as_str())).then_some(id);
    let rpc = stores.connection.read(cx).rpc();
    let asked = select_server(&rpc, next, chat, cx);
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

#[cfg(test)]
mod tests {
    use gpui_kit::TestAppContext;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    fn terminal(id: &str, name: &str, requires_saved_chat: bool) -> TerminalServerDto {
        TerminalServerDto {
            id: id.into(),
            name: name.into(),
            kind: "system".into(),
            requires_saved_chat,
            device: false,
        }
    }

    /// A terminal that needs a saved chat (Open WebUI 0.13.4's chat-scoped
    /// template) is offered to a saved chat, and selected from it.
    #[gpui_kit::test]
    fn a_saved_chat_is_offered_its_own_terminal_and_selects_it(cx: &mut TestAppContext) {
        let servers = [
            terminal("box", "", false),
            terminal("per-chat", "Chat bench", true),
        ];
        assert_eq!(
            offered(&servers, Some("box"), None),
            [("box".to_string(), "box".to_string(), true, false)],
            "a new chat was offered a terminal it cannot use"
        );
        // A temporary chat keeps a local id (restored by Go Back too), and
        // the server holds no chat for it.
        assert_eq!(
            offered(&servers, Some("box"), Some("local:tide-chart")),
            [("box".to_string(), "box".to_string(), true, false)],
            "a temporary chat was offered a terminal that needs a saved chat"
        );
        // Picked in a saved chat, it stays listed (and clearable) elsewhere.
        assert_eq!(
            offered(&servers, Some("per-chat"), None),
            [
                ("box".to_string(), "box".to_string(), false, false),
                (
                    "per-chat".to_string(),
                    "Chat bench".to_string(),
                    true,
                    false
                ),
            ],
            "a new chat hid the terminal it has selected, so it could not be cleared"
        );
        assert_eq!(
            offered(&servers, Some("box"), Some("chat-lighthouse")),
            [
                ("box".to_string(), "box".to_string(), true, false),
                (
                    "per-chat".to_string(),
                    "Chat bench".to_string(),
                    false,
                    false
                ),
            ]
        );

        let daemon = FakeDaemon::new();
        daemon.returns::<methods::TerminalSelect>(TerminalServers::default());
        let rpc = daemon.rpc();
        let asked = cx.update(|cx| {
            select_server(
                &rpc,
                Some("per-chat".into()),
                Some("chat-lighthouse".into()),
                cx,
            )
        });
        assert!(cx.foreground_executor().block_test(asked).is_some());
        assert_eq!(
            daemon.calls::<methods::TerminalSelect>(),
            [serde_json::json!({"serverId": "per-chat", "scopeId": "chat-lighthouse"})],
            "the daemon was not told which chat the terminal is for"
        );
    }
}
