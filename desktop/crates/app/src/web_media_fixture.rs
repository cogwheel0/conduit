//! `--fixture web-media`: the web views' media policy
//! ([`crate::shell::web_media`]) in real web views, in a real window.
//!
//! Builds an inline web view (as an embed or an MCP App is), a web view in a
//! window of its own (as the Preview and SSO windows are), one built without
//! the policy's guard (as a site that forgot it would be), and a call's page
//! (`voice::peer`), then asks each web view's own UI delegate, as WebKit
//! does when a page calls `getUserMedia`, whether its page may use the
//! microphone or the camera. Nothing is ever captured: the delegate is asked
//! directly, so neither WebKit nor macOS opens a device or asks the user.
//!
//! Prints `FIXTURE web-media <json>` (each case and its answer) and
//! `FIXTURE passed` or `FIXTURE FAILED`; `tests/web_media.rs` runs it.

use std::rc::Rc;

use conduit_components::assets::ConduitAssets;
use conduit_components::window as cw;
use gpui_kit::prelude::*;
use gpui_kit::{App, AsyncApp, Bounds, Context, Entity, Window, div, px, size};
use serde_json::json;

use crate::shell::web_media::{
    CAMERA, CAMERA_AND_MICROPHONE, CallPage, DENY, GRANT, MICROPHONE, mac::ask,
};
use crate::views::chat::inline_web::InlineWebView;
use crate::voice::peer;

pub fn requested(args: &[String]) -> bool {
    args.iter()
        .position(|a| a == "--fixture")
        .and_then(|i| args.get(i + 1))
        .is_some_and(|m| m == "web-media")
}

struct FixtureView {
    inline: Option<Rc<InlineWebView>>,
    windowed: Option<Entity<gpui_webview::WebView>>,
    unguarded: Option<wry::WebView>,
    call: Option<peer::PeerHost>,
}

impl Render for FixtureView {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full()
    }
}

/// One question to one web view's delegate, and the answer it must give.
struct Case {
    view: &'static str,
    scheme: &'static str,
    main_frame: bool,
    kind: isize,
    want: isize,
}

const fn case(
    view: &'static str,
    scheme: &'static str,
    main_frame: bool,
    kind: isize,
    want: isize,
) -> Case {
    Case {
        view,
        scheme,
        main_frame,
        kind,
        want,
    }
}

const CASES: &[Case] = &[
    // An embed or MCP App: nothing, whatever origin it claims.
    case("inline", "https", true, MICROPHONE, DENY),
    case("inline", "https", true, CAMERA, DENY),
    case("inline", "about", true, CAMERA_AND_MICROPHONE, DENY),
    case("inline", peer::SCHEME, true, MICROPHONE, DENY),
    // The Preview and SSO windows: nothing.
    case("windowed", "https", true, MICROPHONE, DENY),
    case("windowed", "about", false, CAMERA, DENY),
    // A web view built without the guard: wry's own delegate now denies too.
    case("unguarded", "https", true, MICROPHONE, DENY),
    case("unguarded", peer::SCHEME, true, MICROPHONE, DENY),
    // The call's page: the microphone, at its own origin, in its main frame.
    case("call", peer::SCHEME, true, MICROPHONE, GRANT),
    case("call", peer::SCHEME, true, CAMERA, DENY),
    case("call", peer::SCHEME, true, CAMERA_AND_MICROPHONE, DENY),
    case("call", peer::SCHEME, false, MICROPHONE, DENY),
    case("call", "https", true, MICROPHONE, DENY),
];

fn check(view: &FixtureView, cx: &App) -> (bool, serde_json::Value) {
    let _ = cx;
    let mut all = true;
    let mut answers = vec![];
    for c in CASES {
        let webview = match c.view {
            "inline" => view.inline.as_ref().map(|v| v.webview()),
            "windowed" => view.windowed.as_ref().map(|v| v.read(cx).raw()),
            "unguarded" => view.unguarded.as_ref(),
            "call" => view.call.as_ref().and_then(|c| c.webview()),
            _ => None,
        };
        let got = webview.and_then(|w| ask(w, c.scheme, c.main_frame, c.kind));
        let pass = got == Some(c.want);
        all &= pass;
        answers.push(json!({
            "view": c.view, "scheme": c.scheme, "mainFrame": c.main_frame,
            "type": c.kind, "want": c.want, "got": got, "pass": pass,
        }));
    }
    // A page registered as a call's, then let go: granted, then not.
    if let Some(inline) = view.inline.as_ref() {
        let token = CallPage::register(inline.webview());
        let while_registered = ask(inline.webview(), peer::SCHEME, true, MICROPHONE);
        drop(token);
        let after = ask(inline.webview(), peer::SCHEME, true, MICROPHONE);
        let pass = while_registered == Some(GRANT) && after == Some(DENY);
        all &= pass;
        answers.push(json!({
            "view": "inline registered, then let go",
            "got": [while_registered, after], "pass": pass,
        }));
    } else {
        all = false;
    }
    (all, json!(answers))
}

pub fn run() {
    let app = gpui_kit::application().with_assets(ConduitAssets);
    app.run(move |cx: &mut App| {
        gpui_kit::init(cx);
        let bounds = Bounds::centered(None, size(px(640.), px(480.)), cx);
        let options = cw::window_options("Conduit web media fixture", bounds, true, true);
        let opened = cw::open_window_clear_root(options, cx, |window, cx| {
            let html = |text: &str| format!("<!doctype html><p>{text}</p>");
            let inline = InlineWebView::new(
                wry::WebViewBuilder::new()
                    .with_incognito(true)
                    .with_html(html("An embed")),
                window,
            );
            let windowed = cx.new(|cx| {
                let webview = gpui_webview::WebView::build(
                    wry::WebViewBuilder::new()
                        .with_incognito(true)
                        .with_html(html("A preview")),
                    window,
                    cx,
                )
                .expect("a WKWebView always builds on macOS");
                crate::shell::web_media::guard(webview.raw());
                webview
            });
            // Built after the others, and never guarded.
            let unguarded = wry::WebViewBuilder::new()
                .with_incognito(true)
                .with_html(html("Unguarded"))
                .build_as_child(&*window)
                .ok();
            let call = peer::PeerHost::open(
                &peer::Options {
                    source: peer::Source::Samples {
                        rate: 16_000,
                        pcm: vec![0; 160],
                    },
                    play: false,
                    relay: None,
                },
                |_| {},
            )
            .ok();
            cx.new(|_| FixtureView {
                inline,
                windowed: Some(windowed),
                unguarded,
                call,
            })
        });
        let Ok((_, view)) = opened else {
            println!("FIXTURE FAILED no window");
            cx.quit();
            return;
        };
        cx.spawn(async move |cx: &mut AsyncApp| {
            let (passed, answers) = cx.update(|cx| check(view.read(cx), cx));
            println!("FIXTURE web-media {answers}");
            println!("FIXTURE {}", if passed { "passed" } else { "FAILED" });
            cx.update(|cx| cx.quit());
        })
        .detach();
    });
}
