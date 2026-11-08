/// `metadata['transport']` of a message a LibreChat turn produced, and the
/// conversation `metadata['backend']` of a LibreChat chat.
///
/// Both are app-owned provenance, like Hermes' and Direct's markers: Stop,
/// regenerate and approvals route on them. An Open WebUI payload that claims
/// either has it stripped when parsed (`conversation_parsing.dart`), so a
/// server can never send a request to LibreChat in the user's name.
const String kLibreChatTransport = 'libreChat';

/// Metadata keys starting with this (any case) carry LibreChat's own message
/// and conversation state. Open WebUI payloads lose them on parse too.
const String kLibreChatMetadataPrefix = 'librechat';

/// Whether [key] is LibreChat-owned metadata.
bool isLibreChatMetadataKey(Object? key) =>
    key.toString().toLowerCase().startsWith(kLibreChatMetadataPrefix);
