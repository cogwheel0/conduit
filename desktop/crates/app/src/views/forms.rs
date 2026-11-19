//! Form pieces the first-run screens and Settings share: labelled fields
//! over Kit inputs, an error line VoiceOver announces, a PEM file picker,
//! custom-header rows, and the server URL rules.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::announce::{Priority, live_text};
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::with_alpha;
use conduit_components::views::kit::{Button, ClickHandler, IconButton, bare_input, field_frame};
use gpui_kit::component::input::InputState;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, Div, ElementId, Entity, Hsla, PathPromptOptions, Role,
    SharedString, Window, div, px, relative,
};

/// The placeholders of the fields [`input`] made, drawn by [`field`] in the
/// tertiary label colour (macOS's placeholder colour). Kit draws its own
/// placeholder in the secondary colour, which reads as a typed value, so
/// these inputs get none of Kit's.
#[derive(Default)]
struct FieldHints(Vec<(gpui_kit::WeakEntity<InputState>, SharedString)>);

impl gpui_kit::Global for FieldHints {}

/// A new Kit input; `placeholder` (an example, or "Required") shows while
/// it is empty, inside its [`field`].
pub fn input<V: 'static>(
    placeholder: impl Into<SharedString>,
    masked: bool,
    window: &mut Window,
    cx: &mut Context<V>,
) -> Entity<InputState> {
    let placeholder = placeholder.into();
    let state = cx.new(|cx| InputState::new(window, cx).masked(masked));
    set_hint(&state, placeholder, cx);
    state
}

/// Replaces a field's placeholder (empty: none).
pub fn set_hint(state: &Entity<InputState>, hint: impl Into<SharedString>, cx: &mut App) {
    let hint = hint.into();
    let hints = &mut cx.default_global::<FieldHints>().0;
    // Forget the fields that are gone.
    hints.retain(|(w, _)| w.upgrade().is_some());
    hints.retain(|(w, _)| w.entity_id() != state.entity_id());
    if !hint.is_empty() {
        hints.push((state.downgrade(), hint));
    }
}

/// A field's placeholder, from [`input`] or [`set_hint`].
pub fn hint(state: &Entity<InputState>, cx: &App) -> Option<SharedString> {
    cx.try_global::<FieldHints>()?
        .0
        .iter()
        .find(|(w, _)| w.entity_id() == state.entity_id())
        .map(|(_, h)| h.clone())
}

/// Whether every one of `states` has text: a form's default button stays
/// off until its required fields are filled (Mail's account sheet).
pub fn filled(states: &[&Entity<InputState>], cx: &App) -> bool {
    states.iter().all(|s| !s.read(cx).value().trim().is_empty())
}

/// An input's text, trimmed.
pub fn text(state: &Entity<InputState>, cx: &App) -> String {
    state.read(cx).value().trim().to_string()
}

/// An input's text as typed (a password can begin or end with a space).
pub fn raw(state: &Entity<InputState>, cx: &App) -> String {
    state.read(cx).value().to_string()
}

/// After a submit fails: focus the field to fix, its text selected so
/// typing replaces it (Mail's account setup does this), so focus never
/// stays on a button or Back.
pub fn focus_invalid(state: &Entity<InputState>, window: &mut Window, cx: &mut App) {
    state.update(cx, |s, cx| {
        s.focus(window, cx);
        s.select_all(window, cx);
    });
}

/// The width of a form's label column: every row of every form starts its
/// value at the same edge (a longer translation wraps inside it).
pub const LABEL_COLUMN: f32 = 136.;

/// The one form spec onboarding and Settings share, as System Settings'
/// grouped forms: rows in an inset group (see [`form_group`]) split by
/// hairlines, each at least the switch row's height (44 pt compact), with
/// 12 pt insets and the control-size label. A switch row (`setting_row`)
/// matches it.
fn row_min_height(cx: &App) -> f32 {
    cx.conduit().metrics.row_height + 16.
}

/// A form row: the label in the label column, `value` after it. With
/// `first_line` (the height of the value's first line, a field's box), the
/// label sits on that line, as NSGridView's first-baseline rows do: a
/// field's help hangs under the field alone and never pulls its label
/// down. Without it the label centres on the value (a segmented control).
fn labelled_row(label: &SharedString, value: AnyElement, first_line: Option<f32>, cx: &App) -> Div {
    let t = cx.conduit().clone();
    let m = t.metrics;
    let min_height = row_min_height(cx);
    let label_box = div()
        .debug_selector(|| "form-label".into())
        .flex_none()
        .w(px(LABEL_COLUMN))
        .text_size(px(m.control))
        .line_height(relative(1.25))
        .text_color(t.roles.text)
        .child(label.clone());
    let row = div()
        .w_full()
        .min_h(px(min_height))
        .px(px(12.))
        .flex()
        .gap(px(12.));
    match first_line {
        Some(line) => {
            // The same top and bottom room a field without help has.
            let pad = first_line_pad(min_height, line);
            row.items_start()
                .pt(px(pad))
                .pb(px(pad))
                .child(label_box.min_h(px(line)).flex().items_center())
                .child(div().flex_1().min_w_0().child(value))
        }
        None => row
            .py(px(6.))
            .items_center()
            .child(label_box)
            .child(div().flex_1().min_w_0().flex().items_center().child(value)),
    }
}

/// The room above (and below) a first-baseline row's value: what centres
/// a value of `line` in a row of `min_height`, and never less than 6 pt.
pub fn first_line_pad(min_height: f32, line: f32) -> f32 {
    ((min_height - line) / 2.).max(6.)
}

/// A field box's height (its first line, which its label sits on).
fn field_height(cx: &App) -> f32 {
    cx.conduit().metrics.control_height - 4.
}

/// Rows of a form in one inset group, hairlines between them (as Settings'
/// groups and the chooser's).
pub fn form_group(rows: Vec<AnyElement>, cx: &App) -> Div {
    conduit_components::views::kit::grouped(rows, cx)
}

/// A note under a [`form_group`], as a grouped section's footer.
pub fn group_footer(text: impl Into<SharedString>, cx: &App) -> Div {
    let t = cx.conduit();
    div()
        .px(px(12.))
        .text_size(px(t.metrics.small))
        .line_height(relative(1.35))
        .text_color(t.roles.text_subtle)
        .child(text.into())
}

/// A control (a segmented choice) on a form row, its label in the same
/// column as the fields' labels and the control where their values start.
pub fn form_row(label: impl Into<SharedString>, control: impl IntoElement, cx: &App) -> Div {
    let label = label.into();
    labelled_row(&label, control.into_any_element(), None, cx)
}

/// The buttons at the end of a form, as a Mac dialog's: push buttons at
/// the trailing edge, the default (primary) one last, where Return goes.
pub fn form_buttons(buttons: Vec<AnyElement>) -> Div {
    div()
        .w_full()
        .pt(px(4.))
        .flex()
        .items_center()
        .justify_end()
        .gap(px(8.))
        .children(buttons)
}

/// A text field's fill and hairline: a shade into the card it sits on, so
/// it reads as a place to type (System Settings › Internet Accounts).
pub fn field_tones(t: &conduit_components::theme::ConduitTheme) -> (Hsla, Hsla) {
    let (_, card) = conduit_components::views::kit::grouped_tones(t);
    let r = t.roles;
    if t.dark {
        // The dark ramp's step above the group (#232323 on #181818).
        (
            conduit_components::views::kit::field_fill(t),
            with_alpha(r.text, 0.16),
        )
    } else {
        (
            conduit_components::theme::mix(card, r.text, 0.035),
            with_alpha(r.text, 0.13),
        )
    }
}

/// The field's corner radius.
const FIELD_RADIUS: f32 = 5.;

/// The field itself: an inset box with the input, its placeholder (in the
/// tertiary colour) while empty, a red edge with an error, and while it has
/// the caret, the one focus ring every control draws (2 pt, 2 pt out).
fn field_box(
    label: &SharedString,
    state: &Entity<InputState>,
    hint: Option<SharedString>,
    error: bool,
    locked: bool,
    window: &Window,
    cx: &App,
) -> Div {
    use conduit_components::views::focus::{Ring, ring_overlay};
    let t = cx.conduit().clone();
    let r = t.roles;
    let m = t.metrics;
    let focused = gpui_kit::Focusable::focus_handle(state.read(cx), cx).is_focused(window);
    let empty = state.read(cx).value().is_empty();
    let (fill, hairline) = field_tones(&t);
    // A soft shade along the top edge: the box reads as set into the row.
    let inset = gpui_kit::BoxShadow {
        color: with_alpha(gpui_kit::black(), if t.dark { 0.28 } else { 0.06 }),
        offset: gpui_kit::point(px(0.), px(0.5)),
        blur_radius: px(1.5),
        spread_radius: px(0.),
        inset: true,
    };
    div()
        .debug_selector(|| "form-field-box".into())
        .relative()
        .w_full()
        .h(px(field_height(cx)))
        .px(px(7.))
        .flex()
        .items_center()
        .rounded(px(FIELD_RADIUS))
        .bg(fill)
        .border_1()
        .border_color(if error { r.danger } else { hairline })
        .shadow(vec![inset])
        .when(focused, |d| {
            d.child(ring_overlay(Ring::Outset(FIELD_RADIUS), &t))
        })
        // Under the input (painted first), so the caret and clicks are the
        // input's.
        .when_some(hint.filter(|_| empty), |d, h| {
            d.child(
                div()
                    .absolute()
                    .top_0()
                    .bottom_0()
                    .left(px(7.))
                    .right(px(7.))
                    .flex()
                    .items_center()
                    .overflow_hidden()
                    .text_size(px(m.control))
                    .text_color(r.text_faint)
                    .child(div().truncate().child(h)),
            )
        })
        .child(
            div()
                .flex_1()
                .min_w_0()
                .child(bare_input(state, label.clone(), m.control).disabled(locked)),
        )
}

/// A labelled field, a row of a [`form_group`]: the label in the label
/// column, the inset field after it with its placeholder ([`input`]), and
/// help or the error (the error wins) under the field, inside the row.
pub fn field(
    label: impl Into<SharedString>,
    state: &Entity<InputState>,
    help: Option<SharedString>,
    error: Option<SharedString>,
    window: &Window,
    cx: &App,
) -> Div {
    let hint = hint(state, cx);
    field_hinted(label, state, hint, help, error, window, cx)
}

/// A field's error that answers a request (a Save, a Test), with the
/// sheet's count of answered requests: the one attempt its other live
/// regions take too, so each answer is heard, even in the words of the one
/// before (see [`conduit_components::announce::LiveText::attempt`]).
pub struct Answer {
    pub error: Option<SharedString>,
    pub attempt: u64,
}

/// [`field_locked`] whose error is an [`Answer`].
pub fn field_answered(
    label: impl Into<SharedString>,
    state: &Entity<InputState>,
    help: Option<SharedString>,
    answer: Answer,
    locked: bool,
    window: &Window,
    cx: &App,
) -> Div {
    let hint = hint(state, cx);
    let Answer { error, attempt } = answer;
    field_with(label, state, hint, help, error, locked, attempt, window, cx)
}

/// [`field`] that takes no typing while `locked`: a form whose save or test
/// is out, so what it answers is the form as it stands (nothing typed
/// meanwhile is closed over or judged by an older answer).
pub fn field_locked(
    label: impl Into<SharedString>,
    state: &Entity<InputState>,
    help: Option<SharedString>,
    error: Option<SharedString>,
    locked: bool,
    window: &Window,
    cx: &App,
) -> Div {
    let hint = hint(state, cx);
    field_with(label, state, hint, help, error, locked, 0, window, cx)
}

/// [`field`] with its placeholder given here (one input that serves two
/// labels, as sign-in's email or LDAP user name).
pub fn field_hinted(
    label: impl Into<SharedString>,
    state: &Entity<InputState>,
    hint: Option<SharedString>,
    help: Option<SharedString>,
    error: Option<SharedString>,
    window: &Window,
    cx: &App,
) -> Div {
    field_with(label, state, hint, help, error, false, 0, window, cx)
}

#[allow(clippy::too_many_arguments)]
fn field_with(
    label: impl Into<SharedString>,
    state: &Entity<InputState>,
    hint: Option<SharedString>,
    help: Option<SharedString>,
    error: Option<SharedString>,
    locked: bool,
    attempt: u64,
    window: &Window,
    cx: &App,
) -> Div {
    let t = cx.conduit().clone();
    let r = t.roles;
    let m = t.metrics;
    let label = label.into();
    let help = error.clone().or(help);
    let help_id = SharedString::from(format!("{label}-help"));
    let value = div()
        .w_full()
        .flex()
        .flex_col()
        .gap(px(4.))
        .child(field_box(
            &label,
            state,
            hint,
            error.is_some(),
            locked,
            window,
            cx,
        ))
        .when_some(help, |d, h| {
            d.child(
                div()
                    .id(help_id)
                    .when(error.is_some(), |d| d.role(Role::Alert))
                    // Heard when it appears, as the phone's field errors.
                    .child(live_text("live", error.clone(), Priority::High).attempt(attempt))
                    .text_size(px(m.small))
                    .line_height(relative(1.35))
                    .text_color(if error.is_some() {
                        conduit_components::theme::legible_text(
                            r.danger,
                            r.text,
                            conduit_components::views::kit::grouped_tones(&t).1,
                            4.5,
                        )
                    } else {
                        r.text_subtle
                    })
                    .child(h),
            )
        });
    div().relative().w_full().child(labelled_row(
        &label,
        value.into_any_element(),
        Some(field_height(cx)),
        cx,
    ))
}

/// A form-level error, announced when it appears.
pub fn form_error(
    id: &'static str,
    message: impl Into<SharedString>,
    cx: &App,
) -> gpui_kit::Stateful<Div> {
    form_error_answered(id, message, 0, cx)
}

/// [`form_error`] answering a request: heard again for each `attempt` (see
/// [`field_answered`]).
pub fn form_error_answered(
    id: &'static str,
    message: impl Into<SharedString>,
    attempt: u64,
    cx: &App,
) -> gpui_kit::Stateful<Div> {
    let t = cx.conduit().clone();
    let r = t.roles;
    let message = message.into();
    let color = conduit_components::theme::legible_text(r.danger, r.text, t.surfaces.window, 4.5);
    div()
        .id(id)
        .role(Role::Alert)
        .aria_label(message.clone())
        .w_full()
        .px(px(12.))
        .py(px(9.))
        .flex()
        .items_start()
        .gap(px(8.))
        .rounded(px(8.))
        .bg(conduit_components::theme::with_alpha(
            r.danger,
            if t.dark { 0.16 } else { 0.08 },
        ))
        .text_size(px(t.metrics.control))
        .line_height(relative(1.4))
        .text_color(color)
        .child(
            div()
                .pt(px(2.))
                .child(icon(IconName::CircleAlert, 14., color)),
        )
        // Wraps rather than running past the form's edge.
        .child(div().flex_1().min_w_0().child(message.clone()))
        .child(live_text("live", Some(message), Priority::High).attempt(attempt))
}

/// A status line under a form (a test result, "Saved"), announced when it
/// appears or changes.
pub fn form_note(message: impl Into<SharedString>, ok: bool, cx: &App) -> gpui_kit::Stateful<Div> {
    form_note_answered(message, ok, 0, cx)
}

/// [`form_note`] answering a request: heard again for each `attempt` (see
/// [`field_answered`]).
pub fn form_note_answered(
    message: impl Into<SharedString>,
    ok: bool,
    attempt: u64,
    cx: &App,
) -> gpui_kit::Stateful<Div> {
    let t = cx.conduit().clone();
    let r = t.roles;
    let color = if ok {
        conduit_components::theme::legible_text(r.success, r.text, t.surfaces.window, 4.5)
    } else {
        r.text_subtle
    };
    let message = message.into();
    div()
        .id("form-note")
        .role(Role::Status)
        .flex()
        .items_center()
        .gap(px(6.))
        .text_size(px(t.metrics.small))
        .text_color(color)
        .when(ok, |d| d.child(icon(IconName::CircleCheck, 13., color)))
        .child(message.clone())
        .child(live_text("live", Some(message), Priority::Medium).attempt(attempt))
}

/// The URL a user typed, as the daemon takes it: an absolute http(s) URL
/// with a host. No scheme means https, or http for a local address.
pub fn normalize_url(raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    let with_scheme = if raw.contains("://") {
        raw.to_string()
    } else {
        // A bracketed IPv6 literal (`[::1]:8080`) is one host.
        let host = match raw.strip_prefix('[') {
            Some(rest) => rest.split(']').next().unwrap_or_default(),
            None => raw.split(['/', ':']).next().unwrap_or_default(),
        };
        let local = host == "localhost"
            || host.ends_with(".local")
            || host.parse::<std::net::IpAddr>().is_ok();
        format!("{}://{raw}", if local { "http" } else { "https" })
    };
    let url = url::Url::parse(&with_scheme).ok()?;
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none_or(str::is_empty) {
        return None;
    }
    Some(with_scheme.trim_end_matches('/').to_string())
}

/// The host of `url`, for a default name and the server chip.
pub fn host_of(url: &str) -> String {
    url::Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(str::to_string))
        .unwrap_or_else(|| url.to_string())
}

/// Why custom headers were refused.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HeaderError {
    /// Row `index` (from 0) has a value but no name.
    MissingName(usize),
    /// Row `index` has a name a request cannot carry.
    InvalidName(usize),
    /// Two rows set `name`.
    Duplicate(String),
}

/// Custom header rows as a map: empty rows are skipped, names must be
/// HTTP tokens, and a name may appear once.
pub fn headers_from_rows(
    rows: &[(String, String)],
) -> Result<BTreeMap<String, String>, HeaderError> {
    let mut out = BTreeMap::new();
    for (i, (name, value)) in rows.iter().enumerate() {
        let (name, value) = (name.trim(), value.trim());
        if name.is_empty() && value.is_empty() {
            continue;
        }
        if name.is_empty() {
            return Err(HeaderError::MissingName(i));
        }
        let token = name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b));
        if !token {
            return Err(HeaderError::InvalidName(i));
        }
        if out.keys().any(|k: &String| k.eq_ignore_ascii_case(name)) {
            return Err(HeaderError::Duplicate(name.to_string()));
        }
        out.insert(name.to_string(), value.to_string());
    }
    Ok(out)
}

/// The custom headers an edit sends, from the rows typed: the window knows
/// saved headers by name only, so the daemon adds the ones sent to them (an
/// empty value takes one away). With Clear, every saved header not typed
/// again is taken away; nothing typed and no Clear sends nothing.
pub fn headers_edit(
    typed: BTreeMap<String, String>,
    clear: bool,
    saved: &[String],
) -> Option<BTreeMap<String, String>> {
    if typed.is_empty() {
        return clear.then(BTreeMap::new);
    }
    let mut out = typed;
    if clear {
        for name in saved {
            if !out.keys().any(|k| k.eq_ignore_ascii_case(name)) {
                out.insert(name.clone(), String::new());
            }
        }
    }
    Some(out)
}

/// Called with a row's index.
pub type RowHandler = Rc<dyn Fn(usize, &mut Window, &mut App)>;

/// One custom-header row: a name and a value input.
pub struct HeaderRow {
    pub name: Entity<InputState>,
    pub value: Entity<InputState>,
}

/// Renders header rows with a remove button each.
pub fn header_rows(
    rows: &[HeaderRow],
    name_label: SharedString,
    value_label: SharedString,
    remove_label: SharedString,
    on_remove: RowHandler,
    cx: &App,
) -> Div {
    header_rows_locked(
        rows,
        name_label,
        value_label,
        remove_label,
        on_remove,
        false,
        cx,
    )
}

/// [`header_rows`] that take no typing, and remove nothing, while `locked`
/// (as [`field_locked`]).
pub fn header_rows_locked(
    rows: &[HeaderRow],
    name_label: SharedString,
    value_label: SharedString,
    remove_label: SharedString,
    on_remove: RowHandler,
    locked: bool,
    cx: &App,
) -> Div {
    let t = cx.conduit().clone();
    let h = t.metrics.control_height + 2.;
    div()
        .flex()
        .flex_col()
        .gap(px(6.))
        .children(rows.iter().enumerate().map(|(i, row)| {
            let remove = on_remove.clone();
            // A placeholder a field was given (a kept value's "configured"
            // note) shows under its input while it is empty.
            let placed = |state: &Entity<InputState>, label: &SharedString| {
                let shown = hint(state, cx).filter(|_| state.read(cx).value().is_empty());
                field_frame(false, h, cx)
                    .relative()
                    .flex_1()
                    .when_some(shown, |d, h| {
                        d.child(
                            div()
                                .absolute()
                                .top_0()
                                .bottom_0()
                                .left(px(7.))
                                .right(px(7.))
                                .flex()
                                .items_center()
                                .overflow_hidden()
                                .text_size(px(t.metrics.control))
                                .text_color(t.roles.text_faint)
                                .child(div().truncate().child(h)),
                        )
                    })
                    .child(div().flex_1().min_w_0().child(
                        bare_input(state, label.clone(), t.metrics.control).disabled(locked),
                    ))
            };
            div()
                .flex()
                .items_center()
                .gap(px(6.))
                .child(placed(&row.name, &name_label))
                .child(placed(&row.value, &value_label))
                .child(
                    IconButton::new(
                        ElementId::NamedInteger("remove-header".into(), i as u64),
                        IconName::X,
                        remove_label.clone(),
                    )
                    .size(24., 14.)
                    .disabled(locked)
                    .on_click(Rc::new(move |_, window, cx| remove(i, window, cx))),
                )
        }))
}

/// A PEM file the user picked: its name (shown, and sent as the label) and
/// its text (sent to the daemon, never shown).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PemFile {
    pub label: String,
    pub pem: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PemError {
    /// Not a PEM file with a `marker` block.
    NotPem,
    Unreadable(String),
}

/// Whether `text` holds a PEM block whose label contains `marker`
/// (`CERTIFICATE`, `PRIVATE KEY`).
pub fn contains_pem_block(text: &str, marker: &str) -> bool {
    text.lines().any(|l| {
        let l = l.trim();
        l.starts_with("-----BEGIN ") && l.ends_with("-----") && l.contains(marker)
    })
}

/// Asks for a file with the system picker and reads it as PEM.
pub fn pick_pem(
    marker: &'static str,
    cx: &mut App,
) -> gpui_kit::Task<Result<Option<PemFile>, PemError>> {
    let paths = cx.prompt_for_paths(PathPromptOptions {
        files: true,
        directories: false,
        multiple: false,
        prompt: None,
    });
    cx.spawn(async move |_: &mut AsyncApp| {
        let path: Option<PathBuf> = match paths.await {
            Ok(Ok(Some(mut p))) => p.pop(),
            Ok(Ok(None)) | Err(_) => None,
            Ok(Err(e)) => return Err(PemError::Unreadable(e.to_string())),
        };
        let Some(path) = path else { return Ok(None) };
        let text =
            std::fs::read_to_string(&path).map_err(|e| PemError::Unreadable(e.to_string()))?;
        if !contains_pem_block(&text, marker) {
            return Err(PemError::NotPem);
        }
        let label = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        Ok(Some(PemFile { label, pem: text }))
    })
}

/// The labels of a [`pem_picker`].
pub struct PemLabels {
    pub choose: SharedString,
    pub replace: SharedString,
    pub clear: SharedString,
}

/// "Choose file…" with the chosen file's name and a Clear button.
pub fn pem_picker(
    id: &'static str,
    file: Option<&PemFile>,
    labels: PemLabels,
    on_choose: ClickHandler,
    on_clear: ClickHandler,
    cx: &App,
) -> Div {
    pem_picker_locked(id, file, labels, on_choose, on_clear, false, cx)
}

/// [`pem_picker`] that picks and clears nothing while `locked`.
pub fn pem_picker_locked(
    id: &'static str,
    file: Option<&PemFile>,
    labels: PemLabels,
    on_choose: ClickHandler,
    on_clear: ClickHandler,
    locked: bool,
    cx: &App,
) -> Div {
    let PemLabels {
        choose: choose_label,
        replace: replace_label,
        clear: clear_label,
    } = labels;
    let t = cx.conduit().clone();
    let r = t.roles;
    div()
        .flex()
        .items_center()
        .gap(px(8.))
        .when_some(file, |d, f| {
            d.child(
                div()
                    .max_w(px(180.))
                    .truncate()
                    .font_family(conduit_components::theme::MONO_FONT)
                    .text_size(px(t.metrics.small))
                    .text_color(r.text_subtle)
                    .child(f.label.clone()),
            )
            .child(
                Button::new(
                    SharedString::from(format!("{id}-clear")),
                    clear_label.clone(),
                )
                .ghost()
                .disabled(locked)
                .on_click(on_clear),
            )
        })
        .child(
            Button::new(
                SharedString::from(id),
                if file.is_some() {
                    replace_label
                } else {
                    choose_label
                },
            )
            .disabled(locked)
            .on_click(on_choose),
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Two fields: an address with an example, a name with none.
    struct Bench {
        address: Entity<InputState>,
        name: Entity<InputState>,
    }

    impl Render for Bench {
        fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            form_group(
                vec![
                    field("Address", &self.address, None, None, window, cx).into_any_element(),
                    field(
                        "Name",
                        &self.name,
                        None,
                        Some("Required".into()),
                        window,
                        cx,
                    )
                    .into_any_element(),
                ],
                cx,
            )
        }
    }

    #[gpui_kit::test]
    fn placeholders_stay_with_their_field_and_filled_needs_text_in_each(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        use conduit_components::theme::{ConduitTheme, DesignPrefs, install};
        cx.update(|cx| {
            gpui_kit::init(cx);
            install(
                ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
                cx,
            );
        });
        let (view, vcx) = cx.add_window_view(|window, cx| Bench {
            address: input("https://chat.example.org", false, window, cx),
            name: input("", false, window, cx),
        });
        vcx.update(|window, cx| window.draw(cx).clear(cx));
        vcx.update(|window, cx| {
            let (address, name) = {
                let v = view.read(cx);
                (v.address.clone(), v.name.clone())
            };
            assert_eq!(
                hint(&address, cx).as_deref(),
                Some("https://chat.example.org")
            );
            assert_eq!(hint(&name, cx), None);
            assert!(!filled(&[&address], cx));
            address.update(cx, |i, cx| i.set_value("   ", window, cx));
            assert!(!filled(&[&address], cx), "blanks are not an address");
            address.update(cx, |i, cx| i.set_value("chat.example.org", window, cx));
            assert!(filled(&[&address], cx));
            assert!(!filled(&[&address, &name], cx));
            set_hint(&name, "Required", cx);
            assert_eq!(hint(&name, cx).as_deref(), Some("Required"));
            set_hint(&name, "", cx);
            assert_eq!(hint(&name, cx), None);
            assert_eq!(
                hint(&address, cx).as_deref(),
                Some("https://chat.example.org")
            );
        });
        // The field draws with its error, the hint under the empty input.
        vcx.update(|window, cx| window.draw(cx).clear(cx));
    }

    #[test]
    fn urls_get_a_scheme_and_must_have_a_host() {
        assert_eq!(
            normalize_url(" chat.example.org/ ").as_deref(),
            Some("https://chat.example.org")
        );
        assert_eq!(
            normalize_url("192.168.1.10:8080").as_deref(),
            Some("http://192.168.1.10:8080")
        );
        assert_eq!(
            normalize_url("localhost:3000").as_deref(),
            Some("http://localhost:3000")
        );
        // A bracketed IPv6 address is local like an IPv4 one.
        assert_eq!(
            normalize_url("[::1]:8080").as_deref(),
            Some("http://[::1]:8080")
        );
        assert_eq!(
            normalize_url("http://box.local/owui").as_deref(),
            Some("http://box.local/owui")
        );
        for bad in ["", "   ", "ftp://x.org", "https://", "file:///etc/hosts"] {
            assert_eq!(normalize_url(bad), None, "{bad}");
        }
        assert_eq!(
            host_of("https://chat.example.org:8443/x"),
            "chat.example.org"
        );
    }

    #[test]
    fn header_rows_validate() {
        let rows = |r: &[(&str, &str)]| -> Vec<(String, String)> {
            r.iter()
                .map(|(a, b)| (a.to_string(), b.to_string()))
                .collect()
        };
        assert_eq!(
            headers_from_rows(&rows(&[("X-Proxy-Token", " abc "), ("", "")])),
            Ok(BTreeMap::from([("X-Proxy-Token".into(), "abc".into())]))
        );
        assert_eq!(
            headers_from_rows(&rows(&[("", "v")])),
            Err(HeaderError::MissingName(0))
        );
        assert_eq!(
            headers_from_rows(&rows(&[("a", "1"), ("Bad Name", "2")])),
            Err(HeaderError::InvalidName(1))
        );
        assert_eq!(
            headers_from_rows(&rows(&[("X-A", "1"), ("x-a", "2")])),
            Err(HeaderError::Duplicate("x-a".into()))
        );
    }

    #[test]
    fn pem_blocks_are_recognised_by_their_label() {
        let cert = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n";
        // Written in parts so the source holds no key-shaped text.
        let key = concat!(
            "-----BEGIN EC PRIVATE",
            " KEY-----\nMHc\n-----END EC PRIVATE",
            " KEY-----"
        );
        assert!(contains_pem_block(cert, "CERTIFICATE"));
        assert!(!contains_pem_block(cert, "PRIVATE KEY"));
        assert!(contains_pem_block(key, "PRIVATE KEY"));
        assert!(!contains_pem_block("not pem", "CERTIFICATE"));
    }
}
