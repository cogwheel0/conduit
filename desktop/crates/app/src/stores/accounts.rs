//! Saved Open WebUI accounts: `accounts.list/add/cancelAdd/switch/remove/
//! signOut` over core's accounts controller.
//!
//! Every change goes through the daemon and the list shown is the one the
//! daemon answers with (each change's reply carries it), then refetched
//! with `accounts.list`; nothing is patched locally. `accounts.changed`
//! refetches too, so a change made in another window shows up here.
//!
//! Each outcome becomes an [`AccountNotice`] the window words, and
//! `blockedByActiveReply` parks the change in [`AccountsStore::blocked`]
//! until the user confirms stopping the reply ([`AccountsStore::confirm_blocked`],
//! which repeats it with `force`) or not ([`AccountsStore::dismiss_blocked`]).

use std::future::Future;
use std::pin::Pin;

use conduit_daemon::RpcError;
use conduit_protocol::{
    AccountChangeOutcome, AccountChangeResult, AccountList, AccountRef, AccountSignOut,
    AccountSummary, AddAccount, ErrorCode, LibreChatAccountSummary, LibreChatSessionPhase,
    NoParams, PrimaryAccount, ServerDraft, methods,
};
use gpui_kit::{AsyncApp, Context, EventEmitter, Task, WeakEntity};

use super::rpc::Rpc;

/// An account change the user asked for.
#[derive(Clone, Debug, PartialEq)]
pub enum AccountChange {
    /// Sign in to a new account on `server`.
    Add(Box<ServerDraft>),
    /// Sign in to another account on the saved server `server_id`, through
    /// its first address (Add Account on This Server); `server` names it.
    AddOnServer {
        server_id: String,
        server: Box<ServerDraft>,
    },
    /// Leave an addition whose sign-in has not finished.
    CancelAdd,
    Switch {
        account_id: String,
    },
    /// Sign out of the account and remove it with its local data.
    Remove {
        account_id: String,
    },
    /// Sign out of the active account; the next one takes over.
    SignOut,
}

impl AccountChange {
    /// The account the change is about, when it names one.
    pub fn account_id(&self) -> Option<&str> {
        match self {
            Self::Switch { account_id } | Self::Remove { account_id } => Some(account_id),
            _ => None,
        }
    }

    /// Whether it signs out of an account (rather than switching to one).
    pub fn signs_out(&self) -> bool {
        matches!(self, Self::Remove { .. } | Self::SignOut)
    }
}

/// What the window tells the user after a change. Names are display names
/// resolved from the lists before and after the change.
#[derive(Clone, Debug, PartialEq)]
pub enum AccountNotice {
    /// The first account was added; its sign-in is next (nothing to say).
    Added,
    /// An account was added beside the one in use and waits for its
    /// sign-in.
    AddedNeedsSignIn,
    /// Switched; the account is signed in.
    SwitchedTo {
        name: String,
    },
    /// Switched, but its session is gone: sign in again.
    SwitchedNeedsSignIn {
        name: String,
    },
    AlreadyActive {
        name: String,
    },
    /// Signed out of `name`; `next` took over (signed in), or none is left.
    SignedOut {
        name: String,
        next: Option<String>,
    },
    /// Signed out of `name`; `next` took over and needs a sign-in.
    SignedOutNextNeedsSignIn {
        name: String,
        next: String,
    },
    /// The addition was left, or an account nobody signed in to was
    /// removed; back on `name` (or no account).
    AddCancelled {
        name: Option<String>,
    },
    /// `cancelAdd` found nothing to leave: the sign-in had finished.
    NothingToCancel,
    /// A newer daemon answered with an outcome this build does not know.
    UnknownOutcome,
    Failed {
        error: RpcError,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub enum AccountsEvent {
    /// A change finished (or failed); show the notice.
    Notice(AccountNotice),
    /// A change was refused because a reply is still being written in the
    /// account it would leave: ask, then [`AccountsStore::confirm_blocked`].
    Blocked(AccountChange),
}

/// A display name for an account: its user's name, else its email, else the
/// connection's name.
pub fn display_name(account: &AccountSummary) -> String {
    account
        .user
        .as_ref()
        .and_then(|u| {
            u.name
                .clone()
                .filter(|n| !n.trim().is_empty())
                .or_else(|| u.email.clone().filter(|e| !e.is_empty()))
        })
        .unwrap_or_else(|| account.connection.name.clone())
}

/// A display name for a LibreChat account: its user's name, else its
/// email, else its server's title.
pub fn libre_chat_display_name(account: &LibreChatAccountSummary) -> String {
    account
        .user
        .as_ref()
        .and_then(|u| {
            u.name
                .clone()
                .filter(|n| !n.trim().is_empty())
                .or_else(|| u.email.clone().filter(|e| !e.is_empty()))
        })
        .unwrap_or_else(|| account.title.clone())
}

fn name_of(list: &AccountList, id: Option<&str>) -> Option<String> {
    let id = id?;
    list.accounts
        .iter()
        .find(|a| a.id == id)
        .map(display_name)
        .or_else(|| {
            list.libre_chat_accounts
                .iter()
                .find(|a| a.id == id)
                .map(libre_chat_display_name)
        })
}

/// The account in charge of the chats: the active Open WebUI account, or
/// the LibreChat account in use while LibreChat owns them.
fn in_charge(list: &AccountList) -> Option<&str> {
    match list.primary {
        PrimaryAccount::LibreChat => list.active_libre_chat_account_id.as_deref(),
        _ => list.active_account_id.as_deref(),
    }
}

/// The notice for `change`'s `result`, given the list before it. `None` for
/// `blockedByActiveReply`, which asks rather than tells.
pub fn describe(
    change: &AccountChange,
    before: Option<&AccountList>,
    result: &AccountChangeResult,
) -> Option<AccountNotice> {
    use AccountChangeOutcome as O;
    let after = &result.accounts;
    let active_after = in_charge(after);
    let target_before = change
        .account_id()
        .map(str::to_string)
        .or_else(|| match change {
            AccountChange::SignOut => before.and_then(in_charge).map(str::to_string),
            _ => None,
        });
    let name = before
        .and_then(|b| name_of(b, target_before.as_deref()))
        .or_else(|| name_of(after, target_before.as_deref()))
        .unwrap_or_default();
    let next = name_of(after, active_after);
    // Leaving an account nobody signed in to (a server that failed its
    // check, Use a Different Server) signs out of nothing.
    let never_signed_in = before
        .and_then(|b| {
            b.accounts
                .iter()
                .find(|a| Some(a.id.as_str()) == target_before.as_deref())
        })
        .is_some_and(|a| a.user.is_none() && !a.has_session);
    Some(match (change, result.outcome) {
        (_, O::BlockedByActiveReply) => return None,
        (_, O::Unknown) => AccountNotice::UnknownOutcome,
        (_, O::AlreadyActive) => AccountNotice::AlreadyActive { name },
        // The first account needs no notice: the window shows its sign-in.
        (AccountChange::Add(_) | AccountChange::AddOnServer { .. }, _) if !after.adding_account => {
            return Some(AccountNotice::Added);
        }
        (AccountChange::Add(_) | AccountChange::AddOnServer { .. }, _) => {
            AccountNotice::AddedNeedsSignIn
        }
        (AccountChange::CancelAdd, O::Unchanged) => AccountNotice::NothingToCancel,
        (AccountChange::CancelAdd, _) => AccountNotice::AddCancelled { name: next },
        (AccountChange::Switch { .. }, O::NeedsSignIn) => {
            AccountNotice::SwitchedNeedsSignIn { name }
        }
        (AccountChange::Switch { .. }, _) => AccountNotice::SwitchedTo { name },
        (AccountChange::Remove { .. } | AccountChange::SignOut, _) if never_signed_in => {
            AccountNotice::AddCancelled { name: next }
        }
        (AccountChange::Remove { .. } | AccountChange::SignOut, O::NeedsSignIn) => match next {
            Some(next) => AccountNotice::SignedOutNextNeedsSignIn { name, next },
            None => AccountNotice::SignedOut { name, next: None },
        },
        (AccountChange::Remove { .. } | AccountChange::SignOut, _) => {
            AccountNotice::SignedOut { name, next }
        }
    })
}

type ChangeFuture = Pin<Box<dyn Future<Output = Result<AccountChangeResult, RpcError>> + Send>>;

pub struct AccountsStore {
    rpc: Rpc,
    /// `None` until the daemon has answered once.
    pub list: Option<AccountList>,
    pub load_error: Option<RpcError>,
    /// The change in flight.
    pub busy: Option<AccountChange>,
    /// A change refused by `blockedByActiveReply`, waiting for the user.
    pub blocked: Option<AccountChange>,
    /// The account in charge when [`Self::blocked`] was asked for: the one
    /// its forced repeat is bound to.
    blocked_over: Option<String>,
    /// The last change's notice, until the next one.
    pub notice: Option<AccountNotice>,
    generation: u64,
    _fetch: Option<Task<()>>,
}

impl EventEmitter<AccountsEvent> for AccountsStore {}

impl AccountsStore {
    pub fn new(rpc: Rpc) -> Self {
        Self {
            rpc,
            list: None,
            load_error: None,
            busy: None,
            blocked: None,
            blocked_over: None,
            notice: None,
            generation: 0,
            _fetch: None,
        }
    }

    pub fn accounts(&self) -> &[AccountSummary] {
        self.list.as_ref().map_or(&[], |l| l.accounts.as_slice())
    }

    pub fn active(&self) -> Option<&AccountSummary> {
        let list = self.list.as_ref()?;
        let id = list.active_account_id.as_deref()?;
        list.accounts.iter().find(|a| a.id == id)
    }

    /// The id of the account in charge of the chats: the active Open WebUI
    /// account, or the LibreChat account in use while LibreChat owns them.
    pub fn in_charge_id(&self) -> Option<String> {
        in_charge(self.list.as_ref()?).map(str::to_string)
    }

    /// The account in charge of the chats, as a scope: the active Open
    /// WebUI account, or the LibreChat account in use while LibreChat owns
    /// the chats. Another scope means nothing chosen carries over.
    pub fn scope_key(&self) -> Option<String> {
        let list = self.list.as_ref()?;
        let id = in_charge(list)?;
        Some(match list.primary {
            PrimaryAccount::LibreChat => format!("librechat:{id}"),
            _ => id.to_string(),
        })
    }

    pub fn adding(&self) -> bool {
        self.list.as_ref().is_some_and(|l| l.adding_account)
    }

    /// The saved LibreChat accounts.
    pub fn libre_chat_accounts(&self) -> &[LibreChatAccountSummary] {
        self.list
            .as_ref()
            .map_or(&[], |l| l.libre_chat_accounts.as_slice())
    }

    /// Whether a LibreChat account owns the chats.
    pub fn libre_chat_in_charge(&self) -> bool {
        self.list
            .as_ref()
            .is_some_and(|l| l.primary == PrimaryAccount::LibreChat)
    }

    /// The LibreChat account in use, whether or not it owns the chats.
    pub fn libre_chat_active(&self) -> Option<&LibreChatAccountSummary> {
        let list = self.list.as_ref()?;
        let id = list.active_libre_chat_account_id.as_deref()?;
        list.libre_chat_accounts.iter().find(|a| a.id == id)
    }

    /// The LibreChat account in charge of the chats when its session ended
    /// and it needs a sign-in, from its own server.
    pub fn libre_chat_needs_sign_in(&self) -> Option<&LibreChatAccountSummary> {
        let list = self.list.as_ref()?;
        if list.primary != PrimaryAccount::LibreChat
            || list.libre_chat_session != LibreChatSessionPhase::NeedsSignIn
        {
            return None;
        }
        self.libre_chat_active()
    }

    /// Forgets the list: a new daemon session may hold another state.
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.generation += 1;
        self.list = None;
        self.busy = None;
        self.blocked = None;
        self.blocked_over = None;
        cx.notify();
    }

    /// Refetches `accounts.list`. Answers that arrive after a newer fetch or
    /// change are dropped.
    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        self.generation += 1;
        let generation = self.generation;
        let call = self.rpc.call::<methods::AccountsList>(&NoParams);
        self._fetch = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    if s.generation != generation {
                        return;
                    }
                    match result {
                        Ok(list) => {
                            s.load_error = None;
                            s.set_list(list, cx);
                        }
                        Err(e) => {
                            log::warn!("accounts.list: {e}");
                            s.load_error = Some(e);
                            cx.notify();
                        }
                    }
                });
            }),
        );
    }

    /// Takes a list another store fetched from the daemon (the session's
    /// refresh), unless a change of this store is in flight. Whether it
    /// took it.
    pub fn adopt(&mut self, list: AccountList, cx: &mut Context<Self>) -> bool {
        if self.busy.is_some() {
            return false;
        }
        // A read of this store's still on its way is older than this.
        self.generation += 1;
        self._fetch = None;
        self.load_error = None;
        self.set_list(list, cx);
        true
    }

    fn set_list(&mut self, list: AccountList, cx: &mut Context<Self>) {
        if self.list.as_ref() != Some(&list) {
            self.list = Some(list);
            cx.notify();
        }
    }

    /// Starts `change`. Resolves with the daemon's answer (also reported as
    /// an [`AccountsEvent`] and in [`Self::notice`]).
    pub fn change(
        &mut self,
        change: AccountChange,
        force: bool,
        cx: &mut Context<Self>,
    ) -> Task<Result<AccountChangeResult, RpcError>> {
        self.change_asked_over(change, force, None, cx)
    }

    /// [`Self::change`], for a switch the user was asked about while
    /// `asked_over` was in charge (Switch Anyway): conduitd refuses it, and
    /// stops nothing, once another account is in charge. A forced switch
    /// with no account it was asked over is not sent at all (conduitd would
    /// refuse it too).
    pub fn change_asked_over(
        &mut self,
        change: AccountChange,
        force: bool,
        asked_over: Option<String>,
        cx: &mut Context<Self>,
    ) -> Task<Result<AccountChangeResult, RpcError>> {
        if force && asked_over.is_none() && matches!(change, AccountChange::Switch { .. }) {
            return Task::ready(Err(RpcError {
                debug_message: Some("a forced switch needs the account it was asked over".into()),
                ..RpcError::new(ErrorCode::InvalidParams)
            }));
        }
        let call = self.call(&change, force, asked_over);
        // Names in the notice come from the list as it was: by the time the
        // reply arrives, accounts.changed may have refetched it already.
        let before = self.list.clone();
        self.busy = Some(change.clone());
        self.blocked = None;
        self.blocked_over = None;
        self.generation += 1;
        let generation = self.generation;
        cx.notify();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            this.update(cx, |s, cx| {
                s.finish(change, before.as_ref(), generation, &result, cx)
            })
            .ok();
            result
        })
    }

    fn call(
        &self,
        change: &AccountChange,
        force: bool,
        asked_over: Option<String>,
    ) -> ChangeFuture {
        let rpc = &self.rpc;
        match change {
            AccountChange::Add(server) => Box::pin(rpc.call::<methods::AccountsAdd>(&AddAccount {
                server: (**server).clone(),
                server_id: None,
                force,
            })),
            AccountChange::AddOnServer { server_id, server } => {
                Box::pin(rpc.call::<methods::AccountsAdd>(&AddAccount {
                    server: (**server).clone(),
                    server_id: Some(server_id.clone()),
                    force,
                }))
            }
            AccountChange::CancelAdd => Box::pin(rpc.call::<methods::AccountsCancelAdd>(&NoParams)),
            AccountChange::Switch { account_id } => {
                Box::pin(rpc.call::<methods::AccountsSwitch>(&AccountRef {
                    account_id: account_id.clone(),
                    force,
                    asked_over,
                }))
            }
            AccountChange::Remove { account_id } => {
                Box::pin(rpc.call::<methods::AccountsRemove>(&AccountRef {
                    account_id: account_id.clone(),
                    force,
                    asked_over: None,
                }))
            }
            AccountChange::SignOut => {
                Box::pin(rpc.call::<methods::AccountsSignOut>(&AccountSignOut { force }))
            }
        }
    }

    fn finish(
        &mut self,
        change: AccountChange,
        before: Option<&AccountList>,
        generation: u64,
        result: &Result<AccountChangeResult, RpcError>,
        cx: &mut Context<Self>,
    ) {
        if self.busy.as_ref() == Some(&change) {
            self.busy = None;
        }
        match result {
            Ok(result) => {
                let notice = describe(&change, before.or(self.list.as_ref()), result);
                if generation == self.generation {
                    self.set_list(result.accounts.clone(), cx);
                }
                match notice {
                    None => {
                        self.blocked_over = before.and_then(in_charge).map(str::to_string);
                        self.blocked = Some(change.clone());
                        cx.emit(AccountsEvent::Blocked(change));
                    }
                    Some(notice) => {
                        self.notice = Some(notice.clone());
                        cx.emit(AccountsEvent::Notice(notice));
                    }
                }
            }
            Err(error) => {
                let notice = AccountNotice::Failed {
                    error: error.clone(),
                };
                self.notice = Some(notice.clone());
                cx.emit(AccountsEvent::Notice(notice));
            }
        }
        // The reply is the daemon's list; fetch once more so what settled
        // after it (a session restored on a switch) shows too.
        self.refresh(cx);
        cx.notify();
    }

    /// Repeats the blocked change with `force`, stopping the reply.
    pub fn confirm_blocked(
        &mut self,
        cx: &mut Context<Self>,
    ) -> Option<Task<Result<AccountChangeResult, RpcError>>> {
        let change = self.blocked.take()?;
        let over = self.blocked_over.take();
        Some(self.change_asked_over(change, true, over, cx))
    }

    pub fn dismiss_blocked(&mut self, cx: &mut Context<Self>) {
        self.blocked_over = None;
        if self.blocked.take().is_some() {
            cx.notify();
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use conduit_protocol::{AccountUser, ServerSummary};
    use gpui_kit::{AppContext as _, TestAppContext};
    use serde_json::json;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    pub fn account(id: &str, name: &str, active: bool, session: bool) -> AccountSummary {
        AccountSummary {
            id: id.into(),
            server_id: "srv".into(),
            connection: ServerSummary {
                id: id.into(),
                name: "Lab".into(),
                url: "https://chat.example.org".into(),
                is_active: active,
                last_connected_ms: None,
                allow_self_signed_certificates: false,
                has_mutual_tls_credentials: false,
                mtls_certificate_label: None,
                mtls_private_key_label: None,
                custom_header_names: vec![],
                has_stored_session: session,
            },
            user: Some(AccountUser {
                name: Some(name.into()),
                email: Some(format!("{}@example.org", name.to_lowercase())),
                avatar_url: None,
            }),
            is_active: active,
            has_session: session,
            last_used_ms: None,
        }
    }

    pub fn list(accounts: Vec<AccountSummary>) -> AccountList {
        let active = accounts.iter().find(|a| a.is_active).map(|a| a.id.clone());
        AccountList {
            accounts,
            active_account_id: active,
            adding_account: false,
            ..Default::default()
        }
    }

    pub fn two() -> AccountList {
        list(vec![
            account("a", "Avery", true, true),
            account("b", "Blake", false, true),
        ])
    }

    fn result(outcome: AccountChangeOutcome, accounts: AccountList) -> AccountChangeResult {
        AccountChangeResult { outcome, accounts }
    }

    #[test]
    fn the_scope_is_the_account_in_charge_of_the_chats() {
        let mut store = AccountsStore::new(crate::stores::rpc::fake::FakeDaemon::new().rpc());
        let mut l = two();
        store.list = Some(l.clone());
        assert_eq!(store.scope_key().as_deref(), Some("a"));
        // LibreChat owns the chats: its account is the scope, though the
        // Open WebUI account stays active (parked).
        l.primary = PrimaryAccount::LibreChat;
        l.active_libre_chat_account_id = Some("a".into());
        store.list = Some(l.clone());
        assert_eq!(store.scope_key().as_deref(), Some("librechat:a"));
        l.active_libre_chat_account_id = None;
        store.list = Some(l);
        assert_eq!(store.scope_key(), None);
    }

    #[test]
    fn every_outcome_has_a_notice() {
        use AccountChangeOutcome as O;
        let before = two();
        let switch = AccountChange::Switch {
            account_id: "b".into(),
        };
        let after_switch = list(vec![
            account("a", "Avery", false, true),
            account("b", "Blake", true, true),
        ]);
        assert_eq!(
            describe(
                &switch,
                Some(&before),
                &result(O::Done, after_switch.clone())
            ),
            Some(AccountNotice::SwitchedTo {
                name: "Blake".into()
            })
        );
        assert_eq!(
            describe(
                &switch,
                Some(&before),
                &result(O::NeedsSignIn, after_switch)
            ),
            Some(AccountNotice::SwitchedNeedsSignIn {
                name: "Blake".into()
            })
        );
        let stay = AccountChange::Switch {
            account_id: "a".into(),
        };
        assert_eq!(
            describe(&stay, Some(&before), &result(O::AlreadyActive, two())),
            Some(AccountNotice::AlreadyActive {
                name: "Avery".into()
            })
        );
        assert_eq!(
            describe(
                &switch,
                Some(&before),
                &result(O::BlockedByActiveReply, two())
            ),
            None,
            "blocked asks instead of telling"
        );
        assert_eq!(
            describe(
                &AccountChange::CancelAdd,
                Some(&before),
                &result(O::Unchanged, two())
            ),
            Some(AccountNotice::NothingToCancel)
        );
        assert_eq!(
            describe(
                &AccountChange::CancelAdd,
                Some(&before),
                &result(O::Done, two())
            ),
            Some(AccountNotice::AddCancelled {
                name: Some("Avery".into())
            })
        );
        assert_eq!(
            describe(
                &AccountChange::Add(Box::new(ServerDraft {
                    id: None,
                    name: "Lab".into(),
                    url: "https://chat.example.org".into(),
                    allow_self_signed_certificates: false,
                    mtls_certificate_chain_pem: None,
                    mtls_certificate_label: None,
                    mtls_private_key_pem: None,
                    mtls_private_key_label: None,
                    mtls_private_key_password: None,
                    clear_mutual_tls: false,
                    custom_headers: None,
                })),
                Some(&before),
                &result(O::NeedsSignIn, {
                    let mut l = two();
                    l.adding_account = true;
                    l
                })
            ),
            Some(AccountNotice::AddedNeedsSignIn)
        );
        assert_eq!(
            describe(&switch, Some(&before), &result(O::Unknown, two())),
            Some(AccountNotice::UnknownOutcome)
        );
    }

    #[test]
    fn signing_out_names_the_hand_over() {
        use AccountChangeOutcome as O;
        let before = two();
        let next_signed_in = list(vec![account("b", "Blake", true, true)]);
        assert_eq!(
            describe(
                &AccountChange::SignOut,
                Some(&before),
                &result(O::Done, next_signed_in)
            ),
            Some(AccountNotice::SignedOut {
                name: "Avery".into(),
                next: Some("Blake".into())
            })
        );
        let next_signed_out = list(vec![account("b", "Blake", true, false)]);
        assert_eq!(
            describe(
                &AccountChange::SignOut,
                Some(&before),
                &result(O::NeedsSignIn, next_signed_out)
            ),
            Some(AccountNotice::SignedOutNextNeedsSignIn {
                name: "Avery".into(),
                next: "Blake".into()
            })
        );
        let none_left = list(vec![]);
        assert_eq!(
            describe(
                &AccountChange::Remove {
                    account_id: "a".into()
                },
                Some(&before),
                &result(O::Done, none_left)
            ),
            Some(AccountNotice::SignedOut {
                name: "Avery".into(),
                next: None
            })
        );
    }

    #[gpui_kit::test]
    fn changes_adopt_the_daemons_list_and_refetch(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let after = list(vec![
            account("a", "Avery", false, true),
            account("b", "Blake", true, true),
        ]);
        daemon.returns::<methods::AccountsList>(two());
        daemon
            .returns::<methods::AccountsSwitch>(result(AccountChangeOutcome::Done, after.clone()));
        let store = cx.new(|_| AccountsStore::new(daemon.rpc()));
        let events = Rc::new(RefCell::new(vec![]));
        cx.update(|cx| {
            let events = events.clone();
            cx.subscribe(&store, move |_, e: &AccountsEvent, _| {
                events.borrow_mut().push(e.clone())
            })
            .detach();
        });
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        assert_eq!(store.read_with(cx, |s, _| s.list.clone()), Some(two()));

        daemon.returns::<methods::AccountsList>(after.clone());
        store
            .update(cx, |s, cx| {
                s.change(
                    AccountChange::Switch {
                        account_id: "b".into(),
                    },
                    false,
                    cx,
                )
            })
            .detach();
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.list.as_ref(), Some(&after));
            assert_eq!(s.busy, None);
            assert_eq!(s.active().map(display_name).as_deref(), Some("Blake"));
        });
        assert_eq!(
            daemon.calls::<methods::AccountsSwitch>(),
            vec![json!({"accountId": "b", "force": false})]
        );
        assert_eq!(daemon.calls::<methods::AccountsList>().len(), 2);
        assert_eq!(
            events.borrow().as_slice(),
            &[AccountsEvent::Notice(AccountNotice::SwitchedTo {
                name: "Blake".into()
            })]
        );
    }

    /// A blocked switch, confirmed, names the account that was in charge
    /// when it was asked for; a forced switch with no such account is never
    /// sent.
    #[gpui_kit::test]
    fn a_forced_switch_names_the_account_it_was_asked_over(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(two());
        daemon.once::<methods::AccountsSwitch>(Ok(result(
            AccountChangeOutcome::BlockedByActiveReply,
            two(),
        )));
        daemon.once::<methods::AccountsSwitch>(Ok(result(AccountChangeOutcome::Done, two())));
        let store = cx.new(|_| AccountsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        let asked_over = store.read_with(cx, |s, _| s.in_charge_id());
        assert!(asked_over.is_some());
        let switch = AccountChange::Switch {
            account_id: "b".into(),
        };
        store
            .update(cx, |s, cx| s.change(switch.clone(), false, cx))
            .detach();
        cx.run_until_parked();
        store
            .update(cx, |s, cx| s.confirm_blocked(cx))
            .expect("a blocked change to confirm")
            .detach();
        cx.run_until_parked();
        let calls = daemon.calls::<methods::AccountsSwitch>();
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].get("askedOver"), None, "a plain switch names none");
        assert_eq!(calls[1]["force"], json!(true));
        assert_eq!(calls[1]["askedOver"].as_str(), asked_over.as_deref());

        let refused = store.update(cx, |s, cx| s.change_asked_over(switch, true, None, cx));
        let failed = std::rc::Rc::new(std::cell::Cell::new(false));
        let seen = failed.clone();
        cx.spawn(async move |_| seen.set(refused.await.is_err()))
            .detach();
        cx.run_until_parked();
        assert!(
            failed.get(),
            "the forced switch with no origin did not fail"
        );
        assert_eq!(
            daemon.calls::<methods::AccountsSwitch>().len(),
            2,
            "a forced switch with no account it was asked over was sent"
        );
    }

    #[gpui_kit::test]
    fn a_blocked_change_waits_for_force(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(two());
        daemon.once::<methods::AccountsSignOut>(Ok(result(
            AccountChangeOutcome::BlockedByActiveReply,
            two(),
        )));
        daemon.once::<methods::AccountsSignOut>(Ok(result(
            AccountChangeOutcome::Done,
            list(vec![account("b", "Blake", true, true)]),
        )));
        let store = cx.new(|_| AccountsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        store
            .update(cx, |s, cx| s.change(AccountChange::SignOut, false, cx))
            .detach();
        cx.run_until_parked();
        assert_eq!(
            store.read_with(cx, |s, _| s.blocked.clone()),
            Some(AccountChange::SignOut)
        );
        store
            .update(cx, |s, cx| s.confirm_blocked(cx))
            .expect("a blocked change to confirm")
            .detach();
        cx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::AccountsSignOut>(),
            vec![json!({"force": false}), json!({"force": true})]
        );
        store.read_with(cx, |s, _| {
            assert_eq!(s.blocked, None);
            assert_eq!(
                s.notice,
                Some(AccountNotice::SignedOut {
                    name: "Avery".into(),
                    next: Some("Blake".into())
                })
            );
        });
    }

    #[gpui_kit::test]
    fn the_notice_names_the_account_even_after_a_refetch(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let after = list(vec![account("b", "Blake", true, true)]);
        daemon.returns::<methods::AccountsList>(two());
        daemon
            .returns::<methods::AccountsSignOut>(result(AccountChangeOutcome::Done, after.clone()));
        let store = cx.new(|_| AccountsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        let task = store.update(cx, |s, cx| s.change(AccountChange::SignOut, false, cx));
        // accounts.changed lands before the reply: the list no longer has
        // the account signed out of.
        daemon.returns::<methods::AccountsList>(after);
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        task.detach();
        cx.run_until_parked();
        assert_eq!(
            store.read_with(cx, |s, _| s.notice.clone()),
            Some(AccountNotice::SignedOut {
                name: "Avery".into(),
                next: Some("Blake".into())
            })
        );
    }

    #[gpui_kit::test]
    fn a_failed_change_is_reported_and_the_list_refetched(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(two());
        daemon.once::<methods::AccountsRemove>(Err(conduit_daemon::protocol::error(
            "resource.notFound",
            "gone",
        )));
        let store = cx.new(|_| AccountsStore::new(daemon.rpc()));
        store
            .update(cx, |s, cx| {
                s.change(
                    AccountChange::Remove {
                        account_id: "zz".into(),
                    },
                    false,
                    cx,
                )
            })
            .detach();
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(matches!(s.notice, Some(AccountNotice::Failed { .. })));
            assert_eq!(s.list.as_ref(), Some(&two()));
        });
    }

    #[gpui_kit::test]
    fn an_older_read_never_replaces_an_adopted_list(cx: &mut gpui_kit::TestAppContext) {
        use gpui_kit::AppContext as _;
        let daemon = crate::stores::rpc::fake::FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(two());
        let held = daemon.hold::<methods::AccountsList>();
        let store = cx.new(|_| AccountsStore::new(daemon.rpc()));
        store.update(cx, |a, cx| a.refresh(cx));
        cx.run_until_parked();
        // The session's newer fetch saw a switch to B.
        let switched = list(vec![
            account("a", "Avery", false, true),
            account("b", "Blake", true, true),
        ]);
        store.update(cx, |a, cx| a.adopt(switched.clone(), cx));
        held.release();
        cx.run_until_parked();
        store.read_with(cx, |a, _| assert_eq!(a.list.as_ref(), Some(&switched)));
    }
}
