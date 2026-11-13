import 'package:conduit_core/features/chat/composer/composer_availability.dart';
import 'package:conduit_core/features/chat/composer/composer_commands.dart';
import 'package:conduit_core/features/chat/providers/attached_files_provider.dart'
    show alwaysConvertImageFormats;
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/services/quick_pill_catalog.dart';
import 'package:conduit_core/features/chat/services/url_context.dart';
import 'package:conduit_core/features/chat/voice_call/voice_call_eligibility.dart'
    show voiceCallEligibilityProvider;
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart'
    show isHermesModel;
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart'
    show hermesSecretsLoadingProvider;
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/file_info.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart'
    show appSettingsProvider;
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/misc.dart' show ProviderListenable;
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import 'settled.dart';

/// Implements `composer.*` (what the composer may offer) and what it draws
/// on: `mentions.search`, `skills.search`, `context.*` and `files.list`.
///
/// The rules are the core's `webSearchAvailableProvider` and
/// `imageGenerationAvailableProvider`, the same ones mobile reads. Those
/// providers are synchronous views over asynchronous sources: the backend
/// config, the account's permissions, the model list. A cold read would see
/// every source still loading, and each provider's own fallback for
/// "loading" would decide the answer. So the sources are awaited first.
final class ComposerService {
  ComposerService(this._container);

  final ProviderContainer _container;

  Future<ComposerOptions> options() async {
    await Future.wait<Object?>(<Future<Object?>>[
      _settle(backendConfigProvider.future),
      _settle(userPermissionsProvider.future),
      _settle(modelsProvider.future),
    ]);

    List<ToolSummary> tools;
    var all = const <Tool>[];
    try {
      all = await readSettled(_container, toolsListProvider.future);
      tools = <ToolSummary>[
        for (final tool in all)
          ToolSummary(
            id: tool.id,
            name: tool.name,
            description: tool.description,
          ),
      ];
    } on Object catch (error) {
      // A server with no tools, or none this account may use, should
      // leave the picker empty rather than break the composer.
      DebugLogger.error('tools-failed', scope: 'daemon/composer', error: error);
      tools = const <ToolSummary>[];
    }

    // Listed without connecting to them: opening every server to count
    // its tools would make the composer wait on the slowest one.
    var mcpTools = const <ToolSummary>[];
    try {
      final servers = await readSettled(
        _container,
        directMcpServersProvider.future,
      );
      mcpTools = <ToolSummary>[
        for (final server in servers)
          if (server.enabled)
            ToolSummary(
              id: '$kDirectMcpToolIdPrefix${server.id}',
              name: server.name,
              description: Uri.tryParse(server.endpoint)?.host,
            ),
      ];
    } on Object catch (error) {
      DebugLogger.error('mcp-failed', scope: 'daemon/composer', error: error);
    }

    final model = _container.read(selectedModelProvider);
    final read = _container.read;
    // The interpreter as the + menu offers it with nothing chosen yet (the
    // core's offer); why it would not run, for a choice the window holds.
    final offer = _container.read(codeInterpreterOfferProvider);
    final block = _container.read(codeInterpreterBlockProvider);
    final kinds = composerAttachmentKinds(read, model);
    final openWebUi = composerSkillsAvailable(read, model);
    final directModel = model != null && hasReservedDirectIdentity(model);
    final webSearch = _container.read(webSearchAvailableProvider);
    final imageGeneration = _container.read(imageGenerationAvailableProvider);
    // Quick pills are an Open WebUI composer's, as on mobile: chosen in
    // Settings › Chats, drawn when this model can turn them on.
    final quickPills = openWebUi && !directModel
        ? composerQuickPills(
            _container.read(appSettingsProvider).quickPills,
            webSearchAvailable: webSearch,
            imageGenerationAvailable: imageGeneration,
            tools: all,
            filters: model?.filters ?? const [],
          )
        : const <QuickPillCandidate>[];
    final voiceCall = await _voiceCallAdmitted(model);
    return ComposerOptions(
      voiceCall: voiceCall,
      webSearch: webSearch,
      imageGeneration: imageGeneration,
      tools: tools,
      mcpTools: mcpTools,
      filters: <ToolSummary>[
        for (final filter in model?.filters ?? const [])
          ToolSummary(
            id: filter.id,
            name: filter.name,
            description: filter.description,
          ),
      ],
      filterDefaults: defaultFilterIdsForModel(model),
      codeInterpreter: offer != null,
      codeInterpreterBlock:
          block == null || block == CodeInterpreterBlock.notOpenWebUi
          ? null
          : block.name,
      attachments: AttachmentAvailability(
        files: kinds.file,
        serverFiles: kinds.serverFile,
        images: kinds.image,
        webPage: kinds.web,
        mcpContent: kinds.mcpContent,
      ),
      skills: openWebUi,
      context:
          composerContextAvailable(model) &&
          _container.read(apiServiceProvider) != null,
      notes: _container.read(notesFeatureEnabledProvider),
      // Users and channels are Open WebUI's, and a turn that never reaches
      // the server would carry their tokens as plain text.
      mentions: openWebUi && !directModel,
      steer: isHermesDesktopComposer(read, model),
      imageConversions: alwaysConvertImageFormats.toList()..sort(),
      compareModels: _container.read(comparisonCommandAvailableProvider),
      quickPills: <QuickPillOption>[
        for (final pill in quickPills)
          QuickPillOption(
            id: pill.id,
            kind: pill.kind.name,
            name: pill.name,
            targetId: pill.targetId,
          ),
      ],
    );
  }

  /// Whether a voice call may start with [model]: the core's admission, as
  /// the phone's launcher reads it. Hermes' secrets load at start; a Hermes
  /// model waits for them (as the launcher does) rather than reading
  /// "still loading" as "no".
  Future<bool> _voiceCallAdmitted(Model? model) async {
    if (model != null && isHermesModel(model)) {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (_container.read(hermesSecretsLoadingProvider) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    try {
      return _container.read(voiceCallEligibilityProvider).canStart;
    } on Object catch (error) {
      DebugLogger.error(
        'voice-call-admission-failed',
        scope: 'daemon/composer',
        error: error,
      );
      return false;
    }
  }

  /// The server's users and channels matching [query], for `@`.
  Future<MentionList> mentions(String query) async {
    final api = _container.read(apiServiceProvider);
    if (api == null) return const MentionList();
    final q = query.trim().toLowerCase();
    var users = const <MentionTarget>[];
    var channels = const <MentionTarget>[];
    await Future.wait<void>(<Future<void>>[
      () async {
        try {
          final page = await api.searchWorkspaceUsers(q);
          users = <MentionTarget>[
            for (final user in page.items.take(_mentionsPerKind))
              MentionTarget(id: user.id, name: user.name, detail: user.email),
          ];
        } on Object catch (error) {
          DebugLogger.error(
            'users-failed',
            scope: 'daemon/composer',
            error: error,
          );
        }
      }(),
      () async {
        try {
          final (rows, _) = await api.getChannels();
          channels = <MentionTarget>[
            for (final row in rows)
              if ('${row['id'] ?? ''}'.isNotEmpty &&
                  '${row['name'] ?? ''}'.toLowerCase().contains(q))
                MentionTarget(
                  id: '${row['id']}',
                  name: '${row['name']}',
                  detail: _text(row['description']),
                ),
          ].take(_mentionsPerKind).toList();
        } on Object catch (error) {
          DebugLogger.error(
            'channels-failed',
            scope: 'daemon/composer',
            error: error,
          );
        }
      }(),
    ]);
    return MentionList(users: users, channels: channels);
  }

  static const int _mentionsPerKind = 4;

  /// Open WebUI skills matching [query], for `$`.
  Future<SkillList> skills(String query) async {
    final api = _container.read(apiServiceProvider);
    if (api == null) return const SkillList();
    final skills = await searchComposerSkills(api, query: query.trim());
    return SkillList(
      items: <SkillSummary>[
        for (final skill in skills)
          SkillSummary(
            id: skill.id,
            name: skill.name,
            description: _text(skill.description),
          ),
      ],
    );
  }

  /// Notes, knowledge bases and knowledge files matching [query], for `#`:
  /// the core's searches and its four of each. A row with no name of its
  /// own comes with an empty one, which the window names in its language.
  Future<ContextSuggestions> context(String query) async {
    final api = _container.read(apiServiceProvider);
    if (api == null) return const ContextSuggestions();
    final notes = _container.read(notesFeatureEnabledProvider);
    final account = _container.read(openWebUiAuthSessionEpochProvider);
    final rows = await searchComposerContext(
      api,
      query: query.trim(),
      includeNotes: notes,
      // As mobile: a server that refuses notes stops being asked for them,
      // the account that asked only.
      onNotesForbidden: () {
        if (!identical(
          account,
          _container.read(openWebUiAuthSessionEpochProvider),
        )) {
          return;
        }
        _container.read(notesFeatureEnabledProvider.notifier).setEnabled(false);
      },
    );
    final suggestions = buildComposerContextSuggestions(
      notes: rows.notes,
      bases: rows.bases,
      files: rows.files,
      untitledLabel: '',
      knowledgeBaseLabel: '',
      fileLabel: '',
    );
    return ContextSuggestions(
      items: <ContextSuggestion>[
        for (final s in suggestions)
          ContextSuggestion(
            kind: switch (s.type) {
              ComposerContextSuggestionType.note => ContextSuggestionKind.note,
              ComposerContextSuggestionType.knowledgeBase =>
                ContextSuggestionKind.knowledgeBase,
              ComposerContextSuggestionType.knowledgeFile =>
                ContextSuggestionKind.knowledgeFile,
            },
            id: s.id,
            name: s.displayName,
            subtitle: s.subtitle,
            collectionName: s.collectionName,
          ),
      ],
    );
  }

  /// A web page's readable text or a YouTube video's transcript, read by the
  /// server, as mobile's Web Page dialog attaches it.
  Future<FetchedUrl> fetchUrl(String url) async {
    final api = _container.read(apiServiceProvider);
    final trimmed = url.trim();
    if (!isFetchableUrl(trimmed)) return const FetchedUrl(error: 'invalidUrl');
    if (api == null) return const FetchedUrl(error: 'failed');
    try {
      final page = await readUrlContext(api, trimmed);
      if (page.content.isEmpty) return const FetchedUrl(error: 'noContent');
      return FetchedUrl(
        attachment: ContextAttachmentDto(
          id: const Uuid().v4(),
          kind: page.youtube
              ? ContextAttachmentKind.youtube
              : ContextAttachmentKind.web,
          name: page.displayName,
          url: page.url,
          content: page.content,
          collectionName: page.collectionName,
        ),
      );
    } on Object catch (error) {
      DebugLogger.error(
        'fetch-url-failed',
        scope: 'daemon/composer',
        error: error,
      );
      return const FetchedUrl(error: 'failed');
    }
  }

  /// The account's files on the server, newest first, matching [query]:
  /// what mobile's server-file picker lists.
  Future<ServerFileList> serverFiles(String query) async {
    if (_container.read(apiServiceProvider) == null) {
      return const ServerFileList();
    }
    final q = query.trim();
    final List<FileInfo> files;
    if (q.isEmpty) {
      _container.invalidate(userFilesProvider);
      files = await readSettled(_container, userFilesProvider.future);
    } else {
      files = await readSettled(_container, searchUserFilesProvider(q).future);
    }
    final sorted = List<FileInfo>.of(files)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return ServerFileList(
      items: <ServerFile>[
        for (final file in sorted)
          ServerFile(
            id: file.id,
            name: file.displayName,
            size: file.size,
            contentType: file.mimeType.isEmpty ? null : file.mimeType,
            updatedAtMs: file.updatedAt.millisecondsSinceEpoch,
          ),
      ],
    );
  }

  static String? _text(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// Knowledge bases matching [query], for the `#` menu.
  Future<KnowledgeList> knowledge(String query) async {
    final api = _container.read(apiServiceProvider);
    if (api == null) return const KnowledgeList();
    final rows = await api.searchKnowledgeBases(query: query.trim());
    return KnowledgeList(
      items: <KnowledgeSummary>[
        for (final row in rows)
          if (row['id'] != null)
            KnowledgeSummary(
              id: '${row['id']}',
              name: '${row['name'] ?? row['id']}',
              description:
                  (row['description'] as String?)?.trim().isEmpty ?? true
                  ? null
                  : row['description'] as String,
            ),
      ],
    );
  }

  /// Waits for a source, and lets it fail. The availability rules have
  /// their own answer for a source that errored, and that answer is the
  /// one to use.
  Future<Object?> _settle<T>(ProviderListenable<Future<T>> provider) =>
      readSettled<T>(
        _container,
        provider,
      ).then<Object?>((value) => value, onError: (Object _) => null);
}
