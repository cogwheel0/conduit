//! Motion: the app's curves and durations, and the interruptible tweens
//! every transition is built from.
//!
//! * **Purposeful and short.** Each transition names what it shows (where a
//!   panel came from, that a section opened) and lasts 90–250 ms. Nothing
//!   animates on a high-frequency keyboard action: focus moves and typing
//!   lands at once, whatever is still fading.
//! * **Interruptible.** A tween retargeted mid-flight starts from the value on
//!   screen, never from its end, and a reversal takes only the share of the
//!   time the distance back needs.
//! * **Reduce Motion** (System Settings › Accessibility › Display, read by
//!   the app into [`App::reduce_motion`]): movement and size changes become
//!   instant ([`Reduced::Snap`]); fades that help follow a change stay, as a
//!   plain crossfade ([`Reduced::Keep`]).
//!
//! GPUI draws no transforms on a div, so a panel "scaling in" is drawn as a
//! fade plus a few points of travel from where it comes from.

use std::time::{Duration, Instant};

use gpui_kit::{
    AnyElement, App, AvailableSpace, Bounds, ContentMask, Element, ElementId, GlobalElementId,
    HighlightStyle, Hsla, InspectorElementId, IntoElement, LayoutId, Pixels, SharedString, Style,
    StyledText, Window, point, px, relative, size,
};

/// An easing curve (cubic Bézier, from the motion guidelines' table; never
/// the weak CSS built-ins).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Curve {
    /// Strong ease-out (0.23, 1, 0.32, 1): entrances and exits.
    EaseOut,
    /// Strong ease-in-out (0.77, 0, 0.175, 1): something moving on screen.
    EaseInOut,
    /// The drawer curve (0.32, 0.72, 0, 1).
    Drawer,
    /// AppKit's own ease-in-ease-out (0.42, 0, 0.58, 1), as NSSplitView
    /// slides a pane: even at both ends, no crawl into place (the sidebar,
    /// a card collapsing where it stands).
    Standard,
    /// A gentle ease-out (cubic, 0.215, 0.61, 0.355, 1) whose tail is short:
    /// a popover or pane fading in, which [`Curve::EaseOut`] would leave
    /// creeping the last few percent for half its time.
    Decelerate,
    /// Opacity leaving: even steps and a crisp end, so nothing lingers
    /// faintly once the rest has gone.
    Linear,
}

impl Curve {
    /// The eased progress at `t` (0…1).
    pub fn sample(self, t: f32) -> f32 {
        let t = t.clamp(0., 1.);
        match self {
            Self::Linear => t,
            Self::EaseOut => bezier(0.23, 1., 0.32, 1., t),
            Self::EaseInOut => bezier(0.77, 0., 0.175, 1., t),
            Self::Drawer => bezier(0.32, 0.72, 0., 1., t),
            Self::Standard => bezier(0.42, 0., 0.58, 1., t),
            Self::Decelerate => bezier(0.215, 0.61, 0.355, 1., t),
        }
    }
}

/// `y` of the cubic Bézier `(0,0) (x1,y1) (x2,y2) (1,1)` at `x`: Newton's
/// method on `x(s)`, bisection when the slope is flat.
fn bezier(x1: f32, y1: f32, x2: f32, y2: f32, x: f32) -> f32 {
    if x <= 0. || x >= 1. {
        return x.clamp(0., 1.);
    }
    let coord = |a: f32, b: f32, s: f32| {
        let m = 1. - s;
        3. * m * m * s * a + 3. * m * s * s * b + s * s * s
    };
    let slope = |a: f32, b: f32, s: f32| {
        let m = 1. - s;
        3. * m * m * a + 6. * m * s * (b - a) + 3. * s * s * (1. - b)
    };
    let mut s = x;
    for _ in 0..8 {
        let err = coord(x1, x2, s) - x;
        if err.abs() < 1e-5 {
            return coord(y1, y2, s);
        }
        let d = slope(x1, x2, s);
        if d.abs() < 1e-6 {
            break;
        }
        s = (s - err / d).clamp(0., 1.);
    }
    let (mut lo, mut hi) = (0f32, 1f32);
    s = x;
    for _ in 0..30 {
        let v = coord(x1, x2, s);
        if (v - x).abs() < 1e-5 {
            break;
        }
        if v < x {
            lo = s;
        } else {
            hi = s;
        }
        s = (lo + hi) / 2.;
    }
    coord(y1, y2, s)
}

/// A duration and a curve.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Spec {
    pub duration: Duration,
    pub curve: Curve,
}

impl Spec {
    pub const fn new(ms: u64, curve: Curve) -> Self {
        Self {
            duration: Duration::from_millis(ms),
            curve,
        }
    }
}

/// The app's transitions.
pub mod specs {
    use super::{Curve, Spec};

    /// The sidebar sliding in and out, the content beside it reflowing, as
    /// NSSplitView collapses a pane (220 ms, even at both ends).
    pub const SIDEBAR: Spec = Spec::new(220, Curve::Standard);
    /// ⌘K: in quickly, out quicker (typing never waits for it). Scrim and
    /// panel leave together on one even fade, so no faint panel outlasts
    /// the scrim.
    pub const PALETTE_IN: Spec = Spec::new(120, Curve::EaseOut);
    pub const PALETTE_OUT: Spec = Spec::new(90, Curve::Linear);
    /// The model picker and the citation popover, from their trigger: in
    /// with a short tail (no last step landing late), out evenly.
    pub const POPOVER_IN: Spec = Spec::new(120, Curve::Decelerate);
    pub const POPOVER_OUT: Spec = Spec::new(100, Curve::Linear);
    /// Toasts rise in and fade out where they were.
    pub const TOAST_IN: Spec = Spec::new(200, Curve::EaseOut);
    pub const TOAST_OUT: Spec = Spec::new(150, Curve::EaseOut);
    /// The approval card docking above the composer, and leaving: once
    /// answered it fades and collapses where it stands.
    pub const CARD_IN: Spec = Spec::new(200, Curve::EaseOut);
    pub const CARD_OUT: Spec = Spec::new(150, Curve::Standard);
    /// Reasoning and tool disclosures: the height and the chevron.
    pub const DISCLOSURE: Spec = Spec::new(180, Curve::EaseOut);
    /// A Settings pane replacing another.
    pub const CROSSFADE: Spec = Spec::new(100, Curve::Decelerate);
    /// Quick Ask's panel.
    pub const QUICK_ASK_IN: Spec = Spec::new(150, Curve::EaseOut);
    pub const QUICK_ASK_OUT: Spec = Spec::new(120, Curve::EaseOut);
    /// A finished answer's actions and its suggestions, arriving together,
    /// and the suggestions leaving at a send.
    pub const REVEAL: Spec = Spec::new(150, Curve::Decelerate);
    pub const REVEAL_OUT: Spec = Spec::new(150, Curve::EaseOut);
    /// An answer being regenerated dims while the new one is on its way.
    pub const STALE: Spec = Spec::new(200, Curve::EaseOut);
    /// …its suggestions fade where they stand (their room kept until the
    /// new answer starts), and the waiting line comes in where its actions
    /// were.
    pub const REGEN_OUT: Spec = Spec::new(120, Curve::Linear);
    pub const REGEN_WAIT_IN: Spec = Spec::new(120, Curve::Decelerate);
    /// …and once the new answer's first words arrive, the old one
    /// crossfades into it in place, the height following.
    pub const REGEN_CROSSFADE: Spec = Spec::new(150, Curve::Standard);
    /// A new chat's first send: the greeting fades out…
    pub const HANDOFF_OUT: Spec = Spec::new(120, Curve::Linear);
    /// …while the message rises into place from the composer's side and
    /// fades in (the whole hand-off about 200 ms, as Messages').
    pub const HANDOFF_IN: Spec = Spec::new(200, Curve::Decelerate);
}

/// How far a new chat's first message rises into place (points).
pub const HANDOFF_RISE: f32 = 10.;

/// How long a just-finished answer waits for its suggestions before its
/// actions show without them: the server writes suggestions after the
/// answer, and the two arriving apart would land in two steps.
pub const SETTLE_WAIT: Duration = Duration::from_millis(600);

/// Whether a finished answer's actions and suggestions may show at `now`:
/// at once for an answer that was never seen streaming, else once its
/// suggestions are in or [`SETTLE_WAIT`] has passed since it finished.
pub fn settled(finished: Option<Instant>, has_suggestions: bool, now: Instant) -> bool {
    finished.is_none_or(|at| has_suggestions || now.saturating_duration_since(at) >= SETTLE_WAIT)
}

/// A frame this long after the one before means the main thread was busy.
pub const STALL: Duration = Duration::from_millis(50);
/// One display frame at 60 Hz.
pub const FRAME: Duration = Duration::from_micros(16_667);

/// A keyed tween and when it was last drawn.
#[derive(Clone, Copy)]
struct Keyed {
    tween: Tween,
    seen: Instant,
}

/// What a tween does under Reduce Motion.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reduced {
    /// Jump to the target (movement, size).
    Snap,
    /// Keep the tween (an opacity crossfade).
    Keep,
}

/// A value easing from `from` to `to` since `start`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Tween {
    pub from: f32,
    pub to: f32,
    pub start: Instant,
    pub duration: Duration,
    pub curve: Curve,
}

impl Tween {
    /// At rest on `value`.
    pub fn at(value: f32, now: Instant) -> Self {
        Self {
            from: value,
            to: value,
            start: now,
            duration: Duration::ZERO,
            curve: Curve::Linear,
        }
    }

    /// The value at `now`.
    pub fn value(&self, now: Instant) -> f32 {
        let p = self.progress(now);
        self.from + (self.to - self.from) * self.curve.sample(p)
    }

    fn progress(&self, now: Instant) -> f32 {
        if self.duration.is_zero() {
            return 1.;
        }
        let elapsed = now.saturating_duration_since(self.start);
        (elapsed.as_secs_f32() / self.duration.as_secs_f32()).clamp(0., 1.)
    }

    /// Still on its way at `now`.
    pub fn moving(&self, now: Instant) -> bool {
        self.from != self.to && self.progress(now) < 1.
    }

    /// Drawn at `now`, last drawn at `seen`: a gap the size of a stall (the
    /// main thread busy with a long layout: more than [`STALL`], less than
    /// a second) while it was on its way moves its clock on by all but one
    /// frame. The frame after a long one then carries on from where the
    /// motion was, instead of landing at its end with nothing in between
    /// (GPUI draws on the main thread; Core Animation would not have
    /// stopped).
    pub fn skip_stall(&mut self, seen: Instant, now: Instant) {
        let gap = now.saturating_duration_since(seen);
        if self.moving(seen) && gap > STALL && gap < Duration::from_secs(1) {
            self.start += gap - FRAME;
        }
    }

    /// Heads for `to` from wherever it is at `now`. The time is the spec's,
    /// scaled by the share of `span` left to cover, so turning back halfway
    /// takes half as long.
    pub fn retarget(&mut self, to: f32, spec: Spec, span: f32, now: Instant) {
        if to == self.to {
            return;
        }
        let from = self.value(now);
        let share = if span > 0. {
            ((to - from).abs() / span).clamp(0., 1.)
        } else {
            1.
        };
        *self = Self {
            from,
            to,
            start: now,
            duration: spec.duration.mul_f32(share),
            curve: spec.curve,
        };
    }
}

/// The value, keyed by `id` in the element being drawn, easing toward
/// `target` (0…1). The first value is adopted at once (nothing animates
/// when a window opens); later targets ease, from the value on screen.
pub fn tween(
    id: impl Into<ElementId>,
    target: f32,
    spec: Spec,
    reduced: Reduced,
    window: &mut Window,
    cx: &mut App,
) -> f32 {
    keyed(
        id.into(),
        target,
        Some(target),
        spec,
        spec,
        reduced,
        window,
        cx,
    )
}

/// [`tween`] with one spec on the way up and another on the way down.
pub fn tween_with(
    id: impl Into<ElementId>,
    target: f32,
    up: Spec,
    down: Spec,
    reduced: Reduced,
    window: &mut Window,
    cx: &mut App,
) -> f32 {
    keyed(
        id.into(),
        target,
        Some(target),
        up,
        down,
        reduced,
        window,
        cx,
    )
}

/// How far something that comes and goes is shown.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Appear {
    /// 0 (gone) … 1 (in place), eased.
    pub progress: f32,
    /// What its opacity should be.
    pub opacity: f32,
    /// How much of its travel is left (0 at rest; always 0 under Reduce
    /// Motion, where it only fades).
    pub travel: f32,
    /// Whether to draw it at all (false once it has faded out).
    pub visible: bool,
    /// On its way out: draw it, but take no clicks.
    pub leaving: bool,
}

impl Appear {
    /// `offset` points of travel left, toward the side it comes from.
    pub fn offset(&self, offset: f32) -> f32 {
        offset * self.travel
    }
}

/// Something that comes and goes, keyed by `id`: eases in with `enter`
/// the first time it is drawn shown (or again once shown), out with `exit`.
/// Under Reduce Motion it crossfades in place.
pub fn appear(
    id: impl Into<ElementId>,
    shown: bool,
    enter: Spec,
    exit: Spec,
    window: &mut Window,
    cx: &mut App,
) -> Appear {
    let target = if shown { 1. } else { 0. };
    let p = keyed(
        id.into(),
        target,
        Some(0.),
        enter,
        exit,
        Reduced::Keep,
        window,
        cx,
    );
    appear_at(p, shown, cx.reduce_motion())
}

/// [`Appear`] at progress `p`.
pub fn appear_at(p: f32, shown: bool, reduce_motion: bool) -> Appear {
    Appear {
        progress: p,
        opacity: p,
        travel: if reduce_motion { 0. } else { 1. - p },
        visible: shown || p > 0.001,
        leaving: !shown,
    }
}

/// 0 → 1 the first time `id` is drawn (a new pane fading in).
pub fn enter(
    id: impl Into<ElementId>,
    spec: Spec,
    reduced: Reduced,
    window: &mut Window,
    cx: &mut App,
) -> f32 {
    keyed(id.into(), 1., Some(0.), spec, spec, reduced, window, cx)
}

#[allow(clippy::too_many_arguments)]
fn keyed(
    id: ElementId,
    target: f32,
    initial: Option<f32>,
    up: Spec,
    down: Spec,
    reduced: Reduced,
    window: &mut Window,
    cx: &mut App,
) -> f32 {
    let now = cx.background_executor().now();
    let start = initial.unwrap_or(target);
    let state = window.use_keyed_state(id, cx, |_, _| Keyed {
        tween: Tween::at(start, now),
        seen: now,
    });
    let snap = reduced == Reduced::Snap && cx.reduce_motion();
    let Keyed { mut tween, seen } = *state.read(cx);
    if snap {
        if tween.from != target || tween.to != target {
            tween = Tween::at(target, now);
            state.update(cx, |s, _| *s = Keyed { tween, seen: now });
        }
        return target;
    }
    let before = tween;
    tween.skip_stall(seen, now);
    if tween.to != target {
        let spec = if target >= tween.value(now) { up } else { down };
        tween.retarget(target, spec, 1., now);
    }
    // When it was drawn matters only while it moves.
    if tween != before || tween.moving(now) {
        state.update(cx, |s, _| *s = Keyed { tween, seen: now });
    }
    let value = tween.value(now);
    if tween.moving(now) {
        window.request_animation_frame();
    }
    value
}

/// A critically damped spring chasing a moving target (the transcript
/// following the end of a streaming answer): it carries its velocity when
/// the target moves again, so the motion never restarts.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Chase {
    pub position: f32,
    pub velocity: f32,
    /// Natural frequency (rad/s): about `2π / response`.
    pub omega: f32,
}

impl Chase {
    /// At `position`, with a response of `response` seconds (≈ the time to
    /// settle most of the way).
    pub fn new(position: f32, response: f32) -> Self {
        Self {
            position,
            velocity: 0.,
            omega: std::f32::consts::TAU / response.max(0.01),
        }
    }

    /// Advances `dt` seconds toward `target` (exact for a fixed target; a
    /// long gap is capped so a stalled frame never jumps).
    pub fn step(&mut self, target: f32, dt: f32) -> f32 {
        let dt = dt.clamp(0., 0.05);
        let w = self.omega;
        let d0 = self.position - target;
        let c = self.velocity + w * d0;
        let e = (-w * dt).exp();
        self.position = target + (d0 + c * dt) * e;
        self.velocity = (self.velocity - w * c * dt) * e;
        self.position
    }

    /// Close enough to `target` to stop.
    pub fn settled(&self, target: f32) -> bool {
        (self.position - target).abs() < 0.5 && self.velocity.abs() < 20.
    }
}

// ── Shimmer ─────────────────────────────────────────────────────────────

/// One sweep of the shimmer's band along its line, from before the first
/// character to past the last. Sweeps follow one another with no rest, so
/// the line changes on every display frame (a still moment reads as a
/// stall).
pub const SHIMMER_SWEEP: Duration = Duration::from_millis(1300);
/// The band's width in points: a raised-cosine feather either side of its
/// centre, so it has no edge.
pub const SHIMMER_BAND: f32 = 60.;
/// How far toward its highlight the band takes the line at its centre.
pub const SHIMMER_PEAK: f32 = 0.85;
/// A glyph's average advance in the system font, in ems (the band is laid
/// out in points over glyphs placed this far apart).
pub const SHIMMER_ADVANCE: f32 = 0.52;

/// How much of the highlight a glyph centred `x` points along its line takes
/// with the band centred at `centre`.
pub fn shimmer_weight(x: f32, centre: f32) -> f32 {
    let d = (x - centre).abs() / (SHIMMER_BAND / 2.);
    if d >= 1. {
        0.
    } else {
        SHIMMER_PEAK * 0.5 * (1. + (std::f32::consts::PI * d).cos())
    }
}

/// Each character's highlight weight for a line of `n` characters in a
/// `font_size` pt font at `phase` (0…1 of a [`SHIMMER_SWEEP`]). The band's
/// centre runs from half a band before the line to half a band past it,
/// less a glyph at each end, so some of the line is always under it.
pub fn shimmer_weights(n: usize, font_size: f32, phase: f32) -> Vec<f32> {
    let advance = font_size * SHIMMER_ADVANCE;
    let width = n as f32 * advance;
    let half = SHIMMER_BAND / 2.;
    let (from, to) = (-half + advance, width + half - advance);
    let centre = from + phase.rem_euclid(1.) * (to - from);
    (0..n)
        .map(|i| shimmer_weight((i as f32 + 0.5) * advance, centre))
        .collect()
}

/// Where the shimmer is at `now`: every shimmer shares one clock, so a line
/// redrawn by another row carries on where it was.
pub fn shimmer_phase(now: Instant) -> f32 {
    static EPOCH: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
    let epoch = *EPOCH.get_or_init(|| now);
    now.saturating_duration_since(epoch).as_secs_f32() / SHIMMER_SWEEP.as_secs_f32()
}

/// A short status line ("Waiting for the answer…") with a soft band of
/// highlight sweeping along it, in `base` with the band toward `highlight`,
/// redrawn every display frame. Each character takes the band's strength
/// at its centre, unquantized, so the band glides rather than steps. Under
/// Reduce Motion the line is still (plain `base`).
pub fn shimmer_text(
    text: impl Into<SharedString>,
    font_size: f32,
    base: Hsla,
    highlight: Hsla,
    window: &mut Window,
    cx: &App,
) -> StyledText {
    let text = text.into();
    if cx.reduce_motion() {
        return StyledText::new(text);
    }
    let phase = shimmer_phase(cx.background_executor().now());
    let weights = shimmer_weights(text.chars().count(), font_size, phase);
    window.request_animation_frame();
    let highlights: Vec<_> = text
        .char_indices()
        .zip(weights)
        .filter(|(_, w)| *w > 0.002)
        .map(|((at, ch), w)| {
            (
                at..at + ch.len_utf8(),
                HighlightStyle {
                    color: Some(crate::theme::mix(base, highlight, w)),
                    ..Default::default()
                },
            )
        })
        .collect();
    StyledText::new(text).with_highlights(highlights)
}

// ── Reveal ──────────────────────────────────────────────────────────────

/// Which edge of its child a [`Reveal`] keeps in place.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Anchor {
    /// The child's top stays at the reveal's top; the bottom is cut (a
    /// disclosure opening, a card rising from behind what is under it).
    Top,
    /// The child's bottom stays at the reveal's bottom; the top is cut (a
    /// card above the composer collapsing where it stands).
    Bottom,
}

/// A measured, clipped vertical reveal: draws `progress` (0…1) of its
/// child's height. Until it has measured the child it draws nothing (rather
/// than the whole child for a frame), unless fully open, when the child is
/// laid out in place and the reveal is its height.
pub struct Reveal {
    id: ElementId,
    progress: f32,
    bleed: Pixels,
    anchor: Anchor,
    child: AnyElement,
}

impl Reveal {
    pub fn new(id: impl Into<ElementId>, progress: f32, child: impl IntoElement) -> Self {
        Self {
            id: id.into(),
            progress: progress.clamp(0., 1.),
            bleed: px(0.),
            anchor: Anchor::Top,
            child: child.into_any_element(),
        }
    }

    /// Keeps the child's `anchor` edge in place as it opens and closes.
    pub fn anchor(mut self, anchor: Anchor) -> Self {
        self.anchor = anchor;
        self
    }

    /// Room the child may paint outside the reveal (a card's shadow): at the
    /// sides and the anchored edge always, and past the moving edge once
    /// fully open. While it opens, the moving edge still clips, as the
    /// reveal needs.
    pub fn bleed(mut self, bleed: f32) -> Self {
        self.bleed = px(bleed.max(0.));
        self
    }

    /// The content mask: the bounds, grown by the bleed.
    fn mask(&self, bounds: Bounds<Pixels>) -> ContentMask<Pixels> {
        let b = self.bleed;
        let open = if self.progress >= 1. { b } else { px(0.) };
        let (above, below) = match self.anchor {
            Anchor::Top => (b, open),
            Anchor::Bottom => (open, b),
        };
        ContentMask {
            bounds: Bounds::from_corners(
                point(bounds.left() - b, bounds.top() - above),
                point(bounds.right() + b, bounds.bottom() + below),
            ),
        }
    }
}

impl IntoElement for Reveal {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

impl Element for Reveal {
    type RequestLayoutState = ();
    type PrepaintState = ();

    fn id(&self) -> Option<ElementId> {
        Some(self.id.clone())
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        global_id: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        let height = window.with_element_state(
            global_id.expect("Reveal has an id"),
            |state: Option<Option<Pixels>>, _| {
                let state = state.flatten();
                (state, state)
            },
        );
        let mut style = Style::default();
        style.size.width = relative(1.).into();
        // Fully open, the child is laid out as an ordinary child, so the
        // reveal is its height in the same frame, on its first one too and
        // when the content grows or shrinks.
        if self.progress >= 1. {
            let child = self.child.request_layout(window, cx);
            return (window.request_layout(style, [child], cx), ());
        }
        style.size.height = match height {
            None => px(0.).into(),
            Some(height) => (height * self.progress).into(),
        };
        (window.request_layout(style, None, cx), ())
    }

    fn prepaint(
        &mut self,
        global_id: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut Self::RequestLayoutState,
        window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        if self.progress >= 1. {
            // Laid out in place: what it measures is kept, so closing starts
            // from the height on screen.
            window.with_element_state(
                global_id.expect("Reveal has an id"),
                |_: Option<Option<Pixels>>, _| ((), Some(bounds.size.height)),
            );
            let mask = self.mask(bounds);
            window.with_content_mask(Some(mask), |window| self.child.prepaint(window, cx));
            return;
        }
        let measured = self.child.layout_as_root(
            size(
                AvailableSpace::Definite(bounds.size.width),
                AvailableSpace::MinContent,
            ),
            window,
            cx,
        );
        let changed = window.with_element_state(
            global_id.expect("Reveal has an id"),
            |state: Option<Option<Pixels>>, _| {
                let changed = state.flatten() != Some(measured.height);
                (changed, Some(measured.height))
            },
        );
        if changed {
            window.request_animation_frame();
        }
        let origin = match self.anchor {
            Anchor::Top => bounds.origin,
            Anchor::Bottom => point(
                bounds.origin.x,
                bounds.origin.y + bounds.size.height - measured.height,
            ),
        };
        let mask = self.mask(bounds);
        window.with_content_mask(Some(mask), |window| {
            self.child.prepaint_at(origin, window, cx);
        });
    }

    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut Self::RequestLayoutState,
        _: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        let mask = self.mask(bounds);
        window.with_content_mask(Some(mask), |window| {
            self.child.paint(window, cx);
        });
    }
}

// ── Crossfade ───────────────────────────────────────────────────────────

/// One place changing what it shows: `from` (what was there, drawn by the
/// caller at `1 - progress` opacity) over `to` (at `progress`), the height
/// going from `from`'s to `to`'s as `size` goes 0 → 1, with what does not
/// fit cut at the bottom. With no `from` it is just `to`, and it keeps
/// `to`'s height so a later crossfade starts from what was on screen.
pub struct Crossfade {
    id: ElementId,
    size: f32,
    from: Option<AnyElement>,
    to: AnyElement,
}

/// The heights a [`Crossfade`] keeps: what it showed before the crossfade
/// began, and `to`'s as last measured.
#[derive(Clone, Copy, Default)]
struct CrossfadeHeights {
    from: Pixels,
    to: Pixels,
}

impl Crossfade {
    /// `to` alone.
    pub fn new(id: impl Into<ElementId>, to: impl IntoElement) -> Self {
        Self {
            id: id.into(),
            size: 1.,
            from: None,
            to: to.into_any_element(),
        }
    }

    /// Crossfading from `from`, the height `size` (0…1) of the way to
    /// `to`'s.
    pub fn from(mut self, from: impl IntoElement, size: f32) -> Self {
        self.from = Some(from.into_any_element());
        self.size = size.clamp(0., 1.);
        self
    }

    /// The height at `size` of the way from `from` to `to`.
    pub fn height_at(from: f32, to: f32, size: f32) -> f32 {
        from + (to - from) * size.clamp(0., 1.)
    }
}

impl IntoElement for Crossfade {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

impl Element for Crossfade {
    type RequestLayoutState = ();
    type PrepaintState = ();

    fn id(&self) -> Option<ElementId> {
        Some(self.id.clone())
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        global_id: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        let mut style = Style::default();
        style.size.width = relative(1.).into();
        if self.from.is_none() {
            let child = self.to.request_layout(window, cx);
            return (window.request_layout(style, [child], cx), ());
        }
        let heights = window.with_element_state(
            global_id.expect("Crossfade has an id"),
            |state: Option<CrossfadeHeights>, _| {
                let state = state.unwrap_or_default();
                (state, state)
            },
        );
        let to = if heights.to > px(0.) {
            heights.to
        } else {
            heights.from
        };
        style.size.height = px(Self::height_at(
            f32::from(heights.from),
            f32::from(to),
            self.size,
        ))
        .into();
        (window.request_layout(style, None, cx), ())
    }

    fn prepaint(
        &mut self,
        global_id: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut Self::RequestLayoutState,
        window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        let id = global_id.expect("Crossfade has an id");
        let Some(from) = self.from.as_mut() else {
            self.to.prepaint(window, cx);
            let h = bounds.size.height;
            window.with_element_state(id, |_: Option<CrossfadeHeights>, _| {
                ((), CrossfadeHeights { from: h, to: h })
            });
            return;
        };
        let space = size(
            AvailableSpace::Definite(bounds.size.width),
            AvailableSpace::MinContent,
        );
        from.layout_as_root(space, window, cx);
        let to_size = self.to.layout_as_root(space, window, cx);
        let changed = window.with_element_state(id, |state: Option<CrossfadeHeights>, _| {
            let mut state = state.unwrap_or_default();
            let changed = state.to != to_size.height;
            state.to = to_size.height;
            (changed, state)
        });
        if changed {
            window.request_animation_frame();
        }
        let mask = ContentMask { bounds };
        window.with_content_mask(Some(mask), |window| {
            from.prepaint_at(bounds.origin, window, cx);
            self.to.prepaint_at(bounds.origin, window, cx);
        });
    }

    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut Self::RequestLayoutState,
        _: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        let Some(from) = self.from.as_mut() else {
            self.to.paint(window, cx);
            return;
        };
        window.with_content_mask(Some(ContentMask { bounds }), |window| {
            from.paint(window, cx);
            self.to.paint(window, cx);
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn curves_start_at_zero_end_at_one_and_never_go_back() {
        for curve in [
            Curve::EaseOut,
            Curve::EaseInOut,
            Curve::Drawer,
            Curve::Standard,
            Curve::Decelerate,
            Curve::Linear,
        ] {
            assert_eq!(curve.sample(0.), 0.);
            assert!((curve.sample(1.) - 1.).abs() < 1e-4);
            let mut last = 0.;
            for i in 1..=100 {
                let v = curve.sample(i as f32 / 100.);
                assert!(v >= last - 1e-4, "{curve:?} went back at {i}");
                last = v;
            }
        }
        // Ease-out is fast first: past halfway at a quarter of the time.
        assert!(Curve::EaseOut.sample(0.25) > 0.5);
        assert!(Curve::Drawer.sample(0.25) > 0.4);
        // Ease-in-out is slow at both ends and about halfway at the middle.
        assert!(Curve::EaseInOut.sample(0.1) < 0.05 && Curve::EaseInOut.sample(0.9) > 0.95);
        assert!((Curve::EaseInOut.sample(0.5) - 0.5).abs() < 0.1);
        // AppKit's ease-in-ease-out is symmetric: as far from the start at
        // t as from the end at 1 - t.
        for i in 1..10 {
            let t = i as f32 / 10.;
            let (a, b) = (Curve::Standard.sample(t), Curve::Standard.sample(1. - t));
            assert!((a + b - 1.).abs() < 1e-3, "{t}: {a} + {b}");
        }
    }

    /// Frame-by-frame progress of `spec` at 60 Hz, ending on 1.
    fn frames(spec: Spec) -> Vec<f32> {
        let frame = 1000. / 60.;
        let ms = spec.duration.as_millis() as f32;
        let mut out: Vec<f32> = (1..)
            .map(|k| k as f32 * frame)
            .take_while(|t| *t < ms - 0.5)
            .map(|t| spec.curve.sample(t / ms))
            .collect();
        out.push(1.);
        out
    }

    #[test]
    fn the_sidebar_moves_evenly_with_no_crawl_into_place() {
        assert_eq!(specs::SIDEBAR.duration, Duration::from_millis(220));
        let p = frames(specs::SIDEBAR);
        // On its way from the first frame, never more than a fifth of the
        // way in one frame (the drawer curve covered 80% in two), and the
        // last tenth of the distance takes at most a third of the frames
        // (the drawer curve crawled through it for over half).
        let tail = |p: &[f32]| p.iter().filter(|v| **v > 0.9).count() * 3 <= p.len();
        assert!(p[0] > 0.005, "{p:?}");
        assert!(p.windows(2).all(|w| w[1] - w[0] <= 0.2), "{p:?}");
        assert!(tail(&p), "{p:?}");
        assert!(!tail(&frames(Spec::new(220, Curve::Drawer))));
    }

    #[test]
    fn fades_leave_without_a_faint_tail() {
        // Out: every frame takes a visible step, the last one included.
        for spec in [specs::PALETTE_OUT, specs::POPOVER_OUT] {
            let p = frames(spec);
            assert!(p.windows(2).all(|w| w[1] - w[0] > 0.05), "{spec:?} {p:?}");
        }
        // In: the popover and a Settings pane are nearly there with a
        // quarter of their time left (a strong ease-out still creeps).
        for spec in [specs::POPOVER_IN, specs::CROSSFADE, specs::REVEAL] {
            assert!(spec.curve.sample(0.75) > 0.97, "{spec:?}");
        }
        assert!(specs::CROSSFADE.duration <= Duration::from_millis(100));
        assert!(specs::PALETTE_OUT.duration <= Duration::from_millis(90));
    }

    #[test]
    fn the_shimmer_band_glides_every_frame_with_no_edge_and_no_rest() {
        let (n, font) = (23, 13.);
        let frame = FRAME.as_secs_f32() / SHIMMER_SWEEP.as_secs_f32();
        // A sweep takes 1.2–1.5 s and the band is about 60 pt wide.
        assert!((1200..=1500).contains(&SHIMMER_SWEEP.as_millis()));
        assert!((50. ..=70.).contains(&SHIMMER_BAND));
        // Every frame of a sweep (and across its wrap) changes the line: no
        // rest between sweeps.
        let mut still = 0;
        for k in 0..200 {
            let a = shimmer_weights(n, font, k as f32 * frame);
            let b = shimmer_weights(n, font, (k + 1) as f32 * frame);
            let moved = a
                .iter()
                .zip(&b)
                .map(|(x, y)| (x - y).abs())
                .fold(0., f32::max);
            if moved < 0.01 {
                still += 1;
            }
        }
        assert_eq!(still, 0, "frames with no visible change");
        // One frame never moves a character far (no stepping), and
        // neighbours differ softly (a feathered band, no hard edge).
        for k in 0..80 {
            let a = shimmer_weights(n, font, k as f32 * frame);
            let b = shimmer_weights(n, font, (k + 1) as f32 * frame);
            assert!(
                a.iter().zip(&b).all(|(x, y)| (x - y).abs() < 0.2),
                "{a:?} → {b:?}"
            );
            assert!(a.windows(2).all(|w| (w[1] - w[0]).abs() < 0.3), "{a:?}");
        }
        // It travels from the start of the line to its end, peaking short of
        // the full highlight.
        let peak_at = |phase: f32| {
            let w = shimmer_weights(n, font, phase);
            (0..n).max_by(|a, b| w[*a].total_cmp(&w[*b])).unwrap()
        };
        assert!(peak_at(0.3) < peak_at(0.5) && peak_at(0.5) < peak_at(0.7));
        let max = (0..100)
            .flat_map(|k| shimmer_weights(n, font, k as f32 / 100.))
            .fold(0., f32::max);
        assert!(max <= SHIMMER_PEAK + 1e-4 && max > 0.8, "{max}");
    }

    #[test]
    fn a_finished_answer_waits_briefly_for_its_suggestions() {
        let t0 = Instant::now();
        // Never seen streaming (opened finished): at once.
        assert!(settled(None, false, t0));
        // Just finished: waits, unless the suggestions are already in.
        assert!(!settled(Some(t0), false, t0 + Duration::from_millis(300)));
        assert!(settled(Some(t0), true, t0 + Duration::from_millis(300)));
        // …and never longer than the settle wait.
        assert!(settled(Some(t0), false, t0 + SETTLE_WAIT));
    }

    #[test]
    fn a_retargeted_tween_turns_from_where_it_is_and_takes_its_share_of_the_time() {
        let t0 = Instant::now();
        let spec = Spec::new(200, Curve::Linear);
        let mut tween = Tween::at(0., t0);
        tween.retarget(1., spec, 1., t0);
        let mid = t0 + Duration::from_millis(100);
        assert!((tween.value(mid) - 0.5).abs() < 1e-3);
        tween.retarget(0., spec, 1., mid);
        // No jump at the turn, and half the distance takes half the time.
        assert!((tween.value(mid) - 0.5).abs() < 1e-3);
        assert_eq!(tween.duration, Duration::from_millis(100));
        assert!(tween.moving(mid + Duration::from_millis(50)));
        assert!(!tween.moving(mid + Duration::from_millis(100)));
        assert_eq!(tween.value(mid + Duration::from_millis(100)), 0.);
    }

    #[test]
    fn a_tween_carries_on_after_a_stall_instead_of_landing_at_its_end() {
        let t0 = Instant::now();
        let spec = Spec::new(150, Curve::Linear);
        let mut tween = Tween::at(0., t0);
        tween.retarget(1., spec, 1., t0);
        // The frame it started in took 200 ms to draw.
        let late = t0 + Duration::from_millis(200);
        tween.skip_stall(t0, late);
        let v = tween.value(late);
        assert!((v - FRAME.as_secs_f32() / 0.15).abs() < 1e-3, "{v}");
        assert!(tween.moving(late));
        // Ordinary frames run on its clock.
        let mut steady = Tween::at(0., t0);
        steady.retarget(1., spec, 1., t0);
        let next = t0 + Duration::from_millis(17);
        steady.skip_stall(t0, next);
        assert!((steady.value(next) - 17. / 150.).abs() < 1e-3);
        // A tween at rest, or one not drawn for long, is left alone.
        let mut done = Tween::at(1., t0);
        done.skip_stall(t0, late);
        assert_eq!(done.start, t0);
        let mut away = Tween::at(0., t0);
        away.retarget(1., spec, 1., t0);
        away.skip_stall(t0, t0 + Duration::from_secs(2));
        assert_eq!(away.start, t0);
    }

    #[test]
    fn a_chase_keeps_its_speed_when_the_target_moves_and_never_overshoots() {
        let mut chase = Chase::new(0., 0.2);
        let mut target = 100.;
        let mut last = 0.;
        for frame in 0..60 {
            if frame == 6 {
                // More text arrived: the target moves on mid-flight.
                target = 160.;
            }
            let p = chase.step(target, 1. / 60.);
            assert!(p >= last - 1e-3, "it never turns back ({frame})");
            assert!(p <= target + 1e-3, "it never passes the end ({frame})");
            last = p;
        }
        assert!(chase.settled(target), "{chase:?}");
        // Most of the way within the response time.
        let mut c = Chase::new(0., 0.2);
        for _ in 0..12 {
            c.step(100., 1. / 60.);
        }
        assert!(c.position > 90., "{}", c.position);
    }

    #[test]
    fn appear_fades_without_travel_under_reduce_motion() {
        let half = appear_at(0.5, true, false);
        assert_eq!((half.opacity, half.travel), (0.5, 0.5));
        assert!(half.visible && !half.leaving);
        let reduced = appear_at(0.5, true, true);
        assert_eq!((reduced.opacity, reduced.travel), (0.5, 0.));
        let gone = appear_at(0., false, false);
        assert!(!gone.visible);
        let leaving = appear_at(0.3, false, false);
        assert!(leaving.visible && leaving.leaving);
    }
}
