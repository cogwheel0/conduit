//! Mobile-chat replacement for Codex's V8-backed code-mode runtime.
//!
//! The protocol types remain available because `codex-core` references them
//! in dormant tool-planning code, but no executable runtime or process host is
//! linked into Conduit.

use std::path::PathBuf;
use std::sync::Arc;

pub use codex_code_mode_protocol::*;

const DISABLED: &str = "code mode is disabled by the Conduit mobile-chat runtime";

#[derive(Default)]
pub struct InProcessCodeModeSessionProvider;

impl CodeModeSessionProvider for InProcessCodeModeSessionProvider {
    fn create_session<'a>(
        &'a self,
        _delegate: Arc<dyn CodeModeSessionDelegate>,
    ) -> CodeModeSessionProviderFuture<'a> {
        Box::pin(async { Err(DISABLED.to_owned()) })
    }
}

#[derive(Default)]
pub struct ProcessOwnedCodeModeSessionProvider;

impl ProcessOwnedCodeModeSessionProvider {
    pub fn with_host_program(_host_program: PathBuf) -> Self {
        Self
    }
}

impl CodeModeSessionProvider for ProcessOwnedCodeModeSessionProvider {
    fn create_session<'a>(
        &'a self,
        _delegate: Arc<dyn CodeModeSessionDelegate>,
    ) -> CodeModeSessionProviderFuture<'a> {
        Box::pin(async { Err(DISABLED.to_owned()) })
    }
}
