//! The actions under a message, as the phone offers them (mobile's
//! `message_action_settings.dart`, core's `messageActionIds`): Copy, Read
//! Aloud, Regenerate, Retry Without Reasoning Effort, Merge Responses,
//! Usage, Fork Chat, Share and Delete, in that order. A Hermes chat's
//! reply adds Branch from Here and Undo Last Turn after Fork Chat, always
//! in More (core's `messageActionIsOverflowOnly`), and Settings never
//! lists them.
//!
//! Which show as buttons under the answer and which go in its More menu is
//! Settings › Chat › Message Actions: Automatic (the first three that may
//! show inline; Share and Delete always in More) or the user's own set, in
//! their order ([`layout`], the core's `messageActionLayout`). Read Aloud
//! is the main window's (its playback bar sits above the message field).
//!
//! Every action runs through [`run`], from a button (with its window) or
//! from the More menu ([`RunRowCommand`], with the window in front).

use gpui_kit::{App, Pixels, Point, WeakEntity, Window};

use crate::l10n::ActiveL10n as _;
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::chat::{ChatAction, ChatStore};
use crate::views::chat_pane::ChatPane;

/// One message action, by its stable id (core's `messageActionIds`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MessageAction {
    Copy,
    /// Read Aloud, or Stop Speaking while the answer is read.
    ReadAloud,
    Regenerate,
    RetryWithoutEffort,
    /// Merge Responses, or Stop Merging while a merge runs.
    Merge,
    Usage,
    Fork,
    /// A Hermes chat's: a new session with the chat up to this reply.
    BranchFromHere,
    /// A Hermes chat's last reply, on a Desktop Gateway.
    UndoLastTurn,
    Share,
    Delete,
}

impl MessageAction {
    /// Every action Settings lists, in its order (not Hermes's history
    /// actions, which are always in More).
    pub const ALL: [Self; 9] = [
        Self::Copy,
        Self::ReadAloud,
        Self::Regenerate,
        Self::RetryWithoutEffort,
        Self::Merge,
        Self::Usage,
        Self::Fork,
        Self::Share,
        Self::Delete,
    ];

    /// The id the setting stores.
    pub fn id(self) -> &'static str {
        match self {
            Self::Copy => "copy",
            Self::ReadAloud => "tts",
            Self::Regenerate => "regenerate",
            Self::RetryWithoutEffort => "retry-without-effort",
            Self::Merge => "merge",
            Self::Usage => "usage",
            Self::Fork => "fork",
            Self::BranchFromHere => "hermes-branch",
            Self::UndoLastTurn => "hermes-undo",
            Self::Share => "share",
            Self::Delete => "delete",
        }
    }

    /// Share and Delete stay in More unless the user put them inline;
    /// Hermes's history actions, always.
    fn more_only(self) -> bool {
        matches!(
            self,
            Self::Share | Self::Delete | Self::BranchFromHere | Self::UndoLastTurn
        )
    }
}

/// How many actions Automatic shows inline.
pub const AUTOMATIC_INLINE: usize = 3;

/// Splits the actions a message offers (`available`, in [`MessageAction::ALL`]
/// order) into those shown inline and those in More, as the core's
/// `messageActionLayout` does: with no choice saved (`None`), the first
/// three that may show inline, Share and Delete after the rest in More;
/// otherwise the chosen ones in the chosen order, the others in More.
pub fn layout(
    available: &[MessageAction],
    preferred: Option<&[String]>,
) -> (Vec<MessageAction>, Vec<MessageAction>) {
    match preferred {
        None => {
            let (inline_ok, more_only): (Vec<_>, Vec<_>) =
                available.iter().copied().partition(|a| !a.more_only());
            let inline: Vec<_> = inline_ok.iter().copied().take(AUTOMATIC_INLINE).collect();
            let more = inline_ok
                .into_iter()
                .skip(AUTOMATIC_INLINE)
                .chain(more_only)
                .collect();
            (inline, more)
        }
        Some(ids) => {
            let mut seen = std::collections::HashSet::new();
            let inline: Vec<_> = ids
                .iter()
                .filter(|id| seen.insert(id.as_str()))
                .filter_map(|id| available.iter().copied().find(|a| a.id() == id))
                .collect();
            let more = available
                .iter()
                .copied()
                .filter(|a| !inline.contains(a))
                .collect();
            (inline, more)
        }
    }
}

/// What a message action does, with what it needs.
#[derive(Clone, Debug, PartialEq)]
pub enum RowCommand {
    Copy(String),
    /// Runs the answer again, with this model (Regenerate With) or the
    /// one it was written with.
    Regenerate(Option<String>),
    RetryWithoutEffort,
    Merge,
    StopMerge,
    Usage,
    Fork,
    /// Branch from Here (a Hermes chat).
    BranchFromHere,
    /// Undo Last Turn (a Hermes chat on a Desktop Gateway).
    UndoLastTurn,
    Share(String),
    Delete,
    /// Read Aloud, or Stop Speaking (resume, when paused) for this answer.
    ReadAloud,
    /// Continue from This Response: another answer becomes the chat's.
    ContinueFrom(String),
    /// The version list (a popover at the `n / N` label).
    Versions,
}

/// The message an action is for, and where it was asked.
#[derive(Clone, Debug, PartialEq)]
pub struct RowContext {
    pub store: WeakEntity<ChatStore>,
    /// The chat pane, for what opens a chat or a sheet (none in Quick Ask).
    pub pane: Option<WeakEntity<ChatPane>>,
    /// The message (its row's message id).
    pub key: String,
    /// The answer shown in it (a version's id while another is shown).
    pub target: String,
    /// Merge Responses' answers.
    pub mergeable: Vec<String>,
    /// Where the click was (a popover or the Share menu hangs there).
    pub position: Point<Pixels>,
}

/// A message action chosen from a native menu.
#[derive(Clone, Debug, PartialEq, gpui_kit::Action)]
#[action(namespace = conduit_chat, no_json)]
pub struct RunRowCommand {
    pub ctx: RowContext,
    pub command: RowCommand,
}

/// Registers the menu action: it runs in the window in front.
pub fn register(cx: &mut App) {
    cx.on_action(|a: &RunRowCommand, cx: &mut App| {
        let (ctx, command) = (a.ctx.clone(), a.command.clone());
        match cx.active_window() {
            Some(window) => {
                let _ = window.update(cx, move |_, window, cx| run(ctx, command, window, cx));
            }
            None => log::warn!("{command:?}: no window in front"),
        }
    });
}

/// Carries out `command` on `ctx`'s message.
pub fn run(ctx: RowContext, command: RowCommand, window: &mut Window, cx: &mut App) {
    let store = ctx.store.clone();
    match command {
        RowCommand::Copy(text) => {
            cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(text));
            if let Some(p) = &ctx.pane {
                let _ = p.update(cx, |p, cx| p.notify_copied(cx));
            }
        }
        RowCommand::Regenerate(model) => {
            let _ = store.update(cx, |s, cx| s.regenerate(&ctx.key, model, cx));
        }
        RowCommand::RetryWithoutEffort => {
            let _ = store.update(cx, |s, cx| s.regenerate_with(&ctx.key, None, true, cx));
        }
        RowCommand::Merge => {
            let sources = ctx.mergeable.clone();
            let _ = store.update(cx, |s, cx| s.merge(&ctx.key, &ctx.target, sources, cx));
        }
        RowCommand::StopMerge => {
            let _ = store.update(cx, |s, cx| s.stop_merge(cx));
        }
        RowCommand::Usage => {
            crate::views::chat::transcript::show_row_popover(
                crate::views::chat::transcript::RowPopoverKind::Usage,
                ctx.key.clone(),
                ctx.position,
                cx,
            );
        }
        RowCommand::Versions => {
            crate::views::chat::transcript::show_row_popover(
                crate::views::chat::transcript::RowPopoverKind::Versions,
                ctx.key.clone(),
                ctx.position,
                cx,
            );
        }
        RowCommand::Fork => {
            let Some(pane) = ctx.pane.clone() else {
                return;
            };
            let task = store.update(cx, |s, cx| s.fork(&ctx.target, cx));
            let Ok(task) = task else {
                return;
            };
            cx.spawn(async move |cx| {
                if let Some(forked) = task.await {
                    let _ = pane.update(cx, |p, cx| p.open_forked(forked.chat_id, cx));
                }
            })
            .detach();
        }
        RowCommand::Share(text) => {
            crate::shell::share::share(
                crate::shell::share::Shared::Text(text),
                ctx.position,
                window,
                cx,
            );
        }
        RowCommand::Delete => confirm_delete(ctx, window, cx),
        history @ (RowCommand::BranchFromHere | RowCommand::UndoLastTurn) => {
            let Some(chat_id) = store.upgrade().map(|s| s.read(cx).chat_id().to_string()) else {
                return;
            };
            let Some(stores) = cx.try_global::<crate::AppState>().map(|s| s.stores.clone()) else {
                return;
            };
            if history == RowCommand::UndoLastTurn {
                crate::views::hermes_sessions::undo(&stores, &chat_id, cx);
            } else {
                crate::views::hermes_sessions::branch(&stores, &chat_id, &ctx.key, cx);
            }
        }
        RowCommand::ReadAloud => {
            let Some(chat_id) = store.upgrade().map(|s| s.read(cx).chat_id().to_string()) else {
                return;
            };
            if let Some(speech) = cx
                .try_global::<crate::AppState>()
                .map(|s| s.stores.speech.clone())
            {
                speech.update(cx, |s, cx| s.toggle(chat_id, ctx.target.clone(), cx));
            }
        }
        RowCommand::ContinueFrom(answer) => {
            let _ = store.update(cx, |s, cx| {
                s.set_current(&answer, Some(&ctx.key), cx).detach();
            });
        }
    }
}

/// Delete…: says how many messages go (a question takes its answers with
/// it), then deletes them.
fn confirm_delete(ctx: RowContext, window: &mut Window, cx: &mut App) {
    let ids = vec![ctx.key.clone()];
    let Ok(count) = ctx
        .store
        .update(cx, |s, cx| s.delete_count(ids.clone(), cx))
    else {
        return;
    };
    let handle = window.window_handle();
    let store = ctx.store.clone();
    cx.spawn(async move |cx| {
        let count = match count.await {
            Ok(n) if n > 0 => n,
            Ok(_) => return,
            // Not counted (an answer running, the server away): nothing is
            // asked or deleted on a guess of how much goes.
            Err(e) => {
                log::warn!("messages.delete (count): {e}");
                let _ = store.update(cx, |s, cx| s.failed(ChatAction::Delete, &e, cx));
                return;
            }
        };
        let asked = handle.update(cx, |_, window, cx| {
            let l10n = cx.l10n().clone();
            let spec = SheetSpec::new(
                l10n.delete_messages_title(),
                l10n.delete_messages_message(count),
                l10n.delete(),
                l10n.cancel(),
            )
            .destructive();
            present_sheet(window, spec, cx)
        });
        let Ok(asked) = asked else {
            return;
        };
        if asked.await {
            let _ = ctx
                .store
                .update(cx, |s, cx| s.delete_messages(ids.clone(), cx));
        }
    })
    .detach();
}

#[cfg(test)]
mod tests {
    use super::MessageAction::*;
    use super::*;

    fn ids(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    /// The same cases as the core's `messageActionLayout` test.
    #[test]
    fn automatic_shows_the_first_three_and_keeps_share_and_delete_in_more() {
        let all = [Copy, Regenerate, Usage, Fork, Share, Delete];
        let (inline, more) = layout(&all, None);
        assert_eq!(inline, vec![Copy, Regenerate, Usage]);
        assert_eq!(more, vec![Fork, Share, Delete]);
        // Fewer than three that may show inline: Share and Delete still wait.
        let (inline, more) = layout(&[Copy, Share, Delete], None);
        assert_eq!(inline, vec![Copy]);
        assert_eq!(more, vec![Share, Delete]);
    }

    #[test]
    fn a_saved_choice_shows_those_in_its_order_and_the_rest_in_more() {
        let all = [Copy, Regenerate, Usage, Fork, Share, Delete];
        let (inline, more) = layout(&all, Some(&ids(&["delete", "copy", "tts", "copy"])));
        // An action not offered is not shown; a repeat counts once.
        assert_eq!(inline, vec![Delete, Copy]);
        assert_eq!(more, vec![Regenerate, Usage, Fork, Share]);
        // An empty choice puts every action in More.
        let (inline, more) = layout(&all, Some(&[]));
        assert!(inline.is_empty());
        assert_eq!(more, all.to_vec());
    }

    #[test]
    fn hermes_history_actions_are_always_in_more() {
        let all = [Copy, Regenerate, Usage, BranchFromHere, UndoLastTurn, Share];
        let (inline, more) = layout(&all, None);
        assert_eq!(inline, vec![Copy, Regenerate, Usage]);
        assert_eq!(more, vec![BranchFromHere, UndoLastTurn, Share]);
        // Settings never lists them, so a saved choice leaves them in More.
        let (inline, more) = layout(&all, Some(&ids(&["copy", "usage"])));
        assert_eq!(inline, vec![Copy, Usage]);
        assert_eq!(more, vec![Regenerate, BranchFromHere, UndoLastTurn, Share]);
    }

    #[test]
    fn the_ids_are_cores() {
        let got: Vec<_> = MessageAction::ALL.iter().map(|a| a.id()).collect();
        assert_eq!(
            got,
            [
                "copy",
                "tts",
                "regenerate",
                "retry-without-effort",
                "merge",
                "usage",
                "fork",
                "share",
                "delete"
            ]
        );
    }
}
