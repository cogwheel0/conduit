//! A video attached to a message, as the phone's `EnhancedVideoAttachment`
//! plays it: a tile with its name and Play Video; played, the movie is
//! fetched through the daemon's `/files` (with the server's credentials,
//! into the staging folder) and plays inline in AVKit's player, with its
//! own controls and full-screen button. Save… keeps a copy.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::views::kit::{Button, IconButton};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Context, ElementId, FontWeight, Role, SharedString, Window, div, px,
};

use super::inline_web::{InlineWebView, inline_web};
use crate::l10n::ActiveL10n as _;
use crate::stores::files::{FileRef, stage_file};

/// A video tile's height while it plays.
const PLAYER_HEIGHT: f32 = 300.;

#[derive(Clone, Default)]
enum Phase {
    #[default]
    Idle,
    Loading,
    Playing,
    Failed,
}

/// One video's state, kept while its tile is drawn.
#[derive(Default)]
pub struct VideoState {
    phase: Phase,
    path: Option<std::path::PathBuf>,
    view: Option<Rc<InlineWebView>>,
    save_failed: bool,
}

impl VideoState {
    fn play(&mut self, file: FileRef, name: String, window: &mut Window, cx: &mut Context<Self>) {
        self.phase = Phase::Loading;
        cx.notify();
        let staged = stage_file(file, &name, cx);
        cx.spawn_in(window, async move |this, cx| {
            let result = staged.await;
            let _ = this.update_in(cx, |s: &mut Self, window, cx| {
                match result {
                    Ok(path) => match InlineWebView::player(&path, window) {
                        Some(view) => {
                            s.view = Some(view);
                            s.path = Some(path);
                            s.phase = Phase::Playing;
                        }
                        None => s.phase = Phase::Failed,
                    },
                    Err(e) => {
                        log::warn!("video: {e}");
                        s.phase = Phase::Failed;
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn save(&mut self, name: String, cx: &mut Context<Self>) {
        let Some(from) = self.path.clone() else {
            return;
        };
        let home = std::env::var_os("HOME")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| "/".into());
        let downloads = home.join("Downloads");
        let dir = if downloads.is_dir() { downloads } else { home };
        let asked = cx.prompt_for_new_path(&dir, Some(&crate::stores::files::safe_name(&name)));
        cx.spawn(async move |this, cx| {
            let Ok(Ok(Some(path))) = asked.await else {
                return;
            };
            let failed = std::fs::copy(&from, &path).is_err();
            let _ = this.update(cx, |s: &mut Self, cx| {
                s.save_failed = failed;
                cx.notify();
            });
        })
        .detach();
    }
}

/// The tile for a video attached to a message.
pub fn video_tile(
    id: ElementId,
    file: FileRef,
    name: String,
    window: &mut Window,
    cx: &mut App,
) -> AnyElement {
    let state =
        window.use_keyed_state(ElementId::Name(format!("{id}-video").into()), cx, |_, _| {
            VideoState::default()
        });
    let t = cx.conduit().clone();
    let l10n = cx.l10n().clone();
    let r = t.roles;
    let m = t.metrics;
    let label = SharedString::from(l10n.desktop_video_label(&name));
    let s = state.read(cx);
    let phase = s.phase.clone();
    let view = s.view.clone();
    let save_failed = s.save_failed;
    match (phase, view) {
        (Phase::Playing, Some(view)) => {
            let full = view.clone();
            let save_state = state.clone();
            let save_name = name.clone();
            div()
                .id(id)
                .role(Role::Group)
                .aria_label(label)
                .w_full()
                .max_w(px(560.))
                .flex()
                .flex_col()
                .gap(px(4.))
                .child(
                    div()
                        .w_full()
                        .rounded(t.card_radius())
                        .overflow_hidden()
                        .bg(gpui_kit::black())
                        .child(inline_web(view, PLAYER_HEIGHT)),
                )
                .child(
                    div()
                        .flex()
                        .items_center()
                        .gap(px(4.))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .truncate()
                                .text_size(px(m.small))
                                .text_color(r.text_subtle)
                                .child(SharedString::from(name.clone())),
                        )
                        .when(save_failed, |d| {
                            d.child(
                                div()
                                    .text_size(px(m.small))
                                    .text_color(r.danger)
                                    .child(SharedString::from(l10n.desktop_preview_save_failed())),
                            )
                        })
                        .child(
                            IconButton::new(
                                "video-full-screen",
                                IconName::Maximize2,
                                l10n.desktop_video_full_screen(),
                            )
                            .size(24., 12.)
                            .tooltip(l10n.desktop_video_full_screen())
                            .on_click(Rc::new(move |_, _, _| full.enter_full_screen())),
                        )
                        .child(
                            IconButton::new(
                                "video-save",
                                IconName::Download,
                                l10n.desktop_preview_save(),
                            )
                            .size(24., 12.)
                            .tooltip(l10n.desktop_preview_save())
                            .on_click(Rc::new(move |_, _, cx| {
                                let name = save_name.clone();
                                save_state.update(cx, |s, cx| s.save(name, cx));
                            })),
                        ),
                )
                .into_any_element()
        }
        (phase, _) => {
            let loading = matches!(phase, Phase::Loading);
            let failed = matches!(phase, Phase::Failed);
            let play_state = state.clone();
            let play_name = name.clone();
            div()
                .id(id)
                .role(Role::Group)
                .aria_label(label)
                .w(px(300.))
                .h(px(64.))
                .px(px(12.))
                .flex()
                .items_center()
                .gap(px(10.))
                .rounded(t.card_radius())
                .border_1()
                .border_color(r.border)
                .bg(conduit_components::views::kit::raised_fill(&t))
                .child(icon(IconName::Film, 18., r.text_subtle))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .child(
                            div()
                                .truncate()
                                .text_size(px(m.control))
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(r.text)
                                .child(SharedString::from(name.clone())),
                        )
                        .when(failed, |d| {
                            d.child(
                                div()
                                    .text_size(px(m.small))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(l10n.desktop_video_load_failed())),
                            )
                        }),
                )
                .child(if loading {
                    super::blocks::spinner("video-loading", 14., r.text_subtle)
                } else {
                    Button::new(
                        "video-play",
                        if failed {
                            l10n.retry()
                        } else {
                            l10n.desktop_video_play()
                        },
                    )
                    .icon(IconName::Play)
                    .on_click(Rc::new(move |_, window, cx| {
                        let (file, name) = (file.clone(), play_name.clone());
                        play_state.update(cx, |s, cx| s.play(file, name, window, cx));
                    }))
                    .into_any_element()
                })
                .into_any_element()
        }
    }
}
