/// The Conduit Core Protocol: the wire contract between the `conduitd`
/// sidecar and the desktop app.
///
/// Plain data with no `dart:io`, so any Dart client can import it, and the
/// JSON it produces is the contract for clients in other languages. The
/// golden fixtures under `test/` pin the exact bytes of every DTO, so a
/// change to the wire shows up as a reviewable diff rather than as a peer
/// that suddenly misreads a payload.
library;

export 'src/accounts.dart';
export 'src/auth.dart';
export 'src/blocks.dart';
export 'src/capabilities.dart';
export 'src/channels.dart';
export 'src/chats.dart';
export 'src/composer.dart';
export 'src/data.dart';
export 'src/direct.dart';
export 'src/events.dart';
export 'src/files.dart';
export 'src/handshake.dart';
export 'src/hermes.dart';
export 'src/mcp.dart';
export 'src/memories.dart';
export 'src/methods.dart';
export 'src/models.dart';
export 'src/notes.dart';
export 'src/profile.dart';
export 'src/peer_helpers.dart';
export 'src/prompts.dart';
export 'src/release_notes.dart';
export 'src/protocol_version.dart';
export 'src/rpc_error.dart';
export 'src/servers.dart';
export 'src/settings.dart';
export 'src/specs.dart';
export 'src/turns.dart';
export 'src/voice.dart';
export 'src/workspace.dart';
export 'src/subprotocol.dart';
export 'src/system.dart';
export 'src/terminal.dart';
