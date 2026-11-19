//! Direct connections: model APIs the app talks to itself, with no Open
//! WebUI server between (OpenAI-compatible servers, OpenRouter, Ollama on
//! this Mac or Ollama Cloud), and the MCP servers whose tools their models
//! may call.
//!
//! * [`form`]: the connection form, inline in onboarding and in the editor.
//! * [`editor`]: Add Connection / Edit Connection, a sheet on Settings.
//! * [`ollama`]: an Ollama connection's models (memory, thinking).
//! * [`mcp`]: Add MCP Server / Edit MCP Server, a sheet on Settings.
//! * [`pane`]: Settings › Direct Connections.

pub mod editor;
pub mod form;
pub mod mcp;
pub mod ollama;
pub mod pane;

pub use form::{DirectEvent, DirectNote, DirectView};
