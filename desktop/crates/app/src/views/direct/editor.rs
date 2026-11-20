//! Add Connection and Edit Connection: the Direct form ([`DirectView`]) in
//! a sheet on the Settings window, as Internet Accounts edits an account.
//! A saved Ollama connection also lists its models ([`OllamaModels`]).
//!
//! The footer holds Delete… (an existing connection), Test Connection,
//! Cancel and Save. Esc and ⌘. cancel, asking first when something was
//! changed; Save closes the sheet once the daemon has the connection.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::views::kit::Button;
use conduit_protocol::{DirectConnectionSummary, DirectKind, DirectRef, methods};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, Entity, FontWeight, Role, SharedString, Subscription,
    WeakEntity, Window, div, px, relative,
};

use super::form::{DirectEvent, DirectView};
use super::ollama::OllamaModels;
use crate::actions::SettingsChoice;
use crate::l10n::ActiveL10n as _;
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::views::forms;
use crate::views::sheet::{self, SheetBody};
use crate::views::words;

/// The sheet's width.
pub const WIDTH: f32 = 600.;

/// What runs after a save or a delete (the list refreshes).
pub type OnChange = Rc<dyn Fn(&mut App)>;

pub struct DirectEditorSheet {
    stores: Stores,
    pub form: Entity<DirectView>,
    pub ollama: Option<Entity<OllamaModels>>,
    /// The form as it opened, to tell whether it was changed.
    initial: String,
    pub deleting: bool,
    on_change: OnChange,
    _subscriptions: Vec<Subscription>,
}

impl DirectEditorSheet {
    /// Opens the editor on `parent` (the Settings window): `summary` to
    /// change, or a new connection (kept in the Open WebUI account when
    /// `open_web_ui`).
    pub fn open(
        stores: Stores,
        summary: Option<DirectConnectionSummary>,
        open_web_ui: bool,
        on_change: OnChange,
        parent: &Window,
        cx: &mut App,
    ) -> Option<Entity<Self>> {
        sheet::open(parent, WIDTH, cx, move |window, cx| {
            Self::new(stores, summary, open_web_ui, on_change, window, cx)
        })
    }

    fn new(
        stores: Stores,
        summary: Option<DirectConnectionSummary>,
        open_web_ui: bool,
        on_change: OnChange,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        // Kept in the account: the account it opened for, never the next.
        let in_account = summary.as_ref().map_or(open_web_ui, |c| c.open_web_ui);
        let ollama = summary
            .as_ref()
            .filter(|c| c.kind == DirectKind::Ollama && !c.open_web_ui)
            .map(|c| {
                let rpc = stores.connection.read(cx).rpc();
                let id = c.id.clone();
                cx.new(|cx| OllamaModels::new(rpc, id, window, cx))
            });
        let form = {
            let stores = stores.clone();
            cx.new(|cx| match summary {
                Some(c) => DirectView::editing(stores, c, window, cx),
                None if open_web_ui => DirectView::new_open_web_ui(stores, window, cx),
                None => DirectView::new(stores, false, window, cx),
            })
        };
        let initial = fingerprint(form.read(cx), cx);
        let mut subscriptions = vec![
            cx.observe(&form, |_, _, cx| cx.notify()),
            cx.subscribe(&form, |this: &mut Self, _, e: &DirectEvent, cx| match e {
                DirectEvent::Saved => {
                    (this.on_change)(cx);
                    sheet::dismiss(cx);
                }
            }),
        ];
        if in_account {
            subscriptions.push(sheet::close_with_account(&stores, cx));
        }
        if let Some(o) = &ollama {
            cx.observe(o, |_, _, cx| cx.notify()).detach();
        }
        // The name field first, as a new sheet's first field takes the
        // keyboard.
        let first = form.read(cx).name.clone();
        first.update(cx, |s, cx| s.focus(window, cx));
        Self {
            stores,
            form,
            ollama,
            initial,
            deleting: false,
            on_change,
            _subscriptions: subscriptions,
        }
    }

    pub fn is_dirty(&self, cx: &App) -> bool {
        fingerprint(self.form.read(cx), cx) != self.initial
    }

    pub fn delete(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(c) = self.form.read(cx).editing.clone() else {
            return;
        };
        let l10n = cx.l10n().clone();
        let spec = SheetSpec::new(
            l10n.desktop_direct_delete_title(&c.name),
            if c.open_web_ui {
                l10n.open_web_ui_direct_connection_delete_message(&c.name)
            } else {
                l10n.desktop_direct_delete_message()
            },
            l10n.delete(),
            l10n.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        let rpc = self.stores.connection.read(cx).rpc();
        let session = self.stores.session.clone();
        let on_change = self.on_change.clone();
        let form = self.form.downgrade();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if !ask.await {
                return;
            }
            let _ = this.update(cx, |s, cx| {
                s.deleting = true;
                cx.notify();
            });
            let result = rpc
                .call::<methods::DirectRemove>(&DirectRef { id: c.id.clone() })
                .await;
            session.update(cx, |s, cx| s.refresh(cx));
            match result {
                Ok(_) => cx.update(|cx| {
                    on_change(cx);
                    sheet::dismiss(cx);
                }),
                Err(e) => {
                    let _ = this.update(cx, |s, cx| {
                        s.deleting = false;
                        cx.notify();
                    });
                    let _ = form.update(cx, |f, cx| {
                        f.error = Some(words::connect_error(&e, &cx.l10n().clone()));
                        cx.notify();
                    });
                }
            }
        })
        .detach();
    }

    fn on_choice(&mut self, action: &SettingsChoice, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(o) = &self.ollama {
            let handled = o.update(cx, |o, cx| o.on_choice(action, window, cx));
            if handled {
                return;
            }
        }
        self.form
            .update(cx, |f, cx| f.on_choice(action, window, cx));
    }
}

/// Everything the form would send, as one string: two equal ones are the
/// same form. Secrets count as "typed" only.
fn fingerprint(f: &DirectView, cx: &App) -> String {
    let headers: Vec<String> = f
        .headers
        .iter()
        .map(|h| format!("{}={}", forms::text(&h.name, cx), forms::raw(&h.value, cx)))
        .collect();
    format!(
        "{:?}|{}|{}|{}|{}|{:?}|{:?}|{}|{}|{}|{}|{:?}|{}|{}|{}|{}|{}|{}|{}",
        f.preset,
        f.enabled,
        forms::text(&f.name, cx),
        forms::text(&f.base_url, cx),
        !forms::raw(&f.api_key, cx).is_empty(),
        f.auth,
        f.api_mode,
        forms::text(&f.api_version, cx),
        forms::text(&f.model_prefix, cx),
        forms::text(&f.tags, cx),
        f.manual_models.read(cx).value(),
        headers,
        f.clear_headers,
        f.certificate.is_some(),
        f.private_key.is_some(),
        f.clear_certificate,
        f.clear_private_key,
        f.self_signed,
        !forms::raw(&f.key_password, cx).is_empty(),
    )
}

impl SheetBody for DirectEditorSheet {
    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l10n = cx.l10n().clone();
        let form = self.form.read(cx);
        let editing = form.editing.is_some();
        let busy = form.busy || form.testing || self.deleting;
        let can_save = form.can_save(cx) && !self.deleting;
        let testing = form.testing;
        let saving = form.busy;
        let view = cx.entity().downgrade();
        let form_entity = self.form.downgrade();
        let delete = editing.then(|| {
            let view = view.clone();
            Button::new("direct-editor-delete", l10n.desktop_delete_ellipsis())
                .disabled(busy)
                .on_click(Rc::new(move |_, window, cx| {
                    let _ = view.update(cx, |v, cx| v.delete(window, cx));
                }))
        });
        let test = {
            let form = form_entity.clone();
            Button::new(
                "direct-editor-test",
                if testing {
                    l10n.desktop_testing()
                } else {
                    l10n.desktop_test_connection()
                },
            )
            .disabled(!can_save)
            .on_click(Rc::new(move |_, window, cx| {
                let _ = form.update(cx, |f, cx| f.test(window, cx));
            }))
        };
        let cancel = {
            let view = view.clone();
            Button::new("direct-editor-cancel", l10n.cancel()).on_click(Rc::new(
                move |_, window, cx| {
                    let _ = view.update(cx, |v, cx| v.cancel(window, cx));
                },
            ))
        };
        let save = Button::new(
            "direct-editor-save",
            if saving {
                l10n.desktop_saving()
            } else {
                l10n.save()
            },
        )
        .primary()
        .disabled(!can_save)
        .on_click(Rc::new(move |_, window, cx| {
            let _ = form_entity.update(cx, |f, cx| f.save(window, cx));
        }));
        Some(
            div()
                .w_full()
                .flex()
                .items_center()
                .gap(px(8.))
                .children(delete)
                .child(div().flex_1())
                .child(test)
                .child(cancel)
                .child(save)
                .into_any_element(),
        )
    }

    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.form.read(cx).busy || self.deleting {
            return;
        }
        if !self.is_dirty(cx) {
            sheet::dismiss(cx);
            return;
        }
        let l10n = cx.l10n().clone();
        let spec = SheetSpec::new(
            l10n.desktop_discard_changes_title(),
            l10n.desktop_discard_changes_message(),
            l10n.desktop_discard(),
            l10n.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        cx.spawn(async move |_, cx: &mut AsyncApp| {
            if ask.await {
                cx.update(sheet::dismiss);
            }
        })
        .detach();
    }

    fn label(&self, cx: &App) -> SharedString {
        let l10n = cx.l10n();
        if self.form.read(cx).editing.is_some() {
            l10n.desktop_edit_connection().into()
        } else {
            l10n.desktop_add_connection().into()
        }
    }
}

impl Render for DirectEditorSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let form = self.form.read(cx);
        let title = if form.editing.is_some() {
            l10n.desktop_edit_connection()
        } else {
            l10n.desktop_add_connection()
        };
        let subtitle = if form.open_web_ui {
            l10n.open_web_ui_direct_connection_editor_description()
        } else {
            l10n.desktop_direct_editor_subtitle()
        };
        let body = self.form.update(cx, |f, cx| {
            // The address as it is now, however it got there.
            f.follow_url_mode(cx);
            f.body(window, cx)
        });
        div()
            .id("direct-editor")
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
            .on_action(
                cx.listener(|this, a: &SettingsChoice, window, cx| this.on_choice(a, window, cx)),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(4.))
                    .child(
                        div()
                            .id("sheet-title")
                            .role(Role::Heading)
                            .text_size(px(t.metrics.body + 2.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(title),
                    )
                    .child(
                        div()
                            .text_size(px(t.metrics.small + 0.5))
                            .line_height(relative(1.4))
                            .text_color(t.roles.text_subtle)
                            .child(subtitle),
                    ),
            )
            .child(body)
            .children(self.ollama.clone())
    }
}

#[cfg(test)]
mod tests {
    use gpui_kit::TestAppContext;
    use serde_json::json;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;
    use crate::views::sheet::bench::{bench, switch_account};

    /// A connection kept in the account belongs to the account it was
    /// opened for: another account closes its sheet before it saves there.
    /// One kept on this Mac stays open.
    #[gpui_kit::test]
    fn an_account_connection_closes_with_its_account(cx: &mut TestAppContext) {
        for (open_web_ui, closes) in [(true, true), (false, false)] {
            let (daemon, stores, vcx) = bench(cx);
            let s = stores.clone();
            vcx.update(|window, cx| {
                DirectEditorSheet::open(s, None, open_web_ui, Rc::new(|_| {}), window, cx)
            })
            .unwrap();
            vcx.run_until_parked();
            switch_account(&stores, vcx);
            assert_eq!(
                vcx.update(|_, cx| sheet::current::<DirectEditorSheet>(cx))
                    .is_none(),
                closes,
                "open_web_ui {open_web_ui}"
            );
            assert!(daemon.calls::<methods::DirectSave>().is_empty());
        }
    }

    /// Only the private key's password typed: Cancel asks before it is
    /// thrown away.
    #[gpui_kit::test]
    fn a_typed_key_password_counts_as_a_change(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-editor-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let saved: DirectConnectionSummary = serde_json::from_value(json!({
            "id": "c1", "name": "Lab", "kind": "openai", "baseUrl": "https://llm.lab.example/v1",
            "hasApiKey": true, "customHeaderNames": [], "manualModelIds": [],
            "allowSelfSignedCertificates": false, "openRouter": false, "ollamaCloud": false,
            "openWebUi": false, "compatible": true, "tags": [],
            "certificateLabel": "lab.pem", "privateKeyLabel": "lab-key.pem"
        }))
        .unwrap();
        let (form, vcx) =
            cx.add_window_view(move |window, cx| DirectView::editing(stores, saved, window, cx));
        let before = form.read_with(vcx, fingerprint);
        let after = form.update_in(vcx, |f, window, cx| {
            f.key_password
                .update(cx, |i, cx| i.set_value("synthetic-pass", window, cx));
            fingerprint(f, cx)
        });
        assert_ne!(before, after, "the typed password would close unasked");
    }
}
