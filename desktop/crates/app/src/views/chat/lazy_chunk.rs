//! A long answer's settled chunks, laid out only near what the transcript
//! shows.
//!
//! The transcript's list lays out every row on screen in full each frame,
//! and an answer is one row: while a long answer streams, every frame laid
//! out all of it (a 32K answer is thirty-odd TextViews, most of a frame)
//! although only its last screenful shows. [`super::markdown::stable_chunks`]
//! already keeps the answer's earlier chunks unchanged; a [`LazyChunk`]
//! holds such a chunk, when it sits well outside the transcript, as an
//! empty box of the height it last laid out at, so a frame lays out what
//! is near the view and the chunk still being written.
//!
//! What is drawn does not change:
//!
//! * a chunk is held only at the width and with the type it was measured
//!   at, from a layout of the text it has now (its parse landed);
//! * the decision uses where the chunk was last frame, with a margin; a
//!   held chunk that turns out to be in view this frame (the transcript
//!   jumped) is laid out and drawn in its room there and then;
//! * a held chunk whose column changed width is measured again next frame
//!   (and drawn at once if it is in view).
//!
//! The row decides which chunks may be held at all: none whose height can
//! change on its own (pictures, PDF cards and diagrams load later), none
//! with focus or a selection under way, none Find in Chat is revealing. And
//! none while assistive technology is connected: a held chunk's links and
//! buttons would leave the accessibility tree, where VoiceOver reaches them
//! anywhere in an answer on screen.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use gpui_kit::{
    AnyElement, App, AvailableSpace, Bounds, Element, ElementId, GlobalElementId,
    InspectorElementId, IntoElement, LayoutId, Pixels, Style, TextStyle, Window, px, relative,
    size,
};

/// How far outside the transcript a chunk is still laid out as usual: half
/// a view, so scrolling (and the answer's growth) reaches chunks already
/// laid out.
fn margin(view: Bounds<Pixels>) -> Pixels {
    (view.size.height * 0.5).max(px(300.))
}

/// What a chunk's layout depends on besides its text and width.
#[derive(Clone, PartialEq)]
struct Typography {
    style: TextStyle,
    rem: Pixels,
    scale: f32,
}

impl Typography {
    fn of(window: &Window) -> Self {
        Self {
            style: window.text_style(),
            rem: window.rem_size(),
            scale: window.scale_factor(),
        }
    }
}

#[derive(Clone)]
struct Measured {
    width: Pixels,
    height: Pixels,
    typography: Typography,
}

#[derive(Default)]
struct PlaceState {
    /// The chunk's size from its last layout of settled text.
    measured: Option<Measured>,
    /// Where it was last laid out or held, and the transcript's area then.
    seen: Option<(Bounds<Pixels>, Bounds<Pixels>)>,
}

/// What a row remembers of one chunk between frames.
#[derive(Default)]
pub struct ChunkPlace(RefCell<PlaceState>, Cell<Option<(usize, bool)>>);

impl ChunkPlace {
    /// [`changes_height_later`] for the chunk's text, worked out once per
    /// text (a settled chunk's text does not change; its length tells).
    pub fn changes_height_later(&self, markdown: &str) -> bool {
        if let Some((len, media)) = self.1.get()
            && len == markdown.len()
        {
            return media;
        }
        let media = changes_height_later(markdown);
        self.1.set(Some((markdown.len(), media)));
        media
    }

    /// The height to hold the chunk at this frame, if it may be held: it
    /// was measured with this typography and was far from the view.
    fn held_height(&self, typography: &Typography) -> Option<Pixels> {
        let state = self.0.borrow();
        let measured = state.measured.as_ref()?;
        if measured.typography != *typography {
            return None;
        }
        let (bounds, view) = state.seen?;
        let m = margin(view);
        let far = bounds.bottom() < view.top() - m || bounds.top() > view.bottom() + m;
        far.then_some(measured.height)
    }

    fn laid_out(&self, bounds: Bounds<Pixels>, view: Bounds<Pixels>, settled: Option<Typography>) {
        let mut state = self.0.borrow_mut();
        state.seen = Some((bounds, view));
        state.measured = settled.map(|typography| Measured {
            width: bounds.size.width,
            height: bounds.size.height,
            typography,
        });
    }

    /// Records where a held chunk is; `false` when its width is no longer
    /// the one it was measured at (the measurement is dropped).
    fn held(&self, bounds: Bounds<Pixels>, view: Bounds<Pixels>) -> bool {
        let mut state = self.0.borrow_mut();
        state.seen = Some((bounds, view));
        let fits = state
            .measured
            .as_ref()
            .is_some_and(|m| m.width == bounds.size.width);
        if !fits {
            state.measured = None;
        }
        fits
    }
}

/// One settled chunk of an answer: laid out as `child`, or held at its
/// last height while it is far from the view (see the module docs).
pub struct LazyChunk {
    place: Rc<ChunkPlace>,
    /// The row allows holding it (nothing in it changes height on its own,
    /// no focus, selection or reveal in it).
    may_hold: bool,
    /// Its text's parse has landed, so this layout's height can be kept.
    settled: bool,
    /// Makes the chunk's element, only when it is laid out.
    build: Option<Box<dyn FnOnce() -> AnyElement>>,
}

impl LazyChunk {
    /// The chunk at `place`, made by `build` when it is laid out.
    pub fn new(place: Rc<ChunkPlace>, build: impl FnOnce() -> AnyElement + 'static) -> Self {
        Self {
            place,
            may_hold: false,
            settled: false,
            build: Some(Box::new(build)),
        }
    }

    /// Whether the chunk may be held, and whether its text's parse has
    /// landed (only then is its height kept for holding).
    pub fn holdable(mut self, may_hold: bool, settled: bool) -> Self {
        self.may_hold = may_hold && settled;
        self.settled = settled;
        self
    }
}

/// The chunk as this frame lays it out.
pub struct ChunkLayout {
    child: Option<AnyElement>,
    typography: Typography,
}

impl IntoElement for LazyChunk {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

impl Element for LazyChunk {
    type RequestLayoutState = ChunkLayout;
    type PrepaintState = Option<AnyElement>;

    /// None, so the chunk's own element ids (and their state) are the ones
    /// it has without this wrapper.
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
    ) -> (LayoutId, Self::RequestLayoutState) {
        let typography = Typography::of(window);
        // With assistive technology connected every chunk is laid out, so
        // its links and buttons stay in the accessibility tree as before.
        if self.may_hold
            && !window.is_a11y_active()
            && let Some(height) = self.place.held_height(&typography)
        {
            // Held: its room, as the chunk filled it.
            let mut style = Style::default();
            style.size.width = relative(1.).into();
            style.size.height = height.into();
            style.flex_shrink = 0.;
            return (
                window.request_layout(style, None, cx),
                ChunkLayout {
                    child: None,
                    typography,
                },
            );
        }
        let mut child = (self.build.take().expect("laid out once"))();
        let layout_id = child.request_layout(window, cx);
        (
            layout_id,
            ChunkLayout {
                child: Some(child),
                typography,
            },
        )
    }

    fn prepaint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        layout: &mut Self::RequestLayoutState,
        window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        let view = window.content_mask().bounds;
        if let Some(mut child) = layout.child.take() {
            child.prepaint(window, cx);
            self.place.laid_out(
                bounds,
                view,
                self.settled.then(|| layout.typography.clone()),
            );
            return Some(child);
        }
        let fits = self.place.held(bounds, view);
        if !fits {
            // The column changed width: measured again next frame.
            window.request_animation_frame();
        }
        if !bounds.intersects(&view) {
            return None;
        }
        // In view after all (the transcript jumped further than the
        // margin): laid out in its room now.
        let mut child = (self.build.take()?)();
        child.layout_as_root(
            size(
                AvailableSpace::Definite(bounds.size.width),
                AvailableSpace::MinContent,
            ),
            window,
            cx,
        );
        child.prepaint_at(bounds.origin, window, cx);
        Some(child)
    }

    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        _: &mut Self::RequestLayoutState,
        child: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        if let Some(child) = child {
            child.paint(window, cx);
        }
    }
}

/// Whether a chunk's markdown may hold content whose height changes after
/// it is laid out: pictures (remote or `data:`, decoded off the main
/// thread), PDF cards (their first page renders later) and diagrams
/// (drawn by the renderer web view). Such a chunk is never held.
pub fn changes_height_later(markdown: &str) -> bool {
    if markdown.contains("![") || markdown.contains("<img") {
        return true;
    }
    if markdown.to_ascii_lowercase().contains(".pdf") {
        return true;
    }
    markdown.lines().any(|line| {
        let t = line.trim_start();
        let fence = t.strip_prefix("```").or_else(|| t.strip_prefix("~~~"));
        fence.is_some_and(|rest| {
            let lang = rest.trim_start_matches(['`', '~']).trim();
            let lang = lang.split_whitespace().next().unwrap_or_default();
            super::diagrams::diagram_kind(lang).is_some()
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn media_and_diagrams_keep_a_chunk_laid_out() {
        assert!(!changes_height_later(
            "Plain **text**, `code` and $x^2$.\n\n```rust\nfn f() {}\n```"
        ));
        assert!(changes_height_later(
            "See ![a tide chart](https://example.org/t.png)."
        ));
        assert!(changes_height_later(
            "![x](data:image/png;base64,iVBORw0KGgo=)"
        ));
        assert!(changes_height_later(
            "The [timetable](https://example.org/Tides.PDF)."
        ));
        assert!(changes_height_later("```mermaid\ngraph TD; A-->B\n```"));
        assert!(changes_height_later("Intro\n\n  ~~~ chart\n{}\n~~~"));
    }
}
