//! An Ollama connection's models, in its editor sheet: mobile's model
//! actions (its picker's "…" per model), on the Mac where the connection is
//! set up. A server on this Mac or the network shows which models are in
//! memory, with Load or Unload and how long each stays loaded after a chat
//! (`direct.ollamaLoad` / `ollamaUnload` / `ollamaKeepAlive`); Ollama
//! Cloud has no memory to manage, and offers each model's thinking level
//! instead (`direct.ollamaThinking`).

use std::collections::BTreeSet;
use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::views::kit::{Button, grouped_section, setting_row};
use conduit_protocol::{DirectRef, OllamaModelAction, OllamaModelList, OllamaModelStatus, methods};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncWindowContext, Context, ElementId, Entity, SharedString, Subscription,
    WeakEntity, Window, div, px,
};

use crate::actions::SettingsChoice;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::rpc::Rpc;
use crate::views::forms::{self, form_error};
use crate::views::model_logo;
use crate::views::settings::controls::{self, Choice};

/// Menus: `direct-ollama-keep:<model>`, `direct-ollama-think:<model>`.
pub const MENU_KEEP: &str = "direct-ollama-keep:";
pub const MENU_THINK: &str = "direct-ollama-think:";

const SERVER_DEFAULT: &str = "__default__";
const CUSTOM: &str = "__custom__";
const AUTOMATIC: &str = "__automatic__";

/// The keep-alive presets, as mobile's.
const KEEP_ALIVES: [&str; 5] = ["5m", "30m", "1h", "-1", "0"];

pub struct OllamaModels {
    rpc: Rpc,
    /// The connection.
    pub id: String,
    pub list: Option<OllamaModelList>,
    pub failed: bool,
    /// Models with a load, unload or setting in flight.
    pub busy: BTreeSet<String>,
    pub error: Option<String>,
    /// The model whose custom keep-alive is being typed.
    pub custom: Option<String>,
    pub custom_input: Entity<InputState>,
    _subscriptions: Vec<Subscription>,
}

impl OllamaModels {
    pub fn new(rpc: Rpc, id: String, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let custom_input = forms::input("10m", false, window, cx);
        let subscriptions = vec![cx.subscribe_in(
            &custom_input,
            window,
            |this: &mut Self, _, e: &InputEvent, window, cx| {
                if let InputEvent::PressEnter { .. } = e {
                    this.save_custom(window, cx);
                }
            },
        )];
        let mut this = Self {
            rpc,
            id,
            list: None,
            failed: false,
            busy: BTreeSet::new(),
            error: None,
            custom: None,
            custom_input,
            _subscriptions: subscriptions,
        };
        this.refresh(window, cx);
        this
    }

    pub fn refresh(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::DirectOllamaModels>(&DirectRef {
            id: self.id.clone(),
        });
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(list) => {
                            s.list = Some(list);
                            s.failed = false;
                        }
                        Err(e) => {
                            log::warn!("direct.ollamaModels: {e}");
                            s.failed = true;
                        }
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// Runs one model action and adopts the list it answers with.
    fn act<M>(
        &mut self,
        model: &str,
        value: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) where
        M: conduit_daemon::RpcMethod<Params = OllamaModelAction, Result = OllamaModelList>,
    {
        if self.busy.contains(model) {
            return;
        }
        self.busy.insert(model.to_string());
        self.error = None;
        cx.notify();
        let call = self.rpc.call::<M>(&OllamaModelAction {
            id: self.id.clone(),
            model: model.to_string(),
            value,
        });
        let model = model.to_string();
        let l10n = cx.l10n().clone();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    s.busy.remove(&model);
                    match result {
                        Ok(list) => {
                            s.list = Some(list);
                            if M::NAME == <methods::DirectOllamaKeepAlive as conduit_daemon::RpcMethod>::NAME
                                && s.custom.as_deref() == Some(model.as_str())
                            {
                                s.custom = None;
                            }
                        }
                        Err(e) => {
                            log::warn!("{}: {e}", M::NAME);
                            s.error = Some(match e.code {
                                conduit_protocol::ErrorCode::InvalidParams => {
                                    l10n.desktop_ollama_keep_alive_invalid()
                                }
                                _ => l10n.desktop_ollama_action_failed(),
                            });
                        }
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    pub fn load(&mut self, model: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.act::<methods::DirectOllamaLoad>(model, None, window, cx);
    }

    pub fn unload(&mut self, model: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.act::<methods::DirectOllamaUnload>(model, None, window, cx);
    }

    fn save_custom(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(model) = self.custom.clone() else {
            return;
        };
        let value = forms::text(&self.custom_input, cx);
        if value.is_empty() {
            return;
        }
        // Open until the daemon takes it: a refused duration keeps what
        // was typed.
        self.act::<methods::DirectOllamaKeepAlive>(&model, Some(value), window, cx);
    }

    /// A pop-up's pick, when it is one of these.
    pub fn on_choice(
        &mut self,
        action: &SettingsChoice,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if let Some(model) = action.menu.strip_prefix(MENU_KEEP) {
            let model = model.to_string();
            match action.value.as_str() {
                CUSTOM => {
                    let current = self.status(&model).and_then(|m| m.keep_alive.clone());
                    self.custom_input.update(cx, |s, cx| {
                        s.set_value(current.unwrap_or_default(), window, cx);
                        s.focus(window, cx);
                    });
                    self.custom = Some(model);
                    cx.notify();
                }
                SERVER_DEFAULT => {
                    self.act::<methods::DirectOllamaKeepAlive>(&model, None, window, cx)
                }
                value => self.act::<methods::DirectOllamaKeepAlive>(
                    &model,
                    Some(value.to_string()),
                    window,
                    cx,
                ),
            }
            return true;
        }
        if let Some(model) = action.menu.strip_prefix(MENU_THINK) {
            let value = (action.value != AUTOMATIC).then(|| action.value.clone());
            self.act::<methods::DirectOllamaThinking>(model, value, window, cx);
            return true;
        }
        false
    }

    fn status(&self, model: &str) -> Option<&OllamaModelStatus> {
        self.list.as_ref()?.models.iter().find(|m| m.id == model)
    }

    fn keep_alive_label(value: Option<&str>, l10n: &L10n) -> String {
        match value {
            None => l10n.ollama_keep_alive_server_default(),
            Some("5m") => l10n.desktop_ollama_five_minutes(),
            Some("30m") => l10n.desktop_ollama_thirty_minutes(),
            Some("1h") => l10n.desktop_ollama_one_hour(),
            Some("-1") => l10n.ollama_keep_alive_always(),
            Some("0") => l10n.ollama_keep_alive_immediate(),
            Some(other) => other.to_string(),
        }
    }

    fn row(
        &self,
        m: &OllamaModelStatus,
        list: &OllamaModelList,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let busy = self.busy.contains(&m.id);
        let this = cx.entity().downgrade();
        let mut controls_row = div().flex().items_center().gap(px(8.));
        let subtitle: Option<SharedString> = if list.cloud {
            None
        } else {
            match m.loaded {
                Some(true) => Some(l10n.desktop_ollama_in_memory().into()),
                Some(false) => Some(l10n.desktop_ollama_not_in_memory().into()),
                None => None,
            }
        };
        if list.lifecycle {
            let loaded = m.loaded == Some(true);
            let id = m.id.clone();
            controls_row = controls_row.child(
                Button::new(
                    ElementId::Name(format!("ollama-memory-{}", m.id).into()),
                    if loaded {
                        l10n.ollama_unload_model()
                    } else {
                        l10n.ollama_load_model()
                    },
                )
                .disabled(busy)
                .on_click(Rc::new(move |_, window, cx| {
                    let _ = this.update(cx, |s, cx| {
                        if loaded {
                            s.unload(&id, window, cx)
                        } else {
                            s.load(&id, window, cx)
                        }
                    });
                })),
            );
            let mut choices = vec![Choice::new(
                SERVER_DEFAULT,
                l10n.ollama_keep_alive_server_default(),
            )];
            choices.extend(KEEP_ALIVES.iter().map(|v| {
                let c = Choice::new(*v, Self::keep_alive_label(Some(v), l10n));
                if *v == "5m" { c.separated() } else { c }
            }));
            let current = m.keep_alive.clone();
            if let Some(custom) = current.as_deref().filter(|c| !KEEP_ALIVES.contains(c)) {
                choices.push(Choice::new(custom, custom).separated());
            }
            choices.push(Choice::new(CUSTOM, l10n.desktop_custom_ellipsis()).separated());
            controls_row = controls_row.child(controls::popup(
                &format!("{MENU_KEEP}{}", m.id),
                &l10n.desktop_ollama_keep_alive_for(&m.name),
                choices,
                current.as_deref().unwrap_or(SERVER_DEFAULT),
                busy,
                window,
                cx,
            ));
        }
        if list.cloud {
            let choices = vec![
                Choice::new(AUTOMATIC, l10n.desktop_effort_automatic()),
                Choice::new("disabled", l10n.desktop_thinking_off()).separated(),
                Choice::new("low", l10n.desktop_effort_low()),
                Choice::new("medium", l10n.desktop_effort_medium()),
                Choice::new("high", l10n.desktop_effort_high()),
            ];
            controls_row = controls_row.child(controls::popup(
                &format!("{MENU_THINK}{}", m.id),
                &l10n.desktop_ollama_thinking_for(&m.name),
                choices,
                m.thinking.as_deref().unwrap_or(AUTOMATIC),
                busy,
                window,
                cx,
            ));
        }
        let mut row = div()
            .w_full()
            .flex()
            .flex_col()
            .child(model_logo::model_row(
                m.logo.as_deref(),
                m.name.clone(),
                subtitle,
                controls_row,
                cx,
            ));
        if self.custom.as_deref() == Some(m.id.as_str()) {
            let save = {
                let this = cx.entity().downgrade();
                Rc::new(
                    move |_: &gpui_kit::ClickEvent, window: &mut Window, cx: &mut App| {
                        let _ = this.update(cx, |s, cx| s.save_custom(window, cx));
                    },
                )
            };
            let cancel = {
                let this = cx.entity().downgrade();
                Rc::new(
                    move |_: &gpui_kit::ClickEvent, _: &mut Window, cx: &mut App| {
                        let _ = this.update(cx, |s, cx| {
                            s.custom = None;
                            cx.notify();
                        });
                    },
                )
            };
            row = row.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .pr(px(12.))
                    .pb(px(8.))
                    .child(div().flex_1().child(forms::field(
                        l10n.ollama_keep_alive(),
                        &self.custom_input,
                        Some(l10n.desktop_ollama_keep_alive_help().into()),
                        None,
                        window,
                        cx,
                    )))
                    .child(Button::new("ollama-custom-cancel", l10n.cancel()).on_click(cancel))
                    .child(
                        Button::new("ollama-custom-save", l10n.desktop_set())
                            .primary()
                            .on_click(save),
                    ),
            );
        }
        row.into_any_element()
    }
}

impl Render for OllamaModels {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let title: SharedString = l10n.desktop_ollama_models().into();
        let mut d = div().flex().flex_col().gap(px(8.));
        match self.list.clone() {
            None => {
                d = d.child(grouped_section(
                    Some(title),
                    vec![
                        setting_row(
                            if self.failed {
                                l10n.desktop_ollama_models_failed()
                            } else {
                                l10n.desktop_loading()
                            },
                            None,
                            div(),
                            cx,
                        )
                        .into_any_element(),
                    ],
                    None,
                    cx,
                ));
            }
            Some(list) => {
                let rows: Vec<AnyElement> = if list.models.is_empty() {
                    vec![
                        setting_row(l10n.desktop_no_models_available(), None, div(), cx)
                            .into_any_element(),
                    ]
                } else {
                    list.models
                        .iter()
                        .map(|m| self.row(m, &list, &l10n, window, cx))
                        .collect()
                };
                let footer: SharedString = if list.cloud {
                    l10n.desktop_ollama_thinking_help().into()
                } else {
                    l10n.desktop_ollama_memory_help().into()
                };
                d = d.child(grouped_section(Some(title), rows, Some(footer), cx));
            }
        }
        let _ = t;
        d.when_some(self.error.clone(), |d, e| {
            d.child(form_error("ollama-error", e, cx))
        })
    }
}

#[cfg(test)]
mod tests {
    use conduit_protocol::methods;
    use gpui_kit::TestAppContext;

    use super::*;
    use crate::stores::Stores;
    use crate::stores::rpc::fake::FakeDaemon;

    /// A duration the daemon refuses keeps its editor, and what was typed.
    #[gpui_kit::test]
    fn a_refused_duration_keeps_what_was_typed(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-ollama-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        daemon.on::<methods::DirectOllamaKeepAlive>(|_| {
            Err(conduit_daemon::protocol::error(
                "rpc.invalidParams",
                "not a duration",
            ))
        });
        let rpc = stores.connection.read_with(cx, |c, _| c.rpc());
        let (view, vcx) =
            cx.add_window_view(move |window, cx| OllamaModels::new(rpc, "c1".into(), window, cx));
        view.update_in(vcx, |v, window, cx| {
            v.custom = Some("lab-model".into());
            v.custom_input
                .update(cx, |i, cx| i.set_value("ten minutes", window, cx));
            v.save_custom(window, cx);
        });
        vcx.run_until_parked();
        view.read_with(vcx, |v, cx| {
            assert!(v.error.is_some());
            assert_eq!(
                v.custom.as_deref(),
                Some("lab-model"),
                "the editor closed on a refused duration"
            );
            assert_eq!(forms::text(&v.custom_input, cx), "ten minutes");
        });
    }

    #[test]
    fn keep_alive_presets_are_ollama_durations() {
        assert_eq!(KEEP_ALIVES, ["5m", "30m", "1h", "-1", "0"]);
        assert!(MENU_KEEP.ends_with(':') && MENU_THINK.ends_with(':'));
    }
}
