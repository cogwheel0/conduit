import 'dart:typed_data';

import '../../../shared/utils/utf16_sanitizer.dart';

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
  });

  final TerminalServerKind kind;
  final String selectionId;
  final Uri baseUrl;
  final String? systemServerId;
  final String? apiKey;
  final String name;
  final Map<String, dynamic> raw;
  final bool selectedEnabled;

  bool get isDirect => kind == TerminalServerKind.direct;

  bool get isSystem => kind == TerminalServerKind.system;

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
