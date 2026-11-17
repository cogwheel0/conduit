//! How the note editor draws: its document as GPUI Kit's block tree, one
//! leaf key per block, inside [`EditorElement`], which collects where each
//! leaf was laid out, scrolls the caret into view, paints the caret and
//! IME's underline, takes the mouse, and hands the platform its input
//! handler.
//!
//! * **Blocks.** A paragraph, heading or code block is one Kit node; the
//!   lines of a quote are one blockquote; list items are Kit lists, nested
//!   by indent, a checklist item with Kit's checkbox. A paragraph that only
//!   links a server file is a card ([`file_card`]) instead.
//! * **Painted behind the text** (Kit's decorations): the selection, Find's
//!   matches (the current one darker) and IME's marked text.

use std::cell::RefCell;
use std::collections::HashMap;
use std::ops::Range;
use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{ConduitTheme, with_alpha};
use conduit_components::views::kit::IconButton;
use gpui_kit::base::text::editor_host::{
    self, BlockNode, CodeBlock, FlowPosition, InlineNode, LinkMark, Paragraph, RenderContext, Span,
    TextMark,
};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Bounds, Context, DispatchPhase, Element, ElementId, ElementInputHandler,
    Entity, FontWeight, GlobalElementId, Hitbox, HitboxBehavior, Hsla, InspectorElementId,
    LayoutId, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, Pixels, Role,
    SharedString, Window, div, fill, point, px, size,
};

use super::doc::{Block, BlockKind, FileLink, Marks, Pos};
use super::editor::{EDITOR_CONTEXT, EditorEvent, FileAction, Layout, NoteEditor};

/// How far the caret stays from the visible area's edges when it scrolls
/// into view.
const REVEAL_MARGIN: f32 = 24.;

impl Render for NoteEditor {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let focused = self.focus.is_focused(window);
        let body = t.metrics.body + 1.;
        let rcx = RenderContext::from_app(cx)
            .with_body_font_size(px(body))
            // A click on a link puts the caret in it; ⌘-click opens it
            // (handled with the press, in `NoteEditor::mouse_down`).
            .on_link_click(|_, _, _, _| {});
        let elements = self.block_elements(&rcx, &t, window, cx);
        let decorations = self.decorations(&t, focused);
        let caret = (focused && self.caret_on && !self.is_read_only())
            .then(|| self.selection().head)
            .filter(|_| self.selection().is_empty());
        let marked = self.marked();
        let reveal = std::mem::take(&mut self.reveal);
        let empty = self.doc.is_empty();
        let placeholder = self.placeholder.clone();
        let text: SharedString = self.doc.plain_text().into();
        let entity = cx.entity();

        let content = div()
            .relative()
            .w_full()
            .flex()
            .flex_col()
            .text_size(px(body))
            .text_color(t.roles.text)
            .children(elements)
            .when(empty && !self.is_read_only(), |d| {
                d.child(
                    div()
                        .absolute()
                        .top_0()
                        .left_0()
                        .text_color(t.roles.text_faint)
                        .child(placeholder),
                )
            });
        let element = EditorElement {
            editor: entity,
            child: Some(content.into_any_element()),
            layout: self.layout.clone(),
            decorations,
            caret,
            caret_color: t.roles.text,
            marked,
            reveal,
            head: self.selection().head,
            head_block: self.doc.blocks[self.selection().head.block].id,
            scroll: self.scroll.clone(),
            focus: self.focus.clone(),
        };
        let root = div()
            .id("note-editor")
            .key_context(EDITOR_CONTEXT)
            .track_focus(&self.focus)
            .role(Role::MultilineTextInput)
            .aria_label(self.label.clone())
            .aria_value(text)
            .cursor_text()
            .w_full()
            .min_h(px(240.))
            .pb(px(120.))
            .child(element);
        bind_actions(root, cx)
    }
}

macro_rules! bind_all {
    ($el:expr, $cx:expr, [$($action:ident),* $(,)?]) => {
        $el$(.on_action($cx.listener(|e: &mut NoteEditor, a: &$action, _, cx| {
            e.on_actions(a, cx);
        })))*
    };
}

/// Every editing action, on the editor's root.
fn bind_actions(
    root: gpui_kit::Stateful<gpui_kit::Div>,
    cx: &mut Context<NoteEditor>,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    use super::editor::*;
    bind_all!(
        root,
        cx,
        [
            MoveLeft,
            MoveRight,
            MoveUp,
            MoveDown,
            MoveWordLeft,
            MoveWordRight,
            MoveLineStart,
            MoveLineEnd,
            MoveDocStart,
            MoveDocEnd,
            PageUp,
            PageDown,
            SelectLeft,
            SelectRight,
            SelectUp,
            SelectDown,
            SelectWordLeft,
            SelectWordRight,
            SelectLineStart,
            SelectLineEnd,
            SelectDocStart,
            SelectDocEnd,
            SelectAll,
            Backspace,
            Delete,
            DeleteWordLeft,
            DeleteWordRight,
            DeleteLineLeft,
            Newline,
            Indent,
            Outdent,
            Copy,
            Cut,
            Paste,
            PastePlain,
            Undo,
            Redo,
            ToggleBold,
            ToggleItalic,
            ToggleStrike,
            ToggleCode,
            AddLink,
            Title,
            Heading,
            Subheading,
            Body,
            BulletList,
            NumberedList,
            Checklist,
            ToggleChecked,
            QuoteBlock,
            CodeBlock,
        ]
    )
}

impl NoteEditor {
    /// The document as elements: Kit nodes and file cards, in order.
    fn block_elements(
        &mut self,
        rcx: &RenderContext,
        t: &ConduitTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let groups = group_blocks(&self.doc.blocks);
        let nodes: Vec<BlockNode> = groups
            .iter()
            .map(|g| match g {
                Group::Card(_) => BlockNode::Paragraph(Paragraph::default()),
                Group::Nodes { node, .. } => node.clone(),
            })
            .collect();
        let refs: Vec<&BlockNode> = nodes.iter().collect();
        let selection = self.selection();
        let (start, end) = (selection.start(), selection.end());
        let mut out = Vec::with_capacity(groups.len());
        for (ix, group) in groups.into_iter().enumerate() {
            match group {
                Group::Card(i) => {
                    let block = &self.doc.blocks[i];
                    let link = block.file_link().unwrap_or(FileLink {
                        id: String::new(),
                        name: block.text.clone(),
                    });
                    let selected = !selection.is_empty() && start.block <= i && i <= end.block;
                    out.push(file_card(block.id, link, selected, self, t, cx));
                }
                Group::Nodes { id, node } => {
                    let flow = FlowPosition::at(&refs, ix, ix + 1 == refs.len());
                    out.push(node.render_with_id(("note-block", id), flow, rcx, window, cx));
                }
            }
        }
        out
    }

    /// What Kit paints behind each leaf's text: the selection, Find's
    /// matches, IME's marked text.
    fn decorations(
        &self,
        t: &ConduitTheme,
        focused: bool,
    ) -> HashMap<u64, Vec<(Range<usize>, Hsla)>> {
        let mut out: HashMap<u64, Vec<(Range<usize>, Hsla)>> = HashMap::new();
        let (match_fill, current_fill) = super::find_fills(t);
        for (i, (a, b)) in self.find.matches.iter().enumerate() {
            let fill = if i == self.find.current {
                current_fill
            } else {
                match_fill
            };
            out.entry(self.doc.blocks[a.block].id)
                .or_default()
                .push((a.offset..b.offset, fill));
        }
        let s = self.selection();
        if !s.is_empty() {
            let fill = if focused {
                t.roles.text_selection
            } else {
                with_alpha(t.roles.text, if t.dark { 0.18 } else { 0.1 })
            };
            for (block, range) in self.doc.ranges(s.start(), s.end()) {
                out.entry(self.doc.blocks[block].id)
                    .or_default()
                    .push((range, fill));
            }
        }
        if let Some((a, b)) = self.marked() {
            let fill = with_alpha(t.roles.text, 0.08);
            for (block, range) in self.doc.ranges(a, b) {
                out.entry(self.doc.blocks[block].id)
                    .or_default()
                    .push((range, fill));
            }
        }
        out
    }
}

/// A run of the document drawn as one piece.
enum Group {
    /// Kit nodes: the id of the first block they hold, and the node.
    Nodes { id: u64, node: BlockNode },
    /// The card of block `usize`.
    Card(usize),
}

/// The document's blocks as Kit's block tree: one node per paragraph,
/// heading and code block, one blockquote per run of quote lines, one list
/// (nested by indent) per run of list items.
fn group_blocks(blocks: &[Block]) -> Vec<Group> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < blocks.len() {
        let block = &blocks[i];
        if block.file_link().is_some() {
            out.push(Group::Card(i));
            i += 1;
            continue;
        }
        match block.kind {
            BlockKind::Quote => {
                let mut children = vec![];
                let first = block.id;
                while i < blocks.len() && blocks[i].kind == BlockKind::Quote {
                    children.push(BlockNode::Paragraph(paragraph(&blocks[i])));
                    i += 1;
                }
                out.push(Group::Nodes {
                    id: first,
                    node: BlockNode::Blockquote {
                        children,
                        span: None,
                    },
                });
            }
            kind if kind.is_list() => {
                let first = block.id;
                let from = i;
                while i < blocks.len() && blocks[i].kind.is_list() {
                    i += 1;
                }
                let items: Vec<&Block> = blocks[from..i].iter().collect();
                let lists = lists(&items, 0);
                // Several lists side by side (a bulleted run, then a
                // numbered one) are one group with one identity.
                let node = if lists.len() == 1 {
                    lists.into_iter().next().unwrap_or(BlockNode::Unknown)
                } else {
                    BlockNode::Root {
                        children: lists,
                        span: None,
                    }
                };
                out.push(Group::Nodes { id: first, node });
            }
            _ => {
                out.push(Group::Nodes {
                    id: block.id,
                    node: single(block),
                });
                i += 1;
            }
        }
    }
    out
}

/// One paragraph, heading or code block.
fn single(block: &Block) -> BlockNode {
    match block.kind {
        BlockKind::Heading(level) => BlockNode::Heading {
            level,
            children: paragraph(block),
            span: None,
        },
        BlockKind::Code => BlockNode::CodeBlock(
            CodeBlock::new(block.text.clone().into(), None, None::<Span>).with_leaf_key(block.id),
        ),
        _ => BlockNode::Paragraph(paragraph(block)),
    }
}

/// `items` (list items, the first at `level` or deeper) as Kit lists: a
/// list per run of one style at `level`, each item holding the deeper
/// items after it as its own nested lists. A deeper item with no parent
/// starts the run.
fn lists(items: &[&Block], level: u8) -> Vec<BlockNode> {
    let mut out = vec![];
    let mut i = 0;
    while i < items.len() {
        let kind = items[i].kind;
        let mut children = vec![];
        while i < items.len() {
            let item = items[i];
            if !children.is_empty() && !item.kind.same_style(kind) {
                break;
            }
            i += 1;
            let from = i;
            while i < items.len() && items[i].indent > level {
                i += 1;
            }
            let mut body = vec![BlockNode::Paragraph(paragraph(item))];
            body.extend(lists(&items[from..i], level + 1));
            children.push(BlockNode::ListItem {
                children: body,
                spread: false,
                checked: match item.kind {
                    BlockKind::Check(c) => Some(c),
                    _ => None,
                },
                span: None,
            });
        }
        out.push(BlockNode::List {
            children,
            ordered: kind == BlockKind::Ordered,
            start: None,
            span: None,
        });
    }
    out
}

/// A block's text with its marks, keyed for the editor.
fn paragraph(block: &Block) -> Paragraph {
    let mut p = Paragraph::default();
    let marks: Vec<(Range<usize>, TextMark)> = block
        .spans()
        .into_iter()
        .filter(|(_, m)| !m.is_plain())
        .map(|(range, m)| (range, text_mark(m)))
        .collect();
    p.push(InlineNode::new(block.text.clone()).marks(marks));
    p.with_leaf_key(block.id)
}

fn text_mark(m: &Marks) -> TextMark {
    TextMark {
        bold: m.bold,
        italic: m.italic,
        strikethrough: m.strike,
        underline: m.underline,
        code: m.code,
        highlight: None,
        link: m.link.as_ref().map(|url| LinkMark {
            url: url.clone().into(),
            identifier: None,
            title: None,
        }),
    }
}

/// Whether `name` is a recording (it plays, and can be transcribed).
pub fn is_audio(name: &str) -> bool {
    let lower = name.to_lowercase();
    [
        ".wav", ".m4a", ".mp3", ".aac", ".ogg", ".oga", ".flac", ".webm", ".caf",
    ]
    .iter()
    .any(|ext| lower.ends_with(ext))
}

/// A file the note attaches, as a card: its kind's glyph, its name, and
/// its actions (Quick Look, Download, Transcribe for a recording, Remove).
/// A recording plays in the card instead of in Quick Look: Play or Pause
/// leads it, and once it is held its scrubber and time stand under its
/// name ([`super::audio`]).
fn file_card(
    id: u64,
    link: FileLink,
    selected: bool,
    editor: &NoteEditor,
    t: &ConduitTheme,
    cx: &mut Context<NoteEditor>,
) -> AnyElement {
    let r = t.roles;
    let audio = is_audio(&link.name);
    let labels = editor.card_labels.clone();
    let kind = if audio {
        labels.audio.clone()
    } else {
        labels.file.clone()
    };
    let entity = cx.entity().downgrade();
    let action = |what: FileAction| {
        let entity = entity.clone();
        let link = link.clone();
        Rc::new(
            move |_: &gpui_kit::ClickEvent, _: &mut Window, cx: &mut App| {
                let link = link.clone();
                entity
                    .update(cx, |_, cx| cx.emit(EditorEvent::File(link, what)))
                    .ok();
            },
        )
    };
    // A control inside the card: its own action only, never the card's
    // too (the click would reach the card after the control).
    let control = |what: FileAction| {
        let run = action(what);
        Rc::new(
            move |e: &gpui_kit::ClickEvent, window: &mut Window, cx: &mut App| {
                cx.stop_propagation();
                run(e, window, cx);
            },
        )
    };
    let read_only = editor.is_read_only();
    let name: SharedString = link.name.clone().into();
    let player = if audio {
        editor
            .audio
            .as_ref()
            .and_then(|a| a.read(cx).state(&link.id).map(|s| (a.clone(), s)))
    } else {
        None
    };
    let playing = player.as_ref().is_some_and(|(_, s)| s.playing);
    let words = super::audio::PlayerWords {
        play: labels.play.clone(),
        pause: labels.pause.clone(),
        position: labels.position.clone(),
        failed: labels.audio_failed.clone(),
        loading: labels.audio_loading.clone(),
    };
    let second_line: AnyElement = match &player {
        Some((a, state)) => super::audio::progress(
            &format!("note-audio-{}", link.id),
            &link.id,
            *state,
            a,
            &words,
            t,
        ),
        None => div()
            .text_size(px(t.metrics.small))
            .text_color(r.text_subtle)
            .child(kind.clone())
            .into_any_element(),
    };
    let button = |key: &str, glyph: IconName, label: SharedString, what: FileAction| {
        IconButton::new(
            SharedString::from(format!("note-file-{key}-{}", link.id)),
            glyph,
            label,
        )
        .size(26., 14.)
        .on_click(control(what))
    };
    div()
        .id(ElementId::NamedInteger("note-file".into(), id))
        .debug_selector({
            let id = link.id.clone();
            move || format!("note-file-{id}")
        })
        .role(Role::Group)
        .aria_label(SharedString::from(format!("{}, {}", link.name, kind)))
        .my(px(6.))
        .w_full()
        .max_w(px(520.))
        .flex()
        .items_center()
        .gap(px(10.))
        .px(px(10.))
        .py(px(8.))
        .rounded(px(10.))
        .border_1()
        .border_color(if selected { r.text_subtle } else { r.border })
        .bg(if selected {
            r.text_selection
        } else {
            conduit_components::views::kit::raised_fill(t)
        })
        .cursor_default()
        // Presses on the card are the card's, not the text's.
        .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
        .on_click({
            let open = action(if audio {
                FileAction::Play
            } else {
                FileAction::QuickLook
            });
            move |e, window, cx| open(e, window, cx)
        })
        .child(if audio {
            let label = if playing {
                words.pause.clone()
            } else {
                words.play.clone()
            };
            IconButton::new(
                SharedString::from(format!("note-file-play-{}", link.id)),
                if playing {
                    IconName::Pause
                } else {
                    IconName::Play
                },
                label.clone(),
            )
            .size(28., 14.)
            .tooltip(label)
            .on_click(control(FileAction::Play))
            .into_any_element()
        } else {
            icon(IconName::FileText, 18., r.text_subtle).into_any_element()
        })
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .child(
                    div()
                        .truncate()
                        .text_size(px(t.metrics.control))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(r.text)
                        .child(name),
                )
                .child(second_line),
        )
        .when(!audio, |d| {
            d.child(button(
                "look",
                IconName::Eye,
                labels.quick_look.clone(),
                FileAction::QuickLook,
            ))
        })
        .when(audio && !read_only, |d| {
            d.child(button(
                "transcribe",
                IconName::Captions,
                labels.transcribe,
                FileAction::Transcribe,
            ))
        })
        .child(button(
            "download",
            IconName::Download,
            labels.download,
            FileAction::Download,
        ))
        .when(!read_only, |d| {
            d.child(button(
                "remove",
                IconName::X,
                labels.remove,
                FileAction::Remove,
            ))
        })
        .into_any_element()
}

/// The editor's own element: lays out its blocks, collects their leaves'
/// geometry, and paints the caret and IME's underline over them.
struct EditorElement {
    editor: Entity<NoteEditor>,
    child: Option<AnyElement>,
    layout: Rc<RefCell<Layout>>,
    decorations: HashMap<u64, Vec<(Range<usize>, Hsla)>>,
    caret: Option<Pos>,
    caret_color: Hsla,
    marked: Option<(Pos, Pos)>,
    /// Scroll the selection's end into view after laying out.
    reveal: bool,
    head: Pos,
    head_block: u64,
    scroll: gpui_kit::ScrollHandle,
    focus: gpui_kit::FocusHandle,
}

impl IntoElement for EditorElement {
    type Element = Self;
    fn into_element(self) -> Self::Element {
        self
    }
}

impl Element for EditorElement {
    type RequestLayoutState = AnyElement;
    type PrepaintState = Option<Hitbox>;

    fn id(&self) -> Option<ElementId> {
        None
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, AnyElement) {
        let mut child = self
            .child
            .take()
            .unwrap_or_else(|| div().into_any_element());
        (child.request_layout(window, cx), child)
    }

    fn prepaint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        child: &mut AnyElement,
        window: &mut Window,
        cx: &mut App,
    ) -> Option<Hitbox> {
        let decorations = std::mem::take(&mut self.decorations);
        let (_, leaves) =
            editor_host::collect_leaf_geometry(decorations, || child.prepaint(window, cx));
        {
            let mut layout = self.layout.borrow_mut();
            layout.leaves = leaves;
            layout.bounds = bounds;
        }
        if self.reveal {
            self.reveal(window);
        }
        Some(window.insert_hitbox(bounds, HitboxBehavior::Normal))
    }

    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        child: &mut AnyElement,
        hitbox: &mut Option<Hitbox>,
        window: &mut Window,
        cx: &mut App,
    ) {
        // The text's own presses first (a card's buttons stop them); the
        // editor's handlers, registered before the children paint, run
        // after them in the bubble phase.
        self.mouse_handlers(bounds, hitbox.clone(), window);
        child.paint(window, cx);
        let layout = self.layout.borrow();
        if let Some(pos) = self.caret
            && let Some(block) = self.editor.read(cx).doc.blocks.get(pos.block)
            && let Some(leaf) = layout.leaves.get(&block.id)
        {
            let top = leaf.position_for_index(pos.offset);
            let height = leaf.caret_height();
            let line = leaf.line_height();
            let y = top.y + (line - height) / 2.;
            window.paint_quad(fill(
                Bounds::new(point(top.x, y), size(px(2.), height)),
                self.caret_color,
            ));
        }
        if let Some((a, b)) = self.marked {
            // IME's marked text is underlined, per visual line.
            let doc = &self.editor.read(cx).doc;
            for (block, range) in doc.ranges(a, b) {
                let Some(leaf) = doc.blocks.get(block).and_then(|b| layout.leaves.get(&b.id))
                else {
                    continue;
                };
                underline(leaf, range, self.caret_color, window);
            }
        }
        drop(layout);
        window.handle_input(
            &self.focus,
            ElementInputHandler::new(bounds, self.editor.clone()),
            cx,
        );
    }
}

impl EditorElement {
    /// Scrolls the editor's scroll view so the selection's end shows,
    /// with a margin.
    fn reveal(&self, window: &mut Window) {
        let layout = self.layout.borrow();
        let Some(leaf) = layout.leaves.get(&self.head_block) else {
            return;
        };
        let top = leaf.position_for_index(self.head.offset);
        let line = leaf.line_height();
        let viewport = self.scroll.bounds();
        if viewport.size.height <= px(0.) {
            return;
        }
        let margin = px(REVEAL_MARGIN).min(viewport.size.height / 4.);
        let dy = if top.y < viewport.top() + margin {
            viewport.top() + margin - top.y
        } else if top.y + line > viewport.bottom() - margin {
            viewport.bottom() - margin - (top.y + line)
        } else {
            return;
        };
        let offset = self.scroll.offset();
        let max = self.scroll.max_offset();
        let y = (offset.y + dy).clamp(-max.y.max(px(0.)), px(0.));
        if y != offset.y {
            self.scroll.set_offset(point(offset.x, y));
            window.refresh();
        }
    }

    fn mouse_handlers(&self, bounds: Bounds<Pixels>, hitbox: Option<Hitbox>, window: &mut Window) {
        let editor = self.editor.clone();
        let hit = hitbox.clone();
        window.on_mouse_event(move |e: &MouseDownEvent, phase, window, cx| {
            if phase != DispatchPhase::Bubble
                || e.button != MouseButton::Left
                || !bounds.contains(&e.position)
                || hit.as_ref().is_some_and(|h| !h.is_hovered(window))
            {
                return;
            }
            let (clicks, shift, cmd) = (e.click_count, e.modifiers.shift, e.modifiers.platform);
            editor.update(cx, |ed, cx| {
                ed.mouse_down(e.position, clicks, shift, cmd, window, cx)
            });
        });
        let editor = self.editor.clone();
        window.on_mouse_event(move |e: &MouseMoveEvent, phase, _, cx| {
            if phase != DispatchPhase::Bubble || e.pressed_button != Some(MouseButton::Left) {
                return;
            }
            if editor.read(cx).drag.is_some() {
                editor.update(cx, |ed, cx| ed.mouse_drag(e.position, cx));
            }
        });
        let editor = self.editor.clone();
        window.on_mouse_event(move |_: &MouseUpEvent, phase, _, cx| {
            if phase == DispatchPhase::Bubble && editor.read(cx).drag.is_some() {
                editor.update(cx, |ed, _| ed.mouse_up());
            }
        });
    }
}

/// Underlines `range` of `leaf`'s text, a line at a time.
fn underline(
    leaf: &gpui_kit::base::text::editor_host::LeafGeometry,
    range: Range<usize>,
    color: Hsla,
    window: &mut Window,
) {
    if range.is_empty() {
        return;
    }
    let line = leaf.line_height();
    let mut start = leaf.position_for_index(range.start);
    let end = leaf.position_for_index(range.end);
    let bounds = leaf.bounds();
    // Each visual line from `start` down to `end`'s.
    let mut guard = 0;
    while guard < 200 {
        guard += 1;
        let same = (f32::from(start.y) - f32::from(end.y)).abs() < 1.;
        let right = if same { end.x } else { bounds.right() };
        let y = start.y + line - px(3.);
        if right > start.x {
            window.paint_quad(fill(
                Bounds::new(point(start.x, y), size(right - start.x, px(1.5))),
                color,
            ));
        }
        if same {
            break;
        }
        start = point(bounds.left(), start.y + line);
        if start.y > end.y + px(1.) {
            break;
        }
    }
}
