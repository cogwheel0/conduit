//! Release notes, as the phone shows them: after an update, a banner in
//! the main window ("What's New in 0.9.0", Learn More, close); its sheet
//! (the notes since the last version seen, Buy Me a Coffee, Done); and
//! About › What's New, which shows the newest note again.
//!
//! The notes describe this app, so the desktop ships its own catalog
//! (`assets/release_notes/<locale>.json`, core's format); core decides what
//! shows and remembers what was seen (`releaseNotes.*`).
//!
//! The sheet is one of the app's window sheets ([`crate::views::sheet`]):
//! on the main window from the banner, on Settings from About. One sheet
//! is down at a time.

use std::collections::BTreeMap;
use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::views::kit::{Button, IconButton};
use conduit_protocol::{ReleaseNoteDto, ReleaseNotesQuery, ReleaseNotesState, methods};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, AnyWindowHandle, App, Context, Div, Entity, FocusHandle, Global, Role,
    SharedString, Window, div, px, relative,
};

use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::stores::session::Route;
use crate::views::sheet::{self, SheetBody};

/// The sheet's width (Add Account's).
pub const WIDTH: f32 = 480.;

/// The desktop's catalog, one document per locale (core's format).
pub const CATALOGS: [(&str, &str); 14] = [
    ("cs", include_str!("../../assets/release_notes/cs.json")),
    ("de", include_str!("../../assets/release_notes/de.json")),
    ("en", include_str!("../../assets/release_notes/en.json")),
    ("es", include_str!("../../assets/release_notes/es.json")),
    ("fr", include_str!("../../assets/release_notes/fr.json")),
    ("it", include_str!("../../assets/release_notes/it.json")),
    ("ja", include_str!("../../assets/release_notes/ja.json")),
    ("ko", include_str!("../../assets/release_notes/ko.json")),
    ("nl", include_str!("../../assets/release_notes/nl.json")),
    ("pl", include_str!("../../assets/release_notes/pl.json")),
    ("ru", include_str!("../../assets/release_notes/ru.json")),
    ("sk", include_str!("../../assets/release_notes/sk.json")),
    ("zh", include_str!("../../assets/release_notes/zh.json")),
    (
        "zh_Hant",
        include_str!("../../assets/release_notes/zh_Hant.json"),
    ),
];

/// `releaseNotes.*`'s params for `version` in the app's language
/// (`zh_Hant` is Chinese in the Traditional script).
pub fn query(version: &str, locale: &str) -> ReleaseNotesQuery {
    let mut parts = locale.splitn(2, ['_', '-']);
    let language = parts.next().unwrap_or("en").to_string();
    let rest = parts.next().map(str::to_string);
    let (script, country) = match rest {
        Some(r) if r.len() == 4 => (Some(r), None),
        Some(r) => (None, Some(r)),
        None => (None, None),
    };
    ReleaseNotesQuery {
        current_version: version.to_string(),
        language_code: language,
        script_code: script,
        country_code: country,
        catalogs: CATALOGS
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect::<BTreeMap<_, _>>(),
    }
}

/// What the banner shows, once core decided.
#[derive(Default)]
pub struct ReleaseNotes {
    pub banner: Option<ReleaseNotesState>,
    /// Checked in this daemon session.
    checked: bool,
}

pub struct ReleaseNotesGlobal(pub Entity<ReleaseNotes>);

impl Global for ReleaseNotesGlobal {}

fn notes(cx: &App) -> Option<Entity<ReleaseNotes>> {
    cx.try_global::<ReleaseNotesGlobal>().map(|g| g.0.clone())
}

/// Checks once per daemon session, when the main window has a session to
/// show (the phone runs it once its backend is set up).
pub fn install(stores: &Stores, cx: &mut App) {
    let entity = cx.new(|_| ReleaseNotes::default());
    cx.set_global(ReleaseNotesGlobal(entity.clone()));
    {
        let entity = entity.clone();
        cx.subscribe(&stores.connection, move |_, event, cx| {
            if let crate::stores::connection::ConnectionEvent::Connected { .. } = event {
                entity.update(cx, |n, _| n.checked = false);
            }
        })
        .detach();
    }
    let s = stores.clone();
    cx.observe(&stores.session, move |_, cx| {
        let main = s.session.read(cx).route(cx) == Route::Main;
        if main && notes(cx).is_some_and(|n| !n.read(cx).checked) {
            check(crate::VERSION, &s, cx);
        }
    })
    .detach();
}

/// `releaseNotes.check` for `version` (the E2E pass names one).
pub fn check(version: &str, stores: &Stores, cx: &mut App) {
    let Some(entity) = notes(cx) else { return };
    entity.update(cx, |n, _| n.checked = true);
    let q = query(version, cx.l10n().locale());
    let call = stores
        .connection
        .read(cx)
        .rpc()
        .call::<methods::ReleaseNotesCheck>(&q);
    cx.spawn(async move |cx| {
        let result = call.await;
        entity.update(cx, |n, cx| {
            match result {
                Ok(state) => n.banner = state.banner.then_some(state),
                Err(e) => {
                    // Asked again when the session changes next.
                    log::warn!("releaseNotes.check: {e}");
                    n.checked = false;
                }
            }
            cx.notify();
        });
    })
    .detach();
}

/// The banner's close button: gone until the next update.
pub fn dismiss(stores: &Stores, cx: &mut App) {
    let Some(entity) = notes(cx) else { return };
    entity.update(cx, |n, cx| {
        n.banner = None;
        cx.notify();
    });
    let call = stores
        .connection
        .read(cx)
        .rpc()
        .call::<methods::ReleaseNotesDismiss>(&conduit_protocol::NoParams);
    cx.background_spawn(async move {
        if let Err(e) = call.await {
            log::debug!("releaseNotes.dismiss: {e}");
        }
    })
    .detach();
}

fn stores(cx: &App) -> Option<Stores> {
    cx.try_global::<crate::AppState>().map(|s| s.stores.clone())
}

/// The after-update banner, over the main window's content (or none).
pub fn banner(window: &mut Window, cx: &mut App) -> Option<Div> {
    let state = notes(cx)?.read(cx).banner.clone()?;
    let l10n = cx.l10n().clone();
    let t = cx.conduit().clone();
    let r = t.roles;
    let title = l10n.release_notes_announcement_title(&state.current_version);
    let learn = Button::new(
        "release-notes-learn",
        l10n.desktop_release_notes_learn_more(),
    )
    .ghost()
    .on_click(Rc::new(|_, window, cx| show_banner_notes(window, cx)));
    let close = IconButton::new(
        "release-notes-dismiss",
        IconName::X,
        l10n.desktop_release_dismiss(),
    )
    .size(22., 12.)
    .on_click(Rc::new(|_, _, cx| {
        if let Some(s) = stores(cx) {
            dismiss(&s, cx);
        }
    }));
    let _ = window;
    Some(
        div()
            .absolute()
            .top(px(conduit_components::window::TOOLBAR_HEIGHT + 6.))
            .left_0()
            .right_0()
            .flex()
            .justify_center()
            .px(px(16.))
            .child(
                div()
                    .id("release-notes-banner")
                    .role(Role::Status)
                    .aria_label(SharedString::from(title.clone()))
                    .max_w(px(560.))
                    .min_h(px(32.))
                    .pl(px(12.))
                    .pr(px(5.))
                    .py(px(3.))
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .rounded(px(16.))
                    .bg(conduit_components::views::kit::raised_fill(&t))
                    .border_1()
                    .border_color(r.border)
                    .shadow(conduit_components::views::kit::pill_shadow(&t))
                    .text_size(px(t.metrics.small))
                    .text_color(r.text)
                    .child(icon(IconName::Megaphone, 14., r.text).flex_none())
                    .child(
                        div()
                            .min_w_0()
                            .font_weight(gpui_kit::FontWeight::MEDIUM)
                            .child(SharedString::from(title)),
                    )
                    .child(learn)
                    .child(close),
            ),
    )
}

/// Learn More: the banner's notes in a sheet; the banner goes once read.
pub fn show_banner_notes(window: &mut Window, cx: &mut App) {
    let Some(state) = notes(cx).and_then(|n| n.read(cx).banner.clone()) else {
        return;
    };
    open_sheet(state.notes, true, window, cx);
}

/// About › What's New: the newest note at or before this version.
pub fn show_latest(window: &mut Window, cx: &mut App) {
    let Some(s) = stores(cx) else { return };
    let q = query(crate::VERSION, cx.l10n().locale());
    let call = s
        .connection
        .read(cx)
        .rpc()
        .call::<methods::ReleaseNotesLatest>(&q);
    let parent = window.window_handle();
    cx.spawn(async move |cx| {
        let notes = match call.await {
            Ok(state) => state.notes,
            Err(e) => {
                log::warn!("releaseNotes.latest: {e}");
                return;
            }
        };
        let _ = parent.update(cx, |_, window, cx| open_sheet(notes, false, window, cx));
    })
    .detach();
}

/// Opens the notes as a window sheet on `window` (the main window, or
/// Settings for About). Another sheet already down keeps the keyboard and
/// this one does not open.
pub fn open_sheet(
    items: Vec<ReleaseNoteDto>,
    from_banner: bool,
    window: &mut Window,
    cx: &mut App,
) {
    let stores = stores(cx);
    sheet::open(window, WIDTH, cx, move |window, cx| {
        ReleaseNotesSheet::new(items, from_banner, stores, window, cx)
    });
}

/// The window of the release notes' sheet, while it is down.
pub fn sheet_window(cx: &App) -> Option<AnyWindowHandle> {
    sheet::current::<ReleaseNotesSheet>(cx).and_then(|_| sheet::current_window(cx))
}

/// Closes the sheet; from the banner, the banner goes too.
pub fn close_sheet(from_banner: bool, cx: &mut App) {
    if sheet::current::<ReleaseNotesSheet>(cx).is_some() {
        sheet::dismiss(cx);
    }
    if from_banner && let Some(s) = stores(cx) {
        dismiss(&s, cx);
    }
}

/// The sheet: the phone's title, the newest note's introduction, every
/// note's lines, then "Enjoying Conduit?" with Buy Me a Coffee, and Done.
pub struct ReleaseNotesSheet {
    pub notes: Vec<ReleaseNoteDto>,
    from_banner: bool,
    /// Held so Return reaches the sheet (Done is its default button).
    focus: FocusHandle,
    coffee: Option<String>,
}

impl ReleaseNotesSheet {
    pub fn new(
        notes: Vec<ReleaseNoteDto>,
        from_banner: bool,
        stores: Option<Stores>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        // Core's support link, as About has it.
        if let Some(stores) = stores {
            let call = stores
                .connection
                .read(cx)
                .rpc()
                .call::<methods::SettingsAbout>(&conduit_protocol::NoParams);
            cx.spawn(async move |this, cx| {
                if let Ok(about) = call.await {
                    let _ = this.update(cx, |s: &mut Self, cx| {
                        s.coffee = Some(about.buy_me_a_coffee_url).filter(|u| !u.is_empty());
                        cx.notify();
                    });
                }
            })
            .detach();
        }
        Self {
            notes,
            from_banner,
            focus,
            coffee: None,
        }
    }

    pub fn done(&mut self, cx: &mut Context<Self>) {
        let from_banner = self.from_banner;
        cx.defer(move |cx| close_sheet(from_banner, cx));
    }
}

impl SheetBody for ReleaseNotesSheet {
    /// Esc, ⌘. and ⌘W: as Done (there is nothing to lose).
    fn cancel(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        self.done(cx);
    }

    fn label(&self, cx: &App) -> SharedString {
        cx.l10n().release_notes_title().into()
    }

    /// "Enjoying Conduit?", Buy Me a Coffee and Done, which stay put while
    /// the notes scroll.
    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let done = Button::new("release-notes-done", l10n.release_notes_done_button())
            .primary()
            .on_click(Rc::new(move |_, _, cx| {
                let _ = view.update(cx, |v, cx| v.done(cx));
            }));
        let coffee = self.coffee.clone().map(|url| {
            Button::new("release-notes-coffee", l10n.buy_me_a_coffee_title())
                .icon(IconName::Coffee)
                .on_click(Rc::new(move |_, _, cx| cx.open_url(&url)))
        });
        Some(
            div()
                .w_full()
                .flex()
                .items_center()
                .gap(px(8.))
                .child(
                    div()
                        .flex_1()
                        .text_size(px(t.metrics.small))
                        .text_color(t.roles.text_subtle)
                        .child(SharedString::from(
                            l10n.release_notes_support_prompt_heading(),
                        )),
                )
                .children(coffee)
                .child(done)
                .into_any_element(),
        )
    }
}

fn bullet_icon(name: Option<&str>) -> IconName {
    match name {
        Some("local") => IconName::Lock,
        Some("hermes") => IconName::Bot,
        Some("direct") => IconName::Zap,
        _ => IconName::Sparkles,
    }
}

impl Render for ReleaseNotesSheet {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let l10n = cx.l10n().clone();
        let intro = self
            .notes
            .last()
            .map(|n| n.intro.clone())
            .unwrap_or_default();
        let bullets: Vec<_> = self
            .notes
            .iter()
            .flat_map(|n| n.bullets.iter().cloned())
            .collect();
        div()
            .id("release-notes-sheet")
            .track_focus(&self.focus)
            // Return is Done, the default button (Esc is the host's).
            .on_key_down(cx.listener(|this, e: &gpui_kit::KeyDownEvent, _, cx| {
                let k = &e.keystroke;
                let plain = !(k.modifiers.platform || k.modifiers.alt || k.modifiers.control);
                if plain && k.key == "enter" {
                    this.done(cx);
                    cx.stop_propagation();
                }
            }))
            .w_full()
            .flex()
            .flex_col()
            .gap(px(14.))
            .child(
                div()
                    .id("release-notes-title")
                    .role(Role::Heading)
                    .text_size(px(m.control + 7.))
                    .font_weight(gpui_kit::FontWeight::BOLD)
                    .child(SharedString::from(l10n.release_notes_title())),
            )
            .when(!intro.is_empty(), |d| {
                d.child(
                    div()
                        .text_size(px(m.control))
                        .line_height(relative(1.45))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(intro)),
                )
            })
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(10.))
                    .children(bullets.into_iter().map(|b| {
                        div()
                            .flex()
                            .items_start()
                            .gap(px(10.))
                            .child(
                                div()
                                    .mt(px(1.))
                                    .size(px(24.))
                                    .flex_none()
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .rounded(px(6.))
                                    .bg(conduit_components::theme::with_alpha(r.text, 0.07))
                                    .child(icon(bullet_icon(b.icon.as_deref()), 13., r.text)),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .text_size(px(m.control))
                                    .line_height(relative(1.45))
                                    .child(SharedString::from(b.text)),
                            )
                    })),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locales_split_into_core_s_parts() {
        let q = query("0.9.0-beta.4", "zh_Hant");
        assert_eq!(q.language_code, "zh");
        assert_eq!(q.script_code.as_deref(), Some("Hant"));
        assert_eq!(q.country_code, None);
        let de = query("1.0.0", "de");
        assert_eq!(de.language_code, "de");
        assert!(de.script_code.is_none() && de.country_code.is_none());
        assert_eq!(de.catalogs.len(), 14);
    }

    #[test]
    fn every_catalog_is_core_s_format_with_the_same_versions() {
        let versions = |text: &str| -> Vec<String> {
            let v: serde_json::Value = serde_json::from_str(text).unwrap();
            v["notes"]
                .as_array()
                .unwrap()
                .iter()
                .map(|n| {
                    assert!(n["title"].as_str().is_some_and(|s| !s.is_empty()));
                    assert!(n["intro"].as_str().is_some_and(|s| !s.is_empty()));
                    let bullets = n["bullets"].as_array().unwrap();
                    assert!(!bullets.is_empty());
                    for b in bullets {
                        assert!(b["text"].as_str().is_some_and(|s| !s.is_empty()));
                    }
                    n["version"].as_str().unwrap().to_string()
                })
                .collect()
        };
        let english = versions(CATALOGS[2].1);
        assert!(!english.is_empty());
        for (locale, text) in CATALOGS {
            assert_eq!(versions(text), english, "{locale}");
        }
    }

    #[gpui_kit::test]
    fn a_check_that_failed_is_asked_again(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        daemon.once::<methods::ReleaseNotesCheck>(Err(conduit_daemon::protocol::error(
            "rpc.timeout",
            "slow",
        )));
        let scratch = std::env::temp_dir().join(format!("conduit-notes-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            let stores = Stores::for_test(daemon.rpc(), &scratch, cx);
            install(&stores, cx);
            stores
        });
        cx.update(|cx| check("1.0.0", &stores, cx));
        cx.run_until_parked();
        let checked = cx.update(|cx| notes(cx).map(|n| n.read(cx).checked));
        assert_eq!(checked, Some(false), "a failed check is never asked again");
    }

    #[gpui_kit::test]
    fn the_notes_never_open_over_another_sheet(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        let scratch =
            std::env::temp_dir().join(format!("conduit-notes-sheet-{}", std::process::id()));
        cx.update(|cx| {
            crate::views::test_globals(cx);
            let stores = Stores::for_test(daemon.rpc(), &scratch, cx);
            install(&stores, cx);
        });
        let other = cx.add_empty_window();
        let handle = other.window_handle();
        let body = other.update(|_, cx| cx.new(|_| ()));
        other.update(|window, cx| {
            crate::views::sheet::adopt(handle, body.into_any(), cx);
            open_sheet(vec![], false, window, cx);
        });
        let sheet = cx.update(|cx| sheet::current::<ReleaseNotesSheet>(cx));
        assert!(sheet.is_none(), "the notes opened over another sheet");
    }
}
