//! Open WebUI's question or approval waiting in the open chat
//! (`chatPrompts.*`), on a card docked above the composer like the
//! approvals card, as the phone's `OpenWebUiPromptOverlay` shows it:
//!
//! * **Questions** (`ask_user`, a coding agent's questions): one at a time,
//!   "1 of 2" in the corner; each a list of choices with their
//!   descriptions, and an Other field where the server takes the user's
//!   own words. Previous and Next walk the questions (Next once this one
//!   is answered), Submit sends every answer once all are, Cancel
//!   declines.
//! * **A tool approval:** "Allow Get Current Timestamp?" over the call's
//!   arguments; Deny or Approve.
//! * **A confirmation:** the server's title and message; Cancel or
//!   Confirm.
//!
//! ⌥⌘↩ is the primary button (Submit, Approve, Confirm), ⌥⌘⌫ the other
//! one, as on the approvals card (which answers first when both show).
//! While an answer is on its way the buttons wait and the card says
//! "Answering…"; a refusal says so on the card. The card comes and goes as
//! the approvals card does.

use std::collections::HashMap;
use std::rc::Rc;

use conduit_components::assets::IconName;
use conduit_components::motion::{self, specs};
use conduit_components::views::approval::{
    ALLOW_KEYS, ApprovalAction, ApprovalCard, ApprovalKind, DENY_KEYS, SelectOption,
};
use conduit_protocol::{ChatPromptAnswerItem, ChatPromptDto, ChatPromptKind};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, ClickEvent, Context, Entity, SharedString, Subscription, Window, div,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::chat::ChatStore;
use crate::views::approvals::{ApprovalsView, tool_question};
use crate::views::forms;

/// One question's answer so far.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Choice {
    pub option: Option<usize>,
    /// The user's own words are the answer.
    pub other: bool,
    pub text: String,
}

impl Choice {
    fn answered(&self) -> bool {
        (self.other && !self.text.trim().is_empty()) || (!self.other && self.option.is_some())
    }
}

/// Every question answered, each in a way it accepts.
pub fn complete(prompt: &ChatPromptDto, answers: &HashMap<String, Choice>) -> bool {
    !prompt.questions.is_empty()
        && prompt.questions.iter().all(|q| {
            answers.get(&q.id).is_some_and(|c| {
                if c.other {
                    q.allow_other && !c.text.trim().is_empty()
                } else {
                    c.option.is_some_and(|i| i < q.options.len())
                }
            })
        })
}

/// What `chatPrompts.answer` sends.
pub fn answer_items(
    prompt: &ChatPromptDto,
    answers: &HashMap<String, Choice>,
) -> Vec<ChatPromptAnswerItem> {
    prompt
        .questions
        .iter()
        .filter_map(|q| {
            let c = answers.get(&q.id)?;
            Some(if c.other {
                ChatPromptAnswerItem {
                    question_id: q.id.clone(),
                    option_index: None,
                    text: Some(c.text.trim().to_string()),
                }
            } else {
                ChatPromptAnswerItem {
                    question_id: q.id.clone(),
                    option_index: c.option.map(|i| i as i64),
                    text: None,
                }
            })
        })
        .collect()
}

pub struct PromptCard {
    store: Option<Entity<ChatStore>>,
    /// The prompt the state below belongs to.
    for_prompt: Option<String>,
    index: usize,
    answers: HashMap<String, Choice>,
    other: Entity<InputState>,
    /// The last prompt drawn, shown while its card leaves.
    last: Option<ChatPromptDto>,
    /// The prompt and question whose own words the Other field holds.
    other_for: Option<(String, usize)>,
    _store: Option<Subscription>,
    _subscriptions: Vec<Subscription>,
}

impl PromptCard {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        // The phone's hint for a question's own answer, as Kit draws it: the
        // card's field is a bare Kit input, not a form `field`.
        let hint = cx.l10n().open_web_ui_prompt_answer_hint();
        let other = cx.new(|cx| InputState::new(window, cx).placeholder(hint));
        let subscriptions = vec![cx.subscribe_in(
            &other,
            window,
            |this: &mut Self, state, e: &InputEvent, _, cx| match e {
                InputEvent::Change | InputEvent::Focus => {
                    let text = forms::raw(state, cx);
                    if let Some(q) = this.question_id(cx) {
                        let choice = this.answers.entry(q).or_default();
                        // Typing (or focusing the field) picks the own
                        // words, as on the phone. A question's own text
                        // put back in the field changes nothing.
                        if matches!(e, InputEvent::Focus) {
                            choice.other = true;
                        } else if text != choice.text {
                            choice.other = !text.is_empty() || choice.other;
                            choice.text = text;
                        }
                        cx.notify();
                    }
                }
                InputEvent::PressEnter { .. } => {
                    this.primary(cx);
                }
                InputEvent::Blur => {}
            },
        )];
        Self {
            store: None,
            for_prompt: None,
            index: 0,
            answers: HashMap::new(),
            other,
            last: None,
            other_for: None,
            _store: None,
            _subscriptions: subscriptions,
        }
    }

    /// The open chat's store (none for a new chat).
    pub fn set_store(&mut self, store: Option<Entity<ChatStore>>, cx: &mut Context<Self>) {
        self._store = store
            .as_ref()
            .map(|s| cx.observe(s, |_, _, cx| cx.notify()));
        self.store = store;
        self.last = None;
        cx.notify();
    }

    fn prompt(&self, cx: &App) -> Option<ChatPromptDto> {
        self.store.as_ref()?.read(cx).prompt.clone()
    }

    /// The waiting prompt, only while it is the one last drawn: a key
    /// answers what the user sees, never a prompt that replaced it since.
    fn drawn(&self, cx: &App) -> Option<ChatPromptDto> {
        self.prompt(cx)
            .filter(|p| self.for_prompt.as_deref() == Some(p.id.as_str()))
    }

    pub fn has_prompt(&self, cx: &App) -> bool {
        self.prompt(cx).is_some()
    }

    fn question_id(&self, cx: &App) -> Option<String> {
        self.prompt(cx)?
            .questions
            .get(self.index)
            .map(|q| q.id.clone())
    }

    fn busy(&self, cx: &App) -> bool {
        self.store.as_ref().is_some_and(|s| s.read(cx).prompt_busy)
    }

    /// Starts over for a new prompt.
    fn sync(&mut self, prompt: &ChatPromptDto, window: &mut Window, cx: &mut Context<Self>) {
        if self.for_prompt.as_deref() == Some(prompt.id.as_str()) {
            return;
        }
        self.for_prompt = Some(prompt.id.clone());
        self.index = 0;
        self.answers.clear();
        self.other_for = None;
        let _ = (window, cx);
    }

    /// The Other field shows the question on screen's own words.
    fn load_other(&mut self, prompt: &ChatPromptDto, window: &mut Window, cx: &mut Context<Self>) {
        let text = prompt
            .questions
            .get(self.index)
            .and_then(|q| self.answers.get(&q.id))
            .map(|c| c.text.clone())
            .unwrap_or_default();
        self.other.update(cx, |i, cx| i.set_value(text, window, cx));
    }

    pub fn pick(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(prompt) = self.prompt(cx) else {
            return;
        };
        let Some(q) = prompt.questions.get(self.index) else {
            return;
        };
        let choice = self.answers.entry(q.id.clone()).or_default();
        if index < q.options.len() {
            choice.option = Some(index);
            choice.other = false;
        } else if q.allow_other {
            choice.other = true;
        }
        cx.notify();
    }

    pub fn step(&mut self, by: isize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(prompt) = self.prompt(cx) else {
            return;
        };
        let next = self.index as isize + by;
        if next < 0 || next as usize >= prompt.questions.len() {
            return;
        }
        self.index = next as usize;
        let _ = (prompt, window);
        cx.notify();
    }

    /// ⌥⌘↩ (and Return in the Other field): Submit, Next, Approve or
    /// Confirm. Whether the card acted.
    pub fn primary(&mut self, cx: &mut Context<Self>) -> bool {
        let Some(prompt) = self.drawn(cx) else {
            return false;
        };
        if self.busy(cx) {
            return true;
        }
        let Some(store) = self.store.clone() else {
            return false;
        };
        match prompt.kind {
            ChatPromptKind::AskUser => {
                if complete(&prompt, &self.answers) {
                    let items = answer_items(&prompt, &self.answers);
                    store.update(cx, |s, cx| s.answer_prompt(items, cx));
                } else if let Some(q) = prompt.questions.get(self.index)
                    && self.answers.get(&q.id).is_some_and(Choice::answered)
                    && self.index + 1 < prompt.questions.len()
                {
                    // Answered this one: on to the next (the field takes
                    // its words as it draws).
                    self.index += 1;
                    cx.notify();
                }
            }
            ChatPromptKind::ToolApproval | ChatPromptKind::Confirmation => {
                store.update(cx, |s, cx| s.decide_prompt(true, cx));
            }
            ChatPromptKind::Unknown => return false,
        }
        true
    }

    /// ⌥⌘⌫: Cancel or Deny. Whether the card acted.
    pub fn secondary(&mut self, cx: &mut Context<Self>) -> bool {
        if self.drawn(cx).is_none() {
            return false;
        }
        if self.busy(cx) {
            return true;
        }
        if let Some(store) = self.store.clone() {
            store.update(cx, |s, cx| s.decide_prompt(false, cx));
        }
        true
    }

    fn card(
        &mut self,
        prompt: &ChatPromptDto,
        l10n: &L10n,
        cx: &mut Context<Self>,
    ) -> ApprovalCard {
        let id = prompt.id.clone();
        let this = cx.entity().downgrade();
        let busy = self.busy(cx);
        let act = |f: fn(&mut PromptCard, &mut Window, &mut Context<PromptCard>)| {
            let this = this.clone();
            Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| f(s, window, cx));
            })
        };
        let primary = |label: String| {
            ApprovalAction::new(SharedString::from(format!("prompt-primary-{id}")), label)
                .primary()
                .shortcut(ALLOW_KEYS)
                .disabled(busy)
                .on_click(act(|s, _, cx| {
                    s.primary(cx);
                }))
        };
        let secondary = |label: String| {
            ApprovalAction::new(SharedString::from(format!("prompt-secondary-{id}")), label)
                .shortcut(DENY_KEYS)
                .disabled(busy)
                .on_click(act(|s, _, cx| {
                    s.secondary(cx);
                }))
        };
        let source = l10n.desktop_prompt_question();
        match prompt.kind {
            ChatPromptKind::AskUser => {
                let count = prompt.questions.len();
                let index = self.index.min(count.saturating_sub(1));
                let Some(q) = prompt.questions.get(index) else {
                    return ApprovalCard::new(
                        id.clone(),
                        source.clone(),
                        "",
                        source,
                        ApprovalKind::Message,
                    )
                    .actions(vec![secondary(l10n.cancel())]);
                };
                let choice = self.answers.get(&q.id).cloned().unwrap_or_default();
                let answered = choice.answered();
                let done = complete(prompt, &self.answers);
                let pick = {
                    let this = this.clone();
                    Rc::new(move |i: usize, _: &mut Window, cx: &mut App| {
                        let _ = this.update(cx, |s, cx| s.pick(i, cx));
                    })
                };
                let mut actions = vec![secondary(l10n.cancel())];
                if index > 0 {
                    actions.push(
                        ApprovalAction::new(
                            SharedString::from(format!("prompt-previous-{id}")),
                            l10n.desktop_prompt_previous(),
                        )
                        .disabled(busy)
                        .on_click(act(|s, window, cx| s.step(-1, window, cx))),
                    );
                }
                if index + 1 < count {
                    actions.push(
                        ApprovalAction::new(
                            SharedString::from(format!("prompt-next-{id}")),
                            l10n.next_label(),
                        )
                        .disabled(busy || !answered)
                        .on_click(act(|s, window, cx| s.step(1, window, cx))),
                    );
                }
                actions.push(primary(l10n.open_web_ui_prompt_submit()).disabled(busy || !done));
                let mut card = ApprovalCard::new(
                    id.clone(),
                    q.header.clone(),
                    q.question.clone(),
                    source,
                    ApprovalKind::Question {
                        question: SharedString::default(),
                        options: q
                            .options
                            .iter()
                            .map(|o| SelectOption {
                                label: o.label.clone().into(),
                                detail: (!o.description.is_empty())
                                    .then(|| o.description.clone().into()),
                            })
                            .collect(),
                        selected: (!choice.other).then_some(choice.option).flatten(),
                        other: q.allow_other.then(|| {
                            (
                                self.other.clone(),
                                SharedString::from(l10n.open_web_ui_prompt_other()),
                            )
                        }),
                        other_selected: choice.other,
                    },
                )
                .on_option(pick)
                .actions(actions);
                if count > 1 {
                    card = card.step(index, count);
                }
                card
            }
            ChatPromptKind::ToolApproval => ApprovalCard::new(
                id.clone(),
                tool_question(&prompt.title, l10n),
                "",
                source,
                ApprovalKind::Code {
                    caption: l10n.desktop_tool_input().into(),
                    code: if prompt.message.trim().is_empty() || prompt.message.trim() == "{}" {
                        SharedString::default()
                    } else {
                        prompt.message.clone().into()
                    },
                },
            )
            .actions(vec![
                secondary(l10n.hermes_approval_deny_action()),
                primary(l10n.hermes_approval_approve_action()),
            ]),
            ChatPromptKind::Confirmation | ChatPromptKind::Unknown => {
                let mut actions = vec![secondary(l10n.cancel())];
                if confirms(prompt.kind) {
                    actions.push(primary(l10n.confirm()));
                }
                ApprovalCard::new(
                    id.clone(),
                    if prompt.title.trim().is_empty() {
                        l10n.confirm()
                    } else {
                        prompt.title.clone()
                    },
                    prompt.message.clone(),
                    source,
                    ApprovalKind::Message,
                )
                .tile(IconName::MessageSquare)
                .actions(actions)
            }
        }
    }
}

/// Whether a prompt of `kind` offers Confirm (Approve): only the kinds this
/// app answers. One it doesn't know (a newer server's) can only be
/// cancelled, which answers it, rather than offer a button that does
/// nothing.
fn confirms(kind: ChatPromptKind) -> bool {
    matches!(
        kind,
        ChatPromptKind::Confirmation | ChatPromptKind::ToolApproval
    )
}

impl Render for PromptCard {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let prompt = self.prompt(cx);
        let shown = motion::appear(
            "prompt-card",
            prompt.is_some(),
            specs::CARD_IN,
            specs::CARD_OUT,
            window,
            cx,
        );
        let reduce = cx.reduce_motion();
        let l10n = cx.l10n().clone();
        let Some(prompt) = prompt else {
            self.for_prompt = None;
            if shown.visible
                && let Some(last) = self.last.clone()
            {
                // Leaving: the last card, as it was, its buttons shielded.
                let card = self.card(&last, &l10n, cx);
                let card = div()
                    .relative()
                    .w_full()
                    .child(card)
                    .child(div().id("prompt-leaving").absolute().inset_0().occlude())
                    .into_any_element();
                return ApprovalsView::docked(card, shown, ApprovalsView::DOCK_GAP, reduce);
            }
            self.last = None;
            return div().into_any_element();
        };
        self.sync(&prompt, window, cx);
        let at = (prompt.id.clone(), self.index);
        if self.other_for.as_ref() != Some(&at) {
            self.other_for = Some(at);
            self.load_other(&prompt, window, cx);
        }
        self.last = Some(prompt.clone());
        let (busy, failed) = self
            .store
            .as_ref()
            .map(|s| (s.read(cx).prompt_busy, s.read(cx).prompt_failed))
            .unwrap_or_default();
        let mut card = self.card(&prompt, &l10n, cx);
        if busy {
            card = card.note(l10n.desktop_answering());
        } else if failed {
            card = card.note(l10n.desktop_approval_failed());
        }
        let card: AnyElement = div()
            .id("chat-prompt")
            .tab_group()
            .tab_index(-1)
            .tab_stop(false)
            .w_full()
            .child(card)
            .into_any_element();
        ApprovalsView::docked(card, shown, ApprovalsView::DOCK_GAP, reduce)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use conduit_protocol::{ChatPromptOptionDto, ChatPromptQuestionDto};

    fn question(id: &str, allow_other: bool) -> ChatPromptQuestionDto {
        ChatPromptQuestionDto {
            id: id.into(),
            header: "Departure".into(),
            question: "When?".into(),
            options: vec![
                ChatPromptOptionDto {
                    label: "Morning".into(),
                    description: "Calm".into(),
                },
                ChatPromptOptionDto {
                    label: "Evening".into(),
                    description: String::new(),
                },
            ],
            allow_other,
        }
    }

    fn prompt() -> ChatPromptDto {
        ChatPromptDto {
            id: "live:1".into(),
            chat_id: "c".into(),
            kind: ChatPromptKind::AskUser,
            title: String::new(),
            message: String::new(),
            questions: vec![question("when", true), question("crew", false)],
            expires_at_ms: None,
        }
    }

    #[test]
    fn a_prompt_this_app_does_not_know_offers_only_cancel() {
        assert!(super::confirms(ChatPromptKind::Confirmation));
        assert!(super::confirms(ChatPromptKind::ToolApproval));
        assert!(!super::confirms(ChatPromptKind::Unknown));
    }

    #[test]
    fn every_question_needs_an_answer_it_accepts() {
        let p = prompt();
        let mut answers = HashMap::new();
        assert!(!complete(&p, &answers));
        answers.insert(
            "when".to_string(),
            Choice {
                option: None,
                other: true,
                text: " At noon ".into(),
            },
        );
        assert!(!complete(&p, &answers));
        // The crew question takes no own words.
        answers.insert(
            "crew".to_string(),
            Choice {
                option: None,
                other: true,
                text: "Six".into(),
            },
        );
        assert!(!complete(&p, &answers));
        answers.insert(
            "crew".to_string(),
            Choice {
                option: Some(1),
                other: false,
                text: String::new(),
            },
        );
        assert!(complete(&p, &answers));
        assert_eq!(
            answer_items(&p, &answers),
            vec![
                ChatPromptAnswerItem {
                    question_id: "when".into(),
                    option_index: None,
                    text: Some("At noon".into()),
                },
                ChatPromptAnswerItem {
                    question_id: "crew".into(),
                    option_index: Some(1),
                    text: None,
                },
            ]
        );
    }

    #[test]
    fn blank_own_words_do_not_answer() {
        let blank = Choice {
            option: Some(0),
            other: true,
            text: "  ".into(),
        };
        assert!(!blank.answered());
        let picked = Choice {
            option: Some(0),
            other: false,
            text: String::new(),
        };
        assert!(picked.answered());
    }

    #[gpui_kit::test]
    fn a_key_never_answers_a_prompt_that_replaced_the_one_on_screen(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        use std::rc::Rc;

        use gpui_kit::AppContext as _;

        use crate::stores::chat::{ChatStore, Subscribe};
        use crate::stores::rpc::fake::FakeDaemon;

        cx.update(crate::views::test_globals);
        let daemon = FakeDaemon::new();
        let confirmation = |id: &str| serde_json::json!({"id": id, "chatId": "c1", "kind": "confirmation", "title": "Proceed?"});
        daemon.on::<conduit_protocol::methods::ChatPromptsGet>(move |_| {
            Ok(serde_json::json!({"chatId": "c1", "prompt": confirmation("p1")}))
        });
        daemon.on::<conduit_protocol::methods::ChatPromptsDecide>(|_| {
            Ok(serde_json::json!({"accepted": true}))
        });
        let subscribe: Subscribe = Rc::new(|_, _| {});
        let rpc = daemon.rpc();
        let store = cx.new(|cx| ChatStore::new(rpc, subscribe, "c1".into(), cx));
        cx.run_until_parked();
        let s = store.clone();
        let (card, vcx) = cx.add_window_view(move |window, cx| {
            let mut card = PromptCard::new(window, cx);
            card.set_store(Some(s), cx);
            card
        });
        vcx.run_until_parked();
        // p1 is on screen; p2 replaces it, and a key comes before the card
        // is drawn again.
        vcx.update(|_, cx| {
            store.update(cx, |s, cx| {
                s.on_event(
                    &conduit_protocol::Event::ChatPromptsChanged(
                        serde_json::from_value(serde_json::json!({
                            "chatId": "c1",
                            "prompt": {"id": "p2", "chatId": "c1", "kind": "confirmation"},
                        }))
                        .unwrap(),
                    ),
                    cx,
                )
            });
            card.update(cx, |c, cx| {
                assert!(!c.primary(cx), "approved a prompt never shown");
                assert!(!c.secondary(cx), "cancelled a prompt never shown");
            });
        });
        assert!(
            daemon
                .calls::<conduit_protocol::methods::ChatPromptsDecide>()
                .is_empty()
        );
        // Once drawn, its keys answer it.
        vcx.run_until_parked();
        card.update(vcx, |c, cx| assert!(c.primary(cx)));
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<conduit_protocol::methods::ChatPromptsDecide>()[0]["promptId"],
            "p2"
        );
    }

    /// Two questions of one prompt worded alike: Next and Back are each
    /// heard, with the question's place; a redraw says nothing more.
    #[gpui_kit::test]
    fn each_question_reached_is_heard_with_its_place(cx: &mut gpui_kit::TestAppContext) {
        use std::rc::Rc;

        use conduit_components::announce::AnnouncementLog;
        use gpui_kit::AppContext as _;

        use crate::stores::chat::{ChatStore, Subscribe};
        use crate::stores::rpc::fake::FakeDaemon;

        cx.update(crate::views::test_globals);
        cx.update(AnnouncementLog::install);
        let daemon = FakeDaemon::new();
        let mut asked = prompt();
        asked.chat_id = "c1".into();
        let asked = serde_json::to_value(&asked).unwrap();
        daemon.on::<conduit_protocol::methods::ChatPromptsGet>(move |_| {
            Ok(serde_json::json!({"chatId": "c1", "prompt": asked}))
        });
        let subscribe: Subscribe = Rc::new(|_, _| {});
        let rpc = daemon.rpc();
        let store = cx.new(|cx| ChatStore::new(rpc, subscribe, "c1".into(), cx));
        cx.run_until_parked();
        let s = store.clone();
        let (card, vcx) = cx.add_window_view(move |window, cx| {
            let mut card = PromptCard::new(window, cx);
            card.set_store(Some(s), cx);
            card
        });
        let draw = |vcx: &mut gpui_kit::VisualTestContext| {
            vcx.update(|window, cx| window.draw(cx).clear(cx));
            vcx.run_until_parked();
        };
        draw(vcx);
        for by in [1, -1] {
            card.update_in(vcx, |c, window, cx| c.step(by, window, cx));
            draw(vcx);
            draw(vcx);
        }
        let said: Vec<String> = vcx.update(|_, cx| {
            AnnouncementLog::texts(cx)
                .iter()
                .map(ToString::to_string)
                .collect()
        });
        assert_eq!(
            said,
            [
                "Departure: When?, 1 of 2",
                "Departure: When?, 2 of 2",
                "Departure: When?, 1 of 2",
            ]
        );
    }
}
