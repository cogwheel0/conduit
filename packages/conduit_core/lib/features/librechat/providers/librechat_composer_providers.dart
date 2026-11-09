import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/librechat/models/librechat_capabilities.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart';
import 'package:conduit_core/features/librechat/models/librechat_prompts.dart';
import 'package:conduit_core/features/librechat/models/librechat_tools.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_http_client.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/ports/app_lifecycle.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// The files uploaded to LibreChat for the message being written, by the
/// `file_id` the composer holds for each. A turn sends their records back
/// in `files`; they live in memory only, like the composer's other state.
final libreChatUploadedFilesProvider =
    NotifierProvider<LibreChatUploadedFiles, Map<String, Map<String, dynamic>>>(
      LibreChatUploadedFiles.new,
    );

class LibreChatUploadedFiles
    extends Notifier<Map<String, Map<String, dynamic>>> {
  /// Records belong to the account they were uploaded to: another account
  /// in use starts with none, so a turn can never name a file on a server
  /// that does not hold it.
  @override
  Map<String, Map<String, dynamic>> build() {
    ref.watch(activeLibreChatAccountProvider.select((account) => account?.id));
    return const <String, Map<String, dynamic>>{};
  }

  /// Whether a record for [fileId] is kept.
  bool has(String fileId) => state.containsKey(fileId);

  /// Keeps the record LibreChat returned for an upload.
  void record(Map<String, dynamic> file) {
    final id = file['file_id'];
    if (id is! String || id.isEmpty) return;
    state = <String, Map<String, dynamic>>{...state, id: file};
  }

  /// The records for [fileIds], in order; throws when one is unknown, so a
  /// turn never goes out missing a file the user attached.
  List<Map<String, dynamic>> recordsFor(Iterable<String> fileIds) => [
    for (final id in fileIds)
      state[id] ??
          (throw const LibreChatApiException(
            message: 'An attached file is no longer available. Attach it again.',
          )),
  ];

  /// Forgets [fileIds] once their turn has gone out.
  void forget(Iterable<String> fileIds) {
    final ids = fileIds.toSet();
    if (!state.keys.any(ids.contains)) return;
    state = <String, Map<String, dynamic>>{
      for (final entry in state.entries)
        if (!ids.contains(entry.key)) entry.key: entry.value,
    };
  }
}

/// The record a turn sends for an uploaded [file]: what LibreChat's web
/// client sends, `{file_id, filepath, filename, type, width, height}`.
Map<String, dynamic> libreChatTurnFile(Map<String, dynamic> file) =>
    <String, dynamic>{
      'file_id': file['file_id'],
      'filepath': ?file['filepath'],
      'filename': ?file['filename'],
      'type': ?file['type'],
      'width': ?file['width'],
      'height': ?file['height'],
      'embedded': ?file['embedded'],
    };

/// Loads a file path on the signed-in LibreChat server (`/images/...`) as
/// bytes, while LibreChat is the primary account; null otherwise.
///
/// LibreChat serves these by session cookie, and checks it against the live
/// session, so a cookie captured before a renewal stops working. Fetching
/// through the account's HTTP client sends the cookies current at that
/// moment and renews once when refused; the cookies never land in a stored
/// file map or a cache key.
final libreChatImageFetcherProvider =
    Provider<Future<Uint8List> Function(String path)?>((ref) {
      if (ref.watch(primaryAccountKindProvider) !=
          PrimaryAccountKind.libreChat) {
        return null;
      }
      final client = ref.watch(libreChatHttpClientProvider);
      if (client == null) return null;
      return (path) async {
        try {
          final response = await client.dio.get<List<int>>(
            path,
            options: Options(responseType: ResponseType.bytes),
          );
          return Uint8List.fromList(response.data ?? const <int>[]);
        } on DioException catch (error) {
          throw libreChatErrorOf(error, fallback: 'The image did not load.');
        }
      };
    });

/// The base address relative LibreChat file paths resolve against, while
/// LibreChat is the primary account and signed in; null otherwise.
final libreChatFileBaseUrlProvider = Provider<String?>((ref) {
  if (ref.watch(primaryAccountKindProvider) != PrimaryAccountKind.libreChat) {
    return null;
  }
  final state = ref.watch(libreChatSessionProvider).asData?.value;
  return state is LibreChatSignedInState ? state.account.server.baseUrl : null;
});

// ---- tools ----------------------------------------------------------------

/// Composer tool ids for LibreChat's toggles, kept apart from Open WebUI and
/// Direct tool ids so neither backend ever receives the other's.
const String kLibreChatToolIdPrefix = 'librechat:';
const String kLibreChatWebSearchToolId = '${kLibreChatToolIdPrefix}web_search';
const String kLibreChatCodeToolId = '${kLibreChatToolIdPrefix}execute_code';
const String kLibreChatFileSearchToolId = '${kLibreChatToolIdPrefix}file_search';
const String kLibreChatMcpToolIdPrefix = '${kLibreChatToolIdPrefix}mcp:';

bool isLibreChatToolId(String id) => id.startsWith(kLibreChatToolIdPrefix);

/// One of the user's MCP servers, as the composer offers it.
@immutable
final class LibreChatMcpServerOption {
  const LibreChatMcpServerOption({
    required this.name,
    this.toolCount = 0,
    this.needsConnection = false,
  });

  final String name;
  final int toolCount;

  /// The server needs the user to sign in to it (OAuth or credentials),
  /// which only LibreChat's web app can do.
  final bool needsConnection;

  String get toolId => '$kLibreChatMcpToolIdPrefix$name';
}

/// Whether MCP server [server] (its `/api/mcp/tools` entry) needs the user to
/// connect it in LibreChat's web app first, going by its connection
/// [status] (`/api/mcp/connection/status`) as LibreChat's own client does.
///
/// The tools listing alone cannot tell: it reads `authenticated: false` for
/// every server with per-user variables, saved or not. It is all there is to
/// go by when the status has no word on the server.
@visibleForTesting
bool libreChatMcpServerNeedsConnection(Object? server, Object? status) {
  final listing = server is Map ? server : const <Object?, Object?>{};
  if (listing['authorizationState'] == 'reauth_required') return true;
  if (status is! Map) return listing['authenticated'] == false;
  // Per-user variables not saved yet, on a server connected per request.
  if (status['configurationState'] == 'needs_configuration') return true;
  if (status['connectionState'] == 'connected') return false;
  if (status['requestScoped'] == true) {
    // Connected only while a request runs: ready once authorized.
    final authorization = status['authorizationState'];
    return authorization != null &&
        authorization != 'not_required' &&
        authorization != 'authorized';
  }
  if (status['requiresOAuth'] == true) return true;
  // Per-user variables on a lasting connection, which is not up.
  final userVariables = listing['authConfig'];
  return userVariables is List && userVariables.isNotEmpty;
}

/// What the composer may offer a LibreChat turn: tools the server and the
/// user's role allow, for a model that takes ad-hoc tools.
@immutable
final class LibreChatComposerOptions {
  const LibreChatComposerOptions({
    this.webSearch = false,
    this.codeInterpreter = false,
    this.fileSearch = false,
    this.mcpServers = const <LibreChatMcpServerOption>[],
    this.prompts = false,
  });

  static const LibreChatComposerOptions none = LibreChatComposerOptions();

  final bool webSearch;
  final bool codeInterpreter;
  final bool fileSearch;
  final List<LibreChatMcpServerOption> mcpServers;

  /// The prompt library is offered for `/`.
  final bool prompts;

  bool get hasTools =>
      webSearch || codeInterpreter || fileSearch || mcpServers.isNotEmpty;
}

/// Whether [model] takes the composer's ad-hoc tools. Saved agents and the
/// admin's model specs bring their own.
bool libreChatModelTakesTools(Model? model) {
  final target = model == null ? null : libreChatTargetOf(model);
  return target != null && target.kind == LibreChatTargetKind.endpoint;
}

/// Whether chat may pick the MCP server with [settings] (from
/// `/api/mcp/servers`) on its own. LibreChat drops one its admin hid from
/// chat (`chatMenu: false`), or one reached only through an agent
/// (`consumeOnly`), from a turn's tools. One without settings is offered,
/// as LibreChat keeps it.
bool libreChatMcpServerChatSelectable(Object? settings) =>
    settings is! Map ||
    (settings['chatMenu'] != false && settings['consumeOnly'] != true);

/// The composer's LibreChat options for the selected model.
final libreChatComposerOptionsProvider =
    FutureProvider<LibreChatComposerOptions>((ref) async {
      final model = ref.watch(selectedModelProvider);
      if (model == null || !isLibreChatModel(model)) {
        return LibreChatComposerOptions.none;
      }
      final LibreChatCapabilities capabilities;
      try {
        capabilities = await ref.watch(libreChatCapabilitiesProvider.future);
      } catch (_) {
        return LibreChatComposerOptions.none;
      }
      if (!libreChatModelTakesTools(model)) {
        return LibreChatComposerOptions(prompts: capabilities.prompts);
      }
      final mcpServers = <LibreChatMcpServerOption>[];
      final api = ref.watch(libreChatApiServiceProvider);
      if (capabilities.mcpServers && api != null) {
        try {
          final results = await Future.wait<Map<String, dynamic>>([
            api.mcpServers(),
            api
                .mcpConnectionStatus()
                .catchError((Object _) => <String, dynamic>{}),
            api
                .mcpServerSettings()
                .catchError((Object _) => <String, dynamic>{}),
          ]);
          final servers = results[0];
          final status = results[1];
          final settings = results[2];
          for (final entry in servers.entries) {
            if (!libreChatMcpServerChatSelectable(settings[entry.key])) {
              continue;
            }
            final server = entry.value;
            final connection = status[entry.key];
            final tools = server is Map ? server['tools'] : null;
            mcpServers.add(
              LibreChatMcpServerOption(
                name: entry.key,
                toolCount: tools is List ? tools.length : 0,
                needsConnection: libreChatMcpServerNeedsConnection(
                  server,
                  connection,
                ),
              ),
            );
          }
        } on LibreChatApiException catch (error) {
          DebugLogger.warning(
            'mcp-list-failed',
            scope: 'librechat/composer',
            data: {'status': error.statusCode},
          );
        }
      }
      // A server is signed in to in the browser; coming back to the app
      // reads where each stands again, so a connected one can be used.
      if (ref.mounted && mcpServers.any((server) => server.needsConnection)) {
        final resumed = ref
            .read(appLifecycleProvider)
            .changes
            .where((phase) => phase == AppLifecyclePhase.resumed)
            .listen((_) => ref.invalidateSelf());
        ref.onDispose(resumed.cancel);
      }
      return LibreChatComposerOptions(
        webSearch: capabilities.webSearch,
        codeInterpreter: capabilities.codeInterpreter,
        fileSearch: capabilities.fileSearch,
        mcpServers: List.unmodifiable(mcpServers),
        prompts: capabilities.prompts,
      );
    });

/// The tools a turn asks for, from the composer's selected tool ids.
LibreChatToolSelection libreChatToolSelectionFor(Iterable<String> toolIds) {
  final ids = toolIds.toSet();
  return LibreChatToolSelection(
    webSearch: ids.contains(kLibreChatWebSearchToolId),
    codeInterpreter: ids.contains(kLibreChatCodeToolId),
    fileSearch: ids.contains(kLibreChatFileSearchToolId),
    mcpServers: [
      for (final id in ids)
        if (id.startsWith(kLibreChatMcpToolIdPrefix))
          id.substring(kLibreChatMcpToolIdPrefix.length),
    ]..sort(),
  );
}

// ---- prompts ----------------------------------------------------------------

/// The user's LibreChat prompt groups, as `/` commands; none when the server
/// does not let them use prompts.
final libreChatPromptsProvider = FutureProvider<List<Prompt>>((ref) async {
  final api = ref.watch(libreChatApiServiceProvider);
  if (api == null) return const <Prompt>[];
  final options = await ref.watch(libreChatComposerOptionsProvider.future);
  if (!options.prompts) return const <Prompt>[];
  final groups = await api.promptGroups();
  return List.unmodifiable([
    for (final group in groups) ?libreChatPromptFromGroup(group),
  ]);
});
