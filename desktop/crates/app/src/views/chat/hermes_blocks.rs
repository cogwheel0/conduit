//! A Hermes reply's own cards, drawn among its blocks as the phone draws
//! them in `AssistantMessageWidget`:
//!
//! * **Changed files** ([`changed_files`]): "2 files changed  +3 −1", then
//!   each file (up to six, "1 more file" after) with its counts; a click
//!   opens the file's coloured diff in a sheet. A file inside the chat's
//!   working directory is listed by its path from there
//!   ([`display_path`], core's `hermesDiffDisplayPath`).
//! * **A classified failure** ([`error_card`]): what broke, whether the
//!   chat is stuck or can go on, the provider and model, Hermes' sentence,
//!   when a limit resets, and the one fix this chat can perform (Retry,
//!   Continue, Compact Chat, Switch to a model, Open Billing, Open a
//!   provider's settings, New Chat).

use std::rc::Rc;

use chrono::{DateTime, Local, TimeZone as _};
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{ConduitTheme, MONO_FONT, with_alpha};
use conduit_components::views::focus::{ControlExt as _, Ring};
use conduit_components::views::kit::Button;
use conduit_protocol::{ChangedFileDto, HermesErrorDto};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, ClickEvent, ElementId, FontWeight, Role, SharedString, Window, div, px,
    relative,
};

use crate::l10n::L10n;
use crate::views::dates::{Form, format};

/// The most files the card lists before it sums up the rest.
const LISTED: usize = 6;

/// `path` as the card lists it: from `directory` (the chat's working
/// directory) when the file is inside it, else as Hermes sent it. `.` and
/// `..` are resolved first, so a path that only starts with the directory's
/// name is not taken for inside it; Windows drive paths compare without
/// case. Core's `hermesDiffDisplayPath`, for display only.
pub fn display_path(path: &str, directory: Option<&str>) -> String {
    let (Some(dir), Some(file)) = (directory.and_then(|d| resolved(d.trim())), resolved(path))
    else {
        return path.to_string();
    };
    // Relative to a root (`/`, `C:/`), a path would only lose its first
    // slash or its drive.
    if dir.ends_with('/') {
        return path.to_string();
    }
    let root = format!("{dir}/");
    let inside = if is_drive(&dir) {
        // The file's own first bytes, compared without case: lowercasing
        // can change a letter's length, and the cut below is by bytes.
        file.get(..root.len())
            .is_some_and(|head| head.to_lowercase() == root.to_lowercase())
    } else {
        file.starts_with(&root)
    };
    if inside {
        file[root.len()..].to_string()
    } else {
        path.to_string()
    }
}

fn is_drive(path: &str) -> bool {
    let b = path.as_bytes();
    b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && b[2] == b'/'
}

/// `value` with `\` as `/` and its empty, `.` and `..` segments resolved;
/// none unless it is absolute (`/…` or `C:/…`) and stays under its root.
fn resolved(value: &str) -> Option<String> {
    let slashed = value.replace('\\', "/");
    let prefix = if slashed.starts_with('/') {
        "/".to_string()
    } else if is_drive(&slashed) {
        slashed[..3].to_string()
    } else {
        return None;
    };
    let mut segments: Vec<&str> = vec![];
    for segment in slashed[prefix.len()..].split('/') {
        match segment {
            "" | "." => {}
            ".." => {
                segments.pop()?;
            }
            s => segments.push(s),
        }
    }
    Some(format!("{prefix}{}", segments.join("/")))
}

/// The last part of a path.
pub fn file_name(path: &str) -> &str {
    path.rsplit(['/', '\\']).next().unwrap_or(path)
}

/// Opens the diff sheet at a file.
pub type OpenDiff = Rc<dyn Fn(usize, &mut Window, &mut App)>;

/// What an error card's button does.
pub type Run = Rc<dyn Fn(&mut Window, &mut App)>;

/// "+3 −1".
fn counts(added: i64, removed: i64, t: &ConduitTheme) -> gpui_kit::Div {
    let m = t.metrics;
    div()
        .flex_none()
        .flex()
        .gap(px(6.))
        .font_family(MONO_FONT)
        .text_size(px(m.small))
        .font_weight(FontWeight::SEMIBOLD)
        .child(
            div()
                .text_color(t.roles.success)
                .child(SharedString::from(format!("+{added}"))),
        )
        .child(
            div()
                .text_color(t.roles.danger)
                .child(SharedString::from(format!("\u{2212}{removed}"))),
        )
}

/// The changed files card.
#[allow(clippy::too_many_arguments)]
pub fn changed_files(
    key: &str,
    files: &[ChangedFileDto],
    directory: Option<&str>,
    open: OpenDiff,
    l10n: &L10n,
    t: &ConduitTheme,
    window: &mut Window,
    cx: &mut App,
) -> Option<AnyElement> {
    if files.is_empty() {
        return None;
    }
    let r = t.roles;
    let m = t.metrics;
    let added: i64 = files.iter().map(|f| f.added).sum();
    let removed: i64 = files.iter().map(|f| f.removed).sum();
    let title = l10n.hermes_changed_files(files.len() as i64);
    let row = |i: usize, label: AnyElement, aria: String, window: &mut Window, cx: &mut App| {
        let open = open.clone();
        div()
            .id(ElementId::Name(format!("changed-file-{key}-{i}").into()))
            .role(Role::Button)
            .aria_label(SharedString::from(aria))
            .min_h(px(m.row_height + 2.))
            .px(px(8.))
            .flex()
            .items_center()
            .gap(px(8.))
            .rounded(px(6.))
            .cursor_pointer()
            .hover(|s| s.bg(r.hover))
            .child(label)
            .child(icon(IconName::ChevronRight, 12., r.text_faint))
            .on_click(move |_: &ClickEvent, window, cx| open(i, window, cx))
            .tip(l10n.desktop_hermes_show_changes(), None)
            .keyboard_control(Ring::Inset(6.), window, cx)
            .into_any_element()
    };
    let mut rows: Vec<AnyElement> = vec![];
    for (i, file) in files.iter().take(LISTED).enumerate() {
        let shown = if file.path.is_empty() {
            l10n.hermes_diff_unnamed_file()
        } else {
            display_path(&file.path, directory)
        };
        let name = if file.path.is_empty() {
            shown.clone()
        } else {
            file_name(&shown).to_string()
        };
        let folder = shown[..shown.len() - name.len()].to_string();
        let label = div()
            .flex_1()
            .min_w_0()
            .flex()
            .items_center()
            .gap(px(8.))
            .child(icon(IconName::FileText, 14., r.text_subtle))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .overflow_hidden()
                    .text_size(px(m.small))
                    .child(
                        div()
                            .flex_none()
                            .max_w(px(320.))
                            .truncate()
                            .text_color(r.text)
                            .font_weight(FontWeight::MEDIUM)
                            .child(SharedString::from(name.clone())),
                    )
                    .when(!folder.is_empty(), |d| {
                        d.child(
                            div()
                                .min_w_0()
                                .pl(px(6.))
                                .truncate()
                                .text_color(r.text_faint)
                                .child(SharedString::from(folder.clone())),
                        )
                    }),
            )
            .child(counts(file.added, file.removed, t))
            .into_any_element();
        let aria = format!(
            "{name}, {}",
            l10n.hermes_diff_line_counts(file.added, file.removed)
        );
        rows.push(row(i, label, aria, window, cx));
    }
    if files.len() > LISTED {
        let more = l10n.hermes_changed_files_more((files.len() - LISTED) as i64);
        let label = div()
            .flex_1()
            .pl(px(22.))
            .text_size(px(m.small))
            .text_color(r.text_subtle)
            .child(SharedString::from(more.clone()))
            .into_any_element();
        rows.push(row(LISTED, label, more, window, cx));
    }
    Some(
        div()
            .id(ElementId::Name(format!("changed-files-{key}").into()))
            .role(Role::Group)
            .aria_label(SharedString::from(title.clone()))
            .w_full()
            .px(px(6.))
            .py(px(4.))
            .flex()
            .flex_col()
            .rounded(t.card_radius())
            .border_1()
            .border_color(r.border)
            .bg(conduit_components::views::kit::on_raised_fill(t))
            .child(
                div()
                    .min_h(px(m.row_height + 2.))
                    .px(px(8.))
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .child(icon(IconName::FileCode, 14., r.text_subtle))
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(m.small))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(r.text)
                            .child(SharedString::from(title)),
                    )
                    .child(counts(added, removed, t)),
            )
            .children(rows)
            .into_any_element(),
    )
}

/// What a failure's card leads with, in the phone's words.
pub fn error_title(kind: &str, l10n: &L10n) -> String {
    match kind {
        "provider" => l10n.hermes_error_provider(),
        "endpoint" => l10n.hermes_error_endpoint(),
        "connection" => l10n.hermes_error_connection(),
        "auth" => l10n.hermes_error_auth(),
        "billing" => l10n.hermes_error_billing(),
        "usageLimit" => l10n.hermes_error_usage_limit(),
        "freeTier" => l10n.hermes_error_free_tier(),
        "rateLimit" => l10n.hermes_error_rate_limit(),
        "contextOverflow" => l10n.hermes_error_context_overflow(),
        "model" => l10n.hermes_error_model(),
        "policy" => l10n.hermes_error_policy(),
        "truncated" => l10n.hermes_error_truncated(),
        "badReply" => l10n.hermes_error_bad_reply(),
        "workspace" => l10n.hermes_error_workspace(),
        "session" => l10n.hermes_error_session(),
        "busy" => l10n.hermes_error_busy(),
        "gateway" => l10n.hermes_error_gateway(),
        "gatewaySignIn" => l10n.hermes_error_gateway_sign_in(),
        "disk" => l10n.hermes_error_disk(),
        _ => l10n.hermes_error_unknown(),
    }
}

fn error_icon(kind: &str) -> IconName {
    match kind {
        "endpoint" | "connection" => IconName::CloudOff,
        "auth" | "gatewaySignIn" => IconName::KeyRound,
        "billing" | "usageLimit" | "freeTier" => IconName::CircleSlash,
        "rateLimit" | "busy" => IconName::Timer,
        "contextOverflow" => IconName::Layers,
        "model" => IconName::Cpu,
        "policy" => IconName::ShieldAlert,
        "truncated" => IconName::ScrollText,
        "workspace" => IconName::FolderClosed,
        "gateway" | "session" => IconName::Server,
        "disk" => IconName::Database,
        _ => IconName::CircleAlert,
    }
}

/// When a limit resets: the time today, else the day and the time.
pub fn reset_time(ms: i64, l10n: &L10n) -> String {
    let locale = l10n.locale();
    let time = format(ms, Form::Time, locale);
    let today = Local::now().date_naive();
    let day = Local
        .timestamp_millis_opt(ms)
        .single()
        .map(|d: DateTime<Local>| d.date_naive());
    if day == Some(today) {
        time
    } else {
        format!("{} {time}", format(ms, Form::DayMonth, locale))
    }
}

/// A fix the card offers, as it reads.
pub fn action_label(action: &str, error: &HermesErrorDto, l10n: &L10n) -> Option<String> {
    Some(match action {
        "retry" => l10n.retry(),
        "continueReply" => l10n.hermes_error_continue(),
        "compact" => l10n.hermes_error_compact(),
        "switchModel" => l10n.hermes_error_switch_model(&error.switch_to.as_ref()?.label),
        "openProviderSettings" => {
            error.provider_settings_url.as_ref()?;
            l10n.hermes_error_open_provider_settings(error.provider.as_deref().unwrap_or(""))
        }
        "openBilling" => {
            error.billing_url.as_ref()?;
            l10n.hermes_error_open_billing()
        }
        "newChat" => l10n.new_chat(),
        _ => return None,
    })
}

/// The failure's card. `action` is the fix this chat can perform (the
/// first of `error.actions` it can), with what pressing it does.
pub fn error_card(
    id: &str,
    error: &HermesErrorDto,
    error_text: &str,
    action: Option<(String, Run)>,
    l10n: &L10n,
    t: &ConduitTheme,
) -> AnyElement {
    let r = t.roles;
    let m = t.metrics;
    let title = error_title(&error.kind, l10n);
    let accent = if error.blocking {
        r.danger
    } else {
        r.text_subtle
    };
    let identity = [error.provider.clone(), error.model.clone()]
        .into_iter()
        .flatten()
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" \u{b7} ");
    let body = error
        .message
        .clone()
        .filter(|m| !m.trim().is_empty())
        .or_else(|| (!error_text.trim().is_empty()).then(|| error_text.to_string()));
    let now = chrono::Utc::now().timestamp_millis();
    let reset = error.resets_at_ms.filter(|ms| *ms > now);
    let severity = if error.blocking {
        l10n.hermes_error_blocking()
    } else {
        l10n.hermes_error_degraded()
    };
    div()
        .id(ElementId::Name(format!("hermes-error-{id}").into()))
        .role(Role::Alert)
        .aria_label(SharedString::from(format!("{title}. {severity}")))
        .w_full()
        .px(px(12.))
        .py(px(10.))
        .flex()
        .flex_col()
        .gap(px(6.))
        .rounded(t.card_radius())
        .border_1()
        .border_color(if error.blocking {
            with_alpha(r.danger, 0.4)
        } else {
            r.border
        })
        .bg(if error.blocking {
            with_alpha(r.danger, if t.dark { 0.12 } else { 0.06 })
        } else {
            conduit_components::views::kit::on_raised_fill(t)
        })
        .child(
            div()
                .flex()
                .items_start()
                .gap(px(8.))
                .child(
                    div()
                        .pt(px(2.))
                        .child(icon(error_icon(&error.kind), 15., accent)),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .gap(px(1.))
                        .child(
                            div()
                                .text_size(px(m.control))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(r.text)
                                .child(SharedString::from(title)),
                        )
                        .child(
                            div()
                                .text_size(px(m.small))
                                .text_color(accent)
                                .child(SharedString::from(severity)),
                        ),
                )
                .when_some(action, |d, (label, run)| {
                    d.child(
                        div().flex_none().child(
                            Button::new(
                                ElementId::Name(format!("hermes-error-action-{id}").into()),
                                label,
                            )
                            .on_click(Rc::new(move |_, window, cx| run(window, cx))),
                        ),
                    )
                }),
        )
        .when(!identity.is_empty(), |d| {
            d.child(
                div()
                    .pl(px(23.))
                    .text_size(px(m.small))
                    .text_color(r.text_faint)
                    .child(SharedString::from(identity)),
            )
        })
        .when_some(body, |d, body| {
            d.child(
                div()
                    .pl(px(23.))
                    .text_size(px(m.small))
                    .line_height(relative(1.45))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(body)),
            )
        })
        .when(error.partial, |d| {
            d.child(
                div()
                    .pl(px(23.))
                    .text_size(px(m.small))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(l10n.hermes_error_partial_kept())),
            )
        })
        .when_some(reset, |d, ms| {
            d.child(
                div()
                    .pl(px(23.))
                    .flex()
                    .items_center()
                    .gap(px(5.))
                    .child(icon(IconName::Clock, 12., r.text_subtle))
                    .child(
                        div()
                            .text_size(px(m.small))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(r.text)
                            .child(SharedString::from(
                                l10n.hermes_error_resets_at(&reset_time(ms, l10n)),
                            )),
                    ),
            )
        })
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_inside_the_working_directory_is_listed_from_there() {
        let dir = Some("/home/u/projects/harbour");
        assert_eq!(
            display_path("/home/u/projects/harbour/notes/pier.md", dir),
            "notes/pier.md"
        );
        // Only starts with the directory's name: not inside it.
        assert_eq!(
            display_path("/home/u/projects/harbour-old/pier.md", dir),
            "/home/u/projects/harbour-old/pier.md"
        );
        // `..` resolved first.
        assert_eq!(
            display_path("/home/u/projects/harbour/../pier.md", dir),
            "/home/u/projects/harbour/../pier.md"
        );
        assert_eq!(
            display_path("/home/u/projects/harbour/a/../b.md", dir),
            "b.md"
        );
        // A root directory, a relative path, no directory: as sent.
        assert_eq!(display_path("/pier.md", Some("/")), "/pier.md");
        assert_eq!(display_path("pier.md", dir), "pier.md");
        assert_eq!(display_path("/x/pier.md", None), "/x/pier.md");
        // Windows drives compare without case.
        assert_eq!(
            display_path("c:\\Work\\Src\\a.rs", Some("C:/work")),
            "Src/a.rs"
        );
        // A letter that lowercases to fewer bytes (the Kelvin sign is `k`)
        // is not the directory's: the path as sent, never a cut letter.
        assert_eq!(
            display_path("C:/\u{212A}/a.rs", Some("C:/K")),
            "C:/\u{212A}/a.rs"
        );
    }

    #[test]
    fn every_kind_has_words_and_an_action_needs_what_it_opens() {
        let l10n = L10n::new("en");
        assert_eq!(error_title("rateLimit", &l10n), "Rate limit reached");
        assert_eq!(error_title("gatewaySignIn", &l10n), "Signed out of Hermes");
        assert_eq!(
            error_title("something-new", &l10n),
            l10n.hermes_error_unknown()
        );
        let error = HermesErrorDto {
            kind: "billing".into(),
            blocking: true,
            message: None,
            provider: Some("Demo".into()),
            model: None,
            resets_at_ms: None,
            partial: false,
            actions: vec!["openBilling".into(), "retry".into()],
            switch_to: None,
            billing_url: None,
            provider_settings_url: None,
        };
        // No billing page to open: not offered.
        assert_eq!(action_label("openBilling", &error, &l10n), None);
        assert_eq!(action_label("retry", &error, &l10n), Some("Retry".into()));
        assert_eq!(
            action_label("compact", &error, &l10n),
            Some("Compact Chat".into())
        );
    }
}
