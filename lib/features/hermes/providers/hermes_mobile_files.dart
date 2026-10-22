import 'dart:convert';
import 'package:conduit_core/features/hermes/models/hermes_media.dart';

import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum HermesFileCategory { all, artifacts, outputs, uploads }

class HermesLibraryFile {
  const HermesLibraryFile({
    required this.name,
    required this.category,
    required this.session,
    required this.messageId,
    this.outputPath,
    this.imageId,
    this.extractedText,
  });
  final String name;
  final HermesFileCategory category;
  final HermesSessionSummary session;
  final String messageId;
  final String? outputPath;
  final String? imageId;
  final String? extractedText;
  String get identity =>
      '${session.id}:${outputPath ?? imageId ?? '$messageId:$name'}';
}

/// Index attachments already recognized by the transcript mapper. Never turn
/// arbitrary user text or remote URLs into downloadable files. Assistant file
/// links remain candidates until an explicit tap passes the server root checks.
List<HermesLibraryFile> hermesLibraryFilesForMessages(
  List<ChatMessage> messages,
  HermesSessionSummary session,
) {
  final result = <HermesLibraryFile>[];
  for (final message in messages) {
    final category = message.role == 'user'
        ? HermesFileCategory.uploads
        : HermesFileCategory.artifacts;
    for (final file in message.files ?? const <Map<String, dynamic>>[]) {
      final name = (file['name'] ?? file['filename'])?.toString();
      if (name == null || name.isEmpty) continue;
      result.add(
        HermesLibraryFile(
          name: name,
          category: message.role == 'user'
              ? category
              : _outputCategory(file, name),
          session: session,
          messageId: message.id,
          outputPath: HermesMediaReference.fromDescriptor(file)?.path,
          extractedText: file['hermes_extracted_text'] as String?,
        ),
      );
    }
    for (var index = 0; index < (message.attachmentIds?.length ?? 0); index++) {
      result.add(
        HermesLibraryFile(
          name: 'Image ${index + 1}',
          imageId: message.attachmentIds![index],
          category: category,
          session: session,
          messageId: message.id,
        ),
      );
    }
    if (message.role == 'assistant') {
      for (final media in hermesMediaReferences(message.content)) {
        if (!result.any((file) => file.outputPath == media.path && file.session.id == session.id)) {
          result.add(_outputFile(media.path, session, message.id));
        }
      }
      _collectOutputPaths(message.content, (path) {
        if (result.any((file) => file.outputPath == path)) return;
        result.add(_outputFile(path, session, message.id));
      });
      for (final match in RegExp(
        r'!?\[([^\]]*)\]\(([^)\s]+)\)',
      ).allMatches(message.content).take(100)) {
        final target = match.group(2)!;
        final uri = Uri.tryParse(target);
        if (uri == null || (uri.hasScheme && uri.scheme != 'file')) continue;
        final path = Uri.decodeComponent(uri.path);
        if (path.isEmpty ||
            !RegExp(
              r'\.(pdf|docx|pptx|xlsx|html|md|txt|csv|json|png|jpg|jpeg|webp|gif|zip|mp3|wav|mp4)$',
              caseSensitive: false,
            ).hasMatch(path)) {
          continue;
        }
        final name = path.split('/').last;
        if (result.any(
          (file) => file.outputPath == path && file.session.id == session.id,
        )) {
          continue;
        }
        result.add(
          HermesLibraryFile(
            name: name,
            category: _outputCategory(const {}, name),
            session: session,
            messageId: message.id,
            outputPath: path,
          ),
        );
      }
    }
  }
  return result;
}

HermesLibraryFile _outputFile(
  String path,
  HermesSessionSummary session,
  String messageId,
) => HermesLibraryFile(
  name: path.split('/').last,
  category: _outputCategory(const {}, path),
  session: session,
  messageId: messageId,
  outputPath: path,
);

final _outputExtension = RegExp(
  r'\.(pdf|docx?|pptx?|xlsx?|html|md|txt|csv|json|png|jpe?g|webp|gif|svg|bmp|zip|tar|gz|mp3|wav|flac|m4a|ogg|opus|mp4|mov|webm|mkv)$',
  caseSensitive: false,
);

void _collectOutputPaths(String text, void Function(String) add) {
  if (text.length > 512 * 1024) text = text.substring(0, 512 * 1024);
  final candidates = <String>[
    if (!text.contains(RegExp(r'\s'))) text,
    for (final match in RegExp(r'!?\[[^\]]*\]\(([^)\s]+)\)').allMatches(text))
      match.group(1)!,
    for (final match in RegExp(
      r'''(?:^|[\s("'`=:])((?:/|~/|\./|\.\./|file:///)[^\s"'`<>]+)''',
    ).allMatches(text))
      match.group(1)!,
  ];
  for (final raw in candidates.take(100)) {
    final uri = Uri.tryParse(raw.replaceFirst(RegExp(r'[),;.!]+$'), ''));
    if (uri == null ||
        (uri.hasScheme && uri.scheme != 'file') ||
        uri.hasAuthority && uri.host.isNotEmpty) {
      continue;
    }
    String path;
    try {
      path = Uri.decodeComponent(uri.path);
    } on FormatException {
      continue;
    }
    if (_outputExtension.hasMatch(path)) add(path);
  }
}

/// Discover tool outputs before the chat mapper folds tool rows into activity.
/// Paths are candidates only; explicit previews still use server root checks.
List<HermesLibraryFile> hermesLibraryFilesForTranscript(
  List<Map<String, dynamic>> raw,
  HermesSessionSummary session, {
  Set<String> trustedLocalDocumentKeys = const {},
}) {
  final result = hermesLibraryFilesForMessages(
    hermesMessagesToChatMessages(
      raw,
      trustedLocalDocumentKeys: trustedLocalDocumentKeys,
    ),
    session,
  );
  final seen = {
    for (final file in result)
      if (file.outputPath != null) file.outputPath!,
  };
  final producer = RegExp(
    r'(?:^|_)(create|creation|download|export|generate|generation|render|save|speech|tts|write)(?:_|$)',
    caseSensitive: false,
  );
  final strongKey = RegExp(
    r'^(artifact_(file|image|path|url)|files?_(created|modified|written)|generated_(file|image|path|url)|media_tag|output_(file|path|url)|result_(file|path|url)|saved_to|screenshot_path)$',
    caseSensitive: false,
  );
  final producerKey = RegExp(
    r'^(artifacts?|attachments?|downloads?|audio|image|video|file_path|local_path|media|path)$',
    caseSensitive: false,
  );
  for (var index = 0; index < raw.length; index++) {
    final message = raw[index];
    if (message['role'] != 'tool') continue;
    final name = (message['tool_name'] ?? message['name'] ?? '').toString();
    final produces = producer.hasMatch(name) || name.startsWith('bfl_flux3_');
    final terminal = name == 'terminal';
    final id = (message['id'] ?? 'tool-$index').toString();
    void add(String path) {
      if (seen.add(path)) result.add(_outputFile(path, session, id));
    }

    Object? payload = message['content'];
    if (payload is String) {
      if (produces || terminal || name == 'browser_vision') {
        _collectOutputPaths(payload, add);
      }
      if (payload.length > 512 * 1024) continue;
      final stripped = payload
          .replaceAll(RegExp(r'</?untrusted_tool_result[^>]*>'), '')
          .trim();
      try {
        payload = jsonDecode(stripped);
      } on FormatException {
        continue;
      }
    }
    var visited = 0;
    void visit(Object? value, bool explicit, int depth) {
      if (depth > 12 || ++visited > 2000) return;
      if (value is Map) {
        for (final entry in value.entries.take(200)) {
          final key = entry.key.toString();
          visit(
            entry.value,
            explicit ||
                strongKey.hasMatch(key) ||
                produces && producerKey.hasMatch(key) ||
                terminal && const {'output', 'stdout', 'path'}.contains(key),
            depth + 1,
          );
        }
      } else if (value is List) {
        for (final item in value.take(200)) {
          visit(item, explicit, depth + 1);
        }
      } else if (value is String && explicit) {
        _collectOutputPaths(value, add);
      }
    }

    visit(payload, false, 0);
  }
  return result;
}

HermesFileCategory _outputCategory(Map<String, dynamic> file, String name) {
  final mime = (file['content_type'] ?? file['mime_type'] ?? '').toString();
  final artifact =
      file['type'] == 'artifact' ||
      mime.startsWith('image/') ||
      RegExp(
        r'\.(pdf|docx|pptx|xlsx|html|md|png|jpg|jpeg|webp|gif)$',
        caseSensitive: false,
      ).hasMatch(name);
  return artifact ? HermesFileCategory.artifacts : HermesFileCategory.outputs;
}

class HermesFileLibrary {
  const HermesFileLibrary(
    this.files, {
    this.partial = false,
    this.indexing = false,
  });
  final List<HermesLibraryFile> files;
  final bool partial;
  final bool indexing;
}

/// The completed, locally loaded conversation contributes new files without
/// another transcript sweep. Never carry a previous connection's shell over.
class HermesLiveFiles extends Notifier<List<HermesLibraryFile>> {
  Object? _owner;
  List<HermesLibraryFile> _files = const [];
  @override
  List<HermesLibraryFile> build() {
    final service = ref.watch(hermesApiServiceProvider);
    final conversation = ref.watch(activeConversationProvider);
    if (service == null || !isNativeHermesConversation(conversation)) {
      _owner = null;
      return _files = const [];
    }
    final endpoint = HermesConfigController.connectionEndpoint(
      service.config.baseUrl,
    );
    final identity = endpoint == null
        ? null
        : HermesLocalDocumentTrustStore.connectionIdentity(
            endpointIdentity: endpoint,
            principalId: ref
                .read(hermesConfigProvider.notifier)
                .documentTrustPrincipalId(),
          );
    final id = conversation!.metadata['hermesSessionId'];
    if (identity == null ||
        conversation.metadata[kHermesConnectionIdentityMetadataKey] !=
            identity ||
        id is! String ||
        id.isEmpty) {
      _owner = null;
      return _files = const [];
    }
    final owner = (
      service,
      conversation.id,
      identity,
      id,
      conversation.metadata['hermesBotProfile'],
    );
    if (_owner != owner) {
      _owner = owner;
      _files = const [];
    }
    // Keep completed files while a new reply arrives, without parsing the
    // growing transcript for each token. Retain at most one conversation.
    if (ref.watch(isChatStreamingProvider)) return _files;
    return _files = hermesLibraryFilesForMessages(
      ref.watch(chatMessagesProvider),
      HermesSessionSummary(id: id, title: conversation.title),
    ).reversed.take(256).toList(growable: false);
  }
}

final hermesLiveFilesProvider =
    NotifierProvider<HermesLiveFiles, List<HermesLibraryFile>>(
      HermesLiveFiles.new,
    );

/// Hermes exposes transcripts rather than a global files endpoint. Fetch a
/// bounded recent window, four at a time; the current chat is indexed locally
/// by the view so streaming never starts another network sweep.
final hermesMobileFilesProvider = StreamProvider<HermesFileLibrary>((
  ref,
) async* {
  final service = ref.watch(hermesApiServiceProvider);
  if (service == null) {
    yield const HermesFileLibrary([]);
    return;
  }
  final principal = ref
      .read(hermesConfigProvider.notifier)
      .documentTrustPrincipalId();
  final endpoint = HermesConfigController.connectionEndpoint(
    service.config.baseUrl,
  );
  final identity = endpoint == null
      ? null
      : HermesLocalDocumentTrustStore.connectionIdentity(
          endpointIdentity: endpoint,
          principalId: principal,
        );
  final cancel = CancelToken();
  ref.onDispose(() => cancel.cancel());
  final sessions = await ref.read(hermesSessionsProvider.future);
  if (!ref.mounted || cancel.isCancelled) return;
  final recent = sessions.take(40).toList();
  final files = <HermesLibraryFile>[];
  var failed = 0;
  for (var offset = 0; offset < recent.length; offset += 4) {
    if (!ref.mounted || cancel.isCancelled) break;
    final batch = recent.skip(offset).take(4);
    final results = await Future.wait(
      batch.map((session) async {
        try {
          final raw =
              await (service is HermesDesktopApiService
                      ? service.readStoredTranscript(
                          session.id,
                          cancelToken: cancel,
                        )
                      : service.getSessionMessages(
                          session.id,
                          cancelToken: cancel,
                        ))
                  .timeout(const Duration(seconds: 12));
          return hermesLibraryFilesForTranscript(
            raw,
            session,
            trustedLocalDocumentKeys: identity == null
                ? const {}
                : HermesLocalDocumentTrustStore.trustedDocumentKeys(
                    connectionIdentity: identity,
                    sessionId: session.id,
                  ),
          );
        } catch (_) {
          failed++;
          return <HermesLibraryFile>[];
        }
      }),
    );
    for (final result in results) {
      files.addAll(result.reversed);
    }
    if (!ref.mounted || cancel.isCancelled) return;
    yield HermesFileLibrary(
      List.unmodifiable(files),
      partial: failed > 0,
      indexing: offset + 4 < recent.length,
    );
  }
  if (recent.isNotEmpty && failed == recent.length) {
    throw StateError('file-index-unavailable');
  }
  yield HermesFileLibrary(List.unmodifiable(files), partial: failed > 0);
});
