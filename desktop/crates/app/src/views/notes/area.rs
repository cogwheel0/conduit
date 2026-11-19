//! What the main window shows for the Notes section: All Notes' list, or a
//! note's pane.
//!
//! A note left for another (or for anything else) is saved first: its pane
//! is kept until the save has landed, so nothing typed is lost to a quick
//! click elsewhere. A draft the server refused (the note became read-only,
//! or its page was removed) cannot be saved where it was: leaving it asks
//! whether to keep it as a note of its own, as the phone's editor offers.
//! Quitting waits for the open note's save too.

use std::cell::Cell;
use std::time::Duration;

use gpui_kit::prelude::*;
use gpui_kit::{App, Context, Entity, Subscription, Window, div};

use super::list::NotesList;
use super::pane::{NotePane, PaneEvent};
use crate::l10n::ActiveL10n as _;
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::navigation::{AreaItem, NavigationEvent};

thread_local! {
    /// New Note: the next note pane opened puts the caret in its text.
    static FOCUS_BODY_NEXT: Cell<bool> = const { Cell::new(false) };
}

/// The next note pane opened takes the keyboard into its text (New Note).
pub fn focus_body_next(_: &mut App) {
    FOCUS_BODY_NEXT.with(|f| f.set(true));
}

pub struct NotesArea {
    stores: Stores,
    pub list: Entity<NotesList>,
    /// The note shown.
    pub note: Option<Entity<NotePane>>,
    /// Notes left that are still saving.
    retiring: Vec<Entity<NotePane>>,
    _subscriptions: Vec<Subscription>,
}

impl NotesArea {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let list = cx.new(|cx| NotesList::new(stores.clone(), window, cx));
        let subscriptions = vec![
            cx.subscribe_in(
                &stores.navigation,
                window,
                |this, _, _: &NavigationEvent, window, cx| this.follow(window, cx),
            ),
            cx.observe(&list, |_, _, cx| cx.notify()),
            // A refused draft left under another account is offered once its
            // own account is back.
            cx.observe_in(&stores.accounts, window, |this, _, window, cx| {
                this.offer_held_drafts(window, cx)
            }),
        ];
        // Quitting saves the note shown first.
        cx.on_app_quit(|this, cx| {
            let pending: Vec<_> = this
                .note
                .iter()
                .chain(this.retiring.iter())
                .map(|pane| pane.update(cx, |p, cx| p.flush(cx)))
                .collect();
            async move {
                let all = futures::future::join_all(pending);
                let _ = futures::future::select(
                    Box::pin(all),
                    Box::pin(smol_timer(Duration::from_secs(3))),
                )
                .await;
            }
        })
        .detach();
        // Quit (⌘Q, the menu) saves what the notes shown and left have not
        // saved yet, and waits for it, before the daemon stops: the quit hook
        // below comes too late for that (the daemon is stopped first).
        let area = cx.weak_entity();
        crate::views::sheet::save_before_quit(cx, move |cx| {
            let area = area.upgrade()?;
            let saves = area.update(cx, |a, cx| a.flush_unsaved(cx));
            (!saves.is_empty()).then(|| {
                Box::pin(async move {
                    futures::future::join_all(saves).await;
                }) as futures::future::LocalBoxFuture<'static, ()>
            })
        });
        let mut this = Self {
            stores,
            list,
            note: None,
            retiring: vec![],
            _subscriptions: subscriptions,
        };
        this.follow(window, cx);
        this
    }

    /// Shows what the navigation store selected.
    fn follow(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let item = self.stores.navigation.read(cx).selected_item().cloned();
        match item {
            Some(AreaItem::Note(id)) => {
                if self.note.as_ref().is_some_and(|p| p.read(cx).shows(&id)) {
                    return;
                }
                self.leave_current(window, cx);
                let focus_body = FOCUS_BODY_NEXT.with(|f| f.replace(false));
                // Left while its save is still out: shown again, rather than
                // a fresh pane reading the stored text from before that save
                // (its own later save would write over it). Only to the
                // account it was opened under: another account (a note shared
                // with both) gets a pane of its own, never these words.
                if let Some(at) = self.retiring.iter().position(|p| {
                    let p = p.read(cx);
                    p.shows(&id) && !p.has_refused_draft() && p.opened_under_active(cx)
                }) {
                    let pane = self.retiring.remove(at);
                    pane.update(cx, |p, cx| p.shown_again(cx));
                    self.note = Some(pane);
                    cx.notify();
                    return;
                }
                let stores = self.stores.clone();
                let pane = cx.new(|cx| NotePane::new(stores, id, focus_body, window, cx));
                let sub =
                    cx.subscribe_in(&pane, window, |this, pane, e: &PaneEvent, window, cx| {
                        this.on_pane(pane.clone(), e, window, cx)
                    });
                self._subscriptions.push(sub);
                self.note = Some(pane);
            }
            Some(AreaItem::AllNotes) => {
                self.leave_current(window, cx);
                self.list.update(cx, |l, cx| l.shown(window, cx));
            }
            _ => self.leave_current(window, cx),
        }
        cx.notify();
    }

    /// The note shown is left: it saves, and stays until it has; a refused
    /// draft asks what to keep.
    fn leave_current(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(pane) = self.note.take() else {
            return;
        };
        let refused = pane.read(cx).refused_draft();
        // Offered only under the draft's own account; held until then.
        if let Some(title) = refused.clone()
            && pane.read(cx).account_active(cx)
        {
            self.ask_about_refused(pane.clone(), title, window, cx);
        }
        let busy = pane.update(cx, |p, cx| {
            p.leave(cx);
            p.is_busy()
        });
        if busy || refused.is_some() {
            self.retiring.push(pane);
        }
    }

    fn on_pane(
        &mut self,
        pane: Entity<NotePane>,
        e: &PaneEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match e {
            PaneEvent::Settled => {
                // A save refused after the note was left: its draft's choices
                // are offered now, as they are when a refused note is left.
                if self.retiring.contains(&pane)
                    && !pane.read(cx).refusal_offered
                    && pane.read(cx).account_active(cx)
                    && let Some(title) = pane.read(cx).refused_draft()
                {
                    self.ask_about_refused(pane.clone(), title, window, cx);
                }
                // A failed save's retry, or a recording or dictation still to
                // come in, keeps the pane until they are done.
                let pane_now = pane.read(cx);
                if !pane_now.has_refused_draft() && !pane_now.is_busy() {
                    self.retiring.retain(|p| p != &pane);
                }
            }
            PaneEvent::Moved { from, to } => {
                let (from, to) = (from.clone(), to.clone());
                self.stores.navigation.update(cx, |n, cx| {
                    n.replace_item(&AreaItem::Note(from), AreaItem::Note(to), cx)
                });
            }
        }
    }

    /// A draft that could not be saved where it was, left behind: keep it
    /// as a note of its own, or go back to it.
    fn ask_about_refused(
        &mut self,
        pane: Entity<NotePane>,
        title: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        pane.update(cx, |p, _| p.refusal_offered = true);
        let l = cx.l10n().clone();
        let spec = SheetSpec::new(
            l.desktop_note_unsaved_title(&title),
            l.desktop_note_unsaved_message(),
            l.note_save_as_own_note(),
            l.desktop_note_show_draft(),
        );
        let ask = present_sheet(window, spec, cx);
        let stores = self.stores.clone();
        cx.spawn_in(window, async move |this, cx| {
            let keep = ask.await;
            let _ = this.update_in(cx, |this, window, cx| {
                // Answered after another account became active: the draft
                // goes nowhere, and is offered again under its own account.
                if !pane.read(cx).account_active(cx) {
                    pane.update(cx, |p, _| p.refusal_offered = false);
                    return;
                }
                if keep {
                    pane.update(cx, |p, cx| p.save_as_own_note(cx));
                } else {
                    // Back to the draft, where Discard Changes is. The note
                    // shown meanwhile is left as any note is (saved, and kept
                    // until it has been).
                    this.retiring.retain(|p| p != &pane);
                    let id = pane.read(cx).note_id().to_string();
                    this.leave_current(window, cx);
                    this.restore(pane, cx);
                    stores
                        .navigation
                        .update(cx, |n, cx| n.open_item(AreaItem::Note(id), cx));
                }
            });
        })
        .detach();
    }

    /// Offers the refused drafts of notes left whose account is active (again).
    fn offer_held_drafts(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let due: Vec<(Entity<NotePane>, String)> = self
            .retiring
            .iter()
            .filter(|p| {
                let p = p.read(cx);
                !p.refusal_offered && p.account_active(cx)
            })
            .filter_map(|p| p.read(cx).refused_draft().map(|t| (p.clone(), t)))
            .collect();
        for (pane, title) in due {
            self.ask_about_refused(pane, title, window, cx);
        }
    }

    /// Shows `pane` again (a refused draft the user went back to).
    fn restore(&mut self, pane: Entity<NotePane>, cx: &mut Context<Self>) {
        self.note = Some(pane);
        cx.notify();
    }

    /// Quit: the note shown and the notes left still saving save what they
    /// have not, and their recordings and dictation finish; one future per
    /// pane that had something to finish.
    fn flush_unsaved(
        &mut self,
        cx: &mut Context<Self>,
    ) -> Vec<impl std::future::Future<Output = ()> + use<>> {
        self.note
            .iter()
            .chain(self.retiring.iter())
            .filter(|pane| {
                let p = pane.read(cx);
                p.dirty(cx) || p.is_busy()
            })
            .cloned()
            .collect::<Vec<_>>()
            .into_iter()
            .map(|pane| pane.update(cx, |p, cx| p.finish_for_quit(cx)))
            .collect()
    }

    /// The note pane shown, if one is.
    pub fn note_pane(&self) -> Option<&Entity<NotePane>> {
        self.note.as_ref()
    }
}

/// A timer that needs no executor of GPUI's (the quit hook's).
async fn smol_timer(after: Duration) {
    let (tx, rx) = futures::channel::oneshot::channel::<()>();
    std::thread::spawn(move || {
        std::thread::sleep(after);
        let _ = tx.send(());
    });
    let _ = rx.await;
}

impl Render for NotesArea {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let item = self.stores.navigation.read(cx).selected_item().cloned();
        match item {
            Some(AreaItem::AllNotes) => self.list.clone().into_any_element(),
            Some(AreaItem::Note(_)) => match &self.note {
                Some(pane) => pane.clone().into_any_element(),
                None => div().into_any_element(),
            },
            _ => div().into_any_element(),
        }
    }
}
