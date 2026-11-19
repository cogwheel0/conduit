//! The Branches sheet: every message of the chat on every branch
//! (`chats.tree`), as an outline. The branch the transcript shows is marked;
//! choosing any message makes the branch through it the chat's on the
//! server (`chats.setCurrent`), down to where that line of conversation
//! ended, and closes the sheet. ↑ and ↓ move, Return chooses.

use std::collections::{HashMap, HashSet};

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::views::kit::Button;
use conduit_protocol::{ChatTree, ChatTreeNode};
use gpui_kit::prelude::*;
use gpui_kit::{
    App, Context, ElementId, FocusHandle, Focusable, FontWeight, Role, ScrollHandle, SharedString,
    WeakEntity, Window, div, px,
};

use super::popovers::one_line;
use crate::l10n::ActiveL10n as _;
use crate::stores::chat::ChatStore;

/// The sheet's size: wide enough for a long line, tall enough for a dozen.
pub const WIDTH: f32 = 560.;
pub const HEIGHT: f32 = 520.;

/// One line of the outline.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Line {
    pub id: String,
    pub depth: usize,
    pub user: bool,
    pub preview: String,
    pub model: Option<String>,
    /// On the branch the transcript shows.
    pub current: bool,
    /// Where it forks: it has more than one reply.
    pub forks: bool,
}

/// `tree` as an outline, depth first in the server's order, children
/// indented under their parent. A run of single replies stays at one depth
/// (a conversation reads down the page); only where a message has several
/// replies do they step in. A parent cycle or an orphan does not loop.
pub fn outline(tree: &ChatTree) -> Vec<Line> {
    let ids: HashSet<&str> = tree.nodes.iter().map(|n| n.id.as_str()).collect();
    let mut children: HashMap<Option<&str>, Vec<&ChatTreeNode>> = HashMap::new();
    for n in &tree.nodes {
        let parent = n.parent_id.as_deref().filter(|p| ids.contains(p));
        children.entry(parent).or_default().push(n);
    }
    for list in children.values_mut() {
        list.sort_by_key(|n| n.timestamp_ms);
    }
    // The current path: the current leaf and its ancestors.
    let by_id: HashMap<&str, &ChatTreeNode> =
        tree.nodes.iter().map(|n| (n.id.as_str(), n)).collect();
    let mut current = HashSet::new();
    let mut at = tree.current_id.as_deref();
    while let Some(id) = at {
        if !current.insert(id.to_string()) {
            break;
        }
        at = by_id.get(id).and_then(|n| n.parent_id.as_deref());
    }
    let mut out = vec![];
    let mut seen = HashSet::new();
    // (node, depth), last child pushed first so the first is drawn first.
    let mut stack: Vec<(&ChatTreeNode, usize)> = children
        .get(&None)
        .map(|roots| {
            let deep = usize::from(roots.len() > 1);
            roots.iter().rev().map(|n| (*n, deep)).collect()
        })
        .unwrap_or_default();
    while let Some((n, depth)) = stack.pop() {
        if !seen.insert(n.id.as_str()) {
            continue;
        }
        let kids = children
            .get(&Some(n.id.as_str()))
            .cloned()
            .unwrap_or_default();
        out.push(Line {
            id: n.id.clone(),
            depth,
            user: n.role == "user",
            preview: one_line(&n.preview, 140),
            model: n.model.clone(),
            current: current.contains(&n.id),
            forks: kids.len() > 1,
        });
        let next = depth + usize::from(kids.len() > 1);
        for k in kids.into_iter().rev() {
            stack.push((k, next));
        }
    }
    out
}

pub struct BranchesSheet {
    store: WeakEntity<ChatStore>,
    lines: Option<Vec<Line>>,
    failed: bool,
    /// The line ↑ and ↓ are on.
    cursor: usize,
    focus: FocusHandle,
    scroll: ScrollHandle,
    names: HashMap<String, String>,
}

impl BranchesSheet {
    pub fn new(
        store: WeakEntity<ChatStore>,
        tree: gpui_kit::Task<Result<ChatTree, conduit_daemon::RpcError>>,
        names: HashMap<String, String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        cx.spawn(async move |this, cx| {
            let result = tree.await;
            let _ = this.update(cx, |s: &mut Self, cx| {
                match result {
                    Ok(tree) => {
                        let lines = outline(&tree);
                        s.cursor = lines.iter().rposition(|l| l.current).unwrap_or(0);
                        s.lines = Some(lines);
                    }
                    Err(e) => {
                        log::warn!("chats.tree: {e}");
                        s.failed = true;
                    }
                }
                cx.notify();
            });
        })
        .detach();
        Self {
            store,
            lines: None,
            failed: false,
            cursor: 0,
            focus,
            scroll: ScrollHandle::new(),
            names,
        }
    }

    /// The outline once loaded (the E2E pass reads it).
    pub fn lines(&self) -> Option<&[Line]> {
        self.lines.as_deref()
    }

    /// Makes the branch through `id` the chat's, and closes the sheet.
    pub fn choose(&mut self, id: &str, cx: &mut Context<Self>) {
        let id = id.to_string();
        let _ = self
            .store
            .update(cx, |s, cx| s.set_current(&id, None, cx).detach());
        cx.defer(super::sheets::close);
    }

    fn step(&mut self, delta: isize, cx: &mut Context<Self>) {
        let Some(lines) = &self.lines else {
            return;
        };
        if lines.is_empty() {
            return;
        }
        let next = (self.cursor as isize + delta).clamp(0, lines.len() as isize - 1) as usize;
        if next != self.cursor {
            self.cursor = next;
            self.scroll.scroll_to_item(next);
            cx.notify();
        }
    }
}

impl Focusable for BranchesSheet {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for BranchesSheet {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        let (r, m) = (t.roles, t.metrics);
        let weak = cx.entity().downgrade();
        let body = match &self.lines {
            None if self.failed => div()
                .text_size(px(m.control))
                .text_color(r.text_subtle)
                .child(SharedString::from(l10n.desktop_branches_failed()))
                .into_any_element(),
            None => div()
                .text_size(px(m.control))
                .text_color(r.text_subtle)
                .child(SharedString::from(l10n.desktop_loading()))
                .into_any_element(),
            Some(lines) => div()
                .id("branches-list")
                .role(Role::Tree)
                .aria_label(SharedString::from(l10n.desktop_branches_title()))
                .track_scroll(&self.scroll)
                .overflow_y_scroll()
                .size_full()
                .rounded(t.card_radius())
                .border_1()
                .border_color(r.border)
                .bg(r.content)
                .py(px(4.))
                .children(lines.iter().enumerate().map(|(i, line)| {
                    let who = if line.user {
                        l10n.you()
                    } else {
                        line.model
                            .as_ref()
                            .map(|m| self.names.get(m).cloned().unwrap_or(m.clone()))
                            .unwrap_or_default()
                    };
                    let spoken = if line.current {
                        format!(
                            "{who}: {}. {}",
                            line.preview,
                            l10n.desktop_branches_current()
                        )
                    } else {
                        format!("{who}: {}", line.preview)
                    };
                    let choose = weak.clone();
                    let id = line.id.clone();
                    let on_cursor = i == self.cursor;
                    div()
                        .id(ElementId::Name(format!("branch-{}", line.id).into()))
                        .role(Role::TreeItem)
                        .aria_label(SharedString::from(spoken))
                        .aria_selected(on_cursor)
                        .aria_level(line.depth + 1)
                        .min_h(px(m.row_height))
                        .pl(px(10. + 16. * line.depth as f32))
                        .pr(px(10.))
                        .py(px(3.))
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .cursor_pointer()
                        .when(on_cursor, |d| d.bg(r.selected))
                        .hover(|s| s.bg(r.hover))
                        .child(icon(
                            if line.user {
                                IconName::User
                            } else {
                                IconName::Sparkles
                            },
                            13.,
                            if line.current { r.text } else { r.text_faint },
                        ))
                        .child(
                            div()
                                .flex_none()
                                .max_w(px(120.))
                                .truncate()
                                .text_size(px(m.small))
                                .text_color(r.text_subtle)
                                .child(SharedString::from(who)),
                        )
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .truncate()
                                .text_size(px(m.control))
                                .when(line.current, |d| d.font_weight(FontWeight::MEDIUM))
                                .text_color(if line.current { r.text } else { r.text_subtle })
                                .child(SharedString::from(line.preview.clone())),
                        )
                        .when(line.forks, |d| {
                            d.child(icon(IconName::GitBranch, 12., r.text_faint))
                        })
                        .on_click(move |_, _, cx| {
                            let _ = choose.update(cx, |s, cx| s.choose(&id, cx));
                        })
                }))
                .into_any_element(),
        };
        let done = Button::new("branches-done", l10n.done())
            .primary()
            .on_click(std::rc::Rc::new(|_, _, cx| super::sheets::close(cx)))
            .into_any_element();
        let keys = weak.clone();
        super::sheets::frame(
            "branches-sheet",
            l10n.desktop_branches_title(),
            Some(l10n.desktop_branches_description()),
            body,
            vec![done],
            super::sheets::close,
            &t,
        )
        .track_focus(&self.focus)
        .on_key_down(move |e: &gpui_kit::KeyDownEvent, _, cx| {
            let key = e.keystroke.key.as_str();
            let _ = keys.update(cx, |s, cx| match key {
                "up" => s.step(-1, cx),
                "down" => s.step(1, cx),
                "enter" => {
                    if let Some(id) = s
                        .lines
                        .as_ref()
                        .and_then(|l| l.get(s.cursor))
                        .map(|l| l.id.clone())
                    {
                        s.choose(&id, cx);
                    }
                }
                _ => {}
            });
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(id: &str, parent: Option<&str>, role: &str, at: i64) -> ChatTreeNode {
        ChatTreeNode {
            id: id.into(),
            parent_id: parent.map(Into::into),
            role: role.into(),
            preview: format!("text of {id}"),
            timestamp_ms: at,
            model: (role == "assistant").then(|| "fake-model".into()),
        }
    }

    #[test]
    fn single_replies_read_down_and_forks_step_in() {
        // q1 → a1 → q2 → (a2, a2b), and a1 regenerated as a1b.
        let tree = ChatTree {
            chat_id: "c".into(),
            nodes: vec![
                node("q1", None, "user", 1),
                node("a1", Some("q1"), "assistant", 2),
                node("q2", Some("a1"), "user", 3),
                node("a2", Some("q2"), "assistant", 4),
                node("a2b", Some("q2"), "assistant", 5),
                node("a1b", Some("q1"), "assistant", 6),
            ],
            current_id: Some("a2b".into()),
        };
        let got: Vec<_> = outline(&tree)
            .iter()
            .map(|l| (l.id.clone(), l.depth, l.current, l.forks))
            .collect();
        assert_eq!(
            got,
            vec![
                ("q1".to_string(), 0, true, true),
                ("a1".to_string(), 1, true, false),
                ("q2".to_string(), 1, true, true),
                ("a2".to_string(), 2, false, false),
                ("a2b".to_string(), 2, true, false),
                ("a1b".to_string(), 1, false, false),
            ]
        );
    }

    #[test]
    fn a_cycle_or_an_orphan_does_not_loop() {
        let tree = ChatTree {
            chat_id: "c".into(),
            nodes: vec![
                node("a", Some("b"), "user", 1),
                node("b", Some("a"), "assistant", 2),
                node("lost", Some("gone"), "user", 3),
            ],
            current_id: Some("a".into()),
        };
        // Only the orphan is a root (its parent is missing); the cycle has
        // none, so it is not drawn rather than drawn forever.
        let ids: Vec<_> = outline(&tree).into_iter().map(|l| l.id).collect();
        assert_eq!(ids, vec!["lost".to_string()]);
    }
}
