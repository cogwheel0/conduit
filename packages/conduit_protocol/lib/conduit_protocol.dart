/// The Conduit Core Protocol: the wire contract between the `conduitd`
/// sidecar and the desktop app.
///
/// Plain data with no `dart:io`, so any Dart client can import it, and the
/// JSON it produces is the contract for clients in other languages. The
/// golden fixtures under `test/` pin the exact bytes of every DTO, so a
/// change to the wire shows up as a reviewable diff rather than as a peer
/// that suddenly misreads a payload.
library;

export 'src/access.dart';
export 'src/accounts.dart';
export 'src/auth.dart';
export 'src/automations.dart';
export 'src/blocks.dart';
export 'src/calendar.dart';
export 'src/calls.dart';
export 'src/capabilities.dart';
export 'src/chat_prompts.dart';
export 'src/channels.dart';
export 'src/chat_settings.dart';
export 'src/chats.dart';
export 'src/composer.dart';
export 'src/computer.dart';
export 'src/data.dart';
export 'src/dictation.dart';
export 'src/direct.dart';
export 'src/events.dart';
export 'src/files.dart';
export 'src/handoff.dart';
export 'src/speech.dart';
export 'src/apple.dart';
export 'src/handshake.dart';
export 'src/integrations.dart';
export 'src/hermes.dart';
export 'src/hermes_admin.dart';
export 'src/hermes_rooms.dart';
export 'src/hermes_work.dart';
export 'src/intents.dart';
export 'src/librechat.dart';
export 'src/location.dart';
export 'src/mcp.dart';
export 'src/mcp_apps.dart';
export 'src/memories.dart';
export 'src/messages.dart';
export 'src/methods.dart';
export 'src/models.dart';
export 'src/notes.dart';
export 'src/notifications.dart';
export 'src/profile.dart';
export 'src/peer_helpers.dart';
export 'src/prompts.dart';
export 'src/release_notes.dart';
export 'src/queue.dart';
export 'src/recordings.dart';
export 'src/protocol_version.dart';
export 'src/rpc_error.dart';
export 'src/servers.dart';
export 'src/settings.dart';
export 'src/specs.dart';
export 'src/turns.dart';
export 'src/valves.dart';
export 'src/voice.dart';
export 'src/web_search.dart';
export 'src/webhooks.dart';
export 'src/workspace.dart';
export 'src/subprotocol.dart';
export 'src/system.dart';
export 'src/terminal.dart';
