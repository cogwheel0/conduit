//! `--e2e librechat`: LibreChat end to end, against the fake LibreChat
//! server (`tool/local_librechat/librechat.sh start`; its env file is the
//! pass's `--e2e-env`), with its invented accounts:
//!
//! * the chooser offers LibreChat; an address that answers nothing is
//!   refused; the server's sign-in methods (password, "Harbour ID");
//! * a wrong password, then two-step verification: a wrong code, then the
//!   right one; the main window opens on the account's chats;
//! * the model picker offers its specs, agents and endpoint models; a spec
//!   and an agent answer; send and stream; Stop; Regenerate;
//! * rename, pin, archive, Duplicate and delete in the list;
//! * a tool approval;
//! * a prompt with variables;
//! * a memory added and deleted in Settings › Personalization;
//! * a share link;
//! * sign out.

use std::path::Path;
use std::time::Duration;

use conduit_components::views::model::Backend as ChooserBackend;
use gpui_kit::{AsyncApp, Entity};
use serde_json::Value;

use super::chat::{chat_store, in_pane, pane, send, wait_answer, wait_models};
use super::*;
use crate::views::librechat_sign_in::{LibreChatSignInView, Step};

/// What the pass says when the fake's env file is missing.
const NO_LIBRECHAT: &str =
    "the fake LibreChat's env file is the --e2e-env (tool/local_librechat/librechat.sh start)";

struct Fake {
    url: String,
    email: String,
    password: String,
    code: String,
}

impl Fake {
    fn from(inputs: &E2eInputs) -> Option<Self> {
        Some(Self {
            url: inputs.get("LIBRECHAT_URL")?,
            email: inputs.get("LIBRECHAT_2FA_EMAIL")?,
            password: inputs.get("LIBRECHAT_2FA_PASSWORD")?,
            code: inputs.get("LIBRECHAT_2FA_CODE")?,
        })
    }
}

fn onboarding_form(cx: &mut AsyncApp) -> Option<Entity<LibreChatSignInView>> {
    in_setup(cx, |sw, _, cx| sw.onboarding.read(cx).librechat.clone())
}

/// Types into the LibreChat form's field for its step and submits.
async fn submit_form(
    form: &Entity<LibreChatSignInView>,
    fill: Vec<(FieldOf, String)>,
    cx: &mut AsyncApp,
) {
    let form = form.clone();
    in_setup(cx, move |_, window, cx| {
        for (field, text) in &fill {
            let state = {
                let f = form.read(cx);
                match field {
                    FieldOf::Address => f.address.clone(),
                    FieldOf::Email => f.email.clone(),
                    FieldOf::Password => f.password.clone(),
                    FieldOf::Code => f.code.clone(),
                }
            };
            set_text(&state, text, window, cx);
        }
        form.update(cx, |f, cx| f.submit(window, cx));
    });
}

#[derive(Clone, Copy)]
enum FieldOf {
    Address,
    Email,
    Password,
    Code,
}

async fn wait_form(
    form: &Entity<LibreChatSignInView>,
    cx: &mut AsyncApp,
    done: impl Fn(&LibreChatSignInView) -> bool + 'static,
) -> bool {
    let form = form.clone();
    wait_until(cx, Duration::from_secs(30), move |cx| {
        let f = form.read(cx);
        !f.busy && done(f)
    })
    .await
}

fn chat_titles(cx: &mut App) -> Vec<String> {
    let list = cx.global::<AppState>().stores.chat_list.clone();
    list.read(cx)
        .list
        .as_ref()
        .map(|l| l.chats.iter().map(|c| c.title.clone()).collect())
        .unwrap_or_default()
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some(fake) = Fake::from(inputs) else {
        return ok(NO_LIBRECHAT, false);
    };
    let mut pass = sign_in(&fake, dir, cx).await;
    if !cx.update(main_window).is_some() {
        return ok("signed in, the main window is up", false);
    }
    pass &= chats(dir, cx).await;
    pass &= agent_stop_regenerate(&fake, dir, cx).await;
    pass &= approval(dir, cx).await;
    pass &= tools(&fake, dir, cx).await;
    pass &= prompt(dir, cx).await;
    pass &= list_actions(&fake, dir, cx).await;
    pass &= share(&fake, dir, cx).await;
    pass &= memories(&fake, dir, cx).await;
    pass &= sign_out(dir, cx).await;
    pass &= sso(&fake, dir, cx).await;
    pass
}

/// Single sign-on: from the chooser again, Continue with Harbour ID opens
/// the sign-in window; the provider's page (a test script presses its
/// Continue) sends the browser back, the window stops at LibreChat's web
/// app, and the session it left signs in another account.
async fn sso(fake: &Fake, dir: &Path, cx: &mut AsyncApp) -> bool {
    cx.update(|cx| {
        cx.set_global(SsoScript(Some(
            "document.getElementById('continue').click()".into(),
        )))
    });
    in_setup(cx, |sw, window, cx| {
        sw.onboarding.update(cx, |o, cx| {
            o.selected = ChooserBackend::LibreChat;
            o.choose(window, cx)
        })
    });
    settle(cx, 500).await;
    let Some(form) = onboarding_form(cx) else {
        return ok("the LibreChat form", false);
    };
    submit_form(&form, vec![(FieldOf::Address, fake.url.clone())], cx).await;
    let mut pass = ok(
        "the server's ways to sign in follow",
        wait_form(&form, cx, |f| f.step == Step::Methods).await,
    );
    let _ = in_setup(cx, {
        let form = form.clone();
        move |_, window, cx| form.update(cx, |f, cx| f.start_sso("openid".into(), window, cx))
    });
    pass &= ok(
        "single sign-on signs in, into the main window",
        wait_route(cx, Route::Main, Duration::from_secs(90)).await && wait_main(cx).await.is_some(),
    );
    let name = cx.update(|cx| {
        let a = cx.global::<AppState>().stores.accounts.read(cx);
        a.libre_chat_active()
            .and_then(|a| a.user.as_ref().and_then(|u| u.name.clone()))
    });
    pass &= ok(
        &format!("the account is the provider's user ({name:?})"),
        name.as_deref() == Some("Sage Ito"),
    );
    cx.update(|cx| cx.set_global(SsoScript(None)));
    settle(cx, 800).await;
    shoot_main(dir, "librechat-sso-main", cx).await;
    pass
}

/// The fake's own view of what it holds (`/__fake/state`), off the main
/// thread.
async fn fake_state(url: &str, cx: &mut AsyncApp) -> Option<Value> {
    let url = url.to_string();
    cx.background_executor()
        .spawn(async move {
            use std::io::{Read, Write};
            let u = url::Url::parse(&url).ok()?;
            let host = u.host_str()?.to_string();
            let port = u.port_or_known_default()?;
            let mut stream = std::net::TcpStream::connect((host.as_str(), port)).ok()?;
            stream
                .set_read_timeout(Some(Duration::from_secs(10)))
                .ok()?;
            write!(
                stream,
                "GET /__fake/state HTTP/1.1\r\nHost: {host}:{port}\r\nConnection: close\r\n\r\n"
            )
            .ok()?;
            let mut body = String::new();
            stream.read_to_string(&mut body).ok()?;
            let (_, json) = body.split_once("\r\n\r\n")?;
            serde_json::from_str(json).ok()
        })
        .await
}

/// The fake's conversation titled `title`, as it holds it.
async fn fake_chat(url: &str, title: &str, cx: &mut AsyncApp) -> Option<Value> {
    let state = fake_state(url, cx).await?;
    state["conversations"]
        .as_array()?
        .iter()
        .find(|c| c["title"].as_str() == Some(title))
        .cloned()
}

/// The last turn body the fake took (`start`), or a resume.
async fn last_turn(url: &str, key: &str, cx: &mut AsyncApp) -> Option<Value> {
    let state = fake_state(url, cx).await?;
    state["turns"]
        .as_array()?
        .iter()
        .rev()
        .find_map(|t| t.get(key).cloned())
}

fn model_id(name: &'static str) -> impl Fn(&mut App) -> Option<String> {
    move |cx: &mut App| {
        let p = pane(cx)?;
        let store = p.read(cx).composer_store.clone();
        let s = store.read(cx);
        s.models
            .as_ref()?
            .models
            .iter()
            .find(|m| m.name == name)
            .map(|m| m.id.clone())
    }
}

async fn select_model(name: &'static str, cx: &mut AsyncApp) -> bool {
    let Some(id) = cx.update(model_id(name)) else {
        return false;
    };
    in_pane(cx, move |p, _, cx| {
        let store = p.composer_store.clone();
        store.update(cx, |s, cx| s.select_model(&id, cx));
    });
    let id = cx.update(model_id(name));
    wait_until(cx, Duration::from_secs(15), move |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .selected_model()
                .map(|m| m.id.clone())
                == id
        })
    })
    .await
}

async fn new_chat(cx: &mut AsyncApp) {
    cx.update(|cx| {
        let nav = cx.global::<AppState>().stores.navigation.clone();
        nav.update(cx, |n, cx| n.new_chat(false, cx));
    });
    settle(cx, 500).await;
}

fn last_answer(cx: &mut App) -> String {
    chat_store(cx)
        .map(|s| {
            let s = s.read(cx);
            s.rows()
                .iter()
                .rev()
                .filter_map(|r| s.item(*r))
                .find(|i| i.role == crate::stores::chat::Role::Assistant)
                .map(|i| i.text)
                .unwrap_or_default()
        })
        .unwrap_or_default()
}

/// An agent answers; a long answer is stopped, keeping what it wrote; the
/// last answer is regenerated.
async fn agent_stop_regenerate(fake: &Fake, dir: &Path, cx: &mut AsyncApp) -> bool {
    new_chat(cx).await;
    let mut pass = ok(
        "the agent Tidewatch is chosen",
        select_model("Tidewatch", cx).await,
    );
    send("Which tide is next", cx).await;
    pass &= ok(
        "the agent answers",
        wait_answer(cx, Duration::from_secs(60)).await
            && cx.update(last_answer).contains("Tidewatch answers"),
    );
    let start = last_turn(&fake.url, "start", cx).await;
    pass &= ok(
        "the turn went to the agent",
        start.is_some_and(|s| s["agent_id"].as_str() == Some("agent_tidewatch")),
    );

    send("Tell me a long story about the harbour", cx).await;
    let streaming = wait_until(cx, Duration::from_secs(30), |cx| {
        chat_store(cx).is_some_and(|s| {
            let s = s.read(cx);
            s.live
                .as_ref()
                .is_some_and(|l| l.streaming() && !l.blocks.is_empty())
        })
    })
    .await;
    pass &= ok("a long answer streams", streaming);
    settle(cx, 1200).await;
    shoot_main(dir, "librechat-streaming", cx).await;
    in_pane(cx, |p, _, cx| p.stop(cx));
    pass &= ok(
        "Stop ends it, keeping what it wrote",
        wait_answer(cx, Duration::from_secs(30)).await
            && cx.update(last_answer).contains("The tide rolled in"),
    );
    let before = cx.update(last_answer);
    super::chat::dispatch(&crate::actions::RegenerateLastAnswer, cx);
    let regenerated = wait_until(cx, Duration::from_secs(60), move |cx| {
        let s = chat_store(cx);
        s.is_some_and(|s| {
            let s = s.read(cx);
            !s.is_streaming() && s.live.is_none() && s.pending.is_none()
        }) && last_answer(cx) != before
    })
    .await;
    let start = last_turn(&fake.url, "start", cx).await;
    // One answer, under the id the server gave it, with the stopped one
    // kept as its first version (a second row would mean the windows
    // were told the reply under the id the app minted for it).
    let versions = cx.update(|cx| {
        chat_store(cx).map(|s| {
            let s = s.read(cx);
            s.rows()
                .iter()
                .filter_map(|r| s.item(*r))
                .filter(|i| i.role == crate::stores::chat::Role::Assistant)
                .map(|i| i.version)
                .collect::<Vec<_>>()
        })
    });
    settle(cx, 400).await;
    shoot_main(dir, "librechat-regenerated", cx).await;
    pass &= ok(
        "Regenerate asks the server again",
        regenerated && start.is_some_and(|s| s["isRegenerate"].as_bool() == Some(true)),
    );
    pass &= ok(
        &format!("the new answer replaces the stopped one, as version 2 of 2 ({versions:?})"),
        versions.is_some_and(|v| v.len() == 2 && v[1] == Some((2, 2))),
    );
    pass
}

/// A tool call the run paused on: the card asks "Allow lookup_tide to
/// run?", Allow resumes the run.
async fn approval(dir: &Path, cx: &mut AsyncApp) -> bool {
    new_chat(cx).await;
    let mut pass = ok(
        "harbour-small is chosen",
        select_model("harbour-small", cx).await,
    );
    send("Please approve the tide lookup", cx).await;
    let asked = wait_until(cx, Duration::from_secs(30), |cx| {
        let u = cx.global::<AppState>().stores.ui_requests.read(cx);
        u.queue
            .iter()
            .any(|r| r.message_code == "librechat.toolApproval")
    })
    .await;
    pass &= ok("the paused tool call asks for approval", asked);
    settle(cx, 600).await;
    shoot_main(dir, "librechat-approval", cx).await;
    cx.update(|cx| {
        if let Some((handle, _)) = main_window(cx) {
            let _ = handle.update(cx, |_, window, cx| {
                window.dispatch_action(Box::new(crate::actions::AllowRequest), cx)
            });
        }
    });
    pass &= ok(
        "Allow runs the tool and the answer goes on",
        wait_answer(cx, Duration::from_secs(60)).await && cx.update(last_answer).contains("06:40"),
    );
    pass
}

/// The composer's LibreChat tools: Web Search on goes with the turn.
async fn tools(fake: &Fake, dir: &Path, cx: &mut AsyncApp) -> bool {
    new_chat(cx).await;
    let offered = wait_until(cx, Duration::from_secs(20), |cx| {
        pane(cx).is_some_and(|p| {
            let s = p.read(cx).composer_store.read(cx);
            let tools = s.librechat_tools();
            tools.len() >= 4
                && tools.iter().any(|(_, t)| {
                    matches!(
                        t,
                        crate::stores::composer::LibreChatTool::Mcp {
                            needs_connection: true,
                            ..
                        }
                    )
                })
        })
    })
    .await;
    let mut pass = ok(
        "an endpoint model offers web search, code, file search and the MCP servers",
        offered,
    );
    in_pane(cx, |p, _, cx| {
        let store = p.composer_store.clone();
        store.update(cx, |s, cx| s.toggle_tool("librechat:web_search", cx));
    });
    settle(cx, 300).await;
    shoot_main(dir, "librechat-tools", cx).await;
    send("Find the harbour times", cx).await;
    pass &= ok(
        "the answer comes with web search",
        wait_answer(cx, Duration::from_secs(60)).await
            && cx.update(last_answer).contains("The almanac agrees"),
    );
    let start = last_turn(&fake.url, "start", cx).await;
    pass &= ok(
        "the turn asked for web search",
        start.is_some_and(|s| s["ephemeralAgent"]["web_search"].as_bool() == Some(true)),
    );
    pass
}

/// `/tone`: its blanks in the fill-in form, LibreChat's choices offered.
async fn prompt(dir: &Path, cx: &mut AsyncApp) -> bool {
    in_pane(cx, |p, window, cx| {
        p.composer
            .update(cx, |c, cx| c.set_text("/ton", window, cx))
    });
    let listed = wait_until(cx, Duration::from_secs(15), |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .prompts
                .as_ref()
                .is_some_and(|l| l.iter().any(|p| p.command.contains("tone")))
        })
    })
    .await;
    let mut pass = ok("the prompt library is offered under /", listed);
    settle(cx, 300).await;
    in_pane(cx, |p, window, cx| {
        p.composer
            .update(cx, |c, cx| c.choose_menu_item(0, window, cx))
    });
    settle(cx, 1500).await;
    shoot_main(dir, "librechat-prompt-form", cx).await;
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| {
            c.fill_and_submit_form(
                &[("tone", "playful"), ("text", "The tide is out")],
                0,
                window,
                cx,
            )
        })
    });
    let inserted = wait_until(cx, Duration::from_secs(15), |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx).composer.read(cx).text(cx)
                == "Rewrite this in a playful tone: The tide is out"
        })
    })
    .await;
    pass &= ok("the filled-in prompt lands in the composer", inserted);
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.set_text("", window, cx))
    });
    pass
}

fn chat_id(title: &str, cx: &mut App) -> Option<String> {
    let list = cx.global::<AppState>().stores.chat_list.clone();
    list.read(cx)
        .list
        .as_ref()?
        .chats
        .iter()
        .find(|c| c.title == title)
        .map(|c| c.id.clone())
}

async fn run_command(id: &str, command: crate::views::sidebar::ChatCommand, cx: &mut AsyncApp) {
    let id = id.to_string();
    in_main(cx, move |mw, window, cx| {
        mw.sidebar
            .update(cx, |s, cx| s.run(&id, command, window, cx))
    });
}

/// Rename, pin, Duplicate, archive and delete from the chat's menu, each
/// pushed to the server.
async fn list_actions(fake: &Fake, dir: &Path, cx: &mut AsyncApp) -> bool {
    use crate::views::sidebar::ChatCommand;
    let Some(id) = cx.update(|cx| chat_id("Garden shed paint colours", cx)) else {
        return ok("the seeded chat is listed", false);
    };
    // The chat's menu: LibreChat's commands, with Duplicate Chat.
    let items = in_main(cx, {
        let id = id.clone();
        move |mw, _, cx| {
            let chat = cx
                .global::<AppState>()
                .stores
                .chat_list
                .read(cx)
                .find(&id)
                .cloned();
            chat.map(|c| mw.sidebar.read(cx).menu_items(&c, cx))
        }
    })
    .flatten()
    .unwrap_or_default();
    let names: Vec<String> = items.iter().map(|(l, _)| l.clone()).collect();
    let mut pass = ok(
        &format!("the chat's menu offers Duplicate Chat and no folders ({names:?})"),
        names.iter().any(|n| n == "Duplicate Chat")
            && !items
                .iter()
                .any(|(_, c)| matches!(c, ChatCommand::MoveTo(_) | ChatCommand::GenerateTitle)),
    );
    // The core's rule for a LibreChat chat, from the daemon: none of Open
    // WebUI's server actions (unread mark, export).
    pass &= ok(
        "a LibreChat chat's menu has no Mark as Unread or Export",
        !items.iter().any(|(_, c)| {
            matches!(
                c,
                ChatCommand::MarkUnread | ChatCommand::MarkRead | ChatCommand::Export(_)
            )
        }),
    );

    let renamed = cx.update(|cx| {
        let list = cx.global::<AppState>().stores.chat_list.clone();
        list.update(cx, |l, cx| l.rename(&id, "Shed colours", cx))
    });
    let _ = renamed.await;
    run_command(&id, ChatCommand::Pin, cx).await;
    let url = fake.url.clone();
    let mut pushed = false;
    for _ in 0..40 {
        if let Some(c) = fake_chat(&url, "Shed colours", cx).await
            && c["pinned"].as_bool() == Some(true)
        {
            pushed = true;
            break;
        }
        settle(cx, 500).await;
    }
    pass &= ok("Rename and Pin reach the server", pushed);
    settle(cx, 600).await;
    shoot_main(dir, "librechat-sidebar", cx).await;

    run_command(&id, ChatCommand::Duplicate, cx).await;
    let copied = wait_until(cx, Duration::from_secs(20), {
        let id = id.clone();
        move |cx| {
            let list = cx.global::<AppState>().stores.chat_list.clone();
            let open = cx
                .global::<AppState>()
                .stores
                .navigation
                .read(cx)
                .selected_chat()
                .map(str::to_string);
            let copies = list
                .read(cx)
                .list
                .as_ref()
                .map(|l| l.chats.iter().filter(|c| c.title == "Shed colours").count())
                .unwrap_or(0);
            copies >= 2 && open.is_some_and(|o| o != id)
        }
    })
    .await;
    pass &= ok("Duplicate Chat makes a copy and opens it", copied);
    let copy = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .navigation
            .read(cx)
            .selected_chat()
            .map(str::to_string)
    });

    run_command(&id, ChatCommand::Archive, cx).await;
    let mut archived = false;
    for _ in 0..40 {
        let state = fake_state(&url, cx).await;
        if state.is_some_and(|s| {
            s["conversations"].as_array().is_some_and(|a| {
                a.iter().any(|c| {
                    c["conversationId"].as_str() == Some(id.as_str())
                        && c["isArchived"].as_bool() == Some(true)
                })
            })
        }) {
            archived = true;
            break;
        }
        settle(cx, 500).await;
    }
    pass &= ok("Archive reaches the server", archived);

    if let Some(copy) = copy {
        run_command(&copy, ChatCommand::Delete, cx).await;
        let mut deleted = false;
        for _ in 0..40 {
            let state = fake_state(&url, cx).await;
            if state.is_some_and(|s| {
                s["conversations"].as_array().is_some_and(|a| {
                    !a.iter()
                        .any(|c| c["conversationId"].as_str() == Some(copy.as_str()))
                })
            }) {
                deleted = true;
                break;
            }
            settle(cx, 500).await;
        }
        pass &= ok(
            "Delete… (confirmed) deletes the copy on the server",
            deleted,
        );
    }
    pass
}

/// Share Chat: a link under the server's `/share/`, then deleted.
async fn share(fake: &Fake, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some(id) = cx.update(|cx| chat_id("Harbour lights schedule", cx)) else {
        return ok("the chat to share is listed", false);
    };
    let sheet = in_main(cx, {
        let id = id.clone();
        move |_, window, cx| crate::views::chat::share_sheet::open(id, window, cx)
    })
    .flatten();
    let Some(sheet) = sheet else {
        return ok("Share Chat opens", false);
    };
    let read = wait_until(cx, Duration::from_secs(20), {
        let sheet = sheet.clone();
        move |cx| {
            let s = sheet.read(cx);
            s.share.is_some() && !s.busy
        }
    })
    .await;
    let mut pass = ok("Share Chat reads the chat's link", read);
    sheet.update(cx, |s, cx| s.copy_link(cx));
    let prefix = format!("{}/share/", fake.url);
    let linked = wait_until(cx, Duration::from_secs(20), {
        let sheet = sheet.clone();
        let prefix = prefix.clone();
        move |cx| {
            let s = sheet.read(cx);
            !s.busy
                && s.linked()
                && s.share
                    .as_ref()
                    .is_some_and(|s| s.url.as_ref().is_some_and(|u| u.starts_with(&prefix)))
        }
    })
    .await;
    pass &= ok("Copy Link made a link under the server's /share/", linked);
    settle(cx, 400).await;
    if let Some(handle) = cx.update(|cx| crate::views::chat::sheets::handle(cx)) {
        shoot_both_modes(handle, dir, "librechat-share", cx).await;
    }
    let shared = fake_state(&fake.url, cx)
        .await
        .is_some_and(|s| s["shares"].as_object().is_some_and(|m| !m.is_empty()));
    pass &= ok("the server holds the link", shared);
    sheet.update(cx, |s, cx| s.delete_link(cx));
    let deleted = wait_until(cx, Duration::from_secs(20), {
        let sheet = sheet.clone();
        move |cx| {
            let s = sheet.read(cx);
            !s.busy && !s.linked()
        }
    })
    .await;
    pass &= ok("Delete This Link removed it", deleted);
    cx.update(crate::views::chat::sheets::close);
    settle(cx, 500).await;
    pass
}

/// Settings › Personalization: the account's memories; one added, then
/// deleted.
async fn memories(fake: &Fake, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some(handle) = settings_tab(Tab::Personalization, dir, "librechat-memories", cx).await
    else {
        return ok("Settings › Personalization opens", false);
    };
    let view = || {
        move |cx: &mut App| {
            let (_, settings) = cx.global::<AppState>().settings_window.clone()?;
            let pane = settings.read(cx).personalization.clone()?;
            pane.read(cx).librechat.clone()
        }
    };
    let listed = wait_until(cx, Duration::from_secs(20), move |cx| {
        view()(cx).is_some_and(|v| {
            v.read(cx)
                .memories
                .as_ref()
                .is_some_and(|m| m.memories.iter().any(|m| m.key == "home_harbour"))
        })
    })
    .await;
    let mut pass = ok("the LibreChat memories are listed", listed);
    let Some(lc) = cx.update(view()) else {
        return ok("the LibreChat memories view", false);
    };
    let _ = handle.update(cx, {
        let lc = lc.clone();
        move |_, window, cx| {
            lc.update(cx, |v, cx| {
                v.open_editor(None, window, cx);
                let (key, value) = (v.key.clone(), v.value.clone());
                set_text(&key, "boat_name", window, cx);
                value.update(cx, |s, cx| s.set_value("The Grey Gannet", window, cx));
            })
        }
    });
    settle(cx, 300).await;
    shoot_both_modes(handle, dir, "librechat-memory-editor", cx).await;
    let _ = handle.update(cx, {
        let lc = lc.clone();
        move |_, window, cx| lc.update(cx, |v, cx| v.save(window, cx))
    });
    let added = wait_until(cx, Duration::from_secs(20), {
        let lc = lc.clone();
        move |cx| {
            let v = lc.read(cx);
            v.editor.is_none()
                && v.memories
                    .as_ref()
                    .is_some_and(|m| m.memories.iter().any(|m| m.key == "boat_name"))
        }
    })
    .await;
    pass &= ok("a memory is added", added);
    settle(cx, 300).await;
    shoot_both_modes(handle, dir, "librechat-memories-added", cx).await;
    let _ = handle.update(cx, {
        let lc = lc.clone();
        move |_, window, cx| lc.update(cx, |v, cx| v.delete("boat_name".into(), window, cx))
    });
    let gone = wait_until(cx, Duration::from_secs(20), {
        let lc = lc.clone();
        move |cx| {
            lc.read(cx)
                .memories
                .as_ref()
                .is_some_and(|m| !m.memories.iter().any(|m| m.key == "boat_name"))
        }
    })
    .await;
    pass &= ok("Delete… (confirmed) deletes it", gone);
    let on_server = fake_state(&fake.url, cx).await.is_some_and(|s| {
        s["memories"]["u_rowan"]
            .as_array()
            .is_some_and(|a| !a.iter().any(|m| m["key"].as_str() == Some("boat_name")))
    });
    pass &= ok("the server no longer holds it", on_server);
    let _ = handle.update(cx, |_, window, _| window.remove_window());
    settle(cx, 500).await;
    pass
}

/// Sign Out: the only account goes, and the backend is chosen again.
async fn sign_out(dir: &Path, cx: &mut AsyncApp) -> bool {
    let _ = in_main(cx, |mw, window, cx| {
        crate::views::accounts::sign_out_active(&mw.stores, window, cx)
    });
    let pass = ok(
        "signing out of the only account goes back to choosing a backend",
        wait_route(cx, Route::Onboarding, Duration::from_secs(60)).await,
    );
    settle(cx, 600).await;
    shoot_setup(dir, "librechat-signed-out", cx).await;
    pass
}

/// From a fresh profile: the chooser, the address, the password and the
/// two-step code, into the main window.
async fn sign_in(fake: &Fake, dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = fresh_profile(cx).await;
    let Some(setup) = wait_setup(cx).await else {
        return ok("the setup window opened", false);
    };
    settle(cx, 500).await;
    // Shot first, as the Open WebUI pass does: the window is drawn and key
    // before its accessibility tree is read.
    shoot_setup(dir, "librechat-chooser", cx).await;
    let chooser = ax(setup, "librechat-chooser", dir, cx).await;
    pass &= ok(
        "the chooser offers LibreChat",
        has(&chooser, "Button", "LibreChat"),
    );
    in_setup(cx, |sw, window, cx| {
        sw.onboarding.update(cx, |o, cx| {
            o.selected = ChooserBackend::LibreChat;
            o.choose(window, cx)
        })
    });
    settle(cx, 500).await;
    let Some(form) = onboarding_form(cx) else {
        return ok("the LibreChat form", false);
    };
    shoot_setup(dir, "librechat-address", cx).await;

    // Nothing answers there.
    submit_form(
        &form,
        vec![(FieldOf::Address, "http://127.0.0.1:9".into())],
        cx,
    )
    .await;
    pass &= ok(
        "an address that answers nothing is refused",
        wait_form(&form, cx, |f| f.step == Step::Server && f.error.is_some()).await,
    );

    submit_form(&form, vec![(FieldOf::Address, fake.url.clone())], cx).await;
    pass &= ok(
        "the server's ways to sign in follow",
        wait_form(&form, cx, |f| f.step == Step::Methods).await,
    );
    settle(cx, 400).await;
    shoot_setup(dir, "librechat-methods", cx).await;
    let methods = ax(setup, "librechat-methods", dir, cx).await;
    pass &= ok(
        "the password form and Continue with Harbour ID",
        has(&methods, "Button", "Harbour ID") && has(&methods, "TextInput", ""),
    );

    submit_form(
        &form,
        vec![
            (FieldOf::Email, fake.email.clone()),
            (FieldOf::Password, "not-the-password".into()),
        ],
        cx,
    )
    .await;
    pass &= ok(
        "a wrong password is refused, in the server's words",
        wait_form(&form, cx, |f| {
            f.step == Step::Methods && f.error.as_deref() == Some("Incorrect password.")
        })
        .await,
    );

    submit_form(
        &form,
        vec![
            (FieldOf::Email, fake.email.clone()),
            (FieldOf::Password, fake.password.clone()),
        ],
        cx,
    )
    .await;
    pass &= ok(
        "two-step verification follows",
        wait_form(&form, cx, |f| f.step == Step::TwoFactor).await,
    );
    settle(cx, 400).await;
    shoot_setup(dir, "librechat-two-step", cx).await;

    submit_form(&form, vec![(FieldOf::Code, "000000".into())], cx).await;
    pass &= ok(
        "a wrong code is refused",
        wait_form(&form, cx, |f| {
            f.step == Step::TwoFactor && f.error.is_some()
        })
        .await,
    );
    shoot_setup(dir, "librechat-two-step-error", cx).await;

    submit_form(&form, vec![(FieldOf::Code, fake.code.clone())], cx).await;
    pass &= ok(
        "the right code signs in, into the main window",
        wait_route(cx, Route::Main, Duration::from_secs(60)).await && wait_main(cx).await.is_some(),
    );
    pass
}

/// The account's chats in the sidebar, and its account in the footer.
async fn chats(dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = ok(
        "the sidebar lists the account's chats",
        wait_until(cx, Duration::from_secs(30), |cx| {
            let titles = chat_titles(cx);
            titles.iter().any(|t| t == "Harbour lights schedule")
                && titles.iter().any(|t| t == "Tide table questions")
        })
        .await,
    );
    pass &= ok(
        "the main window chats through LibreChat",
        cx.update(|cx| {
            let s = cx.global::<AppState>().stores.session.clone();
            s.read(cx).backend(cx) == Some(crate::stores::session::Backend::LibreChat)
        }),
    );
    pass &= wait_models(cx).await;
    settle(cx, 800).await;
    shoot_main(dir, "librechat-main", cx).await;

    let model = |name: &'static str| {
        move |cx: &mut App| -> Option<String> {
            let p = pane(cx)?;
            let store = p.read(cx).composer_store.clone();
            let s = store.read(cx);
            s.models
                .as_ref()?
                .models
                .iter()
                .find(|m| m.name == name)
                .map(|m| m.id.clone())
        }
    };
    let Some(spec) = cx.update(model("Quick Notes")) else {
        return ok("the picker offers the spec Quick Notes", false);
    };
    pass &= ok(
        "the picker offers specs, agents and endpoint models",
        cx.update(model("Tidewatch")).is_some() && cx.update(model("harbour-large")).is_some(),
    );
    in_pane(cx, move |p, _, cx| {
        let store = p.composer_store.clone();
        store.update(cx, |s, cx| s.select_model(&spec, cx));
    });
    send("Tell me about lighthouse keepers", cx).await;
    pass &= ok(
        "a spec answers, streamed",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let answer = cx.update(|cx| {
        chat_store(cx)
            .map(|s| {
                let s = s.read(cx);
                s.rows()
                    .iter()
                    .rev()
                    .filter_map(|r| s.item(*r))
                    .find(|i| i.role == crate::stores::chat::Role::Assistant)
                    .map(|i| i.text)
                    .unwrap_or_default()
            })
            .unwrap_or_default()
    });
    pass &= ok(
        &format!("the answer names the spec ({answer:?})"),
        answer.contains("Quick Notes answers"),
    );
    // The open chat's Chat menu follows the core's rule too: Duplicate,
    // and no unread mark, generated title or export.
    pass &= ok(
        "the Chat menu offers a LibreChat chat's commands",
        wait_until(cx, Duration::from_secs(10), |cx| {
            let state = crate::menus::menu_state(cx);
            state.chat.as_ref().is_some_and(|c| {
                c.offered.duplicate
                    && !c.offered.mark_unread
                    && !c.offered.generate_title
                    && !c.offered.export
                    && !c.offered.r#move
            })
        })
        .await,
    );
    // A call: the core's admission decides (the phone offers the button in
    // every chat and its launcher asks the same), so the button is ready
    // exactly when `composer.options` says a call may start.
    let call = cx.update(|cx| {
        let p = pane(cx)?;
        let p = p.read(cx);
        let admitted = p.composer_store.read(cx).options.voice_call;
        let composer = p.composer.read(cx);
        Some((admitted, composer.call_offer, composer.call_ready))
    });
    pass &= ok(
        &format!(
            "the call button follows the core's admission (admitted, offered, ready: {call:?})"
        ),
        call.is_some_and(|(admitted, offered, ready)| offered && ready == admitted),
    );
    settle(cx, 800).await;
    shoot_main(dir, "librechat-answer", cx).await;
    pass
}
