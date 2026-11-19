//! Hermes sessions' commands, wherever they are asked: the sidebar's
//! Hermes rows (their context menu and "…"), the Chat menu and the
//! toolbar's More menu while a session is open, Hidden Chats, the
//! read-only notice and a reply's history actions.
//!
//! As the phone's session tile (`hermes_session_tile.dart`): Pin or Unpin
//! (not on an archived session), Archive or Unarchive, Hide (Unhide in
//! Hidden Chats), Fork, Rename and Delete. They stand in the app's one
//! chat-menu order ([`crate::menus::CHAT_COMMAND_ORDER`]): Pin, Rename…,
//! Fork, Archive, Hide, then Delete… on its own.
//!
//! The daemon does the work (`hermes.*`, over the core's own session list
//! controller); here a command is sent, the list it answers with is shown,
//! and a failure is said in the phone's words.

use conduit_protocol::{
    ChatRef, HermesBranch, HermesContinue, HermesRef, HermesRename, HermesSessionDto,
    HermesSessionUpdate, NoticeLevel, methods,
};
use gpui_kit::{Action, App, AsyncApp, Window};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::menus::ChatCommandSlot;
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::navigation::AreaItem;
use gpui_kit::component::native_menu::NativeMenu;

/// One command on a Hermes session.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HermesCommand {
    Pin,
    Unpin,
    Rename,
    Fork,
    Archive,
    Unarchive,
    Hide,
    Unhide,
    Delete,
}

impl HermesCommand {
    /// Its place in the chat menus' shared order.
    pub fn slot(self) -> ChatCommandSlot {
        match self {
            Self::Pin | Self::Unpin => ChatCommandSlot::Pin,
            Self::Rename => ChatCommandSlot::Rename,
            Self::Fork => ChatCommandSlot::Fork,
            Self::Archive | Self::Unarchive => ChatCommandSlot::Archive,
            Self::Hide | Self::Unhide => ChatCommandSlot::Hide,
            Self::Delete => ChatCommandSlot::Delete,
        }
    }

    /// Its menu item.
    pub fn label(self, l: &L10n) -> String {
        match self {
            Self::Pin => l.desktop_pin_chat(),
            Self::Unpin => l.desktop_unpin_chat(),
            Self::Rename => l.desktop_rename_ellipsis(),
            Self::Fork => l.hermes_session_fork(),
            Self::Archive => l.desktop_archive_chat(),
            Self::Unarchive => l.unarchive(),
            Self::Hide => l.hermes_session_hide(),
            Self::Unhide => l.hermes_session_unhide(),
            Self::Delete => l.desktop_delete_ellipsis(),
        }
    }
}

/// A Hermes session's menu command: `command` on session `session_id`.
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit_sidebar, no_json)]
pub struct HermesMenu {
    pub session_id: String,
    pub command: HermesCommand,
}

/// What `session` offers, in the shared order: a hidden one only comes
/// back (or goes); an archived one is not pinned.
pub fn commands(session: &HermesSessionDto) -> Vec<HermesCommand> {
    use HermesCommand as C;
    let mut out = if session.hidden {
        vec![C::Unhide, C::Delete]
    } else {
        let mut out = vec![];
        if !session.archived {
            out.push(if session.pinned { C::Unpin } else { C::Pin });
        }
        out.extend([
            C::Rename,
            C::Fork,
            if session.archived {
                C::Unarchive
            } else {
                C::Archive
            },
            C::Hide,
            C::Delete,
        ]);
        out
    };
    out.sort_by_key(|c| c.slot().rank());
    out
}

/// `session`'s menu: its commands, then `open_items` (the open chat's own,
/// from the toolbar's More) in a group just before Delete…, as the Chat
/// menu has them.
pub fn native_menu(
    session: &HermesSessionDto,
    open_items: Vec<(String, Box<dyn Action>)>,
    l: &L10n,
) -> NativeMenu {
    let mut menu = NativeMenu::new();
    let mut open_items = Some(open_items);
    for command in commands(session) {
        if command == HermesCommand::Delete {
            menu = menu.separator();
            let open = open_items.take().unwrap_or_default();
            if !open.is_empty() {
                for (label, item) in open {
                    menu = menu.menu(label, item);
                }
                menu = menu.separator();
            }
        }
        menu = menu.menu(
            command.label(l),
            Box::new(HermesMenu {
                session_id: session.id.clone(),
                command,
            }),
        );
    }
    menu
}

fn toast(stores: &Stores, level: NoticeLevel, text: String, cx: &mut App) {
    stores.toasts.update(cx, |t, cx| t.show(level, text, cx));
}

/// Carries out `command` on session `id`, except Rename, which the
/// sidebar does in place ([`rename`] saves it).
pub fn run(stores: &Stores, id: &str, command: HermesCommand, window: &mut Window, cx: &mut App) {
    let update = |pinned, archived, hidden| HermesSessionUpdate {
        id: id.to_string(),
        pinned,
        archived,
        hidden,
    };
    match command {
        HermesCommand::Pin => set_flags(stores, update(Some(true), None, None), cx),
        HermesCommand::Unpin => set_flags(stores, update(Some(false), None, None), cx),
        HermesCommand::Archive => set_flags(stores, update(None, Some(true), None), cx),
        HermesCommand::Unarchive => set_flags(stores, update(None, Some(false), None), cx),
        HermesCommand::Hide => set_flags(stores, update(None, None, Some(true)), cx),
        HermesCommand::Unhide => set_flags(stores, update(None, None, Some(false)), cx),
        HermesCommand::Fork => fork(stores, id, cx),
        HermesCommand::Delete => confirm_delete(stores, id, window, cx),
        // The sidebar's own: the name field in the row.
        HermesCommand::Rename => {}
    }
}

/// Pins, archives or hides a session, or undoes one of them.
fn set_flags(stores: &Stores, update: HermesSessionUpdate, cx: &mut App) {
    let hid = update.hidden == Some(true);
    let unhid = update.hidden == Some(false);
    let call = stores
        .connection
        .read(cx)
        .rpc()
        .call::<methods::HermesSessionsUpdate>(&update);
    let stores = stores.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let result = call.await;
        cx.update(|cx| match result {
            Ok(sessions) => {
                stores.areas.update(cx, |a, cx| {
                    a.adopt_hermes(sessions, cx);
                    if hid || unhid {
                        a.refresh_hermes_hidden(cx);
                    }
                });
                if hid {
                    let text = cx.l10n().desktop_hermes_chat_hidden();
                    toast(&stores, NoticeLevel::Info, text, cx);
                }
            }
            Err(e) => {
                log::warn!("hermes.sessions.update: {e}");
                let text = cx.l10n().hermes_session_update_failed();
                toast(&stores, NoticeLevel::Warning, text, cx);
            }
        });
    })
    .detach();
}

/// Saves session `id`'s new title.
pub fn rename(stores: &Stores, id: &str, title: &str, cx: &mut App) {
    let call = stores
        .connection
        .read(cx)
        .rpc()
        .call::<methods::HermesRenameSession>(&HermesRename {
            id: id.to_string(),
            title: title.to_string(),
        });
    let stores = stores.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let result = call.await;
        cx.update(|cx| match result {
            Ok(sessions) => stores
                .areas
                .update(cx, |a, cx| a.adopt_hermes(sessions, cx)),
            Err(e) => {
                log::warn!("hermes.renameSession: {e}");
                let text = cx.l10n().hermes_session_rename_failed();
                toast(&stores, NoticeLevel::Warning, text, cx);
            }
        });
    })
    .detach();
}

/// Fork: a copy of the session joins the list (the phone's Fork opens
/// nothing either).
fn fork(stores: &Stores, id: &str, cx: &mut App) {
    let call = stores
        .connection
        .read(cx)
        .rpc()
        .call::<methods::HermesForkSession>(&HermesRef { id: id.to_string() });
    let stores = stores.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let result = call.await;
        cx.update(|cx| match result {
            Ok(_) => stores.areas.update(cx, |a, cx| {
                a.refresh(crate::stores::navigation::Area::Hermes, cx)
            }),
            Err(e) => {
                log::warn!("hermes.forkSession: {e}");
                let text = cx.l10n().hermes_session_fork_failed();
                toast(&stores, NoticeLevel::Warning, text, cx);
            }
        });
    })
    .detach();
}

/// Delete…: asked first (it cannot be undone); the open session's chat
/// gives way to a new chat.
fn confirm_delete(stores: &Stores, id: &str, window: &mut Window, cx: &mut App) {
    let l = cx.l10n().clone();
    let spec = SheetSpec::new(
        l.hermes_session_delete_title(),
        l.hermes_session_delete_message(),
        l.delete(),
        l.cancel(),
    )
    .destructive();
    let ask = present_sheet(window, spec, cx);
    let stores = stores.clone();
    let id = id.to_string();
    cx.spawn(async move |cx: &mut AsyncApp| {
        if !ask.await {
            return;
        }
        let call = cx.update(|cx| {
            stores
                .connection
                .read(cx)
                .rpc()
                .call::<methods::HermesDeleteSession>(&HermesRef { id: id.clone() })
        });
        let result = call.await;
        cx.update(|cx| match result {
            Ok(sessions) => {
                stores.areas.update(cx, |a, cx| {
                    a.forget_hermes_hidden(&id);
                    a.adopt_hermes(sessions, cx);
                    // Hidden Chats, when read, lists what is left.
                    if a.hermes_hidden.is_some() {
                        a.refresh_hermes_hidden(cx);
                    }
                });
                let open = stores.navigation.read(cx).selected_item()
                    == Some(&AreaItem::HermesSession(id.clone()));
                if open {
                    stores.navigation.update(cx, |n, cx| n.new_chat(false, cx));
                }
            }
            Err(e) => {
                log::warn!("hermes.deleteSession: {e}");
                let text = cx.l10n().hermes_session_delete_failed();
                toast(&stores, NoticeLevel::Warning, text, cx);
            }
        });
    })
    .detach();
}

/// Opens session `session`'s chat (a branch, a fork or a copy just made).
fn open(stores: &Stores, session: &HermesSessionDto, cx: &mut App) {
    stores.areas.update(cx, |a, cx| {
        a.refresh(crate::stores::navigation::Area::Hermes, cx)
    });
    let item = AreaItem::HermesSession(session.id.clone());
    stores.navigation.update(cx, |n, cx| n.open_item(item, cx));
}

/// Continue Here (`copy` false) or Continue in a Copy, from a read-only
/// session's chat `chat_id`; the session it goes on in opens. `done` runs
/// once it is over, either way (the notice's buttons wait for it).
pub fn continue_chat(
    stores: &Stores,
    chat_id: &str,
    copy: bool,
    done: impl FnOnce(&mut App) + 'static,
    cx: &mut App,
) {
    let call = stores
        .connection
        .read(cx)
        .rpc()
        .call::<methods::HermesSessionsContinue>(&HermesContinue {
            chat_id: chat_id.to_string(),
            copy,
        });
    let stores = stores.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let result = call.await;
        cx.update(|cx| {
            done(cx);
            match result {
                Ok(session) => open(&stores, &session, cx),
                Err(e) => {
                    log::warn!("hermes.sessions.continue: {e}");
                    let l = cx.l10n();
                    let text = if copy {
                        l.hermes_continue_in_copy_failed()
                    } else {
                        l.hermes_continue_here_failed()
                    };
                    toast(&stores, NoticeLevel::Warning, text, cx);
                }
            }
        });
    })
    .detach();
}

/// Branch from Here on reply `message_id` of Hermes chat `chat_id`: the
/// new session's chat opens.
pub fn branch(stores: &Stores, chat_id: &str, message_id: &str, cx: &mut App) {
    let call = stores
        .connection
        .read(cx)
        .rpc()
        .call::<methods::HermesHistoryBranch>(&HermesBranch {
            chat_id: chat_id.to_string(),
            message_id: message_id.to_string(),
        });
    let stores = stores.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let result = call.await;
        cx.update(|cx| match result {
            Ok(session) => open(&stores, &session, cx),
            Err(e) => {
                log::warn!("hermes.history.branch: {e}");
                let text = cx.l10n().hermes_branch_failed();
                toast(&stores, NoticeLevel::Warning, text, cx);
            }
        });
    })
    .detach();
}

/// Undo Last Turn of Hermes chat `chat_id` (a Desktop Gateway's): said
/// once it is done; the chat reads itself again.
pub fn undo(stores: &Stores, chat_id: &str, cx: &mut App) {
    let call = stores
        .connection
        .read(cx)
        .rpc()
        .call::<methods::HermesHistoryUndo>(&ChatRef {
            id: chat_id.to_string(),
        });
    let stores = stores.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let result = call.await;
        cx.update(|cx| match result {
            Ok(done) if done.ok => {
                let text = cx.l10n().hermes_undo_last_turn_done();
                toast(&stores, NoticeLevel::Info, text, cx);
            }
            // Nothing was undone: nothing to say.
            Ok(_) => {}
            Err(e) => {
                log::warn!("hermes.history.undo: {e}");
                let text = cx.l10n().hermes_undo_last_turn_failed();
                toast(&stores, NoticeLevel::Warning, text, cx);
            }
        });
    })
    .detach();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(pinned: bool, archived: bool, hidden: bool) -> HermesSessionDto {
        HermesSessionDto {
            id: "s1".into(),
            chat_id: "local:hermes_s1".into(),
            title: "Pond plants".into(),
            preview: None,
            updated_at_ms: None,
            pinned,
            archived,
            hidden,
            source: None,
            running: false,
        }
    }

    /// Delete… of a hidden session takes it out of Hidden Chats too, once
    /// confirmed: the page lists what is left.
    #[gpui_kit::test]
    fn a_deleted_hidden_session_leaves_hidden_chats(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-hdel-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            cx.set_global(crate::shell::sheet::AutoAnswer(Some(true)));
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        daemon.returns::<methods::HermesDeleteSession>(conduit_protocol::HermesSessions::default());
        daemon.returns::<methods::HermesHiddenList>(conduit_protocol::HermesSessions::default());
        stores.areas.update(cx, |a, cx| {
            a.hermes_hidden = Some(Ok(vec![session(false, false, true)]));
            cx.notify();
        });
        let vcx = cx.add_empty_window();
        vcx.update(|window, cx| run(&stores, "s1", HermesCommand::Delete, window, cx));
        vcx.run_until_parked();
        assert!(daemon.calls::<methods::HermesDeleteSession>().len() == 1);
        stores.areas.read_with(vcx, |a, _| {
            assert!(
                matches!(&a.hermes_hidden, Some(Ok(list)) if list.is_empty()),
                "Hidden Chats still lists the deleted session"
            );
        });
    }

    /// A deleted hidden session is not found again through the Hidden Chats
    /// last listed when the refresh after the delete fails.
    #[gpui_kit::test]
    fn a_deleted_hidden_session_is_not_found_after_a_failed_refresh(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-hdel2-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            cx.set_global(crate::shell::sheet::AutoAnswer(Some(true)));
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        daemon.once::<methods::HermesHiddenList>(Ok(conduit_protocol::HermesSessions {
            sessions: vec![session(false, false, true)],
            ..Default::default()
        }));
        daemon.once::<methods::HermesHiddenList>(Err(conduit_daemon::protocol::error(
            "rpc.daemonUnavailable",
            "away",
        )));
        daemon.returns::<methods::HermesDeleteSession>(conduit_protocol::HermesSessions::default());
        stores.areas.update(cx, |a, cx| a.refresh_hermes_hidden(cx));
        cx.run_until_parked();
        assert!(
            stores
                .areas
                .read_with(cx, |a, _| a.hermes_session("s1").is_some())
        );
        let vcx = cx.add_empty_window();
        vcx.update(|window, cx| run(&stores, "s1", HermesCommand::Delete, window, cx));
        vcx.run_until_parked();
        assert!(
            stores
                .areas
                .read_with(vcx, |a, _| a.hermes_session("s1").is_none()),
            "the deleted session is still found"
        );
    }

    #[test]
    fn a_session_offers_the_phones_commands_in_the_shared_order() {
        use HermesCommand as C;
        assert_eq!(
            commands(&session(false, false, false)),
            [C::Pin, C::Rename, C::Fork, C::Archive, C::Hide, C::Delete]
        );
        assert_eq!(commands(&session(true, false, false))[0], C::Unpin);
        // An archived session is not pinned.
        assert_eq!(
            commands(&session(false, true, false)),
            [C::Rename, C::Fork, C::Unarchive, C::Hide, C::Delete]
        );
        // A hidden one only comes back, or goes.
        assert_eq!(
            commands(&session(false, false, true)),
            [C::Unhide, C::Delete]
        );
        // Each in its slot of the order every chat menu shares.
        let ranks: Vec<usize> = commands(&session(false, false, false))
            .iter()
            .map(|c| c.slot().rank())
            .collect();
        assert!(ranks.windows(2).all(|w| w[0] < w[1]));
    }
}
