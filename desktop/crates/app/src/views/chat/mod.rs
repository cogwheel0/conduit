//! The chat view's parts: the transcript and its rows, the block
//! renderers, message markdown, the composer with its menus and model
//! picker, and the code-block Preview window. [`crate::views::chat_pane`]
//! puts them together.

pub mod actions;
pub mod blocks;
pub mod branches;
pub mod call;
pub mod composer;
pub mod composer_panels;
pub mod diagram;
pub mod diagrams;
pub mod dictation;
pub mod embed;
pub mod export;
pub mod hermes_blocks;
pub mod hermes_work;
pub mod inline_web;
pub mod lazy_chunk;
pub mod live_connection;
pub mod markdown;
pub mod pace;
pub mod pdf_card;
pub mod popovers;
pub mod preview;
pub mod prompt;
pub mod queue;
pub mod remote_image;
pub mod rows;
pub mod share_sheet;
pub mod sheets;
pub mod sources;
pub mod speech_bar;
pub mod tasks;
pub mod transcript;
pub mod video;
pub mod web_guard;

use gpui_kit::{Global, WeakEntity};

/// Where a citation click goes: the transcript on screen. Markdown plugins
/// and link handlers must be `Send + Sync`, so they reach it through this
/// global rather than holding the view.
pub struct CitationTarget(pub WeakEntity<transcript::Transcript>);

impl Global for CitationTarget {}

/// The text of the last fenced code block in `markdown`, if any.
pub fn last_code_block(markdown: &str) -> Option<String> {
    fn fence(line: &str) -> Option<(char, usize)> {
        let trimmed = line.trim_start();
        let c = trimmed.chars().next().filter(|c| *c == '`' || *c == '~')?;
        let run = trimmed.chars().take_while(|x| *x == c).count();
        (run >= 3).then_some((c, run))
    }
    let mut last = None;
    let mut open: Option<((char, usize), Vec<&str>)> = None;
    for line in markdown.lines() {
        match &mut open {
            None => {
                if let Some(f) = fence(line) {
                    open = Some((f, vec![]));
                }
            }
            Some(((c, run), body)) => {
                let trimmed = line.trim();
                let closes = trimmed.chars().all(|x| x == *c) && trimmed.chars().count() >= *run;
                if closes {
                    last = Some(body.join("\n"));
                    open = None;
                } else {
                    body.push(line);
                }
            }
        }
    }
    last
}

#[cfg(test)]
mod tests {

    #[test]
    fn mention_tokens_read_as_their_names() {
        use super::rows::shown_mentions;
        assert_eq!(
            shown_mentions("Say hi <$plain-english|Plain English> to <@U:u-1|Riley>"),
            "Say hi $Plain English to @Riley"
        );
        assert_eq!(
            shown_mentions("<@M:gpt-4|GPT-4> and a < b > c"),
            "@GPT-4 and a < b > c"
        );
        assert_eq!(
            shown_mentions("<b>bold</b> <@x:y|z>"),
            "<b>bold</b> <@x:y|z>"
        );
        assert_eq!(shown_mentions("ends with <"), "ends with <");
    }

    use super::*;

    #[test]
    fn the_last_fenced_block_is_found() {
        let md = "Intro\n```rust\nfn a() {}\n```\nthen\n~~~\nplain\n~~~\nend";
        assert_eq!(last_code_block(md).as_deref(), Some("plain"));
        let md = "```py\nprint(1)\n```";
        assert_eq!(last_code_block(md).as_deref(), Some("print(1)"));
        // A longer fence holds a shorter one.
        let md = "````md\n```js\nx\n```\n````";
        assert_eq!(last_code_block(md).as_deref(), Some("```js\nx\n```"));
        assert_eq!(last_code_block("no code"), None);
        // Unclosed (still streaming): not a block yet.
        assert_eq!(last_code_block("```\nhalf"), None);
    }
}
