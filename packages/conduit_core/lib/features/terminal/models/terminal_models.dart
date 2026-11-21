import 'dart:typed_data';

import 'package:conduit_core/features/tether/tether_offers.dart';
import 'package:conduit_core/utils/utf16_sanitizer.dart';

enum TerminalServerKind { direct, system }

enum TerminalConnectionStatus { disconnected, connecting, connected, error }

/// Console vs file browser within the sidebar Terminal tab (driven from the
/// sidebar app bar).
enum TerminalSidebarPanel { console, files }

class TerminalServerInfo {
  const TerminalServerInfo({
    required this.kind,
    required this.selectionId,
    required this.baseUrl,
    this.systemServerId,
    this.apiKey,
    this.name = '',
    this.raw = const <String, dynamic>{},
    this.selectedEnabled = false,
    this.chatContextAvailable = true,
    this.requiresSavedChatContext = false,
    this.requiresModelContext = false,
    this.modelId,
  });

  final TerminalServerKind kind;
  final String selectionId;
  final Uri baseUrl;
  final String? systemServerId;
  final String? apiKey;
  final String name;
  final Map<String, dynamic> raw;
  final bool selectedEnabled;
  final bool chatContextAvailable;
  final bool requiresSavedChatContext;

  /// An Open WebUI 0.13.4 template that makes a machine per model (`scope:
  /// 'model'`): usable only for a model, which every call to it names.
  final bool requiresModelContext;

  /// The model a [requiresModelContext] terminal is used for ([forModel]).
  final String? modelId;

  bool get isDirect => kind == TerminalServerKind.direct;

  bool get isSystem => kind == TerminalServerKind.system;

  /// One of the user's own devices, which the server reaches through Tether.
  bool get isTetherDevice => isSystem && isTetherTerminalId(systemServerId);

  /// This terminal used for [model], the chat's model: only one made per
  /// model keeps it.
  TerminalServerInfo forModel(String? model) {
    if (!requiresModelContext) return this;
    final id = model?.trim();
    return TerminalServerInfo(
      kind: kind,
      selectionId: selectionId,
      baseUrl: baseUrl,
      systemServerId: systemServerId,
      apiKey: apiKey,
      name: name,
      raw: raw,
      selectedEnabled: selectedEnabled,
      chatContextAvailable: chatContextAvailable,
      requiresSavedChatContext: requiresSavedChatContext,
      requiresModelContext: true,
      modelId: id == null || id.isEmpty ? null : id,
    );
  }

  /// A terminal made per model with no model to use: Open WebUI refuses it
  /// (409 "This terminal requires a model").
  bool get needsModel => requiresModelContext && modelId == null;

  bool isAvailableForChatScope(String sessionScopeId) {
    if (!chatContextAvailable) return false;
    return !requiresSavedChatContext ||
        isSavedTerminalChatScopeId(sessionScopeId);
  }

  String get displayName {
    final trimmedName = name.trim();
    if (trimmedName.isNotEmpty) {
      return sanitizeUtf16(trimmedName);
    }

    if (isSystem &&
        systemServerId != null &&
        systemServerId!.trim().isNotEmpty) {
      return sanitizeUtf16(systemServerId!.trim());
    }

    final host = baseUrl.host.trim();
    if (host.isNotEmpty) {
      return sanitizeUtf16(host);
    }

    return sanitizeUtf16(selectionId);
  }

  String get subtitle {
    final host = baseUrl.host.trim();
    if (host.isEmpty) {
      return sanitizeUtf16(selectionId);
    }

    final port = baseUrl.hasPort ? ':${baseUrl.port}' : '';
    final path = baseUrl.path == '/' ? '' : baseUrl.path;
    return sanitizeUtf16('$host$port$path');
  }
}

/// What Open WebUI's chat ids start with when no saved chat stands behind
/// them (`utils/chat_id.py`).
const _unsavedChatIdPrefixes = ['local:', 'temporary:', 'channel:'];

bool isSavedTerminalChatScopeId(String value) {
  final id = value.trim();
  return id.isNotEmpty &&
      id != 'sidebar-terminal' &&
      !_unsavedChatIdPrefixes.any(id.startsWith);
}

/// [value] as Open WebUI's terminal proxy reads it in `X-Session-Id`.
///
/// Open WebUI 0.13.4 takes any id without one of [_unsavedChatIdPrefixes]
/// for a saved chat, and refuses one it cannot find, as it would the
/// `sidebar-terminal` scope of a terminal used outside any chat. Such a scope
/// goes as a `local:` id, which no release reads as a chat.
String terminalProxySessionId(String value) {
  final id = value.trim();
  if (id.isEmpty ||
      isSavedTerminalChatScopeId(id) ||
      _unsavedChatIdPrefixes.any(id.startsWith)) {
    return id;
  }
  return 'local:$id';
}

class TerminalFileEntry {
  const TerminalFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size,
    this.modifiedAt,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int? size;
  final DateTime? modifiedAt;

  String get displayName => sanitizeUtf16(name.trim().isEmpty ? path : name);
}

class TerminalListeningPort {
  const TerminalListeningPort({required this.port, this.pid, this.process});

  final int port;
  final int? pid;
  final String? process;
}

/// What a terminal server says it can do, from its `/api/config`.
///
/// A flag the server leaves out is off, so an older server is never sent to
/// an endpoint it does not have. Only [terminal] defaults on: servers that
/// predate the flag all had an interactive terminal.
class TerminalServerFeatures {
  const TerminalServerFeatures({
    this.terminal = true,
    this.events = false,
    this.browser = false,
  });

  /// Whether the server opens interactive terminal sessions.
  final bool terminal;

  /// Whether the server has the `/events` socket that reports file and port
  /// changes as they happen.
  final bool events;

  /// Whether the server opens browser sessions, whose pages load from a
  /// signed link without credentials.
  final bool browser;
}

/// A message from a terminal's `/events` socket.
sealed class TerminalEvent {
  const TerminalEvent();
}

/// The watched directory is being watched (`fs:ready`) or changed
/// (`fs:change`). The server names no files: the listing must be read again.
final class TerminalFilesChanged extends TerminalEvent {
  const TerminalFilesChanged();
}

/// The listening ports changed; [ports] is the whole new list.
final class TerminalPortsChanged extends TerminalEvent {
  const TerminalPortsChanged(this.ports);

  final List<TerminalListeningPort> ports;
}

class TerminalSessionInfo {
  const TerminalSessionInfo({
    required this.serverSelectionId,
    required this.sessionId,
    required this.sessionScopeId,
  });

  final String serverSelectionId;
  final String sessionId;
  final String sessionScopeId;
}

class TerminalConnectionState {
  const TerminalConnectionState({required this.status, this.message});

  const TerminalConnectionState.disconnected({this.message})
    : status = TerminalConnectionStatus.disconnected;

  const TerminalConnectionState.connecting({this.message})
    : status = TerminalConnectionStatus.connecting;

  const TerminalConnectionState.connected({this.message})
    : status = TerminalConnectionStatus.connected;

  const TerminalConnectionState.error({this.message})
    : status = TerminalConnectionStatus.error;

  final TerminalConnectionStatus status;
  final String? message;

  bool get isConnected => status == TerminalConnectionStatus.connected;

  bool get isConnecting => status == TerminalConnectionStatus.connecting;
}

class TerminalFileReadResult {
  const TerminalFileReadResult({
    required this.fileName,
    required this.contentType,
    this.text,
    this.bytes,
  });

  final String fileName;
  final String contentType;
  final String? text;
  final Uint8List? bytes;

  bool get isImage => contentType.startsWith('image/');

  bool get isText => text != null;
}

class TerminalDownloadedFile {
  const TerminalDownloadedFile({
    required this.fileName,
    required this.contentType,
    required this.bytes,
  });

  final String fileName;
  final String contentType;
  final Uint8List bytes;
}
