//! What VoiceOver hears for changes the user isn't on, in the app's words
//! (over [`conduit_components::announce`]).
//!
//! The lists a text field drives (the composer's `/`, `@`, `#` and `$`
//! menus, the model picker, the + menu's panels, the ⌘K palette) keep
//! focus in the field while ↑ and ↓ move their highlight. GPUI's
//! `aria_active_descendant` only reports a row while the focused node is
//! its ancestor, and these lists are the field's siblings, so the row's
//! selection alone is never heard: each step speaks the row and its place
//! instead ([`announce_row`]).

use conduit_components::announce::{Priority, announce};
use gpui_kit::App;

use crate::l10n::{ActiveL10n as _, L10n};

/// What a step to row `index` (0-based) of `count` says: the row's name,
/// then its place ("Summarize, 2 of 5").
pub fn row_text(l: &L10n, row: &str, index: usize, count: usize) -> String {
    l.desktop_announce_menu_row(row, &(index + 1).to_string(), &count.to_string())
}

/// Speaks row `index` of `count` at once, interrupting the previous step.
/// Nothing for an empty list or a nameless row.
pub fn announce_row(row: &str, index: usize, count: usize, cx: &mut App) {
    if count == 0 || row.trim().is_empty() {
        return;
    }
    let text = row_text(cx.l10n(), row, index.min(count - 1), count);
    announce(text, Priority::High, cx);
}

#[cfg(test)]
mod tests {
    use conduit_components::announce::{Announcement, AnnouncementLog};
    use gpui_kit::TestAppContext;

    use super::*;

    #[test]
    fn a_row_is_said_with_its_place_in_every_locale() {
        for locale in crate::l10n::LOCALES {
            let l = L10n::new(locale);
            let text = row_text(&l, "Summarize", 1, 5);
            assert!(
                text.contains("Summarize") && text.contains('2') && text.contains('5'),
                "{locale}: {text}"
            );
        }
        assert_eq!(
            row_text(&L10n::new("en"), "Summarize", 1, 5),
            "Summarize, 2 of 5"
        );
    }

    #[gpui_kit::test]
    fn announce_row_speaks_at_high_priority_and_skips_empty_lists(cx: &mut TestAppContext) {
        cx.update(|cx| {
            cx.set_global(L10n::new("en"));
            AnnouncementLog::install(cx);
            announce_row("Summarize", 1, 5, cx);
            announce_row("Nothing", 0, 0, cx);
            announce_row(" ", 0, 3, cx);
            assert_eq!(
                cx.global::<AnnouncementLog>().0,
                [Announcement {
                    text: "Summarize, 2 of 5".into(),
                    priority: Priority::High
                }]
            );
        });
    }
}
