//! `route.remap`: the daemon replaced a chat id (a temporary chat that was
//! saved, a local id the server gave a real one). Whatever shows `from`
//! moves to `to`. The sidebar's selection and the open chats resolve their
//! ids through [`RouterStore::resolve`] and listen for
//! [`RouterEvent::Remapped`].

use std::collections::HashMap;

use gpui_kit::{Context, EventEmitter};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RouterEvent {
    Remapped { from: String, to: String },
}

#[derive(Default)]
pub struct RouterStore {
    remaps: HashMap<String, String>,
}

impl EventEmitter<RouterEvent> for RouterStore {}

impl RouterStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// The id `id` is known by now, following chains (`a → b → c`).
    pub fn resolve(&self, id: &str) -> String {
        let mut current = id;
        // Bounded: a cycle from a confused daemon must not hang the window.
        for _ in 0..16 {
            match self.remaps.get(current) {
                Some(next) if next != current => current = next,
                _ => break,
            }
        }
        current.to_string()
    }

    pub fn on_remap(&mut self, from: String, to: String, cx: &mut Context<Self>) {
        if from == to {
            return;
        }
        self.remaps.insert(from.clone(), to.clone());
        cx.emit(RouterEvent::Remapped { from, to });
        cx.notify();
    }

    /// A new daemon session: earlier ids may mean nothing now.
    pub fn reset(&mut self) {
        self.remaps.clear();
    }
}

#[cfg(test)]
mod tests {
    use gpui_kit::{AppContext as _, TestAppContext};

    use super::*;

    #[gpui_kit::test]
    fn remaps_chain_and_announce(cx: &mut TestAppContext) {
        let store = cx.new(|_| RouterStore::new());
        let seen = std::rc::Rc::new(std::cell::RefCell::new(vec![]));
        cx.update(|cx| {
            let seen = seen.clone();
            cx.subscribe(&store, move |_, e: &RouterEvent, _| {
                seen.borrow_mut().push(e.clone())
            })
            .detach();
        });
        store.update(cx, |s, cx| {
            s.on_remap("local:1".into(), "tmp".into(), cx);
            s.on_remap("tmp".into(), "c42".into(), cx);
            s.on_remap("x".into(), "x".into(), cx);
        });
        store.read_with(cx, |s, _| {
            assert_eq!(s.resolve("local:1"), "c42");
            assert_eq!(s.resolve("other"), "other");
        });
        assert_eq!(seen.borrow().len(), 2);
        // A cycle resolves without hanging.
        store.update(cx, |s, cx| s.on_remap("c42".into(), "local:1".into(), cx));
        let _ = store.read_with(cx, |s, _| s.resolve("local:1"));
    }
}
