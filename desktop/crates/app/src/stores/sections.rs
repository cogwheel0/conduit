//! Which sidebar sections are closed, and which show all their items, per
//! account (`sidebar-sections.json`).
//!
//! A section is named by a key: an area (`notes`), or one of the Chats
//! area's own sections (`chats.pinned`, `chats.date.today`). Each account
//! (an Open WebUI account by id; the Direct, Hermes and demo setups by
//! kind) keeps its own, as the phone keeps each account's tab. Saved a
//! moment after a change, so a run of clicks writes once.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::time::Duration;

use gpui_kit::{AsyncApp, Context, Task, WeakEntity};
use serde::{Deserialize, Serialize};

use crate::prefs;

/// One account's sections.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SectionState {
    /// Closed sections, by key.
    pub collapsed: BTreeSet<String>,
    /// Areas listing every item rather than the first few.
    pub show_all: BTreeSet<String>,
}

/// The file: each account's sections, by scope.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SectionsFile {
    pub accounts: BTreeMap<String, SectionState>,
}

pub struct SectionsStore {
    /// `None`: kept in memory only (tests, the fixtures).
    path: Option<PathBuf>,
    file: SectionsFile,
    /// The account the sections are this one's.
    scope: String,
    /// Bumped on every change, for the sidebar's rows cache.
    revision: u64,
    pending_save: Option<Task<()>>,
}

impl SectionsStore {
    pub fn load(path: Option<PathBuf>) -> Self {
        let file = path
            .as_deref()
            .map(prefs::load::<SectionsFile>)
            .unwrap_or_default();
        Self {
            path,
            file,
            scope: String::new(),
            revision: 0,
            pending_save: None,
        }
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    pub fn scope(&self) -> &str {
        &self.scope
    }

    /// Another account's sections, from now on.
    pub fn set_scope(&mut self, scope: String, cx: &mut Context<Self>) {
        if self.scope != scope {
            self.scope = scope;
            self.revision += 1;
            cx.notify();
        }
    }

    fn state(&self) -> Option<&SectionState> {
        self.file.accounts.get(&self.scope)
    }

    pub fn is_collapsed(&self, key: &str) -> bool {
        self.state().is_some_and(|s| s.collapsed.contains(key))
    }

    pub fn shows_all(&self, key: &str) -> bool {
        self.state().is_some_and(|s| s.show_all.contains(key))
    }

    /// Opens or closes section `key`.
    pub fn set_collapsed(&mut self, key: &str, collapsed: bool, cx: &mut Context<Self>) {
        if self.is_collapsed(key) == collapsed {
            return;
        }
        let state = self.file.accounts.entry(self.scope.clone()).or_default();
        if collapsed {
            state.collapsed.insert(key.to_string());
        } else {
            state.collapsed.remove(key);
        }
        self.changed(cx);
    }

    pub fn toggle_collapsed(&mut self, key: &str, cx: &mut Context<Self>) {
        let collapsed = !self.is_collapsed(key);
        self.set_collapsed(key, collapsed, cx);
    }

    /// Lists every item of area `key`, or the first few again.
    pub fn set_show_all(&mut self, key: &str, all: bool, cx: &mut Context<Self>) {
        if self.shows_all(key) == all {
            return;
        }
        let state = self.file.accounts.entry(self.scope.clone()).or_default();
        if all {
            state.show_all.insert(key.to_string());
        } else {
            state.show_all.remove(key);
        }
        self.changed(cx);
    }

    fn changed(&mut self, cx: &mut Context<Self>) {
        self.revision += 1;
        cx.notify();
        if self.path.is_none() {
            return;
        }
        self.pending_save = Some(cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                cx.background_executor()
                    .timer(Duration::from_millis(300))
                    .await;
                let _ = this.update(cx, |s, _| s.save_now());
            },
        ));
    }

    pub fn save_now(&self) {
        if let Some(path) = &self.path
            && let Err(e) = prefs::save(path, &self.file)
        {
            log::error!("could not save {}: {e}", path.display());
        }
    }
}

#[cfg(test)]
mod tests {
    use gpui_kit::{AppContext as _, TestAppContext};

    use super::*;

    #[gpui_kit::test]
    fn each_account_keeps_its_own_sections_across_launches(cx: &mut TestAppContext) {
        let dir = std::env::temp_dir().join(format!("conduit-sections-{}", std::process::id()));
        let path = dir.join("sidebar-sections.json");
        let store = cx.new(|_| SectionsStore::load(Some(path.clone())));
        store.update(cx, |s, cx| {
            s.set_scope("account-a".into(), cx);
            s.toggle_collapsed("notes", cx);
            s.set_show_all("channels", true, cx);
            s.set_scope("direct".into(), cx);
            assert!(!s.is_collapsed("notes"), "another account starts open");
            s.set_collapsed("chats.pinned", true, cx);
            s.save_now();
        });
        let again = SectionsStore::load(Some(path.clone()));
        let read = |scope: &str| again.file.accounts.get(scope).cloned().unwrap_or_default();
        assert!(read("account-a").collapsed.contains("notes"));
        assert!(read("account-a").show_all.contains("channels"));
        assert!(read("direct").collapsed.contains("chats.pinned"));
        assert!(!read("direct").collapsed.contains("notes"));
        let _ = std::fs::remove_dir_all(dir);
    }
}
