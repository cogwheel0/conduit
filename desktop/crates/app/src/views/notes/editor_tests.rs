//! The note editor in a real (test) window: every block kind lays out a
//! leaf the caret can sit in, typing goes through the platform's input
//! handler (marked text included), the arrows walk the text, a checkbox
//! click checks its item, and undo takes back what typing did.

use conduit_components::theme::{ConduitTheme, DesignPrefs, install};
use gpui_kit::prelude::*;
use gpui_kit::{
    Context, Entity, EntityInputHandler as _, Modifiers, MouseButton, TestAppContext,
    VisualTestContext, Window, div, point, px,
};
use serde_json::json;

use super::doc::{BlockKind, Doc, Pos};
use super::editor::NoteEditor;

struct Host {
    editor: Entity<NoteEditor>,
}

impl Render for Host {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .id("host")
            .size_full()
            .overflow_y_scroll()
            .track_scroll(&self.editor.read_with_scroll())
            .child(self.editor.clone())
    }
}

trait ScrollOf {
    fn read_with_scroll(&self) -> gpui_kit::ScrollHandle;
}

impl ScrollOf for Entity<NoteEditor> {
    fn read_with_scroll(&self) -> gpui_kit::ScrollHandle {
        SCROLL.with(|s| s.borrow().clone().unwrap_or_default())
    }
}

thread_local! {
    static SCROLL: std::cell::RefCell<Option<gpui_kit::ScrollHandle>> = const { std::cell::RefCell::new(None) };
}

fn every_format() -> Doc {
    let ops = json!([
        { "insert": "Plan" }, { "insert": "\n", "attributes": { "header": 1 } },
        { "insert": "Some " }, { "insert": "bold", "attributes": { "bold": true } },
        { "insert": " text.\n\n" },
        { "insert": "One" }, { "insert": "\n", "attributes": { "list": "bullet" } },
        { "insert": "Nested" },
        { "insert": "\n", "attributes": { "list": "bullet", "indent": 1 } },
        { "insert": "First" }, { "insert": "\n", "attributes": { "list": "ordered" } },
        { "insert": "Done" }, { "insert": "\n", "attributes": { "list": "checked" } },
        { "insert": "To do" }, { "insert": "\n", "attributes": { "list": "unchecked" } },
        { "insert": "Quoted" }, { "insert": "\n", "attributes": { "blockquote": true } },
        { "insert": "let a = 1;" },
        { "insert": "\n", "attributes": { "code-block": "plain" } },
        { "insert": "let b = 2;" },
        { "insert": "\n", "attributes": { "code-block": "plain" } },
        { "insert": "End\n" },
    ]);
    Doc::from_ops(ops.as_array().unwrap())
}

fn open(cx: &mut TestAppContext, doc: Doc) -> (Entity<NoteEditor>, &mut VisualTestContext) {
    cx.update(|cx| {
        gpui_kit::init(cx);
        install(
            ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
            cx,
        );
        cx.set_global(conduit_components::Strings::default());
    });
    let mut editor = None;
    let (_, vcx) = cx.add_window_view(|window, cx| {
        let e = cx.new(|cx| {
            let mut e = NoteEditor::new(window, cx);
            e.set_doc(doc, true, cx);
            e
        });
        SCROLL.with(|s| *s.borrow_mut() = Some(e.read(cx).scroll.clone()));
        editor = Some(e.clone());
        Host { editor: e }
    });
    let editor = editor.unwrap();
    vcx.update(|window, cx| {
        let focus = editor.read(cx).focus.clone();
        window.focus(&focus, cx);
    });
    draw(vcx);
    (editor, vcx)
}

fn draw(vcx: &mut VisualTestContext) {
    vcx.run_until_parked();
    vcx.update(|window, cx| window.draw(cx).clear(cx));
    vcx.run_until_parked();
}

fn type_text(editor: &Entity<NoteEditor>, text: &str, vcx: &mut VisualTestContext) {
    vcx.update(|window, cx| {
        editor.update(cx, |e, cx| e.replace_text_in_range(None, text, window, cx))
    });
    draw(vcx);
}

#[gpui_kit::test]
fn every_block_kind_lays_out_a_leaf_with_the_caret_in_it(cx: &mut TestAppContext) {
    let (editor, vcx) = open(cx, every_format());
    vcx.update(|_, cx| {
        let e = editor.read(cx);
        let layout = e.layout.borrow();
        for (i, block) in e.doc.blocks.iter().enumerate() {
            let leaf = layout
                .leaves
                .get(&block.id)
                .unwrap_or_else(|| panic!("block {i} ({:?}) has no leaf", block.kind));
            assert!(leaf.line_height() > px(0.), "block {i}");
            assert_eq!(leaf.len(), block.text.len(), "block {i}");
        }
        // Top to bottom, in document order.
        let tops: Vec<f32> = e
            .doc
            .blocks
            .iter()
            .map(|b| f32::from(layout.leaves[&b.id].bounds().top()))
            .collect();
        assert!(tops.windows(2).all(|w| w[0] < w[1]), "{tops:?}");
        // The heading's text is larger than the body's.
        let h = layout.leaves[&e.doc.blocks[0].id].line_height();
        let p = layout.leaves[&e.doc.blocks[1].id].line_height();
        assert!(h > p);
        // The nested item sits to the right of its parent.
        let one = layout.leaves[&e.doc.blocks[3].id].bounds().left();
        let nested = layout.leaves[&e.doc.blocks[4].id].bounds().left();
        assert!(nested > one);
    });
}

#[gpui_kit::test]
fn typing_goes_through_the_input_handler_and_undo_takes_it_back(cx: &mut TestAppContext) {
    let (editor, vcx) = open(cx, Doc::default());
    type_text(&editor, "H", vcx);
    type_text(&editor, "i", vcx);
    vcx.update(|_, cx| assert_eq!(editor.read(cx).doc.plain_text(), "Hi"));
    // Marked text (IME) replaces itself until committed.
    vcx.update(|window, cx| {
        editor.update(cx, |e, cx| {
            e.replace_and_mark_text_in_range(None, "に", None, window, cx);
            e.replace_and_mark_text_in_range(None, "にほ", None, window, cx);
            assert_eq!(e.doc.plain_text(), "Hiにほ");
            assert!(e.marked().is_some());
            e.replace_text_in_range(None, "日本", window, cx);
            assert_eq!(e.doc.plain_text(), "Hi日本");
            assert!(e.marked().is_none());
        })
    });
    // Autoformat: "- " at a line's start makes a bulleted item.
    vcx.update(|_, cx| editor.update(cx, |e, cx| e.newline(cx)));
    type_text(&editor, "-", vcx);
    type_text(&editor, " ", vcx);
    type_text(&editor, "milk", vcx);
    vcx.update(|_, cx| {
        let e = editor.read(cx);
        assert_eq!(e.doc.blocks[1].kind, BlockKind::Bullet);
        assert_eq!(e.doc.blocks[1].text, "milk");
    });
    vcx.update(|_, cx| editor.update(cx, |e, cx| e.undo(cx)));
    vcx.update(|_, cx| assert_eq!(editor.read(cx).doc.blocks[1].text, ""));
    vcx.update(|_, cx| editor.update(cx, |e, cx| e.redo(cx)));
    vcx.update(|_, cx| assert_eq!(editor.read(cx).doc.blocks[1].text, "milk"));
}

#[gpui_kit::test]
fn the_arrows_walk_lines_and_blocks(cx: &mut TestAppContext) {
    let (editor, vcx) = open(cx, every_format());
    vcx.update(|_, cx| editor.update(cx, |e, cx| e.select_to(Pos::new(1, 2), false, cx)));
    draw(vcx);
    vcx.dispatch_action(super::editor::MoveDown);
    draw(vcx);
    // Below the paragraph: the empty one after it.
    vcx.update(|_, cx| assert_eq!(editor.read(cx).selection().head.block, 2));
    vcx.dispatch_action(super::editor::MoveDown);
    draw(vcx);
    vcx.update(|_, cx| assert_eq!(editor.read(cx).selection().head.block, 3));
    vcx.dispatch_action(super::editor::MoveUp);
    vcx.dispatch_action(super::editor::MoveUp);
    draw(vcx);
    vcx.update(|_, cx| assert_eq!(editor.read(cx).selection().head, Pos::new(1, 2)));
    vcx.dispatch_action(super::editor::MoveLineEnd);
    draw(vcx);
    vcx.update(|_, cx| {
        let e = editor.read(cx);
        assert_eq!(e.selection().head, Pos::new(1, e.doc.blocks[1].text.len()))
    });
    vcx.dispatch_action(super::editor::SelectLeft);
    draw(vcx);
    vcx.update(|_, cx| assert_eq!(editor.read(cx).selected_text(), "."));
}

#[gpui_kit::test]
fn a_click_in_a_box_checks_its_item_and_a_click_in_text_moves_the_caret(cx: &mut TestAppContext) {
    let (editor, vcx) = open(cx, every_format());
    let (box_at, text_at) = vcx.update(|_, cx| {
        let e = editor.read(cx);
        let layout = e.layout.borrow();
        let todo = layout.leaves[&e.doc.blocks[7].id].bounds();
        let body = layout.leaves[&e.doc.blocks[1].id].bounds();
        (
            point(todo.left() - px(14.), todo.top() + px(8.)),
            point(body.left() + px(2.), body.top() + px(6.)),
        )
    });
    vcx.simulate_click(box_at, Modifiers::none());
    draw(vcx);
    vcx.update(|_, cx| assert_eq!(editor.read(cx).doc.blocks[7].kind, BlockKind::Check(true)));
    vcx.simulate_mouse_down(text_at, MouseButton::Left, Modifiers::none());
    vcx.simulate_mouse_up(text_at, MouseButton::Left, Modifiers::none());
    draw(vcx);
    vcx.update(|_, cx| assert_eq!(editor.read(cx).selection().head, Pos::new(1, 0)));
}

#[gpui_kit::test]
fn file_cards_come_in_at_the_end_and_step_as_one_piece(cx: &mut TestAppContext) {
    use super::doc::FileLink;
    let ops = json!([{ "insert": "Before\n" }]);
    let (editor, vcx) = open(cx, Doc::from_ops(ops.as_array().unwrap()));
    vcx.update(|_, cx| {
        editor.update(cx, |e, cx| {
            e.append_cards(
                &[FileLink {
                    id: "f1".into(),
                    name: "tide.wav".into(),
                }],
                cx,
            )
        })
    });
    draw(vcx);
    vcx.update(|_, cx| {
        let e = editor.read(cx);
        assert_eq!(e.cards().len(), 1);
        // A paragraph follows a card that ends the note, to type in.
        assert_eq!(e.doc.blocks.len(), 3);
        assert!(e.doc.blocks[1].file_link().is_some());
        assert_eq!(e.doc.blocks[2].text, "");
    });
    // → from "Before"'s end steps over the card in one go.
    vcx.update(|_, cx| editor.update(cx, |e, cx| e.select_to(Pos::new(0, 6), false, cx)));
    vcx.dispatch_action(super::editor::MoveRight);
    draw(vcx);
    vcx.update(|_, cx| assert_eq!(editor.read(cx).selection().head, Pos::new(2, 0)));
    // ⌫ at the start of the paragraph after it takes the card out; ⌘Z
    // puts it back.
    vcx.update(|_, cx| editor.update(cx, |e, cx| e.backspace(cx)));
    vcx.update(|_, cx| assert!(editor.read(cx).cards().is_empty()));
    vcx.update(|_, cx| editor.update(cx, |e, cx| e.undo(cx)));
    vcx.update(|_, cx| assert_eq!(editor.read(cx).cards().len(), 1));
    // Typing never goes into a card.
    vcx.update(|_, cx| editor.update(cx, |e, cx| e.select_to(Pos::new(1, 2), false, cx)));
    vcx.update(|_, cx| assert_ne!(editor.read(cx).selection().head.block, 1));
}

#[gpui_kit::test]
fn empty_blocks_of_every_kind_still_hold_the_caret(cx: &mut TestAppContext) {
    let ops = json!([
        { "insert": "\n", "attributes": { "header": 2 } },
        { "insert": "\n", "attributes": { "list": "bullet" } },
        { "insert": "\n", "attributes": { "list": "unchecked" } },
        { "insert": "\n", "attributes": { "blockquote": true } },
        { "insert": "\n", "attributes": { "code-block": "plain" } },
        { "insert": "\n" },
    ]);
    let (editor, vcx) = open(cx, Doc::from_ops(ops.as_array().unwrap()));
    vcx.update(|_, cx| {
        let e = editor.read(cx);
        for (i, block) in e.doc.blocks.iter().enumerate() {
            assert!(
                e.caret_point(Pos::new(i, 0)).is_some(),
                "an empty {:?} has no leaf",
                block.kind
            );
        }
    });
}

/// A click on a control inside a file card runs that control's action
/// once, and never the card's own (Play twice would leave a recording
/// paused; Download would also play it).
#[gpui_kit::test]
fn a_cards_controls_run_their_own_action_only(cx: &mut TestAppContext) {
    use std::cell::RefCell;
    use std::rc::Rc;

    use super::doc::FileLink;
    use super::editor::{EditorEvent, FileAction};
    let ops = json!([{ "insert": "Before\n" }]);
    let (editor, vcx) = open(cx, Doc::from_ops(ops.as_array().unwrap()));
    vcx.update(|_, cx| {
        editor.update(cx, |e, cx| {
            e.append_cards(
                &[FileLink {
                    id: "f1".into(),
                    name: "tide.wav".into(),
                }],
                cx,
            )
        })
    });
    draw(vcx);
    let heard: Rc<RefCell<Vec<FileAction>>> = Rc::default();
    let _listening = vcx.update(|_, cx| {
        let heard = heard.clone();
        cx.subscribe(&editor, move |_, e: &EditorEvent, _| {
            if let EditorEvent::File(_, what) = e {
                heard.borrow_mut().push(*what);
            }
        })
    });
    let card = vcx.debug_bounds("note-file-f1").expect("the card is drawn");
    let middle = card.top() + card.size.height / 2.;
    // Play sits first (10 pt in, 28 pt wide).
    vcx.simulate_click(point(card.left() + px(24.), middle), Modifiers::none());
    draw(vcx);
    assert_eq!(*heard.borrow(), vec![FileAction::Play]);
    heard.borrow_mut().clear();
    // Remove sits last (10 pt in from the right, 26 pt wide).
    vcx.simulate_click(point(card.right() - px(23.), middle), Modifiers::none());
    draw(vcx);
    assert_eq!(*heard.borrow(), vec![FileAction::Remove]);
    heard.borrow_mut().clear();
    // Elsewhere on the card: the card's own action, Play.
    vcx.simulate_click(point(card.left() + px(80.), middle), Modifiers::none());
    draw(vcx);
    assert_eq!(*heard.borrow(), vec![FileAction::Play]);
}
